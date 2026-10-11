# Runs at boot (before anyone signs in) and loops forever:
# re-applies server mode, applies the battery rule, keeps WSL and services up,
# and runs plugin hooks (boot, server-on, server-off, server-paused).
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$keepAlive = @{}
$round = 0
$trayChecked = [datetime]::MinValue
$conf = Get-Config
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')

Write-Log "Watchdog started (pid $PID, user $env:USERNAME)"

# Adopt keep-alives left by a previous watchdog (it may have crashed), so
# restarts don't pile up WSL processes. Killing the System32 wsl.exe stub
# also ends the real wsl.exe it starts.
foreach ($p in Get-CimInstance Win32_Process -Filter "Name='wsl.exe'") {
    if ($p.ExecutablePath -notlike '*\System32\wsl.exe' -or $p.CommandLine -notmatch '-d (\S+) -- sleep infinity') { continue }
    $d = $Matches[1]
    $proc = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) { continue }
    if ($keepAlive[$d]) { $proc.Kill(); continue }
    $keepAlive[$d] = $proc
    Write-Log "WSL keep-alive adopted for $d (pid $($p.ProcessId))"
}
while ($true) {
    try {
        $conf  = Get-Config
        $state = Sync-ServerMode -Source watchdog
        Set-KeepAwake $state.active

        # Hooks: once per Windows boot, and when server mode changes state
        # (whoever changed it: the tray, the battery rule, or a restart).
        $fire = Get-HookEvents $state $boot
        if ($state.lastBoot -ne $boot -or $state.hookReason -ne $state.reason) {
            $reason = $state.reason
            Update-State { param($s) $s.lastBoot = $boot; $s.hookReason = $reason; $s } | Out-Null
        }
        foreach ($f in $fire) { Invoke-Hooks $f[0] $f[1] }

        # Repair-Wslg (restart WSL from the desktop session) is off: restarting
        # every Claude at each sign-in costs too much. To be replaced by
        # reconnecting WSLg's msrdc without a restart.

        # WSL stops a distro when no Windows process holds it open. Keep the
        # main distro up while server mode is ON, and each WSL service's
        # distro up while that service is enabled (services keep running
        # when server mode is OFF).
        $want = @{}
        if ($state.enabled -and $conf.wslDistro) { $want[$conf.wslDistro] = $true }
        foreach ($svc in @(Get-Services)) {
            if ($svc.runsIn -eq 'wsl' -and (Test-ServiceEnabled $svc $state)) { $want[(Get-PluginDistro $svc)] = $true }
        }
        foreach ($d in @($want.Keys)) {
            $k = $keepAlive[$d]
            if (-not $k -or $k.HasExited) {
                $keepAlive[$d] = Start-Process $wsl -ArgumentList "-d $d -- sleep infinity" -WindowStyle Hidden -PassThru
                Write-Log "WSL keep-alive started for $d (pid $($keepAlive[$d].Id))"
            }
        }
        foreach ($d in @($keepAlive.Keys)) {
            if (-not $want[$d]) {
                if (-not $keepAlive[$d].HasExited) { $keepAlive[$d].Kill() }
                $keepAlive.Remove($d)
                Write-Log "WSL keep-alive stopped for $d"
            }
        }

        # Service checks can take seconds, so run them outside the state lock
        # and only write back their status.
        # While server mode is OFF, check services every 4th round only.
        $round++
        if ($state.enabled -or ($round % 4) -eq 1) {
            $snapshot = Get-State
            Sync-Services $snapshot
            Update-State { param($s) $s.serviceStatus = $snapshot.serviceStatus; $s } | Out-Null
        }
        # Bring the tray back if it crashed while someone is signed in (not
        # after "Quit tray"). The tray task starts it in that person's session.
        if (-not $state.trayQuit -and ((Get-Date) - $trayChecked).TotalSeconds -ge 60) {
            $trayChecked = Get-Date
            $signedIn = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -ne 0).Count -gt 0
            $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -match '\\Tray\.ps1').Count -gt 0
            if ($signedIn -and -not $running -and (Get-ScheduledTask -TaskName 'LaptopServerMode Tray' -ErrorAction SilentlyContinue)) {
                Start-ScheduledTask -TaskName 'LaptopServerMode Tray'
                Write-Log 'Tray was not running; started it'
            }
        }

        if (($round % 40) -eq 1) { Clear-WorkingSet }   # about every 10 minutes
    } catch {
        Write-Log "Error: $_"
    }
    Start-Sleep -Seconds ([math]::Max(5, [int]$conf.pollSeconds))
}
