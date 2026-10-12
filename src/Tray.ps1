# Tray icon: left-click toggles server mode, right-click opens the flyout.
# Badge: green = ON, amber = paused by the battery rule, none = OFF.
# -Preview battery shows the low-battery dialog on its own (for testing).
# -Preview flyout -Out <folder> saves PNGs of the flyout in both themes.
param([string]$Preview, [string]$Out)
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force
# Test seam: tests/Tray.Tests.ps1 swaps in mocks here and drives the tray at
# the end instead of the message loop. Unset in normal use.
$TestScript = $env:LSM_TRAY_TEST
if ($TestScript) { . $TestScript 'setup' }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'TrayUi.cs'), (Join-Path $PSScriptRoot 'Flyout.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing

$mutex = New-Object Threading.Mutex($false, 'Local\LaptopServerModeTray')
if (-not $Preview -and -not $mutex.WaitOne(0)) { exit }

[LSM.Win]::SetProcessDPIAware() | Out-Null
[Windows.Forms.Application]::EnableVisualStyles()

$AppTitle     = 'Laptop Server Mode'
# Notification identity. Each fresh install gets its own id (app.id, written by
# Install-Tasks.ps1): Windows caches an id's name and icon, and an uninstall can
# leave it cached without them, showing "LaptopServerMode" and no icon.
$idFile = Join-Path $PSScriptRoot 'app.id'
$AppId  = if (Test-Path $idFile) { (Get-Content $idFile -Raw).Trim() } else { 'LaptopServerMode' }
$WatchdogTask = 'LaptopServerMode Watchdog'

$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$Scale = $g.DpiX / 96
$g.Dispose()

# ---------------------------------------------------------------- theme + icons

$script:themeKey = $null
function Update-Theme {
    $t = [LSM.Theme]::Load($Scale)
    $key = "$($t.Dark)/$($t.TaskbarDark)/$($t.Accent)"
    if ($key -eq $script:themeKey) { return $false }
    $script:themeKey = $key
    $script:T = $t
    $size = [Windows.Forms.SystemInformation]::SmallIconSize.Width
    $script:icons = @{
        on      = [LSM.Art]::Tray($t, $size, $t.Good, $false)
        battery = [LSM.Art]::Tray($t, $size, $t.Warn, $false)
        off     = [LSM.Art]::Tray($t, $size, $null, $true)
    }
    if ($script:flyout) { $flyout.SetTheme($t) }

    # Notification identity: shows as "Laptop Server Mode" with our tile, not "Windows PowerShell".
    $tile = Join-Path $PSScriptRoot 'app.png'
    ([LSM.Art]::Tile($t, 256)).Save($tile, [Drawing.Imaging.ImageFormat]::Png)
    # Same tile as an .ico (PNG inside, sharp at every size) for the Start menu shortcut.
    $png = [IO.File]::ReadAllBytes($tile)
    $w = New-Object IO.BinaryWriter ([IO.File]::Create((Join-Path $PSScriptRoot 'app.ico')))
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)                  # icon file, 1 image
    $w.Write([byte[]](0, 0, 0, 0)); $w.Write([uint16]1); $w.Write([uint16]32)       # 256x256, 32-bit
    $w.Write([uint32]$png.Length); $w.Write([uint32]22); $w.Write($png); $w.Close()
    if (-not $TestScript) {
        $reg = "HKCU:\Software\Classes\AppUserModelId\$AppId"
        New-Item $reg -Force | Out-Null
        Set-ItemProperty $reg DisplayName $AppTitle
        Set-ItemProperty $reg IconUri $tile
    }
    $true
}

# ---------------------------------------------------------------- notifications

function Show-Note {
    param([string]$Title, [string]$Text)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $esc = [Security.SecurityElement]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$($esc::Escape($Title))</text><text>$($esc::Escape($Text))</text></binding></visual><audio silent=`"true`"/></toast>")
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show((New-Object Windows.UI.Notifications.ToastNotification $xml))
    } catch {
        $tray.ShowBalloonTip(4000, $Title, $Text, 'Info')
    }
}

# ---------------------------------------------------------------- battery dialog

# Asks to plug in the charger. Returns 'charger' (plugged in while waiting),
# 'anyway' or 'cancel'.
function Show-BatteryDialog {
    param([int]$Percent, [int]$Limit, [switch]$NoWait)
    $f = New-Object Windows.Forms.Form
    $f.Text = $AppTitle
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; $f.ShowIcon = $false
    $f.BackColor = $T.Bg; $f.ForeColor = $T.Fg; $f.Font = $T.Font(9.5)
    $f.AutoScaleMode = 'None'
    $pad = $T.Px(24); $w = $T.Px(440)
    $f.ClientSize = New-Object Drawing.Size $w, $T.Px(232)

    $icon = New-Object Windows.Forms.PictureBox
    $icon.Image = [LSM.Art]::Glyph($T, [string][char]0xEBA3, $T.Px(28), $T.Warn)
    $icon.SizeMode = 'AutoSize'; $icon.Location = New-Object Drawing.Point $pad, $T.Px(26)

    $title = New-Object Windows.Forms.Label
    $title.Text = "Battery is at $Percent%"; $title.Font = $T.Font(14, 'Bold'); $title.AutoSize = $true
    $title.Location = New-Object Drawing.Point ($pad + $T.Px(40)), $T.Px(22)

    $body = New-Object Windows.Forms.Label
    $body.Text = "Plug in your charger to keep the laptop awake. Server mode turns on as soon as it's connected."
    $body.Location = New-Object Drawing.Point $pad, $T.Px(72)
    $body.Size = New-Object Drawing.Size ($w - 2 * $pad), $T.Px(44)

    $note = New-Object Windows.Forms.Label
    $note.Text = "Turning it on anyway ignores the $Limit% limit until the charger is next connected."
    $note.ForeColor = $T.Fg2; $note.Font = $T.Font(8.5)
    $note.Location = New-Object Drawing.Point $pad, $T.Px(118)
    $note.Size = New-Object Drawing.Size ($w - 2 * $pad), $T.Px(36)

    $footer = New-Object Windows.Forms.Panel
    $footer.Dock = 'Bottom'; $footer.Height = $T.Px(68)
    $footer.BackColor = if ($T.Dark) { [Drawing.Color]::FromArgb(32, 32, 32) } else { [Drawing.Color]::FromArgb(243, 243, 243) }

    $waiting = New-Object Windows.Forms.Label
    $waiting.Text = "Waiting for charger$([char]0x2026)"; $waiting.ForeColor = $T.Fg2; $waiting.AutoSize = $true
    $waiting.Location = New-Object Drawing.Point $pad, $T.Px(24)

    $bw = $T.Px(130); $bh = $T.Px(32); $by = ($footer.Height - $bh) / 2
    $cancel = New-Object LSM.FlatButton
    $cancel.T = $T; $cancel.Text = 'Cancel'; $cancel.Size = New-Object Drawing.Size $T.Px(96), $bh
    $cancel.Location = New-Object Drawing.Point ($w - $pad - $T.Px(96)), $by
    $cancel.DialogResult = 'Cancel'
    $anyway = New-Object LSM.FlatButton
    $anyway.T = $T; $anyway.Primary = $true; $anyway.Text = 'Turn on anyway'; $anyway.Size = New-Object Drawing.Size $bw, $bh
    $anyway.Location = New-Object Drawing.Point ($cancel.Left - $T.Px(8) - $bw), $by
    $anyway.DialogResult = 'Yes'
    $footer.Controls.AddRange(@($waiting, $anyway, $cancel))

    $f.Controls.AddRange(@($icon, $title, $body, $note, $footer))
    $f.AcceptButton = $anyway; $f.CancelButton = $cancel
    $f.add_HandleCreated({ [LSM.Win]::Style($f.Handle, $T) })

    $script:pluggedIn = $false
    $poll = New-Object Windows.Forms.Timer
    $poll.Interval = 1000
    $poll.add_Tick({ if ((Get-PowerStatus).onAC) { $script:pluggedIn = $true; $f.DialogResult = 'OK' } })
    if (-not $NoWait) { $poll.Start() }
    $result = $f.ShowDialog()
    $poll.Dispose(); $f.Dispose()

    if ($script:pluggedIn) { 'charger' } elseif ($result -eq 'Yes') { 'anyway' } else { 'cancel' }
}

# ---------------------------------------------------------------- state -> UI

function Test-WatchdogAlive {
    param($State)
    if (-not $State.heartbeat) { return $false }
    $limit = [math]::Max(60, 4 * [int](Get-Config).pollSeconds)
    ((Get-Date) - [datetime]$State.heartbeat).TotalSeconds -lt $limit
}

$script:lastReason = $null
function Update-Tray {
    [void](Update-Theme)
    $s = Get-State
    $alive = Test-WatchdogAlive $s
    # Without the watchdog, the tray applies the battery rule itself.
    if (-not $alive) { $s = Sync-ServerMode -Source tray }

    $tray.Icon = $icons[$s.reason]
    $tip = switch ($s.reason) {
        'on'      { "$AppTitle`nOn" }
        'battery' { "$AppTitle`nPaused (battery $($s.battery)%)" }
        default   { "$AppTitle`nOff" }
    }
    $tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))

    $script:watchdogDown = -not $alive
    if ($flyout.Visible) { Update-Flyout $s }

    if ($script:lastReason -and $s.reason -ne $script:lastReason -and -not $script:userToggled) {
        switch ($s.reason) {
            'battery' { Show-Note 'Server mode paused' "Battery at $($s.battery)%. Normal power settings apply until you plug in." }
            'on'      { Show-Note 'Server mode resumed' 'Lid close and idle sleep are ignored again.' }
            'off'     { Show-Note 'Server mode is off' 'Normal power settings apply.' }
        }
    }
    $script:userToggled = $false
    $script:lastReason = $s.reason
}

function Switch-ServerMode {
    $s = Get-State
    $script:userToggled = $true
    if ($s.enabled) {
        Set-ServerMode $false
    } else {
        $conf = Get-Config
        $p = Get-PowerStatus
        $ignore = $false
        if (-not $p.onAC -and $p.percent -le $conf.batteryLimit) {
            $answer = Show-BatteryDialog $p.percent $conf.batteryLimit
            if ($answer -eq 'cancel') { return }
            $ignore = $answer -eq 'anyway'
        }
        Set-ServerMode $true -IgnoreBatteryLimit:$ignore
    }
    Update-Tray
}

function Invoke-Safely {
    param([scriptblock]$Action)
    try { & $Action } catch { Write-Log "Tray error: $_" 'tray'; Show-Note 'Something went wrong' "$_" }
}

# ---------------------------------------------------------------- flyout

$script:watchdogDown = $false

function Update-Flyout {
    param($State = (Get-State))
    $flyout.ServerOn = $State.enabled
    $flyout.Reason = $State.reason
    $flyout.Battery = [int]$State.battery
    $flyout.OnAC = [bool]$State.onAC
    $flyout.NoBattery = (Get-PowerStatus).noBattery
    $flyout.WatchdogDown = $watchdogDown
    $flyout.Services.Clear()
    foreach ($svc in @(Get-Services)) {
        $st = $State.serviceStatus.PSObject.Properties[$svc.name]
        $row = New-Object LSM.FlyoutService
        $row.Name = $svc.name
        $row.Title = $svc.title
        $row.On = Test-ServiceEnabled $svc $State
        $row.Status = if ($st) { $st.Value.status } else { 'stopped' }
        $row.Detail = if ($st -and $st.Value.PSObject.Properties['detail'] -and $st.Value.status -in 'needs-setup', 'failing') { [string]$st.Value.detail } else { $null }
        $flyout.Services.Add($row)
    }
    $flyout.Relayout()
}

function Invoke-FlyoutAction {
    param([string]$Action, [string]$Arg)
    switch ($Action) {
        'toggle'    { Switch-ServerMode }
        'service'   { $on = Test-ServiceEnabled (Get-Services | Where-Object name -eq $Arg) (Get-State); Set-ServiceEnabled $Arg (-not $on) }
        'watchdog'  { Start-ScheduledTask -TaskName $WatchdogTask; Show-Note 'Restarting background checks' 'Server mode checks resume in a few seconds.' }
        'stopall'   {
            Stop-AllServices
            Show-Note 'All services stopped' 'Turn them back on from the tray icon when you need them.'
        }
        'screenoff' { [LSM.Win]::ScreenOff() }
        'logs'      { Start-Process explorer.exe (Join-Path $PSScriptRoot 'logs') }
        'quit'      {
            # Tells the watchdog not to bring the tray back (it does after a crash).
            Update-State { param($s) $s | Add-Member -Force trayQuit $true; $s } | Out-Null
            $tray.Visible = $false; [Windows.Forms.Application]::Exit(); return
        }
    }
    if ($flyout.Visible) { Update-Flyout }
}

[void](Update-Theme)
$flyout = New-Object LSM.Flyout $T
$flyout.add_ActionRequested({ param($sender, $e) Invoke-Safely { Invoke-FlyoutAction $e.Action $e.Arg } })
$flyout.add_VisibleChanged({ if (-not $flyout.Visible) { [LSM.Win]::Trim() } })

function Show-Flyout {
    # A right-click that closed the flyout (by taking focus) shouldn't reopen it.
    if ($flyout.Visible -or ((Get-Date) - $flyout.HiddenAt).TotalMilliseconds -lt 300) { $flyout.HideFlyout(); return }
    Update-Flyout
    $flyout.ShowAt([Windows.Forms.Cursor]::Position)
}

# ---------------------------------------------------------------- start

if ($Preview -eq 'battery') { Show-BatteryDialog 28 35 -NoWait; exit }
if ($Preview -eq 'flyout') {
    foreach ($dark in $true, $false) {
        $flyout.SetTheme([LSM.Theme]::Load($Scale, $dark))
        $name = if ($dark) { 'dark' } else { 'light' }
        Update-Flyout
        $flyout.SavePreview((Join-Path $Out "flyout-$name.png"), -1)
        foreach ($case in 'battery', 'off') {
            $flyout.Reason = $case; $flyout.ServerOn = $case -ne 'off'; $flyout.WatchdogDown = $case -eq 'off'
            $flyout.Services[0].Status = if ($case -eq 'off') { 'needs-setup' } else { 'failing' }
            $flyout.Services[0].Detail = if ($case -eq 'off') { 'WSL is not installed (or has no Linux distro).' } else { 'Exit code 1' }
            $flyout.SavePreview((Join-Path $Out "flyout-$name-$case.png"), 1)
        }
    }
    exit
}
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $icons.off
$tray.Text = $AppTitle
$tray.add_MouseClick({
    if ($_.Button -eq 'Left') { Invoke-Safely { Switch-ServerMode } }
    if ($_.Button -eq 'Right') { Invoke-Safely { Show-Flyout } }
})
$tray.Visible = $true

# First run only: pin the icon next to the clock instead of the hidden overflow.
# Windows keys the entry by executable, and this tray runs as powershell.exe.
# Respects the user's choice afterwards.
function Show-TrayIconOnce {
    if ($TestScript) { return }
    $s = Get-State
    if ($s.PSObject.Properties['trayPinned'] -and $s.trayPinned) { return }
    $entry = Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' -ErrorAction SilentlyContinue |
        Where-Object {
            $p = Get-ItemProperty $_.PSPath
            $p.PSObject.Properties['ExecutablePath'] -and $p.ExecutablePath -like '*\WindowsPowerShell\v1.0\powershell.exe'
        } | Select-Object -First 1
    if (-not $entry) { return }
    Set-ItemProperty $entry.PSPath IsPromoted 1 -Type DWord
    Update-State { param($x) $x | Add-Member -Force trayPinned $true; $x } | Out-Null
    Write-Log 'Tray icon pinned to the taskbar' 'tray'
    Show-Note "$AppTitle is ready" 'Click the laptop icon next to the clock to turn server mode on.'
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Invoke-Safely { Update-Tray; Show-TrayIconOnce } })
$timer.Start()

Invoke-Safely { Update-Tray }
Write-Log "Tray started (pid $PID)" 'tray'
if (-not $TestScript) { Update-State { param($s) $s | Add-Member -Force trayQuit $false; $s } | Out-Null }
[LSM.Win]::Trim()
if ($TestScript) { . $TestScript 'run'; $tray.Dispose(); return }
[Windows.Forms.Application]::Run()
$tray.Dispose()
