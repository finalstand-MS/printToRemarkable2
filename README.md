# reMarkable Windows Print

Print from Windows 11 directly to a reMarkable 2. Press `Ctrl+P`, choose
`reMarkable`, done. No xochitl restart, no reload.

> **No warranty, no liability.** This is an unofficial, vibe-coded project that
> installs a printer, registers a task that runs at every logon, and transmits
> every document you print to it unencrypted over HTTP to `10.11.99.1`. Read
> [DISCLAIMER.md](DISCLAIMER.md) before installing. Using it means you accept
> it. Not affiliated with reMarkable AS or Microsoft.

## Install

### 1. On the reMarkable

One toggle. **No SSH required.**

`Menu` → `Settings` → `Storage` → **Enable USB web interface** → on

Connect the USB cable and open `http://10.11.99.1` in a browser to confirm it
works. That is the entire device-side setup.

### 2. On Windows 11

PowerShell **as Administrator**:

```powershell
cd <this folder>
.\install.ps1
```

### 3. Print

`Ctrl+P` → `reMarkable` → `Print`.

That is the whole setup. The installer creates the printer, installs the
watcher, and starts it at every logon. Everything below is detail,
troubleshooting, and manual alternatives.

### Signed scripts

The `.ps1` files are Authenticode-signed, so they run under an `AllSigned`
execution policy **on machines that trust the signing certificate**.

The certificate is self-signed. Your machine does not trust it, and you should
not be asked to install a stranger's root certificate. If your policy is
`RemoteSigned` (the Windows default for most setups) the scripts run as-is
after you unblock them:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

If your policy is `AllSigned`, either relax it for one session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

or sign the scripts with your own certificate. Check what applies to you with
`Get-ExecutionPolicy -List`.

Verify what you are about to run:

```powershell
Get-ChildItem *.ps1 | ForEach-Object { Get-AuthenticodeSignature $_ } |
    Select Path, Status, SignerCertificate
```

### Optional: SSH

SSH is **not** needed to install or use this. It is only useful for checking
things when something is wrong. The root password is on the device under
`Settings` → `Help` → `About` → `Copyrights and licenses`.

```sh
ssh root@10.11.99.1

ip addr show usb0        # should show 10.11.99.1
netstat -tlnp | grep :80 # web interface listening
```

---

## Prerequisites

- [ ] reMarkable 2
- [ ] USB cable connected to Windows
- [ ] USB web interface enabled on the reMarkable
- [ ] reMarkable reachable at `10.11.99.1`
- [ ] Microsoft Print to PDF installed on Windows
- [ ] PowerShell
- [ ] `curl.exe`

## Context

### reMarkable

- Device: reMarkable 2
- USB IP: `10.11.99.1`
- USB web interface: enabled in `Settings` → `Storage`
- SSH (optional, troubleshooting only): `ssh root@10.11.99.1`

### Windows

- USB network IP: `10.11.99.14`
- Working folder: `C:\reMarkable`
- Windows printer: `reMarkable`

### Before installing

1. Connect the reMarkable to Windows by USB.
2. Enable the USB web interface on the device.
3. Verify Windows can reach `10.11.99.1` in a browser.

`install.ps1` is idempotent: re-running it updates the printer, the watcher,
and the logon task in place.

## Start the watcher at logon

`install.ps1` already registers this. Run it manually only if you skipped the
installer or the task was removed.

Open PowerShell **as Administrator** and run:

```powershell
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\reMarkable\remarkable-print.ps1"'

$trigger = New-ScheduledTaskTrigger -AtLogOn

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit 0 `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask -TaskName "reMarkable Print Watcher" `
    -Action $action -Trigger $trigger -Settings $settings `
    -RunLevel Highest -Force

Start-ScheduledTask -TaskName "reMarkable Print Watcher"
```

Verify:

```powershell
Get-ScheduledTaskInfo "reMarkable Print Watcher" | Select LastRunTime, LastTaskResult
Get-Content C:\reMarkable\print.log -Tail 5
```

The log should end with `watcher started`.

### If `Register-ScheduledTask` returns "Access is denied"

The window is not elevated. `C:\Windows\system32` is the default prompt for
both elevated and normal PowerShell, so check:

```powershell
[bool](New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

If `False`, run `Start-Process powershell -Verb RunAs` and try again.

### Without administrator rights

Use a Startup shortcut instead of a scheduled task, then grant your account
write access to the working folder so the watcher can delete uploaded jobs:

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut(
     "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\reMarkable Print.lnk")
$s.TargetPath = "powershell.exe"
$s.Arguments  = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\reMarkable\remarkable-print.ps1"'
$s.Save()

# once, from an elevated window
icacls C:\reMarkable /grant "$env:USERNAME:(OI)(CI)M"
```

### Stop or remove the autostart

```powershell
Stop-ScheduledTask       -TaskName "reMarkable Print Watcher"
Unregister-ScheduledTask -TaskName "reMarkable Print Watcher" -Confirm:$false
```

## Print

1. Press `Ctrl+P`.
2. Select `reMarkable`.
3. Click `Print`.
4. The PDF appears on the reMarkable.

## How it works

`Ctrl+P`
→ `reMarkable`
→ Microsoft Print to PDF
→ `C:\reMarkable\print.prn`
→ `C:\reMarkable\queue\<document>.pdf`
→ `POST /upload` on `10.11.99.1`
→ reMarkable library

The document title is read from the Windows print queue while the job is still
spooling, so files land on the device with their real name instead of
`print.prn`. If the title cannot be read, a timestamp is used.

## Disconnection

Printing while the reMarkable is unplugged, asleep, or rebooting is safe.

- Jobs are captured into `C:\reMarkable\queue` before any upload is attempted,
  so a second print can never overwrite a pending one.
- Nothing is deleted until the device confirms the upload.
- The queue drains oldest-first as soon as the device is reachable again.
- Time spent unreachable does not count as a failed attempt. After 5 failures
  *while reachable*, a job moves to `C:\reMarkable\failed` instead of retrying
  forever.
- Everything is logged to `C:\reMarkable\print.log` (rotated at 512 KB).

## Restarts

| Restart | Result |
|---|---|
| reMarkable | Works. Queue uploads once the device is reachable again. |
| Windows | Works. The logon task restarts the watcher. |
| USB unplug / replug | Works. Queue drains on reconnect. |

## Behaviour notes

- The watcher waits for the spooler to release the file, so large documents are
  never uploaded half-written.
- Files that are not valid PDFs are moved to `failed` rather than uploaded.
- A mutex prevents two watchers from running and double-uploading.
- The logon task restarts the watcher up to 10 times if the process dies.

## Important

- USB connection is required.
- The USB web interface must stay enabled; it only serves while the device is
  connected and awake.
- The reMarkable must be reachable at `10.11.99.1`.
- `print.prn` is actually a PDF.
- Do not restart xochitl.
- Do not modify OTG configuration.

## Files

- `install.ps1` — printer, watcher, logon task.
- `remarkable-print.ps1` — queues printed PDFs and uploads them.
- `uninstall.ps1` — removes the printer, task, and watcher.
- `CONTEXT.md` — implementation notes.
- `DISCLAIMER.md` — usage policy, warranty and liability disclaimer.
- `.gitattributes` — keeps `.ps1` bytes verbatim so signatures survive cloning.

## Troubleshooting

Check the log first:

```powershell
Get-Content C:\reMarkable\print.log -Tail 20
```

Watcher running?

```powershell
Get-ScheduledTaskInfo "reMarkable Print Watcher" | Select LastRunTime, LastTaskResult
```

Device reachable?

```powershell
curl.exe -s -o NUL -w "%{http_code}`n" http://10.11.99.1/
```

Re-send a failed job by moving it from `C:\reMarkable\failed` back into
`C:\reMarkable\queue`.

## Licence

MIT — see [LICENSE](LICENSE) and [DISCLAIMER.md](DISCLAIMER.md).
