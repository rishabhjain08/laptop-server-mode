# Registers the startup tasks. Run elevated; install.sh does this for you.
#   Watchdog: at boot, before sign-in. Uses S4U ("do not store password"),
#             so no password is saved anywhere.
#   Tray:     at sign-in, in your desktop session.
param([Parameter(Mandatory)][string]$User)
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$names = 'LaptopServerMode Watchdog', 'LaptopServerMode Tray'

foreach ($n in $names) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $n }
}
# Stopping a task doesn't stop its children (the tray runs under conhost,
# the watchdog owns a WSL keep-alive), so end leftovers explicitly.
Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match '\\(Tray|Watchdog)\.ps1') -or
    ($_.Name -eq 'wsl.exe' -and $_.CommandLine -like '*-- sleep infinity*')
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $names[0] -Force -Settings $settings `
    -Description 'Laptop Server Mode: keeps server mode, WSL and services running across restarts.' `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Watchdog.ps1`"") `
    -Trigger @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $User)) `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited) | Out-Null

Register-ScheduledTask -TaskName $names[1] -Force -Settings $settings `
    -Description 'Laptop Server Mode: tray icon to toggle server mode.' `
    -Action (New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$dir\Tray.ps1`"") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $User) `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited) | Out-Null

foreach ($n in $names) { Start-ScheduledTask -TaskName $n }
Write-Host 'Tasks registered and started.'
