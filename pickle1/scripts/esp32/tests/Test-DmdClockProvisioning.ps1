[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$flashScript = Join-Path $PSScriptRoot '..\Flash-DmdClockEsp32.ps1'
$sdScript = Join-Path $PSScriptRoot '..\Prepare-DmdClockSdCard.ps1'
$fixtureScript = Join-Path $PSScriptRoot '..\dev\New-DmdClockOfflineFixture.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockProvisioningTests-' + [Guid]::NewGuid().ToString('N'))

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
    $parsedFiles = @{}
    foreach ($path in @($modulePath, $flashScript, $sdScript)) {
        $tokens = $null
        $errors = $null
        $parsedFiles[$path] = [Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "PowerShell parser rejected '$path'."
        $emptyCatches = @($parsedFiles[$path].FindAll({
            param($node)
            $node -is [Management.Automation.Language.CatchClauseAst] -and
                $node.Body.Statements.Count -eq 0
        }, $true))
        Assert-True ($emptyCatches.Count -eq 0) `
            "PowerShell source contains an empty catch block: '$path'."
    }

    $sdSource = Get-Content -LiteralPath $sdScript -Raw
    Assert-True ($sdSource -notmatch '(?im)\b(Clear-Disk|Format-Volume|Initialize-Disk|New-Partition|Remove-Partition)\b') `
        'microSD preparation contains a disk partitioning or formatting command.'
    Assert-True ($sdSource -notmatch '(?s)foreach\s*\(\s*\$obsoletePath.*?Remove-Item') `
        'microSD preparation deletes obsolete managed scene files.'
    Assert-True ($sdSource -notmatch '(?s)\$legacyManifest\s*=.*?Remove-Item') `
        'microSD preparation deletes the legacy card manifest.'
    Assert-True ($sdSource -match "\`$mountedVolumes\.Count\s+-ne\s+1") `
        'microSD preparation does not require exactly one mounted volume.'
    Assert-True ($sdSource -match "\`$volume\.FileSystem\s+-ne\s+'FAT32'") `
        'microSD preparation does not enforce FAT32.'
    Assert-True ($sdSource -match "\`$volume\.HealthStatus.*-ne\s+'Healthy'") `
        'microSD preparation does not reject an unhealthy FAT32 volume.'

    Import-Module $modulePath -Force
    $readOnlyDestination = Join-Path $testRoot 'requirements-must-not-create'
    $requirements = Invoke-DmdClockRequirementsCheck -Operation Check `
        -DataPath $readOnlyDestination -MinimumFreeBytes 1MB `
        -RequiredCommands @('Get-FileHash', 'Invoke-WebRequest')
    Assert-True $requirements.Passed 'Requirements check unexpectedly failed.'
    Assert-True (-not (Test-Path -LiteralPath $testRoot)) `
        'Requirements check created its destination.'

    $whatIfRoot = Join-Path $testRoot 'whatif-must-not-create'
    $null = New-DmdClockStagingLayout -Destination $whatIfRoot -WhatIf
    Assert-True (-not (Test-Path -LiteralPath $whatIfRoot)) `
        'Staging -WhatIf created its destination.'

    $layout = New-DmdClockStagingLayout -Destination (Join-Path $testRoot 'fixture') `
        -Confirm:$false
    $fixturePath = Join-Path $layout.SDCard 'fixture.bin'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $fixturePath)) | Out-Null
    [IO.File]::WriteAllBytes($fixturePath, [byte[]](1, 2, 3, 4, 5))
    $fixtureHash = Get-DmdClockSha256 -Path $fixturePath
    $artifact = [pscustomobject]@{
        artifactId = 'test.fixture'; kind = 'test'; sourceUrl = 'https://example.invalid/fixture.bin'
        relativePath = 'SDCard/fixture.bin'; size = 5; sha256 = $fixtureHash
        version = '1'; target = 'test'; status = 'downloaded'
    }
    $null = Update-DmdClockStagingManifest -StagingRoot $layout.Root `
        -Artifacts @($artifact) -Confirm:$false
    $validated = Test-DmdClockStagingManifest -Source $layout.Root `
        -RequiredArtifactIds @('test.fixture')
    Assert-True ($validated.Artifacts.ContainsKey('test.fixture')) `
        'Complete staging fixture was not accepted.'

    Assert-Throws {
        $null = Test-DmdClockStagingManifest -Source $layout.Root `
            -RequiredArtifactIds @('test.missing')
    } 'missing inventory entry'

    [IO.File]::WriteAllBytes($fixturePath, [byte[]](9, 9, 9, 9, 9))
    Assert-Throws {
        $null = Test-DmdClockStagingManifest -Source $layout.Root `
            -RequiredArtifactIds @('test.fixture')
    } 'SHA-256 mismatch'

    $offlineFixture = Join-Path $testRoot 'offline-fixture'
    $fixtureRoot = & $fixtureScript -Destination $offlineFixture -Library DmdLarge |
        Select-Object -Last 1
    Assert-True (-not [string]::IsNullOrWhiteSpace($fixtureRoot)) `
        'Offline fixture builder returned no root.'

    $fixtureArtifactIds = @(
        'sd.catalog', 'sd.scene-metadata', 'sd.template.manifest',
        'sd.template.readme', 'sd.library.drwize-complete')
    $validatedFixture = Test-DmdClockStagingManifest -Source $fixtureRoot `
        -RequiredArtifactIds $fixtureArtifactIds
    Assert-True ($validatedFixture.Artifacts.ContainsKey('sd.library.drwize-complete')) `
        'Complete offline staging fixture was not fully validated.'

    $incompleteFixture = Join-Path $testRoot 'offline-fixture-incomplete'
    [IO.Directory]::CreateDirectory($incompleteFixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'staging-manifest.json') `
        -Destination (Join-Path $incompleteFixture 'staging-manifest.json')
    Copy-Item -LiteralPath (Join-Path $fixtureRoot 'SDCard') `
        -Destination (Join-Path $incompleteFixture 'SDCard') -Recurse
    Remove-Item -LiteralPath (Join-Path $incompleteFixture 'SDCard\catalog.json') -Force
    Assert-Throws {
        $null = Test-DmdClockStagingManifest -Source $incompleteFixture `
            -RequiredArtifactIds $fixtureArtifactIds
    } 'missing file.*sd.catalog'

    $dryRunTarget = Join-Path ([IO.Path]::GetTempPath()) (
        'DmdClockSdCardTest-' + [Guid]::NewGuid().ToString('N'))
    & $sdScript -TestRoot $dryRunTarget -Library DmdLarge -DryRun `
        -StagingSource $fixtureRoot
    Assert-True (-not (Test-Path -LiteralPath $dryRunTarget)) `
        'microSD card -DryRun created its test target.'

    $evidenceDirectory = Join-Path $testRoot 'evidence-logs'
    $evidenceLog = Start-DmdClockProvisioningLog -LogDirectory $evidenceDirectory `
        -Operation 'test-evidence'
    $mockRequirements = [pscustomobject]@{
        Checks = @([pscustomobject]@{
            Name = 'Fixture'; Passed = $true; Detected = 'ready'
            Required = 'ready'; Remediation = ''
        })
    }
    Write-DmdClockRequirementsLog -Requirements $mockRequirements
    Write-DmdClockProvisioningLog -Event 'redaction-fixture' -Detail (
        'password=do-not-log https://example.invalid/file?token=do-not-log')
    Complete-DmdClockProvisioningLog -Outcome completed -Detail 'fixture=true'
    $evidenceFiles = @(Get-ChildItem -LiteralPath $evidenceDirectory -Filter '*.log' -File)
    Assert-True ($evidenceFiles.Count -eq 1) 'Evidence logging did not create exactly one log.'
    Assert-True ($evidenceFiles[0].FullName -eq $evidenceLog) `
        'Evidence logging returned a different log path.'
    $evidence = Get-Content -LiteralPath $evidenceLog -Raw
    Assert-True ($evidence -match 'event=requirement') `
        'Evidence log omitted requirements.'
    Assert-True ($evidence -match 'event=run-finished.*outcome=completed') `
        'Evidence log omitted the final completed outcome.'
    Assert-True ($evidence -notmatch 'do-not-log') `
        'Evidence log retained a password or URL query secret.'
    Assert-True ($evidence -match '\[REDACTED\]') `
        'Evidence log did not mark redacted content.'

    $failedLog = Start-DmdClockProvisioningLog -LogDirectory $evidenceDirectory `
        -Operation 'test-failed-evidence'
    Write-DmdClockProvisioningLog -Event 'error' `
        -Detail 'error_type=Fixture error=token=do-not-log'
    Complete-DmdClockProvisioningLog -Outcome failed -Detail 'fixture=true'
    $failedEvidence = Get-Content -LiteralPath $failedLog -Raw
    Assert-True ($failedEvidence -match 'event=run-finished.*outcome=failed') `
        'Evidence log omitted the final failed outcome.'
    Assert-True ($failedEvidence -notmatch 'do-not-log') `
        'Failed evidence log retained a secret.'

    Write-Host '[PASS] Non-destructive provisioning parser, requirements, dry-run, evidence-log, redaction, complete, incomplete, and corrupt-staging tests passed.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockProvisioningTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
