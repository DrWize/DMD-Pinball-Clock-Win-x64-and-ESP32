[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $ReleaseTag,

    [ValidateSet('Waveshare7', 'Waveshare349B')]
    [string] $Board,

    [ValidateSet('Application', 'Full', 'FullReset')]
    [string] $FlashMode,

    [switch] $FactoryRecovery,

    [ValidateSet('V1', 'V2')]
    [string] $BoardRevision,

    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [switch] $DownloadOnly,

    [switch] $CheckRequirements,

    [switch] $ProbePorts,

    [string] $Destination,

    [string] $Source,

    [Alias('DryRun')]
    [switch] $WhatIf,

    [string] $ConfirmHardware,

    [switch] $Force,

    [switch] $Wizard
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$null = Add-Type -AssemblyName System.IO.Compression.FileSystem

$provisioningModule = Join-Path $PSScriptRoot 'DmdClock.Provisioning.psm1'
if (-not (Test-Path -LiteralPath $provisioningModule -PathType Leaf)) {
    throw "Shared provisioning module not found: $provisioningModule"
}
Import-Module $provisioningModule -Force

$config = Get-DmdClockConfig
$DmdClockCacheRoot = $config.CacheRoot
$nvsRegionOffset = $config.NvsRegionOffset
$nvsRegionSize = $config.NvsRegionSize
$esptoolRepository = $config.EsptoolRepository
$hardwareTargets = @(Get-DmdClockHardwareTargets)
$maximumManifestBytes = 1MB
$maximumPackageBytes = 64MB
$toolCacheRoot = Join-Path $DmdClockCacheRoot 'tools\esptool'

$selectedTarget = $null
$esptool = $null
$script:selectedPortIdentity = $null

$factoryRecoveryImages = @{
    V1 = [pscustomobject]@{
        Revision = 'V1'
        Repository = 'waveshareteam/ESP32-S3-Touch-LCD-3.49'
        Commit = 'def6edd0b6e1925ed09702eed01a2f181afdf8c1'
        FileName = 'ESP32-S3-Touch-LCD-3.49-FactoryProgram.bin'
        Size = 2813728
        Sha256 = '921C41A413E75DCE5F0DA4954023864C21E159B16BF3B36311823ACD9B96E4DC'
    }
    V2 = [pscustomobject]@{
        Revision = 'V2'
        Repository = 'waveshareteam/ESP32-S3-Touch-LCD-3.49-V2'
        Commit = '1c157e6e8e68b89fd4dc400f46bf1724cb64a57e'
        FileName = 'ESP32-S3-Touch-LCD-3.49-V2.bin'
        Size = 2813008
        Sha256 = '1D1F84C766E720F344FAF59D1E6C95846DF1A26DA4C1E6D6094F9095F6B68312'
    }
}

function Show-SupportedHardwareBanner {
    [CmdletBinding()]
    param(
        [switch] $ShowGuidance
    )
    Write-Host ''
    Write-Host 'DMDClock ESP32-S3 installer/updater' -ForegroundColor Cyan
    Write-Host '----------------------------------' -ForegroundColor DarkCyan
    if ($ShowGuidance) {
        Write-Host 'Select the exact physical board before choosing a firmware version.'
        Write-Host 'Waveshare ESP32-S3-Touch-LCD-7B (1024x600) is not supported.' `
            -ForegroundColor Red
    }
}

function Select-HardwareTarget {
    if ($Board) {
        return @($hardwareTargets | Where-Object { $_.Key -eq $Board })[0]
    }

    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host 'Select your hardware:'
    for ($index = 0; $index -lt $hardwareTargets.Count; $index++) {
        Write-Host ("  [{0}] {1}" -f ($index + 1), $hardwareTargets[$index].Product)
    }
    Write-Host ("  [{0}] Exit" -f ($hardwareTargets.Count + 1))
    $choice = Read-DmdClockMenuChoice -Prompt 'Select hardware' -Minimum 1 `
        -Maximum ($hardwareTargets.Count + 1) -RequiredParameter '-Board'
    if ($choice -eq $hardwareTargets.Count + 1) { return $null }
    $target = $hardwareTargets[$choice - 1]
    if ($null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Board' -Value $target.Product
    }
    return $target
}

function Get-CompatibleReleases {
    param([Parameter(Mandatory)] $Target)

    $uri = "https://api.github.com/repos/$Repository/releases?per_page=30"
    Write-Host "Checking GitHub releases for $($Target.Product)..."
    Write-DmdClockProvisioningLog -Event 'metadata-query' `
        -Detail "url=$uri target=$($Target.Id)"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-DmdClockGitHubHeaders)
    }
    catch {
        throw "GitHub could not be reached. Check the internet connection and retry. Releases: https://github.com/$Repository/releases"
    }
    $releases = @($response)
    $compatible = @()
    foreach ($release in $releases) {
        if ($release.draft) { continue }
        $manifestAssets = @($release.assets | Where-Object {
            $_.name -match '(?i)^DMDClock-.+-esp32(?:-[A-Za-z0-9_.-]+)?-manifest\.json$' -and
            [long]$_.size -gt 0 -and [long]$_.size -le $maximumManifestBytes
        })
        foreach ($manifestAsset in $manifestAssets) {
            try {
                $manifest = Invoke-RestMethod -Uri $manifestAsset.browser_download_url `
                    -Headers (Get-DmdClockGitHubHeaders)
            }
            catch {
                Write-Warning "Ignoring unreadable manifest '$($manifestAsset.name)' in release '$($release.tag_name)'."
                continue
            }
            if ([string]$manifest.target.id -ne $Target.Id) { continue }
            $compatible += [pscustomobject]@{
                Release = $release
                ManifestAsset = $manifestAsset
                Manifest = $manifest
            }
        }
    }
    return $compatible
}

function Select-CompatibleRelease {
    param([Parameter(Mandatory)] $Target)

    $releases = @(Get-CompatibleReleases -Target $Target)
    if ($ReleaseTag) {
        $selected = @($releases | Where-Object { $_.Release.tag_name -eq $ReleaseTag })
        if ($selected.Count -ne 1) {
            throw "Release '$ReleaseTag' has no compatible image for $($Target.Product). See https://github.com/$Repository/releases."
        }
        return $selected[0]
    }

    if ($releases.Count -eq 0) {
        throw "No published release currently contains an image for $($Target.Product). See $($Target.Homepage) and https://github.com/$Repository/releases."
    }

    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host "Available firmware for $($Target.Product):"
    for ($index = 0; $index -lt $releases.Count; $index++) {
        $release = $releases[$index].Release
        $channel = if ($release.prerelease) { 'Preview' } else { 'Stable' }
        $date = ([DateTimeOffset]$release.published_at).ToString('yyyy-MM-dd')
        Write-Host ("  [{0}] {1,-14} {2,-8} {3}" -f ($index + 1), $release.tag_name, $channel, $date)
    }
    Write-Host ("  [{0}] Cancel" -f ($releases.Count + 1)) -ForegroundColor DarkGray
    $choice = Read-DmdClockMenuChoice -Prompt 'Select release' -Minimum 1 `
        -Maximum ($releases.Count + 1) -Default 1 -RequiredParameter '-ReleaseTag'
    if ($choice -gt $releases.Count) {
        Write-Host 'Release selection cancelled.' -ForegroundColor Yellow
        return $null
    }
    $selected = $releases[$choice - 1]
    if ($null -ne $wizardState) {
        $channel = if ($selected.Release.prerelease) { 'Preview' } else { 'Stable' }
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Release' `
            -Value "$($selected.Release.tag_name) ($channel)"
    }
    return $selected
}

function Assert-CompatibleManifest {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] $Target
    )

    if ([int]$Manifest.schemaVersion -ne 1) {
        throw "Unsupported ESP32 manifest schema '$($Manifest.schemaVersion)'."
    }
    if ([string]$Manifest.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or
        [string]$Manifest.releaseTag -ne "v$($Manifest.version)") {
        throw 'The firmware version or release tag is invalid.'
    }
    if ([string]$Manifest.target.id -ne $Target.Id -or
        [string]$Manifest.target.product -ne $Target.Product -or
        [string]$Manifest.target.chip -ne 'esp32s3' -or
        [string]$Manifest.target.flashSize -ne '16MB') {
        throw "Firmware target mismatch. The selected hardware is $($Target.Product)."
    }
    if ($Target.Display -and [string]$Manifest.target.display -ne $Target.Display) {
        throw "Firmware display mismatch. Expected $($Target.Display)."
    }
    if ($Target.Module -and [string]$Manifest.target.module -ne $Target.Module) {
        throw "Firmware module mismatch. Expected $($Target.Module)."
    }
    if ([string]$Manifest.target.supportedBoard -ne $Target.SupportedBoard -or
        [bool]$Manifest.target.touchEnabled -ne $Target.TouchEnabled) {
        throw "Firmware board revision or touch capability does not match $($Target.Product)."
    }
    if ([string]$Manifest.package.asset -notmatch '^[A-Za-z0-9_.-]+\.zip$' -or
        [long]$Manifest.package.size -le 0 -or
        [long]$Manifest.package.size -gt $maximumPackageBytes) {
        throw 'The firmware package metadata is invalid or exceeds the permitted size.'
    }
    if ([string]$Manifest.package.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The firmware package SHA-256 is invalid.'
    }
    if ([string]$Manifest.flash.settings.mode -ne 'dio' -or
        [string]$Manifest.flash.settings.frequency -ne '80m' -or
        [string]$Manifest.flash.settings.size -ne '16MB') {
        throw 'The firmware flash settings are not supported for this board.'
    }

    $expectedOffsets = @{
        application = @('0x10000')
        full = @('0x0', '0x8000', '0x10000')
    }
    $validatedModes = @{}
    foreach ($modeName in $expectedOffsets.Keys) {
        if ($Manifest.flash.$modeName.preservesNvs -ne $true) {
            throw "Manifest flash mode '$modeName' does not guarantee NVS preservation."
        }
        $files = @($Manifest.flash.$modeName.files)
        if ($files.Count -ne $expectedOffsets[$modeName].Count) {
            throw "Manifest flash mode '$modeName' has an unexpected number of files."
        }
        $seenOffsets = @{}
        $seenPaths = @{}
        foreach ($file in $files) {
            $offset = ([string]$file.offset).ToLowerInvariant()
            $relativePath = [string]$file.path
            if ($offset -notin $expectedOffsets[$modeName]) {
                throw "Unsupported flash offset '$($file.offset)' in mode '$modeName'."
            }
            if ($seenOffsets.ContainsKey($offset) -or $seenPaths.ContainsKey($relativePath)) {
                throw "Duplicate flash offset or path in mode '$modeName'."
            }
            $seenOffsets[$offset] = $true
            $seenPaths[$relativePath] = $true
            Assert-DmdClockSafeRelativePath -RelativePath $relativePath
            if ([long]$file.size -le 0 -or [long]$file.size -gt 16MB) {
                throw "Invalid firmware size for '$relativePath'."
            }
            if ([string]$file.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw "Invalid firmware hash for '$relativePath'."
            }
        }
        foreach ($expectedOffset in $expectedOffsets[$modeName]) {
            if (-not $seenOffsets.ContainsKey($expectedOffset)) {
                throw "Manifest flash mode '$modeName' is missing offset '$expectedOffset'."
            }
        }
        $validatedModes[$modeName] = $files
    }

    $application = @($validatedModes.application)[0]
    $fullApplication = @($validatedModes.full | Where-Object {
        ([string]$_.offset).ToLowerInvariant() -eq '0x10000'
    })
    if ($fullApplication.Count -ne 1 -or
        [string]$application.path -cne [string]$fullApplication[0].path -or
        [long]$application.size -ne [long]$fullApplication[0].size -or
        [string]$application.sha256 -ine [string]$fullApplication[0].sha256) {
        throw 'Application and full flash modes do not reference the same application image.'
    }
}

function Expand-VerifiedPackage {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] $Manifest
    )

    $cacheRoot = Join-Path $DmdClockCacheRoot 'cache\firmware'
    $staging = "$Destination.staging-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $staging)

        $allFiles = @(
            @($Manifest.flash.application.files) + @($Manifest.flash.full.files) |
                Sort-Object path -Unique
        )
        foreach ($file in $allFiles) {
            $path = Join-Path $staging ([string]$file.path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Firmware package is missing '$($file.path)'."
            }
            Assert-DmdClockSha256Hash -Path $path -ExpectedHash ([string]$file.sha256)
        }

        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        Move-Item -LiteralPath $staging -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

function Get-ReleasePackage {
    param([Parameter(Mandatory)] $Selection)

    $release = $Selection.Release
    $manifestAsset = $Selection.ManifestAsset
    $cacheRoot = Join-Path $DmdClockCacheRoot 'cache\firmware'
    $safeTag = ([string]$release.tag_name) -replace '[^A-Za-z0-9_.-]', '_'
    $releaseCache = Join-Path (Join-Path $cacheRoot $safeTag) $selectedTarget.Id
    New-Item -ItemType Directory -Force -Path $releaseCache | Out-Null
    $manifestFile = Join-Path $releaseCache $manifestAsset.name

    Write-Host "Downloading manifest for $($release.tag_name)..."
    Save-DmdClockRemoteFile -Uri $manifestAsset.browser_download_url `
        -Destination $manifestFile -MaximumBytes $maximumManifestBytes
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    Assert-CompatibleManifest -Manifest $manifest -Target $selectedTarget
    if ([string]$manifest.releaseTag -ne [string]$release.tag_name) {
        throw "Manifest release '$($manifest.releaseTag)' does not match '$($release.tag_name)'."
    }

    $packageAssets = @($release.assets | Where-Object {
        $_.name -ceq [string]$manifest.package.asset
    })
    if ($packageAssets.Count -ne 1) {
        throw "Release '$($release.tag_name)' does not contain package '$($manifest.package.asset)'."
    }
    if ([long]$packageAssets[0].size -ne [long]$manifest.package.size) {
        throw 'GitHub asset size does not match the release manifest metadata.'
    }

    $archivePath = Join-Path $releaseCache ([string]$manifest.package.asset)
    $reuseArchive = (Test-Path -LiteralPath $archivePath -PathType Leaf)
    if ($reuseArchive) {
        try {
            Assert-DmdClockSha256Hash -Path $archivePath -ExpectedHash ([string]$manifest.package.sha256)
            Write-Host "Using verified cached package: $archivePath"
        }
        catch {
            Remove-Item -LiteralPath $archivePath -Force
            $reuseArchive = $false
        }
    }
    if (-not $reuseArchive) {
        Write-Host "Downloading $($manifest.package.asset)..."
        Save-DmdClockRemoteFile -Uri $packageAssets[0].browser_download_url `
            -Destination $archivePath -MaximumBytes $maximumPackageBytes
        Assert-DmdClockSha256Hash -Path $archivePath -ExpectedHash ([string]$manifest.package.sha256)
    }

    $expandedPath = Join-Path $releaseCache 'package'
    Expand-VerifiedPackage -ArchivePath $archivePath -Destination $expandedPath -Manifest $manifest
    Write-DmdClockProvisioningLog -Event 'firmware-package-ready' -Detail (
        "release=$($release.tag_name) manifest=$manifestFile archive=$archivePath " +
        "package_root=$expandedPath size=$($manifest.package.size) sha256=$($manifest.package.sha256)")
    return [pscustomobject]@{
        Source = "GitHub release $($release.tag_name)"
        Version = [string]$manifest.version
        Manifest = $manifest
        Root = $expandedPath
        Cache = $releaseCache
        IsLocal = $false
    }
}

function Select-FactoryRecoveryRevision {
    if ($BoardRevision) {
        return $BoardRevision
    }

    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host '3.49B hardware revision:'
    Write-Host '  [1] V1'
    Write-Host '  [2] V2 (Rev1.1 PCB / V2 case sticker)' -ForegroundColor Green
    Write-Host '  [3] Exit' -ForegroundColor DarkGray
    switch (Read-DmdClockMenuChoice -Prompt 'Select the exact physical revision' -Minimum 1 -Maximum 3 `
            -RequiredParameter '-BoardRevision') {
        1 {
            if ($null -ne $wizardState) {
                Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Revision' -Value 'V1'
            }
            return 'V1'
        }
        2 {
            if ($null -ne $wizardState) {
                Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Revision' -Value 'V2'
            }
            return 'V2'
        }
        3 { return $null }
    }
}

function Get-FactoryRecoveryPackage {
    param([Parameter(Mandatory)] [string] $Revision)

    $image = $factoryRecoveryImages[$Revision]
    if ($null -eq $image) {
        throw "No factory recovery definition exists for revision '$Revision'."
    }

    $cacheRoot = Join-Path $DmdClockCacheRoot 'cache\firmware'
    $destination = Join-Path (Join-Path $cacheRoot 'factory-recovery') $Revision
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $imagePath = Join-Path $destination $image.FileName
    $reuseImage = Test-Path -LiteralPath $imagePath -PathType Leaf
    if ($reuseImage) {
        try {
            if ((Get-Item -LiteralPath $imagePath).Length -ne [long]$image.Size) {
                throw 'Cached factory image size mismatch.'
            }
            Assert-DmdClockSha256Hash -Path $imagePath -ExpectedHash $image.Sha256
            Write-Host "Using verified cached factory image: $imagePath"
        }
        catch {
            Remove-Item -LiteralPath $imagePath -Force
            $reuseImage = $false
        }
    }

    if (-not $reuseImage) {
        $uri = "https://raw.githubusercontent.com/$($image.Repository)/$($image.Commit)/Firmware/$($image.FileName)"
        Write-Host "Downloading official Waveshare 3.49B $Revision factory image..."
        Save-DmdClockRemoteFile -Uri $uri -Destination $imagePath -MaximumBytes 16MB
        if ((Get-Item -LiteralPath $imagePath).Length -ne [long]$image.Size) {
            Remove-Item -LiteralPath $imagePath -Force
            throw "Factory image size mismatch. Expected $($image.Size) bytes."
        }
        Assert-DmdClockSha256Hash -Path $imagePath -ExpectedHash $image.Sha256
    }
    Write-DmdClockProvisioningLog -Event 'factory-image-ready' -Detail (
        "revision=$Revision source_commit=$($image.Commit) destination=$imagePath " +
        "size=$($image.Size) sha256=$($image.Sha256) reused=$reuseImage")

    return [pscustomobject]@{
        Source = "Official Waveshare factory image at commit $($image.Commit)"
        Revision = $Revision
        ImagePath = $imagePath
        FileName = $image.FileName
        Sha256 = $image.Sha256
        Cache = $destination
    }
}

function Show-PortHelp {
    param([Parameter(Mandatory)] $Target)

    Write-Host ''
    Write-Host '[FAILED] No usable serial port was detected.' -ForegroundColor Red
    Write-Host ''
    Write-Host "Selected hardware: $($Target.Product)"
    Write-Host 'Check the physical USB connection:'
    for ($index = 0; $index -lt $Target.PortInstructions.Count; $index++) {
        Write-Host ("  {0}. {1}" -f ($index + 1), $Target.PortInstructions[$index])
    }
    Write-Host ("  {0}. Open Device Manager > Ports (COM & LPT)." -f ($Target.PortInstructions.Count + 1))
    Write-Host ("  {0}. Disconnect and reconnect the board to identify the correct port." -f ($Target.PortInstructions.Count + 2))
    Write-Host ''
    Write-Host "Official product homepage: $($Target.Homepage)" -ForegroundColor Cyan
    Write-Host "Port diagram and documentation: $($Target.Documentation)" -ForegroundColor Cyan
    if ($Target.Driver) {
        Write-Host "If no CH343 port appears, install the official driver: $($Target.Driver)" `
            -ForegroundColor Cyan
    }
}

function Invoke-FirmwareDownloadOnly {
    param([Parameter(Mandatory)][string] $StagingDestination)

    $layout = New-DmdClockStagingLayout -Destination $StagingDestination `
        -WhatIf:$WhatIf
    $artifacts = [Collections.Generic.List[object]]::new()
    $targetsToStage = if ($Board) {
        @($hardwareTargets | Where-Object Key -eq $Board)
    } else {
        @($hardwareTargets)
    }
    foreach ($target in $targetsToStage) {
        $selections = @(Get-CompatibleReleases -Target $target)
        $selectionMatches = if ($ReleaseTag) {
            @($selections | Where-Object { [string]$_.Release.tag_name -eq $ReleaseTag })
        } else {
            @($selections | Select-Object -First 1)
        }
        if ($selectionMatches.Count -ne 1) {
            $requested = if ($ReleaseTag) { $ReleaseTag } else { 'the latest release' }
            throw "No unique compatible firmware for $($target.Product) was found in $requested."
        }
        $selection = $selectionMatches[0]
        $release = $selection.Release
        $safeTag = ([string]$release.tag_name) -replace '[^0-9A-Za-z._-]', '_'
        $targetRoot = Join-Path $layout.ESP32 "$($target.Key)/$safeTag"
        $manifestPath = Join-Path $targetRoot ([string]$selection.ManifestAsset.name)
        $manifestDigest = [string]$selection.ManifestAsset.digest
        $manifestHash = if ($manifestDigest -match '^sha256:([0-9A-Fa-f]{64})$') {
            $Matches[1]
        } else { '' }
        $artifacts.Add((Save-DmdClockStagedDownload `
            -ArtifactId "firmware.$($target.Key).manifest" `
            -Uri ([uri][string]$selection.ManifestAsset.browser_download_url) `
            -Destination $manifestPath -StagingRoot $layout.Root `
            -ExpectedBytes ([long]$selection.ManifestAsset.size) `
            -ExpectedSha256 $manifestHash -MaximumBytes $maximumManifestBytes `
            -Kind 'firmware-manifest' -Version ([string]$release.tag_name) `
            -Target $target.Id -WhatIf:$WhatIf))
        if ($WhatIf) { continue }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-CompatibleManifest -Manifest $manifest -Target $target
        if ([string]$manifest.releaseTag -ne [string]$release.tag_name) {
            throw "Firmware manifest release '$($manifest.releaseTag)' does not match '$($release.tag_name)'."
        }
        $packageAssets = @($release.assets | Where-Object {
            [string]$_.name -ceq [string]$manifest.package.asset
        })
        if ($packageAssets.Count -ne 1 -or
            [long]$packageAssets[0].size -ne [long]$manifest.package.size) {
            throw "Firmware package asset for $($target.Product) is missing or has the wrong size."
        }
        $packagePath = Join-Path $targetRoot ([string]$manifest.package.asset)
        $artifacts.Add((Save-DmdClockStagedDownload `
            -ArtifactId "firmware.$($target.Key).package" `
            -Uri ([uri][string]$packageAssets[0].browser_download_url) `
            -Destination $packagePath -StagingRoot $layout.Root `
            -ExpectedBytes ([long]$manifest.package.size) `
            -ExpectedSha256 ([string]$manifest.package.sha256) `
            -MaximumBytes $maximumPackageBytes -Kind 'firmware-package' `
            -Version ([string]$manifest.version) -Target $target.Id))
    }

    if (-not $WhatIf) {
        Write-Host 'Checking the official portable Espressif flashing tool...'
        $tool = Get-DmdClockEsptoolReleaseAsset -Repository $esptoolRepository
        $toolPath = Join-Path $layout.Tools "esptool/$($tool.Release.tag_name)/$($tool.Asset.name)"
        $artifacts.Add((Save-DmdClockStagedDownload `
            -ArtifactId 'tool.esptool.windows-x64' `
            -Uri ([uri][string]$tool.Asset.browser_download_url) `
            -Destination $toolPath -StagingRoot $layout.Root `
            -ExpectedBytes ([long]$tool.Asset.size) -ExpectedSha256 $tool.Sha256 `
            -MaximumBytes 128MB -Kind 'flash-tool' `
            -Version ([string]$tool.Release.tag_name) -Target 'windows-x64'))

        $manifestPath = Update-DmdClockStagingManifest -StagingRoot $layout.Root `
            -Artifacts @($artifacts)
        Write-DmdClockProvisioningLog -Event 'staging-complete' `
            -Detail "kind=firmware manifest=$manifestPath artifacts=$($artifacts.Count)"
        Write-Host ''
        Write-Host '[DONE] Verified firmware/tool payload staged without enumerating COM devices.' -ForegroundColor Green
        Write-Host "Manifest: $manifestPath"
        $artifacts | Select-Object artifactId, status, size, sha256, relativePath | Format-Table -AutoSize
    } else {
        Write-Host '[WHATIF] Firmware manifest downloads are required to resolve package names and hashes; no files or hardware were changed.' -ForegroundColor Yellow
    }
}

function Get-StagedFirmwareAndTool {
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)][string] $StagingSource
    )

    $required = @(
        "firmware.$($Target.Key).manifest",
        "firmware.$($Target.Key).package",
        'tool.esptool.windows-x64'
    )
    $staged = Test-DmdClockStagingManifest -Source $StagingSource `
        -RequiredArtifactIds $required
    $manifestArtifact = $staged.Artifacts["firmware.$($Target.Key).manifest"]
    $packageArtifact = $staged.Artifacts["firmware.$($Target.Key).package"]
    $toolArtifact = $staged.Artifacts['tool.esptool.windows-x64']
    if ([string]$manifestArtifact.target -ne $Target.Id -or
        [string]$packageArtifact.target -ne $Target.Id) {
        throw "The staged inventory target does not match $($Target.Product)."
    }
    $manifest = Get-Content -LiteralPath $manifestArtifact.ResolvedPath -Raw |
        ConvertFrom-Json
    Assert-CompatibleManifest -Manifest $manifest -Target $Target
    if ([long]$packageArtifact.size -ne [long]$manifest.package.size -or
        ([string]$packageArtifact.sha256).ToLowerInvariant() -ne
            ([string]$manifest.package.sha256).ToLowerInvariant() -or
        [string]$packageArtifact.version -ne [string]$manifest.version) {
        throw "The staged package inventory is stale or does not match its firmware manifest for $($Target.Product)."
    }

    if ($WhatIf) {
        if ([string]$toolArtifact.version -notmatch '^v5\.[0-9.]+$' -or
            [string]$toolArtifact.target -ne 'windows-x64') {
            throw 'The staged esptool inventory has an unsupported version or platform.'
        }
        Write-Host "[OK] Offline firmware package and esptool archive inventory verified for dry-run." -ForegroundColor Green
        return [pscustomobject]@{
            Package = [pscustomobject]@{
                Source = "Offline staging $($staged.Root)"
                Version = [string]$manifest.version
                Manifest = $manifest
                Root = $null
                Cache = $null
                IsLocal = $true
            }
            Tool = [pscustomobject]@{
                Path = $null
                Version = [string]$toolArtifact.version
            }
        }
    }

    $safeVersion = ([string]$manifest.version) -replace '[^0-9A-Za-z._-]', '_'
    $cacheRoot = Join-Path $DmdClockCacheRoot 'cache\firmware'
    $offlineRoot = Join-Path $cacheRoot "offline/$($Target.Key)/$safeVersion"
    $expandedPackage = Join-Path $offlineRoot 'package'
    Expand-VerifiedPackage -ArchivePath $packageArtifact.ResolvedPath `
        -Destination $expandedPackage -Manifest $manifest

    if ([string]$toolArtifact.version -notmatch '^v5\.[0-9.]+$' -or
        [string]$toolArtifact.target -ne 'windows-x64') {
        throw 'The staged esptool inventory has an unsupported version or platform.'
    }
    $safeToolVersion = ([string]$toolArtifact.version) -replace '[^0-9A-Za-z._-]', '_'
    $expandedTool = Join-Path $toolCacheRoot "offline/$safeToolVersion/package"
    if (-not (Test-Path -LiteralPath $expandedTool -PathType Container)) {
        Expand-DmdClockSafeArchive -ArchivePath $toolArtifact.ResolvedPath `
            -Destination $expandedTool -ContainmentRoot $toolCacheRoot
    }
    $executables = @(Get-ChildItem -LiteralPath $expandedTool -Filter 'esptool.exe' -File -Recurse)
    if ($executables.Count -ne 1) {
        throw 'The staged esptool archive does not contain exactly one esptool.exe.'
    }
    $versionOutput = @(& $executables[0].FullName version 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($versionOutput | Out-String) -notmatch [Regex]::Escape(
            ([string]$toolArtifact.version).TrimStart('v'))) {
        throw 'The staged esptool executable could not be verified.'
    }
    Write-Host "[OK] Offline firmware and esptool $($toolArtifact.version) verified." -ForegroundColor Green
    return [pscustomobject]@{
        Package = [pscustomobject]@{
            Source = "Offline staging $($staged.Root)"
            Version = [string]$manifest.version
            Manifest = $manifest
            Root = $expandedPackage
            Cache = $offlineRoot
            IsLocal = $true
        }
        Tool = [pscustomobject]@{
            Path = $executables[0].FullName
            Version = [string]$toolArtifact.version
        }
    }
}

function Assert-ConnectedHardware {
    param(
        [Parameter(Mandatory)] [string] $SelectedPort,
        [switch] $SkipPhysicalConfirmation
    )

    if (-not $SkipPhysicalConfirmation -and -not $identifiedDevice) {
        Write-Host ''
        Write-Warning 'Look at the model and revision printed on the physical board.'
    }
    $confirmation = if ($SkipPhysicalConfirmation -or $identifiedDevice) {
        $selectedTarget.Confirmation
    } elseif ($ConfirmHardware) {
        $ConfirmHardware.Trim()
    } else {
        Read-DmdClockHighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $selectedTarget.Confirmation `
            -Suffix " to confirm $($selectedTarget.Product)" `
            -RequiredParameter '-ConfirmHardware' `
            -Color Green
    }
    if ($selectedTarget.UnsupportedConfirmation -and
        $confirmation -ieq $selectedTarget.UnsupportedConfirmation) {
        throw "Cancelled: '$confirmation' is not the selected or supported board."
    }
    if ($confirmation -ine $selectedTarget.Confirmation) {
        throw 'Hardware confirmation was not accepted.'
    }

    Assert-DmdClockEsp32s3WithFlash -EsptoolPath $esptool.Path -Port $SelectedPort
    if (-not $SkipPhysicalConfirmation -and -not $identifiedDevice) {
        Write-Warning 'Chip detection cannot distinguish display models or PCB revisions; the board-label confirmation remains required.'
    }
}

function Get-DmdClockDeviceProbe {
    $ports = @(Get-DmdClockConnectedPorts)
    if ($ports.Count -eq 0) {
        return @()
    }
    $rows = @()
    foreach ($port in $ports) {
        $native = $port.InstanceId -match 'VID_303A&PID_1001'
        $banner = Read-DmdClockSerialBanner -Port $port.Port -NativeUsbJtag:$native -ToolCacheRoot $toolCacheRoot
        if ([string]::IsNullOrWhiteSpace($banner)) {
            $rows += [pscustomobject]@{
                Port = $port.Port
                Name = $port.Name
                Model = 'no banner read'
                App = '-'
                Signals = '-'
                Status = 'Not verified'
                Target = $null
                ModelKey = $null
                Revision = $null
                Identified = $false
            }
            continue
        }
        $probe = Get-DmdClockBoardProbe -BannerText $banner
        $target = Resolve-DmdClockDeviceFromProbe -Probe $probe
        $modelLabel = if ($target) { $target.ShortLabel } else { $null }
        $recognized = $null -ne $target -or -not [string]::IsNullOrWhiteSpace($probe.AppVersion)
        $signalParts = @(
            $probe.Resolution,
            $probe.TouchController,
            $probe.Accelerometer
        ) | Where-Object { $_ }
        $rows += [pscustomobject]@{
            Port = $port.Port
            Name = $port.Name
            Model = if ($modelLabel) {
                $modelLabel
            } elseif ($recognized) {
                'DMDClock (model unclear)'
            } else {
                'unrecognized'
            }
            App = if ($probe.AppVersion) { $probe.AppVersion } else { '-' }
            Signals = if ($signalParts) { $signalParts -join ' / ' } else { '-' }
            Status = if ($recognized) { 'OK to flash' } else { 'Not verified' }
            Target = $target
            ModelKey = if ($target) { $target.Key } else { $null }
            Revision = $probe.Revision
            Identified = $null -ne $target
        }
    }
    return $rows
}

function Show-DeviceTable {
    param([Parameter(Mandatory)] [object[]] $Rows)
    Show-DmdClockDeviceTable -Rows $Rows
}

function Resolve-DmdClockModelLabel {
    param([Parameter(Mandatory)] [string] $Value)

    $targets = @(Get-DmdClockHardwareTargets)
    $trimmed = $Value.Trim()
    foreach ($target in $targets) {
        if ($trimmed -ieq $target.Key -or
            $trimmed -ieq $target.ShortLabel -or
            $trimmed -ieq $target.Product) {
            return $target.ShortLabel
        }
    }
    $normalized = $trimmed.ToLowerInvariant() -replace '\s+', ' '
    if ($normalized -eq '7' -or $normalized -eq '7 inch' -or $normalized -eq 'waveshare7') {
        return 'Waveshare 7'
    }
    if ($normalized -match '3\.49' -or $normalized -match '349' -or $normalized -match '3xx') {
        return 'Waveshare 3.49B'
    }
    return $trimmed
}

function Get-DmdClockSuggestedName {
    param([Parameter(Mandatory)] [string] $Mac)

    $hex = ($Mac -replace '[^0-9a-fA-F]', '')
    if ($hex.Length -lt 4) { return $null }
    return 'DMDClock-' + $hex.Substring($hex.Length - 4).ToUpperInvariant()
}

function Read-DmdClockPromptOrDefault {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [string] $Default
    )

    $answer = Read-Host $Prompt
    if ($null -eq $answer) {
        throw "Input ended before '$Prompt' was answered. Supply the probe values as interactive input."
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Default
    }
    return $answer.Trim()
}

function Set-DmdClockDeviceName {
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $DeviceName
    )

    $url = "http://$IpAddress/api/settings"
    $body = @{ deviceName = $DeviceName } | ConvertTo-Json
    $response = Invoke-RestMethod -Uri $url -Method Post -Body $body `
        -ContentType 'application/json' -TimeoutSec 10
    return $response
}

function Write-DmdClockPortMap {
    param([Parameter(Mandatory)] [object[]] $Entries)

    $directory = Join-Path $DmdClockCacheRoot ''
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory 'ports.json'
    $map = [ordered]@{
        schema = 'dmdclock-port-map'
        version = 1
        probedAt = [DateTime]::UtcNow.ToString('o')
        ports = @($Entries)
    }
    $json = $map | ConvertTo-Json -Depth 6
    $temp = $path + '.tmp'
    [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $path, $true)
    return $path
}

function Assert-FactoryRecoveryRevision {
    param([Parameter(Mandatory)] [string] $Revision)

    Write-Host ''
    Write-Warning 'Factory images for 3.49B V1 and V2 are not interchangeable.'
    $confirmation = if ($BoardRevision) {
        $BoardRevision
    } else {
        Read-DmdClockHighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $Revision `
            -Suffix " to confirm the physical 3.49B $Revision marking" `
            -RequiredParameter '-BoardRevision' `
            -Color Green
    }
    if ($confirmation -ine $Revision) {
        throw 'PCB revision confirmation was not accepted.'
    }
}

function Assert-DmdFirmwareRevision {
    param(
        [Parameter(Mandatory)] $Target,
        [string] $DetectedRevision
    )

    if ([string]::IsNullOrWhiteSpace($Target.RequiredFirmwareRevision)) {
        return
    }

    $requiredRevision = [string]$Target.RequiredFirmwareRevision
    if (-not [string]::IsNullOrWhiteSpace($DetectedRevision)) {
        if ($DetectedRevision -ieq $requiredRevision) {
            Write-Host "[OK] UART probe confirms 3.49B $DetectedRevision / Rev1.1" -ForegroundColor Green
            return
        }
        throw "The connected 3.49B reports $DetectedRevision, but this DMDClock image supports only 3.49B $requiredRevision / Rev1.1. Refusing to continue."
    }

    Write-Host ''
    Write-Warning 'DMDClock firmware for 3.49B V1 and V2 is not interchangeable.'
    $confirmation = if ($BoardRevision) {
        $BoardRevision
    } else {
        Read-DmdClockHighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $requiredRevision `
            -Suffix " to confirm the physical 3.49B $requiredRevision / Rev1.1 marking" `
            -RequiredParameter '-BoardRevision' `
            -Color Green
    }
    if ($confirmation -ine $requiredRevision) {
        throw "This DMDClock image supports only 3.49B $requiredRevision / Rev1.1."
    }
}

function Get-SelectedFlashFiles {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)] [string] $Mode
    )

    $modeProperty = if ($Mode -eq 'FullReset') { 'full' } else { $Mode.ToLowerInvariant() }
    $files = @($Package.Manifest.flash.$modeProperty.files)
    $resolved = @()
    foreach ($file in $files) {
        Assert-DmdClockSafeRelativePath -RelativePath ([string]$file.path)
        $path = Join-Path $Package.Root ([string]$file.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Firmware image is missing: $path"
        }
        Assert-DmdClockSha256Hash -Path $path -ExpectedHash ([string]$file.sha256)
        $resolved += [pscustomobject]@{
            Offset = [string]$file.offset
            Path = $path
            RelativePath = [string]$file.path
        }
    }
    return $resolved
}

function Invoke-FirmwareFlash {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [string] $SelectedPort,
        [switch] $SkipIfIdentified
    )

    $resetNvs = $Mode -eq 'FullReset'
    if ($resetNvs -and $Force) {
        throw 'Complete installation with settings reset requires the final RESET confirmation; -Force is not accepted.'
    }

    $files = @(Get-SelectedFlashFiles -Package $Package -Mode $Mode)
    $settings = $Package.Manifest.flash.settings
    Write-Host ''
    Write-Host 'Flash summary:'
    Write-Host "  Source:   $($Package.Source)"
    Write-Host "  Version:  $($Package.Version)" -ForegroundColor Cyan
    Write-Host "  Target:   $($selectedTarget.Product)"
    Write-Host "  Port:     $SelectedPort" -ForegroundColor Cyan
    Write-Host "  Device:   $($script:selectedPortIdentity.Name)"
    Write-Host "  PnP ID:   $($script:selectedPortIdentity.InstanceId)"
    Write-Host "  Mode:     $Mode" -ForegroundColor Yellow
    Write-Host "  Package:  $($Package.Manifest.package.sha256) (SHA-256)"
    if ($resetNvs) {
        Write-Host "  NVS:      erased at $nvsRegionOffset (size $nvsRegionSize)" -ForegroundColor Yellow
        Write-Warning 'The microSD card is untouched; dmd\config\settings.json can restore old settings at boot.'
    } else {
        Write-Host '  NVS:      preserved (no erase command is used)' -ForegroundColor Green
    }
    Write-Host '  microSD card:  untouched' -ForegroundColor Green
    foreach ($file in $files) {
        Write-Host "  $($file.Offset)  $($file.RelativePath)"
    }
    Write-DmdClockProvisioningLog -Event 'flash-plan' -Detail (
        "target=$($selectedTarget.Id) port=$SelectedPort pnp=$($script:selectedPortIdentity.InstanceId) " +
        "mode=$Mode reset_nvs=$resetNvs version=$($Package.Version) package_sha256=$($Package.Manifest.package.sha256) " +
        "files=$(($files | ForEach-Object { $_.Offset + ':' + $_.RelativePath }) -join ',')")

    Assert-DmdClockSerialPortUnchanged -SelectedPort $SelectedPort `
        -PortIdentity $script:selectedPortIdentity -Context 'flashing'

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] All downloads, hashes, and hardware checks passed; flash was skipped.' `
            -ForegroundColor Yellow
        return $false
    }

    if (-not $Force -and -not $SkipIfIdentified) {
        $confirmationToken = if ($resetNvs) { 'RESET' } else { 'FLASH' }
        $confirmationAction = if ($resetNvs) {
            'erase device settings and write the complete installation'
        } else {
            'write this firmware'
        }
        $confirmation = Read-DmdClockHighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $confirmationToken `
            -Suffix " (uppercase or lowercase) to $confirmationAction" `
            -RequiredParameter '-Force' `
            -Color Yellow
        if ($confirmation -ine $confirmationToken) {
            Write-Host 'Flash cancelled. The verified download remains cached.' `
                -ForegroundColor Yellow
            Write-DmdClockProvisioningLog -Event 'flash-cancelled' -Detail "port=$SelectedPort mode=$Mode"
            return $false
        }
    }

    if ($resetNvs) {
        Write-Host ''
        Write-Host "Erasing NVS settings region $nvsRegionOffset (size $nvsRegionSize)..." -ForegroundColor Yellow
        Write-DmdClockProvisioningLog -Event 'nvs-erase-started' `
            -Detail "port=$SelectedPort region=$nvsRegionOffset size=$nvsRegionSize"
        $null = Invoke-DmdClockEsptoolChecked -EsptoolPath $esptool.Path -Arguments @(
            '--chip', 'esp32s3',
            '--port', $SelectedPort,
            '--baud', '460800',
            '--before', 'default-reset',
            '--after', 'no-reset',
            'erase_region',
            $nvsRegionOffset,
            $nvsRegionSize
        )
        Write-DmdClockProvisioningLog -Event 'nvs-erase-complete' `
            -Detail "port=$SelectedPort region=$nvsRegionOffset size=$nvsRegionSize"
    }

    $arguments = @(
        '--chip', 'esp32s3',
        '--port', $SelectedPort,
        '--baud', '460800',
        '--before', 'default-reset',
        '--after', 'hard-reset',
        'write-flash',
        '--flash-mode', [string]$settings.mode,
        '--flash-freq', [string]$settings.frequency,
        '--flash-size', [string]$settings.size
    )
    foreach ($file in $files) {
        $arguments += @($file.Offset, $file.Path)
    }
    $null = Invoke-DmdClockEsptoolChecked -EsptoolPath $esptool.Path -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] Firmware written and verified by esptool; the board was reset.' `
        -ForegroundColor Green
    if ($resetNvs) {
        Write-Host 'NVS settings were reset. Remove dmd\config\settings.json from the microSD card' `
            -ForegroundColor Cyan
        Write-Host 'before reinserting it if the saved card settings must also be discarded.' `
            -ForegroundColor Cyan
    }
    $cacheLocations = Get-DmdClockCacheLocations
    Write-Host ''
    Write-Host "Cached files: $($cacheLocations.Firmware)" -ForegroundColor DarkGray
    Write-Host "              $($cacheLocations.Tools)" -ForegroundColor DarkGray
    Write-Host 'To free disk space, delete the cache folders above.' -ForegroundColor DarkGray
    Write-DmdClockProvisioningLog -Event 'flash-complete' `
        -Detail "target=$($selectedTarget.Id) port=$SelectedPort mode=$Mode version=$($Package.Version)"
    return $true
}

function Invoke-FactoryRecoveryFlash {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)] [string] $SelectedPort
    )

    Write-Host ''
    Write-Host 'Factory recovery summary:'
    Write-Host "  Source:   $($Package.Source)"
    Write-Host "  Target:   $($selectedTarget.Product) $($Package.Revision)"
    Write-Host "  Port:     $SelectedPort" -ForegroundColor Cyan
    Write-Host "  Device:   $($script:selectedPortIdentity.Name)"
    Write-Host "  PnP ID:   $($script:selectedPortIdentity.InstanceId)"
    Write-Host '  Offset:   0x0'
    Write-Host "  Image:    $($Package.FileName)"
    Write-Host "  SHA-256:  $($Package.Sha256)"
    Write-Warning 'Factory recovery replaces the current internal-flash contents, including stored settings.'
    Write-Host '  microSD card:  untouched' -ForegroundColor Green
    Write-DmdClockProvisioningLog -Event 'factory-recovery-plan' -Detail (
        "target=$($selectedTarget.Id) revision=$($Package.Revision) port=$SelectedPort " +
        "pnp=$($script:selectedPortIdentity.InstanceId) image=$($Package.FileName) sha256=$($Package.Sha256)")

    Assert-DmdClockSerialPortUnchanged -SelectedPort $SelectedPort `
        -PortIdentity $script:selectedPortIdentity -Context 'factory recovery'

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] Image, hash, revision, and hardware checks passed; factory recovery was skipped.' `
            -ForegroundColor Yellow
        return $false
    }

    $confirmation = Read-DmdClockHighlightedConfirmation `
        -Prefix 'Type ' `
        -Token 'FLASH' `
        -Suffix ' (uppercase or lowercase) to restore the official factory image' `
        -RequiredParameter 'interactive FLASH confirmation' `
        -Color Yellow
    if ($confirmation -ine 'FLASH') {
            Write-Host 'Factory recovery cancelled. The verified image remains cached.' `
                -ForegroundColor Yellow
        Write-DmdClockProvisioningLog -Event 'factory-recovery-cancelled' `
            -Detail "revision=$($Package.Revision) port=$SelectedPort"
        return $false
    }

    $arguments = @(
        '--chip', 'esp32s3',
        '--port', $SelectedPort,
        '--baud', '460800',
        '--before', 'default-reset',
        '--after', 'hard-reset',
        'write-flash',
        '0x0', $Package.ImagePath
    )
    $null = Invoke-DmdClockEsptoolChecked -EsptoolPath $esptool.Path -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] Official factory image written and verified; the board was reset.' `
        -ForegroundColor Green
    Write-Host 'Exercise the LCD, touch, and microSD card tests before installing custom firmware.'
    $cacheLocations = Get-DmdClockCacheLocations
    Write-Host ''
    Write-Host "Cached files: $($cacheLocations.Firmware)" -ForegroundColor DarkGray
    Write-DmdClockProvisioningLog -Event 'factory-recovery-complete' `
        -Detail "revision=$($Package.Revision) port=$SelectedPort sha256=$($Package.Sha256)"
    return $true
}

function Show-FirmwareDryRun {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)][string] $Mode
    )

    $ports = @(Get-DmdClockConnectedPorts)
    if ($Port -and $Port -notin @($ports.Port)) {
        throw "Dry-run requested '$Port', but that COM port is not currently enumerated."
    }
    Write-Host ''
    Write-Host '[DRY RUN] No files, caches, serial ports, flash, or hardware will be changed.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Summary:' -ForegroundColor Cyan
    Write-Host "  Target:    $($selectedTarget.Product)"
    Write-Host "  Revision:  $($selectedTarget.SupportedBoard)"
    Write-Host "  Firmware:  $($Package.Version)"
    Write-Host "  Mode:      $Mode"
    Write-Host "  Tool:      $(if ($esptool) { $esptool.Version } else { 'official esptool v5 (resolved only during execution)' })"
    Write-Host "  Package:   $($Package.Manifest.package.size) bytes"
    Write-Host "  SHA-256:   $($Package.Manifest.package.sha256)"
    Write-Host ''
    Write-Host 'Files to flash:' -ForegroundColor Cyan
    Write-Host ('  {0,-9} {1,-28} {2,10}  {3}' -f 'Offset', 'File', 'Size (bytes)', 'SHA-256')
    $packageMode = if ($Mode -eq 'FullReset') { 'full' } else { $Mode.ToLowerInvariant() }
    foreach ($file in @($Package.Manifest.flash.$packageMode.files)) {
        Write-Host ('  {0,-9} {1,-28} {2,10}  {3}' -f
            [string]$file.offset, [string]$file.path,
            [string]$file.size, [string]$file.sha256)
    }
    if ($Mode -eq 'FullReset') {
        Write-Host ''
        Write-Host "NVS plan: erase settings region $nvsRegionOffset (size $nvsRegionSize)." `
            -ForegroundColor Yellow
        Write-Host 'The microSD card remains untouched; remove dmd\config\settings.json separately.' `
            -ForegroundColor Yellow
    }
    Write-Host ''
    if ($Port) {
        $identity = @($ports | Where-Object Port -eq $Port)[0]
        Write-Host "COM plan:  $($identity.Port) - $($identity.Name) - $($identity.InstanceId)"
    } elseif ($ports.Count) {
        Write-Host 'Available COM devices (none selected or opened):'
        foreach ($identity in $ports) {
            Write-Host "  $($identity.Port) - $($identity.Name) - $($identity.InstanceId)"
        }
    } else {
        Write-Host 'Available COM devices: none (allowed in dry-run).'
    }
}

# --- Main flow ---
$identifiedDevice = $false

$willPrompt = -not $CheckRequirements -and
    (-not $Board -or
        ([string]::IsNullOrWhiteSpace($Source) -and -not $ReleaseTag) -or
        ($FactoryRecovery -and -not $BoardRevision) -or
        (-not $WhatIf -and -not $FactoryRecovery -and -not $FlashMode) -or
        (-not $WhatIf -and -not $Port))
Show-SupportedHardwareBanner -ShowGuidance:($Wizard -or $willPrompt)

$requirementsPath = if (-not [string]::IsNullOrWhiteSpace($Source)) {
    [IO.Path]::GetFullPath($Source)
} elseif ([string]::IsNullOrWhiteSpace($Destination)) {
    Join-Path $DmdClockCacheRoot 'DmdClockFiles'
} else {
    [IO.Path]::GetFullPath($Destination)
}
$requirements = Invoke-DmdClockRequirementsCheck `
    -Operation $(if ($CheckRequirements) { 'Check' } elseif ($Source) { 'Offline' } elseif ($DownloadOnly) { 'Download' } else { 'Flash' }) `
    -DataPath $requirementsPath `
    -MinimumFreeBytes 256MB `
    -RequiredCommands @(
        'Get-CimInstance',
        'Get-FileHash',
        'Get-PnpDevice',
        'Invoke-RestMethod',
        'Invoke-WebRequest'
    ) `
    -RequireNetwork:(((-not $CheckRequirements) -and [string]::IsNullOrWhiteSpace($Source)) -or
        ($CheckRequirements -and $DownloadOnly -and [string]::IsNullOrWhiteSpace($Source))) `
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
if ($ProbePorts) {
    $ports = @(Get-DmdClockConnectedPorts)
    if ($ports.Count -eq 0) {
        throw 'No serial port was detected.'
    }
    if ($null -eq $esptool) {
        $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $toolCacheRoot
    }
        $entries = @()
    foreach ($port in $ports) {
        Write-Host ''
        Write-Host "Probing $($port.Port) ($($port.Name))..." -ForegroundColor Cyan
        $native = $port.InstanceId -match 'VID_303A&PID_1001'
        $banner = Read-DmdClockSerialBanner -Port $port.Port -NativeUsbJtag:$native -ToolCacheRoot $toolCacheRoot
        $probe = if ($banner) { Get-DmdClockBoardProbe -BannerText $banner } else { $null }
        $target = if ($probe) { Resolve-DmdClockDeviceFromProbe -Probe $probe } else { $null }
        $suggestedLabel = if ($target) { $target.ShortLabel } else { $null }
        $mac = $null
        try {
            $chipOutput = Invoke-DmdClockEsptoolChecked -EsptoolPath $esptool.Path -Arguments @(
                '--chip', 'esp32s3', '--port', $port.Port, 'chip-id')
            if ($chipOutput -match 'MAC:\s*([0-9a-fA-F:]+)') {
                $mac = $Matches[1]
            }
        }
        catch {
            Write-Warning "Could not read the chip identity on $($port.Port): $($_.Exception.Message)"
        }
        $suggestedName = if ($mac) { Get-DmdClockSuggestedName -Mac $mac } else { $null }
        $confirmedName = Read-DmdClockPromptOrDefault `
            -Prompt "  Device name (Enter keeps '$suggestedName')" -Default $suggestedName
        $confirmedModel = Read-DmdClockPromptOrDefault `
            -Prompt "  Model (Enter keeps '$suggestedLabel')" -Default $suggestedLabel
        $confirmedModel = if ($confirmedModel) {
            Resolve-DmdClockModelLabel -Value $confirmedModel
        } else { $null }
        $nameStatus = 'not applicable'
        if ($confirmedName -and $probe -and $probe.LanIp) {
            try {
                Set-DmdClockDeviceName -IpAddress $probe.LanIp -DeviceName $confirmedName | Out-Null
                $nameStatus = 'applied'
            }
            catch {
                $nameStatus = "failed: $($_.Exception.Message)"
            }
        }
        $probeObject = if ($probe) {
            [pscustomobject]@{
                resolution = $probe.Resolution
                touch = $probe.TouchController
                accelerometer = $probe.Accelerometer
                app = $probe.AppVersion
            }
        } else { $null }
        $entries += [pscustomobject]@{
            port = $port.Port
            deviceName = $confirmedName
            model = $confirmedModel
            probe = $probeObject
            mac = $mac
            pnp = $port.InstanceId
            ip = if ($probe) { $probe.LanIp } else { $null }
        }
        $signalText = if ($probe) {
            "$($probe.Resolution) / $($probe.TouchController) / $($probe.Accelerometer)"
        } else { 'no boot banner read' }
        Write-Host "  Detected: $signalText -> $confirmedModel; MAC=$mac; name='$confirmedName' ($nameStatus)"
    }

    Write-Host ''
    Write-Host ('{0,-7} {1,-14} {2,-18} {3,-10} {4,-10} {5,-8} {6,-6} {7}' -f
        'COM port', 'Device', 'Model', 'Resolution', 'Touch', 'IMU', 'App', 'IP') -ForegroundColor Cyan
    foreach ($entry in $entries) {
        Write-Host ('{0,-7} {1,-14} {2,-18} {3,-10} {4,-10} {5,-8} {6,-6} {7}' -f
            $entry.port,
            $(if ($entry.deviceName) { $entry.deviceName } else { '-' }),
            $(if ($entry.model) { $entry.model } else { 'unknown' }),
            $(if ($entry.probe -and $entry.probe.resolution) { $entry.probe.resolution } else { '-' }),
            $(if ($entry.probe -and $entry.probe.touch) { $entry.probe.touch } else { '-' }),
            $(if ($entry.probe -and $entry.probe.accelerometer) { $entry.probe.accelerometer } else { '-' }),
            $(if ($entry.probe -and $entry.probe.app) { $entry.probe.app } else { '-' }),
            $(if ($entry.ip) { $entry.ip } else { '-' }))
    }
    $mapPath = Write-DmdClockPortMap -Entries $entries
    Write-Host ''
    Write-Host "Port map saved: $mapPath" -ForegroundColor Green
    Set-DmdClockOperationResult -Status completed -Operation 'Probe serial ports'
    return
}
if ($DownloadOnly -and -not [string]::IsNullOrWhiteSpace($Destination) -and
    -not [string]::IsNullOrWhiteSpace($Source)) {
    throw 'Do not combine -DownloadOnly -Destination with -Source.'
}

$runOutcome = 'cancelled'
$runDetail = ''
$logPath = $null
$wizardState = $null
$wizardDevices = $null
if ($Wizard -or $willPrompt) {
    if (-not $WhatIf -and -not $DownloadOnly -and -not $ProbePorts -and
        -not [Console]::IsInputRedirected) {
        if ($null -eq $esptool) {
            $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $toolCacheRoot
        }
        Write-Host ''
        Write-Host 'Scanning for connected DMDClock devices...' -ForegroundColor Cyan
        $wizardDevices = @(Get-DmdClockDeviceProbe)
    }
    $wizardState = New-DmdClockWizard -Title 'DMDClock ESP32 flash' -Devices $wizardDevices
}
$quickSelect = $null
if ($null -ne $wizardDevices -and -not $FactoryRecovery) {
    $offered = @($wizardDevices | Where-Object { $_.Identified })
    if ($offered.Count -eq 1) {
        $quickSelect = $offered[0]
        Write-Host ''
        Write-Host "Auto-detected: $($quickSelect.Port) - $($quickSelect.Model)" -ForegroundColor Green
    } elseif ($offered.Count -gt 1) {
        Show-DeviceTable -Rows $wizardDevices
        $choice = Read-DmdClockMenuChoice -Prompt 'Select device to flash' -Minimum 1 `
            -Maximum ($wizardDevices.Count + 1) -Wizard $wizardState -RequiredParameter '-Port'
        if ($choice -gt $wizardDevices.Count) {
            Set-DmdClockOperationResult -Status cancelled -Operation 'Flash firmware' `
                -Detail 'No device was selected.'
            return
        }
        $quickSelect = $wizardDevices[$choice - 1]
    }
    if ($null -ne $quickSelect -and $null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Device' `
            -Value "$($quickSelect.Port) - $($quickSelect.Model)"
        $wizardState.Devices = $null
    }
}
if (-not $WhatIf) {
    $operation = if ($DownloadOnly -and -not [string]::IsNullOrWhiteSpace($Destination)) {
        'stage-firmware'
    } elseif ($DownloadOnly -and -not [string]::IsNullOrWhiteSpace($Source)) {
        'verify-offline-firmware'
    } elseif ($FactoryRecovery) {
        'factory-recovery'
    } elseif ($DownloadOnly) {
        'download-firmware'
    } else {
        'flash-firmware'
    }
    $logDirectory = if ($operation -eq 'stage-firmware') {
        Join-Path ([IO.Path]::GetFullPath($Destination)) 'Logs'
    } else {
        Join-Path $DmdClockCacheRoot 'Logs\Provisioning'
    }
    $logPath = Start-DmdClockProvisioningLog -LogDirectory $logDirectory `
        -Operation $operation
    Write-Host "Log: $logPath"
    Write-DmdClockRequirementsLog -Requirements $requirements
    Write-DmdClockProvisioningLog -Event 'invocation' -Detail (
        "repository=$Repository board=$Board release=$ReleaseTag flash_mode=$FlashMode " +
        "download_only=$DownloadOnly source=$Source destination=$Destination")
}

try {
    if ($DownloadOnly -and -not [string]::IsNullOrWhiteSpace($Destination)) {
        Invoke-FirmwareDownloadOnly -StagingDestination $Destination
        $runOutcome = 'completed'
        return
    }
    if (-not $WhatIf) {
        $cacheRoot = Join-Path $DmdClockCacheRoot 'cache\firmware'
        New-Item -ItemType Directory -Force -Path $cacheRoot, $toolCacheRoot | Out-Null
    }

    $selectedTarget = if ($null -ne $quickSelect -and $null -ne $quickSelect.Target) {
        $quickSelect.Target
    } else {
        Select-HardwareTarget
    }
    if ($null -eq $selectedTarget) { return }
    $identifiedDevice = $null -ne $quickSelect -and $quickSelect.Identified
    Write-DmdClockProvisioningLog -Event 'target-selected' -Detail (
        "key=$($selectedTarget.Key) id=$($selectedTarget.Id) product=$($selectedTarget.Product) " +
        "revision=$($selectedTarget.SupportedBoard) auto_identified=$identifiedDevice")

if ($FactoryRecovery) {
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        throw 'Offline factory recovery staging is not implemented; use verified production firmware or the pinned online recovery path.'
    }
    if ($selectedTarget.Key -ne 'Waveshare349B') {
        throw 'Factory recovery mode is only supported for Waveshare ESP32-S3-Touch-LCD-3.49B.'
    }
    if ($ReleaseTag -or $FlashMode) {
        throw 'Do not combine -FactoryRecovery with -ReleaseTag or -FlashMode.'
    }
    if ($Force) {
        throw 'Factory recovery requires the final FLASH confirmation; -Force is not accepted.'
    }

    $revision = Select-FactoryRecoveryRevision
    if ($null -eq $revision) { return }
    if ($WhatIf) {
        $image = $factoryRecoveryImages[$revision]
        $package = [pscustomobject]@{
            Source = "https://raw.githubusercontent.com/$($image.Repository)/$($image.Commit)/Firmware/$($image.FileName)"
            Revision = $revision
            ImagePath = $null
            FileName = $image.FileName
            Sha256 = $image.Sha256
            Cache = $null
        }
    } else {
        $package = Get-FactoryRecoveryPackage -Revision $revision
    }
    Write-Host ''
    Write-Host '[OK] Official factory recovery image verified' -ForegroundColor Green
    Write-Host "  Source:   $($package.Source)"
    Write-Host "  Revision: $($package.Revision)"
    if ($package.Cache) { Write-Host "  Cache:    $($package.Cache)" }
    if ($DownloadOnly) {
        Write-Host 'Download-only mode selected; nothing was flashed.'
        $runOutcome = 'completed'
        return
    }

    if ($WhatIf) {
        $ports = @(Get-DmdClockConnectedPorts)
        Write-Host ''
        Write-Host '[DRY RUN] Factory image URL, pinned revision, size, and SHA-256 were resolved; no file, cache, COM port, or hardware was changed.' -ForegroundColor Yellow
        Write-Host "  Target:   $($selectedTarget.Product) $revision"
        Write-Host "  Image:    $($package.FileName)"
        Write-Host "  SHA-256:  $($package.Sha256)"
        Write-Host "  COM plan: $(if ($Port) { $Port } elseif ($ports.Count) { 'none selected; available: ' + ($ports.Port -join ', ') } else { 'none connected (allowed in dry-run)' })"
        return
    }

    $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $toolCacheRoot
    $portResult = Select-DmdClockSerialPort -Port $Port -Context 'factory recovery'
    $script:selectedPortIdentity = $portResult.Identity
    $selectedPort = $portResult.Port
    Write-DmdClockProvisioningLog -Event 'serial-selected' -Detail (
        "port=$selectedPort name=$($script:selectedPortIdentity.Name) pnp=$($script:selectedPortIdentity.InstanceId) " +
        "tool_version=$($esptool.Version)")
    Assert-ConnectedHardware -SelectedPort $selectedPort
    Assert-FactoryRecoveryRevision -Revision $revision
    $flashed = Invoke-FactoryRecoveryFlash -Package $package -SelectedPort $selectedPort
    $runOutcome = if ($flashed) { 'completed' } else { 'cancelled' }
    return
}

if (-not [string]::IsNullOrWhiteSpace($Source)) {
    $offline = Get-StagedFirmwareAndTool -Target $selectedTarget `
        -StagingSource $Source
    $package = $offline.Package
    $esptool = $offline.Tool
} else {
    $selection = Select-CompatibleRelease -Target $selectedTarget
    if ($null -eq $selection) { return }
    if ($WhatIf) {
        Assert-CompatibleManifest -Manifest $selection.Manifest -Target $selectedTarget
        $package = [pscustomobject]@{
            Source = "GitHub release $($selection.Release.tag_name) (metadata only)"
            Version = [string]$selection.Manifest.version
            Manifest = $selection.Manifest
            Root = $null
            Cache = $null
            IsLocal = $false
        }
    } else {
        $package = Get-ReleasePackage -Selection $selection
    }
}

Write-Host ''
Write-Host '[OK] Firmware package verified' -ForegroundColor Green
Write-Host "  Source:  $($package.Source)"
Write-Host "  Version: $($package.Version)"
Write-Host "  Target:  $($selectedTarget.Product)"
Write-DmdClockProvisioningLog -Event 'firmware-verified' -Detail (
    "source=$($package.Source) version=$($package.Version) target=$($selectedTarget.Id) " +
    "package_size=$($package.Manifest.package.size) package_sha256=$($package.Manifest.package.sha256)")
if ($package.Cache) {
    Write-Host "  Cache:   $($package.Cache)"
}

if ($DownloadOnly) {
    Write-Host 'Download-only mode selected; nothing was flashed.'
    $cacheLocations = Get-DmdClockCacheLocations
    Write-Host ''
    Write-Host "Cached files: $($cacheLocations.Firmware)" -ForegroundColor DarkGray
    Write-Host "              $($cacheLocations.Tools)" -ForegroundColor DarkGray
    Write-Host 'To free disk space, delete the cache folders above.' -ForegroundColor DarkGray
    $runOutcome = 'completed'
    return
}

if ($WhatIf -and -not $FlashMode) {
    $FlashMode = 'Application'
} elseif (-not $FlashMode) {
    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host 'Flash mode:'
    Write-Host '  [1] Application update (Recommended; preserves bootloader, partitions and NVS)' `
        -ForegroundColor Green
    Write-Host '  [2] Complete installation (bootloader, partition table and application; preserves NVS)' `
        -ForegroundColor Yellow
    Write-Host '  [3] Complete installation + reset device settings (erases NVS; microSD untouched)' `
        -ForegroundColor Red
    Write-Host '  [4] Keep download only and exit' -ForegroundColor DarkGray
    switch (Read-DmdClockMenuChoice -Prompt 'Select flash mode' -Minimum 1 -Maximum 4 -Default 1 `
            -RequiredParameter '-FlashMode') {
        1 { $FlashMode = 'Application' }
        2 { $FlashMode = 'Full' }
        3 { $FlashMode = 'FullReset' }
        4 {
            Write-Host 'Nothing was flashed. The verified download remains cached.'
            return
        }
    }
    if ($null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Flash mode' `
            -Value $(switch ($FlashMode) {
                'Application' { 'Application update' }
                'Full' { 'Complete installation' }
                'FullReset' { 'Complete installation + reset device settings' }
            })
    }
}

if ($WhatIf) {
    Show-FirmwareDryRun -Package $package -Mode $FlashMode
    return
}

if ($null -eq $esptool) {
    $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $toolCacheRoot
}
$quickPort = if ($null -ne $quickSelect) { $quickSelect.Port } else { $null }
$portResult = Select-DmdClockSerialPort -Port $Port -QuickPort $quickPort `
    -WizardState $wizardState -Context 'flashing'
$script:selectedPortIdentity = $portResult.Identity
$selectedPort = $portResult.Port
Write-DmdClockProvisioningLog -Event 'serial-selected' -Detail (
    "port=$selectedPort name=$($script:selectedPortIdentity.Name) pnp=$($script:selectedPortIdentity.InstanceId) " +
    "tool_version=$($esptool.Version)")
Assert-ConnectedHardware -SelectedPort $selectedPort `
    -SkipPhysicalConfirmation:($null -ne $quickSelect -and $identifiedDevice)
    Assert-DmdFirmwareRevision -Target $selectedTarget `
        -DetectedRevision $(if ($null -ne $quickSelect) { $quickSelect.Revision } else { $null })
    $flashed = Invoke-FirmwareFlash -Package $package -Mode $FlashMode `
        -SelectedPort $selectedPort -SkipIfIdentified:($null -ne $quickSelect -and $identifiedDevice)
    $runOutcome = if ($flashed) { 'completed' } else { 'cancelled' }
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
    Set-DmdClockOperationResult -Status failed -Operation 'Flash firmware' `
        -Detail $originalError.Exception.Message
    throw $originalError
}
finally {
    Complete-DmdClockProvisioningLogSafely -LogPath $logPath `
        -Outcome $runOutcome -Detail $runDetail
    if ($runOutcome -ne 'failed') {
        $resultStatus = if ($WhatIf) { 'dry-run' } else { $runOutcome }
        Set-DmdClockOperationResult -Status $resultStatus -Operation 'Flash firmware' `
            -Detail $runDetail
    }
}
