# Appends one line per event to %USERPROFILE%\server-mode-events.log, e.g.
#   2026-10-11 09:30:02 server-paused battery=34% ac=0 previous=on
$line = '{0:yyyy-MM-dd HH:mm:ss} {1} battery={2}% ac={3}' -f (Get-Date), $env:LSM_EVENT, $env:LSM_BATTERY, $env:LSM_ON_AC
if ($env:LSM_PREVIOUS) { $line += " previous=$env:LSM_PREVIOUS" }
if ($env:LSM_SERVICE) { $line += " service=$env:LSM_SERVICE" }
Add-Content -Path (Join-Path $env:USERPROFILE 'server-mode-events.log') -Value $line
