# Tray icon: left-click toggles server mode, right-click opens the menu.
# Badge: green = ON, amber = paused by the battery rule, none = OFF.
# -Preview battery shows the low-battery dialog on its own (for testing).
param([string]$Preview)
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'TrayUi.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing

$mutex = New-Object Threading.Mutex($false, 'Local\LaptopServerModeTray')
if (-not $Preview -and -not $mutex.WaitOne(0)) { exit }

[LSM.Win]::SetProcessDPIAware() | Out-Null
[Windows.Forms.Application]::EnableVisualStyles()

$AppTitle     = 'Laptop Server Mode'
$AppId        = 'LaptopServerMode'
$WatchdogTask = 'LaptopServerMode Watchdog'
$Dot          = [string][char]0x00B7

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
    $glyph = { param($code, $color) [LSM.Art]::Glyph($t, [string][char]$code, $t.Px(16), $color, 0.14) }
    $script:img = @{
        power   = & $glyph 0xE7E8 $t.Fg
        powerOn = & $glyph 0xE7E8 $t.Accent
        apps    = & $glyph 0xE71D $t.Fg
        moon    = & $glyph 0xE708 $t.Fg
        folder  = & $glyph 0xE838 $t.Fg
        warn    = & $glyph 0xE7BA $t.Warn
        stop    = & $glyph 0xE71A $t.Bad
        close   = & $glyph 0xE711 $t.Fg
        check   = & $glyph 0xE73E $t.Accent
        blank   = New-Object Drawing.Bitmap $t.Px(16), $t.Px(16)
    }

    # Notification identity: shows as "Laptop Server Mode" with our tile, not "Windows PowerShell".
    $tile = Join-Path $PSScriptRoot 'app.png'
    ([LSM.Art]::Tile($t, 256)).Save($tile, [Drawing.Imaging.ImageFormat]::Png)
    $reg = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    New-Item $reg -Force | Out-Null
    Set-ItemProperty $reg DisplayName $AppTitle
    Set-ItemProperty $reg IconUri $tile
    $true
}

function Set-MenuStyle {
    param($Menu)
    $Menu.Renderer = New-Object LSM.Renderer $T
    $Menu.BackColor = $T.Bg
    $Menu.Font = $T.Font(9)
    $Menu.ImageScalingSize = New-Object Drawing.Size $T.Px(16), $T.Px(16)
    $Menu.Padding = New-Object Windows.Forms.Padding $T.Px(4), $T.Px(4), $T.Px(4), $T.Px(4)
    $Menu.ShowCheckMargin = $false
    $Menu.ShowImageMargin = $true
}

function New-Item2 {
    param([string]$Text, $Image, [scriptblock]$OnClick, [string]$Role = '')
    $i = New-Object Windows.Forms.ToolStripMenuItem $Text
    $i.Image = $Image
    $i.Name = $Role
    $i.Padding = New-Object Windows.Forms.Padding $T.Px(2), $T.Px(5), $T.Px(2), $T.Px(5)
    if ($OnClick) { $i.add_Click($OnClick) }
    $i
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

function Get-PowerText {
    param($State)
    if ($State.onAC) { "plugged in, $($State.battery)%" } else { "on battery, $($State.battery)%" }
}

$script:lastReason = $null
function Update-Tray {
    if (Update-Theme) { Build-Menu }
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

    $miToggle.Name  = if ($s.enabled) { 'toggle-on' } else { 'toggle-off' }
    $miToggle.Image = if ($s.reason -eq 'on') { $img.powerOn } else { $img.power }
    $miStatus.Text = switch ($s.reason) {
        'on'      { "Lid and sleep ignored $Dot $(Get-PowerText $s)" }
        'battery' { "Paused at $($s.battery)% $Dot resumes when plugged in" }
        default   { "Normal power settings $Dot $(Get-PowerText $s)" }
    }
    $miWatchdog.Visible = -not $alive
    $menu.Invalidate()

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

# ---------------------------------------------------------------- menu

$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.add_Opened({ [LSM.Win]::Style($menu.Handle, $T) })

function Build-Menu {
    Set-MenuStyle $menu
    $menu.Items.Clear()

    $script:miToggle = New-Item2 'Server mode' $img.power { Invoke-Safely { Switch-ServerMode } } 'toggle-off'
    $miToggle.Font = $T.Font(10, 'Bold')
    $miToggle.ShortcutKeyDisplayString = '          '   # room for the switch
    $miToggle.Padding = New-Object Windows.Forms.Padding $T.Px(2), $T.Px(6), $T.Px(2), 0
    $script:miStatus = New-Item2 '' $img.blank $null
    $miStatus.Enabled = $false
    $miStatus.Font = $T.Font(8.5)
    $miStatus.Padding = New-Object Windows.Forms.Padding $T.Px(2), 0, $T.Px(2), $T.Px(4)

    $script:miServices = New-Item2 'Services' $img.apps $null
    Set-MenuStyle $miServices.DropDown
    $miServices.DropDown.add_Opened({ [LSM.Win]::Style($miServices.DropDown.Handle, $T) })
    [void]$miServices.DropDownItems.Add('(loading)')

    $script:miWatchdog = New-Item2 'Start watchdog' $img.warn {
        Invoke-Safely { Start-ScheduledTask -TaskName $WatchdogTask; Show-Note 'Starting watchdog' 'Server mode checks will resume in a few seconds.' }
    }

    $menu.Items.AddRange(@(
        $miToggle, $miStatus,
        (New-Object Windows.Forms.ToolStripSeparator),
        $miServices,
        (New-Item2 'Stop all services now' $img.stop {
            Invoke-Safely {
                Stop-AllServices
                Show-Note 'All services stopped' 'Claude and other services are off. Turn them back on from Services.'
            }
        }),
        (New-Item2 'Turn screen off now' $img.moon { [LSM.Win]::ScreenOff() }),
        (New-Item2 'Open logs' $img.folder { Start-Process explorer.exe (Join-Path $PSScriptRoot 'logs') }),
        $miWatchdog,
        (New-Object Windows.Forms.ToolStripSeparator),
        (New-Item2 'Quit tray' $img.close { $tray.Visible = $false; [Windows.Forms.Application]::Exit() })
    ))
    $menu.MinimumSize = New-Object Drawing.Size $T.Px(280), 0
}

# Services list is rebuilt every time the menu opens.
$menu.add_Opening({
    Invoke-Safely {
        $s = Get-State
        $dd = $miServices.DropDownItems
        $dd.Clear()
        foreach ($svc in @(Get-Services)) {
            $on = Test-ServiceEnabled $svc $s
            $st = $s.serviceStatus.PSObject.Properties[$svc.name]
            $status = if ($st) { $st.Value.status } else { 'stopped' }
            $role = switch ($status) { 'running' { 'status-good' } 'failing' { 'status-bad' } 'needs-setup' { 'status-warn' } default { 'status-none' } }
            if ($status -eq 'needs-setup') { $status = 'needs sign-in' }
            $item = New-Item2 $svc.title $(if ($on) { $img.check } else { $img.blank }) $null $role
            $item.ShortcutKeyDisplayString = (Get-Culture).TextInfo.ToTitleCase($status)
            $item.Tag = @{ name = $svc.name; on = $on }
            $item.add_Click({ Invoke-Safely { Set-ServiceEnabled $this.Tag.name (-not $this.Tag.on) } })
            [void]$dd.Add($item)
        }
        if ($dd.Count -eq 0) { $none = $dd.Add('No services installed'); $none.Enabled = $false }
    }
})

# ---------------------------------------------------------------- start

[void](Update-Theme)
if ($Preview -eq 'battery') { Show-BatteryDialog 28 35 -NoWait; exit }
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $icons.off
$tray.Text = $AppTitle
$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ if ($_.Button -eq 'Left') { Invoke-Safely { Switch-ServerMode } } })
Build-Menu
$tray.Visible = $true

# First run only: pin the icon next to the clock instead of the hidden overflow.
# Windows keys the entry by executable, and this tray runs as powershell.exe.
# Respects the user's choice afterwards.
function Show-TrayIconOnce {
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
[LSM.Win]::Trim()
$menu.add_Closed({ [LSM.Win]::Trim() })
[Windows.Forms.Application]::Run()
$tray.Dispose()
