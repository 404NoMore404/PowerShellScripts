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
        $Widths[$col] = $max
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
            $line += $row.$col.ToString().PadRight($Widths[$col] + 2)
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
# 3. Devices by Operating System
# =============================
Write-Section "Devices by Operating System"

$rows = $devices |
    Group-Object OperatingSystem |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            OS    = Trunc $_.Name $MaxColWidth
            Count = $_.Count
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

$rows = $devices |
    Group-Object Model |
    Sort-Object Count -Descending |
    ForEach-Object {
        [PSCustomObject]@{
            Model = Trunc $_.Name $MaxColWidth
            Count = $_.Count
        }
    }

Write-Table -Rows $rows

# =============================
# Done
# =============================
Write-Host "`nReport Complete." -ForegroundColor Yellow
Write-Host "=====================================`n"
