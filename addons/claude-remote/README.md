# Claude Remote add-on

Runs [Claude Code](https://claude.com/claude-code) with Remote Control on the
laptop around the clock, so you can drive it from your phone or another
computer. Pick any of three plugins:

| Plugin | Runs | Needs | Permissions by default |
| --- | --- | --- | --- |
| `claude` | Claude in **ClaudeBox**, an isolated WSL distro | WSL | skipped (the box is the sandbox) |
| `claude-main` | Claude in your main WSL distro, with your full access | WSL | asks on your phone |
| `claude-windows` | Claude on Windows, with your full access | nothing extra | asks on your phone |

## Install

Install Laptop Server Mode first. Then, from the repo root:

| You want | Run |
| --- | --- |
| ClaudeBox, plus Claude in this distro (off until you turn it on) | `addons/claude-remote/install.sh` (from WSL) |
| Only Claude in this distro | `addons/claude-remote/install.sh --no-box` (from WSL) |
| Claude on Windows (no WSL needed) | `powershell -ExecutionPolicy Bypass -File addons\claude-remote\install.ps1`, or add `--windows` to `install.sh` |

`install.sh` creates and hardens ClaudeBox, installs the shared agent rules
and runs the isolation self-test. Re-run an installer to update; your settings
are kept. Remove the plugins with `uninstall.sh` or `uninstall.ps1` in this
folder (`uninstall.sh --remove-box` deletes ClaudeBox too).

## Session or server mode

Each plugin keeps Claude running in one of two ways:

| `mode` | What runs | After a restart |
| --- | --- | --- |
| `session` (default; WSL plugins) | One Claude conversation in tmux with Remote Control. You can also `tmux attach` and use it at the laptop. | Resumes the conversation with the latest message |
| `server` (only mode on Windows) | `claude remote-control`: no conversation until you start one from the Claude app, then a new session per chat, in the plugin's folder | Reattaches to the same server in the app if it ran within about 4 hours, else registers a new one |

Session mode keeps one long conversation and all its context; server mode is
simpler and lets you start fresh sessions from the app.

## Settings

Put a `settings.json` in the installed plugin's folder,
`%LOCALAPPDATA%\LaptopServerMode\plugins\<plugin>\settings.json`, with the keys you
want to change, e.g. `{ "mode": "server" }`. Changes apply within a minute: the
plugin restarts Claude with the new settings.

| Setting | `claude` | `claude-main` | `claude-windows` |
| --- | --- | --- | --- |
| `mode` | `session` | `session` | (server only) |
| `permissionMode` | `bypassPermissions` | `default` | `default` |
| `name` (shown in the app) | Claude's default | `claude-main` | Claude's default |
| `folder` | (`~/work`) | your home; set a subfolder, e.g. `~/projects` | `%USERPROFILE%\Claude` |

`permissionMode` is passed to Claude: `default` asks you (on your phone) before
risky actions; `acceptEdits`, `auto`, `plan` and `dontAsk` are Claude's other
modes; `bypassPermissions` skips every prompt. Outside ClaudeBox that gives
remote sessions your full access, so keep the default unless you understand the
risk.

The folder must be trusted by Claude once: run `claude` in it and accept the
prompt. Until then, and until Claude is installed and signed in, the tray shows
the plugin as **Needs setup**; hover it for the exact command.

## Claude in ClaudeBox

Claude Code runs unattended with Remote Control and **permission prompts
skipped** (`--dangerously-skip-permissions`), inside a separate, locked-down
WSL distro called **ClaudeBox**, which acts as the sandbox. This folder's `install.sh` creates it.
After a restart it resumes the conversation with the latest message, or starts
a fresh one if there is none (or with `"mode": "server"`, see above).

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
and trust the folder. Until then the tray shows the service as *Needs setup*.

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
conversation in that folder with the latest message. It runs as you with full
access (keys, `gh`, Windows), so it is **off by default** (`install.sh --no-box`
turns it on): turn it on in the tray flyout.

Set its folder first, since Claude never remembers trust for your home folder:

```json
{ "folder": "~/projects", "name": "my-laptop" }
```

in `%LOCALAPPDATA%\LaptopServerMode\plugins\claude-main\settings.json`. (Older
versions used `~/.config/laptop-server-mode/claude-main.env`; `install.sh`
moves it into `settings.json`.)

Open it with `tmux attach -t my-laptop` (or `Ctrl-b s` inside tmux). Stopping it
kills only that tmux session, never your other ones.

## Claude on Windows (no WSL needed)

The `claude-windows` plugin runs `claude remote-control` hidden in the
background, as you, in server mode: open the Claude app and start a session
on this computer, and it works in the plugin's folder (default
`%USERPROFILE%\Claude`). Windows has no tmux to keep one interactive
conversation alive unattended, so server mode is the only mode here.

There's no sandbox: sessions can do anything your Windows account can. So it
is off unless you install it with `install.ps1` (or `install.sh --windows`),
and `permissionMode` defaults to `default`, which asks on your phone before
risky actions.

First time only, in PowerShell: install Claude Code if needed
(`irm https://claude.ai/install.ps1 | iex`), then run `claude` in the folder
to sign in and trust it, and run `claude remote-control` there once to switch
Remote Control on (answer `y`, wait for *Ready*, press Ctrl+C). The tray shows
**Needs setup** with the next step until all three are done.

Its output goes to `%LOCALAPPDATA%\LaptopServerMode\logs\claude-windows.log`.
Turning it off in the tray stops the server and any sessions it started.
