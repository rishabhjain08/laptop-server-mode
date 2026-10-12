# Plugins

A plugin is a folder with a `plugin.json`. It can provide a **service**
(something Laptop Server Mode keeps running), **hooks** (commands run when
something happens), or both. Plugins run in Windows (PowerShell or a command
line) or in a WSL distro (bash).

- [Managing plugins](#managing-plugins)
- [Services](#services)
- [Hooks](#hooks)
- [Settings](#settings)
- [With or without WSL](#with-or-without-wsl)
- [plugin.json reference](#pluginjson-reference)
- [Environment variables](#environment-variables)
- [Writing good plugins](#writing-good-plugins)

## Managing plugins

```powershell
.\plugin.ps1 add <folder>...       # install, or update (keeps the user's settings.json)
.\plugin.ps1 list                  # each plugin, where it runs, and why if it can't
.\plugin.ps1 enable <name>...      # turn a service on (like its tray switch)
.\plugin.ps1 disable <name>...     # turn it off
.\plugin.ps1 remove <name>...      # stop its service, delete it and forget its switch
```

From WSL, `./plugin.sh` takes the same commands. If PowerShell refuses to run
scripts, prefix with `powershell -ExecutionPolicy Bypass -File`.

Installed plugins live in `%LOCALAPPDATA%\LaptopServerMode\plugins\<name>`.
The watchdog picks up changes on its next check (every 15 seconds by
default); nothing needs restarting.

## Services

### A command to keep running (`run`)

```json
{
  "name": "file-share",
  "title": "File share on port 8080",
  "run": "python3 -m http.server 8080 --directory ~/share"
}
```

The command runs in a login shell in the plugin's WSL distro, in the
background, and is started again if it exits. With `"runsIn": "windows"` it
runs as a hidden Windows command line instead:

```json
{
  "name": "file-share",
  "title": "File share on port 8080",
  "runsIn": "windows",
  "run": "python -m http.server 8080 --directory %USERPROFILE%\\share"
}
```

Output goes to `~/.local/state/laptop-server-mode/<name>.log` (WSL) or
`%LOCALAPPDATA%\LaptopServerMode\logs\<name>.log` (Windows).

### A script with full control (`script`)

For services that need their own health check or setup steps, point `script`
at a file in the plugin folder. It's called with one argument:

| Argument | Must |
| --- | --- |
| `start` | Start the service in the background and return within 60 seconds. Exit `3` (and print why) if a person must do something first. |
| `check` | Exit `0` if healthy, anything else if not. Output on success is logged (useful for "fixed X"). |
| `stop` | Stop it. |

```bash
#!/bin/bash
# plugins/my-bot/bot.sh, with "script": "bot.sh" in plugin.json
case "$1" in
  start)
    [ -f ~/.config/my-bot/token ] || { echo "No token yet. Run: my-bot login"; exit 3; }
    tmux new-session -d -s my-bot 'my-bot serve' ;;
  check) tmux has-session -t my-bot 2>/dev/null ;;
  stop)  tmux kill-session -t my-bot 2>/dev/null; true ;;
esac
```

On Windows, use a `.ps1` file with `param([string]$Verb)` and `exit` codes in
the same way. `addons/claude-remote/plugins/` has three full examples.

### Lifecycle

- Services start when server mode turns on, and when their switch is turned on.
- A failed start is retried with growing gaps: 1, 2, 4, ... up to 30 minutes. The `service-failed` hook fires on the first failure.
- `start` exiting `3` shows **Needs setup** with its message, and is checked again every minute without counting as a failure.
- When server mode turns off, services keep running unless `stopWhenServerModeOff` is `true`.
- **Stop all services** in the flyout turns every service off and stops it immediately. Services in their own WSL distro are stopped by shutting that distro down.

## Hooks

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
| `shutdown` | Windows is shutting down or restarting. Best effort: Windows doesn't wait. |

Hooks run one at a time, in the plugin's folder, with a 60-second limit (20
for `shutdown`), and log to `logs\hooks.log`. A plugin's hooks run only while
its switch is on. Hook commands are bash in WSL, PowerShell on Windows.

`examples/event-log` (WSL) and `examples/event-log-windows` log every event
to `server-mode-events.log` in your home folder: a quick way to watch them.

## Settings

A plugin declares its settings and their defaults in `plugin.json`:

```json
"settings": { "port": 8080, "mode": "fast" }
```

Users change them in `settings.json` in the installed plugin's folder, with
only the keys they change:

```json
{ "port": 9090 }
```

`plugin add` keeps the user's `settings.json` when it updates the plugin.
Services, hooks and `run` commands get each setting as an environment
variable named `LSM_SETTING_` plus the key in capitals, with `camelCase`
split by `_`: `permissionMode` becomes `LSM_SETTING_PERMISSION_MODE`.
Booleans become `true` or `false`, and arrays or objects become JSON. An
invalid `settings.json` is logged once and the defaults are used.

To apply a change to a running service, have its `check` compare the
settings it was started with and fail when they differ; the watchdog then
restarts it. The Claude plugins do this.

## With or without WSL

- A plugin runs in WSL unless it says `"runsIn": "windows"`.
- Its distro is its own `wslDistro`, else `config.json`'s `wslDistro`, else Windows' default WSL distro (`wsl --set-default <name>`).
- If WSL or that distro isn't installed, the plugin shows **Needs setup** with the reason, its hooks are skipped and nothing retries in a loop. It starts on the next check after you install them.
- WSL stops a distro when no Windows process holds it open. The watchdog holds a distro while one of its services should be running. To keep a distro up whenever server mode is on (for your own tmux sessions, say), add `examples/keep-wsl-running` and set `wslDistro` in it.
- WSL scripts are piped into the distro, so they also work in distros that can't see Windows files (like the Claude add-on's ClaudeBox).

## plugin.json reference

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | (required) | Unique id |
| `title` | `name` | Shown in the tray |
| `runsIn` | `wsl` | `wsl` (bash) or `windows` (PowerShell for hooks and `script`, a command line for `run`) |
| `wslDistro` | see [above](#with-or-without-wsl) | Distro for WSL plugins |
| `wslUser` | the distro's default user | User for WSL plugins (`root` to manage other users) |
| `run` | | A command to keep running |
| `script` | | Instead of `run`: a script called with `start`, `check` or `stop` |
| `on` | | Hooks: `{ "<event>": "<command>" }` |
| `enabledByDefault` | `true` | `false` keeps a service off until it's turned on |
| `stopWhenServerModeOff` | `false` | `true` stops the service when server mode turns off |
| `settings` | | Settings and their defaults |

## Environment variables

| Variable | In | Value |
| --- | --- | --- |
| `LSM_PLUGIN`, `LSM_PLUGIN_DIR` | everything | The plugin's name and folder |
| `LSM_SETTING_*` | everything | The plugin's settings |
| `LSM_EVENT` | hooks | The event name |
| `LSM_STATE` | hooks | `on`, `paused` or `off` |
| `LSM_PREVIOUS` | state-change hooks | The previous state |
| `LSM_SERVICE` | `service-failed` | The service that failed |
| `LSM_BATTERY`, `LSM_ON_AC` | hooks | Battery percent, and `1` when plugged in |

## Writing good plugins

- **Keep hooks short** and don't leave work running in the background: a `boot` hook can run while the distro is still starting, and processes it leaves behind may be cleaned up. Put long-running work in a service.
- **Background means no windows.** Windows services and hooks run in session 0, so they can't show anything on screen.
- **Before sign-in, Windows can't see WSL's files.** A WSL plugin that starts a Windows program (`cmd.exe`, `powershell.exe`, ...) must `cd /mnt/c` first, or it fails with "Invalid argument".
- **No secrets in `plugin.json`.** Let the tool use its own login, and use exit code `3` to ask the user to sign in.
- **Say why.** Whatever a failing `start` prints is shown in the tray and the log, so print a sentence a person can act on.
