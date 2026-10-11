# Claude Remote add-on

Runs [Claude Code](https://claude.com/claude-code) with Remote Control on the
laptop around the clock, so you can drive it from your phone or another
computer. Two plugins:

| Plugin | Runs | Default |
| --- | --- | --- |
| `claude` | Claude in **ClaudeBox**, an isolated WSL distro | on |
| `claude-main` | Claude in your main distro, with your full access | off |

## Install

Install Laptop Server Mode first, then from the repo root:

```bash
addons/claude-remote/install.sh
```

It creates and hardens ClaudeBox, installs the shared agent rules, runs the
isolation self-test and adds both plugins. Re-run it to update. Remove the
plugins with `addons/claude-remote/uninstall.sh` (add `--remove-box` to delete
ClaudeBox too).

## Claude in ClaudeBox

Claude Code runs unattended with Remote Control and **permission prompts
skipped** (`--dangerously-skip-permissions`), inside a separate, locked-down
WSL distro called **ClaudeBox**, which acts as the sandbox. This folder's `install.sh` creates it.
After a restart it resumes the last conversation (`--continue`), or starts a
fresh one if there is none.

Why a separate distro: an unattended agent reads web pages and packages nobody
is watching, and a prompt injection could make it misbehave. ClaudeBox makes
the worst case "one revocable deploy key", not "your whole machine".

| Inside ClaudeBox, Claude can't... | How |
| --- | --- |
| Run Windows programs or read Windows files | No drive mounts, no Windows PATH, WSL interop sockets root-only (`/run/WSL` 0700) |
| Read your main distro, SSH keys or `gh` login | Separate distro filesystem; runs as unprivileged `claude` (UID 2501), no sudo, root locked |
| Use the mic, speakers or screen | WSLg bridge unmounted at boot |
| Reach your home network, VPN peers or laptop services | nftables rules for UID 2501: private/LAN/CGNAT ranges and sensitive local ports rejected; internet allowed |
| Hog the laptop | cgroup caps: 6 GB RAM (5 GB soft), 4 CPU cores, 2000 processes |

`harden.sh` runs at every box boot **and** before every Claude start; the
service refuses to start if any check fails. Verify any time:

```bash
wsl.exe -d ClaudeBox -u root -- bash -s < addons/claude-remote/selftest.sh
```

Note: WSL distros share one kernel, so don't set `[interop] enabled=false` in
ClaudeBox; it would turn interop off for **every** distro. The permission
approach above blocks only the box user.

**First-time setup:** `wsl -d ClaudeBox`, then `cd ~/work && claude` to sign in
and trust the folder. Until then the tray shows the service as *needs sign-in*.

**GitHub access, one repo at a time:**

```bash
addons/claude-remote/add-repo.sh owner/repo              # read-write deploy key, cloned to ~/work/repo
addons/claude-remote/add-repo.sh owner/repo --read-only
```

The private key is generated inside ClaudeBox and never leaves it. Revoke in
GitHub > repo > Settings > Deploy keys > "ClaudeBox".

**Working on the same repo from both distros:** each has its own clone and they
sync only through GitHub. `install.sh` puts shared rules (`AGENTS.md`) at
`/etc/claude-code/CLAUDE.md` in both distros, so each Claude knows about the
other: ClaudeBox branches from fresh `main`, works on `claude/<task>` and never
pushes `main`; you review and merge. Don't mount one distro's files in the other:
git hooks and configs planted by the box would then run as you.

**Kill switch:** **Stop all services** in the tray flyout disables every service
and shuts ClaudeBox down instantly. From SSH: `wsl.exe --terminate ClaudeBox`.
Rebuild from scratch: `addons/claude-remote/uninstall.sh --remove-box && addons/claude-remote/install.sh`.

Watch it work: `wsl -d ClaudeBox -- tmux attach -t claude-server` (detach with Ctrl-b d).

## Claude in your main distro (optional, off by default)

The `claude-main` plugin keeps one named Claude conversation running in your
**main** distro, in tmux, with Remote Control. After a restart it resumes the
same conversation (`--resume` with a saved session ID) and the same Remote
Control link. It runs as you with full access (keys, `gh`, Windows), so it is
**off by default**: turn it on in the tray flyout.

Settings in `~/.config/laptop-server-mode/claude-main.env`:

```bash
NAME=my-laptop                            # tmux session, Remote Control and /resume name
DIR=$HOME/projects                        # must be a trusted folder (Claude never saves trust for $HOME)
FLAGS="--dangerously-skip-permissions"    # optional
```

Open it with `tmux attach -t my-laptop` (or `Ctrl-b s` inside tmux). Stopping it
kills only that tmux session, never your other ones.
