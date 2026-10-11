# Core of Laptop Server Mode: state, power override, battery rule, services.
# Windows PowerShell 5.1 compatible. Keep this file ASCII-only.

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Root      = $PSScriptRoot
$script:StatePath = Join-Path $Root 'state.json'
$script:ConfPath  = Join-Path $Root 'config.json'
$script:LockPath  = Join-Path $Root 'state.lock'
$script:LogDir    = Join-Path $Root 'logs'
$script:PowerCfg  = Join-Path $env:SystemRoot 'System32\powercfg.exe'
$script:PlanName  = 'Laptop Server Mode - temporary'
$script:Balanced  = '381b4222-f694-41f0-9685-ff5bb260df2e'

# Settings the temporary plan overrides (AC and DC). Everything else is
# copied from whatever plan was active when server mode was turned on.
$script:Overrides = @(
    @('SUB_BUTTONS', 'LIDACTION'),                                # lid close: do nothing
    @('SUB_SLEEP',   'STANDBYIDLE'),                              # sleep after: never
    @('SUB_SLEEP',   'HIBERNATEIDLE'),                            # hibernate after: never
    @('SUB_SLEEP',   '7bc4a2f9-d8fc-4469-b07b-33eb785aaca0')      # unattended sleep timeout: never
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace LSM -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
'@

# ---------------------------------------------------------------- logging

function Write-Log {
    param([string]$Message, [string]$Name = 'watchdog')
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $file = Join-Path $LogDir "$Name.log"
    if ((Test-Path $file) -and (Get-Item $file).Length -gt 1MB) {
        Move-Item $file "$file.old" -Force
    }
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -Path $file -Value $line -Encoding ASCII
}

# ---------------------------------------------------------------- config + state

function Get-Config {
    $conf = [ordered]@{ batteryLimit = 35; pollSeconds = 15; wslDistro = ''; wslRoot = '' }
    if (Test-Path $ConfPath) {
        $json = Get-Content $ConfPath -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $conf[$p.Name] = $p.Value }
    }
    [pscustomobject]$conf
}

function New-State {
    [pscustomobject]@{
        enabled = $false; ignoreBatteryLimit = $false; services = [pscustomobject]@{}
        active = $false; reason = 'off'; originalPlan = $null; serverPlan = $null
        battery = $null; onAC = $true; serviceStatus = [pscustomobject]@{}; heartbeat = $null
    }
}

function Read-StateFile {
    $s = New-State
    if (Test-Path $StatePath) {
        try {
            $json = Get-Content $StatePath -Raw | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $s | Add-Member -Force $p.Name $p.Value }
        } catch { Write-Log "state.json unreadable, starting fresh: $_" }
    }
    $s
}

# Runs $Body with exclusive access to state.json and saves what it returns.
# A lock file (not a mutex) so the boot task and the tray can share it
# across Windows sessions.
function Update-State {
    param([scriptblock]$Body)
    $lock = $null
    for ($i = 0; $i -lt 100 -and -not $lock; $i++) {
        try { $lock = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if (-not $lock) { throw 'Could not lock state file' }
    try {
        $state = Read-StateFile
        $state = & $Body $state
        $tmp = "$StatePath.tmp"
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding ASCII
        Move-Item $tmp $StatePath -Force
        $state
    } finally { $lock.Dispose() }
}

function Get-State { Read-StateFile }

function Set-ServerMode {
    param([bool]$On, [switch]$IgnoreBatteryLimit)
    Update-State {
        param($s)
        $s.enabled = $On
        $s.ignoreBatteryLimit = [bool]$IgnoreBatteryLimit
        $s
    } | Out-Null
    Sync-ServerMode -Source tray | Out-Null
}

function Set-ServiceEnabled {
    param([string]$Name, [bool]$On)
    Update-State {
        param($s)
        $s.services | Add-Member -Force $Name $On
        $s
    } | Out-Null
}

# ---------------------------------------------------------------- power

function Get-PowerStatus {
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    $noBattery = ($ps.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) -ne 0
    [pscustomobject]@{
        onAC      = $noBattery -or ($ps.PowerLineStatus -eq 'Online')
        percent   = if ($noBattery) { 100 } else { [int][math]::Round($ps.BatteryLifePercent * 100) }
        noBattery = $noBattery
    }
}

function Invoke-PowerCfg {
    param([string[]]$Arguments)
    $out = & $PowerCfg @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "powercfg $($Arguments -join ' ') failed: $out" }
    ($out | Out-String)
}

function Get-PowerPlans {
    $list = Invoke-PowerCfg @('/list')
    foreach ($m in [regex]::Matches($list, '([0-9a-fA-F-]{36})\s+\((.+?)\)(\s*\*)?')) {
        [pscustomobject]@{
            Guid   = $m.Groups[1].Value.ToLower()
            Name   = $m.Groups[2].Value
            Active = $m.Groups[3].Success
        }
    }
}

function Enable-PowerOverride {
    param($State)
    $plans  = @(Get-PowerPlans)
    $active = $plans | Where-Object Active | Select-Object -First 1
    if ($State.serverPlan -and $active -and $active.Guid -eq $State.serverPlan) { return }

    # Base the temporary plan on the user's current plan, never on an old copy of ours.
    $base = $active.Guid
    if ($active.Name -eq $PlanName) {
        $base = if ($State.originalPlan -and ($plans.Guid -contains $State.originalPlan)) { $State.originalPlan } else { $Balanced }
    }
    $plans | Where-Object { $_.Name -eq $PlanName -and -not $_.Active } |
        ForEach-Object { Invoke-PowerCfg @('/delete', $_.Guid) | Out-Null }

    $dup  = Invoke-PowerCfg @('/duplicatescheme', $base)
    $guid = ([regex]::Match($dup, '[0-9a-fA-F-]{36}')).Value.ToLower()
    Invoke-PowerCfg @('/changename', $guid, $PlanName, 'Temporary plan used while server mode is ON. Safe to delete when OFF.') | Out-Null
    foreach ($o in $Overrides) {
        Invoke-PowerCfg @('/setacvalueindex', $guid, $o[0], $o[1], '0') | Out-Null
        Invoke-PowerCfg @('/setdcvalueindex', $guid, $o[0], $o[1], '0') | Out-Null
    }
    Invoke-PowerCfg @('/setactive', $guid) | Out-Null
    if ($active.Name -eq $PlanName) { Invoke-PowerCfg @('/delete', $active.Guid) | Out-Null }

    $State.originalPlan = $base
    $State.serverPlan   = $guid
    Write-Log "Power override ON (plan $guid, based on $base)"
}

function Disable-PowerOverride {
    param($State)
    $plans = @(Get-PowerPlans)
    $ours  = @($plans | Where-Object { $_.Name -eq $PlanName })
    if ($ours.Count -eq 0) { $State.serverPlan = $null; return }

    if ($ours | Where-Object Active) {
        $back = if ($State.originalPlan -and ($plans.Guid -contains $State.originalPlan)) { $State.originalPlan } else { $Balanced }
        Invoke-PowerCfg @('/setactive', $back) | Out-Null
        Write-Log "Power override OFF (back to $back)"
    }
    foreach ($p in $ours) { Invoke-PowerCfg @('/delete', $p.Guid) | Out-Null }
    $State.serverPlan = $null
}

# Brings the power plan in line with the desired state and the battery rule.
# Safe to call often and from several processes.
function Sync-ServerMode {
    param([string]$Source = 'watchdog')
    $conf  = Get-Config
    $power = Get-PowerStatus
    Update-State {
        param($s)
        if ($power.onAC) { $s.ignoreBatteryLimit = $false }
        $batteryOk = $power.onAC -or $s.ignoreBatteryLimit -or ($power.percent -gt $conf.batteryLimit)
        $want = $s.enabled -and $batteryOk

        if ($want) { Enable-PowerOverride $s } else { Disable-PowerOverride $s }

        $reason = if (-not $s.enabled) { 'off' } elseif (-not $batteryOk) { 'battery' } else { 'on' }
        if ($reason -ne $s.reason) { Write-Log "Server mode: $($s.reason) -> $reason ($Source, battery $($power.percent)%, AC=$($power.onAC))" }
        $s.active  = $want
        $s.reason  = $reason
        $s.battery = $power.percent
        $s.onAC    = $power.onAC
        if ($Source -eq 'watchdog') { $s.heartbeat = (Get-Date).ToString('o') }
        $s
    }
}

# Belt and braces next to the power plan: tells Windows this process needs
# the system awake (covers idle sleep, not the lid).
function Set-KeepAwake {
    param([bool]$On)
    $ES_CONTINUOUS = [uint32]'0x80000000'; $ES_SYSTEM_REQUIRED = [uint32]1
    if ($On) { [LSM.Native]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null }
    else     { [LSM.Native]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null }
}

# ---------------------------------------------------------------- services

function Get-Services {
    $dir = Join-Path $Root 'services'
    if (-not (Test-Path $dir)) { return }
    foreach ($f in Get-ChildItem $dir -Recurse -Filter 'service.json') {
        $svc = Get-Content $f.FullName -Raw | ConvertFrom-Json
        $svc | Add-Member -Force dir $f.DirectoryName
        $svc
    }
}

function Test-ServiceEnabled {
    param($Service, $State)
    $p = $State.services.PSObject.Properties[$Service.name]
    if ($p) { [bool]$p.Value } else { [bool]$Service.enabledByDefault }
}

function Invoke-Hidden {
    param([string]$File, [string]$Arguments, [int]$TimeoutSec = 60)
    $psi = New-Object Diagnostics.ProcessStartInfo $File, $Arguments
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); return [pscustomobject]@{ Code = -1; Output = 'timeout' } }
    [pscustomobject]@{ Code = $p.ExitCode; Output = (($out.Result + $err.Result) -replace "`0", '').Trim() }
}

# Runs a service's script with one verb: start | check | stop.
function Invoke-ServiceVerb {
    param($Service, [string]$Verb)
    $conf = Get-Config
    if ($Service.runsIn -eq 'wsl') {
        $rel    = $Service.dir.Substring($Root.Length).TrimStart('\') -replace '\\', '/'
        $script = "$($conf.wslRoot)/$rel/$($Service.script)"
        $wsl    = Join-Path $env:SystemRoot 'System32\wsl.exe'
        # wsl.exe does not strip quotes from -d; distro names never contain spaces.
        Invoke-Hidden $wsl "-d $($conf.wslDistro) -- bash -l `"$script`" $Verb"
    } else {
        $script = Join-Path $Service.dir $Service.script
        Invoke-Hidden 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -File `"$script`" $Verb"
    }
}

# Keeps enabled services running while server mode is ON. Retries a failing
# service with growing gaps (1, 2, 4 ... 30 min) so a broken one doesn't spin.
function Sync-Services {
    param($State)
    $now = Get-Date
    foreach ($svc in @(Get-Services)) {
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
        } elseif ((Invoke-ServiceVerb $svc 'check').Code -eq 0) {
            if ($st.status -ne 'running') { Write-Log "[$name] running" }
            $st.status = 'running'; $st.failures = 0; $st.retryAt = $null
        } elseif (-not $st.retryAt -or $now -ge [datetime]$st.retryAt) {
            $r = Invoke-ServiceVerb $svc 'start'
            Start-Sleep -Seconds 3
            if ((Invoke-ServiceVerb $svc 'check').Code -eq 0) {
                Write-Log "[$name] started"
                $st.status = 'running'; $st.failures = 0; $st.retryAt = $null
            } else {
                $st.failures = [int]$st.failures + 1
                $wait = [math]::Min(30, [math]::Pow(2, $st.failures - 1))
                $st.status = 'failing'; $st.retryAt = $now.AddMinutes($wait).ToString('o')
                Write-Log "[$name] failed to start (try $($st.failures), next in $wait min): exit $($r.Code) $($r.Output)"
            }
        }
        $State.serviceStatus | Add-Member -Force $name $st
    }
}

Export-ModuleMember -Function Write-Log, Get-Config, Get-State, Update-State, Set-ServerMode,
    Set-ServiceEnabled, Get-PowerStatus, Sync-ServerMode, Set-KeepAwake, Get-Services,
    Test-ServiceEnabled, Sync-Services, Disable-PowerOverride
