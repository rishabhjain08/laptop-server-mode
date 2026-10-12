#!/usr/bin/env bash
# Installs and removes plugins from WSL. A wrapper for plugin.ps1.
#   ./plugin.sh list
#   ./plugin.sh add <folder>...     copy a plugin folder in (replaces an older copy, keeps your settings.json)
#   ./plugin.sh remove <name>...    stop its service and delete it
#   ./plugin.sh enable|disable <name>...  turn a service on or off (like its tray switch)
# The watchdog picks changes up on its next round; no restart needed.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"; [ $# -gt 0 ] && shift
args=()
for a in "$@"; do
  # Plugin folders are copied to the Windows side first; names pass through.
  if [ "$cmd" = add ]; then args+=("$(cd "$a" && pwd)"); else args+=("$a"); fi
done
. "$REPO/src/stage.sh"
cp "$REPO/plugin.ps1" "$STAGE/"
if [ "$cmd" = add ]; then
  win=()
  for d in "${args[@]}"; do
    n=$(basename "$d"); mkdir -p "$STAGE/plugins"; cp -r "$d" "$STAGE/plugins/$n"
    win+=("$STAGE_WIN\\plugins\\$n")
  done
  args=("${win[@]}")
fi
"$PS" -NoProfile -ExecutionPolicy Bypass -File "$STAGE_WIN\\plugin.ps1" "$cmd" "${args[@]}" | tr -d '\r'
