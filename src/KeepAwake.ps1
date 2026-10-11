# Second keep-awake, independent of the watchdog. With the lid closed Windows
# is in Modern Standby, and only a "system required" power request keeps it
# working. The watchdog holds one; this small loop holds another, so the
# laptop stays up while a crashed watchdog is restarted (within 5 minutes).
# Same rule as the watchdog: hold while server mode is on and the battery
# rule allows it. It reads state.json and config.json only, and shares no
# code with the watchdog on purpose.
# Dot-source it (". .\KeepAwake.ps1") to load the functions without the loop.

$script:Root = $PSScriptRoot
Add-Type -Namespace LSMKeepAwake -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
[DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out PowerStatus status);
[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr process);
public struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int BatteryLifeTime, BatteryFullLifeTime; }
'@

function Get-KeepAwakePower {
    $s = New-Object LSMKeepAwake.Native+PowerStatus
    [void][LSMKeepAwake.Native]::GetSystemPowerStatus([ref]$s)
    $noBattery = ($s.BatteryFlag -band 128) -ne 0 -or $s.BatteryLifePercent -eq 255
    [pscustomobject]@{
        onAC    = $noBattery -or $s.ACLineStatus -eq 1
        percent = if ($noBattery) { 100 } else { [int]$s.BatteryLifePercent }
    }
}

function Read-Json {
    param([string]$Name)
    try { [IO.File]::ReadAllText((Join-Path $Root $Name)) | ConvertFrom-Json } catch { $null }
}

# The watchdog's rule: on, unless on battery at or below the limit (and the
# user didn't choose "turn on anyway").
function Test-ShouldHold {
    param($State, $Config, $Power)
    if (-not $State -or -not $State.enabled) { return $false }
    $limit = if ($Config -and $Config.PSObject.Properties['batteryLimit']) { [int]$Config.batteryLimit } else { 35 }
    $ignore = $State.PSObject.Properties['ignoreBatteryLimit'] -and $State.ignoreBatteryLimit
    [bool]($Power.onAC -or $ignore -or $Power.percent -gt $limit)
}

function Write-KeepAwakeLog {
    param([string]$Message)
    try {
        $file = Join-Path $Root 'logs\keepawake.log'
        if ((Test-Path $file) -and (Get-Item $file).Length -gt 256KB) { Move-Item $file "$file.old" -Force }
        Add-Content -Path $file -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding ASCII
    } catch { }
}

if ($MyInvocation.InvocationName -eq '.') { return }

Write-KeepAwakeLog "Keep-awake started (pid $PID)"
$holding = $null
$lastState = $null
while ($true) {
    # If state.json can't be read (mid-write), keep the last known state.
    $state = Read-Json 'state.json'
    if ($state) { $lastState = $state } else { $state = $lastState }
    $hold = Test-ShouldHold $state (Read-Json 'config.json') (Get-KeepAwakePower)
    if ($hold -ne $holding) {
        $flags = if ($hold) { [uint32]'0x80000001' } else { [uint32]'0x80000000' }   # ES_CONTINUOUS (| ES_SYSTEM_REQUIRED)
        [void][LSMKeepAwake.Native]::SetThreadExecutionState($flags)
        Write-KeepAwakeLog $(if ($hold) { 'Holding the system awake' } else { 'Released' })
        if ($null -eq $holding) { [void][LSMKeepAwake.Native]::EmptyWorkingSet([Diagnostics.Process]::GetCurrentProcess().Handle) }
        $holding = $hold
    }
    Start-Sleep -Seconds 15
}
