param(
    [Parameter(Mandatory)]
    [string]$LogPath,

    [ValidateSet('Info','Warning','Error')]
    [string]$Severity,

    [string]$Component,

    [string]$AppId,

    [string[]]$Keyword
)

if (-not (Test-Path $LogPath)) {
    throw "Log file not found: $LogPath"
}

$severityMap = @{
    '1' = 'Info'
    '2' = 'Warning'
    '3' = 'Error'
}

# IME log regex
$logRegex = '<!\[LOG\[(?<Message>.*?)\]LOG\]\!><time="(?<Time>[^"]+)" date="(?<Date>[^"]+)" component="(?<Component>[^"]*)" context="(?<Context>[^"]*)" type="(?<Type>\d)" thread="(?<Thread>\d+)" file="(?<File>[^"]*)"'

# GUID (App ID) regex
$appIdRegex = '(?<AppId>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'

$results = foreach ($chunk in Get-Content -Path $LogPath -ReadCount 500) {
    foreach ($line in $chunk) {
        if ($line -match $logRegex) {

            $appIdFound = $null
            if ($Matches.Message -match $appIdRegex) {
                $appIdFound = $Matches.AppId
            }

            [PSCustomObject]@{
                Timestamp = [datetime]"$($Matches.Date) $($Matches.Time)"
                Severity  = $severityMap[$Matches.Type]
                Component = $Matches.Component
                Message   = $Matches.Message
                AppId     = $appIdFound
                Thread    = $Matches.Thread
                File      = $Matches.File
                RawLine   = $line
            }
        }
    }
}

# =========================
# Filters
# =========================

if ($Severity) {
    $results = $results | Where-Object Severity -eq $Severity
}

if ($Component) {
    $results = $results | Where-Object Component -eq $Component
}

if ($AppId) {
    $results = $results | Where-Object AppId -eq $AppId
}

if ($Keyword) {
    foreach ($word in $Keyword) {
        $results = $results | Where-Object {
            $_.Message -match [regex]::Escape($word)
        }
    }
}

$results
