[CmdletBinding()]
param(
    [string]$InstallerPath,

    [string]$StandaloneDirectory,

    [switch]$SkipRepeatInstall
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'output'
if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $installerDirectory = Join-Path $outputRoot 'current\win-x64-installer'
    $installerInfoPath = Join-Path $installerDirectory 'installer-build-info.json'
    if (-not (Test-Path -LiteralPath $installerInfoPath -PathType Leaf)) {
        throw "Installer metadata not found: $installerInfoPath"
    }
    $installerInfo = Get-Content -LiteralPath $installerInfoPath -Raw | ConvertFrom-Json
    $InstallerPath = Join-Path $installerDirectory $installerInfo.installer
}
if ([string]::IsNullOrWhiteSpace($StandaloneDirectory)) {
    $StandaloneDirectory = Join-Path $outputRoot 'current\win-x64-standalone'
}

$installer = [IO.Path]::GetFullPath($InstallerPath)
$standalone = [IO.Path]::GetFullPath($StandaloneDirectory)
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Installer not found: $installer"
}
if (-not (Test-Path -LiteralPath $standalone -PathType Container)) {
    throw "Standalone input directory not found: $standalone"
}

$registeredUninstallerKey =
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{D01CC10C-1283-4C72-AD7C-BEA19B81B762}_is1'
if (Test-Path -LiteralPath $registeredUninstallerKey) {
    throw @"
Refusing installer validation because DMDClock is already registered for this user.
Uninstall the existing setup installation or validate in a disposable Windows user/VM.
"@
}

$validationRoot = Join-Path $outputRoot (
    'installer-validation\automated-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$installDirectory = Join-Path $validationRoot 'app'
$resultPath = Join-Path $validationRoot 'validation-result.json'
New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null

$desktopRegistryPath = 'HKCU:\Control Panel\Desktop'
$installerStatePath = 'HKCU:\Software\Alien Tech\DMDClock\Installer'
$screenSaverProperty = 'SCRNSAVE.EXE'
$activeProperty = 'ScreenSaveActive'
$desktopState = Get-ItemProperty -Path $desktopRegistryPath -ErrorAction Stop
$previousScreenSaverExists = $null -ne $desktopState.$screenSaverProperty
$previousScreenSaver = $desktopState.$screenSaverProperty
$previousActiveExists = $null -ne $desktopState.$activeProperty
$previousActive = $desktopState.$activeProperty
$settingsPath = Join-Path $env:LOCALAPPDATA 'DmdClock\settings.json'
$settingsHashBefore = if (Test-Path -LiteralPath $settingsPath) {
    (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
} else {
    $null
}
$installedScreenSaver = Join-Path $installDirectory 'DMDClock.scr'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$uninstallCompleted = $false

function Invoke-Setup([string]$Path, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "'$Path' failed with exit code $($process.ExitCode)."
    }
    return $process.ExitCode
}

function Restore-OriginalScreenSaverIfNeeded {
    $current = Get-ItemProperty -Path $desktopRegistryPath -ErrorAction SilentlyContinue
    if ($null -eq $current -or
        -not [string]::Equals(
            $current.$screenSaverProperty,
            $installedScreenSaver,
            [StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    if ($previousScreenSaverExists) {
        Set-ItemProperty -Path $desktopRegistryPath -Name $screenSaverProperty `
            -Value $previousScreenSaver
    } else {
        Remove-ItemProperty -Path $desktopRegistryPath -Name $screenSaverProperty `
            -ErrorAction SilentlyContinue
    }

    if ($previousActiveExists) {
        Set-ItemProperty -Path $desktopRegistryPath -Name $activeProperty `
            -Value $previousActive
    } else {
        Remove-ItemProperty -Path $desktopRegistryPath -Name $activeProperty `
            -ErrorAction SilentlyContinue
    }
}

try {
    $installArguments = @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        "/DIR=$installDirectory",
        '/TASKS=activatescreensaver'
    )
    $installExitCode = Invoke-Setup $installer $installArguments

    $requiredFiles = @(
        'DmdClock.App.exe',
        'DMDClock.scr',
        'i18n\en.json',
        'fonts\Inter\InterVariable.ttf',
        'scenes\scene-metadata.json',
        'docs\USER-SETUP.md',
        'docs\SETTINGS.md',
        'docs\INSTALLER.md',
        'docs\screenshots\setup\settings-menu.png',
        'unins000.exe'
    )
    $missingFiles = @($requiredFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $installDirectory $_) -PathType Leaf)
    })

    $sourceExeHash = (Get-FileHash -LiteralPath (
        Join-Path $standalone 'DmdClock.App.exe') -Algorithm SHA256).Hash
    $installedExeHash = (Get-FileHash -LiteralPath (
        Join-Path $installDirectory 'DmdClock.App.exe') -Algorithm SHA256).Hash
    $sourceScrHash = (Get-FileHash -LiteralPath (
        Join-Path $standalone 'DMDClock.scr') -Algorithm SHA256).Hash
    $installedScrHash = (Get-FileHash -LiteralPath (
        Join-Path $installDirectory 'DMDClock.scr') -Algorithm SHA256).Hash

    $currentScreenSaver = (
        Get-ItemProperty -Path $desktopRegistryPath -Name $screenSaverProperty -ErrorAction Stop
    ).$screenSaverProperty
    $screenSaverActivated = [string]::Equals(
        $currentScreenSaver, $installedScreenSaver, [StringComparison]::OrdinalIgnoreCase)
    $savedBeforeRepeat = (
        Get-ItemProperty -LiteralPath $installerStatePath -ErrorAction Stop
    ).PreviousScreenSaver

    $repeatExitCode = $null
    $repeatPreservedRestorePoint = $true
    if (-not $SkipRepeatInstall) {
        $repeatExitCode = Invoke-Setup $installer $installArguments
        $savedAfterRepeat = (
            Get-ItemProperty -LiteralPath $installerStatePath -ErrorAction Stop
        ).PreviousScreenSaver
        $repeatPreservedRestorePoint =
            $savedBeforeRepeat -eq $previousScreenSaver -and
            $savedAfterRepeat -eq $previousScreenSaver
    }

    $uninstallExitCode = Invoke-Setup $uninstaller @(
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART'
    )
    $uninstallCompleted = $true

    $desktopAfter = Get-ItemProperty -Path $desktopRegistryPath -ErrorAction Stop
    $settingsHashAfter = if (Test-Path -LiteralPath $settingsPath) {
        (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    } else {
        $null
    }

    $result = [ordered]@{
        schemaVersion = 1
        testedAt = (Get-Date).ToString('o')
        installer = $installer
        standaloneDirectory = $standalone
        validationRoot = $validationRoot
        installExitCode = $installExitCode
        repeatInstallExitCode = $repeatExitCode
        uninstallExitCode = $uninstallExitCode
        allRequiredFilesPresent = $missingFiles.Count -eq 0
        missingFiles = $missingFiles
        exeHashMatches = $sourceExeHash -eq $installedExeHash
        scrHashMatches = $sourceScrHash -eq $installedScrHash
        screenSaverActivated = $screenSaverActivated
        repeatInstallPreservedRestorePoint = $repeatPreservedRestorePoint
        previousScreenSaverRestored = $desktopAfter.$screenSaverProperty -eq $previousScreenSaver
        previousActiveStateRestored = $desktopAfter.$activeProperty -eq $previousActive
        installerStateRemoved = -not (Test-Path -LiteralPath $installerStatePath)
        programFilesRemoved = -not (
            Test-Path -LiteralPath (Join-Path $installDirectory 'DmdClock.App.exe'))
        appDataSettingsRetained = $settingsHashAfter -eq $settingsHashBefore
    }
    $result | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $resultPath -Encoding utf8

    $failedChecks = @($result.GetEnumerator() | Where-Object {
        $_.Key -in @(
            'allRequiredFilesPresent',
            'exeHashMatches',
            'scrHashMatches',
            'screenSaverActivated',
            'repeatInstallPreservedRestorePoint',
            'previousScreenSaverRestored',
            'previousActiveStateRestored',
            'installerStateRemoved',
            'programFilesRemoved',
            'appDataSettingsRetained'
        ) -and $_.Value -ne $true
    })
    if ($failedChecks.Count -gt 0) {
        throw "Installer validation failed: $($failedChecks.Key -join ', ')."
    }

    [pscustomobject]$result
    Write-Host "Installer validation passed. Report: $resultPath"
}
finally {
    if (-not $uninstallCompleted -and (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
        try {
            Invoke-Setup $uninstaller @(
                '/VERYSILENT',
                '/SUPPRESSMSGBOXES',
                '/NORESTART'
            ) | Out-Null
        } catch {
            Write-Warning "Validation cleanup uninstall failed: $($_.Exception.Message)"
        }
    }
    Restore-OriginalScreenSaverIfNeeded
}
