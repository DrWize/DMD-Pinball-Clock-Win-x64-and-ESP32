# END-USER TEST (tests\) - verifies that RUNME-Install-DmdClockEsp32.ps1 composes
# Prepare-DmdClockSdCard.ps1 then Flash-DmdClockEsp32.ps1 in the correct order,
# self-fetches missing companion scripts, stages once (and skips staging when
# already present), supports -DownloadOnly, -Update, -SkipCard, and -Force,
# forwards parameters, refuses to download under -WhatIf, and passes
# -CheckRequirements through.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installScript = Join-Path $PSScriptRoot '..\RUNME-Install-DmdClockEsp32.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockInstallTests-' + [Guid]::NewGuid().ToString('N'))
$scratch = Join-Path $testRoot 'scratch'
$callPath = Join-Path $scratch 'calls.txt'
$total = 0

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

function Get-CallsSince([int] $From) {
    if (-not (Test-Path -LiteralPath $callPath -PathType Leaf)) {
        return ,@()
    }
    return ,@(Get-Content -LiteralPath $callPath | Select-Object -Skip $From)
}

function Invoke-Scenario {
    param([string] $Name, [scriptblock] $Run, [string] $Expect)
    & $Run
    $newCalls = Get-CallsSince -From $script:total
    $script:total += $newCalls.Count
    Write-Host ("[{0}] {1}: {2}" -f $Name, $newCalls.Count, $Expect)
    return ,$newCalls
}

try {
    [IO.Directory]::CreateDirectory($scratch) | Out-Null

    # --- Stub provisioning module: sd staging is valid only when a marker exists. ---
    Set-Content -LiteralPath (Join-Path $scratch 'DmdClock.Provisioning.psm1') -Value @'
function Test-DmdClockStagingManifest {
    param([string] $Source, [string[]] $RequiredArtifactIds)
    if (Test-Path -LiteralPath (Join-Path $Source 'MARKER-OK') -PathType Leaf) {
        return [pscustomobject]@{ Artifacts = @{} }
    }
    throw 'stub: staging incomplete'
}
function Set-DmdClockOperationResult {
    param([string] $Status, [string] $Operation, [string] $Detail = '')
    $global:DmdClockOperationResult = [pscustomobject]@{
        PSTypeName = 'DmdClock.OperationResult'
        Status = $Status
        Operation = $Operation
        Detail = $Detail
    }
}
function Invoke-DmdClockChildOperation {
    param([string] $Operation, [string] $ScriptPath, [hashtable] $Arguments = @{})
    $global:DmdClockOperationResult = $null
    & $ScriptPath @Arguments
    if ($null -eq $global:DmdClockOperationResult) { throw "$Operation did not report an operation result." }
    return $global:DmdClockOperationResult
}
Export-ModuleMember -Function Test-DmdClockStagingManifest,Set-DmdClockOperationResult,Invoke-DmdClockChildOperation
'@ -Encoding utf8NoBOM

    # --- Recording fakes for the three real entry scripts. ---
    Set-Content -LiteralPath (Join-Path $scratch 'Prepare-DmdClockSdCard.ps1') -Value @'
[CmdletBinding()]
param(
    [int] $DiskNumber = -1,
    [switch] $Wizard,
    [switch] $ListDisks,
    [switch] $CheckRequirements,
    [string] $Destination,
    [switch] $DownloadOnly,
    [string] $Library,
    [string] $SourceDirectory,
    [string] $StagingSource,
    [switch] $RefreshSource,
    [switch] $DryRun,
    [switch] $AllowFixedDrive,
    [string] $Repository,
    [switch] $OnlineSupportFiles
)
$kind = if ($DownloadOnly) { 'sd-stage' } elseif ($CheckRequirements) { 'sd-check' } else { 'sd-prepare' }
$entry = '{0}|dest={1}|src={2}|lib={3}|disk={4}|dry={5}|wiz={6}|check={7}|refresh={8}' -f `
    $kind, $Destination, $StagingSource, $Library, $DiskNumber, [bool]$DryRun, [bool]$Wizard, `
    [bool]$CheckRequirements, [bool]$RefreshSource
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'), $entry + [Environment]::NewLine)
if ($env:DMD_TEST_CANCEL_KIND -eq $kind) {
    Set-DmdClockOperationResult -Status cancelled -Operation $kind
} else {
    Set-DmdClockOperationResult -Status $(if ($DryRun) { 'dry-run' } else { 'completed' }) -Operation $kind
}
'@ -Encoding utf8NoBOM

    Set-Content -LiteralPath (Join-Path $scratch 'Flash-DmdClockEsp32.ps1') -Value @'
[CmdletBinding()]
param(
    [switch] $Wizard,
    [switch] $CheckRequirements,
    [string] $Board,
    [string] $FlashMode,
    [string] $Port,
    [string] $BoardRevision,
    [switch] $FactoryRecovery,
    [string] $ReleaseTag,
    [string] $Destination,
    [switch] $DownloadOnly,
    [string] $Source,
    [string] $Repository,
    [switch] $WhatIf,
    [string] $ConfirmHardware,
    [switch] $Force
)
$kind = if ($DownloadOnly) { 'fw-stage' } elseif ($CheckRequirements) { 'fw-check' } else { 'fw-flash' }
$entry = '{0}|src={1}|board={2}|mode={3}|port={4}|dest={5}|wi={6}|check={7}|rev={8}|fr={9}|tag={10}|hw={11}|force={12}' -f `
    $kind, $Source, $Board, $FlashMode, $Port, $Destination, [bool]$WhatIf, [bool]$CheckRequirements, `
    $BoardRevision, [bool]$FactoryRecovery, $ReleaseTag, $ConfirmHardware, [bool]$Force
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'), $entry + [Environment]::NewLine)
if ($env:DMD_TEST_CANCEL_KIND -eq $kind) {
    Set-DmdClockOperationResult -Status cancelled -Operation $kind
} else {
    Set-DmdClockOperationResult -Status $(if ($WhatIf) { 'dry-run' } else { 'completed' }) -Operation $kind
}
'@ -Encoding utf8NoBOM

    Set-Content -LiteralPath (Join-Path $scratch 'Reset-DmdClockSettings.ps1') -Value @'
[CmdletBinding()]
param(
    [string] $Port,
    [switch] $CheckRequirements,
    [switch] $WhatIf,
    [string] $ConfirmHardware,
    [switch] $Force,
    [string] $Repository
)
$kind = if ($CheckRequirements) { 'reset-check' } else { 'reset-settings' }
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'), $kind + [Environment]::NewLine)
Set-DmdClockOperationResult -Status $(if ($WhatIf) { 'dry-run' } else { 'completed' }) -Operation $kind
'@ -Encoding utf8NoBOM

    Copy-Item -LiteralPath $installScript -Destination (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1')

    # --- Scenario A: nothing staged; expect stage -> prepare -> stage -> flash. ---
    $destA = Join-Path $testRoot 'dest-a'
    [IO.Directory]::CreateDirectory($destA) | Out-Null
    $callsA = Invoke-Scenario 'A' { & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destA -DiskNumber 3 } 'full run'
    Assert-True ($callsA.Count -eq 4) "Scenario A expected 4 calls; got: $($callsA -join ' | ')"
    Assert-True ($callsA[0] -match '^sd-stage') "Scenario A first call must be sd-stage; got: $($callsA[0])"
    Assert-True ($callsA[1] -match '^fw-stage') "Scenario A second call must be fw-stage; got: $($callsA[1])"
    Assert-True ($callsA[2] -match '^sd-prepare') "Scenario A third call must be sd-prepare; got: $($callsA[2])"
    Assert-True ($callsA[3] -match '^fw-flash') "Scenario A last call must be fw-flash; got: $($callsA[3])"
    Assert-True ($callsA[2] -match "disk=3") 'Scenario A sd-prepare must forward -DiskNumber 3.'
    Assert-True ($callsA[2] -match 'src=.*dest-a') 'Scenario A sd-prepare must forward the staging destination as -StagingSource.'
    Assert-True ($callsA[3] -match 'src=.*dest-a') 'Scenario A fw-flash must forward the staging destination as -Source.'

    # --- Scenario B: already fully staged; expect prepare + flash only, forwarded args. ---
    $destB = Join-Path $testRoot 'dest-b'
    [IO.Directory]::CreateDirectory($destB) | Out-Null
    Set-Content -LiteralPath (Join-Path $destB 'MARKER-OK') -Value 'ok'
    Set-Content -LiteralPath (Join-Path $destB 'staging-manifest.json') -Value @'
{ "schema": "dmdclock-staging", "version": 1, "artifacts": [
  { "artifactId": "sd.catalog", "status": "downloaded" },
  { "artifactId": "sd.library.drwize-complete", "status": "downloaded" },
  { "artifactId": "tool.esptool.windows-x64", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare7.manifest", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare7.package", "status": "downloaded" }
] }
'@ -Encoding utf8NoBOM
    $callsB = Invoke-Scenario 'B' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destB `
            -Board Waveshare7 -FlashMode FullReset -Port COM5 -DiskNumber 3
    } 'staged, prepare + flash'
    Assert-True ($callsB.Count -eq 2) "Scenario B expected 2 calls; got: $($callsB -join ' | ')"
    Assert-True ($callsB[0] -match '^sd-prepare') "Scenario B first call must be sd-prepare; got: $($callsB[0])"
    Assert-True ($callsB[1] -match '^fw-flash') "Scenario B second call must be fw-flash; got: $($callsB[1])"
    Assert-True ($callsB[1] -match 'board=Waveshare7') 'Scenario B must forward -Board.'
    Assert-True ($callsB[1] -match 'mode=FullReset') 'Scenario B must forward -FlashMode FullReset.'
    Assert-True ($callsB[1] -match 'port=COM5') 'Scenario B must forward -Port.'

    # --- A fully staged destination covering both boards, the library, and the tool. ---
    $destFull = Join-Path $testRoot 'dest-full'
    [IO.Directory]::CreateDirectory($destFull) | Out-Null
    Set-Content -LiteralPath (Join-Path $destFull 'MARKER-OK') -Value 'ok'
    Set-Content -LiteralPath (Join-Path $destFull 'staging-manifest.json') -Value @'
{ "schema": "dmdclock-staging", "version": 1, "artifacts": [
  { "artifactId": "sd.catalog", "status": "downloaded" },
  { "artifactId": "sd.library.drwize-complete", "status": "downloaded" },
  { "artifactId": "tool.esptool.windows-x64", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare7.manifest", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare7.package", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare349B.manifest", "status": "downloaded" },
  { "artifactId": "firmware.Waveshare349B.package", "status": "downloaded" }
] }
'@ -Encoding utf8NoBOM

    # --- Scenario C: -WhatIf with nothing staged must never download or plan against
    # --- an empty destination, so no child script runs at all. ---
    $destC = Join-Path $testRoot 'dest-c'
    [IO.Directory]::CreateDirectory($destC) | Out-Null
    $callsC = Invoke-Scenario 'C' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destC -WhatIf
    } 'whatif, unstaged'
    Assert-True ($callsC.Count -eq 0) "Scenario C expected 0 calls; got: $($callsC -join ' | ')"
    Assert-True (@($callsC | Where-Object { $_ -match '^(sd|fw)-stage' }).Count -eq 0) `
        'Scenario C must not run any staging under -WhatIf.'

    # --- Scenario G: -WhatIf with a fully staged destination plans the real
    # --- microSD and flash steps against that staging without downloading. ---
    $callsG = Invoke-Scenario 'G' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destB `
            -Board Waveshare7 -WhatIf
    } 'whatif, staged'
    Assert-True ($callsG.Count -eq 2) "Scenario G expected 2 calls; got: $($callsG -join ' | ')"
    Assert-True ($callsG[0] -match '^sd-prepare.*dry=True') 'Scenario G sd-prepare must run in dry-run.'
    Assert-True ($callsG[1] -match '^fw-flash.*wi=True') 'Scenario G fw-flash must run in dry-run.'

    # --- Scenario H: -DownloadOnly stages the library and both firmware images
    # --- and stops, never touching the card or flashing. ---
    $destH = Join-Path $testRoot 'dest-h'
    [IO.Directory]::CreateDirectory($destH) | Out-Null
    $callsH = Invoke-Scenario 'H' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destH -DownloadOnly
    } 'download only'
    Assert-True ($callsH.Count -eq 2) "Scenario H expected 2 calls; got: $($callsH -join ' | ')"
    Assert-True ($callsH[0] -match '^sd-stage') "Scenario H first call must be sd-stage; got: $($callsH[0])"
    Assert-True ($callsH[1] -match '^fw-stage') "Scenario H second call must be fw-stage; got: $($callsH[1])"

    # --- Scenario I: -DownloadOnly on already-staged payload stages nothing. ---
    $callsI = Invoke-Scenario 'I' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destFull -DownloadOnly
    } 'download only, already staged'
    Assert-True ($callsI.Count -eq 0) "Scenario I expected 0 calls; got: $($callsI -join ' | ')"

    # --- Scenario J: -Update forces re-staging the latest payloads even when
    # --- staging already exists, then prepares and flashes. ---
    $callsJ = Invoke-Scenario 'J' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destFull `
            -Board Waveshare7 -Update -DiskNumber 3
    } 'update on staged'
    Assert-True ($callsJ.Count -eq 4) "Scenario J expected 4 calls; got: $($callsJ -join ' | ')"
    Assert-True ($callsJ[0] -match '^sd-stage') 'Scenario J must re-stage the microSD payload.'
    Assert-True ($callsJ[1] -match '^fw-stage') 'Scenario J must re-stage the firmware.'
    Assert-True ($callsJ[2] -match '^sd-prepare') 'Scenario J must then prepare the card.'
    Assert-True ($callsJ[3] -match '^fw-flash') 'Scenario J must then flash.'

    # --- Scenario K: -SkipCard runs only the flash phase. ---
    $callsK = Invoke-Scenario 'K' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destFull `
            -Board Waveshare7 -Port COM5 -SkipCard -Force
    } 'skip card'
    Assert-True ($callsK.Count -eq 1) "Scenario K expected 1 call; got: $($callsK -join ' | ')"
    Assert-True ($callsK[0] -match '^fw-flash') "Scenario K must only flash; got: $($callsK[0])"
    Assert-True ($callsK[0] -match 'force=True') 'Scenario K must forward -Force.'
    Assert-True ($callsK[0] -match 'port=COM5') 'Scenario K must forward -Port.'

    # --- Scenario M: a child cancellation stops orchestration and must never
    #     become an install or flash completion message. ---
    $beforeM = $script:total
    $env:DMD_TEST_CANCEL_KIND = 'sd-prepare'
    try {
        $outputM = @(& (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') `
            -Destination $destFull -DiskNumber 3 6>&1)
    }
    finally {
        Remove-Item Env:\DMD_TEST_CANCEL_KIND -ErrorAction SilentlyContinue
    }
    $callsM = Get-CallsSince -From $beforeM
    $script:total += $callsM.Count
    Assert-True ($callsM.Count -eq 1 -and $callsM[0] -match '^sd-prepare') `
        'Scenario M must stop immediately after the cancelled card operation.'
    Assert-True (($outputM -join "`n") -notmatch '\[DONE\]|Flash complete|Install complete') `
        'Scenario M converted child cancellation into a completion message.'
    Assert-True ($global:DmdClockOperationResult.Status -eq 'cancelled') `
        'Scenario M did not propagate the cancelled operation result.'

    # --- Scenario D: -CheckRequirements passes through to both scripts. ---
    $callsD = Invoke-Scenario 'D' {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -CheckRequirements
    } 'check requirements'
    Assert-True ($callsD.Count -eq 2) "Scenario D expected 2 calls; got: $($callsD -join ' | ')"
    Assert-True ($callsD[0] -match '^sd-check') "Scenario D first call must be sd-check; got: $($callsD[0])"
    Assert-True ($callsD[1] -match '^fw-check') "Scenario D second call must be fw-check; got: $($callsD[1])"

    # --- Scenario E: invalid disk number is rejected. ---
    Assert-Throws {
        & (Join-Path $scratch 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destB -DiskNumber 1000
    } 'DiskNumber'

    # --- Scenario F: with missing companions, -WhatIf plans the fetch and stops
    # --- without downloading anything. ---
    $lonely = Join-Path $testRoot 'lonely'
    [IO.Directory]::CreateDirectory($lonely) | Out-Null
    Copy-Item -LiteralPath $installScript -Destination (Join-Path $lonely 'RUNME-Install-DmdClockEsp32.ps1')
    Assert-Throws {
        & (Join-Path $lonely 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destB -WhatIf
    } 'companion scripts'

    # --- Scenario L: a missing companion script is self-fetched from the script
    # --- base URL, then the run proceeds (stage, stage, prepare, flash). ---
    $fetchSrc = Join-Path $testRoot 'fetch-src'
    [IO.Directory]::CreateDirectory($fetchSrc) | Out-Null
    Copy-Item -LiteralPath (Join-Path $scratch 'DmdClock.Provisioning.psm1') -Destination (Join-Path $fetchSrc 'DmdClock.Provisioning.psm1')
    Copy-Item -LiteralPath (Join-Path $scratch 'Prepare-DmdClockSdCard.ps1') -Destination (Join-Path $fetchSrc 'Prepare-DmdClockSdCard.ps1')
    Copy-Item -LiteralPath (Join-Path $scratch 'Flash-DmdClockEsp32.ps1') -Destination (Join-Path $fetchSrc 'Flash-DmdClockEsp32.ps1')
    Copy-Item -LiteralPath (Join-Path $scratch 'Reset-DmdClockSettings.ps1') -Destination (Join-Path $fetchSrc 'Reset-DmdClockSettings.ps1')
    $lonelyB = Join-Path $testRoot 'lonely-b'
    [IO.Directory]::CreateDirectory($lonelyB) | Out-Null
    Copy-Item -LiteralPath $installScript -Destination (Join-Path $lonelyB 'RUNME-Install-DmdClockEsp32.ps1')
    $destL = Join-Path $testRoot 'dest-l'
    [IO.Directory]::CreateDirectory($destL) | Out-Null
    & (Join-Path $lonelyB 'RUNME-Install-DmdClockEsp32.ps1') -Destination $destL `
        -CompanionScriptSource $fetchSrc -DiskNumber 3 | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $lonelyB 'DmdClock.Provisioning.psm1')) 'Scenario L must self-fetch the provisioning module.'
    Assert-True (Test-Path -LiteralPath (Join-Path $lonelyB 'Prepare-DmdClockSdCard.ps1')) 'Scenario L must self-fetch Prepare-DmdClockSdCard.ps1.'
    Assert-True (Test-Path -LiteralPath (Join-Path $lonelyB 'Flash-DmdClockEsp32.ps1')) 'Scenario L must self-fetch Flash-DmdClockEsp32.ps1.'
    Assert-True (Test-Path -LiteralPath (Join-Path $lonelyB 'Reset-DmdClockSettings.ps1')) 'Scenario L must self-fetch Reset-DmdClockSettings.ps1.'
    $callsL = @(Get-Content -LiteralPath (Join-Path $lonelyB 'calls.txt'))
    Assert-True ($callsL.Count -eq 4) "Scenario L expected 4 calls; got: $($callsL -join ' | ')"
    Assert-True ($callsL[0] -match '^sd-stage') 'Scenario L must run sd staging after fetching.'
    Assert-True ($callsL[1] -match '^fw-stage') 'Scenario L must run fw staging after fetching.'
    Assert-True ($callsL[2] -match '^sd-prepare') 'Scenario L must then prepare the card.'
    Assert-True ($callsL[3] -match '^fw-flash') 'Scenario L must then flash.'
    Write-Host '[L] 4: self-fetch companion scripts'

    Write-Host '[PASS] Install orchestrator orders staging, SD card preparation, and flashing correctly, stages once or downloads-only, updates to the latest, skips the card phase, forwards -Force and parameters, never downloads in -WhatIf, and passes requirements through.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockInstallTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
