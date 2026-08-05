[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'output'
$runtime = 'osx-arm64'
$buildNumber = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')
$sourceRevision = (& git -C $projectRoot rev-parse --short=12 HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sourceRevision)) {
    throw 'Unable to determine the Git source revision.'
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    [xml]$buildProperties = Get-Content -LiteralPath (
        Join-Path $projectRoot 'Directory.Build.props') -Raw
    $Version = [string]$buildProperties.Project.PropertyGroup.VersionPrefix
    if ($Version -notmatch '^\d+\.\d+\.\d+$') {
        throw 'Directory.Build.props must define a semantic VersionPrefix, or pass -Version x.y.z.'
    }
}

$buildId = "$Version+$buildNumber.$runtime.$sourceRevision"
$artifactStem = "DMDClock-$Version-build$buildNumber-$runtime-unsigned"
$currentDirectory = Join-Path $outputRoot "current/$runtime"
$stagingDirectory = Join-Path $outputRoot ".staging/$buildNumber-$runtime"
$bundleDirectory = Join-Path $stagingDirectory 'DMDClock.app'
$contentsDirectory = Join-Path $bundleDirectory 'Contents'
$publishDirectory = Join-Path $contentsDirectory 'MacOS'
$resourcesDirectory = Join-Path $contentsDirectory 'Resources'
$zipName = "$artifactStem.zip"
$stagingZipPath = Join-Path $outputRoot ".staging\$zipName"
$projectFile = Join-Path $projectRoot 'src/DmdClock.App/DmdClock.App.csproj'
$plistTemplatePath = Join-Path $projectRoot 'assets/macos/Info.plist.template'
$iconPath = Join-Path $projectRoot 'assets/icons/dmdclock-flipper-3-512.png'

$localDotnet = Join-Path (Split-Path -Parent $projectRoot) '.tools/dotnet10/dotnet.exe'
$dotnet = if ($env:DMD_DOTNET) {
    $env:DMD_DOTNET
} elseif (Test-Path -LiteralPath $localDotnet) {
    $localDotnet
} else {
    'dotnet'
}

$runningOnMacOS = $PSVersionTable.PSEdition -eq 'Core' -and
    [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [Runtime.InteropServices.OSPlatform]::OSX)

function Assert-WithinOutputRoot([string]$Path) {
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

function Assert-PublishedFile([string]$RelativePath) {
    $path = Join-Path $publishDirectory $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "macOS publish is missing required file: $RelativePath"
    }
}

Assert-WithinOutputRoot $currentDirectory
Assert-WithinOutputRoot $stagingDirectory
Assert-WithinOutputRoot $stagingZipPath

if (-not (Test-Path -LiteralPath $plistTemplatePath -PathType Leaf)) {
    throw "Missing macOS Info.plist template: $plistTemplatePath"
}
if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) {
    throw "Missing temporary macOS icon: $iconPath"
}

New-Item -ItemType Directory -Force -Path $publishDirectory, $resourcesDirectory | Out-Null

try {
    & $dotnet publish $projectFile `
        --configuration $Configuration `
        --runtime $runtime `
        --self-contained true `
        "-p:Version=$Version" `
        "-p:InformationalVersion=$buildId" `
        --output $publishDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    @(
        'DmdClock.App'
        'libAvaloniaNative.dylib'
        'libSkiaSharp.dylib'
        'i18n/en.json'
        'scenes/scene-metadata.json'
    ) | ForEach-Object { Assert-PublishedFile $_ }

    Copy-Item -LiteralPath $iconPath `
        -Destination (Join-Path $resourcesDirectory 'dmdclock.png') -Force

    $plist = (Get-Content -LiteralPath $plistTemplatePath -Raw).
        Replace('__VERSION__', $Version).
        Replace('__BUILD_NUMBER__', $buildNumber)
    if ($plist.Contains('__VERSION__') -or $plist.Contains('__BUILD_NUMBER__')) {
        throw 'Info.plist template replacement left unresolved tokens.'
    }
    [IO.File]::WriteAllText(
        (Join-Path $contentsDirectory 'Info.plist'),
        $plist,
        [Text.UTF8Encoding]::new($false))

    $executablePermissionValidated = $false
    if ($runningOnMacOS) {
        & /bin/chmod +x (Join-Path $publishDirectory 'DmdClock.App')
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to mark the macOS application executable.'
        }
        $executablePermissionValidated = $true
    }

    $buildInfo = [ordered]@{
        buildId = $buildId
        buildNumber = $buildNumber
        version = $Version
        sourceRevision = $sourceRevision
        artifactFile = $zipName
        builtAt = (Get-Date).ToString('o')
        runtime = $runtime
        configuration = $Configuration
        selfContained = $true
        bundleIdentifier = 'io.github.drwize.dmdclock'
        signed = $false
        notarized = $false
        releaseReady = $false
        macLaunchValidated = $false
        executablePermissionValidated = $executablePermissionValidated
        status = 'Developer preview: unsigned, unnotarized, and not launch-tested on macOS.'
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        (Join-Path $resourcesDirectory 'build-info.json'),
        $buildInfo,
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(
        (Join-Path $stagingDirectory 'build-info.json'),
        $buildInfo,
        [Text.UTF8Encoding]::new($false))

    if (Test-Path -LiteralPath $stagingZipPath) {
        Remove-Item -LiteralPath $stagingZipPath -Force
    }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingDirectory,
        $stagingZipPath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false)

    if (Test-Path -LiteralPath $currentDirectory) {
        Remove-Item -LiteralPath $currentDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $currentDirectory) | Out-Null
    Move-Item -LiteralPath $stagingDirectory -Destination $currentDirectory
    $zipPath = Join-Path $currentDirectory $zipName
    Move-Item -LiteralPath $stagingZipPath -Destination $zipPath

    Write-Host "macOS app bundle: $(Join-Path $currentDirectory 'DMDClock.app')"
    Write-Host "Unsigned preview ZIP: $zipPath"
    Write-Warning 'This package is unsigned, unnotarized, and not release-ready until it passes the physical-Mac plan.'
    if (-not $runningOnMacOS) {
        Write-Warning 'The bundle was cross-built off macOS; executable permissions and launch behavior still require Mac validation.'
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $stagingZipPath) {
        Remove-Item -LiteralPath $stagingZipPath -Force
    }
}
