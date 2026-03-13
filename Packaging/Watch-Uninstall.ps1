# ==============================================================================
# Watch-Uninstall.ps1
# Purpose  : Watches what an uninstaller removes vs what it leaves behind.
#
#            TWO MODES:
#
#            [A] JSON mode  -- Loads a Watch_Installer_<AppName>.json produced
#                by Watch-Install.ps1. Knows exactly which files and registry
#                keys were installed. Reports precisely what was removed vs
#                left behind. Pass output to Compare-WatchReports.ps1.
#
#            [B] Standalone mode  -- No JSON required. Picks an app from the
#                installed apps list (same source as Add/Remove Programs), takes
#                before snapshots of the registry and app install folder, runs
#                the app's own uninstall string, then diffs to show what was
#                cleaned up vs what remains. Works on any installed app.
#
# Usage    : Right-click -> "Run with PowerShell"  (self-elevates automatically)
#            OR: .\Watch-Uninstall.ps1
#
# Workflow : Watch-Install.ps1  ->  Watch-Uninstall.ps1  ->  Compare-WatchReports.ps1
#            (JSON mode only for the full three-script workflow)
#
# Pair with: Watch-Install.ps1 (v1.6+), Compare-WatchReports.ps1
#
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 2.1
# Changelog:
#   2.1 - Added Mode C (Direct string). User pastes the full uninstall command
#         exactly as they know it (e.g. setup.exe /s /f1"path\uninstall.iss").
#         Exe and args are parsed out automatically. User optionally specifies
#         folders to watch; defaults to Program Files + ProgramData if none
#         given. Before/after registry and filesystem snapshots wrap the run.
#         Registry remaining section skipped in Mode C report (no app context
#         to filter against). Mode label updated throughout for all three modes.
#
#   2.0 - Added standalone mode (Mode B). No Watch_Installer JSON required.
#         Reads installed apps from registry (same source as Add/Remove Programs),
#         lets user filter/select by name, takes before snapshots of registry
#         uninstall hives and app install folder, runs the uninstall string,
#         diffs before vs after, and reports removed items and leftovers.
#         Mode selection prompt added at startup. Both modes share the same
#         uninstaller execution and report logic.
#
#   1.1 - Fixed three JSON field-path bugs introduced when Watch-Install.ps1
#         moved to the v1.6 schema (AppName, UninstallString, RegistryKeysAdded
#         path locations). See original changelog for full detail.
#
#   1.0 - Initial release. JSON mode only.
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
    Write-Host "  ║         WATCH-UNINSTALL  v2.1  -- Intune Packager        ║" -ForegroundColor Magenta
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
# REGION: REGISTRY HELPERS
# ==============================================================================
$script:UninstallHives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Get-InstalledApps {
    $apps = [System.Collections.Generic.List[object]]::new()
    foreach ($hive in $script:UninstallHives) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName) {
                $apps.Add([PSCustomObject]@{
                    DisplayName      = $props.DisplayName
                    DisplayVersion   = $props.DisplayVersion
                    Publisher        = $props.Publisher
                    InstallLocation  = $props.InstallLocation
                    UninstallString  = $props.UninstallString
                    QuietUninstallString = $props.QuietUninstallString
                    RegistryPath     = $_.PSPath
                    RegistryKey      = $_.PSChildName
                })
            }
        }
    }
    return $apps | Sort-Object DisplayName
}

# Takes a snapshot of all Uninstall hive keys and their values
function Get-RegistrySnapshot {
    $snapshot = [System.Collections.Generic.List[object]]::new()
    foreach ($hive in $script:UninstallHives) {
        if (-not (Test-Path $hive)) { continue }
        Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            $snapshot.Add([PSCustomObject]@{
                Path   = $_.PSPath
                Values = $props
            })
        }
    }
    return $snapshot
}

# Snapshots all files in a given set of root folders
function Get-FilesystemSnapshot {
    param([string[]]$Roots)
    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
        Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { $files.Add($_.FullName) }
    }
    return $files
}

# Builds the list of filesystem roots to watch for a given app
function Get-AppWatchRoots {
    param([PSCustomObject]$App)
    $roots = [System.Collections.Generic.List[string]]::new()

    # InstallLocation from registry is the most reliable
    if ($App.InstallLocation -and (Test-Path $App.InstallLocation -ErrorAction SilentlyContinue)) {
        $roots.Add($App.InstallLocation.TrimEnd('\'))
    }

    # Also check common locations by app name in case InstallLocation is blank
    $safeName = $App.DisplayName -replace '[^\w\s]','' -replace '\s+', ' '
    $candidates = @(
        (Join-Path $env:ProgramFiles        $safeName),
        (Join-Path ${env:ProgramFiles(x86)} $safeName),
        (Join-Path $env:ProgramData         $safeName)
    )
    foreach ($c in $candidates) {
        if ((Test-Path $c -ErrorAction SilentlyContinue) -and $roots -notcontains $c) {
            $roots.Add($c)
        }
    }

    # Also watch ProgramData and AppData top-level for vendor-named folders
    if ($App.Publisher) {
        $vendorSafe = $App.Publisher -replace '[^\w\s]','' -replace '\s+', ' '
        $vendorCandidates = @(
            (Join-Path $env:ProgramData $vendorSafe),
            (Join-Path $env:APPDATA     $vendorSafe),
            (Join-Path $env:LOCALAPPDATA $vendorSafe)
        )
        foreach ($c in $vendorCandidates) {
            if ((Test-Path $c -ErrorAction SilentlyContinue) -and $roots -notcontains $c) {
                $roots.Add($c)
            }
        }
    }

    return $roots
}

# Recursively searches common registry hives for any key whose path, name, or
# value data contains the search term. Returns an array of match objects.
function Search-RegistryRemnants {
    param([string]$SearchTerm)

    $searchRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE',
        'HKLM:\SOFTWARE\WOW6432Node',
        'HKCU:\SOFTWARE',
        'HKLM:\SYSTEM\CurrentControlSet\Services'
    )

    # Use first meaningful word (3+ chars) to reduce noise on short/generic names
    $keyword = ($SearchTerm -split '\s+' | Where-Object { $_.Length -ge 3 } | Select-Object -First 1)
    if (-not $keyword) { $keyword = $SearchTerm }

    $results = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root -ErrorAction SilentlyContinue)) { continue }
        try {
            Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $keyPath = $_.PSPath

                # Check if the key path itself contains the keyword
                if ($keyPath -match [regex]::Escape($keyword)) {
                    if ($seen.Add($keyPath)) {
                        $results.Add([PSCustomObject]@{
                            RegistryPath = $keyPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
                            MatchType    = 'Key name'
                            MatchDetail  = ''
                        })
                    }
                }

                # Check values within the key
                try {
                    $props = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
                    if ($props) {
                        $props.PSObject.Properties |
                            Where-Object { $_.Name -notmatch '^PS(Path|Drive|Provider|ChildName|ParentPath)$' } |
                            ForEach-Object {
                                $valName = $_.Name
                                $valData = "$($_.Value)"
                                $matchedVal = $valName -match [regex]::Escape($keyword) -or
                                              $valData -match [regex]::Escape($keyword)
                                if ($matchedVal) {
                                    $dedupeKey = "$keyPath|$valName"
                                    if ($seen.Add($dedupeKey)) {
                                        $results.Add([PSCustomObject]@{
                                            RegistryPath = $keyPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
                                            MatchType    = 'Value'
                                            MatchDetail  = "$valName = $($valData -replace '(.{60}).+','$1...')"
                                        })
                                    }
                                }
                            }
                    }
                } catch { }
            }
        } catch { }
    }

    return $results
}

# ==============================================================================
# REGION: SHARED -- PARSE AND RUN UNINSTALLER
# ==============================================================================
function Invoke-Uninstaller {
    param(
        [string]$UninstallerPath,
        [string]$Arguments
    )

    Write-Host "  Launching uninstaller - waiting for it to finish..." -ForegroundColor Yellow
    Write-Host "  (Complete the uninstallation, then return here for your report)" -ForegroundColor DarkGray
    Write-Log "Launching uninstaller: $UninstallerPath $Arguments"

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
        $fallbackParams = @{ FilePath = $procParams.FilePath; Wait = $true; PassThru = $true }
        if ($procParams.ContainsKey('ArgumentList')) { $fallbackParams.ArgumentList = $procParams.ArgumentList }
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

    return $exitCode
}

function Get-ExitMeaning {
    param([int]$Code)
    switch ($Code) {
        0    { 'Success' }
        1    { 'General error' }
        2    { 'File not found or bad arguments' }
        3010 { 'Success - REBOOT REQUIRED' }
        1602 { 'User cancelled the uninstallation' }
        1603 { 'Fatal MSI error' }
        1605 { 'App not currently installed (MSI)' }
        1614 { 'Product uninstalled' }
        1641 { 'Reboot initiated by uninstaller' }
        default { 'Unknown - consult uninstaller documentation' }
    }
}

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Show-Banner

# -- Mode selection ------------------------------------------------------------
Write-Host "  How do you want to run Watch-Uninstall?" -ForegroundColor White
Write-Host ""
Write-Host "    [A]  JSON mode      -- Load a Watch_Installer JSON from Watch-Install.ps1" -ForegroundColor Gray
Write-Host "                          Tracks the exact files and registry keys that were" -ForegroundColor DarkGray
Write-Host "                          installed. Best precision. Use for Intune packaging." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    [B]  Standalone     -- No JSON needed. Pick any installed app from the" -ForegroundColor Gray
Write-Host "                          list (same as Add/Remove Programs), take before/after" -ForegroundColor DarkGray
Write-Host "                          snapshots, and see exactly what the uninstaller" -ForegroundColor DarkGray
Write-Host "                          cleaned up vs what it left behind." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    [C]  Direct string  -- You already know the full uninstall command." -ForegroundColor Gray
Write-Host "                          Paste it in, optionally specify folders to watch," -ForegroundColor DarkGray
Write-Host "                          and get before/after snapshots around the run." -ForegroundColor DarkGray
Write-Host "                          e.g.  setup.exe /s /f1`"C:\uninstall.iss`"" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Choice [A/B/C, default A] > " -ForegroundColor White -NoNewline
$modeChoice = (Read-Host).Trim().ToUpper()
if ([string]::IsNullOrEmpty($modeChoice)) { $modeChoice = 'A' }

Write-Host ""

# ==============================================================================
# ── MODE A: JSON ──────────────────────────────────────────────────────────────
# ==============================================================================
if ($modeChoice -eq 'A') {

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

    $appName     = $installerData.AppInfo.DisplayName
    $appVersion  = $installerData.AppInfo.DisplayVersion
    $safeAppName = $installerData.Meta.AppName

    if (-not $appName)    { $appName    = $installerData.AppName }
    if (-not $appVersion) { $appVersion = $installerData.AppVersion }
    if (-not $safeAppName) { $safeAppName = ($appName -replace '[^a-zA-Z0-9]+', '_').Trim('_') }

    $installedFiles = @($installerData.NewFiles)
    $installedReg   = @(
        $installerData.RegistryKeysAdded |
        Where-Object { $_.Path } |
        ForEach-Object { $_.Path }
    )

    Write-Host "  OK  Loaded: $appName $appVersion" -ForegroundColor Green
    Write-Host "      Files tracked   : $($installedFiles.Count)" -ForegroundColor DarkGray
    Write-Host "      Registry keys   : $($installedReg.Count)" -ForegroundColor DarkGray
    Write-Host ""

    # -- Determine uninstall method --------------------------------------------
    Write-Host "  STEP 2 -- Uninstall method" -ForegroundColor White

    $uninstallString = $installerData.AppInfo.UninstallString
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
        Write-Host "  [U] Use detected string -- same as Add/Remove Programs (default)" -ForegroundColor DarkGray
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
        if ($uninstallString -match '^"([^"]+)"\s*(.*)$') {
            $UninstallerPath = $Matches[1]; $Arguments = $Matches[2].Trim()
        } elseif ($uninstallString -match '^(\S+\.exe)\s*(.*)$') {
            $UninstallerPath = $Matches[1]; $Arguments = $Matches[2].Trim()
        } else {
            $UninstallerPath = $uninstallString
        }
        Write-Host "  OK  Using: $UninstallerPath" -ForegroundColor Green
        if ($Arguments) { Write-Host "      Args : $Arguments" -ForegroundColor DarkGray }
        Write-Host "      (Equivalent to clicking Uninstall in Add/Remove Programs)" -ForegroundColor DarkGray

    } elseif ($methodChoice -match '^[Bb]') {
        $browseStart     = if ($installedFiles.Count -gt 0) { Split-Path $installedFiles[0] -Parent } else { $env:ProgramFiles }
        $UninstallerPath = Select-ExeFile -InitialDir $browseStart
        if (-not $UninstallerPath) { Write-Host "  No file selected. Exiting." -ForegroundColor Yellow; exit 0 }
        Write-Host "  OK  Selected: $UninstallerPath" -ForegroundColor Green

    } else {
        Write-Host "  Enter full path to uninstaller > " -ForegroundColor White -NoNewline
        $UninstallerPath = (Read-Host).Trim()
        if (-not $UninstallerPath -or -not (Test-Path $UninstallerPath)) {
            Write-Host "  Path not found or empty. Exiting." -ForegroundColor Red; exit 1
        }
    }

    Write-Host ""
    Write-Host "  STEP 3 -- Additional uninstall arguments (optional)" -ForegroundColor White
    Write-Host "  Current: $(if ($Arguments) { $Arguments } else { '(none)' })" -ForegroundColor DarkGray
    Write-Host "  Add more args, or press Enter to keep as-is > " -ForegroundColor White -NoNewline
    $extraArgs = (Read-Host).Trim()
    if ($extraArgs) { $Arguments = "$Arguments $extraArgs".Trim() }
    Write-Host ""

    # -- Confirm ---------------------------------------------------------------
    $uninstallerName = Split-Path $UninstallerPath -Leaf
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f 'READY TO UNINSTALL  [JSON MODE]')    -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f '')                                    -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f "App        : $($appName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Uninstaller: $($uninstallerName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Arguments  : $(if ($Arguments) { $Arguments } else { '(none)' })") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Tracking   : $($installedFiles.Count) files, $($installedReg.Count) reg keys") -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkMagenta
    Write-Host ""
    Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
    Read-Host | Out-Null

    Write-Log "===== WATCH-UNINSTALL v2.1 [JSON MODE] STARTED ====="
    Write-Log "App         : $appName $appVersion"
    Write-Log "Uninstaller : $UninstallerPath"
    Write-Log "Arguments   : $(if ($Arguments) { $Arguments } else { '(none)' })"
    Write-Log "Tracking    : $($installedFiles.Count) files, $($installedReg.Count) registry keys"

    # -- Pre-uninstall snapshot ------------------------------------------------
    Write-Host ""
    Write-Host "  Taking pre-uninstall existence snapshot..." -ForegroundColor DarkGray

    $filesExistBefore   = [System.Collections.Generic.List[string]]::new()
    $filesMissingBefore = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $installedFiles) {
        if (Test-Path $f -ErrorAction SilentlyContinue) { $filesExistBefore.Add($f) }
        else { $filesMissingBefore.Add($f) }
    }

    $regExistBefore   = [System.Collections.Generic.List[string]]::new()
    $regMissingBefore = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $installedReg) {
        if (Test-Path $key -ErrorAction SilentlyContinue) { $regExistBefore.Add($key) }
        else { $regMissingBefore.Add($key) }
    }

    Write-Log "Pre-check: $($filesExistBefore.Count)/$($installedFiles.Count) files present, $($regExistBefore.Count)/$($installedReg.Count) reg keys present"
    if ($filesMissingBefore.Count -gt 0) {
        Write-Host "  NOTE: $($filesMissingBefore.Count) tracked file(s) already missing before uninstall (updated/moved)." -ForegroundColor Yellow
    }

    # -- Run uninstaller -------------------------------------------------------
    Write-Host ""
    $exitCode = Invoke-Uninstaller -UninstallerPath $UninstallerPath -Arguments $Arguments

    # -- Post-uninstall analysis -----------------------------------------------
    Write-Host ""
    Write-Host "  Analysing what was removed vs what remains..." -ForegroundColor DarkGray

    $filesRemoved   = [System.Collections.Generic.List[string]]::new()
    $filesRemaining = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $filesExistBefore) {
        if (Test-Path $f -ErrorAction SilentlyContinue) { $filesRemaining.Add($f) }
        else { $filesRemoved.Add($f) }
    }

    $regRemoved   = [System.Collections.Generic.List[string]]::new()
    $regRemaining = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $regExistBefore) {
        if (Test-Path $key -ErrorAction SilentlyContinue) { $regRemaining.Add($key) }
        else { $regRemoved.Add($key) }
    }

    Write-Log "Files removed: $($filesRemoved.Count)  |  Files remaining: $($filesRemaining.Count)"
    Write-Log "Reg removed: $($regRemoved.Count)  |  Reg remaining: $($regRemaining.Count)"

    $exitMeaning = Get-ExitMeaning -Code $exitCode
    $codeColor   = if ($exitCode -in @(0, 3010, 1614, 1641)) { 'Green' } else { 'Red' }

    # -- Auto-save JSON --------------------------------------------------------
    $watchUninstallDir  = Split-Path $installerJsonPath -Parent
    $watchUninstallFile = Join-Path $watchUninstallDir "Watch_Uninstaller_${safeAppName}.json"

    $uninstallRecord = [ordered]@{
        Type                        = 'Uninstall'
        GeneratedAt                 = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Meta = [ordered]@{
            ScriptVersion           = '2.0'
            Mode                    = 'JSON'
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
        $watchUninstallFile = "(save failed)"
    }

# ==============================================================================
# ── MODE B: STANDALONE ────────────────────────────────────────────────────────
# ==============================================================================
} elseif ($modeChoice -eq 'B') {

    Write-Host "  STEP 1 -- Select the app to uninstall" -ForegroundColor White
    Write-Host "  Loading installed apps from registry..." -ForegroundColor DarkGray
    Write-Host ""

    $allApps = Get-InstalledApps
    if ($allApps.Count -eq 0) {
        Write-Host "  No installed apps found in registry. Exiting." -ForegroundColor Red
        exit 1
    }

    # Filter loop
    $filteredApps = $allApps
    do {
        Write-Host "  Type a filter to narrow the list, or press Enter to show all ($($filteredApps.Count) apps):" -ForegroundColor DarkGray
        Write-Host "  Filter > " -ForegroundColor White -NoNewline
        $filterStr = (Read-Host).Trim()

        if ($filterStr) {
            $filteredApps = @($allApps | Where-Object { $_.DisplayName -like "*$filterStr*" })
            if ($filteredApps.Count -eq 0) {
                Write-Host "  No apps matched '$filterStr'. Try a broader term." -ForegroundColor Yellow
                $filteredApps = $allApps
                continue
            }
        } else {
            $filteredApps = $allApps
        }

        Write-Host ""
        $i = 1
        foreach ($app in $filteredApps) {
            $ver = if ($app.DisplayVersion) { "  v$($app.DisplayVersion)" } else { "" }
            Write-Host ("  [{0,3}]  {1}{2}" -f $i, $app.DisplayName, $ver) -ForegroundColor White
            $i++
        }
        Write-Host ""
        Write-Host "  Enter number to select, or type a new filter term > " -ForegroundColor White -NoNewline
        $selInput = (Read-Host).Trim()

        $selNum = 0
        if ([int]::TryParse($selInput, [ref]$selNum) -and $selNum -ge 1 -and $selNum -le $filteredApps.Count) {
            $selectedApp = $filteredApps[$selNum - 1]
            break
        } elseif ($selInput) {
            # Treat as a new filter
            $filteredApps = @($allApps | Where-Object { $_.DisplayName -like "*$selInput*" })
            if ($filteredApps.Count -eq 0) {
                Write-Host "  No apps matched '$selInput'. Try a broader term." -ForegroundColor Yellow
                $filteredApps = $allApps
            } elseif ($filteredApps.Count -eq 1) {
                $selectedApp = $filteredApps[0]
                break
            }
        }
    } while ($true)

    $appName    = $selectedApp.DisplayName
    $appVersion = $selectedApp.DisplayVersion
    $safeAppName = ($appName -replace '[^a-zA-Z0-9]+', '_').Trim('_')

    Write-Host ""
    Write-Host "  Selected: $appName$(if ($appVersion) { "  v$appVersion" })" -ForegroundColor Green
    Write-Host ""

    # -- Determine uninstall string --------------------------------------------
    Write-Host "  STEP 2 -- Uninstall method" -ForegroundColor White

    # Prefer QuietUninstallString for cleaner silent run, fall back to UninstallString
    $uninstallString = if ($selectedApp.QuietUninstallString) {
        $selectedApp.QuietUninstallString
    } else {
        $selectedApp.UninstallString
    }

    $UninstallerPath = $null
    $Arguments       = ''

    if ($uninstallString) {
        $stringLabel = if ($selectedApp.QuietUninstallString) { "QuietUninstallString (silent)" } else { "UninstallString" }
        Write-Host "  Detected $stringLabel`:" -ForegroundColor DarkGray
        Write-Host "  $uninstallString" -ForegroundColor White
        Write-Host ""
        Write-Host "  [U] Use detected string -- same as Add/Remove Programs (default)" -ForegroundColor DarkGray
        Write-Host "  [B] Browse for a different uninstaller exe" -ForegroundColor DarkGray
        Write-Host "  [M] Type path manually" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Choice > " -ForegroundColor White -NoNewline
        $methodChoice = (Read-Host).Trim()
        if ([string]::IsNullOrEmpty($methodChoice)) { $methodChoice = 'U' }
    } else {
        Write-Host "  No UninstallString found in registry for this app." -ForegroundColor Yellow
        Write-Host "  [B] Browse for uninstaller (default)   [M] Manual entry" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Choice > " -ForegroundColor White -NoNewline
        $methodChoice = (Read-Host).Trim()
        if ([string]::IsNullOrEmpty($methodChoice)) { $methodChoice = 'B' }
    }

    if ($methodChoice -match '^[Uu]' -and $uninstallString) {
        if ($uninstallString -match '^"([^"]+)"\s*(.*)$') {
            $UninstallerPath = $Matches[1]; $Arguments = $Matches[2].Trim()
        } elseif ($uninstallString -match '^(\S+\.exe)\s*(.*)$') {
            $UninstallerPath = $Matches[1]; $Arguments = $Matches[2].Trim()
        } else {
            $UninstallerPath = $uninstallString
        }
        Write-Host "  OK  Using: $UninstallerPath" -ForegroundColor Green
        if ($Arguments) { Write-Host "      Args : $Arguments" -ForegroundColor DarkGray }
        Write-Host "      (Equivalent to clicking Uninstall in Add/Remove Programs)" -ForegroundColor DarkGray

    } elseif ($methodChoice -match '^[Bb]') {
        $browseStart = if ($selectedApp.InstallLocation -and (Test-Path $selectedApp.InstallLocation)) {
            $selectedApp.InstallLocation
        } else { $env:ProgramFiles }
        $UninstallerPath = Select-ExeFile -InitialDir $browseStart
        if (-not $UninstallerPath) { Write-Host "  No file selected. Exiting." -ForegroundColor Yellow; exit 0 }
        Write-Host "  OK  Selected: $UninstallerPath" -ForegroundColor Green

    } else {
        Write-Host "  Enter full path to uninstaller > " -ForegroundColor White -NoNewline
        $UninstallerPath = (Read-Host).Trim()
        if (-not $UninstallerPath -or -not (Test-Path $UninstallerPath)) {
            Write-Host "  Path not found or empty. Exiting." -ForegroundColor Red; exit 1
        }
    }

    Write-Host ""
    Write-Host "  STEP 3 -- Additional uninstall arguments (optional)" -ForegroundColor White
    Write-Host "  Current: $(if ($Arguments) { $Arguments } else { '(none - may show UI)' })" -ForegroundColor DarkGray
    Write-Host "  Add more args, or press Enter to keep as-is > " -ForegroundColor White -NoNewline
    $extraArgs = (Read-Host).Trim()
    if ($extraArgs) { $Arguments = "$Arguments $extraArgs".Trim() }
    Write-Host ""

    # -- Build watch roots and take before snapshot ----------------------------
    Write-Host "  STEP 4 -- Taking before snapshot..." -ForegroundColor White

    $watchRoots = Get-AppWatchRoots -App $selectedApp

    if ($watchRoots.Count -gt 0) {
        Write-Host "  Watching these locations:" -ForegroundColor DarkGray
        foreach ($r in $watchRoots) { Write-Host "    $r" -ForegroundColor Gray }
    } else {
        Write-Host "  NOTE: No InstallLocation found. Watching all of Program Files and ProgramData." -ForegroundColor Yellow
        $watchRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    }
    Write-Host ""

    # Registry snapshot: all keys in uninstall hives before
    Write-Host "  Snapshotting registry..." -ForegroundColor DarkGray
    $regBefore = Get-RegistrySnapshot
    $regBeforePaths = @($regBefore | ForEach-Object { $_.Path })

    # Filesystem snapshot: all files in watch roots before
    Write-Host "  Snapshotting filesystem (this may take a moment)..." -ForegroundColor DarkGray
    $filesBefore = Get-FilesystemSnapshot -Roots $watchRoots
    Write-Host "  Snapshot complete: $($filesBefore.Count) files, $($regBefore.Count) registry keys" -ForegroundColor DarkGray
    Write-Host ""

    # -- Confirm ---------------------------------------------------------------
    $uninstallerName = Split-Path $UninstallerPath -Leaf
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f 'READY TO UNINSTALL  [STANDALONE MODE]') -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f '')                                       -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f "App        : $($appName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Uninstaller: $($uninstallerName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Arguments  : $(if ($Arguments) { $Arguments } else { '(none - may show UI)' })") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Watching   : $($watchRoots.Count) folder(s), $($filesBefore.Count) files") -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkMagenta
    Write-Host ""
    Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
    Read-Host | Out-Null

    Write-Log "===== WATCH-UNINSTALL v2.1 [STANDALONE MODE] STARTED ====="
    Write-Log "App         : $appName $appVersion"
    Write-Log "Uninstaller : $UninstallerPath"
    Write-Log "Arguments   : $(if ($Arguments) { $Arguments } else { '(none)' })"
    Write-Log "Watch roots : $($watchRoots -join ', ')"
    Write-Log "Snapshot    : $($filesBefore.Count) files, $($regBefore.Count) reg keys"

    # -- Run uninstaller -------------------------------------------------------
    $exitCode = Invoke-Uninstaller -UninstallerPath $UninstallerPath -Arguments $Arguments

    # -- Post-uninstall snapshot and diff --------------------------------------
    Write-Host ""
    Write-Host "  Taking after snapshot and comparing..." -ForegroundColor DarkGray

    $regAfter = Get-RegistrySnapshot
    $regAfterPaths = @($regAfter | ForEach-Object { $_.Path })

    $filesAfter = Get-FilesystemSnapshot -Roots $watchRoots

    # Diff
    $regRemoved   = @($regBeforePaths | Where-Object { $regAfterPaths -notcontains $_ })
    $regRemaining = @($regBeforePaths | Where-Object { $regAfterPaths -contains $_ -and $_ -match [regex]::Escape($appName.Split(' ')[0]) })
    # For remaining reg: only flag keys that look related to this app (avoid listing every unrelated app)
    $regAppRelated = @($regBefore | Where-Object {
        $v = $_.Values
        ($v.DisplayName -and $v.DisplayName -like "*$($appName.Split(' ')[0])*") -or
        ($v.Publisher -and $selectedApp.Publisher -and $v.Publisher -like "*$($selectedApp.Publisher.Split(' ')[0])*")
    } | ForEach-Object { $_.Path })
    $regRemaining = @($regAppRelated | Where-Object { $regAfterPaths -contains $_ })

    $filesRemoved   = @($filesBefore | Where-Object { $filesAfter -notcontains $_ })
    $filesRemaining = @($filesBefore | Where-Object { $filesAfter -contains $_ })

    Write-Log "After snapshot: $($filesAfter.Count) files, $($regAfter.Count) reg keys"
    Write-Log "Files removed: $($filesRemoved.Count)  |  Files remaining in watched paths: $($filesRemaining.Count)"
    Write-Log "Reg removed: $($regRemoved.Count)  |  App-related reg remaining: $($regRemaining.Count)"

    $exitMeaning = Get-ExitMeaning -Code $exitCode
    $codeColor   = if ($exitCode -in @(0, 3010, 1614, 1641)) { 'Green' } else { 'Red' }

    # -- Auto-save JSON --------------------------------------------------------
    $watchUninstallDir  = "$env:USERPROFILE\Downloads"
    $watchUninstallFile = Join-Path $watchUninstallDir "Watch_Uninstaller_${safeAppName}.json"

    $uninstallRecord = [ordered]@{
        Type        = 'Uninstall'
        GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Meta = [ordered]@{
            ScriptVersion   = '2.0'
            Mode            = 'Standalone'
            AppName         = $safeAppName
            UninstallerPath = $UninstallerPath
            UninstallerFile = $uninstallerName
            Arguments       = $Arguments
            ExitCode        = $exitCode
            ExitMeaning     = $exitMeaning
            IMELog          = $script:LogPath
            WatchRoots      = $watchRoots
        }
        AppInfo = [ordered]@{
            DisplayName    = $appName
            DisplayVersion = $appVersion
            Publisher      = $selectedApp.Publisher
            RegistryPath   = $selectedApp.RegistryPath
        }
        FilesWatchedBeforeUninstall = $filesBefore.Count
        FilesRemoved                = @($filesRemoved)
        FilesRemaining              = @($filesRemaining)
        RegistryKeysWatched         = $regBefore.Count
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
        $watchUninstallFile = "(save failed)"
    }

    # Use same variable names as JSON mode for the shared report section
    $filesBefore    = $null  # not needed below
    $uninstallerName = Split-Path $UninstallerPath -Leaf

# ==============================================================================
# ── MODE C: DIRECT STRING ─────────────────────────────────────────────────────
# ==============================================================================
} elseif ($modeChoice -eq 'C') {

    Write-Host "  STEP 1 -- Enter your full uninstall command" -ForegroundColor White
    Write-Host "  Paste the complete command exactly as you would run it." -ForegroundColor DarkGray
    Write-Host "  Examples:" -ForegroundColor DarkGray
    Write-Host "    setup.exe /s /f1`"C:\Temp\uninstall.iss`"" -ForegroundColor Gray
    Write-Host "    `"C:\Program Files\App\uninstall.exe`" /r /debuglog`"C:\Logs\uninstall.log`"" -ForegroundColor Gray
    Write-Host "    MsiExec.exe /X{GUID} /qn /norestart" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Command > " -ForegroundColor White -NoNewline
    $rawCommand = (Read-Host).Trim()

    if ([string]::IsNullOrWhiteSpace($rawCommand)) {
        Write-Host "  No command entered. Exiting." -ForegroundColor Red
        exit 1
    }

    # Parse exe + args out of the raw string
    if ($rawCommand -match '^"([^"]+)"\s*(.*)$') {
        $UninstallerPath = $Matches[1]
        $Arguments       = $Matches[2].Trim()
    } elseif ($rawCommand -match '^(\S+)\s+(.+)$') {
        $UninstallerPath = $Matches[1]
        $Arguments       = $Matches[2].Trim()
    } else {
        $UninstallerPath = $rawCommand
        $Arguments       = ''
    }

    # Validate the exe exists
    if (-not (Test-Path $UninstallerPath -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "  WARNING: Executable not found at: $UninstallerPath" -ForegroundColor Yellow
        Write-Host "  This may still work if the path is resolved at runtime (e.g. msiexec)." -ForegroundColor DarkGray
    } else {
        Write-Host "  OK  Exe found: $UninstallerPath" -ForegroundColor Green
    }
    if ($Arguments) { Write-Host "      Args : $Arguments" -ForegroundColor DarkGray }
    Write-Host ""

    # -- App label (used in report and filenames) ------------------------------
    Write-Host "  STEP 2 -- App name (for the report and output filename)" -ForegroundColor White
    Write-Host "  Enter a short name for the app being uninstalled, or press Enter to use" -ForegroundColor DarkGray
    Write-Host "  the executable filename." -ForegroundColor DarkGray
    Write-Host ""
    $uninstallerName = Split-Path $UninstallerPath -Leaf
    $defaultLabel    = [System.IO.Path]::GetFileNameWithoutExtension($uninstallerName)
    Write-Host "  App name [default: $defaultLabel] > " -ForegroundColor White -NoNewline
    $appNameInput = (Read-Host).Trim()
    $appName    = if ($appNameInput) { $appNameInput } else { $defaultLabel }
    $appVersion = ''
    $safeAppName = ($appName -replace '[^a-zA-Z0-9]+', '_').Trim('_')

    Write-Host ""

    # -- Watch roots -----------------------------------------------------------
    Write-Host "  STEP 3 -- Folders to watch (optional but recommended)" -ForegroundColor White
    Write-Host "  Enter the app's install folder so the script knows what to snapshot." -ForegroundColor DarkGray
    Write-Host "  You can enter multiple paths -- press Enter with a blank line when done." -ForegroundColor DarkGray
    Write-Host "  Press Enter immediately to watch Program Files + ProgramData (broader)." -ForegroundColor DarkGray
    Write-Host ""

    $manualRoots = [System.Collections.Generic.List[string]]::new()
    $pathNum = 1
    do {
        Write-Host "  Folder $pathNum (or Enter to finish) > " -ForegroundColor White -NoNewline
        $pathInput = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($pathInput)) { break }
        if (Test-Path $pathInput -ErrorAction SilentlyContinue) {
            $manualRoots.Add($pathInput.TrimEnd('\'))
            Write-Host "  OK  Added: $pathInput" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Path not found, skipping: $pathInput" -ForegroundColor Yellow
        }
        $pathNum++
    } while ($true)

    $watchRoots = if ($manualRoots.Count -gt 0) {
        $manualRoots
    } else {
        Write-Host "  No folders entered -- watching Program Files, Program Files (x86), and ProgramData." -ForegroundColor DarkGray
        @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    }

    Write-Host ""

    # -- Before snapshot -------------------------------------------------------
    Write-Host "  Taking before snapshot..." -ForegroundColor DarkGray
    Write-Host "  Watching: $($watchRoots -join ', ')" -ForegroundColor DarkGray

    $regBefore      = Get-RegistrySnapshot
    $regBeforePaths = @($regBefore | ForEach-Object { $_.Path })

    Write-Host "  Snapshotting filesystem (this may take a moment)..." -ForegroundColor DarkGray
    $filesBefore = Get-FilesystemSnapshot -Roots $watchRoots
    Write-Host "  Snapshot: $($filesBefore.Count) files, $($regBefore.Count) registry keys" -ForegroundColor DarkGray
    Write-Host ""

    # -- Confirm ---------------------------------------------------------------
    Write-Host "  ┌──────────────────────────────────────────────────────────┐" -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f 'READY TO UNINSTALL  [DIRECT STRING MODE]') -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f '')                                          -ForegroundColor DarkMagenta
    Write-Host ("  │  {0,-56}│" -f "App        : $($appName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Uninstaller: $($uninstallerName -replace '(.{42}).+','$1...')") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Arguments  : $(if ($Arguments) { ($Arguments -replace '(.{42}).+','$1...') } else { '(none)' })") -ForegroundColor White
    Write-Host ("  │  {0,-56}│" -f "Watching   : $($watchRoots.Count) folder(s), $($filesBefore.Count) files") -ForegroundColor White
    Write-Host "  └──────────────────────────────────────────────────────────┘" -ForegroundColor DarkMagenta
    Write-Host ""
    Write-Host "  Press Enter to start  |  Ctrl+C to cancel" -ForegroundColor DarkGray
    Read-Host | Out-Null

    Write-Log "===== WATCH-UNINSTALL v2.1 [DIRECT STRING MODE] STARTED ====="
    Write-Log "App         : $appName"
    Write-Log "Command     : $rawCommand"
    Write-Log "Uninstaller : $UninstallerPath"
    Write-Log "Arguments   : $(if ($Arguments) { $Arguments } else { '(none)' })"
    Write-Log "Watch roots : $($watchRoots -join ', ')"
    Write-Log "Snapshot    : $($filesBefore.Count) files, $($regBefore.Count) reg keys"

    # -- Run uninstaller -------------------------------------------------------
    $exitCode = Invoke-Uninstaller -UninstallerPath $UninstallerPath -Arguments $Arguments

    # -- Post-uninstall snapshot and diff --------------------------------------
    Write-Host ""
    Write-Host "  Taking after snapshot and comparing..." -ForegroundColor DarkGray

    $regAfter      = Get-RegistrySnapshot
    $regAfterPaths = @($regAfter | ForEach-Object { $_.Path })
    $filesAfter    = Get-FilesystemSnapshot -Roots $watchRoots

    $regRemoved   = @($regBeforePaths | Where-Object { $regAfterPaths -notcontains $_ })
    $regRemaining = @()   # Can't know which remaining keys are app-related without registry data

    $filesRemoved   = @($filesBefore | Where-Object { $filesAfter -notcontains $_ })
    $filesRemaining = @($filesBefore | Where-Object { $filesAfter -contains $_ })

    # Registry remnant scan -- searches hives for any key or value still
    # referencing the app name after the uninstaller ran
    Write-Host "  Scanning registry for remnants of '$appName'..." -ForegroundColor DarkGray
    $regRemnants = @(Search-RegistryRemnants -SearchTerm $appName)
    Write-Host "  Registry remnant scan complete: $($regRemnants.Count) match(es) found." -ForegroundColor DarkGray

    Write-Log "After snapshot: $($filesAfter.Count) files, $($regAfter.Count) reg keys"
    Write-Log "Files removed: $($filesRemoved.Count)  |  Files remaining: $($filesRemaining.Count)"
    Write-Log "Reg removed: $($regRemoved.Count)  |  Registry remnants found: $($regRemnants.Count)"

    $exitMeaning = Get-ExitMeaning -Code $exitCode
    $codeColor   = if ($exitCode -in @(0, 3010, 1614, 1641)) { 'Green' } else { 'Red' }

    # -- Auto-save JSON --------------------------------------------------------
    $watchUninstallDir  = "$env:USERPROFILE\Downloads"
    $watchUninstallFile = Join-Path $watchUninstallDir "Watch_Uninstaller_${safeAppName}.json"

    $uninstallRecord = [ordered]@{
        Type        = 'Uninstall'
        GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Meta = [ordered]@{
            ScriptVersion   = '2.0'
            Mode            = 'Direct'
            AppName         = $safeAppName
            RawCommand      = $rawCommand
            UninstallerPath = $UninstallerPath
            UninstallerFile = $uninstallerName
            Arguments       = $Arguments
            ExitCode        = $exitCode
            ExitMeaning     = $exitMeaning
            IMELog          = $script:LogPath
            WatchRoots      = $watchRoots
        }
        AppInfo = [ordered]@{
            DisplayName    = $appName
            DisplayVersion = ''
        }
        FilesWatchedBeforeUninstall = $filesBefore.Count
        FilesRemoved                = @($filesRemoved)
        FilesRemaining              = @($filesRemaining)
        RegistryKeysWatched         = $regBefore.Count
        RegistryKeysRemoved         = @($regRemoved)
        RegistryKeysRemaining       = @($regRemaining)
        RegistryRemnants            = @($regRemnants)
    }

    try {
        $uninstallRecord | ConvertTo-Json -Depth 10 |
            Set-Content -Path $watchUninstallFile -Encoding UTF8 -ErrorAction Stop
        Write-Log "Watch_Uninstaller data saved to: $watchUninstallFile"
    }
    catch {
        Write-Log "Failed to save Watch_Uninstaller JSON: $_" 'WARN'
        $watchUninstallFile = "(save failed)"
    }

    $filesBefore = $null  # not needed in shared report

} else {
    Write-Host "  Invalid choice. Exiting." -ForegroundColor Red
    exit 1
}

# ==============================================================================
# REGION: SHARED REPORT (both modes)
# ==============================================================================
Show-Banner
$modeLabel = switch ($modeChoice) {
    'A' { 'JSON MODE' }
    'B' { 'STANDALONE MODE' }
    'C' { 'DIRECT STRING MODE' }
}
Write-ReportHeader "UNINSTALL REPORT  [$modeLabel]  --  $appName $(if ($appVersion) { "v$appVersion" })"

Write-ReportSection "EXIT CODE"
Write-ReportItem '>' "Exit Code  : $exitCode" $codeColor
Write-ReportItem '>' "Meaning    : $exitMeaning" $codeColor

Write-ReportSection "REGISTRY  --  REMOVED  ($($regRemoved.Count))"
if ($regRemoved.Count -gt 0) {
    foreach ($key in $regRemoved) { Write-ReportItem '[REM]' $key 'Green' }
} else {
    Write-ReportItem '!' "No registry keys were removed." 'Yellow'
}

if ($modeChoice -eq 'A') {
    Write-ReportSection "REGISTRY  --  REMAINING / NOT CLEANED UP  ($($regRemaining.Count))"
    if ($regRemaining.Count -gt 0) {
        foreach ($key in $regRemaining) { Write-ReportItem '[LEFT]' $key 'Red' }
        Write-Host ""
        Write-ReportSubItem "These keys were installed but NOT removed by the uninstaller." 'Yellow'
    } else {
        Write-ReportItem 'OK' "All tracked registry keys were removed." 'Green'
    }
} elseif ($modeChoice -eq 'B') {
    Write-ReportSection "REGISTRY  --  APP-RELATED KEYS STILL PRESENT  ($($regRemaining.Count))"
    if ($regRemaining.Count -gt 0) {
        foreach ($key in $regRemaining) { Write-ReportItem '[LEFT]' $key 'Red' }
        Write-ReportSubItem "These app-related registry keys were NOT removed." 'Yellow'
    } else {
        Write-ReportItem 'OK' "No app-related registry keys remain." 'Green'
    }
} elseif ($modeChoice -eq 'C') {
    Write-ReportSection "REGISTRY  --  KEYS REMOVED BY UNINSTALLER  ($($regRemoved.Count))"
    if ($regRemoved.Count -gt 0) {
        foreach ($key in $regRemoved) { Write-ReportItem '[REM]' $key 'Green' }
    } else {
        Write-ReportItem '!' "No registry keys were removed from uninstall hives." 'Yellow'
    }

    Write-ReportSection "REGISTRY  --  REMNANT SCAN  ($($regRemnants.Count) match(es) for '$appName')"
    if ($regRemnants.Count -gt 0) {
        $regRemnants | Group-Object -Property RegistryPath | ForEach-Object {
            Write-ReportItem '[LEFT]' ($_.Name -replace '^HKEY_LOCAL_MACHINE','HKLM:' -replace '^HKEY_CURRENT_USER','HKCU:') 'Red'
            $_.Group | ForEach-Object {
                if ($_.MatchType -eq 'Key name') {
                    Write-ReportSubItem "(key path matches app name)" 'Yellow'
                } else {
                    Write-ReportSubItem $_.MatchDetail 'Yellow'
                }
            }
            Write-Host ""
        }
        Write-ReportSubItem "These registry entries still reference '$appName' after uninstall." 'Yellow'
        Write-ReportSubItem "They may need manual cleanup or can be added to the uninstall script." 'DarkGray'
    } else {
        Write-ReportItem 'OK' "No registry remnants found matching '$appName'." 'Green'
    }
}

Write-ReportSection "FILES  --  REMOVED  ($($filesRemoved.Count))"
if ($filesRemoved.Count -gt 0) {
    $filesRemoved | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[REM]' $_.Name 'Green'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Gray' }
        Write-Host ""
    }
} else {
    Write-ReportItem '!' "No tracked files were removed." 'Yellow'
}

$remainLabel = switch ($modeChoice) {
    'A' { "FILES  --  REMAINING / NOT CLEANED UP  ($($filesRemaining.Count))" }
    'B' { "FILES  --  STILL PRESENT IN WATCHED FOLDERS  ($($filesRemaining.Count))" }
    'C' { "FILES  --  STILL PRESENT IN WATCHED FOLDERS  ($($filesRemaining.Count))" }
}
Write-ReportSection $remainLabel
if ($filesRemaining.Count -gt 0) {
    $filesRemaining | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
        Write-ReportItem '[LEFT]' $_.Name 'Red'
        $_.Group | ForEach-Object { Write-ReportSubItem (Split-Path $_ -Leaf) 'Yellow' }
        Write-Host ""
    }
    if ($modeChoice -eq 'A') {
        Write-ReportSubItem "These files were installed but NOT removed by the uninstaller." 'Yellow'
        Write-ReportSubItem "Run Compare-WatchReports.ps1 for the full leftover diff report." 'DarkGray'
    } else {
        Write-ReportSubItem "These files existed before the uninstall and still exist after." 'Yellow'
        Write-ReportSubItem "They may be app files the uninstaller left behind, or unrelated files" 'DarkGray'
        Write-ReportSubItem "in the same folder. Review the list above carefully." 'DarkGray'
    }
} else {
    Write-ReportItem 'OK' "$(if ($modeChoice -eq 'A') { 'All tracked files were removed.' } else { 'All files in watched folders were removed.' })" 'Green'
}

Write-ReportSection "SUMMARY"
Write-ReportItem '>' "App             : $appName$(if ($appVersion) { " v$appVersion" })" 'White'
Write-ReportItem '>' "Uninstaller     : $uninstallerName" 'White'
Write-ReportItem '>' "Mode            : $modeLabel" 'White'
Write-ReportItem '>' "Exit Code       : $exitCode  ($exitMeaning)" $codeColor
Write-ReportItem '>' "Files Removed   : $($filesRemoved.Count)" $(if ($filesRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Files Remaining : $($filesRemaining.Count)" $(if ($filesRemaining.Count -gt 0) { 'Red' } else { 'Green' })
Write-ReportItem '>' "Reg Removed     : $($regRemoved.Count)" $(if ($regRemaining.Count -eq 0) { 'Green' } else { 'Yellow' })
Write-ReportItem '>' "Reg Remaining   : $($regRemaining.Count)" $(if ($regRemaining.Count -gt 0) { 'Red' } else { 'Green' })
if ($modeChoice -eq 'C') {
    Write-ReportItem '>' "Reg Remnants    : $($regRemnants.Count)  (entries still referencing '$appName')" $(if ($regRemnants.Count -gt 0) { 'Red' } else { 'Green' })
}
Write-ReportItem '>' "Watch data file : $watchUninstallFile" 'DarkGray'
Write-ReportItem '>' "Log saved to    : $script:LogPath" 'DarkGray'

Write-Host ""
Write-Host "  ════════════════════════════════════════════════════════════" -ForegroundColor DarkMagenta

# ==============================================================================
# REGION: OPTIONAL TEXT REPORT SAVE (both modes)
# ==============================================================================
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

        $reportLines.Add("WATCH-UNINSTALL v2.1 [$modeLabel] - UNINSTALL REPORT")
        $reportLines.Add("Generated        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        $reportLines.Add("App              : $appName$(if ($appVersion) { " v$appVersion" })")
        $reportLines.Add("Uninstaller      : $UninstallerPath")
        $reportLines.Add("Arguments        : $(if ($Arguments) { $Arguments } else { '(none)' })")
        $reportLines.Add("Exit Code        : $exitCode  ($exitMeaning)")
        $reportLines.Add("IME Log          : $script:LogPath")
        $reportLines.Add("Watch data file  : $watchUninstallFile")
        $reportLines.Add("")
        $reportLines.Add(('-' * 64))
        $reportLines.Add("")
        $reportLines.Add("REGISTRY KEYS REMOVED  ($($regRemoved.Count))")
        $reportLines.Add(('-' * 64))
        if ($regRemoved.Count -gt 0) { foreach ($k in $regRemoved) { $reportLines.Add("  [REM]  $k") } }
        else { $reportLines.Add("  (none)") }
        $reportLines.Add("")
        $reportLines.Add("REGISTRY KEYS REMAINING  ($($regRemaining.Count))")
        $reportLines.Add(('-' * 64))
        if ($regRemaining.Count -gt 0) { foreach ($k in $regRemaining) { $reportLines.Add("  [LEFT] $k") } }
        else { $reportLines.Add("  (all clean)") }
        $reportLines.Add("")
        # Mode C: include remnant scan in text report
        if ($modeChoice -eq 'C') {
            $reportLines.Add("REGISTRY REMNANT SCAN -- entries still referencing '$appName'  ($($regRemnants.Count))")
            $reportLines.Add(('-' * 64))
            if ($regRemnants.Count -gt 0) {
                $regRemnants | Group-Object -Property RegistryPath | ForEach-Object {
                    $reportLines.Add("  [LEFT] $($_.Name)")
                    $_.Group | ForEach-Object {
                        if ($_.MatchType -eq 'Key name') { $reportLines.Add("         (key path matches app name)") }
                        else { $reportLines.Add("         $($_.MatchDetail)") }
                    }
                    $reportLines.Add("")
                }
            } else { $reportLines.Add("  (no remnants found)") }
            $reportLines.Add("")
        }
        $reportLines.Add("FILES REMOVED  ($($filesRemoved.Count))")
        $reportLines.Add(('-' * 64))
        if ($filesRemoved.Count -gt 0) {
            $filesRemoved | Group-Object -Property { Split-Path $_ -Parent } | ForEach-Object {
                $reportLines.Add("  [DIR] $($_.Name)")
                $_.Group | ForEach-Object { $reportLines.Add("        $(Split-Path $_ -Leaf)") }
                $reportLines.Add("")
            }
        } else { $reportLines.Add("  (none)") }
        $reportLines.Add("")
        $reportLines.Add("FILES REMAINING  ($($filesRemaining.Count))")
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
        $reportLines.Add("  App             : $appName$(if ($appVersion) { " v$appVersion" })")
        $reportLines.Add("  Mode            : $modeLabel")
        $reportLines.Add("  Exit Code       : $exitCode  ($exitMeaning)")
        $reportLines.Add("  Files Removed   : $($filesRemoved.Count)")
        $reportLines.Add("  Files Remaining : $($filesRemaining.Count)")
        $reportLines.Add("  Reg Removed     : $($regRemoved.Count)")
        $reportLines.Add("  Reg Remaining   : $($regRemaining.Count)")
        if ($modeChoice -eq 'C') {
            $reportLines.Add("  Reg Remnants    : $($regRemnants.Count)  (entries still referencing '$appName')")
        }
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
