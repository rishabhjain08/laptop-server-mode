# Tray icon: left-click toggles server mode, right-click opens the menu.
# Green = ON, amber = paused by the battery rule, grey = OFF.
Import-Module (Join-Path $PSScriptRoot 'ServerMode.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace LSM -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
'@

$mutex = New-Object Threading.Mutex($false, 'Local\LaptopServerModeTray')
if (-not $mutex.WaitOne(0)) { exit }

$AppTitle     = 'Laptop Server Mode'
$WatchdogTask = 'LaptopServerMode Watchdog'

function New-DotIcon {
    param([Drawing.Color]$Color)
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object Drawing.SolidBrush $Color), 4, 4, 24, 24)
    $g.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::White), 2), 4, 4, 24, 24)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icons = @{
    on      = New-DotIcon ([Drawing.Color]::FromArgb(34, 160, 80))
    battery = New-DotIcon ([Drawing.Color]::FromArgb(230, 150, 20))
    off     = New-DotIcon ([Drawing.Color]::FromArgb(130, 130, 130))
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = $icons.off
$tray.Visible = $true
$lastReason = $null

function Show-Note {
    param([string]$Text, [string]$Kind = 'Info')
    $tray.ShowBalloonTip(4000, $AppTitle, $Text, $Kind)
}

function Test-WatchdogAlive {
    param($State)
    if (-not $State.heartbeat) { return $false }
    $limit = [math]::Max(60, 4 * [int](Get-Config).pollSeconds)
    ((Get-Date) - [datetime]$State.heartbeat).TotalSeconds -lt $limit
}

function Update-Tray {
    $s = Get-State
    $alive = Test-WatchdogAlive $s
    # Without the watchdog, the tray applies the battery rule itself.
    if (-not $alive) { $s = Sync-ServerMode -Source tray }

    $text = switch ($s.reason) {
        'on'      { 'Server mode: ON' }
        'battery' { "Server mode: paused (battery $($s.battery)%)" }
        default   { 'Server mode: OFF' }
    }
    if (-not $alive) { $text += ' - watchdog down' }
    $tray.Icon = $icons[$s.reason]
    $tray.Text = $text.Substring(0, [math]::Min(63, $text.Length))
    $miStatus.Text = $text
    $miToggle.Text = if ($s.enabled) { 'Turn server mode OFF' } else { 'Turn server mode ON' }
    $miWatchdog.Visible = -not $alive

    if ($script:lastReason -and $s.reason -ne $script:lastReason) {
        switch ($s.reason) {
            'battery' { Show-Note "Battery at $($s.battery)%. Normal power settings apply until you plug in." 'Warning' }
            'on'      { Show-Note 'Server mode is ON. Lid close and idle sleep are ignored.' }
            'off'     { Show-Note 'Server mode is OFF. Normal power settings apply.' }
        }
    }
    $script:lastReason = $s.reason
}

function Switch-ServerMode {
    $s = Get-State
    if ($s.enabled) {
        Set-ServerMode $false
    } else {
        $conf = Get-Config
        $p = Get-PowerStatus
        $ignore = $false
        if (-not $p.onAC -and $p.percent -le $conf.batteryLimit) {
            $msg = "Battery is at $($p.percent)% (limit $($conf.batteryLimit)%). Plug in the charger first.`n`n" +
                   "Turn server mode on anyway? The battery limit will be ignored until the charger is next connected."
            $answer = [Windows.Forms.MessageBox]::Show($msg, $AppTitle, 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            $ignore = $true
        }
        Set-ServerMode $true -IgnoreBatteryLimit:$ignore
    }
    Update-Tray
}

function Invoke-Safely {
    param([scriptblock]$Action)
    try { & $Action } catch { Write-Log "Tray error: $_" 'tray'; Show-Note "Error: $_" 'Error' }
}

# ---------------------------------------------------------------- menu

$menu = New-Object Windows.Forms.ContextMenuStrip
$miStatus = New-Object Windows.Forms.ToolStripMenuItem 'Server mode'
$miStatus.Enabled = $false
$miToggle = New-Object Windows.Forms.ToolStripMenuItem 'Turn server mode ON'
$miToggle.Font = New-Object Drawing.Font($miToggle.Font, [Drawing.FontStyle]::Bold)
$miToggle.add_Click({ Invoke-Safely { Switch-ServerMode } })
$miServices = New-Object Windows.Forms.ToolStripMenuItem 'Services'
$miScreen = New-Object Windows.Forms.ToolStripMenuItem 'Turn screen off now'
$miScreen.add_Click({
    # WM_SYSCOMMAND / SC_MONITORPOWER / 2 = off. Any input turns it back on.
    [LSM.User32]::PostMessage([IntPtr]0xffff, 0x0112, [IntPtr]0xF170, [IntPtr]2) | Out-Null
})
$miLogs = New-Object Windows.Forms.ToolStripMenuItem 'Open logs'
$miLogs.add_Click({ Start-Process explorer.exe (Join-Path $PSScriptRoot 'logs') })
$miWatchdog = New-Object Windows.Forms.ToolStripMenuItem 'Start watchdog'
$miWatchdog.add_Click({ Invoke-Safely { Start-ScheduledTask -TaskName $WatchdogTask; Show-Note 'Watchdog starting...' } })
$miExit = New-Object Windows.Forms.ToolStripMenuItem 'Exit tray (server mode stays as is)'
$miExit.add_Click({ $tray.Visible = $false; [Windows.Forms.Application]::Exit() })

[void]$menu.Items.Add($miStatus)
[void]$menu.Items.Add($miToggle)
[void]$menu.Items.Add('-')
[void]$menu.Items.Add($miServices)
[void]$menu.Items.Add($miScreen)
[void]$menu.Items.Add($miLogs)
[void]$menu.Items.Add($miWatchdog)
[void]$menu.Items.Add('-')
[void]$menu.Items.Add($miExit)

# Rebuild the services list each time the menu opens.
$menu.add_Opening({
    Invoke-Safely {
        $s = Get-State
        $miServices.DropDownItems.Clear()
        foreach ($svc in @(Get-Services)) {
            $st = $s.serviceStatus.PSObject.Properties[$svc.name]
            $label = if ($st) { "$($svc.title) - $($st.Value.status)" } else { $svc.title }
            $item = New-Object Windows.Forms.ToolStripMenuItem $label
            $item.Checked = Test-ServiceEnabled $svc $s
            $item.Tag = $svc.name
            $item.add_Click({ Invoke-Safely { Set-ServiceEnabled $this.Tag (-not $this.Checked) } })
            [void]$miServices.DropDownItems.Add($item)
        }
        if ($miServices.DropDownItems.Count -eq 0) {
            $none = $miServices.DropDownItems.Add('(no services installed)')
            $none.Enabled = $false
        }
    }
})

$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({ if ($_.Button -eq 'Left') { Invoke-Safely { Switch-ServerMode } } })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 5000
$timer.add_Tick({ Invoke-Safely { Update-Tray } })
$timer.Start()

Invoke-Safely { Update-Tray }
Write-Log "Tray started (pid $PID)" 'tray'
[Windows.Forms.Application]::Run()
$tray.Dispose()
