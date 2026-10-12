#!/usr/bin/env bash
# Claude Remote add-on, from WSL. Install Laptop Server Mode first.
#   ./install.sh             ClaudeBox (on) + Claude in this distro (off until you turn it on)
#   ./install.sh --no-box    only Claude in this distro (on)
#   --windows                also Claude on Windows (on; see README)
# Without WSL, use install.ps1 instead (Claude on Windows only).
# Re-run to update; ClaudeBox, its files and your plugin settings are kept.
set -euo pipefail
WANT_BOX=1; MAIN_ON=0; WIN=0
for a in "$@"; do
  case "$a" in
    --no-box) WANT_BOX=0; MAIN_ON=1 ;;
    --windows) WIN=1 ;;
    *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WSL=/mnt/c/Windows/System32/wsl.exe
DISTRO="${WSL_DISTRO_NAME:?Run this inside WSL}"
BOX=ClaudeBox
box_root() { (cd /mnt/c && "$WSL" -d "$BOX" -u root --cd / -- "$@"); }
win_env() { (cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c "echo %$1%" | tr -d '\r'); }

if [ $WANT_BOX = 1 ]; then
if ! (cd /mnt/c && "$WSL" -l -q 2>/dev/null) | tr -d '\0\r' | grep -qx "$BOX"; then
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
fi

echo "==> Installing plugins"
plugins=("$HERE/plugins/claude-main")
[ $WANT_BOX = 1 ] && plugins+=("$HERE/plugins/claude")
[ $WIN = 1 ] && plugins+=("$HERE/plugins/claude-windows")
"$ROOT/plugin.sh" add "${plugins[@]}"
[ $MAIN_ON = 1 ] && "$ROOT/plugin.sh" enable claude-main
[ $WIN = 1 ] && "$ROOT/plugin.sh" enable claude-windows

echo "==> Done. First time only:"
[ $WANT_BOX = 1 ] && echo "    ClaudeBox: run 'wsl -d $BOX', then 'cd ~/work && claude' to sign in and trust the folder."
[ $MAIN_ON = 1 ] && echo "    This distro: set \"folder\" in %LOCALAPPDATA%\\LaptopServerMode\\plugins\\claude-main\\settings.json (e.g. {\"folder\": \"~/projects\"}) and run 'claude' there once."
[ $WIN = 1 ] && echo "    Windows: see the tray; if it says Needs setup, hover it for the next step."
echo "    Settings (mode, permissionMode, ...): see addons/claude-remote/README.md."
true
