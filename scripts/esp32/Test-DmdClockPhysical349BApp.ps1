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

    [ValidateRange(1, 60)]
    [int] $DurationMinutes = 10,

    [switch] $SkipBuild,

    [switch] $Force,

    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$projectPath = Join-Path $repoRoot 'firmware\dmdclock-esp32'
$buildPath = Join-Path $projectPath 'build-hw-349b'
$reportRoot = Join-Path $repoRoot 'output\esp32\reports\physical-349b-app'
$invokeIdf = Join-Path $PSScriptRoot 'Invoke-Idf.ps1'
$buildScript = Join-Path $PSScriptRoot 'Build-DmdClock.ps1'

if ($ConfirmHardware -ine '3.49B') {
    throw "Hardware confirmation must be exactly '3.49B'."
}
if ($BoardRevision -ne 'V2') {
    throw 'This smoke test supports only the 3.49B V2 / Rev1.1 hardware contract.'
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
    & $buildScript -Board Waveshare349B
}

$generatedConfig = Join-Path $buildPath 'config\sdkconfig.h'
$configText = Get-Content -LiteralPath $generatedConfig -Raw
$expectedConfig = @(
    '#define CONFIG_DMD_BOARD_3_49_LANDSCAPE 1',
    '#define CONFIG_DMD_DISPLAY_WIDTH 640',
    '#define CONFIG_DMD_DISPLAY_HEIGHT 172',
    '#define CONFIG_DMD_DMD_SCALE 5'
)
foreach ($line in $expectedConfig) {
    if (-not $configText.Contains($line)) {
        throw "3.49B build configuration mismatch; missing '$line'."
    }
}

$flashFiles = @(
    [pscustomobject]@{ Offset = '0x0'; Path = Join-Path $buildPath 'bootloader\bootloader.bin' }
    [pscustomobject]@{ Offset = '0x8000'; Path = Join-Path $buildPath 'partition_table\partition-table.bin' }
    [pscustomobject]@{ Offset = '0x10000'; Path = Join-Path $buildPath 'dmdclock_esp32.bin' }
)
foreach ($file in $flashFiles) {
    if (-not (Test-Path -LiteralPath $file.Path -PathType Leaf)) {
        throw "3.49B build artifact is missing: $($file.Path)"
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
Write-Host 'Physical DMDClock 3.49B V2 smoke-test summary:'
Write-Host "  Port:       $Port" -ForegroundColor Cyan
Write-Host '  Board:      Waveshare ESP32-S3-Touch-LCD-3.49B V2 / Rev1.1'
Write-Host '  Display:    640x172 landscape'
Write-Host "  Monitor:    $DurationMinutes minute(s)"
Write-Warning 'This writes the local P7 development image with physically qualified touch enabled.'
foreach ($file in $flashFiles) {
    Write-Host ("  {0,-7} {1} ({2} bytes, SHA-256 {3})" -f `
        $file.Offset, [IO.Path]::GetFileName($file.Path), $file.Size, $file.Sha256)
}

if ($WhatIf) {
    Write-Host ''
    Write-Host '[WHATIF] Configuration, artifacts, hashes, and hardware checks passed; flash was skipped.' `
        -ForegroundColor Yellow
    return
}

if (-not $Force) {
    $confirmation = Read-Host 'Type FLASH to write DMDClock for Waveshare 3.49B V2'
    if ($confirmation -ine 'FLASH') {
        Write-Host 'Test cancelled; nothing was written.' -ForegroundColor Yellow
        return
    }
}

& $invokeIdf -ProjectPath $projectPath `
    -IdfArguments @('-B', 'build-hw-349b', '-p', $Port, 'flash')

New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$logPath = Join-Path $reportRoot "dmdclock349-v2-$timestamp.log"
$reportPath = Join-Path $reportRoot "dmdclock349-v2-$timestamp.json"
$serial = [IO.Ports.SerialPort]::new($Port, 115200, 'None', 8, 'One')
$serial.ReadTimeout = 250
$serial.DtrEnable = $false
$serial.RtsEnable = $false
$text = [Text.StringBuilder]::new()
$timer = [Diagnostics.Stopwatch]::StartNew()
try {
    $serial.Open()
    Write-Host ''
    Write-Host "Monitoring DMDClock for $DurationMinutes minute(s). Press Ctrl+C to abort." -ForegroundColor Cyan
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
$requiredMarkers = [ordered]@{
    scenes = '\d+ scenes validated'
    panel = 'Initializing Waveshare 3\.49B V2 panel as 640x172'
    touch = 'DMDClock ready: touch=available'
    ready = 'DMDClock ready: touch=(?:available|unavailable)'
}
$observedMarkers = @(
    foreach ($entry in $requiredMarkers.GetEnumerator()) {
        if ($serialText -match $entry.Value) { $entry.Key }
    }
)
$fatalPattern =
    '(?i)Guru Meditation|assert failed|abort\(\)|rst:0x[3-9a-f]|ESP_ERROR_CHECK failed|' +
    'Task watchdog got triggered|rename retry failed|fwrite/fflush/fclose failed'
$fatalDetected = $serialText -match $fatalPattern
$serialPassed = $observedMarkers.Count -eq $requiredMarkers.Count -and -not $fatalDetected

$report = [ordered]@{
    schemaVersion = 1
    startedAtUtc = [DateTime]::UtcNow.Subtract($timer.Elapsed).ToString('o')
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    board = 'Waveshare ESP32-S3-Touch-LCD-3.49B'
    revision = 'V2'
    port = $Port
    durationMinutes = $timer.Elapsed.TotalMinutes
    expectedGeometry = [ordered]@{ width = 640; height = 172; orientation = 'landscape' }
    requiredMarkers = @($requiredMarkers.Keys)
    observedMarkers = $observedMarkers
    fatalDetected = $fatalDetected
    serialPassed = $serialPassed
    physicalTouchEnabled = $true
    visualVerificationRequired = $true
    visualChecklist = @(
        'The 128x32 test pattern occupies exactly 640x160 at x=0 with 6 pixels above and below.'
        'The clock, a static scene, and an animated scene render in the correct orientation.'
        'Basic, Gradient, Raster, and Plasma modes render with correct colors.'
        'Colors are correct and the image has no tearing or corruption.'
        'Representative physical scenes match the Landscape349 QEMU captures.'
        'The guided five-point touch test registers all targets at the intended positions.'
        'Every visible touch-menu control activates its intended action exactly once.'
    )
    images = @($flashFiles | ForEach-Object {
        [ordered]@{ offset = $_.Offset; path = $_.Path; size = $_.Size; sha256 = $_.Sha256 }
    })
    serialLog = $logPath
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath

if (-not $serialPassed) {
    throw "Physical DMDClock 3.49B smoke test failed. Evidence: $reportPath"
}

Write-Host ''
Write-Host '[PASS] DMDClock reached ready state on the physical 3.49B without a detected crash.' `
    -ForegroundColor Green
Write-Host 'Display orientation, colors, tearing, and scene playback still require observation.' `
    -ForegroundColor Yellow
Write-Host "Evidence: $reportPath"
