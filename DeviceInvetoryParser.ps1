Add-Type -AssemblyName System.Windows.Forms

# =============================
# Configs
# =============================
[int]$MaxColWidth = 36   # Max characters displayed per column

# =============================
# File Picker Dialog
# =============================
$FileDialog = New-Object System.Windows.Forms.OpenFileDialog
$FileDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
$FileDialog.Filter = "CSV Files (*.csv)|*.csv"
$FileDialog.Title = "Select Intune Device Export CSV"

if ($FileDialog.ShowDialog() -ne "OK") {
    Write-Host "No file selected. Exiting..." -ForegroundColor Red
    exit
}

$csvPath = $FileDialog.FileName
Write-Host "`n====================================="
Write-Host " Selected File: $csvPath"
Write-Host "=====================================`n"

$devices = Import-Csv -Path $csvPath

if (-not $devices) {
    Write-Host "No devices found in CSV. Exiting..." -ForegroundColor Red
    exit
}

# =============================
# Filter by Category Prompt
# =============================
$allCategories = $devices | Select-Object -ExpandProperty Category -Unique | Sort-Object
Write-Host "`nAvailable Categories:" -ForegroundColor Cyan
$allCategories | ForEach-Object { Write-Host " - $_" }

$categoryChoice = Read-Host "`nDo you want to run for the entire file or a specific Category? Enter 'All' or type the Category name"

if ($categoryChoice -ne "All") {
    if ($allCategories -notcontains $categoryChoice) {
        Write-Host "Category '$categoryChoice' not found. Exiting..." -ForegroundColor Red
        exit
    }
    $devices = $devices | Where-Object { $_.Category -eq $categoryChoice }
    Write-Host "`nRunning report for Category: $categoryChoice`n" -ForegroundColor Green
} else {
    Write-Host "`nRunning report for all devices`n" -ForegroundColor Green
}


# =============================
# Helper: Section Header
# =============================
function Write-Section {
    param([string]$Title)
    Write-Host "`n-------------------------------------" -ForegroundColor DarkGray
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host "-------------------------------------`n" -ForegroundColor DarkGray
}

# =============================
# Helper: Truncate Text
# =============================
function Trunc {
    param([string]$Text, [int]$Max = 36)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max - 3) + "..."
}

# =============================
# Helper: Write Perfect Table
# =============================
function Write-Table {
    param(
        [Parameter(Mandatory)]
        [array]$Rows
    )

    if ($Rows.Count -eq 0) {
        Write-Host "(no data)"
        return
    }

    $Columns = $Rows[0].PSObject.Properties.Name
    $Widths = @{}

    foreach ($col in $Columns) {
        $max = ($Rows | ForEach-Object { $_.$col.ToString().Length } | Measure-Object -Maximum).Maximum
        if ($col.Length -gt $max) { $max = $col.Length }
        $Widths[$col] = if ($max -gt $MaxColWidth) { $MaxColWidth } else { $max }
    }

    # Header
    $header = ""
    foreach ($col in $Columns) {
        $header += $col.PadRight($Widths[$col] + 2)
    }
    Write-Host $header -ForegroundColor Cyan

    # Separator
    $sep = ""
    foreach ($col in $Columns) {
        $sep += ("-" * $Widths[$col]) + "  "
    }
    Write-Host $sep -ForegroundColor DarkGray

    # Data rows
    foreach ($row in $Rows) {
        $line = ""
        foreach ($col in $Columns) {
            $val = Trunc $row.$col $Widths[$col]
            $line += $val.PadRight($Widths[$col] + 2)
        }
        Write-Host $line
    }
}

# =============================
# 1. Total Device Count
# =============================
Write-Section "Total Device Count"
Write-Host "Total Devices Found: $($devices.Count)" -ForegroundColor Green

# =============================
# 2. Devices by Category
# =============================
Write-Section "Devices by Category"
$rows = $devices |
    Group-Object DeviceCategoryDisplayName |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            Category = Trunc $_.Name $MaxColWidth
            Count    = $_.Count
        }
    }
Write-Table -Rows $rows


# =============================
# 4. Devices by Ownership
# =============================
Write-Section "Devices by Ownership"
$rows = $devices |
    Group-Object Ownership |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            Ownership = Trunc $_.Name $MaxColWidth
            Count     = $_.Count
        }
    }
Write-Table -Rows $rows

# =============================
# 5. Devices by Model
# =============================
Write-Section "Devices by Model"

$ModelMaxWidth = 17   # Limit model name to 17 characters

$rows = $devices |
    Group-Object Model |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            Model = Trunc $_.Name $ModelMaxWidth
            Count = $_.Count
        }
    }
Write-Table -Rows $rows


# =============================
# 6. Devices by OS Version
# =============================
Write-Section "Devices by OS Version"
$rows = $devices |
    Group-Object -Property "OS version" |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            OSVersion = Trunc $_.Name $MaxColWidth
            Count     = $_.Count
        }
    }
Write-Table -Rows $rows

# =============================
# 7. Devices by Windows Release & Build
# =============================
Write-Section "Devices by Windows Release (H2) and Build"

# Map build numbers to H2 releases
function Get-WinRelease {
    param([string]$Build)

    switch -Regex ($Build) {
        "^10\.0\.26200"   { return "Windows 11 25H2" }  # 25H2 builds
        "^10\.0\.26100"   { return "Windows 11 24H2" }  # 24H2 builds
        "^10\.0\.25252"   { return "Windows 11 24H2" }  # older 24H2 builds
        "^10\.0\.22963"   { return "Windows 11 23H2" }
        "^10\.0\.2262[13]" { return "Windows 11 22H2" }
        "^10\.0\.19045"   { return "Windows 10 22H2" }
        "^10\.0\.19044"   { return "Windows 10 21H2" }
        default           { return "Unknown" }
    }
}

# Group devices by release, then by build
$releaseGroups = $devices |
    ForEach-Object {
        [PSCustomObject]@{
            Release = Get-WinRelease $_."OS version"
            Build   = $_."OS version"
        }
    } |
    Group-Object -Property Release

foreach ($release in $releaseGroups) {
    Write-Host "`n$($release.Name)" -ForegroundColor Yellow
    $buildRows = $release.Group |
        Group-Object -Property Build |
        Sort-Object Count -Descending |
        ForEach-Object {
            [PSCustomObject]@{
                Build = $_.Name
                Count = $_.Count
            }
        }
    Write-Table -Rows $buildRows
}

# =============================
# Done
# =============================
Write-Host "`nReport Complete." -ForegroundColor Yellow
Write-Host "=====================================`n"
