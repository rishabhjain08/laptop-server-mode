# This PC: two WSL distros

Installed by laptop-server-mode as /etc/claude-code/CLAUDE.md in both distros.
Check which one you are in with `echo $WSL_DISTRO_NAME`.

- **__MAIN_DISTRO__**: the user's own environment. Projects in ~/projects, the
  user's GitHub login (gh, SSH keys), Windows access.
- **ClaudeBox**: isolated, unattended Claude Code driven over Remote Control
  (tmux session `claude-server`, user `claude`, repos in ~/work). No Windows
  files, no LAN, no gh login. GitHub access is one deploy key per repo.

The same repo can be cloned in both. They share nothing except GitHub, so
fetch before you start, and never assume the other side's clone is current.

## Git rules

In **ClaudeBox**:
- Start every task from fresh main: `git checkout main && git pull`.
- Work on a new branch `claude/<short-task>`. Never commit or push to main.
- When done, push the branch and reply with
  `https://github.com/<owner>/<repo>/compare/main...claude/<short-task>?expand=1`.

In **__MAIN_DISTRO__**:
- `git fetch` before working, so ClaudeBox's `claude/*` branches are visible.
- Don't commit to a `claude/*` branch unless the user asks; ClaudeBox may
  still be pushing to it.
- Merge `claude/*` branches into main only when the user asks.

## Admin (from __MAIN_DISTRO__, repo ~/projects/laptop-server-mode)

- Give ClaudeBox a repo: `addons/claude-remote/add-repo.sh owner/repo [--read-only]`.
- Watch it: `wsl.exe -d ClaudeBox -- tmux attach -t claude-server`.
- Stop it: tray flyout > Stop all services now, or `wsl.exe --terminate ClaudeBox`.
