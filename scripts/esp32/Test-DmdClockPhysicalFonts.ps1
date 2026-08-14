[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [uri] $DeviceUrl,

    [Parameter(Mandatory)]
    [ValidateSet('Waveshare349B', 'Waveshare7')]
    [string] $Board,

    [ValidateSet('ALL-FONTS-OK')]
    [string] $VisualConfirmation,

    [ValidateRange(15, 180)]
    [int] $RestartTimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$reportRoot = Join-Path $repoRoot 'output\esp32\reports\physical-fonts'
$stateUri = [uri]::new($DeviceUrl, '/api/state')
$settingsUri = [uri]::new($DeviceUrl, '/api/settings')
$actionUri = [uri]::new($DeviceUrl, '/api/action')

function Get-State {
    Invoke-RestMethod -Uri $stateUri -TimeoutSec 5
}

function Set-Settings {
    param([Parameter(Mandatory)] [hashtable] $Values)

    Invoke-RestMethod -Uri $settingsUri -Method Post `
        -ContentType 'application/json' `
        -Body ($Values | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
    Start-Sleep -Milliseconds 500
    Get-State
}

function Invoke-Reboot {
    try {
        Invoke-RestMethod -Uri $actionUri -Method Post `
            -ContentType 'application/json' -Body '{"action":"reboot"}' `
            -TimeoutSec 10 | Out-Null
    }
    catch {
        # The board may reset before the HTTP response is fully returned.
    }
}

$initial = Get-State
$expectedWidth = if ($Board -eq 'Waveshare349B') { 640 } else { 800 }
$fontCases = @(
    [ordered]@{ Id = 'builtin-5x7'; Use24Hour = $true; ShowSeconds = $false }
    [ordered]@{ Id = 'altern8'; Use24Hour = $false; ShowSeconds = $false }
    [ordered]@{ Id = 'fishy'; Use24Hour = $true; ShowSeconds = $true }
    [ordered]@{ Id = 'trek'; Use24Hour = $false; ShowSeconds = $true }
    [ordered]@{ Id = 'twilight'; Use24Hour = $true; ShowSeconds = $false }
)
$results = [Collections.Generic.List[object]]::new()
$restartResult = $null
$testError = $null

try {
    foreach ($case in $fontCases) {
        $before = Get-State
        $state = Set-Settings @{
            playScene = $false
            automaticCycle = $false
            clockFont = $case.Id
            use24Hour = $case.Use24Hour
            showSeconds = $case.ShowSeconds
        }
        Start-Sleep -Milliseconds 600
        $after = Get-State
        if ([string]$state.clockFont -ne $case.Id -or
            [bool]$state.use24Hour -ne $case.Use24Hour -or
            [bool]$state.showSeconds -ne $case.ShowSeconds) {
            throw "Settings did not round-trip for font '$($case.Id)'."
        }
        if ([int64]$after.displayFramesRendered -le [int64]$before.displayFramesRendered) {
            throw "The physical display did not advance while rendering '$($case.Id)'."
        }
        if (-not [bool]$after.settingsSaveOk -or
            [string]$after.lastNvsSaveStatus -ne 'ESP_OK' -or
            [string]$after.lastSdSaveStatus -ne 'ESP_OK') {
            throw "Settings persistence reported an error for font '$($case.Id)'."
        }
        $results.Add([ordered]@{
            font = $case.Id
            fontName = [string]$after.clockFontName
            use24Hour = [bool]$after.use24Hour
            showSeconds = [bool]$after.showSeconds
            displayFrameAdvanced = $true
            freeHeapBytes = [int64]$after.freeHeapBytes
            minimumFreeHeapBytes = [int64]$after.minimumFreeHeapBytes
            freePsramBytes = [int64]$after.freePsramBytes
        })
    }

    try {
        Invoke-RestMethod -Uri $settingsUri -Method Post `
            -ContentType 'application/json' -Body '{"clockFont":"unknown-font"}' `
            -TimeoutSec 10 | Out-Null
        throw 'The physical settings API accepted an unknown font.'
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 400) { throw }
    }

    $sceneState = Set-Settings @{
        clockFont = 'twilight'
        playScene = $true
        automaticCycle = $false
        sceneIndex = [int]$initial.sceneIndex
    }
    if (-not [bool]$sceneState.playScene -or [int]$sceneState.sceneCount -le 0) {
        throw 'Scene playback did not remain healthy with the selected DotClk font.'
    }

    $persisted = Set-Settings @{
        clockFont = 'twilight'
        use24Hour = $false
        showSeconds = $true
        playScene = $false
        automaticCycle = $false
    }
    $bootCountBefore = [int]$persisted.bootCount
    Invoke-Reboot

    $deadline = [DateTime]::UtcNow.AddSeconds($RestartTimeoutSeconds)
    $afterRestart = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 750
        try {
            $candidate = Get-State
            if ([int]$candidate.bootCount -gt $bootCountBefore) {
                $afterRestart = $candidate
                break
            }
        }
        catch {
            # Expected while Wi-Fi and the web server restart.
        }
    }
    if ($null -eq $afterRestart) {
        throw "The board did not return after reboot within $RestartTimeoutSeconds seconds."
    }
    if ([string]$afterRestart.clockFont -ne 'twilight' -or
        [bool]$afterRestart.use24Hour -ne $false -or
        [bool]$afterRestart.showSeconds -ne $true) {
        throw 'Clock font or time-format settings did not persist across reboot.'
    }
    if (-not [bool]$afterRestart.settingsSaveOk -or
        [string]$afterRestart.lastNvsSaveStatus -ne 'ESP_OK' -or
        [string]$afterRestart.lastSdSaveStatus -ne 'ESP_OK') {
        throw 'The rebooted board reported a settings persistence error.'
    }
    if ([int64]$afterRestart.minimumFreeHeapBytes -lt 524288 -or
        [int64]$afterRestart.freePsramBytes -lt 524288) {
        throw 'The rebooted board fell below the physical font memory floor.'
    }
    if (-not [bool]$afterRestart.touchAvailable -or
        [int]$afterRestart.touchReadErrorCount -gt [int]$initial.touchReadErrorCount) {
        throw 'Touch availability regressed during physical font acceptance.'
    }
    $restartResult = [ordered]@{
        bootCountBefore = $bootCountBefore
        bootCountAfter = [int]$afterRestart.bootCount
        resetReason = [string]$afterRestart.resetReason
        clockFont = [string]$afterRestart.clockFont
        use24Hour = [bool]$afterRestart.use24Hour
        showSeconds = [bool]$afterRestart.showSeconds
        uptimeSeconds = [int]$afterRestart.uptimeSeconds
        settingsSaveOk = [bool]$afterRestart.settingsSaveOk
    }
}
catch {
    $testError = $_
}
finally {
    try {
        Set-Settings @{
            clockFont = [string]$initial.clockFont
            use24Hour = [bool]$initial.use24Hour
            showSeconds = [bool]$initial.showSeconds
            playScene = [bool]$initial.playScene
            automaticCycle = [bool]$initial.automaticCycle
            sceneIndex = [int]$initial.sceneIndex
        } | Out-Null
    }
    catch {
        if ($null -eq $testError) { $testError = $_ }
    }
}

New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$reportPath = Join-Path $reportRoot "$($Board.ToLowerInvariant())-$timestamp.json"
$report = [ordered]@{
    schemaVersion = 1
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    board = $Board
    expectedDisplayWidth = $expectedWidth
    deviceUrl = $DeviceUrl.AbsoluteUri
    buildNumber = [string]$initial.buildNumber
    sceneCount = [int]$initial.sceneCount
    fonts = $results
    allFiveFontsExercised = $results.Count -eq $fontCases.Count
    visualConfirmation = $VisualConfirmation
    visualConfirmationProvided = $VisualConfirmation -eq 'ALL-FONTS-OK'
    scenePlaybackWithSelectedFont = $null -eq $testError
    restartPersistence = $restartResult
    touchAvailable = [bool]$initial.touchAvailable
    touchReadErrorCount = [int]$initial.touchReadErrorCount
    passed = $null -eq $testError
    error = if ($testError) { $testError.Exception.Message } else { $null }
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath

if ($testError) {
    throw "Physical font acceptance failed: $($testError.Exception.Message) Evidence: $reportPath"
}

Write-Host "[PASS] $Board physical font acceptance completed." -ForegroundColor Green
Write-Host "       Fonts: $($results.Count); reboot: $($restartResult.bootCountBefore) -> $($restartResult.bootCountAfter)"
Write-Host "       Evidence: $reportPath"
