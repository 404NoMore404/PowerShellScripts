# Intune Win32 Package Templates

## Overview

This folder contains PowerShell scripts for deploying and observing applications via Microsoft Intune as Win32 apps. The goal was to build a reusable foundation so that packaging a new application does not require writing scripts from scratch each time. The structure is consistent across every package, the logging format is always the same, and the only things that change between packages are filled in at the top of each script in a dedicated configuration block.

These templates were built and tested against real-world Intune deployments. They account for common edge cases like already-installed detection, path resolution differences depending on how PowerShell invokes the script, leftover file cleanup on uninstall, and producing logs that land in the right place for Intune's built-in device diagnostic collection.

---

## Template Files

| File | Purpose |
|------|---------|
| `TEMPLATE_Install-APPNAME.ps1` | Silent install wrapper with logging and progress indicator |
| `TEMPLATE_Uninstall-APPNAME.ps1` | Silent uninstall wrapper with logging and cleanup |
| `TEMPLATE_Detect-APPNAME.ps1` | Intune detection script supporting four detection methods |
| `Invoke-IntuneInstall.ps1` | Universal install/uninstall wrapper, drop-in for every package |
| `Watch-Install.ps1` | Interactive pre-packaging observation tool — runs installer, captures all registry and file changes, saves machine-readable JSON for use by the other Watch scripts |
| `Watch-Uninstall.ps1` | Mirrors Watch-Install.ps1 for uninstalls — loads the installer JSON, runs the uninstaller, and reports exactly what was cleaned up vs what was left behind |
| `Compare-WatchReports.ps1` | Diffs the installer and uninstaller JSON files to produce a definitive report of every file and registry key the uninstaller failed to clean up |

---

## Recommended Packaging Workflow

The scripts are designed to be used in a specific order. Following this sequence means you always have the right values before you need them.

**Step 1 — Run Watch-Install.ps1 on a test machine**

Before writing a single configuration value, run the installer through Watch-Install.ps1. This tells you exactly what the installer writes — the DisplayName, DisplayVersion, registry key location, and every file created. These are the values you will paste into your configuration blocks. Watch-Install.ps1 also saves a `Watch_Installer_<AppName>.json` file next to the installer exe, which the other Watch scripts use.

**Step 2 — Copy and rename the template files**

Copy the three template files into your package folder and rename them to match your application.

```
TEMPLATE_Install-APPNAME.ps1    -->    Install-7Zip.ps1
TEMPLATE_Uninstall-APPNAME.ps1  -->    Uninstall-7Zip.ps1
TEMPLATE_Detect-APPNAME.ps1     -->    Detect-7Zip.ps1
```

Alternatively, use Invoke-IntuneInstall.ps1 as a single drop-in wrapper instead of separate install and uninstall scripts. See the Invoke-IntuneInstall section for details.

**Step 3 — Fill in the configuration blocks**

Open each script and fill in the Configuration Block at the top using the values Watch-Install.ps1 reported. Every variable has a comment explaining what it expects.

**Step 4 — Test locally**

Always test all scripts on a real machine before packaging. Full testing instructions are in the testing section of this document.

**Step 5 — (Optional) Validate uninstaller cleanliness with Watch-Uninstall.ps1 and Compare-WatchReports.ps1**

After testing the uninstall script, run Watch-Uninstall.ps1 to record exactly what the uninstaller removed. Then run Compare-WatchReports.ps1 to diff the install and uninstall records. This tells you definitively whether the uninstaller leaves files or registry keys behind — critical for clean re-installs and supersedence.

**Step 6 — Package and upload to Intune**

Once local testing passes, package the folder using the Win32 Content Prep Tool and upload to Intune.

---

## Script Details

### Install-APPNAME.ps1

This script is the install wrapper. When Intune runs it, it handles everything from pre-flight checks through the actual install and post-install verification. It is designed so that even if something fails partway through, the log will tell you exactly where and why without needing to remote into the machine.

**What it does, in order:**

1. Creates the log folder if it does not exist and starts a timestamped log file.
2. Logs the machine name, username, OS version, and available disk space so you have full context when reading the log remotely.
3. Checks that it is running as Administrator and exits immediately if not.
4. Resolves its own folder path using a three-tier fallback so the script works whether it is run via `-File`, dot-sourced, or invoked directly. This path is used to find the installer and ISS file sitting next to the script.
5. Confirms the installer file and (if applicable) the ISS response file exist in the expected location.
6. Checks the registry to see if the application is already installed. If it is, the script exits with code 0 so Intune does not attempt a reinstall.
7. Launches the installer silently using `Start-Process` in non-blocking mode so a progress bar can run while waiting for it to finish.
8. Displays a live progress bar in the console showing elapsed time and an estimated percentage based on the duration you configure. This prevents any confusion during testing about whether the install is still running or has silently failed.
9. Reads the installer exit code and maps it to a human-readable result in the log.
10. Waits ten seconds then checks the registry again to confirm the install registered correctly.
11. Checks for the expected Windows service if the application installs one.
12. Copies the InstallShield debug log (if present) into the Intune logs folder so both logs are collected together during device diagnostics.
13. Writes a summary block at the end with the result, exit code, and total duration.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$AppName` | Display name used in log headers. Example: `"7-Zip 24.08"` |
| `$AppVersion` | Version number. Example: `"24.08.0.0"` |
| `$InstallerFileName` | Filename of the installer EXE or MSI. Example: `"7z2408-x64.exe"` |
| `$InstallArguments` | Silent install flags. See common examples in the script comments |
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

If you are unsure which installer type an EXE uses, run it through Watch-Install.ps1 first. You can also run it with `/?` or check the vendor's documentation.

---

### Uninstall-APPNAME.ps1

This script handles removal of the application. Unlike the install script, it does not need to know where it is located on disk because everything it does is based on registry lookups and hardcoded system paths rather than files sitting next to the script.

**What it does, in order:**

1. Creates the log folder and starts a timestamped uninstall log file.
2. Logs machine name and username for context.
3. Checks for Administrator privileges.
4. Looks up the application in the registry. If it is not found the script logs a warning and skips the uninstall step rather than failing.
5. Runs the uninstall using either MSI product code or a direct EXE uninstaller, depending on which method you configure.
6. For MSI uninstalls, enables verbose MSI logging so a detailed MSI log is also written to the Intune logs folder.
7. Iterates through any leftover folders and registry keys you define and removes them if they exist.
8. Provides comment blocks for optional additional cleanup such as stopping services, removing scheduled tasks, or deleting cached installer files.
9. Verifies the registry entry is gone after uninstall and logs a warning if it is still present.
10. Writes a summary block at the end.

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

The `PSChildName` column is the value you need. Alternatively, run Watch-Install.ps1 and it will report this for you automatically from the registry diff.

---

### Detect-APPNAME.ps1

This script is uploaded directly to Intune as a custom detection script. Intune runs it silently on the device and interprets the result based on the exit code and whether anything was written to the console.

The rules Intune follows are simple: if the script exits with code `0` and writes output to the console, the app is considered installed. If the script exits with any other code or writes nothing, the app is considered not installed.

**Four detection methods are available:**

**DisplayName (recommended)** — searches all Uninstall registry hives for an app whose DisplayName matches a wildcard filter. This is the most reliable method because it works regardless of which version is installed, which GUID the package used, whether the app is 32-bit or 64-bit, and whether it was installed per-machine or per-user. It is the right default for any app you plan to supersede or upgrade in the future, because any installed version will pass detection rather than a single specific build. Run Watch-Install.ps1 to get the exact DisplayName to use.

**RegistryGUID** — targets a specific MSI product GUID or registry key name directly. Product GUIDs change with every new version, so detection will fail after an upgrade and Intune will attempt a reinstall on top of an already-installed app. Only use this method if you need pinpoint control over one specific package with no plans to supersede it.

**File** — checks whether a specific file exists at a known path. Useful for applications that do not create a registry entry, such as portable apps or certain system tools.

**Service** — checks whether a Windows service with a specific name is registered on the machine. Useful for server-side or background service applications where the service presence is the most meaningful indicator that the install succeeded.

Only one method is active at a time. The other three are commented out in the configuration block.

**A note on version checking and supersedence:**

The detection script's job is to answer "is this app present?" — not "is this exact build present?". Intune handles version enforcement through the package itself and supersedence rules, not the detection script. For that reason, `$ExpectedVersion` defaults to `$null` and you should leave it that way for any package that participates in a supersedence chain.

If you need a minimum baseline — for example, version 20 or newer counts but version 10 does not — use `$MinimumVersion` instead. This lets newer versions pass detection while still blocking outdated installs from being considered compliant.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$DetectionMethod` | `"DisplayName"`, `"RegistryGUID"`, `"File"`, or `"Service"` |
| `$DisplayNameFilter` | Wildcard app name for DisplayName method. Example: `"*7-Zip*"` |
| `$ExpectedVersion` | Exact version string, or `$null` to skip. Leave `$null` for supersedence. |
| `$MinimumVersion` | Minimum acceptable version string, or `$null` to skip |
| `$RegistryPath` | Full uninstall registry path (RegistryGUID method) |
| `$DetectionFilePath` | Full file path (File method) |
| `$DetectionServiceName` | Windows service name (Service method) |

---

### Invoke-IntuneInstall.ps1

This is a single drop-in wrapper that handles both install and uninstall from one file. Instead of maintaining separate Install and Uninstall scripts, you drop this file into every package folder alongside the installer, fill in the configuration block at the top, and call it with `-IsUninstall` for removal.

**When to use this instead of the separate Install/Uninstall templates:**

Use Invoke-IntuneInstall.ps1 when you want minimal files per package and do not need the full progress bar, pre-flight checks, or InstallShield ISS support that the dedicated templates provide. It is well-suited for straightforward MSI and single-EXE packages. Use the dedicated templates when you need richer logging, a visual progress indicator during testing, or InstallShield ISS-based installs.

**What it does:**

Invoke-IntuneInstall.ps1 auto-detects the installer in its own folder (or uses a hardcoded filename if you set one), builds the correct msiexec or EXE command, runs it, evaluates the exit code, and optionally runs a post-install detection check to confirm the install actually took effect before reporting success to Intune.

For uninstalls it first tries the MSI product code if you supply one, then falls back to a configured EXE uninstaller path, and finally attempts a registry lookup for the uninstall string if neither is configured.

**Configuration block variables:**

| Variable | What to fill in |
|----------|----------------|
| `$AppName` | Display name for log file names and messages. Example: `"7-Zip"` |
| `$AppVersion` | Version number. Example: `"24.08.0.0"` |
| `$AppVendor` | Vendor name. Example: `"Igor Pavlov"` |
| `$MSIProductCode` | MSI product GUID for clean uninstalls. Leave blank to use file path. |
| `$EXEUninstallPath` | Full path to EXE uninstaller on the endpoint, if applicable. |
| `$DetectionType` | `"DisplayName"`, `"RegistryKey"`, `"File"`, or `"None"` |
| `$DetectionNameFilter` | Wildcard filter for DisplayName post-install check. Example: `"*7-Zip*"` |
| `$DetectionValue` | Registry key path or file path for RegistryKey or File detection. |

**Post-install detection in Invoke-IntuneInstall.ps1:**

The post-install detection check runs immediately after the installer exits and catches installers that exit with code 0 but silently fail. Three methods are available, consistent with the detection script:

`DisplayName` is the recommended method. It searches all Uninstall registry hives using a wildcard name filter, the same approach used in Detect-APPNAME.ps1. Set `$DetectionNameFilter` to the same wildcard you used in your detection script. Run Watch-Install.ps1 first — it prints the exact DisplayName the installer registers with a ready-to-paste filter suggestion.

`RegistryKey` checks that a specific registry path exists. Use when you need to verify a particular key rather than a display name.

`File` checks that a specific file path exists. Use for apps without a standard registry entry.

**Usage:**

```powershell
# Install
powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1

# Uninstall
powershell.exe -ExecutionPolicy Bypass -File Invoke-IntuneInstall.ps1 -IsUninstall
```

---

### Watch-Install.ps1

Watch-Install.ps1 is an interactive pre-packaging observation tool. Right-click and run it as Administrator — it self-elevates automatically. A Windows file picker opens so you can select your installer, then you optionally supply silent arguments. Registry and filesystem watching are always enabled; no flags are required.

**Always run this before packaging.** The values it reports — particularly DisplayName and DisplayVersion from the registry diff — are exactly what you need for your detection scripts. There is no guessing or manual registry browsing required.

**What it does, in order:**

1. Self-elevates to Administrator if not already running elevated.
2. Opens a Windows file picker filtered to `.exe`, `.msi`, `.msix`, and `.appx` files, defaulting to your Downloads folder.
3. Prompts for optional silent install arguments. Press Enter to skip for GUI installs.
4. Shows a confirmation screen and waits for you to press Enter before launching.
5. Takes before snapshots of all Uninstall registry hives and top-level directories in Program Files, LocalAppData, AppData, and ProgramData.
6. Launches the installer and waits for it to complete.
7. Takes after snapshots and diffs against the before state.
8. Prints a full console report: exit code with meaning, all new registry keys with every value, all new files grouped by directory (recursed fully), and all modified files in pre-existing directories grouped by directory.
9. Auto-saves a `Watch_Installer_<AppName>.json` file next to the installer exe containing all captured data in machine-readable format. This JSON is consumed by Watch-Uninstall.ps1 and Compare-WatchReports.ps1.
10. Prompts to save a human-readable `.txt` copy of the report. Default filename is `<InstallerName>_<YYYYMMDD>_InstallReport.txt`, defaulting to your Desktop.

**What the console report shows:**

The registry diff output includes every value written to new uninstall keys, with the DisplayName called out explicitly for use in detection scripts:

```
[REG]  HKEY_LOCAL_MACHINE\SOFTWARE\...\Uninstall\Google Chrome
       DisplayName     : Google Chrome  <-- use as "*Google Chrome*" in detection scripts
       DisplayVersion  : 146.0.7680.72
       Publisher       : Google LLC
       InstallLocation : C:\Program Files\Google\Chrome\Application
       UninstallString : "...\setup.exe" --uninstall --channel=stable ...
```

If no new registry keys appear, the app does not register in the standard Uninstall hives. Switch to File detection and use a path from the new files section.

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `Watch_Installer_<AppName>.json` | Next to installer exe | Machine-readable install record for Watch-Uninstall and Compare-WatchReports |
| `<AppName>_<YYYYMMDD>_InstallReport.txt` | Location you choose | Human-readable report for reference and tickets |
| `PKG_WatchInstall_<timestamp>.log` | IME logs folder | Full observation log collected by Intune diagnostics |

**Usage:**

```powershell
# Interactive mode (recommended) — just double-click or right-click Run with PowerShell
.\Watch-Install.ps1
```

---

### Watch-Uninstall.ps1

Watch-Uninstall.ps1 mirrors Watch-Install.ps1 for uninstalls. It loads the `Watch_Installer_<AppName>.json` produced by Watch-Install.ps1 so it knows exactly which files and registry keys were installed. It then runs the uninstaller and checks each tracked item to determine what was actually cleaned up vs what remains.

**Run this after Watch-Install.ps1 and before Compare-WatchReports.ps1.** Together the three scripts give you a complete picture of whether the uninstaller leaves a clean system.

**What it does, in order:**

1. Self-elevates to Administrator if not already elevated.
2. Opens a file picker to select the `Watch_Installer_<AppName>.json` file. The picker defaults to Downloads and is filtered to `Watch_*.json` files.
3. Loads the installer JSON and displays the app name, version, and count of tracked files and registry keys.
4. Reads the `UninstallString` from the stored registry data and offers it as the default uninstall method. You can also browse for an uninstaller executable or enter a path manually.
5. Prompts for any additional uninstall arguments.
6. Shows a confirmation screen and waits before launching.
7. Checks which tracked files and registry keys exist on disk before the uninstaller runs (catches files already missing due to updates or manual cleanup).
8. Launches the uninstaller and waits for completion.
9. Checks every tracked file and registry key against the current disk state, splitting them into removed vs remaining.
10. Auto-saves a `Watch_Uninstaller_<AppName>.json` in the same folder as the installer JSON.
11. Prints a full console report with colour-coded sections for removed items (green) and remaining items (red).
12. Prompts to save a human-readable `.txt` report.

**Uninstall method selection:**

When the UninstallString is detected from the stored registry data, the script presents a three-way choice:

| Option | When to use |
|--------|------------|
| `U` — Use detected string (default) | The UninstallString from the registry is a standard exe path. Press Enter to accept. |
| `B` — Browse | The detected string is a wrapper or you want to point to a different uninstaller. Opens a file picker. |
| `M` — Manual entry | The uninstaller requires a custom path you want to type in directly. |

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `Watch_Uninstaller_<AppName>.json` | Same folder as installer JSON | Machine-readable uninstall record for Compare-WatchReports |
| `<AppName>_<YYYYMMDD>_UninstallReport.txt` | Location you choose | Human-readable report |
| `PKG_WatchUninstall_<timestamp>.log` | IME logs folder | Full observation log |

**Usage:**

```powershell
# Interactive mode — just double-click or right-click Run with PowerShell
.\Watch-Uninstall.ps1
```

---

### Compare-WatchReports.ps1

Compare-WatchReports.ps1 is the final step in the Watch workflow. It loads both JSON files produced by Watch-Install.ps1 and Watch-Uninstall.ps1, diffs them, and produces a definitive report of every file and registry key the installer created that the uninstaller failed to remove.

**Run this after both Watch-Install.ps1 and Watch-Uninstall.ps1 have completed.** This is the script that answers the question: does this uninstaller leave a clean system?

**What it does, in order:**

1. Self-elevates if needed.
2. Opens a file picker for the `Watch_Installer_<AppName>.json` file.
3. Opens a second file picker for the `Watch_Uninstaller_<AppName>.json` file, defaulting to the same folder as the installer JSON.
4. Warns if the two files are for different apps and asks you to confirm before continuing.
5. Builds sets of installed and removed items and computes the diff.
6. For each leftover item, checks whether it currently exists on disk to distinguish between items the uninstaller skipped (a real problem) vs items that were already gone before the uninstaller ran (expected for things like temp files).
7. Prints a colour-coded console report with a headline verdict, detailed stats, leftover files grouped by directory, leftover registry keys with all stored values, and a section for items not in the remove list but already gone from disk.
8. Prompts to save a `.txt` copy of the diff report.

**Verdict levels:**

| Verdict | Criteria |
|---------|---------|
| `CLEAN UNINSTALL` | Zero files or registry keys remain on disk |
| `MINOR LEFTOVERS` | Fewer than 10 items remain on disk |
| `DIRTY UNINSTALL` | 10 or more items remain on disk |

**Understanding the diff sections:**

The report distinguishes between two categories of "not removed":

- **Still on disk (PROBLEM)** — The item was installed, is not in the uninstaller's remove list, and is still physically present. These are genuine leftovers that could interfere with a clean re-install or leave sensitive data behind.
- **Already gone (OK)** — The item was installed, is not in the uninstaller's remove list, but is no longer on disk. This is normal for temp files, cached content, or items cleaned up by another process.

**Files produced:**

| File | Location | Purpose |
|------|----------|---------|
| `<AppName>_<YYYYMMDD>_DiffReport.txt` | Location you choose | Human-readable diff report for documentation or tickets |
| `PKG_CompareReports_<timestamp>.log` | IME logs folder | Comparison log |

**Usage:**

```powershell
# Interactive mode — just double-click or right-click Run with PowerShell
.\Compare-WatchReports.ps1
```

---

## Full Watch Workflow Example

The following shows the complete sequence for Google Chrome, producing a clean install and uninstall audit trail.

**Step 1 — Run Watch-Install.ps1**

Select `ChromeSetup.exe` in the file picker, leave arguments blank (Chrome's stub handles silent mode internally). After the install completes, the report shows:

```
[REG]  ...\Uninstall\Google Chrome
       DisplayName     : Google Chrome  <-- use as "*Google Chrome*" in detection scripts
       DisplayVersion  : 146.0.7680.72
       InstallLocation : C:\Program Files\Google\Chrome\Application
```

A `Watch_Installer_Google_Chrome.json` is saved next to `ChromeSetup.exe`.

**Step 2 — Fill in your package configuration**

Copy `DisplayName` and `DisplayVersion` from the report directly into your install, uninstall, and detection script configuration blocks.

**Step 3 — Run Watch-Uninstall.ps1**

Select `Watch_Installer_Google_Chrome.json`. The script detects the UninstallString automatically and offers it as the default. Press Enter to accept. After the uninstall completes, a `Watch_Uninstaller_Google_Chrome.json` is saved in the same folder.

**Step 4 — Run Compare-WatchReports.ps1**

Select both JSON files. The report produces a verdict:

- **CLEAN UNINSTALL** — Chrome's uninstaller removed everything it installed.
- **DIRTY UNINSTALL** — The report lists every leftover file and registry key grouped by directory, so you know exactly what to add to `$LeftoverFolders` and `$LeftoverRegKeys` in your uninstall script.

**File layout after running all three scripts:**

```
Downloads\
  ChromeSetup.exe
  Watch_Installer_Google_Chrome.json
  Watch_Uninstaller_Google_Chrome.json
  Google_Chrome_20260312_InstallReport.txt
  Google_Chrome_20260312_UninstallReport.txt
  Google_Chrome_20260312_DiffReport.txt
```

---

## Log Files

All scripts write logs to the Intune management extension logs folder, which is the location Intune targets when you collect device diagnostics from the admin portal. You do not need to RDP into a machine to retrieve logs.

**Log folder:**
```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\
```

**Log files produced:**

| Filename | Script | Contents |
|----------|--------|---------|
| `[APPNAME]_LogFile_Installer_YYYY-MM-DD_HHMMSS.log` | Install template | Full install log |
| `[APPNAME]_LogFile_InstallShield_YYYY-MM-DD_HHMMSS.log` | Install template | Raw InstallShield debug log (if applicable) |
| `[APPNAME]_LogFile_Uninstaller_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Full uninstall log |
| `[APPNAME]_LogFile_MSI_Uninstall_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Verbose MSI uninstall log (MSI method only) |
| `PKG_Install_[APPNAME]_YYYYMMDD_HHMMSS.log` | Invoke-IntuneInstall | Install log |
| `PKG_Uninstall_[APPNAME]_YYYYMMDD_HHMMSS.log` | Invoke-IntuneInstall | Uninstall log |
| `PKG_[APPNAME]_msi.log` | Invoke-IntuneInstall | MSI verbose log |
| `PKG_WatchInstall_YYYYMMDD_HHMMSS.log` | Watch-Install | Full observation log |
| `PKG_WatchUninstall_YYYYMMDD_HHMMSS.log` | Watch-Uninstall | Full observation log |
| `PKG_CompareReports_YYYYMMDD_HHMMSS.log` | Compare-WatchReports | Diff comparison log |

**Log entry format:**

Every log line follows the same format for easy reading and searching:

```
2026-03-06 10:30:01  [OK   ]  Registry entry confirmed.
2026-03-06 10:30:02  [WARN ]  SQL Server service not found. Reboot may be required.
2026-03-06 10:30:03  [ERROR]  Installer EXE not found. Ensure it is in the same folder as this script.
2026-03-06 10:30:04  [INFO ]  Installer exit code: 0
```

When reviewing a log after a failure, search for `ERROR` first to jump straight to the problem. `WARN` entries indicate something unexpected but non-fatal. `OK` entries confirm each step completed successfully.

---

## Testing Locally

Testing locally before packaging is critical. Packaging and uploading an untested script to Intune and then deploying it to machines is the slowest possible feedback loop for debugging.

**Before testing, confirm:**
- PowerShell is open as Administrator
- You are in the same folder as the scripts and installer files
- The application is not currently installed (for install testing) or is installed (for uninstall testing)

**Test the install script:**

```powershell
cd "C:\Path\To\PackageFolder"
. .\Install-YourApp.ps1
```

Watch the console for color-coded output. A progress bar will appear while the installer runs. When it finishes, open the log file and confirm the last line shows `SUCCESS`. Check Apps and Features to verify the application appears.

**Test the uninstall script:**

```powershell
cd "C:\Path\To\PackageFolder"
. .\Uninstall-YourApp.ps1
```

Confirm the application is gone from Apps and Features and verify the log shows no ERROR entries.

**Test the detection script:**

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Detect-YourApp.ps1"
echo $LASTEXITCODE
```

Run this once with the app installed and confirm you get exit code `0`. Then run the uninstall script and run detection again to confirm you get exit code `1`.

**Test Invoke-IntuneInstall.ps1:**

```powershell
cd "C:\Path\To\PackageFolder"
powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-IntuneInstall.ps1"
# After install completes:
powershell.exe -ExecutionPolicy Bypass -File ".\Invoke-IntuneInstall.ps1" -IsUninstall
```

Verify both install and uninstall log files appear in the IME logs folder and show no ERROR entries.

**Test the Watch scripts:**

The Watch scripts are interactive and self-elevate. Simply right-click each one and select Run with PowerShell, or launch them from an elevated terminal with no arguments:

```powershell
.\Watch-Install.ps1        # Run during install observation
.\Watch-Uninstall.ps1      # Run after install, during uninstall observation
.\Compare-WatchReports.ps1 # Run after both Watch scripts have completed
```

---

## Packaging for Intune

Once all scripts test successfully, package the folder with the Win32 Content Prep Tool.

**Folder contents when using Install/Uninstall templates:**
```
YourInstaller.exe         (or .msi)
setup.iss                 (InstallShield packages only)
Install-YourApp.ps1
Uninstall-YourApp.ps1
Detect-YourApp.ps1
```

**Folder contents when using Invoke-IntuneInstall.ps1:**
```
YourInstaller.exe         (or .msi)
Invoke-IntuneInstall.ps1
Detect-YourApp.ps1
```

> **Note:** The Watch scripts (`Watch-Install.ps1`, `Watch-Uninstall.ps1`, `Compare-WatchReports.ps1`) and their output files (`Watch_Installer_*.json`, `Watch_Uninstaller_*.json`, `*_InstallReport.txt`, etc.) are pre-packaging tools only. Do not include them in the folder you package for Intune deployment.

**Run the content prep tool:**

```cmd
IntuneWinAppUtil.exe -c "C:\Path\To\PackageFolder" -s "YourInstaller.exe" -o "C:\Output"
```

**Intune app configuration (Install/Uninstall templates):**

| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File Install-YourApp.ps1` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File Uninstall-YourApp.ps1` |
| Install behavior | System |
| Device restart behavior | App install may force a device restart |
| Detection rule | Custom script — upload `Detect-YourApp.ps1` |

**Intune app configuration (Invoke-IntuneInstall.ps1):**

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
| `3010` | Soft Reboot |
| `1641` | Soft Reboot |

---

## Common Issues and How to Fix Them

**Script says installer not found**

The install script looks for the installer in the same folder as the script itself. Always CD into the package folder before running. Invoke-IntuneInstall.ps1 uses the same folder resolution — if auto-detection is not finding the right file, hardcode `$InstallerFile` in the params block.

**Detection script returns 1 after a successful install**

If using the DisplayName method, the wildcard filter may not match the app's actual display name. Run Watch-Install.ps1 after a manual install — it prints the exact DisplayName with a ready-to-paste filter suggestion. If using RegistryGUID, the path or version string may not match exactly.

**Post-install detection check fails in Invoke-IntuneInstall.ps1**

If using DisplayName detection, confirm `$DetectionNameFilter` matches the value Watch-Install.ps1 reported. If `$DetectionType` is set to `'None'`, the check is skipped entirely — set it to `'DisplayName'` for production packages.

**Detection passes for the wrong version after an upgrade**

This is expected and correct behavior when using the DisplayName method with no version pinning. If you need to enforce a minimum version, set `$MinimumVersion` in Detect-APPNAME.ps1. Do not use `$ExpectedVersion` in a supersedence chain — it will cause detection to fail whenever a newer version is present.

**Exit code -3 from InstallShield installer**

The GUID in the ISS file section headers does not match the installer's product code. Open the ISS file and confirm every `{GUID}` in the section headers matches the ProductCode from the installer. You can find the correct GUID in the InstallShield debug log under `ProductCode=`.

**Uninstall script exits with 1603**

1603 is the MSI generic failure code and usually means either another installation is already in progress, the process is not running as SYSTEM or Administrator, or the application left behind a corrupted install state. Check the verbose MSI log in the Intune logs folder for the specific internal error.

**Progress bar does not appear during testing**

The progress bar uses `Write-Progress` which only displays in an interactive PowerShell console. It will not appear in the Intune execution context on managed devices, which is expected. It is a local testing aid only and does not affect the install outcome.

**Watch-Install.ps1 reports no new registry keys**

The installer does not write to the standard Uninstall hives. This means Registry and DisplayName detection methods will not work for this app. Use File detection instead, with a path from the new files section of the Watch-Install.ps1 report.

**Watch-Uninstall.ps1 cannot find the UninstallString**

The installer JSON may not have captured a registry key (same condition as above). Choose Browse or Manual entry at the uninstall method prompt and point directly to the uninstaller executable. The uninstall observation and diff will still work correctly — the UninstallString is only used as a convenience default.

**Compare-WatchReports.ps1 shows a high DIRTY count but the app appears fully removed**

Check the "Already gone (OK)" section of the diff report. Items listed there were installed but are no longer on disk and were not in the uninstaller's remove list — this is normal for temp files, log files, or content cleared by the app itself during uninstall. Only the "Still on disk (PROBLEM)" count reflects genuine leftovers.

**Watch-Uninstall.ps1 reports files missing before uninstall even started**

The app was updated, repaired, or partially removed between the time Watch-Install.ps1 ran and now. The script notes this count separately in its report and in the JSON. Compare-WatchReports.ps1 accounts for this correctly — it checks current disk state rather than relying purely on the JSON lists.

---

## Recording an ISS Response File (InstallShield)

Some enterprise applications use InstallShield as their installer framework and require a response file — a `.iss` file — to drive a fully silent install. The ISS file records every choice you make during a manual interactive install (install path, components, license agreement, etc.) so the installer can replay those answers silently with no UI when deployed via Intune.

**How to tell if an installer uses InstallShield:**

Run the installer with `/?` or extract it with 7-Zip and look for any of the following: a `setup.iss` file, a `_setup.dll`, or a `setup.inx` file inside. The installer may also display "InstallShield Wizard" in its title bar during a normal install.

---

### Step 1 — Run the installer in record mode

Open an elevated command prompt, navigate to the folder containing the installer, and run:

```cmd
setup.exe /r /f1"C:\Temp\setup.iss"
```

`/r` tells InstallShield to record your responses. `/f1` sets the output path for the ISS file. Use an absolute path — relative paths are unreliable with InstallShield. The installer will launch its normal graphical wizard. Complete every screen exactly as you want it configured on managed endpoints — install path, feature selection, license acceptance, and so on. When the installer finishes, your responses will have been written to `C:\Temp\setup.iss`.

**Important:** Do not dismiss or cancel the installer partway through. The ISS file is only written on a complete, successful install. If you cancel, the file will either not be created or will be incomplete.

---

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

[{12345678-ABCD-1234-ABCD-1234567890AB}-SdLicense2-0]
Result=1
...
```

Every section header contains the product GUID of the installer. This GUID must match the actual installer's ProductCode exactly — if it does not, the silent install will fail with exit code `-3`. Confirm the GUID by running the installer with verbose InstallShield logging (see Step 4) and checking the `ProductCode=` line in the debug log.

---

### Step 3 — Test the ISS file silently

Copy the ISS file into the same folder as the installer and run a silent replay:

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\Temp\setup_silent_test.log"
```

`/s` runs silently. `/f1` points to the ISS response file. `/f2` writes an InstallShield debug log. The install should complete with no UI. When it finishes, check:

1. The application appears in Apps and Features
2. The debug log at `C:\Temp\setup_silent_test.log` ends with `ResultCode=0`

A `ResultCode` of `0` means success. `-3` means the GUID in the ISS does not match the installer. `-5` means the ISS file was not found — double-check the `/f1` path.

---

### Step 4 — Enable InstallShield logging

InstallShield provides two separate logging flags. You should always use `/f2` on every silent install, and reach for `/debuglog` when you need more detail than `/f2` provides.

**`/f2` — Results log (always use this)**

`/f2` writes a short summary log capturing each dialog result and the final `ResultCode`. It is the fastest way to confirm whether an install succeeded and is sufficient for catching the most common failures like GUID mismatches and missing ISS files.

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_results.log"
```

**`/debuglog` — Full engine trace log (use when /f2 is not enough)**

`/debuglog` produces a detailed internal trace of everything the InstallShield engine did — component evaluation, file operations, registry writes, condition checks, feature selection logic, and error details that never appear in the `/f2` log. When a silent install fails with a non-obvious result code, or succeeds but the application is missing components or behaving incorrectly, `/debuglog` is what tells you why.

```cmd
setup.exe /s /f1".\setup.iss" /debuglog"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_verbose.log"
```

**Important:** There is no space between `/debuglog` and the path. This is an InstallShield requirement — the path must be joined directly to the flag. A space will cause the flag to be silently ignored and no log will be written.

**Using both flags together:**

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_results.log" /debuglog"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_verbose.log"
```

Both flags work identically for uninstalls. Use `/x` to trigger an uninstall and point `/f1` at a recorded uninstall ISS if you have one:

```cmd
setup.exe /s /x /f1".\uninstall.iss" /f2"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\uninstall_results.log" /debuglog"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\uninstall_verbose.log"
```

Writing all logs directly to the IME logs folder means they are collected automatically when you run Collect Diagnostics from the Intune portal, alongside your packaging logs.

**When to use each:**

| Situation | Use |
|-----------|-----|
| Confirming a silent install or uninstall succeeded | `/f2` alone is enough |
| Non-zero ResultCode and you need to know why | Add `/debuglog` |
| ResultCode=0 but application is missing components or behaving incorrectly | Add `/debuglog` |
| Verifying the correct ProductCode GUID before editing your ISS file | `/debuglog` — check near the top of the log |

**Key lines to look for in the `/f2` results log:**

| Line | What it means |
|------|--------------|
| `ProductCode={GUID}` | The installer's actual product GUID — must match every section header in your ISS file |
| `ResultCode=0` | Completed successfully |
| `ResultCode=-3` | GUID mismatch between ISS section headers and installer ProductCode |
| `ResultCode=-5` | ISS file not found — check the `/f1` path |
| `ResultCode=-6` | ISS file is incomplete — re-record it from a fresh install |

**Key things to search for in the `/debuglog` trace:**

| Search term | What it tells you |
|-------------|------------------|
| `ProductCode=` | The installer's actual GUID — copy this into your ISS section headers if there is a mismatch |
| `Error` | Any internal error InstallShield encountered, with a description |
| `Rolling back` | The install started but failed partway through and is undoing changes |
| `Feature:` | Which features were evaluated and whether they were installed or skipped |
| `Action:` | Each internal action executed — useful for pinpointing exactly where a failure occurred |
| `Return value 3` | MSI-level fatal error within an InstallShield action — look at the lines immediately above for the cause |

The verbose log can be large. Start by jumping to the last 20–30 lines — the point of failure is almost always near the end. Then search backwards for `Error` or `Return value 3` to find the root cause.

---

### Step 5 — Copy the ISS file into your package folder

Place `setup.iss` in the same folder as your installer and scripts before packaging with the Win32 Content Prep Tool. The install script expects it to be sitting next to the installer.

```
YourInstaller.exe
setup.iss              <-- must be here
Install-YourApp.ps1
Uninstall-YourApp.ps1
Detect-YourApp.ps1
```

In the install script, set `$InstallArguments` to:

```
/s /f1"setup.iss"
```

The script resolves the full path to the folder it is running from and passes it to the installer, so a relative reference in the argument string will work correctly at runtime.

---

### Common ISS Issues

**Exit code -3**

The GUID in every section header of the ISS file must exactly match the installer's ProductCode. If you recorded the ISS against a different version of the installer, the GUIDs will not match. Re-record the ISS against the exact installer version you are packaging.

**Install completes but wrong options are selected**

The ISS records the exact answers given during the recording session. If the target machines need different options than what you selected (for example, a different install path or a different feature set), delete the ISS file and re-record with the correct choices.

**Silent install launches a GUI anyway**

Some InstallShield installers have a "resume" mode that always shows UI when a reboot is pending from a previous install. Complete any pending reboots on your test machine before re-recording.

**ISS file works locally but fails when deployed by Intune**

Intune runs scripts as SYSTEM from a working directory that is not your package folder. The install script handles this by resolving its own path and passing the full absolute path to `/f1`. If you are calling the installer directly without using the template scripts, always use an absolute path for `/f1`, never a relative one.

---

## Version History

| Version | Date | Notes |
|---------|------|-------|
| 1.0 | 03/06/2026 | Initial template release |
| 2.0 | 03/09/2026 | Detection script overhauled. DisplayName search is now the recommended method, replacing direct GUID targeting. Added $MinimumVersion support. Detection now searches 64-bit, 32-bit, and per-user registry hives. RegistryGUID method retained but demoted with supersedence warnings. |
| 2.1 | 03/09/2026 | Invoke-IntuneInstall.ps1 updated to add DisplayName as a post-install detection type, consistent with the detection script. Watch-Install.ps1 updated to annotate DisplayName output with ready-to-paste filter suggestions. README updated to document Invoke-IntuneInstall.ps1 and Watch-Install.ps1 fully, including the recommended packaging workflow. |
| 2.2 | 03/10/2026 | Added ISS Response File section covering how to record, test, and troubleshoot InstallShield silent response files for packages that require them. |
| 2.3 | 03/10/2026 | Consolidated /f2 and /debuglog into a single unified Step 4. Removed duplicate standalone /debuglog section. Expanded /debuglog coverage to include uninstall usage, the no-space syntax requirement, and additional search term guidance for the verbose log. |
| 2.4 | 03/12/2026 | Added Watch-Uninstall.ps1 and Compare-WatchReports.ps1. Watch-Install.ps1 updated to v1.5 — now auto-saves Watch_Installer_AppName.json next to the installer exe after every run. Watch-Uninstall.ps1 (v1.0) loads the installer JSON, detects the UninstallString automatically, runs the uninstaller, and saves Watch_Uninstaller_AppName.json. Compare-WatchReports.ps1 (v1.0) diffs both JSON files and produces a colour-coded verdict (CLEAN / MINOR LEFTOVERS / DIRTY UNINSTALL) with full detail on every leftover file and registry key. README updated with full Watch workflow section, file layout example, updated template files table, updated log files table, updated common issues, and note excluding Watch scripts from Intune packages. |
