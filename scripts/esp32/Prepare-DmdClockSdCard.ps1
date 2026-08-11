[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Card')]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,

    [Parameter(Mandatory, ParameterSetName = 'Test', DontShow)]
    [string]$TestRoot,

    [ValidateSet('Original', 'DmdLarge')]
    [string]$Library = 'DmdLarge',

    [string]$SourceDirectory,

    [switch]$RefreshSource,

    [switch]$AllowFixedDrive,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [Parameter(DontShow)]
    [switch]$OnlineSupportFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$localCardTemplateRoot = Join-Path $projectRoot 'firmware\dmdclock-esp32\sdcard\dmd'
$localMetadataPath = Join-Path $projectRoot 'scenes\scene-metadata.json'
$localCatalogPath = Join-Path $projectRoot 'scenes\catalog.json'
$cardTemplateRoot = $null
$metadataPath = $null
$catalogPath = $null
$rawRepositoryRoot = "https://raw.githubusercontent.com/$Repository/master"
$preparationGuide = 'https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/blob/master/docs/PREPARE-ESP32-SD-CARD.md'
$minimumSafetyBytes = 64MB
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockSdCard-' + [Guid]::NewGuid().ToString('N'))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)

function Get-NormalizedRoot {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
}

function Assert-PathBelowRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Description
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = Get-NormalizedRoot $Root
    if (-not $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description resolves outside its required root: $fullPath"
    }

    return $fullPath
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    # Use the framework directly so the caller's WhatIf preference cannot
    # propagate into the provider used by Get-FileHash.
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-CardTarget {
    if ($PSCmdlet.ParameterSetName -eq 'Test') {
        $testBase = Get-NormalizedRoot ([IO.Path]::GetTempPath())
        $resolvedTestRoot = [IO.Path]::GetFullPath($TestRoot)
        if ($resolvedTestRoot.TrimEnd('\') -eq $testBase.TrimEnd('\') -or
            -not $resolvedTestRoot.StartsWith($testBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The internal test target must be a dedicated directory below $testBase"
        }

        [IO.Directory]::CreateDirectory($resolvedTestRoot) | Out-Null
        return [pscustomobject]@{
            Root = Get-NormalizedRoot $resolvedTestRoot
            Volume = $null
            IsTest = $true
        }
    }

    $letter = $DriveLetter.Substring(0, 1).ToUpperInvariant()
    $systemLetter = [IO.Path]::GetPathRoot($env:SystemRoot).Substring(0, 1).ToUpperInvariant()
    if ($letter -eq $systemLetter) {
        throw "Refusing to use the Windows system volume $letter`:"
    }

    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ($volume.FileSystem -ne 'FAT32') {
        throw "Volume $letter`: uses '$($volume.FileSystem)'; DMDClock requires FAT32. The script does not format cards."
    }
    if ($volume.HealthStatus -and $volume.HealthStatus -ne 'Healthy') {
        throw "Volume $letter`: health status is '$($volume.HealthStatus)', not Healthy."
    }
    if ($volume.DriveType -ne 'Removable' -and -not $AllowFixedDrive) {
        throw "Volume $letter`: is reported as '$($volume.DriveType)'. Use -AllowFixedDrive only after confirming it is the SD card."
    }

    $root = Get-NormalizedRoot "$letter`:\"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Volume root is unavailable: $root"
    }

    return [pscustomobject]@{
        Root = $root
        Volume = $volume
        IsTest = $false
    }
}

function Expand-CheckedArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $destinationRoot = Get-NormalizedRoot $Destination
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.FullName)) {
                continue
            }

            $entryName = $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $entryPath = Assert-PathBelowRoot `
                -Path (Join-Path $Destination $entryName) `
                -Root $destinationRoot `
                -Description "Archive entry '$($entry.FullName)'"
            if ([string]::IsNullOrEmpty($entry.Name)) {
                [IO.Directory]::CreateDirectory($entryPath) | Out-Null
                continue
            }

            $entryDirectory = Split-Path -Parent $entryPath
            [IO.Directory]::CreateDirectory($entryDirectory) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Resolve-SceneSource {
    param([Parameter(Mandatory)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $candidate = if ((Split-Path -Leaf $resolved) -ieq 'Scenes') {
        $resolved
    }
    else {
        Join-Path $resolved 'Scenes'
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "The DotClk source does not contain a Scenes directory: $resolved"
    }

    $sceneCount = @(
        Get-ChildItem -LiteralPath $candidate -File -Filter '*.scn' -Recurse
    ).Count
    if ($sceneCount -eq 0) {
        throw "No .scn files were found under $candidate"
    }

    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-LibraryDefinition {
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
        throw "Shared scene catalog not found: $catalogPath"
    }

    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1) {
        throw "Unsupported shared scene catalog schema '$($catalog.schemaVersion)'."
    }

    $packId = if ($Library -eq 'Original') { 'dotclk-original' } else { 'drwize-complete' }
    $matches = @($catalog.packs | Where-Object { [string]$_.packId -eq $packId })
    if ($matches.Count -ne 1) {
        throw "The shared scene catalog must contain exactly one '$packId' entry."
    }

    $entry = $matches[0]
    if (-not [bool]$entry.available -or
        @($entry.supportedPlatforms) -notcontains 'esp32-s3' -or
        [string]$entry.downloadUrl -notmatch '^https://' -or
        [string]$entry.archiveSha256 -notmatch '^[0-9a-fA-F]{64}$' -or
        [long]$entry.downloadBytes -le 0 -or
        [int]$entry.sceneCount -le 0) {
        throw "The '$packId' catalog entry is not a valid ESP32 scene-library download."
    }

    return [pscustomobject]@{
        PackId = [string]$entry.packId
        DisplayName = [string]$entry.displayName
        Version = [string]$entry.version
        DownloadUrl = [string]$entry.downloadUrl
        DownloadBytes = [long]$entry.downloadBytes
        ArchiveSha256 = ([string]$entry.archiveSha256).ToUpperInvariant()
        SceneCount = [int]$entry.sceneCount
        SourceRevision = [string]$entry.sourceRevision
    }
}

function Get-SceneSource {
    param([Parameter(Mandatory)]$Definition)

    if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
        return [pscustomobject]@{
            Scenes = Resolve-SceneSource $SourceDirectory
            ArchiveHash = $null
            Source = [IO.Path]::GetFullPath($SourceDirectory)
        }
    }

    $cacheRoot = Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ) 'DmdClock\cache\scene-libraries'
    $safeVersion = $Definition.Version -replace '[^0-9A-Za-z._-]', '_'
    $cacheArchive = Join-Path $cacheRoot "$($Definition.PackId)-$safeVersion.zip"
    $archivePath = $cacheArchive
    $cacheValid = $false

    if (Test-Path -LiteralPath $cacheArchive -PathType Leaf) {
        $cachedItem = Get-Item -LiteralPath $cacheArchive
        $cachedHash = Get-Sha256 $cacheArchive
        $cacheValid = $cachedItem.Length -eq $Definition.DownloadBytes -and
            $cachedHash -eq $Definition.ArchiveSha256
        if (-not $cacheValid) {
            Write-Warning "Ignoring an invalid cached archive: $cacheArchive"
        }
    }

    if ($RefreshSource -or -not $cacheValid) {
        $downloadPath = Join-Path $temporaryRoot "$($Definition.PackId)-download.zip"
        Write-Host "Downloading $($Definition.DisplayName) v$($Definition.Version)..."
        Invoke-WebRequest -Uri $Definition.DownloadUrl -OutFile $downloadPath
        $downloadItem = Get-Item -LiteralPath $downloadPath
        $downloadHash = Get-Sha256 $downloadPath
        if ($downloadItem.Length -ne $Definition.DownloadBytes) {
            throw (
                "Downloaded archive size mismatch. Expected $($Definition.DownloadBytes) " +
                "bytes; received $($downloadItem.Length).")
        }
        if ($downloadHash -ne $Definition.ArchiveSha256) {
            throw (
                "Downloaded archive SHA-256 mismatch. Expected " +
                "$($Definition.ArchiveSha256); received $downloadHash.")
        }

        $archivePath = $downloadPath
        if (-not $WhatIfPreference -and
            $PSCmdlet.ShouldProcess($cacheArchive, 'Cache the verified scene-library archive')) {
            [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
            $cacheTemporary = Join-Path $cacheRoot (
                '.' + $Definition.PackId + '-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Item -LiteralPath $downloadPath -Destination $cacheTemporary
            Move-Item -LiteralPath $cacheTemporary -Destination $cacheArchive -Force
            $archivePath = $cacheArchive
        }
    }
    else {
        Write-Host "Using verified cached archive: $cacheArchive"
    }

    $expandedRoot = Join-Path $temporaryRoot 'source'
    Expand-CheckedArchive -ArchivePath $archivePath -Destination $expandedRoot
    $resourceRoot = Get-ChildItem -LiteralPath $expandedRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Scenes') } |
        Select-Object -First 1
    if ($null -eq $resourceRoot) {
        throw 'The downloaded archive does not contain the expected Scenes directory.'
    }

    return [pscustomobject]@{
        Scenes = Resolve-SceneSource $resourceRoot.FullName
        ArchiveHash = Get-Sha256 $archivePath
        Source = $Definition.DownloadUrl
    }
}

function Test-SceneLibrary {
    param([Parameter(Mandatory)][string]$ScenesPath)

    $files = @(Get-ChildItem -LiteralPath $ScenesPath -File -Filter '*.scn' -Recurse)
    $rejected = [Collections.Generic.List[string]]::new()
    $warned = 0
    Write-Host "Validating every SCN file with the built-in validator..."
    for ($index = 0; $index -lt $files.Count; $index++) {
        $file = $files[$index]
        if (($index % 100) -eq 0) {
            Write-Progress -Activity 'Validating SCN files' `
                -Status "$index of $($files.Count)" `
                -PercentComplete $(if ($files.Count) { ($index * 100) / $files.Count } else { 100 })
        }
        $stream = $null
        $reader = $null
        try {
            $stream = [IO.File]::OpenRead($file.FullName)
            $reader = [IO.BinaryReader]::new($stream)
            if ($stream.Length -lt 6) { throw 'header is truncated' }
            $version = $reader.ReadUInt16()
            $frameCount = $reader.ReadUInt16()
            $storyboardCount = $reader.ReadUInt16()
            if ($version -ne 1) { throw "unsupported version $version" }
            if ($frameCount -eq 0 -or $frameCount -gt 10000) {
                throw "invalid frame count $frameCount"
            }
            if ($storyboardCount -gt 10000) {
                throw "invalid storyboard count $storyboardCount"
            }

            $hasWarning = $storyboardCount -eq 0
            for ($storyboardIndex = 0; $storyboardIndex -lt $storyboardCount; $storyboardIndex++) {
                $values = @()
                for ($valueIndex = 0; $valueIndex -lt 8; $valueIndex++) {
                    $values += $reader.ReadUInt16()
                }
                foreach ($flagIndex in @(1, 2, 4, 6, 7)) {
                    if ($values[$flagIndex] -notin @(0, 1)) {
                        throw "storyboard $storyboardIndex has invalid flag $($values[$flagIndex])"
                    }
                }
                $firstFrameIsConsumed = $values[0] -gt 0 -and $values[2] -eq 0
                $regularFrameCount = $frameCount - $(if ($firstFrameIsConsumed) { 1 } else { 0 })
                if ($values[3] -eq 0 -and $regularFrameCount -gt 0) {
                    $hasWarning = $true
                }
                if ($reader.ReadBytes(20).Count -ne 20) {
                    throw "storyboard $storyboardIndex is truncated"
                }
            }
            if ($storyboardCount -gt 1) { $hasWarning = $true }

            for ($frameIndex = 0; $frameIndex -lt $frameCount; $frameIndex++) {
                $width = $reader.ReadUInt16()
                $height = $reader.ReadUInt16()
                $bitsPerPixel = $reader.ReadUInt16()
                $hasMask = $reader.ReadUInt16()
                if ($width -ne 128 -or $height -ne 32 -or $bitsPerPixel -ne 4) {
                    throw "frame $frameIndex has unsupported geometry ${width}x${height} at $bitsPerPixel bpp"
                }
                if ($hasMask -notin @(0, 1)) {
                    throw "frame $frameIndex has invalid mask flag $hasMask"
                }
                $payloadBytes = 2048 + $(if ($hasMask -eq 1) { 512 } else { 0 })
                if (($stream.Length - $stream.Position) -lt $payloadBytes) {
                    throw "frame $frameIndex is truncated"
                }
                $stream.Position += $payloadBytes
            }
            if ($stream.Position -ne $stream.Length) {
                throw "$($stream.Length - $stream.Position) unexpected trailing bytes"
            }
            if ($hasWarning) { $warned++ }
        }
        catch {
            $rejected.Add("$($file.Name): $($_.Exception.Message)")
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            elseif ($null -ne $stream) { $stream.Dispose() }
        }
    }
    Write-Progress -Activity 'Validating SCN files' -Completed
    Write-Host "Files: $($files.Count)"
    Write-Host "Accepted: $($files.Count - $rejected.Count)"
    Write-Host "Warned: $warned"
    Write-Host "Rejected: $($rejected.Count)"
    if ($rejected.Count -gt 0) {
        $details = @($rejected | Select-Object -First 20) -join [Environment]::NewLine
        throw "SCN validation rejected $($rejected.Count) file(s):`n$details"
    }
}

function Get-SupportFile {
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RepositoryPath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    if (-not $OnlineSupportFiles -and
        (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        return (Resolve-Path -LiteralPath $LocalPath).Path
    }

    $uri = [uri]("$rawRepositoryRoot/$RepositoryPath")
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'raw.githubusercontent.com') {
        throw "Refusing support-file download from '$uri'."
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Destination)) | Out-Null
    Write-Host "Downloading support file $RepositoryPath..."
    Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'DMDClock-SD-Card-Preparation' }
    $size = (Get-Item -LiteralPath $Destination).Length
    if ($size -le 0 -or $size -gt $MaximumBytes) {
        throw "Downloaded support file '$RepositoryPath' has invalid size $size."
    }
    return $Destination
}

function Initialize-SupportFiles {
    $supportRoot = Join-Path $temporaryRoot 'support'
    $templateRoot = Join-Path $supportRoot 'card-template'
    $resolvedCatalog = Get-SupportFile `
        -LocalPath $localCatalogPath `
        -RepositoryPath 'scenes/catalog.json' `
        -Destination (Join-Path $supportRoot 'catalog.json') `
        -MaximumBytes 1MB
    $resolvedMetadata = Get-SupportFile `
        -LocalPath $localMetadataPath `
        -RepositoryPath 'scenes/scene-metadata.json' `
        -Destination (Join-Path $supportRoot 'scene-metadata.json') `
        -MaximumBytes 4MB
    $resolvedTemplateRoot = $localCardTemplateRoot
    if ($OnlineSupportFiles -or
        -not (Test-Path -LiteralPath (Join-Path $localCardTemplateRoot 'manifest.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $localCardTemplateRoot 'README.md') -PathType Leaf)) {
        $resolvedTemplateRoot = $templateRoot
        foreach ($templateName in @('manifest.json', 'README.md')) {
            $null = Get-SupportFile `
                -LocalPath (Join-Path $supportRoot 'missing-local-file') `
                -RepositoryPath "firmware/dmdclock-esp32/sdcard/dmd/$templateName" `
                -Destination (Join-Path $templateRoot $templateName) `
                -MaximumBytes 1MB
        }
    }
    return [pscustomobject]@{
        Catalog = $resolvedCatalog
        Metadata = $resolvedMetadata
        CardTemplate = $resolvedTemplateRoot
    }
}

function Get-ManagedFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RelativeTarget,
        [Parameter(Mandatory)][ValidateSet('Scene', 'Metadata', 'Template', 'Manifest')]
        [string]$Category
    )

    $item = Get-Item -LiteralPath $SourcePath
    return [pscustomobject]@{
        SourcePath = $item.FullName
        RelativeTarget = $RelativeTarget.Replace('/', '\')
        Category = $Category
        Length = $item.Length
        Hash = Get-Sha256 $item.FullName
    }
}

function Install-FileAtomically {
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$CardRoot
    )

    $destination = Assert-PathBelowRoot `
        -Path (Join-Path $CardRoot $File.RelativeTarget) `
        -Root $CardRoot `
        -Description "Destination '$($File.RelativeTarget)'"
    $destinationDirectory = Split-Path -Parent $destination
    [IO.Directory]::CreateDirectory($destinationDirectory) | Out-Null
    $temporaryName = '.' + [IO.Path]::GetFileName($destination) +
        '.dmdtmp-' + [Guid]::NewGuid().ToString('N')
    $temporaryPath = Join-Path $destinationDirectory $temporaryName

    try {
        Copy-Item -LiteralPath $File.SourcePath -Destination $temporaryPath
        $copiedHash = Get-Sha256 $temporaryPath
        if ($copiedHash -ne $File.Hash) {
            throw "Hash verification failed while staging $($File.RelativeTarget)"
        }
        Move-Item -LiteralPath $temporaryPath -Destination $destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-PreviouslyManagedScenePaths {
    param([Parameter(Mandatory)][string]$CardRoot)

    $candidateManifests = @(
        @{ Path = 'dmd\config\scene-library-manifest.json'; Prefix = '' },
        @{ Path = 'dmd\config\dotclk-scenes-manifest.json'; Prefix = '' },
        @{ Path = 'dmd\scenes\scene-pack-content.json'; Prefix = 'Scenes/' }
    )
    foreach ($candidate in $candidateManifests) {
        $path = Join-Path $CardRoot $candidate.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        try {
            $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $paths = [Collections.Generic.HashSet[string]]::new(
                [StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($manifest.files)) {
                $relative = [string]$entry.path
                if ($candidate.Prefix -and
                    $relative.StartsWith($candidate.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $relative.Substring($candidate.Prefix.Length)
                }
                if ($relative -and $relative -notmatch '(^|/)\.\.(/|$)' -and
                    $relative -match '\.scn$') {
                    [void]$paths.Add($relative.Replace('\', '/'))
                }
            }
            if ($paths.Count -gt 0) {
                return $paths
            }
        }
        catch {
            Write-Warning "Ignoring unreadable previous library manifest '$path'."
        }
    }

    return [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
}

[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $supportFiles = Initialize-SupportFiles
    $catalogPath = $supportFiles.Catalog
    $metadataPath = $supportFiles.Metadata
    $cardTemplateRoot = $supportFiles.CardTemplate
    if (-not (Test-Path -LiteralPath $cardTemplateRoot -PathType Container)) {
        throw "Card template not found: $cardTemplateRoot"
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Scene metadata not found: $metadataPath"
    }

    $definition = Get-LibraryDefinition
    $target = Get-CardTarget
    Write-Host "Library: $($definition.DisplayName) v$($definition.Version) ($($definition.SceneCount) scenes)"
    Write-Host "Target: $($target.Root)"
    Write-Host "Instructions: $preparationGuide"
    if (-not $target.IsTest) {
        Write-Host (
            "Volume: FAT32, $($target.Volume.DriveType), " +
            "$([Math]::Round($target.Volume.Size / 1GB, 2)) GiB")
    }

    $source = Get-SceneSource -Definition $definition
    Test-SceneLibrary $source.Scenes

    $managed = [Collections.Generic.List[object]]::new()
    $sceneManifestEntries = [Collections.Generic.List[object]]::new()
    $sourceRoot = Get-NormalizedRoot $source.Scenes
    $sceneFiles = Get-ChildItem -LiteralPath $source.Scenes -File -Filter '*.scn' -Recurse |
        Sort-Object FullName
    if ($sceneFiles.Count -ne $definition.SceneCount) {
        throw (
            "Scene count mismatch for $($definition.DisplayName). Expected " +
            "$($definition.SceneCount); found $($sceneFiles.Count).")
    }
    foreach ($sceneFile in $sceneFiles) {
        $relative = $sceneFile.FullName.Substring($sourceRoot.Length).Replace('\', '/')
        $managedFile = Get-ManagedFile `
            -SourcePath $sceneFile.FullName `
            -RelativeTarget "dmd/scenes/$relative" `
            -Category Scene
        $managed.Add($managedFile)
        $sceneManifestEntries.Add([ordered]@{
            path = $relative
            size = $managedFile.Length
            sha256 = $managedFile.Hash
        })
    }

    $sourceMetadataPath = Join-Path $source.Scenes 'scene-metadata.json'
    if (-not (Test-Path -LiteralPath $sourceMetadataPath -PathType Leaf)) {
        $sourceMetadataPath = $metadataPath
    }
    $managed.Add((Get-ManagedFile `
        -SourcePath $sourceMetadataPath `
        -RelativeTarget 'dmd/scenes/scene-metadata.json' `
        -Category Metadata))
    foreach ($templateName in @('manifest.json', 'README.md')) {
        $managed.Add((Get-ManagedFile `
            -SourcePath (Join-Path $cardTemplateRoot $templateName) `
            -RelativeTarget "dmd/$templateName" `
            -Category Template))
    }

    $contentManifest = [ordered]@{
        schema = 'dmdclock-scene-library'
        version = 1
        packId = $definition.PackId
        displayName = $definition.DisplayName
        libraryVersion = $definition.Version
        sourceRevision = $definition.SourceRevision
        source = $source.Source
        sourceArchiveSha256 = $source.ArchiveHash
        fileCount = $sceneManifestEntries.Count
        files = $sceneManifestEntries
    }
    $manifestPath = Join-Path $temporaryRoot 'scene-library-manifest.json'
    $manifestJson = $contentManifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText(
        $manifestPath,
        $manifestJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    $managed.Add((Get-ManagedFile `
        -SourcePath $manifestPath `
        -RelativeTarget 'dmd/config/scene-library-manifest.json' `
        -Category Manifest))

    $installedLibrary = [ordered]@{
        packId = $definition.PackId
        displayName = $definition.DisplayName
        version = $definition.Version
        sceneCount = $definition.SceneCount
    }
    $installedLibraryPath = Join-Path $temporaryRoot 'scene-library-installed.json'
    [IO.File]::WriteAllText(
        $installedLibraryPath,
        (($installedLibrary | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false))
    $managed.Add((Get-ManagedFile `
        -SourcePath $installedLibraryPath `
        -RelativeTarget 'dmd/config/scene-pack-installed.json' `
        -Category Manifest))

    $directories = @(
        'dmd',
        'dmd\backups',
        'dmd\cache',
        'dmd\config',
        'dmd\downloads',
        'dmd\fonts',
        'dmd\logs',
        'dmd\plasma',
        'dmd\scenes',
        'dmd\web'
    )
    $counts = [ordered]@{
        Unchanged = 0
        Added = 0
        Repaired = 0
        Updated = 0
        Removed = 0
        Preserved = 0
    }
    $copyBytes = [long]0
    foreach ($file in $managed) {
        $destination = Assert-PathBelowRoot `
            -Path (Join-Path $target.Root $file.RelativeTarget) `
            -Root $target.Root `
            -Description "Destination '$($file.RelativeTarget)'"
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            $counts.Added++
            $copyBytes += $file.Length
            continue
        }

        $destinationItem = Get-Item -LiteralPath $destination
        $matches = $destinationItem.Length -eq $file.Length -and
            (Get-Sha256 $destination) -eq $file.Hash
        if ($matches) {
            $counts.Unchanged++
        }
        elseif ($file.Category -eq 'Scene') {
            $counts.Repaired++
            $copyBytes += $file.Length
        }
        else {
            $counts.Updated++
            $copyBytes += $file.Length
        }
    }

    $managedScenePaths = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $managed | Where-Object Category -eq 'Scene') {
        [void]$managedScenePaths.Add($file.RelativeTarget.Replace('\', '/'))
    }
    $previousManagedPaths = Get-PreviouslyManagedScenePaths -CardRoot $target.Root
    $obsoleteManagedFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $previousManagedPaths) {
        $managedRelative = "dmd/scenes/$relative"
        if (-not $managedScenePaths.Contains($managedRelative)) {
            $obsoletePath = Assert-PathBelowRoot `
                -Path (Join-Path $target.Root $managedRelative) `
                -Root $target.Root `
                -Description "Previously managed scene '$relative'"
            if (Test-Path -LiteralPath $obsoletePath -PathType Leaf) {
                [void]$obsoleteManagedFiles.Add($obsoletePath)
                $counts.Removed++
            }
        }
    }
    $targetScenes = Join-Path $target.Root 'dmd\scenes'
    if (Test-Path -LiteralPath $targetScenes -PathType Container) {
        $targetRootNormalized = Get-NormalizedRoot $target.Root
        foreach ($existing in Get-ChildItem -LiteralPath $targetScenes -File -Recurse) {
            $relativeExisting = $existing.FullName.Substring(
                $targetRootNormalized.Length).Replace('\', '/')
            if ($relativeExisting -ne 'dmd/scenes/scene-metadata.json' -and
                -not $obsoleteManagedFiles.Contains($existing.FullName) -and
                -not $managedScenePaths.Contains($relativeExisting)) {
                $counts.Preserved++
            }
        }
    }

    if (-not $target.IsTest -and $copyBytes -gt 0) {
        $requiredBytes = $copyBytes + $minimumSafetyBytes
        if ($target.Volume.SizeRemaining -lt $requiredBytes) {
            throw (
                "Insufficient free space. Required including safety margin: " +
                "$([Math]::Round($requiredBytes / 1MB, 1)) MiB; available: " +
                "$([Math]::Round($target.Volume.SizeRemaining / 1MB, 1)) MiB.")
        }
    }

    Write-Host ''
    Write-Host "Plan:"
    Write-Host "  Unchanged: $($counts.Unchanged)"
    Write-Host "  Added:     $($counts.Added)"
    Write-Host "  Repaired:  $($counts.Repaired)"
    Write-Host "  Updated:   $($counts.Updated)"
    Write-Host "  Removed:   $($counts.Removed)"
    Write-Host "  Preserved: $($counts.Preserved)"
    Write-Host "  Write:     $([Math]::Round($copyBytes / 1MB, 1)) MiB"

    $changeCount = $counts.Added + $counts.Repaired + $counts.Updated + $counts.Removed
    if ($changeCount -eq 0) {
        Write-Host 'The card is already up to date; no files were written.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
        $target.Root,
        "Synchronize $($sceneFiles.Count) scenes for $($definition.DisplayName) and the DMDClock card layout")) {
        return
    }

    foreach ($directory in $directories) {
        $directoryPath = Assert-PathBelowRoot `
            -Path (Join-Path $target.Root $directory) `
            -Root $target.Root `
            -Description "Directory '$directory'"
        [IO.Directory]::CreateDirectory($directoryPath) | Out-Null
    }
    foreach ($file in $managed | Where-Object Category -ne 'Manifest') {
        $destination = Join-Path $target.Root $file.RelativeTarget
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationItem = Get-Item -LiteralPath $destination
            if ($destinationItem.Length -eq $file.Length -and
                (Get-Sha256 $destination) -eq $file.Hash) {
                continue
            }
        }

        Install-FileAtomically -File $file -CardRoot $target.Root
    }

    foreach ($obsoletePath in $obsoleteManagedFiles) {
        Remove-Item -LiteralPath $obsoletePath -Force
    }
    foreach ($file in $managed | Where-Object Category -eq 'Manifest') {
        $destination = Join-Path $target.Root $file.RelativeTarget
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationItem = Get-Item -LiteralPath $destination
            if ($destinationItem.Length -eq $file.Length -and
                (Get-Sha256 $destination) -eq $file.Hash) {
                continue
            }
        }

        Install-FileAtomically -File $file -CardRoot $target.Root
    }
    $legacyManifest = Join-Path $target.Root 'dmd\config\dotclk-scenes-manifest.json'
    if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
        Remove-Item -LiteralPath $legacyManifest -Force
    }

    Write-Host ''
    Write-Host (
        "SD card preparation complete: added $($counts.Added), " +
        "repaired $($counts.Repaired), updated $($counts.Updated), " +
        "removed $($counts.Removed), unchanged $($counts.Unchanged), " +
        "preserved $($counts.Preserved).")
}
finally {
    $temporaryBase = Get-NormalizedRoot ([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $temporaryRoot) -and
        $temporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -WhatIf:$false
    }
}
