[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [ValidateSet('Waveshare7', 'Waveshare349B')]
    [string] $Board = 'Waveshare7',

    [string] $BuildDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'
$BuildDir = if ($BuildDir) {
    $BuildDir
} elseif ($Board -eq 'Waveshare349B') {
    'build-hw-349b'
} else {
    'build-hw-esp32'
}
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
Write-Host "Board: $Board"
Write-Host "Build directory: $BuildDir"
$idfArguments = @('-B', $BuildDir)
if ($Board -eq 'Waveshare349B') {
    $buildPath = [IO.Path]::GetFullPath((Join-Path $projectPath $BuildDir))
    $sdkconfigPath = (Join-Path $buildPath 'sdkconfig').Replace('\', '/')
    $defaultConfig = (Join-Path $projectPath 'sdkconfig.defaults').Replace('\', '/')
    $boardConfig = (Join-Path $projectPath 'sdkconfig.waveshare349b.defaults').Replace('\', '/')
    $idfArguments += "-DSDKCONFIG=$sdkconfigPath"
    $idfArguments += "-DSDKCONFIG_DEFAULTS=$defaultConfig;$boardConfig"
}
$idfArguments += "-DDMD_BOOTSTRAP_WIFI_HEADER=$bootstrapOption"
$idfArguments += "-DPROJECT_VER=$resolvedVersion"
$idfArguments += 'build'
& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    -IdfArguments $idfArguments

$generatedConfig = Join-Path $projectPath "$BuildDir\config\sdkconfig.h"
if (-not (Test-Path -LiteralPath $generatedConfig -PathType Leaf)) {
    throw "ESP-IDF did not produce '$generatedConfig'."
}
$configText = Get-Content -LiteralPath $generatedConfig -Raw
$expected = if ($Board -eq 'Waveshare349B') {
    @(
        '#define CONFIG_DMD_BOARD_3_49_LANDSCAPE 1',
        '#define CONFIG_DMD_DISPLAY_WIDTH 640',
        '#define CONFIG_DMD_DISPLAY_HEIGHT 172',
        '#define CONFIG_DMD_DMD_SCALE 5'
    )
} else {
    @(
        '#define CONFIG_DMD_BOARD_WAVESHARE_7 1',
        '#define CONFIG_DMD_DISPLAY_WIDTH 800',
        '#define CONFIG_DMD_DISPLAY_HEIGHT 480',
        '#define CONFIG_DMD_DMD_SCALE 6'
    )
}
foreach ($line in $expected) {
    if (-not $configText.Contains($line)) {
        throw "Build configuration mismatch for $Board; missing '$line'."
    }
}
Write-Host "Board configuration verified: $Board" -ForegroundColor Green

$binary = Join-Path $projectPath "$BuildDir\dmdclock_esp32.bin"
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "ESP-IDF returned without producing '$binary'."
}

Write-Host "Firmware: $binary"
