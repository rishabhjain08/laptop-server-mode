# Drives the real tray and flyout: Tray.ps1 runs in its own process from a
# staging copy, with power, services and notifications mocked, and this file
# sends it real mouse and keyboard messages. No desktop needed.
#   Entry (tests/run.sh):  Tray.Tests.ps1 -Src <copy of src>
#   Hook (from Tray.ps1):  . Tray.Tests.ps1 setup|run
param([string]$Mode, [string]$Src)

# ------------------------------------------------------------ entry: stage and launch
if (-not $Mode) {
    $root = Join-Path $env:TEMP 'lsm-tray-test'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force "$root\logs" | Out-Null
    Copy-Item "$Src\*" $root
    foreach ($p in @(
        @{ n = 'svc-a'; j = '{ "name": "svc-a", "title": "Service A", "run": "x" }' },
        @{ n = 'svc-b'; j = '{ "name": "svc-b", "title": "Service B", "run": "x", "enabledByDefault": false }' },
        @{ n = 'hooks'; j = '{ "name": "hooks", "on": { "boot": "x" } }' })) {
        New-Item -ItemType Directory -Force "$root\plugins\$($p.n)" | Out-Null
        $p.j | Set-Content "$root\plugins\$($p.n)\plugin.json"
    }
    '{ "batteryLimit": 35, "pollSeconds": 15, "wslDistro": "Test" }' | Set-Content "$root\config.json"
    $env:LSM_TRAY_TEST = "$root\Tray.Tests.ps1"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\Tray.ps1" 2>&1
    $out | ForEach-Object { "$_" }
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    if (-not ($out -match '^RESULT .* 0 failed')) { exit 1 }
    return
}

# ------------------------------------------------------------ hook: mocks before the tray starts
if ($Mode -eq 'setup') {
    & (Get-Module ServerMode) {
        $script:FakePower = [pscustomobject]@{ onAC = $true; percent = 80; noBattery = $false }
        $script:Verbs = New-Object Collections.ArrayList
        function script:Get-PowerStatus { $script:FakePower }
        function script:Enable-PowerOverride { param($State) $State.serverPlan = 'test' }
        function script:Disable-PowerOverride { param($State) $State.serverPlan = $null }
        function script:Invoke-ServiceVerb { param($Service, $Verb) [void]$script:Verbs.Add("$($Service.name):$Verb"); [pscustomobject]@{ Code = 0; Output = '' } }
        function script:Invoke-Hidden { param($File, $Arguments) [void]$script:Verbs.Add("hidden:$Arguments"); [pscustomobject]@{ Code = 0; Output = '' } }
    }
    # Calls from Tray.ps1 (including WinForms event handlers) go to the
    # module's exported command, which keeps the original function; replace it.
    function global:Get-PowerStatus { & (Get-Module ServerMode) { $script:FakePower } }
    return
}

# ------------------------------------------------------------ hook: drive the tray
$script:pass = 0; $script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++ } else { $script:fail++; Write-Output "FAIL $Name $Detail" }
}
$mod = Get-Module ServerMode
function SetPower($ac, $pct) { & $mod { param($a, $p) $script:FakePower = [pscustomobject]@{ onAC = $a; percent = $p; noBattery = $false } } $ac $pct }
function Verbs { @(& $mod { $script:Verbs }) }

# Mocks for what Tray.ps1 itself calls.
$script:Notes = New-Object Collections.ArrayList
$script:Started = New-Object Collections.ArrayList
function Show-Note { param($Title, $Text) [void]$script:Notes.Add($Title) }
function Start-Process { param($FilePath, $ArgumentList) [void]$script:Started.Add("$FilePath $ArgumentList") }
function Start-ScheduledTask { param($TaskName) [void]$script:Started.Add("task:$TaskName") }

Add-Type -Namespace T -Name U -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);'
function Pump { 1..5 | ForEach-Object { [Windows.Forms.Application]::DoEvents() } }
$hitsField = [LSM.Flyout].GetField('hits', [Reflection.BindingFlags]'NonPublic,Instance')
function Hits {
    foreach ($h in $hitsField.GetValue($flyout)) {
        $t = $h.GetType()
        [pscustomobject]@{ R = $t.GetField('R').GetValue($h); Action = $t.GetField('Action').GetValue($h); Arg = $t.GetField('Arg').GetValue($h) }
    }
}
function Click([string]$Action, [string]$Arg) {
    $h = Hits | Where-Object { $_.Action -eq $Action -and (-not $Arg -or $_.Arg -eq $Arg) } | Select-Object -First 1
    if (-not $h) { throw "no click target $Action $Arg" }
    $x = [int]($h.R.X + $h.R.Width / 2); $y = [int]($h.R.Y + $h.R.Height / 2)
    $lp = [IntPtr](($y -shl 16) -bor $x)
    [void][T.U]::SendMessage($flyout.Handle, 0x200, [IntPtr]0, $lp)   # move
    [void][T.U]::SendMessage($flyout.Handle, 0x201, [IntPtr]1, $lp)   # left down
    [void][T.U]::SendMessage($flyout.Handle, 0x202, [IntPtr]0, $lp)   # left up
    Pump
}
function Key([int]$Vk) {
    $msg = New-Object Windows.Forms.Message
    $msg.HWnd = $flyout.Handle; $msg.Msg = 0x100; $msg.WParam = [IntPtr]$Vk
    [void]$flyout.PreProcessMessage([ref]$msg)
    Pump
}
function Open { $flyout.HiddenAt = [datetime]::MinValue; if ($flyout.Visible) { $flyout.HideFlyout() }; $flyout.HiddenAt = [datetime]::MinValue; Show-Flyout; Pump }
function Fresh { Update-State { param($s) $s.heartbeat = (Get-Date).ToString('o'); $s } | Out-Null }

$timer.Stop()   # the tray's own 5 s refresh; tests call Update-Tray themselves
Check 'mock power reaches the tray' ((Get-PowerStatus).percent -eq 80)

# B3/H1: open, contents, close
Fresh; Open
Check 'H1 flyout opens' $flyout.Visible
$rows = @(Hits | Where-Object Action -eq 'service')
Check 'G2 one row per service, hooks-only plugin not listed' ((($rows.Arg | Sort-Object) -join ',') -eq 'svc-a,svc-b') "rows=$($rows.Arg -join ',')"
Check 'H2 four footer buttons' (@(Hits | Where-Object { $_.Action -in 'quit', 'logs', 'stopall', 'screenoff' }).Count -eq 4)
Check 'G2 svc-b off by default shown off' (-not ($flyout.Services | Where-Object Name -eq 'svc-b').On)
Show-Flyout; Pump
Check 'H1 right-click again closes' (-not $flyout.Visible)
Show-Flyout; Pump
Check 'H1 right-click right after closing keeps it closed' (-not $flyout.Visible)

# B1/B3: toggle on AC
Open
Click 'toggle'
$s = Get-State
Check 'B3 card click turns server mode on' ($s.enabled -and $s.reason -eq 'on') "enabled=$($s.enabled) reason=$($s.reason)"
Check 'B3 flyout stays open and shows it' ($flyout.Visible -and $flyout.ServerOn)
Click 'toggle'
Check 'B3 second click turns it off' (-not (Get-State).enabled)

# G1: service switches
Click 'service' 'svc-b'
Check 'G1 switch on' ((Get-State).services.'svc-b' -eq $true)
Click 'service' 'svc-b'
Check 'G1 switch off' ((Get-State).services.'svc-b' -eq $false)
Click 'service' 'svc-a'
Check 'G1 default-on service switched off' ((Get-State).services.'svc-a' -eq $false)
Click 'service' 'svc-a'

# H3: keyboard
Open
Key 0x09; Key 0x0D
Check 'H3 Tab then Enter toggles server mode' ((Get-State).enabled -eq $true)
Key 0x09; Key 0x20
Check 'H3 next Tab + Space toggles the first service' ((Get-State).services.'svc-a' -eq $false) "svc-a=$((Get-State).services.'svc-a')"
Key 0x20
Key 0x1B
Check 'H3 Esc closes' (-not $flyout.Visible)

# G3: stop all
Open
& $mod { $script:Verbs.Clear() }
Update-State { param($s) $s.serviceStatus = [pscustomobject]@{ 'svc-a' = [pscustomobject]@{ status = 'running'; failures = 0; retryAt = $null } }; $s } | Out-Null
Click 'stopall'
$s = Get-State
Check 'G3 stop all switches every service off' (-not $s.services.'svc-a' -and -not $s.services.'svc-b')
Check 'G3 stop all stops them now' ((Verbs) -contains 'svc-a:stop' -and (Verbs) -contains 'svc-b:stop') "verbs=$((Verbs) -join ',')"
Check 'G3 statuses show stopped' ($s.serviceStatus.'svc-a'.status -eq 'stopped')
Check 'G3 tells you' ($Notes -contains 'All services stopped')

# H2: banner, screen off, logs
Update-State { param($s) $s.heartbeat = (Get-Date).AddMinutes(-10).ToString('o'); $s } | Out-Null
Update-Tray; Open
Check 'H2 banner when background checks stopped' (@(Hits | Where-Object Action -eq 'watchdog').Count -eq 1)
Click 'watchdog'
Check 'H2 banner restarts the watchdog task' ($Started -contains "task:$WatchdogTask") "started=$($Started -join ' | ')"
Fresh; Update-Tray; Update-Flyout
Check 'H2 banner gone when the watchdog is back' (@(Hits | Where-Object Action -eq 'watchdog').Count -eq 0)
Click 'screenoff'
Check 'H2 screen off closes the flyout' (-not $flyout.Visible)
Open; Click 'logs'
Check 'H2 open logs closes the flyout and opens the folder' (-not $flyout.Visible -and ($Started | Where-Object { $_ -like '*explorer.exe*logs*' })) "started=$($Started -join ' | ')"

# B2: low-battery prompt, every answer. Windows won't show a modal dialog
# without a desktop, so the dialog itself is replaced by one that answers as
# told; the dialog window (buttons, noticing the charger) is a manual check.
function Show-BatteryDialog { param($Percent, $Limit) $script:asked = "$Percent/$Limit"; if ($script:answer -eq 'charger') { SetPower $true $Percent }; $script:answer }
function Prompt([string]$Answer) {
    SetPower $false 20
    Set-ServerMode $false
    $script:asked = $null; $script:answer = $Answer
    Open; Click 'toggle'
    Get-State
}
$s = Prompt 'anyway'
Check 'B2 asks on low battery, with the right numbers' ($asked -eq '20/35') "asked=$asked"
Check 'B2 turn on anyway -> on, limit ignored' ($s.enabled -and $s.reason -eq 'on' -and $s.ignoreBatteryLimit) "reason=$($s.reason) ignore=$($s.ignoreBatteryLimit)"
$s = Prompt 'cancel'
Check 'B2 cancel or close -> stays off' (-not $s.enabled -and $s.reason -eq 'off')
$s = Prompt 'charger'
Check 'B2 plugging in while asked -> on, limit not ignored' ($s.enabled -and $s.reason -eq 'on' -and -not $s.ignoreBatteryLimit) "reason=$($s.reason) ignore=$($s.ignoreBatteryLimit)"
SetPower $false 50
Update-State { param($s) $s.enabled = $false; $s } | Out-Null
$script:asked = $null; Open; Click 'toggle'
Check 'B2 no prompt above the limit' (-not $asked -and (Get-State).enabled)
SetPower $false 20
$script:asked = $null; Click 'toggle'
Check 'B2 no prompt when turning off' (-not $asked -and -not (Get-State).enabled)
SetPower $true 80
Remove-Item Function:\Show-BatteryDialog

# I: notifications and icon for changes made elsewhere (the watchdog)
$Notes.Clear()
foreach ($c in @(@('on', 'Server mode resumed'), @('battery', 'Server mode paused'), @('off', 'Server mode is off'))) {
    Update-State { param($s) $s.reason = $c[0]; $s.battery = 20; $s.heartbeat = (Get-Date).ToString('o'); $s } | Out-Null
    $script:userToggled = $false
    Update-Tray
    Check "I notification when it changes to $($c[0])" ($Notes -contains $c[1]) "notes=$($Notes -join ' | ')"
    Check "I icon for $($c[0])" ($tray.Icon -eq $icons[$c[0]])
}
Update-State { param($s) $s.reason = 'battery'; $s } | Out-Null
Update-Tray
Check 'I tooltip text' ($tray.Text -match 'Paused \(battery 20%\)') "tip=$($tray.Text)"
$Notes.Clear(); Update-Tray
Check 'I no repeat notification without a change' ($Notes.Count -eq 0)

# H4: themes
foreach ($dark in $true, $false) {
    $ok = $true
    try { $flyout.SetTheme([LSM.Theme]::Load($Scale, $dark)); Open; Click 'service' 'svc-a'; $flyout.HideFlyout() } catch { $ok = $false; $err = "$_" }
    Check "H4 works in $(if ($dark) { 'dark' } else { 'light' }) theme" $ok $err
}

# Errors are reported, not fatal
function Set-ServerMode { throw 'simulated failure' }
$Notes.Clear(); Open; Click 'toggle'
Check 'errors show a notification' ($Notes -contains 'Something went wrong')
Check 'errors are logged' ((Get-Content (Join-Path $PSScriptRoot 'logs\tray.log') -Raw) -match 'simulated failure')
Remove-Item Function:\Set-ServerMode

# H2: quit (last)
Open; Click 'quit'
Check 'H2 quit hides the icon' (-not $tray.Visible)

Write-Output ("RESULT {0} passed, {1} failed" -f $pass, $fail)
