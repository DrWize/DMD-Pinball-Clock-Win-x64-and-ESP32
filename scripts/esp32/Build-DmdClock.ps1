[CmdletBinding()]
param()

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

Write-Host "Bootstrap Wi-Fi injection: $bootstrapOption"
& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    "-DDMD_BOOTSTRAP_WIFI_HEADER=$bootstrapOption" `
    build

$binary = Join-Path $projectPath 'build\dmdclock_esp32.bin'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "ESP-IDF returned without producing '$binary'."
}

Write-Host "Firmware: $binary"
