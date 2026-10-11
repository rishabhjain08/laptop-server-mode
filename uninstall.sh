#!/usr/bin/env bash
# Removes Laptop Server Mode and restores your normal power plan.
# The ClaudeBox distro is kept unless you pass --remove-box (that deletes
# everything inside it).
set -euo pipefail

SYS32=/mnt/c/Windows/System32
PS="$SYS32/WindowsPowerShell/v1.0/powershell.exe"
DEST_WIN="$(cd /mnt/c && "$SYS32/cmd.exe" /c 'echo %LOCALAPPDATA%' | tr -d '\r')\\LaptopServerMode"

echo "==> Uninstalling (approve the Windows admin prompt)"
"$PS" -NoProfile -Command "\$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$DEST_WIN\\Uninstall.ps1\"'; exit \$p.ExitCode"
echo "==> Done."

if [ "${1:-}" = "--remove-box" ]; then
  echo "==> Deleting the ClaudeBox distro and everything in it"
  (cd /mnt/c && "$SYS32/wsl.exe" --unregister ClaudeBox)
fi
