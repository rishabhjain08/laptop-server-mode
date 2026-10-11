#!/usr/bin/env bash
# Installs and removes plugins. Run from WSL.
#   ./plugin.sh list
#   ./plugin.sh add <folder>...     copy a plugin folder in (replaces an older copy)
#   ./plugin.sh remove <name>...    stop its service and delete it
# The watchdog picks changes up on its next round; no restart needed.
set -euo pipefail

SYS32=/mnt/c/Windows/System32
PS="$SYS32/WindowsPowerShell/v1.0/powershell.exe"
DEST_WIN="$(cd /mnt/c && "$SYS32/cmd.exe" /c 'echo %LOCALAPPDATA%' | tr -d '\r')\\LaptopServerMode"
DEST="$(wslpath -u "$DEST_WIN")"
PLUGINS="$DEST/plugins"
[ -f "$DEST/ServerMode.psm1" ] || { echo "Laptop Server Mode isn't installed. Run ./install.sh first." >&2; exit 1; }
usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Stops the plugin's service (if it has one) through the app's own runner.
stop_plugin() {
  "$PS" -NoProfile -ExecutionPolicy Bypass -Command "Import-Module '$DEST_WIN\\ServerMode.psm1'; Get-Services | Where-Object { (Split-Path \$_.dir -Leaf) -eq '$1' } | ForEach-Object { Invoke-ServiceVerb \$_ stop | Out-Null }" | tr -d '\r'
}

case "${1:-}" in
  list)
    for f in "$PLUGINS"/*/plugin.json; do
      [ -f "$f" ] && printf '%-20s %s\n' "$(basename "$(dirname "$f")")" "$(grep -o '"title": *"[^"]*"' "$f" | cut -d'"' -f4)"
    done
    ;;
  add)
    shift; [ $# -gt 0 ] || usage
    for src in "$@"; do
      [ -f "$src/plugin.json" ] || { echo "$src has no plugin.json" >&2; exit 1; }
      name=$(basename "$(cd "$src" && pwd)")
      mkdir -p "$PLUGINS"
      rm -rf "$PLUGINS/$name"
      cp -r "$src" "$PLUGINS/$name"
      echo "Added $name"
    done
    ;;
  remove)
    shift; [ $# -gt 0 ] || usage
    for name in "$@"; do
      [ -d "$PLUGINS/$name" ] || { echo "No plugin named $name" >&2; continue; }
      stop_plugin "$name"
      rm -rf "${PLUGINS:?}/$name"
      echo "Removed $name"
    done
    ;;
  *) usage ;;
esac
