#Requires -RunAsAdministrator
<#
    Installs the reMarkable printer, the watcher, and a logon task that keeps
    the watcher running. Safe to re-run: it updates in place.
#>

$ErrorActionPreference = 'Stop'

$Dir      = 'C:\reMarkable'
$Port     = "$Dir\print.prn"
$Printer  = 'reMarkable'
$Driver   = 'Microsoft Print To PDF'
$TaskName = 'reMarkable Print Watcher'
$Script   = "$Dir\remarkable-print.ps1"

# folders
New-Item -ItemType Directory -Force $Dir, "$Dir\queue", "$Dir\failed" | Out-Null

# watcher
Copy-Item "$PSScriptRoot\remarkable-print.ps1" $Script -Force

# driver check
if (-not (Get-PrinterDriver -Name $Driver -ErrorAction SilentlyContinue)) {
    throw "'$Driver' is not installed. Enable it under Windows Features > Microsoft Print to PDF."
}

# port
if (-not (Get-PrinterPort -Name $Port -ErrorAction SilentlyContinue)) {
    Add-PrinterPort -Name $Port
}

# printer
if (Get-Printer -Name $Printer -ErrorAction SilentlyContinue) {
    Set-Printer -Name $Printer -PortName $Port
} else {
    Add-Printer -Name $Printer -DriverName $Driver -PortName $Port
}

# logon task
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0 `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Settings $settings -RunLevel Highest -Force | Out-Null

Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

Write-Host "Installed."
Write-Host "  Printer : $Printer"
Write-Host "  Queue   : $Dir\queue"
Write-Host "  Log     : $Dir\print.log"
Write-Host "Print with Ctrl+P and choose '$Printer'."
