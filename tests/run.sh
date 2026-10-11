#!/usr/bin/env bash
# Runs the automated tests on Windows from WSL. They use a temporary copy of
# src/ and never touch your installed copy, power settings or services.
#   tests/run.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
TMP_WIN="$(cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c 'echo %TEMP%' | tr -d '\r')\\lsm-test-src"
TMP="$(wslpath -u "$TMP_WIN")"
rm -rf "$TMP"; mkdir -p "$TMP"; cp "$REPO"/src/* "$TMP"/; cp "$REPO"/tests/*.ps1 "$TMP"/
status=0
for t in "$TMP"/*.Tests.ps1; do
  echo "== $(basename "$t")"
  "$PS" -NoProfile -ExecutionPolicy Bypass -File "$TMP_WIN\\$(basename "$t")" -Src "$TMP_WIN" | tr -d '\r' || status=1
done
rm -rf "$TMP"
exit $status
