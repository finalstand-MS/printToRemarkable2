#Requires -RunAsAdministrator
<#
    Removes the printer, the watcher, and the logon task.
    Queued and failed jobs are left on disk.
#>

$Dir      = 'C:\reMarkable'
$Printer  = 'reMarkable'
$TaskName = 'reMarkable Print Watcher'

Stop-ScheduledTask       -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*remarkable-print.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Printer     -Name $Printer      -ErrorAction SilentlyContinue
Remove-PrinterPort -Name "$Dir\print.prn" -ErrorAction SilentlyContinue
Remove-Item "$Dir\remarkable-print.ps1" -Force -ErrorAction SilentlyContinue

Write-Host "Removed. Anything still in $Dir\queue and $Dir\failed was left in place."
