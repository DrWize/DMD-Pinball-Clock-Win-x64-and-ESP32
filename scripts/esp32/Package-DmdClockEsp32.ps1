[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,

    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$outputRoot = Join-Path $repoRoot 'output'
$projectPath = Join-Path $repoRoot 'firmware/dmdclock-esp32'
$buildPath = Join-Path $projectPath 'build'
$toolRoot = Join-Path (Split-Path -Parent $repoRoot) '.tools/esp-idf/v5.5.2/tools'
$python = Join-Path $toolRoot 'python/v5.5.2/venv/Scripts/python.exe'
$bootstrapHeader = Join-Path $projectPath 'main/dmd_bootstrap_wifi.h'
$targetSlug = 'esp32-s3-touch-lcd-7-800x480-n16r8'
$buildNumber = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
$sourceRevision = (& git -C $repoRoot rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
    throw 'Unable to determine the Git source revision.'
}

if (-not $Version) {
    [xml]$properties = Get-Content -LiteralPath (Join-Path $repoRoot 'Directory.Build.props') -Raw
    $Version = [string]$properties.Project.PropertyGroup.VersionPrefix
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'Directory.Build.props must contain a valid VersionPrefix, or pass -Version.'
    }
}

$artifactStem = "DMDClock-$Version-$targetSlug"
$zipName = "$artifactStem.zip"
$manifestName = "DMDClock-$Version-esp32-manifest.json"
$checksumsName = "DMDClock-$Version-esp32-SHA256SUMS.txt"
$currentDirectory = Join-Path $outputRoot 'current/esp32-release'
$stagingDirectory = Join-Path $outputRoot ".staging/$buildNumber-esp32-release"
$firmwareDirectory = Join-Path $stagingDirectory 'firmware'
$stagingZip = Join-Path $outputRoot ".staging/$zipName"

function Assert-WithinOutputRoot([string] $Path) {
    $resolvedOutput = [IO.Path]::GetFullPath($outputRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith(
        "$resolvedOutput$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside output directory: $resolvedPath"
    }
}

function Get-FirmwareEntry {
    param(
        [Parameter(Mandatory)] [string] $Offset,
        [Parameter(Mandatory)] [string] $SourceRelativePath,
        [Parameter(Mandatory)] [string] $PackageFileName
    )

    $source = Join-Path $buildPath $SourceRelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Firmware build is missing '$source'."
    }
    $destination = Join-Path $firmwareDirectory $PackageFileName
    Copy-Item -LiteralPath $source -Destination $destination -Force
    return [ordered]@{
        offset = $Offset
        path = "firmware/$PackageFileName"
        size = (Get-Item -LiteralPath $destination).Length
        sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Assert-WithinOutputRoot $currentDirectory
Assert-WithinOutputRoot $stagingDirectory
Assert-WithinOutputRoot $stagingZip

if (Test-Path -LiteralPath $bootstrapHeader -PathType Leaf) {
    throw "Refusing to package a build with bootstrap Wi-Fi credentials: $bootstrapHeader. Clear the bootstrap header and rebuild first."
}

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'Build-DmdClock.ps1') -Version $Version
    if ($LASTEXITCODE -ne 0) {
        throw "Firmware build failed with exit code $LASTEXITCODE."
    }
}

$applicationImage = Join-Path $buildPath 'dmdclock_esp32.bin'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "ESP-IDF Python/esptool was not found: $python"
}
if (-not (Test-Path -LiteralPath $applicationImage -PathType Leaf)) {
    throw "Firmware application image is missing: $applicationImage"
}
$imageInfo = @(& $python -m esptool image_info --version 2 $applicationImage 2>&1)
$imageInfoExitCode = $LASTEXITCODE
$imageInfoText = $imageInfo | Out-String
if ($imageInfoExitCode -ne 0 -or
    $imageInfoText -notmatch "(?m)^App version:\s*$([Regex]::Escape($Version))\s*$") {
    throw "Firmware image does not embed the requested version '$Version'."
}
Write-Host "Verified embedded firmware version: $Version"

$flasherArgsPath = Join-Path $buildPath 'flasher_args.json'
if (-not (Test-Path -LiteralPath $flasherArgsPath -PathType Leaf)) {
    throw "Missing '$flasherArgsPath'. Build the firmware before packaging."
}
$flasher = Get-Content -LiteralPath $flasherArgsPath -Raw | ConvertFrom-Json
if ([string]$flasher.extra_esptool_args.chip -ne 'esp32s3' -or
    [string]$flasher.flash_settings.flash_size -ne '16MB' -or
    [string]$flasher.app.offset -ne '0x10000' -or
    [string]$flasher.bootloader.offset -ne '0x0' -or
    [string]$flasher.'partition-table'.offset -ne '0x8000') {
    throw 'Unexpected target, flash size, or flash offsets. Refusing to package this build.'
}

New-Item -ItemType Directory -Force -Path $firmwareDirectory | Out-Null
try {
    $bootloader = Get-FirmwareEntry -Offset '0x0' `
        -SourceRelativePath ([string]$flasher.bootloader.file) `
        -PackageFileName 'bootloader.bin'
    $application = Get-FirmwareEntry -Offset '0x10000' `
        -SourceRelativePath ([string]$flasher.app.file) `
        -PackageFileName 'dmdclock-esp32.bin'
    $partitionTable = Get-FirmwareEntry -Offset '0x8000' `
        -SourceRelativePath ([string]$flasher.'partition-table'.file) `
        -PackageFileName 'partition-table.bin'

    $internalBuildInfo = [ordered]@{
        version = $Version
        releaseTag = "v$Version"
        buildNumber = $buildNumber
        buildId = "$Version+$buildNumber.esp32.$sourceRevision"
        sourceRevision = $sourceRevision
        builtAt = (Get-Date).ToUniversalTime().ToString('o')
        target = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
        bootstrapWifiIncluded = $false
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory 'build-info.json'),
        $internalBuildInfo,
        [Text.UTF8Encoding]::new($false))

    if (Test-Path -LiteralPath $stagingZip) {
        Remove-Item -LiteralPath $stagingZip -Force
    }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingDirectory,
        $stagingZip,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)
    $zipInfo = Get-Item -LiteralPath $stagingZip
    $zipHash = (Get-FileHash -LiteralPath $stagingZip -Algorithm SHA256).Hash.ToLowerInvariant()

    $manifest = [ordered]@{
        schemaVersion = 1
        releaseTag = "v$Version"
        version = $Version
        buildId = "$Version+$buildNumber.esp32.$sourceRevision"
        sourceRevision = $sourceRevision
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        target = [ordered]@{
            id = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
            product = 'Waveshare ESP32-S3-Touch-LCD-7'
            display = '800x480'
            module = 'ESP32-S3-WROOM-1-N16R8'
            chip = 'esp32s3'
            flashSize = '16MB'
            supportedBoard = '7'
            unsupportedBoards = @('ESP32-S3-Touch-LCD-7B', '1024x600')
        }
        package = [ordered]@{
            asset = $zipName
            size = $zipInfo.Length
            sha256 = $zipHash
        }
        flash = [ordered]@{
            settings = [ordered]@{
                mode = [string]$flasher.flash_settings.flash_mode
                frequency = [string]$flasher.flash_settings.flash_freq
                size = [string]$flasher.flash_settings.flash_size
            }
            application = [ordered]@{
                description = 'Application update; preserves bootloader, partition table, NVS, Wi-Fi settings, and TF card.'
                preservesNvs = $true
                files = @($application)
            }
            full = [ordered]@{
                description = 'Complete installation; writes bootloader, partition table, and application without erasing NVS.'
                preservesNvs = $true
                files = @($bootloader, $partitionTable, $application)
            }
        }
    } | ConvertTo-Json -Depth 8

    if (Test-Path -LiteralPath $currentDirectory) {
        Remove-Item -LiteralPath $currentDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $currentDirectory | Out-Null
    $zipPath = Join-Path $currentDirectory $zipName
    Move-Item -LiteralPath $stagingZip -Destination $zipPath
    $manifestPath = Join-Path $currentDirectory $manifestName
    [IO.File]::WriteAllText($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))

    $checksumLines = @($zipName, $manifestName) | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath (Join-Path $currentDirectory $_) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $_"
    }
    Set-Content -LiteralPath (Join-Path $currentDirectory $checksumsName) `
        -Value $checksumLines -Encoding ascii

    Write-Host "ESP32 release package: $zipPath"
    Write-Host "ESP32 release manifest: $manifestPath"
    Write-Host "ESP32 checksums: $(Join-Path $currentDirectory $checksumsName)"
    Write-Host 'Supported hardware: Waveshare ESP32-S3-Touch-LCD-7, 800x480, N16R8 only.'
    Write-Warning 'The ESP32-S3-Touch-LCD-7B (1024x600) is not supported.'
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $stagingZip) {
        Remove-Item -LiteralPath $stagingZip -Force
    }
}
