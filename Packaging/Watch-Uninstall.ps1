# ==============================================================================
# Watch-Uninstall.ps1
# Purpose  : Mirrors Watch-Install.ps1 for uninstalls. Loads the
#            Watch_Installer_<AppName>.json produced by Watch-Install.ps1 to
#            know exactly which files and registry keys were installed, then
#            runs the uninstaller and checks what was actually cleaned up vs
#            what was left behind. Saves Watch_Uninstaller_<AppName>.json in
#            the same directory as the installer JSON for use by
#            Compare-WatchReports.ps1.
#
# Usage    : Right-click -> "Run with PowerShell"  (self-elevates automatically)
#            OR: .\Watch-Uninstall.ps1
#
# Workflow : Watch-Install.ps1  ->  Watch-Uninstall.ps1  ->  Compare-WatchReports.ps1
#
# Pair with: Watch-Install.ps1 (v1.6+), Compare-WatchReports.ps1
#
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.1
# Changelog:
#   1.1 - Fixed three JSON field-path bugs introduced when Watch-Install.ps1
#         moved to the v1.6 schema. All three caused the uninstall string to
#         read as null and the registry/file tracking to silently fail:
#
#         (1) $installerData.AppName and .AppVersion no longer exist at the
#             top level of the v1.6 JSON. They are now under .Meta.AppName and
#             .AppInfo.DisplayVersion respectively. Fixed to read from the
#             correct paths.
#
#         (2) $installerData.RegistryData (a flat hashtable keyed by path)
#             was removed in v1.6 and replaced by .RegistryKeysAdded, an array
#             of {Path, Values} objects. The UninstallString lookup used
#             $regDataObj.PSObject.Properties[$firstKey] where $firstKey was
#             the whole PSCustomObject, not a string key — always returning
#             null. Fixed to read directly from
#             $installerData.AppInfo.UninstallString, which is the canonical
#             location in v1.6.
#
#         (3) $installedReg was set to @($installerData.RegistryKeysAdded),
#             giving an array of {Path, Values} PSCustomObjects. Downstream
#             Test-Path calls received whole objects instead of path strings,
#             always failing silently. Fixed to extract .Path strings:
#             @($installerData.RegistryKeysAdded | ForEach-Object { $_.Path })
#
#         NOTE on Add/Remove Programs: option [U] — "Use detected uninstall
#         string" — already behaves identically to clicking Uninstall in
#         Windows Settings / Add/Remove Programs. It parses and launches the
#         UninstallString from the installer JSON directly, with no file picker
#         required. Now that the UninstallString is correctly read this path
#         works as intended.
#
#   1.0 - Initial release. Loads Watch_Installer JSON, detects UninstallString
#         from stored registry data, runs uninstaller, then checks every file
#         and registry key from the installer record to determine what was
#         removed vs what was left behind. Saves Watch_Uninstaller JSON next
#         to the installer JSON. Provides console report and optional save of
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
$script:LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_WatchUninstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
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
    Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║         WATCH-UNINSTALL  v1.1  -- Intune Packager        ║" -ForegroundColor Magenta
    Write-Host "  ║  Monitors what the uninstaller removes vs what it leaves  ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""
}

# ==============================================================================
# REGION: REPORT HELPERS
# ==============================================================================
function Write-ReportHeader {
    param([string]$Title)
    $line = '─' * 62
    Write-Host ""
    Write-Host "  ┌$line┐" -ForegroundColor Magenta
    Write-Host ("  │  {0,-60}│" -f $Title) -ForegroundColor Magenta
    Write-Host "  └$line┘" -ForegroundColor Magenta
}

function Write-ReportSection {
    param([string]$Label)
    Write-Host ""
    Write-Host "  ── $Label " -ForegroundColor DarkMagenta -NoNewline
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
# REGION: FILE PICKERS
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

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Show-Banner

# -- Step 1: Load installer JSON -----------------------------------------------
Write-Host "  STEP 1 -- Select the Watch_Installer JSON for the app you are uninstalling" -ForegroundColor White
Write-Host "  This was auto-created by Watch-Install.ps1 next to your installer file." -ForegroundColor DarkGray
Write-Host "  A file picker is opening..." -ForegroundColor DarkGray
Write-Host ""

$installerJsonPath = Select-JsonFile -Title "Select Watch_Installer_*.json" -InitialDir "$env:USERPROFILE\Downloads"

try {
    $installerData = Get-Content $installerJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-Host "  ERROR: Could not read or parse the JSON file: $_" -ForegroundColor Red
    Read-Host "`n  Press Enter to exit"
    exit 1
}

# ------------------------------------------------------------------------------
# FIX (v1.1): All three field paths below were broken for v1.6 JSON.
#
# v1.6 schema locations:
#   App display name   -> .AppInfo.DisplayName   (human-readable, e.g. "Google Chrome")
#   App version        -> .AppInfo.DisplayVersion
#   Safe/sanitized name-> .Meta.AppName          (used for filenames, e.g. "Google_Chrome")
#   UninstallString    -> .AppInfo.UninstallString
#   Registry key paths -> .RegistryKeysAdded[].Path  (array of {Path, Values} objects)
#   New files list     -> .NewFiles              (unchanged, still top-level array)
# ------------------------------------------------------------------------------
$appName        = $installerData.AppInfo.DisplayName
$appVersion     = $installerData.AppInfo.DisplayVersion
$safeAppName    = $installerData.Meta.AppName

# Fallback: if AppInfo is missing (older JSON), try top-level fields
if (-not $appName)    { $appName    = $installerData.AppName }
if (-not $appVersion) { $appVersion = $installerData.AppVersion }
if (-not $safeAppName) {
    $safeAppName = ($appName -replace '[^a-zA-Z0-9]+', '_').Trim('_')
}

$installedFiles = @($installerData.NewFiles)

# FIX (v1.1): Extract .Path strings from RegistryKeysAdded array.
# Previously set to @($installerData.RegistryKeysAdded) which gave {Path,Values}
# objects — Test-Path on those always fails silently.
$installedReg = @(
    $installerData.RegistryKeysAdded |
    Where-Object { $_.Path } |
    ForEach-Object { $_.Path }
)

Write-Host "  OK  Loaded: $appName $appVersion" -ForegroundColor Green
Write-Host "      Files tracked   : $($installedFiles.Count)" -ForegroundColor DarkGray
Write-Host "      Registry keys   : $($installedReg.Count)" -ForegroundColor DarkGray
Write-Host ""

# -- Step 2: Determine uninstall method ----------------------------------------
Write-Host "  STEP 2 -- Uninstall method" -ForegroundColor White

# FIX (v1.1): UninstallString is now at .AppInfo.UninstallString in v1.6 JSON.
# The old code looked it up through $installerData.RegistryData (removed in v1.6)
# using the full PSCustomObject as a hashtable key — always returning null.
$uninstallString = $installerData.AppInfo.UninstallString

# Fallback: scan RegistryKeysAdded[].Values for an UninstallString in case
# AppInfo is missing or empty (handles edge cases where registry had no key).
if (-not $uninstallString -and $installerData.RegistryKeysAdded) {
    foreach ($regEntry in $installerData.RegistryKeysAdded) {
        $candidate = $regEntry.Values.UninstallString
        if ($candidate) { $uninstallString = $candidate; break }
    }
}

$UninstallerPath = $null
$Arguments       = ''

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
    Write-Host "  No UninstallString found in installer data." -ForegroundColor Yellow
    Write-Host "  [B] Browse for uninstaller (default)   [M] Manual entry" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Choice > " -ForegroundColor White -NoNewline
    $methodChoice = (Read-Host).Trim()
    if ([string]::IsNullOrEmpty($methodChoice)) { $methodChoice = 'B' }
}

if ($methodChoice -match '^[Uu]' -and $uninstallString) {
    # Parse quoted path + trailing args, or unquoted exe + trailing args
    if ($uninstallString -match '^"([^"]+)"\s*(.*)$') {
        $UninstallerPath = $Matches[1]
        $Arguments       = $Matches[2].Trim()
    } elseif ($uninstallString -match '^(\S+\.exe)\s*(.*)$') {
        $UninstallerPath = $Matches[1]
        $Arguments       = $Matches[2].Trim()
    } else {
        $UninstallerPath = $uninstallString
    }
    Write-Host "  OK  Using: $UninstallerPath" -ForegroundColor Green
    if ($Arguments) { Write-Host "      Args : $Arguments" -ForegroundColor DarkGray }
    Write-Host "      (Equivalent to clicking Uninstall in Add/Remove Programs)" -ForegroundColor DarkGray

} elseif ($methodChoice -match '^[Bb]') {
    $browseStart     = if ($installedFiles.Count -gt 0) { Split-Path $installedFiles[0] -Parent } else { $env:ProgramFiles }
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

Write-Host ""

# -- Step 3: Optional extra arguments ------------------------------------------
Write-Host "  STEP 3 -- Additional uninstall arguments (optional)" -ForegroundColor White
Write-Host "  Current: $(if ($Arguments) { $Arguments } else { '(none)' })" -ForegroundColor DarkGray
Write-Host "  Add more args, or press Enter to keep as-is" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Extra args > " -ForegroundColor White -NoNewline
$extraArgs = (Read-Host).Trim()
if ($extraArgs) { $Arguments = "$Arguments $extraArgs".Trim() }
Write-Host ""

# -- Step 4: Confirm -----------------------------------------------------------
$uninstallerName = Split-Path $UninstallerPath -Leaf
$disp_app    = 'App        : ' + ($appName -replace '(.{40}).+', '$1...')
$disp_uninst = 'Uninstaller: ' + ($uninstallerName -replace '(.{40}).+', '$1...')
$disp_args   = 'Arguments  : ' + $(if ($Arguments) { $Arguments } else { '(none - GUI mode)' })
$disp_track  = 'Tracking   : ' + "$($installedFiles.Count) files, $($installedReg.Count) reg keys"

Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f 'READY TO UNINSTALL')   -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f '')                      -ForegroundColor DarkMagenta
Write-Host ("  │  {0,-56}│" -f $disp_app)               -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $disp_uninst)            -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $disp_args)              -ForegroundColor White
Write-Host ("  │  {0,-56}│" -f $disp_track)             -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkMagenta
Write-Host ""
Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
Read-Host | Out-Null

# -- Step 5: Init log ----------------------------------------------------------
Write-Log "===== WATCH-UNINSTALL v1.1 STARTED ====="
Write-Log "App         : $appName $appVersion"
Write-Log "Uninstaller : $UninstallerPath"
Write-Log "Arguments   : $(if ($Arguments) { $Arguments } else { '(none)' })"
Write-Log "Tracking    : $($installedFiles.Count) files, $($installedReg.Count) registry keys"

# -- Step 6: Pre-uninstall existence check ------------------------------------
Write-Host ""
Write-Host "  Taking pre-uninstall existence snapshot..." -ForegroundColor DarkGray

$filesExistBefore   = [System.Collections.Generic.List[string]]::new()
$filesMissingBefore = [System.Collections.Generic.List[string]]::new()
foreach ($f in $installedFiles) {
    if (Test-Path $f -ErrorAction SilentlyContinue) {
        $filesExistBefore.Add($f)
    } else {
        $filesMissingBefore.Add($f)
    }
}

$regExistBefore   = [System.Collections.Generic.List[string]]::new()
$regMissingBefore = [System.Collections.Generic.List[string]]::new()
foreach ($key in $installedReg) {
    if (Test-Path $key -ErrorAction SilentlyContinue) {
        $regExistBefore.Add($key)
    } else {
        $regMissingBefore.Add($key)
    }
}

Write-Log "Pre-check: $($filesExistBefore.Count)/$($installedFiles.Count) files present, $($regExistBefore.Count)/$($installedReg.Count) reg keys present"
if ($filesMissingBefore.Count -gt 0) {
    Write-Host "  NOTE: $($filesMissingBefore.Count) tracked file(s) already missing before uninstall (updated/moved)." -ForegroundColor Yellow
}

# -- Step 7: Launch uninstaller -----------------------------------------------
Write-Host "  Launching uninstaller - waiting for it to finish..." -ForegroundColor Yellow
Write-Host "  (Complete the uninstallation, then return here for your report)" -ForegroundColor DarkGray
Write-Log "Launching uninstaller..."

$ext = [System.IO.Path]::GetExtension($UninstallerPath).ToLower()

$procParams = @{
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = "$env:TEMP\PKG_uninst_stdout.txt"
    RedirectStandardError  = "$env:TEMP\PKG_uninst_stderr.txt"
}

if ($ext -eq '.msi') {
    $procParams.FilePath = 'msiexec.exe'
    $msiArgs = "/x `"$UninstallerPath`""
    if ($Arguments) { $msiArgs += " $Arguments" }
    $procParams.ArgumentList = $msiArgs
} else {
    $procParams.FilePath = $UninstallerPath
    if ($Arguments) { $procParams.ArgumentList = $Arguments }
}

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
Write-Log "Uninstaller exited with code: $exitCode"

foreach ($stream in @('uninst_stdout', 'uninst_stderr')) {
    $sf = "$env:TEMP\PKG_$stream.txt"
    if (Test-Path $sf) {
        $sc = Get-Content $sf -Raw -ErrorAction SilentlyContinue
        if ($sc -and $sc.Trim()) { Write-Log "[$stream]: $($sc.Trim())" }
        Remove-Item $sf -Force -ErrorAction SilentlyContinue
    }
}

# -- Step 8: Post-uninstall analysis ------------------------------------------
Write-Host ""
Write-Host "  Analysing what was removed vs what remains..." -ForegroundColor DarkGray

$filesRemoved   = [System.Collections.Generic.List[string]]::new()
$filesRemaining = [System.Collections.Generic.List[string]]::new()
foreach ($f in $filesExistBefore) {
    if (Test-Path $f -ErrorAction SilentlyContinue) {
        $filesRemaining.Add($f)
    } else {
        $filesRemoved.Add($f)
    }
}

$regRemoved   = [System.Collections.Generic.List[string]]::new()
$regRemaining = [System.Collections.Generic.List[string]]::new()
foreach ($key in $regExistBefore) {
    if (Test-Path $key -ErrorAction SilentlyContinue) {
        $regRemaining.Add($key)
    } else {
        $regRemoved.Add($key)
    }
}

Write-Log "Files removed: $($filesRemoved.Count)  |  Files remaining: $($filesRemaining.Count)"
Write-Log "Reg removed: $($regRemoved.Count)  |  Reg remaining: $($regRemaining.Count)"

# -- Step 9: Exit code lookup --------------------------------------------------
$exitMeaning = switch ($exitCode) {
    0    { 'Success' }
    1    { 'General error' }
    2    { 'File not found or bad arguments' }
    3010 { 'Success - REBOOT REQUIRED' }
    1602 { 'User cancelled the uninstallation' }
    1603 { 'Fatal MSI error' }
    1605 { 'App not currently installed (MSI)' }
    1614 { 'Product uninstalled' }
    1641 { 'Reboot initiated by uninstaller' }
    # [CHANGE ME] - Add vendor-specific codes below as you encounter them.
    default { 'Unknown - consult uninstaller documentation' }
}
$codeColor = if ($exitCode -in @(0, 3010, 1614, 1641)) { 'Green' } else { 'Red' }

# -- Step 10: Auto-save Watch_Uninstaller JSON ---------------------------------
$watchUninstallDir  = Split-Path $installerJsonPath -Parent
$watchUninstallFile = Join-Path $watchUninstallDir "Watch_Uninstaller_${safeAppName}.json"

$uninstallRecord = [ordered]@{
    Type                        = 'Uninstall'
    GeneratedAt                 = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Meta = [ordered]@{
        ScriptVersion           = '1.1'
        AppName                 = $safeAppName
        UninstallerPath         = $UninstallerPath
        UninstallerFile         = $uninstallerName
        Arguments               = $Arguments
        ExitCode                = $exitCode
        ExitMeaning             = $exitMeaning
        IMELog                  = $script:LogPath
        InstallerJsonPath       = $installerJsonPath
    }
    AppInfo = [ordered]@{
        DisplayName             = $appName
        DisplayVersion          = $appVersion
    }
    FilesTrackedFromInstaller   = $installedFiles.Count
    FilesRemoved                = @($filesRemoved)
    FilesRemaining              = @($filesRemaining)
    FilesMissingBeforeUninstall = @($filesMissingBefore)
    RegistryKeysTracked         = $installedReg.Count
    RegistryKeysRemoved         = @($regRemoved)
    RegistryKeysRemaining       = @($regRemaining)
}

try {
    $uninstallRecord | ConvertTo-Json -Depth 10 |
        Set-Content -Path $watchUninstallFile -Encoding UTF8 -ErrorAction Stop
    Write-Log "Watch_Uninstaller data saved to: $watchUninstallFile"
}
catch {
    Write-Log "Failed to save Watch_Uninstaller JSON: $_" 'WARN'
}

# ==============================================================================
# REGION: FULL CONSOLE REPORT
# ==============================================================================
Show-Banner
Write-ReportHeader "UNINSTALL REPORT  --  $appName $appVersion"

Write-ReportSection "EXIT CODE"
Write-ReportItem '>' "Exit Code  : $exitCode" $codeColor
Write-ReportItem '>' "Meaning    : $exitMeaning" $codeColor

Write-ReportSection "REGISTRY  --  REMOVED  ($($regRemoved.Count) of $($regExistBefore.Count))"
if ($regRemoved.Count -gt 0) {
    foreach ($key in $regRemoved) { Write-ReportItem '[REM]' $key 'Green' }
} else {
    Write-ReportItem '!' "No registry keys were removed." 'Yellow'
}

Write-ReportSection "REGISTRY  --  REMAINING / NOT CLEANED UP  ($($regRemaining.Count))"
if ($regRemaining.Count -gt 0) {
    foreach ($key in $regRemaining) { Write-ReportItem '[LEFT]' $key 'Red' }
    Write-Host ""
    Write-ReportSubItem "These keys were installed but NOT removed by the uninstaller." 'Yellow'
} else {
    Write-ReportItem 'OK' "All tracked registry keys were removed." 'Green'
}

Write-ReportSection "FILES  --  REMOVED  ($($filesRemoved.Count) of $($filesExistBefore.Count))"
if ($filesRemoved.Count -gt 0) {
    $filesRemoved | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[REM]' $_.Name 'Green'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Gray' }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No tracked files were removed." 'Yellow'
}

Write-ReportSection "FILES  --  REMAINING / NOT CLEANED UP  ($($filesRemaining.Count))"
if ($filesRemaining.Count -gt 0) {
    $filesRemaining | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[LEFT]' $_.Name 'Red'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Yellow' }
        Write-Host ""
    }
    Write-ReportSubItem "These files were installed but NOT removed by the uninstaller." 'Yellow'
    Write-ReportSubItem "Run Compare-WatchReports.ps1 for the full leftover diff report." 'DarkGray'
} else {
    Write-ReportItem 'OK' "All tracked files were removed. Clean uninstall." 'Green'
}

Write-ReportSection "SUMMARY"
Write-ReportItem '>' "App             : $appName $appVersion" 'White'
Write-ReportItem '>' "Uninstaller     : $uninstallerName" 'White'
Write-ReportItem '>' "Exit Code       : $exitCode  ($exitMeaning)" $codeColor
Write-ReportItem '>' "Files Removed   : $($filesRemoved.Count) / $($filesExistBefore.Count)" $(if ($filesRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Files Remaining : $($filesRemaining.Count)" $(if ($filesRemaining.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Reg Removed     : $($regRemoved.Count) / $($regExistBefore.Count)" $(if ($regRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Reg Remaining   : $($regRemaining.Count)" $(if ($regRemaining.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Watch data file : $watchUninstallFile" 'DarkGray'
Write-ReportItem '>' "Log saved to    : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkMagenta

# -- Optional text report save -------------------------------------------------
Write-Host ""
Write-Host "  Save a copy of this report to a text file?" -ForegroundColor White
Write-Host "  [Y] Yes (default)   [N] No  -- then press Enter" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Choice > " -ForegroundColor White -NoNewline
$saveChoice = (Read-Host).Trim()
if ([string]::IsNullOrEmpty($saveChoice)) { $saveChoice = 'Y' }

if ($saveChoice -match '^[Yy]') {
    $dateStamp   = Get-Date -Format 'yyyyMMdd'
    $defaultName = "${safeAppName}_${dateStamp}_UninstallReport.txt"

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $saveDialog                  = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Title            = "Save Uninstall Report"
    $saveDialog.Filter           = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    $saveDialog.DefaultExt       = "txt"
    $saveDialog.FileName         = $defaultName
    $saveDialog.InitialDirectory = $watchUninstallDir

    $owner         = New-Object System.Windows.Forms.Form
    $owner.TopMost = $true
    $dialogResult  = $saveDialog.ShowDialog($owner)
    $owner.Dispose()

    if ($dialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $savePath    = $saveDialog.FileName
        $reportLines = [System.Collections.Generic.List[string]]::new()

        $reportLines.Add("WATCH-UNINSTALL v1.1 - UNINSTALL REPORT")
        $reportLines.Add("Generated        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $reportLines.Add("App              : $appName $appVersion")
        $reportLines.Add("Uninstaller      : $UninstallerPath")
        $reportLines.Add("Arguments        : $(if ($Arguments) { $Arguments } else { '(none)' })")
        $reportLines.Add("Exit Code        : $exitCode  ($exitMeaning)")
        $reportLines.Add("Installer JSON   : $installerJsonPath")
        $reportLines.Add("IME Log          : $script:LogPath")
        $reportLines.Add("")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("")
        $reportLines.Add("REGISTRY KEYS REMOVED  ($($regRemoved.Count) of $($regExistBefore.Count))")
        $reportLines.Add(('-' * 64))
        if ($regRemoved.Count -gt 0) {
            foreach ($k in $regRemoved) { $reportLines.Add("  [REM]  $k") }
        } else { $reportLines.Add("  (none)") }
        $reportLines.Add("")
        $reportLines.Add("REGISTRY KEYS REMAINING / NOT CLEANED UP  ($($regRemaining.Count))")
        $reportLines.Add(('-' * 64))
        if ($regRemaining.Count -gt 0) {
            foreach ($k in $regRemaining) { $reportLines.Add("  [LEFT] $k") }
        } else { $reportLines.Add("  (all clean)") }
        $reportLines.Add("")
        $reportLines.Add("FILES REMOVED  ($($filesRemoved.Count) of $($filesExistBefore.Count))")
        $reportLines.Add(('-' * 64))
        if ($filesRemoved.Count -gt 0) {
            $filesRemoved | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
                $reportLines.Add("  [DIR] $($_.Name)")
                $_.Group | ForEach-Object { $reportLines.Add("        $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (none)") }
        $reportLines.Add("")
        $reportLines.Add("FILES REMAINING / NOT CLEANED UP  ($($filesRemaining.Count))")
        $reportLines.Add(('-' * 64))
        if ($filesRemaining.Count -gt 0) {
            $filesRemaining | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
                $reportLines.Add("  [LEFT] $($_.Name)")
                $_.Group | ForEach-Object { $reportLines.Add("         $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (all clean)") }
        $reportLines.Add("")
        $reportLines.Add("SUMMARY")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("  App             : $appName $appVersion")
        $reportLines.Add("  Exit Code       : $exitCode  ($exitMeaning)")
        $reportLines.Add("  Files Removed   : $($filesRemoved.Count) / $($filesExistBefore.Count)")
        $reportLines.Add("  Files Remaining : $($filesRemaining.Count)")
        $reportLines.Add("  Reg Removed     : $($regRemoved.Count) / $($regExistBefore.Count)")
        $reportLines.Add("  Reg Remaining   : $($regRemaining.Count)")
        $reportLines.Add("  Watch data file : $watchUninstallFile")
        $reportLines.Add("  IME Log         : $script:LogPath")

        try {
            $reportLines | Set-Content -Path $savePath -Encoding UTF8 -ErrorAction Stop
            Write-Host ""
            Write-Host "  OK  Report saved to: $savePath" -ForegroundColor Green
            Write-Log "Report saved to: $savePath"
        } catch {
            Write-Host "  ERROR  Could not save report: $_" -ForegroundColor Red
            Write-Log "Report save failed: $_" 'ERROR'
        }
    } else {
        Write-Host ""
        Write-Host "  Save cancelled." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Press Enter to exit." -ForegroundColor DarkGray
Read-Host | Out-Null
