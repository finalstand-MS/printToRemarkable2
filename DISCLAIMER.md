# Disclaimer and Usage Policy

**Read this before installing. Installing or running anything in this
repository means you accept everything below.**

## No warranty

This software is provided "as is", without warranty of any kind, express or
implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose, title, and non-infringement.

There is no guarantee that it works, that it keeps working, that it is fit for
any purpose, or that it is free of defects.

## No liability

To the maximum extent permitted by applicable law, the author is not liable for
any claim, damage, loss, or other liability, whether in an action of contract,
tort (including negligence), or otherwise, arising from, out of, or in
connection with this software or its use, including but not limited to:

- loss, corruption, or disclosure of documents, files, or data
- damage to, malfunction of, or bricking of a reMarkable device or any computer
- voided warranties or terminated support from the device manufacturer
- changes to Windows configuration, printers, printer ports, drivers,
  scheduled tasks, file system permissions, or execution policy
- documents uploaded to the wrong device, the wrong account, or not at all
- confidential material leaving your control
- downtime, lost work, lost time, or lost revenue

This applies even if the author has been advised of the possibility of such
damage.

## What this software actually does to your system

Be aware that installing it will:

- create the directory `C:\reMarkable` and write files into it
- install a Windows printer named `reMarkable` and a printer port that writes
  to a file on disk
- register a scheduled task that runs at every logon with highest privileges
- run a background process that continuously watches a folder
- read every document you print to that printer and transmit it over USB to a
  device at `10.11.99.1`
- delete local copies of those documents after upload

Printed documents are transmitted **unencrypted over plain HTTP** to the
reMarkable's USB web interface. Do not use this for material where that is
unacceptable.

## Not affiliated

This is an unofficial, independent project. It is not affiliated with,
endorsed by, sponsored by, or supported by reMarkable AS or Microsoft. All
trademarks belong to their respective owners.

Using it may violate the terms of service or warranty conditions of your
device. That is your decision and your risk.

## Your responsibility

You are solely responsible for:

- deciding whether this software is appropriate for your situation
- reviewing the source code before running it
- any data you send through it
- backing up anything you care about
- complying with all laws, regulations, employer policies, and third-party
  terms that apply to you

If you do not accept all of this, do not install or use this software.

## Origin

This project was written quickly and with heavy AI assistance ("vibe coded").
It has not been formally reviewed, audited, or tested beyond one person's
machine. Treat it accordingly. Heck, to be honest only this single line of thoughts was not hallucinated.

## Licence

Distributed under the MIT Licence. See `LICENSE`. Where this document and the
MIT Licence overlap, both apply; nothing here grants rights beyond that
licence.
