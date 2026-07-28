[CmdletBinding()]
param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'
$qemuVersion = 'esp_develop_9.2.2_20250817'
$qemuBin = Join-Path $workspaceRoot ".tools\esp-idf\v5.5.2\tools\qemu-xtensa\$qemuVersion\qemu\bin"
$qemuExe = Join-Path $qemuBin 'qemu-system-xtensa.exe'
$msysBin = 'C:\msys64\mingw64\bin'
$iconv = Join-Path $msysBin 'libiconv-2.dll'

if (-not (Test-Path -LiteralPath $qemuExe -PathType Leaf)) {
    throw "Espressif QEMU was not found at '$qemuExe'."
}

if (-not (Test-Path -LiteralPath $iconv -PathType Leaf)) {
    throw "QEMU requires '$iconv'. Install the 64-bit MSYS2 libiconv runtime first."
}

$env:PATH = "$qemuBin;$msysBin;$env:PATH"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-DmdClockQemu.ps1')
}

Write-Host 'Starting the ESP32 simulation profile.'
Write-Host 'Web remote: http://localhost:8080/'
Write-Host 'Exit: close the QEMU display window or press Ctrl+] in the monitor.'

& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    '-B' 'build-qemu-esp32' `
    '-DIDF_TARGET=esp32' `
    '-DSDKCONFIG=sdkconfig.qemu-esp32' `
    '-DSDKCONFIG_DEFAULTS=sdkconfig.qemu.defaults' `
    qemu `
    --graphics `
    --qemu-extra-args `
    '-nic user,model=open_eth,hostfwd=tcp::8080-:80' `
    monitor
