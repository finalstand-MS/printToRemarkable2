# reMarkable Windows Print

Print from Windows 11 directly to a reMarkable 2.

## Prerequisites

- [ ] reMarkable 2
- [ ] USB cable connected to Windows
- [ ] Fixed USB IP address for the reMarkable: `10.11.99.1`
- [ ] SSH access to the reMarkable as `root`
- [ ] Microsoft Print to PDF installed on Windows
- [ ] PowerShell
- [ ] `curl.exe`

## Context

### reMarkable

- Device: reMarkable 2
- USB IP: `10.11.99.1`
- SSH: `ssh root@10.11.99.1`

### Windows

- USB network IP: `10.11.99.14`
- Temporary print file: `C:\reMarkable\print.prn`
- Windows printer: `reMarkable`

### Before installing

1. Connect the reMarkable to Windows by USB.
2. SSH into the reMarkable.
3. Verify the fixed USB IP is `10.11.99.1`.
4. Verify Windows can reach `10.11.99.1`.

## Install

1. Run `install.ps1` as Administrator.
2. Start `remarkable-print.ps1`.

## Print

1. Press `Ctrl+P`.
2. Select `reMarkable`.
3. Click `Print`.
4. The PDF appears on the reMarkable.

No xochitl restart or reload is required.

## How it works

`Ctrl+P`
→ `reMarkable`
→ Microsoft Print to PDF
→ `C:\reMarkable\print.prn`
→ `/upload`
→ reMarkable library

## Important

- USB connection is required.
- The reMarkable must be reachable at `10.11.99.1`.
- `print.prn` is actually a PDF.
- Do not restart xochitl.
- Do not modify OTG configuration.

## Files

- `install.ps1` — installs the Windows printer.
- `remarkable-print.ps1` — watches for printed PDFs and uploads them.
- `uninstall.ps1` — removes the printer.
- `CONTEXT.md` — implementation notes.
