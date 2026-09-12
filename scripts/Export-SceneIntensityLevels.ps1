[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string[]]$Path,
    [switch]$Recurse,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'SceneIntensity.psm1') -Force
$files = @(
    foreach ($entry in $Path) {
        $item = Get-Item -LiteralPath $entry
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -File -Filter '*.scn' -Recurse:$Recurse
        } else { $item }
    }
) | Sort-Object FullName -Unique
if (-not $files) { throw 'No SCN files found.' }
$errorsFound = [Collections.Generic.List[object]]::new()
$completed = 0
$reports = @(
    foreach ($file in $files) {
        Write-Progress -Activity 'Scanning SCN intensity levels' -Status "$completed / $(@($files).Count): $($file.Name)" -PercentComplete (100 * $completed / @($files).Count)
        try { Get-ScnIntensityReport -Path $file.FullName }
        catch {
            $errorsFound.Add([pscustomobject]@{ Path = $file.FullName; Error = $_.Exception.Message })
            Write-Warning "$($file.FullName): $($_.Exception.Message)"
        }
        $completed++
    }
)
Write-Progress -Activity 'Scanning SCN intensity levels' -Completed
$rows = @($reports | Select-Object Path, File, Sha256, FrameCount, LevelCount, NonzeroLevelCount,
    @{Name='UsedValues'; Expression={ $_.UsedValues -join ',' }})
if ($OutputDirectory) {
    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $report = [pscustomobject]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Measurement = 'Raw stored pixels; includes black and masked pixels; excludes row padding; no timing weighting or brightness remapping.'
        Scenes = $reports
        Errors = @($errorsFound.ToArray())
    }
    $report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'scene-intensity-levels.json') -Encoding utf8
    $rows | Export-Csv -LiteralPath (Join-Path $OutputDirectory 'scene-intensity-levels.csv') -NoTypeInformation -Encoding utf8
}
$rows
if ($errorsFound.Count) { throw "$($errorsFound.Count) file(s) failed analysis; see warnings and JSON Errors when exported." }
