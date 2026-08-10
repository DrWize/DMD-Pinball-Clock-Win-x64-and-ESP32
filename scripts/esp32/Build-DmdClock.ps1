[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [string] $BuildDir = 'build-hw-esp32'
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

$resolvedVersion = $Version
if (-not $resolvedVersion) {
    $resolvedVersion = (& git -C $repoRoot describe --tags --always --dirty).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedVersion)) {
        throw 'Unable to determine the local firmware version from Git.'
    }
}
if ([Text.Encoding]::UTF8.GetByteCount($resolvedVersion) -gt 31) {
    throw "Firmware version '$resolvedVersion' exceeds the ESP-IDF 31-byte limit."
}

Write-Host "Bootstrap Wi-Fi injection: $bootstrapOption"
Write-Host "Firmware version: $resolvedVersion"
Write-Host "Build directory: $BuildDir"
& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    "-B" $BuildDir `
    "-DDMD_BOOTSTRAP_WIFI_HEADER=$bootstrapOption" `
    "-DPROJECT_VER=$resolvedVersion" `
    build

$binary = Join-Path $projectPath "$BuildDir\dmdclock_esp32.bin"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "ESP-IDF returned without producing '$binary'."
}

Write-Host "Firmware: $binary"
