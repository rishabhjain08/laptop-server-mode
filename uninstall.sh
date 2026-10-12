#!/usr/bin/env bash
# Removes Laptop Server Mode and restores your normal power plan: ./uninstall.sh
# A wrapper for uninstall.ps1 (which also works from PowerShell, without WSL).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/src/stage.sh"
cp "$REPO/uninstall.ps1" "$STAGE/"
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$STAGE_WIN\\uninstall.ps1" | tr -d '\r'
