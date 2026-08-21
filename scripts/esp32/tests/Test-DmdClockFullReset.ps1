[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$flashScript = Join-Path $PSScriptRoot '..\Flash-DmdClockEsp32.ps1'
$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
Import-Module $modulePath -Force

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

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $flashScript, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "PowerShell parser rejected '$flashScript'."

$source = Get-Content -LiteralPath $flashScript -Raw
Assert-True ($source -match "ValidateSet\('Application', 'Full', 'FullReset'\)") `
    'FlashMode does not advertise FullReset.'
$config = Get-DmdClockConfig
Assert-True ($config.NvsRegionOffset -eq '0x9000') `
    'FullReset NVS offset is not 0x9000.'
Assert-True ($config.NvsRegionSize -eq '0x6000') `
    'FullReset NVS size is not 0x6000.'
Assert-True ($source -notmatch '(?im)\berase_flash\b') `
    'The flash script contains a full-chip erase command.'
Assert-True ($source -match 'Complete installation \+ reset device settings') `
    'The flash menu does not describe the settings-reset mode.'
Assert-True ($source -match 'microSD card remains untouched') `
    'FullReset does not warn that microSD settings remain.'

$functionNode = $ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Invoke-FirmwareFlash'
}, $true) | Select-Object -First 1
if ($null -eq $functionNode) { throw 'Flash function not found: Invoke-FirmwareFlash' }
Invoke-Expression $functionNode.Extent.Text

$selectedTarget = [pscustomobject]@{ Product = 'Test ESP32-S3 board'; Id = 'test-board' }
$selectedPortIdentity = [pscustomobject]@{ Name = 'Test serial port'; InstanceId = 'USB\TEST' }
$nvsRegionOffset = '0x9000'
$nvsRegionSize = '0x6000'
$esptool = [pscustomobject]@{ Path = 'mock-esptool.exe'; Version = 'test' }
$WhatIf = $false
$Force = $false
$script:confirmation = 'RESET'
$script:commands = [Collections.Generic.List[string]]::new()
$script:requestedMode = $null

$package = [pscustomobject]@{
    Source = 'test fixture'
    Version = '1.6.0-test'
    Manifest = [pscustomobject]@{
        package = [pscustomobject]@{ sha256 = ('A' * 64) }
        flash = [pscustomobject]@{
            settings = [pscustomobject]@{ mode = 'dio'; frequency = '80m'; size = '16MB' }
        }
    }
}
$fullFiles = @(
    [pscustomobject]@{ Offset = '0x0'; Path = 'bootloader.bin'; RelativePath = 'bootloader.bin' },
    [pscustomobject]@{ Offset = '0x8000'; Path = 'partition-table.bin'; RelativePath = 'partition-table.bin' },
    [pscustomobject]@{ Offset = '0x10000'; Path = 'dmdclock.bin'; RelativePath = 'dmdclock.bin' }
)

function Get-SelectedFlashFiles {
    param($Package, [string] $Mode)
    $script:requestedMode = $Mode
    return $fullFiles
}

function Assert-DmdClockSerialPortUnchanged {
    param([string] $SelectedPort, $PortIdentity, [string] $Context)
}

function Read-DmdClockHighlightedConfirmation {
    param([string] $Prefix, [string] $Token, [string] $Suffix, [string] $RequiredParameter, [ConsoleColor] $Color)
    return $script:confirmation
}

function Write-DmdClockProvisioningLog {
    param([string] $Event, [string] $Detail)
}

function Invoke-DmdClockEsptoolChecked {
    param([string] $EsptoolPath, [string[]] $Arguments)
    $script:commands.Add(($Arguments -join ' '))
    return 'mock esptool success'
}

# FullReset must erase only NVS, then write the normal complete-installation files.
$result = Invoke-FirmwareFlash -Package $package -Mode FullReset -SelectedPort COM9
Assert-True $result 'FullReset did not report success.'
Assert-True ($script:requestedMode -eq 'FullReset') `
    'FullReset was not passed to flash-file selection.'
Assert-True ($script:commands.Count -eq 2) `
    "FullReset expected two esptool commands; received $($script:commands.Count)."
Assert-True ($script:commands[0] -eq '--chip esp32s3 --port COM9 --baud 460800 --before default-reset --after no-reset erase_region 0x9000 0x6000') `
    "FullReset constructed an unexpected NVS command: $($script:commands[0])"
Assert-True ($script:commands[1] -match '\bwrite-flash\b') `
    'FullReset did not follow the NVS erase with a firmware write.'
foreach ($offset in @('0x0', '0x8000', '0x10000')) {
    Assert-True ($script:commands[1] -match [regex]::Escape($offset)) `
        "FullReset omitted complete-installation offset $offset."
}

# A wrong confirmation must cancel before either destructive command.
$script:commands.Clear()
$script:confirmation = 'NO'
$result = Invoke-FirmwareFlash -Package $package -Mode FullReset -SelectedPort COM9
Assert-True (-not $result) 'A wrong RESET confirmation did not cancel FullReset.'
Assert-True ($script:commands.Count -eq 0) `
    'FullReset ran an esptool command after a wrong confirmation.'

# Automation cannot bypass the destructive confirmation.
$script:confirmation = 'RESET'
$Force = $true
Assert-Throws {
    $null = Invoke-FirmwareFlash -Package $package -Mode FullReset -SelectedPort COM9
} '-Force is not accepted'
Assert-True ($script:commands.Count -eq 0) `
    'FullReset ran an esptool command while rejecting -Force.'

# Dry-run constructs and displays the plan but executes no command.
$Force = $false
$WhatIf = $true
$result = Invoke-FirmwareFlash -Package $package -Mode FullReset -SelectedPort COM9
Assert-True (-not $result) 'FullReset -WhatIf unexpectedly reported a completed flash.'
Assert-True ($script:commands.Count -eq 0) `
    'FullReset -WhatIf ran an esptool command.'

# Existing Full mode remains a single write and never erases NVS.
$WhatIf = $false
$script:confirmation = 'FLASH'
$result = Invoke-FirmwareFlash -Package $package -Mode Full -SelectedPort COM9
Assert-True $result 'Full mode did not report success.'
Assert-True ($script:commands.Count -eq 1 -and $script:commands[0] -match '\bwrite-flash\b') `
    'Full mode did not remain a single firmware-write command.'
Assert-True ($script:commands[0] -notmatch '\berase_region\b') `
    'Full mode unexpectedly erased NVS.'

Write-Host '[PASS] FullReset: exact NVS-only erase, complete write, confirmation, -Force rejection, dry-run, and preserved Full mode passed.' -ForegroundColor Green
