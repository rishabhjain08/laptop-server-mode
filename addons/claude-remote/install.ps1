# Claude Remote add-on, from PowerShell: sets up Claude on Windows (no WSL
# needed). Install Laptop Server Mode first (..\..\install.ps1).
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
# ClaudeBox and Claude in a WSL distro need WSL: run install.sh from WSL.
# Re-run to update; your plugin settings are kept.
$ErrorActionPreference = 'Stop'
$plugin = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'plugin.ps1'
function Run-Plugin { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $plugin @args; if ($LASTEXITCODE) { throw "plugin.ps1 $args failed" } }

Write-Host '==> Installing Claude on Windows'
Run-Plugin add (Join-Path $PSScriptRoot 'plugins\claude-windows')
Run-Plugin enable claude-windows

$exe = @((Get-Command claude.exe -ErrorAction SilentlyContinue).Source, "$env:USERPROFILE\.local\bin\claude.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
Write-Host '==> Done. First time only, in PowerShell:'
if (-not $exe) { Write-Host '    1. Install Claude Code: irm https://claude.ai/install.ps1 | iex' }
Write-Host "    - Sign in, and trust the folder Claude works in (default $env:USERPROFILE\Claude):"
Write-Host "        mkdir `"$env:USERPROFILE\Claude`" -Force; cd `"$env:USERPROFILE\Claude`"; claude"
Write-Host '      (log in if asked, accept the trust prompt, then /exit)'
Write-Host '    - Switch Remote Control on once: claude remote-control   (answer y, wait for Ready, then Ctrl+C)'
Write-Host '    The tray shows "Needs setup" until then; hover it for the next step.'
Write-Host '    Settings (folder, permissionMode, name): see addons\claude-remote\README.md.'

$wsl = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue).Count
if ($wsl) { Write-Host '    ClaudeBox (isolated) and Claude in your WSL distro: run addons/claude-remote/install.sh from WSL.' }
