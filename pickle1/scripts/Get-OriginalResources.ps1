[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet(
        'All',
        'DotClk',
        'DotClk-Resources',
        'DotClk-Support',
        'ModernHackerspace-DMDClock',
        'Inter')]
    [string[]]$Resource = @('All'),

    [switch]$Update,

    [switch]$Redownload
)

$ErrorActionPreference = 'Stop'

if ($Update -and $Redownload) {
    throw 'Use either -Update or -Redownload, not both.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $projectRoot 'external'
$lockPath = Join-Path $externalRoot 'original-resources-lock.json'
$reportPath = Join-Path $externalRoot 'original-resources-last-update.json'

$catalog = @(
    [pscustomobject]@{
        Name = 'DotClk'
        Url = 'https://github.com/sigmafx/DotClk.git'
        Branch = 'master'
        Purpose = 'Original DotClk firmware and SCN behavior reference'
    }
    [pscustomobject]@{
        Name = 'DotClk-Resources'
        Url = 'https://github.com/sigmafx/DotClk-Resources.git'
        Branch = 'master'
        Purpose = 'Original SCN animations, DotClk fonts, and RD index'
    }
    [pscustomobject]@{
        Name = 'DotClk-Support'
        Url = 'https://github.com/sigmafx/DotClk-Support.git'
        Branch = 'master'
        Purpose = 'Original DotClk font and scene editor reference'
    }
    [pscustomobject]@{
        Name = 'ModernHackerspace-DMDClock'
        Url = 'https://gitlab.com/modernhackerspace/dmdclock.git'
        Branch = 'master'
        Purpose = 'Modern Hackerspace implementation and build instructions'
    }
    [pscustomobject]@{
        Name = 'Inter'
        Url = 'https://github.com/rsms/inter.git'
        Branch = 'master'
        Purpose = 'Upstream source and license reference for the bundled Inter font'
    }
)

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $details = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE.`n$details"
    }

    return $output
}

function Get-NormalizedRemoteUrl {
    param([Parameter(Mandatory)][string]$Url)

    return $Url.Trim().TrimEnd('/').ToLowerInvariant() -replace '\.git$', ''
}

function Assert-ResourcePath {
    param([Parameter(Mandatory)][string]$Path)

    $root = [IO.Path]::GetFullPath($externalRoot).TrimEnd([char[]]@(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar))
    $candidate = [IO.Path]::GetFullPath($Path)
    if (-not $candidate.StartsWith(
        "$root$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a resource outside '$externalRoot': $candidate"
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $temporaryPath = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-RepositoryState {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$Path
    )

    $commit = (Invoke-Git -Arguments @('-C', $Path, 'rev-parse', 'HEAD') |
        Select-Object -Last 1).ToString().Trim()
    $statusLines = @(Invoke-Git -Arguments @(
        '-C', $Path, 'status', '--porcelain', '--untracked-files=all'))
    $fileCount = @(Invoke-Git -Arguments @('-C', $Path, 'ls-files')).Count

    return [ordered]@{
        name = $Definition.Name
        purpose = $Definition.Purpose
        url = $Definition.Url
        branch = $Definition.Branch
        relativePath = "external/$($Definition.Name)"
        commit = $commit
        dirty = $statusLines.Count -gt 0
        trackedFileCount = $fileCount
        recordedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Assert-ExpectedRepository {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        throw "'$Path' exists but is not a Git repository. Move it aside and rerun the script."
    }

    $actualUrl = (Invoke-Git -Arguments @('-C', $Path, 'remote', 'get-url', 'origin') |
        Select-Object -Last 1).ToString().Trim()
    if ((Get-NormalizedRemoteUrl $actualUrl) -ne
        (Get-NormalizedRemoteUrl $Definition.Url)) {
        throw "'$Path' uses unexpected origin '$actualUrl'. Expected '$($Definition.Url)'."
    }
}

function Show-Changes {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Changes = @()
    )

    if ($Changes.Count -eq 0) {
        Write-Host "$Name`: no tracked files changed."
        return
    }

    $counts = [ordered]@{ Added = 0; Modified = 0; Deleted = 0; Renamed = 0; Other = 0 }
    foreach ($change in $Changes) {
        $status = ($change -split "`t", 2)[0]
        switch -Regex ($status) {
            '^A' { $counts.Added++; break }
            '^M' { $counts.Modified++; break }
            '^D' { $counts.Deleted++; break }
            '^R' { $counts.Renamed++; break }
            default { $counts.Other++ }
        }
    }

    Write-Host (
        "$Name changes: +$($counts.Added) ~$($counts.Modified) " +
        "-$($counts.Deleted) renamed=$($counts.Renamed) other=$($counts.Other)")
    $Changes | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
    if ($Changes.Count -gt 20) {
        Write-Host "  ... $($Changes.Count - 20) more; see $reportPath"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git is required. Install Git for Windows and ensure git.exe is available on PATH.'
}

New-Item -ItemType Directory -Force -Path $externalRoot | Out-Null

$selectedNames = if ($Resource -contains 'All') {
    @($catalog.Name)
} else {
    @($Resource | Select-Object -Unique)
}
$selected = @($catalog | Where-Object Name -in $selectedNames)
$missingNames = @($selectedNames | Where-Object { $_ -notin $catalog.Name })
if ($missingNames.Count -gt 0) {
    throw "Unknown resource selection: $($missingNames -join ', ')"
}

$mode = if ($Redownload) { 'redownload' } elseif ($Update) { 'update' } else { 'download-missing' }
$startedAt = (Get-Date).ToUniversalTime()
$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($definition in $selected) {
    $target = Join-Path $externalRoot $definition.Name
    Assert-ResourcePath $target

    try {
        $previousCommit = $null
        $changes = @()
        $action = 'unchanged'

        if (Test-Path -LiteralPath $target) {
            Assert-ExpectedRepository -Definition $definition -Path $target
            $before = Get-RepositoryState -Definition $definition -Path $target
            $previousCommit = $before.commit

            if (($Update -or $Redownload) -and $before.dirty) {
                throw "Local changes exist in '$target'. Commit, stash, or remove them before updating."
            }
        }

        if (-not (Test-Path -LiteralPath $target)) {
            if ($PSCmdlet.ShouldProcess($target, "Clone $($definition.Url)")) {
                Invoke-Git -Arguments @(
                    'clone', '--depth', '1', '--branch', $definition.Branch,
                    '--', $definition.Url, $target) | ForEach-Object { Write-Host $_ }
                $action = 'downloaded'
                $changes = @(Invoke-Git -Arguments @('-C', $target, 'ls-files') |
                    ForEach-Object { "A`t$_" })
            } else {
                $action = 'skipped'
            }
        } elseif ($Redownload) {
            $staging = Join-Path $externalRoot ".$($definition.Name)-download-$([guid]::NewGuid().ToString('N'))"
            $backup = Join-Path $externalRoot ".$($definition.Name)-backup-$([guid]::NewGuid().ToString('N'))"
            Assert-ResourcePath $staging
            Assert-ResourcePath $backup

            if ($PSCmdlet.ShouldProcess($target, "Redownload $($definition.Url)")) {
                try {
                    Invoke-Git -Arguments @(
                        'clone', '--depth', '1', '--branch', $definition.Branch,
                        '--', $definition.Url, $staging) | ForEach-Object { Write-Host $_ }
                    Move-Item -LiteralPath $target -Destination $backup
                    try {
                        Move-Item -LiteralPath $staging -Destination $target
                    } catch {
                        Move-Item -LiteralPath $backup -Destination $target
                        throw
                    }
                    Remove-Item -LiteralPath $backup -Recurse -Force
                    $action = 'redownloaded'
                } finally {
                    if (Test-Path -LiteralPath $staging) {
                        Remove-Item -LiteralPath $staging -Recurse -Force
                    }
                }
            } else {
                $action = 'skipped'
            }
        } elseif ($Update) {
            if ($PSCmdlet.ShouldProcess($target, "Fast-forward $($definition.Branch) from origin")) {
                Invoke-Git -Arguments @(
                    '-C', $target, 'fetch', '--prune', 'origin', $definition.Branch) |
                    ForEach-Object { Write-Host $_ }
                $fetchedCommit = (Invoke-Git -Arguments @('-C', $target, 'rev-parse', 'FETCH_HEAD') |
                    Select-Object -Last 1).ToString().Trim()
                $changes = @(Invoke-Git -Arguments @(
                    '-C', $target, 'diff', '--name-status', $previousCommit, $fetchedCommit, '--'))
                Invoke-Git -Arguments @('-C', $target, 'merge', '--ff-only', 'FETCH_HEAD') |
                    ForEach-Object { Write-Host $_ }
                $action = if ($previousCommit -eq $fetchedCommit) { 'unchanged' } else { 'updated' }
            } else {
                $action = 'skipped'
            }
        }

        if (Test-Path -LiteralPath (Join-Path $target '.git')) {
            $state = Get-RepositoryState -Definition $definition -Path $target
            Show-Changes -Name $definition.Name -Changes $changes
            $results.Add([ordered]@{
                name = $definition.Name
                action = $action
                previousCommit = $previousCommit
                currentCommit = $state.commit
                changes = @($changes)
                state = $state
            })
        } else {
            $results.Add([ordered]@{
                name = $definition.Name
                action = $action
                previousCommit = $previousCommit
                currentCommit = $null
                changes = @()
                state = $null
            })
        }
    } catch {
        $message = "$($definition.Name): $($_.Exception.Message)"
        [Console]::Error.WriteLine("ERROR: $message")
        $failures.Add($message)
        $results.Add([ordered]@{
            name = $definition.Name
            action = 'failed'
            error = $_.Exception.Message
        })
    }
}

$allStates = [System.Collections.Generic.List[object]]::new()
foreach ($definition in $catalog) {
    $target = Join-Path $externalRoot $definition.Name
    if (Test-Path -LiteralPath (Join-Path $target '.git')) {
        try {
            Assert-ExpectedRepository -Definition $definition -Path $target
            $allStates.Add((Get-RepositoryState -Definition $definition -Path $target))
        } catch {
            $allStates.Add([ordered]@{
                name = $definition.Name
                url = $definition.Url
                branch = $definition.Branch
                relativePath = "external/$($definition.Name)"
                error = $_.Exception.Message
            })
        }
    }
}

$completedAt = (Get-Date).ToUniversalTime()
$lock = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = $completedAt.ToString('o')
    resources = @($allStates)
}
$report = [ordered]@{
    schemaVersion = 1
    mode = $mode
    startedAtUtc = $startedAt.ToString('o')
    completedAtUtc = $completedAt.ToString('o')
    success = $failures.Count -eq 0
    selectedResources = @($selectedNames)
    resources = @($results)
}

if ($WhatIfPreference) {
    Write-Host 'Preview complete; reproducibility metadata was not changed.'
    if ($failures.Count -gt 0) {
        throw "$($failures.Count) resource operation(s) failed during preview."
    }
    return
}

Write-AtomicJson -Path $lockPath -Value $lock
Write-AtomicJson -Path $reportPath -Value $report
Write-Host "Resource lock: $lockPath"
Write-Host "Update report: $reportPath"

if ($failures.Count -gt 0) {
    throw "$($failures.Count) resource operation(s) failed. See '$reportPath'."
}
