[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$resetScript = Join-Path $PSScriptRoot '..\Reset-DmdClockSettings.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockSettingsResetTests-' + [Guid]::NewGuid().ToString('N'))

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

try {
    # --- Static evidence: the reset script parses cleanly and has no empty catch. ---
    $tokens = $null
    $errors = $null
    $resetAst = [Management.Automation.Language.Parser]::ParseFile(
        $resetScript, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "PowerShell parser rejected '$resetScript'."
    $emptyCatches = @($resetAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CatchClauseAst] -and
            $node.Body.Statements.Count -eq 0
    }, $true))
    Assert-True ($emptyCatches.Count -eq 0) 'Reset script contains an empty catch block.'

    # --- Static evidence: the reset script erases only the NVS settings region and
    # never issues a full-chip erase, a flash write, or any card-file mutation. ---
    $resetSource = Get-Content -LiteralPath $resetScript -Raw
    Assert-True ($resetSource -match 'erase_region') `
        'Reset script does not call esptool erase_region.'
    Assert-True ($resetSource -match "\`$nvsRegionOffset = '0x9000'") `
        'NVS region offset is not the expected 0x9000.'
    Assert-True ($resetSource -match "\`$nvsRegionSize = '0x6000'") `
        'NVS region size is not the expected 0x6000.'
    Assert-True ($resetSource -notmatch '(?im)\berase_flash\b') `
        'Reset script contains a full-flash erase command.'
    Assert-True ($resetSource -notmatch '(?im)\bwrite-flash\b') `
        'Reset script contains a flash-write command.'
    Assert-True ($resetSource -match 'No firmware, bootloader, partition table, other flash region, or') `
        'Reset script no longer declares its limited-scope banner.'
    Assert-True ($resetSource -match 'microSD card file is written, erased, or deleted') `
        'Reset script does not state that microSD card files are never written or deleted.'
    Assert-True ($resetSource -notmatch '(?im)\b(Remove-Item|Delete-Item|Clear-Item)\b.*(settings\.json|\\dmd[\\/]|/sd)') `
        'Reset script contains a command that deletes an SD card settings file.'
    Assert-True ($resetSource -notmatch '(?im)(settings\.json|/sd)[\s\S]{0,200}\b(Remove-Item|Delete-Item|Clear-Item)\b') `
        'Reset script deletes the SD card settings file.'
    Assert-True ($resetSource -match 'Delete  dmd\\config\\settings\.json') `
        'Reset script does not instruct removing /dmd/config/settings.json.'
    Assert-True ($resetSource -match 'that file wins at boot') `
        'Reset script does not explain that settings.json wins at boot.'

    # --- Static evidence: the reset always requires a typed confirmation and never
    # accepts -Force, mirroring the factory-recovery guardrails. ---
    Assert-True ($resetSource -match '-Force is not accepted') `
        'Reset script does not reject -Force.'
    Assert-True ($resetSource -match "Token 'RESET'") `
        'Reset script does not require the RESET confirmation token.'
    Assert-True ($resetSource -match 'Settings reset confirmation was not accepted') `
        'Reset script does not reject a wrong confirmation token.'
    Assert-True ($resetSource -match 'Assert-SerialPortUnchanged') `
        'Reset script does not revalidate the serial port before erasing.'
    Assert-True ($resetSource -match 'Assert-ConnectedHardware') `
        'Reset script does not verify the chip and flash before erasing.'
    Assert-True ($resetSource -match 'refusing an identity-weak selection') `
        'Reset script does not require a strong PnP port identity.'

    # --- Static evidence: the reset script never stages firmware or downloads an
    # image, and the provisioning module advertises the Reset operation. ---
    Assert-True ($resetSource -notmatch '(?im)\bInvoke-FirmwareDownloadOnly\b') `
        'Reset script reuses the firmware download path.'
    $moduleSource = Get-Content -LiteralPath $modulePath -Raw
    Assert-True ($moduleSource -match "ValidateSet\('Check', 'Download', 'Offline', 'SdCard', 'Flash', 'Reset'\)") `
        'Provisioning module does not advertise the Reset requirements operation.'

    # --- Extract only the hardware-check function, leaving Invoke-EsptoolChecked
    # undefined so a local mock drives chip/flash results (mirrors
    # Test-DmdClockBoardProbe). ---
    $functionNode = $resetAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Assert-ConnectedHardware'
    }, $true) | Select-Object -First 1
    if ($null -eq $functionNode) {
        throw 'Reset function not found: Assert-ConnectedHardware'
    }
    Invoke-Expression $functionNode.Extent.Text

    Import-Module $modulePath -Force

    # --- Unit: Assert-ConnectedHardware accepts a matching ESP32-S3 with 16 MB. ---
    $global:MockEsptoolCalls = [Collections.Generic.List[string[]]]::new()
    function Invoke-EsptoolChecked {
        param([Parameter(Mandatory)] [string[]] $Arguments)
        $global:MockEsptoolCalls.Add(@($Arguments))
        $joined = $Arguments -join ' '
        if ($joined -match '\bchip-id\b') {
            return 'Chip is ESP32-S3 (revision v0.1)'
        }
        if ($joined -match '\bflash-id\b') {
            return 'Detected flash size: 16MB'
        }
        return ''
    }

    $output = Assert-ConnectedHardware -SelectedPort 'COM9'
    $mockAllArgs = @($global:MockEsptoolCalls | ForEach-Object { $_ })
    Assert-True (@($mockAllArgs | Where-Object { $_ -eq 'chip-id' }).Count -ge 1) `
        'Assert-ConnectedHardware did not run chip-id.'
    Assert-True (@($mockAllArgs | Where-Object { $_ -eq 'flash-id' }).Count -ge 1) `
        'Assert-ConnectedHardware did not run flash-id.'

    # --- Unit: a non-ESP32-S3 chip is refused. ---
    function Invoke-EsptoolChecked {
        param([Parameter(Mandatory)] [string[]] $Arguments)
        if (($Arguments -join ' ') -match '\bchip-id\b') {
            return 'Chip is ESP32 (revision v1.0)'
        }
        return ''
    }
    Assert-Throws {
        Assert-ConnectedHardware -SelectedPort 'COM9'
    } 'not an ESP32-S3'

    # --- Unit: an ESP32-S3 with the wrong flash size is refused. ---
    function Invoke-EsptoolChecked {
        param([Parameter(Mandatory)] [string[]] $Arguments)
        if (($Arguments -join ' ') -match '\bchip-id\b') {
            return 'Chip is ESP32-S3 (revision v0.1)'
        }
        if (($Arguments -join ' ') -match '\bflash-id\b') {
            return 'Detected flash size: 8MB'
        }
        return ''
    }
    Assert-Throws {
        Assert-ConnectedHardware -SelectedPort 'COM9'
    } '16 MB flash'

    Write-Host '[PASS] Settings reset: source-inspection (region-only erase, no firmware download, no card-file mutation, -Force rejection, RESET token, serial identity) and unit chip/flash checks passed.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockSettingsResetTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
