# reMarkable Windows Print

Print from Windows 11 directly to a reMarkable 2. Press `Ctrl+P`, choose
`reMarkable`, done. No xochitl restart, no reload.

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
- Working folder: `C:\reMarkable`
- Windows printer: `reMarkable`

### Before installing

1. Connect the reMarkable to Windows by USB.
2. SSH into the reMarkable.
3. Verify the fixed USB IP is `10.11.99.1`.
4. Verify Windows can reach `10.11.99.1`.

## Install

Run `install.ps1` as Administrator. It creates the printer, installs the
watcher, and registers a logon task that keeps it running. Re-running it
updates everything in place.

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
- The reMarkable must be reachable at `10.11.99.1`.
- `print.prn` is actually a PDF.
- Do not restart xochitl.
- Do not modify OTG configuration.

## Files

- `install.ps1` — printer, watcher, logon task.
- `remarkable-print.ps1` — queues printed PDFs and uploads them.
- `uninstall.ps1` — removes the printer, task, and watcher.
- `CONTEXT.md` — implementation notes.

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

## License

MIT
