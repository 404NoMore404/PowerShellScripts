###########################################################################################
# Detect-Interactive.ps1
# Version 2.0
#
# Interactive Intune detection script for any Win32 app
#
# HOW TO USE:
#   Run the script and follow the prompts. No manual config needed.
#   The script will:
#     1. Ask what app to search for and scan the registry automatically
#     2. Show what it found and let you confirm the correct entry
#     3. Ask which detection method to use (DisplayName recommended)
#     4. Ask about version requirements (optional)
#     5. Generate a ready-to-deploy Detect-[AppName].ps1 in the same folder
#
# HOW TO TEST LOCALLY:
#   powershell.exe -ExecutionPolicy Bypass -File ".\Detect-Interactive.ps1"
#
# Intune behavior of the GENERATED script:
#   Exit 0 + console output = DETECTED (app is installed)
#   Exit 1 + no output      = NOT DETECTED
#
# Last Updated: 2026-03-12
###########################################################################################

[CmdletBinding()]
Param()

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
    param([string]$Title)
    $Divider = "-" * 80
    Write-Host ""
    Write-Host $Divider -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host $Divider -ForegroundColor Cyan
}

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
# REGISTRY DISCOVERY
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
            if ($Props.SystemComponent -eq 1) { return }
            if ($Props.DisplayName -match "^KB\d") { return }
            if ([string]::IsNullOrWhiteSpace($Props.DisplayName)) { return }

            if ($Props.DisplayName -like "*$SearchTerm*") {
                $Results += [PSCustomObject]@{
                    DisplayName     = $Props.DisplayName
                    DisplayVersion  = $Props.DisplayVersion
                    Publisher       = $Props.Publisher
                    InstallLocation = $Props.InstallLocation
                    PSChildName     = $_.PSChildName
                    RegistryPath    = $_.PsPath
                    UninstallString = $Props.UninstallString
                }
            }
        }
    }
    return $Results
}

###########################################################################################
# SCRIPT GENERATOR
# Builds the ready-to-deploy Detect-[AppName].ps1 from the collected settings
###########################################################################################

Function Build-DetectScript {
    param(
        [string]$AppName,
        [string]$DetectionMethod,
        [string]$DisplayNameFilter,
        [string]$RegistryPath,
        [string]$FilePath,
        [string]$ServiceName,
        [string]$ExpectedVersion,
        [string]$MinimumVersion
    )

    $SafeName    = $AppName -replace '[^A-Za-z0-9_\-]', ''
    $ExpVerLine  = if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) { '$null' } else { "`"$ExpectedVersion`"" }
    $MinVerLine  = if ([string]::IsNullOrWhiteSpace($MinimumVersion))  { '$null' } else { "`"$MinimumVersion`"" }
    $DateStamp   = Get-Date -Format "yyyy-MM-dd"

    # Build the active detection line and comment out the others
    $DisplayNameBlock  = if ($DetectionMethod -eq "DisplayName")   { "`$DetectionMethod   = `"DisplayName`"`n`$DisplayNameFilter = `"$DisplayNameFilter`"" } `
                         else { "# `$DetectionMethod   = `"DisplayName`"`n# `$DisplayNameFilter = `"$DisplayNameFilter`"" }

    $RegistryGUIDBlock = if ($DetectionMethod -eq "RegistryGUID")  { "`$DetectionMethod = `"RegistryGUID`"`n`$RegistryPath    = `"$RegistryPath`"" } `
                         else { "# `$DetectionMethod = `"RegistryGUID`"`n# `$RegistryPath    = `"$RegistryPath`"" }

    $FileBlock         = if ($DetectionMethod -eq "File")          { "`$DetectionMethod   = `"File`"`n`$DetectionFilePath = `"$FilePath`"" } `
                         else { "# `$DetectionMethod   = `"File`"`n# `$DetectionFilePath = `"$FilePath`"" }

    $ServiceBlock      = if ($DetectionMethod -eq "Service")       { "`$DetectionMethod      = `"Service`"`n`$DetectionServiceName = `"$ServiceName`"" } `
                         else { "# `$DetectionMethod      = `"Service`"`n# `$DetectionServiceName = `"$ServiceName`"" }

$Script = @"
###########################################################################################
# Detect-$SafeName.ps1
# Version 2.0
#
# Intune detection script for $AppName
# Generated by Detect-Interactive.ps1 on $DateStamp
#
# Intune behavior:
#   Exit 0 + console output = DETECTED (app is installed)
#   Exit 1 + no output      = NOT DETECTED (app is not installed)
#
# HOW TO TEST LOCALLY:
#   powershell.exe -ExecutionPolicy Bypass -File ".\Detect-$SafeName.ps1"
#   Then run: echo `$LASTEXITCODE
#   0 = detected, 1 = not detected
###########################################################################################

###########################################################################################
# DETECTION CONFIGURATION
###########################################################################################

$DisplayNameBlock

$RegistryGUIDBlock

$FileBlock

$ServiceBlock

# Version requirements (applies to DisplayName and RegistryGUID methods)
# Set to `$null to accept any installed version (recommended for supersedence)
`$ExpectedVersion = $ExpVerLine
`$MinimumVersion  = $MinVerLine

###########################################################################################
# DETECTION LOGIC -- No edits needed below this line
###########################################################################################

`$Detected        = `$false
`$DetectedMessage = ""

`$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

function Test-Version {
    param([string]`$Installed)
    if (`$ExpectedVersion) { return (`$Installed -eq `$ExpectedVersion) }
    if (`$MinimumVersion) {
        try   { return ([version]`$Installed -ge [version]`$MinimumVersion) }
        catch { return (`$Installed -ge `$MinimumVersion) }
    }
    return `$true
}

switch (`$DetectionMethod) {

    "DisplayName" {
        foreach (`$Path in `$UninstallPaths) {
            `$Installs = Get-ChildItem `$Path -ErrorAction SilentlyContinue |
                         Get-ItemProperty -ErrorAction SilentlyContinue |
                         Where-Object { `$_.DisplayName -like `$DisplayNameFilter }
            foreach (`$Install in `$Installs) {
                if (Test-Version -Installed `$Install.DisplayVersion) {
                    `$Detected        = `$true
                    `$DetectedMessage = "DETECTED: `$(`$Install.DisplayName) v`$(`$Install.DisplayVersion)"
                    break
                }
            }
            if (`$Detected) { break }
        }
    }

    "RegistryGUID" {
        `$Install = Get-ItemProperty `$RegistryPath -ErrorAction SilentlyContinue
        if (`$Install -and (Test-Version -Installed `$Install.DisplayVersion)) {
            `$Detected        = `$true
            `$DetectedMessage = "DETECTED: `$(`$Install.DisplayName) v`$(`$Install.DisplayVersion)"
        }
    }

    "File" {
        if (Test-Path `$DetectionFilePath) {
            `$Detected        = `$true
            `$DetectedMessage = "DETECTED: File found at `$DetectionFilePath"
        }
    }

    "Service" {
        `$Svc = Get-Service -Name `$DetectionServiceName -ErrorAction SilentlyContinue
        if (`$Svc) {
            `$Detected        = `$true
            `$DetectedMessage = "DETECTED: Service '`$DetectionServiceName' found. Status: `$(`$Svc.Status)"
        }
    }

    default {
        Write-Host "ERROR: Unknown DetectionMethod '`$DetectionMethod'."
        exit 1
    }
}

if (`$Detected) {
    Write-Host `$DetectedMessage
    exit 0
} else {
    exit 1
}
"@

    return $Script, $SafeName
}

###########################################################################################
# MAIN
###########################################################################################

Function Main {

    Write-Banner "INTUNE DETECTION SCRIPT GENERATOR  v2.0"

    #######################################################################################
    # Step 1 -- Find the App in Registry
    #######################################################################################

    Write-Section "STEP 1 -- FIND APPLICATION"

    $SelectedApp = $null

    do {
        Write-Host "  Enter the application name (or partial name) to search for:" -ForegroundColor Cyan
        Write-Host "  Example: '7-Zip'  or  'Adobe'  or  'Chrome'" -ForegroundColor DarkGray
        Write-Host ""
        $SearchTerm = (Read-Host "  Search").Trim()

        if ([string]::IsNullOrWhiteSpace($SearchTerm)) {
            Write-Host "  Search term cannot be empty." -ForegroundColor Yellow
            continue
        }

        Write-Host ""
        Write-Host "  Scanning registry..." -ForegroundColor DarkGray

        $FoundApps = @(Get-InstalledApps -SearchTerm $SearchTerm)

        if ($FoundApps.Count -eq 0) {
            Write-Host ""
            Write-Host "  [!] No applications found matching '$SearchTerm'." -ForegroundColor Yellow
            Write-Host "      Tip: The app must be installed on this machine to be detected." -ForegroundColor DarkGray
            Write-Host ""
            if (-not (Read-YN "Search again?")) { exit 0 }
            continue
        }

        Write-Host ""
        Write-Host "  Found $($FoundApps.Count) match(es):" -ForegroundColor Green
        Write-Host ""

        $Index = 0
        foreach ($App in $FoundApps) {
            $Index++
            # Identify if GUID key (MSI) or named key (EXE)
            $KeyType = if ($App.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') { "MSI/GUID" } else { "Named key" }
            Write-Host "  [$Index]  $($App.DisplayName)" -ForegroundColor White
            Write-Host "       Version    : $($App.DisplayVersion)" -ForegroundColor Gray
            Write-Host "       Publisher  : $($App.Publisher)" -ForegroundColor Gray
            Write-Host "       Key type   : $KeyType" -ForegroundColor Gray
            Write-Host "       Registry   : $($App.RegistryPath)" -ForegroundColor DarkGray
            Write-Host ""
        }

        if ($FoundApps.Count -eq 1) {
            if (Read-YN "Use '$($FoundApps[0].DisplayName)'?") {
                $SelectedApp = $FoundApps[0]
            } else { exit 0 }
        } else {
            Write-Host "  Enter the number of the app to detect, or (S) to search again, or (N) to exit:" -ForegroundColor Cyan
            $Pick     = (Read-Host "  Choice").Trim()
            $AppCount = $FoundApps.Count

            if ($Pick -match '^[Ss]') { continue }
            if ($Pick -match '^[Nn]') { exit 0 }

            $PickNum = [int]$Pick
            if ($PickNum -lt 1 -or $PickNum -gt $AppCount) {
                Write-Host "  Invalid selection. Enter a number between 1 and $AppCount." -ForegroundColor Yellow
                continue
            }
            $SelectedApp = $FoundApps[$PickNum - 1]
        }

    } while (-not $SelectedApp)

    #######################################################################################
    # Step 2 -- Choose Detection Method
    #######################################################################################

    Write-Section "STEP 2 -- DETECTION METHOD"

    $IsGUID = $SelectedApp.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$'

    Write-Host ""
    Write-Host "  App       : $($SelectedApp.DisplayName)" -ForegroundColor White
    Write-Host "  Version   : $($SelectedApp.DisplayVersion)" -ForegroundColor White
    Write-Host "  Registry  : $($SelectedApp.RegistryPath)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Detection methods:" -ForegroundColor Cyan
    Write-Host "    [1]  DisplayName   (RECOMMENDED) -- finds the app by name across all registry hives." -ForegroundColor White
    Write-Host "                       Works across all versions. Best for supersedence." -ForegroundColor DarkGray
    if ($IsGUID) {
    Write-Host "    [2]  RegistryGUID  -- targets this exact package GUID only." -ForegroundColor White
    Write-Host "                       Will break on upgrade. Use only if you need to pin a specific version." -ForegroundColor DarkGray
    }
    Write-Host "    [3]  File          -- checks for a specific file on disk. Use if app has no registry entry." -ForegroundColor White
    Write-Host "    [4]  Service       -- checks for a Windows service. Use for apps that install a service." -ForegroundColor White
    Write-Host ""

    $DetectionMethod  = ""
    $DisplayNameFilter = ""
    $RegistryPath     = ""
    $FilePath         = ""
    $ServiceName      = ""

    do {
        $MethodPick = (Read-Host "  Choice [1-4, default 1]").Trim()
        if ([string]::IsNullOrWhiteSpace($MethodPick)) { $MethodPick = "1" }

        switch ($MethodPick) {
            "1" {
                $DetectionMethod   = "DisplayName"
                # Suggest a wildcard filter that will survive version changes
                $SuggestedFilter   = "*$($SelectedApp.DisplayName -replace ' \d+[\.\d]*$', '')*"
                Write-Host ""
                Write-Host "  Suggested filter : $SuggestedFilter" -ForegroundColor White
                Write-Host "  Press Enter to accept, or type a custom filter (wildcards supported):" -ForegroundColor Cyan
                $FilterInput = (Read-Host "  Filter").Trim()
                $DisplayNameFilter = if ([string]::IsNullOrWhiteSpace($FilterInput)) { $SuggestedFilter } else { $FilterInput }
                Write-Host "  Using filter: $DisplayNameFilter" -ForegroundColor Green
            }
            "2" {
                if (-not $IsGUID) {
                    Write-Host "  [!] This app uses a named registry key, not a GUID. RegistryGUID method is not applicable." -ForegroundColor Yellow
                    continue
                }
                $DetectionMethod = "RegistryGUID"
                $RegistryPath    = $SelectedApp.RegistryPath
                Write-Host "  Using registry path: $RegistryPath" -ForegroundColor Green
                Write-Host "  [!] Note: This GUID will change on upgrade. DisplayName is recommended instead." -ForegroundColor Yellow
            }
            "3" {
                $DetectionMethod = "File"
                Write-Host ""
                $SuggestedPath = if (-not [string]::IsNullOrWhiteSpace($SelectedApp.InstallLocation)) {
                    $SelectedApp.InstallLocation.TrimEnd('\')
                } else { "C:\Program Files\$($SelectedApp.DisplayName)" }
                Write-Host "  Enter the full path to a file that only exists when the app is installed:" -ForegroundColor Cyan
                Write-Host "  Suggested base path: $SuggestedPath" -ForegroundColor DarkGray
                $FilePath = (Read-Host "  File path").Trim()
                if ([string]::IsNullOrWhiteSpace($FilePath)) {
                    Write-Host "  File path cannot be empty." -ForegroundColor Yellow
                    $DetectionMethod = ""
                    continue
                }
                Write-Host "  Using file path: $FilePath" -ForegroundColor Green
            }
            "4" {
                $DetectionMethod = "Service"
                Write-Host ""
                Write-Host "  Enter the Windows service name to check for:" -ForegroundColor Cyan
                Write-Host "  Tip: Run 'Get-Service' to list service names on this machine." -ForegroundColor DarkGray
                $ServiceName = (Read-Host "  Service name").Trim()
                if ([string]::IsNullOrWhiteSpace($ServiceName)) {
                    Write-Host "  Service name cannot be empty." -ForegroundColor Yellow
                    $DetectionMethod = ""
                    continue
                }
                Write-Host "  Using service: $ServiceName" -ForegroundColor Green
            }
            default {
                Write-Host "  Invalid choice. Enter 1, 2, 3, or 4." -ForegroundColor Yellow
            }
        }
    } while ([string]::IsNullOrWhiteSpace($DetectionMethod))

    #######################################################################################
    # Step 3 -- Version Requirements
    #######################################################################################

    Write-Section "STEP 3 -- VERSION REQUIREMENTS"

    $ExpectedVersion = $null
    $MinimumVersion  = $null

    Write-Host ""
    Write-Host "  Installed version : $($SelectedApp.DisplayVersion)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Version checking options:" -ForegroundColor Cyan
    Write-Host "    None (recommended) -- any installed version passes detection." -ForegroundColor DarkGray
    Write-Host "                         Best for supersedence and upgrades." -ForegroundColor DarkGray
    Write-Host "    Minimum version    -- pass only if installed version >= a baseline." -ForegroundColor DarkGray
    Write-Host "    Exact version      -- pass only if exactly this version is installed." -ForegroundColor DarkGray
    Write-Host "                         Breaks supersedence -- avoid unless absolutely needed." -ForegroundColor DarkGray
    Write-Host ""

    if (Read-YN "Set a minimum version requirement?" -DefaultNo) {
        Write-Host "  Current version: $($SelectedApp.DisplayVersion)" -ForegroundColor DarkGray
        Write-Host "  Enter minimum version (e.g. '$($SelectedApp.DisplayVersion)'):" -ForegroundColor Cyan
        $MinInput = (Read-Host "  Minimum version").Trim()
        if (-not [string]::IsNullOrWhiteSpace($MinInput)) {
            $MinimumVersion = $MinInput
            Write-Host "  Minimum version set to: $MinimumVersion" -ForegroundColor Green
        }
    }

    if (Read-YN "Set an exact version requirement? (not recommended for supersedence)" -DefaultNo) {
        Write-Host "  Current version: $($SelectedApp.DisplayVersion)" -ForegroundColor DarkGray
        Write-Host "  Enter exact version (or press Enter to use current: $($SelectedApp.DisplayVersion)):" -ForegroundColor Cyan
        $ExactInput = (Read-Host "  Exact version").Trim()
        $ExpectedVersion = if ([string]::IsNullOrWhiteSpace($ExactInput)) { $SelectedApp.DisplayVersion } else { $ExactInput }
        Write-Host "  Exact version set to: $ExpectedVersion" -ForegroundColor Green
    }

    #######################################################################################
    # Step 4 -- Confirm and Generate
    #######################################################################################

    Write-Section "STEP 4 -- CONFIRM AND GENERATE"

    Write-Host ""
    Write-Host "  Application      : $($SelectedApp.DisplayName)" -ForegroundColor White
    Write-Host "  Detection method : $DetectionMethod" -ForegroundColor White

    switch ($DetectionMethod) {
        "DisplayName"  { Write-Host "  Name filter      : $DisplayNameFilter" -ForegroundColor White }
        "RegistryGUID" { Write-Host "  Registry path    : $RegistryPath" -ForegroundColor White }
        "File"         { Write-Host "  File path        : $FilePath" -ForegroundColor White }
        "Service"      { Write-Host "  Service name     : $ServiceName" -ForegroundColor White }
    }

    $VerLine = if ($ExpectedVersion) { "Exact: $ExpectedVersion" } `
               elseif ($MinimumVersion) { "Minimum: $MinimumVersion" } `
               else { "None (any version)" }
    Write-Host "  Version check    : $VerLine" -ForegroundColor White
    Write-Host ""

    if (-not (Read-YN "Generate the detection script?")) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }

    # Build and write the script
    $ScriptContent, $SafeName = Build-DetectScript `
        -AppName          $SelectedApp.DisplayName `
        -DetectionMethod  $DetectionMethod `
        -DisplayNameFilter $DisplayNameFilter `
        -RegistryPath     $RegistryPath `
        -FilePath         $FilePath `
        -ServiceName      $ServiceName `
        -ExpectedVersion  $ExpectedVersion `
        -MinimumVersion   $MinimumVersion

    # Determine output folder - same folder as this script if available
    if ($PSScriptRoot -and $PSScriptRoot -ne "") {
        $OutputFolder = $PSScriptRoot
    } elseif ($MyInvocation.MyCommand.Path) {
        $OutputFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
    } else {
        $OutputFolder = (Get-Location).Path
    }

    $OutputPath = Join-Path $OutputFolder "Detect-$SafeName.ps1"
    $ScriptContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

    Write-Host ""
    Write-Host "  Detection script generated:" -ForegroundColor Green
    Write-Host "  $OutputPath" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To test it now:" -ForegroundColor DarkGray
    Write-Host "    powershell.exe -ExecutionPolicy Bypass -File `"$OutputPath`"" -ForegroundColor DarkGray
    Write-Host "    echo `$LASTEXITCODE   (0 = detected, 1 = not detected)" -ForegroundColor DarkGray
    Write-Host ""

    # Offer to test immediately
    if (Read-YN "Run the detection script now to verify?") {
        Write-Host ""
        Write-Host "  Running: $OutputPath" -ForegroundColor DarkGray
        Write-Host ""
        & powershell.exe -ExecutionPolicy Bypass -File $OutputPath
        $TestResult = $LASTEXITCODE
        Write-Host ""
        if ($TestResult -eq 0) {
            Write-Host "  Result : EXIT 0 -- DETECTED" -ForegroundColor Green
        } else {
            Write-Host "  Result : EXIT 1 -- NOT DETECTED" -ForegroundColor Yellow
            Write-Host "  Tip: If you just installed the app, try re-running. Some apps take a moment to register." -ForegroundColor DarkGray
        }
        Write-Host ""
    }

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
