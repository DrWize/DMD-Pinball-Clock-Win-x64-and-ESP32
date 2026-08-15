[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockDownloadTests-' + [Guid]::NewGuid().ToString('N'))

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

# --- Mock Invoke-WebRequest. It is defined globally because the module's
# functions resolve commands from module/global scope, not the caller's script
# scope. Downloads copy a local fixture to -OutFile; HEAD requests report the
# configured GitHub reachability; both are driven by global mock state. ---
$global:MockDownloadFixture = $null
$global:MockGitHubReachable = $true
$global:MockDownloadCallCount = 0

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
    $global:MockDownloadCallCount++
    if ($Method -ieq 'Head') {
        if (-not $global:MockGitHubReachable) {
            throw "Simulated GitHub outage for $($Uri.AbsoluteUri)"
        }
        return [pscustomobject]@{ StatusCode = 200 }
    }
    if ($null -eq $global:MockDownloadFixture) {
        throw "Simulated network failure for $($Uri.AbsoluteUri)"
    }
    Copy-Item -LiteralPath $global:MockDownloadFixture -Destination $OutFile -Force
}

try {
    Import-Module $modulePath -Force
    $layout = New-DmdClockStagingLayout -Destination (Join-Path $testRoot 'stage') `
        -Confirm:$false

    $payload = Join-Path $testRoot 'payload.bin'
    [IO.File]::WriteAllBytes($payload, [byte[]](1, 2, 3, 4, 5))
    $payloadHash = Get-DmdClockSha256 -Path $payload

    function Assert-NoPartialFiles {
        param([string] $Directory)
        $partials = @(Get-ChildItem -LiteralPath $Directory -File |
            Where-Object { $_.Name -match '\.partial-[0-9a-f]{32}$' })
        Assert-True ($partials.Count -eq 0) 'A partial download file was left behind.'
    }

    # --- Fresh download verifies size and digest, then lands atomically. ---
    $global:MockDownloadFixture = $payload
    $global:MockDownloadCallCount = 0
    $dest = Join-Path $layout.SDCard 'downloaded.bin'
    $artifact = Save-DmdClockStagedDownload `
        -ArtifactId 'test.file' -Uri ([uri]'https://example.invalid/downloaded.bin') `
        -Destination $dest -StagingRoot $layout.Root `
        -ExpectedBytes 5 -ExpectedSha256 $payloadHash `
        -Kind 'scene-library' -Version '1' -Target 'esp32-s3'
    Assert-True ($artifact.status -eq 'downloaded') 'Fresh download did not report downloaded status.'
    Assert-True ($artifact.size -eq 5 -and $artifact.sha256 -eq $payloadHash) `
        'Fresh download reported wrong size or digest.'
    Assert-True (Test-Path -LiteralPath $dest) 'Fresh download did not create the artifact.'
    Assert-True ((Get-DmdClockSha256 -Path $dest) -eq $payloadHash) `
        'Fresh download wrote corrupted bytes.'
    Assert-True ($global:MockDownloadCallCount -eq 1) 'Fresh download made more than one request.'
    Assert-NoPartialFiles $layout.SDCard

    # --- Zero-byte download is rejected and leaves no file behind. ---
    $zero = Join-Path $testRoot 'zero.bin'
    [IO.File]::WriteAllBytes($zero, [byte[]]@())
    $global:MockDownloadFixture = $zero
    $zeroDest = Join-Path $layout.SDCard 'zero.bin'
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.zero' -Uri ([uri]'https://example.invalid/zero.bin') `
            -Destination $zeroDest -StagingRoot $layout.Root
    } 'outside the accepted range'
    Assert-True (-not (Test-Path -LiteralPath $zeroDest)) 'Zero-byte download left an artifact.'
    Assert-NoPartialFiles $layout.SDCard

    # --- Over-maximum download is rejected. ---
    $global:MockDownloadFixture = $payload
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.over' -Uri ([uri]'https://example.invalid/over.bin') `
            -Destination (Join-Path $layout.SDCard 'over.bin') -StagingRoot $layout.Root `
            -MaximumBytes 1
    } 'outside the accepted range'

    # --- Size mismatch is rejected. ---
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.size' -Uri ([uri]'https://example.invalid/size.bin') `
            -Destination (Join-Path $layout.SDCard 'size.bin') -StagingRoot $layout.Root `
            -ExpectedBytes 10
    } 'size mismatch'

    # --- SHA-256 mismatch is rejected. ---
    $other = Join-Path $testRoot 'other.bin'
    [IO.File]::WriteAllBytes($other, [byte[]](9, 9, 9))
    $otherHash = Get-DmdClockSha256 -Path $other
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.sha' -Uri ([uri]'https://example.invalid/sha.bin') `
            -Destination (Join-Path $layout.SDCard 'sha.bin') -StagingRoot $layout.Root `
            -ExpectedBytes 5 -ExpectedSha256 $otherHash
    } 'SHA-256 mismatch'

    # --- Non-HTTPS downloads are refused outright. ---
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.http' -Uri ([uri]'http://example.invalid/plain.bin') `
            -Destination (Join-Path $layout.SDCard 'plain.bin') -StagingRoot $layout.Root
    } 'Refusing non-HTTPS download'

    # --- A malformed expected digest is rejected before any network access. ---
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.badhash' -Uri ([uri]'https://example.invalid/badhash.bin') `
            -Destination (Join-Path $layout.SDCard 'badhash.bin') -StagingRoot $layout.Root `
            -ExpectedSha256 'not-a-digest'
    } 'Invalid expected SHA-256'

    # --- A network failure propagates and leaves no artifact or partial file. ---
    $global:MockDownloadFixture = $null
    $failDest = Join-Path $layout.SDCard 'failed.bin'
    Assert-Throws {
        $null = Save-DmdClockStagedDownload `
            -ArtifactId 'test.fail' -Uri ([uri]'https://example.invalid/failed.bin') `
            -Destination $failDest -StagingRoot $layout.Root `
            -ExpectedBytes 5 -ExpectedSha256 $payloadHash
    } 'Simulated network failure'
    Assert-True (-not (Test-Path -LiteralPath $failDest)) 'Failed download left an artifact.'
    Assert-NoPartialFiles $layout.SDCard

    # --- -WhatIf plans the download without touching the destination. ---
    $global:MockDownloadFixture = $payload
    $plannedDest = Join-Path $layout.SDCard 'planned.bin'
    $planned = Save-DmdClockStagedDownload `
        -ArtifactId 'test.plan' -Uri ([uri]'https://example.invalid/planned.bin') `
        -Destination $plannedDest -StagingRoot $layout.Root `
        -ExpectedBytes 5 -ExpectedSha256 $payloadHash -WhatIf
    Assert-True ($planned.status -eq 'planned') '-WhatIf did not report a planned status.'
    Assert-True (-not (Test-Path -LiteralPath $plannedDest)) '-WhatIf created the artifact.'

    # --- A verified artifact is reused without another request. ---
    $global:MockDownloadCallCount = 0
    $reused = Save-DmdClockStagedDownload `
        -ArtifactId 'test.file' -Uri ([uri]'https://example.invalid/downloaded.bin') `
        -Destination $dest -StagingRoot $layout.Root `
        -ExpectedBytes 5 -ExpectedSha256 $payloadHash
    Assert-True ($reused.status -eq 'reused') 'Valid staged artifact was not reused.'
    Assert-True ($global:MockDownloadCallCount -eq 0) 'Reuse still performed a download.'

    # --- A stale artifact with a wrong digest is replaced. ---
    [IO.File]::WriteAllBytes($dest, [byte[]](7, 7, 7, 7, 7))
    $replaced = Save-DmdClockStagedDownload `
        -ArtifactId 'test.file' -Uri ([uri]'https://example.invalid/downloaded.bin') `
        -Destination $dest -StagingRoot $layout.Root `
        -ExpectedBytes 5 -ExpectedSha256 $payloadHash
    Assert-True ($replaced.status -eq 'replaced') 'Stale artifact was not replaced.'
    Assert-True ((Get-DmdClockSha256 -Path $dest) -eq $payloadHash) `
        'Replacement did not restore the verified digest.'
    Assert-NoPartialFiles $layout.SDCard

    # --- An unpinned URL is refreshed and reused when the bytes are unchanged. ---
    $refreshDest = Join-Path $layout.SDCard 'refresh.bin'
    $first = Save-DmdClockStagedDownload `
        -ArtifactId 'test.refresh' -Uri ([uri]'https://example.invalid/refresh.bin') `
        -Destination $refreshDest -StagingRoot $layout.Root
    Assert-True ($first.status -eq 'downloaded') 'Unpinned first download did not download.'
    $second = Save-DmdClockStagedDownload `
        -ArtifactId 'test.refresh' -Uri ([uri]'https://example.invalid/refresh.bin') `
        -Destination $refreshDest -StagingRoot $layout.Root
    Assert-True ($second.status -eq 'reused') 'Unpinned refresh did not report a verified reuse.'

    # --- GitHub HTTPS reachability. ---
    $global:MockGitHubReachable = $true
    Assert-True (Test-DmdClockGitHubHttps) 'GitHub HTTPS probe failed while reachable.'
    $okRequirements = Invoke-DmdClockRequirementsCheck -Operation Download `
        -DataPath (Join-Path $testRoot 'gh-ok') -RequireNetwork
    Assert-True $okRequirements.Passed 'Download requirements failed while GitHub was reachable.'
    $githubCheck = @($okRequirements.Checks | Where-Object { $_.Name -eq 'GitHub HTTPS' })
    Assert-True ($githubCheck.Count -eq 1 -and $githubCheck[0].Passed) `
        'GitHub HTTPS check did not pass while reachable.'

    $global:MockGitHubReachable = $false
    Assert-True (-not (Test-DmdClockGitHubHttps)) 'GitHub HTTPS probe passed while unreachable.'
    $badRequirements = Invoke-DmdClockRequirementsCheck -Operation Download `
        -DataPath (Join-Path $testRoot 'gh-bad') -RequireNetwork
    Assert-True (-not $badRequirements.Passed) 'Download requirements passed while GitHub was unreachable.'
    $failedGithubCheck = @($badRequirements.Checks | Where-Object { $_.Name -eq 'GitHub HTTPS' })
    Assert-True ($failedGithubCheck.Count -eq 1 -and -not $failedGithubCheck[0].Passed) `
        'GitHub HTTPS check passed while unreachable.'
    Assert-Throws {
        $null = Invoke-DmdClockRequirementsCheck -Operation Download `
            -DataPath (Join-Path $testRoot 'gh-bad') -RequireNetwork -ThrowOnFailure
    } "Requirements check failed for 'Download'"

    Write-Host '[PASS] Download robustness: fresh, zero-byte, over-maximum, size-mismatch, SHA-256 mismatch, non-HTTPS, malformed digest, network failure, -WhatIf, reuse, stale replacement, unpinned refresh, and GitHub reachable/unreachable tests passed.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockDownloadTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
