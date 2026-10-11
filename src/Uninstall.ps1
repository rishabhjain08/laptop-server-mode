# Removes the tasks, turns the power override off and deletes the install
# folder. Run elevated; uninstall.sh does this for you.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

foreach ($n in 'LaptopServerMode Watchdog', 'LaptopServerMode Tray') {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $n
        Unregister-ScheduledTask -TaskName $n -Confirm:$false
    }
}

Import-Module (Join-Path $dir 'ServerMode.psm1') -Force
Update-State { param($s) $s.enabled = $false; Disable-PowerOverride $s; $s } | Out-Null
Remove-Module ServerMode

Set-Location $env:TEMP
Remove-Item $dir -Recurse -Force
Write-Host 'Uninstalled. Your normal power plan is active.'
