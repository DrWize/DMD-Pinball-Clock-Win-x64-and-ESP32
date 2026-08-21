[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$source = Join-Path $repoRoot 'assets\fonts\DotClk'
$main = Join-Path $repoRoot 'firmware\dmdclock-esp32\main'
$gcc = 'C:\msys64\mingw64\bin\gcc.exe'
if (-not (Test-Path -LiteralPath $gcc -PathType Leaf)) {
    throw "The host C font loader test requires '$gcc'."
}
$env:Path = (Split-Path -Parent $gcc) + ';' + $env:Path
$testRoot = Join-Path $repoRoot ('output\esp32\font-loader-test-' + [guid]::NewGuid().ToString('N'))
$resolvedOutput = [IO.Path]::GetFullPath((Join-Path $repoRoot 'output')).TrimEnd('\')
$resolvedTest = [IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTest.StartsWith($resolvedOutput + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Temporary font-test path escaped the output directory: $resolvedTest"
}

function Invoke-Loader {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    & $exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Font loader test failed: $($Arguments -join ' ')"
    }
}

New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
try {
    $exe = Join-Path $testRoot 'font-loader-test.exe'
    & $gcc -std=c11 -Wall -Wextra -Werror -O2 `
        -I $main `
        (Join-Path $main 'dmd_font.c') `
        (Join-Path $main 'dmd_font_loader.c') `
        (Join-Path $PSScriptRoot 'Test-DmdClockFontLoader.c') `
        -o $exe
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the host C font loader test.' }

    foreach ($font in Get-ChildItem -LiteralPath $source -Filter '*.fnt' -File) {
        Invoke-Loader inspect $font.FullName $font.Name 1
    }

    $fixtures = Join-Path $testRoot 'fixtures'
    Copy-Item -LiteralPath $source -Destination $fixtures -Recurse
    Copy-Item -LiteralPath (Join-Path $source 'ALTERN8.fnt') `
        -Destination (Join-Path $fixtures 'z-duplicate-id.fnt')
    Invoke-Loader catalog $fixtures 5

    $emptyCatalog = Join-Path $testRoot 'empty-catalog'
    New-Item -ItemType Directory -Path $emptyCatalog | Out-Null
    Invoke-Loader catalog $emptyCatalog 1
    Invoke-Loader catalog (Join-Path $testRoot 'missing-catalog') 1

    $canonical = [IO.File]::ReadAllBytes((Join-Path $source 'ALTERN8.fnt'))

    $truncated = Join-Path $testRoot 'truncated.fnt'
    [IO.File]::WriteAllBytes($truncated, $canonical[0..($canonical.Length - 20)])
    Invoke-Loader inspect $truncated 'truncated.fnt' 0

    $trailing = Join-Path $testRoot 'trailing.fnt'
    [IO.File]::WriteAllBytes($trailing, $canonical + [byte]0)
    Invoke-Loader inspect $trailing 'trailing.fnt' 0

    $unsupported = [byte[]]$canonical.Clone()
    $unsupported[0] = 2
    $unsupportedPath = Join-Path $testRoot 'unsupported.fnt'
    [IO.File]::WriteAllBytes($unsupportedPath, $unsupported)
    Invoke-Loader inspect $unsupportedPath 'unsupported.fnt' 0

    $badUtf8 = [byte[]]$canonical.Clone()
    $badUtf8[3] = 0xFF
    $badUtf8Path = Join-Path $testRoot 'bad-utf8.fnt'
    [IO.File]::WriteAllBytes($badUtf8Path, $badUtf8)
    Invoke-Loader inspect $badUtf8Path 'bad-utf8.fnt' 0

    $nameLength = [int]$canonical[2]
    $firstGlyph = 2 + 1 + $nameLength + 2
    $duplicate = [byte[]]$canonical.Clone()
    $duplicate[$firstGlyph + 5] = $duplicate[$firstGlyph]
    $duplicatePath = Join-Path $testRoot 'duplicate-glyph.fnt'
    [IO.File]::WriteAllBytes($duplicatePath, $duplicate)
    Invoke-Loader inspect $duplicatePath 'duplicate-glyph.fnt' 0

    $missingRequired = [byte[]]$canonical.Clone()
    $missingRequired[$firstGlyph] = [byte][char]'z'
    $missingRequiredPath = Join-Path $testRoot 'missing-required.fnt'
    [IO.File]::WriteAllBytes($missingRequiredPath, $missingRequired)
    Invoke-Loader inspect $missingRequiredPath 'missing-required.fnt' 0

    $wideGlyph = [byte[]]$canonical.Clone()
    $wideGlyph[$firstGlyph + 1] = 0
    $wideGlyph[$firstGlyph + 2] = 1
    $wideGlyphPath = Join-Path $testRoot 'wide-glyph.fnt'
    [IO.File]::WriteAllBytes($wideGlyphPath, $wideGlyph)
    Invoke-Loader inspect $wideGlyphPath 'wide-glyph.fnt' 0

    $oversized = Join-Path $testRoot 'oversized.fnt'
    $stream = [IO.File]::OpenWrite($oversized)
    try { $stream.SetLength(96KB + 1) } finally { $stream.Dispose() }
    Invoke-Loader inspect $oversized 'oversized.fnt' 0
    Invoke-Loader inspect (Join-Path $source 'ALTERN8.fnt') '../bad.fnt' 0

    Write-Host '[PASS] Runtime DotClk parser, catalog deduplication, limits, and malformed-input rejection passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $resolvedTest) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
