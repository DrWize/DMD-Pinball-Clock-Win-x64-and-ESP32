[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $ReleaseTag,

    [switch] $LocalBuild,

    [string] $ManifestPath,

    [ValidateSet('Application', 'Full')]
    [string] $FlashMode,

    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [switch] $DownloadOnly,

    [switch] $Monitor,

    [switch] $ConfirmOriginal7,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$supportedTargetId = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
$supportedProduct = 'Waveshare ESP32-S3-Touch-LCD-7'
$supportedDisplay = '800x480'
$supportedModule = 'ESP32-S3-WROOM-1-N16R8'
$maximumManifestBytes = 1MB
$maximumPackageBytes = 64MB
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
$outputRoot = Join-Path $repoRoot 'output'
$cacheRoot = Join-Path $outputRoot 'esp32/releases'
$projectPath = Join-Path $repoRoot 'firmware/dmdclock-esp32'
$buildPath = Join-Path $projectPath 'build'
$toolRoot = Join-Path $workspaceRoot '.tools/esp-idf/v5.5.2/tools'
$python = Join-Path $toolRoot 'python/v5.5.2/venv/Scripts/python.exe'

function Show-SupportedHardwareBanner {
    Write-Host ''
    Write-Host 'DMDClock ESP32-S3 installer/updater'
    Write-Host '----------------------------------'
    Write-Host 'SUPPORTED:     Waveshare ESP32-S3-Touch-LCD-7, 800x480, N16R8'
    Write-Warning 'NOT SUPPORTED: Waveshare ESP32-S3-Touch-LCD-7B, 1024x600'
    Write-Host 'The 7 and 7B use different display timing and GPIO mappings.'
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
    $uri = "https://api.github.com/repos/$Repository/releases?per_page=30"
    Write-Host "Checking GitHub releases for $Repository..."
    $response = Invoke-RestMethod -Uri $uri -Headers (Get-GitHubHeaders)
    $releases = @($response)
    $compatible = @()
    foreach ($release in $releases) {
        if ($release.draft) { continue }
        $manifestAssets = @($release.assets | Where-Object {
            $_.name -match '(?i)^DMDClock-.+-esp32-manifest\.json$'
        })
        if ($manifestAssets.Count -eq 1) {
            $compatible += [pscustomobject]@{
                Release = $release
                ManifestAsset = $manifestAssets[0]
            }
        }
    }
    return $compatible
}

function Select-CompatibleRelease {
    $releases = @(Get-CompatibleReleases)
    if ($ReleaseTag) {
        $selected = @($releases | Where-Object { $_.Release.tag_name -eq $ReleaseTag })
        if ($selected.Count -ne 1) {
            throw "Release '$ReleaseTag' has no compatible ESP32 package. Only packages for the original 7-inch 800x480 N16R8 board are accepted."
        }
        return $selected[0]
    }

    if ($releases.Count -eq 0) {
        throw "No published release contains a compatible ESP32 firmware package. See https://github.com/$Repository/releases."
    }

    Write-Host ''
    Write-Host 'Available ESP32 releases:'
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
    if ($Uri.Host -notin @('github.com', 'api.github.com', 'objects.githubusercontent.com')) {
        throw "Refusing download from an unexpected host: $($Uri.Host)"
    }

    $temporary = "$Destination.partial-$([Guid]::NewGuid().ToString('N'))"
    Assert-WithinDirectory -Path $temporary -Directory $outputRoot
    try {
        Invoke-WebRequest -Uri $Uri -Headers (Get-GitHubHeaders) -OutFile $temporary
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
    param([Parameter(Mandatory)] $Manifest)

    if ([int]$Manifest.schemaVersion -ne 1) {
        throw "Unsupported ESP32 manifest schema '$($Manifest.schemaVersion)'."
    }
    if ([string]$Manifest.version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$' -or
        [string]$Manifest.releaseTag -ne "v$($Manifest.version)") {
        throw 'The firmware version or release tag is invalid.'
    }
    if ([string]$Manifest.target.id -ne $supportedTargetId -or
        [string]$Manifest.target.product -ne $supportedProduct -or
        [string]$Manifest.target.display -ne $supportedDisplay -or
        [string]$Manifest.target.module -ne $supportedModule -or
        [string]$Manifest.target.chip -ne 'esp32s3' -or
        [string]$Manifest.target.flashSize -ne '16MB') {
        throw 'Firmware target mismatch. This installer supports only the original Waveshare ESP32-S3-Touch-LCD-7, 800x480, N16R8. The 7B is not supported.'
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
    $releaseCache = Join-Path $cacheRoot $safeTag
    Assert-WithinDirectory -Path $releaseCache -Directory $outputRoot
    New-Item -ItemType Directory -Force -Path $releaseCache | Out-Null
    $manifestFile = Join-Path $releaseCache $manifestAsset.name

    Write-Host "Downloading manifest for $($release.tag_name)..."
    Save-RemoteFile -Uri $manifestAsset.browser_download_url `
        -Destination $manifestFile -MaximumBytes $maximumManifestBytes
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    Assert-CompatibleManifest -Manifest $manifest
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

function Get-OfflinePackage {
    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
    if ((Get-Item -LiteralPath $resolvedManifest).Length -gt $maximumManifestBytes) {
        throw 'Offline manifest is larger than the accepted limit.'
    }
    $manifest = Get-Content -LiteralPath $resolvedManifest -Raw | ConvertFrom-Json
    Assert-CompatibleManifest -Manifest $manifest
    $archivePath = Join-Path (Split-Path -Parent $resolvedManifest) ([string]$manifest.package.asset)
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw "Offline package is missing: $archivePath"
    }
    if ((Get-Item -LiteralPath $archivePath).Length -ne [long]$manifest.package.size) {
        throw 'Offline package size does not match the manifest.'
    }
    Assert-Sha256 -Path $archivePath -ExpectedHash ([string]$manifest.package.sha256)

    $offlineCache = Join-Path $cacheRoot (
        'offline-' + ([string]$manifest.package.sha256).Substring(0, 12).ToLowerInvariant())
    Expand-VerifiedPackage -ArchivePath $archivePath -Destination $offlineCache -Manifest $manifest
    return [pscustomobject]@{
        Source = "Offline package $resolvedManifest"
        Version = [string]$manifest.version
        Manifest = $manifest
        Root = $offlineCache
        Cache = $offlineCache
        IsLocal = $false
    }
}

function Get-LocalBuildPackage {
    $flasherArgsPath = Join-Path $buildPath 'flasher_args.json'
    if (-not (Test-Path -LiteralPath $flasherArgsPath -PathType Leaf)) {
        throw "No local firmware build exists. Run .\scripts\esp32\Build-DmdClock.ps1 first."
    }
    $flasher = Get-Content -LiteralPath $flasherArgsPath -Raw | ConvertFrom-Json
    if ([string]$flasher.extra_esptool_args.chip -ne 'esp32s3' -or
        [string]$flasher.flash_settings.flash_size -ne '16MB') {
        throw 'The local build does not target the supported ESP32-S3 with 16 MB flash.'
    }

    [xml]$properties = Get-Content -LiteralPath (Join-Path $repoRoot 'Directory.Build.props') -Raw
    $version = [string]$properties.Project.PropertyGroup.VersionPrefix
    $fullFiles = @()
    foreach ($property in $flasher.flash_files.PSObject.Properties) {
        $relativePath = [string]$property.Value
        Assert-SafeRelativePath -RelativePath $relativePath
        $filePath = Join-Path $buildPath $relativePath
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Local build is missing '$relativePath'."
        }
        $fullFiles += [pscustomobject]@{
            offset = [string]$property.Name
            path = $relativePath
            sha256 = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $applicationFiles = @($fullFiles | Where-Object { $_.path -eq [string]$flasher.app.file })
    if ($applicationFiles.Count -ne 1) {
        throw 'Unable to identify the application image in the local build.'
    }

    $manifest = [pscustomobject]@{
        schemaVersion = 1
        releaseTag = 'local'
        version = $version
        target = [pscustomobject]@{
            id = $supportedTargetId
            product = $supportedProduct
            display = $supportedDisplay
            module = $supportedModule
            chip = 'esp32s3'
            flashSize = '16MB'
        }
        flash = [pscustomobject]@{
            settings = [pscustomobject]@{
                mode = [string]$flasher.flash_settings.flash_mode
                frequency = [string]$flasher.flash_settings.flash_freq
                size = [string]$flasher.flash_settings.flash_size
            }
            application = [pscustomobject]@{ files = $applicationFiles; preservesNvs = $true }
            full = [pscustomobject]@{ files = $fullFiles; preservesNvs = $true }
        }
    }
    return [pscustomobject]@{
        Source = 'Current local build'
        Version = $version
        Manifest = $manifest
        Root = $buildPath
        Cache = $null
        IsLocal = $true
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
            throw "Serial port '$Port' is not connected. Available ports: $available."
        }
        return $Port
    }
    if ($ports.Count -eq 0) {
        throw 'No serial ports are connected. Connect the board through its UART/data USB port.'
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

function Invoke-EsptoolChecked {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "ESP-IDF Python/esptool was not found. Run .\scripts\esp32\Doctor.ps1. Expected: $python"
    }
    $output = @(& $python -m esptool @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Write-Host
    if ($exitCode -ne 0) {
        throw "esptool failed with exit code $exitCode."
    }
    return ($output | Out-String)
}

function Assert-ConnectedHardware {
    param([Parameter(Mandatory)] [string] $SelectedPort)

    if (-not $ConfirmOriginal7) {
        Write-Host ''
        Write-Warning 'Look at the board label before continuing.'
        $confirmation = (Read-Host 'Type 7 to confirm the original 800x480 model (typing 7B cancels)').Trim()
        if ($confirmation -ieq '7B') {
            throw 'Cancelled: the Waveshare 7B is not supported and must not be flashed with this firmware.'
        }
        if ($confirmation -ne '7') {
            throw 'Hardware confirmation was not accepted.'
        }
    }

    Write-Host "Checking the device on $SelectedPort..."
    $chipOutput = Invoke-EsptoolChecked -Arguments @('--chip', 'esp32s3', '--port', $SelectedPort, 'chip_id')
    if ($chipOutput -notmatch '(?i)ESP32-S3') {
        throw 'The connected chip is not an ESP32-S3.'
    }
    $flashOutput = Invoke-EsptoolChecked -Arguments @('--chip', 'esp32s3', '--port', $SelectedPort, 'flash_id')
    if ($flashOutput -notmatch '(?i)(Detected flash size:\s*16MB|flash size.*16\s*MB)') {
        throw 'The connected device did not report the required 16 MB flash. Refusing to continue.'
    }
    Write-Host '[OK] ESP32-S3 with 16 MB flash detected.'
    Write-Warning 'Chip detection cannot distinguish the 800x480 model from the incompatible 7B; the board-label confirmation remains required.'
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
    Write-Host "  Version:  $($Package.Version)"
    Write-Host "  Target:   $supportedProduct ($supportedDisplay, N16R8)"
    Write-Host "  Port:     $SelectedPort"
    Write-Host "  Mode:     $Mode"
    Write-Host '  NVS:      preserved (no erase command is used)'
    Write-Host '  TF card:  untouched'
    foreach ($file in $files) {
        Write-Host "  $($file.Offset)  $($file.RelativePath)"
    }

    if (-not $Force) {
        $confirmation = (Read-Host 'Type FLASH to write this firmware').Trim()
        if ($confirmation -cne 'FLASH') {
            Write-Host 'Flash cancelled. The verified download remains cached.'
            return
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
        "$SelectedPort ($supportedProduct, $supportedDisplay)",
        "Flash DMDClock $($Package.Version) in $Mode mode")) {
        return
    }

    $arguments = @(
        '--chip', 'esp32s3',
        '--port', $SelectedPort,
        '--baud', '460800',
        '--before', 'default_reset',
        '--after', 'hard_reset',
        'write_flash',
        '--flash_mode', [string]$settings.mode,
        '--flash_freq', [string]$settings.frequency,
        '--flash_size', [string]$settings.size
    )
    foreach ($file in $files) {
        $arguments += @($file.Offset, $file.Path)
    }
    $null = Invoke-EsptoolChecked -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] Firmware written and verified by esptool; the board was reset.'

    if ($Monitor) {
        if (-not $Package.IsLocal) {
            Write-Warning 'Serial symbol monitoring is available only for the matching local build. The release flash itself completed successfully.'
        } else {
            $monitorArguments = @('-p', $SelectedPort, 'monitor')
            & (Join-Path $PSScriptRoot 'Invoke-Idf.ps1') `
                -ProjectPath $projectPath @monitorArguments
        }
    }
}

Show-SupportedHardwareBanner

$sourceCount = @($LocalBuild.IsPresent, -not [string]::IsNullOrWhiteSpace($ManifestPath)) |
    Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
if ($sourceCount -gt 1 -or ($ReleaseTag -and $sourceCount -gt 0)) {
    throw 'Choose exactly one source: -ReleaseTag, -LocalBuild, or -ManifestPath.'
}

$sourceMode = if ($LocalBuild) {
    'Local'
} elseif ($ManifestPath) {
    'Offline'
} elseif ($ReleaseTag) {
    'Release'
} else {
    Write-Host ''
    Write-Host 'Firmware source:'
    Write-Host '  [1] Download a published release'
    Write-Host '  [2] Use the current local build'
    Write-Host '  [3] Use an offline release manifest and package'
    Write-Host '  [4] Exit'
    switch (Read-MenuChoice -Prompt 'Select source' -Minimum 1 -Maximum 4 -Default 1) {
        1 { 'Release' }
        2 { 'Local' }
        3 { 'Offline' }
        4 { return }
    }
}

if ($sourceMode -eq 'Offline' -and -not $ManifestPath) {
    $ManifestPath = (Read-Host 'Path to the downloaded ESP32 manifest').Trim('"')
}

$package = switch ($sourceMode) {
    'Local' { Get-LocalBuildPackage }
    'Offline' { Get-OfflinePackage }
    'Release' { Get-ReleasePackage -Selection (Select-CompatibleRelease) }
}

Write-Host ''
Write-Host '[OK] Firmware package verified'
Write-Host "  Source:  $($package.Source)"
Write-Host "  Version: $($package.Version)"
Write-Host "  Target:  $supportedProduct ($supportedDisplay, $supportedModule)"
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
    Write-Host '  [1] Application update (Recommended; preserves bootloader, partitions and NVS)'
    Write-Host '  [2] Complete installation (bootloader, partition table and application; preserves NVS)'
    Write-Host '  [3] Keep download only and exit'
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
Assert-ConnectedHardware -SelectedPort $selectedPort
Invoke-FirmwareFlash -Package $package -Mode $FlashMode -SelectedPort $selectedPort
