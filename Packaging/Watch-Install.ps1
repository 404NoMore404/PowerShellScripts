# ==============================================================================
# Watch-Install.ps1
# Purpose  : Interactive installer monitor. Pops a file picker, runs the
#            installer, then prints a full report of every registry key and
#            file the installer touched — no flags required.
#
# Usage    : Right-click → "Run with PowerShell"  (self-elevates automatically)
#            OR: .\Watch-Install.ps1
#
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.4
# Changelog:
#   1.4 - Added post-report save prompt (Y/N, default Y).
#         Opens a WinForms SaveFileDialog with a pre-filled filename in the
#         format <InstallerName>_<YYYYMMDD>_InstallReport.txt, defaulting to
#         the user's Desktop. Saves full report as UTF-8 plain text including
#         all registry key values, new files grouped by directory, modified
#         files grouped by directory, and summary. Save path is written to
#         the IME log for traceability.
#         Fixed self-elevation block: replaced multi-line WindowsPrincipal cast
#         that caused a PowerShell parser error with three explicit assignment
#         statements (GetCurrent → WindowsPrincipal → IsInRole check).
#   1.3 - Full interactive mode. Removed mandatory params and CLI switches.
#         Script now self-elevates, opens a WinForms OpenFileDialog to pick
#         the installer (filtered to .exe/.msi/.msix/.appx, defaults to
#         Downloads), prompts for optional silent arguments, then always
#         enables -WatchRegistry and -WatchFiles — no flags required.
#         Post-install report printed to console with full detail: all new
#         registry keys with every value, new files grouped by directory
#         (full recursive), and modified files in pre-existing directories
#         grouped by directory (files written after install start time).
#         Added Show-Banner, Write-ReportHeader, Write-ReportSection,
#         Write-ReportItem, and Write-ReportSubItem helper functions for
#         consistent styled console output.
#   1.2 - Fixed ArgumentList validation error when no arguments are supplied.
#         Start-Process rejects an empty string for -ArgumentList; both the
#         primary and fallback launch paths now only include ArgumentList when
#         the caller actually provided a value. Resolves crash with stub
#         installers (e.g. ChromeSetup.exe) that also reject stream
#         redirection, which previously made the fallback crash identically.
#   1.1 - Initial tracked release.
# ==============================================================================

# ==============================================================================
# REGION: SELF-ELEVATION
# ==============================================================================
$currentUser    = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin        = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n  Not running as Administrator — relaunching elevated...`n" -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ==============================================================================
# REGION: LOGGING
# ==============================================================================
$script:LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_WatchInstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Path (Split-Path $script:LogPath) -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

# ==============================================================================
# REGION: BANNER
# ==============================================================================
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║           WATCH-INSTALL  v1.4  — Intune Packager         ║" -ForegroundColor Cyan
    Write-Host "  ║    Monitors registry + filesystem changes during install  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

# ==============================================================================
# REGION: FILE PICKER
# ==============================================================================
function Select-InstallerFile {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = "Select Installer File"
    $dialog.Filter           = "Installers (*.exe;*.msi;*.msix;*.appx)|*.exe;*.msi;*.msix;*.appx|All Files (*.*)|*.*"
    $dialog.InitialDirectory = "$env:USERPROFILE\Downloads"
    $dialog.Multiselect      = $false

    # Dummy owner form forces dialog to appear on top of the terminal
    $owner        = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true

    $result = $dialog.ShowDialog($owner)
    $owner.Dispose()

    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "`n  No file selected. Exiting.`n" -ForegroundColor Yellow
        exit 0
    }
    return $dialog.FileName
}

# ==============================================================================
# REGION: SNAPSHOT HELPERS
# ------------------------------------------------------------------------------
# Registry snapshot  — captures every key under the standard uninstall hives.
# Filesystem snapshot — captures top-level entries in watched install roots.
#   After install:
#     • Brand-new top-level dirs  → recursed fully for every file inside them.
#     • Existing dirs with a newer LastWriteTime → scanned for files written
#       after $StartTime (catches patches, config drops, etc.).
#
# [CHANGE ME] - Add org-specific registry hives or install directories below.
# ==============================================================================
function Get-RegistrySnapshot {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        # [CHANGE ME] - Example: 'HKLM:\SOFTWARE\YourOrg\InstalledApps'
    )
    $snap = @{}
    foreach ($hive in $hives) {
        Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $snap[$_.PSPath] = $_
        }
    }
    return $snap
}

function Get-FilesystemSnapshot {
    $watchPaths = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LocalAppData,
        $env:AppData,
        'C:\ProgramData'
        # [CHANGE ME] - Example: 'D:\Applications'
    )
    $snap = @{}
    foreach ($root in $watchPaths) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $snap[$_.FullName] = $_.LastWriteTime
        }
    }
    return $snap
}

# ==============================================================================
# REGION: REPORT HELPERS
# ==============================================================================
function Write-ReportHeader {
    param([string]$Title)
    $line = '─' * 62
    Write-Host ""
    Write-Host "  ┌$line┐" -ForegroundColor Cyan
    Write-Host ("  │  {0,-60}│" -f $Title) -ForegroundColor Cyan
    Write-Host "  └$line┘" -ForegroundColor Cyan
}

function Write-ReportSection {
    param([string]$Label)
    Write-Host ""
    Write-Host "  ── $Label " -ForegroundColor DarkCyan -NoNewline
    Write-Host ('─' * ([Math]::Max(2, 58 - $Label.Length))) -ForegroundColor DarkGray
}

function Write-ReportItem {
    param([string]$Icon, [string]$Text, [ConsoleColor]$Color = 'White')
    Write-Host "    $Icon  $Text" -ForegroundColor $Color
}

function Write-ReportSubItem {
    param([string]$Text, [ConsoleColor]$Color = 'Gray')
    Write-Host "         $Text" -ForegroundColor $Color
}

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Show-Banner

# ── Step 1: Pick installer ────────────────────────────────────────────────────
Write-Host "  STEP 1 — Select your installer file" -ForegroundColor White
Write-Host "  A file picker window is opening..." -ForegroundColor DarkGray
Write-Host ""
$InstallerPath = Select-InstallerFile
$InstallerName = Split-Path $InstallerPath -Leaf
$ext           = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

Write-Host "  OK  Selected: $InstallerName" -ForegroundColor Green
Write-Host ""

# ── Step 2: Optional silent arguments ────────────────────────────────────────
Write-Host "  STEP 2 — Silent install arguments (optional)" -ForegroundColor White
Write-Host "  Common examples:  /VERYSILENT   /S   /quiet   /QN" -ForegroundColor DarkGray
Write-Host "  Press Enter to skip (installer GUI will appear)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Arguments > " -ForegroundColor White -NoNewline
$Arguments = (Read-Host).Trim()
Write-Host ""

# ── Step 3: Confirm ───────────────────────────────────────────────────────────
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
Write-Host "  │  READY TO INSTALL                                         │" -ForegroundColor DarkCyan
Write-Host "  │                                                            │" -ForegroundColor DarkCyan
Write-Host ("  │  File      : {0,-47}│" -f ($InstallerName -replace '(.{44}).+','$1...')) -ForegroundColor White
Write-Host ("  │  Arguments : {0,-47}│" -f $(if ($Arguments) { $Arguments } else { '(none — GUI mode)' })) -ForegroundColor White
Write-Host "  │  Watching  : Registry + Filesystem (always on)            │" -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
Read-Host | Out-Null

# ── Step 4: Init log ─────────────────────────────────────────────────────────
Write-Log "===== WATCH-INSTALL v1.4 STARTED ====="
Write-Log "Installer : $InstallerPath"
Write-Log "Arguments : $(if ($Arguments) { $Arguments } else { '(none)' })"
Write-Log "Log File  : $script:LogPath"

# ── Step 5: Pre-install snapshots ────────────────────────────────────────────
Write-Host ""
Write-Host "  Taking pre-install snapshots..." -ForegroundColor DarkGray
$regBefore = Get-RegistrySnapshot
$fsBefore  = Get-FilesystemSnapshot
Write-Log "Pre-snapshot: $($regBefore.Count) registry keys, $($fsBefore.Count) filesystem entries."

$StartTime = Get-Date

# ── Step 6: Build launch params ──────────────────────────────────────────────
$procParams = @{
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = "$env:TEMP\PKG_stdout.txt"
    RedirectStandardError  = "$env:TEMP\PKG_stderr.txt"
}

if ($ext -eq '.msi') {
    $procParams.FilePath = 'msiexec.exe'
    $msiArgs = "/i `"$InstallerPath`""
    if ($Arguments) { $msiArgs += " $Arguments" }
    $procParams.ArgumentList = $msiArgs
} else {
    $procParams.FilePath = $InstallerPath
    if ($Arguments) { $procParams.ArgumentList = $Arguments }
}

# ── Step 7: Launch installer ─────────────────────────────────────────────────
Write-Host "  Launching installer — waiting for it to finish..." -ForegroundColor Yellow
Write-Host "  (Complete the installation, then return here for your report)" -ForegroundColor DarkGray
Write-Log "Launching installer..."

try {
    $proc = Start-Process @procParams -ErrorAction Stop
}
catch {
    Write-Log "Redirected launch failed, falling back to direct launch." 'WARN'
    Write-Log "Reason: $_" 'WARN'
    $fallbackParams = @{ FilePath = $procParams.FilePath; Wait = $true; PassThru = $true }
    if ($procParams.ContainsKey('ArgumentList')) {
        $fallbackParams.ArgumentList = $procParams.ArgumentList
    }
    $proc = Start-Process @fallbackParams -ErrorAction Stop
}

$exitCode = $proc.ExitCode
Write-Log "Installer exited with code: $exitCode"

# Capture stdout/stderr if present
foreach ($stream in @('stdout', 'stderr')) {
    $sf = "$env:TEMP\PKG_$stream.txt"
    if (Test-Path $sf) {
        $sc = Get-Content $sf -Raw -ErrorAction SilentlyContinue
        if ($sc -and $sc.Trim()) { Write-Log "[$stream]: $($sc.Trim())" }
        Remove-Item $sf -Force -ErrorAction SilentlyContinue
    }
}

# ==============================================================================
# REGION: POST-INSTALL ANALYSIS
# ==============================================================================
Write-Host ""
Write-Host "  Analysing changes — please wait..." -ForegroundColor DarkGray

# ── Registry diff ─────────────────────────────────────────────────────────────
$regAfter   = Get-RegistrySnapshot
$newRegKeys = @($regAfter.Keys | Where-Object { -not $regBefore.ContainsKey($_) })

# ── Filesystem diff ───────────────────────────────────────────────────────────
$fsAfter    = Get-FilesystemSnapshot
$newFSRoots = @($fsAfter.Keys | Where-Object { -not $fsBefore.ContainsKey($_) })

# Files inside brand-new top-level dirs (full recursive list)
$newFiles = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $newFSRoots) {
    if (Test-Path $entry -PathType Container) {
        Get-ChildItem $entry -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $newFiles.Add($_.FullName) }
    } else {
        $newFiles.Add($entry)
    }
}

# Files modified inside pre-existing dirs (written after $StartTime)
$modifiedFiles = [System.Collections.Generic.List[string]]::new()
$touchedDirs   = @($fsAfter.Keys | Where-Object {
    $fsBefore.ContainsKey($_) -and $fsAfter[$_] -gt $StartTime
})
foreach ($dir in $touchedDirs) {
    if (Test-Path $dir -PathType Container) {
        Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $StartTime } |
            ForEach-Object { $modifiedFiles.Add($_.FullName) }
    }
}

# ==============================================================================
# REGION: FULL CONSOLE REPORT
# ==============================================================================
Show-Banner
Write-ReportHeader "INSTALLATION REPORT  —  $InstallerName"

# ── Exit code ─────────────────────────────────────────────────────────────────
Write-ReportSection "EXIT CODE"
$exitMeaning = switch ($exitCode) {
    0    { 'Success' }
    1    { 'General error' }
    2    { 'File not found or bad arguments' }
    3010 { 'Success — REBOOT REQUIRED' }
    1602 { 'User cancelled the installation' }
    1603 { 'Fatal MSI error — check MSI log' }
    1618 { 'Another MSI install already in progress' }
    1619 { 'Package could not be opened' }
    1624 { 'Error applying transforms' }
    1638 { 'Another version already installed' }
    1641 { 'Reboot initiated by installer' }
    # [CHANGE ME] - Add vendor-specific codes below as you encounter them.
    # Example: 5 { 'Vendor XYZ: License validation failed' }
    default { 'Unknown — consult installer documentation' }
}
$codeColor = if ($exitCode -in @(0, 3010, 1641)) { 'Green' } else { 'Red' }
Write-ReportItem '>' "Exit Code  : $exitCode" $codeColor
Write-ReportItem '>' "Meaning    : $exitMeaning" $codeColor

# ── Registry ──────────────────────────────────────────────────────────────────
Write-ReportSection "REGISTRY  —  NEW UNINSTALL KEYS  ($($newRegKeys.Count) found)"

if ($newRegKeys.Count -gt 0) {
    foreach ($key in $newRegKeys) {
        $kd         = $regAfter[$key]
        $dispName   = $kd.GetValue('DisplayName')
        $dispVer    = $kd.GetValue('DisplayVersion')
        $publisher  = $kd.GetValue('Publisher')
        $installDir = $kd.GetValue('InstallLocation')
        $uninstall  = $kd.GetValue('UninstallString')

        Write-ReportItem '[REG]' $key 'Green'
        if ($dispName)   { Write-ReportSubItem "DisplayName     : $dispName  <-- use as `"*$dispName*`" in detection scripts" 'Cyan' }
        if ($dispVer)    { Write-ReportSubItem "DisplayVersion  : $dispVer" 'White' }
        if ($publisher)  { Write-ReportSubItem "Publisher       : $publisher" 'Gray' }
        if ($installDir) { Write-ReportSubItem "InstallLocation : $installDir" 'Gray' }
        if ($uninstall)  { Write-ReportSubItem "UninstallString : $uninstall" 'DarkGray' }

        # All remaining values
        $kd.GetValueNames() | Where-Object {
            $_ -notin @('DisplayName','DisplayVersion','Publisher','InstallLocation','UninstallString','')
        } | ForEach-Object {
            Write-ReportSubItem "$_  =  $($kd.GetValue($_))" 'DarkGray'
        }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No new uninstall keys detected." 'Yellow'
    Write-ReportSubItem "App may not register in standard hives — use File detection in Intune." 'DarkYellow'
}

# ── New files ─────────────────────────────────────────────────────────────────
Write-ReportSection "FILES  —  NEW FILES IN NEW DIRECTORIES  ($($newFiles.Count) found)"

if ($newFiles.Count -gt 0) {
    $newFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[DIR]' $_.Name 'Green'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'White' }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No new top-level install directories detected." 'Yellow'
}

# ── Modified files ────────────────────────────────────────────────────────────
Write-ReportSection "FILES  —  MODIFIED FILES IN EXISTING DIRECTORIES  ($($modifiedFiles.Count) found)"

if ($modifiedFiles.Count -gt 0) {
    $modifiedFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[MOD]' $_.Name 'DarkCyan'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Gray' }
        Write-Host ""
    }
} else {
    Write-ReportItem 'o' "No modified files detected in existing directories." 'DarkGray'
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-ReportSection "SUMMARY"
Write-ReportItem '>' "Installer       : $InstallerName" 'White'
Write-ReportItem '>' "Arguments       : $(if ($Arguments) { $Arguments } else { '(none)' })" 'White'
Write-ReportItem '>' "Exit Code       : $exitCode  ($exitMeaning)" $codeColor
Write-ReportItem '>' "New Reg Keys    : $($newRegKeys.Count)" $(if ($newRegKeys.Count -gt 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "New Files       : $($newFiles.Count)" $(if ($newFiles.Count -gt 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Modified Files  : $($modifiedFiles.Count)" $(if ($modifiedFiles.Count -gt 0) { 'Cyan' } else { 'DarkGray' })
Write-ReportItem '>' "Log saved to    : $script:LogPath" 'DarkGray'

Write-Host ""

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan

# ── Save report prompt ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Save a copy of this report to a text file?" -ForegroundColor White
Write-Host "  [Y] Yes (default)   [N] No  — then press Enter" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Choice > " -ForegroundColor White -NoNewline
$saveChoice = (Read-Host).Trim()
if ([string]::IsNullOrEmpty($saveChoice)) { $saveChoice = 'Y' }

if ($saveChoice -match '^[Yy]') {

    # Build a clean default filename: AppName_YYYYMMDD_InstallReport.txt
    $safeName    = ($InstallerName -replace '\.[^.]+$', '') -replace '[\\/:*?"<>|]', '_'
    $dateStamp   = Get-Date -Format 'yyyyMMdd'
    $defaultName = "${safeName}_${dateStamp}_InstallReport.txt"

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $saveDialog                  = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Title            = "Save Installation Report"
    $saveDialog.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveDialog.DefaultExt       = "txt"
    $saveDialog.FileName         = $defaultName
    $saveDialog.InitialDirectory = "$env:USERPROFILE\Desktop"

    $owner         = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $dialogResult  = $saveDialog.ShowDialog($owner)
    $owner.Dispose()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $savePath    = $saveDialog.FileName
        $reportLines = [System.Collections.Generic.List[string]]::new()

        $reportLines.Add("WATCH-INSTALL v1.4 - INSTALLATION REPORT")
        $reportLines.Add("Generated  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $reportLines.Add("Installer  : $InstallerPath")
        $reportLines.Add("Arguments  : $(if ($Arguments) { $Arguments } else { '(none)' })")
        $reportLines.Add("Exit Code  : $exitCode  ($exitMeaning)")
        $reportLines.Add("IME Log    : $script:LogPath")
        $reportLines.Add("")
        $reportLines.Add(('-' * 64))

        # Registry
        $reportLines.Add("")
        $reportLines.Add("REGISTRY - NEW UNINSTALL KEYS  ($($newRegKeys.Count) found)")
        $reportLines.Add(('-' * 64))
        if ($newRegKeys.Count -gt 0) {
            foreach ($key in $newRegKeys) {
                $kd = $regAfter[$key]
                $reportLines.Add("  KEY : $key")
                $kd.GetValueNames() | ForEach-Object {
                    $reportLines.Add(("  {0,-22} = {1}" -f $_, $kd.GetValue($_)))
                }
                $reportLines.Add("")
            }
        } else {
            $reportLines.Add("  (none detected)")
            $reportLines.Add("")
        }

        # New files
        $reportLines.Add("FILES - NEW FILES IN NEW DIRECTORIES  ($($newFiles.Count) found)")
        $reportLines.Add(('-' * 64))
        if ($newFiles.Count -gt 0) {
            $newFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
                $reportLines.Add("  [DIR] $($_.Name)")
                $_.Group | ForEach-Object { $reportLines.Add("        $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else {
            $reportLines.Add("  (none detected)")
            $reportLines.Add("")
        }

        # Modified files
        $reportLines.Add("FILES - MODIFIED FILES IN EXISTING DIRECTORIES  ($($modifiedFiles.Count) found)")
        $reportLines.Add(('-' * 64))
        if ($modifiedFiles.Count -gt 0) {
            $modifiedFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
                $reportLines.Add("  [MOD] $($_.Name)")
                $_.Group | ForEach-Object { $reportLines.Add("        $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else {
            $reportLines.Add("  (none detected)")
            $reportLines.Add("")
        }

        # Summary
        $reportLines.Add("SUMMARY")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("  Installer       : $InstallerName")
        $reportLines.Add("  Arguments       : $(if ($Arguments) { $Arguments } else { '(none)' })")
        $reportLines.Add("  Exit Code       : $exitCode  ($exitMeaning)")
        $reportLines.Add("  New Reg Keys    : $($newRegKeys.Count)")
        $reportLines.Add("  New Files       : $($newFiles.Count)")
        $reportLines.Add("  Modified Files  : $($modifiedFiles.Count)")
        $reportLines.Add("  IME Log         : $script:LogPath")

        $reportLines | Set-Content -Path $savePath -Encoding UTF8 -ErrorAction Stop
        Write-Host ""
        Write-Host "  OK  Report saved to: $savePath" -ForegroundColor Green
        Write-Log "Report saved to: $savePath"
    } else {
        Write-Host ""
        Write-Host "  Save cancelled." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Press Enter to exit." -ForegroundColor DarkGray
Read-Host | Out-Null
