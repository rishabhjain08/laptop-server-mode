# Plugins: the things Laptop Server Mode runs for you. Dot-sourced by
# ServerMode.psm1. Windows PowerShell 5.1 compatible, ASCII-only.
#
# A plugin is a folder in plugins\ with a plugin.json (see README):
#   run     command to keep running (a simple service)
#   script  file called with start | check | stop (a service with full control)
#   on      { "<event>": "<command>" } hooks
# plus name, title, runsIn (wsl | windows), wslDistro, wslUser,
# enabledByDefault, stopWhenServerModeOff.

$script:PluginDir = Join-Path $Root 'plugins'
$script:HookEvents = 'boot', 'server-on', 'server-off', 'server-paused', 'service-failed', 'shutdown'
$script:Wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$script:BadPlugins = @{}

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
            on = $null; enabledByDefault = $true; stopWhenServerModeOff = $false
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

function Get-PluginDistro {
    param($Plugin)
    if ($Plugin.wslDistro) { $Plugin.wslDistro } else { (Get-Config).wslDistro }
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
    foreach ($k in $Env.Keys) { $vars[$k] = [string]$Env[$k] }
    if ($Plugin.runsIn -eq 'wsl') {
        $vars['LSM_PLUGIN_DIR'] = ConvertTo-WslPath $Plugin.dir
        $head = foreach ($k in $vars.Keys) { "export $k='" + ($vars[$k] -replace "'", "'\''") + "'" }
        $text = (($head -join "`n") + "`n" + $Code) -replace "`r`n", "`n"
        $user = if ($Plugin.wslUser) { "-u $($Plugin.wslUser) " } else { '' }
        # wsl.exe does not strip quotes from -d; distro names never contain spaces.
        Invoke-Hidden $Wsl "-d $(Get-PluginDistro $Plugin) $user--cd / -- bash -s -- $($Arguments -join ' ')" -TimeoutSec $TimeoutSec -InputText $text
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
                $p = Start-Process cmd.exe -ArgumentList "/d /c $($Service.run) >> `"$log`" 2>&1" `
                    -WorkingDirectory $Service.dir -WindowStyle Hidden -PassThru
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

        if (-not $wanted) {
            $stopIt = -not (Test-ServiceEnabled $svc $State) -or $svc.stopWhenServerModeOff
            if ($stopIt -and $st.status -ne 'stopped') {
                $r = Invoke-ServiceVerb $svc 'stop'
                Write-Log "[$name] stopped (exit $($r.Code)) $($r.Output)"
                $st.status = 'stopped'; $st.failures = 0; $st.retryAt = $null
            } elseif (-not $stopIt) {
                $st.status = if ((Invoke-ServiceVerb $svc 'check').Code -eq 0) { 'running' } else { 'stopped' }
            }
        } elseif (($chk = Invoke-ServiceVerb $svc 'check').Code -eq 0) {
            if ($st.status -ne 'running') { Write-Log "[$name] running" }
            if ($chk.Output) { Write-Log "[$name] $($chk.Output)" }   # a healthy check may report what it fixed
            $st.status = 'running'; $st.failures = 0; $st.retryAt = $null
        } elseif (-not $st.retryAt -or $now -ge [datetime]$st.retryAt) {
            $r = Invoke-ServiceVerb $svc 'start'
            if ($r.Code -eq 3) {
                # Needs one-time setup by a person; check again in a minute, quietly.
                if ($st.status -ne 'needs-setup') { Write-Log "[$name] needs setup: $($r.Output)" }
                $st.status = 'needs-setup'; $st.retryAt = $now.AddMinutes(1).ToString('o')
                $State.serviceStatus | Add-Member -Force $name $st
                continue
            }
            Start-Sleep -Seconds 3
            if ((Invoke-ServiceVerb $svc 'check').Code -eq 0) {
                Write-Log "[$name] started"
                $st.status = 'running'; $st.failures = 0; $st.retryAt = $null
            } else {
                $st.failures = [int]$st.failures + 1
                $wait = [math]::Min(30, [math]::Pow(2, $st.failures - 1))
                $st.status = 'failing'; $st.retryAt = $now.AddMinutes($wait).ToString('o')
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
    foreach ($svc in @(Get-Services)) {
        Set-ServiceEnabled $svc.name $false
        $own = $svc.runsIn -eq 'wsl' -and $svc.wslDistro -and $svc.wslDistro -ne $conf.wslDistro
        if ($own) { $r = Invoke-Hidden $Wsl "--terminate $($svc.wslDistro)" } else { $r = Invoke-ServiceVerb $svc 'stop' }
        Write-Log "[$($svc.name)] emergency stop (exit $($r.Code))" 'tray'
    }
    Update-State {
        param($s)
        foreach ($p in @($s.serviceStatus.PSObject.Properties)) { $p.Value.status = 'stopped' }
        $s
    } | Out-Null
}
