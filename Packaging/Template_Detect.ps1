###########################################################################################
# Detect-[APPNAME].ps1
# Version 2.0
#
# ---------------------------------------------------------------
# FILL IN: Replace [APPNAME] in the filename and throughout
#          this script with your application name.
#          Example: Detect-7Zip.ps1
# ---------------------------------------------------------------
#
# Intune detection script for [APPLICATION FULL NAME]
#
# Intune behavior:
#   Exit 0 + console output = DETECTED (app is installed)
#   Exit 1 + no output      = NOT DETECTED (app is not installed)
#
# HOW TO TEST LOCALLY:
#   powershell.exe -ExecutionPolicy Bypass -File ".\Detect-[APPNAME].ps1"
#   Then run: echo $LASTEXITCODE
#   0 = detected, 1 = not detected
#
# Last Updated: [DATE]
###########################################################################################

###########################################################################################
# CONFIGURATION BLOCK
###########################################################################################

# ---------------------------------------------------------------
# DETECTION METHOD
# Choose ONE detection method below and comment out the others.
#
# RECOMMENDED ORDER OF PREFERENCE:
#   1. DisplayName  — searches by app name across all registry keys.
#                     Works across ALL versions and GUIDs. Best for
#                     supersedence since any installed version passes.
#   2. RegistryGUID — only use if you need to target one exact MSI
#                     package. GUIDs change every version — avoid for
#                     anything you plan to supersede or upgrade later.
#   3. File         — use if the app leaves no registry entry.
#   4. Service      — use for apps that install a Windows service.
# ---------------------------------------------------------------

# ---------------------------------------------------------------
# METHOD 1 - DisplayName Search (RECOMMENDED)
# Searches all Uninstall registry hives for a matching DisplayName.
# Works for 32-bit apps, 64-bit apps, and per-user installs.
#
# Use a wildcard (*) to match any version suffix, e.g. "*7-Zip*"
#
# Find the right display name after a manual install by running:
#   Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
#                 "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" |
#       Get-ItemProperty |
#       Where-Object { $_.DisplayName -like "*YourApp*" } |
#       Select-Object DisplayName, DisplayVersion, PSChildName
# ---------------------------------------------------------------
$DetectionMethod   = "DisplayName"
$DisplayNameFilter = "*[APPLICATION DISPLAY NAME]*"   # e.g. "*7-Zip*" or "*Google Chrome*"

# ---------------------------------------------------------------
# VERSION CHECKING (applies to DisplayName and RegistryGUID methods)
#
# $ExpectedVersion — exact version match. Leave $null unless you have
#                    a specific reason to pin. Pinning a version breaks
#                    supersedence: if v2 is installed, detection for v1
#                    will fail and Intune will try to reinstall.
#
# $MinimumVersion  — pass detection if installed version is >= this value.
#                    Good middle ground: ensures a baseline is present
#                    without blocking newer versions from counting.
#                    Leave $null to skip minimum version checking.
#
# TIP: For supersedence workflows, leave BOTH as $null.
#      Detection should answer "is something installed?" —
#      not "is exactly this version installed?"
# ---------------------------------------------------------------
$ExpectedVersion = $null        # e.g. "24.08.0.0"  — leave $null for any version
$MinimumVersion  = $null        # e.g. "24.00.0.0"  — leave $null to skip

# ---------------------------------------------------------------
# METHOD 2 - Registry GUID (avoid for apps you plan to upgrade/supersede)
# Targets a specific MSI product GUID or registry key name directly.
# The GUID changes with every new version, so this will break on upgrade.
# Only use this if you need pinpoint control over one specific package
# and have no plans to supersede it.
#
# To use: set $DetectionMethod = "RegistryGUID" and fill in $RegistryPath
# ---------------------------------------------------------------
# $DetectionMethod = "RegistryGUID"
# $RegistryPath    = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{[PRODUCT GUID]}"

# ---------------------------------------------------------------
# METHOD 3 - File Exists (use if app has no registry entry)
# Check for a specific file that only exists when the app is installed.
# Example: "C:\Program Files\YourApp\app.exe"
#
# To use: set $DetectionMethod = "File" and fill in $DetectionFilePath
# ---------------------------------------------------------------
# $DetectionMethod   = "File"
# $DetectionFilePath = "C:\Program Files\[APPNAME]\[EXECUTABLE].exe"

# ---------------------------------------------------------------
# METHOD 4 - Service Exists (use for apps that install a Windows service)
# Check whether a specific service name is registered on the machine.
# Example: "MSSQL$PROPRICERSQL" or "Spooler"
#
# To use: set $DetectionMethod = "Service" and fill in $DetectionServiceName
# ---------------------------------------------------------------
# $DetectionMethod      = "Service"
# $DetectionServiceName = "[SERVICE NAME]"

###########################################################################################
# END OF CONFIGURATION BLOCK
###########################################################################################

$Detected        = $false
$DetectedMessage = ""

# Registry hives to search (covers 64-bit, 32-bit, and per-user installs)
$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

function Test-Version {
    param (
        [string]$Installed
    )
    # Exact version check takes priority if set
    if ($ExpectedVersion) {
        return ($Installed -eq $ExpectedVersion)
    }
    # Minimum version check
    if ($MinimumVersion) {
        try {
            return ([version]$Installed -ge [version]$MinimumVersion)
        }
        catch {
            # Version string not parseable — fall back to string compare
            return ($Installed -ge $MinimumVersion)
        }
    }
    # No version requirement — any installed version passes
    return $true
}

switch ($DetectionMethod) {

    "DisplayName" {
        foreach ($Path in $UninstallPaths) {
            $Installs = Get-ChildItem $Path -ErrorAction SilentlyContinue |
                        Get-ItemProperty -ErrorAction SilentlyContinue |
                        Where-Object { $_.DisplayName -like $DisplayNameFilter }

            foreach ($Install in $Installs) {
                if (Test-Version -Installed $Install.DisplayVersion) {
                    $Detected        = $true
                    $DetectedMessage = "DETECTED: $($Install.DisplayName) v$($Install.DisplayVersion)"
                    break
                }
            }
            if ($Detected) { break }
        }
    }

    "RegistryGUID" {
        $Install = Get-ItemProperty $RegistryPath -ErrorAction SilentlyContinue
        if ($Install) {
            if (Test-Version -Installed $Install.DisplayVersion) {
                $Detected        = $true
                $DetectedMessage = "DETECTED: $($Install.DisplayName) v$($Install.DisplayVersion)"
            }
        }
    }

    "File" {
        if (Test-Path $DetectionFilePath) {
            $Detected        = $true
            $DetectedMessage = "DETECTED: File found at $DetectionFilePath"
        }
    }

    "Service" {
        $Svc = Get-Service -Name $DetectionServiceName -ErrorAction SilentlyContinue
        if ($Svc) {
            $Detected        = $true
            $DetectedMessage = "DETECTED: Service '$DetectionServiceName' found. Status: $($Svc.Status)"
        }
    }

    default {
        Write-Host "ERROR: Unknown DetectionMethod '$DetectionMethod'. Use DisplayName, RegistryGUID, File, or Service."
        exit 1
    }
}

if ($Detected) {
    Write-Host $DetectedMessage
    exit 0
}
else {
    exit 1
}
