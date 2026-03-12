# ==============================================================================
# Watch-Suite.ps1
# Purpose  : All-in-one install / uninstall / compare workflow.
#            Runs all three Watch phases in a single session — only the initial
#            installer file picker is shown to the user. All subsequent phases
#            share data in memory; no re-reading of JSON between phases.
#
#            Phase 1 — INSTALL   : Snapshots system, runs installer, saves
#                                  Watch_Installer_<AppName>.json next to the
#                                  installer file.
#            Phase 2 — UNINSTALL : Detects uninstall method from Phase 1 data,
#                                  runs uninstaller, saves
#                                  Watch_Uninstaller_<AppName>.json in the same
#                                  folder.
#            Phase 3 — COMPARE   : Diffs installed vs removed sets, reports
#                                  leftover files and registry keys, prompts to
#                                  save a diff report as a text file.
#
# Usage    : Right-click -> "Run with PowerShell"  (self-elevates automatically)
#            OR: .\Watch-Suite.ps1
#
# Also use as standalones if needed:
#            Watch-Install.ps1, Watch-Uninstall.ps1, Compare-WatchReports.ps1
#
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.0
# Changelog:
#   1.0 - Initial release. Combines Watch-Install v1.6, Watch-Uninstall v1.1,
#         and Compare-WatchReports v1.0 into a single end-to-end workflow.
#         All three phases share data in memory — no JSON round-tripping between
#         phases. Also fixes the RegistryKeysAdded path extraction issue present
#         in Compare-WatchReports v1.0 where {Path,Values} objects were passed
#         directly to a HashSet instead of extracting .Path strings first.
# ==============================================================================

# ==============================================================================
# REGION: SELF-ELEVATION
# ==============================================================================
$currentUser      = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin          = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n  Not running as Administrator — relaunching elevated...`n" -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ==============================================================================
# REGION: LOGGING
# ==============================================================================
$script:LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_WatchSuite_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
# REGION: BANNER FUNCTIONS
# ==============================================================================
function Show-SuiteBanner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "  ║           WATCH-SUITE  v1.0  —  Intune Packager          ║" -ForegroundColor Yellow
    Write-Host "  ║     Install  →  Uninstall  →  Compare  in one session     ║" -ForegroundColor Yellow
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
}

function Show-PhaseHeader {
    param([string]$PhaseLabel, [string]$Title, [ConsoleColor]$Color = 'Cyan')
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor $Color
    $headerLine = "$PhaseLabel  —  $Title"
    Write-Host ("  ║  {0,-56}║" -f $headerLine) -ForegroundColor $Color
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor $Color
    Write-Host ""
}

# ==============================================================================
# REGION: REPORT HELPERS
# ==============================================================================
function Write-ReportHeader {
    param([string]$Title, [ConsoleColor]$Color = 'Cyan')
    $line = '─' * 62
    Write-Host ""
    Write-Host "  ┌$line┐" -ForegroundColor $Color
    Write-Host ("  │  {0,-60}│" -f $Title) -ForegroundColor $Color
    Write-Host "  └$line┘" -ForegroundColor $Color
}

function Write-ReportSection {
    param([string]$Label, [ConsoleColor]$Color = 'DarkCyan')
    Write-Host ""
    Write-Host "  ── $Label " -ForegroundColor $Color -NoNewline
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
# REGION: SNAPSHOT HELPERS
# ------------------------------------------------------------------------------
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
# REGION: FILE PICKERS
# ==============================================================================
function Select-InstallerFile {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = "Select Installer File"
    $dialog.Filter           = "Installers (*.exe;*.msi;*.msix;*.appx)|*.exe;*.msi;*.msix;*.appx|All Files (*.*)|*.*"
    $dialog.InitialDirectory = "$env:USERPROFILE\Downloads"
    $dialog.Multiselect      = $false
    $owner         = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $result        = $dialog.ShowDialog($owner)
    $owner.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host "`n  No file selected. Exiting.`n" -ForegroundColor Yellow
        exit 0
    }
    return $dialog.FileName
}

function Select-ExeFile {
    param([string]$InitialDir)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = "Select Uninstaller Executable"
    $dialog.Filter           = "Executables (*.exe;*.msi)|*.exe;*.msi|All Files (*.*)|*.*"
    $dialog.InitialDirectory = $InitialDir
    $dialog.Multiselect      = $false
    $owner         = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $result        = $dialog.ShowDialog($owner)
    $owner.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dialog.FileName
}

function Select-SaveFile {
    param([string]$Title, [string]$DefaultName, [string]$InitialDir)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg                  = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title            = $Title
    $dlg.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $dlg.DefaultExt       = "txt"
    $dlg.FileName         = $DefaultName
    $dlg.InitialDirectory = $InitialDir
    $owner         = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $result        = $dlg.ShowDialog($owner)
    $owner.Dispose()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    return $dlg.FileName
}

# ==============================================================================
# ==============================================================================
# PHASE 1: INSTALL
# ==============================================================================
# ==============================================================================
Show-SuiteBanner
Write-Host "  This script runs all three Watch phases in sequence:" -ForegroundColor White
Write-Host "    Phase 1  Install    — run the installer and record what changes" -ForegroundColor DarkGray
Write-Host "    Phase 2  Uninstall  — run the uninstaller and record what it cleans" -ForegroundColor DarkGray
Write-Host "    Phase 3  Compare    — diff install vs uninstall, report leftovers" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  You will only be asked for one file: the installer." -ForegroundColor Yellow
Write-Host ""
Write-Host "  Press Enter to begin  |  Ctrl+C to cancel" -ForegroundColor DarkGray
Read-Host | Out-Null

Show-PhaseHeader "PHASE 1 of 3" "INSTALL" 'Cyan'

# ── Select installer ──────────────────────────────────────────────────────────
Write-Host "  Select your installer — a file picker is opening..." -ForegroundColor White
Write-Host ""
$InstallerPath = Select-InstallerFile
$InstallerName = Split-Path $InstallerPath -Leaf
$InstallerDir  = Split-Path $InstallerPath -Parent
$ext           = [System.IO.Path]::GetExtension($InstallerPath).ToLower()
Write-Host "  OK  Selected: $InstallerName" -ForegroundColor Green
Write-Host ""

# ── Optional silent install arguments ────────────────────────────────────────
Write-Host "  Silent install arguments (optional)" -ForegroundColor White
Write-Host "  Common examples:  /VERYSILENT   /S   /quiet   /QN" -ForegroundColor DarkGray
Write-Host "  Press Enter to skip (installer GUI will appear)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Arguments > " -ForegroundColor White -NoNewline
$InstallArguments = (Read-Host).Trim()
Write-Host ""

# ── Confirm ───────────────────────────────────────────────────────────────────
$p1_file  = 'File      : ' + ($InstallerName -replace '(.{41}).+', '$1...')
$p1_args  = 'Arguments : ' + $(if ($InstallArguments) { $InstallArguments } else { '(none - GUI mode)' })
$p1_watch = 'Watching  : Registry + Filesystem (always on)'
Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkCyan
Write-Host ("  │  {0,-56}│" -f 'READY TO INSTALL')  -ForegroundColor DarkCyan
Write-Host ("  │  {0,-56}│" -f '')                  -ForegroundColor DarkCyan
Write-Host ("  │  {0,-56}│" -f $p1_file)            -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $p1_args)            -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $p1_watch)           -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
Read-Host | Out-Null

# ── Init log ──────────────────────────────────────────────────────────────────
Write-Log "===== WATCH-SUITE v1.0 STARTED ====="
Write-Log "===== PHASE 1: INSTALL ====="
Write-Log "Installer : $InstallerPath"
Write-Log "Arguments : $(if ($InstallArguments) { $InstallArguments } else { '(none)' })"
Write-Log "Suite Log : $script:LogPath"

# ── Pre-install snapshots ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Taking pre-install snapshots..." -ForegroundColor DarkGray
$regBefore       = Get-RegistrySnapshot
$fsBefore        = Get-FilesystemSnapshot
$InstallStartTime = Get-Date
Write-Log "Pre-snapshot: $($regBefore.Count) reg keys, $($fsBefore.Count) fs entries."

# ── Launch installer ──────────────────────────────────────────────────────────
$p1_proc = @{
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = "$env:TEMP\PKG_suite_stdout.txt"
    RedirectStandardError  = "$env:TEMP\PKG_suite_stderr.txt"
}
if ($ext -eq '.msi') {
    $p1_proc.FilePath = 'msiexec.exe'
    $msiInstallArgs  = "/i `"$InstallerPath`""
    if ($InstallArguments) { $msiInstallArgs += " $InstallArguments" }
    $p1_proc.ArgumentList = $msiInstallArgs
} else {
    $p1_proc.FilePath = $InstallerPath
    if ($InstallArguments) { $p1_proc.ArgumentList = $InstallArguments }
}

Write-Host "  Launching installer — waiting for it to finish..." -ForegroundColor Yellow
Write-Host "  (Complete the installation, then return here)" -ForegroundColor DarkGray
Write-Log "Launching installer..."
try {
    $p1_result = Start-Process @p1_proc -ErrorAction Stop
} catch {
    Write-Log "Redirected launch failed, retrying direct." 'WARN'
    $p1_fallback = @{ FilePath = $p1_proc.FilePath; Wait = $true; PassThru = $true }
    if ($p1_proc.ContainsKey('ArgumentList')) { $p1_fallback.ArgumentList = $p1_proc.ArgumentList }
    $p1_result = Start-Process @p1_fallback -ErrorAction Stop
}
$installExitCode = $p1_result.ExitCode
Write-Log "Installer exit code: $installExitCode"

foreach ($stream in @('suite_stdout', 'suite_stderr')) {
    $sf = "$env:TEMP\PKG_$stream.txt"
    if (Test-Path $sf) {
        $sc = Get-Content $sf -Raw -ErrorAction SilentlyContinue
        if ($sc -and $sc.Trim()) { Write-Log "[$stream]: $($sc.Trim())" }
        Remove-Item $sf -Force -ErrorAction SilentlyContinue
    }
}

# ── Post-install analysis ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Analysing changes..." -ForegroundColor DarkGray

$regAfter   = Get-RegistrySnapshot
$newRegKeys = @($regAfter.Keys | Where-Object { -not $regBefore.ContainsKey($_) })

$fsAfter    = Get-FilesystemSnapshot
$newFSRoots = @($fsAfter.Keys | Where-Object { -not $fsBefore.ContainsKey($_) })

$newFiles = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $newFSRoots) {
    if (Test-Path $entry -PathType Container) {
        Get-ChildItem $entry -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $newFiles.Add($_.FullName) }
    } else {
        $newFiles.Add($entry)
    }
}

$modifiedFiles = [System.Collections.Generic.List[string]]::new()
$touchedDirs   = @($fsAfter.Keys | Where-Object {
    $fsBefore.ContainsKey($_) -and $fsAfter[$_] -gt $InstallStartTime
})
foreach ($dir in $touchedDirs) {
    if (Test-Path $dir -PathType Container) {
        Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $InstallStartTime } |
            ForEach-Object { $modifiedFiles.Add($_.FullName) }
    }
}

# ── Exit code lookup ──────────────────────────────────────────────────────────
$installExitMeaning = switch ($installExitCode) {
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
    default { 'Unknown — consult installer documentation' }
}
$installCodeColor = if ($installExitCode -in @(0, 3010, 1641)) { 'Green' } else { 'Red' }

# ── Derive app identity ───────────────────────────────────────────────────────
$appDisplayName = $null
$appVersion     = $null
$appPublisher   = $null

if ($newRegKeys.Count -gt 0) {
    $firstKey       = $newRegKeys | Select-Object -First 1
    $appDisplayName = $regAfter[$firstKey].GetValue('DisplayName')
    $appVersion     = $regAfter[$firstKey].GetValue('DisplayVersion')
    $appPublisher   = $regAfter[$firstKey].GetValue('Publisher')
}
if (-not $appDisplayName) {
    $appDisplayName = $InstallerName -replace '\.[^.]+$', ''
}

$safeAppName     = ($appDisplayName -replace '[^a-zA-Z0-9]+', '_').Trim('_')
$installJsonPath = Join-Path $InstallerDir "Watch_Installer_${safeAppName}.json"

# ── Build registry key objects (used in Phase 3 for value lookup) ─────────────
$regKeyObjects = [System.Collections.Generic.List[object]]::new()
foreach ($key in $newRegKeys) {
    $kd   = $regAfter[$key]
    $vals = [ordered]@{}
    foreach ($valName in $kd.GetValueNames()) {
        $vals[$valName] = "$($kd.GetValue($valName))"
    }
    $regKeyObjects.Add([PSCustomObject]@{ Path = $key; Values = $vals })
}

# Build quick lookup dict (path -> values) for Phase 3 compare display
$regKeyLookup = @{}
foreach ($obj in $regKeyObjects) { $regKeyLookup[$obj.Path] = $obj.Values }

# ── Build AppInfo object ──────────────────────────────────────────────────────
$appInfoObj = [PSCustomObject]@{
    DisplayName     = ''
    DisplayVersion  = ''
    Publisher       = ''
    InstallLocation = ''
    UninstallString = ''
}
if ($newRegKeys.Count -gt 0) {
    $kd0 = $regAfter[$newRegKeys[0]]
    $appInfoObj = [PSCustomObject]@{
        DisplayName     = "$($kd0.GetValue('DisplayName'))"
        DisplayVersion  = "$($kd0.GetValue('DisplayVersion'))"
        Publisher       = "$($kd0.GetValue('Publisher'))"
        InstallLocation = "$($kd0.GetValue('InstallLocation'))"
        UninstallString = "$($kd0.GetValue('UninstallString'))"
    }
}

# ── Save Watch_Installer JSON ─────────────────────────────────────────────────
$installJsonData = [PSCustomObject]@{
    Type        = 'Install'
    GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Meta        = [PSCustomObject]@{
        ScriptVersion = '1.0'
        InstallerPath = $InstallerPath
        InstallerName = $InstallerName
        AppName       = $safeAppName
        Arguments     = $InstallArguments
        ExitCode      = $installExitCode
        ExitMeaning   = $installExitMeaning
        IMELog        = $script:LogPath
    }
    AppInfo           = $appInfoObj
    RegistryKeysAdded = @($regKeyObjects)
    NewFiles          = @($newFiles)
    ModifiedFiles     = @($modifiedFiles)
}

try {
    $installJsonData | ConvertTo-Json -Depth 10 |
        Set-Content -Path $installJsonPath -Encoding UTF8 -ErrorAction Stop
    Write-Log "Watch_Installer JSON saved: $installJsonPath"
} catch {
    Write-Log "Watch_Installer JSON save failed: $_" 'ERROR'
}

# ── Phase 1 console report ────────────────────────────────────────────────────
Write-ReportHeader "PHASE 1: INSTALL REPORT  —  $InstallerName" 'Cyan'

Write-ReportSection "EXIT CODE" 'DarkCyan'
Write-ReportItem '>' "Exit Code  : $installExitCode" $installCodeColor
Write-ReportItem '>' "Meaning    : $installExitMeaning" $installCodeColor

Write-ReportSection "REGISTRY  —  NEW UNINSTALL KEYS  ($($newRegKeys.Count) found)" 'DarkCyan'
if ($newRegKeys.Count -gt 0) {
    foreach ($key in $newRegKeys) {
        $kd = $regAfter[$key]
        Write-ReportItem '[REG]' $key 'Green'
        $dn = $kd.GetValue('DisplayName')
        $dv = $kd.GetValue('DisplayVersion')
        $pb = $kd.GetValue('Publisher')
        $il = $kd.GetValue('InstallLocation')
        $us = $kd.GetValue('UninstallString')
        if ($dn) { Write-ReportSubItem "DisplayName     : $dn  <-- use as `"*$dn*`" in detection" 'Cyan' }
        if ($dv) { Write-ReportSubItem "DisplayVersion  : $dv" 'White' }
        if ($pb) { Write-ReportSubItem "Publisher       : $pb" 'Gray' }
        if ($il) { Write-ReportSubItem "InstallLocation : $il" 'Gray' }
        if ($us) { Write-ReportSubItem "UninstallString : $us" 'DarkGray' }
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

Write-ReportSection "FILES  —  NEW FILES IN NEW DIRECTORIES  ($($newFiles.Count) found)" 'DarkCyan'
if ($newFiles.Count -gt 0) {
    $newFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[DIR]' $_.Name 'Green'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'White' }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No new top-level install directories detected." 'Yellow'
}

Write-ReportSection "FILES  —  MODIFIED FILES IN EXISTING DIRECTORIES  ($($modifiedFiles.Count) found)" 'DarkCyan'
if ($modifiedFiles.Count -gt 0) {
    $modifiedFiles | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[MOD]' $_.Name 'DarkCyan'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Gray' }
        Write-Host ""
    }
} else {
    Write-ReportItem 'o' "No modified files detected in existing directories." 'DarkGray'
}

Write-ReportSection "INSTALL SUMMARY" 'DarkCyan'
Write-ReportItem '>' "App Name        : $appDisplayName" 'White'
Write-ReportItem '>' "Version         : $(if ($appVersion) { $appVersion } else { '(not detected)' })" 'White'
Write-ReportItem '>' "Exit Code       : $installExitCode  ($installExitMeaning)" $installCodeColor
Write-ReportItem '>' "New Reg Keys    : $($newRegKeys.Count)" $(if ($newRegKeys.Count -gt 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "New Files       : $($newFiles.Count)" $(if ($newFiles.Count -gt 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Modified Files  : $($modifiedFiles.Count)" $(if ($modifiedFiles.Count -gt 0) { 'Cyan' } else { 'DarkGray' })
Write-ReportItem '>' "Install JSON    : $installJsonPath" 'DarkGray'
Write-ReportItem '>' "Log File        : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan
Write-Host ""
Write-Host "  Phase 1 complete." -ForegroundColor Green
Write-Host "  Moving to Phase 2: Uninstall  —  press Enter to continue  |  Ctrl+C to stop" -ForegroundColor DarkGray
Read-Host | Out-Null

# ==============================================================================
# ==============================================================================
# PHASE 2: UNINSTALL
# ==============================================================================
# ==============================================================================
Show-PhaseHeader "PHASE 2 of 3" "UNINSTALL" 'Magenta'
Write-Log "===== PHASE 2: UNINSTALL ====="

Write-Host "  App detected from Phase 1  : $appDisplayName  $appVersion" -ForegroundColor White
Write-Host "  Files to verify  : $($newFiles.Count)" -ForegroundColor DarkGray
Write-Host "  Registry keys    : $($newRegKeys.Count)" -ForegroundColor DarkGray
Write-Host ""

# ── Determine uninstall method ────────────────────────────────────────────────
$uninstallString = $appInfoObj.UninstallString

# Fallback: scan RegistryKeysAdded values if AppInfo is empty
if (-not $uninstallString -and $regKeyObjects.Count -gt 0) {
    foreach ($regEntry in $regKeyObjects) {
        $candidate = $regEntry.Values['UninstallString']
        if ($candidate) { $uninstallString = $candidate; break }
    }
}

$UninstallerPath    = $null
$UninstallArguments = ''

if ($uninstallString) {
    Write-Host "  Detected UninstallString:" -ForegroundColor DarkGray
    Write-Host "  $uninstallString" -ForegroundColor White
    Write-Host ""
    Write-Host "  [U] Use detected string — same as Add/Remove Programs (default)" -ForegroundColor DarkGray
    Write-Host "  [B] Browse for a different uninstaller exe" -ForegroundColor DarkGray
    Write-Host "  [M] Type path manually" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Choice > " -ForegroundColor White -NoNewline
    $methodChoice = (Read-Host).Trim()
    if ([string]::IsNullOrEmpty($methodChoice)) { $methodChoice = 'U' }
} else {
    Write-Host "  No UninstallString found in Phase 1 data." -ForegroundColor Yellow
    Write-Host "  [B] Browse for uninstaller (default)   [M] Manual entry" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Choice > " -ForegroundColor White -NoNewline
    $methodChoice = (Read-Host).Trim()
    if ([string]::IsNullOrEmpty($methodChoice)) { $methodChoice = 'B' }
}

if ($methodChoice -match '^[Uu]' -and $uninstallString) {
    if ($uninstallString -match '^"([^"]+)"\s*(.*)$') {
        $UninstallerPath    = $Matches[1]
        $UninstallArguments = $Matches[2].Trim()
    } elseif ($uninstallString -match '^(\S+\.exe)\s*(.*)$') {
        $UninstallerPath    = $Matches[1]
        $UninstallArguments = $Matches[2].Trim()
    } else {
        $UninstallerPath = $uninstallString
    }
    Write-Host "  OK  Using: $UninstallerPath" -ForegroundColor Green
    if ($UninstallArguments) { Write-Host "      Args : $UninstallArguments" -ForegroundColor DarkGray }
    Write-Host "      (Equivalent to clicking Uninstall in Add/Remove Programs)" -ForegroundColor DarkGray

} elseif ($methodChoice -match '^[Bb]') {
    $browseStart     = if ($newFiles.Count -gt 0) { Split-Path $newFiles[0] -Parent } else { $env:ProgramFiles }
    $UninstallerPath = Select-ExeFile -InitialDir $browseStart
    if (-not $UninstallerPath) {
        Write-Host "  No file selected. Exiting." -ForegroundColor Yellow
        exit 0
    }
    Write-Host "  OK  Selected: $UninstallerPath" -ForegroundColor Green

} else {
    Write-Host "  Enter full path to uninstaller > " -ForegroundColor White -NoNewline
    $UninstallerPath = (Read-Host).Trim()
    if (-not $UninstallerPath -or -not (Test-Path $UninstallerPath)) {
        Write-Host "  Path not found or empty. Exiting." -ForegroundColor Red
        exit 1
    }
}

$uninstallerName = Split-Path $UninstallerPath -Leaf
Write-Host ""

# ── Optional extra arguments ──────────────────────────────────────────────────
Write-Host "  Additional uninstall arguments (optional)" -ForegroundColor White
Write-Host "  Current: $(if ($UninstallArguments) { $UninstallArguments } else { '(none)' })" -ForegroundColor DarkGray
Write-Host "  Add more args, or press Enter to keep as-is" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Extra args > " -ForegroundColor White -NoNewline
$extraArgs = (Read-Host).Trim()
if ($extraArgs) { $UninstallArguments = "$UninstallArguments $extraArgs".Trim() }
Write-Host ""

# ── Confirm ───────────────────────────────────────────────────────────────────
$p2_app    = 'App        : ' + ($appDisplayName -replace '(.{40}).+', '$1...')
$p2_uninst = 'Uninstaller: ' + ($uninstallerName -replace '(.{40}).+', '$1...')
$p2_args   = 'Arguments  : ' + $(if ($UninstallArguments) { $UninstallArguments } else { '(none - GUI mode)' })
$p2_track  = 'Tracking   : ' + "$($newFiles.Count) files, $($newRegKeys.Count) reg keys"

Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f 'READY TO UNINSTALL')  -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f '')                    -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f $p2_app)               -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $p2_uninst)            -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $p2_args)              -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $p2_track)             -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkMagenta
Write-Host ""
Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
Read-Host | Out-Null

Write-Log "App         : $appDisplayName $appVersion"
Write-Log "Uninstaller : $UninstallerPath"
Write-Log "Arguments   : $(if ($UninstallArguments) { $UninstallArguments } else { '(none)' })"
Write-Log "Tracking    : $($newFiles.Count) files, $($newRegKeys.Count) registry keys"

# ── Pre-uninstall existence check ─────────────────────────────────────────────
Write-Host ""
Write-Host "  Taking pre-uninstall existence snapshot..." -ForegroundColor DarkGray

$filesExistBefore   = [System.Collections.Generic.List[string]]::new()
$filesMissingBefore = [System.Collections.Generic.List[string]]::new()
foreach ($f in $newFiles) {
    if (Test-Path $f -ErrorAction SilentlyContinue) { $filesExistBefore.Add($f) }
    else                                             { $filesMissingBefore.Add($f) }
}

$regExistBefore   = [System.Collections.Generic.List[string]]::new()
$regMissingBefore = [System.Collections.Generic.List[string]]::new()
foreach ($key in $newRegKeys) {
    if (Test-Path $key -ErrorAction SilentlyContinue) { $regExistBefore.Add($key) }
    else                                               { $regMissingBefore.Add($key) }
}

Write-Log "Pre-check: $($filesExistBefore.Count)/$($newFiles.Count) files present, $($regExistBefore.Count)/$($newRegKeys.Count) reg keys present"
if ($filesMissingBefore.Count -gt 0) {
    Write-Host "  NOTE: $($filesMissingBefore.Count) tracked file(s) already missing before uninstall." -ForegroundColor Yellow
}

# ── Launch uninstaller ────────────────────────────────────────────────────────
$uninstExt = [System.IO.Path]::GetExtension($UninstallerPath).ToLower()

$p2_proc = @{
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = "$env:TEMP\PKG_suite_uninst_stdout.txt"
    RedirectStandardError  = "$env:TEMP\PKG_suite_uninst_stderr.txt"
}
if ($uninstExt -eq '.msi') {
    $p2_proc.FilePath = 'msiexec.exe'
    $msiUninstArgs   = "/x `"$UninstallerPath`""
    if ($UninstallArguments) { $msiUninstArgs += " $UninstallArguments" }
    $p2_proc.ArgumentList = $msiUninstArgs
} else {
    $p2_proc.FilePath = $UninstallerPath
    if ($UninstallArguments) { $p2_proc.ArgumentList = $UninstallArguments }
}

Write-Host "  Launching uninstaller — waiting for it to finish..." -ForegroundColor Yellow
Write-Host "  (Complete the uninstallation, then return here)" -ForegroundColor DarkGray
Write-Log "Launching uninstaller..."
try {
    $p2_result = Start-Process @p2_proc -ErrorAction Stop
} catch {
    Write-Log "Redirected launch failed, retrying direct." 'WARN'
    $p2_fallback = @{ FilePath = $p2_proc.FilePath; Wait = $true; PassThru = $true }
    if ($p2_proc.ContainsKey('ArgumentList')) { $p2_fallback.ArgumentList = $p2_proc.ArgumentList }
    $p2_result = Start-Process @p2_fallback -ErrorAction Stop
}
$uninstallExitCode = $p2_result.ExitCode
Write-Log "Uninstaller exit code: $uninstallExitCode"

foreach ($stream in @('suite_uninst_stdout', 'suite_uninst_stderr')) {
    $sf = "$env:TEMP\PKG_$stream.txt"
    if (Test-Path $sf) {
        $sc = Get-Content $sf -Raw -ErrorAction SilentlyContinue
        if ($sc -and $sc.Trim()) { Write-Log "[$stream]: $($sc.Trim())" }
        Remove-Item $sf -Force -ErrorAction SilentlyContinue
    }
}

# ── Post-uninstall analysis ───────────────────────────────────────────────────
Write-Host ""
Write-Host "  Analysing what was removed vs what remains..." -ForegroundColor DarkGray

$filesRemoved   = [System.Collections.Generic.List[string]]::new()
$filesRemaining = [System.Collections.Generic.List[string]]::new()
foreach ($f in $filesExistBefore) {
    if (Test-Path $f -ErrorAction SilentlyContinue) { $filesRemaining.Add($f) }
    else                                             { $filesRemoved.Add($f) }
}

$regRemoved   = [System.Collections.Generic.List[string]]::new()
$regRemaining = [System.Collections.Generic.List[string]]::new()
foreach ($key in $regExistBefore) {
    if (Test-Path $key -ErrorAction SilentlyContinue) { $regRemaining.Add($key) }
    else                                               { $regRemoved.Add($key) }
}

Write-Log "Files removed: $($filesRemoved.Count)  |  Files remaining: $($filesRemaining.Count)"
Write-Log "Reg removed: $($regRemoved.Count)  |  Reg remaining: $($regRemaining.Count)"

# ── Exit code lookup ──────────────────────────────────────────────────────────
$uninstallExitMeaning = switch ($uninstallExitCode) {
    0    { 'Success' }
    1    { 'General error' }
    2    { 'File not found or bad arguments' }
    3010 { 'Success — REBOOT REQUIRED' }
    1602 { 'User cancelled the uninstallation' }
    1603 { 'Fatal MSI error' }
    1605 { 'App not currently installed (MSI)' }
    1614 { 'Product uninstalled' }
    1641 { 'Reboot initiated by uninstaller' }
    # [CHANGE ME] - Add vendor-specific codes below as you encounter them.
    default { 'Unknown — consult uninstaller documentation' }
}
$uninstallCodeColor = if ($uninstallExitCode -in @(0, 3010, 1614, 1641)) { 'Green' } else { 'Red' }

# ── Save Watch_Uninstaller JSON ───────────────────────────────────────────────
$uninstallJsonPath = Join-Path $InstallerDir "Watch_Uninstaller_${safeAppName}.json"

$uninstallJsonData = [ordered]@{
    Type                        = 'Uninstall'
    GeneratedAt                 = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Meta = [ordered]@{
        ScriptVersion           = '1.0'
        AppName                 = $safeAppName
        UninstallerPath         = $UninstallerPath
        UninstallerFile         = $uninstallerName
        Arguments               = $UninstallArguments
        ExitCode                = $uninstallExitCode
        ExitMeaning             = $uninstallExitMeaning
        IMELog                  = $script:LogPath
        InstallerJsonPath       = $installJsonPath
    }
    AppInfo = [ordered]@{
        DisplayName             = $appDisplayName
        DisplayVersion          = $appVersion
    }
    FilesTrackedFromInstaller   = $newFiles.Count
    FilesRemoved                = @($filesRemoved)
    FilesRemaining              = @($filesRemaining)
    FilesMissingBeforeUninstall = @($filesMissingBefore)
    RegistryKeysTracked         = $newRegKeys.Count
    RegistryKeysRemoved         = @($regRemoved)
    RegistryKeysRemaining       = @($regRemaining)
}

try {
    $uninstallJsonData | ConvertTo-Json -Depth 10 |
        Set-Content -Path $uninstallJsonPath -Encoding UTF8 -ErrorAction Stop
    Write-Log "Watch_Uninstaller JSON saved: $uninstallJsonPath"
} catch {
    Write-Log "Watch_Uninstaller JSON save failed: $_" 'WARN'
}

# ── Phase 2 console report ────────────────────────────────────────────────────
Write-ReportHeader "PHASE 2: UNINSTALL REPORT  —  $appDisplayName $appVersion" 'Magenta'

Write-ReportSection "EXIT CODE" 'DarkMagenta'
Write-ReportItem '>' "Exit Code  : $uninstallExitCode" $uninstallCodeColor
Write-ReportItem '>' "Meaning    : $uninstallExitMeaning" $uninstallCodeColor

Write-ReportSection "REGISTRY  —  REMOVED  ($($regRemoved.Count) of $($regExistBefore.Count))" 'DarkMagenta'
if ($regRemoved.Count -gt 0) {
    foreach ($key in $regRemoved) { Write-ReportItem '[REM]' $key 'Green' }
} else {
    Write-ReportItem '!' "No registry keys were removed." 'Yellow'
}

Write-ReportSection "REGISTRY  —  REMAINING / NOT CLEANED UP  ($($regRemaining.Count))" 'DarkMagenta'
if ($regRemaining.Count -gt 0) {
    foreach ($key in $regRemaining) { Write-ReportItem '[LEFT]' $key 'Red' }
    Write-Host ""
    Write-ReportSubItem "These keys were installed but NOT removed by the uninstaller." 'Yellow'
} else {
    Write-ReportItem 'OK' "All tracked registry keys were removed." 'Green'
}

Write-ReportSection "FILES  —  REMOVED  ($($filesRemoved.Count) of $($filesExistBefore.Count))" 'DarkMagenta'
if ($filesRemoved.Count -gt 0) {
    $filesRemoved | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[REM]' $_.Name 'Green'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Gray' }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No tracked files were removed." 'Yellow'
}

Write-ReportSection "FILES  —  REMAINING / NOT CLEANED UP  ($($filesRemaining.Count))" 'DarkMagenta'
if ($filesRemaining.Count -gt 0) {
    $filesRemaining | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[LEFT]' $_.Name 'Red'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Yellow' }
        Write-Host ""
    }
    Write-ReportSubItem "These files were installed but NOT removed by the uninstaller." 'Yellow'
} else {
    Write-ReportItem 'OK' "All tracked files were removed. Clean uninstall." 'Green'
}

Write-ReportSection "UNINSTALL SUMMARY" 'DarkMagenta'
Write-ReportItem '>' "App             : $appDisplayName $appVersion" 'White'
Write-ReportItem '>' "Uninstaller     : $uninstallerName" 'White'
Write-ReportItem '>' "Exit Code       : $uninstallExitCode  ($uninstallExitMeaning)" $uninstallCodeColor
Write-ReportItem '>' "Files Removed   : $($filesRemoved.Count) / $($filesExistBefore.Count)" $(if ($filesRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Files Remaining : $($filesRemaining.Count)" $(if ($filesRemaining.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Reg Removed     : $($regRemoved.Count) / $($regExistBefore.Count)" $(if ($regRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Reg Remaining   : $($regRemaining.Count)" $(if ($regRemaining.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Uninstall JSON  : $uninstallJsonPath" 'DarkGray'
Write-ReportItem '>' "Log File        : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkMagenta
Write-Host ""
Write-Host "  Phase 2 complete." -ForegroundColor Green
Write-Host "  Moving to Phase 3: Compare  —  press Enter to continue  |  Ctrl+C to stop" -ForegroundColor DarkGray
Read-Host | Out-Null

# ==============================================================================
# ==============================================================================
# PHASE 3: COMPARE
# ==============================================================================
# ==============================================================================
Show-PhaseHeader "PHASE 3 of 3" "COMPARE" 'Cyan'
Write-Log "===== PHASE 3: COMPARE ====="

Write-Host "  Running diff on in-memory Phase 1 / Phase 2 data..." -ForegroundColor DarkGray
Write-Host ""

# ── Build comparison sets ─────────────────────────────────────────────────────
# Installed files: everything Watch-Install recorded in $newFiles
$installedFilesSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($newFiles),
    [System.StringComparer]::OrdinalIgnoreCase
)
# Removed files: what Watch-Uninstall confirmed gone
$removedFilesSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($filesRemoved),
    [System.StringComparer]::OrdinalIgnoreCase
)
# Installed registry keys: path strings from $newRegKeys
# FIX: use $newRegKeys (already strings) — avoids the {Path,Values} object bug
# in the standalone Compare-WatchReports v1.0 where RegistryKeysAdded objects
# were passed directly to HashSet without extracting .Path first.
$installedRegSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($newRegKeys),
    [System.StringComparer]::OrdinalIgnoreCase
)
# Removed registry keys
$removedRegSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($regRemoved),
    [System.StringComparer]::OrdinalIgnoreCase
)

# ── Compute leftovers ─────────────────────────────────────────────────────────
$leftoverFiles = [System.Collections.Generic.List[string]]::new()
foreach ($f in $installedFilesSet) {
    if (-not $removedFilesSet.Contains($f)) { $leftoverFiles.Add($f) }
}
$leftoverFiles = @($leftoverFiles | Sort-Object)

$leftoverReg = [System.Collections.Generic.List[string]]::new()
foreach ($k in $installedRegSet) {
    if (-not $removedRegSet.Contains($k)) { $leftoverReg.Add($k) }
}
$leftoverReg = @($leftoverReg | Sort-Object)

# ── Verify against current disk ───────────────────────────────────────────────
$leftoverFilesOnDisk = @($leftoverFiles | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })
$leftoverFilesGone   = @($leftoverFiles | Where-Object { -not (Test-Path $_ -ErrorAction SilentlyContinue) })
$leftoverRegOnDisk   = @($leftoverReg   | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })
$leftoverRegGone     = @($leftoverReg   | Where-Object { -not (Test-Path $_ -ErrorAction SilentlyContinue) })

$totalProblems = $leftoverFilesOnDisk.Count + $leftoverRegOnDisk.Count

Write-Log "Installed files : $($installedFilesSet.Count)  |  Removed: $($removedFilesSet.Count)  |  Leftover (not removed): $($leftoverFiles.Count)"
Write-Log "Leftover files still on disk: $($leftoverFilesOnDisk.Count)"
Write-Log "Installed keys  : $($installedRegSet.Count)  |  Removed: $($removedRegSet.Count)  |  Leftover: $($leftoverReg.Count)"
Write-Log "Leftover keys still on disk : $($leftoverRegOnDisk.Count)"
Write-Log "Total problems (disk-verified) : $totalProblems"

# ── Phase 3 console report ────────────────────────────────────────────────────
Write-ReportHeader "PHASE 3: COMPARE REPORT  —  $appDisplayName $appVersion" 'Cyan'

# Verdict
Write-ReportSection "VERDICT" 'DarkCyan'
if ($totalProblems -eq 0) {
    Write-ReportItem 'OK' "CLEAN UNINSTALL — No installed files or registry keys remain on disk." 'Green'
} elseif ($totalProblems -lt 10) {
    Write-ReportItem '!' "MINOR LEFTOVERS — $totalProblems item(s) remain on disk that were not removed." 'Yellow'
} else {
    Write-ReportItem 'X' "DIRTY UNINSTALL — $totalProblems items remain on disk. Uninstaller is incomplete." 'Red'
}

# Stats
Write-ReportSection "COMPARISON STATS" 'DarkCyan'
Write-ReportItem '>' "Files installed           : $($installedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files removed             : $($removedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files not in remove list  : $($leftoverFiles.Count)" $(if ($leftoverFiles.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-ReportItem '>' "  Still on disk (PROBLEM) : $($leftoverFilesOnDisk.Count)" $(if ($leftoverFilesOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "  Already gone (OK)       : $($leftoverFilesGone.Count)" 'DarkGray'
Write-Host ""
Write-ReportItem '>' "Reg keys installed        : $($installedRegSet.Count)" 'White'
Write-ReportItem '>' "Reg keys removed          : $($removedRegSet.Count)" 'White'
Write-ReportItem '>' "Reg keys not removed      : $($leftoverReg.Count)" $(if ($leftoverReg.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-ReportItem '>' "  Still on disk (PROBLEM) : $($leftoverRegOnDisk.Count)" $(if ($leftoverRegOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "  Already gone (OK)       : $($leftoverRegGone.Count)" 'DarkGray'

# Leftover files on disk
Write-ReportSection "LEFTOVER FILES STILL ON DISK  ($($leftoverFilesOnDisk.Count))" 'Red'
if ($leftoverFilesOnDisk.Count -gt 0) {
    $leftoverFilesOnDisk | Group-Object -Property { Split-Path $_ -Parent } | Sort-Object Name | ForEach-Object {
        Write-ReportItem '[LEFT]' $_.Name 'Red'
        $_.Group | Sort-Object | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Yellow' }
        Write-Host ""
    }
} else {
    Write-ReportItem 'OK' "No leftover files found on disk." 'Green'
}

# Files not in remove list but already gone
if ($leftoverFilesGone.Count -gt 0) {
    Write-ReportSection "FILES NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverFilesGone.Count))" 'DarkGray'
    Write-ReportSubItem "Installed but neither explicitly removed nor present on disk." 'DarkGray'
    Write-ReportSubItem "Likely removed by a dependency or prior cleanup." 'DarkGray'
    Write-Host ""
    $leftoverFilesGone | Group-Object -Property { Split-Path $_ -Parent } | Sort-Object Name | ForEach-Object {
        Write-ReportItem 'o' $_.Name 'DarkGray'
        $_.Group | Sort-Object | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'DarkGray' }
        Write-Host ""
    }
}

# Leftover registry keys on disk — use in-memory $regKeyLookup for values
Write-ReportSection "LEFTOVER REGISTRY KEYS STILL ON DISK  ($($leftoverRegOnDisk.Count))" 'Red'
if ($leftoverRegOnDisk.Count -gt 0) {
    foreach ($key in $leftoverRegOnDisk) {
        Write-ReportItem '[LEFT]' $key 'Red'
        if ($regKeyLookup.ContainsKey($key)) {
            foreach ($prop in $regKeyLookup[$key].PSObject.Properties) {
                Write-ReportSubItem "$($prop.Name)  =  $($prop.Value)" 'DarkGray'
            }
        }
        Write-Host ""
    }
} else {
    Write-ReportItem 'OK' "No leftover registry keys found on disk." 'Green'
}

# Registry keys not in remove list but already gone
if ($leftoverRegGone.Count -gt 0) {
    Write-ReportSection "REG KEYS NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverRegGone.Count))" 'DarkGray'
    foreach ($key in $leftoverRegGone) { Write-ReportItem 'o' $key 'DarkGray' }
}

# Summary
Write-ReportSection "COMPARE SUMMARY" 'DarkCyan'
$verdict = if ($totalProblems -eq 0) { 'CLEAN UNINSTALL' } elseif ($totalProblems -lt 10) { 'MINOR LEFTOVERS' } else { 'DIRTY UNINSTALL' }
$verdictColor = if ($totalProblems -eq 0) { 'Green' } elseif ($totalProblems -lt 10) { 'Yellow' } else { 'Red' }
Write-ReportItem '>' "App                      : $appDisplayName $appVersion" 'White'
Write-ReportItem '>' "Install exit code        : $installExitCode  ($installExitMeaning)" $installCodeColor
Write-ReportItem '>' "Uninstall exit code      : $uninstallExitCode  ($uninstallExitMeaning)" $uninstallCodeColor
Write-ReportItem '>' "Installed files          : $($installedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files removed            : $($removedFilesSet.Count)" 'White'
Write-ReportItem '>' "Leftover files on disk   : $($leftoverFilesOnDisk.Count)" $(if ($leftoverFilesOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Leftover reg keys on disk: $($leftoverRegOnDisk.Count)" $(if ($leftoverRegOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Verdict                  : $verdict" $verdictColor
Write-ReportItem '>' "Install JSON             : $installJsonPath" 'DarkGray'
Write-ReportItem '>' "Uninstall JSON           : $uninstallJsonPath" 'DarkGray'
Write-ReportItem '>' "Log File                 : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkCyan

# ==============================================================================
# REGION: OPTIONAL DIFF REPORT SAVE
# ==============================================================================
Write-Host ""
Write-Host "  Save a copy of this diff report to a text file?" -ForegroundColor White
Write-Host "  [Y] Yes (default)   [N] No  —  then press Enter" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Choice > " -ForegroundColor White -NoNewline
$saveChoice = (Read-Host).Trim()
if ([string]::IsNullOrEmpty($saveChoice)) { $saveChoice = 'Y' }

if ($saveChoice -match '^[Yy]') {
    $dateStamp   = Get-Date -Format 'yyyyMMdd'
    $defaultName = "${safeAppName}_${dateStamp}_DiffReport.txt"

    $savePath = Select-SaveFile -Title "Save Diff Report" -DefaultName $defaultName -InitialDir $InstallerDir

    if ($savePath) {
        $reportLines = [System.Collections.Generic.List[string]]::new()

        $reportLines.Add("WATCH-SUITE v1.0 - DIFF REPORT")
        $reportLines.Add("Generated        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $reportLines.Add("App              : $appDisplayName $appVersion")
        $reportLines.Add("Installer        : $InstallerPath")
        $reportLines.Add("Uninstaller      : $UninstallerPath")
        $reportLines.Add("Install Exit     : $installExitCode  ($installExitMeaning)")
        $reportLines.Add("Uninstall Exit   : $uninstallExitCode  ($uninstallExitMeaning)")
        $reportLines.Add("Verdict          : $verdict")
        $reportLines.Add("Install JSON     : $installJsonPath")
        $reportLines.Add("Uninstall JSON   : $uninstallJsonPath")
        $reportLines.Add("IME Log          : $script:LogPath")
        $reportLines.Add("")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("")
        $reportLines.Add("COMPARISON STATS")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("  Files installed           : $($installedFilesSet.Count)")
        $reportLines.Add("  Files removed             : $($removedFilesSet.Count)")
        $reportLines.Add("  Files not in remove list  : $($leftoverFiles.Count)")
        $reportLines.Add("    Still on disk (PROBLEM) : $($leftoverFilesOnDisk.Count)")
        $reportLines.Add("    Already gone (OK)       : $($leftoverFilesGone.Count)")
        $reportLines.Add("  Reg keys installed        : $($installedRegSet.Count)")
        $reportLines.Add("  Reg keys removed          : $($removedRegSet.Count)")
        $reportLines.Add("  Reg keys not removed      : $($leftoverReg.Count)")
        $reportLines.Add("    Still on disk (PROBLEM) : $($leftoverRegOnDisk.Count)")
        $reportLines.Add("    Already gone (OK)       : $($leftoverRegGone.Count)")
        $reportLines.Add("")
        $reportLines.Add("LEFTOVER FILES STILL ON DISK  ($($leftoverFilesOnDisk.Count))")
        $reportLines.Add(('-' * 64))
        if ($leftoverFilesOnDisk.Count -gt 0) {
            $leftoverFilesOnDisk | Group-Object -Property { Split-Path $_ -Parent } | Sort-Object Name | ForEach-Object {
                $reportLines.Add("  [LEFT] $($_.Name)")
                $_.Group | Sort-Object | ForEach-Object { $reportLines.Add("         $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (none — clean)") }
        $reportLines.Add("")
        if ($leftoverFilesGone.Count -gt 0) {
            $reportLines.Add("FILES NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverFilesGone.Count))")
            $reportLines.Add(('-' * 64))
            $leftoverFilesGone | Group-Object -Property { Split-Path $_ -Parent } | Sort-Object Name | ForEach-Object {
                $reportLines.Add("  [GONE] $($_.Name)")
                $_.Group | Sort-Object | ForEach-Object { $reportLines.Add("         $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        }
        $reportLines.Add("LEFTOVER REGISTRY KEYS STILL ON DISK  ($($leftoverRegOnDisk.Count))")
        $reportLines.Add(('-' * 64))
        if ($leftoverRegOnDisk.Count -gt 0) {
            foreach ($key in $leftoverRegOnDisk) {
                $reportLines.Add("  [LEFT] $key")
                if ($regKeyLookup.ContainsKey($key)) {
                    foreach ($prop in $regKeyLookup[$key].PSObject.Properties) {
                        $reportLines.Add(("         {0,-22} = {1}" -f $prop.Name, $prop.Value))
                    }
                }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (none — clean)") }
        $reportLines.Add("")
        if ($leftoverRegGone.Count -gt 0) {
            $reportLines.Add("REG KEYS NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverRegGone.Count))")
            $reportLines.Add(('-' * 64))
            foreach ($key in $leftoverRegGone) { $reportLines.Add("  [GONE] $key") }
            $reportLines.Add("")
        }
        $reportLines.Add("SUMMARY")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("  App                      : $appDisplayName $appVersion")
        $reportLines.Add("  Install exit code        : $installExitCode  ($installExitMeaning)")
        $reportLines.Add("  Uninstall exit code      : $uninstallExitCode  ($uninstallExitMeaning)")
        $reportLines.Add("  Leftover files on disk   : $($leftoverFilesOnDisk.Count)")
        $reportLines.Add("  Leftover reg keys on disk: $($leftoverRegOnDisk.Count)")
        $reportLines.Add("  Verdict                  : $verdict")
        $reportLines.Add("  Install JSON             : $installJsonPath")
        $reportLines.Add("  Uninstall JSON           : $uninstallJsonPath")
        $reportLines.Add("  IME Log                  : $script:LogPath")

        try {
            $reportLines | Set-Content -Path $savePath -Encoding UTF8 -ErrorAction Stop
            Write-Host ""
            Write-Host "  OK  Diff report saved to: $savePath" -ForegroundColor Green
            Write-Log "Diff report saved: $savePath"
        } catch {
            Write-Host "  ERROR  Could not save report: $_" -ForegroundColor Red
            Write-Log "Diff report save failed: $_" 'ERROR'
        }
    } else {
        Write-Host ""
        Write-Host "  Save cancelled." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "  WATCH-SUITE complete." -ForegroundColor Yellow
Write-Host "  All three phases finished. Files are in: $InstallerDir" -ForegroundColor DarkGray
Write-Host ""
Write-Log "===== WATCH-SUITE COMPLETE ====="
Write-Host "  Press Enter to exit." -ForegroundColor DarkGray
Read-Host | Out-Null
