[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Tag,

    [string]$Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [string]$Target = 'master',

    [string]$Title,

    [string]$NotesPath,

    [switch]$Prerelease,

    [switch]$Draft,

    [switch]$IncludeEsp32,

    [switch]$Esp32Only
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$portableDirectory = Join-Path $projectRoot 'output\current\win-x64'
$standaloneDirectory = Join-Path $projectRoot 'output\current\win-x64-standalone'
$installerDirectory = Join-Path $projectRoot 'output\current\win-x64-installer'
$releaseDirectory = Join-Path $projectRoot 'output\current\release'
$releaseManifestPath = Join-Path $releaseDirectory 'release-manifest.json'
$esp32ReleaseDirectory = Join-Path $projectRoot 'output\current\esp32-release'
$installerInfoPath = Join-Path $installerDirectory 'installer-build-info.json'
$portableInfoPath = Join-Path $portableDirectory 'build-info.json'
$standaloneInfoPath = Join-Path $standaloneDirectory 'build-info.json'
$esp32StartScriptPath = Join-Path $projectRoot 'scripts\esp32\RUNME-Install-DmdClockEsp32.ps1'

function Assert-Command([string]$Name) {
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command was not found: $Name"
    }
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required release file is missing: $Path"
    }
}

function Resolve-ManifestArtifact([object]$Manifest, [string]$Kind) {
    $matches = @($Manifest.artifacts | Where-Object { $_.kind -eq $Kind })
    if ($matches.Count -ne 1) {
        throw "Release manifest must contain exactly one '$Kind' artifact."
    }
    $resolved = [IO.Path]::GetFullPath((Join-Path $projectRoot $matches[0].path))
    $resolvedRoot = [IO.Path]::GetFullPath($projectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolved.StartsWith(
        "$resolvedRoot$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release manifest artifact escapes the project directory: $resolved"
    }
    Assert-File $resolved
    if ((Split-Path -Leaf $resolved) -ne $matches[0].fileName) {
        throw "Release manifest filename does not match its path for '$Kind'."
    }
    $actualHash = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash
    if ($actualHash -ne $matches[0].sha256) {
        throw "Release manifest checksum mismatch for '$Kind': $resolved"
    }
    return $resolved
}

Assert-Command 'git'
Assert-Command 'gh'
Assert-File $esp32StartScriptPath

Push-Location $projectRoot
try {
    & gh auth status
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run gh auth login first.'
    }

    if ($Esp32Only -and -not $IncludeEsp32) {
        throw '-Esp32Only requires -IncludeEsp32.'
    }

    $desktopAssetPaths = @()
    $releaseBuildId = 'ESP32-only'
    if (-not $Esp32Only) {
        Assert-File $releaseManifestPath
        $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
        $installer = Resolve-ManifestArtifact $releaseManifest 'installer'
        $portableZip = Resolve-ManifestArtifact $releaseManifest 'portable'
        $standaloneZip = Resolve-ManifestArtifact $releaseManifest 'standalone'
        $installerInfoPath = Resolve-ManifestArtifact $releaseManifest 'installerInfo'

        foreach ($path in @(
            $portableZip,
            $standaloneZip,
            $installer,
            $installerInfoPath,
            $portableInfoPath,
            $standaloneInfoPath
        )) {
            Assert-File $path
        }

        $portableInfo = Get-Content -LiteralPath $portableInfoPath -Raw | ConvertFrom-Json
        $standaloneInfo = Get-Content -LiteralPath $standaloneInfoPath -Raw | ConvertFrom-Json
        $installerInfo = Get-Content -LiteralPath $installerInfoPath -Raw | ConvertFrom-Json

        if ($portableInfo.buildId -ne $standaloneInfo.buildId -or
            $portableInfo.buildId -ne $installerInfo.applicationBuildId -or
            $portableInfo.buildId -ne $releaseManifest.buildId) {
        throw @"
Release artifacts do not come from the same application build:
Portable:   $($portableInfo.buildId)
Standalone: $($standaloneInfo.buildId)
Installer:  $($installerInfo.applicationBuildId)
Manifest:   $($releaseManifest.buildId)
"@
        }
        $actualInstallerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
        if ($actualInstallerHash -ne $installerInfo.installerSha256) {
        throw @"
Installer checksum does not match installer-build-info.json:
Recorded: $($installerInfo.installerSha256)
Actual:   $actualInstallerHash
"@
        }

        if ($installerInfo.appVersion -notmatch '^\d+\.\d+\.\d+$') {
            throw "Invalid installer application version: $($installerInfo.appVersion)"
        }

        if ([string]::IsNullOrWhiteSpace($Tag)) {
            $Tag = "v$($installerInfo.appVersion)"
        }
        $desktopAssetPaths = @($installer, $portableZip, $standaloneZip, $installerInfoPath)
        $releaseBuildId = [string]$portableInfo.buildId
    } elseif ([string]::IsNullOrWhiteSpace($Tag)) {
        throw '-Esp32Only requires an explicit -Tag.'
    }
    if ($Tag -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw "Tag must use a semantic version such as v1.0.0 or v1.1.0-beta.1: $Tag"
    }
    if ([string]::IsNullOrWhiteSpace($Title)) {
        $Title = "DMDClock $Tag"
    }

    $workingChanges = & git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the Git working tree.'
    }
    if ($workingChanges) {
        throw 'The Git working tree is not clean. Commit or restore changes before publishing.'
    }

    & git fetch --prune origin
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to fetch origin.'
    }
    $localCommit = (& git rev-parse HEAD).Trim()
    $targetCommit = (& git rev-parse "origin/$Target").Trim()
    if ($LASTEXITCODE -ne 0 -or $localCommit -ne $targetCommit) {
        throw "HEAD must exactly match origin/$Target before publishing."
    }

    $esp32AssetPaths = @()
    if ($IncludeEsp32) {
        if (-not (Test-Path -LiteralPath $esp32ReleaseDirectory -PathType Container)) {
            throw "ESP32 release directory is missing: $esp32ReleaseDirectory"
        }
        $esp32ManifestFiles = @(Get-ChildItem -LiteralPath $esp32ReleaseDirectory `
            -Filter 'DMDClock-*-esp32*-manifest.json' -File)
        $allowedEsp32Targets = @(
            'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8',
            'waveshare-esp32-s3-touch-lcd-3-49b-v2-640x172-n16r8'
        )
        if ($esp32ManifestFiles.Count -ne $allowedEsp32Targets.Count) {
            throw "The ESP32 release directory must contain one manifest for each supported target ($($allowedEsp32Targets.Count) total)."
        }
        $seenEsp32Targets = @{}
        foreach ($esp32ManifestFile in $esp32ManifestFiles) {
            $esp32ManifestPath = $esp32ManifestFile.FullName
            $esp32Manifest = Get-Content -LiteralPath $esp32ManifestPath -Raw | ConvertFrom-Json
            $esp32TargetId = [string]$esp32Manifest.target.id
            if ([int]$esp32Manifest.schemaVersion -ne 1 -or
                [string]$esp32Manifest.releaseTag -ne $Tag -or
                [string]$esp32Manifest.sourceRevision -notmatch '^[0-9A-Fa-f]{12}$' -or
                $esp32TargetId -notin $allowedEsp32Targets -or
                [bool]$esp32Manifest.target.touchEnabled -ne $true) {
                throw "ESP32 manifest '$($esp32ManifestFile.Name)' has an invalid schema, tag, revision, target, or touch status."
            }
            if ($seenEsp32Targets.ContainsKey($esp32TargetId)) {
                throw "Duplicate ESP32 release manifest for target '$esp32TargetId'."
            }
            $seenEsp32Targets[$esp32TargetId] = $true
            if (-not $localCommit.StartsWith(
                [string]$esp32Manifest.sourceRevision,
                [StringComparison]::OrdinalIgnoreCase)) {
                throw "ESP32 package '$esp32TargetId' was not built from release commit $localCommit."
            }

            $esp32TargetSlug = $esp32TargetId
            $expectedEsp32ManifestName = "DMDClock-$($esp32Manifest.version)-esp32-$esp32TargetSlug-manifest.json"
            $expectedEsp32PackageName = "DMDClock-$($esp32Manifest.version)-$esp32TargetSlug.zip"
            $esp32ChecksumsName = "DMDClock-$($esp32Manifest.version)-esp32-$esp32TargetSlug-SHA256SUMS.txt"
            $esp32PackagePath = Join-Path $esp32ReleaseDirectory ([string]$esp32Manifest.package.asset)
            $esp32ChecksumsPath = Join-Path $esp32ReleaseDirectory $esp32ChecksumsName
            if ((Split-Path -Leaf $esp32ManifestPath) -cne $expectedEsp32ManifestName -or
                [string]$esp32Manifest.package.asset -cne $expectedEsp32PackageName) {
                throw "ESP32 manifest or package filename is not canonical for target '$esp32TargetId'."
            }
            foreach ($path in @($esp32ManifestPath, $esp32PackagePath, $esp32ChecksumsPath)) {
                Assert-File $path
            }
            if ((Get-Item -LiteralPath $esp32PackagePath).Length -ne [long]$esp32Manifest.package.size) {
                throw "ESP32 package size does not match the manifest for '$esp32TargetId'."
            }
            $esp32PackageHash = (Get-FileHash -LiteralPath $esp32PackagePath -Algorithm SHA256).Hash
            if ($esp32PackageHash -ne [string]$esp32Manifest.package.sha256) {
                throw "ESP32 package checksum does not match the manifest for '$esp32TargetId'."
            }
            $esp32ChecksumLines = @(Get-Content -LiteralPath $esp32ChecksumsPath)
            foreach ($path in @($esp32PackagePath, $esp32ManifestPath)) {
                $expectedLine = '{0}  {1}' -f (
                    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()),
                    (Split-Path -Leaf $path)
                if ($expectedLine -cnotin $esp32ChecksumLines) {
                    throw "ESP32 checksum list does not contain the expected entry for '$(Split-Path -Leaf $path)'."
                }
            }
            $esp32AssetPaths += @($esp32PackagePath, $esp32ManifestPath, $esp32ChecksumsPath)
        }
        foreach ($esp32TargetId in $allowedEsp32Targets) {
            if (-not $seenEsp32Targets.ContainsKey($esp32TargetId)) {
                throw "Missing ESP32 release manifest for supported target '$esp32TargetId'."
            }
        }
    }

    & gh release view $Tag --repo $Repository *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "GitHub Release already exists: $Tag"
    }
    & git ls-remote --exit-code --tags origin "refs/tags/$Tag" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Git tag already exists on origin: $Tag"
    }

    if (-not [string]::IsNullOrWhiteSpace($NotesPath)) {
        $NotesPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $NotesPath))
        Assert-File $NotesPath
    }

    $assetPaths = $desktopAssetPaths + $esp32AssetPaths + @($esp32StartScriptPath)
    $hashLines = foreach ($assetPath in $assetPaths) {
        $hash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
        "$hash  $(Split-Path -Leaf $assetPath)"
    }

    Write-Host "Repository: $Repository"
    Write-Host "Target:     $Target ($localCommit)"
    Write-Host "Tag:        $Tag"
    Write-Host "Build:      $releaseBuildId"
    Write-Host "Prerelease: $($Prerelease.IsPresent)"
    Write-Host "Draft:      $($Draft.IsPresent)"
    Write-Host "ESP32:      $($IncludeEsp32.IsPresent)"
    Write-Host "ESP32 only: $($Esp32Only.IsPresent)"
    Write-Host "Start script: $(Split-Path -Leaf $esp32StartScriptPath)"
    $hashLines | ForEach-Object { Write-Host $_ }

    if (-not $PSCmdlet.ShouldProcess(
        "$Repository release $Tag",
        'Create tag, upload release assets, and publish GitHub Release')) {
        return
    }

    New-Item -ItemType Directory -Force -Path $releaseDirectory | Out-Null
    $releaseChecksums = Join-Path $releaseDirectory 'SHA256SUMS.txt'
    Set-Content -LiteralPath $releaseChecksums -Value $hashLines -Encoding ascii

    $arguments = @(
        'release', 'create', $Tag
    ) + $desktopAssetPaths + @(
        $releaseChecksums
    ) + $esp32AssetPaths + @(
        $esp32StartScriptPath
    ) + @(
        '--repo', $Repository,
        '--target', $Target,
        '--title', $Title
    )
    if ([string]::IsNullOrWhiteSpace($NotesPath)) {
        $arguments += '--generate-notes'
    }
    else {
        $arguments += @('--notes-file', $NotesPath)
    }
    if ($Prerelease) {
        $arguments += '--prerelease'
    }
    if ($Draft) {
        $arguments += '--draft'
    }

    & gh @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub Release creation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
