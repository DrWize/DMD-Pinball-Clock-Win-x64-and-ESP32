# Standalone local comparison. See docs/development/CURRENT-PLAYBACK-COMPARISON.md.
[CmdletBinding()]
param(
    [ValidateSet('Prepare','Run','Resume','Report','Cleanup')][string] $Action = 'Prepare',
    [string] $Output,
    [ValidateSet('Standard50','5%','10%','50%','Custom')][string] $TestSet = 'Standard50',
    [string] $Size,
    [string] $Manifest,
    [int] $Seed = 50,
    [string] $SceneRoot,
    [ValidatePattern('^COM\d+$')][string] $Port7 = 'COM4',
    [ValidatePattern('^COM\d+$')][string] $Port349B = 'COM3',
    [string] $Python,
    [switch] $WhatIf
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($PSBoundParameters.Count -eq 0 -and -not [Console]::IsInputRedirected) {
    Write-Host 'Playback comparison — Windows / ESP32 7-inch / ESP32 3.49B'
    $choice = Read-Host '[1] Prepare  [2] Run  [3] Resume  [4] Report  [5] Cleanup  [6] Exit'
    if ($choice -eq '6') { return }
    $Action = switch ($choice) { '1' {'Prepare'} '2' {'Run'} '3' {'Resume'} '4' {'Report'} '5' {'Cleanup'} default {throw 'Choose 1–6.'} }
    $Output = Read-Host 'Run directory (for example output/timing/reference-run)'
    if ($Action -eq 'Prepare') {
        $choice = Read-Host '[1] Standard50 (default)  [2] 5%  [3] 10%  [4] 50%  [5] Custom  [6] Reuse manifest'
        switch ($choice) {
            {$_ -in '', '1'} { $TestSet = 'Standard50' }
            '2' { $TestSet = '5%' }
            '3' { $TestSet = '10%' }
            '4' { $TestSet = '50%' }
            '5' { $TestSet = 'Custom'; $Size = Read-Host 'Scene count or percentage (75 or 12.5%)' }
            '6' { $Manifest = Read-Host 'Existing manifest.json path' }
            default { throw 'Choose 1–6.' }
        }
    }
}
if ([string]::IsNullOrWhiteSpace($Output)) { throw '-Output is required; use a distinct run directory for each software version.' }
if ($Action -ne 'Prepare' -and ($PSBoundParameters.ContainsKey('TestSet') -or $Size -or $Manifest -or $PSBoundParameters.ContainsKey('Seed') -or $PSBoundParameters.ContainsKey('SceneRoot'))) { throw 'Selection options belong to Prepare. Run/Resume use the frozen manifest.' }
if ($Manifest -and ($Size -or $PSBoundParameters.ContainsKey('TestSet') -or $PSBoundParameters.ContainsKey('Seed'))) { throw '-Manifest cannot be combined with -TestSet, -Size, or -Seed.' }
if ($Size -and $TestSet -ne 'Custom') { throw '-Size requires -TestSet Custom.' }
$arguments = @((Join-Path $PSScriptRoot 'Compare-CurrentPlayback.py'), $Action.ToLowerInvariant(), $Output)
if ($Action -eq 'Prepare') {
    if ($Manifest) { $arguments += @('--manifest', $Manifest) }
    else {
        $arguments += @('--test-set', $TestSet, '--seed', [string]$Seed)
        if ($Size) { $arguments += @('--size', $Size) }
    }
    $arguments += @('--port7', $Port7, '--port349b', $Port349B)
    if ($SceneRoot) { $arguments += @('--scene-root', $SceneRoot) }
}
if ($Action -in 'Run','Resume','Cleanup') {
    if ($PSBoundParameters.ContainsKey('Port7')) { $arguments += @('--port7', $Port7) }
    if ($PSBoundParameters.ContainsKey('Port349B')) { $arguments += @('--port349b', $Port349B) }
}
if ($WhatIf) {
    Write-Host ('[WHATIF] Python ' + ($arguments -join ' '))
    Write-Host '[WHATIF] No process, port, capture session, or output directory was opened.'
    return
}
if (-not $Python) {
    $pinned = Join-Path (Split-Path -Parent $repoRoot) '.tools/esp-idf/v5.5.2/tools/python/v5.5.2/venv/Scripts/python.exe'
    $Python = if (Test-Path -LiteralPath $pinned) { $pinned } else { (Get-Command python -ErrorAction Stop).Source }
}
& $Python @arguments
if ($LASTEXITCODE -ne 0) { throw "Playback comparison failed (exit $LASTEXITCODE). Existing evidence is retained; inspect the run directory before resuming." }
