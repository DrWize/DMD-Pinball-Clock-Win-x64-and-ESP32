[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Card')]
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DriveLetter,

    [Parameter(Mandatory, ParameterSetName = 'Test', DontShow)]
    [string]$TestRoot,

    [string]$SourceDirectory,

    [switch]$RefreshSource,

    [switch]$AllowFixedDrive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cardTemplateRoot = Join-Path $projectRoot 'firmware\dmdclock-esp32\sdcard\dmd'
$metadataPath = Join-Path $projectRoot 'scenes\scene-metadata.json'
$toolsProject = Join-Path $projectRoot 'tools\DmdClock.Tools\DmdClock.Tools.csproj'
$downloadUri = 'https://github.com/sigmafx/DotClk-Resources/archive/refs/heads/master.zip'
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

function Get-DotnetExecutable {
    if (-not [string]::IsNullOrWhiteSpace($env:DMD_DOTNET)) {
        return $env:DMD_DOTNET
    }

    $workspaceDotnet = [IO.Path]::GetFullPath(
        (Join-Path $projectRoot '..\.tools\dotnet10\dotnet.exe'))
    if (Test-Path -LiteralPath $workspaceDotnet -PathType Leaf) {
        return $workspaceDotnet
    }

    $command = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw 'A .NET 10 SDK is required to validate the SCN files. Set DMD_DOTNET or install the SDK.'
    }

    return $command.Source
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

function Get-SceneSource {
    if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
        return [pscustomobject]@{
            Scenes = Resolve-SceneSource $SourceDirectory
            ArchiveHash = $null
            Source = [IO.Path]::GetFullPath($SourceDirectory)
        }
    }

    $cacheRoot = Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ) 'DmdClock\cache'
    $cacheArchive = Join-Path $cacheRoot 'DotClk-Resources-master.zip'
    $archivePath = $cacheArchive

    if ($RefreshSource -or -not (Test-Path -LiteralPath $cacheArchive -PathType Leaf)) {
        $downloadPath = Join-Path $temporaryRoot 'DotClk-Resources-master.zip'
        Write-Host "Downloading the original DotClk scene archive..."
        Invoke-WebRequest -Uri $downloadUri -OutFile $downloadPath
        if ((Get-Item -LiteralPath $downloadPath).Length -eq 0) {
            throw 'The downloaded DotClk archive is empty.'
        }

        $archivePath = $downloadPath
        if (-not $WhatIfPreference -and
            $PSCmdlet.ShouldProcess($cacheArchive, 'Cache the downloaded DotClk scene archive')) {
            [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
            $cacheTemporary = Join-Path $cacheRoot (
                '.DotClk-Resources-' + [Guid]::NewGuid().ToString('N') + '.tmp')
            Copy-Item -LiteralPath $downloadPath -Destination $cacheTemporary
            Move-Item -LiteralPath $cacheTemporary -Destination $cacheArchive -Force
            $archivePath = $cacheArchive
        }
    }
    else {
        Write-Host "Using cached DotClk scene archive: $cacheArchive"
    }

    $expandedRoot = Join-Path $temporaryRoot 'source'
    Expand-CheckedArchive -ArchivePath $archivePath -Destination $expandedRoot
    $resourceRoot = Get-ChildItem -LiteralPath $expandedRoot -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Scenes') } |
        Select-Object -First 1
    if ($null -eq $resourceRoot) {
        throw 'The DotClk archive does not contain the expected Scenes directory.'
    }

    return [pscustomobject]@{
        Scenes = Resolve-SceneSource $resourceRoot.FullName
        ArchiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        Source = $downloadUri
    }
}

function Test-SceneLibrary {
    param([Parameter(Mandatory)][string]$ScenesPath)

    $dotnet = Get-DotnetExecutable
    Write-Host "Validating every SCN file..."
    $output = @(& $dotnet run --project $toolsProject --configuration Release -- scan $ScenesPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | Select-Object -Last 30) -join [Environment]::NewLine
        throw "SCN validation failed with exit code $LASTEXITCODE.`n$details"
    }

    $summary = $output | Where-Object {
        $_ -match '^(Files|Accepted|Warned|Rejected|Frames|Masked frames):'
    }
    $summary | ForEach-Object { Write-Host $_ }
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
        Hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
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
        $copiedHash = (Get-FileHash -LiteralPath $temporaryPath -Algorithm SHA256).Hash
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

[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    if (-not (Test-Path -LiteralPath $cardTemplateRoot -PathType Container)) {
        throw "Card template not found: $cardTemplateRoot"
    }
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "Scene metadata not found: $metadataPath"
    }

    $target = Get-CardTarget
    Write-Host "Target: $($target.Root)"
    if (-not $target.IsTest) {
        Write-Host (
            "Volume: FAT32, $($target.Volume.DriveType), " +
            "$([Math]::Round($target.Volume.Size / 1GB, 2)) GiB")
    }

    $source = Get-SceneSource
    Test-SceneLibrary $source.Scenes

    $managed = [Collections.Generic.List[object]]::new()
    $sceneManifestEntries = [Collections.Generic.List[object]]::new()
    $sourceRoot = Get-NormalizedRoot $source.Scenes
    $sceneFiles = Get-ChildItem -LiteralPath $source.Scenes -File -Filter '*.scn' -Recurse |
        Sort-Object FullName
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

    $managed.Add((Get-ManagedFile `
        -SourcePath $metadataPath `
        -RelativeTarget 'dmd/scenes/scene-metadata.json' `
        -Category Metadata))
    foreach ($templateName in @('manifest.json', 'README.md')) {
        $managed.Add((Get-ManagedFile `
            -SourcePath (Join-Path $cardTemplateRoot $templateName) `
            -RelativeTarget "dmd/$templateName" `
            -Category Template))
    }

    $contentManifest = [ordered]@{
        schema = 'dmdclock-dotclk-scenes'
        version = 1
        source = $source.Source
        sourceArchiveSha256 = $source.ArchiveHash
        fileCount = $sceneManifestEntries.Count
        files = $sceneManifestEntries
    }
    $manifestPath = Join-Path $temporaryRoot 'dotclk-scenes-manifest.json'
    $manifestJson = $contentManifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText(
        $manifestPath,
        $manifestJson + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    $managed.Add((Get-ManagedFile `
        -SourcePath $manifestPath `
        -RelativeTarget 'dmd/config/dotclk-scenes-manifest.json' `
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
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $file.Hash
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
    $targetScenes = Join-Path $target.Root 'dmd\scenes'
    if (Test-Path -LiteralPath $targetScenes -PathType Container) {
        $targetRootNormalized = Get-NormalizedRoot $target.Root
        foreach ($existing in Get-ChildItem -LiteralPath $targetScenes -File -Recurse) {
            $relativeExisting = $existing.FullName.Substring(
                $targetRootNormalized.Length).Replace('\', '/')
            if ($relativeExisting -ne 'dmd/scenes/scene-metadata.json' -and
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
    Write-Host "  Preserved: $($counts.Preserved)"
    Write-Host "  Write:     $([Math]::Round($copyBytes / 1MB, 1)) MiB"

    $changeCount = $counts.Added + $counts.Repaired + $counts.Updated
    if ($changeCount -eq 0) {
        Write-Host 'The card is already up to date; no files were written.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess(
        $target.Root,
        "Synchronize $($sceneFiles.Count) DotClk scenes and the DMDClock card layout")) {
        return
    }

    foreach ($directory in $directories) {
        $directoryPath = Assert-PathBelowRoot `
            -Path (Join-Path $target.Root $directory) `
            -Root $target.Root `
            -Description "Directory '$directory'"
        [IO.Directory]::CreateDirectory($directoryPath) | Out-Null
    }
    foreach ($file in $managed) {
        $destination = Join-Path $target.Root $file.RelativeTarget
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationItem = Get-Item -LiteralPath $destination
            if ($destinationItem.Length -eq $file.Length -and
                (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $file.Hash) {
                continue
            }
        }

        Install-FileAtomically -File $file -CardRoot $target.Root
    }

    Write-Host ''
    Write-Host (
        "SD card preparation complete: added $($counts.Added), " +
        "repaired $($counts.Repaired), updated $($counts.Updated), " +
        "unchanged $($counts.Unchanged), preserved $($counts.Preserved).")
}
finally {
    $temporaryBase = Get-NormalizedRoot ([IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $temporaryRoot) -and
        $temporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -WhatIf:$false
    }
}
