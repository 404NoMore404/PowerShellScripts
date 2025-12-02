#Created 12.2.2025
#Hex Timestamp Decoder
#Use: Used for reviewing hex timestamps within intune diagnostic logs.

function Convert-HexTimestamp($hexString) {
    try {
        # Remove "hex(b):" prefix and all non-hex characters
        $hexBytes = $hexString -replace "hex\(b\):","" -replace "[^0-9a-fA-F]", ""

        # Convert every two hex characters to a byte
        $bytes = @()
        for ($i = 0; $i -lt $hexBytes.Length; $i += 2) {
            $bytes += [Convert]::ToByte($hexBytes.Substring($i,2),16)
        }

        if ($bytes.Length -ge 8) {
            $fileTime = [BitConverter]::ToInt64($bytes,0)
            return [DateTime]::FromFileTimeUtc($fileTime)
        } else {
            return "Invalid hex timestamp"
        }
    }
    catch {
        return "Error decoding"
    }
}

Write-Host "Hex Timestamp Decoder"
Write-Host "Type 'exit' at any time to quit.`n"

while ($true) {
    $hexString = Read-Host "Enter hex(b) timestamp"

    if ($hexString.ToLower() -eq "exit") {
        Write-Host "Exiting decoder..." -ForegroundColor Yellow
        break
    }

    $result = Convert-HexTimestamp $hexString
    Write-Host "Decoded timestamp: $result" -ForegroundColor Green
    Write-Host ""
}
