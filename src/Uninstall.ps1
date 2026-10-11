# Removes the tasks, turns the power override off and deletes the install
# folder, including installed plugins. uninstall.sh runs this for you.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot

foreach ($n in 'LaptopServerMode Watchdog', 'LaptopServerMode Tray', 'LaptopServerMode Shutdown', 'LaptopServerMode KeepAwake') {
    if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $n
        Unregister-ScheduledTask -TaskName $n -Confirm:$false
    }
}

Get-CimInstance Win32_Process | Where-Object {
    ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match '\\(Tray|Watchdog|KeepAwake)\.ps1') -or
    ($_.Name -eq 'wsl.exe' -and $_.CommandLine -like '*-- sleep infinity*')
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$ids = @('LaptopServerMode')
if (Test-Path "$dir\app.id") { $ids += (Get-Content "$dir\app.id" -Raw).Trim() }
foreach ($id in $ids) { Remove-Item "HKCU:\Software\Classes\AppUserModelId\$id" -Recurse -ErrorAction SilentlyContinue }
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Laptop Server Mode.lnk') -ErrorAction SilentlyContinue

Import-Module (Join-Path $dir 'ServerMode.psm1') -Force
foreach ($svc in @(Get-Services)) { try { Invoke-ServiceVerb $svc 'stop' | Out-Null } catch { } }
Update-State { param($s) $s.enabled = $false; Disable-PowerOverride $s; $s } | Out-Null
Remove-Module ServerMode

Set-Location $env:TEMP
Remove-Item $dir -Recurse -Force
Write-Host 'Uninstalled. Your normal power plan is active.'
