[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
$toolsRoot = Join-Path $workspaceRoot '.tools\esp-idf\v5.5.2'
$idfPath = Join-Path $toolsRoot 'esp-idf'
$idfToolsPath = Join-Path $toolsRoot 'tools'
$python = Join-Path $idfToolsPath 'python\v5.5.2\venv\Scripts\python.exe'
$idfPy = Join-Path $idfPath 'tools\idf.py'
$cmake = Get-ChildItem -LiteralPath (Join-Path $idfToolsPath 'cmake') -Recurse -Filter cmake.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
$ninja = Get-ChildItem -LiteralPath (Join-Path $idfToolsPath 'ninja') -Recurse -Filter ninja.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
$compiler = Get-ChildItem -LiteralPath (Join-Path $idfToolsPath 'xtensa-esp-elf') -Recurse -Filter xtensa-esp32s3-elf-gcc.exe -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName

function Get-FirstOutputLine {
    param(
        [string] $Executable,
        [string[]] $Arguments
    )

    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        return $null
    }

    $output = & $Executable @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return [string]($output | Select-Object -First 1)
}

$env:IDF_PATH = $idfPath
$env:IDF_TOOLS_PATH = $idfToolsPath
$env:IDF_PYTHON_ENV_PATH = Split-Path -Parent (Split-Path -Parent $python)

$checks = @(
    [pscustomobject]@{ Name = 'ESP-IDF'; Required = $true; Path = $idfPath; Version = Get-FirstOutputLine $python @($idfPy, '--version') }
    [pscustomobject]@{ Name = 'Python'; Required = $true; Path = $python; Version = Get-FirstOutputLine $python @('--version') }
    [pscustomobject]@{ Name = 'CMake'; Required = $true; Path = $cmake; Version = Get-FirstOutputLine $cmake @('--version') }
    [pscustomobject]@{ Name = 'Ninja'; Required = $true; Path = $ninja; Version = Get-FirstOutputLine $ninja @('--version') }
    [pscustomobject]@{ Name = 'Xtensa compiler'; Required = $true; Path = $compiler; Version = Get-FirstOutputLine $compiler @('--version') }
    [pscustomobject]@{ Name = 'esptool'; Required = $true; Path = $python; Version = Get-FirstOutputLine $python @('-m', 'esptool', 'version') }
)

$serialPorts = @(
    Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue |
        Select-Object DeviceID, Name, PNPDeviceID
)
$likelyUsbDevices = @(
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'ESP32|Espressif|CH343|CH34|USB.*Serial|CP210|FTDI'
        } |
        Select-Object Name, DeviceID, Status
)

Write-Host ''
Write-Host 'DMDClock ESP32-S3 toolchain'
Write-Host '---------------------------'
foreach ($check in $checks) {
    $ok = [bool]$check.Version
    $marker = if ($ok) { '[OK]' } else { '[MISSING]' }
    Write-Host ("{0,-10} {1}: {2}" -f $marker, $check.Name, ($check.Version ?? $check.Path))
}

Write-Host ''
if ($serialPorts.Count -eq 0) {
    Write-Warning 'No serial ports are connected. This is expected until the board arrives.'
} else {
    Write-Host 'Serial ports:'
    $serialPorts | Format-Table -AutoSize
}

if ($likelyUsbDevices.Count -gt 0) {
    Write-Host 'Relevant USB devices:'
    $likelyUsbDevices | Format-Table -AutoSize
}

$reportDirectory = Join-Path $repoRoot 'output\esp32\reports'
New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
$report = [ordered]@{
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    machine = $env:COMPUTERNAME
    idfVersion = 'v5.5.2'
    idfCommit = '30aaf64524299d3bde422ca9a2848090d1bc5d0f'
    tools = $checks
    serialPorts = $serialPorts
    relevantUsbDevices = $likelyUsbDevices
}
$reportPath = Join-Path $reportDirectory 'toolchain.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Host "Report: $reportPath"

$missing = @($checks | Where-Object { $_.Required -and -not $_.Version })
if ($missing.Count -gt 0) {
    throw "Toolchain check failed: $($missing.Name -join ', ')"
}

Write-Host '[READY] Local compilation is available. Hardware detection remains pending.'
