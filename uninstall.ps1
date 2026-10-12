# Removes Laptop Server Mode and restores your normal power plan. Plugin
# services are stopped and the plugins folder is deleted. From PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
$ErrorActionPreference = 'Stop'
$script = Join-Path $env:LOCALAPPDATA 'LaptopServerMode\Uninstall.ps1'
if (-not (Test-Path $script)) { Write-Host "Laptop Server Mode isn't installed."; exit 0 }

Write-Host '==> Uninstalling'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script
if ($LASTEXITCODE -ne 0) {
    Write-Host '    Windows needs admin rights for that here; approve the admin prompt'
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
    if ($p.ExitCode -ne 0) { throw 'Uninstall failed.' }
}
Write-Host '==> Done.'
