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

$maximumManifestBytes = 1MB
$maximumPackageBytes = 64MB
$maximumToolBytes = 128MB
$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$outputRoot = Join-Path $localData 'DmdClock'
$cacheRoot = Join-Path $outputRoot 'cache\firmware'
$toolCacheRoot = Join-Path $outputRoot 'tools\esptool'
$esptoolRepository = 'espressif/esptool'
$esptoolReleasesUrl = "https://github.com/$esptoolRepository/releases"
$nvsRegionOffset = '0x9000'
$nvsRegionSize = '0x6000'

$hardwareTargets = @(
    [pscustomobject]@{
        Key = 'Waveshare7'
        Id = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
        Product = 'Waveshare ESP32-S3-Touch-LCD-7'
        ShortLabel = 'Waveshare 7'
        Display = '800x480'
        Module = 'ESP32-S3-WROOM-1-N16R8'
        Confirmation = '7'
        UnsupportedConfirmation = '7B'
        RequiredFirmwareRevision = $null
        SupportedBoard = '7'
        TouchEnabled = $true
        TouchController = 'GT911'
        Accelerometer = $null
        Homepage = 'https://www.waveshare.com/esp32-s3-touch-lcd-7.htm'
        Documentation = 'https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7'
        Driver = 'https://www.wch-ic.com/downloads/CH343SER_EXE.html'
        PortInstructions = @(
            'Use a data-capable USB cable.',
            'Connect it to the USB TO UART Type-C port.',
            'Do not assume that every USB or power connector supports UART.'
        )
    },
    [pscustomobject]@{
        Key = 'Waveshare349B'
        Id = 'waveshare-esp32-s3-touch-lcd-3-49b-v2-640x172-n16r8'
        Product = 'Waveshare ESP32-S3-Touch-LCD-3.49B'
        ShortLabel = 'Waveshare 3.49B'
        Display = '640x172'
        Module = 'ESP32-S3-WROOM-1-N16R8'
        Confirmation = '3.49B'
        UnsupportedConfirmation = $null
        RequiredFirmwareRevision = 'V2'
        SupportedBoard = '3.49B V2 / Rev1.1'
        TouchEnabled = $true
        TouchController = 'AXS15231B'
        Accelerometer = 'QMI8658'
        Homepage = 'https://www.waveshare.com/esp32-s3-touch-lcd-3.49.htm'
        Documentation = 'https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49'
        Driver = $null
        PortInstructions = @(
            'Use a data-capable USB cable.',
            'Use the Type-C connector identified by Waveshare for program flashing and log output.',
            'Check the official interface diagram; not every connector provides a flashing UART.'
        )
    }
)
$selectedTarget = $null
$esptool = $null
$selectedPortIdentity = $null

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

function Read-HighlightedConfirmation {
    param(
        [Parameter(Mandatory)] [string] $Prefix,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $Suffix,
        [ConsoleColor] $Color = [ConsoleColor]::Yellow
    )

    Write-Host $Prefix -NoNewline
    Write-Host $Token -ForegroundColor $Color -NoNewline
    Write-Host ($Suffix + ': ') -NoNewline
    return (Read-Host).Trim()
}

function Show-SupportedHardwareBanner {
# END-USER SCRIPT - flashes a DMDClock board on Windows 11 x64 / PowerShell 7.
# Usually driven by RUNME-Install-DmdClockEsp32.ps1. See docs\INSTALL-ESP32.md.
# Developer tooling lives in scripts\esp32\dev; tests in scripts\esp32\tests.
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
    $choice = Read-MenuChoice -Prompt 'Select hardware' -Minimum 1 `
        -Maximum ($hardwareTargets.Count + 1)
    if ($choice -eq $hardwareTargets.Count + 1) { return $null }
    $target = $hardwareTargets[$choice - 1]
    if ($null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Board' -Value $target.Product
    }
    return $target
}

function Assert-WithinDirectory {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Directory
    )

    $resolvedDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith(
        "$resolvedDirectory$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside '$resolvedDirectory': $resolvedPath"
    }
}

function Read-MenuChoice {
    param(
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [int] $Minimum,
        [Parameter(Mandatory)] [int] $Maximum,
        [int] $Default = 0
    )

    while ($true) {
        $defaultText = if ($Default -ge $Minimum -and $Default -le $Maximum) {
            " [$Default]"
        } else {
            ''
        }
        $answer = (Read-Host "$Prompt$defaultText").Trim()
        if ([string]::IsNullOrWhiteSpace($answer) -and $defaultText) {
            return $Default
        }
        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and
            $choice -ge $Minimum -and $choice -le $Maximum) {
            return $choice
        }
        Write-Warning "Enter a number from $Minimum to $Maximum."
    }
}

function Get-GitHubHeaders {
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'DMDClock-ESP32-Installer'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
}

function Get-CompatibleReleases {
    param([Parameter(Mandatory)] $Target)

    $uri = "https://api.github.com/repos/$Repository/releases?per_page=30"
    Write-Host "Checking GitHub releases for $($Target.Product)..."
    Write-DmdClockProvisioningLog -Event 'metadata-query' `
        -Detail "url=$uri target=$($Target.Id)"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders)
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
                    -Headers (Get-GitHubHeaders)
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
    $choice = Read-MenuChoice -Prompt 'Select release' -Minimum 1 -Maximum $releases.Count -Default 1
    $selected = $releases[$choice - 1]
    if ($null -ne $wizardState) {
        $channel = if ($selected.Release.prerelease) { 'Preview' } else { 'Stable' }
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Release' `
            -Value "$($selected.Release.tag_name) ($channel)"
    }
    return $selected
}

function Save-RemoteFile {
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [long] $MaximumBytes
    )

    if ($Uri.Scheme -ne 'https') {
        throw "Refusing non-HTTPS download: $Uri"
    }
    if ($Uri.Host -notin @(
        'github.com',
        'api.github.com',
        'objects.githubusercontent.com',
        'raw.githubusercontent.com'
    )) {
        throw "Refusing download from an unexpected host: $($Uri.Host)"
    }

    $temporary = "$Destination.partial-$([Guid]::NewGuid().ToString('N'))"
    Assert-WithinDirectory -Path $temporary -Directory $outputRoot
    Write-DmdClockProvisioningLog -Event 'download-started' -Detail (
        "url=$($Uri.AbsoluteUri) destination=$Destination maximum_bytes=$MaximumBytes")
    try {
        Invoke-WebRequest -Uri $Uri -Headers (Get-GitHubHeaders) -OutFile $temporary `
            -UseBasicParsing
        $size = (Get-Item -LiteralPath $temporary).Length
        if ($size -le 0 -or $size -gt $MaximumBytes) {
            throw "Downloaded file size $size is outside the accepted range 1-$MaximumBytes bytes."
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
        $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-DmdClockProvisioningLog -Event 'download-completed' -Detail (
            "url=$($Uri.AbsoluteUri) destination=$Destination size=$size sha256=$hash")
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-SafeRelativePath {
    param([Parameter(Mandatory)] [string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $RelativePath.Contains(':')) {
        throw "Unsafe package path: '$RelativePath'."
    }
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedHash
    )

    if ($ExpectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Invalid SHA-256 value for '$Path'."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedHash) {
        throw "SHA-256 verification failed for '$Path'. Expected $ExpectedHash, found $actual."
    }
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
            Assert-SafeRelativePath -RelativePath $relativePath
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

    $staging = "$Destination.staging-$([Guid]::NewGuid().ToString('N'))"
    Assert-WithinDirectory -Path $Destination -Directory $outputRoot
    Assert-WithinDirectory -Path $staging -Directory $outputRoot
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $archive.Entries) {
                Assert-SafeRelativePath -RelativePath $entry.FullName
                $entryDestination = [IO.Path]::GetFullPath((Join-Path $staging $entry.FullName))
                Assert-WithinDirectory -Path $entryDestination -Directory $staging
            }
        }
        finally {
            $archive.Dispose()
        }
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
            Assert-Sha256 -Path $path -ExpectedHash ([string]$file.sha256)
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
    $safeTag = ([string]$release.tag_name) -replace '[^A-Za-z0-9_.-]', '_'
    $releaseCache = Join-Path (Join-Path $cacheRoot $safeTag) $selectedTarget.Id
    Assert-WithinDirectory -Path $releaseCache -Directory $outputRoot
    New-Item -ItemType Directory -Force -Path $releaseCache | Out-Null
    $manifestFile = Join-Path $releaseCache $manifestAsset.name

    Write-Host "Downloading manifest for $($release.tag_name)..."
    Save-RemoteFile -Uri $manifestAsset.browser_download_url `
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
            Assert-Sha256 -Path $archivePath -ExpectedHash ([string]$manifest.package.sha256)
            Write-Host "Using verified cached package: $archivePath"
        }
        catch {
            Remove-Item -LiteralPath $archivePath -Force
            $reuseArchive = $false
        }
    }
    if (-not $reuseArchive) {
        Write-Host "Downloading $($manifest.package.asset)..."
        Save-RemoteFile -Uri $packageAssets[0].browser_download_url `
            -Destination $archivePath -MaximumBytes $maximumPackageBytes
        Assert-Sha256 -Path $archivePath -ExpectedHash ([string]$manifest.package.sha256)
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

function Get-ConnectedPorts {
    $found = @{}
    Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue | ForEach-Object {
        $found[$_.DeviceID] = [pscustomobject]@{
            Port = [string]$_.DeviceID
            Name = [string]$_.Name
            InstanceId = [string]$_.PNPDeviceID
            Manufacturer = ''
            Service = ''
            Status = [string]$_.Status
        }
    }
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '\((COM\d+)\)') {
            $found[$Matches[1]] = [pscustomobject]@{
                Port = [string]$Matches[1]
                Name = [string]$_.Name
                InstanceId = [string]$_.PNPDeviceID
                Manufacturer = [string]$_.Manufacturer
                Service = [string]$_.Service
                Status = [string]$_.Status
            }
        }
    }
    $serialMap = Get-ItemProperty -Path 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction SilentlyContinue
    if ($null -ne $serialMap) {
        $serialMap.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and $_.Value -match '^COM\d+$'
        } | ForEach-Object {
            if (-not $found.ContainsKey([string]$_.Value)) {
                $found[[string]$_.Value] = [pscustomobject]@{
                    Port = [string]$_.Value
                    Name = [string]$_.Name
                    InstanceId = ''
                    Manufacturer = ''
                    Service = ''
                    Status = ''
                }
            }
        }
    }
    return @($found.Values | Sort-Object { [int]($_.Port -replace '^COM', '') })
}

function Select-SerialPort {
    param([string] $QuickPort)

    $ports = @(Get-ConnectedPorts)
    if ($QuickPort) {
        $identity = @($ports | Where-Object Port -eq $QuickPort) | Select-Object -First 1
        if ($null -ne $identity) {
            if ([string]::IsNullOrWhiteSpace($identity.InstanceId)) {
                throw "Serial port '$QuickPort' has no Windows PnP instance identity; refusing an identity-weak selection."
            }
            $script:selectedPortIdentity = $identity
            Write-Host "Using detected device on $QuickPort ($($identity.Name))." -ForegroundColor Green
            return $QuickPort
        }
        Write-Warning "The detected device on $QuickPort is no longer connected; choose the port manually."
        $QuickPort = $null
    }
    if ($Port) {
        if ($Port -notin @($ports.Port)) {
            $available = if ($ports.Count) { $ports.Port -join ', ' } else { 'none' }
            Show-PortHelp -Target $selectedTarget
            throw "Serial port '$Port' is not connected. Available ports: $available."
        }
        $script:selectedPortIdentity = @($ports | Where-Object Port -eq $Port)[0]
        if ([string]::IsNullOrWhiteSpace($script:selectedPortIdentity.InstanceId)) {
            throw "Serial port '$Port' has no Windows PnP instance identity; refusing an identity-weak selection."
        }
        return $Port
    }
    if ($ports.Count -eq 0) {
        Show-PortHelp -Target $selectedTarget
        throw 'No serial port was detected.'
    }
    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host 'Connected serial ports:'
    for ($index = 0; $index -lt $ports.Count; $index++) {
        Write-Host ("  [{0}] {1,-7} {2}" -f ($index + 1), $ports[$index].Port, $ports[$index].Name)
    }
    $choice = Read-MenuChoice -Prompt 'Select the ESP32 port' -Minimum 1 -Maximum $ports.Count `
        -Default $(if ($ports.Count -eq 1) { 1 } else { 0 })
    $script:selectedPortIdentity = $ports[$choice - 1]
    if ([string]::IsNullOrWhiteSpace($script:selectedPortIdentity.InstanceId)) {
        throw "Serial port '$($script:selectedPortIdentity.Port)' has no Windows PnP instance identity; refusing an identity-weak selection."
    }
    if ($null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Serial port' -Value $script:selectedPortIdentity.Port
    }
    return $script:selectedPortIdentity.Port
}

function Assert-SerialPortUnchanged {
    param([Parameter(Mandatory)][string] $SelectedPort)

    if ($null -eq $selectedPortIdentity) {
        throw 'The selected serial port has no captured Windows identity.'
    }
    $matches = @(Get-ConnectedPorts | Where-Object Port -eq $SelectedPort)
    if ($matches.Count -ne 1) {
        throw "Serial port '$SelectedPort' disappeared or became ambiguous before flashing."
    }
    $current = $matches[0]
    if ([string]::IsNullOrWhiteSpace($current.InstanceId) -or
        [string]$current.InstanceId -cne [string]$selectedPortIdentity.InstanceId -or
        [string]$current.Name -cne [string]$selectedPortIdentity.Name) {
        throw "The Windows PnP device on '$SelectedPort' changed before flashing. Disconnect other serial devices and restart selection."
    }
    Write-Host "[OK] Revalidated $SelectedPort PnP identity: $($current.Name)" -ForegroundColor Green
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
    switch (Read-MenuChoice -Prompt 'Select the exact physical revision' -Minimum 1 -Maximum 3) {
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

    $destination = Join-Path (Join-Path $cacheRoot 'factory-recovery') $Revision
    Assert-WithinDirectory -Path $destination -Directory $outputRoot
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $imagePath = Join-Path $destination $image.FileName
    $reuseImage = Test-Path -LiteralPath $imagePath -PathType Leaf
    if ($reuseImage) {
        try {
            if ((Get-Item -LiteralPath $imagePath).Length -ne [long]$image.Size) {
                throw 'Cached factory image size mismatch.'
            }
            Assert-Sha256 -Path $imagePath -ExpectedHash $image.Sha256
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
        Save-RemoteFile -Uri $uri -Destination $imagePath -MaximumBytes 16MB
        if ((Get-Item -LiteralPath $imagePath).Length -ne [long]$image.Size) {
            Remove-Item -LiteralPath $imagePath -Force
            throw "Factory image size mismatch. Expected $($image.Size) bytes."
        }
        Assert-Sha256 -Path $imagePath -ExpectedHash $image.Sha256
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

function Expand-SafeArchive {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [string] $Destination
    )

    $staging = "$Destination.staging-$([Guid]::NewGuid().ToString('N'))"
    Assert-WithinDirectory -Path $Destination -Directory $outputRoot
    Assert-WithinDirectory -Path $staging -Directory $outputRoot
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.FullName)) { continue }
                Assert-SafeRelativePath -RelativePath $entry.FullName
                $entryDestination = [IO.Path]::GetFullPath((Join-Path $staging $entry.FullName))
                Assert-WithinDirectory -Path $entryDestination -Directory $staging
            }
        }
        finally {
            $archive.Dispose()
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $staging)
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

function Get-PortableEsptool {
    Write-Host ''
    Write-Host 'Checking the portable Espressif flashing tool...'
    $uri = "https://api.github.com/repos/$esptoolRepository/releases?per_page=20"
    Write-DmdClockProvisioningLog -Event 'metadata-query' -Detail "url=$uri kind=esptool"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders)
        $releases = @($response)
    }
    catch {
        throw "Unable to check official esptool releases. See $esptoolReleasesUrl"
    }
    $candidates = @()
    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease -or
            [string]$release.tag_name -notmatch '^v5\.') { continue }
        $assets = @($release.assets | Where-Object {
            [string]$_.name -match '^esptool-v[0-9.]+-windows-amd64\.zip$'
        })
        if ($assets.Count -eq 1) {
            $candidates += [pscustomobject]@{ Release = $release; Asset = $assets[0] }
        }
    }
    if ($candidates.Count -eq 0) {
        throw "No supported official Windows x64 esptool v5 package was found. See $esptoolReleasesUrl"
    }

    $selection = $candidates[0]
    $asset = $selection.Asset
    $digest = [string]$asset.digest
    if ($digest -notmatch '^sha256:([A-Fa-f0-9]{64})$') {
        throw "The official esptool asset has no usable GitHub SHA-256 digest. See $esptoolReleasesUrl"
    }
    $expectedHash = $Matches[1]
    if ([long]$asset.size -le 0 -or [long]$asset.size -gt $maximumToolBytes) {
        throw 'The official esptool archive size is outside the accepted range.'
    }

    $safeVersion = ([string]$selection.Release.tag_name) -replace '[^A-Za-z0-9_.-]', '_'
    $versionRoot = Join-Path $toolCacheRoot $safeVersion
    $archivePath = Join-Path $versionRoot ([string]$asset.name)
    $packagePath = Join-Path $versionRoot 'package'
    New-Item -ItemType Directory -Force -Path $versionRoot | Out-Null

    $archiveIsValid = $false
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        try {
            if ((Get-Item -LiteralPath $archivePath).Length -ne [long]$asset.size) {
                throw 'Cached size mismatch.'
            }
            Assert-Sha256 -Path $archivePath -ExpectedHash $expectedHash
            $archiveIsValid = $true
        }
        catch {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }
    if (-not $archiveIsValid) {
        Write-Host "Downloading official esptool $($selection.Release.tag_name)..."
        Save-RemoteFile -Uri $asset.browser_download_url -Destination $archivePath `
            -MaximumBytes $maximumToolBytes
        if ((Get-Item -LiteralPath $archivePath).Length -ne [long]$asset.size) {
            throw 'Downloaded esptool size does not match GitHub metadata.'
        }
        Assert-Sha256 -Path $archivePath -ExpectedHash $expectedHash
    }

    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) {
        Expand-SafeArchive -ArchivePath $archivePath -Destination $packagePath
    }
    $executables = @(Get-ChildItem -LiteralPath $packagePath -Filter 'esptool.exe' -File -Recurse)
    if ($executables.Count -ne 1) {
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Recurse -Force
        }
        Expand-SafeArchive -ArchivePath $archivePath -Destination $packagePath
        $executables = @(Get-ChildItem -LiteralPath $packagePath -Filter 'esptool.exe' -File -Recurse)
    }
    if ($executables.Count -ne 1) {
        throw "The official esptool archive does not contain exactly one esptool.exe. See $esptoolReleasesUrl"
    }

    $versionOutput = @(& $executables[0].FullName version 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($versionOutput | Out-String) -notmatch [Regex]::Escape(
            ([string]$selection.Release.tag_name).TrimStart('v'))) {
        throw "The portable esptool executable could not be verified. Antivirus software may have blocked it. See $esptoolReleasesUrl"
    }
    Write-Host "[OK] esptool $($selection.Release.tag_name)" -ForegroundColor Green
    Write-DmdClockProvisioningLog -Event 'tool-ready' -Detail (
        "tool=esptool version=$($selection.Release.tag_name) executable=$($executables[0].FullName) " +
        "archive=$archivePath size=$($asset.size) sha256=$expectedHash")
    return [pscustomobject]@{
        Path = $executables[0].FullName
        Version = [string]$selection.Release.tag_name
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
        $toolResponse = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$esptoolRepository/releases?per_page=20" `
            -Headers (Get-GitHubHeaders)
        $toolReleases = @($toolResponse)
        $toolCandidates = @()
        foreach ($release in $toolReleases) {
            if ($release.draft -or $release.prerelease -or
                [string]$release.tag_name -notmatch '^v5\.') { continue }
            $assets = @($release.assets | Where-Object {
                [string]$_.name -match '^esptool-v[0-9.]+-windows-amd64\.zip$'
            })
            if ($assets.Count -eq 1) {
                $toolCandidates += [pscustomobject]@{ Release = $release; Asset = $assets[0] }
            }
        }
        if ($toolCandidates.Count -eq 0) {
            throw "No supported official Windows x64 esptool v5 package was found. See $esptoolReleasesUrl"
        }
        $tool = $toolCandidates[0]
        $digest = [string]$tool.Asset.digest
        if ($digest -notmatch '^sha256:([0-9A-Fa-f]{64})$') {
            throw 'The official esptool asset has no usable GitHub SHA-256 digest.'
        }
        $toolPath = Join-Path $layout.Tools "esptool/$($tool.Release.tag_name)/$($tool.Asset.name)"
        $artifacts.Add((Save-DmdClockStagedDownload `
            -ArtifactId 'tool.esptool.windows-x64' `
            -Uri ([uri][string]$tool.Asset.browser_download_url) `
            -Destination $toolPath -StagingRoot $layout.Root `
            -ExpectedBytes ([long]$tool.Asset.size) -ExpectedSha256 $Matches[1] `
            -MaximumBytes $maximumToolBytes -Kind 'flash-tool' `
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
        Expand-SafeArchive -ArchivePath $toolArtifact.ResolvedPath `
            -Destination $expandedTool
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

function Invoke-EsptoolChecked {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    if ($null -eq $esptool -or -not (Test-Path -LiteralPath $esptool.Path -PathType Leaf)) {
        throw "The portable esptool executable is unavailable. See $esptoolReleasesUrl"
    }
    Write-DmdClockProvisioningLog -Event 'command-started' -Detail (
        "executable=$($esptool.Path) arguments=$($Arguments -join ' ')")
    $output = @(& $esptool.Path @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Write-Host
    if ($exitCode -ne 0) {
        Write-DmdClockProvisioningLog -Event 'command-failed' `
            -Detail "executable=$($esptool.Path) exit_code=$exitCode"
        throw "esptool failed with exit code $exitCode."
    }
    Write-DmdClockProvisioningLog -Event 'command-completed' `
        -Detail "executable=$($esptool.Path) exit_code=0"
    return ($output | Out-String)
}

function Assert-ConnectedHardware {
    param(
        [Parameter(Mandatory)] [string] $SelectedPort,
        [switch] $SkipPhysicalConfirmation
    )

    if (-not $SkipPhysicalConfirmation) {
        Write-Host ''
        Write-Warning 'Look at the model and revision printed on the physical board.'
    }
    $confirmation = if ($SkipPhysicalConfirmation) {
        $selectedTarget.Confirmation
    } elseif ($ConfirmHardware) {
        $ConfirmHardware.Trim()
    } else {
        Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $selectedTarget.Confirmation `
            -Suffix " to confirm $($selectedTarget.Product)" `
            -Color Green
    }
    if ($selectedTarget.UnsupportedConfirmation -and
        $confirmation -ieq $selectedTarget.UnsupportedConfirmation) {
        throw "Cancelled: '$confirmation' is not the selected or supported board."
    }
    if ($confirmation -ine $selectedTarget.Confirmation) {
        throw 'Hardware confirmation was not accepted.'
    }

    Write-Host "Checking the device on $SelectedPort..."
    $chipOutput = Invoke-EsptoolChecked -Arguments @('--chip', 'esp32s3', '--port', $SelectedPort, 'chip-id')
    if ($chipOutput -notmatch '(?i)ESP32-S3') {
        throw 'The connected chip is not an ESP32-S3.'
    }
    $flashOutput = Invoke-EsptoolChecked -Arguments @('--chip', 'esp32s3', '--port', $SelectedPort, 'flash-id')
    if ($flashOutput -notmatch '(?i)(Detected flash size:\s*16MB|flash size.*16\s*MB)') {
        throw 'The connected device did not report the required 16 MB flash. Refusing to continue.'
    }
    Write-Host '[OK] ESP32-S3 with 16 MB flash detected.' -ForegroundColor Green
    if (-not $SkipPhysicalConfirmation) {
        Write-Warning 'Chip detection cannot distinguish display models or PCB revisions; the board-label confirmation remains required.'
    }
    Assert-DmdClockBoardProbe -SelectedPort $SelectedPort
}

function Read-DmdClockSerialBuffer {
    param(
        [Parameter(Mandatory)] $SerialPort,
        [int] $CaptureSeconds
    )

    $captured = ''
    $sb = [Text.StringBuilder]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($CaptureSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        while ($SerialPort.BytesToRead -gt 0) {
            $buffer = New-Object byte[] ([Math]::Min($SerialPort.BytesToRead, 4096))
            $count = $SerialPort.Read($buffer, 0, $buffer.Length)
            if ($count -gt 0) {
                [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $count))
            }
        }
        $captured = $sb.ToString()
        if ($captured -match 'Initializing[^\r\n]*?\d+x\d+' -and
            $captured -match 'App version:' -and $captured.Length -gt 400) {
            break
        }
        Start-Sleep -Milliseconds 50
    }
    return $captured
}

function Read-DmdClockSerialBanner {
    param(
        [Parameter(Mandatory)] [string] $Port,
        [int] $CaptureSeconds = 12,
        [switch] $NativeUsbJtag
    )

    Add-Type -AssemblyName System.IO.Ports

    if ($NativeUsbJtag) {
        if ($null -eq $esptool -or -not (Test-Path -LiteralPath $esptool.Path -PathType Leaf)) {
            try {
                $script:esptool = Get-PortableEsptool
            }
            catch {
                Write-Debug "Could not resolve esptool for the native USB probe on ${Port}: $($_.Exception.Message)"
                return $null
            }
        }
        $null = @(& $esptool.Path '--port' $Port '--before' 'default-reset' '--after' 'hard-reset' 'chip-id' 2>&1)
        $sp = $null
        for ($attempt = 0; $attempt -lt 25 -and $null -eq $sp; $attempt++) {
            try {
                $sp = [IO.Ports.SerialPort]::new(
                    $Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                $sp.ReadTimeout = 500
                $sp.Open()
            }
            catch {
                if ($null -ne $sp) {
                    $sp.Dispose()
                    $sp = $null
                }
                Start-Sleep -Milliseconds 250
            }
        }
        if ($null -eq $sp) {
            return $null
        }
        try {
            $captured = Read-DmdClockSerialBuffer -SerialPort $sp -CaptureSeconds $CaptureSeconds
        }
        finally {
            if ($sp.IsOpen) {
                try {
                    $sp.Close()
                }
                catch {
                    Write-Debug "Could not close the native USB probe port ${Port}: $($_.Exception.Message)"
                }
            }
            $sp.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($captured)) {
            return $null
        }
        return $captured
    }

    $sequences = @(
        @{ First = 'DtrEnable'; Second = 'RtsEnable' },
        @{ First = 'RtsEnable'; Second = 'DtrEnable' }
    )
    foreach ($sequence in $sequences) {
        $sp = [IO.Ports.SerialPort]::new(
            $Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $sp.ReadTimeout = 500
        $captured = ''
        try {
            $sp.DtrEnable = $true
            $sp.RtsEnable = $true
            $sp.Open()
            Start-Sleep -Milliseconds 400
            $sp.$($sequence.First) = $false
            Start-Sleep -Milliseconds 120
            $sp.$($sequence.Second) = $false
            $captured = Read-DmdClockSerialBuffer -SerialPort $sp -CaptureSeconds $CaptureSeconds
        }
        catch {
            $captured = ''
        }
        finally {
            if ($sp.IsOpen) {
                try {
                    $sp.DtrEnable = $false
                    $sp.RtsEnable = $true
                    Start-Sleep -Milliseconds 150
                    $sp.RtsEnable = $false
                    $sp.Close()
                }
                catch {
                    Write-Debug "Could not reset DTR/RTS on ${Port}: $($_.Exception.Message)"
                }
            }
            $sp.Dispose()
        }
        if ($captured -match 'ESP-ROM|rst:') {
            return $captured
        }
    }
    return $null
}

function Get-DmdClockBoardProbe {
    param([string] $BannerText)

    $probe = [pscustomobject]@{
        Resolution = $null
        TouchController = $null
        Accelerometer = $null
        AppVersion = $null
        LanIp = $null
    }
    if ($BannerText -match 'Initializing[^\r\n]*?\b(?<w>\d+)x(?<h>\d+)\b') {
        $probe.Resolution = "$($Matches.w)x$($Matches.h)"
    }
    if ($BannerText -match 'GT911') {
        $probe.TouchController = 'GT911'
    } elseif ($BannerText -match 'AXS15231B') {
        $probe.TouchController = 'AXS15231B'
    }
    if ($BannerText -match 'QMI8658') {
        $probe.Accelerometer = 'QMI8658'
    }
    if ($BannerText -match 'App version:\s*([0-9][^\s]*)') {
        $probe.AppVersion = $Matches[1]
    }
    if ($BannerText -match 'Home Wi-Fi connected at ([0-9]{1,3}(\.[0-9]{1,3}){3})') {
        $probe.LanIp = $Matches[1]
    } elseif ($BannerText -match 'sta ip: ([0-9]{1,3}(\.[0-9]{1,3}){3})') {
        $probe.LanIp = $Matches[1]
    }
    return $probe
}

function Resolve-DmdClockBoardModel {
    param([Parameter(Mandatory)] $Probe)

    $scores = @{}
    foreach ($target in $hardwareTargets) {
        $scores[$target.Key] = 0
        if ($Probe.Resolution -and $Probe.Resolution -eq $target.Display) {
            $scores[$target.Key]++
        }
        if ($Probe.TouchController -and $Probe.TouchController -eq $target.TouchController) {
            $scores[$target.Key]++
        }
        if ($Probe.Accelerometer -and $Probe.Accelerometer -eq $target.Accelerometer) {
            $scores[$target.Key]++
        }
    }
    $best = $null
    $bestScore = 0
    $tied = $false
    foreach ($key in $scores.Keys) {
        if ($scores[$key] -gt $bestScore) {
            $best = $key
            $bestScore = $scores[$key]
            $tied = $false
        } elseif ($scores[$key] -eq $bestScore -and $scores[$key] -gt 0) {
            $tied = $true
        }
    }
    if ($bestScore -eq 0 -or $tied) {
        return $null
    }
    return $best
}

function Resolve-DmdClockModelLabel {
    param([Parameter(Mandatory)] [string] $Value)

    $trimmed = $Value.Trim()
    foreach ($target in $hardwareTargets) {
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
    if ($null -eq $answer -or [string]::IsNullOrWhiteSpace($answer)) {
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

    $directory = Join-Path $outputRoot ''
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

function Assert-DmdClockBoardProbe {
    param([Parameter(Mandatory)] [string] $SelectedPort)

    $identity = @(Get-ConnectedPorts | Where-Object Port -eq $SelectedPort) | Select-Object -First 1
    $native = $null -ne $identity -and $identity.InstanceId -match 'VID_303A&PID_1001'
    Write-Host 'Probing the connected board over UART...'
    $banner = Read-DmdClockSerialBanner -Port $SelectedPort -NativeUsbJtag:$native
    if ([string]::IsNullOrWhiteSpace($banner)) {
        Write-Warning 'Board probe could not read a boot banner; relying on the physical label confirmation.'
        return
    }
    $probe = Get-DmdClockBoardProbe -BannerText $banner
    $modelKey = Resolve-DmdClockBoardModel -Probe $probe
    $signals = "resolution=$($probe.Resolution) touch=$($probe.TouchController) " +
        "accelerometer=$($probe.Accelerometer) app=$($probe.AppVersion)"
    if ($null -eq $modelKey) {
        Write-Warning "Board probe was inconclusive ($signals); relying on the physical label confirmation."
        return
    }
    if ($modelKey -ne $selectedTarget.Key) {
        throw "Board probe mismatch: $SelectedPort looks like $modelKey ($signals) but the selected board is $($selectedTarget.Product). Refusing to continue."
    }
    Write-Host "[OK] UART probe confirms $($selectedTarget.Product): $signals" -ForegroundColor Green
}

function Get-DmdClockDeviceProbe {
    $ports = @(Get-ConnectedPorts)
    if ($ports.Count -eq 0) {
        return @()
    }
    $rows = @()
    foreach ($port in $ports) {
        $native = $port.InstanceId -match 'VID_303A&PID_1001'
        $banner = Read-DmdClockSerialBanner -Port $port.Port -NativeUsbJtag:$native
        if ([string]::IsNullOrWhiteSpace($banner)) {
            $rows += [pscustomobject]@{
                Port = $port.Port
                Model = 'no banner read'
                App = '-'
                Signals = '-'
                Status = 'Not verified'
                ModelKey = $null
                Revision = $null
            }
            continue
        }
        $probe = Get-DmdClockBoardProbe -BannerText $banner
        $modelKey = Resolve-DmdClockBoardModel -Probe $probe
        $modelLabel = if ($modelKey) {
            ($hardwareTargets | Where-Object Key -eq $modelKey | Select-Object -First 1).ShortLabel
        } else { $null }
        $recognized = $null -ne $modelKey -or -not [string]::IsNullOrWhiteSpace($probe.AppVersion)
        $revision = if ($banner -match '3\.49B\s+V(?<rev>\d)') { "V$($Matches.rev)" } else { $null }
        $signalParts = @(
            $probe.Resolution,
            $probe.TouchController,
            $probe.Accelerometer
        ) | Where-Object { $_ }
        $rows += [pscustomobject]@{
            Port = $port.Port
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
            ModelKey = $modelKey
            Revision = $revision
        }
    }
    return $rows
}

function Select-DmdClockDevice {
    param([Parameter(Mandatory)] [object[]] $Rows)

    if ($Board) {
        return $null
    }
    $offered = @($Rows | Where-Object {
        $_.Status -eq 'OK to flash' -and
        $null -ne $_.ModelKey -and
        $null -ne ($hardwareTargets | Where-Object Key -eq $_.ModelKey | Select-Object -First 1)
    })
    if ($offered.Count -eq 0) {
        return $null
    }
    if ($null -ne $wizardState) {
        Show-DmdClockWizardHeader -Wizard $wizardState
    }
    Write-Host ''
    Write-Host 'Select a device to flash:'
    for ($index = 0; $index -lt $offered.Count; $index++) {
        $row = $offered[$index]
        Write-Host ("  [{0}] {1,-7} {2,-18} {3,-7} {4,-34} {5}" -f
            ($index + 1), $row.Port, $row.Model, $row.App, $row.Signals, $row.Status)
    }
    Write-Host ("  [{0}] Choose manually (board not detected / other)" -f ($offered.Count + 1))
    Write-Host ("  [{0}] Exit" -f ($offered.Count + 2))
    $choice = Read-MenuChoice -Prompt 'Select device' -Minimum 1 -Maximum ($offered.Count + 2) `
        -Default $(if ($offered.Count -eq 1) { 1 } else { 0 })
    if ($choice -eq $offered.Count + 2) {
        return 'EXIT'
    }
    if ($choice -eq $offered.Count + 1) {
        return $null
    }
    $row = $offered[$choice - 1]
    $target = @($hardwareTargets | Where-Object Key -eq $row.ModelKey | Select-Object -First 1)[0]
    if ($null -eq $target) {
        return $null
    }
    if ($null -ne $wizardState) {
        Add-DmdClockWizardSelection -Wizard $wizardState -Label 'Device' `
            -Value "$($row.Port) $($row.Model)"
    }
    Write-Host ("Selected {0} on {1} (probed)." -f $target.Product, $row.Port) -ForegroundColor Green
    return [pscustomobject]@{
        Target = $target
        Port = $row.Port
        DetectedRevision = $row.Revision
    }
}

function Assert-FactoryRecoveryRevision {
    param([Parameter(Mandatory)] [string] $Revision)

    Write-Host ''
    Write-Warning 'Factory images for 3.49B V1 and V2 are not interchangeable.'
    $confirmation = if ($BoardRevision) {
        $BoardRevision
    } else {
        Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $Revision `
            -Suffix " to confirm the physical 3.49B $Revision marking" `
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
        Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $requiredRevision `
            -Suffix " to confirm the physical 3.49B $requiredRevision / Rev1.1 marking" `
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
        Assert-SafeRelativePath -RelativePath ([string]$file.path)
        $path = Join-Path $Package.Root ([string]$file.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Firmware image is missing: $path"
        }
        Assert-Sha256 -Path $path -ExpectedHash ([string]$file.sha256)
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
        [Parameter(Mandatory)] [string] $SelectedPort
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
    Write-Host "  Device:   $($selectedPortIdentity.Name)"
    Write-Host "  PnP ID:   $($selectedPortIdentity.InstanceId)"
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
        "target=$($selectedTarget.Id) port=$SelectedPort pnp=$($selectedPortIdentity.InstanceId) " +
        "mode=$Mode reset_nvs=$resetNvs version=$($Package.Version) package_sha256=$($Package.Manifest.package.sha256) " +
        "files=$(($files | ForEach-Object { $_.Offset + ':' + $_.RelativePath }) -join ',')")

    Assert-SerialPortUnchanged -SelectedPort $SelectedPort

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] All downloads, hashes, and hardware checks passed; flash was skipped.' `
            -ForegroundColor Yellow
        return $false
    }

    if (-not $Force) {
        $confirmationToken = if ($resetNvs) { 'RESET' } else { 'FLASH' }
        $confirmationAction = if ($resetNvs) {
            'erase device settings and write the complete installation'
        } else {
            'write this firmware'
        }
        $confirmation = Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token $confirmationToken `
            -Suffix " (uppercase or lowercase) to $confirmationAction" `
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
        $null = Invoke-EsptoolChecked -Arguments @(
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
    $null = Invoke-EsptoolChecked -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] Firmware written and verified by esptool; the board was reset.' `
        -ForegroundColor Green
    if ($resetNvs) {
        Write-Host 'NVS settings were reset. Remove dmd\config\settings.json from the microSD card' `
            -ForegroundColor Cyan
        Write-Host 'before reinserting it if the saved card settings must also be discarded.' `
            -ForegroundColor Cyan
    }
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
    Write-Host "  Device:   $($selectedPortIdentity.Name)"
    Write-Host "  PnP ID:   $($selectedPortIdentity.InstanceId)"
    Write-Host '  Offset:   0x0'
    Write-Host "  Image:    $($Package.FileName)"
    Write-Host "  SHA-256:  $($Package.Sha256)"
    Write-Warning 'Factory recovery replaces the current internal-flash contents, including stored settings.'
    Write-Host '  microSD card:  untouched' -ForegroundColor Green
    Write-DmdClockProvisioningLog -Event 'factory-recovery-plan' -Detail (
        "target=$($selectedTarget.Id) revision=$($Package.Revision) port=$SelectedPort " +
        "pnp=$($selectedPortIdentity.InstanceId) image=$($Package.FileName) sha256=$($Package.Sha256)")

    Assert-SerialPortUnchanged -SelectedPort $SelectedPort

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] Image, hash, revision, and hardware checks passed; factory recovery was skipped.' `
            -ForegroundColor Yellow
        return $false
    }

    $confirmation = Read-HighlightedConfirmation `
        -Prefix 'Type ' `
        -Token 'FLASH' `
        -Suffix ' (uppercase or lowercase) to restore the official factory image' `
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
    $null = Invoke-EsptoolChecked -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] Official factory image written and verified; the board was reset.' `
        -ForegroundColor Green
    Write-Host 'Exercise the LCD, touch, and microSD card tests before installing custom firmware.'
    Write-DmdClockProvisioningLog -Event 'factory-recovery-complete' `
        -Detail "revision=$($Package.Revision) port=$SelectedPort sha256=$($Package.Sha256)"
    return $true
}

function Show-FirmwareDryRun {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)][string] $Mode
    )

    $ports = @(Get-ConnectedPorts)
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
    Join-Path $outputRoot 'DmdClockFiles'
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
    if (-not $requirements.Passed) { exit 1 }
    return
}
if ($ProbePorts) {
    $ports = @(Get-ConnectedPorts)
    if ($ports.Count -eq 0) {
        Write-Host ''
        Write-Host '[FAILED] No serial port was detected.' -ForegroundColor Red
        return
    }
    if ($null -eq $esptool) {
        $esptool = Get-PortableEsptool
    }
    $entries = @()
    foreach ($port in $ports) {
        Write-Host ''
        Write-Host "Probing $($port.Port) ($($port.Name))..." -ForegroundColor Cyan
        $native = $port.InstanceId -match 'VID_303A&PID_1001'
        $banner = Read-DmdClockSerialBanner -Port $port.Port -NativeUsbJtag:$native
        $probe = if ($banner) { Get-DmdClockBoardProbe -BannerText $banner } else { $null }
        $modelKey = if ($probe) { Resolve-DmdClockBoardModel -Probe $probe } else { $null }
        $suggestedLabel = if ($modelKey) {
            ($hardwareTargets | Where-Object Key -eq $modelKey | Select-Object -First 1).ShortLabel
        } else { $null }
        $mac = $null
        try {
            $chipOutput = Invoke-EsptoolChecked -Arguments @(
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
        $wizardDevices = @(Get-DmdClockDeviceProbe)
    }
    $wizardState = New-DmdClockWizard -Title 'DMDClock ESP32 flash' -Devices $wizardDevices
}
$quickSelect = $null
if ($null -ne $wizardDevices -and -not $FactoryRecovery) {
    $quickSelect = Select-DmdClockDevice -Rows $wizardDevices
    if ($quickSelect -eq 'EXIT') { return }
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
        Join-Path $outputRoot 'Logs\Provisioning'
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
        New-Item -ItemType Directory -Force -Path $cacheRoot, $toolCacheRoot | Out-Null
    }

    $selectedTarget = if ($null -ne $quickSelect) {
        $quickSelect.Target
    } else {
        Select-HardwareTarget
    }
    if ($null -eq $selectedTarget) { return }
    Write-DmdClockProvisioningLog -Event 'target-selected' -Detail (
        "key=$($selectedTarget.Key) id=$($selectedTarget.Id) product=$($selectedTarget.Product) " +
        "revision=$($selectedTarget.SupportedBoard)")

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
        $ports = @(Get-ConnectedPorts)
        Write-Host ''
        Write-Host '[DRY RUN] Factory image URL, pinned revision, size, and SHA-256 were resolved; no file, cache, COM port, or hardware was changed.' -ForegroundColor Yellow
        Write-Host "  Target:   $($selectedTarget.Product) $revision"
        Write-Host "  Image:    $($package.FileName)"
        Write-Host "  SHA-256:  $($package.Sha256)"
        Write-Host "  COM plan: $(if ($Port) { $Port } elseif ($ports.Count) { 'none selected; available: ' + ($ports.Port -join ', ') } else { 'none connected (allowed in dry-run)' })"
        return
    }

    $esptool = Get-PortableEsptool
    $selectedPort = Select-SerialPort
    Write-DmdClockProvisioningLog -Event 'serial-selected' -Detail (
        "port=$selectedPort name=$($selectedPortIdentity.Name) pnp=$($selectedPortIdentity.InstanceId) " +
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
    switch (Read-MenuChoice -Prompt 'Select flash mode' -Minimum 1 -Maximum 4 -Default 1) {
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
    $esptool = Get-PortableEsptool
}
$selectedPort = Select-SerialPort -QuickPort $(if ($null -ne $quickSelect) { $quickSelect.Port } else { $null })
Write-DmdClockProvisioningLog -Event 'serial-selected' -Detail (
    "port=$selectedPort name=$($selectedPortIdentity.Name) pnp=$($selectedPortIdentity.InstanceId) " +
    "tool_version=$($esptool.Version)")
Assert-ConnectedHardware -SelectedPort $selectedPort -SkipPhysicalConfirmation:($null -ne $quickSelect)
Assert-DmdFirmwareRevision -Target $selectedTarget `
    -DetectedRevision $(if ($null -ne $quickSelect) { $quickSelect.DetectedRevision } else { $null })
    $flashed = Invoke-FirmwareFlash -Package $package -Mode $FlashMode -SelectedPort $selectedPort
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
    throw $originalError
}
finally {
    if ($logPath) {
        if ($runOutcome -eq 'failed') {
            try {
                Complete-DmdClockProvisioningLog -Outcome $runOutcome -Detail $runDetail
            }
            catch {
                Write-Warning "Could not finalize the failed provisioning log: $($_.Exception.Message)"
            }
        } else {
            Complete-DmdClockProvisioningLog -Outcome $runOutcome -Detail $runDetail
        }
    }
}
