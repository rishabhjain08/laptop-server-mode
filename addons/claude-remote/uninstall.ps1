# Removes the Claude Remote plugins (from PowerShell). The ClaudeBox distro is
# kept; delete it with: wsl --unregister ClaudeBox (deletes everything in it).
$ErrorActionPreference = 'Stop'
$plugin = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'plugin.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $plugin remove claude claude-main claude-windows
