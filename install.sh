#!/usr/bin/env bash
# Installs Laptop Server Mode from WSL: ./install.sh
# A wrapper for install.ps1 (which also works from PowerShell, without WSL).
# The distro you run this in becomes the default distro for WSL plugins.
# Re-run it to update an existing install (your config, state and plugins are kept).
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/src/stage.sh"
cp -r "$REPO/install.ps1" "$REPO/src" "$STAGE/"
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$STAGE_WIN\\install.ps1" -WslDistro "${WSL_DISTRO_NAME:-}" | tr -d '\r'
