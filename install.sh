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

# ---- ClaudeBox: isolated distro for the Claude service --------------------
WSL="$SYS32/wsl.exe"
BOX=ClaudeBox
if ! "$WSL" -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$BOX"; then
  echo "==> Creating $BOX (Ubuntu 24.04, isolated; takes a few minutes)"
  (cd /mnt/c && "$WSL" --install Ubuntu-24.04 --name "$BOX" --location "$(win_env LOCALAPPDATA)\\$BOX" --no-launch --web-download)
fi
echo "==> Provisioning $BOX"
tar -C "$REPO/box" -cf - wsl.conf harden.sh managed-settings.json |
  (cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- bash -c 'mkdir -p /tmp/lsm && tar -C /tmp/lsm -xf -')
(cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- bash -s) < "$REPO/box/setup.sh"
(cd /mnt/c && "$WSL" --terminate "$BOX" >/dev/null)   # restart so wsl.conf applies
echo "==> Shared agent rules: /etc/claude-code/CLAUDE.md in $BOX and $DISTRO"
put_rules='install -d -m 0755 /etc/claude-code && cat > /etc/claude-code/AGENTS.md && chmod 0644 /etc/claude-code/AGENTS.md && ln -sfn AGENTS.md /etc/claude-code/CLAUDE.md'
sed "s/__MAIN_DISTRO__/$DISTRO/g" "$REPO/box/AGENTS.md" |
  (cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- bash -c "$put_rules")
if sudo -n true 2>/dev/null; then
  sed "s/__MAIN_DISTRO__/$DISTRO/g" "$REPO/box/AGENTS.md" | sudo -n bash -c "$put_rules"
else
  echo "    Skipped in $DISTRO (needs sudo). Run: sed 's/__MAIN_DISTRO__/$DISTRO/g' box/AGENTS.md | sudo bash -c '$put_rules'"
fi
echo "==> $BOX self-test"
(cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- bash -s) < "$REPO/box/selftest.sh" | tr -d '\r'

echo "==> Registering startup tasks for $WIN_USER (approve the Windows admin prompt)"
"$PS" -NoProfile -Command "\$p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$DEST_WIN\\Install-Tasks.ps1\" -User \"$WIN_USER\"'; exit \$p.ExitCode"

echo "==> Done. Look for the laptop icon next to the clock."
echo "    First time only: run 'wsl -d $BOX', then 'cd ~/work && claude' to sign in and trust the folder."
