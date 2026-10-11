# Exhaustive tests of the decision logic: every combination of inputs for the
# server-mode rule, the keep-awake rule, hook events and the service
# lifecycle. Nothing here touches power settings or real processes: power
# and service calls are replaced with mocks inside the module.
# Run with tests/run.sh (copies src to a temp folder, runs this file there).
param([Parameter(Mandatory)][string]$Src)
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++; Write-Output "FAIL $Name $Detail" }
}

$tmp = Join-Path $env:TEMP ("lsm-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp, "$tmp\logs", "$tmp\plugins" | Out-Null
$m = Import-Module (Join-Path $Src 'ServerMode.psm1') -Force -PassThru
& $m { param($t) $script:StatePath = "$t\state.json"; $script:LockPath = "$t\state.lock"; $script:LogDir = "$t\logs"
       $script:ConfPath = "$t\config.json"; $script:PluginDir = "$t\plugins"; $script:Root = $t } $tmp
'{ "batteryLimit": 35, "pollSeconds": 15, "wslDistro": "TestDistro" }' | Set-Content "$tmp\config.json"

# ------------------------------------------------------------ server-mode rule
$limit = 35
$percents = 0, 34, 35, 36, 100
$n = 0
foreach ($enabled in $true, $false) { foreach ($ignore in $true, $false) { foreach ($ac in $true, $false) { foreach ($pct in $percents) {
    $d = Get-ServerModeDecision $enabled $ignore $ac $pct $limit
    # Spec, written out case by case:
    $expReason = if (-not $enabled) { 'off' } elseif ($ac) { 'on' } elseif ($ignore) { 'on' } elseif ($pct -gt $limit) { 'on' } else { 'battery' }
    $expIgnore = $ignore -and -not $ac
    $case = "enabled=$enabled ignore=$ignore ac=$ac pct=$pct"
    Check "decision reason [$case]" ($d.Reason -eq $expReason) "got $($d.Reason) want $expReason"
    Check "decision active [$case]" ($d.Active -eq ($expReason -eq 'on')) "got $($d.Active)"
    Check "decision ignore [$case]" ($d.IgnoreBatteryLimit -eq $expIgnore) "got $($d.IgnoreBatteryLimit)"
    $n++
} } } }
Write-Output "server-mode rule: $n combinations"

# ------------------------------------------------------------ keep-awake rule
. (Join-Path $Src 'KeepAwake.ps1')
$n = 0
foreach ($enabled in $true, $false) { foreach ($ignore in $true, $false) { foreach ($ac in $true, $false) { foreach ($pct in $percents) {
    $state = [pscustomobject]@{ enabled = $enabled; ignoreBatteryLimit = $ignore }
    $hold = Test-ShouldHold $state ([pscustomobject]@{ batteryLimit = $limit }) ([pscustomobject]@{ onAC = $ac; percent = $pct })
    $d = Get-ServerModeDecision $enabled $ignore $ac $pct $limit
    Check "keep-awake agrees with watchdog [enabled=$enabled ignore=$ignore ac=$ac pct=$pct]" ($hold -eq $d.Active) "hold=$hold active=$($d.Active)"
    $n++
} } } }
Check 'keep-awake: no state -> release' (-not (Test-ShouldHold $null $null ([pscustomobject]@{ onAC = $true; percent = 100 })))
Check 'keep-awake: no config -> default limit 35' ((Test-ShouldHold ([pscustomobject]@{ enabled = $true }) $null ([pscustomobject]@{ onAC = $false; percent = 36 })) -and
    -not (Test-ShouldHold ([pscustomobject]@{ enabled = $true }) $null ([pscustomobject]@{ onAC = $false; percent = 35 })))
Check 'keep-awake: state without ignore field' (Test-ShouldHold ([pscustomobject]@{ enabled = $true }) ([pscustomobject]@{ batteryLimit = 35 }) ([pscustomobject]@{ onAC = $true; percent = 5 }))
$p = Get-KeepAwakePower
Check 'keep-awake: reads real power status' ($p.percent -ge 0 -and $p.percent -le 100) "percent=$($p.percent) onAC=$($p.onAC)"
Write-Output "keep-awake rule: $n combinations + 4 edge cases"

# ------------------------------------------------------------ hook events
$n = 0
foreach ($lastBoot in 'B1', 'B0', $null) { foreach ($hookReason in $null, 'on', 'battery', 'off') { foreach ($reason in 'on', 'battery', 'off') {
    $st = [pscustomobject]@{ lastBoot = $lastBoot; hookReason = $hookReason; reason = $reason }
    $ev = Get-HookEvents $st 'B1'   # used as the watchdog uses it
    $exp = @()
    if ($lastBoot -ne 'B1') { $exp += 'boot' }
    if ($hookReason -and $hookReason -ne $reason) { $exp += @{ on = 'server-on'; battery = 'server-paused'; off = 'server-off' }[$reason] }
    $got = @($ev | ForEach-Object { $_[0] })
    $case = "lastBoot=$lastBoot hookReason=$hookReason reason=$reason"
    Check "hook events [$case]" (($got -join ',') -eq ($exp -join ',')) "got '$($got -join ',')' want '$($exp -join ',')'"
    $chg = $ev | Where-Object { $_[0] -ne 'boot' }
    if ($chg) {
        $prev = @{ on = 'on'; battery = 'paused'; off = 'off' }[$hookReason]
        Check "hook previous [$case]" ($chg[1].LSM_PREVIOUS -eq $prev) "got $($chg[1].LSM_PREVIOUS)"
    }
    $n++
} } }
Write-Output "hook events: $n combinations"

# ------------------------------------------------------------ service lifecycle
# Mocks: verbs return scripted codes; sleeps are skipped; hooks are recorded.
& $m {
    $script:Calls = New-Object System.Collections.ArrayList
    $script:Mock = @{}
    function script:Start-Sleep { }
    function script:Invoke-Hooks { param($Event, $Env) [void]$script:Calls.Add("hook:${Event}:$($Env.LSM_SERVICE)") }
    function script:Invoke-ServiceVerb {
        param($Service, $Verb)
        [void]$script:Calls.Add($Verb)
        $code = switch ($Verb) {
            'check' { if (@($script:Calls | Where-Object { $_ -eq 'start' }).Count) { $script:Mock.checkAfterStart } else { $script:Mock.check } }
            'start' { $script:Mock.start }
            default { 0 }
        }
        [pscustomobject]@{ Code = $code; Output = '' }
    }
}
New-Item -ItemType Directory -Force "$tmp\plugins\svc" | Out-Null

$now = Get-Date
$prevStates = [ordered]@{
    'stopped'            = @{ status = 'stopped';     failures = 0; retryAt = $null }
    'running'            = @{ status = 'running';     failures = 0; retryAt = $null }
    'failing-wait'       = @{ status = 'failing';     failures = 2; retryAt = $now.AddMinutes(5).ToString('o') }
    'failing-due'        = @{ status = 'failing';     failures = 2; retryAt = $now.AddMinutes(-1).ToString('o') }
    'failing-max'        = @{ status = 'failing';     failures = 7; retryAt = $now.AddMinutes(-1).ToString('o') }
    'needs-setup-wait'   = @{ status = 'needs-setup'; failures = 0; retryAt = $now.AddMinutes(1).ToString('o') }
    'needs-setup-due'    = @{ status = 'needs-setup'; failures = 0; retryAt = $now.AddMinutes(-1).ToString('o') }
}
$n = 0
foreach ($server in $true, $false) { foreach ($svcOn in $true, $false) { foreach ($stopOff in $true, $false) {
foreach ($prevName in $prevStates.Keys) { foreach ($check in 0, 1) { foreach ($startCase in 'ok', 'fails', 'setup') {
    "{ `"name`": `"svc`", `"title`": `"Test`", `"run`": `"x`", `"stopWhenServerModeOff`": $($stopOff.ToString().ToLower()) }" | Set-Content "$tmp\plugins\svc\plugin.json"
    $prev = $prevStates[$prevName]
    $start = @{ ok = 0; fails = 1; setup = 3 }[$startCase]
    $checkAfter = @{ ok = 0; fails = 1; setup = 1 }[$startCase]
    & $m { param($c, $s, $ca) $script:Calls.Clear(); $script:Mock = @{ check = $c; start = $s; checkAfterStart = $ca } } $check $start $checkAfter
    $state = [pscustomobject]@{
        enabled = $server
        services = [pscustomobject]@{ svc = $svcOn }
        serviceStatus = [pscustomobject]@{ svc = [pscustomobject]$prev.Clone() }
    }
    Sync-Services $state
    $st = $state.serviceStatus.svc
    $calls = @(& $m { $script:Calls })
    $case = "server=$server svcOn=$svcOn stopOff=$stopOff prev=$prevName check=$check start=$startCase"

    # Spec
    $wanted = $server -and $svcOn
    if (-not $wanted) {
        $stopIt = (-not $svcOn) -or $stopOff
        Check "no start when not wanted [$case]" ($calls -notcontains 'start') "calls=$($calls -join ',')"
        if ($stopIt) {
            Check "stopped [$case]" ($st.status -eq 'stopped') "status=$($st.status)"
            Check "stop called only if not already stopped [$case]" (($calls -contains 'stop') -eq ($prev.status -ne 'stopped')) "calls=$($calls -join ',')"
        } else {
            Check "left running, status mirrors check [$case]" ($st.status -eq $(if ($check -eq 0) { 'running' } else { 'stopped' })) "status=$($st.status)"
            Check "never stopped [$case]" ($calls -notcontains 'stop') "calls=$($calls -join ',')"
        }
    } elseif ($check -eq 0) {
        Check "healthy -> running, counters reset [$case]" ($st.status -eq 'running' -and $st.failures -eq 0 -and -not $st.retryAt) "status=$($st.status) failures=$($st.failures)"
        Check "healthy -> no start [$case]" ($calls -notcontains 'start')
    } elseif ($prev.retryAt -and [datetime]$prev.retryAt -gt (Get-Date)) {
        Check "waits for retry time [$case]" ($calls -notcontains 'start' -and $st.status -eq $prev.status) "calls=$($calls -join ',') status=$($st.status)"
    } else {
        Check "starts [$case]" ($calls -contains 'start') "calls=$($calls -join ',')"
        if ($startCase -eq 'setup') {
            Check "needs-setup, retry in 1 min [$case]" ($st.status -eq 'needs-setup' -and ([datetime]$st.retryAt - (Get-Date)).TotalSeconds -gt 50) "status=$($st.status)"
        } elseif ($startCase -eq 'ok') {
            Check "started -> running [$case]" ($st.status -eq 'running' -and $st.failures -eq 0) "status=$($st.status)"
        } else {
            $f = [int]$prev.failures + 1
            $wait = [math]::Min(30, [math]::Pow(2, $f - 1))
            $secs = ([datetime]$st.retryAt - (Get-Date)).TotalSeconds
            Check "failing, backoff ${wait}m [$case]" ($st.status -eq 'failing' -and $st.failures -eq $f -and $secs -gt ($wait * 60 - 30) -and $secs -le ($wait * 60)) "status=$($st.status) failures=$($st.failures) secs=$([int]$secs)"
            $hook = @($calls | Where-Object { $_ -like 'hook:service-failed*' }).Count
            Check "service-failed hook only on first failure [$case]" ($hook -eq $(if ($f -eq 1) { 1 } else { 0 })) "hooks=$hook"
        }
    }
    $n++
} } } } } }
Write-Output "service lifecycle: $n combinations"

# Removed plugin: its status is dropped.
$state = [pscustomobject]@{ enabled = $true; services = [pscustomobject]@{}; serviceStatus = [pscustomobject]@{ gone = [pscustomobject]@{ status = 'running' } } }
& $m { $script:Calls.Clear(); $script:Mock = @{ check = 0; start = 0; checkAfterStart = 0 } }
Sync-Services $state
Check 'removed plugin status dropped' (-not $state.serviceStatus.PSObject.Properties['gone'])

# ------------------------------------------------------------ Sync-ServerMode with mocked power
& $m {
    $script:Power = $null; $script:PowerCalls = New-Object System.Collections.ArrayList
    function script:Get-PowerStatus { $script:Power }
    function script:Enable-PowerOverride { param($State) [void]$script:PowerCalls.Add('enable'); $State.serverPlan = 'test' }
    function script:Disable-PowerOverride { param($State) [void]$script:PowerCalls.Add('disable'); $State.serverPlan = $null }
}
$n = 0
foreach ($enabled in $true, $false) { foreach ($ignore in $true, $false) { foreach ($ac in $true, $false) { foreach ($pct in 20, 80) { foreach ($src in 'watchdog', 'tray') {
    Remove-Item "$tmp\state.json" -ErrorAction SilentlyContinue
    Update-State { param($s) $s.enabled = $enabled; $s.ignoreBatteryLimit = $ignore; $s.heartbeat = $null; $s } | Out-Null
    & $m { param($a, $p) $script:PowerCalls.Clear(); $script:Power = [pscustomobject]@{ onAC = $a; percent = $p; noBattery = $false } } $ac $pct
    $s = Sync-ServerMode -Source $src
    $d = Get-ServerModeDecision $enabled $ignore $ac $pct 35
    $calls = @(& $m { $script:PowerCalls })
    $case = "enabled=$enabled ignore=$ignore ac=$ac pct=$pct src=$src"
    Check "sync applies decision [$case]" ($s.reason -eq $d.Reason -and $s.active -eq $d.Active -and $s.ignoreBatteryLimit -eq $d.IgnoreBatteryLimit) "reason=$($s.reason)"
    Check "sync power call [$case]" ($calls.Count -eq 1 -and $calls[0] -eq $(if ($d.Active) { 'enable' } else { 'disable' })) "calls=$($calls -join ',')"
    Check "sync heartbeat only from watchdog [$case]" ([bool]$s.heartbeat -eq ($src -eq 'watchdog'))
    Check "sync saved [$case]" ((Get-State).reason -eq $d.Reason)
    $n++
} } } } }
Write-Output "sync with mocked power: $n combinations"

# ------------------------------------------------------------ plugin loading
Remove-Item "$tmp\plugins\*" -Recurse -Force
$defs = @{
    'ok-run'    = '{ "name": "ok-run", "run": "x" }'
    'ok-script' = '{ "name": "ok-script", "script": "s.sh", "runsIn": "windows" }'
    'ok-hooks'  = '{ "name": "ok-hooks", "on": { "boot": "x" } }'
    'bad-json'  = '{ "name": '
    'no-name'   = '{ "run": "x" }'
    'both'      = '{ "name": "both", "run": "x", "script": "y" }'
}
foreach ($k in $defs.Keys) { New-Item -ItemType Directory -Force "$tmp\plugins\$k" | Out-Null; $defs[$k] | Set-Content "$tmp\plugins\$k\plugin.json" }
New-Item -ItemType Directory -Force "$tmp\plugins\empty" | Out-Null
$pl = @(Get-Plugins)
Check 'plugins: only valid ones load' ((($pl.name | Sort-Object) -join ',') -eq 'ok-hooks,ok-run,ok-script') "got $($pl.name -join ',')"
Check 'plugins: services are run/script ones' (((@(Get-Services).name | Sort-Object) -join ',') -eq 'ok-run,ok-script')
Check 'plugins: defaults' (($pl | Where-Object name -eq 'ok-run').runsIn -eq 'wsl' -and ($pl | Where-Object name -eq 'ok-run').title -eq 'ok-run' -and ($pl | Where-Object name -eq 'ok-run').enabledByDefault)
Check 'plugins: distro falls back to config' ((Get-PluginDistro ($pl | Where-Object name -eq 'ok-run')) -eq 'TestDistro')

# ------------------------------------------------------------ damaged files
Remove-Item "$tmp\state.json*" -ErrorAction SilentlyContinue
Update-State { param($s) $s.enabled = $true; $s.services | Add-Member -Force keep $true; $s } | Out-Null
[IO.File]::WriteAllText("$tmp\state.json", '{ "enabled": tru')
$s = Get-State
Check 'corrupt state.json -> last saved state' ($s.enabled -eq $true -and $s.services.keep -eq $true) "enabled=$($s.enabled)"
Check 'corrupt state.json -> logged' ((Get-Content "$tmp\logs\watchdog.log" -Raw) -match 'restored the last saved state')
$s = Update-State { param($x) $x.reason = 'on'; $x }
Check 'save after corruption repairs state.json' (((Get-Content "$tmp\state.json" -Raw) | ConvertFrom-Json).enabled -eq $true)
Remove-Item "$tmp\state.json"
Check 'missing state.json -> last saved state' ((Get-State).enabled -eq $true)
[IO.File]::WriteAllText("$tmp\state.json", 'x'); [IO.File]::WriteAllText("$tmp\state.json.bak", 'y')
Check 'both damaged -> fresh state' ((Get-State).enabled -eq $false)
Remove-Item "$tmp\state.json*"
Check 'first run -> fresh state, nothing logged about it' ((Get-State).enabled -eq $false -and -not ((Get-Content "$tmp\logs\watchdog.log" -Raw) -match 'starting fresh: missing'))

'{ "batteryLimit": 50, "pollSeconds": 15, "wslDistro": "TestDistro" }' | Set-Content "$tmp\config.json"
$null = Get-Config
'{ "batteryLimit": ' | Set-Content "$tmp\config.json"
$c = @(1..3 | ForEach-Object { Get-Config })[-1]
$logged = @(Select-String "$tmp\logs\watchdog.log" -Pattern 'config.json is invalid').Count
Check 'invalid config -> last good settings' ($c.batteryLimit -eq 50 -and $c.wslDistro -eq 'TestDistro') "limit=$($c.batteryLimit)"
Check 'invalid config -> logged once' ($logged -eq 1) "logged $logged times"
'{ "batteryLimit": 40, "pollSeconds": 15, "wslDistro": "TestDistro" }' | Set-Content "$tmp\config.json"
Check 'fixed config -> new settings, logged' ((Get-Config).batteryLimit -eq 40 -and (Select-String "$tmp\logs\watchdog.log" -Pattern 'valid again' -Quiet))
& $m { $script:LastConfig = $null; $script:ConfigError = $null }
'{ "batteryLimit": ' | Set-Content "$tmp\config.json"
Check 'invalid config at startup -> defaults' ((Get-Config).batteryLimit -eq 35)

# ------------------------------------------------------------ log rotation
Remove-Item "$tmp\logs\*" -ErrorAction SilentlyContinue
[IO.File]::WriteAllText("$tmp\logs\watchdog.log", ('x' * 1100KB))
Write-Log 'after rotation'
Check 'log over 1 MB rotates to .old' ((Test-Path "$tmp\logs\watchdog.log.old") -and (Get-Item "$tmp\logs\watchdog.log").Length -lt 1KB)

Remove-Module ServerMode
Remove-Item $tmp -Recurse -Force
Write-Output ("RESULT {0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
