#!/bin/bash
# Provisions ClaudeBox. Run as root inside the distro (install.sh pipes it in).
# Expects /tmp/lsm/{wsl.conf,harden.sh,managed-settings.json} to exist.
set -euo pipefail
BOX_UID=2501

id claude >/dev/null 2>&1 || useradd -m -u $BOX_UID -s /bin/bash claude
passwd -l claude >/dev/null; passwd -l root >/dev/null
gpasswd -d claude sudo >/dev/null 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends nftables tmux git gh curl ca-certificates openssh-client procps >/dev/null

install -m 0644 /tmp/lsm/wsl.conf /etc/wsl.conf
install -m 0755 /tmp/lsm/harden.sh /usr/local/sbin/claudebox-harden
install -d -m 0755 /etc/claude-code
install -m 0644 /tmp/lsm/managed-settings.json /etc/claude-code/managed-settings.json

# Claude Code for the box user (official installer, user-local).
if ! runuser -l claude -c 'command -v claude' >/dev/null 2>&1 && [ ! -x /home/claude/.local/bin/claude ]; then
  runuser -l claude -c 'curl -fsSL https://claude.ai/install.sh | bash' >/dev/null
fi
runuser -l claude -c 'mkdir -p ~/work ~/.ssh && chmod 700 ~/.ssh'
grep -q '.local/bin' /home/claude/.profile || echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/claude/.profile
echo "setup ok: $(runuser -l claude -c 'claude --version' 2>/dev/null)"
