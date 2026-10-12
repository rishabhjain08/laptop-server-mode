# Claude Code with Remote Control on Windows, no WSL needed. Runs as you, in
# server mode: `claude remote-control` runs hidden, and the Claude app starts
# sessions on demand in the folder below.
# It has your full Windows access, so it is off by default (turn it on in the
# tray flyout) and permissions default to asking on your phone.
#
# Settings (plugin.json defaults, your settings.json overrides):
#   folder          where sessions work (default %USERPROFILE%\Claude, created
#                   if missing); must be trusted: run `claude` there once
#   permissionMode  default (asks on your phone), acceptEdits, auto, plan,
#                   dontAsk, or bypassPermissions (full access: think twice)
#   name            name in the Claude app (empty: Claude's default)
# Usage: claude-windows.ps1 start|check|stop. Windows PowerShell 5.1, ASCII.
param([string]$Verb)
$ErrorActionPreference = 'Stop'

$root = Split-Path (Split-Path $env:LSM_PLUGIN_DIR -Parent) -Parent   # the app's folder
$pidFile = Join-Path $root 'run\claude-windows.pid'
$log = Join-Path $root 'logs\claude-windows.log'
$folder = if ($env:LSM_SETTING_FOLDER) { $env:LSM_SETTING_FOLDER } else { '%USERPROFILE%\Claude' }
$folder = [Environment]::ExpandEnvironmentVariables($folder)
$perm = if ($env:LSM_SETTING_PERMISSION_MODE) { $env:LSM_SETTING_PERMISSION_MODE } else { 'default' }
$name = [string]$env:LSM_SETTING_NAME
$sig = "$perm|$name|$folder"   # what the running server was started with

function Find-Claude {
    $c = Get-Command claude.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in "$env:USERPROFILE\.local\bin\claude.exe", "$env:APPDATA\npm\claude.cmd") {
        if (Test-Path $p) { return $p }
    }
    $null
}

# The running server (its cmd.exe), checked by PID and start time.
function Get-Server {
    if (-not (Test-Path $pidFile)) { return $null }
    $id, $ticks, $s = (Get-Content $pidFile -Raw).Trim() -split ' ', 3
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.StartTime.Ticks -eq [long]$ticks) { return [pscustomobject]@{ Process = $p; Sig = $s } }
    $null
}

function Stop-Server {
    $s = Get-Server
    if ($s) { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /T /F /PID $s.Process.Id 2>&1 | Out-Null }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}

# What the server wrote to its log after byte $From.
function Read-LogSince([long]$From) {
    try {
        $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
        try { [void]$fs.Seek($From, 'Begin'); (New-Object IO.StreamReader $fs).ReadToEnd() } finally { $fs.Close() }
    } catch { '' }
}

# Starts the server hidden and watches its first seconds: an untrusted folder
# makes it exit, and the first run waits for "Enable Remote Control? (y/n)".
# State: ok (running), setup (a person must act; Why says how), failed.
function Start-Claude([string]$Command) {
    $from = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
    $p = Start-Process cmd.exe -ArgumentList "/d /c `"$Command >> `"$log`" 2>&1`"" -WorkingDirectory $folder -WindowStyle Hidden -PassThru
    "$($p.Id) $($p.StartTime.Ticks) $sig" | Set-Content $pidFile -Encoding ASCII
    $out = ''
    for ($i = 0; $i -lt 20 -and -not $p.HasExited -and $out -notmatch 'Ready|Enable Remote Control\?'; $i++) {
        Start-Sleep -Seconds 1
        $out = Read-LogSince $from
    }
    $out = Read-LogSince $from
    if (-not $p.HasExited -and $out -match 'Enable Remote Control\?' -and $out -notmatch 'Ready') {
        Stop-Server
        return @{ State = 'setup'; Why = "Remote Control isn't switched on for Claude on Windows yet. In PowerShell run: cd `"$folder`"; claude remote-control   (answer y, wait for Ready, then press Ctrl+C)" }
    }
    if (-not $p.HasExited) { return @{ State = 'ok' } }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    if ($out -match 'not trusted') {
        return @{ State = 'setup'; Why = "Folder $folder isn't trusted yet. In PowerShell run: cd `"$folder`"; claude   (accept the trust prompt, then /exit)" }
    }
    @{ State = 'failed'; Why = 'Claude exited: ' + (($out.Trim() -split "`n" | Select-Object -Last 3) -join ' ') }
}

# Exit 3: needs one-time setup by a person. The tray shows the reason.
function Exit-NeedsSetup([string]$Why) { Write-Output $Why; exit 3 }

switch ($Verb) {
    'start' {
        if (Get-Server) { exit 0 }
        $exe = Find-Claude
        if (-not $exe) { Exit-NeedsSetup 'Claude Code is not installed on Windows. Install it in PowerShell: irm https://claude.ai/install.ps1 | iex' }
        if ($perm -notin 'default', 'acceptEdits', 'auto', 'bypassPermissions', 'dontAsk', 'plan') {
            Exit-NeedsSetup "Setting permissionMode '$perm' isn't one of: default, acceptEdits, auto, bypassPermissions, dontAsk, plan."
        }
        if ($name -match '[^A-Za-z0-9._-]') { Exit-NeedsSetup "Setting name may only use letters, digits, '.', '_' and '-'." }
        $auth = (& $exe auth status 2>&1 | Out-String)
        if ($auth -notmatch '"loggedIn":\s*true') { Exit-NeedsSetup 'Claude is not signed in on Windows. In PowerShell run: claude   (then /login)' }

        New-Item -ItemType Directory -Force $folder, (Split-Path $pidFile), (Split-Path $log) | Out-Null
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
        $cmd = "`"$exe`" remote-control --permission-mode $perm" + $(if ($name) { " --name $name" } else { '' })
        # Reattach to the same server in the app if this folder had one (Claude
        # allows about 4 hours; if that fails right away, register a new one).
        $pointer = Join-Path $env:USERPROFILE ('.claude\projects\' + ($folder -replace '[^A-Za-z0-9]', '-') + '\bridge-pointer.json')
        $tries = if (Test-Path $pointer) { "$cmd --continue", $cmd } else { , $cmd }
        foreach ($try in $tries) {
            $r = Start-Claude $try
            if ($r.State -eq 'ok') { exit 0 }
            if ($r.State -eq 'setup') { Exit-NeedsSetup $r.Why }
        }
        # Claude's record of the last server here blocks a new one. If that
        # server is gone, the record is stale: drop it and start fresh.
        if ($r.Why -match 'already served' -and (Test-Path $pointer)) {
            $old = try { (Get-Content $pointer -Raw | ConvertFrom-Json).pid } catch { $null }
            if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
                Exit-NeedsSetup "Another claude remote-control (PID $old) already serves $folder. Stop it, or set a different folder."
            }
            Remove-Item $pointer
            $r = Start-Claude $cmd
            if ($r.State -eq 'ok') { exit 0 }
            if ($r.State -eq 'setup') { Exit-NeedsSetup $r.Why }
        }
        Write-Output $r.Why
        exit 1
    }
    'check' {
        $s = Get-Server
        if (-not $s) { exit 1 }
        # Settings changed since start: restart with the new ones.
        if ($s.Sig -ne $sig) { Stop-Server; Write-Output 'Settings changed; restarting Claude'; exit 1 }
    }
    'stop' { Stop-Server }
    default { Write-Output 'usage: claude-windows.ps1 start|check|stop'; exit 2 }
}
exit 0
