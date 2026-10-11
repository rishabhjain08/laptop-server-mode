# Laptop Server Mode

A tray toggle for Windows laptops that keeps the laptop working as a server (lid closed, unplugged, across restarts) without editing your own power settings. Plugins let it keep your own programs running and run scripts when things happen.

- **One click** in the taskbar tray switches server mode on or off.
- **ON:** lid close and idle sleep are ignored. The screen still turns off.
- **OFF:** your normal power plan and settings apply, unchanged.
- **Restarts:** server mode and your plugins come back after a reboot, before anyone signs in.
- **Plugins:** keep a command running (a bot, a file server, an agent), or run a script on boot, shutdown, or when server mode changes. Write them in bash (any WSL distro) or PowerShell.

## How it works

| Piece | What it does |
| --- | --- |
| Power override | Turning ON copies your *current* power plan into a temporary plan that changes only lid close (do nothing), sleep, hibernate and unattended sleep (never). Turning OFF switches back to your plan and deletes the copy. Your own plans are never edited. |
| Battery rule | On battery, server mode pauses at 35% (configurable) and your normal settings take over. It resumes when you plug in. If the battery is already below the limit when you turn it on, you're asked to plug in first, with an option to continue anyway. |
| Watchdog | A scheduled task that starts at boot. It re-applies server mode, applies the battery rule, keeps WSL running, restarts plugin services that stop and runs hooks. It uses "do not store password" (S4U), so **no password is saved anywhere**. |
| Keep-awake | With the lid closed, Windows is in Modern Standby, and a "keep the system awake" request is what keeps it working. The watchdog holds one; a second small task holds another, so the laptop stays up even while a crashed watchdog is restarted (within 5 minutes). |
| Tray | Starts when you sign in. A laptop icon with a green badge when ON, amber when paused by battery, and none when OFF. Left-click toggles; right-click opens a flyout with each service's status and switch. |

The tray follows Windows 11's look: light and dark themes, your accent color, high DPI and keyboard navigation. Notifications show as "Laptop Server Mode".

Note: any power-setting change you make while server mode is ON goes to the temporary plan and is discarded when you turn it OFF.

## Requirements

- Windows 10/11 laptop (tested on Windows 11 Home with Modern Standby)
- WSL 2 (for the installer and WSL plugins)
- Admin rights once, to register the startup tasks

## Install

From WSL:

```bash
git clone https://github.com/rishabhjain08/laptop-server-mode.git
cd laptop-server-mode
./install.sh        # approve the Windows admin prompt
```

Files are installed to `%LOCALAPPDATA%\LaptopServerMode`. Re-run `./install.sh` to update; your config, state and plugins are kept. To remove everything, run `./uninstall.sh`.

### Config

`%LOCALAPPDATA%\LaptopServerMode\config.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `batteryLimit` | `35` | On battery, pause server mode at or below this % |
| `pollSeconds` | `15` | How often the watchdog checks |
| `wslDistro` | the distro you installed from | Default WSL distro for plugins |

## Plugins

A plugin is a folder with a `plugin.json`. It can provide a **service** (something kept running), **hooks** (commands run on events), or both.

```bash
./plugin.sh add examples/file-share     # install (or update) a plugin
./plugin.sh list
./plugin.sh remove file-share           # stops its service, then deletes it
```

Installed plugins live in `%LOCALAPPDATA%\LaptopServerMode\plugins`. The watchdog picks up changes on its next check; nothing needs restarting.

### A service in one line

```json
{
  "name": "file-share",
  "title": "File share on port 8080",
  "run": "python3 -m http.server 8080 --directory ~/share"
}
```

`run` is started in a login shell in your WSL distro and restarted if it exits. Its output goes to `~/.local/state/laptop-server-mode/<name>.log` (Windows: `logs\<name>.log`). Services start when server mode turns on and are retried with growing gaps (up to 30 minutes) if they keep failing. Each service gets a switch in the tray flyout.

### Hooks

```json
{
  "name": "backup",
  "on": {
    "boot":     "./sync.sh",
    "shutdown": "rclone sync ~/notes remote:notes"
  }
}
```

| Event | When |
| --- | --- |
| `boot` | Once after Windows starts, before anyone signs in |
| `server-on` | Server mode turned on, or resumed after a battery pause |
| `server-off` | Server mode turned off |
| `server-paused` | Paused by the battery rule |
| `service-failed` | A service failed to start (first failure only, until it recovers) |
| `shutdown` | Windows is shutting down or restarting. Best effort: Windows doesn't wait, so keep it to a few seconds. |

Hooks run one at a time with a 60-second limit, in the plugin's folder, and log to `logs\hooks.log`. Keep them short and don't leave work running in the background: a `boot` hook can run while the WSL distro is still starting, and processes it leaves behind may be cleaned up. Put long-running work in a service instead. Hooks get these environment variables:

| Variable | Value |
| --- | --- |
| `LSM_EVENT` | The event name |
| `LSM_STATE` | `on`, `paused` or `off` |
| `LSM_PREVIOUS` | Previous state (state-change events) |
| `LSM_SERVICE` | The failed service (`service-failed`) |
| `LSM_BATTERY`, `LSM_ON_AC` | Battery percent, and `1` when plugged in |
| `LSM_PLUGIN`, `LSM_PLUGIN_DIR` | This plugin's name and folder |

`examples/event-log` logs every event to `~/server-mode-events.log`; it's a quick way to watch them.

### plugin.json reference

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | (required) | Unique id |
| `title` | `name` | Shown in the tray |
| `runsIn` | `wsl` | `wsl` (bash) or `windows` (PowerShell for hooks, a command line for `run`) |
| `wslDistro`, `wslUser` | `config.json`'s distro, its default user | Where WSL plugins run |
| `run` | | A command to keep running |
| `script` | | Instead of `run`: a script called with `start`, `check` (exit 0 when healthy) or `stop`. `start` may exit `3` for "needs one-time setup by a person"; the tray shows *needs sign-in* instead of retrying. |
| `on` | | Hooks: `{ "<event>": "<command>" }` |
| `enabledByDefault` | `true` | `false` keeps a service off until you turn it on in the tray. A plugin's hooks run only while it is on. |
| `stopWhenServerModeOff` | `false` | `false` leaves the service running when server mode is turned off |

A few notes:

- WSL scripts are piped into the distro, so they also work in distros that can't see Windows files.
- Windows `run` services run hidden in the background (session 0), so they can't show windows.
- Don't put secrets in `plugin.json`. Let the tool use its own login.

### Kill switch

**Stop all services** in the tray flyout turns every service off and stops it at once. Services in their own WSL distro are stopped by shutting that distro down.

## Add-ons

- **[Claude Remote](addons/claude-remote/)**: runs Claude Code with Remote Control unattended inside an isolated, locked-down WSL distro (ClaudeBox), so you can drive it from your phone. It's a pair of plugins plus a setup script, and a good example of a larger plugin.

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
- Windows Update can still restart the laptop; server mode and plugins come back on their own afterwards.

## Troubleshooting

- Logs: the folder button in the tray flyout, or `%LOCALAPPDATA%\LaptopServerMode\logs` (`watchdog.log`, `hooks.log`, `tray.log`).
- If the flyout says background checks stopped, click the banner or re-run `./install.sh`.
- To return to normal power immediately, turn server mode OFF, or run `./uninstall.sh`.

## Development

- Edit files in `src/`, then re-run `./install.sh` to deploy.
- `tests/run.sh` runs the automated tests on a temporary copy (no power or service changes): every combination of the server-mode rule, the keep-awake rule, hook events and the service lifecycle.
- `src/Plugins.ps1` runs plugins; `src/ServerMode.psm1` handles power and state; `src/Flyout.cs` and `src/TrayUi.cs` draw the tray UI and are compiled when the tray starts, so the repo contains no binaries.
- Preview the UI without clicking around (from the install folder):
  - `Tray.ps1 -Preview flyout -Out <folder>` saves PNGs of every flyout state in both themes.
  - `Tray.ps1 -Preview battery` shows the low-battery dialog.

## License

MIT
