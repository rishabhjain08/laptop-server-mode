# Architecture

How Laptop Server Mode works, where everything lives, and why it's built the
way it is. Read this before changing anything in `src/`.

- [Overview](#overview)
- [Components](#components)
- [Repository layout](#repository-layout)
- [Installed layout](#installed-layout)
- [Key flows](#key-flows)
- [Design decisions](#design-decisions)
- [Windows and WSL quirks](#windows-and-wsl-quirks)

## Overview

Everything is Windows PowerShell 5.1 plus two small C# files compiled at run
time, started by four scheduled tasks registered for the installing user.
There is no Windows service, no driver and no binary in the repo.

```
                      Task Scheduler (your user)
   ┌──────────────────┬──────────────────┬───────────────┬─────────────────┐
   │ at boot, sign-in │ at boot, sign-in │ at sign-in    │ on shutdown     │
   │ and every 5 min  │ and every 5 min  │               │ (event 1074)    │
   ▼                  ▼                  ▼               ▼
 Watchdog.ps1      KeepAwake.ps1       Tray.ps1        Run-Hooks.ps1
 (S4U, session 0)  (S4U, session 0)    (your desktop)  (S4U)
   │  │  │              │                 │               │
   │  │  └─ plugins: services, hooks, WSL distros          │
   │  └──── power request (keep the system awake)          │
   └─────── power plan, battery rule ──┐                   │
                                       ▼                   ▼
              state.json · config.json · plugins\ · logs\   (shared, %LOCALAPPDATA%)
```

The tray and the watchdog never talk to each other directly. The tray writes
the user's intent to `state.json` (and applies it at once), and the watchdog
re-applies the same state every round. Either can crash without the other
noticing anything beyond a stale heartbeat.

## Components

| File | Runs as | Does |
| --- | --- | --- |
| `src/ServerMode.psm1` | module | State (`state.json` with a lock and a backup), config, the server-mode rule, the power override, keep-awake requests, logging |
| `src/Plugins.ps1` | dot-sourced by the module | Loading plugins, running them in Windows or WSL, the service lifecycle, hooks, WSL detection, settings |
| `src/Watchdog.ps1` | task, at boot | The main loop: re-applies server mode, fires hooks, holds WSL distros, keeps services running, restarts a crashed tray |
| `src/KeepAwake.ps1` | task, at boot | A second, independent keep-awake request (shares no code with the watchdog on purpose) |
| `src/Tray.ps1` | task, at sign-in | The tray icon, flyout, notifications and the low-battery prompt |
| `src/Flyout.cs`, `src/TrayUi.cs` | compiled by `Tray.ps1` | Drawing the Windows 11 style flyout, icons and dialog |
| `src/Run-Hooks.ps1` | task, on shutdown | Runs `shutdown` hooks |
| `src/OnPowerChange.ps1` | task, on charger plug/unplug | Resumes a paused server mode at once and holds the system awake until the watchdog runs (a sleeping laptop wakes for under a second on plug-in, too short for the watchdog's next round) |
| `src/Install-Tasks.ps1` | installer | Registers the five tasks and the Start menu shortcut |
| `src/Uninstall.ps1` | uninstaller | Stops everything, restores the normal power plan, removes all of it |
| `src/stage.sh` | repo `.sh` wrappers | Copies scripts to a Windows temp folder before running them (see [quirks](#windows-and-wsl-quirks)) |

## Repository layout

```
laptop-server-mode/
├── install.ps1 / install.sh        install or update (.sh wraps .ps1)
├── uninstall.ps1 / uninstall.sh    remove everything
├── plugin.ps1 / plugin.sh          add, list, enable, disable, remove plugins
├── src/                            the app (copied to the install folder)
├── examples/                       small plugins to copy from
│   ├── event-log/                  hooks in WSL
│   ├── event-log-windows/          hooks in PowerShell
│   ├── file-share/                 a run service in WSL
│   └── keep-wsl-running/           hold a WSL distro while server mode is on
├── addons/claude-remote/           the Claude Remote add-on
│   ├── install.sh / install.ps1    choose targets: ClaudeBox, main distro, Windows
│   ├── plugins/                    claude (ClaudeBox), claude-main, claude-windows
│   ├── setup.sh, harden.sh,        build and lock down the ClaudeBox distro
│   │   wsl.conf, selftest.sh
│   ├── managed-settings.json       Claude Code settings inside ClaudeBox
│   ├── AGENTS.md                   rules shared by the Claude instances
│   └── add-repo.sh                 give ClaudeBox one GitHub repo (deploy key)
├── tests/
│   ├── run.ps1 / run.sh            run the automated tests
│   ├── Logic.Tests.ps1             every combination of the rules and lifecycle
│   ├── Tray.Tests.ps1              the real tray, driven with real input
│   └── CUJS.md                     every user journey and how it's tested
└── docs/                           this file, PLUGINS.md, images
```

## Installed layout

`%LOCALAPPDATA%\LaptopServerMode\` (per user, no admin):

| Path | What |
| --- | --- |
| `*.ps1`, `*.psm1`, `*.cs` | A copy of `src/` (replaced on update) |
| `config.json` | User settings (kept on update) |
| `state.json`, `state.json.bak` | Server mode on/off, service switches and statuses, heartbeat (kept on update) |
| `state.lock` | Lock file for `state.json` writers |
| `plugins\<name>\` | Installed plugins, each with an optional user `settings.json` |
| `logs\` | `watchdog.log`, `hooks.log`, `tray.log`, `keepawake.log`, Windows service logs (rotated at 1 MB) |
| `run\` | PID files for Windows `run` services |
| `app.id` | The notification identity of this install |

Also: four scheduled tasks named `LaptopServerMode *`, a Start menu shortcut,
a temporary power plan named "Laptop Server Mode - temporary" while server
mode is on, and per WSL distro `~/.local/state/laptop-server-mode/` for WSL
`run` services' PID files and logs.

## Key flows

### Turning server mode on

1. The tray sets `enabled` in `state.json` and calls `Sync-ServerMode`.
2. The server-mode rule decides on, paused (battery) or off from `enabled`, AC power, battery percent, `batteryLimit` and a one-time "turn on anyway".
3. On: the active power plan is duplicated into the temporary plan, which changes only lid close (do nothing), sleep, hibernate and unattended sleep (never), and is activated. The user's own plans are never written to.
4. Off or paused: the original plan is reactivated and the copy deleted.
5. Within one round the watchdog sees the change, fires `server-on`/`server-off`/`server-paused` hooks, and starts or stops services.

### One watchdog round (every `pollSeconds`)

1. Read `config.json` (keep the last good one if it's invalid) and apply the server-mode rule (`Sync-ServerMode`), which also writes the heartbeat.
2. Hold or release the keep-awake request.
3. Fire hooks: `boot` once per Windows boot, and state-change events.
4. Hold the WSL distros that services need (`Get-HeldDistros`): one hidden `wsl.exe -d <distro> -- sleep infinity` each, adopted again after a watchdog restart.
5. Sync services: `check` each; `start` what should run and isn't, with backoff; `stop` what shouldn't. Every round while on, every fourth while off.
6. Every minute, restart the tray if someone is signed in and it isn't running (unless they quit it).
7. Every ~10 minutes, trim its own memory.

### Running a plugin

- **WSL:** the code is piped as stdin into `wsl.exe -d <distro> [-u <user>] --cd / -- bash -s`, with `LSM_*` variables exported at the top. `run` commands are double-forked (`setsid -f`) so they outlive the `wsl.exe` call.
- **Windows:** hooks and `script` verbs run in a hidden `powershell.exe -EncodedCommand`; `run` services are started hidden through `cmd.exe` and tracked by PID plus start time (so a reused PID isn't mistaken for them).
- Before any of that, `Get-PluginProblem` checks the plugin can run here (runsIn valid, WSL and its distro installed, script present). If not, the plugin is **Needs setup** with that reason.

## Design decisions

| Decision | Why |
| --- | --- |
| A temporary copy of the power plan | Server mode must never change the user's own settings, and turning it off must restore them exactly, even after a crash |
| Scheduled tasks with S4U ("do not store password") | Starts at boot before sign-in, needs no admin rights, and saves no password. The cost: no network credentials and no desktop (session 0) |
| A "system required" power request, held twice | With the lid closed, Modern Standby suspends the system unless something holds a power request. The watchdog holds one; `KeepAwake.ps1` holds another so a crashed watchdog (restarted within 5 minutes) doesn't let the laptop sleep |
| A task on the plug-in event (Kernel-Power 105) | Once paused by the battery rule the laptop sleeps normally. Plugging in wakes it only briefly, and the watchdog's sleeping loop doesn't run in that window |
| A 5-minute repeating trigger on the tasks | Task Scheduler's restart setting covers a task that fails to start, not a process that dies later |
| State in one JSON file, written atomically with a backup | A crash or power cut mid-write must not turn server mode off; a damaged file falls back to the backup |
| Plugins instead of built-in features | The core knows nothing about Claude or any other tool; the Claude add-on is three ordinary plugins |
| WSL support built into the core | WSL distros need a Windows process holding them open, which every WSL plugin would otherwise re-implement |
| `start` exit code 3 = "needs a person" | Some setup (sign-in, trusting a folder) can't be automated; retrying it in a loop helps no one |
| UI compiled from C# at run time | No binaries in the repo, and the UI can follow Windows 11's look, DPI and themes |
| PowerShell 5.1, ASCII-only `src/` | It's on every Windows 10/11 PC; 5.1 misreads UTF-8 files without a BOM |

## Windows and WSL quirks

Things learned the hard way. Most of the code's odd corners exist because of one of these.

- **Modern Standby.** Closing the lid with "do nothing" set still enters Modern Standby, which throttles everything unless a power request is held.
- **Session 0.** Tasks that start before sign-in run in session 0: no windows, no message boxes, no desktop.
- **WSL stops idle distros.** A distro stops shortly after the last `wsl.exe` that holds it exits, taking every process inside with it. Hence the `sleep infinity` keep-alives.
- **`\\wsl.localhost` needs a signed-in user.** Until someone signs in, Windows can't see WSL's files, and Windows programs started from a Linux folder fail with "Invalid argument". The `.sh` wrappers therefore copy scripts to a Windows temp folder and run PowerShell from `/mnt/c` (`src/stage.sh`).
- **WSLg follows the first session.** WSLg (Linux GUI apps, the microphone) attaches to the Windows session that started the WSL VM. After a boot before sign-in that's session 0, so WSLg doesn't work until WSL restarts. Laptop Server Mode deliberately doesn't restart WSL for it.
- **Never disable WSL interop in one distro.** WSL distros share a kernel, so `[interop] enabled=false` in one turns interop off for all of them. ClaudeBox blocks its user from the interop socket instead.
- **`wsl.exe` and UTF-16.** Some `wsl.exe` output is UTF-16; the code strips NUL bytes. Installed distros are read from the registry (`HKCU\...\Lxss`) instead, with `wsl --list` as a fallback.
- **Notifications need an app id.** Windows caches the toast identity per app id, so each install gets a fresh one (`app.id`) to avoid showing a stale name and icon.
- **PowerShell 5.1 encoding.** Without a BOM it reads files as the system code page, so `src/` stays ASCII.

The Claude add-on has its own design notes, including the ClaudeBox
isolation model and how Remote Control is kept alive, in
[addons/claude-remote/README.md](../addons/claude-remote/README.md).
