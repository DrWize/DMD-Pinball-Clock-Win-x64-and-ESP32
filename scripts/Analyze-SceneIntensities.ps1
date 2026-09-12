[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$ScenePath,

    [string]$ScenesDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scenes'),
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$DMD_WIDTH = 128
$DMD_HEIGHT = 32
$DMD_PIXEL_COUNT = $DMD_WIDTH * $DMD_HEIGHT
$SCN_HEADER_SIZE = 6
$SCN_STORYBOARD_SIZE = 36
$SCN_FRAME_HEADER_SIZE = 8

function Read-UInt16([byte[]]$Data, [int]$Offset) {
    return [uint16]($Data[$Offset] -bor ([uint16]$Data[$Offset + 1] -shl 8))
}

function Get-SceneFrameIntensities([byte[]]$Data) {
    $frameCount = Read-UInt16 $Data 2
    $storyboardCount = Read-UInt16 $Data 4

    if ($frameCount -eq 0 -or $storyboardCount -eq 0) {
        throw "Invalid scene header"
    }

    $offset = $SCN_HEADER_SIZE + ($storyboardCount * $SCN_STORYBOARD_SIZE)
    $frames = [System.Collections.Generic.List[pscustomobject]]::new()

    for ($f = 0; $f -lt $frameCount; $f++) {
        if ($offset + $SCN_FRAME_HEADER_SIZE -gt $Data.Length) {
            throw "Truncated frame header at frame $f"
        }

        $width = Read-UInt16 $Data $offset
        $height = Read-UInt16 $Data ($offset + 2)
        $bpp = Read-UInt16 $Data ($offset + 4)
        $hasMask = Read-UInt16 $Data ($offset + 6)

        if ($width -ne $DMD_WIDTH -or $height -ne $DMD_HEIGHT -or $bpp -ne 4) {
            throw "Unsupported frame $f`: ${width}x${height} ${bpp}bpp"
        }

        $packedSize = $DMD_PIXEL_COUNT / 2
        $frameDataOffset = $offset + $SCN_FRAME_HEADER_SIZE
        $maskOffset = 0
        $totalFrameSize = $SCN_FRAME_HEADER_SIZE + $packedSize

        if ($hasMask) {
            $maskSize = $DMD_PIXEL_COUNT / 8
            $maskOffset = $frameDataOffset + $packedSize
            $totalFrameSize += $maskSize
        }

        if ($frameDataOffset + $packedSize -gt $Data.Length) {
            throw "Truncated pixel data at frame $f"
        }

        $intensities = [int[]]::new($DMD_PIXEL_COUNT)
        for ($i = 0; $i -lt $packedSize; $i++) {
            $byte = $Data[$frameDataOffset + $i]
            $intensities[$i * 2] = $byte -band 0x0F
            $intensities[$i * 2 + 1] = ($byte -shr 4) -band 0x0F
        }

        $sum = 0
        $min = 15
        $max = 0
        $litPixels = 0
        $histogram = [int[]]::new(16)

        for ($p = 0; $p -lt $DMD_PIXEL_COUNT; $p++) {
            $val = $intensities[$p]
            $sum += $val
            $histogram[$val]++
            if ($val -gt 0) { $litPixels++ }
            if ($val -lt $min) { $min = $val }
            if ($val -gt $max) { $max = $val }
        }

        $avg = [math]::Round($sum / $DMD_PIXEL_COUNT, 2)
        $litRatio = [math]::Round($litPixels / $DMD_PIXEL_COUNT, 4)

        if ($litPixels -gt 0) {
            $litAvg = [math]::Round($sum / $litPixels, 2)
        } else {
            $litAvg = 0
        }

        $frames.Add([pscustomobject]@{
            frame           = $f
            pixels          = $DMD_PIXEL_COUNT
            litPixels       = $litPixels
            litRatio        = $litRatio
            minIntensity    = $min
            maxIntensity    = $max
            avgIntensity    = $avg
            litAvgIntensity = $litAvg
            histogram       = $histogram
        })

        $offset += $totalFrameSize
    }

    return $frames
}

function Get-SceneInfo([byte[]]$Data) {
    $version = Read-UInt16 $Data 0
    $frameCount = Read-UInt16 $Data 2
    $storyboardCount = Read-UInt16 $Data 4

    $storyboardOffset = $SCN_HEADER_SIZE
    $firstDelay = Read-UInt16 $Data $storyboardOffset
    $normalDelay = Read-UInt16 $Data ($storyboardOffset + 6)
    $finalHold = Read-UInt16 $Data ($storyboardOffset + 10)

    return [pscustomobject]@{
        version         = $version
        frameCount      = $frameCount
        storyboardCount = $storyboardCount
        firstDelayMs    = $firstDelay
        normalDelayMs   = if ($normalDelay -eq 0) { 100 } else { $normalDelay }
        finalHoldMs     = $finalHold
        fileSize        = $Data.Length
    }
}

if ($ScenePath) {
    if (-not (Test-Path -LiteralPath $ScenePath -PathType Leaf)) {
        throw "Scene file not found: $ScenePath"
    }
    $sceneFiles = @(Get-Item -LiteralPath $ScenePath)
} else {
    if (-not (Test-Path -LiteralPath $ScenesDirectory -PathType Container)) {
        throw "Scenes directory not found: $ScenesDirectory"
    }
    $sceneFiles = @(Get-ChildItem -LiteralPath $ScenesDirectory -File -Filter '*.scn' | Sort-Object Name)
}

if ($sceneFiles.Count -eq 0) {
    throw "No .scn files found"
}

Write-Host "Analyzing $($sceneFiles.Count) scene(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[pscustomobject]]::new()
$globalHistogram = [int[]]::new(16)
$totalFrames = 0

foreach ($file in $sceneFiles) {
    $data = [IO.File]::ReadAllBytes($file.FullName)

    try {
        $info = Get-SceneInfo $data
        $frames = Get-SceneFrameIntensities $data
    } catch {
        Write-Warning "Skipping $($file.Name): $_"
        continue
    }

    $sceneSum = 0
    $sceneLitSum = 0
    $scenePixelsSum = 0
    $sceneMin = 15
    $sceneMax = 0

    foreach ($frame in $frames) {
        $totalFrames++
        $sceneSum += $frame.avgIntensity
        $sceneLitSum += $frame.litPixels
        $scenePixelsSum += $frame.pixels
        if ($frame.minIntensity -lt $sceneMin) { $sceneMin = $frame.minIntensity }
        if ($frame.maxIntensity -gt $sceneMax) { $sceneMax = $frame.maxIntensity }
        for ($i = 0; $i -lt 16; $i++) {
            $globalHistogram[$i] += $frame.histogram[$i]
        }
    }

    $sceneAvg = [math]::Round($sceneSum / $frames.Count, 2)

    if ($scenePixelsSum -gt 0) {
        $litRatio = [math]::Round($sceneLitSum / $scenePixelsSum, 4)
    } else {
        $litRatio = 0
    }

    $results.Add([pscustomobject]@{
        file          = $file.Name
        frames        = $info.frameCount
        normalDelayMs = $info.normalDelayMs
        finalHoldMs   = $info.finalHoldMs
        fileSize      = $info.fileSize
        avgIntensity  = $sceneAvg
        minIntensity  = $sceneMin
        maxIntensity  = $sceneMax
        litRatio      = $litRatio
    })

    $litPct = if ($scenePixelsSum -gt 0) { [math]::Round($sceneLitSum / $scenePixelsSum * 100, 1) } else { 0 }
    Write-Host "  $($file.Name): $($info.frameCount) frames, avg=$sceneAvg, lit=${litPct}%" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
Write-Host "  Scenes: $($results.Count)" -ForegroundColor White
Write-Host "  Total frames: $totalFrames" -ForegroundColor White

$globalTotal = 0
$weightedSum = 0
for ($i = 0; $i -lt 16; $i++) {
    $globalTotal += $globalHistogram[$i]
    $weightedSum += $i * $globalHistogram[$i]
}

if ($globalTotal -gt 0) {
    $globalLit = $globalTotal - $globalHistogram[0]
    $globalAvg = [math]::Round($weightedSum / $globalTotal, 2)
    $globalLitPct = [math]::Round($globalLit / $globalTotal * 100, 1)
} else {
    $globalLit = 0
    $globalAvg = 0
    $globalLitPct = 0
}

Write-Host "  Global lit ratio: ${globalLitPct}%" -ForegroundColor White
Write-Host "  Global avg intensity: $globalAvg" -ForegroundColor White

Write-Host ""
Write-Host "Histogram (all frames):" -ForegroundColor Yellow
for ($i = 0; $i -lt 16; $i++) {
    $count = $globalHistogram[$i]
    if ($globalTotal -gt 0) {
        $pct = [math]::Round($count / $globalTotal * 100, 2)
    } else {
        $pct = 0
    }
    $barLen = [math]::Min([math]::Round($pct), 50)
    $bar = '#' * $barLen
    Write-Host ("  {0:X1}: {1,10:N0} ({2,6:N2}%) {3}" -f $i, $count, $pct, $bar)
}

$globalLitRatio = if ($globalTotal -gt 0) { [math]::Round($globalLit / $globalTotal, 4) } else { 0 }

$output = [pscustomobject]@{
    analyzedAt  = (Get-Date).ToString('o')
    sceneCount  = $results.Count
    totalFrames = $totalFrames
    globalStats = [pscustomobject]@{
        avgIntensity = $globalAvg
        litRatio     = $globalLitRatio
        histogram    = @($globalHistogram)
    }
    scenes      = @($results)
}

$json = ($output | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"

if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($OutputPath),
        "$json`n",
        [Text.UTF8Encoding]::new($false))
    Write-Host ""
    Write-Host "Report saved to: $OutputPath" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host $json
}

return [pscustomobject]@{
    ScenesAnalyzed = $results.Count
    TotalFrames    = $totalFrames
    GlobalAvg      = $globalAvg
    GlobalLitRatio = $globalLitRatio
}