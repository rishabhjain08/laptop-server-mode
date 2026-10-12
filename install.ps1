# Installs Laptop Server Mode, or updates it (your config, state and plugins
# are kept). WSL is optional. From PowerShell, in this folder:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 [-WslDistro <name>]
# -WslDistro: default distro for WSL plugins on a fresh install. Leave it out
# to use Windows' default WSL distro (install.sh passes the distro it runs in).
param([string]$WslDistro = '')
$ErrorActionPreference = 'Stop'

$repo = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'LaptopServerMode'
$user = "$env:USERDOMAIN\$env:USERNAME"

Write-Host "==> Copying files to $dest"
New-Item -ItemType Directory -Force (Join-Path $dest 'logs'), (Join-Path $dest 'plugins') | Out-Null
Copy-Item (Join-Path $repo 'src\*') $dest -Force

# Older versions kept services in services\<name>\service.json.
$old = Join-Path $dest 'services'
if (Test-Path $old) {
    foreach ($d in Get-ChildItem $old -Directory) {
        $to = Join-Path $dest "plugins\$($d.Name)"
        if (-not (Test-Path $to)) { Move-Item $d.FullName $to; Rename-Item (Join-Path $to 'service.json') 'plugin.json' }
    }
    Remove-Item $old -Recurse -Force
    Write-Host '==> Moved services to plugins'
}

$conf = Join-Path $dest 'config.json'
if (-not (Test-Path $conf)) {
    $json = [ordered]@{ batteryLimit = 35; pollSeconds = 15; wslDistro = $WslDistro } | ConvertTo-Json
    [IO.File]::WriteAllText($conf, $json)
    $d = if ($WslDistro) { "WSL plugins run in $WslDistro" } else { "WSL plugins run in Windows' default distro" }
    Write-Host "==> Created config.json (battery limit 35%; $d)"
}

$distros = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-ItemProperty $_.PSPath).DistributionName } | Where-Object { $_ })
if (-not $distros) {
    Write-Host '    No WSL found: plugins that run on Windows work; WSL plugins will show "Needs setup".'
}

Write-Host "==> Registering startup tasks for $user"
$tasks = Join-Path $dest 'Install-Tasks.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tasks -User $user
if ($LASTEXITCODE -ne 0) {
    Write-Host '    Windows needs admin rights for that here; approve the admin prompt'
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tasks`" -User `"$user`""
    if ($p.ExitCode -ne 0) { throw 'Registering the startup tasks failed.' }
}

Write-Host '==> Done. Look for the laptop icon next to the clock.'
Write-Host '    Add plugins with .\plugin.ps1 add <folder> (see examples\ and addons\).'
