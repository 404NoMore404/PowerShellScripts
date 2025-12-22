
function Get-SafeConsoleWidth {
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -lt 40) { return 80 }
        return $w
    } catch {
        return 80
    }
}

function Write-Border {
    param (
        [string]$Char = "═",
        [ConsoleColor]$Color = "Cyan"
    )

    $width = Get-SafeConsoleWidth
    Write-Host ($Char * $width) -ForegroundColor $Color
}

function Write-CenteredLine {
    param (
        [string]$Text,
        [ConsoleColor]$Color = "White"
    )

    $width = Get-SafeConsoleWidth
    $innerWidth = [Math]::Max($width - 4, 0)

    if ($innerWidth -le 0) {
        Write-Host $Text -ForegroundColor $Color
        return
    }

    if ($Text.Length -gt $innerWidth) {
        $Text = $Text.Substring(0, $innerWidth)
    }

    $space = $innerWidth - $Text.Length
    $paddingLeft  = [Math]::Max([Math]::Floor($space / 2), 0)
    $paddingRight = [Math]::Max($space - $paddingLeft, 0)

    Write-Host (
        $Border +
        (' ' * $paddingLeft) +
        $Text +
        (' ' * $paddingRight) +
        " $Border"
    ) -ForegroundColor $Color
}


# Menu Behind the Scenes


function Show-Menu {
    param (
        [string]$Title,
        [string[]]$Options,
        [string]$Footer = "Version 1.6",
        [string[]]$Breadcrumbs = @("Main Menu")
    )

    $breadcrumbText = ($Breadcrumbs -join " > ")

    do {
        Clear-Host

        $hostname = $env:COMPUTERNAME
        $user     = whoami
        $identity = "Host: $hostname | User: $user"

        Write-Border "═" DarkCyan
        Write-CenteredLine $Title DarkYellow
        Write-CenteredLine $identity DarkGray
        Write-CenteredLine $breadcrumbText DarkYellow        
        Write-Border "─" DarkCyan

        Write-Host ""
        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host ("     {0}. {1}" -f ($i + 1), $Options[$i])
        }
        Write-Host ""

        Write-Border "─" DarkCyan
        Write-CenteredLine $Footer DarkGray
        Write-Border "═" DarkCyan

        $choice = Read-Host "`nPlease choose an option"
    }
    while (-not ($choice -as [int]) -or
           $choice -lt 1 -or
           $choice -gt $Options.Count)

    return [int]$choice
}


# Submenus


function IntuneDevices {
    $options = @(
        "Collect Device Inventory Export",
        "Show Windows Updates",
        "Show Device Models",
        "Primary User Not Assigned",
        "Back to Main Menu"
    )

    do {
        $choice = Show-Menu `
            -Title "Intune Devices" `
            -Options $options `
            -Footer "It's Intune Time" `
            -Breadcrumbs @("Main Menu", "Intune Devices")

        switch ($choice) {
            1 {
                # Step 1: Open webpage
                $url = "https://intune.microsoft.com/#view/Microsoft_Intune_DeviceSettings/DevicesWindowsMenu/~/windowsDevices"
                Start-Process $url

                # Step 2: Prompt user to wait until download finishes
                Write-Host "`nPlease download the file from the webpage. Press Enter when the download is complete."
                Read-Host

                # Step 3: Let user pick the downloaded file
                Add-Type -AssemblyName System.Windows.Forms
                $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
                $fileDialog.InitialDirectory = [Environment]::GetFolderPath("Desktop")
                $fileDialog.Filter = "ZIP files (*.zip)|*.zip|All files (*.*)|*.*"
                $fileDialog.Title = "Select the downloaded Intune ZIP file"

                if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $selectedFile = $fileDialog.FileName

                    # Step 4: Prepare destination folder
                    $destinationFolder = "C:\Temp"
                    if (-not (Test-Path $destinationFolder)) {
                        New-Item -Path $destinationFolder -ItemType Directory | Out-Null
                    }

                    # Step 5: Extract the ZIP
                    $today = Get-Date -Format "yyyy-MM-dd"
                    $newFolderName = "IntuneDeviceExport_$today"
                    $extractedPath = Join-Path $destinationFolder $newFolderName

                    if (Test-Path $extractedPath) {
                        Remove-Item -Path $extractedPath -Recurse -Force
                    }

                    Expand-Archive -Path $selectedFile -DestinationPath $extractedPath -Force

                    Write-Host "`nZIP file extracted and renamed to $newFolderName" -ForegroundColor Green
                    Pause
                }
                else {
                    Write-Host "No file selected. Returning to menu." -ForegroundColor Yellow
                    Pause
                }
            }
            2 {
                $ErrorActionPreference = "Stop"


                function Get-WindowsRelease {
                    param([string]$OsVersion)

                    if ($OsVersion -match '^10\.0\.(\d+)') {
                        $build = [int]$Matches[1]

                        if ($build -ge 26200) { return "Windows 11 25H2" }
                        elseif ($build -ge 26100) { return "Windows 11 24H2" }
                        elseif ($build -ge 22631) { return "Windows 11 23H2" }
                        elseif ($build -ge 22621) { return "Windows 11 22H2" }
                    }
                    return "Unknown"
                }

                $tempFolder = "C:\Temp"

                $exportFolders = Get-ChildItem -Path $tempFolder -Directory -Filter "IntuneDeviceExport_*" |
                Sort-Object LastWriteTime -Descending

                if (-not $exportFolders) {
                    Write-Host "No Intune export folders found." -ForegroundColor Red
                    return
                }

                Write-Host "`nSelect an Intune export folder:`n" -ForegroundColor Cyan
                $folderOptions = @()

                $recent = $exportFolders | Select-Object -First 3
                for ($i = 0; $i -lt $recent.Count; $i++) {
                    Write-Host "$($i + 1). $($recent[$i].Name)" -ForegroundColor Green
                    $folderOptions += $recent[$i].FullName
                }

                Write-Host "$($folderOptions.Count + 1). Manual Select (Browse Folder)" -ForegroundColor Green
                $choice = Read-Host "Enter number"

                if ($choice -eq ($folderOptions.Count + 1)) {
                    Add-Type -AssemblyName System.Windows.Forms
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    if ($dlg.ShowDialog() -ne "OK") { return }
                    $selectedFolder = $dlg.SelectedPath
                }
                else {
                    $selectedFolder = $folderOptions[$choice - 1]
                }

                Write-Host "`nSelected Folder: $selectedFolder" -ForegroundColor Cyan

                $csv = Get-ChildItem $selectedFolder -Filter *.csv | Select-Object -First 1
                if (-not $csv) {
                    Write-Host "No CSV found." -ForegroundColor Red
                    return
                }

                $devices = Import-Csv $csv.FullName
                $osColumn = "OS version"

                if (-not ($devices[0].PSObject.Properties.Name -contains $osColumn)) {
                    Write-Host "Column '$osColumn' NOT found." -ForegroundColor Red
                    return
                }

                $devices = $devices | Where-Object { $_.$osColumn }

                foreach ($d in $devices) {
                    $d | Add-Member -NotePropertyName Release -NotePropertyValue (Get-WindowsRelease $d.$osColumn)
                    $d | Add-Member -NotePropertyName Build -NotePropertyValue ($d.$osColumn)
                }


                Write-Host "`nFilter Options:" -ForegroundColor Cyan
                Write-Host "1. All Devices"
                Write-Host "2. Filter by Windows Release"
                Write-Host "3. Filter by Specific Build"

                $filterChoice = Read-Host "Choose option"

                switch ($filterChoice) {

                    "2" {
                        # List available releases
                        $releases = $devices |
                        Select-Object -ExpandProperty Release -Unique |
                        Sort-Object

                        Write-Host "`nAvailable Windows Releases:`n" -ForegroundColor Cyan
                        for ($i = 0; $i -lt $releases.Count; $i++) {
                            Write-Host "$($i + 1). $($releases[$i])" -ForegroundColor Green
                        }

                        $releaseChoice = Read-Host "Select a release by number"
                        if (-not ($releaseChoice -as [int]) -or
                            $releaseChoice -lt 1 -or
                            $releaseChoice -gt $releases.Count) {
                            Write-Host "Invalid selection." -ForegroundColor Red
                            return
                        }

                        $selectedRelease = $releases[$releaseChoice - 1]
                        $devices = $devices | Where-Object { $_.Release -eq $selectedRelease }
                    }

                    "3" {
                        # List builds with counts
                        $builds = $devices |
                        Group-Object Build |
                        Sort-Object Name

                        Write-Host "`nAvailable Builds:`n" -ForegroundColor Cyan
                        for ($i = 0; $i -lt $builds.Count; $i++) {
                            Write-Host "$($i + 1). $($builds[$i].Name) ($($builds[$i].Count) devices)" -ForegroundColor Green
                        }

                        $buildChoice = Read-Host "Select a build by number"
                        if (-not ($buildChoice -as [int]) -or
                            $buildChoice -lt 1 -or
                            $buildChoice -gt $builds.Count) {
                            Write-Host "Invalid selection." -ForegroundColor Red
                            return
                        }

                        $selectedBuild = $builds[$buildChoice - 1].Name
                        $devices = $devices | Where-Object { $_.Build -eq $selectedBuild }
                    }
                }


                $releaseOrder = @(
                    "Windows 11 25H2",
                    "Windows 11 24H2",
                    "Windows 11 23H2",
                    "Windows 11 22H2",
                    "Unknown"
                )

                foreach ($release in $releaseOrder) {
                    $releaseDevices = $devices | Where-Object { $_.Release -eq $release }
                    if (-not $releaseDevices) { continue }

                    Write-Host "`n$release" -ForegroundColor Cyan
                    Write-Host ("=" * $release.Length)

                    $releaseDevices |
                    Group-Object Build |
                    Sort-Object Name |
                    Select-Object @{n = "Build"; e = { $_.Name } },
                    @{n = "Count"; e = { $_.Count } } |
                    Format-Table -AutoSize
                }

                Write-Host "`nDo you want to export the resulting devices to CSV? (yes / no) [default: no]" -ForegroundColor Cyan
                $exportChoice = Read-Host "Enter choice"

                if ($exportChoice -match '^(?i)y(es)?$') {

                    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    $exportPath = Join-Path $selectedFolder "Filtered_Devices_$timestamp.csv"

                    $devices | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8

                    Write-Host "`nExport completed:" -ForegroundColor Green
                    Write-Host $exportPath -ForegroundColor Yellow
                }
                else {
                    Write-Host "`nExport skipped." -ForegroundColor DarkGray
                }


                Pause


            }
            3 { 
            $tempFolder = "C:\Temp"
                [int]$MaxColWidth = 45

                function Write-Section {
                    param([string]$Title)
                    Write-Host ""
                    Write-Host ("=" * 70) -ForegroundColor DarkGray
                    Write-Host ("  $Title") -ForegroundColor Cyan
                    Write-Host ("=" * 70) -ForegroundColor DarkGray
                    Write-Host ""
                }

                function Trunc {
                    param([string]$Text, [int]$MaxLength = 45)
                    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
                    if ($Text.Length -le $MaxLength) { return $Text }
                    return $Text.Substring(0, $MaxLength - 3) + "..."
                }

                function Write-Table {
                    param([array]$Rows)
                    if (-not $Rows -or $Rows.Count -eq 0) {
                        Write-Host "(no data)" -ForegroundColor Yellow
                        return
                    }

                    $columns = $Rows[0].PSObject.Properties.Name
                    $widths = @{}

                    foreach ($col in $columns) {
                        $max = ($Rows | ForEach-Object { ($_.$col | Out-String).Trim().Length } | Measure-Object -Maximum).Maximum
                        if ($col.Length -gt $max) { $max = $col.Length }
                        if ($max -gt $MaxColWidth) { $max = $MaxColWidth }
                        $widths[$col] = $max
                    }

                    foreach ($col in $columns) {
                        Write-Host ($col.PadRight($widths[$col] + 2)) -NoNewline -ForegroundColor Cyan
                    }
                    Write-Host ""
                    foreach ($col in $columns) {
                        Write-Host (("-" * $widths[$col]).PadRight($widths[$col] + 2)) -NoNewline -ForegroundColor DarkGray
                    }
                    Write-Host ""
                    foreach ($row in $Rows) {
                        foreach ($col in $columns) {
                            $value = Trunc ($row.$col) $widths[$col]
                            Write-Host ($value.PadRight($widths[$col] + 2)) -NoNewline
                        }
                        Write-Host ""
                    }
                }

                # === Select Export Folder ===
                $exportFolders = Get-ChildItem -Path $tempFolder -Directory -Filter "IntuneDeviceExport_*" | Sort-Object LastWriteTime -Descending
                if (-not $exportFolders) { Write-Host "No Intune export folders found." -ForegroundColor Red; Pause; return }

                Write-Host "`nSelect an Intune export folder:`n" -ForegroundColor Cyan
                $folderOptions = @()
                $recent = $exportFolders | Select-Object -First 3
                for ($i = 0; $i -lt $recent.Count; $i++) {
                    Write-Host "$($i+1). $($recent[$i].Name)" -ForegroundColor Green
                    $folderOptions += $recent[$i].FullName
                }
                Write-Host "$($folderOptions.Count + 1). Manual Select (Browse Folder)" -ForegroundColor Green
                $choice = Read-Host "Enter number"

                if ($choice -eq ($folderOptions.Count + 1)) {
                    Add-Type -AssemblyName System.Windows.Forms
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    if ($dlg.ShowDialog() -ne "OK") { return }
                    $selectedFolder = $dlg.SelectedPath
                }
                else {
                    $selectedFolder = $folderOptions[$choice - 1]
                }

                Write-Host "`nSelected Folder: $selectedFolder" -ForegroundColor Cyan
                $csv = Get-ChildItem $selectedFolder -Filter *.csv | Select-Object -First 1
                if (-not $csv) { Write-Host "No CSV found." -ForegroundColor Red; return }

                $devices = Import-Csv $csv.FullName
                $manufacturerCol = "Manufacturer"
                $modelCol = "Model"
                $categoryCol = "Category"

                # Validate required columns
                foreach ($col in @($manufacturerCol, $modelCol, $categoryCol)) {
                    if (-not ($devices[0].PSObject.Properties.Name -contains $col)) { Write-Host "Missing required column: $col" -ForegroundColor Red; Pause; return }
                }

                $filteredDevices = $devices

                # ===== CATEGORY SELECTION =====
                $categorySelected = $null
                $categories = $filteredDevices |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.$categoryCol) } |
                ForEach-Object { ($_.$categoryCol -split '[,;/]') | ForEach-Object { $_.Trim() } } |
                Sort-Object -Unique

                Write-Host "`nSelect a Category:" -ForegroundColor Cyan
                Write-Host "0. All Categories (exclude blanks)" -ForegroundColor Green
                for ($i = 0; $i -lt $categories.Count; $i++) {
                    Write-Host ("{0}. {1}" -f ($i + 1), $categories[$i]) -ForegroundColor Green
                }

                $catChoice = Read-Host "`nEnter number"

                if ($catChoice -as [int] -and $catChoice -gt 0 -and $catChoice -le $categories.Count) {
                    $categorySelected = $categories[$catChoice - 1]

                    $filteredDevices = $filteredDevices | Where-Object {
                        $catList = ([string]($_.$categoryCol)) -split '[,;/]' | ForEach-Object { $_.Trim().ToLower() }
                        $catList -contains $categorySelected.ToLower()
                    }
                }
                else {
                    # Remove blanks if "All Categories" selected
                    $filteredDevices = $filteredDevices | Where-Object { -not [string]::IsNullOrWhiteSpace($_.$categoryCol) }
                }

                Write-Host "Devices after Category filter: $($filteredDevices.Count)" -ForegroundColor Yellow

                # ===== MANUFACTURER SELECTION =====
                $manufacturerSelected = $null
                $filteredManufacturers = $filteredDevices |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.$manufacturerCol) } |
                Select-Object -ExpandProperty $manufacturerCol -Unique |
                Sort-Object

                Write-Host "`nSelect a Manufacturer:" -ForegroundColor Cyan
                Write-Host "0. All Manufacturers" -ForegroundColor Green
                for ($i = 0; $i -lt $filteredManufacturers.Count; $i++) {
                    Write-Host ("{0}. {1}" -f ($i + 1), $filteredManufacturers[$i]) -ForegroundColor Green
                }

                $mfgChoice = Read-Host "`nEnter number"

                if ($mfgChoice -as [int] -and $mfgChoice -gt 0 -and $mfgChoice -le $filteredManufacturers.Count) {
                    $manufacturerSelected = $filteredManufacturers[$mfgChoice - 1]
                    $filteredDevices = $filteredDevices | Where-Object {
                        ([string]($_.$manufacturerCol)).Trim().ToLower() -eq $manufacturerSelected.ToLower()
                    }
                }

                # ===== MODEL SELECTION =====
                $modelSelected = $null
                $filteredModels = $filteredDevices |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.$modelCol) } |
                Select-Object -ExpandProperty $modelCol -Unique |
                Sort-Object

                Write-Host "`nSelect a Model:" -ForegroundColor Cyan
                Write-Host "0. All Models" -ForegroundColor Green
                for ($i = 0; $i -lt $filteredModels.Count; $i++) {
                    Write-Host ("{0}. {1}" -f ($i + 1), $filteredModels[$i]) -ForegroundColor Green
                }

                $modelChoice = Read-Host "`nEnter number"

                if ($modelChoice -as [int] -and $modelChoice -gt 0 -and $modelChoice -le $filteredModels.Count) {
                    $modelSelected = $filteredModels[$modelChoice - 1]
                    $filteredDevices = $filteredDevices | Where-Object {
                        ([string]($_.$modelCol)).Trim().ToLower() -eq $modelSelected.ToLower()
                    }
                }

                # ===== DISPLAY RESULT =====
                $header = "Devices by Manufacturer & Model"
                if ($categorySelected) { $header += " (Category: $categorySelected)" }
                if ($manufacturerSelected) { $header += " (Manufacturer: $manufacturerSelected)" }
                if ($modelSelected) { $header += " (Model: $modelSelected)" }
                Write-Section $header

                $grouped = $filteredDevices | Where-Object { $_.$manufacturerCol -and $_.$modelCol } | Group-Object -Property $manufacturerCol | Sort-Object Count -Descending
                foreach ($mfg in $grouped) {
                    Write-Host "`n$($mfg.Name)" -ForegroundColor Yellow
                    $rows = $mfg.Group | Group-Object -Property $modelCol | Sort-Object Count -Descending | ForEach-Object {
                        [PSCustomObject]@{ Model = Trunc $_.Name; Count = $_.Count }
                    }
                    Write-Table -Rows $rows
                }

                # ===== EXPORT =====
                Write-Host "`nExport these devices to CSV? (yes / no) [default: no]" -ForegroundColor Cyan
                $exportChoice = Read-Host "Enter choice"
                if ($exportChoice -match '^(?i)y(es)?$') {
                    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    $exportName = "Devices"
                    if ($categorySelected) { $exportName += "_$categorySelected" }
                    if ($manufacturerSelected) { $exportName += "_$manufacturerSelected" }
                    if ($modelSelected) { $exportName += "_$modelSelected" }
                    $outPath = Join-Path $selectedFolder "$exportName`_$timestamp.csv"
                    $filteredDevices | Export-Csv $outPath -NoTypeInformation -Encoding UTF8
                    Write-Host "Exported to $outPath" -ForegroundColor Green
                }
                else {
                    Write-Host "Export skipped." -ForegroundColor DarkGray
                }

                Pause


             }
            4 {
                $tempFolder = "C:\Temp"
[int]$MaxColWidth = 45

#Functions
function Write-Section {
    param([string]$Title)

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Host ("  $Title") -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkGray
    Write-Host ""
}

function Trunc {
    param([string]$Text, [int]$MaxLength = 45)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength - 3) + "..."
}

function Write-Table {
    param([array]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host "(no data)" -ForegroundColor Yellow
        return
    }

    $columns = $Rows[0].PSObject.Properties.Name
    $widths = @{}

    foreach ($col in $columns) {
        $max = ($Rows | ForEach-Object {
                ($_.$col | Out-String).Trim().Length
            } | Measure-Object -Maximum).Maximum

        if ($col.Length -gt $max) { $max = $col.Length }
        if ($max -gt $MaxColWidth) { $max = $MaxColWidth }
        $widths[$col] = $max
    }

    foreach ($col in $columns) {
        Write-Host ($col.PadRight($widths[$col] + 2)) -NoNewline -ForegroundColor Cyan
    }
    Write-Host ""

    foreach ($col in $columns) {
        Write-Host (("-" * $widths[$col]).PadRight($widths[$col] + 2)) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ""

    foreach ($row in $Rows) {
        foreach ($col in $columns) {
            $value = Trunc ($row.$col) $widths[$col]
            Write-Host ($value.PadRight($widths[$col] + 2)) -NoNewline
        }
        Write-Host ""
    }
}

# Export Folders
$exportFolders = Get-ChildItem -Path $tempFolder -Directory -Filter "IntuneDeviceExport_*" |
Sort-Object LastWriteTime -Descending

if (-not $exportFolders) {
    Write-Host "No Intune export folders found." -ForegroundColor Red
    Pause
    return
}

Write-Host "`nSelect an Intune export folder:`n" -ForegroundColor Cyan
$folderOptions = @()

$recent = $exportFolders | Select-Object -First 3
for ($i = 0; $i -lt $recent.Count; $i++) {
    Write-Host "$($i + 1). $($recent[$i].Name)" -ForegroundColor Green
    $folderOptions += $recent[$i].FullName
}

Write-Host "$($folderOptions.Count + 1). Manual Select (Browse Folder)" -ForegroundColor Green
$choice = Read-Host "Enter number"

if ($choice -eq ($folderOptions.Count + 1)) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -ne "OK") { return }
    $selectedFolder = $dlg.SelectedPath
}
else {
    $selectedFolder = $folderOptions[$choice - 1]
}

Write-Host "`nSelected Folder: $selectedFolder" -ForegroundColor Cyan

$csv = Get-ChildItem $selectedFolder -Filter *.csv | Select-Object -First 1
if (-not $csv) {
    Write-Host "No CSV found." -ForegroundColor Red
    return
}

$devices = Import-Csv $csv.FullName

$categoryCol = "Category"
$deviceNameCol = "Device Name"      # Change if your CSV uses a different name
$deviceSerialCol = "Device Serial"  # Change if your CSV uses a different name
$primaryUserCol = "Primary User UPN"    # Column to filter empty users

foreach ($col in @($deviceNameCol, $deviceSerialCol, $primaryUserCol)) {
    if (-not ($devices[0].PSObject.Properties.Name -contains $col)) {
        Write-Host "Missing required column: $col" -ForegroundColor Red
        Pause
        return
    }
}

# ====== CATEGORY FILTER LOGIC ======
$categorySelected = $null
if ($devices[0].PSObject.Properties.Name -contains $categoryCol) {
    $categories = $devices |
        Where-Object { $_.$categoryCol } |
        Select-Object -ExpandProperty $categoryCol -Unique |
        Sort-Object

    if ($categories.Count -gt 1) {
        Write-Host "`nFilter by Category?" -ForegroundColor Cyan
        Write-Host "0. All Categories" -ForegroundColor Green
        for ($i = 0; $i -lt $categories.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), $categories[$i]) -ForegroundColor Green
        }

        $catChoice = Read-Host "`nEnter number"
        if ($catChoice -as [int] -and $catChoice -gt 0 -and $catChoice -le $categories.Count) {
            $categorySelected = $categories[$catChoice - 1]
            $devices = $devices | Where-Object { $_.$categoryCol -eq $categorySelected }
        }
        elseif ($catChoice -eq 0) {
            $categorySelected = $null
        }
        else {
            Write-Host "Invalid selection. Showing all categories." -ForegroundColor Yellow
            $categorySelected = $null
        }
    }
}

# Filter devices missing Primary User
$filteredDevices = $devices | Where-Object { -not $_.$primaryUserCol -or $_.$primaryUserCol.Trim() -eq "" }
$totalCount = $filteredDevices.Count

# Display results
if ($categorySelected) {
    Write-Section "$totalCount Devices Missing Primary User (Category: $categorySelected)"
    Write-Table -Rows ($filteredDevices | Select-Object $deviceNameCol, $deviceSerialCol)
}
elseif ($categories.Count -gt 1 -and $categorySelected -eq $null) {
    $grouped = $filteredDevices | Group-Object -Property $categoryCol
    foreach ($grp in $grouped) {
        Write-Section "$($grp.Count) Devices Missing Primary User (Category: $($grp.Name))"
        Write-Table -Rows ($grp.Group | Select-Object $deviceNameCol, $deviceSerialCol)
    }
}
else {
    Write-Section "$totalCount Devices Missing Primary User"
    Write-Table -Rows ($filteredDevices | Select-Object $deviceNameCol, $deviceSerialCol)
}

# Export logic
Write-Host "`nExport these devices to CSV? (yes / no) [default: no]" -ForegroundColor Cyan
$exportChoice = Read-Host "Enter choice"

if ($exportChoice -match '^(?i)y(es)?$') {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($categorySelected) {
        $outPath = Join-Path $selectedFolder "Devices_Missing_PrimaryUser_$categorySelected`_$timestamp.csv"
    }
    else {
        $outPath = Join-Path $selectedFolder "Devices_Missing_PrimaryUser_$timestamp.csv"
    }
    $filteredDevices | Export-Csv $outPath -NoTypeInformation -Encoding UTF8
    Write-Host "Exported to $outPath" -ForegroundColor Green
}
else {
    Write-Host "Export skipped." -ForegroundColor DarkGray
}

Pause

            }
            5 { return }
        }
    }
    while ($true)
}


# Main Menu
$mainMenuOptions = @(
    "Intune Device Info",
    "Empty 2",
    "Empty 3",
    "Empty 4",
    "Exit"
)

do {
    $choice = Show-Menu `
        -Title "Welcome to the Information Superhighway!" `
        -Options $mainMenuOptions `
        -Footer "Version 1.6" `
        -Breadcrumbs @("Main Menu")

    switch ($choice) {
        1 { IntuneDevices }
        2 { Pause }
        3 { Pause }
        4 { Pause }
        5 { clear
            exit  }
    }
}
while ($true)
