# END-USER SCRIPT - prepares a DMDClock microSD card on Windows 11 x64 / PowerShell 7,
# or reports that the card is already up to date. Usually driven by RUNME-Install-DmdClockEsp32.ps1.
# See docs\INSTALL-ESP32.md. Developer tooling lives in scripts\esp32\dev; tests in scripts\esp32\tests.
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Card')]
param(
    [Parameter(Position = 0, ParameterSetName = 'Card')]
    [ValidateRange(0, 999)]
    [int]$DiskNumber,

    [Parameter(ParameterSetName = 'Card')]
    [switch]$Wizard,

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch]$ListDisks,

    [Parameter(Mandatory, ParameterSetName = 'Test', DontShow)]
    [string]$TestRoot,

    [Parameter(Mandatory, ParameterSetName = 'Check')]
    [switch]$CheckRequirements,

    [Parameter(Mandatory, ParameterSetName = 'Stage')]
    [Parameter(ParameterSetName = 'Check')]
    [Parameter(ParameterSetName = 'Card')]
    [Parameter(ParameterSetName = 'Test')]
    [Parameter(ParameterSetName = 'List')]
    [string]$Destination,

    [Parameter(Mandatory, ParameterSetName = 'Stage')]
    [switch]$DownloadOnly,

    [ValidateSet('Original', 'DmdLarge')]
    [string]$Library = 'DmdLarge',

    [string]$SourceDirectory,

    [Alias('Source')]
    [string]$StagingSource,

    [switch]$RefreshSource,

    [switch]$DryRun,

    [switch]$AllowFixedDrive,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [Parameter(DontShow)]
    [switch]$OnlineSupportFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DryRun) { $WhatIfPreference = $true }

$provisioningModule = Join-Path $PSScriptRoot 'DmdClock.Provisioning.psm1'
if (-not (Test-Path -LiteralPath $provisioningModule -PathType Leaf)) {
    throw "Shared provisioning module not found: $provisioningModule"
}
Import-Module $provisioningModule -Force

function Test-DmdClockShouldProcess {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action
    )

    if ($WhatIfPreference) {
        Write-Host "What if: Performing the operation `"$Action`" on target `"$Target`"."
        return $false
    }
    if ([Console]::IsInputRedirected) {
        return $true
    }
    return $PSCmdlet.ShouldProcess($Target, $Action)
}

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$localCardTemplateRoot = Join-Path $projectRoot 'firmware\dmdclock-esp32\sdcard\dmd'
$localFontRoot = Join-Path $projectRoot 'assets\fonts\DotClk'
$localMetadataPath = Join-Path $projectRoot 'scenes\scene-metadata.json'
$localCatalogPath = Join-Path $projectRoot 'scenes\catalog.json'
$cardTemplateRoot = $null
$metadataPath = $null
$catalogPath = $null
$stagedSourceInfo = $null
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

function Get-CardTarget {
    if ($PSCmdlet.ParameterSetName -eq 'Test') {
        $testBase = Get-NormalizedRoot ([IO.Path]::GetTempPath())
        $resolvedTestRoot = [IO.Path]::GetFullPath($TestRoot)
        if ($resolvedTestRoot.TrimEnd('\') -eq $testBase.TrimEnd('\') -or
            -not $resolvedTestRoot.StartsWith($testBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The internal test target must be a dedicated directory below $testBase"
        }

        if (-not $WhatIfPreference) {
            [IO.Directory]::CreateDirectory($resolvedTestRoot) | Out-Null
        }
        return [pscustomobject]@{
            Root = Get-NormalizedRoot $resolvedTestRoot
            Volume = $null
            IsTest = $true
        }
    }

    $snapshot = Get-DmdClockDiskSnapshot -Number $DiskNumber
    if (-not $snapshot.IsCandidate) {
        throw "Refusing Disk $DiskNumber`: $($snapshot.ExclusionReason)"
    }
    $mountedVolumes = @($snapshot.Volumes | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.DriveLetter)
    })
    if ($mountedVolumes.Count -ne 1) {
        throw "Disk $DiskNumber must expose exactly one mounted volume; found $($mountedVolumes.Count)."
    }
    $volumeInfo = $mountedVolumes[0]
    $letter = ([string]$volumeInfo.DriveLetter).ToUpperInvariant()
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    if ($volume.FileSystem -ne 'FAT32') {
        throw (
            "Disk $DiskNumber volume $letter`: uses '$($volume.FileSystem)'; DMDClock requires FAT32. " +
            "Creating and formatting the card are outside this script. Follow $preparationGuide, " +
            "then run -ListDisks again.")
    }
    if ($volume.HealthStatus -and $volume.HealthStatus -ne 'Healthy') {
        throw "Volume $letter`: health status is '$($volume.HealthStatus)', not Healthy."
    }
    if ($volume.DriveType -ne 'Removable' -and -not $AllowFixedDrive) {
        throw "Volume $letter`: is reported as '$($volume.DriveType)'. Use -AllowFixedDrive only after confirming it is the microSD card."
    }

    $root = Get-NormalizedRoot "$letter`:\"
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Volume root is unavailable: $root"
    }

    return [pscustomobject]@{
        Root = $root
        Volume = $volume
        IsTest = $false
        DiskNumber = $DiskNumber
        DiskSnapshot = $snapshot
    }
}

function Get-DmdClockDiskSnapshot {
    param([Parameter(Mandatory)][int] $Number)

    $disk = Get-Disk -Number $Number -ErrorAction Stop
    $partitions = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue |
        Sort-Object PartitionNumber)
    $volumeRecords = [Collections.Generic.List[object]]::new()
    foreach ($partition in $partitions) {
        $volume = $null
        try { $volume = $partition | Get-Volume -ErrorAction Stop } catch { $volume = $null }
        if ($null -ne $volume) {
            $volumeRecords.Add([pscustomobject]@{
                PartitionNumber = [int]$partition.PartitionNumber
                DriveLetter = [string]$volume.DriveLetter
                Label = [string]$volume.FileSystemLabel
                FileSystem = [string]$volume.FileSystem
                Size = [long]$volume.Size
            })
        }
    }
    $systemDisk = $disk.IsSystem -or $disk.IsBoot -or
        @($partitions | Where-Object { $_.IsSystem -or $_.IsBoot }).Count -gt 0
    $externalBus = [string]$disk.BusType -in @('USB', 'SD', 'MMC')
    $healthy = -not $disk.IsOffline -and -not $disk.IsReadOnly -and
        @($disk.OperationalStatus) -contains 'Online'
    $exclusion = if ($systemDisk) {
        'it contains a Windows system or boot partition'
    } elseif (-not $externalBus) {
        "bus type '$($disk.BusType)' is not USB, SD, or MMC"
    } elseif (-not $healthy) {
        "it is offline, read-only, or not operational (status: $($disk.OperationalStatus -join ', '))"
    } else { '' }
    $topology = @($partitions | ForEach-Object {
        '{0}:{1}:{2}:{3}:{4}' -f $_.PartitionNumber, $_.Offset, $_.Size,
            $_.DriveLetter, $_.Type
    }) -join '|'
    $volumeTopology = @($volumeRecords | ForEach-Object {
        '{0}:{1}:{2}:{3}:{4}' -f $_.PartitionNumber, $_.DriveLetter,
            $_.Label, $_.FileSystem, $_.Size
    }) -join '|'
    return [pscustomobject]@{
        Number = [int]$disk.Number
        FriendlyName = [string]$disk.FriendlyName
        SerialNumber = ([string]$disk.SerialNumber).Trim()
        UniqueId = ([string]$disk.UniqueId).Trim()
        Size = [long]$disk.Size
        BusType = [string]$disk.BusType
        PartitionStyle = [string]$disk.PartitionStyle
        Topology = "$topology#volumes=$volumeTopology"
        IsCandidate = [string]::IsNullOrWhiteSpace($exclusion)
        ExclusionReason = $exclusion
        Volumes = @($volumeRecords)
    }
}

function Get-DmdClockDiskCandidates {
    $snapshots = [Collections.Generic.List[object]]::new()
    foreach ($disk in @(Get-Disk | Sort-Object Number)) {
        try {
            $snapshots.Add((Get-DmdClockDiskSnapshot -Number ([int]$disk.Number)))
        }
        catch {
            Write-Warning "Disk $($disk.Number) could not be inspected: $($_.Exception.Message)"
        }
    }
    return @($snapshots)
}

function Show-DmdClockDiskCandidates {
    $snapshots = @(Get-DmdClockDiskCandidates)
    Write-Host ''
    Write-Host 'Physical disks (no disk is selected automatically):' -ForegroundColor Cyan
    foreach ($snapshot in $snapshots) {
        $state = if ($snapshot.IsCandidate) { 'CANDIDATE' } else { 'EXCLUDED' }
        $color = if ($snapshot.IsCandidate) { 'Green' } else { 'DarkGray' }
        Write-Host ("  Disk {0} - {1} - {2:N1} GB - {3} - {4}" -f
            $snapshot.Number, $snapshot.FriendlyName, ($snapshot.Size / 1GB),
            $snapshot.BusType, $state) -ForegroundColor $color
        foreach ($volume in $snapshot.Volumes) {
            $letter = if ($volume.DriveLetter) { "$($volume.DriveLetter):" } else { '(not mounted)' }
            Write-Host ("    Partition {0}: {1}, label='{2}', {3}, {4:N1} GB" -f
                $volume.PartitionNumber, $letter, $volume.Label,
                $volume.FileSystem, ($volume.Size / 1GB))
        }
        if (-not $snapshot.IsCandidate) {
            Write-Host "    Excluded: $($snapshot.ExclusionReason)" -ForegroundColor DarkGray
        }
    }
    Write-Host 'Rerun with -DiskNumber N only after matching the model, size, bus, partitions, and volume.'
}

function Invoke-CardWizard {
    $state = New-DmdClockWizard -Title 'DMDClock microSD card preparation'

    Show-DmdClockWizardHeader -Wizard $state
    Write-Host 'Scene library:'
    Write-Host '  [1] DMD-Large (Recommended)' -ForegroundColor Green
    Write-Host '  [2] Original DotCLK-Orig'
    $libraryChoice = Read-DmdClockMenuChoice -Prompt 'Select scene library' `
        -Minimum 1 -Maximum 2 -Default 1 -RequiredParameter '-Library'
    $library = if ($libraryChoice -eq 1) { 'DmdLarge' } else { 'Original' }
    Add-DmdClockWizardSelection -Wizard $state -Label 'Library' -Value $library

    $candidates = @(Get-DmdClockDiskCandidates | Where-Object IsCandidate)
    if ($candidates.Count -eq 0) {
        Show-DmdClockDiskCandidates
        Write-Host ''
        Write-Host 'No eligible external microSD card was found. Insert a FAT32 card and rerun.' -ForegroundColor Yellow
        return $null
    }

    Show-DmdClockWizardHeader -Wizard $state
    Write-Host 'Select the microSD card (physical disk):'
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        $candidate = $candidates[$index]
        Write-Host ("  [{0}] Disk {1} - {2} - {3:N1} GB - {4}" -f
            ($index + 1), $candidate.Number, $candidate.FriendlyName,
            ($candidate.Size / 1GB), $candidate.BusType)
        foreach ($volume in $candidate.Volumes) {
            $letter = if ($volume.DriveLetter) { "$($volume.DriveLetter):" } else { '(not mounted)' }
            Write-Host ("      Partition {0}: {1}, label='{2}', {3}, {4:N1} GB" -f
                $volume.PartitionNumber, $letter, $volume.Label,
                $volume.FileSystem, ($volume.Size / 1GB))
        }
    }
    $choice = Read-DmdClockMenuChoice -Prompt 'Select the microSD card' `
        -Minimum 1 -Maximum $candidates.Count -RequiredParameter '-DiskNumber'
    $target = $candidates[$choice - 1]
    Add-DmdClockWizardSelection -Wizard $state -Label 'Disk' `
        -Value "Disk $($target.Number) - $($target.FriendlyName)"
    $mounted = @($target.Volumes | Where-Object { $_.DriveLetter })
    if ($mounted.Count -gt 0) {
        Add-DmdClockWizardSelection -Wizard $state -Label 'Drive' `
            -Value "$($mounted[0].DriveLetter):"
    }

    Show-DmdClockWizardHeader -Wizard $state
    return @{
        DiskNumber = [int]$target.Number
        Library = $library
    }
}

function Assert-DmdClockDiskUnchanged {
    param([Parameter(Mandatory)] $Original)

    $current = Get-DmdClockDiskSnapshot -Number ([int]$Original.Number)
    foreach ($property in @(
        'Number', 'FriendlyName', 'SerialNumber', 'UniqueId', 'Size',
        'BusType', 'PartitionStyle', 'Topology')) {
        if ([string]$current.$property -cne [string]$Original.$property) {
            throw "Disk identity/topology changed before synchronization (field: $property). Remove and reinsert the intended card, list disks again, and restart."
        }
    }
    if (-not $current.IsCandidate) {
        throw "Disk $($Original.Number) is no longer an eligible external disk: $($current.ExclusionReason)"
    }
    Write-Host "[OK] Revalidated Disk $($current.Number) identity and topology immediately before synchronization." -ForegroundColor Green
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
            $entryPath = Assert-DmdClockPathBelowRoot `
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

    if ($null -ne $stagedSourceInfo) {
        $artifactId = if ($Library -eq 'Original') {
            'sd.library.dotclk-original'
        } else {
            'sd.library.drwize-complete'
        }
        $artifact = $stagedSourceInfo.Artifacts[$artifactId]
        $archivePath = [string]$artifact.ResolvedPath
        if ([long]$artifact.size -ne $Definition.DownloadBytes -or
            ([string]$artifact.sha256).ToUpperInvariant() -ne $Definition.ArchiveSha256 -or
            [string]$artifact.version -ne $Definition.Version) {
            throw "Staged artifact '$artifactId' is stale or does not match the staged catalog."
        }
        $expandedRoot = Join-Path $temporaryRoot 'source'
        Expand-CheckedArchive -ArchivePath $archivePath -Destination $expandedRoot
        $resourceRoot = Get-ChildItem -LiteralPath $expandedRoot -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Scenes') } |
            Select-Object -First 1
        if ($null -eq $resourceRoot) {
            throw "Staged archive '$artifactId' does not contain the expected Scenes directory."
        }
        return [pscustomobject]@{
            Scenes = Resolve-SceneSource $resourceRoot.FullName
            ArchiveHash = Get-DmdClockSha256 $archivePath
            Source = $archivePath
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
        $cachedHash = Get-DmdClockSha256 $cacheArchive
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
        $downloadHash = Get-DmdClockSha256 $downloadPath
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
        if (Test-DmdClockShouldProcess -Target $cacheArchive -Action 'Cache the verified scene-library archive') {
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
        ArchiveHash = Get-DmdClockSha256 $archivePath
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
    if ($null -ne $stagedSourceInfo) {
        return [pscustomobject]@{
            Catalog = [string]$stagedSourceInfo.Artifacts['sd.catalog'].ResolvedPath
            Metadata = [string]$stagedSourceInfo.Artifacts['sd.scene-metadata'].ResolvedPath
            CardTemplate = Split-Path -Parent (
                [string]$stagedSourceInfo.Artifacts['sd.template.manifest'].ResolvedPath)
            Fonts = Split-Path -Parent (
                [string]$stagedSourceInfo.Artifacts['sd.font.altern8'].ResolvedPath)
        }
    }

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
    $resolvedFontRoot = $localFontRoot
    $fontNames = @('ALTERN8.fnt', 'FISHY.fnt', 'TREK.fnt', 'TWILIGHT.fnt')
    $localFontsAvailable = @(
        $fontNames | Where-Object {
            Test-Path -LiteralPath (Join-Path $localFontRoot $_) -PathType Leaf
        }).Count -eq $fontNames.Count
    if ($OnlineSupportFiles -or -not $localFontsAvailable) {
        $resolvedFontRoot = Join-Path $supportRoot 'fonts'
        foreach ($fontName in $fontNames) {
            $null = Get-SupportFile `
                -LocalPath (Join-Path $supportRoot 'missing-local-file') `
                -RepositoryPath "assets/fonts/DotClk/$fontName" `
                -Destination (Join-Path $resolvedFontRoot $fontName) `
                -MaximumBytes 96KB
        }
    }
    return [pscustomobject]@{
        Catalog = $resolvedCatalog
        Metadata = $resolvedMetadata
        CardTemplate = $resolvedTemplateRoot
        Fonts = $resolvedFontRoot
    }
}

function Get-ManagedFile {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$RelativeTarget,
        [Parameter(Mandatory)][ValidateSet('Scene', 'Metadata', 'Template', 'Manifest', 'Font')]
        [string]$Category
    )

    $item = Get-Item -LiteralPath $SourcePath
    return [pscustomobject]@{
        SourcePath = $item.FullName
        RelativeTarget = $RelativeTarget.Replace('/', '\')
        Category = $Category
        Length = $item.Length
        Hash = Get-DmdClockSha256 $item.FullName
    }
}

function Install-FileAtomically {
    param(
        [Parameter(Mandatory)]$File,
        [Parameter(Mandatory)][string]$CardRoot
    )

    $destination = Assert-DmdClockPathBelowRoot `
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
        $copiedHash = Get-DmdClockSha256 $temporaryPath
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

function Invoke-SdCardDownloadOnly {
    param([Parameter(Mandatory)][string] $StagingDestination)

    $layout = New-DmdClockStagingLayout -Destination $StagingDestination `
        -WhatIf:$WhatIfPreference

    $artifacts = [Collections.Generic.List[object]]::new()
    $supportDefinitions = @(
        [pscustomobject]@{
            Id = 'sd.catalog'; Relative = 'SDCard/catalog.json'
            RepositoryRelative = 'scenes/catalog.json'; Local = $localCatalogPath
            Kind = 'sd-catalog'; Maximum = 1MB
        },
        [pscustomobject]@{
            Id = 'sd.scene-metadata'; Relative = 'SDCard/scene-metadata.json'
            RepositoryRelative = 'scenes/scene-metadata.json'; Local = $localMetadataPath
            Kind = 'sd-metadata'; Maximum = 32MB
        },
        [pscustomobject]@{
            Id = 'sd.template.manifest'; Relative = 'SDCard/template/dmd/manifest.json'
            RepositoryRelative = 'firmware/dmdclock-esp32/sdcard/dmd/manifest.json'
            Local = (Join-Path $localCardTemplateRoot 'manifest.json')
            Kind = 'sd-template'; Maximum = 1MB
        },
        [pscustomobject]@{
            Id = 'sd.template.readme'; Relative = 'SDCard/template/dmd/README.md'
            RepositoryRelative = 'firmware/dmdclock-esp32/sdcard/dmd/README.md'
            Local = (Join-Path $localCardTemplateRoot 'README.md')
            Kind = 'sd-template'; Maximum = 1MB
        },
        [pscustomobject]@{
            Id = 'sd.font.altern8'; Relative = 'SDCard/fonts/ALTERN8.fnt'
            RepositoryRelative = 'assets/fonts/DotClk/ALTERN8.fnt'
            Local = (Join-Path $localFontRoot 'ALTERN8.fnt')
            Kind = 'sd-font'; Maximum = 96KB
        },
        [pscustomobject]@{
            Id = 'sd.font.fishy'; Relative = 'SDCard/fonts/FISHY.fnt'
            RepositoryRelative = 'assets/fonts/DotClk/FISHY.fnt'
            Local = (Join-Path $localFontRoot 'FISHY.fnt')
            Kind = 'sd-font'; Maximum = 96KB
        },
        [pscustomobject]@{
            Id = 'sd.font.trek'; Relative = 'SDCard/fonts/TREK.fnt'
            RepositoryRelative = 'assets/fonts/DotClk/TREK.fnt'
            Local = (Join-Path $localFontRoot 'TREK.fnt')
            Kind = 'sd-font'; Maximum = 96KB
        },
        [pscustomobject]@{
            Id = 'sd.font.twilight'; Relative = 'SDCard/fonts/TWILIGHT.fnt'
            RepositoryRelative = 'assets/fonts/DotClk/TWILIGHT.fnt'
            Local = (Join-Path $localFontRoot 'TWILIGHT.fnt')
            Kind = 'sd-font'; Maximum = 96KB
        }
    )

    foreach ($support in $supportDefinitions) {
        $uri = [uri]("$rawRepositoryRoot/$($support.RepositoryRelative)")
        $destinationPath = Join-Path $layout.Root $support.Relative
        $artifacts.Add((Save-DmdClockStagedDownload `
            -ArtifactId $support.Id -Uri $uri -Destination $destinationPath `
            -StagingRoot $layout.Root -MaximumBytes $support.Maximum `
            -Kind $support.Kind -Version 'v1.6' -Target 'esp32-s3' `
            -WhatIf:$WhatIfPreference))
    }

    if ($WhatIfPreference) {
        Write-Host '[WHATIF] Scene catalog content is not downloaded, so the scene archive is reported after support-file staging executes.' -ForegroundColor Yellow
        return
    }

    $stagedCatalogPath = Join-Path $layout.Root 'SDCard/catalog.json'
    $catalog = Get-Content -LiteralPath $stagedCatalogPath -Raw | ConvertFrom-Json
    if ([int]$catalog.schemaVersion -ne 1) {
        throw "Unsupported shared scene catalog schema '$($catalog.schemaVersion)'."
    }
    $packId = if ($Library -eq 'Original') { 'dotclk-original' } else { 'drwize-complete' }
    $matches = @($catalog.packs | Where-Object { [string]$_.packId -eq $packId })
    if ($matches.Count -ne 1) {
        throw "The staged catalog must contain exactly one '$packId' entry."
    }
    $pack = $matches[0]
    if (-not [bool]$pack.available -or
        [string]$pack.downloadUrl -notmatch '^https://' -or
        [long]$pack.downloadBytes -le 0 -or
        [string]$pack.archiveSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        @($pack.supportedPlatforms) -notcontains 'esp32-s3') {
        throw "The staged '$packId' catalog entry is not a valid ESP32 scene library."
    }
    $archiveName = "$packId-$($pack.version -replace '[^0-9A-Za-z._-]', '_').zip"
    $archivePath = Join-Path $layout.SDCard "libraries/$packId/$archiveName"
    $artifacts.Add((Save-DmdClockStagedDownload `
        -ArtifactId "sd.library.$packId" -Uri ([uri][string]$pack.downloadUrl) `
        -Destination $archivePath -StagingRoot $layout.Root `
        -ExpectedBytes ([long]$pack.downloadBytes) `
        -ExpectedSha256 ([string]$pack.archiveSha256) -MaximumBytes 256MB `
        -Kind 'scene-library' -Version ([string]$pack.version) `
        -Target 'esp32-s3'))

    $manifestPath = Update-DmdClockStagingManifest -StagingRoot $layout.Root `
        -Artifacts @($artifacts)
    Write-DmdClockProvisioningLog -Event 'staging-complete' `
        -Detail "kind=sd library=$packId manifest=$manifestPath artifacts=$($artifacts.Count)"
    Write-Host ''
    Write-Host '[DONE] Verified microSD card payload staged without enumerating removable media.' -ForegroundColor Green
    Write-Host "Manifest: $manifestPath"
    $artifacts | Select-Object artifactId, status, size, sha256, relativePath | Format-Table -AutoSize
}

$requirementsPath = if (-not [string]::IsNullOrWhiteSpace($StagingSource)) {
    [IO.Path]::GetFullPath($StagingSource)
} elseif ([string]::IsNullOrWhiteSpace($Destination)) {
    Join-Path ([Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)) 'DmdClock\DmdClockFiles'
} else {
    [IO.Path]::GetFullPath($Destination)
}
$requirements = Invoke-DmdClockRequirementsCheck `
    -Operation $(if ($CheckRequirements) { 'Check' } elseif ($DownloadOnly) { 'Download' } elseif ($StagingSource) { 'Offline' } else { 'SdCard' }) `
    -DataPath $requirementsPath `
    -MinimumFreeBytes 256MB `
    -RequiredCommands @(
        'Get-Disk',
        'Get-FileHash',
        'Get-Partition',
        'Get-Volume',
        'Invoke-WebRequest'
    ) `
    -RequireNetwork:$DownloadOnly `
    -ThrowOnFailure:(-not $CheckRequirements)
if ($CheckRequirements) {
    if (-not $requirements.Passed) {
        Set-DmdClockOperationResult -Status failed -Operation 'Check requirements' `
            -Detail 'One or more requirements checks failed.'
        exit 1
    }
    Set-DmdClockOperationResult -Status completed -Operation 'Check requirements'
    return
}
if ($ListDisks) {
    Show-DmdClockDiskCandidates
    Set-DmdClockOperationResult -Status completed -Operation 'List disks'
    return
}

$wizardSelection = $null
if ($PSCmdlet.ParameterSetName -eq 'Card' -and
    ($Wizard -or -not $PSBoundParameters.ContainsKey('DiskNumber'))) {
    $wizardSelection = Invoke-CardWizard
    if ($null -eq $wizardSelection) {
        Set-DmdClockOperationResult -Status cancelled -Operation 'Prepare microSD card' `
            -Detail 'No microSD card was selected.'
        return
    }
    $DiskNumber = $wizardSelection.DiskNumber
    $Library = $wizardSelection.Library
}

$runOutcome = 'cancelled'
$runDetail = ''
$logPath = $null
if (-not $WhatIfPreference -and -not $TestRoot) {
    $operation = if ($DownloadOnly) { "stage-sd-$Library" } else { "sync-sd-$Library" }
    $logDirectory = if ($DownloadOnly) {
        Join-Path ([IO.Path]::GetFullPath($Destination)) 'Logs'
    } else {
        Join-Path ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::LocalApplicationData)) 'DmdClock\Logs\Provisioning'
    }
    $logPath = Start-DmdClockProvisioningLog -LogDirectory $logDirectory `
        -Operation $operation
    Write-Host "Log: $logPath"
    Write-DmdClockRequirementsLog -Requirements $requirements
    Write-DmdClockProvisioningLog -Event 'invocation' -Detail (
        "library=$Library disk=$DiskNumber source_directory=$SourceDirectory " +
        "staging_source=$StagingSource destination=$Destination refresh=$RefreshSource " +
        "allow_fixed=$AllowFixedDrive")
}

try {
if ($DownloadOnly) {
    Invoke-SdCardDownloadOnly -StagingDestination $Destination
    $runOutcome = 'completed'
    return
}
if (-not [string]::IsNullOrWhiteSpace($StagingSource)) {
    $libraryArtifactId = if ($Library -eq 'Original') {
        'sd.library.dotclk-original'
    } else {
        'sd.library.drwize-complete'
    }
    $stagedSourceInfo = Test-DmdClockStagingManifest -Source $StagingSource `
        -RequiredArtifactIds @(
            'sd.catalog',
            'sd.scene-metadata',
            'sd.template.manifest',
            'sd.template.readme',
            $libraryArtifactId
        )
}
if ($WhatIfPreference) {
    if ($null -ne $stagedSourceInfo) {
        $catalogPath = [string]$stagedSourceInfo.Artifacts['sd.catalog'].ResolvedPath
    } elseif (Test-Path -LiteralPath $localCatalogPath -PathType Leaf) {
        $catalogPath = $localCatalogPath
    } else {
        throw 'Dry-run needs either a complete -Source staging folder or the repository catalog; it never downloads support files.'
    }
    $definition = Get-LibraryDefinition
    $target = Get-CardTarget
    Write-Host ''
    Write-Host '[DRY RUN] No downloads, temporary extraction, card writes, deletions, formatting, or partitioning will occur.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-Host "  Library:  $($definition.DisplayName) v$($definition.Version) ($($definition.SceneCount) scenes)"
    Write-Host "  Source:   $(if ($StagingSource) { [IO.Path]::GetFullPath($StagingSource) } elseif ($SourceDirectory) { [IO.Path]::GetFullPath($SourceDirectory) } else { $definition.DownloadUrl })"
    Write-Host "  Target:   $($target.Root)"
    if (-not $target.IsTest) {
        Write-Host ''
        Write-Host 'Card target:' -ForegroundColor Cyan
        Write-Host ("  Disk:     {0} - {1} - {2:N1} GB - {3}" -f
            $target.DiskNumber, $target.DiskSnapshot.FriendlyName,
            ($target.DiskSnapshot.Size / 1GB), $target.DiskSnapshot.BusType)
        Write-Host "  Volume:   $($target.Volume.DriveLetter): FAT32; label='$($target.Volume.FileSystemLabel)'"
    }
    return
}

[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    $supportFiles = Initialize-SupportFiles
    $catalogPath = $supportFiles.Catalog
    $metadataPath = $supportFiles.Metadata
    $cardTemplateRoot = $supportFiles.CardTemplate
    $fontRoot = $supportFiles.Fonts
    if (-not (Test-Path -LiteralPath $cardTemplateRoot -PathType Container)) {
        throw "Card template not found: $cardTemplateRoot"
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Scene metadata not found: $metadataPath"
    }
    if (-not (Test-Path -LiteralPath $fontRoot -PathType Container)) {
        throw "DotClk font source not found: $fontRoot"
    }

    $definition = Get-LibraryDefinition
    Write-Host "Library: $($definition.DisplayName) v$($definition.Version) ($($definition.SceneCount) scenes)"
    Write-Host "Instructions: $preparationGuide"

    $source = Get-SceneSource -Definition $definition
    Test-SceneLibrary $source.Scenes
    Write-DmdClockProvisioningLog -Event 'scene-source-verified' -Detail (
        "library=$($definition.PackId) version=$($definition.Version) scenes=$($definition.SceneCount) " +
        "source=$($source.Source) archive_sha256=$($source.ArchiveHash)")

    # Hardware/media enumeration starts only after all source files, inventory,
    # archive metadata, and every SCN have passed validation.
    $target = Get-CardTarget
    Write-Host "Target: $($target.Root)"
    if (-not $target.IsTest) {
        Write-Host (
            "Physical disk: Disk $($target.DiskNumber) - " +
            "$($target.DiskSnapshot.FriendlyName) - " +
            "$([Math]::Round($target.DiskSnapshot.Size / 1GB, 2)) GiB - " +
            "$($target.DiskSnapshot.BusType)")
        Write-Host (
            "Volume: $($target.Volume.DriveLetter):, label='$($target.Volume.FileSystemLabel)', " +
            "FAT32, $($target.Volume.HealthStatus), $($target.Volume.DriveType), " +
            "$([Math]::Round($target.Volume.Size / 1GB, 2)) GiB")
        Write-DmdClockProvisioningLog -Event 'disk-selected' -Detail (
            "disk=$($target.DiskNumber) model=$($target.DiskSnapshot.FriendlyName) " +
            "size=$($target.DiskSnapshot.Size) bus=$($target.DiskSnapshot.BusType) " +
            "volume=$($target.Volume.DriveLetter): label=$($target.Volume.FileSystemLabel) " +
            "filesystem=$($target.Volume.FileSystem) health=$($target.Volume.HealthStatus) " +
            "drive_type=$($target.Volume.DriveType)")
    }
    Write-Host '[SAFE] No partitioning, formatting, or deletion of card files is performed.' -ForegroundColor Green

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
    foreach ($fontName in @('ALTERN8.fnt', 'FISHY.fnt', 'TREK.fnt', 'TWILIGHT.fnt')) {
        $managed.Add((Get-ManagedFile `
            -SourcePath (Join-Path $fontRoot $fontName) `
            -RelativeTarget "dmd/fonts/$fontName" `
            -Category Font))
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
        ObsoletePreserved = 0
        Preserved = 0
    }
    $copyBytes = [long]0
    foreach ($file in $managed) {
        $destination = Assert-DmdClockPathBelowRoot `
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
            (Get-DmdClockSha256 $destination) -eq $file.Hash
        if ($matches) {
            $counts.Unchanged++
        }
        elseif ($file.Category -eq 'Font') {
            $counts.Preserved++
            Write-Warning (
                "Preserving existing user font '$($file.RelativeTarget)' because its content differs from the canonical file.")
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
    $obsoletePreservedFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $previousManagedPaths) {
        $managedRelative = "dmd/scenes/$relative"
        if (-not $managedScenePaths.Contains($managedRelative)) {
            $obsoletePath = Assert-DmdClockPathBelowRoot `
                -Path (Join-Path $target.Root $managedRelative) `
                -Root $target.Root `
                -Description "Previously managed scene '$relative'"
            if (Test-Path -LiteralPath $obsoletePath -PathType Leaf) {
                [void]$obsoletePreservedFiles.Add($obsoletePath)
                $counts.ObsoletePreserved++
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
                -not $obsoletePreservedFiles.Contains($existing.FullName) -and
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
    Write-Host "  Obsolete managed files preserved: $($counts.ObsoletePreserved)"
    Write-Host "  Other files preserved:            $($counts.Preserved)"
    Write-Host "  Write:     $([Math]::Round($copyBytes / 1MB, 1)) MiB"
    Write-DmdClockProvisioningLog -Event 'sd-plan' -Detail (
        "target=$($target.Root) library=$($definition.PackId) unchanged=$($counts.Unchanged) " +
        "added=$($counts.Added) repaired=$($counts.Repaired) updated=$($counts.Updated) " +
        "obsolete_preserved=$($counts.ObsoletePreserved) other_preserved=$($counts.Preserved) " +
        "write_bytes=$copyBytes")

    $changeCount = $counts.Added + $counts.Repaired + $counts.Updated
    if ($changeCount -eq 0) {
        Write-Host 'The card is already up to date; no files were written.'
        $runOutcome = 'completed'
        return
    }

    if (-not $target.IsTest) {
        Assert-DmdClockDiskUnchanged -Original $target.DiskSnapshot
    }

    if (-not (Test-DmdClockShouldProcess `
        -Target $target.Root `
        -Action "Synchronize $($sceneFiles.Count) scenes for $($definition.DisplayName) and the DMDClock card layout")) {
        Write-DmdClockProvisioningLog -Event 'sd-cancelled' -Detail "target=$($target.Root)"
        return
    }

    foreach ($directory in $directories) {
        $directoryPath = Assert-DmdClockPathBelowRoot `
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
                (Get-DmdClockSha256 $destination) -eq $file.Hash) {
                continue
            }
            if ($file.Category -eq 'Font') {
                continue
            }
        }

        Install-FileAtomically -File $file -CardRoot $target.Root
    }

    foreach ($file in $managed | Where-Object Category -eq 'Manifest') {
        $destination = Join-Path $target.Root $file.RelativeTarget
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationItem = Get-Item -LiteralPath $destination
            if ($destinationItem.Length -eq $file.Length -and
                (Get-DmdClockSha256 $destination) -eq $file.Hash) {
                continue
            }
        }

        Install-FileAtomically -File $file -CardRoot $target.Root
    }
    Write-Host ''
    Write-Host (
        "microSD card preparation complete: added $($counts.Added), " +
        "repaired $($counts.Repaired), updated $($counts.Updated), " +
        "unchanged $($counts.Unchanged), obsolete managed files preserved " +
        "$($counts.ObsoletePreserved), other files preserved $($counts.Preserved).")
    Write-DmdClockProvisioningLog -Event 'sd-complete' -Detail (
        "target=$($target.Root) library=$($definition.PackId) added=$($counts.Added) " +
        "repaired=$($counts.Repaired) updated=$($counts.Updated) write_bytes=$copyBytes")
    $runOutcome = 'completed'
}
finally {
    $temporaryBase = Get-NormalizedRoot ([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $temporaryRoot) -and
        $temporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -WhatIf:$false
    }
}
}
catch {
    $originalError = $_
    $runOutcome = 'failed'
    $runDetail = "error_type=$($originalError.Exception.GetType().FullName) error=$($originalError.Exception.Message)"
    try {
        Write-DmdClockProvisioningLog -Event 'error' -Detail $runDetail
    }
    catch {
        Write-Warning "Could not append the original failure to the provisioning log: $($_.Exception.Message)"
    }
    Set-DmdClockOperationResult -Status failed -Operation 'Prepare microSD card' `
        -Detail $originalError.Exception.Message
    throw $originalError
}
finally {
    Complete-DmdClockProvisioningLogSafely -LogPath $logPath `
        -Outcome $runOutcome -Detail $runDetail
    if ($runOutcome -ne 'failed') {
        $resultStatus = if ($WhatIfPreference) { 'dry-run' } else { $runOutcome }
        Set-DmdClockOperationResult -Status $resultStatus -Operation 'Prepare microSD card' `
            -Detail $runDetail
    }
}
