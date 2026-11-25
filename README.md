# Star Citizen Controller Monitor (`SCMonitorService-Full.ps1`)

A lightweight Windows system tray utility that automatically manages your HID game controllers (such as VIRPIL HOTAS/HOSAS setups) and **JoyToKey** based on the status of the **RSI Launcher**.

## Features

- **Automated Management:** Polls processes every 3 seconds to enable/disable HID game controllers and JoyToKey in sync with `RSI Launcher.exe`.
- **Auto-Elevation & Stealth:** Automatically requests Administrator privileges (necessary for PnP device control) and hides the PowerShell console.
- **Persistent Startup:** Option in the tray menu to save a local copy to `%LOCALAPPDATA%\SCMonitor` and register an elevated Windows Scheduled Task (`SCMonitorService`).
- **Smart Path Detection:** Auto-detects standard installation paths for the RSI Launcher and JoyToKey, with fallback file picker prompts.
- **Built-in Assets & Safety:** Uses an in-memory tray icon and safely resets controllers/JoyToKey upon exit.

## Quick Start

### Option 1: Run from PowerShell (Recommended)
```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command "irm ''https://raw.githubusercontent.com/ranalli/Star-Citizen---VIRPL-Controller-enabler/refs/heads/main/SCMonitorService-Full.ps1'' | iex"'
```
*(Accept the UAC prompt. Avoid running directly via `Win + R` to prevent antivirus flags).*

### Option 2: Local Script (Antivirus-Friendly)
```powershell
mkdir "\$env:LOCALAPPDATA\SCMonitor" -Force | Out-Null
irm "https://raw.githubusercontent.com/ranalli/Star-Citizen---VIRPL-Controller-enabler/refs/heads/main/SCMonitorService-Full.ps1" -OutFile "\$env:LOCALAPPDATA\SCMonitor\SCMonitorService-Full.ps1"
Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%LOCALAPPDATA%\SCMonitor\SCMonitorService-Full.ps1"'
```

## Usage & Configuration

Right-click the system tray icon to pause monitoring, toggle startup persistence, reset executable paths, or view logs. 

Files are stored in `%LOCALAPPDATA%\SCMonitor\`:
- **`config.json`**: Saved binary paths.
- **`service_log.txt`**: Rotating activity log (up to 1 MB).

## Requirements

- **OS:** Windows 10 or 11 (64-bit)
- **PowerShell:** 5.1 or newer
- **Permissions:** Administrator rights
