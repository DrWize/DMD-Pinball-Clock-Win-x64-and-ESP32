# END-USER SCRIPT - DMDClock ESP32 installation orchestrator (Windows 11 x64 / PowerShell 7).
# Runs the setup in the correct order: stage every required artifact once, prepare
# the microSD card (skipping when it is already up to date), then flash the board.
#   -DownloadOnly stages the DMD-Large library and the latest firmware images for
#     both supported boards (plus the official esptool) and stops, so you can flash
#     fully offline later.
#   -Update re-checks GitHub and re-stages the latest library and firmware even when
#     staging already exists (unchanged artifacts are reused, not re-downloaded).
#   -SkipCard skips the microSD card phase for flash-only runs.
#   -Force skips the interactive FLASH confirmation (testing/automation).
#   If Prepare-DmdClockSdCard.ps1, Flash-DmdClockEsp32.ps1,
#   Reset-DmdClockSettings.ps1, or DmdClock.Provisioning.psm1 is missing next to
#   this script, it is downloaded automatically from GitHub (network required on
#   the first run).
#   -CompanionScriptSource overrides the source: an https URL base or a local
#   folder path containing the four companion files (offline mirror).
# See docs\INSTALL-ESP32.md. Developer tooling lives in scripts\esp32\dev;
# automated tests live in scripts\esp32\tests.
[CmdletBinding()]
param(
    [switch] $Wizard,

    [switch] $CheckRequirements,

    [string] $CompanionScriptSource,

    [switch] $DownloadOnly,

    [switch] $Update,

    [switch] $SkipCard,

    [switch] $Force,

    [ValidateSet('Waveshare7', 'Waveshare349B')]
    [string] $Board,

    [ValidateSet('Application', 'Full', 'FullReset')]
    [string] $FlashMode,

    [ValidatePattern('^COM\d+$')]
    [string] $Port,

    [ValidateSet('V1', 'V2')]
    [string] $BoardRevision,

    [switch] $FactoryRecovery,

    [ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $ReleaseTag,

    [ValidateSet('Original', 'DmdLarge')]
    [string] $Library = 'DmdLarge',

    [string] $Destination,

    [int] $DiskNumber = -1,

    [string] $ConfirmHardware,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32',

    [Alias('DryRun')]
    [switch] $WhatIf,

    [Parameter(DontShow)]
    [switch] $MenuChild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$showStartupMenu = ($PSBoundParameters.Count -eq 0 -and -not [Console]::IsInputRedirected)

function Show-DmdClockBanner {
    Write-Host '     :::    :::       :::::::::::::::::::::::::    :::::::::::::::::::::::::::::::: :::    ::: ' -ForegroundColor Cyan
    Write-Host '   :+: :+:  :+:           :+:    :+:       :+:+:   :+:    :+:    :+:      :+:    :+::+:    :+: ' -ForegroundColor Cyan
    Write-Host '  +:+   +:+ +:+           +:+    +:+       :+:+:+  +:+    +:+    +:+      +:+       +:+    +:+ ' -ForegroundColor Cyan
    Write-Host ' +#++:++#++:+#+           +#+    +#++:++#  +#+ +:+ +#+    +#+    +#++:++# +#++:++# +#++:++#++ ' -ForegroundColor Cyan
    Write-Host ' #+#     +#++#+           +#+    +#+       +#+  +#+#+#    +#+    +#+      +#+       +#+    +#+ ' -ForegroundColor Cyan
    Write-Host ' #+#     #+##+#           #+#    #+#       #+#   #+#+#    #+#    #+#      #+#    #+##+#    #+# ' -ForegroundColor Cyan
    Write-Host ' ###     #####################################    ####    ###    ################## ###    ### ' -ForegroundColor Cyan
    Write-Host ' DMD clock flasher for esp32-s3 devices.' -ForegroundColor Yellow
    Write-Host ' https://github.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32'
    Write-Host ''
}

function Show-DmdClockStartupMenu {
    if (-not [Console]::IsOutputRedirected) {
        Clear-Host
    }
    Show-DmdClockBanner
    Write-Host '  [1] Prepare microSD card' -ForegroundColor White
    Write-Host '  [2] Flash firmware' -ForegroundColor White
    Write-Host '  [3] Reset device settings' -ForegroundColor White
    Write-Host '  [4] Download only' -ForegroundColor White
    Write-Host '  [5] Complete install / update' -ForegroundColor White
    Write-Host '  [6] Exit' -ForegroundColor DarkGray
    Write-Host ''
}

if (-not $showStartupMenu -and -not $MenuChild) {
    Show-DmdClockBanner
}

function Wait-DmdClockForMenuReturn {
    if ([Console]::IsInputRedirected) {
        return
    }

    Write-Host ''
    try {
        $null = Read-Host 'Press Enter to return to the main menu'
    }
    catch {
        Write-Warning "Could not wait for input: $($_.Exception.Message)"
    }
}

function Invoke-DmdClockStartupMenuOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    try {
        Write-Host ''
        Write-Host "=== $Operation ===" -ForegroundColor Cyan
        $result = & $Action
        if ($null -eq $result -or $result.PSTypeNames -notcontains 'DmdClock.OperationResult') {
            throw "$Operation did not report an operation result."
        }
        Write-Host ''
        switch ($result.Status) {
            'completed' {
                Write-Host "[DONE] $Operation completed successfully." -ForegroundColor Green
            }
            'dry-run' {
                Write-Host "[DRY RUN] $Operation plan completed without making changes." -ForegroundColor Yellow
            }
            'cancelled' {
                Write-Host "[CANCELLED] $Operation did not complete." -ForegroundColor Yellow
            }
            default {
                throw "$Operation reported unsupported status '$($result.Status)'."
            }
        }
        Wait-DmdClockForMenuReturn
    }
    catch {
        $originalError = $_
        Write-Host ''
        Write-Host "[ERROR] $Operation failed." -ForegroundColor Red
        Write-Host $originalError.Exception.Message -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($originalError.ScriptStackTrace)) {
            Write-Host $originalError.ScriptStackTrace -ForegroundColor DarkGray
        }
        Wait-DmdClockForMenuReturn
    }
}

if ($PSBoundParameters.ContainsKey('DiskNumber') -and
    ($DiskNumber -lt 0 -or $DiskNumber -gt 999)) {
    throw 'DiskNumber must be between 0 and 999.'
}

$provisioningModule = Join-Path $PSScriptRoot 'DmdClock.Provisioning.psm1'
$sdScript = Join-Path $PSScriptRoot 'Prepare-DmdClockSdCard.ps1'
$flashScript = Join-Path $PSScriptRoot 'Flash-DmdClockEsp32.ps1'
$resetScript = Join-Path $PSScriptRoot 'Reset-DmdClockSettings.ps1'
$installScript = Join-Path $PSScriptRoot 'RUNME-Install-DmdClockEsp32.ps1'

# --- Self-fetch any missing companion script so a single downloaded file works. ---
$scriptSource = if (-not [string]::IsNullOrWhiteSpace($CompanionScriptSource)) {
    $CompanionScriptSource.TrimEnd('/')
} else {
    "https://raw.githubusercontent.com/$Repository/master/scripts/esp32"
}
$missingScripts = @($provisioningModule, $sdScript, $flashScript, $resetScript |
    Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingScripts.Count -gt 0) {
    if ($WhatIf) {
        foreach ($missingPath in $missingScripts) {
            $missingName = [IO.Path]::GetFileName($missingPath)
            Write-Host "[WHATIF] would download missing companion script '$missingName' from $scriptSource/$missingName." -ForegroundColor Yellow
        }
        throw ('Required companion scripts are missing next to RUNME-Install-DmdClockEsp32.ps1: ' +
            ($missingScripts -join ', ') +
            '. A real run downloads them automatically; -WhatIf works only when all five files are already present.')
    }
    foreach ($missingPath in $missingScripts) {
        $missingName = [IO.Path]::GetFileName($missingPath)
        $sourcePath = "$scriptSource/$missingName"
        $tempFile = Join-Path ([IO.Path]::GetTempPath()) ('.dmdclock-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            if ($scriptSource -match '^https?://') {
                Invoke-WebRequest -Uri $sourcePath -OutFile $tempFile -UseBasicParsing
            } else {
                $mirrorPath = Join-Path $scriptSource $missingName
                if (-not (Test-Path -LiteralPath $mirrorPath -PathType Leaf)) {
                    throw "Local companion-script source does not contain '$missingName' at $mirrorPath."
                }
                Copy-Item -LiteralPath $mirrorPath -Destination $tempFile
            }
            $rawContent = [IO.File]::ReadAllText($tempFile)
            $looksLikeScript = (-not [string]::IsNullOrWhiteSpace($rawContent)) -and
                ($rawContent -notmatch '(?i)<!doctype html|<html') -and
                ($rawContent -match '(?m)^\s*(#|\[[A-Za-z]|function\b|param\s*\(|using\s+)')
            if (-not $looksLikeScript) {
                throw "Downloaded content from $sourcePath is not a valid PowerShell script."
            }
            Copy-Item -LiteralPath $tempFile -Destination $missingPath -Force
            Write-Host "[DOWNLOADED] Fetched missing companion script '$missingName' from $sourcePath." -ForegroundColor Green
        }
        catch {
            throw ("Failed to fetch missing companion script '$missingName' from $sourcePath. " +
                "$($_.Exception.Message) Download all five files together; see https://github.com/$Repository/blob/master/docs/INSTALL-ESP32.md")
        }
        finally {
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
        }
    }
}
Import-Module $provisioningModule -Force

if ($showStartupMenu) {
    do {
        Show-DmdClockStartupMenu
        $choice = Read-DmdClockMenuChoice -Prompt 'Select an option' -Minimum 1 -Maximum 6 `
            -RequiredParameter 'valid menu input'

        switch ($choice) {
            1 {
                Invoke-DmdClockStartupMenuOperation -Operation 'SD card preparation' -Action {
                    Invoke-DmdClockChildOperation -Operation 'SD card preparation' -ScriptPath $sdScript
                }
            }
            2 {
                Invoke-DmdClockStartupMenuOperation -Operation 'Firmware flash' -Action {
                    Invoke-DmdClockChildOperation -Operation 'Firmware flash' -ScriptPath $flashScript
                }
            }
            3 {
                Invoke-DmdClockStartupMenuOperation -Operation 'Device settings reset' -Action {
                    Invoke-DmdClockChildOperation -Operation 'Device settings reset' -ScriptPath $resetScript
                }
            }
            4 {
                Invoke-DmdClockStartupMenuOperation -Operation 'Download' -Action {
                    Invoke-DmdClockChildOperation -Operation 'Download' -ScriptPath $installScript `
                        -Arguments @{ DownloadOnly = $true; MenuChild = $true }
                }
            }
            5 {
                Invoke-DmdClockStartupMenuOperation -Operation 'Complete install / update' -Action {
                    Invoke-DmdClockChildOperation -Operation 'Complete install / update' `
                        -ScriptPath $installScript -Arguments @{ Update = $true; MenuChild = $true }
                }
            }
            6 {
                Write-Host 'Goodbye.' -ForegroundColor DarkGray
                Set-DmdClockOperationResult -Status completed -Operation 'Exit'
                return
            }
        }
    } while ($true)
}

$localData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
$destination = if (-not [string]::IsNullOrWhiteSpace($Destination)) {
    [IO.Path]::GetFullPath($Destination)
} else {
    Join-Path $localData 'DmdClock\DmdClockFiles'
}

if ($CheckRequirements) {
    $null = Invoke-DmdClockChildOperation -Operation 'microSD requirements check' `
        -ScriptPath $sdScript -Arguments @{ CheckRequirements = $true; Repository = $Repository }
    $null = Invoke-DmdClockChildOperation -Operation 'firmware requirements check' `
        -ScriptPath $flashScript -Arguments @{ CheckRequirements = $true; Repository = $Repository }
    Set-DmdClockOperationResult -Status completed -Operation 'Install requirements check'
    return
}

# --- Phase 1: stage every artifact once (skipped when already staged). ---
$libraryArtifactId = if ($Library -eq 'Original') {
    'sd.library.dotclk-original'
} else {
    'sd.library.drwize-complete'
}
$sdReady = $false
if (Test-Path -LiteralPath $destination -PathType Container) {
    try {
        $null = Test-DmdClockStagingManifest -Source $destination `
            -RequiredArtifactIds @(
                'sd.catalog',
                'sd.scene-metadata',
                'sd.template.manifest',
                'sd.template.readme',
                $libraryArtifactId
            )
        $sdReady = $true
    } catch {
        $sdReady = $false
    }
}
if (-not $sdReady -or $Update) {
    if ($WhatIf) {
        $sdReason = if ($Update) { 'an update to the latest microSD payload is requested' } else { 'the microSD payload is not staged' }
        Write-Host "[WHATIF] $sdReason at $destination; dry-run never downloads, so staging is skipped." -ForegroundColor Yellow
    } else {
        Write-Host "Staging microSD payload into $destination ..." -ForegroundColor Cyan
        $sdStageArgs = @{
            DownloadOnly = $true
            Destination = $destination
            Library = $Library
            Repository = $Repository
        }
        $stageResult = Invoke-DmdClockChildOperation -Operation 'microSD payload staging' `
            -ScriptPath $sdScript -Arguments $sdStageArgs
        if ($stageResult.Status -eq 'cancelled') {
            Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
                -Detail 'microSD payload staging was cancelled.'
            return
        }
    }
}

$stagedManifestPath = Join-Path $destination 'staging-manifest.json'
$fwReady = $false
if (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf) {
    try {
        $stagedManifest = Get-Content -LiteralPath $stagedManifestPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
        $artifactIds = @($stagedManifest.artifacts |
            ForEach-Object { [string]$_.artifactId })
        $requiredFirmwareIds = [Collections.Generic.List[string]]::new()
        if ($Board) {
            $requiredFirmwareIds.Add("firmware.$Board.manifest")
            $requiredFirmwareIds.Add("firmware.$Board.package")
        } else {
            foreach ($candidateBoard in @('Waveshare7', 'Waveshare349B')) {
                $requiredFirmwareIds.Add("firmware.$candidateBoard.manifest")
                $requiredFirmwareIds.Add("firmware.$candidateBoard.package")
            }
        }
        $missing = @($requiredFirmwareIds |
            Where-Object { $artifactIds -notcontains $_ })
        $fwReady = (@($artifactIds |
            Where-Object { $_ -eq 'tool.esptool.windows-x64' }).Count -eq 1) -and
            ($missing.Count -eq 0)
    } catch {
        $fwReady = $false
    }
}
if (-not $fwReady -or $Update) {
    if ($WhatIf) {
        $fwReason = if ($Update) { 'an update to the latest firmware is requested' } else { 'the firmware/tool payload is not staged' }
        Write-Host "[WHATIF] $fwReason at $destination; dry-run never downloads, so staging is skipped." -ForegroundColor Yellow
    } else {
        Write-Host "Staging firmware and flash tool into $destination ..." -ForegroundColor Cyan
        $flashStageArgs = @{
            DownloadOnly = $true
            Destination = $destination
            Repository = $Repository
        }
        if ($Board) { $flashStageArgs['Board'] = $Board }
        if ($ReleaseTag) { $flashStageArgs['ReleaseTag'] = $ReleaseTag }
        $stageResult = Invoke-DmdClockChildOperation -Operation 'firmware/tool staging' `
            -ScriptPath $flashScript -Arguments $flashStageArgs
        if ($stageResult.Status -eq 'cancelled') {
            Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
                -Detail 'Firmware/tool staging was cancelled.'
            return
        }
    }
}

if ($DownloadOnly) {
    if ($WhatIf) {
        Write-Host '[DRY RUN] Download/staging plan completed; no files were downloaded or staged and no flash occurred.' -ForegroundColor Yellow
        Set-DmdClockOperationResult -Status 'dry-run' -Operation 'Download only'
        return
    }
    Write-Host '[DONE] Staging complete. The verified payload is ready for offline card preparation and flashing.' -ForegroundColor Green
    Write-Host "Staging: $destination"
    Set-DmdClockOperationResult -Status completed -Operation 'Download only'
    return
}

# --- Phase 2: prepare the microSD card (reports when already up to date). ---
$cardPhaseSkipped = $false
$prepareArgs = @{
    StagingSource = $destination
    Library = $Library
    Repository = $Repository
}
if ($PSBoundParameters.ContainsKey('DiskNumber')) {
    $prepareArgs['DiskNumber'] = $DiskNumber
}
if ($Wizard) { $prepareArgs['Wizard'] = $true }
if ($SkipCard) {
    Write-Host '[SKIP] microSD card preparation skipped (-SkipCard).' -ForegroundColor Yellow
    $cardPhaseSkipped = $true
} elseif ($WhatIf) {
    if (-not $sdReady) {
        Write-Host "[WHATIF] Skipping microSD card plan: no staged microSD payload at $destination." -ForegroundColor Yellow
    } else {
        $prepareArgs['DryRun'] = $true
        $cardResult = Invoke-DmdClockChildOperation -Operation 'microSD card preparation' `
            -ScriptPath $sdScript -Arguments $prepareArgs
        if ($cardResult.Status -eq 'cancelled') {
            Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
                -Detail 'microSD card preparation was cancelled.'
            return
        }
    }
} elseif ($PSBoundParameters.ContainsKey('DiskNumber') -or $Wizard) {
    $cardResult = Invoke-DmdClockChildOperation -Operation 'microSD card preparation' `
        -ScriptPath $sdScript -Arguments $prepareArgs
    if ($cardResult.Status -eq 'cancelled') {
        Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
            -Detail 'microSD card preparation was cancelled.'
        return
    }
} elseif (-not [Console]::IsInputRedirected) {
    # Interactive run without a chosen disk: ask whether a card needs preparing.
    $needPrepare = $null
    while ($null -eq $needPrepare) {
        $answer = Read-Host 'Do you need to prepare a microSD card? (Y)es / (N)o'
        if ($null -eq $answer) { $answer = '' }
        $needPrepare = switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { $true }
            '^(n|no|)$' { $false }
            default { $null }
        }
    }
    if ($needPrepare) {
        $cardResult = Invoke-DmdClockChildOperation -Operation 'microSD card preparation' `
            -ScriptPath $sdScript -Arguments $prepareArgs
        if ($cardResult.Status -eq 'cancelled') {
            Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
                -Detail 'microSD card preparation was cancelled.'
            return
        }
    } else {
        Write-Host '[SKIP] microSD card preparation skipped (you answered that no card needs preparing).' -ForegroundColor Yellow
        $cardPhaseSkipped = $true
    }
} else {
    Write-Host '[SKIP] microSD card preparation skipped: no -DiskNumber was given and input is not interactive. Pass -DiskNumber N to prepare the card.' -ForegroundColor Yellow
    $cardPhaseSkipped = $true
}

# --- Phase 3: flash the board from the staged payload. ---
$flashArgs = @{
    Source = $destination
    Repository = $Repository
}
foreach ($forwarded in @(
        'Board', 'FlashMode', 'Port', 'BoardRevision', 'ReleaseTag', 'ConfirmHardware')) {
    if ($PSBoundParameters.ContainsKey($forwarded)) {
        $flashArgs[$forwarded] = $PSBoundParameters[$forwarded]
    }
}
if ($FactoryRecovery) { $flashArgs['FactoryRecovery'] = $true }
if ($Wizard) { $flashArgs['Wizard'] = $true }
if ($Force) { $flashArgs['Force'] = $true }
if ($WhatIf) {
    if (-not $fwReady) {
        Write-Host "[WHATIF] Skipping flash plan: no staged firmware/tool payload at $destination." -ForegroundColor Yellow
    } else {
        $flashArgs['WhatIf'] = $true
        $flashResult = Invoke-DmdClockChildOperation -Operation 'firmware flash plan' `
            -ScriptPath $flashScript -Arguments $flashArgs
    }
} else {
    $flashResult = Invoke-DmdClockChildOperation -Operation 'firmware flash' `
        -ScriptPath $flashScript -Arguments $flashArgs
    if ($flashResult.Status -eq 'cancelled') {
        Set-DmdClockOperationResult -Status cancelled -Operation 'Install' `
            -Detail 'Firmware flashing was cancelled.'
        return
    }
}

if ($WhatIf) {
    Write-Host '[DRY RUN] Install plan completed; no flash occurred.' -ForegroundColor Yellow
    Set-DmdClockOperationResult -Status 'dry-run' -Operation 'Install'
    return
}

if ($cardPhaseSkipped) {
    Write-Host '[DONE] Flash complete. microSD card preparation was skipped; run without -SkipCard when the card is ready.' -ForegroundColor Green
} else {
    Write-Host '[DONE] Install complete: microSD card and firmware are up to date.' -ForegroundColor Green
}
Set-DmdClockOperationResult -Status completed -Operation 'Install'
