#!/usr/bin/env bash
# Removes Laptop Server Mode and restores your normal power plan: ./uninstall.sh
# A wrapper for uninstall.ps1 (which also works from PowerShell, without WSL).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
cd /mnt/c
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$REPO/uninstall.ps1")" | tr -d '\r'
