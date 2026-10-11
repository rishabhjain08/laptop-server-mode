# Registers the startup tasks and the Start menu shortcut. install.sh runs
# this for you, without admin rights when Windows allows it.
#   Watchdog: at boot, before sign-in. Uses S4U ("do not store password"),
#             so no password is saved anywhere.
#   KeepAwake: at boot, a second "keep the system awake" holder that doesn't
#             depend on the watchdog (see KeepAwake.ps1).
#   Tray:     at sign-in, in your desktop session.
#   Shutdown: when Windows starts shutting down or restarting (event 1074),
#             runs plugins' "shutdown" hooks.
param([Parameter(Mandatory)][string]$User)
$ErrorActionPreference = 'Stop'

$dir = $PSScriptRoot
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$names = 'LaptopServerMode Watchdog', 'LaptopServerMode Tray', 'LaptopServerMode KeepAwake'
$shutdownTask = 'LaptopServerMode Shutdown'

foreach ($n in $names) {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $n }
}
# Stopping a task doesn't stop its process tree (the tray runs under
# conhost), so end leftovers explicitly. WSL keep-alives stay: the new
# watchdog adopts them, so distros (and what runs in them) stay up.
Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq 'powershell.exe' -and $_.CommandLine -match '\\(Tray|Watchdog|KeepAwake)\.ps1'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)

# Task Scheduler's restart setting only covers a task that fails to start,
# not one whose process dies later. This trigger starts the watchdog again
# within 5 minutes if it ever exits (IgnoreNew skips it while it's running).
# KeepAwake gets the same triggers.
$every5min = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $names[0] -Force -Settings $settings `
    -Description 'Laptop Server Mode: keeps server mode, WSL and services running across restarts.' `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Watchdog.ps1`"") `
    -Trigger @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $User), $every5min) `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited) | Out-Null

Register-ScheduledTask -TaskName $names[2] -Force -Settings $settings `
    -Description 'Laptop Server Mode: keeps the laptop awake while server mode is on, independently of the watchdog.' `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\KeepAwake.ps1`"") `
    -Trigger @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -AtLogOn -User $User), $every5min) `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited) | Out-Null

Register-ScheduledTask -TaskName $names[1] -Force -Settings $settings `
    -Description 'Laptop Server Mode: tray icon to toggle server mode.' `
    -Action (New-ScheduledTaskAction -Execute $conhost -Argument "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$dir\Tray.ps1`"") `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $User) `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited) | Out-Null

# Event triggers aren't exposed by New-ScheduledTaskTrigger; build one via CIM.
$class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$onShutdown = New-CimInstance -CimClass $class -ClientOnly
$onShutdown.Enabled = $true
$onShutdown.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''User32''] and EventID=1074]]</Select></Query></QueryList>'
Register-ScheduledTask -TaskName $shutdownTask -Force `
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) `
    -Description 'Laptop Server Mode: runs plugin shutdown hooks when Windows shuts down or restarts.' `
    -Action (New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\Run-Hooks.ps1`" -Event shutdown") `
    -Trigger $onShutdown `
    -Principal (New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Limited) | Out-Null

# Start menu shortcut: brings the tray back after "Quit tray".
$lnk = New-Object -ComObject WScript.Shell
$sc = $lnk.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Laptop Server Mode.lnk'))
$sc.TargetPath = $conhost
$sc.Arguments = "--headless `"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$dir\Tray.ps1`""
$sc.IconLocation = "$dir\app.ico"
$sc.Description = 'Show the Laptop Server Mode icon next to the clock'
$sc.Save()

foreach ($n in $names) { Start-ScheduledTask -TaskName $n }
Write-Host 'Tasks registered and started.'
