#!/usr/bin/env bash
# Installs and removes plugins from WSL. A wrapper for plugin.ps1.
#   ./plugin.sh list
#   ./plugin.sh add <folder>...     copy a plugin folder in (replaces an older copy, keeps your settings.json)
#   ./plugin.sh remove <name>...    stop its service and delete it
# The watchdog picks changes up on its next round; no restart needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
cmd="${1:-}"; [ $# -gt 0 ] && shift
args=()
for a in "$@"; do
  # Folders become Windows paths; plugin names pass through.
  if [ "$cmd" = add ]; then args+=("$(wslpath -w "$(cd "$a" && pwd)")"); else args+=("$a"); fi
done
cd /mnt/c
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$REPO/plugin.ps1")" "$cmd" "${args[@]}" | tr -d '\r'
