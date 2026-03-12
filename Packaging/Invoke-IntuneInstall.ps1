# ==============================================================================
# Invoke-IntuneInstall.ps1
# Purpose  : Universal Intune Win32 app install/uninstall wrapper.
#            Drop this alongside your installer in every package folder.
#            Fill in the CONFIG REGION below for each new application.
# Usage    : .\Invoke-IntuneInstall.ps1
#            .\Invoke-IntuneInstall.ps1 -IsUninstall
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.1
# ==============================================================================

param(
    # [CHANGE ME] - You can hardcode $InstallerFile here or leave it blank to
    #               use auto-detection (script will find the first .msi or .exe
    #               in the same folder). Hardcoding is safer for packages that
    #               contain multiple executables.
    [string]$InstallerFile = '',

    # [CHANGE ME] - $InstallerArgs is your silent switch string.
    #               Leave blank to use the defaults (/quiet /norestart for EXE,
    #               /qn /norestart for MSI). Override here with app-specific args.
    # Examples:
    #   Inno Setup  : '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
    #   NSIS        : '/S'
    #   InstallShield: '/s /v"/qn /norestart"'
    [string]$InstallerArgs = '',

    # [CHANGE ME] - $UninstallArgs is used when running with -IsUninstall.
    #               For MSI this is handled automatically. For EXE uninstallers
    #               you will need to supply the correct args.
    # Examples:
    #   Inno Setup  : '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
    #   NSIS        : '/S'
    [string]$UninstallArgs = '',

    # Switch to trigger uninstall mode instead of install.
    [switch]$IsUninstall
)

# ==============================================================================
# REGION: APP CONFIG — FILL THIS OUT PER PACKAGE
# ------------------------------------------------------------------------------
# [CHANGE ME] - These values are used in log file names and output messages.
#               Set them for every package you create. Do not leave defaults.
# ==============================================================================
$AppName    = "AppNameHere"       # [CHANGE ME] e.g. "7-Zip", "Adobe Reader"
$AppVersion = "0.0.0"             # [CHANGE ME] e.g. "24.1.0"
$AppVendor  = "VendorNameHere"    # [CHANGE ME] e.g. "Adobe", "Microsoft"

# ==============================================================================
# REGION: LOGGING CONFIGURATION
# ------------------------------------------------------------------------------
# Log directory is fixed to the IME logs path so Intune Diagnostic Collection
# always picks up your packaging logs alongside the built-in IME logs.
#
# [CHANGE ME] - "PKG_" is the log file prefix. Change this to your org's prefix
#               if desired (e.g. "CORP_", "IT_"). Keep consistent across all
#               three scripts so logs group together alphabetically.
#
# DO NOT change $LogDir unless Microsoft changes the Intune diagnostic
# collection scope. Moving logs outside this path means they won't be
# collected when you run "Collect diagnostics" in the Intune portal.
# ==============================================================================
$LogDir  = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
$Mode    = if ($IsUninstall) { 'Uninstall' } else { 'Install' }
$LogFile = Join-Path $LogDir "PKG_${Mode}_${AppName}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$MSILog  = Join-Path $LogDir "PKG_${AppName}_msi.log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# ==============================================================================
# REGION: LOGGING FUNCTION
# ==============================================================================
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Msg"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    Write-Output $line
}

# ==============================================================================
# REGION: HEADER
# ==============================================================================
Write-Log "=============================="
Write-Log "App     : $AppName $AppVersion ($AppVendor)"
Write-Log "Mode    : $Mode"
Write-Log "Script  : $PSCommandPath"
Write-Log "User    : $env:USERNAME  |  Machine: $env:COMPUTERNAME"
Write-Log "OS      : $([System.Environment]::OSVersion.VersionString)"
Write-Log "=============================="

# ==============================================================================
# REGION: INSTALLER AUTO-DETECTION
# ------------------------------------------------------------------------------
# If $InstallerFile is not hardcoded in the params, the script searches the
# folder it is running from for the first .msi or .exe that doesn't look like
# an uninstaller.
#
# [CHANGE ME] - The -Exclude pattern 'uninstall*' covers most cases but some
#               vendors name their uninstaller differently (e.g. "remove.exe",
#               "uninst.exe"). Add additional exclusion patterns as needed.
# ==============================================================================
if (-not $InstallerFile) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    $installer = Get-ChildItem $scriptDir -Include '*.msi', '*.exe' -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch '(?i)(uninstall|uninst|remove|cleanup)' } |
                 # [CHANGE ME] - Add additional exclusion patterns above if your package
                 #               folder contains helper EXEs that aren't the main installer.
                 Select-Object -First 1

    if (-not $installer) {
        Write-Log "No installer (.msi or .exe) found in $scriptDir" 'ERROR'
        exit 1
    }
    $InstallerFile = $installer.FullName
}

Write-Log "Installer: $InstallerFile"

# ==============================================================================
# REGION: UNINSTALL PATH RESOLUTION
# ------------------------------------------------------------------------------
# For MSI uninstalls the product code is the cleanest approach.
# For EXE uninstallers you need to know the uninstall string from the registry
# or ship a dedicated uninstaller in your package.
#
# [CHANGE ME] - $MSIProductCode: Set this to your MSI's product code GUID if
#               you want a reliable MSI uninstall that doesn't depend on the
#               original .msi file being present on the endpoint.
#               Find it by running: (Get-Item .\installer.msi).Property or
#               checking HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall
#               Leave blank to use the installer file path instead of GUID.
#
# [CHANGE ME] - $EXEUninstallPath: For EXE-based uninstallers, set this to the
#               full path of the uninstaller on the endpoint (not your package).
#               Example: "C:\Program Files\AppName\uninstall.exe"
# ==============================================================================
$MSIProductCode   = ""            # [CHANGE ME] e.g. "{12345678-ABCD-1234-ABCD-1234567890AB}"
$EXEUninstallPath = ""            # [CHANGE ME] e.g. "C:\Program Files\AppName\uninstall.exe"

# ==============================================================================
# REGION: BUILD COMMAND
# ==============================================================================
$ext = [System.IO.Path]::GetExtension($InstallerFile).ToLower()
$exe = ''
$args = ''

if ($ext -eq '.msi') {

    $exe = 'msiexec.exe'

    if ($IsUninstall) {
        # Use product code GUID for uninstall if supplied, otherwise use file path
        $target = if ($MSIProductCode) { $MSIProductCode } else { "`"$InstallerFile`"" }
        $args   = "/x $target /qn /norestart /l*v `"$MSILog`""
        if ($UninstallArgs) { $args += " $UninstallArgs" }
    } else {
        $args = "/i `"$InstallerFile`" /qn /norestart /l*v `"$MSILog`""
        if ($InstallerArgs) { $args += " $InstallerArgs" }
    }

} elseif ($ext -eq '.exe') {

    if ($IsUninstall) {
        # Use dedicated uninstall EXE path if supplied, otherwise try the installer with uninstall args
        if ($EXEUninstallPath -and (Test-Path $EXEUninstallPath)) {
            $exe  = $EXEUninstallPath
            $args = if ($UninstallArgs) { $UninstallArgs } else { '/quiet /norestart' }
            # [CHANGE ME] - Default '/quiet /norestart' may not work for all uninstallers.
            #               Test on a real machine and supply correct $UninstallArgs in params.
        } else {
            Write-Log "EXE uninstall: no EXEUninstallPath set and no dedicated uninstaller found." 'WARN'
            Write-Log "Attempting uninstall via registry string lookup..." 'WARN'

            # Attempt to find uninstall string from registry using app name
            $regPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            $uninstallEntry = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
                              Where-Object { $_.DisplayName -like "*$AppName*" } |
                              Select-Object -First 1

            if ($uninstallEntry -and $uninstallEntry.UninstallString) {
                Write-Log "Found registry uninstall string: $($uninstallEntry.UninstallString)"
                # Attempt to run the string — may need silent args appended
                $exe  = 'cmd.exe'
                $args = "/c `"$($uninstallEntry.UninstallString)`""
                Write-Log "Note: Registry uninstall string may launch a GUI. Set EXEUninstallPath for silent uninstall." 'WARN'
            } else {
                Write-Log "No uninstall method found. Set EXEUninstallPath or MSIProductCode in the script." 'ERROR'
                exit 1
            }
        }
    } else {
        $exe  = $InstallerFile
        $args = if ($InstallerArgs) { $InstallerArgs } else { '/quiet /norestart' }
        # [CHANGE ME] - '/quiet /norestart' is a generic fallback. Always test with
        #               Watch-Install.ps1 first to get the correct args for the engine.
    }

} else {
    Write-Log "Unsupported installer extension: $ext" 'ERROR'
    exit 1
}

Write-Log "Executable : $exe"
Write-Log "Arguments  : $args"

# ==============================================================================
# REGION: EXECUTE INSTALLER
# ==============================================================================
try {
    $proc = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow -ErrorAction Stop
    $exitCode = $proc.ExitCode
} catch {
    Write-Log "Failed to launch installer process: $_" 'ERROR'
    exit 1
}

Write-Log "Exit Code: $exitCode"

# ==============================================================================
# REGION: EXIT CODE EVALUATION
# ------------------------------------------------------------------------------
# [CHANGE ME] - $successCodes contains exit codes treated as success.
#               3010 = success with reboot pending (Intune handles reboots).
#               1641 = reboot initiated immediately.
#               Add any vendor-specific success codes your apps use here.
# ==============================================================================
$successCodes = @(0, 3010, 1641)
# [CHANGE ME] - Example: $successCodes = @(0, 3010, 1641, 8) if vendor uses 8 for success.

if ($exitCode -in $successCodes) {
    Write-Log "$Mode reported success (exit $exitCode)" 'SUCCESS'
    if ($exitCode -in @(3010, 1641)) {
        Write-Log "REBOOT REQUIRED — Intune will handle restart per your assignment settings." 'WARN'
    }
} else {
    $meaning = switch ($exitCode) {
        1    { 'General error' }
        2    { 'File not found or bad arguments' }
        1602 { 'User cancelled — ensure silent args suppress all UI' }
        1603 { 'Fatal MSI error — check MSI verbose log for details' }
        1618 { 'Another MSI install is already in progress' }
        1619 { 'Installer package could not be opened' }
        1624 { 'Error applying transforms' }
        1638 { 'Another version of this application is already installed' }
        # [CHANGE ME] - Add vendor-specific error codes below as you discover them.
        # Example: 5 { 'VendorX: License server unreachable' }
        default { 'Unknown — check installer documentation or verbose log' }
    }
    Write-Log "$Mode FAILED — Exit code: $exitCode ($meaning)" 'ERROR'
    if (Test-Path $MSILog) { Write-Log "MSI verbose log available at: $MSILog" 'ERROR' }
    exit $exitCode
}

# ==============================================================================
# REGION: POST-INSTALL DETECTION CHECK
# ------------------------------------------------------------------------------
# After a successful install, optionally verify the app is actually present
# before reporting success to Intune. Prevents false positives from installers
# that exit 0 but silently fail.
#
# [CHANGE ME] - Set $DetectionType and the corresponding value variable to match
#               how you want to verify the install succeeded. Options:
#
#   'DisplayName'  — searches all Uninstall registry hives for a matching
#                    DisplayName using a wildcard filter. This is the recommended
#                    method. It works regardless of GUID, bitness, or install scope,
#                    and stays consistent with how Detect-APPNAME.ps1 works.
#                    Set $DetectionNameFilter to a wildcard string, e.g. "*7-Zip*"
#                    Run Watch-Install.ps1 first — it reports the exact DisplayName
#                    written by the installer so you know what filter to use here.
#
#   'RegistryKey'  — checks that a specific registry key path exists.
#                    Useful when you need to verify a particular GUID or key name
#                    rather than a display name. Note: GUIDs change between versions,
#                    so this will need updating if you supersede the package later.
#                    Set $DetectionValue to the full registry path.
#                    e.g. 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{GUID}'
#
#   'File'         — checks that a specific file exists on disk.
#                    Use for apps that don't write a standard registry entry.
#                    Set $DetectionValue to the full file path.
#                    e.g. 'C:\Program Files\AppName\app.exe'
#
#   'None'         — skips the detection check entirely (not recommended for production).
#
# Leave $DetectionType as 'None' or $DetectionValue/$DetectionNameFilter empty
# to skip detection entirely.
# ==============================================================================
$DetectionType       = 'None'   # [CHANGE ME] 'DisplayName', 'RegistryKey', 'File', or 'None'
$DetectionNameFilter = ''       # [CHANGE ME] For DisplayName — wildcard filter e.g. "*7-Zip*"
$DetectionValue      = ''       # [CHANGE ME] For RegistryKey or File — the path to check

# Registry hives searched when using DisplayName detection
$UninstallHives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)

if (-not $IsUninstall -and $DetectionType -ne 'None') {
    Write-Log "Running post-install detection check ($DetectionType)..."
    Start-Sleep -Seconds 3   # Brief pause to allow filesystem/registry to settle

    $detected = $false

    switch ($DetectionType) {

        'DisplayName' {
            if (-not $DetectionNameFilter) {
                Write-Log "DetectionType is DisplayName but DetectionNameFilter is empty. Skipping check." 'WARN'
                $detected = $true  # Don't fail the install over a misconfigured optional check
            } else {
                foreach ($hive in $UninstallHives) {
                    $match = Get-ChildItem $hive -ErrorAction SilentlyContinue |
                             Get-ItemProperty -ErrorAction SilentlyContinue |
                             Where-Object { $_.DisplayName -like $DetectionNameFilter } |
                             Select-Object -First 1
                    if ($match) {
                        Write-Log "Detection check PASSED: Found '$($match.DisplayName)' v$($match.DisplayVersion)" 'SUCCESS'
                        $detected = $true
                        break
                    }
                }
            }
        }

        'RegistryKey' {
            $detected = Test-Path $DetectionValue
            if ($detected) { Write-Log "Detection check PASSED: Registry key found at $DetectionValue" 'SUCCESS' }
        }

        'File' {
            $detected = Test-Path $DetectionValue
            if ($detected) { Write-Log "Detection check PASSED: File found at $DetectionValue" 'SUCCESS' }
        }
    }

    if (-not $detected) {
        Write-Log "Detection check FAILED: Expected $DetectionType '$($DetectionNameFilter)$($DetectionValue)' not found after install." 'ERROR'
        Write-Log "App may have installed to an unexpected location or failed silently." 'ERROR'
        exit 1
    }
}

# ==============================================================================
# REGION: FOOTER
# ==============================================================================
Write-Log "=============================="
Write-Log "$Mode complete for $AppName $AppVersion"
Write-Log "Log file : $LogFile"
if (Test-Path $MSILog) { Write-Log "MSI log  : $MSILog" }
Write-Log "=============================="
exit 0
