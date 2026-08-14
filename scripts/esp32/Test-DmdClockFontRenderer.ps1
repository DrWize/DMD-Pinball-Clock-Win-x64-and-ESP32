[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$main = Join-Path $repoRoot 'firmware\dmdclock-esp32\main'
$gcc = 'C:\msys64\mingw64\bin\gcc.exe'
if (-not (Test-Path -LiteralPath $gcc -PathType Leaf)) {
    throw "The host C renderer test requires '$gcc'."
}
$env:Path = (Split-Path -Parent $gcc) + ';' + $env:Path

$testRoot = Join-Path $repoRoot ('output\esp32\font-renderer-test-' + [guid]::NewGuid().ToString('N'))
$exe = Join-Path $testRoot 'dmd-font-renderer-test.exe'
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$cases = @(
    @{ Name='builtin-24-seconds'; Font='builtin-5x7'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='FC47F8CC3CED7E870ADF2AC52D7E23109C9A01A1E344DB2432DDEFB0F368BC25' }
    @{ Name='builtin-24'; Font='builtin-5x7'; Text='23:59'; Scale=3; X=64; Y=16; Hash='ABECE4848BA4C57FF4812D79FCB15ECBEE598DD4C3F6B2EF235B4962B8DD8E2A' }
    @{ Name='builtin-12-seconds'; Font='builtin-5x7'; Text='11:59:58 PM'; Scale=2; X=64; Y=16; Hash='93E4D1B572DEFFB991AC624ACE838117C71070947EB97AC62861CA6DC1A4BE98' }
    @{ Name='builtin-12'; Font='builtin-5x7'; Text='11:59 PM'; Scale=2; X=64; Y=16; Hash='ADEF70163A4B7A491D278886E8EA3A84CCDED93B3A2724914502554AAAB337FF' }
    @{ Name='builtin-compact-clipped'; Font='builtin-5x7'; Text='11:59'; Scale=2; X=20; Y=10; Hash='8B9603CD213E4F33282E9DA100781C255B662A415970A3BD353FA4BF16FCB93F' }
    @{ Name='invalid-id-fallback'; Font='invalid-id'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='FC47F8CC3CED7E870ADF2AC52D7E23109C9A01A1E344DB2432DDEFB0F368BC25' }
    @{ Name='altern8-time'; Font='altern8'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='ED44FBAA9D94C8E7E50BF6024AF5F47690352EC82D2EA418CC80643458BD0C27' }
    @{ Name='altern8-12-hour'; Font='altern8'; Text='11:59:58 PM'; Scale=2; X=64; Y=16; Hash='2EFE00CC367DA06D1EAE00171E81A688EC419F3A2F1C6AA20FC75EA2F1633CD6' }
    @{ Name='altern8-separators'; Font='altern8'; Text='2026-07/23.'; Scale=3; X=64; Y=16; Hash='9E0C6487FE8F1B01D7077F214CCF994C93AB488804EAC7231BFBC1C4606FEF3E' }
    @{ Name='altern8-missing'; Font='altern8'; Text='2?3'; Scale=3; X=64; Y=16; Hash='A4D45B72CA85A8A3C741D40D97C8FD7393B4EBABE6171F2E042C64A9DBC47A26' }
    @{ Name='fishy-time'; Font='fishy'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='5CC14E5C7B87FA3C800EF5A1B677474364A72C2A7FD6045403D8A6010DCF7E00' }
    @{ Name='fishy-12-hour'; Font='fishy'; Text='11:59:58 PM'; Scale=2; X=64; Y=16; Hash='04925F1C0369FCC61B2E69C0AA2763DF2CF347A86B842AB116882390A15975DA' }
    @{ Name='fishy-separators'; Font='fishy'; Text='2026-07/23.'; Scale=3; X=64; Y=16; Hash='309E4004A92D8733F4E2A61F75D182C7BB0B42101181B8A005BDEF274D7C574F' }
    @{ Name='fishy-missing'; Font='fishy'; Text='2?3'; Scale=3; X=64; Y=16; Hash='D7122F5D8B5C4F7FA873D6C77583449E252408E658731FAD5A0A64DE9E49D2E4' }
    @{ Name='trek-time'; Font='trek'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='719E9F585413BEB71E19961E1C78860CE780D69AF919393C36405398EA76425C' }
    @{ Name='trek-12-hour'; Font='trek'; Text='11:59:58 PM'; Scale=2; X=64; Y=16; Hash='48CD334ABAB402A66298E6F2F0D2084AC8DC073E6136A42EA529092725F59E48' }
    @{ Name='trek-separators'; Font='trek'; Text='2026-07/23.'; Scale=3; X=64; Y=16; Hash='52A458B50585E2828BC52684F157E8EBC28A4AB3471E640EB302F14CF59B327F' }
    @{ Name='trek-missing'; Font='trek'; Text='2?3'; Scale=3; X=64; Y=16; Hash='559761392418F286B059C1DBC7971567FA4EB05ABD13EFB3D26653D186A7EA50' }
    @{ Name='twilight-time'; Font='twilight'; Text='23:59:58'; Scale=3; X=64; Y=16; Hash='55D3C75EAE2A583698EF77ECE9FCC8A959FCF3DC22E551EA71E910584DD5E5BC' }
    @{ Name='twilight-12-hour'; Font='twilight'; Text='11:59:58 PM'; Scale=2; X=64; Y=16; Hash='8F06834079449A6181460C464375E71F662D7ACF4A0852704359494F636F6A65' }
    @{ Name='twilight-separators'; Font='twilight'; Text='2026-07/23.'; Scale=3; X=64; Y=16; Hash='CBBA354466DCF5665A44FBFDF7F2B05996761F46AC6345A8AD8C9198919E754F' }
    @{ Name='twilight-missing'; Font='twilight'; Text='2?3'; Scale=3; X=64; Y=16; Hash='A422FC7CF3160A7DD87D4AC7739C2970FBD90D7A549F4AA0720189E981AD8032' }
)

try {
    $compileArguments = @(
        '-std=c11', '-Wall', '-Wextra', '-Werror',
        '-I', $main,
        (Join-Path $main 'dmd_font.c'),
        (Join-Path $main 'generated\dmd_fonts_generated.c'),
        (Join-Path $PSScriptRoot 'Test-DmdClockFontRenderer.c'),
        '-o', $exe
    )
    & $gcc @compileArguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the host C font renderer test.' }

    foreach ($case in $cases) {
        $output = Join-Path $testRoot ($case.Name + '.bin')
        & $exe $case.Font $case.Text $case.Scale $case.X $case.Y $output
        if ($LASTEXITCODE -ne 0) { throw "C renderer failed for '$($case.Name)'." }
        $file = Get-Item -LiteralPath $output
        if ($file.Length -ne 8192) {
            throw "C renderer produced $($file.Length) bytes for '$($case.Name)'; expected 8192."
        }
        $actual = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash
        if ($actual -ne $case.Hash) {
            throw "C renderer parity failed for '$($case.Name)': expected $($case.Hash), got $actual."
        }
    }

    Write-Host "[PASS] Actual C font renderer matched $($cases.Count) desktop intensity+mask goldens." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
