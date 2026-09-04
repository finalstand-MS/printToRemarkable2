# Context

## reMarkable

- Device: reMarkable 2
- xochitl: 3.28.0.169
- SSH: Dropbear
- USB IP: `10.11.99.1`

## Windows

- USB network IP: `10.11.99.14`
- Working folder: `C:\reMarkable`
- Spool file: `C:\reMarkable\print.prn`
- Queue: `C:\reMarkable\queue`
- Failed: `C:\reMarkable\failed`
- Log: `C:\reMarkable\print.log`
- Printer: `reMarkable` on the `Microsoft Print To PDF` driver
- Task: `reMarkable Print Watcher`, at logon, highest privileges

## Upload API

The reMarkable USB web interface accepts PDFs at:

`POST http://10.11.99.1/upload`

multipart field: `file`

The multipart filename becomes the document title in the library. Uploads
appear immediately without restarting xochitl.

## Why the printer port is a file

The printer uses `C:\reMarkable\print.prn` as its port, so Microsoft Print to
PDF writes the rendered PDF straight to that path with no save dialog. The
`.prn` extension is cosmetic; the contents are a normal PDF, verified by the
`%PDF-` header before upload.

## Reachability probe

A TCP connect to `10.11.99.1:80` with a 700 ms timeout, not ICMP. The device
answers ping before the web interface is serving, so ping produces false
positives right after a reboot.

## Document titles

`Get-PrintJob -PrinterName reMarkable` exposes `DocumentName` only while the
job is spooling. The watcher polls it every 500 ms and uses the last value seen
when `print.prn` appears. Invalid characters are stripped and a source
extension such as `.docx` is removed so titles do not read `report.docx.pdf`.

## Failure handling

- Retry counters are keyed by queued file name and only increment when the
  device is confirmed reachable at the moment of failure.
- A mid-upload disconnect is not counted as a failure.
- 5 reachable failures move the job to `failed`.
- `curl --fail` makes any non-2xx response a non-zero exit, and `--max-time
  120` prevents a hung upload from blocking the loop.

## Do not

- restart xochitl
- use `printer.arm -restart`
- modify OTG configuration
- replace the working `/upload` method
- reintroduce the TCP/9100 relay
