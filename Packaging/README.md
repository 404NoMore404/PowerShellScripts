# Intune Win32 Package Templates

## Overview

This repository contains PowerShell scripts for packaging and deploying applications through Microsoft Intune as Win32 apps. The goal is a consistent, reusable foundation so that packaging a new application does not mean writing scripts from scratch every time. The structure stays the same across every package, the log format is always identical, and the only things that change between applications are the values you fill in at the top of each script.

There are two layers of tooling here. The first is the packaging layer: install, uninstall, and detection scripts you configure and ship inside the Intune package. The second is the observation layer: the Watch scripts, which are pre-packaging tools you run locally on a test machine to learn exactly what an installer does before you write a single configuration value.

All of these scripts have been built against real-world Intune deployments and account for the edge cases that tend to cause problems: apps that are already installed, path resolution differences depending on how PowerShell launches the script, leftover files the uninstaller does not clean up, and log output that lands exactly where Intune can collect it.

---

## Files in This Repository

| File | Purpose |
|------|---------|
| `TEMPLATE_Install-APPNAME.ps1` | Silent install wrapper with logging and a live progress indicator |
| `TEMPLATE_Uninstall-APPNAME.ps1` | Silent uninstall wrapper with logging and post-uninstall cleanup |
| `TEMPLATE_Detect-APPNAME.ps1` | Custom detection script supporting four detection methods |
| `Invoke-IntuneInstall.ps1` | Single-file install and uninstall wrapper for straightforward packages |
| `Watch-Install.ps1` | Interactive tool that monitors your installer, captures every registry and file change, and saves a JSON record used by the other Watch scripts |
| `Watch-Uninstall.ps1` | Mirrors Watch-Install for uninstalls — loads the installer JSON, runs the uninstaller, and reports what was removed vs what was left behind |
| `Compare-WatchReports.ps1` | Diffs the two Watch JSON files and produces a verdict on whether the uninstaller leaves a clean system |
| `Watch-Suite.ps1` | Runs all three Watch phases back-to-back in a single session with a single file picker — the fastest way to get a full install and uninstall audit |

---

## How the Pieces Fit Together

The Watch scripts and the packaging scripts serve different purposes and are used at different stages. Before you write anything:

1. Run Watch-Suite (or Watch-Install) on a test machine so you know exactly what the installer does.
2. Use what you learn to fill in the packaging scripts.
3. Test the packaging scripts locally.
4. Package and upload to Intune.

The Watch scripts are pre-packaging tools only. They never go inside the Intune package.

---

## Recommended Packaging Workflow

### Step 1 — Run Watch-Suite.ps1 (or Watch-Install.ps1) on a test machine

Before you touch any configuration values, run the installer through the Watch tooling. This gives you the app's DisplayName, DisplayVersion, publisher, registry key location, uninstall string, and a full list of every file the installer dropped — exactly the values you need for your packaging scripts. You do not need to manually browse the registry or guess at paths.

If this is your first time with a package, `Watch-Suite.ps1` is the easiest entry point. It handles the full install, uninstall, and comparison sequence in one session, and all you have to do is pick the installer file at the beginning. If you only need install observations and want to handle uninstall analysis separately, run `Watch-Install.ps1` on its own.

### Step 2 — Copy and rename the template files

Copy the template files into your package folder and rename them to match your application:

```
TEMPLATE_Install-APPNAME.ps1    ->    Install-7Zip.ps1
TEMPLATE_Uninstall-APPNAME.ps1  ->    Uninstall-7Zip.ps1
TEMPLATE_Detect-APPNAME.ps1     ->    Detect-7Zip.ps1
```

For simpler packages that do not need a progress indicator or InstallShield ISS support, use `Invoke-IntuneInstall.ps1` as a drop-in that handles both install and uninstall from one file.

### Step 3 — Fill in the configuration blocks

Open each script and fill in the configuration block at the top using the values the Watch scripts reported. Every variable has a comment explaining what it expects. For a standard package this takes about two minutes.

### Step 4 — Test locally

Always test all three scripts on a real machine before packaging. The testing section of this document walks through exactly how to do that, including what a passing result looks like for each script.

### Step 5 — Package and upload to Intune

Once local testing passes, package the folder using the Win32 Content Prep Tool and upload to Intune. The packaging section covers exactly what goes into the folder and what to configure in the Intune app settings.

---

## Script Details

### Watch-Suite.ps1

Watch-Suite is the recommended starting point for any new package. It combines all three Watch phases into a single interactive session so you walk away with the full install and uninstall audit in one run, rather than running three separate scripts in sequence.

The only input it needs from you is the installer file. After that, it detects the uninstall string automatically from Phase 1, runs the uninstaller, and produces the full diff report — all without asking you to re-select any files between phases.

**The three phases:**

Phase 1 takes before-and-after snapshots of the registry and filesystem, runs the installer, and builds a report of everything that changed. It auto-saves `Watch_Installer_<AppName>.json` next to your installer file.

Phase 2 reads the Phase 1 data directly from memory (no re-reading of the JSON), detects the app's uninstall string, runs the uninstaller, and records which files and registry keys were removed vs which were left behind. It auto-saves `Watch_Uninstaller_<AppName>.json` in the same folder.

Phase 3 diffs the Phase 1 and Phase 2 data and produces the final verdict — CLEAN UNINSTALL, MINOR LEFTOVERS, or DIRTY UNINSTALL — with a full breakdown of every leftover item and whether it is still present on disk right now. It then asks if you want to save a copy of the diff report as a text file.

Between each phase the script pauses and waits for you to press Enter. This means if the install fails and you want to stop, you can hit Ctrl+C at the phase transition instead of having the uninstall run against a broken state.

**Files produced — everything goes next to your installer:**

| File | Purpose |
|------|---------|
| `Watch_Installer_<AppName>.json` | Machine-readable install record — used by Watch-Uninstall and Compare-WatchReports if running as standalones |
| `Watch_Uninstaller_<AppName>.json` | Machine-readable uninstall record |
| `<AppName>_<YYYYMMDD>_DiffReport.txt` | Human-readable diff report (optional save at the end of Phase 3) |
| `PKG_WatchSuite_<timestamp>.log` | Full log covering all three phases |

**Usage:**

```powershell
# Interactive — right-click and Run with PowerShell, or from an elevated terminal:
.\Watch-Suite.ps1
```

---

### Watch-Install.ps1

Watch-Install is the standalone version of Phase 1. Use it when you only need install observations and plan to run Watch-Uninstall and Compare-WatchReports separately later, or when you want to re-observe an install without going through the full suite.

**What it does:**

It self-elevates to Administrator, opens a file picker so you can select the installer, prompts for optional silent arguments, takes before snapshots of the registry and filesystem, runs the installer, diffs the before and after state, and prints a full report.

The report covers the exit code with a plain-English meaning, every new registry key with all values (the DisplayName line includes a ready-to-paste detection filter suggestion), all new files grouped by directory, and all files modified in pre-existing directories. After printing the report, it auto-saves `Watch_Installer_<AppName>.json` next to the installer file, then offers to save a text copy of the report.

The app name used in the JSON filename is derived from the installer's registry DisplayName if one was found. If no registry key was created, it falls back to the installer filename without the extension.

**Registry hives watched:**

- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
- `HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`
- `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`

To add your organization's custom hives, find the `[CHANGE ME]` comment in the `Get-RegistrySnapshot` function.

**Filesystem paths watched:**

Program Files, Program Files (x86), LocalAppData, AppData (Roaming), and ProgramData top-level directories. Brand-new directories are recursed fully for every file inside. Existing directories that were modified during the install are scanned for files written after the install started. To add custom paths, find the `[CHANGE ME]` comment in the `Get-FilesystemSnapshot` function.

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `Watch_Installer_<AppName>.json` | Same folder as installer | Data file for Watch-Uninstall and Compare-WatchReports |
| `<InstallerName>_<YYYYMMDD>_InstallReport.txt` | Location you choose | Human-readable install report |
| `PKG_WatchInstall_<timestamp>.log` | IME logs folder | Full observation log |

**Usage:**

```powershell
.\Watch-Install.ps1
```

---

### Watch-Uninstall.ps1

Watch-Uninstall is the standalone version of Phase 2. It picks up where Watch-Install left off: it loads the installer JSON, cross-checks which tracked files and registry keys are currently present before the uninstaller runs, launches the uninstaller, and then checks each one again to see what was actually removed.

**What it does:**

It reads the `Watch_Installer_<AppName>.json` file you select, extracts the UninstallString from the stored registry data, and offers you three ways to proceed: use the detected string as-is (which is the same as clicking Uninstall in Windows Settings), browse for a different uninstaller, or type a path manually. You can also append extra arguments at the optional arguments prompt.

After the uninstaller finishes, it checks every file and registry key from the installer record against current disk state and reports what was removed, what remains, and what was already missing before the uninstall started. That last category is tracked separately so it does not inflate your leftover count. It auto-saves `Watch_Uninstaller_<AppName>.json` in the same folder as the installer JSON.

**Uninstall method options:**

| Option | When to use |
|--------|------------|
| U — Use detected string (default) | The UninstallString from the installer record is a normal executable path. Press Enter to accept. |
| B — Browse | You want to point to a different uninstaller, or the detected string is a wrapper you do not want to use. |
| M — Manual entry | The uninstaller is at a path you want to type directly. |

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `Watch_Uninstaller_<AppName>.json` | Same folder as installer JSON | Data file for Compare-WatchReports |
| `<AppName>_<YYYYMMDD>_UninstallReport.txt` | Location you choose | Human-readable uninstall report |
| `PKG_WatchUninstall_<timestamp>.log` | IME logs folder | Full observation log |

**Usage:**

```powershell
.\Watch-Uninstall.ps1
```

---

### Compare-WatchReports.ps1

Compare-WatchReports is the standalone version of Phase 3. Run it after both Watch-Install and Watch-Uninstall have completed. It loads both JSON files via file pickers, diffs them, and produces the definitive answer to: does this uninstaller leave a clean system?

**What the diff means:**

The script builds the set of files and registry keys that were installed but not in the uninstaller's remove list. For each of those items it then checks whether the item is actually on disk right now. This distinction matters because some items disappear on their own — temp files, cached content, things the app cleans up during uninstall — and those should not count against the verdict.

- **Still on disk (PROBLEM)** — The item was installed, the uninstaller did not remove it, and it is physically present right now. This is a genuine leftover. Add these paths to `$LeftoverFolders` and `$LeftoverRegKeys` in your uninstall script.
- **Already gone (OK)** — The item was installed and is not in the uninstaller's remove list, but it is no longer on disk. This is normal and does not count against the verdict.

**Verdict thresholds:**

| Verdict | What it means |
|---------|--------------|
| CLEAN UNINSTALL | Zero files or registry keys remain on disk. The uninstaller did a complete job. |
| MINOR LEFTOVERS | Fewer than 10 items remain on disk. Likely harmless but worth noting. |
| DIRTY UNINSTALL | 10 or more items remain on disk. The uninstaller is leaving meaningful traces behind. |

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `<AppName>_<YYYYMMDD>_DiffReport.txt` | Location you choose | Human-readable diff report |
| `PKG_CompareReports_<timestamp>.log` | IME logs folder | Comparison log |

**Usage:**

```powershell
.\Compare-WatchReports.ps1
```

---

### Install-APPNAME.ps1

This is the install wrapper you ship inside the Intune package. It handles everything from pre-flight checks through the actual install and post-install verification, and it is designed so that if something goes wrong, the log tells you exactly where and why without needing to remote into the machine.

**What it does, in order:**

1. Creates the log folder and starts a timestamped log file.
2. Logs machine name, username, OS version, and available disk space for full context when reading logs remotely.
3. Confirms it is running as Administrator and exits immediately if not.
4. Resolves its own folder path using a three-tier fallback so the script works whether it is run via `-File`, dot-sourced, or invoked directly.
5. Confirms the installer file exists. If an ISS response file is configured, confirms that exists too.
6. Checks the registry to see if the application is already installed. If it is, exits with code 0 so Intune does not attempt a reinstall.
7. Launches the installer silently using `Start-Process` in non-blocking mode so a progress bar can run concurrently.
8. Displays a live progress bar showing elapsed time and estimated percentage while the installer runs. This prevents confusion during testing about whether the install is still running or has silently failed.
9. Maps the installer exit code to a plain-English description in the log.
10. Waits ten seconds, then re-checks the registry to confirm the install registered correctly.
11. Checks for the expected Windows service if the app installs one.
12. Copies the InstallShield debug log (if present) into the Intune logs folder so both logs are collected together during device diagnostics.
13. Writes a summary block with the final result, exit code, and total duration.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$AppName` | Display name used in log headers. Example: `"7-Zip 24.08"` |
| `$AppVersion` | Version number. Example: `"24.08.0.0"` |
| `$InstallerFileName` | Filename of the installer file. Example: `"7z2408-x64.exe"` |
| `$InstallArguments` | Silent install flags. See common examples below. |
| `$RegistryDetectionPath` | Full registry path to the app's uninstall key |
| `$LogFolderName` | Short name for the log subfolder. Example: `"7Zip"` |
| `$EstimatedSeconds` | Approximate install duration in seconds for the progress bar |

**Silent install arguments by installer type:**

| Installer Type | Silent Arguments |
|---------------|-----------------|
| InstallShield with ISS | `/s /f1"setup.iss"` |
| MSI | `/quiet /norestart` |
| NSIS | `/S` |
| Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| Generic EXE | `/install /quiet /norestart` |

If you are not sure which type an EXE uses, run it through Watch-Suite or Watch-Install first. You can also try running it with `/?` or check the vendor's documentation.

---

### Uninstall-APPNAME.ps1

The uninstall wrapper mirrors the install script in structure. Unlike the install script, it does not need to know where it is located on disk because everything it does is based on registry lookups and known system paths.

**What it does, in order:**

1. Creates the log folder and starts a timestamped uninstall log.
2. Logs machine name and username for context.
3. Confirms Administrator privileges.
4. Looks up the application in the registry. If it is not found, logs a warning and skips the uninstall step rather than failing hard.
5. Runs the uninstall using either an MSI product code or a direct EXE uninstaller path, depending on which method you configure.
6. For MSI uninstalls, enables verbose MSI logging so a detailed log is written to the Intune logs folder.
7. Iterates through any leftover folders and registry keys you define and removes them if they exist. This is where you put the paths Compare-WatchReports flagged as still on disk.
8. Verifies the registry entry is gone after uninstall and logs a warning if it is still present.
9. Writes a summary block at the end.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$AppName` | Display name for logs |
| `$UninstallMethod` | Either `"MSI"` or `"EXE"` |
| `$ProductCode` | Product GUID for MSI uninstall. Example: `"{12345678-ABCD-...}"` |
| `$UninstallerPath` | Full path to uninstaller EXE if using EXE method |
| `$UninstallArguments` | Silent uninstall flags for EXE method |
| `$RegistryDetectionPath` | Same path used in the install script |
| `$LeftoverFolders` | Array of folder paths to delete after uninstall |
| `$LeftoverRegKeys` | Array of registry keys to delete after uninstall |
| `$LogFolderName` | Must match the value used in the install script |

**Finding the product code:**

After a manual install, run this in PowerShell to find the GUID:

```powershell
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" |
    Get-ItemProperty |
    Where-Object { $_.DisplayName -like "*YourAppName*" } |
    Select-Object DisplayName, DisplayVersion, PSChildName
```

The `PSChildName` column is the value you need. If you ran Watch-Install or Watch-Suite first, this is already printed in the registry section of the report — no separate lookup needed.

---

### Detect-APPNAME.ps1

This script is uploaded to Intune as a custom detection rule. Intune runs it silently on the device and decides whether the app is installed based on the exit code and whether anything was written to the console. Exit code 0 plus console output means installed. Anything else means not installed.

**Four detection methods are available:**

**DisplayName (recommended)** — searches all Uninstall hives for an app whose DisplayName matches a wildcard you define. This is the most reliable method because it works regardless of the specific GUID the installer used, whether the app is 32-bit or 64-bit, whether it was installed per-machine or per-user, and whether you are superseding it with a newer version. It is the right default for any package that participates in a supersedence chain. Watch-Install prints the exact DisplayName with a ready-to-paste filter suggestion so you do not have to guess.

**RegistryGUID** — targets a specific product GUID or registry key name directly. Product GUIDs change with every new version, so detection will fail after an upgrade and Intune will attempt to reinstall on top of the existing app. Only use this if you need exact version pinning with no plans to supersede.

**File** — checks whether a specific file exists at a known path. Useful for apps that do not create a standard registry entry, such as portable tools or certain system utilities.

**Service** — checks whether a Windows service with a specific name is registered. Useful for server-side or background service applications.

Only one method is active at a time. The other three are commented out in the configuration block.

**A note on version enforcement:**

The detection script's job is to answer "is this app present?" not "is this exact build present?". Intune enforces version through the package and supersedence rules, not through detection. For that reason, `$ExpectedVersion` defaults to `$null` and you should leave it that way for any package in a supersedence chain.

If you need a minimum baseline — for example, version 20 or newer counts as installed but version 10 does not — use `$MinimumVersion` instead. This lets newer versions pass detection while still marking outdated installs as non-compliant.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$DetectionMethod` | `"DisplayName"`, `"RegistryGUID"`, `"File"`, or `"Service"` |
| `$DisplayNameFilter` | Wildcard app name. Example: `"*7-Zip*"` |
| `$ExpectedVersion` | Exact version string, or `$null` to skip. Leave `$null` for supersedence chains. |
| `$MinimumVersion` | Minimum acceptable version, or `$null` to skip |
| `$RegistryPath` | Full uninstall registry path (RegistryGUID method) |
| `$DetectionFilePath` | Full file path (File method) |
| `$DetectionServiceName` | Windows service name (Service method) |

---

### Invoke-IntuneInstall.ps1

This is a single drop-in file that handles both install and uninstall from one script. Instead of maintaining separate install and uninstall templates per package, you drop this into every package folder alongside the installer, fill in the configuration block, and call it with `-IsUninstall` for removal.

Use Invoke-IntuneInstall when you want minimal files per package and do not need the full progress bar, pre-flight checks, or InstallShield ISS support that the dedicated templates provide. It is well-suited for clean MSI packages and simple single-EXE installers. Use the dedicated templates when you need richer logging, a progress indicator during testing, or ISS-based installs.

**What it does:**

It auto-detects the installer in its own folder (or uses a filename you hardcode), builds the correct msiexec or EXE command, runs it, evaluates the exit code, and optionally runs a post-install detection check to confirm the install actually registered before reporting success. For uninstalls it tries the MSI product code first, then falls back to a configured EXE path, then falls back to a registry lookup for the uninstall string.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$AppName` | Display name for log file names and console messages |
| `$AppVersion` | Version number |
| `$AppVendor` | Vendor name |
| `$MSIProductCode` | MSI product GUID for uninstalls. Leave blank to use file path. |
| `$EXEUninstallPath` | Full path to EXE uninstaller on the endpoint, if applicable |
| `$DetectionType` | `"DisplayName"`, `"RegistryKey"`, `"File"`, or `"None"` |
| `$DetectionNameFilter` | Wildcard filter for DisplayName post-install check. Example: `"*7-Zip*"` |
| `$DetectionValue` | Registry key path or file path for RegistryKey or File detection |

**Usage:**

```powershell
# Install
powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1

# Uninstall
powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1 -IsUninstall
```

---

## Full Watch Workflow Example

The following shows the complete observation sequence for Google Chrome. The goal is to walk away with enough information to fill in the packaging scripts and know whether the uninstaller leaves a clean system.

### Option A — Using Watch-Suite.ps1 (recommended)

Run `Watch-Suite.ps1`. When the file picker opens, select `ChromeSetup.exe`. Leave the arguments blank — Chrome's stub installer handles silent mode internally.

After the install completes, Phase 1 reports something like:

```
[REG]  ...\Uninstall\Google Chrome
       DisplayName     : Google Chrome  <-- use as "*Google Chrome*" in detection scripts
       DisplayVersion  : 123.0.6312.86
       InstallLocation : C:\Program Files\Google\Chrome\Application
       UninstallString : "C:\Program Files\Google\Chrome\Application\...\setup.exe" --uninstall ...
```

Copy DisplayName and DisplayVersion into your detection and packaging scripts.

At the Phase 2 transition, press Enter to continue. Watch-Suite detects the UninstallString automatically and offers it as the default — press Enter to accept. After the uninstall completes, Phase 3 runs automatically and prints the verdict. If the result is CLEAN UNINSTALL, you are done. If it shows leftovers, note the paths listed under "Still on disk (PROBLEM)" and add them to `$LeftoverFolders` and `$LeftoverRegKeys` in your uninstall script.

**File layout after a full Watch-Suite run:**

```
Downloads\
  ChromeSetup.exe
  Watch_Installer_Google_Chrome.json
  Watch_Uninstaller_Google_Chrome.json
  Google_Chrome_20260312_DiffReport.txt    (if you chose to save at the Phase 3 prompt)
  PKG_WatchSuite_20260312_143201.log
```

### Option B — Using the three scripts separately

Run `Watch-Install.ps1` during the install. It saves `Watch_Installer_Google_Chrome.json` next to the installer.

After the install, run `Watch-Uninstall.ps1`. When the file picker opens, select the `Watch_Installer_Google_Chrome.json` file. The script detects the UninstallString and offers it as the default — press Enter to accept. It saves `Watch_Uninstaller_Google_Chrome.json` in the same folder.

Finally, run `Compare-WatchReports.ps1`. Select both JSON files when prompted. The verdict tells you whether the uninstaller cleaned up completely or left files and registry keys behind.

**File layout after running all three separately:**

```
Downloads\
  ChromeSetup.exe
  Watch_Installer_Google_Chrome.json
  Watch_Uninstaller_Google_Chrome.json
  Google_Chrome_20260312_InstallReport.txt
  Google_Chrome_20260312_UninstallReport.txt
  Google_Chrome_20260312_DiffReport.txt
  PKG_WatchInstall_20260312_141500.log
  PKG_WatchUninstall_20260312_142100.log
  PKG_CompareReports_20260312_142800.log
```

---

## Log Files

All scripts write logs to the Intune management extension logs folder. This is the location Intune targets when you use Collect Diagnostics from the admin portal, which means you can retrieve logs without remoting into the machine.

**Log folder:**

```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\
```

**Log files produced by each script:**

| Filename pattern | Script | Contents |
|-----------------|--------|---------|
| `[APPNAME]_LogFile_Installer_YYYY-MM-DD_HHMMSS.log` | Install template | Full install log |
| `[APPNAME]_LogFile_InstallShield_YYYY-MM-DD_HHMMSS.log` | Install template | Raw InstallShield debug log (if applicable) |
| `[APPNAME]_LogFile_Uninstaller_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Full uninstall log |
| `[APPNAME]_LogFile_MSI_Uninstall_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Verbose MSI uninstall log (MSI method only) |
| `PKG_Install_[APPNAME]_YYYYMMDD_HHMMSS.log` | Invoke-IntuneInstall | Install log |
| `PKG_Uninstall_[APPNAME]_YYYYMMDD_HHMMSS.log` | Invoke-IntuneInstall | Uninstall log |
| `PKG_[APPNAME]_msi.log` | Invoke-IntuneInstall | Verbose MSI log |
| `PKG_WatchInstall_YYYYMMDD_HHMMSS.log` | Watch-Install | Full observation log |
| `PKG_WatchUninstall_YYYYMMDD_HHMMSS.log` | Watch-Uninstall | Full observation log |
| `PKG_CompareReports_YYYYMMDD_HHMMSS.log` | Compare-WatchReports | Diff comparison log |
| `PKG_WatchSuite_YYYYMMDD_HHMMSS.log` | Watch-Suite | Full log covering all three phases |

**Log entry format:**

Every log line follows the same format across all scripts:

```
[10:30:01] [INFO   ]  Installer exit code: 0
[10:30:02] [OK     ]  Registry entry confirmed.
[10:30:03] [WARN   ]  SQL Server service not found. Reboot may be required.
[10:30:04] [ERROR  ]  Installer EXE not found. Ensure it is in the same folder as this script.
```

When reading a log after a failure, search for `ERROR` first to jump straight to the problem. `WARN` entries indicate something unexpected but non-fatal. `OK` entries confirm each step completed successfully.

---

## Testing Locally

Testing before packaging is one of the most important things you can do. Uploading an untested script to Intune and deploying it to machines is the slowest possible feedback loop for catching problems. Every issue that would have taken two minutes to catch locally can turn into a half-hour remote investigation after deployment.

**Before testing, confirm:**

- PowerShell is open as Administrator
- You are in the same directory as the scripts and installer files
- The application is not currently installed (for install testing) or is installed (for uninstall testing)

**Test the install script:**

```powershell
cd "C:\Path\To\PackageFolder"
.\Install-YourApp.ps1
```

Watch the console for color-coded output. A progress bar will show while the installer runs. When it finishes, open the log file and confirm the last entry shows `OK` or `SUCCESS`. Open Apps and Features and verify the application appears.

**Test the uninstall script:**

```powershell
cd "C:\Path\To\PackageFolder"
.\Uninstall-YourApp.ps1
```

Confirm the application is gone from Apps and Features and the log shows no `ERROR` entries.

**Test the detection script:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Detect-YourApp.ps1"
echo $LASTEXITCODE
```

Run this with the app installed and confirm you get exit code `0`. Then run the uninstall script and run detection again — you should get exit code `1`. If detection returns `0` after an uninstall, something in the detection configuration is too broad or is matching a leftover file or registry key.

**Test Invoke-IntuneInstall.ps1:**

```powershell
cd "C:\Path\To\PackageFolder"
powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-IntuneInstall.ps1"
# After install completes:
powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-IntuneInstall.ps1" -IsUninstall
```

Verify both install and uninstall log files appear in the IME logs folder and neither shows `ERROR` entries.

**Test the Watch scripts:**

The Watch scripts self-elevate and are fully interactive. Right-click and select Run with PowerShell, or launch from an elevated terminal:

```powershell
.\Watch-Suite.ps1           # All three phases in one session (recommended)
.\Watch-Install.ps1         # Install observation only
.\Watch-Uninstall.ps1       # Uninstall observation only (requires Watch_Installer JSON)
.\Compare-WatchReports.ps1  # Diff only (requires both JSON files)
```

---

## Packaging for Intune

Once all scripts test cleanly, package the folder using the Win32 Content Prep Tool and upload to Intune.

**Important:** The Watch scripts (`Watch-Install.ps1`, `Watch-Uninstall.ps1`, `Compare-WatchReports.ps1`, `Watch-Suite.ps1`) and their output files (`Watch_Installer_*.json`, `Watch_Uninstaller_*.json`, `*_InstallReport.txt`, `*_UninstallReport.txt`, `*_DiffReport.txt`) are pre-packaging tools only. Do not include them in the folder you package for Intune deployment.

**Package folder contents — Install/Uninstall templates:**

```
YourInstaller.exe         (or .msi)
setup.iss                 (InstallShield packages only)
Install-YourApp.ps1
Uninstall-YourApp.ps1
Detect-YourApp.ps1
```

**Package folder contents — Invoke-IntuneInstall.ps1:**

```
YourInstaller.exe         (or .msi)
Invoke-IntuneInstall.ps1
Detect-YourApp.ps1
```

**Run the content prep tool:**

```cmd
IntuneWinAppUtil.exe -c "C:\Path\To\PackageFolder" -s "YourInstaller.exe" -o "C:\Output"
```

**Intune app configuration — Install/Uninstall templates:**

| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-YourApp.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-YourApp.ps1` |
| Install behavior | System |
| Device restart behavior | App install may force a device restart |
| Detection rule | Custom script — upload `Detect-YourApp.ps1` |

**Intune app configuration — Invoke-IntuneInstall.ps1:**

| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1 -IsUninstall` |
| Install behavior | System |
| Device restart behavior | App install may force a device restart |
| Detection rule | Custom script — upload `Detect-YourApp.ps1` |

**Return codes to configure in Intune:**

| Code | Type |
|------|------|
| `0` | Success |
| `3010` | Soft reboot required |
| `1641` | Soft reboot required |

---

## Common Issues and How to Fix Them

**Script says the installer was not found**

The install script looks for the installer in the same folder as the script itself. Always `cd` into the package folder before running. If you are using Invoke-IntuneInstall and auto-detection is not finding the right file, hardcode `$InstallerFile` in the parameters block at the top of the script.

**Detection script returns 1 after a successful install**

If you are using the DisplayName method, the wildcard filter probably does not match the app's actual display name. Run Watch-Install or Watch-Suite and check the DisplayName line in the registry section — it prints a ready-to-paste suggestion right there in the output. If you are using RegistryGUID, the path or GUID may not match exactly what the installer created.

**Post-install detection fails in Invoke-IntuneInstall.ps1**

Confirm `$DetectionNameFilter` matches the DisplayName value Watch-Install reported. If `$DetectionType` is set to `'None'`, the post-install check is skipped entirely — set it to `'DisplayName'` for production packages. Also confirm the app is actually uninstalled before testing — Apps and Features should show no trace of it before you run the install.

**Detection passes for the wrong version after an upgrade**

This is expected behavior when using the DisplayName method with no version pinning, which is the correct setup for packages in a supersedence chain. If you need to enforce a minimum version, set `$MinimumVersion` in Detect-APPNAME.ps1. Do not set `$ExpectedVersion` in a supersedence chain — it will cause detection to fail as soon as a newer version is present.

**Exit code -3 from an InstallShield installer**

The GUID in the ISS file section headers does not match the installer's actual ProductCode. This almost always happens when the ISS was recorded against a different version than the one you are packaging now. Re-record the ISS against the exact installer version you are deploying. You can find the correct GUID in the InstallShield verbose log under `ProductCode=`.

**Uninstall script exits with 1603**

1603 is the MSI generic failure code. It usually means another installation is already in progress, the process is not running with sufficient privileges, or the application left behind a corrupted state from a previous failed install or uninstall. Check the verbose MSI log in the Intune logs folder for the specific internal error — the actual cause will be in the lines just before the failure point.

**Watch-Install.ps1 reports no new registry keys**

The installer does not write to the standard Uninstall hives. This means DisplayName and RegistryGUID detection methods will not work for this app. Use File detection in your detection script instead, picking a file path from the new files section of the Watch-Install report. The Watch_Installer JSON will still be created and will still work with Watch-Uninstall and Compare-WatchReports — the tracked items will just be files only, with no registry keys.

**Watch-Uninstall.ps1 cannot find the UninstallString**

Same root cause as above — the installer did not register in the standard Uninstall hives, so there is no stored UninstallString. Choose Browse or Manual at the uninstall method prompt and point directly to the uninstaller executable. The uninstall observation and diff will still work correctly. The UninstallString is only used as a convenience default to pre-fill the path.

**Compare-WatchReports shows a high leftover count but the app looks fully removed**

Look at the "Already gone (OK)" section of the report. Items listed there were installed but are no longer on disk and were not in the uninstaller's explicit remove list. This is normal for temp files, cache content, and files the app deletes during its own shutdown. Only the "Still on disk (PROBLEM)" items are genuine leftovers worth addressing in your uninstall script.

**Watch-Uninstall reports files missing before the uninstall even started**

The app was updated, repaired, or partially removed between when Watch-Install ran and when you ran Watch-Uninstall. The script tracks this count separately in the report and in the JSON so those files do not inflate your leftover numbers. Compare-WatchReports accounts for this correctly because it checks current disk state at comparison time rather than relying purely on what the JSON files say.

**Watch-Suite stops between phases and I want to cancel**

That is exactly what the pause between phases is designed for. Press Ctrl+C at any "Press Enter to continue" prompt to stop there. The JSON file for the phase that already completed will have been saved next to your installer, so nothing is lost.

**Watch-Suite Phase 2 launches the wrong uninstaller**

At the Phase 2 uninstall method prompt, choose B to browse for the correct executable instead of accepting the detected string. The detected UninstallString is pulled directly from the Phase 1 registry data — if the app wrote an unusual value or you want to use a wrapper or different executable, Browse lets you pick anything.

**The progress bar does not appear during local testing**

`Write-Progress` only renders in an interactive PowerShell console. It will not appear when the script runs inside the Intune execution context on managed devices, which is expected. It is a local testing aid and has no effect on the install result.

---

## Recording an ISS Response File (InstallShield)

Some enterprise applications use InstallShield as their installer framework and require a response file — a `.iss` file — to drive a fully silent install. The ISS records every choice you make during an interactive install so the installer can replay those answers silently with no UI when deployed through Intune.

**How to tell if an installer uses InstallShield:**

Run the installer with `/?` or extract it with 7-Zip and look for a `setup.iss`, `_setup.dll`, or `setup.inx` file inside. The installer will also display an "InstallShield Wizard" title bar during a normal interactive install.

### Step 1 — Record the ISS file

Open an elevated command prompt, navigate to the folder containing the installer, and run:

```cmd
setup.exe /r /f1"C:\Temp\setup.iss"
```

`/r` tells InstallShield to record your responses. `/f1` sets the output path. Use an absolute path — relative paths are unreliable with InstallShield. Complete every screen of the installer exactly as you want it configured on managed endpoints: install path, feature selection, license acceptance, all of it. When the installer finishes, your responses will have been written to the path you specified.

Do not cancel partway through. The ISS file is only written on a complete successful install.

### Step 2 — Verify the ISS file was created

```cmd
type C:\Temp\setup.iss
```

The file should look something like this:

```ini
[InstallShield Silent]
Version=v7.00
File=Response File

[{12345678-ABCD-1234-ABCD-1234567890AB}-DlgOrder]
Dlg0={12345678-ABCD-1234-ABCD-1234567890AB}-SdWelcome-0
Count=3
Dlg1={12345678-ABCD-1234-ABCD-1234567890AB}-SdLicense2-0
Dlg2={12345678-ABCD-1234-ABCD-1234567890AB}-SdFinishReboot-0

[{12345678-ABCD-1234-ABCD-1234567890AB}-SdWelcome-0]
Result=1
```

Every section header contains the installer's ProductCode GUID. This must match the actual installer exactly. If it does not, the silent install will fail with exit code `-3`.

### Step 3 — Test the ISS file silently

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\Temp\setup_test.log"
```

`/s` runs silently. `/f2` writes a results log. The install should complete with no UI. Confirm the app appears in Apps and Features and the results log ends with `ResultCode=0`.

| ResultCode | Meaning |
|------------|---------|
| 0 | Success |
| -3 | GUID mismatch between ISS and installer |
| -5 | ISS file not found — check your `/f1` path |
| -6 | ISS file is incomplete — re-record from scratch |

### Step 4 — Enable InstallShield logging

InstallShield has two logging flags. Use `/f2` on every silent install. Add `/debuglog` when you need more detail.

**`/f2` — Results log (always use this):**

Captures each dialog result and the final ResultCode. Sufficient for confirming success or failure on most packages.

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_results.log"
```

**`/debuglog` — Full engine trace (use when `/f2` is not enough):**

Captures everything the InstallShield engine did internally — component evaluation, file operations, registry writes, condition checks, and errors that never appear in the `/f2` log. When a silent install fails with a non-obvious code, or succeeds but something is missing, this log tells you why.

```cmd
setup.exe /s /f1".\setup.iss" /debuglog"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_verbose.log"
```

There is no space between `/debuglog` and the path. That is an InstallShield requirement — adding a space causes the flag to be silently ignored and nothing gets logged.

**Using both flags together:**

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\...\setup_results.log" /debuglog"C:\ProgramData\...\setup_verbose.log"
```

Writing both logs to the IME logs folder means they are collected automatically when you run Collect Diagnostics from the Intune portal.

**Key lines to look for in the `/f2` results log:**

| Line | Meaning |
|------|---------|
| `ResultCode=0` | Success |
| `ResultCode=-3` | GUID mismatch |
| `ResultCode=-5` | ISS file not found |
| `ResultCode=-6` | ISS file is incomplete |

**Key search terms in the `/debuglog` trace:**

| Search term | What it tells you |
|-------------|------------------|
| `ProductCode=` | The installer's actual GUID — copy into your ISS section headers if there is a mismatch |
| `Error` | Any internal error with a description |
| `Rolling back` | Install started but failed and is undoing changes |
| `Return value 3` | MSI-level fatal error — look at the lines immediately above for the cause |

The verbose log can be large. Start at the last 20 to 30 lines since failures almost always appear near the end, then search backwards for `Error` or `Return value 3` to find the root cause.

### Step 5 — Copy the ISS file into your package folder

```
YourInstaller.exe
setup.iss
Install-YourApp.ps1
Uninstall-YourApp.ps1
Detect-YourApp.ps1
```

In the install script, set `$InstallArguments` to `/s /f1"setup.iss"`. The script resolves its own folder path at runtime and passes the full absolute path to the installer, so a relative reference in the argument string works correctly when Intune deploys it.

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 1.0 | 03/06/2026 | Initial template release |
| 2.0 | 03/09/2026 | Detection script overhauled. DisplayName search is now the recommended detection method, replacing direct GUID targeting. Added $MinimumVersion support. Detection now searches 64-bit, 32-bit, and per-user hives. RegistryGUID retained but demoted with supersedence warnings. |
| 2.1 | 03/09/2026 | Invoke-IntuneInstall.ps1 updated to add DisplayName as a post-install detection type. Watch-Install.ps1 updated to annotate DisplayName output with ready-to-paste filter suggestions. README updated with full Invoke-IntuneInstall and Watch-Install documentation. |
| 2.2 | 03/10/2026 | Added ISS Response File section covering how to record, test, and troubleshoot InstallShield silent response files. |
| 2.3 | 03/10/2026 | Consolidated /f2 and /debuglog into a single unified section. Expanded /debuglog coverage to include uninstall usage, the no-space syntax requirement, and additional search term guidance for the verbose log. |
| 2.4 | 03/12/2026 | Added Watch-Uninstall.ps1 (v1.0) and Compare-WatchReports.ps1 (v1.0). Watch-Install.ps1 updated to v1.5 with auto-save of Watch_Installer JSON next to the installer exe. Full Watch workflow section added with file layout example. |
| 2.5 | 03/13/2026 | Watch-Install.ps1 updated to v1.6: fixed two bugs that prevented correct JSON output — ExitMeaning was referenced before it was defined, and two conflicting JSON-build blocks produced duplicate files with inconsistent schemas. Both replaced with a single canonical block. Watch-Uninstall.ps1 updated to v1.1: fixed three field-path bugs caused by the v1.6 schema change — AppName, UninstallString, and registry key paths were all reading from paths that no longer existed in the new JSON. Watch-Suite.ps1 (v1.0) added: combines all three Watch phases in a single session with one file picker, shares all data in memory between phases with no JSON round-tripping, and includes the RegistryKeysAdded path-extraction fix. README fully rewritten. |
