#!/usr/bin/env bash
# Gate: must be green before anything is merged into main .
#   ./scripts/gate.sh            Go checks, PowerShell parse, Pester
# On Windows (Git Bash) every Pester test must pass. Elsewhere the full suite
# runs too, and the failures must be the known Windows-only ones listed in
# tests/linux-known-failures.txt (registry, powershell.exe, Appx, junctions).
set -euo pipefail
cd "$(dirname "$0")/.."

export SWEEPR_NO_OPLOG=1

echo "== gofmt =="
unformatted="$(gofmt -l cmd)"
if [ -n "$unformatted" ]; then
    echo "Not gofmt-formatted:"; echo "$unformatted"; exit 1
fi

echo "== go vet (host + windows) =="
go vet ./cmd/...
GOOS=windows go vet ./cmd/...

echo "== go test =="
go test ./cmd/...

echo "== go build (windows) =="
GOOS=windows go build -o /dev/null ./cmd/analyze
GOOS=windows go build -o /dev/null ./cmd/status
GOOS=windows go build -o /dev/null ./cmd/sw

PWSH="${PWSH:-pwsh}"
if ! command -v "$PWSH" >/dev/null 2>&1; then
    echo "pwsh not found: install PowerShell 7 (and Pester 5+) or set PWSH." >&2
    exit 1
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) SCOPE="all" ;;
    *) SCOPE="portable" ;;
esac

echo "== PowerShell parse + Pester ($SCOPE) =="
"$PWSH" -NoProfile -NonInteractive -File scripts/gate-pester.ps1 -Scope "$SCOPE"

echo "Gate green."
