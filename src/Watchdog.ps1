# Runs at boot (before anyone signs in) and loops forever:
# re-applies server mode, applies the battery rule, keeps WSL and services up.
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$keepAlive = $null
$conf = Get-Config

Write-Log "Watchdog started (pid $PID, user $env:USERNAME)"
while ($true) {
    try {
        $conf  = Get-Config
        $state = Sync-ServerMode -Source watchdog
        Set-KeepAwake $state.active

        # WSL shuts its VM down when no Windows process holds it open.
        if ($state.enabled -and $conf.wslDistro) {
            if (-not $keepAlive -or $keepAlive.HasExited) {
                $keepAlive = Start-Process $wsl -ArgumentList "-d $($conf.wslDistro) -- sleep infinity" -WindowStyle Hidden -PassThru
                Write-Log "WSL keep-alive started (pid $($keepAlive.Id))"
            }
        } elseif ($keepAlive -and -not $keepAlive.HasExited) {
            $keepAlive.Kill(); $keepAlive = $null
            Write-Log 'WSL keep-alive stopped'
        }

        # Service checks can take seconds, so run them outside the state lock
        # and only write back their status.
        $snapshot = Get-State
        Sync-Services $snapshot
        Update-State { param($s) $s.serviceStatus = $snapshot.serviceStatus; $s } | Out-Null
    } catch {
        Write-Log "Error: $_"
    }
    Start-Sleep -Seconds ([math]::Max(5, [int]$conf.pollSeconds))
}
