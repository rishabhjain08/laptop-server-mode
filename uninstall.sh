#!/usr/bin/env bash
# Removes Laptop Server Mode and restores your normal power plan.
# Services that are running (e.g. the claude-server tmux session) are left alone.
set -euo pipefail

SYS32=/mnt/c/Windows/System32
PS="$SYS32/WindowsPowerShell/v1.0/powershell.exe"
DEST_WIN="$(cd /mnt/c && "$SYS32/cmd.exe" /c 'echo %LOCALAPPDATA%' | tr -d '\r')\\LaptopServerMode"

echo "==> Uninstalling (approve the Windows admin prompt)"
"$PS" -NoProfile -Command "\$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$DEST_WIN\\Uninstall.ps1\"'; exit \$p.ExitCode"
echo "==> Done."
