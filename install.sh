#!/usr/bin/env bash
# Installs Laptop Server Mode. Run from WSL inside this repo: ./install.sh
# Re-run it to update an existing install (your config and state are kept).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
SYS32=/mnt/c/Windows/System32
PS="$SYS32/WindowsPowerShell/v1.0/powershell.exe"
[ -x "$PS" ] || { echo "Windows PowerShell not found. Is WSL interop enabled?" >&2; exit 1; }
DISTRO="${WSL_DISTRO_NAME:?Run this inside WSL}"

win_env() { (cd /mnt/c && "$SYS32/cmd.exe" /c "echo %$1%" | tr -d '\r'); }
DEST_WIN="$(win_env LOCALAPPDATA)\\LaptopServerMode"
WIN_USER="$(win_env USERDOMAIN)\\$(win_env USERNAME)"
DEST="$(wslpath -u "$DEST_WIN")"

echo "==> Copying files to $DEST_WIN"
mkdir -p "$DEST/logs"
cp "$REPO"/src/* "$DEST/"
rm -rf "$DEST/services"
cp -r "$REPO/services" "$DEST/services"

if [ ! -f "$DEST/config.json" ]; then
  cat > "$DEST/config.json" <<JSON
{
  "batteryLimit": 35,
  "pollSeconds": 15,
  "wslDistro": "$DISTRO",
  "wslRoot": "$DEST"
}
JSON
  echo "==> Created config.json (battery limit 35%, distro $DISTRO)"
fi

echo "==> Registering startup tasks for $WIN_USER (approve the Windows admin prompt)"
"$PS" -NoProfile -Command "\$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$DEST_WIN\\Install-Tasks.ps1\" -User \"$WIN_USER\"'; exit \$p.ExitCode"

echo "==> Done. Look for the dot in the taskbar tray (click ^ if hidden)."
