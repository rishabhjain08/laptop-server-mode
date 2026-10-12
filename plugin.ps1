# Installs and removes plugins. From PowerShell, in this folder:
#   .\plugin.ps1 list
#   .\plugin.ps1 add <folder>...     copy a plugin folder in (replaces an older
#                                    copy, keeps your settings.json)
#   .\plugin.ps1 remove <name>...    stop its service and delete it
#   .\plugin.ps1 enable <name>...    turn a service on (like its tray switch)
#   .\plugin.ps1 disable <name>...   turn a service off
# (Run as: powershell -ExecutionPolicy Bypass -File .\plugin.ps1 ...)
# The watchdog picks changes up on its next round; no restart needed.
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Items
)
$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'LaptopServerMode'
$plugins = Join-Path $dest 'plugins'
if (-not (Test-Path (Join-Path $dest 'ServerMode.psm1'))) {
    Write-Error "Laptop Server Mode isn't installed. Run install.ps1 first."
}
function Show-Usage { Get-Content $PSCommandPath | Select-Object -Skip 1 -First 8 | ForEach-Object { $_ -replace '^# ?', '' }; exit 2 }

switch ($Command) {
    'list' {
        Import-Module (Join-Path $dest 'ServerMode.psm1')
        foreach ($p in @(Get-Plugins)) {
            $problem = Get-PluginProblem $p
            $where = if ($p.runsIn -eq 'wsl') { "wsl:$(Get-PluginDistro $p)" } else { $p.runsIn }
            $line = '{0,-20} {1,-14} {2}' -f (Split-Path $p.dir -Leaf), $where, $p.title
            if ($problem) { $line += "  (needs setup: $problem)" }
            $line
        }
    }
    'add' {
        if (-not $Items) { Show-Usage }
        foreach ($src in $Items) {
            $src = (Resolve-Path $src).Path
            if (-not (Test-Path (Join-Path $src 'plugin.json'))) { Write-Error "$src has no plugin.json" }
            $name = Split-Path $src -Leaf
            $to = Join-Path $plugins $name
            $settings = Join-Path $to 'settings.json'
            $keep = if (Test-Path $settings) { [IO.File]::ReadAllText($settings) } else { $null }
            New-Item -ItemType Directory -Force $plugins | Out-Null
            if (Test-Path $to) { Remove-Item $to -Recurse -Force }
            Copy-Item $src $to -Recurse
            if ($null -ne $keep) { [IO.File]::WriteAllText($settings, $keep) }
            "Added $name" + $(if ($null -ne $keep) { ' (kept your settings.json)' } else { '' })
        }
    }
    'remove' {
        if (-not $Items) { Show-Usage }
        Import-Module (Join-Path $dest 'ServerMode.psm1')
        foreach ($name in $Items) {
            $dir = Join-Path $plugins $name
            if (-not (Test-Path $dir)) { Write-Warning "No plugin named $name"; continue }
            Get-Services | Where-Object { (Split-Path $_.dir -Leaf) -eq $name -and -not (Get-PluginProblem $_) } |
                ForEach-Object { Invoke-ServiceVerb $_ 'stop' | Out-Null }
            Remove-Item $dir -Recurse -Force
            # Forget its tray switch too, so a later add starts from its default.
            Update-State { param($s) $s.services.PSObject.Properties.Remove($name); $s } | Out-Null
            "Removed $name"
        }
    }
    { $_ -in 'enable', 'disable' } {
        if (-not $Items) { Show-Usage }
        Import-Module (Join-Path $dest 'ServerMode.psm1')
        foreach ($name in $Items) {
            if (-not (Get-Services | Where-Object name -eq $name)) { Write-Warning "No service named $name"; continue }
            Set-ServiceEnabled $name ($Command -eq 'enable')
            "Turned $name $(if ($Command -eq 'enable') { 'on' } else { 'off' })"
        }
    }
    default { Show-Usage }
}
