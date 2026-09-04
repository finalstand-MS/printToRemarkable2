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

# SIG # Begin signature block
# MIIcFwYJKoZIhvcNAQcCoIIcCDCCHAQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCB+8pccgtSempmS
# CorhsBiLCGFX0pY7kDVxJ2IGzrOmcKCCFlgwggMaMIICAqADAgECAhBGkcMhxQq6
# sEsltXkoFAUAMA0GCSqGSIb3DQEBCwUAMCUxIzAhBgNVBAMMGmZpbmFsc3RhbmQt
# TVMgQ29kZSBTaWduaW5nMB4XDTI2MDkwNDIzMzUwMloXDTMxMDkwNDIzNDUwM1ow
# JTEjMCEGA1UEAwwaZmluYWxzdGFuZC1NUyBDb2RlIFNpZ25pbmcwggEiMA0GCSqG
# SIb3DQEBAQUAA4IBDwAwggEKAoIBAQDRUPZfnI4xiL3WYAuEFDe2ICKsFQIyqEnM
# mfasJp+h3CdY61ljpjilvS973ZLJuEh1RkqMOo9ZkNp7Z1REXdLb1aeCqIvVZ4HP
# fTWwe7kSBZz4X4wrBiBJbJOlJ0LIII/iXh1XmiBdXbqh2vnXannY4XosI+iRnIJN
# w+XUie59quyXNHedWaRxUTlg6S+J17A4UQs+wyhYhbgEbPrazzNvxZR4kUvNdMaY
# Gy9gLxbZBzkTbVD4/udoehkLcPf/GX2gUVooZWnX7bHQQXzQWR+ElSDAC9s58dfF
# d96bptqhDfBNNjBEVaY7V0OkdFY3XuX+EwEHWBmKnFC45nate/XBAgMBAAGjRjBE
# MA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAzAdBgNVHQ4EFgQU
# odw56+BJ6FhPvzKQFVREsTxYccUwDQYJKoZIhvcNAQELBQADggEBAJ0qpEPq94Zb
# 9HA1Hh5KflDj3DZw5jTANmeABKTsmlFC3BayeAp6sVQfHV09w9D8QZesiKvBTzZY
# 7efyfocIC4IPauhz050fKSMR4mH3xGQY7sR7QrvlIaZxLZ0e8/Nsfk2kg2p9oC2B
# a8/WTxy+KLOqgmGZfvf+u67BCpOOxI+gD01W/blSmuXzb4BCNXYvg3XYm02EEcWj
# 3FD6h2DQe2RdqAsPpHJ3IBIIo67qq8dWkQiITeqlmVWO0XK4sYCxbtxYXskp98A0
# VCbNZfrTzbAllHTCE7c5epL61nMDynG5ppcg02PmpOgIvT/cYo+ucx8zxpfZT+0g
# nrD9O66BKh8wggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqGSIb3
# DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAX
# BgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3Vy
# ZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTlaMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8MCIw
# aTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauyefLK
# EdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34LzB4Tm
# dDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+xembu
# d8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhAkHnD
# eMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1LyuGwN1
# XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2PVld
# QnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37AlLTS
# YW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD76GSm
# M9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/ybzT
# QRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXAj6Kx
# fgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTADAQH/
# MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF66Kv
# 9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEEbTBr
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUH
# MAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAIMAYG
# BFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979XB72a
# rKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4kvFID
# yE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU53/o
# Wajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pcVIxv
# 76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5vIy30
# fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQwgga0MIIE
# nKADAgECAhANx6xXBf8hmS5AQyIMOkmGMA0GCSqGSIb3DQEBCwUAMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0y
# NTA1MDcwMDAwMDBaFw0zODAxMTQyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYD
# VQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBH
# NCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQC0eDHTCphBcr48RsAcrHXbo0ZodLRRF51N
# rY0NlLWZloMsVO1DahGPNRcybEKq+RuwOnPhof6pvF4uGjwjqNjfEvUi6wuim5ba
# p+0lgloM2zX4kftn5B1IpYzTqpyFQ/4Bt0mAxAHeHYNnQxqXmRinvuNgxVBdJkf7
# 7S2uPoCj7GH8BLuxBG5AvftBdsOECS1UkxBvMgEdgkFiDNYiOTx4OtiFcMSkqTtF
# 2hfQz3zQSku2Ws3IfDReb6e3mmdglTcaarps0wjUjsZvkgFkriK9tUKJm/s80Fio
# cSk1VYLZlDwFt+cVFBURJg6zMUjZa/zbCclF83bRVFLeGkuAhHiGPMvSGmhgaTzV
# yhYn4p0+8y9oHRaQT/aofEnS5xLrfxnGpTXiUOeSLsJygoLPp66bkDX1ZlAeSpQl
# 92QOMeRxykvq6gbylsXQskBBBnGy3tW/AMOMCZIVNSaz7BX8VtYGqLt9MmeOreGP
# RdtBx3yGOP+rx3rKWDEJlIqLXvJWnY0v5ydPpOjL6s36czwzsucuoKs7Yk/ehb//
# Wx+5kMqIMRvUBDx6z1ev+7psNOdgJMoiwOrUG2ZdSoQbU2rMkpLiQ6bGRinZbI4O
# Lu9BMIFm1UUl9VnePs6BaaeEWvjJSjNm2qA+sdFUeEY0qVjPKOWug/G6X5uAiynM
# 7Bu2ayBjUwIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4E
# FgQU729TSunkBnx6yuKQVvYv1Ensy04wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5n
# P+e6mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcG
# CCsGAQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQu
# Y29tMEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGln
# aUNlcnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8v
# Y3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNV
# HSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIB
# ABfO+xaAHP4HPRF2cTC9vgvItTSmf83Qh8WIGjB/T8ObXAZz8OjuhUxjaaFdleMM
# 0lBryPTQM2qEJPe36zwbSI/mS83afsl3YTj+IQhQE7jU/kXjjytJgnn0hvrV6hqW
# Gd3rLAUt6vJy9lMDPjTLxLgXf9r5nWMQwr8Myb9rEVKChHyfpzee5kH0F8HABBgr
# 0UdqirZ7bowe9Vj2AIMD8liyrukZ2iA/wdG2th9y1IsA0QF8dTXqvcnTmpfeQh35
# k5zOCPmSNq1UH410ANVko43+Cdmu4y81hjajV/gxdEkMx1NKU4uHQcKfZxAvBAKq
# MVuqte69M9J6A47OvgRaPs+2ykgcGV00TYr2Lr3ty9qIijanrUR3anzEwlvzZiiy
# fTPjLbnFRsjsYg39OlV8cipDoq7+qNNjqFzeGxcytL5TTLL4ZaoBdqbhOhZ3ZRDU
# phPvSRmMThi0vw9vODRzW6AxnJll38F0cuJG7uEBYTptMSbhdhGQDpOXgpIUsWTj
# d6xpR6oaQf/DJbg3s6KCLPAlZ66RzIg9sC+NJpud/v4+7RWsWCiKi9EOLLHfMR2Z
# yJ/+xhCx9yHbxtl5TPau1j/1MIDpMPx0LckTetiSuEtQvLsNz3Qbp7wGWqbIiOWC
# nb5WqxL3/BAPvIXKUjPSxyZsq8WhbaM2tszWkPZPubdcMIIG7TCCBNWgAwIBAgIQ
# CE/cM09+RU7bww+P+ZIYNTANBgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEX
# MBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0
# ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMB4XDTI2
# MDgwNTAwMDAwMFoXDTM3MTEwNDIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAVBgNV
# BAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBTSEEyNTYgUlNB
# NDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVyIDIwMjYgMTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBALZ7pvLJ/s1K+NSbTGWz/TjGMPh8CQ6RucZCLv5anHzW
# JjF/NWJrFIhy24fcpKXlgRiky4WAawDfU3YP0BMxt9l3Dm5oCG5Z69AqEN1kgHg2
# epx+l+lZBcmJCcN0ASURML5uFIS80sZsDwO3BSkUxDjLJhBI+qiZP3aixAC/qEGL
# jsBNlLol9VZ7pfGEXiMlneJIC5/YKuizVzNFKZZEeoy/0B8Zm+nzKBgSWG52lCO1
# w+nCg6XpCtklTJXeIg283hw7TmmsZXR+SMbjbrEOvZ3fP2VxIgeR28Y90ZStd3F9
# VuA5RVynb/whITPAo9b75Zr4Ta6Mj3URm26QZYMn/FnbuTegcoRcFEZ9FOqM5T6M
# Tdtr/n74lIT/ug0eeOzmZ6QTFg33otX+bFRsIolvykE1jive4PuESaT8zzVeFWDA
# MDtozNgLctkGD1ZjkEyZtJrLl5ya0m5doH/ScpaZCZVl6pNUOCybMc/kxC6EAmSJ
# Y24L0yYKD1Nkddsnb/ItVKi/2nXpQNMu1PT5prW83vV8d67WowuUs0HdY4H8AMLG
# vdL/WHEj3ZnqMqAQQP9u3Ai9t+5eQ02GDwy0ODjdzi0xlp70W+ow63/0++YDEX1M
# 0iwgUHwbrJvfpklkZQvw3+kv3vUPItdwroczk9icflf55W1zOEKAcJVAIXpcMCU9
# AgMBAAGjggGVMIIBkTAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBQUyWOKMC7USvtu
# lPPm40B+9ezN4jAfBgNVHSMEGDAWgBTvb1NK6eQGfHrK4pBW9i/USezLTjAOBgNV
# HQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsGAQUFBwEB
# BIGIMIGFMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXQYI
# KwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRy
# dXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNydDBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRU
# cnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcmwwIAYD
# VR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4IC
# AQCNxTphHp1SCt+ZrAmAfn0oQLFr0mLywSLaDXQIENoyKqxrFbJblzCVP/pkXmwX
# OdrOpWygLzlT12os5ipDCy35RBCg2UMeApEtrfGhz45F4Wt4WGdNdIbRWt3YTYJm
# pR+b7lr4d7Uwn+H600u4D7RnOGf8Wj4UNgAdZkfHhHv1mx9EVh71SJelcEN/oORS
# jXzdjfw1iZH9d8Nh/thn6hH23d+VsPAr6GAYyzSA02nXD1nYLI7Ijmiv+xLCiYC4
# 1DSFYL3GhTiy0PxpawPtGRyaBVGzq+UiTfM8pD7KVyF5aQyWP4KhVGUUTnmm/RlY
# JoW3TiXA/+t0YcT2oRVBm3JETjajHug2AL+v5jhtKVnd3D0rbHXEu27o+Q8p4sEW
# PMqKDB+qbceb6T/6WcwTwXmQ9lOCLLYcsQeSWmvKqzpAec9etE14jOQAzLKWdE3w
# /TCaKtLRaRT7LCkRYVnhA2D73FLje1O5b3HR5eHs0NzU/+xX7NbEdcofy0W3Wdwd
# 1XOqtlpg/JgwtKfZM5dqO94lbUveOiJBI+xZEbGRsMNbXmMREUTgu+Oca7Y73MPW
# cslIx2VhkSKSXjDbD6rgg39H5Mh7QfieAIjWagkJNt68Yfim6cjEzVSiLSeZfdkr
# 5dtFPTW6jATlWJdYeeDRGCyatf8R1hSjzSvdN8yWQPT9gzGCBRUwggURAgEBMDkw
# JTEjMCEGA1UEAwwaZmluYWxzdGFuZC1NUyBDb2RlIFNpZ25pbmcCEEaRwyHFCrqw
# SyW1eSgUBQAwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAA
# oQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4w
# DAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgFR/Kqwgkr8a0rPNVoGgcpwUq
# bonC3kIdm3McfPCvETowDQYJKoZIhvcNAQEBBQAEggEAR1B6IPl+DVRxHyRq9n2m
# hmmzsB9ve/xopTZQjkF8+vlKoUFrwzbR364u/5RznhClZ6pUBMEUDajP2s1V9bAx
# x57dHHFYbDKUIVMSsq/kLsY3NbI9tv0erHFuYGGVq2EhbVgOzU8aEUdmFUDPkR+5
# rvmgG8GDFNr3tf1YQ1zVXenXEPU+rRUfJJl6MUe6BCDpoSLWpbGbcJ4f9CupUk6Q
# QrGv6x3m6jL/cZOBmm4F4fVp9bY2RL4fcMvHNKDv/7B7zaMc8+VZtM754hOmYwL5
# zb3shRf1hDqRli/73hJeejakd3QPGoeRpgiIcP2rlXutRuRPv/ciPYflrUg77Jw2
# xKGCAyYwggMiBgkqhkiG9w0BCQYxggMTMIIDDwIBATB9MGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTECEAhP
# 3DNPfkVO28MPj/mSGDUwDQYJYIZIAWUDBAIBBQCgaTAYBgkqhkiG9w0BCQMxCwYJ
# KoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNjA5MDQyMzQ1MDdaMC8GCSqGSIb3
# DQEJBDEiBCBkWaHCY3AsqKZ+7qz40axE/TXQ+QE99tCinHjmR3HP2TANBgkqhkiG
# 9w0BAQEFAASCAgA8jzNA2Ti4nWtf0cveBx8JPEAi5wDAFSqSmX9EgbPt0dgZUw/1
# 6h6pdnb9bMQnES26FzgfM4AIPC2CbHQOac4rM+mnA8CjRzCMGXCtGB53a2PHUV9U
# tfPcuQBAyfeuVrgm4Scn+yYeN9Dip5FE2+XAdyKfs22hDjo1KLjbYt+N6WUP1LNo
# 63DHm8PpbrG5eP/mnAEMMFKw+eo2Q8fKDDj6UaUBdQeojoHqBNUTmFS2Q4in9Ugc
# qeV0WfC2A/SEWDlnX6ZyelO5F59lAHkSQlMj+iQ74Ib0c9OLmVNL9x1t94Mhot9t
# rhKiQ3UgrR9bDYnkEQnJw+GBSGgSjw7Y6OmLd/TG1wyAPcJsmZ2uJEvReeTHejA+
# Mj8FAObq+Rs6sqUH+FBhBXYW6xnkjdf/RtI5Y7TvGnHSNv4Y5QRvvIjRYg0qZ8eL
# vMKifiBhqXMiDBIP9UnMlQeFWlM2S2mqmAgt3oKseeXQXl6bs1Uqchd3nqEZg/EF
# mmV6LAHScnCyV2NrNzMyTyW8+SQ1AIwfBizuGxAKnKW9SFyiTFVKkOyddfpX7KmD
# PpbNCiKeeEBepAXVaeHgMm9bcRDHI82r3bfFsr2QRXEXmTQwuQ108SJU2OaWg00Y
# xOYAEdny3sUoY9C65JBrZIN34I4S4+upCx9J0aCp5LjoftqQymDXYNWhxA==
# SIG # End signature block
