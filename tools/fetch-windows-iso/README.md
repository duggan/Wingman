# fetch-windows-iso

Fetches the **latest Windows 11 (or 10) ISO** from Microsoft — `--win 10` for
Windows 10 — and optionally runs Wingman's compatibility check on it, automating
the "a new release is out, does Wingman still handle it?" loop.

Personal/maintainer convenience: it downloads *your own* copy from Microsoft. It
is **not** part of the shipped app and never hosts or redistributes an ISO.

## How it works (and why it's robust)

There is no stable official API for downloading the consumer Windows 11 ISO — the
flow sits behind session/anti-bot gating that Microsoft reshapes a few times a
year. Rather than maintain our own scraper, this script **delegates to
[Fido](https://github.com/pbatard/Fido)** (the download-URL helper the Rufus
author keeps current). It pulls the *latest* `Fido.ps1` at runtime, asks it for
the URL, hands that to `curl`, and chains into `make check-iso`. When Microsoft
breaks the flow, the upstream fix is picked up automatically — we own no selectors.

## Setup (once)

```sh
brew install powershell   # Fido is a PowerShell script; pwsh runs it on macOS
```

## Use

```sh
./fetch-iso.sh                                  # latest "English International" ISO into the CWD
./fetch-iso.sh --language "English" --out ~/Downloads
./fetch-iso.sh --check                          # download, then run `make check-iso`
```

Or from the repo root: `make fetch-iso` (downloads the latest ISO and checks it).
