# END-USER SCRIPT - resets all DMDClock settings on the ESP32-S3 (Windows 11 x64 / PowerShell 7).
# Erases ONLY the NVS settings partition region (0x9000, 0x6000) on a connected
# board, so brightness, theme, timezone, schedule, Wi-Fi, and MQTT settings return
# to factory defaults after the next reboot. No firmware, bootloader, partition
# table, other flash region, or microSD card file is written, erased, or deleted.
# Settings also persist in /dmd/config/settings.json on the TF card (SD wins at
# boot), so the final message explains that the microSD card must be handled manually.
# Requires the shared DmdClock.Provisioning.psm1 next to this script. See docs\INSTALL-ESP32.md.
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

$config = Get-DmdClockConfig
$DmdClockCacheRoot = $config.CacheRoot
$nvsRegionOffset = $config.NvsRegionOffset
$nvsRegionSize = $config.NvsRegionSize
$esptoolRepository = $config.EsptoolRepository
$toolCacheRoot = Join-Path $DmdClockCacheRoot 'tools\esptool'
$hardwareTargets = @(Get-DmdClockHardwareTargets)

function Show-ResetBanner {
    Write-Host ''
    Write-Host 'DMDClock ESP32-S3 settings reset' -ForegroundColor Cyan
    Write-Host '---------------------------------' -ForegroundColor DarkCyan
    Write-Host "This erases ONLY the NVS settings region ($nvsRegionOffset, size $nvsRegionSize)."
    Write-Host 'No firmware, bootloader, partition table, other flash region, or' `
        -ForegroundColor Yellow
    Write-Host 'microSD card file is written, erased, or deleted.' -ForegroundColor Yellow
}

function Get-DmdClockResetDeviceProbe {
    $ports = @(Get-DmdClockConnectedPorts)
    if ($ports.Count -eq 0) {
        return @()
    }
    $rows = @()
    foreach ($port in $ports) {
        $native = $port.InstanceId -match 'VID_303A&PID_1001'
        $banner = Read-DmdClockSerialBanner -Port $port.Port -NativeUsbJtag:$native -ToolCacheRoot $toolCacheRoot
        $model = 'unrecognized'
        $target = $null
        $identified = $false
        if (-not [string]::IsNullOrWhiteSpace($banner)) {
            $probe = Get-DmdClockBoardProbe -BannerText $banner
            $target = Resolve-DmdClockDeviceFromProbe -Probe $probe
            if ($null -ne $target) {
                $model = $target.ShortLabel
                $identified = $true
            } else {
                $model = 'DMDClock (model unclear)'
            }
        }
        $rows += [pscustomobject]@{
            Port = $port.Port
            Name = $port.Name
            Identity = $port
            Model = $model
            Target = $target
            Identified = $identified
        }
    }
    return $rows
}

function Show-ResetDeviceTable {
    param([Parameter(Mandatory)] [object[]] $Rows)
    Show-DmdClockDeviceTable -Rows $Rows
}

function Show-ResetDryRun {
    $ports = @(Get-DmdClockConnectedPorts)
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
    Write-Host 'After the reset: remove dmd\config\settings.json from the microSD card' -ForegroundColor Cyan
    Write-Host 'before reinserting (that file wins at boot).' -ForegroundColor Cyan
}

Show-ResetBanner

$requirementsPath = Join-Path $DmdClockCacheRoot 'DmdClockFiles'
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
    if (-not $requirements.Passed) {
        Set-DmdClockOperationResult -Status failed -Operation 'Check requirements' `
            -Detail 'One or more requirements checks failed.'
        exit 1
    }
    Set-DmdClockOperationResult -Status completed -Operation 'Check requirements'
    return
}

$runOutcome = 'cancelled'
$runDetail = ''
$logPath = $null
$esptool = $null

if ($Force) {
    throw 'Settings reset requires the final typed RESET confirmation; -Force is not accepted.'
}

try {
    if ($WhatIf) {
        Show-ResetDryRun
        $runOutcome = 'completed'
        return
    }

    # --- Auto-detect devices ---
    $probeRows = @(Get-DmdClockResetDeviceProbe)
    $selectedRow = $null

    if ($Port) {
        $match = @($probeRows | Where-Object Port -eq $Port)
        if ($match.Count -eq 1) {
            $selectedRow = $match[0]
        }
    } elseif ($probeRows.Count -eq 1) {
        $selectedRow = $probeRows[0]
        Write-Host ''
        Write-Host "Auto-detected: $($selectedRow.Port) - $($selectedRow.Model)" -ForegroundColor Green
    } elseif ($probeRows.Count -gt 1) {
        Show-ResetDeviceTable -Rows $probeRows
        $choice = Read-DmdClockMenuChoice -Prompt 'Select device to reset' -Minimum 1 `
            -Maximum ($probeRows.Count + 1) -RequiredParameter '-Port'
        if ($choice -gt $probeRows.Count) { return }
        $selectedRow = $probeRows[$choice - 1]
    } else {
        throw 'No serial port was detected.'
    }

    if ($null -eq $selectedRow) {
        throw "No matching device was found for port '$Port'."
    }

    $selectedPort = $selectedRow.Port
    $selectedPortIdentity = $selectedRow.Identity
    $identifiedDevice = $selectedRow.Identified

    Write-Host ''
    Write-Host "Selected: $selectedPort - $($selectedRow.Model)" -ForegroundColor Cyan

    # --- Ensure esptool is available ---
    $cachedEsptool = Get-DmdClockCachedEsptool -ToolCacheRoot $toolCacheRoot
    if ($cachedEsptool) {
        Write-Host "Using cached esptool: $cachedEsptool"
        $esptool = [pscustomobject]@{ Path = $cachedEsptool; Version = 'cached' }
    } else {
        $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $toolCacheRoot
    }

    # --- Select port (if not already set) ---
    if (-not $Port) {
        $portResult = Select-DmdClockSerialPort -Port $selectedPort -Context 'erasing NVS'
        $selectedPort = $portResult.Port
        $selectedPortIdentity = $portResult.Identity
    }

    # --- Verify hardware ---
    Assert-DmdClockEsp32s3WithFlash -EsptoolPath $esptool.Path -Port $selectedPort

    if (-not $identifiedDevice) {
        Write-Host ''
        Write-Warning 'This device could not be automatically identified.'
        Write-Warning 'Only ESP32 NVS settings will be cleared. The microSD card is NOT touched.'
        Write-Warning 'You must manually delete dmd\config\settings.json from the TF card.'
        Write-Host ''
        $proceed = Read-DmdClockHighlightedConfirmation `
            -Prefix 'Type ' `
            -Token 'RESET' `
            -Suffix ' to erase settings on this unidentified device' `
            -RequiredParameter '-ConfirmHardware RESET' `
            -Color Yellow
        if ($proceed -ine 'RESET') {
            Write-Host 'Reset cancelled.' -ForegroundColor Yellow
            $runOutcome = 'cancelled'
            return
        }
    } else {
        Write-Host ''
        Write-Warning 'This erases ALL saved DMDClock settings, Wi-Fi, and MQTT credentials.'
        Write-Warning 'Only ESP32 NVS is cleared. The microSD card is NOT touched.'
        Write-Host ''
        $confirmation = if ($ConfirmHardware) {
            $ConfirmHardware.Trim()
        } else {
            Read-DmdClockHighlightedConfirmation `
                -Prefix 'Type ' `
                -Token 'RESET' `
                -Suffix ' (uppercase or lowercase) to erase the NVS settings region' `
                -RequiredParameter '-ConfirmHardware RESET' `
                -Color Yellow
        }
        if ($confirmation -ine 'RESET') {
            Write-Host 'Reset cancelled.' -ForegroundColor Yellow
            $runOutcome = 'cancelled'
            return
        }
    }

    # --- Erase NVS ---
    $logDirectory = Join-Path $DmdClockCacheRoot 'Logs\Provisioning'
    $logPath = Start-DmdClockProvisioningLog -LogDirectory $logDirectory -Operation 'reset-settings'
    Write-Host "Log: $logPath"
    Write-DmdClockRequirementsLog -Requirements $requirements
    Write-DmdClockProvisioningLog -Event 'invocation' -Detail (
        "region=$nvsRegionOffset size=$nvsRegionSize port=$selectedPort identified=$identifiedDevice")

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
    Assert-DmdClockSerialPortUnchanged -SelectedPort $selectedPort `
        -PortIdentity $selectedPortIdentity -Context 'erasing NVS'
    $null = Invoke-DmdClockEsptoolChecked -EsptoolPath $esptool.Path -Arguments $arguments
    Write-Host ''
    Write-Host '[DONE] NVS settings region erased; the board was reset to factory-default settings.' `
        -ForegroundColor Green
    Write-Host ''
    Write-Host 'IMPORTANT: Only ESP32 NVS was cleared. The microSD card was NOT touched.' `
        -ForegroundColor Cyan
    Write-Host 'To complete the reset, manually delete dmd\config\settings.json from the TF card.' `
        -ForegroundColor Cyan
    Write-Host ''
    $cacheLocations = Get-DmdClockCacheLocations
    Write-Host "Cached files: $($cacheLocations.Tools)" -ForegroundColor DarkGray
    Write-Host 'To free disk space, delete the cache folder above.' -ForegroundColor DarkGray
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
    Set-DmdClockOperationResult -Status failed -Operation 'Reset device settings' `
        -Detail $originalError.Exception.Message
    throw $originalError
}
finally {
    Complete-DmdClockProvisioningLogSafely -LogPath $logPath `
        -Outcome $runOutcome -Detail $runDetail
    if ($runOutcome -ne 'failed') {
        $resultStatus = if ($WhatIf) { 'dry-run' } else { $runOutcome }
        Set-DmdClockOperationResult -Status $resultStatus -Operation 'Reset device settings' `
            -Detail $runDetail
    }
}
