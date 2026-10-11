# Runs at boot (before anyone signs in) and loops forever:
# re-applies server mode, applies the battery rule, keeps WSL and services up.
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$keepAlive = @{}
$round = 0
$conf = Get-Config

Write-Log "Watchdog started (pid $PID, user $env:USERNAME)"
while ($true) {
    try {
        $conf  = Get-Config
        $state = Sync-ServerMode -Source watchdog
        Set-KeepAwake $state.active

        # WSL stops a distro when no Windows process holds it open. Keep the
        # main distro up while server mode is ON, and each service's own
        # distro up while that service is enabled (services keep running
        # when server mode is OFF).
        $want = @{}
        if ($state.enabled -and $conf.wslDistro) { $want[$conf.wslDistro] = $true }
        foreach ($svc in @(Get-Services)) {
            if ($svc.PSObject.Properties['wslDistro'] -and (Test-ServiceEnabled $svc $state)) { $want[$svc.wslDistro] = $true }
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
        if (($round % 40) -eq 1) { Clear-WorkingSet }   # about every 10 minutes
    } catch {
        Write-Log "Error: $_"
    }
    Start-Sleep -Seconds ([math]::Max(5, [int]$conf.pollSeconds))
}
