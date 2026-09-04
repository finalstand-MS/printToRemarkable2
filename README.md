# reMarkable Windows Print

Print from Windows 11 directly to a reMarkable 2. Use it by pressing `Ctrl+P`.

If it does not work, copy-paste this folder into an LLM and it will probably figure it out.

Vibe coded. Improvement over other approaches: no reload / xochitl restart needed.

## Requirements

- Windows 11
- reMarkable 2
- USB cable connected
- SSH access to the reMarkable
- Microsoft Print to PDF

## Setup

- Connect the reMarkable by USB.
- SSH into the reMarkable.
- Verify its USB IP is `10.11.99.1`.
- Run `install.ps1` as Administrator.
- Start `remarkable-print.ps1`.

## Print

- Open any document.
- Press `Ctrl+P`.
- Select **reMarkable**.
- Click **Print**.
- PDF is sent to the reMarkable.
- No xochitl restart or reload.

## Fixed IP

The reMarkable USB network address is:

`10.11.99.1`

The Windows USB network address is:

`10.11.99.14`

## Files

- `install.ps1` — installs the Windows printer.
- `remarkable-print.ps1` — watches for printed PDFs and uploads them.
- `uninstall.ps1` — removes the printer.
- `CONTEXT.md` — setup and troubleshooting notes.
