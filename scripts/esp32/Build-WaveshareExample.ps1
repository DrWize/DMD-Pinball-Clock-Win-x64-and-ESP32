[CmdletBinding()]
param(
    [ValidateSet('I2C', 'RS485', 'SD', 'Sensor', 'UART', 'TWAITransmit', 'TWAIReceive', 'LVGL')]
    [string] $Example = 'LVGL'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$exampleRoot = Join-Path $repoRoot 'external\waveshare-esp32-s3-touch-lcd-7\package\ESP32-S3-Touch-LCD-7-Demo\ESP-IDF'
$folders = @{
    I2C          = '01_I2C_Test'
    RS485        = '02_RS485_Test'
    SD           = '03_SD_Test'
    Sensor       = '04_Sensor_AD'
    UART         = '05_UART_Test'
    TWAITransmit = '06_TWAItransmit'
    TWAIReceive  = '07_TWAIreceive'
    LVGL         = '08_lvgl_Porting'
}

$projectPath = Join-Path $exampleRoot $folders[$Example]
if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
    throw "The cached Waveshare example was not found at '$projectPath'."
}

& (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') -ProjectPath $projectPath build
