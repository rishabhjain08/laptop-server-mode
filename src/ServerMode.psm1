# Core of Laptop Server Mode: state, power override, battery rule.
# Plugins (services and hooks) are in Plugins.ps1.
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
[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr hProcess);
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

$script:LastConfig = $null
$script:ConfigError = $null

# A config.json you're editing may be invalid for a while: keep using the last
# good settings (or the defaults) and log the problem once, not every round.
function Get-Config {
    $conf = [ordered]@{ batteryLimit = 35; pollSeconds = 15; wslDistro = '' }
    if (Test-Path $ConfPath) {
        try { $json = Get-Content $ConfPath -Raw | ConvertFrom-Json }
        catch {
            if ("$_" -ne $script:ConfigError) { Write-Log "config.json is invalid, using the last good settings: $_" }
            $script:ConfigError = "$_"
            if ($script:LastConfig) { return $script:LastConfig }
            return [pscustomobject]$conf
        }
        if ($script:ConfigError) { Write-Log 'config.json is valid again' }
        $script:ConfigError = $null
        foreach ($p in $json.PSObject.Properties) { $conf[$p.Name] = $p.Value }
    }
    $script:LastConfig = [pscustomobject]$conf
    $script:LastConfig
}

function New-State {
    [pscustomobject]@{
        enabled = $false; ignoreBatteryLimit = $false; services = [pscustomobject]@{}
        active = $false; reason = 'off'; originalPlan = $null; serverPlan = $null
        battery = $null; onAC = $true; serviceStatus = [pscustomobject]@{}; heartbeat = $null
        trayQuit = $false
        hookReason = $null; lastBoot = $null
    }
}

function Read-StateJson {
    param([string]$Path)
    $s = New-State
    $json = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if (-not $json) { throw 'empty' }
    foreach ($p in $json.PSObject.Properties) { $s | Add-Member -Force $p.Name $p.Value }
    $s
}

# Every save also keeps a copy as state.json.bak. If state.json is damaged or
# missing, the last saved state comes back from there; starting fresh would
# turn server mode and services off.
function Read-StateFile {
    $bak = "$StatePath.bak"
    # Lock-free readers (Get-State) can race a save, so retry briefly.
    for ($i = 1; $i -le 5; $i++) {
        if (Test-Path $StatePath) {
            try { return Read-StateJson $StatePath }
            catch { $err = $_ }
        } else { $err = 'missing' }
        if ($i -lt 5) { Start-Sleep -Milliseconds 100 }
    }
    if (Test-Path $bak) {
        try {
            $s = Read-StateJson $bak
            Write-Log "state.json unreadable ($err); restored the last saved state"
            return $s
        } catch { }
    }
    if ($err -ne 'missing') { Write-Log "state.json unreadable, starting fresh: $err" }
    New-State   # first run
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
        Copy-Item $tmp "$StatePath.bak" -Force
        # Replace in one step, so readers never see the file missing.
        if (Test-Path $StatePath) { [IO.File]::Replace($tmp, $StatePath, [NullString]::Value) }
        else { Move-Item $tmp $StatePath }
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

# The rule as a pure function (tests cover every combination). On battery at
# or below the limit, server mode pauses unless the user chose "turn on
# anyway"; plugging in clears that choice.
function Get-ServerModeDecision {
    param([bool]$Enabled, [bool]$IgnoreBatteryLimit, [bool]$OnAC, [int]$Percent, [int]$Limit)
    $ignore = $IgnoreBatteryLimit -and -not $OnAC
    $batteryOk = $OnAC -or $ignore -or ($Percent -gt $Limit)
    [pscustomobject]@{
        Active             = $Enabled -and $batteryOk
        Reason             = if (-not $Enabled) { 'off' } elseif (-not $batteryOk) { 'battery' } else { 'on' }
        IgnoreBatteryLimit = $ignore
    }
}

# Brings the power plan in line with the desired state and the battery rule.
# Safe to call often and from several processes.
function Sync-ServerMode {
    param([string]$Source = 'watchdog')
    $conf  = Get-Config
    $power = Get-PowerStatus
    Update-State {
        param($s)
        $d = Get-ServerModeDecision $s.enabled $s.ignoreBatteryLimit $power.onAC $power.percent $conf.batteryLimit
        $s.ignoreBatteryLimit = $d.IgnoreBatteryLimit
        $want = $d.Active
        $reason = $d.Reason

        if ($want) { Enable-PowerOverride $s } else { Disable-PowerOverride $s }

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

# Gives back memory that was only needed briefly (module load, JSON parsing).
function Clear-WorkingSet {
    [GC]::Collect()
    [LSM.Native]::EmptyWorkingSet([Diagnostics.Process]::GetCurrentProcess().Handle) | Out-Null
}

# ---------------------------------------------------------------- plugins

. (Join-Path $PSScriptRoot 'Plugins.ps1')

# ---------------------------------------------------------------- WSLg

# WSLg (Linux GUI apps, and the microphone for Claude's /voice) attaches to
# the Windows session that started the WSL VM. After a boot before sign-in,
# or a WSL restart, the watchdog's keep-alives start the VM in session 0,
# which has no desktop, so there's no mic. Once someone signs in, restart WSL
# and start it from their session first. Only when:
#   - every WSLg client (msrdc) is in session 0 and the main distro has no mic,
#   - no WSL terminal is open on the desktop (it would close),
#   - no Claude in a running distro is busy (it resumes afterwards),
#   - it wasn't tried yet for this sign-in.
# The watchdog calls this before it starts any wsl.exe itself, and it waits
# until WSLg is up in the desktop session, so nothing races it.
$script:WslgProbe = @'
mic=missing
PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl list short sources 2>/dev/null | grep -q RDPSource && mic=ok
command -v pactl >/dev/null || mic=unknown
busy=no
for s in /root/.claude/sessions/*.json /home/*/.claude/sessions/*.json; do
  [ -f "$s" ] && kill -0 "$(basename "$s" .json)" 2>/dev/null && grep -q '"status":"busy"' "$s" && busy=yes
done
echo "mic=$mic busy=$busy"
'@
$script:WslgTried = 0

function Repair-Wslg {
    param([string]$Distro)
    if (-not $Distro) { return }
    $desktop = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -ne 0 | Select-Object -First 1
    if (-not $desktop -or $script:WslgTried -eq $desktop.Id) { return }
    $msrdc = @(Get-Process msrdc -ErrorAction SilentlyContinue)
    if (-not $msrdc -or @($msrdc | Where-Object SessionId -ne 0)) { return }
    if (@(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object SessionId -ne 0)) { return }
    $running = (Invoke-Hidden $Wsl '--list --running --quiet').Output -split '\r?\n' | Where-Object { $_.Trim() }
    if ($running -notcontains $Distro) { return }
    foreach ($d in $running) {
        $probe = Invoke-Hidden $Wsl "-d $($d.Trim()) -u root --cd / -- sh -s" -InputText $WslgProbe -TimeoutSec 20
        if ($probe.Output -match 'busy=yes') { return }   # try again next round
        if ($d.Trim() -eq $Distro -and $probe.Output -notmatch 'mic=missing') { $script:WslgTried = $desktop.Id; return }
    }
    $script:WslgTried = $desktop.Id
    Write-Log "WSLg started in session 0 (no mic); restarting WSL from the desktop session"
    Invoke-Hidden $Wsl '--shutdown' | Out-Null
    $task = 'LaptopServerMode WSL Start'
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $action = New-ScheduledTaskAction -Execute $conhost -Argument "--headless $Wsl -d $Distro --exec sleep infinity"
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    $until = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 1
        $ok = @(Get-Process msrdc -ErrorAction SilentlyContinue | Where-Object SessionId -eq $desktop.SessionId)
    } until ($ok -or (Get-Date) -gt $until)
    if ($ok) { Write-Log "WSLg is up in the desktop session" } else { Write-Log "WSLg didn't come up in the desktop session within 90 s" }
}

Export-ModuleMember -Function Write-Log, Get-Config, Get-State, Update-State, Set-ServerMode,
    Set-ServiceEnabled, Get-PowerStatus, Sync-ServerMode, Set-KeepAwake, Get-Services,
    Test-ServiceEnabled, Sync-Services, Disable-PowerOverride, Stop-AllServices, Clear-WorkingSet,
    Get-Plugins, Get-PluginDistro, Invoke-Hooks, Invoke-ServiceVerb, Get-ServerModeDecision, Get-HookEvents, Repair-Wslg
