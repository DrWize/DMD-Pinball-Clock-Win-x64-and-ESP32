# Captures 30 Landscape349 QEMU screenshots for each colour family as PNG files.
# Start QEMU first:
#   .\scripts\esp32\dev\Run-DmdClockQemuModel.ps1 -Model Landscape349

[CmdletBinding()]
param(
    [uri] $QemuUrl = 'http://127.0.0.1:8081',

    [ValidateRange(1, 65535)]
    [int] $MonitorPort = 4445,

    [ValidateRange(1, 200)]
    [int] $CountPerMode = 30,

    [ValidateRange(100, 10000)]
    [int] $IntervalMilliseconds = 800,

    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$captureScript = Join-Path $PSScriptRoot 'Test-DmdClockQemuDisplay.ps1'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path $repoRoot "output\esp32\screenshots\landscape349-colour-modes\$runId"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$baseUri = $QemuUrl.AbsoluteUri.TrimEnd('/')
$stateUri = "$baseUri/api/state"
$settingsUri = "$baseUri/api/settings"
$actionUri = "$baseUri/api/action"
$themeCases = @(
    @{ Family = 'Basic'; Preset = 0 },
    @{ Family = 'Gradient'; Preset = 4 },
    @{ Family = 'Raster'; Preset = 25 },
    @{ Family = 'Plasma'; Preset = 2 }
)

function Get-State {
    Invoke-RestMethod -Uri $stateUri -TimeoutSec 5
}

function Set-Settings {
    param([Parameter(Mandatory)] [hashtable] $Values)
    Invoke-RestMethod -Uri $settingsUri -Method Post -ContentType 'application/json' `
        -Body ($Values | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
    Start-Sleep -Milliseconds 350
    Get-State
}

function Invoke-Action {
    param([Parameter(Mandatory)] [string] $Name)
    Invoke-RestMethod -Uri $actionUri -Method Post -ContentType 'application/json' `
        -Body (@{ action = $Name } | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
}

function Advance-ToNextScene {
    param([Parameter(Mandatory)] [int] $PreviousSceneIndex)

    # sceneNext is deliberately constrained to the current game's scenes.
    # Use pinballNext so a one-scene game still advances to a distinct scene.
    Invoke-Action 'pinballNext'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $state = Get-State
        # One-frame SCN files can finish between the action response and this
        # status poll. A different API scene index proves the new scene was
        # selected without rejecting those valid short scenes.
        if ([int]$state.sceneIndex -ne $PreviousSceneIndex) {
            return $state
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 5)
    throw "pinballNext did not produce a new playing scene after index $PreviousSceneIndex."
}

function Wait-ForQemuDisplay {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $state = Get-State
            if ([int]$state.uptimeSeconds -ge 25 -and
                [int]$state.displayFramesRendered -ge 2) {
                return $state
            }
        }
        catch {
            if ($timer.Elapsed.TotalSeconds -ge 60) { throw }
        }
        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt 60)
    throw "QEMU at '$baseUri' was not ready after 60 seconds."
}

function Save-QemuScreenshot {
    param([Parameter(Mandatory)] [string] $PngPath)

    # Reuse the established QEMU PPM capture helper; it handles the monitor's
    # Windows-path behavior. The PPM is only a transient transport file.
    $stagingDirectory = Join-Path $repoRoot 'output\esp32\reports\qemu-colour-capture-staging'
    New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
    $ppmPath = Join-Path $stagingDirectory 'landscape349.ppm'
    $evidencePath = Join-Path $stagingDirectory 'landscape349.json'
    & $captureScript -Model Landscape349 -QemuUrl $QemuUrl -MonitorPort $MonitorPort `
        -OutputDirectory $stagingDirectory -TimeoutSeconds 30 | Out-Null
    if (-not (Test-Path -LiteralPath $ppmPath -PathType Leaf)) {
        throw "QEMU capture helper did not create '$ppmPath'."
    }

    try {
        $data = [IO.File]::ReadAllBytes($ppmPath)
        $sample = [Text.Encoding]::ASCII.GetString($data, 0, [Math]::Min(128, $data.Length))
        $header = [regex]::Match($sample, '\AP6\s+(\d+)\s+(\d+)\s+(\d+)\s')
        if (-not $header.Success) { throw "'$ppmPath' is not a binary P6 PPM image." }
        $width = [int]$header.Groups[1].Value
        $height = [int]$header.Groups[2].Value
        $maximum = [int]$header.Groups[3].Value
        $pixelOffset = $header.Length
        if ($width -ne 640 -or $height -ne 172 -or $maximum -ne 255 -or
            $data.Length -ne ($pixelOffset + $width * $height * 3)) {
            throw "QEMU screenshot is not the expected 640x172 P6 image."
        }

        $argb = New-Object byte[] ($width * $height * 4)
        for ($pixel = 0; $pixel -lt ($width * $height); $pixel++) {
            $source = $pixelOffset + $pixel * 3
            $target = $pixel * 4
            $argb[$target] = $data[$source + 2]
            $argb[$target + 1] = $data[$source + 1]
            $argb[$target + 2] = $data[$source]
            $argb[$target + 3] = 255
        }

        $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $rectangle = [Drawing.Rectangle]::new(0, 0, $width, $height)
            $bits = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, $bitmap.PixelFormat)
            try {
                [Runtime.InteropServices.Marshal]::Copy($argb, 0, $bits.Scan0, $argb.Length)
            }
            finally {
                $bitmap.UnlockBits($bits)
            }
            $bitmap.Save($PngPath, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $bitmap.Dispose()
        }
    }
    finally {
        Remove-Item -LiteralPath $ppmPath,$evidencePath -Force -ErrorAction SilentlyContinue
    }
}

$initial = Wait-ForQemuDisplay
$captures = [Collections.Generic.List[object]]::new()
try {
    foreach ($theme in $themeCases) {
        $state = Set-Settings @{
            displayOn = $true
            playScene = $true
            automaticCycle = $false
            brightness = 100
            colorPreset = $theme.Preset
        }
        if ([string]$state.colorFamily -ne $theme.Family) {
            throw "Preset $($theme.Preset) did not select $($theme.Family)."
        }

        $familyDirectory = Join-Path $OutputDirectory $theme.Family.ToLowerInvariant()
        New-Item -ItemType Directory -Force -Path $familyDirectory | Out-Null
        $previousSceneIndex = [int]$state.sceneIndex
        $seenSceneIndexes = [Collections.Generic.HashSet[int]]::new()
        for ($number = 1; $number -le $CountPerMode; $number++) {
            $state = Advance-ToNextScene -PreviousSceneIndex $previousSceneIndex
            $previousSceneIndex = [int]$state.sceneIndex
            if (-not $seenSceneIndexes.Add($previousSceneIndex)) {
                throw "Scene index $previousSceneIndex was repeated in the $($theme.Family) capture set."
            }
            Start-Sleep -Milliseconds $IntervalMilliseconds
            $fileName = '{0:D2}-{1:yyyyMMddTHHmmssfffZ}.png' -f $number, [DateTime]::UtcNow
            $pngPath = Join-Path $familyDirectory $fileName
            Save-QemuScreenshot -PngPath $pngPath
            $state = Get-State
            if ([int]$state.sceneIndex -ne $previousSceneIndex) {
                throw "Scene changed during screenshot capture: expected index $previousSceneIndex, got $([int]$state.sceneIndex)."
            }
            $captures.Add([ordered]@{
                family = $theme.Family
                preset = $theme.Preset
                number = $number
                path = [IO.Path]::GetRelativePath($OutputDirectory, $pngPath)
                sha256 = (Get-FileHash -LiteralPath $pngPath -Algorithm SHA256).Hash
                sceneIndex = [int]$state.sceneIndex
                sceneFrame = [int]$state.sceneFrame
                capturedAtUtc = [DateTime]::UtcNow.ToString('o')
            })
        }
    }
}
finally {
    Set-Settings @{
        displayOn = [bool]$initial.displayOn
        playScene = [bool]$initial.playScene
        automaticCycle = [bool]$initial.automaticCycle
        brightness = [int]$initial.brightness
        colorPreset = [int]$initial.colorPreset
    } | Out-Null
}

[ordered]@{
    schemaVersion = 1
    model = 'Landscape349'
    qemuUrl = $baseUri
    monitorPort = $MonitorPort
    countPerMode = $CountPerMode
    totalScreenshots = $captures.Count
    captures = @($captures)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'manifest.json') -Encoding utf8

Write-Host "[PASS] Captured $($captures.Count) PNG screenshots to '$OutputDirectory'." -ForegroundColor Green
