#!/usr/bin/env bash
# Removes the Claude Remote plugins (from WSL). ClaudeBox is kept unless you pass
# --remove-box (that deletes everything inside it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/plugin.sh" remove claude claude-main claude-windows 2>&1 | grep -v "No plugin named" || true
if [ "${1:-}" = "--remove-box" ]; then
  echo "==> Deleting the ClaudeBox distro and everything in it"
  (cd /mnt/c && /mnt/c/Windows/System32/wsl.exe --unregister ClaudeBox)
fi
