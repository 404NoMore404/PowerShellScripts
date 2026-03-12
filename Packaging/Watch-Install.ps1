# ==============================================================================
# Watch-Install.ps1
# Purpose  : Runs an installer and monitors everything it does in real time.
#            Useful for manually observing installs before packaging for Intune.
#            Run this on a clean test machine or snapshot VM before packaging.
#
# TIP      : The DisplayName and DisplayVersion values printed in the registry
#            diff output are the exact values written by the installer. Copy the
#            DisplayName and wrap it in wildcards (e.g. "*7-Zip*") to use as
#            $DisplayNameFilter in Detect-APPNAME.ps1 and as $DetectionNameFilter
#            in Invoke-IntuneInstall.ps1. This is the recommended way to populate
#            both detection scripts without guessing.
#
# Usage    : .\Watch-Install.ps1 -InstallerPath ".\setup.exe" -Arguments "/VERYSILENT" -WatchRegistry -WatchFiles
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.2
# Changelog:
#   1.2 - Fixed ArgumentList validation error when no arguments are supplied.
#         Start-Process rejects an empty string for -ArgumentList; both the
#         primary and fallback launch paths now only include ArgumentList when
#         the caller actually provided a value. Resolves crash with stub
#         installers (e.g. ChromeSetup.exe) that also reject stream redirection.
#   1.1 - Initial tracked release.
# ==============================================================================

param(
    [Parameter(Mandatory)]
    [string]$InstallerPath,

    # [CHANGE ME] - Set default Arguments to your most common silent switch if
    #               you want a default fallback. Leave empty to force you to
    #               always supply args explicitly (safer for testing).
    [string]$Arguments = '',

    # Log destination — must stay in IME logs path for Intune diagnostic collection.
    # [CHANGE ME] - The prefix "PKG_" groups your logs together. Change to match
    #               whatever prefix you set in the other scripts.
    [string]$LogPath = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_WatchInstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log",

    # Switch flags — pass -WatchRegistry and/or -WatchFiles to enable snapshots.
    [switch]$WatchRegistry,
    [switch]$WatchFiles
)

# ==============================================================================
# REGION: LOGGING
# ==============================================================================
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

# ==============================================================================
# REGION: SNAPSHOT HELPERS
# ------------------------------------------------------------------------------
# These functions take a before/after snapshot of registry uninstall keys and
# top-level program directories so you can see exactly what changed.
#
# The DisplayName and DisplayVersion values logged in the registry diff are
# exactly what the installer registered. Use them directly:
#   - Detect-APPNAME.ps1      : set $DisplayNameFilter = "*<DisplayName>*"
#   - Invoke-IntuneInstall.ps1: set $DetectionNameFilter = "*<DisplayName>*"
#
# [CHANGE ME] - $registryKeys contains the standard uninstall hives. If your
#               environment uses additional registry locations for app tracking
#               or a custom software inventory key, add those paths here.
# ==============================================================================
function Get-RegistrySnapshot {
    $registryKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        # [CHANGE ME] - Add any additional registry hives relevant to your environment here.
        # Example: 'HKLM:\SOFTWARE\YourOrg\InstalledApps'
    )
    $snapshot = @{}
    foreach ($key in $registryKeys) {
        Get-ChildItem $key -ErrorAction SilentlyContinue | ForEach-Object {
            $snapshot[$_.PSPath] = $_
        }
    }
    return $snapshot
}

function Get-ProgramFilesSnapshot {
    # [CHANGE ME] - $watchPaths contains the directories monitored for new folders
    #               dropped by the installer. Add any additional paths your org
    #               uses for software installs (e.g. a custom D:\Apps directory).
    $watchPaths = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:LocalAppData,
        $env:AppData
        # [CHANGE ME] - Example: 'D:\Applications'
    )
    $snapshot = @{}
    foreach ($path in $watchPaths) {
        if (Test-Path $path) {
            Get-ChildItem $path -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $snapshot[$_.FullName] = $_.LastWriteTime
            }
        }
    }
    return $snapshot
}

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Write-Log "===== WATCH-INSTALL STARTED ====="
Write-Log "Installer : $InstallerPath"
Write-Log "Arguments : $(if($Arguments){'(' + $Arguments + ')'}else{'(none supplied — installer may launch GUI)'} )"
Write-Log "Log File  : $LogPath"
Write-Log "WatchReg  : $WatchRegistry  |  WatchFiles: $WatchFiles"

if (-not (Test-Path $InstallerPath)) {
    Write-Log "Installer not found: $InstallerPath" 'ERROR'
    exit 1
}

# --- Pre-install snapshots ---
if ($WatchRegistry) {
    Write-Log "Taking registry snapshot (before)..."
    $regBefore = Get-RegistrySnapshot
    Write-Log "Registry snapshot captured — $($regBefore.Count) existing uninstall keys."
}

if ($WatchFiles) {
    Write-Log "Taking filesystem snapshot (before)..."
    $fsBefore = Get-ProgramFilesSnapshot
    Write-Log "Filesystem snapshot captured — $($fsBefore.Count) existing top-level directories."
}

# --- Build launch parameters ---
$ext = [System.IO.Path]::GetExtension($InstallerPath).ToLower()

$procParams = @{
    Wait                   = $true
    PassThru               = $true
    NoNewWindow            = $true
    RedirectStandardOutput = "$env:TEMP\PKG_stdout.txt"
    RedirectStandardError  = "$env:TEMP\PKG_stderr.txt"
}

if ($ext -eq '.msi') {
    # MSI must be launched via msiexec, not directly.
    # /i "<path>" is always required; append caller-supplied args if provided.
    $procParams.FilePath = 'msiexec.exe'
    $msiArgs = "/i `"$InstallerPath`""
    if ($Arguments) { $msiArgs += " $Arguments" }
    $procParams.ArgumentList = $msiArgs
} else {
    $procParams.FilePath = $InstallerPath
    # FIX (v1.2): Only add ArgumentList when the caller actually supplied
    # something. Start-Process throws a validation error if ArgumentList is
    # an empty string, which crashes stub installers that also reject stream
    # redirection (e.g. ChromeSetup.exe), preventing the fallback from working.
    if ($Arguments) {
        $procParams.ArgumentList = $Arguments
    }
}

Write-Log "Launching installer..."

# --- Execute ---
try {
    $proc = Start-Process @procParams -ErrorAction Stop
}
catch {
    # Some installers reject stdout/stderr redirection (GUI-only or stub installers).
    # Fall back to a plain launch and just capture the exit code.
    Write-Log "Redirected stdout/stderr launch failed. Falling back to direct launch (no stream capture)." 'WARN'
    Write-Log "Reason: $_" 'WARN'

    # FIX (v1.2): Build fallback params independently and only include
    # ArgumentList if it was actually set in $procParams — avoids the same
    # empty-string validation error that triggered the fallback in the first place.
    $fallbackParams = @{
        FilePath = $procParams.FilePath
        Wait     = $true
        PassThru = $true
    }
    if ($procParams.ContainsKey('ArgumentList')) {
        $fallbackParams.ArgumentList = $procParams.ArgumentList
    }

    $proc = Start-Process @fallbackParams -ErrorAction Stop
}

$exitCode = $proc.ExitCode
Write-Log "Installer process exited. Exit code: $exitCode" $(if ($exitCode -eq 0) { 'SUCCESS' } else { 'WARN' })

# --- Capture stdout / stderr output if available ---
foreach ($stream in @('stdout', 'stderr')) {
    $streamFile = "$env:TEMP\PKG_$stream.txt"
    if (Test-Path $streamFile) {
        $streamContent = Get-Content $streamFile -Raw -ErrorAction SilentlyContinue
        if ($streamContent -and $streamContent.Trim()) {
            Write-Log "[$stream output]:" 'INFO'
            Write-Log $streamContent.Trim()
        }
        Remove-Item $streamFile -Force -ErrorAction SilentlyContinue
    }
}

# --- Post-install registry diff ---
if ($WatchRegistry) {
    Write-Log "--- REGISTRY CHANGES (new uninstall keys added) ---" 'INFO'
    $regAfter = Get-RegistrySnapshot
    $newKeys  = $regAfter.Keys | Where-Object { -not $regBefore.ContainsKey($_) }

    if ($newKeys) {
        foreach ($key in $newKeys) {
            $keyData = $regAfter[$key]
            Write-Log "NEW KEY  : $key" 'SUCCESS'

            # DisplayName and DisplayVersion are the values to use in your detection scripts.
            # Copy DisplayName and wrap in wildcards for $DisplayNameFilter / $DetectionNameFilter.
            $dispName = $keyData.GetValue('DisplayName')
            $dispVer  = $keyData.GetValue('DisplayVersion')
            if ($dispName) { Write-Log "  DisplayName    : $dispName  <-- use as: `"*$dispName*`"" 'SUCCESS' }
            if ($dispVer)  { Write-Log "  DisplayVersion : $dispVer" 'SUCCESS' }
        }
    } else {
        Write-Log "No new uninstall registry keys detected." 'WARN'
        Write-Log "App may not write to standard uninstall hives. Consider File detection method instead." 'WARN'
    }
}

# --- Post-install filesystem diff ---
if ($WatchFiles) {
    Write-Log "--- FILESYSTEM CHANGES (new top-level directories) ---" 'INFO'
    $fsAfter = Get-ProgramFilesSnapshot
    $newDirs  = $fsAfter.Keys | Where-Object { -not $fsBefore.ContainsKey($_) }

    if ($newDirs) {
        foreach ($dir in $newDirs) {
            Write-Log "NEW DIR  : $dir" 'SUCCESS'
        }
    } else {
        Write-Log "No new top-level directories detected in watched paths." 'WARN'
    }
}

# ==============================================================================
# REGION: EXIT CODE TRANSLATION
# ------------------------------------------------------------------------------
# [CHANGE ME] - Add any vendor-specific exit codes you encounter here.
#               Some applications use non-standard exit codes for things like
#               "already installed" or "reboot needed" that differ from MSI.
# ==============================================================================
$exitMeaning = switch ($exitCode) {
    0    { 'Success' }
    1    { 'General error' }
    2    { 'File not found or bad arguments' }
    3010 { 'Success — REBOOT REQUIRED' }
    1602 { 'User cancelled the installation' }
    1603 { 'Fatal error during MSI installation — check MSI log' }
    1618 { 'Another MSI installation is already in progress' }
    1619 { 'Installation package could not be opened' }
    1624 { 'Error applying transforms' }
    1638 { 'Another version of this app is already installed' }
    1641 { 'Reboot initiated by installer' }
    # [CHANGE ME] - Add vendor-specific codes below as you encounter them.
    # Example: 5 { 'Vendor XYZ: License validation failed' }
    default { "Unknown exit code — consult installer documentation" }
}

Write-Log "Exit Code Translation: $exitCode = $exitMeaning" $(
    if ($exitCode -in @(0, 3010, 1641)) { 'SUCCESS' } else { 'ERROR' }
)

Write-Log "===== WATCH-INSTALL COMPLETE — Log saved to: $LogPath ====="
