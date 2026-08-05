[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'
$bootstrapHeader = Join-Path $projectPath 'main\dmd_bootstrap_wifi.h'
$bootstrapOption = if (Test-Path -LiteralPath $bootstrapHeader -PathType Leaf) {
    'ON'
} else {
    'OFF'
}

if (-not $Version) {
    $Version = (& git -C $repoRoot describe --tags --always --dirty).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Version)) {
        throw 'Unable to determine the local firmware version from Git.'
    }
}
if ([Text.Encoding]::UTF8.GetByteCount($Version) -gt 31) {
    throw "Firmware version '$Version' exceeds the ESP-IDF 31-byte limit."
}

Write-Host "Bootstrap Wi-Fi injection: $bootstrapOption"
Write-Host "Firmware version: $Version"
& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    "-DDMD_BOOTSTRAP_WIFI_HEADER=$bootstrapOption" `
    "-DPROJECT_VER=$Version" `
    build

$binary = Join-Path $projectPath 'build\dmdclock_esp32.bin'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "ESP-IDF returned without producing '$binary'."
}

Write-Host "Firmware: $binary"
