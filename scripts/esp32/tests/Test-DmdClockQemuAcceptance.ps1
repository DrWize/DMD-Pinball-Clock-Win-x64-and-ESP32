[CmdletBinding()]
param(
    [ValidateSet('Landscape349', 'Waveshare7')]
    [string] $Model = 'Landscape349',

    [uri] $QemuUrl = 'http://127.0.0.1:8081',

    [ValidateRange(1, 65535)]
    [int] $MonitorPort = 4445,

    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$captureScript = Join-Path $PSScriptRoot 'Test-DmdClockQemuDisplay.ps1'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "output\esp32\reports\qemu-acceptance\$($Model.ToLowerInvariant())"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$stateUri = [uri]::new($QemuUrl, '/api/state')
$fontsUri = [uri]::new($QemuUrl, '/api/fonts')
$settingsUri = [uri]::new($QemuUrl, '/api/settings')
$actionUri = [uri]::new($QemuUrl, '/api/action')

function Get-State {
    Invoke-RestMethod -Uri $stateUri -TimeoutSec 5
}

function Set-Settings {
    param([Parameter(Mandatory)] [hashtable] $Values)
    Invoke-RestMethod -Uri $settingsUri -Method Post -ContentType 'application/json' `
        -Body ($Values | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
    Start-Sleep -Milliseconds 350
    Get-State
}

function Invoke-Action {
    param([Parameter(Mandatory)] [string] $Name)
    Invoke-RestMethod -Uri $actionUri -Method Post -ContentType 'application/json' `
        -Body (@{ action = $Name } | ConvertTo-Json -Compress) -TimeoutSec 10 | Out-Null
    Start-Sleep -Milliseconds 250
}

function Capture-Case {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [switch] $AllowBlank
    )
    $directory = Join-Path $OutputDirectory $Name
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    & $captureScript -Model $Model -QemuUrl $QemuUrl -MonitorPort $MonitorPort `
        -OutputDirectory $directory -TimeoutSeconds 30 -AllowBlank:$AllowBlank | Out-Null
    $evidencePath = Join-Path $directory "$($Model.ToLowerInvariant()).json"
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        Name = $Name
        Sha256 = [string]$evidence.screenshot.sha256
        NonBlackPixels = [int]$evidence.screenshot.nonBlackPixels
        Width = [int]$evidence.screenshot.width
        Height = [int]$evidence.screenshot.height
        Evidence = $evidencePath
    }
}

$initial = Get-State
$captures = [Collections.Generic.List[object]]::new()
try {
    $fontIds = @('builtin-5x7', 'altern8', 'fishy', 'trek', 'twilight')
    $fontCatalog = Invoke-RestMethod -Uri $fontsUri -TimeoutSec 5
    $catalogIds = @($fontCatalog.fonts | ForEach-Object { [string]$_.id })
    if ([string]::Join(',', $catalogIds) -ne [string]::Join(',', $fontIds)) {
        throw "The usable font catalog was unexpected: $([string]::Join(', ', $catalogIds))"
    }
    if (@($fontCatalog.fonts | Where-Object { $_.source -eq 'sd' -and -not $_.filename }).Count -ne 0) {
        throw 'An SD font catalog entry did not include its filename.'
    }

    $clock = Set-Settings @{
        displayOn = $true
        playScene = $false
        automaticCycle = $false
        brightness = 100
        colorPreset = 0
    }
    if ($clock.playScene -or [int]$clock.colorPreset -ne 0) {
        throw 'Clock/Basic settings did not apply.'
    }
    $captures.Add((Capture-Case 'clock-basic'))

    foreach ($fontId in $fontIds) {
        $fontState = Set-Settings @{
            playScene = $false
            automaticCycle = $false
            use24Hour = $true
            showSeconds = $false
            clockFont = $fontId
        }
        if ([string]$fontState.clockFont -ne $fontId -or
            [string]$fontState.clockFontActive -ne $fontId -or
            [bool]$fontState.clockFontFallback -ne $false -or
            $null -ne $fontState.clockFontError) {
            throw "Clock font '$fontId' did not activate cleanly through the state API."
        }
        $captures.Add((Capture-Case "font-$fontId"))
    }
    try {
        Set-Settings @{ clockFont = 'not-in-the-boot-catalog' } | Out-Null
        throw 'An unknown font ID was accepted.'
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 400) { throw }
    }
    $fontHashes = @(
        $captures | Where-Object Name -like 'font-*' |
            Select-Object -ExpandProperty Sha256 -Unique
    )
    if ($fontHashes.Count -ne $fontIds.Count) {
        throw 'One or more clock fonts produced an identical framebuffer hash.'
    }
    Set-Settings @{
        playScene = $false
        clockFont = 'altern8'
        glowStrength = 0
        hotCoreEnabled = $false
    } | Out-Null
    $glowOffCapture = Capture-Case 'glow-off'
    $captures.Add($glowOffCapture)
    Set-Settings @{ glowStrength = 70 } | Out-Null
    $glowOnCapture = Capture-Case 'glow-on'
    $captures.Add($glowOnCapture)
    if ($glowOnCapture.Sha256 -eq $glowOffCapture.Sha256) {
        throw 'DotClk font glow did not change the physical framebuffer.'
    }
    Set-Settings @{ hotCoreEnabled = $true; hotCoreStyle = 0 } | Out-Null
    $hotCoreCapture = Capture-Case 'hot-core'
    $captures.Add($hotCoreCapture)
    if ($hotCoreCapture.Sha256 -eq $glowOnCapture.Sha256) {
        throw 'DotClk hot-core rendering did not change the physical framebuffer.'
    }
    try {
        Invoke-RestMethod -Uri $settingsUri -Method Post `
            -ContentType 'application/json' `
            -Body '{"clockFont":"unknown-font"}' -TimeoutSec 10 | Out-Null
        throw 'The settings API accepted an unknown clock font.'
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 400) { throw }
    }
    $static = Set-Settings @{ playScene = $true; sceneIndex = 1; automaticCycle = $false }
    if ([int]$static.sceneFrames -ne 1) {
        throw "Expected scene index 1 to be static; reported $($static.sceneFrames) frames."
    }
    $captures.Add((Capture-Case 'scene-static'))

    $animated = Set-Settings @{
        playScene = $true
        sceneIndex = 0
        automaticCycle = $false
        animationsPerCycle = 5
    }
    if ([int]$animated.sceneFrames -le 1) {
        throw "Expected scene index 0 to be animated; reported $($animated.sceneFrames) frames."
    }
    $frameValues = [Collections.Generic.HashSet[int]]::new()
    $null = $frameValues.Add([int]$animated.sceneFrame)
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 200
        $null = $frameValues.Add([int](Get-State).sceneFrame)
        if ($frameValues.Count -gt 1) { break }
    }
    $advanced = $frameValues.Count -gt 1
    if (-not $advanced) { throw 'Animated scene frame did not advance.' }
    $captures.Add((Capture-Case 'scene-animated'))

    $themeCases = @(
        @{ Name = 'theme-basic'; Preset = 0; Family = 'Basic' }
        @{ Name = 'theme-gradient'; Preset = 4; Family = 'Gradient' }
        @{ Name = 'theme-raster'; Preset = 25; Family = 'Raster' }
        @{ Name = 'theme-plasma'; Preset = 2; Family = 'Plasma' }
    )
    foreach ($case in $themeCases) {
        $state = Set-Settings @{ playScene = $false; colorPreset = $case.Preset; brightness = 100 }
        if ([string]$state.colorFamily -ne $case.Family) {
            throw "$($case.Name) reported color family '$($state.colorFamily)'."
        }
        $captures.Add((Capture-Case $case.Name))
    }

    $low = Set-Settings @{ playScene = $false; colorPreset = 0; brightness = 20 }
    if ([int]$low.brightness -ne 20) { throw 'Low brightness did not apply.' }
    $captures.Add((Capture-Case 'brightness-20'))
    $high = Set-Settings @{ brightness = 100 }
    if ([int]$high.brightness -ne 100) { throw 'High brightness did not apply.' }
    $captures.Add((Capture-Case 'brightness-100'))

    Invoke-Action 'setupQr'
    $qrCapture = Capture-Case 'setup-qr'
    $captures.Add($qrCapture)
    Invoke-Action 'showClock'
    Invoke-Action 'touchTest'
    $touch = Get-State
    if (-not [bool]$touch.touchTestRunning) { throw 'Touch diagnostic did not start.' }
    $touchCapture = Capture-Case 'touch-diagnostic'
    $captures.Add($touchCapture)
    if ($touchCapture.Sha256 -eq $qrCapture.Sha256) {
        throw 'Setup QR and touch diagnostic produced identical framebuffer hashes.'
    }
    Invoke-Action 'showClock'

    $scheduleRows = @('000000000000000000000000') * 7
    $activeRow = $scheduleRows[[int]$high.deviceWeekday].ToCharArray()
    $activeRow[[int]$high.deviceHour] = '1'
    $scheduleRows[[int]$high.deviceWeekday] = -join $activeRow
    $scheduled = Set-Settings @{
        displayOn = $true
        screenScheduleEnabled = $true
        screenOffSchedule = $scheduleRows
    }
    if (-not [bool]$scheduled.screenScheduledOff) {
        throw 'The current-hour screen-off schedule did not activate.'
    }
    if ([int]$scheduled.scheduleOverrideSecondsRemaining -ne 0) {
        throw 'A touch wake override would keep the display on during the schedule blackout case.'
    }
    $scheduleBlackout = Capture-Case 'screen-off-schedule' -AllowBlank
    $captures.Add($scheduleBlackout)
    if ([int]$scheduleBlackout.NonBlackPixels -ne 0) {
        throw 'The framebuffer was not fully black while the weekly schedule was in an off hour.'
    }
    Set-Settings @{
        screenScheduleEnabled = $false
        screenOffSchedule = @($initial.screenOffSchedule)
    } | Out-Null

    $switchedOff = Set-Settings @{ displayOn = $false }
    if ([bool]$switchedOff.displayOn) { throw 'The screen switch did not turn the display off.' }
    $switchBlackout = Capture-Case 'screen-off-switch' -AllowBlank
    $captures.Add($switchBlackout)
    if ([int]$switchBlackout.NonBlackPixels -ne 0) {
        throw 'The framebuffer was not fully black while the screen switch was off.'
    }
    Set-Settings @{ displayOn = $true } | Out-Null

    $behavior = Set-Settings @{
        automaticCycle = $true
        randomPlayback = $true
        screenScheduleEnabled = $false
        clockDisplaySeconds = 5
        animationGapSeconds = 0
        animationsPerCycle = 1
        playScene = $false
    }
    Invoke-Action 'showClock'
    $automaticTransition = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        $behavior = Get-State
        if ([bool]$behavior.playScene) {
            $automaticTransition = $true
            break
        }
    }
    if (-not [bool]$behavior.automaticCycle -or
        -not [bool]$behavior.randomPlayback -or
        -not $automaticTransition) {
        throw 'Automatic random scene playback did not transition from clock to scene.'
    }

    $uniqueThemeHashes = @(
        $captures | Where-Object Name -like 'theme-*' | Select-Object -ExpandProperty Sha256 -Unique
    )
    if ($uniqueThemeHashes.Count -ne $themeCases.Count) {
        throw 'One or more theme captures produced an identical framebuffer hash.'
    }
    $brightnessHashes = @(
        $captures | Where-Object Name -like 'brightness-*' | Select-Object -ExpandProperty Sha256 -Unique
    )
    if ($brightnessHashes.Count -ne 2) {
        throw 'Low and high brightness produced identical framebuffer hashes.'
    }

    $report = [ordered]@{
        schemaVersion = 1
        capturedAtUtc = [DateTime]::UtcNow.ToString('o')
        model = $Model
        qemuUrl = $QemuUrl.AbsoluteUri
        monitorPort = $MonitorPort
        sceneCount = [int]$behavior.sceneCount
        staticSceneIndex = 1
        animatedSceneIndex = 0
        animatedFrameAdvanced = $advanced
        automaticRandomTransition = $automaticTransition
        currentHourScheduleActivated = [bool]$scheduled.screenScheduledOff
        scheduleBlackoutFramebufferBlack = [int]$scheduleBlackout.NonBlackPixels -eq 0
        switchBlackoutFramebufferBlack = [int]$switchBlackout.NonBlackPixels -eq 0
        clockFonts = $fontIds
        uniqueClockFontHashes = $fontHashes.Count
        clockFontApiRoundTrip = $true
        clockFontRestartPersistence = 'physical-device-gate'
        clockFontGlowChangedFramebuffer = $true
        clockFontHotCoreChangedFramebuffer = $true
        settingsRoundTrip = [ordered]@{
            automaticCycle = [bool]$behavior.automaticCycle
            randomPlayback = [bool]$behavior.randomPlayback
            screenScheduleEnabled = [bool]$scheduled.screenScheduleEnabled
        }
        captures = @($captures)
    }
    $reportPath = Join-Path $OutputDirectory 'acceptance.json'
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath
    Write-Host "[PASS] $Model QEMU acceptance matrix completed." -ForegroundColor Green
    Write-Host "       Captures: $($captures.Count); scenes: $($behavior.sceneCount)"
    Write-Host "       Evidence: $reportPath"
}
finally {
    Set-Settings @{
        brightness = [int]$initial.brightness
        glowStrength = [int]$initial.glowStrength
        hotCoreEnabled = [bool]$initial.hotCoreEnabled
        hotCoreStyle = [int]$initial.hotCoreStyle
        colorPreset = [int]$initial.colorPreset
        displayOn = [bool]$initial.displayOn
        playScene = [bool]$initial.playScene
        sceneIndex = [int]$initial.sceneIndex
        automaticCycle = [bool]$initial.automaticCycle
        randomPlayback = [bool]$initial.randomPlayback
        screenScheduleEnabled = [bool]$initial.screenScheduleEnabled
        screenOffSchedule = @($initial.screenOffSchedule)
        animationsPerCycle = [int]$initial.animationsPerCycle
        clockDisplaySeconds = [int]$initial.clockDisplaySeconds
        animationGapSeconds = [int]$initial.animationGapSeconds
        clockFont = [string]$initial.clockFont
        use24Hour = [bool]$initial.use24Hour
        showSeconds = [bool]$initial.showSeconds
    } | Out-Null
    Invoke-Action 'showClock'
}
