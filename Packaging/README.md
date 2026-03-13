# Intune Win32 Package Templates

## Overview

This repository contains PowerShell scripts for packaging and deploying applications through Microsoft Intune as Win32 apps. The goal is a consistent, reusable foundation so that packaging a new application does not mean writing scripts from scratch every time.

There are three layers of tooling here. The first is the all-in-one packager: **Intunator.ps1**, which takes you from raw installer to a complete, upload-ready package folder in a single guided session. The second is the template layer: individual install, uninstall, and detection scripts you configure manually for cases that need custom logic. The third is the observation layer: the Watch scripts, which are pre-packaging tools you run on a test machine to learn exactly what an installer does before writing any configuration values.

All of these scripts have been built against real-world Intune deployments and account for the edge cases that tend to cause problems: apps that are already installed, path resolution differences depending on how PowerShell launches the script, leftover files the uninstaller does not clean up, and log output that lands exactly where Intune can collect it.

---

## Files in This Repository

| File | Purpose |
|------|---------|
| `Intunator.ps1` | All-in-one guided package builder — takes you from raw installer to a complete upload-ready package folder in one session |
| `TEMPLATE_Install-APPNAME.ps1` | Silent install wrapper with logging and a live progress indicator — for packages needing custom install logic |
| `TEMPLATE_Uninstall-APPNAME.ps1` | Silent uninstall wrapper with logging and post-uninstall cleanup — for packages needing custom uninstall logic |
| `TEMPLATE_Detect-APPNAME.ps1` | Custom detection script supporting four detection methods |
| `Watch-Install.ps1` | Interactive tool that monitors your installer, captures every registry and file change, and saves a JSON record used by the other Watch scripts |
| `Watch-Uninstall.ps1` | Mirrors Watch-Install for uninstalls — loads the installer JSON, runs the uninstaller, and reports what was removed vs what was left behind |
| `Compare-WatchReports.ps1` | Diffs the two Watch JSON files and produces a verdict on whether the uninstaller leaves a clean system |
| `Watch-Suite.ps1` | Runs all three Watch phases back-to-back in a single session with a single file picker — the fastest way to get a full install and uninstall audit |

---

## How the Pieces Fit Together

**Intunator.ps1 is the primary recommended workflow.** For the vast majority of packages it handles the entire journey: installer detection, silent argument verification, uninstall discovery, detection rule configuration, and generation of all three scripts plus a Package-Summary.txt with every Intune upload field pre-filled. At the end it optionally wraps everything with IntuneWinAppUtil.exe. If something cannot be resolved automatically, it writes an Escalation-Notes.txt explaining exactly what a senior engineer needs to review.

The **Watch scripts** are supplementary. Use them when you want more detailed insight into what an installer does before committing to a package — every registry key written, every file dropped, and whether the uninstaller actually cleans up. Intunator handles the most common packaging scenarios on its own, but Watch-Suite gives you the full forensic picture if you need it. The Watch scripts are pre-packaging tools only and never go inside an Intune package.

The **individual templates** are there when a package needs logic that Intunator cannot generate — ISS response files, custom pre/post scripts, progress bars during testing, or anything else that requires hand-editing beyond what the guided flow produces. Pull a template when Intunator's output needs to grow.

---

## Recommended Packaging Workflow

### Step 1 — Run Intunator.ps1

Open an elevated PowerShell terminal and run Intunator.ps1. It walks you through seven steps, doing the heavy lifting at each one:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Intunator.ps1"
```

**What happens in each step:**

**Step 1 — Select installer.** A file picker opens. Select your `.exe`, `.msi`, or `.msp`. Intunator reads the file header bytes to detect the installer engine (Inno Setup, NSIS, InstallShield, WiX, Squirrel, MSI, or generic EXE) and immediately suggests the correct silent arguments.

**Step 2 — App information.** Intunator reads the file's version info block and auto-fills app name, version, and publisher. Press Enter to accept each value or type to override.

**Step 3 — Install command.** Review the suggested silent arguments. If you want to verify them live, answer Yes and Intunator will run the installer on this machine, cycling through argument combinations from most-suppressed to least until it finds one that installs silently. After each technically successful install it asks whether the install was truly silent — no visible windows — and auto-uninstalls and retries if not. If no combination works, all attempts are recorded in Escalation-Notes.txt.

**Step 4 — Uninstall command.** Intunator scans the registry for the installed app, identifies the uninstall method (MSI GUID or EXE), and builds the uninstall command. The DisplayName filter it derives from the actual registry entry — not the installer filename — so it will match all versions of the app at runtime. You can optionally test the uninstall live on this machine.

**Step 5 — Detection rule.** Choose from DisplayName (recommended), File, Service, or RegistryGUID. The DisplayName filter from Step 4 is carried forward automatically. You can optionally require a minimum installed version.

**Step 6 — Requirements.** Architecture and minimum OS version are shown and confirmed.

**Step 7 — Build package.** Intunator creates the output folder, copies the installer, generates all three scripts, and writes Package-Summary.txt. If IntuneWinAppUtil.exe is found on the machine (or you browse to it), it optionally wraps everything into a `.intunewin` file and opens the folder in Explorer.

### Step 2 — Review the output

Open the generated package folder. It contains:

```
[AppName]_[Version]\
  Source\
    [installer file]
    Install-[AppName].ps1
    Uninstall-[AppName].ps1
    Detect-[AppName].ps1
  Package-Summary.txt
  Escalation-Notes.txt     (only if issues were flagged)
  [AppName].intunewin      (only if IntuneWinAppUtil.exe was available)
```

Open `Package-Summary.txt`. Every Intune upload field is pre-filled: app name, publisher, version, install command, uninstall command, detection method, requirements, and step-by-step upload instructions.

If `Escalation-Notes.txt` was generated, read it before deploying. It lists exactly what could not be resolved automatically and what needs manual review, along with a record of every install and uninstall attempt that was made.

### Step 3 — Test before deploying

Even though Intunator verifies the install and uninstall during packaging (if you opted in), always run the generated scripts once on a clean test machine before assigning to real devices. See the Testing section for how to do this.

### Step 4 — Upload to Intune

Use the fields in Package-Summary.txt to fill in the Intune app entry. Upload the `.intunewin` file, paste the install and uninstall commands, set requirements, and upload the detection script. Assign to a test group before broad deployment.

### When to use the Watch scripts instead

Run Watch-Suite (or Watch-Install) when you want the full forensic picture of what an installer does before committing to a package. Intunator covers the most common paths on its own, but Watch-Suite shows you every registry key written, every file dropped, every value set — and whether the uninstaller actually cleans them all up. This is especially useful for complex enterprise apps, InstallShield packages, or any installer that behaves unexpectedly.

### When to use the individual templates instead

Pull a template file when the generated scripts need custom logic: ISS response file handling, pre/post-install steps, a live progress bar during testing, conditional logic based on machine state, or anything else that cannot come from a guided flow. Use Intunator to generate the baseline, then modify the generated scripts — or copy a template and fill it in from scratch using the values Watch-Suite reported.

---

## Script Details

### Intunator.ps1

Intunator is the all-in-one guided packager. Run it on your packaging machine and it handles installer detection, silent argument verification, registry-based uninstall discovery, detection rule configuration, and output file generation in a single session.

**What it generates:**

| File | Purpose |
|------|---------|
| `Install-[AppName].ps1` | Intune-ready silent install wrapper with logging |
| `Uninstall-[AppName].ps1` | Intune-ready silent uninstaller that scans registry by DisplayName at runtime, handles MSI and EXE, and cleans up leftover shortcuts |
| `Detect-[AppName].ps1` | Detection script supporting DisplayName, File, Service, or RegistryGUID methods |
| `Package-Summary.txt` | Every Intune upload field pre-filled, plus step-by-step upload instructions |
| `Escalation-Notes.txt` | Flags anything that needs manual review, with full attempt logs |

**Installer type detection:**

Intunator reads the first 4 KB of the installer file to identify the engine and select the right silent arguments automatically.

| Detected type | Silent arguments used |
|--------------|----------------------|
| MSI | `/quiet /norestart` |
| MSP (patch) | `/quiet /norestart` |
| Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| NSIS (Nullsoft) | `/S` |
| InstallShield | `/s /v"/qn /norestart"` |
| WiX bootstrapper | `/quiet /norestart` |
| Squirrel | `--silent` |
| Unknown EXE | `/S` (medium confidence — escalation flag added) |

For medium or low confidence types, Intunator prompts you to review the args before proceeding, and if you opt into live verification it will auto-try multiple combinations ordered from most-suppressed to least.

**Uninstall script strategy:**

The generated Uninstall script scans the registry by DisplayName filter at runtime rather than hardcoding a product code. This means it handles any installed version of the app, not just the one that was present when the package was built. The fallback product code or EXE path captured at package time is embedded as a last-resort only.

**Escalation flags:**

Any condition Intunator cannot fully resolve generates an escalation flag. Common triggers include: medium-confidence installer type, install args not verified by a live test, Squirrel-style user-profile install, app not found in registry on the packaging machine, uninstall path inside a user profile, and RegistryGUID detection selected. All flags appear in Escalation-Notes.txt with a specific explanation and suggested resolution for each.

**Silence check:**

When live install verification is enabled, Intunator asks you after each technically successful install: "Was the install completely silent — zero visible windows?" If not, it auto-uninstalls using the registry's current uninstall string and tries the next quieter argument combination. This loop continues until a fully silent install is confirmed, you enter a custom arg string that works, or you exhaust all options and escalate.

**Usage:**

```powershell
# Default output to Desktop\IntunePackages\
powershell.exe -ExecutionPolicy Bypass -File ".\Intunator.ps1"

# Custom output root
powershell.exe -ExecutionPolicy Bypass -File ".\Intunator.ps1" -OutputRoot "D:\Packages"
```

---

### Watch-Suite.ps1

Watch-Suite is the recommended starting point when you want full forensic visibility into what an installer does before you package it. It combines all three Watch phases into a single interactive session so you walk away with the complete install and uninstall audit in one run.

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

It reads the `Watch_Installer_<AppName>.json` file you select, extracts the UninstallString from the stored registry data, and offers you three ways to proceed: use the detected string as-is, browse for a different uninstaller, or type a path manually. You can also append extra arguments at the optional arguments prompt.

After the uninstaller finishes, it checks every file and registry key from the installer record against current disk state and reports what was removed, what remains, and what was already missing before the uninstall started.

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

The script builds the set of files and registry keys that were installed but not in the uninstaller's remove list. For each of those items it then checks whether the item is actually on disk right now.

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

This is the install wrapper template you configure and ship inside the Intune package when you need custom install logic beyond what Intunator generates. Intunator already produces an Install script for you — use this template when you need to hand-edit the result or build a script from scratch for a package with special requirements.

**What it does, in order:**

1. Creates the log folder and starts a timestamped log file.
2. Logs machine name, username, OS version, and available disk space for full context when reading logs remotely.
3. Confirms it is running as Administrator and exits immediately if not.
4. Resolves its own folder path using a three-tier fallback so the script works whether it is run via `-File`, dot-sourced, or invoked directly.
5. Confirms the installer file exists. If an ISS response file is configured, confirms that exists too.
6. Checks the registry to see if the application is already installed. If it is, exits with code 0 so Intune does not attempt a reinstall.
7. Launches the installer silently using `Start-Process` in non-blocking mode so a progress bar can run concurrently.
8. Displays a live progress bar showing elapsed time and estimated percentage while the installer runs.
9. Maps the installer exit code to a plain-English description in the log.
10. Waits ten seconds, then re-checks the registry to confirm the install registered correctly.
11. Checks for the expected Windows service if the app installs one.
12. Copies the InstallShield debug log (if present) into the Intune logs folder.
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
|---------------|----------------|
| InstallShield with ISS | `/s /f1"setup.iss"` |
| MSI | `/quiet /norestart` |
| NSIS | `/S` |
| Inno Setup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| Generic EXE | `/install /quiet /norestart` |

---

### Uninstall-APPNAME.ps1

The uninstall wrapper template mirrors the install script in structure. Use it when you need custom uninstall logic beyond what Intunator generates.

**What it does, in order:**

1. Creates the log folder and starts a timestamped uninstall log.
2. Logs machine name and username for context.
3. Confirms Administrator privileges.
4. Looks up the application in the registry. If it is not found, logs a warning and skips the uninstall step rather than failing hard.
5. Runs the uninstall using either an MSI product code or a direct EXE uninstaller path, depending on which method you configure.
6. For MSI uninstalls, enables verbose MSI logging so a detailed log is written to the Intune logs folder.
7. Iterates through any leftover folders and registry keys you define and removes them if they exist.
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

Intunator generates this script for you automatically. Use the template when you need to hand-edit the result or write a detection script for a package that was not built through Intunator.

**Four detection methods are available:**

**DisplayName (recommended)** — searches all Uninstall hives for an app whose DisplayName matches a wildcard you define. This works regardless of the specific GUID the installer used, whether the app is 32-bit or 64-bit, whether it was installed per-machine or per-user, and whether you are superseding it with a newer version.

**RegistryGUID** — targets a specific product GUID or registry key name directly. Product GUIDs change with every new version, so detection will fail after an upgrade. Only use this if you need exact version pinning with no plans to supersede.

**File** — checks whether a specific file exists at a known path. Useful for apps that do not create a standard registry entry.

**Service** — checks whether a Windows service with a specific name is registered.

**A note on version enforcement:**

The detection script's job is to answer "is this app present?" not "is this exact build present?". For that reason, `$ExpectedVersion` defaults to `$null` and you should leave it that way for any package in a supersedence chain. If you need a minimum baseline, use `$MinimumVersion` instead.

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

## Full Workflow Examples

### Using Intunator.ps1 (recommended for most packages)

Run `Intunator.ps1`. When the file picker opens, select `ChromeSetup.exe`.

Intunator detects the installer type, suggests silent args, and (if you opt in) runs the installer to verify. It scans the registry, finds the Chrome entry, builds the uninstall command, and sets up a DisplayName-based detection filter derived from the actual registry entry.

At Step 7 it generates:

```
Desktop\IntunePackages\GoogleChrome_123.0.6312.86\
  Source\
    ChromeSetup.exe
    Install-GoogleChrome.ps1
    Uninstall-GoogleChrome.ps1
    Detect-GoogleChrome.ps1
  Package-Summary.txt
  GoogleChrome.intunewin      (if IntuneWinAppUtil.exe was available)
```

Open `Package-Summary.txt`. Every field is pre-filled. Copy the install and uninstall commands into Intune, upload the detection script, and you are done.

### Using Watch-Suite.ps1 (for forensic analysis before packaging)

Run `Watch-Suite.ps1`. When the file picker opens, select `ChromeSetup.exe`. Leave the arguments blank.

After the install completes, Phase 1 reports something like:

```
[REG]  ...\Uninstall\Google Chrome
       DisplayName     : Google Chrome  <-- use as "*Google Chrome*" in detection scripts
       DisplayVersion  : 123.0.6312.86
       InstallLocation : C:\Program Files\Google\Chrome\Application
       UninstallString : "C:\Program Files\Google\Chrome\Application\...\setup.exe" --uninstall ...
```

At the Phase 2 transition, press Enter to continue. Watch-Suite detects the UninstallString automatically — press Enter to accept. After the uninstall, Phase 3 produces the verdict. If the result is CLEAN UNINSTALL, you have everything you need. If it shows leftovers, the paths listed under "Still on disk (PROBLEM)" go into `$LeftoverFolders` and `$LeftoverRegKeys` in your uninstall script.

**File layout after a full Watch-Suite run:**

```
Downloads\
  ChromeSetup.exe
  Watch_Installer_Google_Chrome.json
  Watch_Uninstaller_Google_Chrome.json
  Google_Chrome_20260312_DiffReport.txt    (if you chose to save at the Phase 3 prompt)
  PKG_WatchSuite_20260312_143201.log
```

### Using the three Watch scripts separately

Run `Watch-Install.ps1` during the install. It saves `Watch_Installer_Google_Chrome.json` next to the installer.

After the install, run `Watch-Uninstall.ps1`. Select the `Watch_Installer_Google_Chrome.json` file. The script detects the UninstallString and offers it as the default — press Enter to accept. It saves `Watch_Uninstaller_Google_Chrome.json` in the same folder.

Finally, run `Compare-WatchReports.ps1`. Select both JSON files when prompted.

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
|----------------|--------|---------|
| `[APPNAME]\[APPNAME]_Installer_YYYY-MM-DD_HHMMSS.log` | Intunator-generated Install script | Full install log |
| `[APPNAME]\[APPNAME]_Uninstaller_YYYY-MM-DD_HHMMSS.log` | Intunator-generated Uninstall script | Full uninstall log |
| `[APPNAME]\[APPNAME]_MSI_YYYY-MM-DD_HHMMSS.log` | Intunator-generated Install/Uninstall | Verbose MSI log (MSI packages only) |
| `[APPNAME]_LogFile_Installer_YYYY-MM-DD_HHMMSS.log` | Install template | Full install log |
| `[APPNAME]_LogFile_InstallShield_YYYY-MM-DD_HHMMSS.log` | Install template | Raw InstallShield debug log (if applicable) |
| `[APPNAME]_LogFile_Uninstaller_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Full uninstall log |
| `[APPNAME]_LogFile_MSI_Uninstall_YYYY-MM-DD_HHMMSS.log` | Uninstall template | Verbose MSI uninstall log (MSI method only) |
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

Testing before packaging is one of the most important things you can do. Uploading an untested script to Intune and deploying it to machines is the slowest possible feedback loop for catching problems.

**Before testing, confirm:**

- PowerShell is open as Administrator
- You are in the same directory as the scripts and installer files
- The application is not currently installed (for install testing) or is installed (for uninstall testing)

**Test the generated scripts from Intunator:**

```powershell
cd "C:\Users\You\Desktop\IntunePackages\AppName_Version\Source"
.\Install-AppName.ps1
# Verify install, then:
.\Uninstall-AppName.ps1
# Verify removal, then:
powershell.exe -ExecutionPolicy Bypass -File ".\Detect-AppName.ps1"
echo $LASTEXITCODE   # Should be 1 after uninstall
```

**Test the template install script:**

```powershell
cd "C:\Path\To\PackageFolder"
.\Install-YourApp.ps1
```

Watch the console for color-coded output. A progress bar will show while the installer runs. When it finishes, open the log file and confirm the last entry shows `OK` or `SUCCESS`. Open Apps and Features and verify the application appears.

**Test the template uninstall script:**

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

**Package folder contents — Intunator output (Source subfolder):**

```
[installer file]
Install-[AppName].ps1
Uninstall-[AppName].ps1
Detect-[AppName].ps1
```

If Intunator already ran IntuneWinAppUtil.exe during Step 7, the `.intunewin` file is already in the package folder and you can skip the manual wrap step.

**Package folder contents — manual templates:**

```
YourInstaller.exe         (or .msi)
setup.iss                 (InstallShield packages only)
Install-YourApp.ps1
Uninstall-YourApp.ps1
Detect-YourApp.ps1
```

**Run the content prep tool (if not already done by Intunator):**

```cmd
IntuneWinAppUtil.exe -c "C:\Path\To\Source" -s "YourInstaller.exe" -o "C:\Output"
```

**Intune app configuration:**

| Setting | Value |
|---------|-------|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File ".\Install-[AppName].ps1"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File ".\Uninstall-[AppName].ps1"` |
| Install behavior | System (User for Squirrel/per-user apps) |
| Device restart behavior | Determine behavior based on return codes |
| Detection rule | Custom script — upload `Detect-[AppName].ps1` |

These exact strings are pre-filled in `Package-Summary.txt` when using Intunator.

**Return codes to configure in Intune:**

| Code | Type |
|------|------|
| `0` | Success |
| `3010` | Soft reboot required |
| `1641` | Soft reboot required |

---

## Common Issues and How to Fix Them

**Intunator flags an escalation but the package seems fine**

Read each flag in Escalation-Notes.txt carefully. Most flags are informational warnings — "uninstall was not verified by a live test" or "install behavior set to User" — rather than hard failures. A flag means the item needs human review before broad deployment, not that the package is broken. The attempt log in Escalation-Notes.txt shows exactly what was tried and what the result was.

**Intunator's silence check says the install wasn't silent but I don't see any windows**

The silence check asks whether *any* UI appeared — this includes brief progress dialogs that dismiss quickly, the app launching itself after install, or a systray icon appearing for the first time. If you are confident the install is silent enough for your environment, you can accept it anyway by answering Yes when asked. The package will still be built; the flag in Escalation-Notes.txt simply notes your confirmation.

**Intunator can't find the uninstall string for an app I just installed**

This usually means the app registered in a non-standard location (not the three standard Uninstall hives), or the install verification was skipped so the app is not actually installed on this machine. Run Watch-Install first to get the exact registry path, then use Intunator's manual fallback command prompt in Step 4 to enter it directly.

**Intunator generates a Squirrel escalation flag**

Squirrel-based apps (Discord, Slack, VS Code, etc.) install to the user profile rather than Program Files, which means they should use User install context in Intune instead of System. The flag is Intunator's reminder to change the Install behavior in the Intune Program tab. The generated scripts still work correctly — the uninstall script reads the path from the registry at runtime rather than hardcoding it.

**Script says the installer was not found**

The install script looks for the installer in the same folder as the script itself. Always `cd` into the Source folder before running locally. In Intune's execution context the script root is resolved automatically via `$PSScriptRoot`.

**Detection script returns 1 after a successful install**

If you are using the DisplayName method, the wildcard filter probably does not match the app's actual display name. Run Watch-Install or Watch-Suite and check the DisplayName line in the registry section — it prints a ready-to-paste suggestion right there in the output. If you used Intunator, check that the DisplayName filter in `Detect-[AppName].ps1` matches what appears in Apps and Features after a real install.

**Detection passes for the wrong version after an upgrade**

This is expected behavior when using the DisplayName method with no version pinning, which is the correct setup for packages in a supersedence chain. If you need to enforce a minimum version, set `$MinimumVersion` in the detection script. Do not set `$ExpectedVersion` in a supersedence chain — it will cause detection to fail as soon as a newer version is present.

**Exit code -3 from an InstallShield installer**

The GUID in the ISS file section headers does not match the installer's actual ProductCode. This almost always happens when the ISS was recorded against a different version than the one you are packaging now. Re-record the ISS against the exact installer version you are deploying. You can find the correct GUID in the InstallShield verbose log under `ProductCode=`.

**Uninstall script exits with 1603**

1603 is the MSI generic failure code. It usually means another installation is already in progress, the process is not running with sufficient privileges, or the application left behind a corrupted state from a previous failed install or uninstall. Check the verbose MSI log in the Intune logs folder for the specific internal error — the actual cause will be in the lines just before the failure point.

**Watch-Install.ps1 reports no new registry keys**

The installer does not write to the standard Uninstall hives. This means DisplayName and RegistryGUID detection methods will not work for this app. Use File detection in your detection script instead, picking a file path from the new files section of the Watch-Install report. The Watch_Installer JSON will still be created and will still work with Watch-Uninstall and Compare-WatchReports — the tracked items will just be files only, with no registry keys.

**Watch-Uninstall.ps1 cannot find the UninstallString**

Same root cause as above — the installer did not register in the standard Uninstall hives, so there is no stored UninstallString. Choose Browse or Manual at the uninstall method prompt and point directly to the uninstaller executable.

**Compare-WatchReports shows a high leftover count but the app looks fully removed**

Look at the "Already gone (OK)" section of the report. Items listed there were installed but are no longer on disk and were not in the uninstaller's explicit remove list. This is normal for temp files, cache content, and files the app deletes during its own shutdown. Only the "Still on disk (PROBLEM)" items are genuine leftovers worth addressing.

**Watch-Uninstall reports files missing before the uninstall even started**

The app was updated, repaired, or partially removed between when Watch-Install ran and when you ran Watch-Uninstall. The script tracks this count separately so those files do not inflate your leftover numbers.

**Watch-Suite stops between phases and I want to cancel**

That is exactly what the pause between phases is designed for. Press Ctrl+C at any "Press Enter to continue" prompt to stop there. The JSON file for the phase that already completed will have been saved next to your installer.

**Watch-Suite Phase 2 launches the wrong uninstaller**

At the Phase 2 uninstall method prompt, choose B to browse for the correct executable instead of accepting the detected string.

**The progress bar does not appear during local testing**

`Write-Progress` only renders in an interactive PowerShell console. It will not appear when the script runs inside the Intune execution context on managed devices, which is expected. It is a local testing aid and has no effect on the install result.

---

## Recording an ISS Response File (InstallShield)

Some enterprise applications use InstallShield as their installer framework and require a response file — a `.iss` file — to drive a fully silent install. The ISS records every choice you make during an interactive install so the installer can replay those answers silently with no UI when deployed through Intune.

**How to tell if an installer uses InstallShield:**

Run the installer with `/?` or extract it with 7-Zip and look for a `setup.iss`, `_setup.dll`, or `setup.inx` file inside. The installer will also display an "InstallShield Wizard" title bar during a normal interactive install. Intunator will also detect and flag this as `EXE-InstallShield` and note that an ISS file may be needed.

### Step 1 — Record the ISS file

Open an elevated command prompt, navigate to the folder containing the installer, and run:

```cmd
setup.exe /r /f1"C:\Temp\setup.iss"
```

`/r` tells InstallShield to record your responses. `/f1` sets the output path. Use an absolute path — relative paths are unreliable with InstallShield. Complete every screen of the installer exactly as you want it configured on managed endpoints. When the installer finishes, your responses will have been written to the path you specified.

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

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_results.log"
```

**`/debuglog` — Full engine trace (use when `/f2` is not enough):**

```cmd
setup.exe /s /f1".\setup.iss" /debuglog"C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AppName\setup_verbose.log"
```

There is no space between `/debuglog` and the path. That is an InstallShield requirement — adding a space causes the flag to be silently ignored and nothing gets logged.

**Using both flags together:**

```cmd
setup.exe /s /f1".\setup.iss" /f2"C:\ProgramData\...\setup_results.log" /debuglog"C:\ProgramData\...\setup_verbose.log"
```

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
| 2.1 | 03/09/2026 | Invoke-IntuneInstall.ps1 added as a single-file drop-in. Watch-Install.ps1 updated to annotate DisplayName output with ready-to-paste filter suggestions. README updated. |
| 2.2 | 03/10/2026 | Added ISS Response File section covering how to record, test, and troubleshoot InstallShield silent response files. |
| 2.3 | 03/10/2026 | Consolidated /f2 and /debuglog into a single unified section. Expanded /debuglog coverage to include uninstall usage, the no-space syntax requirement, and additional search term guidance for the verbose log. |
| 2.4 | 03/12/2026 | Added Watch-Uninstall.ps1 (v1.0) and Compare-WatchReports.ps1 (v1.0). Watch-Install.ps1 updated to v1.5 with auto-save of Watch_Installer JSON next to the installer exe. Full Watch workflow section added with file layout example. |
| 2.5 | 03/13/2026 | Watch-Install.ps1 updated to v1.6 (ExitMeaning / duplicate JSON block fixes). Watch-Uninstall.ps1 updated to v1.1 (field-path fixes for v1.6 schema). Watch-Suite.ps1 (v1.0) added. README fully rewritten. |
| 2.6 | 03/13/2026 | Invoke-IntuneInstall.ps1 removed. Intunator.ps1 (v1.0) added as the primary all-in-one package builder. Intunator guides the full workflow from raw installer to upload-ready package: installer type detection, live install/uninstall verification with silence check and auto-retry, registry-based DisplayName filter derivation, script generation, Package-Summary.txt, Escalation-Notes.txt, and optional IntuneWinAppUtil.exe wrapping. README restructured with Intunator as the primary recommended workflow and Watch scripts repositioned as supplementary forensic tools. |
