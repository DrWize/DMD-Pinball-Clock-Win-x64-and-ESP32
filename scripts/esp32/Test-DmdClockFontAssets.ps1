[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$generator = Join-Path $PSScriptRoot 'Generate-DmdClockFonts.py'
$source = Join-Path $repoRoot 'assets\fonts\DotClk'
$generated = Join-Path $repoRoot 'firmware\dmdclock-esp32\main\generated'
$testRoot = Join-Path $repoRoot ('output\esp32\font-asset-test-' + [guid]::NewGuid().ToString('N'))
$resolvedOutput = [IO.Path]::GetFullPath((Join-Path $repoRoot 'output')).TrimEnd('\')
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedOutput + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary font-test path escaped the output directory: $resolvedTest"
}

function Invoke-Generator {
    param(
        [Parameter(Mandatory)][string] $SourceDirectory,
        [Parameter(Mandatory)][string] $OutputDirectory,
        [switch] $Check
    )
    $arguments = @(
        $generator,
        '--source-dir', $SourceDirectory,
        '--output-dir', $OutputDirectory
    )
    if ($Check) { $arguments += '--check' }
    $output = & python @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Host $_ }
    return $exitCode
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    if ((Invoke-Generator -SourceDirectory $source -OutputDirectory $generated -Check) -ne 0) {
        throw 'Canonical generated font assets are stale.'
    }

    $testSource = Join-Path $testRoot 'fonts'
    $testGenerated = Join-Path $testRoot 'generated'
    Copy-Item -LiteralPath $source -Destination $testSource -Recurse
    if ((Invoke-Generator -SourceDirectory $testSource -OutputDirectory $testGenerated) -ne 0) {
        throw 'Could not generate isolated font assets.'
    }
    Add-Content -LiteralPath (Join-Path $testGenerated 'dmd_fonts_generated.c') `
        -Value '// deliberately stale'
    if ((Invoke-Generator -SourceDirectory $testSource -OutputDirectory $testGenerated -Check) -eq 0) {
        throw 'Generator check mode accepted a stale generated C asset.'
    }

    $altern8 = Join-Path $testSource 'ALTERN8.fnt'
    $bytes = [IO.File]::ReadAllBytes($altern8)
    [IO.File]::WriteAllBytes($altern8, $bytes[0..([Math]::Max(0, $bytes.Length - 20))])
    if ((Invoke-Generator -SourceDirectory $testSource -OutputDirectory $testGenerated) -eq 0) {
        throw 'Generator accepted a truncated DotClk font.'
    }

    Write-Host '[PASS] DotClk generation, freshness, desktop golden hashes, and malformed-input rejection passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $resolvedTest) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
