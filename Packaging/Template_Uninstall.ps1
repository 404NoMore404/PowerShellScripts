###########################################################################################
# Uninstall-[APPNAME].ps1
# Version 1.0
#
# ---------------------------------------------------------------
# FILL IN: Replace [APPNAME] in the filename and throughout
#          this script with your application name.
#          Example: Uninstall-7Zip.ps1
# ---------------------------------------------------------------
#
# Wrapper script for silent uninstallation of [APPLICATION FULL NAME]
# Designed for Intune Win32 deployment
#
# Log output: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\[APPNAME]\
#             [APPNAME]_LogFile_Uninstaller_YYYY-MM-DD_HHMMSS.log
#
# HOW TO TEST LOCALLY BEFORE PACKAGING:
#   Option A - Dot source (from the folder containing the script):
#        cd "C:\Path\To\PackageFolder"
#        . .\Uninstall-[APPNAME].ps1
#
#   Option B - Direct file execution:
#        powershell.exe -ExecutionPolicy Bypass -File ".\Uninstall-[APPNAME].ps1"
#
#   Then review the log at:
#        C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\[APPNAME]\
#
# Last Updated: [DATE]
###########################################################################################

[CmdletBinding()]
Param()

###########################################################################################
# CONFIGURATION BLOCK
# Fill in all values in this block before using this script.
###########################################################################################

# ---------------------------------------------------------------
# APPLICATION DETAILS
# ---------------------------------------------------------------

# The display name shown in logs
# Example: "7-Zip 24.08"
$AppName = "[APPLICATION DISPLAY NAME]"

# ---------------------------------------------------------------
# PRODUCT CODE / UNINSTALL METHOD
# How to uninstall depends on the installer type used.
#
# OPTION A - MSI Product Code (most common):
#   Find it after install by running:
#     Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" |
#         Get-ItemProperty |
#         Where-Object { $_.DisplayName -like "*YourApp*" } |
#         Select-Object DisplayName, PSChildName
#   PSChildName will be the GUID.
#   Example: "{12345678-1234-1234-1234-123456789ABC}"
#
# OPTION B - EXE uninstaller (some apps ship their own uninstall.exe):
#   Find the UninstallString from the same registry query above.
#   Example: "C:\Program Files\YourApp\uninstall.exe"
#
# OPTION C - Silent flags only (no product code needed):
#   Some EXE installers support silent uninstall via flags.
#   Example: "C:\Program Files\YourApp\setup.exe" /uninstall /silent
# ---------------------------------------------------------------

# Set the uninstall method: "MSI", "EXE"
$UninstallMethod = "MSI"

# For MSI uninstall - the product GUID
# Example: "{12345678-1234-1234-1234-123456789ABC}"
$ProductCode = "[PRODUCT GUID]"

# For EXE uninstall - full path to uninstaller and its silent arguments
# Example path: "C:\Program Files\YourApp\uninstall.exe"
# Example args: "/S" or "/silent /norestart"
$UninstallerPath = "[FULL PATH TO UNINSTALLER EXE]"
$UninstallArguments = "[SILENT UNINSTALL ARGUMENTS]"

# ---------------------------------------------------------------
# REGISTRY DETECTION PATH
# Same as in the install script - used to confirm removal worked.
# Example: "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{GUID}"
# ---------------------------------------------------------------
$RegistryDetectionPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\[PRODUCT GUID OR NAME]"

# ---------------------------------------------------------------
# LEFTOVER CLEANUP
# Paths to remove after uninstall if the installer leaves them behind.
# Add as many as needed. Leave the arrays empty if nothing to clean up.
#
# Folder examples:
#   "C:\Program Files\YourApp"
#   "C:\ProgramData\YourApp"
#
# Registry key examples:
#   "HKLM:\SOFTWARE\YourCompany\YourApp"
#   "HKCU:\SOFTWARE\YourApp"
# ---------------------------------------------------------------
$LeftoverFolders  = @(
    # "C:\Program Files\[APPNAME]"       # Uncomment and fill in as needed
    # "C:\ProgramData\[APPNAME]"
)

$LeftoverRegKeys  = @(
    # "HKLM:\SOFTWARE\[VENDOR]\[APPNAME]"   # Uncomment and fill in as needed
)

# ---------------------------------------------------------------
# LOG FOLDER NAME
# Should match what you used in the install script.
# Example: "7Zip"
# ---------------------------------------------------------------
$LogFolderName = "[APPNAME]"

###########################################################################################
# END OF CONFIGURATION BLOCK - No edits needed below this line for standard packages
###########################################################################################

Function Main {

    $STARTTIME = Get-Date

    #######################################################################################
    # Logging Setup
    #######################################################################################

    $LogFolder = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\$LogFolderName"
    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    $Timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $LogFile   = "$LogFolder\$($LogFolderName)_LogFile_Uninstaller_$Timestamp.log"

    Function Write-Log {
        param(
            [string]$Message,
            [string]$Level = 'INFO'
        )
        $PaddedLevel = $Level.PadRight(5)
        $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$PaddedLevel]  $Message"
        Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
        switch ($Level) {
            'ERROR' { Write-Host $Entry -ForegroundColor Red }
            'WARN'  { Write-Host $Entry -ForegroundColor Yellow }
            'OK'    { Write-Host $Entry -ForegroundColor Green }
            default { Write-Host $Entry -ForegroundColor White }
        }
    }

    Function Write-Section {
        param([string]$Title)
        $Divider = "-" * 80
        Add-Content -Path $LogFile -Value "" -ErrorAction SilentlyContinue
        Add-Content -Path $LogFile -Value $Divider -ErrorAction SilentlyContinue
        Add-Content -Path $LogFile -Value "  $Title" -ErrorAction SilentlyContinue
        Add-Content -Path $LogFile -Value $Divider -ErrorAction SilentlyContinue
        Write-Host ""
        Write-Host $Divider -ForegroundColor Cyan
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host $Divider -ForegroundColor Cyan
    }

    Write-Section "$AppName -- UNINSTALLER LOG"
    Write-Log "Log File   : $LogFile"
    Write-Log "Start Time : $STARTTIME"
    Write-Log "Computer   : $env:COMPUTERNAME"
    Write-Log "User       : $env:USERNAME"

    #######################################################################################
    # Admin Check
    #######################################################################################

    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Log "Script must be run as Administrator. Exiting." "ERROR"
        exit 1
    }
    Write-Log "Running as Administrator." "OK"

    #######################################################################################
    # Step 1 -- Uninstall Application
    #######################################################################################

    Write-Section "STEP 1 -- UNINSTALL $($AppName.ToUpper())"

    $AppKey = Get-ItemProperty $RegistryDetectionPath -ErrorAction SilentlyContinue

    if (-not $AppKey) {
        Write-Log "$AppName does not appear to be installed. Skipping uninstall." "WARN"
    }
    else {
        Write-Log "Found: $($AppKey.DisplayName) $($AppKey.DisplayVersion)"

        try {
            if ($UninstallMethod -eq "MSI") {
                # MSI uninstall using product code
                $Args = "/x $ProductCode /quiet /norestart /l*v `"$LogFolder\$($LogFolderName)_LogFile_MSI_Uninstall_$Timestamp.log`""
                Write-Log "Running MSI uninstall: msiexec.exe $Args"
                $Proc = Start-Process "msiexec.exe" -ArgumentList $Args -Wait -PassThru -NoNewWindow
            }
            elseif ($UninstallMethod -eq "EXE") {
                # EXE uninstall
                Write-Log "Running EXE uninstall: $UninstallerPath $UninstallArguments"
                $Proc = Start-Process $UninstallerPath -ArgumentList $UninstallArguments -Wait -PassThru -NoNewWindow
            }

            Write-Log "Uninstall exit code: $($Proc.ExitCode)"

            if ($Proc.ExitCode -eq 0 -or $Proc.ExitCode -eq 3010) {
                Write-Log "$AppName uninstalled successfully." "OK"
            }
            else {
                Write-Log "Uninstall returned unexpected exit code: $($Proc.ExitCode)" "ERROR"
                exit $Proc.ExitCode
            }
        }
        catch {
            Write-Log "Exception during uninstall: $($_.Exception.Message)" "ERROR"
            exit 1
        }
    }

    #######################################################################################
    # Step 2 -- Leftover Cleanup
    #######################################################################################

    Write-Section "STEP 2 -- LEFTOVER CLEANUP"

    # Remove leftover folders
    foreach ($Folder in $LeftoverFolders) {
        if ($Folder -and (Test-Path $Folder)) {
            Write-Log "Removing folder: $Folder"
            try {
                Remove-Item $Folder -Recurse -Force -ErrorAction Stop
                Write-Log "Folder removed." "OK"
            }
            catch {
                Write-Log "Could not remove folder: $($_.Exception.Message)" "WARN"
            }
        }
    }

    # Remove leftover registry keys
    foreach ($Key in $LeftoverRegKeys) {
        if ($Key -and (Test-Path $Key)) {
            Write-Log "Removing registry key: $Key"
            try {
                Remove-Item $Key -Recurse -Force -ErrorAction Stop
                Write-Log "Registry key removed." "OK"
            }
            catch {
                Write-Log "Could not remove registry key: $($_.Exception.Message)" "WARN"
            }
        }
    }

    # ---------------------------------------------------------------
    # OPTIONAL: ADD APP-SPECIFIC CLEANUP HERE
    # Examples:
    #   Stop a service before removal:
    #     Stop-Service -Name "YourService" -Force -ErrorAction SilentlyContinue
    #
    #   Remove a scheduled task:
    #     Unregister-ScheduledTask -TaskName "YourTask" -Confirm:$false -ErrorAction SilentlyContinue
    #
    #   Remove a cached installer:
    #     $Cache = "$env:LOCALAPPDATA\Downloaded Installations\{GUID}"
    #     if (Test-Path $Cache) { Remove-Item $Cache -Recurse -Force }
    # ---------------------------------------------------------------

    #######################################################################################
    # Verification
    #######################################################################################

    Write-Section "VERIFICATION"
    Start-Sleep -Seconds 5

    $Check = Get-ItemProperty $RegistryDetectionPath -ErrorAction SilentlyContinue
    if (-not $Check) {
        Write-Log "$AppName registry entry removed." "OK"
    }
    else {
        Write-Log "$AppName registry entry still present. Manual cleanup may be needed." "WARN"
    }

    #######################################################################################
    # Summary
    #######################################################################################

    $Duration = (Get-Date) - $STARTTIME

    Write-Section "SUMMARY"
    Write-Log "Product    : $AppName"
    Write-Log "Result     : Uninstall complete (check WARN/ERROR lines above if any)"
    Write-Log "Duration   : $Duration"
    Write-Log "Log saved  : $LogFile"

    exit 0
}

try {
    Main
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
