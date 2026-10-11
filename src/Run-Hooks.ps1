# Runs plugin hooks for one event. The "LaptopServerMode Shutdown" task
# calls this when Windows starts shutting down or restarting (best effort:
# Windows doesn't wait for it, so keep shutdown hooks short).
#   powershell -File Run-Hooks.ps1 -Event shutdown
param([Parameter(Mandatory)][string]$Event)
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force
Invoke-Hooks $Event -TimeoutSec 20
