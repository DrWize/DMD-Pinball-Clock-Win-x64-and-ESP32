[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'

& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    '-B' 'build-qemu-esp32' `
    '-DIDF_TARGET=esp32' `
    '-DSDKCONFIG=sdkconfig.qemu-esp32' `
    '-DSDKCONFIG_DEFAULTS=sdkconfig.qemu.defaults' `
    '-DDMD_BOOTSTRAP_WIFI_HEADER=OFF' `
    build

$binary = Join-Path $projectPath 'build-qemu-esp32\dmdclock_esp32.bin'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "ESP-IDF returned without producing '$binary'."
}

Write-Host "QEMU firmware: $binary"
