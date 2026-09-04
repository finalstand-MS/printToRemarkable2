#Requires -RunAsAdministrator

$dir="C:\reMarkable"

New-Item -ItemType Directory -Force $dir | Out-Null

Add-PrinterPort -Name "$dir\print.prn" -ErrorAction SilentlyContinue

if(-not (Get-Printer -Name "reMarkable" -ErrorAction SilentlyContinue)){
    Add-Printer `
        -Name "reMarkable" `
        -DriverName "Microsoft Print To PDF" `
        -PortName "$dir\print.prn"
}else{
    Set-Printer `
        -Name "reMarkable" `
        -PortName "$dir\print.prn"
}

Copy-Item `
    "$PSScriptRoot\remarkable-print.ps1" `
    "$dir\remarkable-print.ps1" `
    -Force

Write-Host "reMarkable printer installed."
