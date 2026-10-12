#!/usr/bin/env bash
# Installs Laptop Server Mode from WSL: ./install.sh
# A wrapper for install.ps1 (which also works from PowerShell, without WSL).
# The distro you run this in becomes the default distro for WSL plugins.
# Re-run it to update an existing install (your config, state and plugins are kept).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
[ -x "$PS" ] || { echo "Windows PowerShell not found. Is WSL interop enabled?" >&2; exit 1; }
cd /mnt/c   # PowerShell can't start in a WSL folder
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$REPO/install.ps1")" -WslDistro "${WSL_DISTRO_NAME:-}" | tr -d '\r'
