# Plugins: the things Laptop Server Mode runs for you. Dot-sourced by
# ServerMode.psm1. Windows PowerShell 5.1 compatible, ASCII-only.
#
# A plugin is a folder in plugins\ with a plugin.json (see README):
#   run     command to keep running (a simple service)
#   script  file called with start | check | stop (a service with full control)
#   on      { "<event>": "<command>" } hooks
# plus name, title, runsIn (wsl | windows), wslDistro, wslUser,
# enabledByDefault, stopWhenServerModeOff, and settings (defaults that the
# user overrides in the plugin's settings.json; passed as LSM_SETTING_*).
#
# WSL is optional: plugins that run in WSL report "needs setup" when WSL or
# their distro isn't installed, and everything else keeps working.

$script:PluginDir = Join-Path $Root 'plugins'
$script:HookEvents = 'boot', 'server-on', 'server-off', 'server-paused', 'service-failed', 'shutdown'
$script:Wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$script:BadPlugins = @{}
$script:WslCache = $null
$script:WslCacheAt = [datetime]::MinValue

# Keeps a `run` command alive in WSL. Double-forked (setsid -f) so it
# outlives the wsl.exe call that started it, like a daemon.
$script:WslRunner = @'
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/laptop-server-mode
PIDF=$STATE/$LSM_PLUGIN.pid
alive() { [ -s "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; }
case "$1" in
  start)
    alive && exit 0
    mkdir -p "$STATE"
    cd "$LSM_PLUGIN_DIR" 2>/dev/null || cd ~
    setsid -f bash -c 'echo $$ > "$0"; exec bash -lc "$LSM_RUN"' "$PIDF" >>"$STATE/$LSM_PLUGIN.log" 2>&1 </dev/null
    ;;
  check) alive ;;
  stop) alive && kill -- -"$(cat "$PIDF")"; rm -f "$PIDF"; true ;;
esac
'@

function Get-Plugins {
    if (-not (Test-Path $PluginDir)) { return }
    foreach ($d in Get-ChildItem $PluginDir -Directory) {
        $file = Join-Path $d.FullName 'plugin.json'
        if (-not (Test-Path $file)) { continue }
        try {
            $p = Get-Content $file -Raw | ConvertFrom-Json
            if (-not $p.PSObject.Properties['name']) { throw 'missing "name"' }
            if ($p.PSObject.Properties['run'] -and $p.PSObject.Properties['script']) { throw 'use "run" or "script", not both' }
        } catch {
            if (-not $BadPlugins[$file]) { Write-Log "Skipping plugin $($d.Name): $_" }
            $BadPlugins[$file] = $true
            continue
        }
        $BadPlugins.Remove($file)
        $defaults = [ordered]@{
            title = $p.name; runsIn = 'wsl'; wslDistro = $null; wslUser = $null; run = $null; script = $null
            on = $null; enabledByDefault = $true; stopWhenServerModeOff = $false; settings = $null
        }
        foreach ($k in $defaults.Keys) { if (-not $p.PSObject.Properties[$k]) { $p | Add-Member $k $defaults[$k] } }
        $p | Add-Member -Force dir $d.FullName
        $p | Add-Member -Force isService ([bool]($p.run -or $p.script))
        $p
    }
}

# Plugins that provide a service (shown in the tray, kept running).
function Get-Services { Get-Plugins | Where-Object isService }

function Test-ServiceEnabled {
    param($Service, $State)
    $p = $State.services.PSObject.Properties[$Service.name]
    if ($p) { [bool]$p.Value } else { [bool]$Service.enabledByDefault }
}

# Installed WSL distros and the default one. Read from the registry WSL
# itself uses, so it's cheap and safe when WSL isn't installed; falls back to
# `wsl --list` if the registry can't be read. Cached for 30 seconds.
function Get-WslDistros {
    if ($WslCache -and ((Get-Date) - $WslCacheAt).TotalSeconds -lt 30) { return $WslCache }
    $r = [pscustomobject]@{ names = @(); default = $null }
    if (Test-Path $Wsl) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        $def = (Get-ItemProperty $key -ErrorAction SilentlyContinue).DefaultDistribution
        foreach ($k in @(Get-ChildItem $key -ErrorAction SilentlyContinue)) {
            $n = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).DistributionName
            if (-not $n) { continue }
            $r.names += $n
            if ($k.PSChildName -eq $def) { $r.default = $n }
        }
        if (-not $r.names) {
            $l = Invoke-Hidden $Wsl '--list --quiet' -TimeoutSec 20
            if ($l.Code -eq 0) { $r.names = @($l.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            if ($r.names) { $r.default = $r.names[0] }   # `wsl --list` puts the default first
        }
    }
    $script:WslCache = $r; $script:WslCacheAt = Get-Date
    $r
}

# The distro a WSL plugin runs in: its own wslDistro, else config.json's,
# else Windows' default distro.
function Get-PluginDistro {
    param($Plugin)
    if ($Plugin.wslDistro) { return $Plugin.wslDistro }
    $c = (Get-Config).wslDistro
    if ($c) { return $c }
    (Get-WslDistros).default
}

# Why a plugin can't run on this PC (a sentence for the log and the tray),
# or $null when it can.
function Get-PluginProblem {
    param($Plugin)
    if ($Plugin.runsIn -eq 'wsl') {
        $w = Get-WslDistros
        if (-not $w.names) { return 'WSL is not installed (or has no Linux distro). Install WSL, or use a plugin that runs on Windows.' }
        $d = Get-PluginDistro $Plugin
        if ($d -and $w.names -notcontains $d) { return "WSL distro '$d' is not installed. Installed: $($w.names -join ', ')." }
    } elseif ($Plugin.runsIn -ne 'windows') {
        return "runsIn must be 'wsl' or 'windows', not '$($Plugin.runsIn)'."
    }
    if ($Plugin.script -and -not (Test-Path (Join-Path $Plugin.dir $Plugin.script))) {
        return "Its script '$($Plugin.script)' is missing from the plugin folder."
    }
    $null
}

# A plugin's settings: the defaults in plugin.json's "settings", overridden
# by the user's settings.json in the plugin folder (kept when the plugin is
# updated). Returned as LSM_SETTING_<NAME> environment variables, e.g.
# "permissionMode" becomes LSM_SETTING_PERMISSION_MODE.
function Get-PluginSettings {
    param($Plugin)
    $s = [ordered]@{}
    if ($Plugin.settings) { foreach ($p in $Plugin.settings.PSObject.Properties) { $s[$p.Name] = $p.Value } }
    $file = Join-Path $Plugin.dir 'settings.json'
    if (Test-Path $file) {
        try {
            $u = Get-Content $file -Raw | ConvertFrom-Json
            if ($u) { foreach ($p in $u.PSObject.Properties) { $s[$p.Name] = $p.Value } }
            $BadPlugins.Remove($file)
        } catch {
            if (-not $BadPlugins[$file]) { Write-Log "[$($Plugin.name)] settings.json is invalid, using the defaults: $_" }
            $BadPlugins[$file] = $true
        }
    }
    $vars = [ordered]@{}
    foreach ($k in $s.Keys) {
        $name = 'LSM_SETTING_' + (($k -creplace '([a-z0-9])([A-Z])', '${1}_${2}') -replace '[^A-Za-z0-9]', '_').ToUpper()
        $v = $s[$k]
        $vars[$name] = if ($v -is [bool]) { "$v".ToLower() } elseif ($null -eq $v) { '' } elseif ($v -is [string] -or $v -is [ValueType]) { [string]$v } else { $v | ConvertTo-Json -Compress -Depth 5 }
    }
    $vars
}

function ConvertTo-WslPath {
    param([string]$Path)
    '/mnt/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

function Invoke-Hidden {
    param([string]$File, [string]$Arguments, [int]$TimeoutSec = 60, [string]$InputText)
    $psi = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = [bool]$InputText
    $p = [Diagnostics.Process]::Start($psi)
    if ($InputText) { $p.StandardInput.Write($InputText); $p.StandardInput.Close() }
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); return [pscustomobject]@{ Code = -1; Output = 'timeout' } }
    [pscustomobject]@{ Code = $p.ExitCode; Output = (($out.Result + $err.Result) -replace "`0", '').Trim() }
}

# Runs code in the plugin's environment: bash piped into its WSL distro
# (works in distros that can't see Windows files), or PowerShell on Windows.
# $Env becomes LSM_* environment variables.
function Invoke-PluginCode {
    param($Plugin, [string]$Code, [string[]]$Arguments = @(), [hashtable]$Env = @{}, [int]$TimeoutSec = 60)
    $vars = [ordered]@{ LSM_PLUGIN = $Plugin.name }
    $settings = Get-PluginSettings $Plugin
    foreach ($k in $settings.Keys) { $vars[$k] = $settings[$k] }
    foreach ($k in $Env.Keys) { $vars[$k] = [string]$Env[$k] }
    if ($Plugin.runsIn -eq 'wsl') {
        $vars['LSM_PLUGIN_DIR'] = ConvertTo-WslPath $Plugin.dir
        $head = foreach ($k in $vars.Keys) { "export $k='" + ($vars[$k] -replace "'", "'\''") + "'" }
        $text = (($head -join "`n") + "`n" + $Code) -replace "`r`n", "`n"
        $user = if ($Plugin.wslUser) { "-u $($Plugin.wslUser) " } else { '' }
        # wsl.exe does not strip quotes from -d; distro names never contain spaces.
        $distro = Get-PluginDistro $Plugin
        $d = if ($distro) { "-d $distro " } else { '' }   # none set: the default distro
        Invoke-Hidden $Wsl "$d$user--cd / -- bash -s -- $($Arguments -join ' ')" -TimeoutSec $TimeoutSec -InputText $text
    } else {
        $vars['LSM_PLUGIN_DIR'] = $Plugin.dir
        $head = foreach ($k in $vars.Keys) { "`$env:$k = '" + ($vars[$k] -replace "'", "''") + "'" }
        $text = "`$ProgressPreference = 'SilentlyContinue'`n" + ($head -join "`n") + "`nSet-Location -LiteralPath '$($Plugin.dir -replace "'", "''")'`n" + $Code
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
        Invoke-Hidden 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" -TimeoutSec $TimeoutSec
    }
}

# Windows `run` services: started hidden, tracked by PID and start time.
function Invoke-WindowsRun {
    param($Service, [string]$Verb)
    $runDir = Join-Path $Root 'run'
    $pidFile = Join-Path $runDir "$($Service.name).pid"
    $proc = $null
    if (Test-Path $pidFile) {
        $id, $ticks = (Get-Content $pidFile -Raw).Trim() -split ' '
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($proc -and $proc.StartTime.Ticks -ne [long]$ticks) { $proc = $null }
    }
    $code = 0
    switch ($Verb) {
        'start' {
            if (-not $proc) {
                New-Item -ItemType Directory -Force $runDir, $LogDir | Out-Null
                $log = Join-Path $LogDir "$($Service.name).log"
                # The command inherits these (set here only for the start).
                $vars = Get-PluginSettings $Service
                $vars['LSM_PLUGIN'] = $Service.name; $vars['LSM_PLUGIN_DIR'] = $Service.dir
                foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $vars[$k], 'Process') }
                try {
                    $p = Start-Process cmd.exe -ArgumentList "/d /c $($Service.run) >> `"$log`" 2>&1" `
                        -WorkingDirectory $Service.dir -WindowStyle Hidden -PassThru
                } finally {
                    foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
                }
                "$($p.Id) $($p.StartTime.Ticks)" | Set-Content $pidFile -Encoding ASCII
            }
        }
        'check' { if (-not $proc) { $code = 1 } }
        'stop'  {
            if ($proc) { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /T /F /PID $proc.Id 2>&1 | Out-Null }
            Remove-Item $pidFile -ErrorAction SilentlyContinue
        }
    }
    [pscustomobject]@{ Code = $code; Output = '' }
}

# Runs a service verb: start | check | stop (check exits 0 when healthy).
function Invoke-ServiceVerb {
    param($Service, [string]$Verb)
    if ($Service.run) {
        if ($Service.runsIn -eq 'wsl') { return Invoke-PluginCode $Service $WslRunner @($Verb) @{ LSM_RUN = $Service.run } }
        return Invoke-WindowsRun $Service $Verb
    }
    $path = Join-Path $Service.dir $Service.script
    if ($Service.runsIn -eq 'wsl') { return Invoke-PluginCode $Service ([IO.File]::ReadAllText($path)) @($Verb) }
    Invoke-PluginCode $Service "& '$($path -replace "'", "''")' $Verb; exit `$LASTEXITCODE"
}

# The hook events one watchdog round fires: "boot" once per Windows boot, and
# server-on / server-off / server-paused when server mode changed state since
# the last round (whoever changed it). Each event is @(name, extra env vars).
function Get-HookEvents {
    param($State, [string]$Boot)
    $names  = @{ on = 'server-on'; battery = 'server-paused'; off = 'server-off' }
    $states = @{ on = 'on'; battery = 'paused'; off = 'off' }
    $events = @()
    if ($State.lastBoot -ne $Boot) { $events += ,@('boot', @{}) }
    if ($State.hookReason -and $State.hookReason -ne $State.reason) {
        $events += ,@($names[[string]$State.reason], @{ LSM_PREVIOUS = $states[[string]$State.hookReason] })
    }
    ,$events
}

# Runs every enabled plugin's hook for $Event, one after another.
function Invoke-Hooks {
    param([string]$Event, [hashtable]$Env = @{}, [int]$TimeoutSec = 60)
    $state = Get-State
    $power = Get-PowerStatus
    $vars = @{
        LSM_EVENT = $Event; LSM_BATTERY = $power.percent; LSM_ON_AC = [int]$power.onAC
        LSM_STATE = @{ on = 'on'; battery = 'paused'; off = 'off' }[[string]$state.reason]
    }
    foreach ($k in $Env.Keys) { $vars[$k] = $Env[$k] }
    foreach ($p in @(Get-Plugins)) {
        if (-not $p.on -or -not $p.on.PSObject.Properties[$Event]) { continue }
        if (-not (Test-ServiceEnabled $p $state)) { continue }
        $problem = Get-PluginProblem $p
        if ($problem) { Write-Log "[$($p.name)] $Event hook skipped: $problem" 'hooks'; continue }
        $cmd = $p.on.$Event
        if ($p.runsIn -eq 'wsl') {
            # Login shell in the plugin folder, like `run` commands.
            $vars['LSM_HOOK'] = $cmd
            $cmd = 'cd "$LSM_PLUGIN_DIR" 2>/dev/null || cd ~' + "`n" + 'exec bash -lc "$LSM_HOOK"'
        }
        $r = Invoke-PluginCode $p $cmd -Env $vars -TimeoutSec $TimeoutSec
        $out = if ($r.Output) { ": $($r.Output)" } else { '' }
        Write-Log "[$($p.name)] $Event hook (exit $($r.Code))$out" 'hooks'
    }
}

# Sets a service's status; running and stopped clear the failure counters.
# $Detail is the reason shown in the tray (needs-setup, failing).
function Set-ServiceStatus {
    param($St, [string]$Status, [string]$Detail = $null)
    $St.status = $Status
    if ($Status -in 'running', 'stopped', 'needs-setup') { $St.failures = 0; $St.retryAt = $null }
    $St | Add-Member -Force detail $(if ($Detail) { $Detail } else { $null })
}

# The WSL distros to keep running: those of WSL services that should be
# running now (enabled, and server mode ON unless the service keeps running
# when it's OFF) and can run here. WSL stops a distro when no Windows process
# holds it open, so the watchdog holds these.
function Get-HeldDistros {
    param($State)
    $held = [ordered]@{}
    foreach ($svc in @(Get-Services)) {
        if ($svc.runsIn -ne 'wsl' -or -not (Test-ServiceEnabled $svc $State)) { continue }
        if (-not $State.enabled -and $svc.stopWhenServerModeOff) { continue }
        if (Get-PluginProblem $svc) { continue }
        $d = Get-PluginDistro $svc
        if ($d) { $held[$d] = $true }
    }
    @($held.Keys)
}

# Keeps enabled services running while server mode is ON. Retries a failing
# service with growing gaps (1, 2, 4 ... 30 min) so a broken one doesn't spin.
function Sync-Services {
    param($State)
    $now = Get-Date
    $services = @(Get-Services)
    # Forget the status of services whose plugin was removed.
    foreach ($p in @($State.serviceStatus.PSObject.Properties)) {
        if (@($services | Where-Object name -eq $p.Name).Count -eq 0) { $State.serviceStatus.PSObject.Properties.Remove($p.Name) }
    }
    foreach ($svc in $services) {
        $name   = $svc.name
        $prev   = $State.serviceStatus.PSObject.Properties[$name]
        $st     = if ($prev) { $prev.Value } else { [pscustomobject]@{ status = 'stopped'; failures = 0; retryAt = $null } }
        $wanted = $State.enabled -and (Test-ServiceEnabled $svc $State)

        # Can't run on this PC (e.g. no WSL): say why, once, and don't retry.
        $problem = Get-PluginProblem $svc
        if ($problem) {
            if ($wanted -and ($st.status -ne 'needs-setup' -or $st.detail -ne $problem)) { Write-Log "[$name] needs setup: $problem" }
            Set-ServiceStatus $st $(if ($wanted) { 'needs-setup' } else { 'stopped' }) $problem
            $State.serviceStatus | Add-Member -Force $name $st
            continue
        }

        if (-not $wanted) {
            $stopIt = -not (Test-ServiceEnabled $svc $State) -or $svc.stopWhenServerModeOff
            if ($stopIt -and $st.status -ne 'stopped') {
                $r = Invoke-ServiceVerb $svc 'stop'
                Write-Log "[$name] stopped (exit $($r.Code)) $($r.Output)"
                Set-ServiceStatus $st 'stopped'
            } elseif (-not $stopIt) {
                Set-ServiceStatus $st $(if ((Invoke-ServiceVerb $svc 'check').Code -eq 0) { 'running' } else { 'stopped' })
            }
        } elseif (($chk = Invoke-ServiceVerb $svc 'check').Code -eq 0) {
            if ($st.status -ne 'running') { Write-Log "[$name] running" }
            if ($chk.Output) { Write-Log "[$name] $($chk.Output)" }   # a healthy check may report what it fixed
            Set-ServiceStatus $st 'running'
        } elseif (-not $st.retryAt -or $now -ge [datetime]$st.retryAt) {
            if ($chk.Output) { Write-Log "[$name] $($chk.Output)" }   # why the check failed, e.g. settings changed
            $r = Invoke-ServiceVerb $svc 'start'
            if ($r.Code -eq 3) {
                # Needs one-time setup by a person; check again in a minute, quietly.
                if ($st.status -ne 'needs-setup') { Write-Log "[$name] needs setup: $($r.Output)" }
                Set-ServiceStatus $st 'needs-setup' $r.Output
                $st.retryAt = $now.AddMinutes(1).ToString('o')
                $State.serviceStatus | Add-Member -Force $name $st
                continue
            }
            Start-Sleep -Seconds 3
            if ((Invoke-ServiceVerb $svc 'check').Code -eq 0) {
                Write-Log "[$name] started"
                Set-ServiceStatus $st 'running'
            } else {
                $st.failures = [int]$st.failures + 1
                $wait = [math]::Min(30, [math]::Pow(2, $st.failures - 1))
                $st.status = 'failing'; $st.retryAt = $now.AddMinutes($wait).ToString('o')
                $st | Add-Member -Force detail $(if ($r.Output) { "$($r.Output)" } else { "Exit code $($r.Code)" })
                Write-Log "[$name] failed to start (try $($st.failures), next in $wait min): exit $($r.Code) $($r.Output)"
                if ($st.failures -eq 1) { Invoke-Hooks 'service-failed' @{ LSM_SERVICE = $name } }
            }
        }
        $State.serviceStatus | Add-Member -Force $name $st
    }
}

# Kill switch: disables every service and stops it immediately. Services in
# their own distro are stopped by shutting that distro down.
function Stop-AllServices {
    $conf = Get-Config
    $default = if ($conf.wslDistro) { $conf.wslDistro } else { (Get-WslDistros).default }
    foreach ($svc in @(Get-Services)) {
        Set-ServiceEnabled $svc.name $false
        if (Get-PluginProblem $svc) { continue }   # can't be running
        $own = $svc.runsIn -eq 'wsl' -and $svc.wslDistro -and $svc.wslDistro -ne $default
        if ($own) { $r = Invoke-Hidden $Wsl "--terminate $($svc.wslDistro)" } else { $r = Invoke-ServiceVerb $svc 'stop' }
        Write-Log "[$($svc.name)] emergency stop (exit $($r.Code))" 'tray'
    }
    Update-State {
        param($s)
        foreach ($p in @($s.serviceStatus.PSObject.Properties)) { $p.Value.status = 'stopped' }
        $s
    } | Out-Null
}
