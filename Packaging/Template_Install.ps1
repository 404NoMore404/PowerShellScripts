###########################################################################################
# Install-[APPNAME].ps1
# Version 1.0
#
# ---------------------------------------------------------------
# FILL IN: Replace [APPNAME] in the filename and throughout
#          this script with your application name.
#          Example: Install-7Zip.ps1
# ---------------------------------------------------------------
#
# Wrapper script for silent installation of [APPLICATION FULL NAME]
# Designed for Intune Win32 deployment
#
# Log output: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\[APPNAME]\
#             [APPNAME]_LogFile_Installer_YYYY-MM-DD_HHMMSS.log
#
# HOW TO TEST LOCALLY BEFORE PACKAGING:
#   Option A - Dot source (from the folder containing the script):
#        cd "C:\Path\To\PackageFolder"
#        . .\Install-[APPNAME].ps1
#
#   Option B - Direct file execution:
#        powershell.exe -ExecutionPolicy Bypass -File ".\Install-[APPNAME].ps1"
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
# This is the only section you should need to edit for most packages.
###########################################################################################

# ---------------------------------------------------------------
# APPLICATION DETAILS
# ---------------------------------------------------------------

# The display name of the application (used in logs)
# Example: "7-Zip 24.08"
$AppName = "[APPLICATION DISPLAY NAME]"

# The version number of the application (used in logs and detection)
# Example: "24.08.0.0"
$AppVersion = "[VERSION NUMBER]"

# ---------------------------------------------------------------
# INSTALLER FILE
# The name of the installer EXE or MSI sitting in the same folder as this script.
# Example (EXE): "7z2408-x64.exe"
# Example (MSI): "7zip-24.08.msi"
# ---------------------------------------------------------------
$InstallerFileName = "[INSTALLER FILENAME.exe]"

# ---------------------------------------------------------------
# SILENT INSTALL ARGUMENTS
# The command line arguments to pass to the installer for silent install.
#
# Common examples:
#   InstallShield (ISS file):  "/s /f1`"$ISSFile`""        -- uncomment $ISSFile below if using this
#   MSI:                       "/quiet /norestart"
#   NSIS (.exe):               "/S"
#   Inno Setup (.exe):         "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
#   Custom EXE:                "/install /quiet /norestart"
# ---------------------------------------------------------------
$InstallArguments = "[SILENT INSTALL ARGUMENTS]"

# ---------------------------------------------------------------
# ISS RESPONSE FILE (InstallShield only)
# Only needed if your installer is InstallShield and uses a .iss file.
# If not using InstallShield, leave this blank and ignore it.
# ---------------------------------------------------------------
# $ISSFileName = "setup.iss"     # Uncomment this line if using an ISS file
# Then set $InstallArguments = "/s /f1`"$ISSFile`""

# ---------------------------------------------------------------
# REGISTRY DETECTION
# The uninstall registry key used to detect if the app is installed.
# Find this after a manual install by running:
#   Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" |
#       Get-ItemProperty |
#       Where-Object { $_.DisplayName -like "*YourAppName*" } |
#       Select-Object DisplayName, PSChildName
# PSChildName will be either a GUID like {ABC123...} or the app name.
#
# Example GUID:    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{12345678-1234-1234-1234-123456789ABC}"
# Example Name:    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip"
# ---------------------------------------------------------------
$RegistryDetectionPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\[PRODUCT GUID OR NAME]"

# ---------------------------------------------------------------
# LOG FOLDER NAME
# Name of the subfolder under the Intune logs directory.
# Keep it short and matching the app name.
# Example: "7Zip"
# ---------------------------------------------------------------
$LogFolderName = "[APPNAME]"

# ---------------------------------------------------------------
# EXPECTED EXIT CODES
# Add any additional success exit codes your installer uses.
# 0    = Success (universal)
# 3010 = Success, reboot required (MSI standard)
# 1641 = Success, reboot required (MSI standard)
# Check your installer's documentation for app-specific codes.
# ---------------------------------------------------------------
# $AdditionalSuccessCodes = @(1046)    # Example: uncomment and add codes if needed

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
    $LogFile   = "$LogFolder\$($LogFolderName)_LogFile_Installer_$Timestamp.log"

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

    # Header
    Write-Section "$AppName -- INSTALLER LOG"
    Write-Log "Log File   : $LogFile"
    Write-Log "Start Time : $STARTTIME"
    Write-Log "Computer   : $env:COMPUTERNAME"
    Write-Log "User       : $env:USERNAME"
    Write-Log "OS         : $((Get-WmiObject Win32_OperatingSystem).Caption)"

    $FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
    Write-Log "Free Space : $FreeGB GB on C:"

    #######################################################################################
    # Pre-Install Checks
    #######################################################################################

    Write-Section "PRE-INSTALL CHECKS"

    # Admin check
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Log "Script must be run as Administrator. Exiting." "ERROR"
        exit 1
    }
    Write-Log "Running as Administrator." "OK"

    # Resolve script path - supports -File, dot-sourcing, and direct invocation
    if ($PSScriptRoot -and $PSScriptRoot -ne "") {
        $ScriptPath = $PSScriptRoot
        Write-Log "Script path resolved via PSScriptRoot."
    }
    elseif ($MyInvocation.MyCommand.Path -and $MyInvocation.MyCommand.Path -ne "") {
        $ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
        Write-Log "Script path resolved via MyInvocation.MyCommand.Path."
    }
    else {
        $ScriptPath = (Get-Location).Path
        Write-Log "Script path resolved via Get-Location (current directory)." "WARN"
        Write-Log "If files are not found below, CD to the script folder before running." "WARN"
    }

    $InstallerPath = Join-Path $ScriptPath $InstallerFileName

    # If using an ISS file, uncomment and set the path here:
    # $ISSFile = Join-Path $ScriptPath $ISSFileName

    Write-Log "Script path  : $ScriptPath"
    Write-Log "Installer    : $InstallerPath"

    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" "ERROR"
        Write-Log "Ensure the installer is in the same folder as this script." "ERROR"
        exit 1
    }
    Write-Log "Installer found." "OK"

    # If using ISS file, uncomment this block:
    # if (-not (Test-Path $ISSFile)) {
    #     Write-Log "ISS file not found: $ISSFile" "ERROR"
    #     exit 1
    # }
    # Write-Log "ISS file found." "OK"

    # Already installed check
    $Existing = Get-ItemProperty $RegistryDetectionPath -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Log "$AppName $($Existing.DisplayVersion) is already installed. Nothing to do." "WARN"
        exit 0
    }
    Write-Log "No existing $AppName installation detected." "OK"

    #######################################################################################
    # Run Installer (with console progress indicator)
    #######################################################################################

    Write-Section "RUNNING INSTALLER"
    Write-Log "Launching silent installer: $InstallerPath"
    Write-Log "Arguments: $InstallArguments"

    # ---------------------------------------------------------------
    # ESTIMATED DURATION
    # Set this to the approximate install time in seconds.
    # Used only for the progress bar display — does not affect the install.
    # Example: A 5 minute install = 300 seconds
    # ---------------------------------------------------------------
    $EstimatedSeconds = 120

    $ExitCode = -1

    try {
        # Launch installer as a background job so we can show a progress bar while waiting
        $Process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList $InstallArguments `
            -PassThru -NoNewWindow

        Write-Log "Installer launched. PID: $($Process.Id)"
        Write-Log "Waiting for installer to complete..."

        # Progress bar loop — updates every second while installer is running
        $Elapsed = 0
        while (-not $Process.HasExited) {
            $Elapsed++
            $ElapsedMin = [math]::Floor($Elapsed / 60)
            $ElapsedSec = $Elapsed % 60

            # Cap progress at 99% until we know it's actually done
            $PercentComplete = [math]::Min([math]::Round(($Elapsed / $EstimatedSeconds) * 100), 99)

            Write-Progress `
                -Activity "Installing $AppName" `
                -Status "Elapsed: ${ElapsedMin}m ${ElapsedSec}s  |  Progress: ~$PercentComplete%  |  Installer is running, please wait..." `
                -PercentComplete $PercentComplete

            Start-Sleep -Seconds 1
        }

        # Installer finished — complete the progress bar
        Write-Progress -Activity "Installing $AppName" -Status "Complete" -PercentComplete 100
        Start-Sleep -Seconds 1
        Write-Progress -Activity "Installing $AppName" -Completed

        $ExitCode = $Process.ExitCode
        Write-Log "Installer finished. Exit code: $ExitCode"

        switch ($ExitCode) {
            0    { Write-Log "Installation completed successfully." "OK" }
            3010 { Write-Log "Installation completed. Reboot required to finalize." "OK" }
            1641 { Write-Log "Installation completed. Reboot required to finalize." "OK" }
            # ---------------------------------------------------------------
            # ADD APP-SPECIFIC EXIT CODES HERE
            # Example:
            # 1046 { Write-Log "Installation completed. Reboot required." "OK" }
            # 5    { Write-Log "Installation failed - access denied." "ERROR"; exit $ExitCode }
            # ---------------------------------------------------------------
            default {
                Write-Log "Installation failed with exit code $ExitCode." "ERROR"
                Write-Log "Check the installer documentation for what this code means." "ERROR"
                exit $ExitCode
            }
        }
    }
    catch {
        Write-Log "Unexpected exception: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    #######################################################################################
    # Post-Install Verification
    #######################################################################################

    Write-Section "POST-INSTALL VERIFICATION"
    Start-Sleep -Seconds 10

    $Install = Get-ItemProperty $RegistryDetectionPath -ErrorAction SilentlyContinue
    if ($Install) {
        Write-Log "Registry entry confirmed." "OK"
        Write-Log "Name     : $($Install.DisplayName)"
        Write-Log "Version  : $($Install.DisplayVersion)"
        Write-Log "Location : $($Install.InstallLocation)"
    }
    else {
        Write-Log "Registry entry not found after install. Reboot may be required to finalize." "WARN"
    }

    # ---------------------------------------------------------------
    # OPTIONAL: ADD APP-SPECIFIC POST-INSTALL CHECKS HERE
    # Examples:
    #   Check a service is running:
    #     $Svc = Get-Service -Name "YourServiceName" -ErrorAction SilentlyContinue
    #     if ($Svc) { Write-Log "Service found. Status: $($Svc.Status)" "OK" }
    #
    #   Check a file exists:
    #     if (Test-Path "C:\Program Files\YourApp\app.exe") { Write-Log "EXE confirmed." "OK" }
    # ---------------------------------------------------------------

    #######################################################################################
    # Summary
    #######################################################################################

    $Duration = (Get-Date) - $STARTTIME

    Write-Section "SUMMARY"
    Write-Log "Product    : $AppName"
    Write-Log "Result     : $(if ($ExitCode -eq 0) { 'SUCCESS' } else { 'SUCCESS - REBOOT REQUIRED' })"
    Write-Log "Exit Code  : $ExitCode"
    Write-Log "Duration   : $Duration"
    Write-Log "Log saved  : $LogFile"

    exit $ExitCode
}

try {
    Main
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
