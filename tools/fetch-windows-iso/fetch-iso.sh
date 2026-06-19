#!/usr/bin/env bash
# Fetch a Windows 10 or 11 ISO using Fido (the maintained download-URL helper
# from the Rufus author), then optionally run Wingman's compatibility check.
#
# Robust-by-delegation: we pull the LATEST Fido.ps1 at runtime, so when Microsoft
# reshapes its download flow the upstream fix is picked up automatically — we
# maintain no selectors of our own. Downloads YOUR copy from Microsoft; it never
# hosts or redistributes an ISO, and is not part of the shipped app.
#
# Needs: PowerShell (`brew install powershell`) and curl.
#   ./fetch-iso.sh [--win 11|10] [--language "English International"] [--out DIR] [--check]

set -euo pipefail

WIN="11"
LANGUAGE="English International"
OUT_DIR="$PWD"
DO_CHECK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --win)      WIN="$2";      shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --out)      OUT_DIR="$2";  shift 2 ;;
    --check)    DO_CHECK=1;    shift ;;
    -h|--help)  echo "usage: fetch-iso.sh [--win 11|10] [--language NAME] [--out DIR] [--check]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$WIN" in 10|11) ;; *) echo "--win must be 10 or 11 (got: $WIN)" >&2; exit 2 ;; esac

command -v pwsh >/dev/null 2>&1 || { echo "PowerShell is required:  brew install powershell" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FIDO="$TMP/Fido.ps1"
echo "Fetching the latest Fido.ps1…"
curl -fsSL -o "$FIDO" "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"

echo "Resolving the latest Windows $WIN download URL (language: $LANGUAGE)…"
# -PlatformArch x64 skips Fido's WMI arch-probe, which doesn't exist on macOS.
URL="$(pwsh -NoProfile -File "$FIDO" \
        -Win "$WIN" -Rel Latest -Lang "$LANGUAGE" -Arch x64 -PlatformArch x64 -GetUrl 2>/dev/null \
      | grep -Eo 'https://[^[:space:]]+' | tail -1)"
[ -n "$URL" ] || { echo "Fido returned no URL — Microsoft may have changed its flow (check for a newer Fido)." >&2; exit 1; }

FILE="$(basename "${URL%%\?*}")"
OUT="$OUT_DIR/$FILE"
echo "Downloading $FILE…"
curl -fL --retry 3 -C - --progress-bar -o "$OUT" "$URL"
echo "SHA-256: $(shasum -a 256 "$OUT" | awk '{print $1}')"

if [ "$DO_CHECK" = 1 ]; then
  echo; echo "Running Wingman compatibility check…"; echo
  make -C "$REPO_ROOT" check-iso ISO="$OUT"
fi
echo "Done: $OUT"
