[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$sdScript = Join-Path $PSScriptRoot '..\Prepare-DmdClockSdCard.ps1'
$fixtureBuilder = Join-Path $PSScriptRoot '..\dev\New-DmdClockOfflineFixture.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockAcceptanceGate-' + [Guid]::NewGuid().ToString('N'))

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

# --- Mock network and hardware. Global stubs because the sd script imports the
#     provisioning module in-process, and module functions resolve commands from
#     global scope. GET downloads copy a routed local fixture; HEAD reports
#     GitHub reachability; Get-Disk only counts calls (download-only must never
#     enumerate hardware). ---
$global:MockGitHubReachable = $true
$global:MockGetDiskCalls = 0
$global:MockDownloadRoutes = @{}

function global:Invoke-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [string] $OutFile,
        [hashtable] $Headers,
        [string] $Method = 'Default',
        [int] $ConnectionTimeoutSeconds = 0,
        [int] $OperationTimeoutSeconds = 0
    )
    if ($Method -ieq 'Head') {
        if (-not $global:MockGitHubReachable) {
            throw "Simulated GitHub outage for $($Uri.AbsoluteUri)"
        }
        return [pscustomobject]@{ StatusCode = 200 }
    }
    $key = $Uri.AbsoluteUri
    if (-not $global:MockDownloadRoutes.ContainsKey($key)) {
        throw "Simulated network failure: no mock route for '$key'"
    }
    Copy-Item -LiteralPath $global:MockDownloadRoutes[$key] -Destination $OutFile -Force
}

function global:Get-Disk {
    $global:MockGetDiskCalls++
    return @()
}

try {
    Import-Module $modulePath -Force
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null

    # --- Build the offline staging fixture and wire download routes to it. ---
    & $fixtureBuilder -Destination $testRoot | Out-Null
    $catalog = Get-Content -LiteralPath (Join-Path $testRoot 'SDCard\catalog.json') -Raw |
        ConvertFrom-Json
    $pack = @($catalog.packs | Where-Object { [string]$_.packId -eq 'drwize-complete' })[0]
    $libraryFileName = [IO.Path]::GetFileName([string]$pack.downloadUrl)
    $libraryZip = Join-Path $testRoot ("SDCard\libraries\drwize-complete\$libraryFileName")
    $libraryHash = Get-DmdClockSha256 -Path $libraryZip

    $rawBase = 'https://raw.githubusercontent.com/DrWize/DMD-Pinball-Clock-Win-x64-and-ESP32/master'
    $global:MockDownloadRoutes = @{
        "$rawBase/scenes/catalog.json" = Join-Path $testRoot 'SDCard\catalog.json'
        "$rawBase/scenes/scene-metadata.json" = Join-Path $testRoot 'SDCard\scene-metadata.json'
        "$rawBase/firmware/dmdclock-esp32/sdcard/dmd/manifest.json" = Join-Path $testRoot 'SDCard\template\dmd\manifest.json'
        "$rawBase/firmware/dmdclock-esp32/sdcard/dmd/README.md" = Join-Path $testRoot 'SDCard\template\dmd\README.md'
        [string]$pack.downloadUrl = $libraryZip
    }

    # --- A normal Windows 11 x64 / PowerShell 7 user runs download-only staging
    #     with no microSD card and no ESP32 attached: every required artifact is
    #     obtained and verified without formatting a disk or touching hardware. ---
    $dest = Join-Path $testRoot 'stage'
    [IO.Directory]::CreateDirectory($dest) | Out-Null
    $runError = $null
    $output = @()
    try {
        $output = @(& $sdScript -DownloadOnly -Destination $dest 6>&1)
    }
    catch {
        $runError = $_
    }
    if ($null -ne $runError) {
        throw "Download-only staging failed: $($runError.Exception.Message)`n$($runError.ScriptStackTrace)"
    }
    $outputText = $output -join "`n"
    Assert-True ($outputText -match '\[DONE\] Verified microSD card payload staged without enumerating removable media') `
        'Download-only staging did not confirm the no-enumeration guarantee.'
    Assert-True ($global:MockGetDiskCalls -eq 0) 'Download-only staging enumerated disk hardware.'

    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'SDCard\catalog.json')) `
        'Staged catalog.json is missing.'
    $stagedCatalog = Get-Content -LiteralPath (Join-Path $dest 'SDCard\catalog.json') -Raw |
        ConvertFrom-Json
    Assert-True ([int]$stagedCatalog.schemaVersion -eq 1) 'Staged catalog schema is not v1.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'SDCard\scene-metadata.json')) `
        'Staged scene-metadata.json is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'SDCard\template\dmd\manifest.json')) `
        'Staged template manifest.json is missing.'
    Assert-True (Test-Path -LiteralPath (Join-Path $dest 'SDCard\template\dmd\README.md')) `
        'Staged template README.md is missing.'
    $stagedLibrary = Join-Path $dest ("SDCard\libraries\drwize-complete\$libraryFileName")
    Assert-True (Test-Path -LiteralPath $stagedLibrary) 'Staged scene library zip is missing.'
    Assert-True ((Get-DmdClockSha256 -Path $stagedLibrary) -eq $libraryHash) `
        'Staged library digest does not match the catalog.'

    # --- The result validates as a complete offline staging source. ---
    $verified = Test-DmdClockStagingManifest -Source $dest -RequiredArtifactIds @(
        'sd.catalog',
        'sd.scene-metadata',
        'sd.template.manifest',
        'sd.template.readme',
        'sd.library.drwize-complete')
    Assert-True (@($verified.Manifest.artifacts).Count -eq 5) `
        'Staging manifest does not contain all five artifacts.'
    $downloaded = @($verified.Manifest.artifacts | Where-Object { $_.status -eq 'downloaded' })
    Assert-True ($downloaded.Count -eq 5) 'Not every staged artifact was reported as downloaded.'

    # --- The run produced a completed provisioning log and left no partials. ---
    $logFiles = @(Get-ChildItem -LiteralPath (Join-Path $dest 'Logs') -File -Filter '*.log')
    Assert-True ($logFiles.Count -eq 1) 'Download-only staging did not produce exactly one log.'
    $logText = Get-Content -LiteralPath $logFiles[0].FullName -Raw
    Assert-True ($logText -match 'outcome=completed') `
        'The provisioning log did not record a completed outcome.'
    $partials = @(Get-ChildItem -LiteralPath $dest -Recurse -File |
        Where-Object { $_.Name -match '\.partial-[0-9a-f]{32}' })
    Assert-True ($partials.Count -eq 0) 'A partial download or manifest file was left behind.'

    # --- A -WhatIf download-only run plans without writing a single file. ---
    $whatIfDest = Join-Path $testRoot 'stage-whatif'
    [IO.Directory]::CreateDirectory($whatIfDest) | Out-Null
    $whatIfError = $null
    try {
        $null = & $sdScript -DownloadOnly -Destination $whatIfDest -WhatIf 6>&1
    }
    catch {
        $whatIfError = $_
    }
    Assert-True ($null -eq $whatIfError) "Download-only -WhatIf run failed: $whatIfError"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $whatIfDest 'SDCard'))) `
        'WhatIf staging created the SDCard layout.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $whatIfDest 'staging-manifest.json'))) `
        'WhatIf staging wrote a manifest.'

    # --- Firmware web UI: mobile/widescreen responsiveness and the guide name. ---
    $webDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\firmware\dmdclock-esp32\main\web'))
    $indexHtml = Get-Content -LiteralPath (Join-Path $webDir 'index.html') -Raw
    $apiHtml = Get-Content -LiteralPath (Join-Path $webDir 'api.html') -Raw
    Assert-True ($indexHtml -match '<meta name="viewport"') `
        'index.html is missing the mobile viewport meta tag.'
    Assert-True ($apiHtml -match '<meta name="viewport"') `
        'api.html is missing the mobile viewport meta tag.'
    Assert-True ($indexHtml -match '@media\(max-width:640px\)') `
        'index.html is missing the 640px mobile breakpoint.'
    Assert-True ($indexHtml -match 'main\{width:min\(1080px') `
        'index.html must use the 1080px widescreen content column.'
    Assert-True ($apiHtml -match '@media\(max-width:720px\)') `
        'api.html is missing the 720px mobile breakpoint.'
    Assert-True ($indexHtml -match 'Open the Windows microSD card preparation guide') `
        'index.html scene-library guide must use the microSD name.'
    Assert-True ($indexHtml -notmatch 'TF-card preparation guide') `
        'index.html still uses the old TF-card guide name.'

    Write-Host '[PASS] Acceptance gate: a Windows 11 x64 / PowerShell 7 user with no microSD card and no ESP32 attached obtains every required artifact via download-only staging, digests are verified, no disk hardware is enumerated, no partial files remain, -WhatIf plans without writing anything, and the embedded web UI keeps its viewport meta, mobile/widescreen breakpoints, and the microSD guide name.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockAcceptanceGate-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
