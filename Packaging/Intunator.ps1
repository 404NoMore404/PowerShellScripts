###########################################################################################
# New-IntunePackage.ps1
# Version 1.0
#
# Complete Intune Win32 Package Builder
# Guides you from raw installer to a ready-to-upload package folder
#
# WHAT IT DOES:
#   1.  Pick your installer via File Explorer dialog
#   2.  Auto-detect app name, version, publisher from the file
#   3.  Build the silent install command (type-detected + user confirmed)
#   4.  Build the silent uninstall command (pulled from registry or configured)
#   5.  Build the detection rule (registry scan, file, or service)
#   6.  Collect Intune metadata (architecture, min OS, install context)
#   7.  Generate Install / Uninstall / Detect scripts ready to deploy
#   8.  Write a Package-Summary.txt with every Intune upload field pre-filled
#   9.  Flag anything unusual in Escalation-Notes.txt for senior review
#   10. Optionally wrap with IntuneWinAppUtil.exe to produce the .intunewin file
#
# OUTPUT FOLDER STRUCTURE:
#   [OutputRoot]\[AppName]_[Version]\
#     Source\
#       [installer file]
#       Install-[AppName].ps1
#       Uninstall-[AppName].ps1
#       Detect-[AppName].ps1
#     Package-Summary.txt
#     Escalation-Notes.txt     (only if issues were flagged)
#     [AppName].intunewin      (only if IntuneWinAppUtil.exe was found/provided)
#
# ESCALATION:
#   If the app cannot be packaged fully automatically, the script flags exactly
#   what needs manual review in Escalation-Notes.txt so a senior engineer can
#   pick it up without starting from scratch.
#
# HOW TO USE:
#   powershell.exe -ExecutionPolicy Bypass -File ".\New-IntunePackage.ps1"
#
# Last Updated: 2026-03-13
###########################################################################################

[CmdletBinding()]
Param(
    [string]$OutputRoot = ""
)

###########################################################################################
# SHARED HELPERS
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
    param([string]$Title, [string]$Subtitle = "")
    $Divider = "-" * 80
    Write-Host ""
    Write-Host $Divider -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor DarkGray }
    Write-Host $Divider -ForegroundColor Cyan
}

Function Read-YN {
    param([string]$Prompt, [switch]$DefaultNo)
    $Indicator = if ($DefaultNo) { "[y/N]" } else { "[Y/n]" }
    Write-Host "  $Prompt $Indicator : " -ForegroundColor Cyan -NoNewline
    $Answer = (Read-Host).Trim()
    if ($DefaultNo) { return ($Answer -match '^[Yy]') }
    else            { return ($Answer -eq '' -or $Answer -match '^[Yy]') }
}

Function Add-EscalationFlag {
    param([string]$Flag)
    $script:EscalationFlags += $Flag
}

###########################################################################################
# FILE PICKER
###########################################################################################

Function Show-FilePicker {
    param([string]$Title = "Select File", [string]$Filter = "All Files (*.*)|*.*", [string]$InitialDirectory = "C:\")
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $Dialog                  = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title            = $Title
    $Dialog.Filter           = $Filter
    $Dialog.InitialDirectory = $InitialDirectory
    $Dialog.Multiselect      = $false
    $Owner  = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $Result = $Dialog.ShowDialog($Owner)
    $Owner.Dispose()
    if ($Result -eq [System.Windows.Forms.DialogResult]::OK) { return $Dialog.FileName }
    return $null
}

###########################################################################################
# INSTALLER DETECTION
###########################################################################################

Function Resolve-InstallerType {
    param([PSCustomObject]$File)

    $Info = [PSCustomObject]@{
        Type            = ""
        SuggestedArgs   = ""
        InstallCommand  = ""
        Confidence      = "High"
        Notes           = ""
        IsInstallShield = $false
        IsSquirrel      = $false
    }

    if ($File.Extension -eq ".msi") {
        $Info.Type           = "MSI"
        $Info.SuggestedArgs  = "/quiet /norestart"
        $Info.InstallCommand = "msiexec.exe /i `"$($File.Name)`" /quiet /norestart"
        $Info.Notes          = "Standard MSI -- reliable silent flags"
        return $Info
    }

    if ($File.Extension -eq ".msp") {
        $Info.Type           = "MSP"
        $Info.SuggestedArgs  = "/quiet /norestart"
        $Info.InstallCommand = "msiexec.exe /p `"$($File.Name)`" /quiet /norestart"
        $Info.Notes          = "MSI patch"
        return $Info
    }

    if ($File.Extension -eq ".exe") {
        try {
            $Bytes  = [System.IO.File]::ReadAllBytes($File.FullPath) | Select-Object -First 4096
            $Header = [System.Text.Encoding]::ASCII.GetString($Bytes) -replace '[^\x20-\x7E]', ' '

            if ($Header -match 'Inno Setup') {
                $Info.Type           = "EXE-Inno"
                $Info.SuggestedArgs  = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
                $Info.InstallCommand = "`"$($File.Name)`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
                $Info.Notes          = "Inno Setup detected from file header"
                return $Info
            }
            if ($Header -match 'Nullsoft') {
                $Info.Type           = "EXE-NSIS"
                $Info.SuggestedArgs  = "/S"
                $Info.InstallCommand = "`"$($File.Name)`" /S"
                $Info.Notes          = "NSIS (Nullsoft) detected"
                return $Info
            }
            if ($Header -match 'InstallShield') {
                $Info.Type            = "EXE-InstallShield"
                $Info.SuggestedArgs   = "/s /v`"/qn /norestart`""
                $Info.InstallCommand  = "`"$($File.Name)`" /s /v`"/qn /norestart`""
                $Info.Confidence      = "Medium"
                $Info.IsInstallShield = $true
                $Info.Notes           = "InstallShield detected -- may need ISS response file for complex setups"
                return $Info
            }
            if ($Header -match 'WiX|Windows Installer XML') {
                $Info.Type           = "EXE-WiX"
                $Info.SuggestedArgs  = "/quiet /norestart"
                $Info.InstallCommand = "`"$($File.Name)`" /quiet /norestart"
                $Info.Notes          = "WiX bootstrapper detected"
                return $Info
            }
            if ($File.SizeMB -lt 2 -and ($File.Name -match '(?i)setup|update')) {
                $Info.Type           = "EXE-Squirrel"
                $Info.SuggestedArgs  = "--silent"
                $Info.InstallCommand = "`"$($File.Name)`" --silent"
                $Info.Confidence     = "Medium"
                $Info.IsSquirrel     = $true
                $Info.Notes          = "Possible Squirrel installer (small bootstrap EXE). Exits with null code -- verify by checking registry after install."
                return $Info
            }
        } catch { }

        $Info.Type           = "EXE"
        $Info.SuggestedArgs  = "/S"
        $Info.InstallCommand = "`"$($File.Name)`" /S"
        $Info.Confidence     = "Medium"
        $Info.Notes          = "Unknown EXE type -- /S is a common silent flag but may not work for all apps"
        return $Info
    }

    $Info.Type       = "UNKNOWN"
    $Info.Confidence = "Low"
    return $Info
}

###########################################################################################
# REGISTRY HELPERS
###########################################################################################

Function Get-InstalledApps {
    param([string]$SearchTerm)
    $Paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $Results = @()
    foreach ($Path in $Paths) {
        if (-not (Test-Path $Path)) { continue }
        Get-ChildItem $Path -ErrorAction SilentlyContinue | ForEach-Object {
            $P = Get-ItemProperty $_.PsPath -ErrorAction SilentlyContinue
            if ($P.SystemComponent -eq 1) { return }
            if ([string]::IsNullOrWhiteSpace($P.DisplayName)) { return }
            if ($P.DisplayName -like "*$SearchTerm*") {
                $Results += [PSCustomObject]@{
                    DisplayName     = $P.DisplayName
                    DisplayVersion  = $P.DisplayVersion
                    Publisher       = $P.Publisher
                    InstallLocation = $P.InstallLocation
                    PSChildName     = $_.PSChildName
                    RegistryPath    = $_.PsPath
                    UninstallString = $P.UninstallString
                    QuietUninstall  = $P.QuietUninstallString
                }
            }
        }
    }
    return $Results
}

Function Resolve-UninstallMethod {
    param([PSCustomObject]$App)
    $M = [PSCustomObject]@{
        Type             = ""
        ProductCode      = ""
        ExePath          = ""
        ExeArgs          = ""
        UninstallCommand = ""
        Confidence       = "High"
        Notes            = ""
    }
    if ($App.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
        $M.Type             = "MSI"
        $M.ProductCode      = $App.PSChildName
        $M.UninstallCommand = "msiexec.exe /x $($App.PSChildName) /quiet /norestart"
        return $M
    }
    if (-not [string]::IsNullOrWhiteSpace($App.QuietUninstall)) {
        $M.Type             = "EXE"
        $M.UninstallCommand = $App.QuietUninstall
        $M.Notes            = "Using QuietUninstallString from registry"
        return $M
    }
    if (-not [string]::IsNullOrWhiteSpace($App.UninstallString)) {
        if ($App.UninstallString -match 'msiexec' -and $App.UninstallString -match '\{[0-9A-Fa-f\-]{36}\}') {
            $Guid = ([regex]::Match($App.UninstallString, '\{[0-9A-Fa-f\-]{36}\}')).Value
            $M.Type             = "MSI"
            $M.ProductCode      = $Guid
            $M.UninstallCommand = "msiexec.exe /x $Guid /quiet /norestart"
            $M.Notes            = "GUID extracted from UninstallString"
            return $M
        }
        $M.Type             = "EXE"
        $M.UninstallCommand = $App.UninstallString + " /S"
        $M.Confidence       = "Medium"
        $M.Notes            = "Uninstall args guessed -- verify before deploying"
        return $M
    }
    $M.Type       = "UNKNOWN"
    $M.Confidence = "Low"
    $M.Notes      = "Could not determine uninstall method"
    return $M
}

###########################################################################################
# SCRIPT GENERATORS
###########################################################################################

Function Build-InstallScript {
    param($SafeName, $AppName, $InstallerFileName, $InstallerType, $InstallArgs, $DateStamp)
    $IsMSI = ($InstallerType -eq "MSI" -or $InstallerType -eq "MSP")
    $Verb  = if ($InstallerType -eq "MSP") { "/p" } else { "/i" }
return @"
###########################################################################################
# Install-$SafeName.ps1  --  Generated by New-IntunePackage.ps1 on $DateStamp
# Intune silent installer wrapper for: $AppName
###########################################################################################
[CmdletBinding()] Param()

`$AppName          = "$AppName"
`$InstallerFile    = "$InstallerFileName"
`$InstallArguments = "$InstallArgs"
`$LogFolderName    = "$SafeName"

Function Main {
    `$STARTTIME  = Get-Date
    `$LogFolder  = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`$LogFolderName"
    if (-not (Test-Path `$LogFolder)) { New-Item -Path `$LogFolder -ItemType Directory -Force | Out-Null }
    `$Timestamp  = Get-Date -Format "yyyy-MM-dd_HHmmss"
    `$LogFile    = "`$LogFolder\`$(`$LogFolderName)_Installer_`$Timestamp.log"
    Function Write-Log { param([string]`$M,[string]`$L='INFO') `$E="``$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  [`$(`$L.PadRight(5))]  `$M"; Add-Content `$LogFile `$E -EA SilentlyContinue; switch(`$L){'ERROR'{Write-Host `$E -ForegroundColor Red}'WARN'{Write-Host `$E -ForegroundColor Yellow}'OK'{Write-Host `$E -ForegroundColor Green}default{Write-Host `$E}} }
    Write-Log "`$AppName -- INSTALL START"
    Write-Log "Computer : `$env:COMPUTERNAME  |  User : `$env:USERNAME"
    `$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not `$IsAdmin) { Write-Log "Must run as Administrator." "ERROR"; exit 1 }
    if (`$PSScriptRoot) { `$Dir = `$PSScriptRoot } elseif (`$MyInvocation.MyCommand.Path) { `$Dir = Split-Path `$MyInvocation.MyCommand.Path } else { `$Dir = (Get-Location).Path }
    `$InstallerPath = Join-Path `$Dir `$InstallerFile
    if (-not (Test-Path `$InstallerPath)) { Write-Log "Installer not found: `$InstallerPath" "ERROR"; exit 1 }
    Write-Log "Installer : `$InstallerPath" "OK"
    try {
$(if ($IsMSI) {
"        `$MsiLog = `"`$LogFolder\`$(`$LogFolderName)_MSI_`$Timestamp.log`"
        `$MsiArgs = `"$Verb ``\`"`$InstallerPath``\`" `$InstallArguments /l*v ``\`"`$MsiLog``\`"`"
        Write-Log `"Running: msiexec.exe `$MsiArgs`"
        `$P = Start-Process msiexec.exe -ArgumentList `$MsiArgs -Wait -PassThru -NoNewWindow"
} else {
"        Write-Log `"Running: `$InstallerPath `$InstallArguments`"
        `$P = Start-Process `$InstallerPath -ArgumentList `$InstallArguments -Wait -PassThru -NoNewWindow"
})
        `$Code = if (`$null -eq `$P.ExitCode) { Write-Log "Null exit code (Squirrel-style installer) -- treating as success." "WARN"; 0 } else { `$P.ExitCode }
        Write-Log "Exit code: `$Code"
        if (`$Code -eq 0) { Write-Log "Install succeeded." "OK" }
        elseif (`$Code -eq 3010 -or `$Code -eq 1641) { Write-Log "Install succeeded -- reboot required." "OK" }
        else { Write-Log "Unexpected exit code `$Code." "ERROR"; exit `$Code }
    } catch { Write-Log "Exception: `$(`$_.Exception.Message)" "ERROR"; exit 1 }
    Write-Log "Duration: `$((Get-Date)-`$STARTTIME)"
    exit 0
}
try { Main } catch { Write-Host "FATAL: `$(`$_.Exception.Message)" -ForegroundColor Red; exit 1 }
"@
}

Function Build-UninstallScript {
    param(
        $SafeName, $AppName, $DisplayNameFilter,
        $FallbackMethod, $FallbackProductCode, $FallbackExePath, $FallbackExeArgs,
        $DateStamp
    )
$Script = @"
###########################################################################################
# Uninstall-$SafeName.ps1  --  Generated by New-IntunePackage.ps1 on $DateStamp
# Intune silent uninstaller wrapper for: $AppName
#
# STRATEGY: Scans the registry by DisplayName at runtime so it handles ANY installed
# version. Falls back to a known uninstall command if dynamic scan cannot determine
# the method on its own.
###########################################################################################
[CmdletBinding()] Param()

`$AppDisplayNameFilter = "$DisplayNameFilter"
`$FallbackMethod       = "$FallbackMethod"
`$FallbackProductCode  = "$FallbackProductCode"
`$FallbackExePath      = "$FallbackExePath"
`$FallbackExeArgs      = "$FallbackExeArgs"
`$LogFolderName        = "$SafeName"

`$UninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)

Function Main {
    `$STARTTIME = Get-Date
    `$LogFolder = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\`$LogFolderName"
    if (-not (Test-Path `$LogFolder)) { New-Item `$LogFolder -ItemType Directory -Force | Out-Null }
    `$Timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    `$LogFile   = "`$LogFolder\`$(`$LogFolderName)_Uninstaller_`$Timestamp.log"
    Function Write-Log {
        param([string]`$M,[string]`$L='INFO')
        `$E = "`$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  [`$(`$L.PadRight(5))]  `$M"
        Add-Content `$LogFile `$E -EA SilentlyContinue
        switch(`$L) { 'ERROR'{Write-Host `$E -ForegroundColor Red} 'WARN'{Write-Host `$E -ForegroundColor Yellow} 'OK'{Write-Host `$E -ForegroundColor Green} default{Write-Host `$E} }
    }

    Write-Log "$AppName -- UNINSTALL START"
    `$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not `$IsAdmin) { Write-Log "Must run as Administrator." "ERROR"; exit 1 }

    `$Found = @()
    foreach (`$Path in `$UninstallPaths) {
        if (-not (Test-Path `$Path)) { continue }
        Get-ChildItem `$Path -EA SilentlyContinue | ForEach-Object {
            `$P = Get-ItemProperty `$_.PsPath -EA SilentlyContinue
            if (`$P.SystemComponent -eq 1) { return }
            if ([string]::IsNullOrWhiteSpace(`$P.DisplayName)) { return }
            if (`$P.DisplayName -like `$AppDisplayNameFilter) {
                `$Found += [PSCustomObject]@{
                    DisplayName     = `$P.DisplayName
                    DisplayVersion  = `$P.DisplayVersion
                    PSChildName     = `$_.PSChildName
                    RegistryPath    = `$_.PsPath
                    QuietUninstall  = `$P.QuietUninstallString
                    UninstallString = `$P.UninstallString
                }
            }
        }
    }

    if (`$Found.Count -eq 0) {
        Write-Log "$AppName not found in registry (filter: `$AppDisplayNameFilter) -- may already be uninstalled." "WARN"
        exit 0
    }

    Write-Log "Found `$(`$Found.Count) install(s) matching '`$AppDisplayNameFilter'."
    `$AnyFailed = `$false

    foreach (`$App in `$Found) {
        Write-Log "Processing: `$(`$App.DisplayName) v`$(`$App.DisplayVersion)"

        `$ExecPath = ""; `$ExecArgs = ""; `$Method = ""

        if (-not [string]::IsNullOrWhiteSpace(`$App.QuietUninstall)) {
            Write-Log "Method: QuietUninstallString"
            if (`$App.QuietUninstall -match '^"([^"]+)"(.*)$') {
                `$ExecPath = `$Matches[1]; `$ExecArgs = `$Matches[2].Trim()
            } else {
                `$Parts = `$App.QuietUninstall -split ' ',2
                `$ExecPath = `$Parts[0]; `$ExecArgs = if (`$Parts.Count -gt 1) { `$Parts[1] } else { "" }
            }
            `$Method = "EXE"
        }
        elseif (`$App.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
            Write-Log "Method: MSI GUID from registry key name"
            `$MsiLog   = "`$LogFolder\`$(`$LogFolderName)_MSI_`$Timestamp.log"
            `$ExecPath = "msiexec.exe"
            `$ExecArgs = "/x `$(`$App.PSChildName) /quiet /norestart /l*v ``"`$MsiLog``""
            `$Method   = "MSI"
        }
        elseif (-not [string]::IsNullOrWhiteSpace(`$App.UninstallString) -and `$App.UninstallString -match 'msiexec') {
            `$Guid = ([regex]::Match(`$App.UninstallString,'\{[0-9A-Fa-f\-]{36}\}')).Value
            if (`$Guid) {
                Write-Log "Method: MSI GUID from UninstallString"
                `$MsiLog   = "`$LogFolder\`$(`$LogFolderName)_MSI_`$Timestamp.log"
                `$ExecPath = "msiexec.exe"
                `$ExecArgs = "/x `$Guid /quiet /norestart /l*v ``"`$MsiLog``""
                `$Method   = "MSI"
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace(`$App.UninstallString)) {
            Write-Log "Method: EXE UninstallString (appending /S)" "WARN"
            if (`$App.UninstallString -match '^"([^"]+)"(.*)$') {
                `$ExecPath = `$Matches[1]; `$ExecArgs = (`$Matches[2].Trim() + " /S").Trim()
            } else {
                `$Parts = `$App.UninstallString -split ' ',2
                `$ExecPath = `$Parts[0]; `$ExecArgs = ((if (`$Parts.Count -gt 1) {`$Parts[1]} else {""}) + " /S").Trim()
            }
            `$Method = "EXE"
        }
        elseif (-not [string]::IsNullOrWhiteSpace(`$FallbackMethod)) {
            Write-Log "Method: Fallback from package time (method: `$FallbackMethod)" "WARN"
            if (`$FallbackMethod -eq "MSI") {
                `$MsiLog   = "`$LogFolder\`$(`$LogFolderName)_MSI_`$Timestamp.log"
                `$ExecPath = "msiexec.exe"
                `$ExecArgs = "/x `$FallbackProductCode /quiet /norestart /l*v ``"`$MsiLog``""
                `$Method   = "MSI"
            } else {
                `$ExecPath = `$FallbackExePath; `$ExecArgs = `$FallbackExeArgs; `$Method = "EXE"
            }
        }
        else {
            Write-Log "No uninstall method could be determined for `$(`$App.DisplayName). Skipping." "ERROR"
            `$AnyFailed = `$true
            continue
        }

        try {
            Write-Log "Running: `$ExecPath `$ExecArgs"
            `$P    = Start-Process `$ExecPath -ArgumentList `$ExecArgs -Wait -PassThru -NoNewWindow
            `$Code = if (`$null -eq `$P.ExitCode) { 0 } else { `$P.ExitCode }
            Write-Log "Exit code: `$Code"
            if (`$Code -eq 0 -or `$Code -eq 3010 -or `$Code -eq 1641) {
                Write-Log "Uninstall succeeded: `$(`$App.DisplayName)" "OK"
            } else {
                Write-Log "Unexpected exit code `$Code for `$(`$App.DisplayName)." "ERROR"
                `$AnyFailed = `$true
            }
        } catch {
            Write-Log "Exception: `$(`$_.Exception.Message)" "ERROR"
            `$AnyFailed = `$true
        }
    }

    Start-Sleep -Seconds 5

    `$Remaining = @()
    foreach (`$Path in `$UninstallPaths) {
        if (-not (Test-Path `$Path)) { continue }
        Get-ChildItem `$Path -EA SilentlyContinue | ForEach-Object {
            `$P = Get-ItemProperty `$_.PsPath -EA SilentlyContinue
            if (`$P.DisplayName -like `$AppDisplayNameFilter) { `$Remaining += `$P.DisplayName }
        }
    }

    if (`$Remaining.Count -eq 0) { Write-Log "All registry entries removed. Uninstall verified." "OK" }
    else { Write-Log "Still present: `$(`$Remaining -join ', '). Reboot may be required." "WARN" }

    # ── SHORTCUT CLEANUP ─────────────────────────────────────────────────────────
    Write-Log "Scanning for leftover shortcuts..."

    `$AppNameWords    = (`$AppDisplayNameFilter -replace '[*]','').Trim()
    `$ShortcutRemoved = 0

    `$ShortcutRoots = @(
        [System.Environment]::GetFolderPath('CommonPrograms'),
        [System.Environment]::GetFolderPath('CommonDesktopDirectory'),
        [System.Environment]::GetFolderPath('Programs'),
        [System.Environment]::GetFolderPath('Desktop')
    )

    `$ProfileRoots = Get-ChildItem 'C:\Users' -Directory -EA SilentlyContinue |
        Where-Object { `$_.Name -notmatch '^(Public|Default.*|All Users)$' }
    foreach (`$Prof in `$ProfileRoots) {
        `$ShortcutRoots += Join-Path `$Prof.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
        `$ShortcutRoots += Join-Path `$Prof.FullName 'Desktop'
    }

    foreach (`$Root in (`$ShortcutRoots | Select-Object -Unique)) {
        if (-not (Test-Path `$Root)) { continue }
        Get-ChildItem `$Root -Recurse -Include '*.lnk','*.url' -EA SilentlyContinue | ForEach-Object {
            if (`$_.BaseName -like `$AppDisplayNameFilter -or `$_.BaseName -like "*`$AppNameWords*") {
                try {
                    Remove-Item `$_.FullName -Force -EA Stop
                    Write-Log "Removed shortcut: `$(`$_.FullName)" "OK"
                    `$ShortcutRemoved++
                } catch {
                    Write-Log "Could not remove shortcut `$(`$_.FullName): `$(`$_.Exception.Message)" "WARN"
                }
            }
        }
        Get-ChildItem `$Root -Recurse -Directory -EA SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                if ((Get-ChildItem `$_.FullName -EA SilentlyContinue).Count -eq 0) {
                    try { Remove-Item `$_.FullName -Force -EA SilentlyContinue } catch { }
                }
            }
    }

    Write-Log "Shortcut cleanup complete. Removed: `$ShortcutRemoved shortcut(s)."

    Write-Log "Duration: `$((Get-Date)-`$STARTTIME)"
    if (`$AnyFailed) { exit 1 } else { exit 0 }
}
try { Main } catch { Write-Host "FATAL: `$(`$_.Exception.Message)" -ForegroundColor Red; exit 1 }
"@
    return $Script
}

Function Build-DetectScript {
    param($SafeName, $AppName, $DetectionMethod, $DisplayNameFilter, $RegistryPath, $FilePath, $ServiceName, $MinVersion, $DateStamp)
    $ExpVerLine = '$null'
    $MinVerLine = if ([string]::IsNullOrWhiteSpace($MinVersion)) { '$null' } else { "`"$MinVersion`"" }
    $ActiveMethod = switch ($DetectionMethod) {
        "DisplayName"  { "`$DetectionMethod = `"DisplayName`"`n`$DisplayNameFilter = `"$DisplayNameFilter`"" }
        "RegistryGUID" { "`$DetectionMethod = `"RegistryGUID`"`n`$RegistryPath = `"$RegistryPath`"" }
        "File"         { "`$DetectionMethod = `"File`"`n`$DetectionFilePath = `"$FilePath`"" }
        "Service"      { "`$DetectionMethod = `"Service`"`n`$DetectionServiceName = `"$ServiceName`"" }
    }
return @"
###########################################################################################
# Detect-$SafeName.ps1  --  Generated by New-IntunePackage.ps1 on $DateStamp
# Intune detection script for: $AppName
# Exit 0 + output = DETECTED   |   Exit 1 no output = NOT DETECTED
###########################################################################################

$ActiveMethod
`$ExpectedVersion = $ExpVerLine
`$MinimumVersion  = $MinVerLine

`$Detected = `$false; `$DetectedMessage = ""
`$UninstallPaths = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall","HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall","HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall")
function Test-Version { param([string]`$I) if (`$ExpectedVersion) { return `$I -eq `$ExpectedVersion } if (`$MinimumVersion) { try { return [version]`$I -ge [version]`$MinimumVersion } catch { return `$I -ge `$MinimumVersion } } return `$true }

switch (`$DetectionMethod) {
    "DisplayName"  { foreach (`$P in `$UninstallPaths) { `$I = Get-ChildItem `$P -EA SilentlyContinue | Get-ItemProperty -EA SilentlyContinue | Where-Object { `$_.DisplayName -like `$DisplayNameFilter }; foreach (`$A in `$I) { if (Test-Version `$A.DisplayVersion) { `$Detected=`$true; `$DetectedMessage="DETECTED: `$(`$A.DisplayName) v`$(`$A.DisplayVersion)"; break } }; if (`$Detected) { break } } }
    "RegistryGUID" { `$I = Get-ItemProperty `$RegistryPath -EA SilentlyContinue; if (`$I -and (Test-Version `$I.DisplayVersion)) { `$Detected=`$true; `$DetectedMessage="DETECTED: `$(`$I.DisplayName) v`$(`$I.DisplayVersion)" } }
    "File"         { if (Test-Path `$DetectionFilePath) { `$Detected=`$true; `$DetectedMessage="DETECTED: `$DetectionFilePath" } }
    "Service"      { `$S = Get-Service -Name `$DetectionServiceName -EA SilentlyContinue; if (`$S) { `$Detected=`$true; `$DetectedMessage="DETECTED: `$DetectionServiceName (`$(`$S.Status))" } }
}
if (`$Detected) { Write-Host `$DetectedMessage; exit 0 } else { exit 1 }
"@
}

###########################################################################################
# PACKAGE SUMMARY GENERATOR
###########################################################################################

Function Build-PackageSummary {
    param(
        [hashtable]$Pkg,
        [System.Collections.Generic.List[string]]$Flags
    )

    $DateStamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    $FlagBlock = if ($Flags.Count -gt 0) {
        "  !! SEE Escalation-Notes.txt FOR ITEMS NEEDING MANUAL REVIEW !!"
    } else {
        "  No escalation flags -- package appears ready to deploy."
    }

return @"
###########################################################################################
#
#  INTUNE WIN32 PACKAGE SUMMARY
#  Generated : $DateStamp
#  App       : $($Pkg.AppName)  v$($Pkg.AppVersion)
#
$FlagBlock
#
###########################################################################################

=======================================================================================
  INTUNE UPLOAD FIELDS  (Add > Apps > Windows > Win32)
=======================================================================================

  Name                  : $($Pkg.AppName)
  Description           : $($Pkg.Description)
  Publisher             : $($Pkg.Publisher)
  App Version           : $($Pkg.AppVersion)
  Information URL       :
  Privacy URL           :
  Notes                 : Packaged by New-IntunePackage.ps1 on $DateStamp

=======================================================================================
  PROGRAM TAB
=======================================================================================

  Install command       : powershell.exe -ExecutionPolicy Bypass -File ".\Install-$($Pkg.SafeName).ps1"
  Uninstall command     : powershell.exe -ExecutionPolicy Bypass -File ".\Uninstall-$($Pkg.SafeName).ps1"
  Install behavior      : $($Pkg.InstallBehavior)
  Device restart        : $($Pkg.RestartBehavior)

  Return codes (add these in Intune if not already present):
    0    = Success
    3010 = Soft reboot (success, reboot required)
    1641 = Hard reboot (success, reboot required)

=======================================================================================
  REQUIREMENTS TAB
=======================================================================================

  Operating system      : $($Pkg.MinOS)
  Architecture          : $($Pkg.Architecture)

=======================================================================================
  DETECTION RULES TAB
=======================================================================================

  Rule type             : Custom script
  Script file           : Detect-$($Pkg.SafeName).ps1
  Run as 32-bit         : No
  Detection method      : $($Pkg.DetectionMethod)
  Detection detail      : $($Pkg.DetectionDetail)

=======================================================================================
  SOURCE FILES
=======================================================================================

  Installer             : $($Pkg.InstallerFileName)
  Installer type        : $($Pkg.InstallerType)
  Install args          : $($Pkg.InstallArgs)
  Uninstall method      : $($Pkg.UninstallMethod)
  Uninstall command     : $($Pkg.UninstallCommand)

=======================================================================================
  PACKAGE FOLDER
=======================================================================================

  Source folder         : $($Pkg.SourceFolder)
  .intunewin file       : $($Pkg.IntuneWinPath)

=======================================================================================
  INTUNE UPLOAD STEPS
=======================================================================================

  1.  Go to: Intune admin center > Apps > Windows > Add > App type: Windows app (Win32)
  2.  Upload the .intunewin file listed above
  3.  Fill in all fields from the INTUNE UPLOAD FIELDS section above
  4.  Program tab: paste Install and Uninstall commands exactly as shown
  5.  Requirements tab: set OS and architecture as listed
  6.  Detection tab: select Custom script and upload Detect-$($Pkg.SafeName).ps1
  7.  Assignments tab: assign to a test group first -- do not deploy broadly until verified
  8.  Monitor the install in Intune device blade and review logs at:
        C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\$($Pkg.SafeName)\

"@
}

Function Build-EscalationNotes {
    param(
        [hashtable]$Pkg,
        [System.Collections.Generic.List[string]]$Flags,
        [System.Collections.Generic.List[object]]$InstallAttempts   = $null,
        [System.Collections.Generic.List[object]]$UninstallAttempts = $null
    )
    $DateStamp = Get-Date -Format "yyyy-MM-dd HH:mm"
$Out = @"
###########################################################################################
#
#  ESCALATION NOTES  --  $($Pkg.AppName)
#  Generated : $DateStamp
#
#  The items below were flagged during packaging and need manual review
#  before this package is ready to deploy to production.
#
###########################################################################################

"@
    $Num = 0
    foreach ($Flag in $Flags) {
        $Num++
        $Out += "  [$Num]  $Flag`r`n`r`n"
    }

    if ($InstallAttempts -and $InstallAttempts.Count -gt 0) {
        $Out += @"

=======================================================================================
  INSTALL VERIFICATION ATTEMPTS  ($($InstallAttempts.Count) total)
=======================================================================================

"@
        foreach ($A in $InstallAttempts) {
            $Status = if ($A.Success) { "PASS" } else { "FAIL" }
            $Out += "  [$Status]  Args      : $($A.Args)`r`n"
            $Out += "           Exit code  : $($A.ExitCode)  $(if($A.ExitCodeOk){'(clean)'}else{'(unexpected)'})`r`n"
            $Out += "           Registry   : $(if($A.RegistryFound){'App FOUND -- install confirmed'}else{'App NOT found after install'})`r`n"
            $Out += "           Silent     : $(if($A.WasSilent){'Yes -- confirmed by user'}elseif($A.WasSilent -eq $false){'NO -- visible windows appeared'}else{'Not checked'})`r`n"
            $Out += "           Source     : $($A.Source)`r`n"
            $Out += "           Time       : $($A.Timestamp)`r`n"
            if ($A.Error) { $Out += "           Error      : $($A.Error)`r`n" }
            $Out += "`r`n"
        }
        $WorkingInstall = $InstallAttempts | Where-Object { $_.Success } | Select-Object -First 1
        if ($WorkingInstall) {
            $Out += "  WORKING ARGS: $($WorkingInstall.Args)`r`n`r`n"
        } else {
            $Out += "  NO WORKING ARGS FOUND -- manual investigation required.`r`n`r`n"
        }
    }

    if ($UninstallAttempts -and $UninstallAttempts.Count -gt 0) {
        $Out += @"

=======================================================================================
  UNINSTALL VERIFICATION ATTEMPTS  ($($UninstallAttempts.Count) total)
=======================================================================================

"@
        foreach ($A in $UninstallAttempts) {
            $Status = if ($A.Success) { "PASS" } else { "FAIL" }
            $Out += "  [$Status]  Command    : $($A.Command)`r`n"
            $Out += "           Exit code  : $($A.ExitCode)  $(if($A.ExitCodeOk){'(clean)'}else{'(unexpected)'})`r`n"
            $Out += "           Registry   : $(if($A.RegistryGone){'App GONE -- removal confirmed'}else{'App STILL PRESENT after uninstall'})`r`n"
            $Out += "           Source     : $($A.Source)`r`n"
            $Out += "           Time       : $($A.Timestamp)`r`n"
            if ($A.Error) { $Out += "           Error      : $($A.Error)`r`n" }
            $Out += "`r`n"
        }
        $WorkingUninstall = $UninstallAttempts | Where-Object { $_.Success } | Select-Object -First 1
        if ($WorkingUninstall) {
            $Out += "  WORKING COMMAND: $($WorkingUninstall.Command)`r`n`r`n"
        } else {
            $Out += "  NO WORKING UNINSTALL FOUND -- manual investigation required.`r`n`r`n"
        }
    }

    $Out += @"

=======================================================================================
  WHAT TO DO
=======================================================================================

  Review each flag above and resolve it before deploying broadly.
  The partial package in the Source folder still contains everything collected
  automatically -- a senior engineer can start from here rather than from scratch.

  Common resolutions:
    Unknown EXE type      ->  Check vendor docs for silent install flags, or use
                               Process Monitor during a manual install to find args
    No registry entry     ->  Switch detection to File method pointing to main EXE
    Squirrel installer    ->  Verify with vendor if --silent is supported, or
                               pre-stage via Chocolatey/Winget package instead
    InstallShield         ->  Record an ISS file using Install-Interactive.ps1
    User-context install  ->  Change Install behavior to User in Intune Program tab
    Null exit code        ->  Already handled in the install script -- verify via
                               detection script after deploy
    Install not silent    ->  Try /SUPPRESSMSGBOXES, /qn, or equivalent; check vendor
                               docs for fully unattended install flags
    Install args failed   ->  Use Process Monitor (procmon) during a manual install
                               to capture the child processes and arguments used
    Uninstall not found   ->  Check vendor support docs; try running the uninstaller
                               manually from %AppData% or %LocalAppData% for user installs

"@
    return $Out
}


###########################################################################################
# INSTALL / UNINSTALL VERIFICATION HELPERS
###########################################################################################

# Returns an ordered list of arg combinations to auto-try.
# *** Ordered from most-suppressed to least -- the script tries the quietest
#     combination first so it finds a fully silent install before falling back
#     to anything that might show a window. ***
Function Get-AlternativeArgs {
    param([string]$InstallerType, [string]$PrimaryArgs)
    $Alts = switch ($InstallerType) {
        "MSI"               { @("/quiet /norestart",
                                "/qn /norestart",
                                "/quiet /qn /norestart",
                                "/passive /norestart",
                                "/quiet",
                                "/qn") }
        "MSP"               { @("/quiet /norestart", "/qn /norestart") }
        "EXE-Inno"          { @("/VERYSILENT /SUPPRESSMSGBOXES /NORESTART",
                                "/VERYSILENT /SUPPRESSMSGBOXES",
                                "/VERYSILENT /NORESTART",
                                "/SILENT /SUPPRESSMSGBOXES /NORESTART",
                                "/SILENT /NORESTART",
                                "/VERYSILENT",
                                "/S") }
        "EXE-NSIS"          { @("/S", "/S /NCRC", "/silent", "/S /D") }
        "EXE-InstallShield" { @('/s /v"/qn /norestart"',
                                '/s /v"/qn /norestart REBOOT=ReallySuppress"',
                                '/s /v"/qb /norestart"',
                                '/s /v"/qn"',
                                "/s",
                                "/SMS") }
        "EXE-WiX"           { @("/quiet /norestart",
                                "/quiet /norestart /nodialog",
                                "/quiet",
                                "/passive /norestart",
                                "/install /quiet /norestart") }
        "EXE-Squirrel"      { @("--silent",
                                "--silent --no-desktop-shortcut",
                                "--silent --no-shortcut",
                                "/S") }
        default             { @("-s",
                                "/s",
                                "--silent",
                                "/silent",
                                "/quiet",
                                "/S",
                                "/VERYSILENT /SUPPRESSMSGBOXES",
                                "/S /NCRC",
                                '/s /v"/qn"') }
    }
    $All = @($PrimaryArgs) + ($Alts | Where-Object { $_ -ne $PrimaryArgs })
    return $All | Select-Object -Unique
}

# Run a single install attempt, return a result object.
Function Invoke-InstallAttempt {
    param(
        [PSCustomObject]$File,
        [string]$InstallerType,
        [string]$InstallArgs,
        [string]$LogFolder,
        [string]$AppNameHint
    )
    $Timestamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $ExitCode     = -9999
    $ErrorMsg     = ""
    $LaunchFailed = $false

    try {
        if ($InstallerType -eq "MSI" -or $InstallerType -eq "MSP") {
            $Verb     = if ($InstallerType -eq "MSP") { "/p" } else { "/i" }
            $MsiLog   = Join-Path $LogFolder "verify_msi_$Timestamp.log"
            $FullArgs = "$Verb `"$($File.FullPath)`" $InstallArgs /l*v `"$MsiLog`""
            $P = Start-Process -FilePath "msiexec.exe" -ArgumentList $FullArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
        } else {
            $P = Start-Process -FilePath $File.FullPath -ArgumentList $InstallArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
        }
        $ExitCode = if ($null -eq $P.ExitCode) { 0 } else { $P.ExitCode }
    } catch {
        $ErrorMsg     = $_.Exception.Message
        $LaunchFailed = $true
    }

    # Squirrel launchers exit 0 immediately and spawn a child -- wait for child
    if ($ExitCode -eq 0 -and -not $LaunchFailed) {
        Start-Sleep -Seconds 8
    } else {
        Start-Sleep -Seconds 4
    }

    $ExitOk   = ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 1641)
    $RegFound = (@(Get-InstalledApps -SearchTerm $AppNameHint)).Count -gt 0

    return [PSCustomObject]@{
        Phase         = "Install"
        Source        = "Auto"
        Args          = $InstallArgs
        ExitCode      = $ExitCode
        ExitCodeOk    = $ExitOk
        RegistryFound = $RegFound
        LaunchFailed  = $LaunchFailed
        WasSilent     = $null   # filled in by silence check after PASS
        Success       = ($ExitOk -and $RegFound -and -not $LaunchFailed)
        Error         = $ErrorMsg
        Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

# After a technically successful install, ask whether it was truly silent.
# If not silent: attempt to auto-uninstall so the loop can retry with better args.
# Returns $true  = confirmed silent (or user chose to accept anyway) -> lock args
# Returns $false = not silent, uninstalled (or user said not to uninstall) -> retry
Function Invoke-SilenceCheck {
    param(
        [string]$TestedArgs,
        [string]$AppNameHint,
        [string]$LogFolder
    )

    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │  SILENCE CHECK                                              │" -ForegroundColor Cyan
    Write-Host "  │  Did the install run with ZERO visible windows?             │" -ForegroundColor Cyan
    Write-Host "  │  (Any dialog, progress bar, or the app launching afterward  │" -ForegroundColor Cyan
    Write-Host "  │   all count as NOT silent.)                                 │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
    Write-Host ""

    $WasSilent = Read-YN "Was the install completely silent (no windows appeared)?"

    if ($WasSilent) {
        Write-Host "  Confirmed silent. Args locked in: $TestedArgs" -ForegroundColor Green
        return $true
    }

    # Not silent -- need to clean up before trying next args
    Write-Host ""
    Write-Host "  [!] Install was NOT fully silent -- visible windows appeared." -ForegroundColor Yellow
    Write-Host "      Need to remove the app before trying the next argument set." -ForegroundColor DarkGray
    Write-Host ""

    # Try to auto-uninstall using whatever the registry has right now
    $AutoUninstalled = $false
    $InstalledNow = @(Get-InstalledApps -SearchTerm $AppNameHint)
    if ($InstalledNow.Count -gt 0) {
        $UM = Resolve-UninstallMethod -App $InstalledNow[0]
        if ($UM.Type -ne "UNKNOWN") {
            Write-Host "  Attempting auto-uninstall: $($UM.UninstallCommand)" -ForegroundColor DarkGray
            try {
                if ($UM.Type -eq "MSI") {
                    $Guid    = ([regex]::Match($UM.UninstallCommand, '\{[0-9A-Fa-f\-]{36}\}')).Value
                    $MsiLog  = Join-Path $LogFolder "silence_cleanup_msi_$(Get-Date -f 'HHmmss').log"
                    $UP = Start-Process msiexec.exe -ArgumentList "/x $Guid /quiet /norestart /l*v `"$MsiLog`"" -Wait -PassThru -NoNewWindow
                } else {
                    if ($UM.UninstallCommand -match '^"([^"]+)"(.*)$') {
                        $UPath = $Matches[1]; $UArgs = $Matches[2].Trim()
                    } else {
                        $Parts = $UM.UninstallCommand -split ' ',2
                        $UPath = $Parts[0]; $UArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
                    }
                    $UP = Start-Process -FilePath $UPath -ArgumentList $UArgs -Wait -PassThru -NoNewWindow
                }
                Start-Sleep -Seconds 5
                $StillThere = (@(Get-InstalledApps -SearchTerm $AppNameHint)).Count -gt 0
                if (-not $StillThere) {
                    Write-Host "  Auto-uninstall succeeded. Ready to try next args." -ForegroundColor Green
                    $AutoUninstalled = $true
                } else {
                    Write-Host "  Auto-uninstall ran but app may still be present." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  Auto-uninstall exception: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if (-not $AutoUninstalled) {
        Write-Host ""
        Write-Host "  Could not auto-uninstall. Please remove the app manually:" -ForegroundColor Yellow
        Write-Host "    Settings > Apps  --OR--  Add/Remove Programs" -ForegroundColor DarkGray
        Write-Host ""
        Read-Host "  Press Enter once the app has been uninstalled"
    }

    return $false   # not silent -- caller should try next arg combination
}

# Run a single uninstall attempt against all matching DisplayName entries; return result.
Function Invoke-UninstallAttempt {
    param(
        [string]$DisplayNameFilter,
        [string]$UninstallCommand,
        [string]$Method,
        [string]$LogFolder,
        [string]$AppNameHint
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $ExitCode  = -9999
    $ErrorMsg  = ""

    $UninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    try {
        if ($Method -eq "MSI" -and $UninstallCommand -match '\{[0-9A-Fa-f\-]{36}\}') {
            $Guid    = ([regex]::Match($UninstallCommand, '\{[0-9A-Fa-f\-]{36}\}')).Value
            $MsiLog  = Join-Path $LogFolder "verify_uninstall_msi_$Timestamp.log"
            $P       = Start-Process msiexec.exe -ArgumentList "/x $Guid /quiet /norestart /l*v `"$MsiLog`"" -Wait -PassThru -NoNewWindow
            $ExitCode = if ($null -eq $P.ExitCode) { 0 } else { $P.ExitCode }
        } else {
            $Found = @()
            foreach ($Path in $UninstallPaths) {
                if (-not (Test-Path $Path)) { continue }
                Get-ChildItem $Path -EA SilentlyContinue | ForEach-Object {
                    $Prop = Get-ItemProperty $_.PsPath -EA SilentlyContinue
                    if ($Prop.DisplayName -like $DisplayNameFilter) {
                        $Found += [PSCustomObject]@{
                            DisplayName     = $Prop.DisplayName
                            PSChildName     = $_.PSChildName
                            QuietUninstall  = $Prop.QuietUninstallString
                            UninstallString = $Prop.UninstallString
                        }
                    }
                }
            }
            if ($Found.Count -eq 0) {
                return [PSCustomObject]@{
                    Phase         = "Uninstall"
                    Source        = "Auto"
                    Command       = $UninstallCommand
                    ExitCode      = -1
                    ExitCodeOk    = $false
                    RegistryGone  = $false
                    Success       = $false
                    FilterNoMatch = $true
                    Error         = "No registry entries matched filter '$DisplayNameFilter'. The filter may not match the app's actual DisplayName. Check the registry manually."
                    Timestamp     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
            }
            foreach ($App in $Found) {
                $Cmd = ""
                if (-not [string]::IsNullOrWhiteSpace($App.QuietUninstall)) { $Cmd = $App.QuietUninstall }
                elseif ($App.PSChildName -match '^\{[0-9A-Fa-f\-]{36}\}$') {
                    $MsiLog = Join-Path $LogFolder "verify_uninstall_msi_$Timestamp.log"
                    $P = Start-Process msiexec.exe -ArgumentList "/x $($App.PSChildName) /quiet /norestart /l*v `"$MsiLog`"" -Wait -PassThru -NoNewWindow
                    $ExitCode = if ($null -eq $P.ExitCode) { 0 } else { $P.ExitCode }
                    continue
                }
                elseif (-not [string]::IsNullOrWhiteSpace($App.UninstallString)) { $Cmd = $App.UninstallString + " /S" }
                if ($Cmd) {
                    if ($Cmd -match '^"([^"]+)"(.*)$') { $ExePath = $Matches[1]; $ExeArgs = $Matches[2].Trim() }
                    else { $Parts = $Cmd -split ' ',2; $ExePath = $Parts[0]; $ExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" } }
                    $P = Start-Process $ExePath -ArgumentList $ExeArgs -Wait -PassThru -NoNewWindow
                    $ExitCode = if ($null -eq $P.ExitCode) { 0 } else { $P.ExitCode }
                }
            }
        }
    } catch {
        $ErrorMsg = $_.Exception.Message
    }

    $ExitOk = ($ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 1641 -or $ExitCode -eq -9999)
    Start-Sleep -Seconds 4
    $RegGone = (@(Get-InstalledApps -SearchTerm $AppNameHint)).Count -eq 0

    return [PSCustomObject]@{
        Phase        = "Uninstall"
        Source       = "Auto"
        Command      = $UninstallCommand
        ExitCode     = $ExitCode
        ExitCodeOk   = $ExitOk
        RegistryGone = $RegGone
        Success      = $RegGone
        Error        = $ErrorMsg
        Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
}

Function Format-AttemptLog {
    param([System.Collections.Generic.List[object]]$Attempts)
    $Lines = @()
    foreach ($A in $Attempts) {
        $Status = if ($A.Success) { "PASS" } else { "FAIL" }
        if ($A.Phase -eq "Install") {
            $Silent = if ($null -eq $A.WasSilent) { "not checked" } elseif ($A.WasSilent) { "YES" } else { "NO" }
            $Lines += "  [$Status]  Args: $($A.Args)  |  Exit: $($A.ExitCode)  |  Registry: $(if($A.RegistryFound){'Found'}else{'Not found'})  |  Silent: $Silent  |  Source: $($A.Source)  |  $($A.Timestamp)"
        } else {
            $Lines += "  [$Status]  $($A.Command)  |  Exit: $($A.ExitCode)  |  Registry: $(if($A.RegistryGone){'Gone'}else{'Still present'})  |  Source: $($A.Source)  |  $($A.Timestamp)"
        }
        if ($A.Error) { $Lines += "         Error: $($A.Error)" }
    }
    return $Lines -join "`r`n"
}

###########################################################################################
# MAIN
###########################################################################################

Function Main {

    $script:EscalationFlags   = [System.Collections.Generic.List[string]]::new()
    $script:InstallAttempts   = [System.Collections.Generic.List[object]]::new()
    $script:UninstallAttempts = [System.Collections.Generic.List[object]]::new()
    $Pkg = @{}

    Write-Banner "INTUNE PACKAGE BUILDER  v1.0"

    Write-Host "  This tool builds a complete Intune Win32 package folder." -ForegroundColor White
    Write-Host "  Follow the prompts -- press Enter to accept suggested values." -ForegroundColor DarkGray
    Write-Host ""

    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $IsAdmin) {
        Write-Host "  [ERROR] Run this script as Administrator." -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $OutputRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "IntunePackages"
    }

    #######################################################################################
    # STEP 1 -- Select Installer
    #######################################################################################

    Write-Section "STEP 1 of 7 -- SELECT INSTALLER" "Pick the installer file for this app"

    $SelectedFile  = $null
    $InstallerInfo = $null

    do {
        Write-Host ""
        Write-Host "  A File Explorer window will open -- browse to your installer." -ForegroundColor Cyan
        Write-Host "  Supported types: .exe  .msi  .msp" -ForegroundColor DarkGray
        Write-Host ""

        $PickedPath = Show-FilePicker -Title "Select Installer" -Filter "Installer Files (*.exe;*.msi;*.msp)|*.exe;*.msi;*.msp|All Files (*.*)|*.*" -InitialDirectory ([Environment]::GetFolderPath("UserProfile") + "\Downloads")

        if ([string]::IsNullOrWhiteSpace($PickedPath)) {
            Write-Host "  [!] No file selected." -ForegroundColor Yellow
            if (-not (Read-YN "Try again?")) { exit 0 }
            continue
        }

        $FObj = Get-Item $PickedPath
        $SelectedFile = [PSCustomObject]@{
            Name      = $FObj.Name
            FullPath  = $FObj.FullName
            Extension = $FObj.Extension.ToLower()
            SizeMB    = [math]::Round($FObj.Length / 1MB, 1)
        }

        $InstallerInfo = Resolve-InstallerType -File $SelectedFile

        $ConfColor = switch ($InstallerInfo.Confidence) { "High" { "Green" } "Medium" { "Yellow" } default { "Red" } }

        Write-Host ""
        Write-Host "  File       : $($SelectedFile.Name)  ($($SelectedFile.SizeMB) MB)" -ForegroundColor White
        Write-Host "  Type       : $($InstallerInfo.Type)" -ForegroundColor White
        Write-Host "  Args       : $($InstallerInfo.SuggestedArgs)" -ForegroundColor $ConfColor
        if ($InstallerInfo.Notes) { Write-Host "  Note       : $($InstallerInfo.Notes)" -ForegroundColor $ConfColor }
        Write-Host ""

        if (-not (Read-YN "Use this file?")) { $SelectedFile = $null; $InstallerInfo = $null }

    } while (-not $SelectedFile)

    if ($InstallerInfo.Confidence -ne "High") {
        Add-EscalationFlag "Installer type confidence is $($InstallerInfo.Confidence) for '$($SelectedFile.Name)'. Review silent args: '$($InstallerInfo.SuggestedArgs)'. $($InstallerInfo.Notes)"
    }
    if ($InstallerInfo.IsSquirrel) {
        Add-EscalationFlag "Possible Squirrel installer detected. These install to user profile by default. Verify Install behavior should be 'User' in Intune, and confirm --silent flag is supported by this specific app."
    }

    #######################################################################################
    # STEP 2 -- App Metadata
    #######################################################################################

    Write-Section "STEP 2 of 7 -- APP INFORMATION" "Auto-detected from file -- press Enter to accept or type to override"

    $DetectedName      = ""
    $DetectedVersion   = ""
    $DetectedPublisher = ""

    try {
        $VI = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($SelectedFile.FullPath)
        $DetectedName      = if ($VI.ProductName)    { $VI.ProductName.Trim() }    else { $SelectedFile.Name -replace '\.[^.]+$', '' }
        $DetectedVersion   = if ($VI.ProductVersion) { $VI.ProductVersion.Trim() } else { "" }
        $DetectedPublisher = if ($VI.CompanyName)    { $VI.CompanyName.Trim() }    else { "" }
    } catch {
        $DetectedName = $SelectedFile.Name -replace '\.[^.]+$', ''
    }

    Write-Host ""
    Write-Host "  Detected name      : $DetectedName" -ForegroundColor White
    $NameInput = (Read-Host "  App name (Enter to accept)").Trim()
    $AppName   = if ([string]::IsNullOrWhiteSpace($NameInput)) { $DetectedName } else { $NameInput }

    Write-Host "  Detected version   : $DetectedVersion" -ForegroundColor White
    $VerInput   = (Read-Host "  Version (Enter to accept)").Trim()
    $AppVersion = if ([string]::IsNullOrWhiteSpace($VerInput)) { $DetectedVersion } else { $VerInput }

    Write-Host "  Detected publisher : $DetectedPublisher" -ForegroundColor White
    $PubInput     = (Read-Host "  Publisher (Enter to accept)").Trim()
    $AppPublisher = if ([string]::IsNullOrWhiteSpace($PubInput)) { $DetectedPublisher } else { $PubInput }

    Write-Host ""
    Write-Host "  Description (shown in Company Portal -- e.g. 'PDF reader for Windows'):" -ForegroundColor Cyan
    $AppDesc = (Read-Host "  Description").Trim()
    if ([string]::IsNullOrWhiteSpace($AppDesc)) { $AppDesc = "$AppName for Windows" }

    $SafeName = $AppName -replace '[^A-Za-z0-9_\-]', ''

    $Pkg.AppName           = $AppName
    $Pkg.AppVersion        = $AppVersion
    $Pkg.Publisher         = $AppPublisher
    $Pkg.Description       = $AppDesc
    $Pkg.SafeName          = $SafeName
    $Pkg.InstallerFileName = $SelectedFile.Name
    $Pkg.InstallerType     = $InstallerInfo.Type

    #######################################################################################
    # STEP 3 -- Install Configuration
    #######################################################################################

    Write-Section "STEP 3 of 7 -- INSTALL COMMAND" "Review and confirm the silent install arguments"

    Write-Host ""
    Write-Host "  Suggested args : $($InstallerInfo.SuggestedArgs)" -ForegroundColor White

    if ($InstallerInfo.Confidence -ne "High") {
        $EditArgs = Read-YN "Edit install arguments? (confidence is $($InstallerInfo.Confidence))"
    } else {
        $EditArgs = Read-YN "Edit install arguments?" -DefaultNo
    }

    if ($EditArgs) {
        Write-Host "  Common flags:" -ForegroundColor DarkGray
        Write-Host "    MSI / WiX    :  /quiet /norestart" -ForegroundColor DarkGray
        Write-Host "    Inno Setup   :  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -ForegroundColor DarkGray
        Write-Host "    NSIS         :  /S" -ForegroundColor DarkGray
        Write-Host "    InstallShield:  /s /v`"/qn /norestart`"" -ForegroundColor DarkGray
        $NewArgs = (Read-Host "  New arguments").Trim()
        if (-not [string]::IsNullOrWhiteSpace($NewArgs)) { $InstallerInfo.SuggestedArgs = $NewArgs }
    }

    Write-Host ""
    Write-Host "  Install behavior:" -ForegroundColor Cyan
    Write-Host "    [1]  System  (default -- installs for all users, runs as SYSTEM)" -ForegroundColor White
    Write-Host "    [2]  User    (installs per-user, runs in user context)" -ForegroundColor White
    Write-Host ""
    Write-Host "  Note: Squirrel-based apps (Discord, Slack, VS Code) install to user profile" -ForegroundColor DarkGray
    Write-Host "        and should use User context." -ForegroundColor DarkGray
    $ContextPick     = (Read-Host "  Choice [1/2, default 1]").Trim()
    $InstallBehavior = if ($ContextPick -eq "2") { "User" } else { "System" }
    Write-Host "  Install behavior set to: $InstallBehavior" -ForegroundColor Green

    if ($InstallBehavior -eq "User") {
        Add-EscalationFlag "Install behavior is set to 'User'. Verify the app installs correctly in user context during testing. User-context installs can behave differently across different user profiles."
    }

    Write-Host ""
    Write-Host "  Device restart behavior:" -ForegroundColor Cyan
    Write-Host "    [1]  Determine behavior based on return codes  (recommended)" -ForegroundColor White
    Write-Host "    [2]  No specific action" -ForegroundColor White
    Write-Host "    [3]  Force reboot" -ForegroundColor White
    $RestartPick     = (Read-Host "  Choice [1-3, default 1]").Trim()
    $RestartBehavior = switch ($RestartPick) {
        "2" { "No specific action" }
        "3" { "Force a reboot" }
        default { "Determine behavior based on return codes" }
    }

    $Pkg.InstallArgs     = $InstallerInfo.SuggestedArgs
    $Pkg.InstallBehavior = $InstallBehavior
    $Pkg.RestartBehavior = $RestartBehavior

    #######################################################################################
    # STEP 3b -- Verify Install (optional)
    #######################################################################################

    $script:InstallAttempts    = [System.Collections.Generic.List[object]]::new()
    $script:InstallVerified    = $false
    $script:WorkingInstallArgs = $InstallerInfo.SuggestedArgs

    $AppNameHint = ($AppName -split ' ')[0]   # used for registry hint throughout

    Write-Host ""
    Write-Host "  Verify that the silent install actually works before packaging." -ForegroundColor DarkGray
    Write-Host "  The tool tries the quietest arg combos first, then asks if the" -ForegroundColor DarkGray
    Write-Host "  install was truly silent (no visible windows appeared)." -ForegroundColor DarkGray
    Write-Host ""

    if (Read-YN "Test the install on this machine now?") {

        $VerifyLogFolder = Join-Path $env:TEMP "IntuneVerify_$SafeName"
        New-Item -Path $VerifyLogFolder -ItemType Directory -Force | Out-Null

        $ArgQueue  = @(Get-AlternativeArgs -InstallerType $InstallerInfo.Type -PrimaryArgs $InstallerInfo.SuggestedArgs)
        $AutoIndex = 0
        $GaveUp    = $false

        :VerifyLoop while ($true) {

            # ── Auto-try phase ────────────────────────────────────────────────
            if ($AutoIndex -lt $ArgQueue.Count) {
                $CurrentArgs = $ArgQueue[$AutoIndex]
                $AutoIndex++

                $SourceLabel = if ($AutoIndex -eq 1) { "Suggested" } else { "Auto-alt $AutoIndex" }
                Write-Host ""
                Write-Host "  [$SourceLabel]  Testing args: $CurrentArgs" -ForegroundColor Cyan
                Write-Host "  Running installer -- this may take a moment..." -ForegroundColor DarkGray

                $Result = Invoke-InstallAttempt -File $SelectedFile -InstallerType $InstallerInfo.Type `
                    -InstallArgs $CurrentArgs -LogFolder $VerifyLogFolder -AppNameHint $AppNameHint
                $Result.Source = $SourceLabel
                $script:InstallAttempts.Add($Result)

                if ($Result.Success) {
                    Write-Host "  [PASS]  Exit code $($Result.ExitCode) -- app found in registry." -ForegroundColor Green

                    # ── SILENCE CHECK ─────────────────────────────────────────
                    $Silent = Invoke-SilenceCheck -TestedArgs $CurrentArgs -AppNameHint $AppNameHint -LogFolder $VerifyLogFolder
                    $Result.WasSilent = $Silent

                    if ($Silent) {
                        $script:InstallVerified    = $true
                        $script:WorkingInstallArgs = $CurrentArgs
                        $InstallerInfo.SuggestedArgs = $CurrentArgs
                        $Pkg.InstallArgs = $CurrentArgs
                        break VerifyLoop
                    } else {
                        # Not silent -- flag it and fall through so the while loop
                        # naturally iterates to the next arg combination.
                        Add-EscalationFlag "Args '$CurrentArgs' installed successfully but were NOT fully silent -- visible windows appeared. Trying quieter combinations."
                        if ($AutoIndex -lt $ArgQueue.Count) {
                            Write-Host "  Trying next (quieter) combination..." -ForegroundColor DarkGray
                        } else {
                            Write-Host "  No more auto-combinations left. Will ask for a custom arg string." -ForegroundColor Yellow
                        }
                        # (fall through to next while iteration)
                    }
                    # ── END SILENCE CHECK ─────────────────────────────────────

                } elseif ($Result.ExitCodeOk -and -not $Result.RegistryFound) {
                    Write-Host "  [WARN]  Exit code $($Result.ExitCode) OK but app NOT found in registry." -ForegroundColor Yellow
                    Write-Host "         This could be a Squirrel/user-context installer or a reboot is needed." -ForegroundColor DarkGray
                    if (Read-YN "  Accept this result anyway (exit code was clean)?" -DefaultNo) {
                        $Result.Success = $true
                        $script:InstallVerified    = $true
                        $script:WorkingInstallArgs = $CurrentArgs
                        $InstallerInfo.SuggestedArgs = $CurrentArgs
                        $Pkg.InstallArgs = $CurrentArgs
                        Write-Host "  Accepted. Working args: $CurrentArgs" -ForegroundColor Yellow
                        break VerifyLoop
                    }
                } else {
                    if ($Result.LaunchFailed) {
                        Write-Host "  [FAIL]  Installer did not launch -- process exception." -ForegroundColor Red
                        Write-Host "          $($Result.Error)" -ForegroundColor Red
                        Write-Host "          (Path wrong, file blocked, or UAC issue -- not an args problem.)" -ForegroundColor DarkGray
                    } elseif (-not $Result.ExitCodeOk) {
                        Write-Host "  [FAIL]  Installer returned exit code $($Result.ExitCode)." -ForegroundColor Red
                        if ($Result.Error) { Write-Host "          $($Result.Error)" -ForegroundColor Red }
                    } else {
                        Write-Host "  [FAIL]  Exit code clean but app NOT found in registry afterward." -ForegroundColor Red
                    }
                    if ($AutoIndex -lt $ArgQueue.Count) {
                        Write-Host "  Auto-trying next combination..." -ForegroundColor DarkGray
                    }
                }

            } else {
                # ── All auto options exhausted -- ask user ────────────────────
                Write-Host ""
                Write-Host "  All $($ArgQueue.Count) auto-combinations have been tried." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  You can enter a custom argument string to try, or give up and escalate." -ForegroundColor Cyan
                Write-Host "  If you give up, all attempts will be recorded in Escalation-Notes.txt." -ForegroundColor DarkGray
                Write-Host ""

                if (-not (Read-YN "Try a custom argument string?")) {
                    $GaveUp = $true
                    break VerifyLoop
                }

                Write-Host "  Common references:" -ForegroundColor DarkGray
                Write-Host "    MSI/WiX       : /quiet /norestart" -ForegroundColor DarkGray
                Write-Host "    Inno Setup    : /VERYSILENT /SUPPRESSMSGBOXES /NORESTART" -ForegroundColor DarkGray
                Write-Host "    NSIS          : /S" -ForegroundColor DarkGray
                Write-Host "    InstallShield : /s /v`"/qn /norestart`"" -ForegroundColor DarkGray
                Write-Host "    Generic EXE   : --silent  /silent  -s  /S /NCRC" -ForegroundColor DarkGray
                Write-Host ""
                $UserArgs = (Read-Host "  Enter args to try").Trim()
                if ([string]::IsNullOrWhiteSpace($UserArgs)) { continue }

                Write-Host ""
                Write-Host "  Testing user args: $UserArgs" -ForegroundColor Cyan
                Write-Host "  Running installer..." -ForegroundColor DarkGray

                $Result = Invoke-InstallAttempt -File $SelectedFile -InstallerType $InstallerInfo.Type `
                    -InstallArgs $UserArgs -LogFolder $VerifyLogFolder -AppNameHint $AppNameHint
                $Result.Source = "UserEntered"
                $script:InstallAttempts.Add($Result)

                if ($Result.Success) {
                    Write-Host "  [PASS]  Exit code $($Result.ExitCode) -- app found in registry." -ForegroundColor Green

                    # ── SILENCE CHECK ─────────────────────────────────────────
                    $Silent = Invoke-SilenceCheck -TestedArgs $UserArgs -AppNameHint $AppNameHint -LogFolder $VerifyLogFolder
                    $Result.WasSilent = $Silent

                    if ($Silent) {
                        $script:InstallVerified    = $true
                        $script:WorkingInstallArgs = $UserArgs
                        $InstallerInfo.SuggestedArgs = $UserArgs
                        $Pkg.InstallArgs = $UserArgs
                        break VerifyLoop
                    } else {
                        # Not silent -- flag it, ask if they want to try another
                        Add-EscalationFlag "Args '$UserArgs' installed successfully but were NOT fully silent. Try adding /SUPPRESSMSGBOXES or equivalent flags."
                        if (-not (Read-YN "  Try another custom combination?")) { $GaveUp = $true; break VerifyLoop }
                        # (fall through to next while iteration -- loop back to user prompt)
                    }
                    # ── END SILENCE CHECK ─────────────────────────────────────

                } elseif ($Result.ExitCodeOk -and -not $Result.RegistryFound) {
                    Write-Host "  [WARN]  Exit code $($Result.ExitCode) was clean but app NOT found in registry." -ForegroundColor Yellow
                    Write-Host "         Could be a Squirrel/user-context installer, or needs a reboot." -ForegroundColor DarkGray
                    if (Read-YN "  Accept this result anyway (exit code was clean)?" -DefaultNo) {
                        $Result.Success = $true
                        $script:InstallVerified    = $true
                        $script:WorkingInstallArgs = $UserArgs
                        $InstallerInfo.SuggestedArgs = $UserArgs
                        $Pkg.InstallArgs = $UserArgs
                        Write-Host "  Accepted. Working args: $UserArgs" -ForegroundColor Yellow
                        break VerifyLoop
                    }
                    if (-not (Read-YN "  Try another custom combination?")) { $GaveUp = $true; break VerifyLoop }
                } else {
                    if ($Result.LaunchFailed) {
                        Write-Host "  [FAIL]  Installer did not launch -- process exception." -ForegroundColor Red
                        Write-Host "          $($Result.Error)" -ForegroundColor Red
                    } elseif (-not $Result.ExitCodeOk) {
                        Write-Host "  [FAIL]  Exit code $($Result.ExitCode) -- installer ran but reported failure." -ForegroundColor Red
                        if ($Result.Error) { Write-Host "          $($Result.Error)" -ForegroundColor Red }
                    } else {
                        Write-Host "  [FAIL]  Exit code clean but app not in registry afterward." -ForegroundColor Red
                    }
                    if (-not (Read-YN "  Try another custom combination?")) {
                        $GaveUp = $true
                        break VerifyLoop
                    }
                }
            }
        }

        if ($GaveUp) {
            $AttemptSummary = Format-AttemptLog -Attempts $script:InstallAttempts
            Add-EscalationFlag "Install verification FAILED after $($script:InstallAttempts.Count) attempt(s). None of the tried arg combinations produced a confirmed silent install. Manual investigation required.`r`n`r`n  Attempts:`r`n$AttemptSummary"
            Write-Host ""
            Write-Host "  Install could not be verified. All attempts logged to Escalation-Notes.txt." -ForegroundColor Yellow
        } elseif ($script:InstallVerified) {
            $FailedCount = ($script:InstallAttempts | Where-Object { -not $_.Success }).Count
            if ($FailedCount -gt 0) {
                Write-Host "  ($FailedCount failed/non-silent attempt(s) before finding working args)" -ForegroundColor DarkGray
            }
        }

    } else {
        Write-Host "  Skipping install verification -- args not confirmed by test." -ForegroundColor DarkGray
        Add-EscalationFlag "Install args '$($InstallerInfo.SuggestedArgs)' were NOT verified by a live test. Validate on a test device before broad deployment."
    }


    #######################################################################################
    # STEP 4 -- Uninstall Configuration
    #######################################################################################

    Write-Section "STEP 4 of 7 -- UNINSTALL COMMAND" "Scanning registry for all installed versions"

    Write-Host ""
    Write-Host "  Searching registry for: $AppName" -ForegroundColor DarkGray

    $RegistryApps = @(Get-InstalledApps -SearchTerm $AppNameHint)

    $DisplayNameFilter   = ""
    $FallbackMethod      = ""
    $FallbackProductCode = ""
    $FallbackExePath     = ""
    $FallbackExeArgs     = ""
    $UninstallRegPath    = ""

    if ($RegistryApps.Count -eq 0) {
        Write-Host ""
        Write-Host "  [!] App not found in registry on this machine." -ForegroundColor Yellow
        Write-Host "      The generated uninstall script will still scan by DisplayName at runtime." -ForegroundColor DarkGray
        Write-Host ""
        $BaseAppName       = $AppName -replace ' \d+[\.\d]*$', ''
        $DisplayNameFilter = "*$BaseAppName*"
        Write-Host "  Filter (from file metadata, may not match registry): $DisplayNameFilter" -ForegroundColor Yellow
        Add-EscalationFlag "App '$AppName' was not found in registry on the packaging machine. The DisplayName filter '$DisplayNameFilter' was derived from the installer file metadata and may NOT match the actual registry DisplayName once installed. Install the app and re-run to get the correct filter from the registry."

        if (Read-YN "Enter a fallback uninstall command in case DisplayName scan fails?" -DefaultNo) {
            Write-Host "  Examples:" -ForegroundColor DarkGray
            Write-Host "    MSI : msiexec.exe /x {GUID} /quiet /norestart" -ForegroundColor DarkGray
            Write-Host "    EXE : C:\Program Files\App\uninstall.exe /S" -ForegroundColor DarkGray
            $FallbackRaw = (Read-Host "  Fallback command").Trim()
            if ($FallbackRaw -match 'msiexec' -and $FallbackRaw -match '\{[0-9A-Fa-f\-]{36}\}') {
                $FallbackMethod      = "MSI"
                $FallbackProductCode = ([regex]::Match($FallbackRaw, '\{[0-9A-Fa-f\-]{36}\}')).Value
            } elseif (-not [string]::IsNullOrWhiteSpace($FallbackRaw)) {
                $FallbackMethod  = "EXE"
                if ($FallbackRaw -match '^\"([^\"]+)\"(.*)$') {
                    $FallbackExePath = $Matches[1]; $FallbackExeArgs = $Matches[2].Trim()
                } else {
                    $Parts = $FallbackRaw -split ' ',2
                    $FallbackExePath = $Parts[0]; $FallbackExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
                }
            }
        }
    }
    else {
        Write-Host "  Found $($RegistryApps.Count) matching install(s) in registry:" -ForegroundColor Green
        Write-Host ""

        foreach ($App in $RegistryApps) {
            $UM = Resolve-UninstallMethod -App $App
            $ConfColor = switch ($UM.Confidence) { "High" { "Gray" } "Medium" { "Yellow" } default { "Red" } }
            Write-Host "  >>  $($App.DisplayName)  v$($App.DisplayVersion)" -ForegroundColor White
            Write-Host "      Uninstall method  : $($UM.Type)  ($($UM.Confidence) confidence)" -ForegroundColor $ConfColor
            Write-Host "      Uninstall command : $($UM.UninstallCommand)" -ForegroundColor $ConfColor
            if ($UM.Notes) { Write-Host "      Note              : $($UM.Notes)" -ForegroundColor DarkGray }
            Write-Host ""
        }

        $PrimaryApp          = $RegistryApps[0]
        $PrimaryUM           = Resolve-UninstallMethod -App $PrimaryApp
        $UninstallRegPath    = $PrimaryApp.RegistryPath
        $FallbackMethod      = $PrimaryUM.Type
        $FallbackProductCode = if ($PrimaryUM.Type -eq "MSI") { $PrimaryUM.ProductCode } else { "" }

        if ($PrimaryUM.Type -eq "EXE") {
            if ($PrimaryUM.UninstallCommand -match '^\"([^\"]+)\"(.*)$') {
                $FallbackExePath = $Matches[1]; $FallbackExeArgs = $Matches[2].Trim()
            } else {
                $Parts = $PrimaryUM.UninstallCommand -split ' ',2
                $FallbackExePath = $Parts[0]; $FallbackExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
            }
        }

        # Build filter from actual registry DisplayName, not file metadata
        $RegDisplayName    = $PrimaryApp.DisplayName -replace ' \d+[\d\.]*$', ''
        $DisplayNameFilter = "*$RegDisplayName*"

        Write-Host "  Registry DisplayName  : $($PrimaryApp.DisplayName)" -ForegroundColor White
        Write-Host "  DisplayName filter    : $DisplayNameFilter" -ForegroundColor White
        Write-Host "  (Derived from actual registry entry -- not the installer filename.)" -ForegroundColor DarkGray
        Write-Host "  (The script will find and remove ALL versions matching this filter at runtime.)" -ForegroundColor DarkGray
        Write-Host ""

        $FilterInput = (Read-Host "  Press Enter to accept filter, or type a custom filter").Trim()
        if (-not [string]::IsNullOrWhiteSpace($FilterInput)) { $DisplayNameFilter = $FilterInput }

        if ($PrimaryUM.Confidence -ne "High") {
            Add-EscalationFlag "Uninstall confidence is $($PrimaryUM.Confidence) for '$($PrimaryApp.DisplayName)'. Command: '$($PrimaryUM.UninstallCommand)'. $($PrimaryUM.Notes)"
        }

        # Warn if uninstall path is inside a user profile (Squirrel apps)
        $UninstallCmdCheck   = $PrimaryUM.UninstallCommand
        $UserProfilePatterns = @($env:USERPROFILE, 'C:\Users\', '%LocalAppData%', '%AppData%', '%UserProfile%')
        $IsUserProfilePath   = $UserProfilePatterns | Where-Object { $UninstallCmdCheck -like "*$_*" }
        if ($IsUserProfilePath) {
            Write-Host ""
            Write-Host "  [!] WARNING: Uninstall path is inside a user profile folder." -ForegroundColor Yellow
            Write-Host "      $UninstallCmdCheck" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  This is a Squirrel-style app (Discord, Slack, Teams, VS Code)." -ForegroundColor DarkGray
            Write-Host "  Squirrel installs per-user -- the uninstaller lives in AppData." -ForegroundColor DarkGray
            Write-Host "  When Intune runs as SYSTEM, this path will NOT exist on other devices." -ForegroundColor DarkGray
            Write-Host "  The package should be deployed in User install context." -ForegroundColor DarkGray
            Write-Host ""
            Add-EscalationFlag "Uninstall path '$UninstallCmdCheck' is inside a user profile and is device/user-specific. This will fail when Intune runs as SYSTEM. Deploy this package in User install context. The generated uninstall script resolves the path via QuietUninstallString from registry at runtime, which is correct -- but the Intune assignment must use User context."
        }

        if ($RegistryApps.Count -gt 1) {
            Write-Host "  NOTE: $($RegistryApps.Count) versions were found. The uninstall script will remove ALL of them." -ForegroundColor Yellow
        }
    }

    $Pkg.UninstallMethod      = $FallbackMethod
    $Pkg.FallbackProductCode  = $FallbackProductCode
    $Pkg.FallbackExePath      = $FallbackExePath
    $Pkg.FallbackExeArgs      = $FallbackExeArgs
    $Pkg.DisplayNameFilter    = $DisplayNameFilter
    $Pkg.UninstallRegPath     = $UninstallRegPath
    $Pkg.UninstallCommand     = if ($RegistryApps.Count -gt 0) { (Resolve-UninstallMethod -App $RegistryApps[0]).UninstallCommand } else { "Runtime discovery by DisplayName filter: $DisplayNameFilter" }

    #######################################################################################
    # STEP 4b -- Verify Uninstall (optional)
    #######################################################################################

    $script:UninstallAttempts = [System.Collections.Generic.List[object]]::new()
    $script:UninstallVerified = $false

    $AppCurrentlyInstalled = (@(Get-InstalledApps -SearchTerm $AppNameHint)).Count -gt 0

    if ($AppCurrentlyInstalled) {
        Write-Host ""
        Write-Host "  App is currently installed on this machine -- uninstall can be tested now." -ForegroundColor DarkGray
        Write-Host ""

        if (Read-YN "Test the uninstall on this machine now?") {

            $VerifyLogFolder = Join-Path $env:TEMP "IntuneVerify_$SafeName"
            New-Item -Path $VerifyLogFolder -ItemType Directory -Force | Out-Null

            :UninstallLoop while ($true) {

                Write-Host ""
                Write-Host "  Running uninstall via DisplayName scan (filter: $DisplayNameFilter)..." -ForegroundColor Cyan

                $UResult = Invoke-UninstallAttempt `
                    -DisplayNameFilter $DisplayNameFilter `
                    -UninstallCommand  $Pkg.UninstallCommand `
                    -Method            $Pkg.UninstallMethod `
                    -LogFolder         $VerifyLogFolder `
                    -AppNameHint       $AppNameHint
                $UResult.Source = "Auto"
                $script:UninstallAttempts.Add($UResult)

                if ($UResult.Success) {
                    Write-Host "  [PASS]  App removed -- no longer found in registry." -ForegroundColor Green
                    $script:UninstallVerified = $true
                    break UninstallLoop
                } elseif ($UResult.FilterNoMatch) {
                    Write-Host "  [FAIL]  Filter did not match any registry entries." -ForegroundColor Red
                    Write-Host "          $($UResult.Error)" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "  Open regedit and check the actual DisplayName under:" -ForegroundColor Yellow
                    Write-Host "  HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" -ForegroundColor DarkGray
                    Write-Host "  HKLM\SOFTWARE\WOW6432Node\...\Uninstall" -ForegroundColor DarkGray
                    Write-Host "  Then re-enter the correct filter below." -ForegroundColor Cyan
                } else {
                    if (-not $UResult.ExitCodeOk) {
                        Write-Host "  [FAIL]  Uninstall exited with code $($UResult.ExitCode)." -ForegroundColor Red
                    } else {
                        Write-Host "  [FAIL]  Exit code OK but app still present in registry." -ForegroundColor Red
                    }
                    if ($UResult.Error) { Write-Host "         Error: $($UResult.Error)" -ForegroundColor Red }

                    Write-Host ""
                    Write-Host "  If the auto-detected command isn't working, you can enter one manually." -ForegroundColor DarkGray
                    Write-Host ""

                    if (-not (Read-YN "Try a custom uninstall command?")) {
                        $AttemptSummary = Format-AttemptLog -Attempts $script:UninstallAttempts
                        Add-EscalationFlag "Uninstall verification FAILED after $($script:UninstallAttempts.Count) attempt(s). App remained in registry after each attempt.`r`n`r`n  Attempts:`r`n$AttemptSummary"
                        Write-Host "  Uninstall could not be verified. Logged to Escalation-Notes.txt." -ForegroundColor Yellow
                        break UninstallLoop
                    }

                    Write-Host "  Common patterns:" -ForegroundColor DarkGray
                    Write-Host "    MSI  : msiexec.exe /x {GUID} /quiet /norestart" -ForegroundColor DarkGray
                    Write-Host "    EXE  : `"C:\Program Files\App\uninstall.exe`" /S" -ForegroundColor DarkGray
                    $CustomUCmd = (Read-Host "  Enter uninstall command").Trim()
                    if ([string]::IsNullOrWhiteSpace($CustomUCmd)) { continue }

                    Write-Host ""
                    Write-Host "  Testing: $CustomUCmd" -ForegroundColor Cyan

                    $CustomMethod = if ($CustomUCmd -match 'msiexec') { "MSI" } else { "EXE" }
                    $UResult2 = Invoke-UninstallAttempt `
                        -DisplayNameFilter $DisplayNameFilter `
                        -UninstallCommand  $CustomUCmd `
                        -Method            $CustomMethod `
                        -LogFolder         $VerifyLogFolder `
                        -AppNameHint       $AppNameHint
                    $UResult2.Source = "UserEntered"
                    $script:UninstallAttempts.Add($UResult2)

                    if ($UResult2.Success) {
                        Write-Host "  [PASS]  App removed successfully." -ForegroundColor Green
                        $script:UninstallVerified = $true
                        if ($CustomMethod -eq "MSI") {
                            $Pkg.UninstallMethod     = "MSI"
                            $Pkg.FallbackProductCode = ([regex]::Match($CustomUCmd, '\{[0-9A-Fa-f\-]{36}\}')).Value
                        } else {
                            $Pkg.UninstallMethod = "EXE"
                            if ($CustomUCmd -match '^"([^"]+)"(.*)$') {
                                $Pkg.FallbackExePath = $Matches[1]; $Pkg.FallbackExeArgs = $Matches[2].Trim()
                            } else {
                                $Parts = $CustomUCmd -split ' ',2
                                $Pkg.FallbackExePath = $Parts[0]; $Pkg.FallbackExeArgs = if ($Parts.Count -gt 1) { $Parts[1] } else { "" }
                            }
                        }
                        $Pkg.UninstallCommand = $CustomUCmd
                        Write-Host "  Uninstall fallback updated with working command." -ForegroundColor Green
                        break UninstallLoop
                    } else {
                        Write-Host "  [FAIL]  Still not removed." -ForegroundColor Red
                        if (-not (Read-YN "  Try another command?")) {
                            $AttemptSummary = Format-AttemptLog -Attempts $script:UninstallAttempts
                            Add-EscalationFlag "Uninstall verification FAILED after $($script:UninstallAttempts.Count) attempt(s).`r`n`r`n  Attempts:`r`n$AttemptSummary"
                            Write-Host "  All attempts logged to Escalation-Notes.txt." -ForegroundColor Yellow
                            break UninstallLoop
                        }
                    }
                }
            }

        } else {
            Write-Host "  Skipping uninstall verification." -ForegroundColor DarkGray
            Add-EscalationFlag "Uninstall command was NOT verified by a live test on this machine. Validate on a test device before broad deployment."
        }
    } else {
        Write-Host ""
        Write-Host "  App is not installed on this machine -- uninstall cannot be tested now." -ForegroundColor DarkGray
        Write-Host "  Make sure to test uninstall on a test device before deploying broadly." -ForegroundColor DarkGray
        Add-EscalationFlag "Uninstall was NOT tested because '$AppName' is not installed on the packaging machine. Test on a real device before broad deployment."
    }

    #######################################################################################
    # STEP 5 -- Detection Rule
    #######################################################################################

    Write-Section "STEP 5 of 7 -- DETECTION RULE" "How Intune checks whether the app is installed"

    Write-Host ""
    Write-Host "  The detection script runs on each device to check if the app is present." -ForegroundColor DarkGray
    Write-Host "  Since GUIDs change between versions and are unreliable across your environment," -ForegroundColor DarkGray
    Write-Host "  DisplayName is the default and works across all versions simultaneously." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1]  DisplayName  (RECOMMENDED) -- matches by app name, any version" -ForegroundColor White
    Write-Host "  [2]  File         -- checks for a specific file on disk" -ForegroundColor White
    Write-Host "  [3]  Service      -- checks for a Windows service by name" -ForegroundColor White
    Write-Host "  [4]  RegistryGUID -- exact GUID match (last resort -- breaks on upgrade)" -ForegroundColor DarkGray
    Write-Host ""

    $DetectionMethod     = "DisplayName"
    $DetectDisplayFilter = $Pkg.DisplayNameFilter
    $DetectRegPath       = ""
    $DetectFilePath      = ""
    $DetectServiceName   = ""
    $DetectMinVersion    = ""

    $InstallLocationHint = if ($RegistryApps.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($RegistryApps[0].InstallLocation)) {
        $RegistryApps[0].InstallLocation
    } else { "C:\Program Files\$AppName" }

    do {
        $DPick = (Read-Host "  Choice [1-4, default 1]").Trim()
        if ([string]::IsNullOrWhiteSpace($DPick)) { $DPick = "1" }

        switch ($DPick) {
            "1" {
                $DetectionMethod = "DisplayName"
                Write-Host "  Current filter (from Step 4) : $DetectDisplayFilter" -ForegroundColor White
                Write-Host "  This filter will match any version of the app." -ForegroundColor DarkGray
                $FInput = (Read-Host "  Press Enter to accept, or type a custom filter").Trim()
                if (-not [string]::IsNullOrWhiteSpace($FInput)) { $DetectDisplayFilter = $FInput }
                Write-Host "  Detection filter: $DetectDisplayFilter" -ForegroundColor Green
            }
            "2" {
                $DetectionMethod = "File"
                Write-Host "  Suggested location: $InstallLocationHint" -ForegroundColor DarkGray
                Write-Host "  Enter the full path to a file that exists when the app is installed." -ForegroundColor Cyan
                Write-Host "  Example: C:\Program Files\MyApp\myapp.exe" -ForegroundColor DarkGray
                $DetectFilePath = (Read-Host "  Full file path").Trim()
                if ([string]::IsNullOrWhiteSpace($DetectFilePath)) {
                    Write-Host "  File path is required." -ForegroundColor Yellow
                    $DPick = ""
                } else { Write-Host "  File detection: $DetectFilePath" -ForegroundColor Green }
            }
            "3" {
                $DetectionMethod   = "Service"
                Write-Host "  Enter the service name exactly as it appears in services.msc" -ForegroundColor Cyan
                $DetectServiceName = (Read-Host "  Service name").Trim()
                if ([string]::IsNullOrWhiteSpace($DetectServiceName)) {
                    Write-Host "  Service name is required." -ForegroundColor Yellow
                    $DPick = ""
                } else { Write-Host "  Service detection: $DetectServiceName" -ForegroundColor Green }
            }
            "4" {
                $AvailableGuid = $Pkg.FallbackProductCode
                if (-not [string]::IsNullOrWhiteSpace($AvailableGuid)) {
                    $DetectionMethod = "RegistryGUID"
                    $DetectRegPath   = $Pkg.UninstallRegPath
                    Write-Host ""
                    Write-Host "  [!] GUID detection will break if the app is upgraded -- the GUID changes" -ForegroundColor Yellow
                    Write-Host "      every version. This means Intune will think the app is NOT installed" -ForegroundColor Yellow
                    Write-Host "      after an upgrade and may attempt to reinstall it." -ForegroundColor Yellow
                    Write-Host "      Only use this if you are managing a single locked version." -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  GUID : $AvailableGuid" -ForegroundColor White
                    Write-Host "  Path : $DetectRegPath" -ForegroundColor White
                    Write-Host ""
                    Add-EscalationFlag "Detection method is RegistryGUID ('$DetectRegPath'). GUIDs change per version and are unreliable in multi-version environments. Switch to DisplayName detection unless you are locking to a single version."
                } else {
                    Write-Host "  [!] No GUID was found for this app in Step 4. Choose a different method." -ForegroundColor Yellow
                    $DPick = ""
                }
            }
            default { Write-Host "  Enter 1, 2, 3, or 4." -ForegroundColor Yellow; $DPick = "" }
        }
    } while ([string]::IsNullOrWhiteSpace($DPick))

    Write-Host ""
    if (Read-YN "Require a minimum version? (No = detect any installed version)" -DefaultNo) {
        Write-Host "  This means the detection will FAIL if the installed version is older than your minimum." -ForegroundColor DarkGray
        $DetectMinVersion = (Read-Host "  Minimum version (e.g. $AppVersion)").Trim()
        Write-Host "  Minimum version set to: $DetectMinVersion" -ForegroundColor Green
    }

    $Pkg.DetectionMethod = $DetectionMethod
    $Pkg.DetectionDetail = switch ($DetectionMethod) {
        "DisplayName"  { "Filter: $DetectDisplayFilter" }
        "RegistryGUID" { "GUID: $($Pkg.FallbackProductCode)  Path: $DetectRegPath" }
        "File"         { "File: $DetectFilePath" }
        "Service"      { "Service: $DetectServiceName" }
    }

    #######################################################################################
    # STEP 6 -- Requirements
    #######################################################################################

    Write-Section "STEP 6 of 7 -- REQUIREMENTS" "Setting standard requirements"

    $Pkg.MinOS        = "Windows 11 21H2 (22000)"
    $Pkg.Architecture = "x64"

    Write-Host ""
    Write-Host "  Min OS       : $($Pkg.MinOS)" -ForegroundColor White
    Write-Host "  Architecture : $($Pkg.Architecture)" -ForegroundColor White

    #######################################################################################
    # STEP 7 -- Build Package
    #######################################################################################

    Write-Section "STEP 7 of 7 -- BUILD PACKAGE" "Creating output folder and generating all files"

    $VersionSlug   = $AppVersion -replace '[^A-Za-z0-9\.\-]', '_'
    $PackageFolder = Join-Path $OutputRoot "$SafeName`_$VersionSlug"
    $SourceFolder  = Join-Path $PackageFolder "Source"

    $Pkg.SourceFolder  = $SourceFolder
    $Pkg.IntuneWinPath = Join-Path $PackageFolder "$SafeName.intunewin"

    Write-Host ""
    Write-Host "  App            : $($Pkg.AppName)  v$($Pkg.AppVersion)" -ForegroundColor White
    Write-Host "  Publisher      : $($Pkg.Publisher)" -ForegroundColor White
    Write-Host "  Installer      : $($Pkg.InstallerFileName)  ($($InstallerInfo.Type))" -ForegroundColor White
    Write-Host "  Install args   : $($Pkg.InstallArgs)" -ForegroundColor White
    Write-Host "  Uninstall      : $($Pkg.UninstallCommand)" -ForegroundColor White
    Write-Host "  Detection      : $($Pkg.DetectionMethod) -- $($Pkg.DetectionDetail)" -ForegroundColor White
    Write-Host "  Install as     : $($Pkg.InstallBehavior)" -ForegroundColor White
    Write-Host "  Min OS         : $($Pkg.MinOS)" -ForegroundColor White
    Write-Host "  Architecture   : $($Pkg.Architecture)" -ForegroundColor White
    Write-Host "  Output folder  : $PackageFolder" -ForegroundColor White

    if ($script:EscalationFlags.Count -gt 0) {
        Write-Host ""
        Write-Host "  [!] $($script:EscalationFlags.Count) escalation flag(s) -- Escalation-Notes.txt will be generated." -ForegroundColor Yellow
    }

    Write-Host ""
    if (-not (Read-YN "Build the package now?")) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        exit 0
    }

    New-Item -Path $SourceFolder -ItemType Directory -Force | Out-Null
    $DateStamp = Get-Date -Format "yyyy-MM-dd"

    Write-Host ""
    Write-Host "  Copying installer..." -ForegroundColor DarkGray
    Copy-Item -Path $SelectedFile.FullPath -Destination (Join-Path $SourceFolder $SelectedFile.Name) -Force

    Write-Host "  Generating Install script..." -ForegroundColor DarkGray
    $InstallScript = Build-InstallScript -SafeName $SafeName -AppName $AppName -InstallerFileName $SelectedFile.Name `
        -InstallerType $InstallerInfo.Type -InstallArgs $InstallerInfo.SuggestedArgs -DateStamp $DateStamp
    $InstallScript | Out-File -FilePath (Join-Path $SourceFolder "Install-$SafeName.ps1") -Encoding UTF8 -Force

    Write-Host "  Generating Uninstall script..." -ForegroundColor DarkGray
    $UninstallScript = Build-UninstallScript -SafeName $SafeName -AppName $AppName `
        -DisplayNameFilter $Pkg.DisplayNameFilter `
        -FallbackMethod $Pkg.UninstallMethod -FallbackProductCode $Pkg.FallbackProductCode `
        -FallbackExePath $Pkg.FallbackExePath -FallbackExeArgs $Pkg.FallbackExeArgs `
        -DateStamp $DateStamp
    $UninstallScript | Out-File -FilePath (Join-Path $SourceFolder "Uninstall-$SafeName.ps1") -Encoding UTF8 -Force

    Write-Host "  Generating Detection script..." -ForegroundColor DarkGray
    $DetectScript = Build-DetectScript -SafeName $SafeName -AppName $AppName -DetectionMethod $DetectionMethod `
        -DisplayNameFilter $DetectDisplayFilter -RegistryPath $DetectRegPath -FilePath $DetectFilePath `
        -ServiceName $DetectServiceName -MinVersion $DetectMinVersion -DateStamp $DateStamp
    $DetectScript | Out-File -FilePath (Join-Path $SourceFolder "Detect-$SafeName.ps1") -Encoding UTF8 -Force

    Write-Host "  Writing Package-Summary.txt..." -ForegroundColor DarkGray
    $Summary = Build-PackageSummary -Pkg $Pkg -Flags $script:EscalationFlags
    $Summary | Out-File -FilePath (Join-Path $PackageFolder "Package-Summary.txt") -Encoding UTF8 -Force

    if ($script:EscalationFlags.Count -gt 0) {
        Write-Host "  Writing Escalation-Notes.txt..." -ForegroundColor DarkGray
        $EscNotes = Build-EscalationNotes -Pkg $Pkg -Flags $script:EscalationFlags -InstallAttempts $script:InstallAttempts -UninstallAttempts $script:UninstallAttempts
        $EscNotes | Out-File -FilePath (Join-Path $PackageFolder "Escalation-Notes.txt") -Encoding UTF8 -Force
    }

    # IntuneWinAppUtil wrapping
    Write-Host ""
    $IntuneWinPath = $Pkg.IntuneWinPath
    $UtilPath = $null

    $CommonPaths = @(
        (Join-Path $PSScriptRoot "IntuneWinAppUtil.exe"),
        (Join-Path (Get-Location) "IntuneWinAppUtil.exe"),
        "C:\Tools\IntuneWinAppUtil.exe",
        (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads\IntuneWinAppUtil.exe")
    )
    foreach ($P in $CommonPaths) {
        if (Test-Path $P) { $UtilPath = $P; break }
    }

    if ($UtilPath) {
        Write-Host "  IntuneWinAppUtil.exe found at: $UtilPath" -ForegroundColor Green
        if (Read-YN "Wrap the Source folder into a .intunewin file now?") {
            Write-Host "  Wrapping..." -ForegroundColor DarkGray
            $WrapArgs = "-c `"$SourceFolder`" -s `"$($SelectedFile.Name)`" -o `"$PackageFolder`" -q"
            $WrapProc = Start-Process $UtilPath -ArgumentList $WrapArgs -Wait -PassThru -NoNewWindow
            if ($WrapProc.ExitCode -eq 0 -and (Test-Path $IntuneWinPath)) {
                Write-Host "  .intunewin created: $IntuneWinPath" -ForegroundColor Green
            } else {
                Write-Host "  [!] Wrapping may have failed. Check $PackageFolder for output." -ForegroundColor Yellow
                $IntuneWinPath = "(not created -- run IntuneWinAppUtil.exe manually)"
                Add-EscalationFlag "IntuneWinAppUtil.exe ran but the .intunewin file was not confirmed. Run manually: IntuneWinAppUtil.exe -c `"$SourceFolder`" -s `"$($SelectedFile.Name)`" -o `"$PackageFolder`""
            }
        }
    } else {
        Write-Host "  IntuneWinAppUtil.exe not found in common locations." -ForegroundColor Yellow
        Write-Host "  You can point to it now, or wrap the package manually later." -ForegroundColor DarkGray
        if (Read-YN "Browse to IntuneWinAppUtil.exe now?" -DefaultNo) {
            $UtilPicked = Show-FilePicker -Title "Select IntuneWinAppUtil.exe" -Filter "IntuneWinAppUtil.exe|IntuneWinAppUtil.exe|EXE Files (*.exe)|*.exe" -InitialDirectory "C:\"
            if ($UtilPicked -and (Test-Path $UtilPicked)) {
                Write-Host "  Wrapping..." -ForegroundColor DarkGray
                $WrapArgs = "-c `"$SourceFolder`" -s `"$($SelectedFile.Name)`" -o `"$PackageFolder`" -q"
                $WrapProc = Start-Process $UtilPicked -ArgumentList $WrapArgs -Wait -PassThru -NoNewWindow
                if ($WrapProc.ExitCode -eq 0 -and (Test-Path $IntuneWinPath)) {
                    Write-Host "  .intunewin created: $IntuneWinPath" -ForegroundColor Green
                } else {
                    $IntuneWinPath = "(not created)"
                }
            }
        } else {
            $IntuneWinPath = "(not created -- run IntuneWinAppUtil.exe manually)"
            Add-EscalationFlag "IntuneWinAppUtil.exe was not available. To create the .intunewin file manually run: IntuneWinAppUtil.exe -c `"$SourceFolder`" -s `"$($SelectedFile.Name)`" -o `"$PackageFolder`""
        }
    }

    $Pkg.IntuneWinPath = $IntuneWinPath
    $Summary = Build-PackageSummary -Pkg $Pkg -Flags $script:EscalationFlags
    $Summary | Out-File -FilePath (Join-Path $PackageFolder "Package-Summary.txt") -Encoding UTF8 -Force

    if ($script:EscalationFlags.Count -gt 0) {
        $EscNotes = Build-EscalationNotes -Pkg $Pkg -Flags $script:EscalationFlags -InstallAttempts $script:InstallAttempts -UninstallAttempts $script:UninstallAttempts
        $EscNotes | Out-File -FilePath (Join-Path $PackageFolder "Escalation-Notes.txt") -Encoding UTF8 -Force
    }

    Start-Process explorer.exe $PackageFolder

    #######################################################################################
    # Final Output
    #######################################################################################

    Write-Section "COMPLETE"
    Write-Host ""
    Write-Host "  Package folder opened in Explorer:" -ForegroundColor Green
    Write-Host "  $PackageFolder" -ForegroundColor Cyan
    Write-Host ""

    if ($script:EscalationFlags.Count -gt 0) {
        Write-Host "  [$($script:EscalationFlags.Count)] escalation flag(s) need review before production deploy:" -ForegroundColor Yellow
        foreach ($Flag in $script:EscalationFlags) {
            Write-Host "    - $($Flag.Substring(0, [Math]::Min(90, $Flag.Length)))..." -ForegroundColor Yellow
        }
        Write-Host ""
        Write-Host "  Full details in: Escalation-Notes.txt" -ForegroundColor Yellow
    } else {
        Write-Host "  No escalation flags -- package looks ready to deploy." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor Cyan
    Write-Host "    1. Review Package-Summary.txt -- all Intune upload fields are pre-filled" -ForegroundColor White
    Write-Host "    2. Upload the .intunewin to Intune and paste fields from the summary" -ForegroundColor White
    Write-Host "    3. Assign to a TEST group first and verify before broad deployment" -ForegroundColor White
    Write-Host ""
}

###########################################################################################

try {
    Main
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
