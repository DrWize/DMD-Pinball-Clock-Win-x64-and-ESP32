[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$fixtureScript = Join-Path $PSScriptRoot '..\dev\New-DmdClockOfflineFixture.ps1'
$sdScript = Join-Path $PSScriptRoot '..\Prepare-DmdClockSdCard.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockDiskSafetyTests-' + [Guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern'; received: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected an error matching '$Pattern', but no error was raised."
}

# --- Mock storage model. Get-Disk / Get-Partition / Get-Volume are shadowed so
# no real disk is ever enumerated; all scenarios are driven by mock state.
# Global scope is used because the script under test runs in a child scope. ---
$global:MockDisks = @()

function Set-MockDisks {
    param([object[]] $Disks)
    $global:MockDisks = @($Disks)
}

function Get-Disk {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [int] $Number
    )
    if ($PSBoundParameters.ContainsKey('Number')) {
        $found = @($global:MockDisks | Where-Object { $_.Number -eq $Number })
        if ($found.Count -eq 0) { throw "Mock disk $Number was not found." }
        return $found[0]
    }
    return @($global:MockDisks)
}

function Get-Partition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $DiskNumber)
    $disk = @($global:MockDisks | Where-Object { $_.Number -eq $DiskNumber })
    if ($disk.Count -eq 0) { return @() }
    return @($disk[0].Partitions)
}

function Find-MockVolumeByLetter {
    param([string] $Letter)
    foreach ($disk in $global:MockDisks) {
        foreach ($partition in @($disk.Partitions)) {
            if ($null -ne $partition.Volume -and
                [string]$partition.Volume.DriveLetter -eq $Letter) {
                return $partition.Volume
            }
        }
    }
    throw "Mock volume '$Letter' was not found."
}

function Get-Volume {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject,
        [Parameter(ValueFromPipelineByPropertyName, Position = 0)]
        [string] $DriveLetter
    )
    process {
        $items = @()
        if ($null -ne $InputObject -and
            $InputObject.PSObject.Properties.Name -contains 'Volume') {
            $items += $InputObject.Volume
        }
        elseif ($PSBoundParameters.ContainsKey('DriveLetter')) {
            $items += Find-MockVolumeByLetter $DriveLetter
        }
        return @($items)
    }
}

function New-MockVolume {
    param(
        [string] $DriveLetter,
        [string] $FileSystem = 'FAT32',
        [string] $HealthStatus = 'Healthy',
        [string] $DriveType = 'Removable',
        [string] $FileSystemLabel = 'DMDCLOCK',
        [long] $Size = 16GB
    )
    return [pscustomobject]@{
        DriveLetter = $DriveLetter
        FileSystem = $FileSystem
        HealthStatus = $HealthStatus
        DriveType = $DriveType
        FileSystemLabel = $FileSystemLabel
        Size = $Size
    }
}

function New-MockPartition {
    param(
        [int] $PartitionNumber,
        [long] $Offset = 0,
        [long] $Size = 16GB,
        [string] $DriveLetter = '',
        [string] $Type = 'Basic',
        [bool] $IsSystem = $false,
        [bool] $IsBoot = $false,
        [object] $Volume
    )
    return [pscustomobject]@{
        PartitionNumber = $PartitionNumber
        Offset = $Offset
        Size = $Size
        DriveLetter = $DriveLetter
        Type = $Type
        IsSystem = $IsSystem
        IsBoot = $IsBoot
        Volume = $Volume
    }
}

function New-MockDisk {
    param(
        [int] $Number,
        [string] $BusType = 'USB',
        [string] $FriendlyName = 'Mock removable disk',
        [bool] $IsSystem = $false,
        [bool] $IsBoot = $false,
        [bool] $IsOffline = $false,
        [bool] $IsReadOnly = $false,
        [string] $OperationalStatus = 'Online',
        [string] $PartitionStyle = 'MBR',
        [long] $Size = 16GB,
        [string] $SerialNumber,
        [string] $UniqueId,
        [object[]] $Partitions = @()
    )
    return [pscustomobject]@{
        Number = $Number
        FriendlyName = $FriendlyName
        SerialNumber = $(if ($SerialNumber) { $SerialNumber } else { "SN$Number" })
        UniqueId = $(if ($UniqueId) { $UniqueId } else { "U$Number" })
        Size = $Size
        BusType = $BusType
        PartitionStyle = $PartitionStyle
        IsSystem = $IsSystem
        IsBoot = $IsBoot
        IsOffline = $IsOffline
        IsReadOnly = $IsReadOnly
        OperationalStatus = $OperationalStatus
        Partitions = @($Partitions)
    }
}

try {
    # --- Static evidence (acceptance item 3): the preparation script never
    # constructs partitioning, formatting, or deletion commands, and never
    # auto-selects a disk. ---
    $sdSource = Get-Content -LiteralPath $sdScript -Raw
    Assert-True ($sdSource -match 'No partitioning, formatting, or deletion of card files is performed\.') `
        'microSD preparation no longer declares its non-destructive safety banner.'
    Assert-True ($sdSource -match 'no disk is selected automatically') `
        'microSD preparation may select a disk automatically.'
    Assert-True ($sdSource -notmatch '(?im)\b(Clear-Disk|Format-Volume|Initialize-Disk|New-Partition|Remove-Partition)\b') `
        'microSD preparation contains a partitioning or formatting command.'

    # Parse the script and expose its functions without running its main body.
    $tokens = $null
    $errors = $null
    $sdAst = [Management.Automation.Language.Parser]::ParseFile(
        $sdScript, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser rejected '$sdScript'."
    $functionAsts = @($sdAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
    foreach ($functionAst in $functionAsts) { Invoke-Expression $functionAst.Extent.Text }

    Import-Module $modulePath -Force
    $fixtureRoot = & $fixtureScript `
        -Destination (Join-Path $testRoot 'offline-fixture') -Library DmdLarge |
        Select-Object -Last 1
    Assert-True (-not [string]::IsNullOrWhiteSpace($fixtureRoot)) `
        'Offline fixture builder returned no root.'
    Assert-True (Test-Path -LiteralPath (Join-Path $fixtureRoot 'staging-manifest.json')) `
        'Offline fixture lacks its staging manifest.'

    $freeLetter = $null
    foreach ($code in 90..65) {
        $candidate = [char]$code
        if (-not (Test-Path -LiteralPath "$candidate`:\" -PathType Container)) {
            $freeLetter = [string]$candidate
            break
        }
    }
    Assert-True ($null -ne $freeLetter) 'No free drive letter was found for the mount check.'

    # --- Unit tests: candidate classification (mock hardware only). ---
    $healthyVolume = New-MockVolume -DriveLetter $freeLetter
    $healthyPartition = New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
        -DriveLetter $freeLetter -Volume $healthyVolume

    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'USB' `
        -Partitions @($healthyPartition))
    $snapshot = Get-DmdClockDiskSnapshot -Number 1
    Assert-True $snapshot.IsCandidate 'A healthy USB removable disk was excluded.'
    Assert-True ($snapshot.Topology -match '1:0:') 'Candidate topology string is missing partition data.'

    Set-MockDisks @(New-MockDisk -Number 0 -BusType 'USB' -IsSystem $true -Size 512GB)
    $systemSnapshot = Get-DmdClockDiskSnapshot -Number 0
    Assert-True (-not $systemSnapshot.IsCandidate) 'The system disk was classified as a candidate.'
    Assert-True ($systemSnapshot.ExclusionReason -match 'Windows system or boot partition') `
        'System-disk exclusion reason is missing.'

    Set-MockDisks @(New-MockDisk -Number 2 -BusType 'USB' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -IsBoot $true -Volume $healthyVolume))
    Assert-True (-not (Get-DmdClockDiskSnapshot -Number 2).IsCandidate) `
        'A disk with a boot partition was classified as a candidate.'

    Set-MockDisks @(New-MockDisk -Number 3 -BusType 'SATA' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 500GB `
            -Volume $healthyVolume))
    $busSnapshot = Get-DmdClockDiskSnapshot -Number 3
    Assert-True (-not $busSnapshot.IsCandidate) 'A fixed-bus disk was classified as a candidate.'
    Assert-True ($busSnapshot.ExclusionReason -match "bus type 'SATA' is not USB, SD, or MMC") `
        'Bus-type exclusion reason is missing.'

    Set-MockDisks @(New-MockDisk -Number 4 -BusType 'USB' -IsOffline $true `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -Volume $healthyVolume))
    $offlineSnapshot = Get-DmdClockDiskSnapshot -Number 4
    Assert-True (-not $offlineSnapshot.IsCandidate) 'An offline disk was classified as a candidate.'
    Assert-True ($offlineSnapshot.ExclusionReason -match 'offline, read-only, or not operational') `
        'Offline exclusion reason is missing.'

    Set-MockDisks @(New-MockDisk -Number 5 -BusType 'USB' -IsReadOnly $true `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -Volume $healthyVolume))
    Assert-True (-not (Get-DmdClockDiskSnapshot -Number 5).IsCandidate) `
        'A read-only disk was classified as a candidate.'

    # --- Unit tests: multiple removable disks; nothing is auto-selected. ---
    $diskA = New-MockDisk -Number 1 -BusType 'USB' -FriendlyName 'Fixture card A' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume $healthyVolume)
    $diskB = New-MockDisk -Number 2 -BusType 'SD' -FriendlyName 'Fixture card B' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 32GB `
            -DriveLetter 'F' -Volume (New-MockVolume -DriveLetter 'F'))
    $systemDisk = New-MockDisk -Number 0 -BusType 'NVMe' -IsSystem $true -Size 512GB
    $fixedDisk = New-MockDisk -Number 3 -BusType 'SATA' -Size 1TB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 1TB `
            -DriveLetter 'C' -Volume (New-MockVolume -DriveLetter 'C' `
                -FileSystem 'NTFS' -DriveType 'Fixed'))
    Set-MockDisks @($diskA, $diskB, $systemDisk, $fixedDisk)
    $candidates = @(Get-DmdClockDiskCandidates)
    Assert-True ($candidates.Count -eq 4) "Expected 4 inspected disks; found $($candidates.Count)."
    Assert-True (@($candidates | Where-Object IsCandidate).Count -eq 2) `
        'Expected exactly two removable candidates among four disks.'
    Assert-True (@($candidates | Where-Object { -not $_.IsCandidate }).Count -eq 2) `
        'Expected exactly two excluded disks among four disks.'

    # --- Unit tests: topology-change guard. ---
    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'USB' -SerialNumber 'A1' -UniqueId 'U1' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume $healthyVolume))
    $original = Get-DmdClockDiskSnapshot -Number 1
    $null = Assert-DmdClockDiskUnchanged -Original $original

    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'USB' -SerialNumber 'A1' -UniqueId 'U1' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 4096 -Size 16GB `
            -DriveLetter $freeLetter -Volume $healthyVolume))
    Assert-Throws { $null = Assert-DmdClockDiskUnchanged -Original $original } `
        'identity/topology changed.*Topology'

    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'USB' -SerialNumber 'A2' -UniqueId 'U1' `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume $healthyVolume))
    Assert-Throws { $null = Assert-DmdClockDiskUnchanged -Original $original } `
        'identity/topology changed.*SerialNumber'

    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'USB' -SerialNumber 'A1' -UniqueId 'U1' `
        -IsSystem $true `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume $healthyVolume))
    Assert-Throws { $null = Assert-DmdClockDiskUnchanged -Original $original } `
        'no longer an eligible external disk'

    # --- Integration tests: the full script refuses unsafe selections through
    # -WhatIf with the offline fixture, so no download or hardware access
    # happens during validation. ---
    $fixturePrefix = $fixtureRoot.TrimEnd('\') + '\'
    $fixtureFilesBefore = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File |
        ForEach-Object {
            "{0}|{1}" -f $_.FullName.Substring($fixturePrefix.Length),
                (Get-DmdClockSha256 -Path $_.FullName)
        })
    Set-MockDisks @(New-MockDisk -Number 0 -BusType 'USB' -IsSystem $true -Size 512GB)
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 0 -StagingSource $fixtureRoot -Library DmdLarge
    } 'Refusing Disk 0: it contains a Windows system or boot partition'

    Set-MockDisks @(New-MockDisk -Number 1 -BusType 'SATA' -Size 1TB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 1TB `
            -Volume $healthyVolume))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 1 -StagingSource $fixtureRoot -Library DmdLarge
    } "Refusing Disk 1: bus type 'SATA' is not USB, SD, or MMC"

    Set-MockDisks @(New-MockDisk -Number 2 -BusType 'USB' -IsOffline $true -Size 16GB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -Volume $healthyVolume))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 2 -StagingSource $fixtureRoot -Library DmdLarge
    } 'Refusing Disk 2: it is offline, read-only, or not operational'

    Set-MockDisks @(New-MockDisk -Number 3 -BusType 'USB' -Size 16GB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume (New-MockVolume -DriveLetter $freeLetter -FileSystem 'NTFS')))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 3 -StagingSource $fixtureRoot -Library DmdLarge
    } 'requires FAT32'

    Set-MockDisks @(New-MockDisk -Number 4 -BusType 'USB' -Size 16GB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume (New-MockVolume -DriveLetter $freeLetter `
                -FileSystem 'FAT32' -HealthStatus 'Unhealthy')))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 4 -StagingSource $fixtureRoot -Library DmdLarge
    } "health status is 'Unhealthy', not Healthy"

    Set-MockDisks @(New-MockDisk -Number 5 -BusType 'USB' -Size 16GB `
        -Partitions @(New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
            -DriveLetter $freeLetter -Volume (New-MockVolume -DriveLetter $freeLetter `
                -FileSystem 'FAT32' -DriveType 'Fixed')))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 5 -StagingSource $fixtureRoot -Library DmdLarge
    } 'Use -AllowFixedDrive only after confirming it is the microSD card'

    # Opting in to a fixed drive passes every safety gate and then only fails on
    # the environment-dependent mount check.
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 5 -AllowFixedDrive -StagingSource $fixtureRoot -Library DmdLarge
    } 'Volume root is unavailable'

    # Exactly one mounted volume is required; 2 and 0 are both refused.
    Set-MockDisks @(New-MockDisk -Number 6 -BusType 'USB' -Size 16GB `
        -Partitions @(
            (New-MockPartition -PartitionNumber 1 -Offset 0 -Size 8GB `
                -DriveLetter $freeLetter -Volume $healthyVolume),
            (New-MockPartition -PartitionNumber 2 -Offset 8GB -Size 8GB `
                -DriveLetter 'F' -Volume (New-MockVolume -DriveLetter 'F'))
        ))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 6 -StagingSource $fixtureRoot -Library DmdLarge
    } 'must expose exactly one mounted volume; found 2'

    Set-MockDisks @(New-MockDisk -Number 7 -BusType 'USB' -Size 16GB `
        -Partitions @(
            New-MockPartition -PartitionNumber 1 -Offset 0 -Size 16GB `
                -Volume (New-MockVolume -DriveLetter '')
        ))
    Assert-Throws {
        & $sdScript -WhatIf -DiskNumber 7 -StagingSource $fixtureRoot -Library DmdLarge
    } 'must expose exactly one mounted volume; found 0'

    # --- Integration test: -ListDisks enumerates candidates without selecting one. ---
    Set-MockDisks @($diskA, $diskB, $systemDisk, $fixedDisk)
    $listing = (& $sdScript -ListDisks -StagingSource $fixtureRoot 6>&1 | Out-String)
    Assert-True ($listing -match 'no disk is selected automatically') `
        'Disk listing does not state that no disk is selected automatically.'
    Assert-True (([regex]::Matches($listing, 'CANDIDATE')).Count -eq 2) `
        'Disk listing did not mark exactly two candidate disks.'
    Assert-True (([regex]::Matches($listing, 'EXCLUDED')).Count -eq 2) `
        'Disk listing did not mark exactly two excluded disks.'

    # The -WhatIf / -ListDisks runs must not have modified the offline fixture.
    $fixtureFilesAfter = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File |
        ForEach-Object {
            "{0}|{1}" -f $_.FullName.Substring($fixturePrefix.Length),
                (Get-DmdClockSha256 -Path $_.FullName)
        })
    Assert-True (@(Compare-Object $fixtureFilesBefore $fixtureFilesAfter).Count -eq 0) `
        'Offline fixture changed during -WhatIf or -ListDisks runs.'

    Write-Host '[PASS] Disk safety: system disk, boot partition, bus, offline/read-only, FAT32, health, fixed-drive opt-in, mounted-volume count, multiple removable disks, no-auto-selection, topology guard, and -WhatIf refusal tests passed.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockDiskSafetyTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
