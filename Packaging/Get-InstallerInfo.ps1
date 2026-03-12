# ==============================================================================
# Get-InstallerInfo.ps1
# Purpose  : Detects the installer engine type and recommends silent switches
# Usage    : .\Get-InstallerInfo.ps1 -InstallerPath "C:\Path\To\setup.exe"
# Author   : [CHANGE ME] - Your Name / Team Name
# Version  : 1.1
# ==============================================================================

param(
    [Parameter(Mandatory)]
    [string]$InstallerPath
)

# ==============================================================================
# REGION: LOGGING CONFIGURATION
# ==============================================================================
$LogDir  = "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs"
$LogFile = Join-Path $LogDir "PKG_InstallerInfo_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        'WARN'    { Write-Host $entry -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

# ==============================================================================
# REGION: HELP OUTPUT CAPTURE
# ------------------------------------------------------------------------------
# Runs the installer with /? and captures any output. Many installers print
# their available switches this way. Runs with a 10-second timeout so it
# doesn't hang if the installer opens a GUI dialog instead.
# ==============================================================================
function Get-InstallerHelp {
    param([string]$Path)

    Write-Log "Running '$Path /?' to capture built-in help..."

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $Path
        $psi.Arguments              = '/?' 
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(10000) | Out-Null   # 10-second timeout

        $combined = ($stdout + $stderr).Trim()
        if ($combined) {
            return $combined
        } else {
            return "No output returned from /?  — installer may have opened a GUI dialog or does not support this flag."
        }
    }
    catch {
        return "Could not run /? — $_"
    }
}

# ==============================================================================
# REGION: INSTALLER TYPE DETECTION
# ==============================================================================
function Get-InstallerType {
    param([string]$Path)

    # FIX: Resolve relative paths (e.g. .\setup.exe) to absolute so
    #      ReadAllBytes and Process.Start both work correctly.
    $Path = (Resolve-Path $Path -ErrorAction Stop).Path

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    $result = [PSCustomObject]@{
        File        = Split-Path $Path -Leaf
        FullPath    = $Path
        Extension   = $ext
        Engine      = 'Unknown'
        SilentArgs  = @()
        LogArg      = ''
        Notes       = ''
        HelpOutput  = ''
    }

    # --- MSI ---
    if ($ext -eq '.msi') {
        $result.Engine     = 'Windows Installer (MSI)'
        $result.SilentArgs = @('/qn', '/norestart')
        $result.LogArg     = '/l*v "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>_msi.log"'
        $result.Notes      = 'Use msiexec.exe /i "<path>" /qn /norestart /l*v "<log>"'
        return $result
    }

    # --- MSP (MSI Patch) ---
    if ($ext -eq '.msp') {
        $result.Engine     = 'MSI Patch'
        $result.SilentArgs = @('/qn', '/norestart')
        $result.LogArg     = '/l*v "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>_patch.log"'
        $result.Notes      = 'Use msiexec.exe /p "<path>" /qn /norestart'
        return $result
    }

    # --- EXE detection via binary header and version info ---
    if ($ext -eq '.exe') {
        $bytes       = [System.IO.File]::ReadAllBytes($Path)
        $content     = [System.Text.Encoding]::ASCII.GetString($bytes[0..([Math]::Min(65535, $bytes.Length - 1))])
        $versionInfo = (Get-Item $Path).VersionInfo
        $searchStr   = "$($versionInfo.FileDescription) $($versionInfo.ProductName) $content"

        switch -Regex ($searchStr) {

            'Inno Setup' {
                $result.Engine     = 'Inno Setup'
                $result.SilentArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-')
                $result.LogArg     = '/LOG="C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>.log"'
                break
            }

            'NSIS|Nullsoft' {
                $result.Engine     = 'NSIS (Nullsoft)'
                $result.SilentArgs = @('/S')
                $result.Notes      = 'Some NSIS installers also accept /D=<installdir> for a custom install path. Test both.'
                break
            }

            'InstallShield' {
                $result.Engine     = 'InstallShield'
                $result.SilentArgs = @('/s', '/v"/qn /norestart"')
                $result.LogArg     = '/v"/l*v C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>.log"'
                $result.Notes      = 'InstallShield wraps MSI. The /v flag passes arguments directly to msiexec.'
                break
            }

            'WiX|Windows Installer XML' {
                $result.Engine     = 'WiX Bootstrapper'
                $result.SilentArgs = @('/quiet', '/norestart')
                $result.LogArg     = '/log "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>.log"'
                break
            }

            'Setup Factory' {
                $result.Engine     = 'Setup Factory'
                $result.SilentArgs = @('/S')
                break
            }

            'Advanced Installer' {
                $result.Engine     = 'Advanced Installer'
                $result.SilentArgs = @('/exenoui', '/qn', '/norestart')
                $result.LogArg     = '/log "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\PKG_<AppName>.log"'
                break
            }

            { $content -match 'MsiExec|\.msi' } {
                $result.Engine     = 'Likely MSI Wrapper / Bootstrapper'
                $result.SilentArgs = @('/quiet', '/qn', '/silent', '/s')
                $result.Notes      = 'Try extracting embedded MSI first: .\installer.exe /extract  or  /layout  or  /x'
                break
            }

            default {
                $result.Engine     = 'Unknown EXE'
                $result.SilentArgs = @('/quiet', '/silent', '/S', '/s', '-silent', '--silent')
                $result.Notes      = 'Engine not recognized from binary scan — see /? output below for clues.'
            }
        }

        # Always capture /? help output for EXEs so there's something useful to work with
        $result.HelpOutput = Get-InstallerHelp -Path $Path
    }

    return $result
}

# ==============================================================================
# REGION: MAIN EXECUTION
# ==============================================================================
Write-Log "===== GET-INSTALLERINFO STARTED ====="
Write-Log "Analyzing: $InstallerPath"

if (-not (Test-Path $InstallerPath)) {
    Write-Log "Installer path not found: $InstallerPath" 'ERROR'
    exit 1
}

$info = Get-InstallerType -Path $InstallerPath

# Output to console
Write-Host "`n===== INSTALLER ANALYSIS =====" -ForegroundColor Cyan
Write-Host "File      : $($info.File)"
Write-Host "Full Path : $($info.FullPath)"
Write-Host "Engine    : $($info.Engine)"        -ForegroundColor Yellow
Write-Host "`nSuggested Silent Switches:"         -ForegroundColor Green
$info.SilentArgs | ForEach-Object { Write-Host "  $_" }
if ($info.LogArg) { Write-Host "Log Arg   : $($info.LogArg)"  -ForegroundColor Green }
if ($info.Notes)  { Write-Host "`nNotes     : $($info.Notes)" -ForegroundColor Magenta }

if ($info.HelpOutput) {
    Write-Host "`n===== INSTALLER /? OUTPUT =====" -ForegroundColor Cyan
    Write-Host $info.HelpOutput
    Write-Host "==============================`n"
}

Write-Host "==============================`n"

# Write results to log
Write-Log "Engine    : $($info.Engine)"
Write-Log "SilentArgs: $($info.SilentArgs -join ' ')"
if ($info.LogArg)     { Write-Log "LogArg    : $($info.LogArg)" }
if ($info.Notes)      { Write-Log "Notes     : $($info.Notes)" }
if ($info.HelpOutput) { Write-Log "HelpOutput:`n$($info.HelpOutput)" }
Write-Log "===== GET-INSTALLERINFO COMPLETE — Log: $LogFile ====="
