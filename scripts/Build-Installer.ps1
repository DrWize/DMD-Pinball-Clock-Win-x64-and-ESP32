[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0',

    [switch]$SkipApplicationBuild,

    [string]$InnoCompiler,

    [ValidateRange(1, 100)]
    [int]$MaxArchivedBuilds = 10
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'output'
$standaloneDirectory = Join-Path $outputRoot 'current\win-x64-standalone'
$installerCurrentDirectory = Join-Path $outputRoot 'current\win-x64-installer'
$archiveRoot = Join-Path $outputRoot 'archive'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stagingDirectory = Join-Path $outputRoot ".installer-staging\$timestamp-win-x64-installer"
$archiveDirectory = Join-Path $archiveRoot "$timestamp-win-x64-installer"
$installerScript = Join-Path $projectRoot 'installer\DMDClock.iss'
$setupFileName = 'DMDClock-win-x64-setup.exe'

function Assert-WithinOutputRoot([string]$Path) {
    $resolvedOutput = [IO.Path]::GetFullPath($outputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith(
        "$resolvedOutput$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside output directory: $resolvedPath"
    }
}

function Resolve-InnoCompiler {
    if (-not [string]::IsNullOrWhiteSpace($InnoCompiler)) {
        if (-not (Test-Path -LiteralPath $InnoCompiler -PathType Leaf)) {
            throw "Inno Setup compiler not found: $InnoCompiler"
        }
        return [IO.Path]::GetFullPath($InnoCompiler)
    }

    $candidates = @(
        $env:DMD_ISCC,
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $resolved = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ($null -eq $resolved) {
        throw @'
Inno Setup compiler was not found. Install the current x64 edition with:
winget install --id JRSoftware.InnoSetup.7 -e -s winget
or set DMD_ISCC to the full path of ISCC.exe.
'@
    }
    return [IO.Path]::GetFullPath($resolved)
}

Assert-WithinOutputRoot $stagingDirectory
Assert-WithinOutputRoot $archiveDirectory
Assert-WithinOutputRoot $installerCurrentDirectory

if (-not $SkipApplicationBuild) {
    & (Join-Path $PSScriptRoot 'Build.ps1') `
        -Configuration $Configuration `
        -Runtime win-x64 `
        -Version $Version `
        -NoStart `
        -MaxArchivedBuilds $MaxArchivedBuilds
    if ($LASTEXITCODE -ne 0) {
        throw "Application build failed with exit code $LASTEXITCODE."
    }
}

$requiredFiles = @(
    'DmdClock.App.exe',
    'DMDClock.scr',
    'README.md',
    'build-info.json',
    'SCN-COMPATIBILITY.txt',
    'SHA256SUMS.txt',
    'i18n\en.json',
    'fonts\Inter\InterVariable.ttf',
    'scenes\scene-metadata.json'
)
foreach ($relativePath in $requiredFiles) {
    $candidate = Join-Path $standaloneDirectory $relativePath
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Standalone installer input is missing: $candidate"
    }
}

$buildInfoPath = Join-Path $standaloneDirectory 'build-info.json'
$buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json
if ($buildInfo.buildId -notmatch '^(?<version>\d+\.\d+\.\d+)') {
    throw "Unable to derive installer version from build ID '$($buildInfo.buildId)'."
}
$appVersion = $Matches.version
$compiler = Resolve-InnoCompiler

New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null

try {
    & $compiler `
        '/Qp' `
        "/DAppVersion=$appVersion" `
        "/DBuildId=$($buildInfo.buildId)" `
        "/DSourceDir=$([IO.Path]::GetFullPath($standaloneDirectory))" `
        "/DProjectRoot=$([IO.Path]::GetFullPath($projectRoot))" `
        "/DOutputDir=$([IO.Path]::GetFullPath($stagingDirectory))" `
        $installerScript
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }

    $setupPath = Join-Path $stagingDirectory $setupFileName
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "Installer compiler did not create $setupPath."
    }

    $setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
    Set-Content -LiteralPath (Join-Path $stagingDirectory 'SHA256SUMS.txt') `
        -Value "$setupHash  $setupFileName" `
        -Encoding ascii

    $compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
    $installerBuildInfo = [ordered]@{
        schemaVersion = 1
        installer = $setupFileName
        installerSha256 = $setupHash
        appVersion = $appVersion
        applicationBuildId = $buildInfo.buildId
        builtAt = (Get-Date).ToString('o')
        configuration = $Configuration
        runtime = 'win-x64'
        installerCompiler = $compiler
        installerCompilerVersion = $compilerVersion
        perUser = $true
        includesStandaloneExe = $true
        includesScreenSaver = $true
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $stagingDirectory 'installer-build-info.json') `
        -Value $installerBuildInfo `
        -Encoding utf8

    if ((Test-Path -LiteralPath $installerCurrentDirectory) -and
        (Get-ChildItem -LiteralPath $installerCurrentDirectory -Force | Select-Object -First 1)) {
        New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
        Get-ChildItem -LiteralPath $installerCurrentDirectory -Force |
            Copy-Item -Destination $archiveDirectory -Recurse -Force
        Write-Host "Archived previous installer package to: $archiveDirectory"
    }

    if (Test-Path -LiteralPath $installerCurrentDirectory) {
        Assert-WithinOutputRoot $installerCurrentDirectory
        Remove-Item -LiteralPath $installerCurrentDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installerCurrentDirectory) | Out-Null
    Move-Item -LiteralPath $stagingDirectory -Destination $installerCurrentDirectory

    Write-Host "Installer available at: $(Join-Path $installerCurrentDirectory $setupFileName)"
    Write-Host "Installer SHA-256: $setupHash"
}
catch {
    Write-Error $_
    throw
}
