[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [Parameter(Mandatory)]
    [ValidateSet('V2')]
    [string] $BoardRevision,

    [Parameter(Mandatory)]
    [string] $ConfirmHardware,

    [ValidateRange(1, 1440)]
    [int] $DurationMinutes = 60,

    [switch] $SkipBuild,

    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\diagnostics\waveshare349b-v2-panel-test'
$buildPath = Join-Path $projectPath 'build'
$reportRoot = Join-Path $repoRoot 'output\esp32\reports\physical-349b'
$invokeIdf = Join-Path $PSScriptRoot 'Invoke-Idf.ps1'

if ($ConfirmHardware -ine '3.49B') {
    throw "Hardware confirmation must be exactly '3.49B'."
}
if ($BoardRevision -ne 'V2') {
    throw 'This diagnostic supports only the 3.49B V2 / Rev1.1 hardware contract.'
}

$workspaceRoot = Split-Path -Parent $repoRoot
while ($workspaceRoot -and
    -not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.tools') -PathType Container)) {
    $parent = Split-Path -Parent $workspaceRoot
    if ($parent -eq $workspaceRoot) { break }
    $workspaceRoot = $parent
}
$idfToolsRoot = Join-Path $workspaceRoot '.tools\esp-idf\v5.5.2\tools'
$python = Join-Path $idfToolsRoot 'python\v5.5.2\venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Pinned ESP-IDF Python environment was not found at '$python'."
}

if (-not $SkipBuild) {
    & $invokeIdf -ProjectPath $projectPath -IdfArguments @('-B', 'build', 'build')
}

$flashFiles = @(
    [pscustomobject]@{ Offset = '0x0'; Path = Join-Path $buildPath 'bootloader\bootloader.bin' }
    [pscustomobject]@{ Offset = '0x8000'; Path = Join-Path $buildPath 'partition_table\partition-table.bin' }
    [pscustomobject]@{ Offset = '0x10000'; Path = Join-Path $buildPath 'waveshare349b_v2_panel_test.bin' }
)
foreach ($file in $flashFiles) {
    if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) {
        throw "Diagnostic build artifact is missing: $($file.Path)"
    }
    $file | Add-Member -NotePropertyName Size -NotePropertyValue (Get-Item -LiteralPath $file.Path).Length
    $file | Add-Member -NotePropertyName Sha256 -NotePropertyValue (
        (Get-FileHash -LiteralPath $file.Path -Algorithm SHA256).Hash)
}

Write-Host "Checking the ESP32-S3 on $Port..."
$chipOutput = @(& $python -m esptool --chip esp32s3 --port $Port chip_id 2>&1)
if ($LASTEXITCODE -ne 0 -or ($chipOutput | Out-String) -notmatch 'ESP32-S3') {
    $chipOutput | Write-Host
    throw "No ESP32-S3 responded on $Port."
}
$flashOutput = @(& $python -m esptool --chip esp32s3 --port $Port flash_id 2>&1)
if ($LASTEXITCODE -ne 0 -or
    ($flashOutput | Out-String) -notmatch '(?i)(Detected flash size:\s*16MB|flash size.*16\s*MB)') {
    $flashOutput | Write-Host
    throw 'The connected board did not report 16 MB flash.'
}
if (($chipOutput | Out-String) -notmatch '(?i)Embedded PSRAM 8MB') {
    throw 'The connected board did not report the required embedded 8 MB PSRAM.'
}

Write-Host ''
Write-Host 'Physical 3.49B V2 panel-test summary:'
Write-Host "  Port:       $Port" -ForegroundColor Cyan
Write-Host '  Board:      Waveshare ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1'
Write-Host '  Display:    640x172 landscape'
Write-Host "  Duration:   $DurationMinutes minute(s)"
Write-Warning 'This diagnostic replaces internal flash and settings. Restore the verified V2 factory image afterward if needed.'
Write-Host '  TF card:    untouched' -ForegroundColor Green
foreach ($file in $flashFiles) {
    Write-Host ("  {0,-7} {1} ({2} bytes, SHA-256 {3})" -f `
        $file.Offset, [IO.Path]::GetFileName($file.Path), $file.Size, $file.Sha256)
}

if ($WhatIf) {
    Write-Host ''
    Write-Host '[WHATIF] Build, artifacts, hashes, and hardware checks passed; flash and monitor were skipped.' `
        -ForegroundColor Yellow
    return
}

$confirmation = Read-Host 'Type FLASH to write the standalone panel diagnostic'
if ($confirmation -ine 'FLASH') {
    Write-Host 'Test cancelled; nothing was written.' -ForegroundColor Yellow
    return
}

& $invokeIdf -ProjectPath $projectPath -IdfArguments @('-B', 'build', '-p', $Port, 'flash')

New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$logPath = Join-Path $reportRoot "panel349-v2-$timestamp.log"
$reportPath = Join-Path $reportRoot "panel349-v2-$timestamp.json"
$serial = [IO.Ports.SerialPort]::new($Port, 115200, 'None', 8, 'One')
$serial.ReadTimeout = 250
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$text = [Text.StringBuilder]::new()
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    $serial.Open()
    Write-Host ''
    Write-Host "Monitoring serial output for $DurationMinutes minute(s). Press Ctrl+C to abort." -ForegroundColor Cyan
    while ($timer.Elapsed.TotalMinutes -lt $DurationMinutes) {
        $chunk = $serial.ReadExisting()
        if (-not [string]::IsNullOrEmpty($chunk)) {
            $null = $text.Append($chunk)
            Write-Host $chunk -NoNewline
        }
        Start-Sleep -Milliseconds 100
    }
}
finally {
    if ($serial.IsOpen) { $serial.Close() }
    $serial.Dispose()
    [IO.File]::WriteAllText($logPath, $text.ToString())
}

$serialText = $text.ToString()
$requiredStages = @('red', 'green', 'blue', 'black', 'white', 'grid')
$observedStages = @(
    foreach ($stage in $requiredStages) {
        if ($serialText -match "PANEL_TEST stage=$stage\b") { $stage }
    }
)
$cycleMatches = [regex]::Matches($serialText, 'PANEL_TEST heartbeat cycle=(\d+)')
$lastCycle = if ($cycleMatches.Count -gt 0) {
    [int]$cycleMatches[$cycleMatches.Count - 1].Groups[1].Value
} else {
    0
}
$fatalPattern = '(?i)Guru Meditation|assert failed|abort\(\)|PANEL_TEST failure=|rst:0x[3-9a-f]'
$fatalDetected = $serialText -match $fatalPattern
$serialPassed = $observedStages.Count -eq $requiredStages.Count -and
    $lastCycle -ge 1 -and
    -not $fatalDetected

$report = [ordered]@{
    schemaVersion = 1
    startedAtUtc = [DateTime]::UtcNow.Subtract($timer.Elapsed).ToString('o')
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    board = 'Waveshare ESP32-S3-Touch-LCD-3.49B'
    revision = 'V2'
    port = $Port
    durationMinutes = $timer.Elapsed.TotalMinutes
    expectedGeometry = [ordered]@{ width = 640; height = 172; orientation = 'landscape' }
    requiredStages = $requiredStages
    observedStages = $observedStages
    lastCompletedCycle = $lastCycle
    fatalDetected = $fatalDetected
    serialPassed = $serialPassed
    visualVerificationRequired = $true
    visualChecklist = @(
        'Solid red, green, blue, black, and white frames have correct colors.'
        'Grid is landscape with no tearing or corruption.'
        'Grid corners are red top-left, green top-right, blue bottom-left, white bottom-right.'
        'Yellow border, cyan 64x32 grid, and magenta center lines are visible.'
    )
    images = @($flashFiles | ForEach-Object {
        [ordered]@{ offset = $_.Offset; path = $_.Path; size = $_.Size; sha256 = $_.Sha256 }
    })
    serialLog = $logPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath

if (-not $serialPassed) {
    throw "Physical panel serial test failed. Evidence: $reportPath"
}

Write-Host ''
Write-Host '[PASS] All panel stages completed without a detected crash.' -ForegroundColor Green
Write-Host 'Visual orientation, color order, tearing, and corruption still require observation.' -ForegroundColor Yellow
Write-Host "Evidence: $reportPath"
