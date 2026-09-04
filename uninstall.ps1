#Requires -RunAsAdministrator

Remove-Printer -Name "reMarkable" -ErrorAction SilentlyContinue
Remove-PrinterPort -Name "C:\reMarkable\print.prn" -ErrorAction SilentlyContinue
Remove-Item "C:\reMarkable\remarkable-print.ps1" -Force -ErrorAction SilentlyContinue

Write-Host "reMarkable printer removed."
