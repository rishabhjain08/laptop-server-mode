#!/usr/bin/env bash
# Claude Remote add-on: creates the isolated ClaudeBox distro and installs
# the "claude" (ClaudeBox) and "claude-main" (your distro, off by default)
# plugins. Install Laptop Server Mode first (../../install.sh).
# Re-run to update; ClaudeBox and its files are kept.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WSL=/mnt/c/Windows/System32/wsl.exe
DISTRO="${WSL_DISTRO_NAME:?Run this inside WSL}"
BOX=ClaudeBox
box_root() { (cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- "$@"); }
win_env() { (cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c "echo %$1%" | tr -d '\r'); }

if ! "$WSL" -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$BOX"; then
  echo "==> Creating $BOX (Ubuntu 24.04, isolated; takes a few minutes)"
  (cd /mnt/c && "$WSL" --install Ubuntu-24.04 --name "$BOX" --location "$(win_env LOCALAPPDATA)\\$BOX" --no-launch --web-download)
fi
echo "==> Provisioning $BOX"
tar -C "$HERE" -cf - wsl.conf harden.sh managed-settings.json | box_root bash -c 'mkdir -p /tmp/lsm && tar -C /tmp/lsm -xf -'
box_root bash -s < "$HERE/setup.sh"
(cd /mnt/c && "$WSL" --terminate "$BOX" >/dev/null)   # restart so wsl.conf applies

echo "==> Shared agent rules: /etc/claude-code/CLAUDE.md in $BOX and $DISTRO"
put_rules='install -d -m 0755 /etc/claude-code && cat > /etc/claude-code/AGENTS.md && chmod 0644 /etc/claude-code/AGENTS.md && ln -sfn AGENTS.md /etc/claude-code/CLAUDE.md'
sed "s/__MAIN_DISTRO__/$DISTRO/g" "$HERE/AGENTS.md" | box_root bash -c "$put_rules"
if sudo -n true 2>/dev/null; then
  sed "s/__MAIN_DISTRO__/$DISTRO/g" "$HERE/AGENTS.md" | sudo -n bash -c "$put_rules"
else
  echo "    Skipped in $DISTRO (needs sudo). Run: sed 's/__MAIN_DISTRO__/$DISTRO/g' $HERE/AGENTS.md | sudo bash -c '$put_rules'"
fi

echo "==> $BOX self-test"
box_root bash -s < "$HERE/selftest.sh" | tr -d '\r'

echo "==> Installing plugins"
"$ROOT/plugin.sh" add "$HERE/plugins/claude" "$HERE/plugins/claude-main"

echo "==> Done. First time only: run 'wsl -d $BOX', then 'cd ~/work && claude' to sign in and trust the folder."
