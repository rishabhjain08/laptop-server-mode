#!/usr/bin/env bash
# Gives ClaudeBox access to ONE GitHub repo with a deploy key, then clones it
# into ~/work inside the box. The private key is created inside the box and
# never leaves it; only the public key is registered (with your gh login).
# Usage (from your main WSL distro):  box/add-repo.sh owner/repo [--read-only]
# Revoke any time: GitHub > repo > Settings > Deploy keys > "ClaudeBox".
set -euo pipefail
REPO="${1:?usage: $0 owner/repo [--read-only]}"
RO="${2:-}"
NAME="${REPO#*/}"
ALIAS="gh-${REPO//\//-}"
WSL=/mnt/c/Windows/System32/wsl.exe
box() { (cd /mnt/c && "$WSL" -d ClaudeBox -u claude --cd / -- bash -s); }

echo "==> Key for $REPO (created inside ClaudeBox)"
PUB=$(box <<BOX
set -e
k=\$HOME/.ssh/$ALIAS
[ -f "\$k" ] || ssh-keygen -q -t ed25519 -N '' -C "claudebox:$REPO" -f "\$k"
grep -q "^Host $ALIAS\$" ~/.ssh/config 2>/dev/null ||
  printf 'Host %s\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/%s\n  IdentitiesOnly yes\n\n' "$ALIAS" "$ALIAS" >> ~/.ssh/config
chmod 600 ~/.ssh/config
cat "\$k.pub"
BOX
)

echo "==> GitHub host keys (from api.github.com, not trust-on-first-use)"
gh api meta --jq '.ssh_keys[] | "github.com " + .' |
  (cd /mnt/c && "$WSL" -d ClaudeBox -u claude --cd / -- bash -c 'cat > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts')

if gh repo deploy-key list -R "$REPO" --json title --jq '.[].title' | grep -qx ClaudeBox; then
  echo "==> Deploy key already registered on $REPO"
else
  echo "==> Registering deploy key on $REPO ($([ -n "$RO" ] && echo read-only || echo read-write))"
  KEYFILE=$(mktemp); echo "$PUB" > "$KEYFILE"
  if [ -n "$RO" ]; then gh repo deploy-key add "$KEYFILE" -R "$REPO" -t ClaudeBox
  else gh repo deploy-key add "$KEYFILE" -R "$REPO" -t ClaudeBox --allow-write; fi
  rm -f "$KEYFILE"
fi

# No branch ruleset: GitHub attributes deploy-key pushes to the repo owner,
# so a "block main" rule can't tell ClaudeBox from you. The "never push to
# main" rule lives in /etc/claude-code/CLAUDE.md (box/AGENTS.md) instead.

echo "==> Cloning into ClaudeBox:~/work/$NAME"
box <<BOX
set -e
git config --global user.name >/dev/null || git config --global user.name "$(git config --global user.name)"
git config --global user.email >/dev/null || git config --global user.email "$(git config --global user.email)"
[ -d ~/work/$NAME/.git ] || git clone -q "$ALIAS:$REPO.git" ~/work/$NAME
git -C ~/work/$NAME remote -v | head -1
BOX
