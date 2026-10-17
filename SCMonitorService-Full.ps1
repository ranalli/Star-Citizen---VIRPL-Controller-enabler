<#
.SYNOPSIS
    System Tray application that monitors for the RSI Launcher.
    Enables controllers/JoyToKey when opened, disables them on exit.
    Includes a "Launch at Startup" tray option that manages its own
    elevated scheduled task (runs at logon, highest privileges).
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Directory & Storage Setup ---
$LogFolder = "$HOME\Documents\SCLauncher"
if (-not (Test-Path $LogFolder)) { New-Item -ItemType Directory -Path $LogFolder -Force | Out-Null }
$LogFile = "$LogFolder\service_log.txt"
$ConfigFile = "$LogFolder\config.json"

function Write-Log ($Message) {
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$Timestamp] $Message" | Out-File -FilePath $LogFile -Append
}

Write-Log "SC Monitor Tray App Initializing..."

# --- Launch at Startup (Scheduled Task) ---
$Global:StartupTaskName = "SCMonitorService"
$Global:ScriptFullPath  = $PSCommandPath

function Test-StartupEnabled {
    return [bool](Get-ScheduledTask -TaskName $Global:StartupTaskName -ErrorAction SilentlyContinue)
}

function Test-IsAdmin {
    $Principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Enable-StartupTask {
    $User = "$env:USERDOMAIN\$env:USERNAME"
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Global:ScriptFullPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $Trigger.Delay = "PT15S"   # short delay so the desktop/tray is ready
    $Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $Global:StartupTaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
}

function Disable-StartupTask {
    Unregister-ScheduledTask -TaskName $Global:StartupTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

# --- Path Detection Logic ---
function Get-ExecutablePath {
    param (
        [string]$AppName,
        [array]$PossiblePaths,
        [string]$Filter
    )

    # 1. Try Auto-Detection
    foreach ($Path in $PossiblePaths) {
        if (Test-Path $Path) {
            Write-Log "Auto-detected $AppName at: $Path"
            return $Path
        }
    }

    # 2. Manual Fallback via File Picker
    Write-Log "$AppName not found automatically. Prompting user..."
    [System.Windows.Forms.MessageBox]::Show("Could not automatically locate $AppName. Please select its executable manually.", "Locate $AppName", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

    $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog
    $FileBrowser.Filter = $Filter
    $FileBrowser.Title = "Select $AppName Executable"
    
    if ($FileBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Log "User manually selected $AppName at: $($FileBrowser.FileName)"
        return $FileBrowser.FileName
    } else {
        Write-Log "User cancelled selection for $AppName. Exiting script."
        [System.Windows.Forms.MessageBox]::Show("The script requires $AppName to function. Exiting.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        exit
    }
}

function Initialize-Paths {
    param ([bool]$ForceReset = $false)

    $DefaultRsiPaths = @(
        "C:\Program Files\Roberts Space Industries\RSI Launcher\RSI Launcher.exe",
        "C:\Program Files (x86)\Roberts Space Industries\RSI Launcher\RSI Launcher.exe"
    )
    $DefaultJoyPaths = @(
        "C:\Program Files (x86)\JoyToKey\JoyToKey.exe",
        "C:\Program Files\JoyToKey\JoyToKey.exe",
        "$HOME\Desktop\JoyToKey\JoyToKey.exe"
    )

    if (-not $ForceReset -and (Test-Path $ConfigFile)) {
        try {
            $Config = Get-Content $ConfigFile | ConvertFrom-Json
            if ($Config.RsiPath -and (Test-Path $Config.RsiPath) -and $Config.JoyPath -and (Test-Path $Config.JoyPath)) {
                $Global:RsiPath = $Config.RsiPath
                $Global:JoyPath = $Config.JoyPath
                Write-Log "Loaded active configurations from JSON file."
                return
            }
        } catch {
            Write-Log "Error reading configuration file. Re-detecting paths..."
        }
    }

    # Determine Detection Type if triggered by Reset
    $AutoDetect = $true
    if ($ForceReset) {
        $Response = [System.Windows.Forms.MessageBox]::Show("Would you like to try detecting the applications automatically? Clicking 'No' opens manual setup.", "Reset Paths", [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($Response -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
        if ($Response -eq [System.Windows.Forms.DialogResult]::No) { $AutoDetect = $false }
    }

    if ($AutoDetect) {
        $Global:RsiPath = Get-ExecutablePath -AppName "RSI Launcher" -PossiblePaths $DefaultRsiPaths -Filter "RSI Launcher (RSI Launcher.exe)|RSI Launcher.exe"
        $Global:JoyPath = Get-ExecutablePath -AppName "JoyToKey" -PossiblePaths $DefaultJoyPaths -Filter "JoyToKey (JoyToKey.exe)|JoyToKey.exe"
    } else {
        # Forced Manual File Picker Selection
        $Global:RsiPath = Get-ExecutablePath -AppName "RSI Launcher" -PossiblePaths @() -Filter "RSI Launcher (RSI Launcher.exe)|RSI Launcher.exe"
        $Global:JoyPath = Get-ExecutablePath -AppName "JoyToKey" -PossiblePaths @() -Filter "JoyToKey (JoyToKey.exe)|JoyToKey.exe"
    }

    # Save Configuration Data
    $ConfigObj = [PSCustomObject]@{
        RsiPath = $Global:RsiPath
        JoyPath = $Global:JoyPath
    }
    $ConfigObj | ConvertTo-Json | Out-File $ConfigFile
    Write-Log "Paths successfully stored to config file."
}

# Run Initialization
Initialize-Paths -ForceReset $false

# Extract runtime names dynamic to saved paths
$RsiProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Global:RsiPath)
$JoyProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Global:JoyPath)

# --- State Management ---
$Global:GameIsRunning = $false
$Global:IsPaused = $false

# --- System Tray Setup ---
$TrayIcon = New-Object System.Windows.Forms.NotifyIcon

if (Test-Path "M:\Scripts\sc.ico") {
    $TrayIcon.Icon = New-Object System.Drawing.Icon("M:\Scripts\sc.ico")
} else {
    $TrayIcon.Icon = [System.Drawing.SystemIcons]::Information
}

$DefaultTrayText = "Star Citizen Controller Monitor"
$TrayIcon.Text = $DefaultTrayText
$TrayIcon.Visible = $true

# Context Menu Creation
$ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$MenuPause   = New-Object System.Windows.Forms.ToolStripMenuItem("Pause")
$MenuStartup = New-Object System.Windows.Forms.ToolStripMenuItem("Launch at Startup")
$MenuReset   = New-Object System.Windows.Forms.ToolStripMenuItem("Reset Paths")
$MenuExit    = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

# Build Context Menu Structure
$ContextMenu.Items.AddRange(@($MenuPause, $MenuStartup, $MenuReset, $MenuExit))
$TrayIcon.ContextMenuStrip = $ContextMenu

# Reflect current startup state on launch
$MenuStartup.Checked = Test-StartupEnabled

# Pause Event Handler
$MenuPause.Add_Click({
    $Global:IsPaused = -not $Global:IsPaused
    if ($Global:IsPaused) {
        $MenuPause.Checked = $true
        $TrayIcon.Text = "$DefaultTrayText (Paused)"
        Write-Log "Monitoring loop paused by user."
    } else {
        $MenuPause.Checked = $false
        $TrayIcon.Text = $DefaultTrayText
        Write-Log "Monitoring loop resumed by user."
    }
})

# Launch at Startup Event Handler
$MenuStartup.Add_Click({
    try {
        if (-not (Test-IsAdmin)) {
            [System.Windows.Forms.MessageBox]::Show("Administrator rights are required to change startup settings.", "Launch at Startup", "OK", "Warning") | Out-Null
            return
        }
        if ($MenuStartup.Checked) {
            Disable-StartupTask
            $MenuStartup.Checked = $false
            Write-Log "Launch at Startup disabled (scheduled task removed)."
        } else {
            Enable-StartupTask
            $MenuStartup.Checked = $true
            Write-Log "Launch at Startup enabled (scheduled task created)."
        }
    } catch {
        Write-Log "Error changing startup setting: $_"
        [System.Windows.Forms.MessageBox]::Show("Failed to change startup setting:`n$_", "Error", "OK", "Error") | Out-Null
    }
})

# Reset Paths Event Handler
$MenuReset.Add_Click({
    Write-Log "User triggered path environment reset."
    Initialize-Paths -ForceReset $true
    # Refresh local processes markers based on updated logic paths
    $script:RsiProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Global:RsiPath)
    $script:JoyProcessName = [System.IO.Path]::GetFileNameWithoutExtension($Global:JoyPath)
})

# Exit Event Handler
$MenuExit.Add_Click({
    Write-Log "Exiting Tray Application. Cleaning up timers..."
    $Global:MonitorTimer.Stop()
    $TrayIcon.Visible = $false
    $TrayIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
    Exit
})

# --- Main Monitoring Logic ---
$MonitorAction = {
    if ($Global:IsPaused) { return }

    try {
        $RsiProcess = Get-Process -Name $RsiProcessName -ErrorAction SilentlyContinue

        if ($RsiProcess -and -not $Global:GameIsRunning) {
            # --- RSI LAUNCHER JUST OPENED ---
            Write-Log "RSI Launcher detected. Initializing setup..."
            $Global:GameIsRunning = $true

            $GameControllers = Get-PnpDevice | Where-Object {
                ($_.FriendlyName -like "HID-compliant game controller*") -and ($_.Status -ne "Unknown")
            }

            if ($GameControllers) {
                foreach ($Controller in $GameControllers) {
                    Enable-PnpDevice -InstanceId $Controller.InstanceId -Confirm:$false
                    Write-Log "Enabled device: $($Controller.FriendlyName)"
                }
            } else {
                Write-Log "Warning: No HID game controllers discovered."
            }

            if (-not (Get-Process -Name $JoyProcessName -ErrorAction SilentlyContinue)) {
                Start-Process -FilePath $Global:JoyPath -Verb RunAs
                Write-Log "Started JoyToKey as Administrator."
            }
        }
        elseif (-not $RsiProcess -and $Global:GameIsRunning) {
            # --- RSI LAUNCHER JUST CLOSED ---
            Write-Log "RSI Launcher closure detected. Cleaning up..."
            $Global:GameIsRunning = $false

            $GameControllers = Get-PnpDevice | Where-Object {
                ($_.FriendlyName -like "HID-compliant game controller*") -and ($_.Status -ne "Unknown")
            }

            if ($GameControllers) {
                foreach ($Controller in $GameControllers) {
                    Disable-PnpDevice -InstanceId $Controller.InstanceId -Confirm:$false
                    Write-Log "Disabled device: $($Controller.FriendlyName)"
                }
            }

            Stop-Process -Name $JoyProcessName -Force -ErrorAction SilentlyContinue
            Write-Log "Closed JoyToKey."
        }
    }
    catch {
        Write-Log "Error encountered in monitor loop: $_"
    }
}

# --- Non-Blocking Loop Using Forms Timer ---
$Global:MonitorTimer = New-Object System.Windows.Forms.Timer
$Global:MonitorTimer.Interval = 3000
$Global:MonitorTimer.Add_Tick($MonitorAction)
$Global:MonitorTimer.Start()

Write-Log "Tray Loop Engine Started Successfully."

# Keep the Windows Forms thread alive
[System.Windows.Forms.Application]::Run()