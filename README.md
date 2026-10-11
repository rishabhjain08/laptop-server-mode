# Laptop Server Mode

A tray toggle for Windows laptops that keeps the laptop working as a server (lid closed, unplugged, across restarts), without editing your own power settings.

- **One click** in the taskbar tray switches server mode on or off.
- **ON:** lid close and idle sleep are ignored. The screen still turns off.
- **OFF:** your normal power plan and settings apply, unchanged.
- **Restarts:** server mode and its services come back after a reboot, before anyone signs in.
- **Services:** small plug-ins started and kept alive while server mode is on. The first one runs [Claude Code](https://claude.com/claude-code) with Remote Control inside an isolated WSL distro.

## How it works

| Piece | What it does |
| --- | --- |
| Power override | Turning ON copies your *current* power plan into a temporary plan that changes only lid close (do nothing), sleep, hibernate and unattended sleep (never). Turning OFF switches back to your plan and deletes the copy. Your own plans are never edited. |
| Battery rule | On battery, server mode pauses at 35% (configurable) and your normal settings take over. It resumes when you plug in. If the battery is already below the limit when you turn it on, you're asked to plug in first, with an option to continue anyway. |
| Watchdog | A scheduled task that starts at boot. It re-applies server mode, applies the battery rule, keeps WSL running and restarts services that stop. It uses "do not store password" (S4U), so **no password is saved anywhere**. |
| Tray | Starts when you sign in. A laptop icon styled like the built-in tray icons, with a green badge when ON, an amber badge when paused by battery, and no badge when OFF. Left-click to toggle; right-click for the menu. |

The tray follows Windows 11's look: light and dark themes, your accent color, high-DPI, rounded menu with a toggle switch, and notifications that show as "Laptop Server Mode". On first run it pins its icon next to the clock (unpin it any time in Taskbar settings).

Note: any power-setting change you make while server mode is ON goes to the temporary plan and is discarded when you turn it OFF.

## Requirements

- Windows 10/11 laptop (tested on Windows 11 Home with Modern Standby)
- WSL 2 with `tmux` (for the Claude service)
- Admin rights once, to register the startup tasks

## Install

From WSL:

```bash
git clone git@github.com:rishabhjain08/laptop-server-mode.git ~/projects/laptop-server-mode
cd ~/projects/laptop-server-mode
./install.sh        # approve the Windows admin prompt
```

Files are installed to `%LOCALAPPDATA%\LaptopServerMode`. Re-run `./install.sh` to update; your config and state are kept. To remove everything, run `./uninstall.sh`.

### Config

`%LOCALAPPDATA%\LaptopServerMode\config.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `batteryLimit` | `35` | On battery, pause server mode at or below this % |
| `pollSeconds` | `15` | How often the watchdog checks |
| `wslDistro` | the distro you installed from | WSL distro that runs WSL services |
| `wslRoot` | install folder as a WSL path | Used to find service scripts from WSL |

## Services

Each service is a folder in `services/` with a `service.json` and a script that accepts `start`, `check` or `stop` (`check` exits 0 when the service is healthy):

```json
{
  "name": "claude",
  "title": "Claude Code (Remote Control)",
  "runsIn": "wsl",
  "script": "claude.sh",
  "enabledByDefault": true,
  "stopWhenServerModeOff": false
}
```

- `runsIn`: `wsl` (a bash script, piped into the distro) or `windows` (a PowerShell script).
- `wslDistro` / `wslUser` (optional): run in a specific distro as a specific user.
- `start` may exit `3` to mean "needs one-time setup by a person"; the tray shows that instead of retrying.
- Services start when server mode turns on and are restarted if `check` fails. Failing starts are retried with growing gaps of up to 30 minutes.
- `stopWhenServerModeOff: false` leaves the service running when server mode is turned off.
- Turn each service on or off from the tray's **Services** menu.

Never put secrets in a service. Let the tool use its own login (for example `claude` uses its own sign-in).

### Claude service (runs in ClaudeBox)

Claude Code runs unattended with Remote Control, in **auto** permission mode
(routine actions approved automatically, risky ones blocked), inside a
separate, locked-down WSL distro called **ClaudeBox**. `install.sh` creates it.

Why a separate distro: an unattended agent reads web pages and packages nobody
is watching, and a prompt injection could make it misbehave. ClaudeBox makes
the worst case "one revocable deploy key", not "your whole machine".

| Inside ClaudeBox, Claude can't... | How |
| --- | --- |
| Run Windows programs or read Windows files | No drive mounts, no Windows PATH, WSL interop sockets root-only (`/run/WSL` 0700) |
| Read your main distro, SSH keys or `gh` login | Separate distro filesystem; runs as unprivileged `claude` (UID 2501), no sudo, root locked |
| Use the mic, speakers or screen | WSLg bridge unmounted at boot |
| Reach your home network, VPN peers or laptop services | nftables rules for UID 2501: private/LAN/CGNAT ranges and sensitive local ports rejected; internet allowed |
| Switch itself to "bypass permissions" | Managed policy `/etc/claude-code/managed-settings.json` (root-owned) |
| Hog the laptop | cgroup caps: 6 GB RAM (5 GB soft), 4 CPU cores, 2000 processes |

`box/harden.sh` runs at every box boot **and** before every Claude start; the
service refuses to start if any check fails. Verify any time:

```bash
wsl.exe -d ClaudeBox -u root -- bash -s < box/selftest.sh
```

Note: WSL distros share one kernel, so don't set `[interop] enabled=false` in
ClaudeBox; it would turn interop off for **every** distro. The permission
approach above blocks only the box user.

**First-time setup:** `wsl -d ClaudeBox`, then `cd ~/work && claude` to sign in
and trust the folder. Until then the tray shows the service as *needs sign-in*.

**GitHub access, one repo at a time:**

```bash
box/add-repo.sh owner/repo              # read-write deploy key, cloned to ~/work/repo
box/add-repo.sh owner/repo --read-only
```

The private key is generated inside ClaudeBox and never leaves it. Revoke in
GitHub > repo > Settings > Deploy keys > "ClaudeBox".

**Kill switch:** tray menu > **Stop all services now** disables every service
and shuts ClaudeBox down instantly. From SSH: `wsl.exe --terminate ClaudeBox`.
Rebuild from scratch: `./uninstall.sh --remove-box && ./install.sh`.

Watch it work: `wsl -d ClaudeBox -- tmux attach -t claude-server` (detach with Ctrl-b d).

## Remote access (optional)

- **Tailscale** on Windows for a private network to the laptop. With WSL [mirrored networking](https://learn.microsoft.com/windows/wsl/networking#mirrored-mode-networking), SSH into WSL at the laptop's Tailscale IP. You may need to allow the port through the Hyper-V firewall (elevated PowerShell):
  ```powershell
  New-NetFirewallHyperVRule -Name WSL-SSH -DisplayName "WSL SSH" -Direction Inbound `
    -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 22
  ```
- **Chrome Remote Desktop** for the Windows desktop. It runs as a service, so it works at the lock screen and after reboots. Windows Home can't host built-in Remote Desktop.

## Tips

- Don't run it with the lid closed inside a bag; leave room for airflow.
- If the laptop stays plugged in, set a battery charge limit (e.g. 80%) in your vendor's tool (Lenovo Vantage, Dell Power Manager, etc.).
- Windows Update can still restart the laptop; server mode and services come back on their own afterwards.

## Troubleshooting

- Logs: tray menu > **Open logs**, or `%LOCALAPPDATA%\LaptopServerMode\logs`.
- If the tray shows "watchdog down", use tray menu > **Start watchdog** or re-run `./install.sh`.
- To return to normal power immediately, turn server mode OFF, or run `./uninstall.sh`.

## Development

- Edit files in `src/` and `services/`, then re-run `./install.sh` to deploy.
- Preview the low-battery dialog without unplugging: run `Tray.ps1 -Preview battery` from the install folder.
- UI code (theme, icons, menu renderer) is in `src/TrayUi.cs` and is compiled when the tray starts, so the repo contains no binaries.

## License

MIT
