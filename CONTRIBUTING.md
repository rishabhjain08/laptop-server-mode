# Contributing

Thanks for helping. This project changes how a laptop sleeps and runs things
unattended, so changes are judged on one question first: can it leave
someone's laptop asleep, awake when it shouldn't be, or with their settings
changed? Please keep that in mind, and test on a real laptop when you touch
power, the watchdog or plugins.

- [Getting started](#getting-started)
- [Development loop](#development-loop)
- [Tests](#tests)
- [Conventions](#conventions)
- [Pull requests](#pull-requests)
- [Reporting bugs](#reporting-bugs)

## Getting started

You need Windows 10 or 11 and Windows PowerShell 5.1 (built in). WSL is
optional; you need it only to work on WSL plugins or the Claude add-on.

```powershell
git clone https://github.com/rishabhjain08/laptop-server-mode.git
cd laptop-server-mode
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first: it explains the
components, the file layout and the Windows quirks behind most design choices.

## Development loop

1. Edit files in `src/` (or `examples/`, `addons/`).
2. Run the tests (below).
3. Deploy to your own install by running the installer again. It replaces the code, restarts the watchdog and tray, and keeps config, state, plugins and running services.
4. Watch `%LOCALAPPDATA%\LaptopServerMode\logs\watchdog.log`.

To update an installed plugin after editing it: `.\plugin.ps1 add <folder>`.

Preview the UI without clicking around (run from the install folder):

```powershell
.\Tray.ps1 -Preview flyout -Out C:\temp\previews   # PNGs of every flyout state, light and dark
.\Tray.ps1 -Preview battery                        # the low-battery dialog
```

Previews render at the DPI of the session they run in.

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\run.ps1     # or tests/run.sh from WSL
```

They run on a temporary copy of `src/` and never touch your install, power
settings or services. WSL is mocked, so they pass with or without it.

| Suite | Covers |
| --- | --- |
| `tests/Logic.Tests.ps1` | Every combination of the server-mode rule, the keep-awake rule, hook events and the service lifecycle; WSL present or missing; plugin settings; damaged state and config files; log rotation |
| `tests/Tray.Tests.ps1` | The real tray and flyout driven with mouse and keyboard input: toggling, service switches, stop all, the low-battery prompt, notifications, the watchdog banner, themes and errors |

Some things can only be checked on a real laptop: the lid, sleep, restarts,
the screen. [tests/CUJS.md](tests/CUJS.md) lists every user journey, how each
is tested, and the latest results. If your change affects a journey, run it
and update the results there.

When adding logic, add it to `Logic.Tests.ps1` in the same style: enumerate
the inputs and check every combination against the spec.

## Conventions

**PowerShell (`src/`, `*.ps1`)**

- Windows PowerShell 5.1 compatible. No PowerShell 7-only syntax (`?:`, `??`, `&&`).
- `src/` files are ASCII-only: 5.1 misreads UTF-8 without a BOM.
- Never write the user's power plans; only the temporary copy.
- Anything that runs before sign-in must work in session 0 (no UI, no interactive prompts).
- Log what the app does and why, in plain sentences, with `Write-Log`.

**Bash (WSL plugins, the add-on)**

- `#!/bin/bash` with `set -u` (and `set -euo pipefail` in installers).
- Start Windows programs from `/mnt/c`; until someone signs in, Windows can't see WSL's files.

**Plugins**

- A `start` that needs a person exits `3` and prints one sentence saying what to do.
- No secrets in `plugin.json`.

**Writing**

- Comments explain why, not what.
- User-facing text (UI, logs, README) is short and plain: say what happened and what to do.
- No binaries in the repo (the UI is compiled from `src/*.cs` at run time). Screenshots for docs go in `docs/images/`.

## Pull requests

1. Fork, and branch from `main`.
2. Keep each pull request to one change, with a message that says what changed and why.
3. Before you open it:
   - [ ] `tests\run.ps1` passes
   - [ ] You ran the affected journeys from `tests/CUJS.md` on a real laptop, or say which you couldn't
   - [ ] Docs updated (README, `docs/`, add-on README, CHANGELOG under **Unreleased**)
   - [ ] UI changes include before and after previews in both themes
4. Describe how you tested it.

## Reporting bugs

Open an issue with:

- Windows version and edition, laptop model, and whether WSL is installed
- What you did, what you expected and what happened
- The relevant lines from `watchdog.log` (and `hooks.log` or a service log if it's a plugin)

Security problems: see [SECURITY.md](SECURITY.md) instead of opening a public issue.
