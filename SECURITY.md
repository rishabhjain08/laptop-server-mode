# Security

## Reporting a vulnerability

Please don't open a public issue for security problems. Use GitHub's private
reporting instead: the repository's **Security** tab > **Report a
vulnerability**. Include what an attacker could do, and steps to reproduce.
You'll get a reply as soon as possible, and credit in the fix if you want it.

## What Laptop Server Mode changes on your PC

- **Power:** while server mode is on, a temporary copy of your power plan is active (lid close does nothing, no sleep or hibernate). Turning it off or uninstalling restores your plan and deletes the copy. Your own plans are never edited.
- **Scheduled tasks:** four tasks named `LaptopServerMode *`, registered for your user only. They use "do not store password" (S4U), so no password is saved, and they run with your normal (non-admin) rights.
- **Files:** everything is in `%LOCALAPPDATA%\LaptopServerMode`, plus a Start menu shortcut.
- **Admin rights:** not needed. If Windows refuses to register the tasks, the installer asks for elevation once.
- **Network:** none. The app opens no ports and contacts no server.

Uninstalling removes all of it.

## Trust model

- **Plugins run as you.** A plugin's service and hooks have the same access as your user account, in Windows or in its WSL distro. Only install plugins you trust, as you would any script.
- **The keep-awake behavior is the point.** A laptop in server mode stays on with the lid closed. Physical security of the laptop is up to you; the screen still locks as usual.
- **Remote access isn't included.** Whatever you use to reach the laptop (Tailscale, ZeroTier, SSH, Chrome Remote Desktop) brings its own security model.

## The Claude Remote add-on

The add-on runs an AI agent unattended, which is a different risk: the agent
reads web pages and packages nobody is watching, and a prompt injection could
make it misbehave.

- **ClaudeBox** runs Claude in a separate, locked-down WSL distro: no Windows files or programs, no LAN or private networks, no access to your main distro or keys, resource caps, and one revocable GitHub deploy key per repo. A self-test checks the isolation; see [addons/claude-remote/README.md](addons/claude-remote/README.md).
- **Claude in your main distro or on Windows** has your full access. Both are off unless you choose them, and permissions default to asking you (on your phone) before risky actions. Turning on `bypassPermissions` outside ClaudeBox gives remote sessions your full access.
