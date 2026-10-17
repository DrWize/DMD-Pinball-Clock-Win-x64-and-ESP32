[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot '../../scripts/Compare-CurrentPlayback.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DmdCurrentPlayback-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $testRoot | Out-Null
$fake = Join-Path $testRoot 'fake-python.ps1'
$env:DMD_CURRENT_ARGS = Join-Path $testRoot 'arguments.json'
Set-Content $fake @'
param([Parameter(ValueFromRemainingArguments)][string[]] $Forwarded)
$Forwarded | ConvertTo-Json | Set-Content $env:DMD_CURRENT_ARGS
$global:LASTEXITCODE = 0
'@
function Assert-True([bool] $Value, [string] $Reason) { if (-not $Value) { throw $Reason } }
function Assert-Throws([scriptblock] $Action) { try { & $Action } catch { return }; throw 'Expected rejection.' }
try {
    $out = Join-Path $testRoot 'run with spaces'
    & $entry -Action Prepare -Output $out -TestSet Custom -Size '12.5%' -Python $fake
    $actual = @(Get-Content $env:DMD_CURRENT_ARGS -Raw | ConvertFrom-Json)
    Assert-True ($actual -contains $out -and $actual -contains '12.5%' -and $actual -contains '--test-set') 'Custom percentage or path quoting changed.'
    & $entry -Action Prepare -Output $out -Manifest 'old run/manifest.json' -Python $fake
    $actual = @(Get-Content $env:DMD_CURRENT_ARGS -Raw | ConvertFrom-Json)
    Assert-True ($actual -contains '--manifest' -and $actual -notcontains '--test-set') 'Manifest reuse mixed with sample selection.'
    & $entry -Action Resume -Output $out -Port7 COM8 -Python $fake
    $actual = @(Get-Content $env:DMD_CURRENT_ARGS -Raw | ConvertFrom-Json)
    Assert-True ($actual -contains 'resume' -and $actual -contains 'COM8' -and $actual -notcontains '--test-set') 'Resume did not use frozen inputs / port override.'
    Remove-Item $env:DMD_CURRENT_ARGS
    & $entry -Action Prepare -Output $out -TestSet '5%' -Python $fake -WhatIf
    Assert-True (-not (Test-Path $out) -and -not (Test-Path $env:DMD_CURRENT_ARGS)) 'WhatIf launched a process or created output.'
    Assert-Throws { & $entry -Action Run -Output $out -TestSet '10%' -Python $fake }
    Assert-Throws { & $entry -Action Resume -Output $out -Seed 99 -Python $fake }
    Assert-Throws { & $entry -Action Run -Output $out -SceneRoot 'other-scenes' -Python $fake }
    Assert-Throws { & $entry -Action Prepare -Output $out -Size 75 -Python $fake }
    Assert-Throws { & $entry -Action Prepare -Output $out -Manifest 'old.json' -Seed 4 -Python $fake }
    Write-Host '[PASS] PowerShell arguments, free-form size, spaces, manifest reuse, resume, COM override, invalid combinations, and nonmutating WhatIf.'
} finally {
    Remove-Item Env:\DMD_CURRENT_ARGS -ErrorAction SilentlyContinue
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf).StartsWith('DmdCurrentPlayback-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
