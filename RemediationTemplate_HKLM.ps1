<# 
    - Created: 12.5.2025
    - Purpose: Creating a modular type of registry remediation script for Intune
#>

# Specify registry to check
$Checks = @(
    @{
        Path = "HKLM:\Test"
        Name = "test"
        ExpectedValue = 1
    },
    @{
        Path = "HKLM:\Test2"
        Name = "Test2"
        ExpectedValue = 1
    }
)


# Testing registry value
function Test-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $ExpectedValue
    )

    if (-not (Test-Path $Path)) { return $false }

    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $false }

        return ($item.$Name -eq $ExpectedValue)
    }
    catch {
        return $false
    }
}

# Running the actual check
$NonCompliant = @()

foreach ($check in $Checks) {
    if (-not (Test-RegistryValue -Path $check.Path -Name $check.Name -ExpectedValue $check.ExpectedValue)) {
        $NonCompliant += "$($check.Path)\$($check.Name) expected value $($check.ExpectedValue)"
    }
}

if ($NonCompliant.Count -eq 0) {
    Write-Output "Compliant"
    exit 0
} else {
    Write-Output "Not Compliant:`n$($NonCompliant -join "`n")"
    exit 1
}




##########################
# Remediation

<# 
Remediation Script to apply any missing paths 
#>


# Define remediation items
$Fixes = @(
    @{
        Path = "HKLM:\Test"
        Name = "test"
        Type = "DWord"
        Value = 1
    },
    @{
        Path = "HKLM:\Test2"
        Name = "Test2"
        Type = "DWord"
        Value = 1
    }
)


# Ensure registry path exists
function Ensure-RegistryPath {
    param([string]$Path)

    $parent = "HKLM:"
    $parts = ($Path -replace "HKLM:\\", "").Split("\")
    
    foreach ($p in $parts) {
        $current = Join-Path $parent $p
        if (-not (Test-Path $current)) {
            New-Item -Path $parent -Name $p -Force | Out-Null
        }
        $parent = $current
    }
}


# Set the registry value
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Type,
        $Value
    )

    Ensure-RegistryPath -Path $Path

    try {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    }
    catch {
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force | Out-Null
    }
}


# Attempting fix
foreach ($fix in $Fixes) {
    Set-RegistryValue -Path $fix.Path -Name $fix.Name -Type $fix.Type -Value $fix.Value
}

Write-Output "Remediation complete"
exit 0
