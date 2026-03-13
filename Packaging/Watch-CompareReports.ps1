# ==============================================================================
# Compare-WatchReports.ps1
# Purpose  : Loads Watch_Installer_<AppName>.json and
#            Watch_Uninstaller_<AppName>.json produced by Watch-Install.ps1
#            and Watch-Uninstall.ps1, then diffs them to identify every file
#            and registry key that the installer created but the uninstaller
#            failed to remove. Gives you a clear picture of whether the
#            uninstaller leaves a clean system.
#
# Usage    : Right-click -> "Run with PowerShell"  (self-elevates automatically)
#            OR: .\Compare-WatchReports.ps1
#
# Workflow : Watch-Install.ps1  ->  Watch-Uninstall.ps1  ->  Compare-WatchReports.ps1
#
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.0
# Changelog:
#   1.0 - Initial release. Loads both Watch JSON files via file pickers,
#         computes the diff between files/registry keys installed vs removed,
#         and reports leftover files (grouped by directory), leftover registry
#         keys (with all stored values), and a clean/dirty verdict. Provides
#         console report with colour-coded severity and optional save of
#         human-readable txt report.
# ==============================================================================

# ==============================================================================
# REGION: SELF-ELEVATION
# ==============================================================================
$currentUser      = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin          = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "`n  Not running as Administrator - relaunching elevated...`n" -ForegroundColor Yellow
    Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ==============================================================================
# REGION: LOGGING
# ==============================================================================
$script:LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_CompareReports_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Path (Split-Path $script:LogPath) -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $script:LogPath -Value $entry -ErrorAction SilentlyContinue
}

# ==============================================================================
# REGION: BANNER
# ==============================================================================
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host "  |       COMPARE-WATCHREPORTS  v1.0  -- Intune Packager        |" -ForegroundColor Cyan
    Write-Host "  |   Diffs install vs uninstall to find leftover files/keys    |" -ForegroundColor Cyan
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host ""
}

# ==============================================================================
# REGION: REPORT HELPERS
# ==============================================================================
function Write-ReportHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "  +------------------------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  |  {0,-66}|" -f $Title) -ForegroundColor Cyan
    Write-Host "  +------------------------------------------------------------------+" -ForegroundColor Cyan
}

function Write-ReportSection {
    param([string]$Label, [ConsoleColor]$Color = 'DarkCyan')
    Write-Host ""
    Write-Host "  -- $Label " -ForegroundColor $Color -NoNewline
    Write-Host ('-' * ([Math]::Max(2, 56 - $Label.Length))) -ForegroundColor DarkGray
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
# REGION: FILE PICKER
# ==============================================================================
function Select-JsonFile {
    param([string]$Title, [string]$InitialDir)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title            = $Title
    $dialog.Filter           = "Watch JSON Files (Watch_*.json)|Watch_*.json|JSON Files (*.json)|*.json|All Files (*.*)|*.*"
    $dialog.InitialDirectory = $InitialDir
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

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Show-Banner

# -- Step 1: Load installer JSON -----------------------------------------------
Write-Host "  STEP 1 -- Select the Watch_Installer_*.json file" -ForegroundColor White
Write-Host "  A file picker is opening..." -ForegroundColor DarkGray
Write-Host ""

$installerJsonPath = Select-JsonFile -Title "Select Watch_Installer_*.json" -InitialDir "$env:USERPROFILE\Downloads"

try {
    $installerData = Get-Content $installerJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "  ERROR: Could not parse installer JSON: $_" -ForegroundColor Red
    Read-Host "`n  Press Enter to exit"
    exit 1
}

Write-Host "  OK  Installer  : $($installerData.AppName) $($installerData.AppVersion)" -ForegroundColor Green
Write-Host "      Install date: $($installerData.InstallDate)" -ForegroundColor DarkGray
Write-Host ""

# -- Step 2: Load uninstaller JSON ---------------------------------------------
Write-Host "  STEP 2 -- Select the Watch_Uninstaller_*.json file" -ForegroundColor White
Write-Host "  A file picker is opening..." -ForegroundColor DarkGray
Write-Host ""

$uninstallerJsonDir  = Split-Path $installerJsonPath -Parent
$uninstallerJsonPath = Select-JsonFile -Title "Select Watch_Uninstaller_*.json" -InitialDir $uninstallerJsonDir

try {
    $uninstallerData = Get-Content $uninstallerJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "  ERROR: Could not parse uninstaller JSON: $_" -ForegroundColor Red
    Read-Host "`n  Press Enter to exit"
    exit 1
}

Write-Host "  OK  Uninstaller : $($uninstallerData.AppName) $($uninstallerData.AppVersion)" -ForegroundColor Green
Write-Host "      Uninstall date: $($uninstallerData.UninstallDate)" -ForegroundColor DarkGray
Write-Host ""

# Warn if the two files are for different apps
if ($installerData.AppName -ne $uninstallerData.AppName) {
    Write-Host "  WARN: App names do not match." -ForegroundColor Yellow
    Write-Host "        Installer  : $($installerData.AppName)" -ForegroundColor Yellow
    Write-Host "        Uninstaller: $($uninstallerData.AppName)" -ForegroundColor Yellow
    Write-Host "  Press Enter to compare anyway, or Ctrl+C to abort." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

Write-Host "  Comparing reports..." -ForegroundColor DarkGray

# ==============================================================================
# REGION: DIFF LOGIC
# ==============================================================================

# Build sets for O(1) lookup
$installedFilesSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($installerData.NewFiles),
    [System.StringComparer]::OrdinalIgnoreCase
)
$removedFilesSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($uninstallerData.FilesRemoved),
    [System.StringComparer]::OrdinalIgnoreCase
)
$installedRegSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($installerData.RegistryKeysAdded),
    [System.StringComparer]::OrdinalIgnoreCase
)
$removedRegSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($uninstallerData.RegistryKeysRemoved),
    [System.StringComparer]::OrdinalIgnoreCase
)

# Leftover files = installed but NOT in the removed list
$leftoverFiles = [System.Collections.Generic.List[string]]::new()
foreach ($f in $installedFilesSet) {
    if (-not $removedFilesSet.Contains($f)) {
        $leftoverFiles.Add($f)
    }
}
# Sort for consistent output
$leftoverFiles = @($leftoverFiles | Sort-Object)

# Leftover registry keys = installed but NOT in the removed list
$leftoverReg = [System.Collections.Generic.List[string]]::new()
foreach ($k in $installedRegSet) {
    if (-not $removedRegSet.Contains($k)) {
        $leftoverReg.Add($k)
    }
}
$leftoverReg = @($leftoverReg | Sort-Object)

# Verify against current disk state to distinguish
# "uninstaller missed it" vs "it was already gone before uninstall"
$leftoverFilesOnDisk   = @($leftoverFiles | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })
$leftoverFilesGone     = @($leftoverFiles | Where-Object { -not (Test-Path $_ -ErrorAction SilentlyContinue) })
$leftoverRegOnDisk     = @($leftoverReg   | Where-Object { Test-Path $_ -ErrorAction SilentlyContinue })
$leftoverRegGone       = @($leftoverReg   | Where-Object { -not (Test-Path $_ -ErrorAction SilentlyContinue) })

Write-Log "===== COMPARE-WATCHREPORTS v1.0 ====="
Write-Log "Installer JSON  : $installerJsonPath"
Write-Log "Uninstaller JSON: $uninstallerJsonPath"
Write-Log "Installed files : $($installedFilesSet.Count)  |  Removed: $($removedFilesSet.Count)  |  Leftover (not in remove list): $($leftoverFiles.Count)"
Write-Log "Leftover files still on disk: $($leftoverFilesOnDisk.Count)"
Write-Log "Installed keys  : $($installedRegSet.Count)  |  Removed: $($removedRegSet.Count)  |  Leftover: $($leftoverReg.Count)"

# ==============================================================================
# REGION: FULL CONSOLE REPORT
# ==============================================================================
Show-Banner
Write-ReportHeader "DIFF REPORT  --  $($installerData.AppName) $($installerData.AppVersion)"

# -- Headline verdict ----------------------------------------------------------
Write-ReportSection "VERDICT"
$totalProblems = $leftoverFilesOnDisk.Count + $leftoverRegOnDisk.Count
if ($totalProblems -eq 0) {
    Write-ReportItem 'OK' "CLEAN UNINSTALL -- No installed files or registry keys remain on disk." 'Green'
} elseif ($totalProblems -lt 10) {
    Write-ReportItem '!' "MINOR LEFTOVERS -- $totalProblems items remain on disk that were not removed." 'Yellow'
} else {
    Write-ReportItem 'X' "DIRTY UNINSTALL -- $totalProblems items remain on disk. Uninstaller is incomplete." 'Red'
}

# -- Stats ---------------------------------------------------------------------
Write-ReportSection "COMPARISON STATS"
Write-ReportItem '>' "Files installed          : $($installedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files removed            : $($removedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files not in remove list : $($leftoverFiles.Count)" $(if ($leftoverFiles.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-ReportItem '>' "  Still on disk (PROBLEM) : $($leftoverFilesOnDisk.Count)" $(if ($leftoverFilesOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "  Already gone (OK)       : $($leftoverFilesGone.Count)" 'DarkGray'
Write-Host ""
Write-ReportItem '>' "Reg keys installed       : $($installedRegSet.Count)" 'White'
Write-ReportItem '>' "Reg keys removed         : $($removedRegSet.Count)" 'White'
Write-ReportItem '>' "Reg keys not removed     : $($leftoverReg.Count)" $(if ($leftoverReg.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-ReportItem '>' "  Still on disk (PROBLEM) : $($leftoverRegOnDisk.Count)" $(if ($leftoverRegOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "  Already gone (OK)       : $($leftoverRegGone.Count)" 'DarkGray'

# -- Leftover files on disk ----------------------------------------------------
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

# -- Leftover files not on disk (uninstaller skipped but already cleaned) ------
if ($leftoverFilesGone.Count -gt 0) {
    Write-ReportSection "FILES NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverFilesGone.Count))" 'DarkGray'
    Write-ReportSubItem "These were installed but neither explicitly removed by the uninstaller" 'DarkGray'
    Write-ReportSubItem "nor present on disk. Likely removed by a dependency or prior cleanup." 'DarkGray'
    Write-Host ""
    $leftoverFilesGone | Group-Object -Property { Split-Path $_ -Parent } | Sort-Object Name | ForEach-Object {
        Write-ReportItem 'o' $_.Name 'DarkGray'
        $_.Group | Sort-Object | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'DarkGray' }
        Write-Host ""
    }
}

# -- Leftover registry keys on disk -------------------------------------------
Write-ReportSection "LEFTOVER REGISTRY KEYS STILL ON DISK  ($($leftoverRegOnDisk.Count))" 'Red'

if ($leftoverRegOnDisk.Count -gt 0) {
    $regDataObj = $installerData.RegistryData
    foreach ($key in $leftoverRegOnDisk) {
        Write-ReportItem '[LEFT]' $key 'Red'
        # Try to show stored values from installer data
        $keyEntry = $regDataObj.PSObject.Properties[$key]
        if ($keyEntry) {
            $keyEntry.Value.PSObject.Properties | ForEach-Object {
                Write-ReportSubItem "$($_.Name)  =  $($_.Value)" 'DarkGray'
            }
        }
        Write-Host ""
    }
} else {
    Write-ReportItem 'OK' "No leftover registry keys found on disk." 'Green'
}

# -- Leftover registry keys already gone --------------------------------------
if ($leftoverRegGone.Count -gt 0) {
    Write-ReportSection "REG KEYS NOT IN REMOVE LIST BUT ALREADY GONE  ($($leftoverRegGone.Count))" 'DarkGray'
    foreach ($key in $leftoverRegGone) { Write-ReportItem 'o' $key 'DarkGray' }
}

# -- Summary -------------------------------------------------------------------
Write-ReportSection "SUMMARY"
Write-ReportItem '>' "App                     : $($installerData.AppName) $($installerData.AppVersion)" 'White'
Write-ReportItem '>' "Installed files          : $($installedFilesSet.Count)" 'White'
Write-ReportItem '>' "Files removed            : $($removedFilesSet.Count)" 'White'
Write-ReportItem '>' "Leftover files on disk   : $($leftoverFilesOnDisk.Count)" $(if ($leftoverFilesOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Leftover reg keys on disk: $($leftoverRegOnDisk.Count)" $(if ($leftoverRegOnDisk.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Verdict                  : $(if ($totalProblems -eq 0) { 'CLEAN' } elseif ($totalProblems -lt 10) { 'MINOR LEFTOVERS' } else { 'DIRTY' })" $(if ($totalProblems -eq 0) { 'Green' } elseif ($totalProblems -lt 10) { 'Yellow' } else { 'Red' })
Write-ReportItem '>' "Installer JSON           : $installerJsonPath" 'DarkGray'
Write-ReportItem '>' "Uninstaller JSON         : $uninstallerJsonPath" 'DarkGray'
Write-ReportItem '>' "Log saved to             : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor DarkCyan

# -- Save report prompt --------------------------------------------------------
Write-Host ""
Write-Host "  Save a copy of this diff report to a text file?" -ForegroundColor White
Write-Host "  [Y] Yes (default)   [N] No  -- then press Enter" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Choice > " -ForegroundColor White -NoNewline
$saveChoice = (Read-Host).Trim()
if ([string]::IsNullOrEmpty($saveChoice)) { $saveChoice = 'Y' }

if ($saveChoice -match '^[Yy]') {
    $safeName    = $installerData.AppName -replace '[\\/:*?"<>|\s]', '_'
    $dateStamp   = Get-Date -Format 'yyyyMMdd'
    $defaultName = "${safeName}_${dateStamp}_DiffReport.txt"

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $saveDialog                  = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Title            = "Save Diff Report"
    $saveDialog.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveDialog.DefaultExt       = "txt"
    $saveDialog.FileName         = $defaultName
    $saveDialog.InitialDirectory = Split-Path $installerJsonPath -Parent

    $owner        = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $dialogResult  = $saveDialog.ShowDialog($owner)
    $owner.Dispose()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $savePath    = $saveDialog.FileName
        $reportLines = [System.Collections.Generic.List[string]]::new()

        $verdict = if ($totalProblems -eq 0) { 'CLEAN UNINSTALL' } elseif ($totalProblems -lt 10) { 'MINOR LEFTOVERS' } else { 'DIRTY UNINSTALL' }

        $reportLines.Add("COMPARE-WATCHREPORTS v1.0 - DIFF REPORT")
        $reportLines.Add("Generated        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $reportLines.Add("App              : $($installerData.AppName) $($installerData.AppVersion)")
        $reportLines.Add("Installer JSON   : $installerJsonPath")
        $reportLines.Add("Uninstaller JSON : $uninstallerJsonPath")
        $reportLines.Add("Verdict          : $verdict")
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
        } else { $reportLines.Add("  (none - clean)") }
        $reportLines.Add("")
        $reportLines.Add("LEFTOVER REGISTRY KEYS STILL ON DISK  ($($leftoverRegOnDisk.Count))")
        $reportLines.Add(('-' * 64))
        if ($leftoverRegOnDisk.Count -gt 0) {
            $regDataObj = $installerData.RegistryData
            foreach ($key in $leftoverRegOnDisk) {
                $reportLines.Add("  [LEFT] $key")
                $keyEntry = $regDataObj.PSObject.Properties[$key]
                if ($keyEntry) {
                    $keyEntry.Value.PSObject.Properties | ForEach-Object {
                        $reportLines.Add("         $($_.Name)  =  $($_.Value)")
                    }
                }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (none - clean)") }
        $reportLines.Add("")
        $reportLines.Add("SUMMARY")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("  App                      : $($installerData.AppName) $($installerData.AppVersion)")
        $reportLines.Add("  Leftover files on disk   : $($leftoverFilesOnDisk.Count)")
        $reportLines.Add("  Leftover reg keys on disk: $($leftoverRegOnDisk.Count)")
        $reportLines.Add("  Verdict                  : $verdict")
        $reportLines.Add("  Log saved to             : $script:LogPath")

        $reportLines | Set-Content -Path $savePath -Encoding UTF8 -ErrorAction Stop
        Write-Host ""
        Write-Host "  OK  Report saved to: $savePath" -ForegroundColor Green
        Write-Log "Diff report saved to: $savePath"
    } else {
        Write-Host ""
        Write-Host "  Save cancelled." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Press Enter to exit." -ForegroundColor DarkGray
Read-Host | Out-Null
