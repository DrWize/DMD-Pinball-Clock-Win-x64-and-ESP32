# END-USER SCRIPT - resets all DMDClock settings on the ESP32-S3 (Windows 11 x64 / PowerShell 7).
# Erases ONLY the NVS settings partition region (0x9000, 0x6000) on a connected
# board, so brightness, theme, timezone, schedule, Wi-Fi, and MQTT settings return
# to factory defaults after the next reboot. No firmware, bootloader, partition
# table, other flash region, or microSD card file is written, erased, or deleted.
# Settings also persist in /dmd/config/settings.json on the TF card (SD wins at
# boot), so the final message explains how to remove that file for a complete reset.
#   -Port selects the COM port; otherwise one is chosen interactively.
#   -WhatIf (alias -DryRun) prints the plan without touching any hardware, cache,
#     download, or log.
#   -ConfirmHardware RESET supplies the confirmation token non-interactively.
#   -Force is NOT accepted; the reset always requires a typed RESET confirmation.
# Requires the shared DmdClock.Provisioning.psm1 next to this script. Developer
# tooling lives in scripts\esp32\dev; automated tests in scripts\esp32\tests.
# See docs\INSTALL-ESP32.md.
[CmdletBinding()]
param(
    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [switch] $CheckRequirements,

    [Alias('DryRun')]
    [switch] $WhatIf,

    [string] $ConfirmHardware,

    [switch] $Force,

    [string] $Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$null = Add-Type -AssemblyName System.IO.Compression.FileSystem

$provisioningModule = Join-Path $PSScriptRoot 'DmdClock.Provisioning.psm1'
if (-not (Test-Path -LiteralPath $provisioningModule -PathType Leaf)) {
    throw "Shared provisioning module not found: $provisioningModule"
}
Import-Module $provisioningModule -Force

$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$outputRoot = Join-Path $localData 'DmdClock'
$toolCacheRoot = Join-Path $outputRoot 'tools\esptool'
$maximumToolBytes = 128MB
$esptoolRepository = 'espressif/esptool'
$esptoolReleasesUrl = "https://github.com/$esptoolRepository/releases"

# NVS settings partition of the single-app-large layout used by DMDClock firmware
# (matches partitions.qemu.csv: nvs 0x9000 0x6000). Erasing this region clears the
# "dmdclock" namespace, Wi-Fi credentials, and any other NVS keys.
$nvsRegionOffset = '0x9000'
$nvsRegionSize = '0x6000'

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

function Show-ResetBanner {
    Write-Host ''
    Write-Host 'DMDClock ESP32-S3 settings reset' -ForegroundColor Cyan
    Write-Host '---------------------------------' -ForegroundColor DarkCyan
    Write-Host "This erases ONLY the NVS settings region ($nvsRegionOffset, size $nvsRegionSize)."
    Write-Host 'No firmware, bootloader, partition table, other flash region, or' `
        -ForegroundColor Yellow
    Write-Host 'microSD card file is written, erased, or deleted.' -ForegroundColor Yellow
}

function Get-GitHubHeaders {
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'DMDClock-ESP32-Settings-Reset'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
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

function Get-CachedEsptool {
    $cached = @(Get-ChildItem -LiteralPath $toolCacheRoot -Filter 'esptool.exe' `
        -File -Recurse -ErrorAction SilentlyContinue)
    if ($cached.Count -gt 0) {
        return $cached[0].FullName
    }
    return $null
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

function Select-SerialPort {
    $ports = @(Get-ConnectedPorts)
    if ($Port) {
        if ($Port -notin @($ports.Port)) {
            $available = if ($ports.Count) { $ports.Port -join ', ' } else { 'none' }
            throw "Serial port '$Port' is not connected. Available ports: $available."
        }
        $script:selectedPortIdentity = @($ports | Where-Object Port -eq $Port)[0]
        if ([string]::IsNullOrWhiteSpace($script:selectedPortIdentity.InstanceId)) {
            throw "Serial port '$Port' has no Windows PnP instance identity; refusing an identity-weak selection."
        }
        return $Port
    }
    if ($ports.Count -eq 0) {
        throw 'No serial port was detected.'
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
    return $script:selectedPortIdentity.Port
}

function Assert-SerialPortUnchanged {
    param([Parameter(Mandatory)] [string] $SelectedPort)

    if ($null -eq $selectedPortIdentity) {
        throw 'The selected serial port has no captured Windows identity.'
    }
    $matches = @(Get-ConnectedPorts | Where-Object Port -eq $SelectedPort)
    if ($matches.Count -ne 1) {
        throw "Serial port '$SelectedPort' disappeared or became ambiguous before erasing NVS."
    }
    $current = $matches[0]
    if ([string]::IsNullOrWhiteSpace($current.InstanceId) -or
        [string]$current.InstanceId -cne [string]$selectedPortIdentity.InstanceId -or
        [string]$current.Name -cne [string]$selectedPortIdentity.Name) {
        throw "The Windows PnP device on '$SelectedPort' changed before erasing NVS. Disconnect other serial devices and restart selection."
    }
    Write-Host "[OK] Revalidated $SelectedPort PnP identity: $($current.Name)" -ForegroundColor Green
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
    param([Parameter(Mandatory)] [string] $SelectedPort)

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
    Write-Warning 'Chip detection cannot distinguish display models or PCB revisions; confirm the connected board is the intended DMDClock device.'
}

function Show-ResetDryRun {
    $ports = @(Get-ConnectedPorts)
    if ($Port -and $Port -notin @($ports.Port)) {
        throw "Dry-run requested '$Port', but that COM port is not currently enumerated."
    }
    Write-Host ''
    Write-Host '[DRY RUN] No files, caches, serial ports, flash regions, or logs will be changed.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Reset plan:' -ForegroundColor Cyan
    Write-Host "  Erase region: $nvsRegionOffset (size $nvsRegionSize) - NVS settings partition"
    Write-Host "  Tool:         $(if ($esptool) { $esptool.Version } else { 'official esptool v5 (resolved only during execution)' })"
    Write-Host "  COM plan:     $(if ($Port) { $Port } elseif ($ports.Count) { 'none selected; available: ' + ($ports.Port -join ', ') } else { 'none connected (allowed in dry-run)' })"
    Write-Host ''
    Write-Host 'After the reset: power off, remove the TF card, and delete' -ForegroundColor Cyan
    Write-Host 'dmd\config\settings.json from it before reinserting (that file wins at boot).' -ForegroundColor Cyan
}

Show-ResetBanner

$requirementsPath = Join-Path $outputRoot 'DmdClockFiles'
$requirements = Invoke-DmdClockRequirementsCheck `
    -Operation $(if ($CheckRequirements) { 'Check' } else { 'Reset' }) `
    -DataPath $requirementsPath `
    -MinimumFreeBytes 256MB `
    -RequiredCommands @(
        'Get-CimInstance',
        'Get-FileHash',
        'Get-PnpDevice',
        'Invoke-RestMethod',
        'Invoke-WebRequest'
    ) `
    -RequireNetwork:(-not $CheckRequirements -and -not $WhatIf) `
    -ThrowOnFailure:(-not $CheckRequirements)
if ($CheckRequirements) {
    if (-not $requirements.Passed) { exit 1 }
    return
}

$runOutcome = 'cancelled'
$runDetail = ''
$logPath = $null
$esptool = $null
$selectedPortIdentity = $null

if ($Force) {
    throw 'Settings reset requires the final typed RESET confirmation; -Force is not accepted.'
}

try {
    if ($WhatIf) {
        Show-ResetDryRun
        $runOutcome = 'completed'
        return
    }

    $logDirectory = Join-Path $outputRoot 'Logs\Provisioning'
    $logPath = Start-DmdClockProvisioningLog -LogDirectory $logDirectory -Operation 'reset-settings'
    Write-Host "Log: $logPath"
    Write-DmdClockRequirementsLog -Requirements $requirements
    Write-DmdClockProvisioningLog -Event 'invocation' -Detail (
        "region=$nvsRegionOffset size=$nvsRegionSize repository=$Repository")

    $cachedEsptool = Get-CachedEsptool
    if ($cachedEsptool) {
        Write-Host "Using cached esptool: $cachedEsptool"
        $esptool = [pscustomobject]@{ Path = $cachedEsptool; Version = 'cached' }
    } else {
        $esptool = Get-PortableEsptool
    }

    $selectedPort = Select-SerialPort
    Write-DmdClockProvisioningLog -Event 'serial-selected' -Detail (
        "port=$selectedPort name=$($selectedPortIdentity.Name) pnp=$($selectedPortIdentity.InstanceId) " +
        "tool_version=$($esptool.Version)")
    Assert-ConnectedHardware -SelectedPort $selectedPort

    Write-Host ''
    Write-Warning 'This will erase all saved DMDClock settings, Wi-Fi, and MQTT credentials.'
    $confirmation = if ($ConfirmHardware) {
        $ConfirmHardware.Trim()
    } else {
        Read-HighlightedConfirmation `
            -Prefix 'Type ' `
            -Token 'RESET' `
            -Suffix ' (uppercase or lowercase) to erase the NVS settings region' `
            -Color Yellow
    }
    if ($confirmation -ine 'RESET') {
        throw 'Settings reset confirmation was not accepted.'
    }

    Assert-SerialPortUnchanged -SelectedPort $selectedPort

    $arguments = @(
        '--chip', 'esp32s3',
        '--port', $selectedPort,
        '--baud', '460800',
        '--before', 'default-reset',
        '--after', 'hard-reset',
        'erase_region',
        $nvsRegionOffset,
        $nvsRegionSize
    )
    Write-Host ''
    Write-Host "Erasing NVS settings region $nvsRegionOffset (size $nvsRegionSize)..."
    $null = Invoke-EsptoolChecked -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] NVS settings region erased; the board was reset to factory-default settings.' `
        -ForegroundColor Green
    Write-Host ''
    Write-Host 'Next, complete the reset by removing the TF-card copy of the settings:' `
        -ForegroundColor Cyan
    Write-Host '  1. Power off the ESP32.'
    Write-Host '  2. Remove the microSD/TF card and read it on a PC.'
    Write-Host '  3. Delete  dmd\config\settings.json  (firmware recreates it with defaults).'
    Write-Host '  4. Reinsert the card and power on; then reconfigure Wi-Fi and time in the web remote.' `
        -ForegroundColor Cyan
    Write-DmdClockProvisioningLog -Event 'reset-complete' -Detail (
        "region=$nvsRegionOffset size=$nvsRegionSize port=$selectedPort")
    $runOutcome = 'completed'
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
