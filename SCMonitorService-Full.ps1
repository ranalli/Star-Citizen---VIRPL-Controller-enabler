#Requires -Version 5.1
<#
  SCMonitorService-Full.ps1
  System Tray application that monitors for the RSI Launcher.
  Enables HID game controllers and launches JoyToKey when opened,
  then disables controllers and closes JoyToKey on exit.

  - Config + log: %LOCALAPPDATA%\SCMonitor\ (config.json, service_log.txt)
  - Optional custom icon: put sc.png or sc.ico next to this script or in %LOCALAPPDATA%\SCMonitor\.
#>

$script:RepoUrl    = 'https://raw.githubusercontent.com/ranalli/Star-Citizen---VIRPL-Controller-enabler/refs/heads/main/SCMonitorService-Full.ps1'
$script:AppDir     = Join-Path $env:LOCALAPPDATA 'SCMonitor'
$script:LocalPs1   = Join-Path $script:AppDir 'SCMonitorService-Full.ps1'
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:LogPath    = Join-Path $script:AppDir 'service_log.txt'
$script:TaskName   = 'SCMonitorService'
$script:PollMs     = 3000

# ---------- Auto-elevate (required for PnP device toggling & Scheduled Task) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`""
        )
    } else {
        $cmd = "irm '$script:RepoUrl' | iex"
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-Command', $cmd
        )
    }
    exit
}

# ---------- Single instance ----------
$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\SCMonitorService_SingleInstance')
if (-not $script:Mutex.WaitOne(0)) {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        'Star Citizen Controller Monitor is already running (check the system tray).',
        'SC Controller Monitor'
    )
    exit
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- Native console hiding ----------
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Win32Console
{
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public static void Hide() { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
}
'@

[Win32Console]::Hide()

# ---------- Paths, Logging & Icon ----------
$baseDir = if ($PSCommandPath) { Split-Path $PSCommandPath } else { $script:AppDir }
$script:IconPng = Join-Path $baseDir 'sc.png'
$script:IconIco = Join-Path $baseDir 'sc.ico'

# Built-in 32x32 PNG tray icon (Base64 encoded)
$script:EmbeddedIconBase64 = 'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAA+UlEQVR4nGNgGGDAiEuibCfDf2pa1OWO3S4MQWpbTMghKBxky+fEClHV4pTF77A6gokelqObiWwXEz6FtHQEDDAiu4hYy5GDkxwHw/R3uTMwYoQAKZZj45MKWPBJvtV2hrOFr+4laNi7tW/hbKFgYaIcgDMEkC3HxsdnOTY+yQ6gF6CLA97uwZ1OaO4AmOW4HDEyomDUAaMOGHXAgDpA2EUIhaa7A/BZTjcH4AM4HYBe/xNqD6DX/8S2B/A2SIhphJBjKTJgYmBANJOJaV6htwFJbRMitwcZGJD6BbRuliNbjuwAJnQBdIW0tJyBYbB1zWjpEFyd0wEHAHVoV/vyxlG3AAAAAElFTkSuQmCC'

if (-not (Test-Path $script:AppDir)) {
    New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
}

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 1MB) {
            Remove-Item $script:LogPath -Force
        }
        Add-Content -Path $script:LogPath -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

Write-Log 'SC Monitor Tray App Initializing...'

# ---------- Launch at Startup (Self-Installing Elevated Scheduled Task) ----------
function Test-Startup {
    return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}

function Set-Startup([bool]$Enable) {
    if ($Enable) {
        if (-not (Test-Path $script:AppDir)) {
            New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        }

        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            if ($PSCommandPath -ne $script:LocalPs1) {
                Copy-Item -Path $PSCommandPath -Destination $script:LocalPs1 -Force
            }
        } else {
            Invoke-WebRequest -Uri $script:RepoUrl -OutFile $script:LocalPs1 -UseBasicParsing
        }

        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:LocalPs1)
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT15S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew

        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log 'Launch at Startup enabled (scheduled task created).'
    } else {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log 'Launch at Startup disabled (scheduled task removed).'
    }
}

# ---------- Path Detection & Config ----------
function Get-ExecutablePath {
    param (
        [string]$AppName,
        [string[]]$PossiblePaths,
        [string]$Filter
    )

    foreach ($path in $PossiblePaths) {
        if (Test-Path $path) {
            Write-Log "Auto-detected $AppName at: $path"
            return $path
        }
    }

    Write-Log "$AppName not found automatically. Prompting user..."
    [void][System.Windows.Forms.MessageBox]::Show(
        "Could not automatically locate $AppName. Please select its executable manually.",
        "Locate $AppName",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )

    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = $Filter
    $dlg.Title = "Select $AppName Executable"

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $selected = $dlg.FileName
        $dlg.Dispose()
        Write-Log "User manually selected $AppName at: $selected"
        return $selected
    } else {
        $dlg.Dispose()
        Write-Log "User cancelled selection for $AppName. Exiting script."
        [void][System.Windows.Forms.MessageBox]::Show(
            "The script requires $AppName to function. Exiting.",
            'Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit
    }
}

function Initialize-Paths {
    param ([bool]$ForceReset = $false)

    $defaultRsiPaths = @(
        'C:\Program Files\Roberts Space Industries\RSI Launcher\RSI Launcher.exe',
        'C:\Program Files (x86)\Roberts Space Industries\RSI Launcher\RSI Launcher.exe'
    )
    $defaultJoyPaths = @(
        'C:\Program Files (x86)\JoyToKey\JoyToKey.exe',
        'C:\Program Files\JoyToKey\JoyToKey.exe',
        "$HOME\Desktop\JoyToKey\JoyToKey.exe"
    )

    if (-not $ForceReset -and (Test-Path $script:ConfigPath)) {
        try {
            $cfg = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            if ($cfg.RsiPath -and (Test-Path $cfg.RsiPath) -and $cfg.JoyPath -and (Test-Path $cfg.JoyPath)) {
                $script:RsiPath = $cfg.RsiPath
                $script:JoyPath = $cfg.JoyPath
                Write-Log 'Loaded active paths from config.json.'
                return
            }
        } catch {
            Write-Log "Config load failed: $($_.Exception.Message)"
        }
    }

    $autoDetect = $true
    if ($ForceReset) {
        $response = [System.Windows.Forms.MessageBox]::Show(
            "Would you like to try detecting the applications automatically? Clicking 'No' opens manual setup.",
            'Reset Paths',
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($response -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($response -eq [System.Windows.Forms.DialogResult]::No) { $autoDetect = $false }
    }

    if ($autoDetect) {
        $script:RsiPath = Get-ExecutablePath -AppName 'RSI Launcher' -PossiblePaths $defaultRsiPaths -Filter 'RSI Launcher (RSI Launcher.exe)|RSI Launcher.exe'
        $script:JoyPath = Get-ExecutablePath -AppName 'JoyToKey' -PossiblePaths $defaultJoyPaths -Filter 'JoyToKey (JoyToKey.exe)|JoyToKey.exe'
    } else {
        $script:RsiPath = Get-ExecutablePath -AppName 'RSI Launcher' -PossiblePaths @() -Filter 'RSI Launcher (RSI Launcher.exe)|RSI Launcher.exe'
        $script:JoyPath = Get-ExecutablePath -AppName 'JoyToKey' -PossiblePaths @() -Filter 'JoyToKey (JoyToKey.exe)|JoyToKey.exe'
    }

    try {
        [pscustomobject]@{
            RsiPath = $script:RsiPath
            JoyPath = $script:JoyPath
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8
        Write-Log 'Paths successfully saved to config.json.'
    } catch {
        Write-Log "Config save failed: $($_.Exception.Message)"
    }
}

Initialize-Paths -ForceReset $false

$script:RsiProcessName = [System.IO.Path]::GetFileNameWithoutExtension($script:RsiPath)
$script:JoyProcessName = [System.IO.Path]::GetFileNameWithoutExtension($script:JoyPath)
$script:GameIsRunning  = $false
$script:IsPaused       = $false

# ---------- Controller & Process Helpers ----------
function Set-ControllersState([bool]$Enable) {
    $controllers = Get-PnpDevice | Where-Object {
        ($_.FriendlyName -like 'HID-compliant game controller*') -and ($_.Status -ne 'Unknown')
    }

    if ($controllers) {
        foreach ($ctrl in $controllers) {
            if ($Enable) {
                Enable-PnpDevice -InstanceId $ctrl.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Enabled device: $($ctrl.FriendlyName)"
            } else {
                Disable-PnpDevice -InstanceId $ctrl.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "Disabled device: $($ctrl.FriendlyName)"
            }
        }
    } else {
        Write-Log 'Warning: No HID game controllers discovered.'
    }
}

function Test-ProcessRunning([string]$ProcName) {
    $target = $ProcName.ToLowerInvariant()
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            if ($p.ProcessName.ToLowerInvariant() -eq $target) { return $true }
        } catch { } finally {
            $p.Dispose()
        }
    }
    return $false
}

# ---------- System Tray Icon & Menu ----------
function Convert-BitmapToIcon([System.Drawing.Bitmap]$SourceBmp) {
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($SourceBmp, 0, 0, 32, 32)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:Tray = New-Object System.Windows.Forms.NotifyIcon
$script:Tray.Icon = [System.Drawing.SystemIcons]::Information

if (Test-Path $script:IconPng) {
    try {
        $src = New-Object System.Drawing.Bitmap($script:IconPng)
        $script:Tray.Icon = Convert-BitmapToIcon $src
        $src.Dispose()
    } catch { Write-Log "PNG icon load failed: $($_.Exception.Message)" }
} elseif (Test-Path $script:IconIco) {
    try { $script:Tray.Icon = New-Object System.Drawing.Icon($script:IconIco) }
    catch { Write-Log "ICO icon load failed: $($_.Exception.Message)" }
} elseif ($script:EmbeddedIconBase64) {
    try {
        $bytes = [Convert]::FromBase64String($script:EmbeddedIconBase64)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $src = New-Object System.Drawing.Bitmap($ms)
        $script:Tray.Icon = Convert-BitmapToIcon $src
        $src.Dispose()
        $ms.Dispose()
    } catch { Write-Log "Embedded icon load failed: $($_.Exception.Message)" }
}

function Update-Tooltip {
    $state = if ($script:IsPaused) { 'Paused' } elseif ($script:GameIsRunning) { 'Active' } else { 'Idle' }
    $text = "SC Controller Monitor - $state"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $script:Tray.Text = $text
}

Update-Tooltip
$script:Tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miPause = New-Object System.Windows.Forms.ToolStripMenuItem('Pause')
$miPause.CheckOnClick = $true

$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem('Launch at Startup')
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-Startup

$miReset = New-Object System.Windows.Forms.ToolStripMenuItem('Reset Paths')
$miLogs  = New-Object System.Windows.Forms.ToolStripMenuItem('Open Config / Logs Folder')
$miExit  = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')

[void]$menu.Items.Add($miPause)
[void]$menu.Items.Add($miStartup)
[void]$menu.Items.Add($miReset)
[void]$menu.Items.Add($miLogs)
[void]$menu.Items.Add('-')
[void]$menu.Items.Add($miExit)
$script:Tray.ContextMenuStrip = $menu

$miPause.Add_Click({
    $script:IsPaused = $miPause.Checked
    Update-Tooltip
    Write-Log $(if ($script:IsPaused) { 'Monitoring loop paused by user.' } else { 'Monitoring loop resumed by user.' })
})

$miStartup.Add_Click({
    try {
        Set-Startup $miStartup.Checked
    } catch {
        $miStartup.Checked = Test-Startup
        Write-Log "Startup toggle failed: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show(
            "Failed to update startup setting: $($_.Exception.Message)",
            'SC Controller Monitor',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
})

$miReset.Add_Click({
    Write-Log 'User triggered path reset.'
    Initialize-Paths -ForceReset $true
    $script:RsiProcessName = [System.IO.Path]::GetFileNameWithoutExtension($script:RsiPath)
    $script:JoyProcessName = [System.IO.Path]::GetFileNameWithoutExtension($script:JoyPath)
})

$miLogs.Add_Click({
    Start-Process explorer.exe $script:AppDir
})

$miExit.Add_Click({
    Write-Log 'Exiting Tray Application...'
    $script:Timer.Stop()
    if ($script:GameIsRunning) {
        Set-ControllersState $false
        Stop-Process -Name $script:JoyProcessName -Force -ErrorAction SilentlyContinue
        $script:GameIsRunning = $false
    }
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---------- Main Monitor Loop ----------
function Check-Launcher {
    if ($script:IsPaused) { return }

    $rsiRunning = Test-ProcessRunning $script:RsiProcessName

    if ($rsiRunning -and -not $script:GameIsRunning) {
        Write-Log 'RSI Launcher detected. Enabling controllers and JoyToKey...'
        $script:GameIsRunning = $true
        Update-Tooltip

        Set-ControllersState $true

        if (-not (Test-ProcessRunning $script:JoyProcessName)) {
            Start-Process -FilePath $script:JoyPath
            Write-Log 'Started JoyToKey.'
        }
    } elseif (-not $rsiRunning -and $script:GameIsRunning) {
        Write-Log 'RSI Launcher closed. Disabling controllers and closing JoyToKey...'
        $script:GameIsRunning = $false
        Update-Tooltip

        Set-ControllersState $false
        Stop-Process -Name $script:JoyProcessName -Force -ErrorAction SilentlyContinue
        Write-Log 'Closed JoyToKey.'
    }
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = $script:PollMs
$script:Timer.Add_Tick({
    try { Check-Launcher }
    catch { Write-Log "Tick error: $($_.Exception.Message)" }
})

Write-Log 'Tray Loop Engine Started Successfully.'
Check-Launcher
$script:Timer.Start()

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    if ($script:GameIsRunning) {
        Set-ControllersState $false
        Stop-Process -Name $script:JoyProcessName -Force -ErrorAction SilentlyContinue
    }
    try { $script:Mutex.ReleaseMutex() } catch { }
    Write-Log 'Exited.'
}
