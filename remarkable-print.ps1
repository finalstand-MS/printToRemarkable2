<#
    reMarkable print watcher

    Watches C:\reMarkable\print.prn, captures each finished print job into a
    queue on disk, and uploads it to the reMarkable over USB.

    Design rules:
      - Capture first, upload second. A print made while the device is
        unplugged is queued, never lost.
      - Nothing is deleted until the device confirms the upload.
      - Retries are only counted while the device is actually reachable.
#>

$ErrorActionPreference = 'Stop'

$Root       = 'C:\reMarkable'
$PrintFile  = Join-Path $Root 'print.prn'
$QueueDir   = Join-Path $Root 'queue'
$FailedDir  = Join-Path $Root 'failed'
$LogFile    = Join-Path $Root 'print.log'

$PrinterName = 'reMarkable'
$DeviceIP    = '10.11.99.1'
$UploadUrl   = "http://$DeviceIP/upload"

$PollMs      = 500      # main loop interval
$ProbeMs     = 700      # TCP connect timeout
$UploadSecs  = 120      # curl --max-time
$MaxRetries  = 5        # attempts made while the device is reachable
$LogMaxBytes = 512KB

# --------------------------------------------------------------------------
# single instance
# --------------------------------------------------------------------------
$createdNew = $false
try {
    $mutex = New-Object System.Threading.Mutex($true, 'Local\reMarkablePrintWatcher', [ref]$createdNew)
} catch {
    $createdNew = $true   # mutex unavailable; carry on rather than refuse to run
}
if (-not $createdNew) { exit 0 }

New-Item -ItemType Directory -Force $Root, $QueueDir, $FailedDir | Out-Null

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $LogMaxBytes)) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) |
            Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

function Test-Device {
    # TCP probe of the reMarkable web interface. Faster and more meaningful
    # than ICMP: the device can answer ping before /upload is serving.
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async  = $client.BeginConnect($DeviceIP, 80, $null, $null)
        $ok     = $async.AsyncWaitHandle.WaitOne($ProbeMs, $false)
        if ($ok) { $client.EndConnect($async) }
        return $ok
    } catch {
        return $false
    } finally {
        if ($client) { $client.Close() }
    }
}

function Test-FileComplete {
    # The spooler holds the file open while writing. Require an exclusive
    # open plus a size that is unchanged across two checks.
    param([string]$Path)
    try {
        $first = (Get-Item $Path).Length
        if ($first -le 0) { return $false }
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        Start-Sleep -Milliseconds 400
        if (-not (Test-Path $Path)) { return $false }
        return ((Get-Item $Path).Length -eq $first)
    } catch {
        return $false
    }
}

function Test-Pdf {
    param([string]$Path)
    $fs = $null
    try {
        $fs  = [System.IO.File]::OpenRead($Path)
        $buf = New-Object byte[] 5
        $n   = $fs.Read($buf, 0, 5)
        return ($n -eq 5 -and [System.Text.Encoding]::ASCII.GetString($buf) -eq '%PDF-')
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-SpooledDocumentName {
    # Microsoft Print to PDF loses the document title once the job is written,
    # so it is captured while the job is still in the queue.
    try {
        $job = Get-PrintJob -PrinterName $PrinterName -ErrorAction SilentlyContinue |
               Select-Object -Last 1
        if ($job -and $job.DocumentName) { return [string]$job.DocumentName }
    } catch { }
    return $null
}

function ConvertTo-SafeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace($c, ' ')
    }
    # strip a source extension so the title is not "report.docx.pdf"
    $Name = $Name -replace '\.(docx?|xlsx?|pptx?|pdf|txt|htm|html|md)$', ''
    $Name = ($Name -replace '\s+', ' ').Trim()
    if ($Name.Length -gt 90) { $Name = $Name.Substring(0, 90).Trim() }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    return $Name
}

function New-QueuePath {
    param([string]$Title)
    if (-not $Title) { $Title = 'Print {0}' -f (Get-Date -Format 'yyyy-MM-dd HH-mm-ss') }
    $path = Join-Path $QueueDir "$Title.pdf"
    $i = 1
    while (Test-Path $path) {
        $path = Join-Path $QueueDir "$Title ($i).pdf"
        $i++
    }
    return $path
}

function Send-ToRemarkable {
    # curl sends the file name as the multipart filename, which becomes the
    # document title on the device.
    param([string]$Path)
    $output = & curl.exe --silent --show-error --fail --max-time $UploadSecs `
                  -F "file=@$Path;type=application/pdf" $UploadUrl 2>&1
    $code = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($code -ne 0)                  { return @{ Ok = $false; Message = "curl exit $code $text".Trim() } }
    if ($text -match '(?i)"?error"?') { return @{ Ok = $false; Message = $text } }
    return @{ Ok = $true; Message = $text }
}

# --------------------------------------------------------------------------
# main loop
# --------------------------------------------------------------------------
Write-Log "watcher started (pid $PID)"

$attempts = @{}     # queued file name -> failed attempts while reachable
$online   = $null   # last logged reachability, so transitions log once
$lastDoc  = $null   # most recent spooled document title

while ($true) {
    try {
        # 1. remember the title of anything currently spooling
        $doc = Get-SpooledDocumentName
        if ($doc) { $lastDoc = $doc }

        # 2. capture a finished print job into the queue
        if ((Test-Path $PrintFile) -and (Test-FileComplete $PrintFile)) {
            $dest = New-QueuePath (ConvertTo-SafeName $lastDoc)
            $lastDoc = $null
            Move-Item $PrintFile $dest -Force
            $name = Split-Path $dest -Leaf

            if (Test-Pdf $dest) {
                Write-Log "queued: $name ($((Get-Item $dest).Length) bytes)"
            } else {
                Move-Item $dest (Join-Path $FailedDir $name) -Force
                Write-Log "not a PDF, moved to failed: $name"
            }
        }

        # 3. drain the queue whenever the device is reachable
        $jobs = @(Get-ChildItem $QueueDir -Filter *.pdf -File -ErrorAction SilentlyContinue |
                  Sort-Object CreationTime)

        if ($jobs.Count -eq 0) {
            $online = $null   # queue empty: report state again on the next job
        } else {
            $up = Test-Device
            if ($up -ne $online) {
                $online = $up
                if ($up) { Write-Log "reMarkable reachable at $DeviceIP" }
                else     { Write-Log "reMarkable not reachable, $($jobs.Count) job(s) waiting" }
            }

            if ($up) {
                foreach ($job in $jobs) {
                    $result = Send-ToRemarkable $job.FullName

                    if ($result.Ok) {
                        Remove-Item $job.FullName -Force
                        $attempts.Remove($job.Name)
                        Write-Log "uploaded: $($job.Name)"
                        continue
                    }

                    if (-not (Test-Device)) {
                        # went away mid-upload: not the file's fault, do not
                        # count the attempt
                        Write-Log "upload interrupted, device went away: $($job.Name)"
                        $online = $false
                        break
                    }

                    $n = [int]$attempts[$job.Name] + 1
                    $attempts[$job.Name] = $n
                    Write-Log "upload failed ($n/$MaxRetries): $($job.Name) - $($result.Message)"

                    if ($n -ge $MaxRetries) {
                        Move-Item $job.FullName (Join-Path $FailedDir $job.Name) -Force
                        $attempts.Remove($job.Name)
                        Write-Log "gave up, moved to failed: $($job.Name)"
                    }
                    Start-Sleep -Seconds 2
                }
            }
        }
    } catch {
        Write-Log "watcher error: $($_.Exception.Message)"
        Start-Sleep -Seconds 2
    }

    Start-Sleep -Milliseconds $PollMs
}
