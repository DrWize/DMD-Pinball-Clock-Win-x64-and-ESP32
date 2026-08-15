# Builds a raw FAT32 disk image from a local scenes folder for the QEMU profile.
#
# QEMU's ESP32 machine emulates the SD/MMC host controller, so the emulator can
# boot the real card layout from a raw image. This script mirrors a folder of
# .scn scenes (plus an optional scene-metadata.json) into /dmd/scenes on a
# FAT32 image that Run-DmdClockQemuModel.ps1 attaches with:
#     -drive file=<image>,if=sd,format=raw
#
# Example:
#   .\scripts\esp32\New-DmdClockQemuSdImage.ps1 `
#       -ScenesFolder ..\..\scenes `
#       -OutputPath ..\..\firmware\dmdclock-esp32\dmdclock-qemu-sd.img
#
# The image is a FAT32 superfloppy with its boot sector at LBA 0, 512-byte
# sectors, and 4 KiB clusters. That is the layout QEMU's ESP32 SD/MMC device
# exposes to ESP-IDF. No external tools are required.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ScenesFolder,
    [string] $OutputPath,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ScenesFolder -PathType Container)) {
    throw "Scenes folder not found: $ScenesFolder"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $ScenesFolder) 'dmdclock-qemu-sd.img'
}
if (-not $Force -and (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    $sources = Get-ChildItem -LiteralPath $ScenesFolder -File -Recurse
    $newest = ($sources | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    if ($newest -lt (Get-Item -LiteralPath $OutputPath).LastWriteTime) {
        Write-Host "microSD image is up to date: $OutputPath"
        return
    }
}

$script:BytesPerSector = 512
$script:SectorsPerCluster = 8
$script:ClusterBytes = $script:BytesPerSector * $script:SectorsPerCluster
$script:ReservedSectors = 32
$script:NumFats = 2
$script:MinClusters = 65525
$script:HiddenSectors = 0

$files = Get-ChildItem -LiteralPath $ScenesFolder -File -Recurse | ForEach-Object {
    [pscustomobject]@{
        RelativePath = $_.FullName.Substring((Resolve-Path -LiteralPath $ScenesFolder).Path.Length).TrimStart('\', '/')
        Length       = [long]$_.Length
        FullName     = $_.FullName
    }
}
if ($files.Count -eq 0) {
    throw "No files found under $ScenesFolder"
}
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$neededClusters = [int][Math]::Ceiling(($totalBytes + 8 * 1024 * 1024) / $script:ClusterBytes)

# QEMU requires a microSD image whose complete byte length is a power of two. Start
# at 512 MiB (the smallest power-of-two image that remains FAT32 with 4 KiB
# clusters) and grow until the data area can contain all source files.
$imageBytes = [long](512MB)
do {
    $script:TotalSectors = [int64]($imageBytes / $script:BytesPerSector)
    $clusters = [int64][Math]::Floor(
        ($script:TotalSectors - $script:ReservedSectors) /
        $script:SectorsPerCluster)
    do {
        $fatSectors = [int64][Math]::Ceiling(
            (($clusters + 2) * 4) / $script:BytesPerSector)
        $adjustedClusters = [int64][Math]::Floor(
            ($script:TotalSectors - $script:ReservedSectors -
                $script:NumFats * $fatSectors) /
            $script:SectorsPerCluster)
        $changed = $adjustedClusters -ne $clusters
        $clusters = $adjustedClusters
    } while ($changed)

    if ($clusters -ge $script:MinClusters -and $clusters -ge $neededClusters) {
        break
    }
    $imageBytes *= 2
} while ($imageBytes -le [long](32GB))

if ($clusters -lt $script:MinClusters -or $clusters -lt $neededClusters) {
    throw 'The requested scenes do not fit in the maximum supported 32 GiB QEMU microSD image.'
}

$script:Clusters = $clusters
$script:FatSectors = $fatSectors
$script:PartitionSectors = $script:TotalSectors

Write-Host (
    'Building microSD image for {0} scene(s), {1} MiB data, {2} MiB volume: {3}' -f
    $files.Count,
    [Math]::Round($totalBytes / 1MB, 1),
    [Math]::Round($imageBytes / 1MB, 0),
    $OutputPath)

$script:Fat = New-Object byte[] ($script:FatSectors * $script:BytesPerSector)
$script:NextCluster = [uint32]3

function Set-FatEntry {
    param([uint32] $Cluster, [uint32] $Value)
    $index = $Cluster * 4
    $script:Fat[$index] = $Value -band 0xFF
    $script:Fat[$index + 1] = ($Value -shr 8) -band 0xFF
    $script:Fat[$index + 2] = ($Value -shr 16) -band 0xFF
    $script:Fat[$index + 3] = ($Value -shr 24) -band 0xFF
}

function Get-AllocClusters {
    param([int] $Count)
    if ($Count -le 0) {
        throw 'Cluster allocation requires a positive count'
    }
    $start = $script:NextCluster
    $last = [uint32]($start + $Count - 1)
    for ($i = [uint32]$start; $i -lt $last; $i++) {
        Set-FatEntry -Cluster $i -Value ($i + 1)
    }
    Set-FatEntry -Cluster $last -Value 0x0FFFFFFF
    $script:NextCluster = $last + 1
    return $start
}

function Get-ClusterOffset {
    param([uint32] $Cluster)
    $sector = $script:HiddenSectors + $script:ReservedSectors +
        2 * $script:FatSectors +
        ($Cluster - 2) * $script:SectorsPerCluster
    return [long]$sector * $script:BytesPerSector
}

function Write-BytesAt {
    param([long] $Offset, [byte[]] $Data)
    $stream.Position = $Offset
    $stream.Write($Data, 0, $Data.Length)
}

function Write-UInt16 {
    param([byte[]] $Target, [int] $Offset, [uint16] $Value)
    [BitConverter]::GetBytes($Value).CopyTo($Target, $Offset)
}

function Write-UInt32 {
    param([byte[]] $Target, [int] $Offset, [uint32] $Value)
    [BitConverter]::GetBytes($Value).CopyTo($Target, $Offset)
}

function Get-LfnChecksum {
    param([byte[]] $ShortName)
    $sum = 0
    foreach ($byte in $ShortName) {
        $sum = (($sum -shr 1) -bor (($sum -band 1) * 0x80)) -band 0xFF
        $sum = ($sum + $byte) -band 0xFF
    }
    return [byte]$sum
}

$validNameChar = '[A-Za-z0-9!$%''()\-@^_`{}~ ]'

function Test-ShortName {
    param([string] $Name)
    $dot = $Name.LastIndexOf('.')
    $base = if ($dot -ge 0) { $Name.Substring(0, $dot) } else { $Name }
    $ext = if ($dot -ge 0) { $Name.Substring($dot + 1) } else { '' }
    if ($base.Length -lt 1 -or $base.Length -gt 8 -or $ext.Length -gt 3) {
        return $false
    }
    if ($base -notmatch "^$validNameChar+$" -or
        $ext -notmatch "^$validNameChar*$") {
        return $false
    }
    return $true
}

function New-ShortName {
    param([string] $Name, [hashtable] $Used)
    $dot = $Name.LastIndexOf('.')
    $base = if ($dot -ge 0) { $Name.Substring(0, $dot) } else { $Name }
    $ext = if ($dot -ge 0) { $Name.Substring($dot + 1) } else { '' }
    $clean = $base.ToUpperInvariant() -replace '[^A-Za-z0-9!$%''()\-@^_`{}~ ]', '_'
    $extClean = ($ext.ToUpperInvariant() -replace '[^A-Za-z0-9!$%''()\-@^_`{}~ ]', '_')
    if ($extClean.Length -gt 3) {
        $extClean = $extClean.Substring(0, 3)
    }
    $stem = $clean.Substring(0, [Math]::Min(6, $clean.Length))
    for ($i = 1; $i -lt 1000; $i++) {
        $suffix = "~$i"
        $base8 = ($stem.Substring(0, [Math]::Min(8 - $suffix.Length, $stem.Length)) + $suffix)
        $candidate = $base8.PadRight(8) + $extClean.PadRight(3)
        if (-not $Used.ContainsKey($candidate)) {
            $Used[$candidate] = $true
            return $candidate
        }
    }
    throw "Could not generate a unique short name for $Name"
}

function Get-ShortNameEntry {
    param([string] $Name, [hashtable] $Used)
    if (Test-ShortName -Name $Name) {
        $dot = $Name.LastIndexOf('.')
        $base = if ($dot -ge 0) { $Name.Substring(0, $dot) } else { $Name }
        $ext = if ($dot -ge 0) { $Name.Substring($dot + 1) } else { '' }
        $shortName = $base.ToUpperInvariant().PadRight(8) + $ext.ToUpperInvariant().PadRight(3)
        if (-not $Used.ContainsKey($shortName)) {
            $Used[$shortName] = $true
            return $shortName
        }
    }
    return New-ShortName -Name $Name -Used $Used
}

function Add-DirectoryEntry {
    param(
        [System.Collections.Generic.List[byte]] $Directory,
        [string] $LongName,
        [string] $ShortName,
        [byte] $Attributes,
        [uint32] $StartCluster,
        [long] $Size
    )
    if (-not [string]::IsNullOrEmpty($LongName)) {
        $checksum = Get-LfnChecksum -ShortName (
            [Text.Encoding]::ASCII.GetBytes($ShortName))
        $utf16 = [Text.Encoding]::Unicode.GetBytes($LongName)
        $slotCount = [int][Math]::Ceiling($LongName.Length / 13.0)
        for ($slotIndex = $slotCount; $slotIndex -ge 1; $slotIndex--) {
            $slot = New-Object byte[] 32
            $ordinal = [byte]$slotIndex
            if ($slotIndex -eq $slotCount) {
                $ordinal = $ordinal -bor 0x40
            }
            $slot[0] = $ordinal
            $charStart = ($slotIndex - 1) * 13
            for ($c = 0; $c -lt 13; $c++) {
                $charIndex = $charStart + $c
                if ($charIndex -ge $LongName.Length) {
                    $code = 0
                }
                else {
                    $code = [int]$LongName[$charIndex]
                }
                if ($c -lt 5) {
                    $charOffset = 1 + $c * 2
                }
                elseif ($c -lt 11) {
                    $charOffset = 14 + ($c - 5) * 2
                }
                else {
                    $charOffset = 28 + ($c - 11) * 2
                }
                $slot[$charOffset] = $code -band 0xFF
                $slot[$charOffset + 1] = ($code -shr 8) -band 0xFF
            }
            $slot[11] = 0x0F
            $slot[13] = $checksum
            foreach ($byte in $slot) {
                $Directory.Add($byte)
            }
        }
    }

    $entry = New-Object byte[] 32
    $nameBytes = [Text.Encoding]::ASCII.GetBytes($ShortName)
    $nameBytes.CopyTo($entry, 0)
    $entry[11] = $Attributes
    Write-UInt16 -Target $entry -Offset 20 -Value ([uint32](($StartCluster -shr 16) -band 0xFFFF))
    Write-UInt16 -Target $entry -Offset 26 -Value ([uint32]($StartCluster -band 0xFFFF))
    Write-UInt32 -Target $entry -Offset 28 -Value ([uint32]$Size)
    foreach ($byte in $entry) {
        $Directory.Add($byte)
    }
}

function Write-Directory {
    param(
        [System.Collections.Generic.List[byte]] $Directory,
        [uint32] $StartCluster
    )
    $data = $Directory.ToArray()
    $clusterCount = [int][Math]::Ceiling([double]$data.Length / $script:ClusterBytes)
    if ($clusterCount -eq 0) {
        $clusterCount = 1
    }
    for ($i = 0; $i -lt $clusterCount; $i++) {
        $cluster = [uint32]($StartCluster + $i)
        $target = New-Object byte[] $script:ClusterBytes
        $offset = $i * $script:ClusterBytes
        [Array]::Copy($data, $offset, $target, 0, [Math]::Min($script:ClusterBytes, $data.Length - $offset))
        Write-BytesAt -Offset (Get-ClusterOffset -Cluster $cluster) -Data $target
    }
}

$stream = New-Object System.IO.FileStream(
    $OutputPath,
    [System.IO.FileMode]::Create,
    [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None)
try {
    $stream.SetLength($imageBytes)

    # --- FAT32 boot sector (superfloppy sector 0) --------------------------
    $boot = New-Object byte[] $script:BytesPerSector
    $boot[0] = 0xEB; $boot[1] = 0x58; $boot[2] = 0x90
    [Text.Encoding]::ASCII.GetBytes('DMDCLOCK ').CopyTo($boot, 3)
    $boot[11] = 0x00; $boot[12] = 0x02
    $boot[13] = $script:SectorsPerCluster
    Write-UInt16 -Target $boot -Offset 14 -Value ([uint16]$script:ReservedSectors)
    $boot[16] = $script:NumFats
    $boot[21] = 0xF8
    Write-UInt16 -Target $boot -Offset 24 -Value 63
    Write-UInt16 -Target $boot -Offset 26 -Value 255
    Write-UInt32 -Target $boot -Offset 28 -Value ([uint32]$script:HiddenSectors)
    Write-UInt32 -Target $boot -Offset 32 -Value ([uint32]$script:PartitionSectors)
    Write-UInt32 -Target $boot -Offset 36 -Value ([uint32]$script:FatSectors)
    Write-UInt32 -Target $boot -Offset 44 -Value 2
    Write-UInt32 -Target $boot -Offset 48 -Value 1
    Write-UInt32 -Target $boot -Offset 50 -Value 6
    $boot[64] = 0x80
    $boot[66] = 0x29
    Write-UInt32 -Target $boot -Offset 67 -Value ([uint32]0x20160325)
    [Text.Encoding]::ASCII.GetBytes('DMDCLOCK    ').CopyTo($boot, 71)
    [Text.Encoding]::ASCII.GetBytes('FAT32   ').CopyTo($boot, 82)
    $boot[510] = 0x55
    $boot[511] = 0xAA
    Write-BytesAt -Offset ([long]$script:HiddenSectors * $script:BytesPerSector) -Data $boot
    Write-BytesAt -Offset ([long]($script:HiddenSectors + 6) * $script:BytesPerSector) -Data $boot

    # --- FSInfo sector (partition sector 1) -------------------------------
    $fsinfo = New-Object byte[] $script:BytesPerSector
    $fsinfo[0] = 0x52; $fsinfo[1] = 0x52; $fsinfo[2] = 0x61; $fsinfo[3] = 0x41
    Write-UInt32 -Target $fsinfo -Offset 0x1E4 -Value ([uint32]0x61417272)
    Write-UInt32 -Target $fsinfo -Offset 0x1E8 -Value ([uint32]::MaxValue)
    Write-UInt32 -Target $fsinfo -Offset 0x1EC -Value ([uint32]::MaxValue)
    $fsinfo[0x1FE] = 0x55; $fsinfo[0x1FF] = 0xAA
    Write-BytesAt -Offset ([long]($script:HiddenSectors + 1) * $script:BytesPerSector) -Data $fsinfo
    Write-BytesAt -Offset ([long]($script:HiddenSectors + 7) * $script:BytesPerSector) -Data $fsinfo

    # --- FAT tables are written after all cluster allocations complete ----

    # --- Scene files: allocate clusters and write content -------------------
    $records = @()
    foreach ($file in $files) {
        $content = [IO.File]::ReadAllBytes($file.FullName)
        $fileClusters = [int][Math]::Ceiling([double]$content.Length / $script:ClusterBytes)
        if ($fileClusters -eq 0) {
            $fileClusters = 1
        }
        $startCluster = Get-AllocClusters -Count $fileClusters
        Write-BytesAt -Offset (Get-ClusterOffset -Cluster $startCluster) -Data $content
        $records += [pscustomobject]@{
            Name         = $file.RelativePath
            StartCluster = $startCluster
            Size         = [long]$content.Length
        }
    }

    # --- Directories: root -> dmd -> scenes -> files ------------------------
    $usedShortNames = @{}
    $fileEntries = New-Object 'System.Collections.Generic.List[byte]'
    foreach ($record in $records) {
        $shortName = Get-ShortNameEntry -Name $record.Name -Used $usedShortNames
        Add-DirectoryEntry `
            -Directory $fileEntries `
            -LongName $record.Name `
            -ShortName $shortName `
            -Attributes 0x20 `
            -StartCluster ([uint32]$record.StartCluster) `
            -Size $record.Size
    }

    $scenesCluster = Get-AllocClusters -Count (
        [int][Math]::Max(1, [Math]::Ceiling(($fileEntries.Count + 64) / 4096.0)))
    $dmdCluster = Get-AllocClusters -Count 1

    $sceneEntries = New-Object 'System.Collections.Generic.List[byte]'
    Add-DirectoryEntry -Directory $sceneEntries -LongName $null -ShortName '.          ' -Attributes 0x10 -StartCluster $scenesCluster -Size 0
    Add-DirectoryEntry -Directory $sceneEntries -LongName $null -ShortName '..         ' -Attributes 0x10 -StartCluster $dmdCluster -Size 0
    foreach ($byte in $fileEntries) {
        $sceneEntries.Add($byte)
    }
    Write-Directory -Directory $sceneEntries -StartCluster $scenesCluster

    $dmdEntries = New-Object 'System.Collections.Generic.List[byte]'
    Add-DirectoryEntry -Directory $dmdEntries -LongName $null -ShortName '.          ' -Attributes 0x10 -StartCluster $dmdCluster -Size 0
    Add-DirectoryEntry -Directory $dmdEntries -LongName $null -ShortName '..         ' -Attributes 0x10 -StartCluster 2 -Size 0
    Add-DirectoryEntry -Directory $dmdEntries -LongName $null -ShortName 'SCENES     ' -Attributes 0x10 -StartCluster $scenesCluster -Size 0
    Write-Directory -Directory $dmdEntries -StartCluster $dmdCluster

    $rootEntries = New-Object 'System.Collections.Generic.List[byte]'
    Add-DirectoryEntry -Directory $rootEntries -LongName $null -ShortName 'DMD        ' -Attributes 0x10 -StartCluster $dmdCluster -Size 0
    Write-Directory -Directory $rootEntries -StartCluster 2

    if ($script:NextCluster -gt ($script:Clusters + 2)) {
        throw "Cluster space exhausted: $($script:NextCluster - 3) of $($script:Clusters) data clusters used"
    }

    # --- FAT tables ---------------------------------------------------------
    Set-FatEntry -Cluster 0 -Value 0x0FFFFFF8
    Set-FatEntry -Cluster 1 -Value 0x0FFFFFFF
    Set-FatEntry -Cluster 2 -Value 0x0FFFFFFF
    for ($f = 0; $f -lt $script:NumFats; $f++) {
        $fatOffset = [long]($script:HiddenSectors + $script:ReservedSectors + $f * $script:FatSectors) * $script:BytesPerSector
        Write-BytesAt -Offset $fatOffset -Data $script:Fat
    }

    $stream.Flush()
    Write-Host 'microSD image build complete.'
}
finally {
    $stream.Dispose()
}
