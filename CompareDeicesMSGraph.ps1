<#
Input your function here to connect to MSgraph

#>

# ================================
# Get Policies and Groups for a Device
# ================================
function Get-DeviceAssignments {
    param(
        [Parameter(Mandatory)]
        [string]$DeviceId
    )

    # Get configuration policies assigned to this device
    $policies = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$DeviceId/deviceConfigurationStates" `
        | Select-Object -ExpandProperty value

    # Get Azure AD Groups the device is a member of
    $groups = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/devices/$DeviceId/memberOf" `
        | Select-Object -ExpandProperty value

    return [PSCustomObject]@{
        DeviceId = $DeviceId
        Policies = $policies
        Groups = $groups
    }
}

# ================================
# Compare Two Devices
# ================================
function Compare-TwoDevices {
    param(
        [string]$DeviceA,
        [string]$DeviceB
    )

    Write-Host "`nPulling assignments..." -ForegroundColor Cyan
    
    $A = Get-DeviceAssignments -DeviceId $DeviceA
    $B = Get-DeviceAssignments -DeviceId $DeviceB

    Write-Host "`n=== POLICY DIFFERENCES ===" -ForegroundColor Yellow

    $A_Policies = $A.Policies.settingStates.settingDisplayName
    $B_Policies = $B.Policies.settingStates.settingDisplayName

    Compare-Object $A_Policies $B_Policies |
        Select-Object InputObject, SideIndicator

    Write-Host "`n=== GROUP DIFFERENCES ===" -ForegroundColor Yellow

    $A_Groups = $A.Groups.displayName
    $B_Groups = $B.Groups.displayName

    Compare-Object $A_Groups $B_Groups |
        Select-Object InputObject, SideIndicator

    Write-Host "`nComparison complete." -ForegroundColor Green
}

# ================================
# Compare Device List Against Each Other
# ================================
function Compare-DeviceList {
    param(
        [string]$DeviceListPath
    )

    if (-not (Test-Path $DeviceListPath)) {
        Write-Error "Device list file not found."
        return
    }

    $deviceIds = Get-Content $DeviceListPath

    Write-Host "`nCollecting assignments for all devices..." -ForegroundColor Cyan
    $all = @{}

    foreach ($id in $deviceIds) {
        Write-Host "→ Gathering for $id"
        $all[$id] = Get-DeviceAssignments -DeviceId $id
    }

    Write-Host "`n=== MULTI-DEVICE COMPARISON REPORT ===" -ForegroundColor Yellow

    foreach ($i in 0..($deviceIds.Count - 1)) {
        foreach ($j in ($i + 1)..($deviceIds.Count - 1)) {
            $A = $deviceIds[$i]
            $B = $deviceIds[$j]

            Write-Host "`nComparing $A ↔ $B" -ForegroundColor Cyan

            $A_Policies = $all[$A].Policies.settingStates.settingDisplayName
            $B_Policies = $all[$B].Policies.settingStates.settingDisplayName

            Write-Host "Policy Differences:"
            Compare-Object $A_Policies $B_Policies |
                Select-Object InputObject, SideIndicator

            $A_Groups = $all[$A].Groups.displayName
            $B_Groups = $all[$B].Groups.displayName

            Write-Host "Group Differences:"
            Compare-Object $A_Groups $B_Groups |
                Select-Object InputObject, SideIndicator
        }
    }

    Write-Host "`nAll comparisons complete." -ForegroundColor Green
}


# Menu

function Start-DeviceComparisonMenu {

    #Change this to your msgraph connection function from above.

    do {
        Clear-Host
        Write-Host "==================================="
        Write-Host " DEVICE POLICY/GROUP COMPARISON TOOL"
        Write-Host "==================================="
        Write-Host "1. Compare two devices"
        Write-Host "2. Compare list of devices"
        Write-Host "0. Exit"
        Write-Host "-----------------------------------"
        $choice = Read-Host "Choose an option"

        switch ($choice) {
            "1" {
                $a = Read-Host "Enter Device A (DeviceId)"
                $b = Read-Host "Enter Device B (DeviceId)"
                Compare-TwoDevices -DeviceA $a -DeviceB $b
                Pause
            }
            "2" {
                $path = Read-Host "Enter path to device list file (one DeviceId per line)"
                Compare-DeviceList -DeviceListPath $path
                Pause
            }
            "0" {
                Write-Host "Goodbye!" -ForegroundColor Green
                return
            }
            default {
                Write-Host "Invalid option." -ForegroundColor Red
                Pause
            }
        }
    } while ($true)
}

# Start the script
Start-DeviceComparisonMenu
