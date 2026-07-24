[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Tag,

    [string]$Repository = 'DrWize/DMDClock-Windows-x64',

    [string]$Target = 'master',

    [string]$Title,

    [string]$NotesPath,

    [switch]$Prerelease,

    [switch]$Draft
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$portableDirectory = Join-Path $projectRoot 'output\current\win-x64'
$standaloneDirectory = Join-Path $projectRoot 'output\current\win-x64-standalone'
$installerDirectory = Join-Path $projectRoot 'output\current\win-x64-installer'
$releaseDirectory = Join-Path $projectRoot 'output\current\release'

$portableZip = Join-Path $portableDirectory 'DMDClock-win-x64-portable.zip'
$standaloneZip = Join-Path $standaloneDirectory 'DMDClock-win-x64-standalone.zip'
$installer = Join-Path $installerDirectory 'DMDClock-win-x64-setup.exe'
$installerInfoPath = Join-Path $installerDirectory 'installer-build-info.json'
$portableInfoPath = Join-Path $portableDirectory 'build-info.json'
$standaloneInfoPath = Join-Path $standaloneDirectory 'build-info.json'

function Assert-Command([string]$Name) {
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command was not found: $Name"
    }
}

function Assert-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required release file is missing: $Path"
    }
}

Assert-Command 'git'
Assert-Command 'gh'

Push-Location $projectRoot
try {
    & gh auth status
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run gh auth login first.'
    }

    foreach ($path in @(
        $portableZip,
        $standaloneZip,
        $installer,
        $installerInfoPath,
        $portableInfoPath,
        $standaloneInfoPath
    )) {
        Assert-File $path
    }

    $portableInfo = Get-Content -LiteralPath $portableInfoPath -Raw | ConvertFrom-Json
    $standaloneInfo = Get-Content -LiteralPath $standaloneInfoPath -Raw | ConvertFrom-Json
    $installerInfo = Get-Content -LiteralPath $installerInfoPath -Raw | ConvertFrom-Json

    if ($portableInfo.buildId -ne $standaloneInfo.buildId -or
        $portableInfo.buildId -ne $installerInfo.applicationBuildId) {
        throw @"
Release artifacts do not come from the same application build:
Portable:   $($portableInfo.buildId)
Standalone: $($standaloneInfo.buildId)
Installer:  $($installerInfo.applicationBuildId)
"@
    }
    $actualInstallerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    if ($actualInstallerHash -ne $installerInfo.installerSha256) {
        throw @"
Installer checksum does not match installer-build-info.json:
Recorded: $($installerInfo.installerSha256)
Actual:   $actualInstallerHash
"@
    }

    if ($installerInfo.appVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid installer application version: $($installerInfo.appVersion)"
    }

    if ([string]::IsNullOrWhiteSpace($Tag)) {
        $Tag = "v$($installerInfo.appVersion)"
    }
    if ($Tag -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw "Tag must use a semantic version such as v1.0.0 or v1.1.0-beta.1: $Tag"
    }
    if ([string]::IsNullOrWhiteSpace($Title)) {
        $Title = "DMDClock $Tag"
    }

    $workingChanges = & git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the Git working tree.'
    }
    if ($workingChanges) {
        throw 'The Git working tree is not clean. Commit or restore changes before publishing.'
    }

    & git fetch --prune origin
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to fetch origin.'
    }
    $localCommit = (& git rev-parse HEAD).Trim()
    $targetCommit = (& git rev-parse "origin/$Target").Trim()
    if ($LASTEXITCODE -ne 0 -or $localCommit -ne $targetCommit) {
        throw "HEAD must exactly match origin/$Target before publishing."
    }

    & gh release view $Tag --repo $Repository *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "GitHub Release already exists: $Tag"
    }
    & git ls-remote --exit-code --tags origin "refs/tags/$Tag" *> $null
    if ($LASTEXITCODE -eq 0) {
        throw "Git tag already exists on origin: $Tag"
    }

    if (-not [string]::IsNullOrWhiteSpace($NotesPath)) {
        $NotesPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $NotesPath))
        Assert-File $NotesPath
    }

    $assetPaths = @(
        $installer,
        $portableZip,
        $standaloneZip,
        $installerInfoPath
    )
    $hashLines = foreach ($assetPath in $assetPaths) {
        $hash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash
        "$hash  $(Split-Path -Leaf $assetPath)"
    }

    Write-Host "Repository: $Repository"
    Write-Host "Target:     $Target ($localCommit)"
    Write-Host "Tag:        $Tag"
    Write-Host "Build:      $($portableInfo.buildId)"
    Write-Host "Prerelease: $($Prerelease.IsPresent)"
    Write-Host "Draft:      $($Draft.IsPresent)"
    $hashLines | ForEach-Object { Write-Host $_ }

    if (-not $PSCmdlet.ShouldProcess(
        "$Repository release $Tag",
        'Create tag, upload release assets, and publish GitHub Release')) {
        return
    }

    New-Item -ItemType Directory -Force -Path $releaseDirectory | Out-Null
    $releaseChecksums = Join-Path $releaseDirectory 'SHA256SUMS.txt'
    Set-Content -LiteralPath $releaseChecksums -Value $hashLines -Encoding ascii

    $arguments = @(
        'release', 'create', $Tag,
        $installer,
        $portableZip,
        $standaloneZip,
        $installerInfoPath,
        $releaseChecksums,
        '--repo', $Repository,
        '--target', $Target,
        '--title', $Title
    )
    if ([string]::IsNullOrWhiteSpace($NotesPath)) {
        $arguments += '--generate-notes'
    }
    else {
        $arguments += @('--notes-file', $NotesPath)
    }
    if ($Prerelease) {
        $arguments += '--prerelease'
    }
    if ($Draft) {
        $arguments += '--draft'
    }

    & gh @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub Release creation failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
