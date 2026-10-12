# Changelog

Notable changes, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no
numbered releases yet, so entries are grouped by date.

## Unreleased

## 2026-10-11 (evening)

### Added
- WSL is optional: `install.ps1`, `uninstall.ps1` and `plugin.ps1` work from PowerShell without WSL; the `.sh` scripts wrap them.
- Plugins that can't run on this PC (no WSL, missing distro, missing script) show **Needs setup** with the reason on hover, logged once.
- Per-plugin settings: defaults in `plugin.json`, user overrides in `settings.json` (kept on update), passed as `LSM_SETTING_*`.
- `plugin.ps1 enable` / `disable`.
- Examples: `event-log-windows` (PowerShell hooks), `keep-wsl-running`.
- Claude add-on: Claude on Windows without WSL (`claude-windows`), a `mode` setting (`session` or `server`) for the WSL plugins, and `permissionMode`, `name` and `folder` settings. `install.sh --no-box` / `--windows` and `install.ps1` pick targets.
- `tests\run.ps1`, plus tests for running with and without WSL, plugin settings, and the flyout's reasons.
- Docs: `docs/ARCHITECTURE.md`, `docs/PLUGINS.md`, `CONTRIBUTING.md`, `SECURITY.md`, this changelog.

### Changed
- The watchdog holds only the WSL distros that running services need (`config.json`'s distro is no longer held while server mode is on; use `examples/keep-wsl-running`).
- `wslDistro` in `config.json` is optional; empty means Windows' default WSL distro.
- The tray says **Needs setup** instead of "Needs sign-in".
- `claude-main` reads only `settings.json`; the add-on installer migrates the old `~/.config/laptop-server-mode/claude-main.env` and deletes it.
- `plugin remove` also forgets the plugin's tray switch.

### Fixed
- The `.sh` scripts failed when Windows couldn't see WSL's files (nobody signed in yet).
- Claude services: resume the conversation with the latest message, and check the transcript of the Claude actually running (not the newest file).
- Claude server mode: reattach after a crash instead of registering a new server; recover from a stale server record; don't hang at the first-run "Enable Remote Control?" prompt.

### Removed
- An experimental WSLg microphone repair that restarted WSL.

## 2026-10-11

### Added
- Generic plugins (services and hooks); Claude moved into the `claude-remote` add-on.
- Windows 11 style flyout replacing the right-click menu.
- A second keep-awake holder, and a 5-minute trigger that restarts a crashed watchdog.
- `claude-main`: one named, resumable Claude session in the main distro.
- Start menu shortcut; install without admin rights; a fresh notification identity per install.
- Exhaustive logic tests, tray tests and the user journey list (`tests/CUJS.md`).

### Fixed
- A damaged `state.json` or `config.json` no longer turns server mode off.
- Remote Control is reconnected when it gives up after a restart, or the session restarts fresh when the server refuses it.
- Claude services wait for the network after boot.
- The watchdog restarts a crashed tray (but not after you quit it).

## 2026-10-10

### Added
- First version: tray toggle, temporary power plan, battery rule, boot watchdog and a Claude service.
- ClaudeBox: Claude in an isolated, hardened WSL distro with resource caps and a self-test.
