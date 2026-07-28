[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [switch] $Monitor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$connectedPorts = @(Get-CimInstance Win32_SerialPort | Select-Object -ExpandProperty DeviceID)
if ($Port -notin $connectedPorts) {
    $available = if ($connectedPorts.Count -gt 0) {
        $connectedPorts -join ', '
    } else {
        'none'
    }
    throw "Serial port '$Port' is not connected. Available ports: $available."
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'
$binary = Join-Path $projectPath 'build\dmdclock_esp32.bin'
if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) {
    throw "Build the firmware before flashing: .\scripts\esp32\Build-DmdClock.ps1"
}

Write-Host "Target: Waveshare ESP32-S3-Touch-LCD-7 (800x480, N16R8)"
Write-Host "Port:   $Port"
Write-Host "Binary: $binary"

$arguments = @('-p', $Port, 'flash')
if ($Monitor) {
    $arguments += 'monitor'
}

& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') -ProjectPath $projectPath @arguments
