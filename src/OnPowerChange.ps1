# Runs when the charger is plugged in or unplugged (the "LaptopServerMode
# PowerChange" task, on Kernel-Power event 105). When server mode is paused
# by the battery rule, the laptop is usually asleep by the time you plug in:
# Windows wakes for under a second and goes back to standby before the
# watchdog's next check. So this applies the rule right away and holds the
# system awake until the watchdog has run a round of its own.
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force

$start = Get-Date
$state = Sync-ServerMode -Source 'power change'
if (-not $state.active) { return }
Set-KeepAwake $true

# The watchdog's heartbeat moving past our start means it's awake and
# holding the system itself (its loop sleeps at most a minute or so).
$deadline = $start.AddMinutes(2)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $s = Get-State
    if (-not $s.active) { break }
    if ($s.heartbeat -and [datetime]$s.heartbeat -gt $start) { break }
}
