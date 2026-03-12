###########################################################################################
# Install-Interactive.ps1
# Version 2.1
#
# Interactive wrapper for silent installation of any Win32 app
# Designed for Intune Win32 deployment
#
# HOW TO USE:
#   Run the script and follow the prompts. No manual config needed.
#   The script will:
#     1. Open a File Explorer dialog so you can browse to your installer
#     2. Auto-detect the installer type (MSI, EXE, etc.) and suggest silent args
#     3. Optionally record an ISS response file (InstallShield only, defaults to No)
#     4. Show you the full install plan and let you confirm before doing anything
#     5. Run the installer silently with a live progress bar and full logging
#     6. Verify the install via registry and show a summary
#
# HOW TO TEST LOCALLY:
#   powershell.exe -ExecutionPolicy Bypass -File ".\Install-Interactive.ps1"
#
# Log output:
#   C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\[AppName]\
#
# Last Updated: 2026-03-12
###########################################################################################

[CmdletBinding()]
Param(
    # Optional: pass installer path directly to skip the file picker dialog
    # Example: .\Install-Interactive.ps1 -InstallerPath "C:\Temp\setup.exe"
    [string]$InstallerPath = ""
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
    Write-Host $Line  -ForegroundColor Cyan
    Write-Host $Inner -ForegroundColor Cyan
    Write-Host $Line  -ForegroundColor Cyan
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
        default { Write-Host $Entry -ForegroundColor White }
    }
}

###########################################################################################
# PROMPT HELPER
# Displays a Y/N question. Default is Y (press Enter = Yes) unless -DefaultNo is passed.
###########################################################################################

Function Read-YN {
    param(
        [string]$Prompt,
        [switch]$DefaultNo
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
# FILE PICKER
# Opens a Windows File Explorer dialog to browse for the installer
###########################################################################################

Function Show-FilePicker {
    param([string]$InitialDirectory = "C:\")

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $Dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title            = "Select Installer File"
    $Dialog.Filter           = "Installer Files (*.exe;*.msi;*.msp)|*.exe;*.msi;*.msp|All Files (*.*)|*.*"
    $Dialog.InitialDirectory = $InitialDirectory
    $Dialog.Multiselect      = $false

    # ShowDialog needs a parent handle to stay on top of the terminal
    $Owner  = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $Result = $Dialog.ShowDialog($Owner)
    $Owner.Dispose()

    if ($Result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }
    return $null
}

###########################################################################################
# INSTALLER TYPE DETECTION
# Inspects the selected file and recommends the best silent install approach
###########################################################################################

Function Resolve-InstallerType {
    param([PSCustomObject]$InstallerFile)

    $Info = [PSCustomObject]@{
        Type            = ""
        SuggestedArgs   = ""
        DisplayArgs     = ""
        Confidence      = "High"
        Notes           = ""
        IsInstallShield = $false
    }

    if ($InstallerFile.Extension -eq ".msi") {
        $Info.Type          = "MSI"
        $Info.SuggestedArgs = "/quiet /norestart"
        $Info.DisplayArgs   = "msiexec.exe /i `"$($InstallerFile.FullPath)`" /quiet /norestart"
        $Info.Notes         = "Standard MSI -- silent flags are reliable"
        return $Info
    }

    if ($InstallerFile.Extension -eq ".msp") {
        $Info.Type          = "MSP"
        $Info.SuggestedArgs = "/quiet /norestart"
        $Info.DisplayArgs   = "msiexec.exe /p `"$($InstallerFile.FullPath)`" /quiet /norestart"
        $Info.Notes         = "MSI patch file"
        return $Info
    }

    if ($InstallerFile.Extension -eq ".exe") {
        $Name = $InstallerFile.Name

        if ($Name -match '(?i)setup.*inno|inno.*setup') {
            $Info.Type          = "EXE-Inno"
            $Info.SuggestedArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
            $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
            $Info.Notes         = "Inno Setup detected from filename"
            return $Info
        }

        if ($Name -match '(?i)nsis|nullsoft') {
            $Info.Type          = "EXE-NSIS"
            $Info.SuggestedArgs = "/S"
            $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /S"
            $Info.Notes         = "NSIS installer detected from filename"
            return $Info
        }

        # Read first 4KB of the binary to check for embedded framework strings
        try {
            $Bytes  = [System.IO.File]::ReadAllBytes($InstallerFile.FullPath) | Select-Object -First 4096
            $Header = [System.Text.Encoding]::ASCII.GetString($Bytes) -replace '[^\x20-\x7E]', ' '

            if ($Header -match 'Inno Setup') {
                $Info.Type          = "EXE-Inno"
                $Info.SuggestedArgs = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
                $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
                $Info.Notes         = "Inno Setup detected from file header"
                return $Info
            }

            if ($Header -match 'Nullsoft') {
                $Info.Type          = "EXE-NSIS"
                $Info.SuggestedArgs = "/S"
                $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /S"
                $Info.Notes         = "NSIS (Nullsoft) detected from file header"
                return $Info
            }

            if ($Header -match 'InstallShield') {
                $Info.Type            = "EXE-InstallShield"
                $Info.SuggestedArgs   = "/s /v`"/qn /norestart`""
                $Info.DisplayArgs     = "`"$($InstallerFile.FullPath)`" /s /v`"/qn /norestart`""
                $Info.Confidence      = "Medium"
                $Info.IsInstallShield = $true
                $Info.Notes           = "InstallShield detected -- may need /f1 ISS file for complex setups"
                return $Info
            }

            if ($Header -match 'WiX|Windows Installer XML') {
                $Info.Type          = "EXE-WiX"
                $Info.SuggestedArgs = "/quiet /norestart"
                $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /quiet /norestart"
                $Info.Notes         = "WiX bootstrapper detected"
                return $Info
            }
        }
        catch { }

        # Generic EXE fallback
        $Info.Type          = "EXE"
        $Info.SuggestedArgs = "/S"
        $Info.DisplayArgs   = "`"$($InstallerFile.FullPath)`" /S"
        $Info.Confidence    = "Medium"
        $Info.Notes         = "Unknown EXE type -- /S is a common silent flag but may not work for all apps"
        return $Info
    }

    $Info.Type       = "UNKNOWN"
    $Info.Confidence = "Low"
    return $Info
}

###########################################################################################
# REGISTRY HELPERS
###########################################################################################

Function Find-RegistryAfterInstall {
    param([string]$AppNameHint, [datetime]$InstalledAfter)

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
            if ([string]::IsNullOrWhiteSpace($Props.DisplayName)) { return }
            if ($Props.SystemComponent -eq 1) { return }

            $NameMatch = $Props.DisplayName -like "*$AppNameHint*"

            $DateMatch = $false
            if ($Props.InstallDate -match '^\d{8}$') {
                try {
                    $ParsedDate = [datetime]::ParseExact($Props.InstallDate, "yyyyMMdd", $null)
                    $DateMatch  = ($ParsedDate -ge $InstalledAfter.Date)
                } catch { }
            }

            if ($NameMatch -or $DateMatch) {
                $Results += [PSCustomObject]@{
                    DisplayName    = $Props.DisplayName
                    DisplayVersion = $Props.DisplayVersion
                    RegistryPath   = $_.PsPath
                }
            }
        }
    }
    return $Results
}

###########################################################################################
# MAIN
###########################################################################################

Function Main {

    $STARTTIME      = Get-Date
    $script:LogFile = $null

    Write-Banner "INTUNE INSTALL SCRIPT  v2.1"

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
    # Step 1 -- Pick Installer via File Explorer Dialog
    #######################################################################################

    Write-Section "STEP 1 -- SELECT INSTALLER" -NoLog

    $SelectedFile  = $null
    $InstallerInfo = $null

    do {
        # If path was passed as a parameter, validate and use it directly
        if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
            if (-not (Test-Path $InstallerPath)) {
                Write-Host "  [!] Specified installer not found: $InstallerPath" -ForegroundColor Red
                $InstallerPath = ""
                continue
            }
            $FileObj = Get-Item $InstallerPath
            $SelectedFile = [PSCustomObject]@{
                Name      = $FileObj.Name
                FullPath  = $FileObj.FullName
                Extension = $FileObj.Extension.ToLower()
                SizeMB    = [math]::Round($FileObj.Length / 1MB, 1)
            }
            $InstallerPath = ""
        }
        else {
            Write-Host "  A File Explorer window will open -- browse to your installer file." -ForegroundColor Cyan
            Write-Host "  Supported types:  .exe   .msi   .msp" -ForegroundColor DarkGray
            Write-Host ""

            $PickedPath = Show-FilePicker -InitialDirectory "C:\"

            if ([string]::IsNullOrWhiteSpace($PickedPath)) {
                Write-Host "  [!] No file selected." -ForegroundColor Yellow
                if (-not (Read-YN "Open the file picker again?")) { exit 0 }
                continue
            }

            $FileObj = Get-Item $PickedPath
            $SelectedFile = [PSCustomObject]@{
                Name      = $FileObj.Name
                FullPath  = $FileObj.FullName
                Extension = $FileObj.Extension.ToLower()
                SizeMB    = [math]::Round($FileObj.Length / 1MB, 1)
            }
        }

        # Analyse the picked file
        $InstallerInfo = Resolve-InstallerType -InstallerFile $SelectedFile

        $ConfColor = switch ($InstallerInfo.Confidence) {
            "High"   { "Green" }
            "Medium" { "Yellow" }
            "Low"    { "Red" }
        }

        Write-Host ""
        Write-Host "  Selected   : $($SelectedFile.Name)  ($($SelectedFile.SizeMB) MB)" -ForegroundColor White
        Write-Host "  Type       : $($InstallerInfo.Type)" -ForegroundColor White
        Write-Host "  Args       : $($InstallerInfo.SuggestedArgs)" -ForegroundColor $ConfColor
        if ($InstallerInfo.Notes) {
            Write-Host "  Note       : $($InstallerInfo.Notes)" -ForegroundColor $ConfColor
        }
        Write-Host ""

        if (-not (Read-YN "Use this file?")) {
            $SelectedFile  = $null
            $InstallerInfo = $null
        }

    } while (-not $SelectedFile)

    #######################################################################################
    # Step 2 -- App Name, ISS Prompt, Confirm Plan
    #######################################################################################

    # Auto-detect app name from the file's embedded version metadata
    # Priority: ProductName > FileDescription > filename stem
    $AppName = ""
    try {
        $VerInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SelectedFile.FullPath)
        if (-not [string]::IsNullOrWhiteSpace($VerInfo.ProductName)) {
            $AppName = $VerInfo.ProductName.Trim()
        } elseif (-not [string]::IsNullOrWhiteSpace($VerInfo.FileDescription)) {
            $AppName = $VerInfo.FileDescription.Trim()
        }
    } catch { }

    # Fall back to filename stem if metadata is empty
    if ([string]::IsNullOrWhiteSpace($AppName)) {
        $AppName = $SelectedFile.Name -replace '\.[^.]+$', ''
    }

    Write-Host ""
    Write-Host "  Detected app name : $AppName" -ForegroundColor White
    Write-Host "  Press Enter to accept, or type a different name to override:" -ForegroundColor Cyan
    $NameOverride = (Read-Host "  App name").Trim()
    if (-not [string]::IsNullOrWhiteSpace($NameOverride)) {
        $AppName = $NameOverride
    }

    # Set up logging now that we have a name
    $SafeName       = $AppName -replace '[^A-Za-z0-9_\-]', '_'
    $LogFolder      = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\$SafeName"
    $Timestamp      = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $script:LogFile = "$LogFolder\$($SafeName)_LogFile_Installer_$Timestamp.log"

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    Write-Section "STEP 2 -- CONFIRM INSTALL PLAN"
    Write-Log "Log File   : $script:LogFile"
    Write-Log "Start Time : $STARTTIME"
    Write-Log "Computer   : $env:COMPUTERNAME"
    Write-Log "User       : $env:USERNAME"
    Write-Log "OS         : $((Get-WmiObject Win32_OperatingSystem).Caption)"
    $FreeGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
    Write-Log "Free Space : $FreeGB GB on C:"

    # ---------------------------------------------------------------
    # ISS RESPONSE FILE PROMPT
    # An ISS file records user choices during a GUI install run so
    # they can be replayed silently on other machines. Useful only for
    # InstallShield installers that require custom configuration.
    # Defaults to No -- this is an uncommon workflow.
    # ---------------------------------------------------------------

    $BuildISS = $false
    $ISSPath  = ""

    Write-Host ""

    # If InstallShield was detected, surface a short explanation before the prompt
    if ($InstallerInfo.IsInstallShield) {
        Write-Host "  InstallShield installer detected." -ForegroundColor Yellow
        Write-Host "  An ISS response file captures your wizard choices for silent replay on other machines." -ForegroundColor DarkGray
        Write-Host "  Only needed when the installer requires custom configuration beyond standard /qn flags." -ForegroundColor DarkGray
        Write-Host ""
    }

    if (Read-YN "Record an ISS response file for this installer?" -DefaultNo) {
        $ISSPath  = Join-Path (Split-Path $SelectedFile.FullPath) "setup.iss"
        $BuildISS = $true

        Write-Host ""
        Write-Host "  ISS recording steps:" -ForegroundColor Cyan
        Write-Host "    1. The installer launches in interactive (GUI) mode" -ForegroundColor White
        Write-Host "    2. Walk through the wizard exactly as you want it to run silently" -ForegroundColor White
        Write-Host "    3. Your choices are saved to: $ISSPath" -ForegroundColor White
        Write-Host "    4. The silent install will replay those choices automatically" -ForegroundColor White
        Write-Host ""

        if (-not (Read-YN "Start the ISS recording now?")) {
            $BuildISS = $false
            $ISSPath  = ""
            Write-Host "  ISS recording skipped." -ForegroundColor Yellow
        }
    }

    # Show full install plan
    Write-Host ""
    Write-Host "  Application  : $AppName" -ForegroundColor White
    Write-Host "  Installer    : $($SelectedFile.Name)  ($($SelectedFile.SizeMB) MB)" -ForegroundColor White
    Write-Host "  Type         : $($InstallerInfo.Type)" -ForegroundColor White

    if ($BuildISS) {
        Write-Host "  ISS File     : $ISSPath  (will be recorded first)" -ForegroundColor White
        $InstallerInfo.SuggestedArgs = "/s /f1`"$ISSPath`""
        $InstallerInfo.DisplayArgs   = "`"$($SelectedFile.FullPath)`" /s /f1`"$ISSPath`""
    }

    Write-Host ""
    Write-Host "  Install Command:" -ForegroundColor Cyan
    Write-Host "    $($InstallerInfo.DisplayArgs)" -ForegroundColor White

    if ($InstallerInfo.Confidence -ne "High" -and -not $BuildISS) {
        Write-Host ""
        Write-Host "  [!] Confidence is $($InstallerInfo.Confidence) -- silent flags were guessed." -ForegroundColor Yellow
    }

    Write-Host ""

    # Default to prompting for edits when confidence is not High (and not using ISS)
    $EditDefault = ($InstallerInfo.Confidence -ne "High") -and (-not $BuildISS)
    if ($EditDefault) {
        $EditPrompt = Read-YN "Edit the silent arguments before continuing?"
    } else {
        $EditPrompt = Read-YN "Edit the silent arguments?" -DefaultNo
    }

    if ($EditPrompt) {
        Write-Host "  Current: $($InstallerInfo.SuggestedArgs)" -ForegroundColor Gray
        Write-Host "  Common flags:" -ForegroundColor DarkGray
        Write-Host "    MSI / WiX        :  /quiet /norestart" -ForegroundColor DarkGray
        Write-Host "    Inno Setup       :  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -ForegroundColor DarkGray
        Write-Host "    NSIS             :  /S" -ForegroundColor DarkGray
        Write-Host "    InstallShield    :  /s /v`"/qn /norestart`"" -ForegroundColor DarkGray
        Write-Host "    InstallShield+ISS:  /s /f1`"C:\path\setup.iss`"" -ForegroundColor DarkGray
        $NewArgs = (Read-Host "  New arguments").Trim()
        if (-not [string]::IsNullOrWhiteSpace($NewArgs)) {
            $InstallerInfo.SuggestedArgs = $NewArgs
            Write-Host "  Arguments updated to: $NewArgs" -ForegroundColor Green
        }
        Write-Host ""
    }

    if (-not (Read-YN "Proceed with installation?")) {
        Write-Host "  Install cancelled by user." -ForegroundColor Yellow
        exit 0
    }

    Write-Log "User confirmed install of: $AppName"
    Write-Log "Installer  : $($SelectedFile.FullPath)"
    Write-Log "Arguments  : $($InstallerInfo.SuggestedArgs)"
    if ($BuildISS) { Write-Log "ISS File   : $ISSPath" }

    #######################################################################################
    # Step 3a -- Record ISS Response File (if requested)
    #######################################################################################

    if ($BuildISS) {
        Write-Section "STEP 3a -- RECORDING ISS RESPONSE FILE"
        Write-Host ""
        Write-Host "  The installer is opening in interactive mode." -ForegroundColor Cyan
        Write-Host "  Complete the wizard exactly as you want it replayed silently." -ForegroundColor Cyan
        Write-Host "  This script will continue automatically once the wizard closes." -ForegroundColor Cyan
        Write-Host ""
        Write-Log "Launching installer in record mode: /r /f1`"$ISSPath`""

        try {
            $RecordProc = Start-Process `
                -FilePath $SelectedFile.FullPath `
                -ArgumentList "/r /f1`"$ISSPath`"" `
                -Wait -PassThru

            Write-Log "ISS record finished. Exit code: $($RecordProc.ExitCode)"

            if (Test-Path $ISSPath) {
                Write-Log "ISS file saved to: $ISSPath" "OK"
            } else {
                Write-Log "ISS file not found after recording -- falling back to /s /v`"/qn /norestart`"" "WARN"
                $InstallerInfo.SuggestedArgs = "/s /v`"/qn /norestart`""
            }
        }
        catch {
            Write-Log "Exception during ISS recording: $($_.Exception.Message)" "ERROR"
            Write-Log "Falling back to standard silent flags." "WARN"
            $InstallerInfo.SuggestedArgs = "/s /v`"/qn /norestart`""
        }
    }

    #######################################################################################
    # Step 3b -- Run Silent Installer
    #######################################################################################

    Write-Section "STEP 3 -- RUNNING INSTALLER"

    $ExitCode         = -1
    $EstimatedSeconds = 120

    try {
        if ($InstallerInfo.Type -eq "MSI" -or $InstallerInfo.Type -eq "MSP") {
            $MsiLogFile = "$LogFolder\$($SafeName)_MSI_Install_$Timestamp.log"
            $Verb       = if ($InstallerInfo.Type -eq "MSP") { "/p" } else { "/i" }
            $FullArgs   = "$Verb `"$($SelectedFile.FullPath)`" $($InstallerInfo.SuggestedArgs) /l*v `"$MsiLogFile`""
            Write-Log "Running: msiexec.exe $FullArgs"
            $Process = Start-Process "msiexec.exe" -ArgumentList $FullArgs -PassThru -NoNewWindow
        } else {
            Write-Log "Running: $($SelectedFile.FullPath) $($InstallerInfo.SuggestedArgs)"
            $Process = Start-Process `
                -FilePath $SelectedFile.FullPath `
                -ArgumentList $InstallerInfo.SuggestedArgs `
                -PassThru -NoNewWindow
        }

        Write-Log "Installer launched. PID: $($Process.Id)"
        Write-Log "Waiting for installer to complete..."

        $Elapsed = 0
        while (-not $Process.HasExited) {
            $Elapsed++
            $ElapsedMin      = [math]::Floor($Elapsed / 60)
            $ElapsedSec      = $Elapsed % 60
            $PercentComplete = [math]::Min([math]::Round(($Elapsed / $EstimatedSeconds) * 100), 99)

            Write-Progress `
                -Activity "Installing $AppName" `
                -Status "Elapsed: ${ElapsedMin}m ${ElapsedSec}s  |  ~$PercentComplete%  |  Please wait..." `
                -PercentComplete $PercentComplete

            Start-Sleep -Seconds 1
        }

        Write-Progress -Activity "Installing $AppName" -Status "Complete" -PercentComplete 100
        Start-Sleep -Seconds 1
        Write-Progress -Activity "Installing $AppName" -Completed

        $ExitCode = $Process.ExitCode

        # Some installers (e.g. Squirrel/Discord) spawn a child process and exit
        # with a null exit code rather than 0. Treat null as success here since
        # the post-install registry check is the real source of truth.
        if ($null -eq $ExitCode) {
            Write-Log "Installer exited with null exit code (common with Squirrel-based installers)." "WARN"
            Write-Log "Treating as success -- registry verification will confirm." "WARN"
            $ExitCode = 0
        }

        Write-Log "Installer finished. Exit code: $ExitCode"

        switch ($ExitCode) {
            0    { Write-Log "Installation completed successfully." "OK" }
            3010 { Write-Log "Installation completed. Reboot required to finalize." "OK" }
            1641 { Write-Log "Installation completed. Reboot required to finalize." "OK" }
            default {
                Write-Log "Installer returned exit code $ExitCode." "ERROR"
                Write-Log "Check installer documentation for what this code means." "ERROR"
                exit $ExitCode
            }
        }
    }
    catch {
        Write-Log "Exception during install: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    #######################################################################################
    # Step 4 -- Post-Install Verification
    #######################################################################################

    Write-Section "STEP 4 -- VERIFICATION"
    Write-Log "Waiting for registry to settle..."
    Start-Sleep -Seconds 10

    $AppNameShort = ($AppName -split ' ')[0]
    $FoundEntries = @(Find-RegistryAfterInstall -AppNameHint $AppNameShort -InstalledAfter $STARTTIME)

    if ($FoundEntries.Count -gt 0) {
        Write-Log "Registry entry confirmed." "OK"
        foreach ($Entry in $FoundEntries) {
            Write-Log "  Name     : $($Entry.DisplayName)"
            Write-Log "  Version  : $($Entry.DisplayVersion)"
            Write-Log "  RegPath  : $($Entry.RegistryPath)"
        }
    } else {
        Write-Log "No registry entry found matching '$AppNameShort' after install." "WARN"
        Write-Log "This may be normal if the app uses a non-standard registry location." "WARN"
        Write-Log "Check manually: HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" "WARN"
    }

    #######################################################################################
    # Summary
    #######################################################################################

    $Duration = (Get-Date) - $STARTTIME

    Write-Section "SUMMARY"
    Write-Log "Product    : $AppName"
    Write-Log "Installer  : $($SelectedFile.Name)"
    Write-Log "Method     : $($InstallerInfo.Type)"
    if ($BuildISS) { Write-Log "ISS File   : $ISSPath" }
    Write-Log "Exit Code  : $ExitCode"
    Write-Log "Result     : $(if ($ExitCode -eq 0) { 'SUCCESS' } else { 'SUCCESS - REBOOT REQUIRED' })"
    Write-Log "Duration   : $Duration"
    Write-Log "Log saved  : $script:LogFile"

    Write-Host ""
    Write-Host "  Done. Full log written to:" -ForegroundColor Green
    Write-Host "  $script:LogFile" -ForegroundColor Cyan
    Write-Host ""

    exit $ExitCode
}

###########################################################################################

try {
    Main
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
