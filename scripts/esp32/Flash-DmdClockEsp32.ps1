[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $ReleaseTag,

    [ValidateSet('Waveshare7', 'Waveshare349B')]
    [string] $Board,

    [ValidateSet('Application', 'Full')]
    [string] $FlashMode,

    [switch] $FactoryRecovery,

    [ValidateSet('V1', 'V2')]
    [string] $BoardRevision,

    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [switch] $DownloadOnly,

    [switch] $WhatIf,

    [string] $ConfirmHardware,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$null = Add-Type -AssemblyName System.IO.Compression.FileSystem

$maximumManifestBytes = 1MB
$maximumPackageBytes = 64MB
$maximumToolBytes = 128MB
$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$outputRoot = Join-Path $localData 'DmdClock'
$cacheRoot = Join-Path $outputRoot 'cache\firmware'
$toolCacheRoot = Join-Path $outputRoot 'tools\esptool'
$esptoolRepository = 'espressif/esptool'
$esptoolReleasesUrl = "https://github.com/$esptoolRepository/releases"

$hardwareTargets = @(
    [pscustomobject]@{
        Key = 'Waveshare7'
        Id = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
        Product = 'Waveshare ESP32-S3-Touch-LCD-7'
        Display = '800x480'
        Module = 'ESP32-S3-WROOM-1-N16R8'
        Confirmation = '7'
        UnsupportedConfirmation = '7B'
        RequiredFirmwareRevision = $null
        SupportedBoard = '7'
        TouchEnabled = $true
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
        Display = '640x172'
        Module = 'ESP32-S3-WROOM-1-N16R8'
        Confirmation = '3.49B'
        UnsupportedConfirmation = $null
        RequiredFirmwareRevision = 'V2'
        SupportedBoard = '3.49B V2 / Rev1.1'
        TouchEnabled = $true
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
    Write-Host ''
    Write-Host 'DMDClock ESP32-S3 installer/updater' -ForegroundColor Cyan
    Write-Host '----------------------------------' -ForegroundColor DarkCyan
    Write-Host 'Select the exact physical board before choosing a firmware version.'
    Write-Host 'Waveshare ESP32-S3-Touch-LCD-7B (1024x600) is not supported.' `
        -ForegroundColor Red
}

function Select-HardwareTarget {
    if ($Board) {
        return @($hardwareTargets | Where-Object { $_.Key -eq $Board })[0]
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
    return $hardwareTargets[$choice - 1]
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

    Write-Host ''
    Write-Host "Available firmware for $($Target.Product):"
    for ($index = 0; $index -lt $releases.Count; $index++) {
        $release = $releases[$index].Release
        $channel = if ($release.prerelease) { 'Preview' } else { 'Stable' }
        $date = ([DateTimeOffset]$release.published_at).ToString('yyyy-MM-dd')
        Write-Host ("  [{0}] {1,-14} {2,-8} {3}" -f ($index + 1), $release.tag_name, $channel, $date)
    }
    $choice = Read-MenuChoice -Prompt 'Select release' -Minimum 1 -Maximum $releases.Count -Default 1
    return $releases[$choice - 1]
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
    try {
        Invoke-WebRequest -Uri $Uri -Headers (Get-GitHubHeaders) -OutFile $temporary `
            -UseBasicParsing
        $size = (Get-Item -LiteralPath $temporary).Length
        if ($size -le 0 -or $size -gt $MaximumBytes) {
            throw "Downloaded file size $size is outside the accepted range 1-$MaximumBytes bytes."
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
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
        $found[$_.DeviceID] = [pscustomobject]@{ Port = $_.DeviceID; Name = $_.Name }
    }
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '\((COM\d+)\)') {
            $found[$Matches[1]] = [pscustomobject]@{ Port = $Matches[1]; Name = $_.Name }
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
                }
            }
        }
    }
    return @($found.Values | Sort-Object { [int]($_.Port -replace '^COM', '') })
}

function Select-SerialPort {
    $ports = @(Get-ConnectedPorts)
    if ($Port) {
        if ($Port -notin @($ports.Port)) {
            $available = if ($ports.Count) { $ports.Port -join ', ' } else { 'none' }
            Show-PortHelp -Target $selectedTarget
            throw "Serial port '$Port' is not connected. Available ports: $available."
        }
        return $Port
    }
    if ($ports.Count -eq 0) {
        Show-PortHelp -Target $selectedTarget
        throw 'No serial port was detected.'
    }
    Write-Host ''
    Write-Host 'Connected serial ports:'
    for ($index = 0; $index -lt $ports.Count; $index++) {
        Write-Host ("  [{0}] {1,-7} {2}" -f ($index + 1), $ports[$index].Port, $ports[$index].Name)
    }
    $choice = Read-MenuChoice -Prompt 'Select the ESP32 port' -Minimum 1 -Maximum $ports.Count `
        -Default $(if ($ports.Count -eq 1) { 1 } else { 0 })
    return $ports[$choice - 1].Port
}

function Select-FactoryRecoveryRevision {
    if ($BoardRevision) {
        return $BoardRevision
    }

    Write-Host ''
    Write-Host '3.49B hardware revision:'
    Write-Host '  [1] V1'
    Write-Host '  [2] V2 (Rev1.1 PCB / V2 case sticker)' -ForegroundColor Green
    Write-Host '  [3] Exit' -ForegroundColor DarkGray
    switch (Read-MenuChoice -Prompt 'Select the exact physical revision' -Minimum 1 -Maximum 3) {
        1 { return 'V1' }
        2 { return 'V2' }
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
    return [pscustomobject]@{
        Path = $executables[0].FullName
        Version = [string]$selection.Release.tag_name
    }
}

function Invoke-EsptoolChecked {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    if ($null -eq $esptool -or -not (Test-Path -LiteralPath $esptool.Path -PathType Leaf)) {
        throw "The portable esptool executable is unavailable. See $esptoolReleasesUrl"
    }
    $output = @(& $esptool.Path @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Write-Host
    if ($exitCode -ne 0) {
        throw "esptool failed with exit code $exitCode."
    }
    return ($output | Out-String)
}

function Assert-ConnectedHardware {
    param([Parameter(Mandatory)] [string] $SelectedPort)

    Write-Host ''
    Write-Warning 'Look at the model and revision printed on the physical board.'
    $confirmation = if ($ConfirmHardware) {
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
    Write-Warning 'Chip detection cannot distinguish display models or PCB revisions; the board-label confirmation remains required.'
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
    param([Parameter(Mandatory)] $Target)

    if ([string]::IsNullOrWhiteSpace($Target.RequiredFirmwareRevision)) {
        return
    }

    $requiredRevision = [string]$Target.RequiredFirmwareRevision
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

    $modeProperty = $Mode.ToLowerInvariant()
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

    $files = @(Get-SelectedFlashFiles -Package $Package -Mode $Mode)
    $settings = $Package.Manifest.flash.settings
    Write-Host ''
    Write-Host 'Flash summary:'
    Write-Host "  Source:   $($Package.Source)"
    Write-Host "  Version:  $($Package.Version)" -ForegroundColor Cyan
    Write-Host "  Target:   $($selectedTarget.Product)"
    Write-Host "  Port:     $SelectedPort" -ForegroundColor Cyan
    Write-Host "  Mode:     $Mode" -ForegroundColor Yellow
    Write-Host '  NVS:      preserved (no erase command is used)' -ForegroundColor Green
    Write-Host '  TF card:  untouched' -ForegroundColor Green
    foreach ($file in $files) {
        Write-Host "  $($file.Offset)  $($file.RelativePath)"
    }

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] All downloads, hashes, and hardware checks passed; flash was skipped.' `
            -ForegroundColor Yellow
        return
    }

    if (-not $Force) {
        $confirmation = Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token 'FLASH' `
            -Suffix ' (uppercase or lowercase) to write this firmware' `
            -Color Yellow
        if ($confirmation -ine 'FLASH') {
            Write-Host 'Flash cancelled. The verified download remains cached.' `
                -ForegroundColor Yellow
            return
        }
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
    Write-Host '  Offset:   0x0'
    Write-Host "  Image:    $($Package.FileName)"
    Write-Host "  SHA-256:  $($Package.Sha256)"
    Write-Warning 'Factory recovery replaces the current internal-flash contents, including stored settings.'
    Write-Host '  TF card:  untouched' -ForegroundColor Green

    if ($WhatIf) {
        Write-Host ''
        Write-Host '[WHATIF] Image, hash, revision, and hardware checks passed; factory recovery was skipped.' `
            -ForegroundColor Yellow
        return
    }

    $confirmation = Read-HighlightedConfirmation `
        -Prefix 'Type ' `
        -Token 'FLASH' `
        -Suffix ' (uppercase or lowercase) to restore the official factory image' `
        -Color Yellow
    if ($confirmation -ine 'FLASH') {
        Write-Host 'Factory recovery cancelled. The verified image remains cached.' `
            -ForegroundColor Yellow
        return
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
    Write-Host 'Exercise the LCD, touch, and SD-card tests before installing custom firmware.'
}

Show-SupportedHardwareBanner

if ($env:OS -ne 'Windows_NT') {
    throw "This flashing script supports Windows only. See https://github.com/$Repository/releases."
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw "The portable Espressif flashing tool requires 64-bit Windows. See $esptoolReleasesUrl"
}
if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw 'Windows PowerShell 5.1 or newer is required. See https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
}
Write-Host "[OK] 64-bit Windows" -ForegroundColor Green
Write-Host "[OK] PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $cacheRoot, $toolCacheRoot | Out-Null

$selectedTarget = Select-HardwareTarget
if ($null -eq $selectedTarget) { return }

if ($FactoryRecovery) {
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
    $package = Get-FactoryRecoveryPackage -Revision $revision
    Write-Host ''
    Write-Host '[OK] Official factory recovery image verified' -ForegroundColor Green
    Write-Host "  Source:   $($package.Source)"
    Write-Host "  Revision: $($package.Revision)"
    Write-Host "  Cache:    $($package.Cache)"
    if ($DownloadOnly) {
        Write-Host 'Download-only mode selected; nothing was flashed.'
        return
    }

    $selectedPort = Select-SerialPort
    $esptool = Get-PortableEsptool
    Assert-ConnectedHardware -SelectedPort $selectedPort
    Assert-FactoryRecoveryRevision -Revision $revision
    Invoke-FactoryRecoveryFlash -Package $package -SelectedPort $selectedPort
    return
}

$package = Get-ReleasePackage -Selection (
    Select-CompatibleRelease -Target $selectedTarget)

Write-Host ''
Write-Host '[OK] Firmware package verified' -ForegroundColor Green
Write-Host "  Source:  $($package.Source)"
Write-Host "  Version: $($package.Version)"
Write-Host "  Target:  $($selectedTarget.Product)"
if ($package.Cache) {
    Write-Host "  Cache:   $($package.Cache)"
}

if ($DownloadOnly) {
    Write-Host 'Download-only mode selected; nothing was flashed.'
    return
}

if (-not $FlashMode) {
    Write-Host ''
    Write-Host 'Flash mode:'
    Write-Host '  [1] Application update (Recommended; preserves bootloader, partitions and NVS)' `
        -ForegroundColor Green
    Write-Host '  [2] Complete installation (bootloader, partition table and application; preserves NVS)' `
        -ForegroundColor Yellow
    Write-Host '  [3] Keep download only and exit' -ForegroundColor DarkGray
    switch (Read-MenuChoice -Prompt 'Select flash mode' -Minimum 1 -Maximum 3 -Default 1) {
        1 { $FlashMode = 'Application' }
        2 { $FlashMode = 'Full' }
        3 {
            Write-Host 'Nothing was flashed. The verified download remains cached.'
            return
        }
    }
}

$selectedPort = Select-SerialPort
$esptool = Get-PortableEsptool
Assert-ConnectedHardware -SelectedPort $selectedPort
Assert-DmdFirmwareRevision -Target $selectedTarget
Invoke-FirmwareFlash -Package $package -Mode $FlashMode -SelectedPort $selectedPort
