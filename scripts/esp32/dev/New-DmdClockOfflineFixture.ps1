[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Destination,
    [ValidateSet('Original', 'DmdLarge')]
    [string] $Library = 'DmdLarge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$fontRoot = Join-Path $repoRoot 'assets\fonts\DotClk'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Shared provisioning module not found: $modulePath"
}
Import-Module $modulePath -Force

$packId = if ($Library -eq 'Original') { 'dotclk-original' } else { 'drwize-complete' }
$displayName = if ($Library -eq 'Original') { 'Original DotCLK-Orig (Fixture)' } else { 'DMD-Large (Fixture)' }
$version = '1.0.0-fixture'
$downloadUrl = "https://example.invalid/$packId/$packId-$version.zip"

$layout = New-DmdClockStagingLayout -Destination $Destination -Confirm:$false

$libraryRelative = "SDCard/libraries/$packId/$packId-$version.zip"
$libraryPath = Join-Path $layout.Root ($libraryRelative -replace '/', '\')
[IO.Directory]::CreateDirectory((Split-Path -Parent $libraryPath)) | Out-Null
[IO.File]::WriteAllBytes($libraryPath, [byte[]](0x44, 0x4D, 0x44, 0x43, 0x4C, 0x4F, 0x43, 0x4B))
$libraryItem = Get-Item -LiteralPath $libraryPath
$libraryHash = Get-DmdClockSha256 -Path $libraryPath

$catalog = [ordered]@{
    schema = 'dmdclock-scene-catalog'
    schemaVersion = 1
    packs = @(
        [ordered]@{
            packId = $packId
            displayName = $displayName
            version = $version
            available = $true
            supportedPlatforms = @('esp32-s3')
            downloadUrl = $downloadUrl
            downloadBytes = [long]$libraryItem.Length
            archiveSha256 = $libraryHash
            sceneCount = 5
            sourceRevision = 'fixture'
        }
    )
}

$supportFiles = @(
    @{
        Id = 'sd.catalog'; Relative = 'SDCard/catalog.json'
        Text = ($catalog | ConvertTo-Json -Depth 8)
    }
    @{
        Id = 'sd.scene-metadata'; Relative = 'SDCard/scene-metadata.json'
        Text = '{"fixture":true}'
    }
    @{
        Id = 'sd.template.manifest'; Relative = 'SDCard/template/dmd/manifest.json'
        Text = '{"fixture":true}'
    }
    @{
        Id = 'sd.template.readme'; Relative = 'SDCard/template/dmd/README.md'
        Text = 'DMDClock fixture microSD card template readme.'
    }
)

$artifacts = [Collections.Generic.List[object]]::new()
foreach ($support in $supportFiles) {
    $path = Join-Path $layout.Root ($support.Relative -replace '/', '\')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path, $support.Text, [Text.UTF8Encoding]::new($false))
    $item = Get-Item -LiteralPath $path
    $artifacts.Add([pscustomobject]@{
        artifactId = $support.Id
        kind = 'sd-fixture'
        sourceUrl = "https://example.invalid/$($support.Id)"
        relativePath = $support.Relative
        size = [long]$item.Length
        sha256 = (Get-DmdClockSha256 -Path $path)
        version = $version
        target = 'esp32-s3'
        status = 'downloaded'
    })
}
foreach ($fontName in @('ALTERN8.fnt', 'FISHY.fnt', 'TREK.fnt', 'TWILIGHT.fnt')) {
    $id = 'sd.font.' + [IO.Path]::GetFileNameWithoutExtension($fontName).ToLowerInvariant()
    $relative = "SDCard/fonts/$fontName"
    $path = Join-Path $layout.Root ($relative -replace '/', '\')
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fontRoot $fontName) -Destination $path
    $item = Get-Item -LiteralPath $path
    $artifacts.Add([pscustomobject]@{
        artifactId = $id
        kind = 'sd-font'
        sourceUrl = "https://example.invalid/$id"
        relativePath = $relative
        size = [long]$item.Length
        sha256 = (Get-DmdClockSha256 -Path $path)
        version = $version
        target = 'esp32-s3'
        status = 'downloaded'
    })
}
$artifacts.Add([pscustomobject]@{
    artifactId = "sd.library.$packId"
    kind = 'scene-library'
    sourceUrl = $downloadUrl
    relativePath = $libraryRelative
    size = [long]$libraryItem.Length
    sha256 = $libraryHash
    version = $version
    target = 'esp32-s3'
    status = 'downloaded'
})

$null = Update-DmdClockStagingManifest -StagingRoot $layout.Root `
    -Artifacts @($artifacts) -Confirm:$false

Write-Output $layout.Root
