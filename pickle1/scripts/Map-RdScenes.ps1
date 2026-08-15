[CmdletBinding()]
param(
    [string]$IndexPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'external\DotClk-Resources\RD Index.txt'),
    [string]$ScenesDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scenes'),
    [string]$MetadataPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scenes\scene-metadata.json')
)

$ErrorActionPreference = 'Stop'

function ConvertTo-RdGameName([string]$Key) {
    $overrides = @{
        '24' = '24'
        'AC#DC' = 'AC/DC'
        'BALLY_LOGOTYPE' = 'Bally logotype'
        'BRAM_STOKERS_DRACULA' = "Bram Stoker's Dracula"
        'CREATURE_FROM_THE_BLACK_L' = 'Creature from the Black Lagoon'
        'CSI' = 'CSI'
        'INDIANA_JONES' = 'Indiana Jones'
        'IRONMAN' = 'Iron Man'
        'NBA' = 'NBA'
        'NBA_FASTBREAK' = 'NBA Fastbreak'
        'RED_AND_TEDS_ROAD_SHOW' = "Red & Ted's Road Show"
        'SPIDERMAN_VE' = 'Spider-Man Vault Edition'
        'STAR_TREK_THE_NEXT_GEN' = 'Star Trek: The Next Generation'
        'STERN_LOGOTYPE' = 'Stern logotype'
        'TERMINATOR_2' = 'Terminator 2: Judgment Day'
        'THE_GETAWAY_HIGH_SPEED_II' = 'The Getaway: High Speed II'
        'WHO_DUNNIT' = "Who Dunnit"
        'WILLIAMS_LOGOTYPE' = 'Williams logotype'
        'X-MEN' = 'X-Men'
    }
    if ($overrides.ContainsKey($Key)) { return $overrides[$Key] }

    $words = $Key.Replace('_', ' ').ToLowerInvariant()
    return [Globalization.CultureInfo]::GetCultureInfo('en-US').TextInfo.ToTitleCase($words)
}

if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
    throw "RD index not found: $IndexPath"
}
if (-not (Test-Path -LiteralPath $ScenesDirectory -PathType Container)) {
    throw "Scenes directory not found: $ScenesDirectory"
}

$sceneNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
Get-ChildItem -LiteralPath $ScenesDirectory -File -Filter 'RD*.scn' |
    ForEach-Object { [void]$sceneNames.Add($_.Name) }

$mapped = [Collections.Generic.List[object]]::new()
$indexedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$lineNumber = 0
foreach ($line in Get-Content -LiteralPath $IndexPath) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $parts = $line.Split(',', 4)
    if ($parts.Count -ne 4 -or $parts[0] -notmatch '^RD\d{4}$' -or
        $parts[1] -notmatch '^[0-9a-fA-F]{8}$' -or $parts[2] -notmatch '^[0-9a-fA-F]{2}$' -or
        $parts[3] -notmatch '^(?<game>.+)_(?<sequence>\d{3})$') {
        throw "Invalid RD index row $lineNumber`: $line"
    }
    if (-not $indexedIds.Add($parts[0])) { throw "Duplicate RD id at row $lineNumber`: $($parts[0])" }

    $fileName = "$($parts[0]).scn"
    if (-not $sceneNames.Contains($fileName)) { continue }
    $mapped.Add([ordered]@{
        path = $fileName
        title = "Scene $($Matches.sequence)"
        game = ConvertTo-RdGameName $Matches.game
    })
}

$missingFromIndex = @($sceneNames | Where-Object { -not $indexedIds.Contains([IO.Path]::GetFileNameWithoutExtension($_)) })
if ($missingFromIndex.Count -gt 0) {
    throw "RD scene files missing from the index: $($missingFromIndex -join ', ')"
}

$existing = if (Test-Path -LiteralPath $MetadataPath) {
    Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{ schemaVersion = 1; prefixes = @(); files = @() }
}

$existingRdByPath = @{}
foreach ($file in $existing.files) {
    if ($file.path -match '(?i)^RD\d{4}\.scn$') {
        $existingRdByPath[$file.path] = $file
    }
}
foreach ($file in $mapped) {
    if (-not $existingRdByPath.ContainsKey($file.path)) { continue }
    foreach ($property in $existingRdByPath[$file.path].PSObject.Properties) {
        if ($property.Name -notin @('path', 'title', 'game')) {
            $file[$property.Name] = $property.Value
        }
    }
}

$nonRdFiles = @($existing.files | Where-Object { $_.path -notmatch '(?i)^RD\d{4}\.scn$' })
$document = [ordered]@{}
foreach ($property in $existing.PSObject.Properties) {
    if ($property.Name -ne 'files' -and $property.Name -ne 'rdIndexSource' -and
        $property.Name -ne 'rdIndexGameNotes') {
        $document[$property.Name] = $property.Value
    }
}
$document['rdIndexSource'] = 'external/DotClk-Resources/RD Index.txt'
$document['rdIndexGameNotes'] = @(
    [ordered]@{ range = 'RD0081-RD0119'; game = 'Avengers'; note = 'The RD index uses the base game name, and the metadata list intentionally does the same; edition labels are omitted.' }
    [ordered]@{ range = 'RD0122-RD0125'; game = 'Batman'; note = 'The RD index uses the base game name, and the metadata list intentionally does the same; edition labels are omitted.' }
    [ordered]@{ range = 'RD0792-RD0845'; game = 'Indiana Jones'; note = 'The RD index uses the base game name, and the metadata list intentionally does the same; edition labels are omitted.' }
    [ordered]@{ range = 'RD1566-RD1603'; game = 'Star Trek'; note = 'The RD index uses the base game name, and the metadata list intentionally does the same; edition labels are omitted.' }
)
$document['files'] = @($nonRdFiles) + @($mapped)

$parent = Split-Path -Parent $MetadataPath
if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
$json = ($document | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
[IO.File]::WriteAllText([IO.Path]::GetFullPath($MetadataPath), "$json`n", [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
    IndexRows = $indexedIds.Count
    RdSceneFiles = $sceneNames.Count
    MappedFiles = $mapped.Count
    MissingSceneFiles = $indexedIds.Count - $mapped.Count
    PreservedNonRdEntries = $nonRdFiles.Count
    MetadataPath = [IO.Path]::GetFullPath($MetadataPath)
}
