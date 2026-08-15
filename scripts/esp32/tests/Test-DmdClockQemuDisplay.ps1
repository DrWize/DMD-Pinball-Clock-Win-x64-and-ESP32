# Validates a running DMDClock QEMU display and records reproducible evidence.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Waveshare7', 'Landscape349')]
    [string] $Model,

    [Parameter(Mandatory)]
    [uri] $QemuUrl,

    [Parameter(Mandatory)]
    [ValidateRange(1, 65535)]
    [int] $MonitorPort,

    [string] $OutputDirectory,

    [ValidateRange(5, 300)]
    [int] $TimeoutSeconds = 60,

    [switch] $AllowBlank
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'output\esp32\reports\qemu-display'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$models = @{
    Waveshare7 = [ordered]@{
        framebufferWidth = 800
        framebufferHeight = 480
        logicalDmdWidth = 128
        logicalDmdHeight = 32
        dmdScale = 6
        dmdWidth = 768
        dmdHeight = 192
        dmdX = 16
        dmdY = 144
    }
    Landscape349 = [ordered]@{
        framebufferWidth = 640
        framebufferHeight = 172
        logicalDmdWidth = 128
        logicalDmdHeight = 32
        dmdScale = 5
        dmdWidth = 640
        dmdHeight = 160
        dmdX = 0
        dmdY = 6
    }
}
$expected = $models[$Model]

$stateUri = [uri]::new($QemuUrl, '/api/state')
$timer = [Diagnostics.Stopwatch]::StartNew()
$state = $null
do {
    try {
        $candidate = Invoke-RestMethod -Uri $stateUri -TimeoutSec 3
        if ([int]$candidate.uptimeSeconds -ge 25 -and
            [int]$candidate.displayFramesRendered -ge 2) {
            $state = $candidate
            break
        }
    }
    catch {
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw }
    }
    Start-Sleep -Milliseconds 500
} while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)

if ($null -eq $state) {
    throw "QEMU state at '$stateUri' was not ready after $TimeoutSeconds seconds."
}

$baseName = $Model.ToLowerInvariant()
$ppmPath = Join-Path $OutputDirectory "$baseName.ppm"
$evidencePath = Join-Path $OutputDirectory "$baseName.json"
Remove-Item -LiteralPath $ppmPath,$evidencePath -Force -ErrorAction SilentlyContinue

$monitorPath = $ppmPath -replace '\\', '/'
$client = [Net.Sockets.TcpClient]::new()
try {
    $client.Connect('127.0.0.1', $MonitorPort)
    $stream = $client.GetStream()
    $command = [Text.Encoding]::ASCII.GetBytes("screendump $monitorPath`n")
    $stream.Write($command, 0, $command.Length)
    $stream.Flush()
    Start-Sleep -Milliseconds 500
}
finally {
    $client.Dispose()
}

$captureTimer = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath $ppmPath -PathType Leaf) -and
       $captureTimer.Elapsed.TotalSeconds -lt 10) {
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $ppmPath -PathType Leaf)) {
    throw "QEMU monitor did not create '$ppmPath'."
}

$data = [IO.File]::ReadAllBytes($ppmPath)
$headerSample = [Text.Encoding]::ASCII.GetString(
    $data,
    0,
    [Math]::Min(128, $data.Length))
$header = [regex]::Match($headerSample, '\AP6\s+(\d+)\s+(\d+)\s+(\d+)\s')
if (-not $header.Success) {
    throw "'$ppmPath' is not a supported binary P6 PPM screenshot."
}

$width = [int]$header.Groups[1].Value
$height = [int]$header.Groups[2].Value
$maximum = [int]$header.Groups[3].Value
$pixelOffset = $header.Length
$expectedBytes = $pixelOffset + $width * $height * 3
if ($width -ne $expected.framebufferWidth -or
    $height -ne $expected.framebufferHeight) {
    throw "QEMU framebuffer is ${width}x${height}; expected $($expected.framebufferWidth)x$($expected.framebufferHeight) for $Model."
}
if ($maximum -ne 255 -or $data.Length -ne $expectedBytes) {
    throw "QEMU screenshot has an invalid P6 payload: max=$maximum bytes=$($data.Length), expected=$expectedBytes."
}

$nonBlackPixels = 0
$minimumX = $width
$minimumY = $height
$maximumX = -1
$maximumY = -1
for ($y = 0; $y -lt $height; $y++) {
    for ($x = 0; $x -lt $width; $x++) {
        $offset = $pixelOffset + ($y * $width + $x) * 3
        if ($data[$offset] -ne 0 -or
            $data[$offset + 1] -ne 0 -or
            $data[$offset + 2] -ne 0) {
            $nonBlackPixels++
            if ($x -lt $minimumX) { $minimumX = $x }
            if ($x -gt $maximumX) { $maximumX = $x }
            if ($y -lt $minimumY) { $minimumY = $y }
            if ($y -gt $maximumY) { $maximumY = $y }
        }
    }
}
if ($nonBlackPixels -eq 0 -and -not $AllowBlank) {
    throw "QEMU produced a blank $Model framebuffer."
}

$bounds = [ordered]@{
    minimumX = $minimumX
    minimumY = $minimumY
    maximumX = $maximumX
    maximumY = $maximumY
}
$evidence = [ordered]@{
    schemaVersion = 1
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    model = $Model
    qemuUrl = $QemuUrl.AbsoluteUri
    monitorPort = $MonitorPort
    contract = $expected
    runtime = [ordered]@{
        uptimeSeconds = [int]$state.uptimeSeconds
        sceneCount = [int]$state.sceneCount
        displayOn = [bool]$state.displayOn
        brightness = [int]$state.brightness
        colorPreset = [int]$state.colorPreset
        plasmaFramesRendered = [int]$state.plasmaFramesRendered
        displayFramesRendered = [int]$state.displayFramesRendered
    }
    screenshot = [ordered]@{
        path = $ppmPath
        width = $width
        height = $height
        maximumChannelValue = $maximum
        bytes = $data.Length
        sha256 = (Get-FileHash -LiteralPath $ppmPath -Algorithm SHA256).Hash
        nonBlackPixels = $nonBlackPixels
        nonBlackBounds = $bounds
        blank = $nonBlackPixels -eq 0
    }
}
$evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $evidencePath

Write-Host "[PASS] $Model QEMU display is ${width}x${height}; non-black pixels: $nonBlackPixels."
Write-Host "       Bounds: x=$minimumX..$maximumX, y=$minimumY..$maximumY; blank=$($nonBlackPixels -eq 0)"
Write-Host "       Evidence: $evidencePath"
$evidence
