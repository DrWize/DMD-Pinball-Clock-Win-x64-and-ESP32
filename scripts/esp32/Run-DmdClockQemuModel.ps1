# Runs the ESP32 QEMU simulation for a selected board model (resolution).
#
# Example:
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model Waveshare7
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model '640x172' -SkipBuild
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model '800x480' -NoRun
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -ScenesFolder ..\..\scenes
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -SdImage dmdclock-qemu-sd.img
#   .\scripts\esp32\Run-DmdClockQemuModel.ps1 -Model Waveshare7 -WebPort 8090
#
# Without -Model the script shows an interactive choice. Each model has its own
# QEMU build directory, so switching models never rebuilds the other one.
#
# Passing -ScenesFolder mirrors that folder into /dmd/scenes on a FAT32 image
# (via New-DmdClockQemuSdImage.ps1) that QEMU attaches as the SD card, so the
# simulated clock indexes the real scenes instead of the embedded fallback set.
# -SdImage attaches an existing image directly.

[CmdletBinding()]
param(
    [string] $Model,
    [switch] $SkipBuild,
    [switch] $NoRun,
    [int] $WebPort,
    [int] $MonitorPort,
    [string] $ScenesFolder,
    [string] $SdImage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
while ($workspaceRoot -and
    -not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.tools') -PathType Container)) {
    $parent = Split-Path -Parent $workspaceRoot
    if ($parent -eq $workspaceRoot) { break }
    $workspaceRoot = $parent
}
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

$models = @{
    Waveshare7 = @{
        SdkConfig = 'sdkconfig.qemu-waveshare'
        BuildDir  = 'build-qemu-waveshare'
        Label     = '800x480 (DMD 6x)'
        WebPort   = 8080
        MonitorPort = 4444
        SdImage   = 'dmdclock-qemu-sd-waveshare7.img'
    }
    Landscape349 = @{
        SdkConfig = 'sdkconfig.qemu-esp32'
        BuildDir  = 'build-qemu-esp32'
        Label     = '640x172 (DMD 5x)'
        WebPort   = 8081
        MonitorPort = 4445
        SdImage   = 'dmdclock-qemu-sd-landscape349.img'
    }
}

function Resolve-ModelChoice {
    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        switch ($Model.Trim().ToLower()) {
            'waveshare7'   { return 'Waveshare7' }
            'waveshare'    { return 'Waveshare7' }
            '800x480'      { return 'Waveshare7' }
            'landscape349' { return 'Landscape349' }
            'landscape'    { return 'Landscape349' }
            '640x172'      { return 'Landscape349' }
            default {
                throw "Unknown -Model '$Model'. Use Waveshare7, Landscape349, '800x480', or '640x172'."
            }
        }
    }

    Write-Host ''
    Write-Host 'Select a board model for offline QEMU testing:'
    Write-Host '  1) Waveshare ESP32-S3-Touch-LCD-7 (800x480, DMD 6x)'
    Write-Host '  2) 3.49-inch IPS board            (640x172, DMD 5x)'
    $response = Read-Host 'Choice (1 or 2)'
    switch ($response) {
        '1' { return 'Waveshare7' }
        '2' { return 'Landscape349' }
        default { throw "Invalid choice '$response'. Expected 1 or 2." }
    }
}

$choice = Resolve-ModelChoice
$board = $models[$choice]
$sdkconfigArg = "-DSDKCONFIG=$($board['SdkConfig'])"
if ($WebPort -eq 0) {
    $WebPort = $board['WebPort']
}
if ($MonitorPort -eq 0) {
    $MonitorPort = $board['MonitorPort']
}
if ($WebPort -lt 1 -or $WebPort -gt 65535) {
    throw "Invalid -WebPort $WebPort. Expected a value from 1 through 65535."
}
if ($MonitorPort -lt 1 -or $MonitorPort -gt 65535) {
    throw "Invalid -MonitorPort $MonitorPort. Expected a value from 1 through 65535."
}

$sdDriveArg = ''
$defaultImagePath = Join-Path $projectPath $board['SdImage']
if (-not [string]::IsNullOrWhiteSpace($ScenesFolder) -or
    -not [string]::IsNullOrWhiteSpace($SdImage) -or
    (Test-Path -LiteralPath $defaultImagePath -PathType Leaf)) {
    $imagePath = if (-not [string]::IsNullOrWhiteSpace($ScenesFolder)) {
        if (-not [string]::IsNullOrWhiteSpace($SdImage)) { $SdImage }
        else { $defaultImagePath }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SdImage)) {
        $SdImage
    }
    else {
        $defaultImagePath
    }
    if (-not [string]::IsNullOrWhiteSpace($ScenesFolder)) {
        & (Join-Path $PSScriptRoot 'New-DmdClockQemuSdImage.ps1') `
            -ScenesFolder $ScenesFolder `
            -OutputPath $imagePath
    }
    if (-not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "SD image not found: $imagePath"
    }
    $imagePath = (Resolve-Path -LiteralPath $imagePath).Path
    $driveValue = $imagePath -replace '\\', '/'
    $sdDriveArg = "-drive file=`"$driveValue`",if=sd,format=raw"
    Write-Host "Attaching SD card image: $imagePath"
}
if (-not $SkipBuild) {
    Write-Host "Building the QEMU profile for: $($board['Label'])"
    & (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
        -ProjectPath $projectPath `
        '-B' $board['BuildDir'] `
        '-DIDF_TARGET=esp32' `
        $sdkconfigArg `
        '-DSDKCONFIG_DEFAULTS=sdkconfig.qemu.defaults' `
        '-DDMD_BOOTSTRAP_WIFI_HEADER=OFF' `
        build

    $binary = Join-Path $projectPath "$($board['BuildDir'])\dmdclock_esp32.bin"
    if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
        throw "ESP-IDF returned without producing '$binary'."
    }
    Write-Host "QEMU firmware: $binary"
}

if ($NoRun) {
    Write-Host "Build finished for $($board['Label']). Not starting QEMU (-NoRun)."
    return
}

$env:PATH = "$qemuBin;$msysBin;$env:PATH"

Write-Host ''
Write-Host "Starting the ESP32 simulation profile: $($board['Label'])"
Write-Host "Web remote: http://localhost:$WebPort/"
Write-Host "QEMU HMP monitor: tcp:127.0.0.1:$MonitorPort (screendump via monitor)"
Write-Host 'Exit: close the QEMU display window or press Ctrl+C in this terminal.'

$qemuArgs = "-nic user,model=open_eth,hostfwd=tcp::$WebPort-:80 -monitor tcp:127.0.0.1:$MonitorPort,server,nowait"
if ($sdDriveArg) {
    $qemuArgs += " $sdDriveArg"
}

& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
    -ProjectPath $projectPath `
    '-B' $board['BuildDir'] `
    '-DIDF_TARGET=esp32' `
    $sdkconfigArg `
    '-DSDKCONFIG_DEFAULTS=sdkconfig.qemu.defaults' `
    qemu `
    --graphics `
    --qemu-extra-args `
    $qemuArgs
