###########################################################################################
# Uninstall-Interactive.ps1
# Version 2.0
#
# Interactive wrapper for silent uninstallation of any Win32 app
# Designed for Intune Win32 deployment
#
# HOW TO USE:
#   Run the script and follow the prompts. No manual config needed.
#   The script will:
#     1. Ask you what app to search for
#     2. Scan the registry and find all matching installs
#     3. Show you what it found and confirm before doing anything
#     4. Perform the uninstall silently with full logging
#     5. Clean up leftovers and verify removal
#
# HOW TO TEST LOCALLY:
#   powershell.exe -ExecutionPolicy Bypass -File ".\Uninstall-Interactive.ps1"
#
# Log output:
#   C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\[AppName]\
#
# Last Updated: 2026-03-12
###########################################################################################

[CmdletBinding()]
Param(
    # Optional: pass app search term as a parameter to skip the first prompt
    # Example: .\Uninstall-Interactive.ps1 -AppSearch "7-Zip"
    [string]$AppSearch = ""
)

###########################################################################################
# HELPER FUNCTIONS
###########################################################################################

Function Write-Banner {
    param([string]$Text)
    $Width = 82
    $Line  = "#" * $Width
    $Pad   = [math]::Floor(($Width - $Text.Length - 2) / 2)
    $Inner = "#" + (" " * $Pad) + $Text + (" " * ($Width - $Pad - $Text.Length - 2)) + "#"
    Write-Host ""
    Write-Host $Line            -ForegroundColor Cyan
    Write-Host $Inner           -ForegroundColor Cyan
    Write-Host $Line            -ForegroundColor Cyan
    Write-Host ""
}

Function Write-Section {
    param([string]$Title, [switch]$NoLog)
    $Divider = "-" * 80
    Write-Host ""
    Write-Host $Divider -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $Divider -ForegroundColor Cyan
    if (-not $NoLog -and $script:LogFile) {
        Add-Content -Path $script:LogFile -Value "" -ErrorAction SilentlyContinue
        Add-Content -Path $script:LogFile -Value $Divider -ErrorAction SilentlyContinue
        Add-Content -Path $script:LogFile -Value "  $Title" -ErrorAction SilentlyContinue
        Add-Content -Path $script:LogFile -Value $Divider -ErrorAction SilentlyContinue
    }
}

Function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $PaddedLevel = $Level.PadRight(5)
    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [$PaddedLevel]  $Message"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $Entry -ErrorAction SilentlyContinue
    }
    switch ($Level) {
        'ERROR' { Write-Host $Entry -ForegroundColor Red }
        'WARN'  { Write-Host $Entry -ForegroundColor Yellow }
        'OK'    { Write-Host $Entry -ForegroundColor Green }
        'PROMPT'{ Write-Host $Entry -ForegroundColor Magenta }
        default { Write-Host $Entry -ForegroundColor White }
    }
}

###########################################################################################
# PROMPT HELPER
# Displays a Y/N question with Y as the default (press Enter = Yes)
###########################################################################################

Function Read-YN {
    param(
        [string]$Prompt,
        [switch]$DefaultNo   # Pass -DefaultNo to flip the default to N
    )
    $Indicator = if ($DefaultNo) { "[y/N]" } else { "[Y/n]" }
    Write-Host "  $Prompt $Indicator : " -ForegroundColor Cyan -NoNewline
    $Answer = (Read-Host).Trim()
    if ($DefaultNo) {
        return ($Answer -match '^[Yy]')
    } else {
        return ($Answer -eq '' -or $Answer -match '^[Yy]')
    }
}

###########################################################################################
# REGISTRY DISCOVERY
# Searches all standard uninstall registry hives for matching apps
###########################################################################################

Function Get-InstalledApps {
    param([string]$SearchTerm)

    $RegistryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $Results = @()

    foreach ($Path in $RegistryPaths) {
        if (-not (Test-Path $Path)) { continue }

        Get-ChildItem $Path -ErrorAction SilentlyContinue | ForEach-Object {
            $Props = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue

            # Skip system components and updates - they clutter results
            if ($Props.SystemComponent -eq 1)    { return }
            if ($Props.DisplayName -match "^KB\d") { return }
            if ([string]::IsNullOrWhiteSpace($Props.DisplayName)) { return }

            if ($Props.DisplayName -like "*$SearchTerm*") {
                $Results += [PSCustomObject]@{
                    DisplayName      = $Props.DisplayName
                    DisplayVersion   = $Props.DisplayVersion
                    Publisher        = $Props.Publisher
                    InstallDate      = $Props.InstallDate
                    InstallLocation  = $Props.InstallLocation
                    # The registry key name itself is the GUID (or product code) for MSI apps
                    PSChildName      = $_.PSChildName
                    RegistryPath     = $_.PsPath
                    # Raw uninstall string - tells us if MSI or EXE
                    UninstallString  = $Props.UninstallString
                    QuietUninstall   = $Props.QuietUninstallString
                    Hive             = $Path
                }
            }
        }
    }

    return $Results
}

###########################################################################################
# UNINSTALL METHOD DETECTION
# Inspects what was found and recommends the best uninstall approach
###########################################################################################

Function Resolve-UninstallMethod {
    param([PSCustomObject]$App)

    $Method = [PSCustomObject]@{
        Type             = ""
        ProductCode      = ""
        ExePath          = ""
        ExeArgs          = ""
        DisplayMethod    = ""
        RegistryPath     = $App.RegistryPath
        Confidence       = "High"
        Notes            = ""
    }

    # GUID pattern - a proper GUID key name means this is an MSI product
    if ($App.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
        $Method.Type          = "MSI"
        $Method.ProductCode   = $App.PSChildName
        $Method.DisplayMethod = "MSI  |  msiexec /x $($App.PSChildName) /quiet /norestart"
        return $Method
    }

    # QuietUninstallString is the gold standard - app explicitly provides a silent CLI
    if (-not [string]::IsNullOrWhiteSpace($App.QuietUninstall)) {
        $Parsed = Split-CommandLine $App.QuietUninstall
        $Method.Type          = "EXE"
        $Method.ExePath       = $Parsed.Executable
        $Method.ExeArgs       = $Parsed.Arguments
        $Method.DisplayMethod = "EXE  |  $($App.QuietUninstall)"
        $Method.Notes         = "Using QuietUninstallString from registry"
        return $Method
    }

    # UninstallString - check if it's an MSI command disguised as a string
    if (-not [string]::IsNullOrWhiteSpace($App.UninstallString)) {
        if ($App.UninstallString -match 'msiexec' -and $App.UninstallString -match '\{[0-9A-Fa-f\-]{36}\}') {
            $GuidMatch = [regex]::Match($App.UninstallString, '\{[0-9A-Fa-f\-]{36}\}')
            $Method.Type          = "MSI"
            $Method.ProductCode   = $GuidMatch.Value
            $Method.DisplayMethod = "MSI  |  msiexec /x $($GuidMatch.Value) /quiet /norestart"
            $Method.Notes         = "GUID extracted from UninstallString"
            return $Method
        }

        # Plain EXE uninstall string
        $Parsed = Split-CommandLine $App.UninstallString
        $Method.Type          = "EXE"
        $Method.ExePath       = $Parsed.Executable
        # Try common silent flags - these are the most universal
        $Method.ExeArgs       = "/S /SILENT /quiet"
        $Method.DisplayMethod = "EXE  |  $($Parsed.Executable)  $($Method.ExeArgs)"
        $Method.Confidence    = "Medium"
        $Method.Notes         = "Silent flags guessed - review before deploying"
        return $Method
    }

    # Nothing found - fall back to manual
    $Method.Type          = "UNKNOWN"
    $Method.Confidence    = "Low"
    $Method.DisplayMethod = "Could not determine uninstall method automatically"
    $Method.Notes         = "Check UninstallString in registry manually"
    return $Method
}

# Splits a command string into executable + arguments, handling quoted paths
Function Split-CommandLine {
    param([string]$CommandLine)

    $CommandLine = $CommandLine.Trim()

    if ($CommandLine -match '^"([^"]+)"(.*)$') {
        return [PSCustomObject]@{
            Executable = $Matches[1].Trim()
            Arguments  = $Matches[2].Trim()
        }
    }
    elseif ($CommandLine -match '^(\S+)(.*)$') {
        return [PSCustomObject]@{
            Executable = $Matches[1].Trim()
            Arguments  = $Matches[2].Trim()
        }
    }

    return [PSCustomObject]@{ Executable = $CommandLine; Arguments = "" }
}

###########################################################################################
# MAIN
###########################################################################################

Function Main {

    $STARTTIME = Get-Date
    $script:LogFile = $null  # Will be set after user picks an app

    Write-Banner "INTUNE UNINSTALL SCRIPT  v2.0"

    #######################################################################################
    # Admin Check
    #######################################################################################

    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Host "  [ERROR] This script must be run as Administrator." -ForegroundColor Red
        Write-Host "  Right-click PowerShell and choose 'Run as Administrator'." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    #######################################################################################
    # Step 1 -- Search for the Application
    #######################################################################################

    Write-Section "STEP 1 -- FIND APPLICATION" -NoLog

    $SelectedApp    = $null
    $UninstallInfo  = $null

    do {
        # Get search term - either from parameter or by prompting
        if ([string]::IsNullOrWhiteSpace($AppSearch)) {
            Write-Host "  Enter the application name (or partial name) to search for:" -ForegroundColor Cyan
            Write-Host "  Example: '7-Zip'  or  'Adobe'  or  'Chrome'" -ForegroundColor DarkGray
            Write-Host ""
            $SearchTerm = Read-Host "  Search"
        }
        else {
            $SearchTerm = $AppSearch
            $AppSearch  = ""  # Clear so retry prompts the user
            Write-Host "  Searching for: $SearchTerm" -ForegroundColor Cyan
        }

        if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
            Write-Host "  Search term cannot be empty. Try again." -ForegroundColor Yellow
            continue
        }

        Write-Host ""
        Write-Host "  Scanning registry..." -ForegroundColor DarkGray

        $FoundApps = @(Get-InstalledApps -SearchTerm $SearchTerm)

        if ($FoundApps.Count -eq 0) {
            Write-Host ""
            Write-Host "  [!] No applications found matching '$SearchTerm'." -ForegroundColor Yellow
            Write-Host "      Try a shorter or different search term." -ForegroundColor DarkGray
            Write-Host ""
            if (-not (Read-YN "Search again?")) { exit 0 }
            continue
        }

        ###################################################################################
        # Display search results
        ###################################################################################

        Write-Host ""
        Write-Host "  Found $($FoundApps.Count) match(es):" -ForegroundColor Green
        Write-Host ""

        $Index = 0
        foreach ($App in $FoundApps) {
            $Index++
            $UM = Resolve-UninstallMethod -App $App

            Write-Host "  [$Index]  $($App.DisplayName)" -ForegroundColor White
            Write-Host "       Version    : $($App.DisplayVersion)" -ForegroundColor Gray
            Write-Host "       Publisher  : $($App.Publisher)" -ForegroundColor Gray
            Write-Host "       Method     : $($UM.DisplayMethod)" -ForegroundColor Gray

            if ($UM.Notes) {
                $ConfColor = switch ($UM.Confidence) {
                    "High"   { "Green" }
                    "Medium" { "Yellow" }
                    "Low"    { "Red" }
                }
                Write-Host "       Note       : $($UM.Notes)" -ForegroundColor $ConfColor
            }

            Write-Host "       Registry   : $($App.RegistryPath)" -ForegroundColor DarkGray
            Write-Host ""
        }

        ###################################################################################
        # Let user pick
        ###################################################################################

        if ($FoundApps.Count -eq 1) {
            Write-Host "  Only one match found." -ForegroundColor Cyan
            if (Read-YN "Select and continue?") {
                $SelectedApp   = $FoundApps[0]
                $UninstallInfo = Resolve-UninstallMethod -App $SelectedApp
            } else { exit 0 }
        }
        else {
            Write-Host "  Enter the number of the app to uninstall, or (S) to search again, or (N) to exit:" -ForegroundColor Cyan
            $Pick = Read-Host "  Choice"

            if ($Pick -match '^[Ss]') { continue }
            if ($Pick -match '^[Nn]') { exit 0 }

            $PickNum  = [int]$Pick
            $AppCount = $FoundApps.Count
            if ($PickNum -lt 1 -or $PickNum -gt $AppCount) {
                Write-Host "  Invalid selection. Enter a number between 1 and $AppCount." -ForegroundColor Yellow
                continue
            }

            $SelectedApp   = $FoundApps[$PickNum - 1]
            $UninstallInfo = Resolve-UninstallMethod -App $SelectedApp
        }

    } while (-not $SelectedApp)

    #######################################################################################
    # Step 2 -- Confirm Before Proceeding
    #######################################################################################

    # Now that we know the app name, set up logging
    $SafeName    = $SelectedApp.DisplayName -replace '[^A-Za-z0-9_\-]', '_'
    $LogFolder   = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\$SafeName"
    $Timestamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $script:LogFile = "$LogFolder\$($SafeName)_LogFile_Uninstaller_$Timestamp.log"

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    Write-Section "STEP 2 -- CONFIRM UNINSTALL"
    Write-Log "Log File   : $script:LogFile"
    Write-Log "Start Time : $STARTTIME"
    Write-Log "Computer   : $env:COMPUTERNAME"
    Write-Log "User       : $env:USERNAME"

    Write-Host ""
    Write-Host "  Please review the uninstall plan before proceeding:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Application  : $($SelectedApp.DisplayName)" -ForegroundColor White
    Write-Host "  Version      : $($SelectedApp.DisplayVersion)" -ForegroundColor White
    Write-Host "  Publisher    : $($SelectedApp.Publisher)" -ForegroundColor White
    Write-Host "  Install Date : $($SelectedApp.InstallDate)" -ForegroundColor White
    Write-Host "  Install Path : $($SelectedApp.InstallLocation)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Uninstall Method:" -ForegroundColor Cyan

    switch ($UninstallInfo.Type) {
        "MSI" {
            Write-Host "    Type         : MSI (Windows Installer)" -ForegroundColor White
            Write-Host "    Product Code : $($UninstallInfo.ProductCode)" -ForegroundColor White
            Write-Host "    Command      : msiexec.exe /x $($UninstallInfo.ProductCode) /quiet /norestart" -ForegroundColor White
        }
        "EXE" {
            $ConfColor = if ($UninstallInfo.Confidence -eq "High") { "White" } else { "Yellow" }
            Write-Host "    Type         : EXE Uninstaller" -ForegroundColor White
            Write-Host "    Executable   : $($UninstallInfo.ExePath)" -ForegroundColor $ConfColor
            Write-Host "    Arguments    : $($UninstallInfo.ExeArgs)" -ForegroundColor $ConfColor
            if ($UninstallInfo.Confidence -ne "High") {
                Write-Host ""
                Write-Host "    [!] Confidence is $($UninstallInfo.Confidence) - silent flags were guessed." -ForegroundColor Yellow
                Write-Host "        You may be prompted to edit the arguments." -ForegroundColor Yellow
            }
        }
        "UNKNOWN" {
            Write-Host "    [!] Could not determine uninstall method automatically." -ForegroundColor Red
            Write-Host "        Manual intervention will be required." -ForegroundColor Red
        }
    }

    Write-Host ""

    # For medium-confidence EXE, offer to edit the arguments
    if ($UninstallInfo.Type -eq "EXE" -and $UninstallInfo.Confidence -ne "High") {
        Write-Host "  The silent arguments '$($UninstallInfo.ExeArgs)' were guessed." -ForegroundColor Yellow
        if (Read-YN "Edit arguments now? (N = keep as-is)" -DefaultNo) {
            Write-Host "  Current: $($UninstallInfo.ExeArgs)" -ForegroundColor Gray
            $NewArgs = Read-Host "  New arguments"
            if (-not [string]::IsNullOrWhiteSpace($NewArgs)) {
                $UninstallInfo.ExeArgs = $NewArgs
                Write-Host "  Arguments updated to: $NewArgs" -ForegroundColor Green
            }
        }
        Write-Host ""
    }

    if ($UninstallInfo.Type -eq "UNKNOWN") {
        Write-Log "Cannot determine uninstall method. Exiting." "ERROR"
        exit 1
    }

    if (-not (Read-YN "Proceed with uninstall?")) {
        Write-Host "  Uninstall cancelled by user." -ForegroundColor Yellow
        exit 0
    }

    Write-Log "User confirmed uninstall of: $($SelectedApp.DisplayName) $($SelectedApp.DisplayVersion)"

    #######################################################################################
    # Step 3 -- Execute Uninstall
    #######################################################################################

    Write-Section "STEP 3 -- EXECUTE UNINSTALL"

    try {
        if ($UninstallInfo.Type -eq "MSI") {
            $MsiLog  = "$LogFolder\$($SafeName)_MSI_Uninstall_$Timestamp.log"
            $MsiArgs = "/x $($UninstallInfo.ProductCode) /quiet /norestart /l*v `"$MsiLog`""
            Write-Log "Running: msiexec.exe $MsiArgs"
            $Proc = Start-Process "msiexec.exe" -ArgumentList $MsiArgs -Wait -PassThru -NoNewWindow
        }
        elseif ($UninstallInfo.Type -eq "EXE") {
            Write-Log "Running: $($UninstallInfo.ExePath)  $($UninstallInfo.ExeArgs)"
            $Proc = Start-Process $UninstallInfo.ExePath -ArgumentList $UninstallInfo.ExeArgs -Wait -PassThru -NoNewWindow
        }

        Write-Log "Exit code: $($Proc.ExitCode)"

        if ($Proc.ExitCode -eq 0) {
            Write-Log "Uninstall completed successfully." "OK"
        }
        elseif ($Proc.ExitCode -eq 3010) {
            Write-Log "Uninstall completed - reboot required." "WARN"
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

    #######################################################################################
    # Step 4 -- Optional Leftover Cleanup
    #######################################################################################

    Write-Section "STEP 4 -- LEFTOVER CLEANUP"

    # Check install folder
    if (-not [string]::IsNullOrWhiteSpace($SelectedApp.InstallLocation) -and (Test-Path $SelectedApp.InstallLocation)) {
        Write-Host ""
        Write-Host "  Install folder still exists: $($SelectedApp.InstallLocation)" -ForegroundColor Yellow
        if (Read-YN "Remove it?") {
            try {
                Remove-Item $SelectedApp.InstallLocation -Recurse -Force -ErrorAction Stop
                Write-Log "Removed install folder: $($SelectedApp.InstallLocation)" "OK"
            }
            catch {
                Write-Log "Could not remove folder: $($_.Exception.Message)" "WARN"
            }
        }
    }
    else {
        Write-Log "No install folder to clean up (or already removed)." "OK"
    }

    # Ask about additional paths
    Write-Host ""
    $RemoveExtra = (Read-YN "Remove any additional folders or registry keys?" -DefaultNo)

    while ($RemoveExtra) {
        Write-Host "  Enter a full path to remove (folder or registry key), or leave blank to stop:" -ForegroundColor Cyan
        Write-Host "  Examples:  C:\ProgramData\MyApp   or   HKLM:\SOFTWARE\MyVendor\MyApp" -ForegroundColor DarkGray
        $ExtraPath = Read-Host "  Path"

        if ([string]::IsNullOrWhiteSpace($ExtraPath)) { break }

        if (Test-Path $ExtraPath) {
            try {
                Remove-Item $ExtraPath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed: $ExtraPath" "OK"
            }
            catch {
                Write-Log "Could not remove '$ExtraPath': $($_.Exception.Message)" "WARN"
            }
        }
        else {
            Write-Log "Path not found (may already be gone): $ExtraPath" "WARN"
        }

        $RemoveExtra = (Read-YN "Remove another path?" -DefaultNo)
    }

    #######################################################################################
    # Step 5 -- Verification
    #######################################################################################

    Write-Section "STEP 5 -- VERIFICATION"
    Start-Sleep -Seconds 5

    $CheckPath = $SelectedApp.RegistryPath
    $Check     = Get-ItemProperty $CheckPath -ErrorAction SilentlyContinue

    if (-not $Check) {
        Write-Log "Registry entry removed. Uninstall verified." "OK"
    }
    else {
        Write-Log "Registry entry still present at: $CheckPath" "WARN"
        Write-Log "App may still be installed or may require a reboot to complete removal." "WARN"
    }

    #######################################################################################
    # Summary
    #######################################################################################

    $Duration = (Get-Date) - $STARTTIME

    Write-Section "SUMMARY"
    Write-Log "Product    : $($SelectedApp.DisplayName) $($SelectedApp.DisplayVersion)"
    Write-Log "Method     : $($UninstallInfo.Type)"
    Write-Log "Result     : Uninstall complete (check WARN/ERROR lines above if any)"
    Write-Log "Duration   : $Duration"
    Write-Log "Log saved  : $script:LogFile"

    Write-Host ""
    Write-Host "  Done. Full log written to:" -ForegroundColor Green
    Write-Host "  $script:LogFile" -ForegroundColor Cyan
    Write-Host ""

    exit 0
}

###########################################################################################

try {
    Main
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
