[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [ValidateSet('win-x64', 'linux-arm64', 'linux-arm')]
    [string]$Runtime = 'win-x64',

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '1.0.0',

    [switch]$NoStart,

    [ValidateRange(1, 100)]
    [int]$MaxArchivedBuilds = 10
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $projectRoot 'output'
$currentDirectory = Join-Path $outputRoot "current\$Runtime"
$archiveRoot = Join-Path $outputRoot 'archive'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$buildId = "$Version+$timestamp.$Runtime"
$archiveDirectory = Join-Path $archiveRoot "$timestamp-$Runtime"
$stagingDirectory = Join-Path $outputRoot ".staging\$timestamp-$Runtime"
$portableZipName = "DMDClock-$Runtime-portable.zip"
$stagingZipPath = Join-Path $outputRoot ".staging\$timestamp-$portableZipName"
$standaloneCurrentDirectory = Join-Path $outputRoot "current\$Runtime-standalone"
$standaloneArchiveDirectory = Join-Path $archiveRoot "$timestamp-$Runtime-standalone"
$standaloneStagingDirectory = Join-Path $outputRoot ".staging\$timestamp-$Runtime-standalone"
$standaloneZipName = "DMDClock-$Runtime-standalone.zip"
$standaloneStagingZipPath = Join-Path $outputRoot ".staging\$timestamp-$standaloneZipName"
$projectFile = Join-Path $projectRoot 'src\DmdClock.App\DmdClock.App.csproj'

$localDotnet = Join-Path (Split-Path -Parent $projectRoot) '.tools\dotnet10\dotnet.exe'
$dotnet = if ($env:DMD_DOTNET) {
    $env:DMD_DOTNET
} elseif (Test-Path -LiteralPath $localDotnet) {
    $localDotnet
} else {
    'dotnet'
}

function Assert-WithinOutputRoot([string]$Path) {
    $resolvedOutput = [IO.Path]::GetFullPath($outputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith("$resolvedOutput$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside output directory: $resolvedPath"
    }
}

function Remove-ExpiredBuildArchives {
    if (-not (Test-Path -LiteralPath $archiveRoot)) { return }

    $expired = @(Get-ChildItem -LiteralPath $archiveRoot -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxArchivedBuilds)

    foreach ($directory in $expired) {
        Assert-WithinOutputRoot $directory.FullName
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force
        Write-Host "Removed expired build archive: $($directory.FullName)"
    }
}

function Stop-DmdClockProcesses {
    $targets = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('DmdClock.App.exe', 'DmdClock.Tools.exe', 'DMDClock.scr') -or
        ($_.Name -eq 'dotnet.exe' -and
            ($_.CommandLine -like '*DmdClock.App*' -or $_.CommandLine -like '*DmdClock.Tools*'))
    })

    foreach ($target in $targets) {
        try {
            $process = Get-Process -Id $target.ProcessId -ErrorAction Stop
            $gracefulRequested = $process.MainWindowHandle -ne 0 -and $process.CloseMainWindow()
            if ($gracefulRequested) {
                $null = $process.WaitForExit(3000)
            }
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                $process.WaitForExit()
                Write-Host "Stopped locked DMDClock process: $($target.Name) (PID $($target.ProcessId))"
            } else {
                Write-Host "Closed DMDClock process gracefully: $($target.Name) (PID $($target.ProcessId))"
            }
        }
        catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
            # The process already exited between discovery and shutdown.
        }
    }
}

Assert-WithinOutputRoot $currentDirectory
Assert-WithinOutputRoot $archiveDirectory
Assert-WithinOutputRoot $stagingDirectory
Assert-WithinOutputRoot $stagingZipPath
Assert-WithinOutputRoot $standaloneCurrentDirectory
Assert-WithinOutputRoot $standaloneArchiveDirectory
Assert-WithinOutputRoot $standaloneStagingDirectory
Assert-WithinOutputRoot $standaloneStagingZipPath

Stop-DmdClockProcesses

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stagingDirectory) | Out-Null

try {
    & $dotnet publish $projectFile `
        --configuration $Configuration `
        --runtime $Runtime `
        --self-contained true `
        "-p:InformationalVersion=$buildId" `
        --output $stagingDirectory

    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE."
    }

    $stagingScenes = Join-Path $stagingDirectory 'scenes'
    $currentScenes = Join-Path $currentDirectory 'scenes'
    $projectScenes = Join-Path $projectRoot 'scenes'
    $sceneSource = if ((Test-Path -LiteralPath $currentScenes) -and
        (Get-ChildItem -LiteralPath $currentScenes -File -Recurse -Filter *.scn | Select-Object -First 1)) {
        $currentScenes
    } else {
        $projectScenes
    }
    New-Item -ItemType Directory -Force -Path $stagingScenes | Out-Null
    if (Test-Path -LiteralPath $sceneSource) {
        Get-ChildItem -LiteralPath $sceneSource -Force |
            Copy-Item -Destination $stagingScenes -Recurse -Force
    }
    $currentMetadata = Join-Path $currentScenes 'scene-metadata.json'
    $projectMetadata = Join-Path $projectScenes 'scene-metadata.json'
    $metadataSource = if ((Test-Path -LiteralPath $currentMetadata) -and (Test-Path -LiteralPath $projectMetadata)) {
        $currentInfo = Get-Item -LiteralPath $currentMetadata
        $projectInfo = Get-Item -LiteralPath $projectMetadata
        if ($currentInfo.LastWriteTimeUtc -gt $projectInfo.LastWriteTimeUtc) { $currentMetadata } else { $projectMetadata }
    } elseif (Test-Path -LiteralPath $currentMetadata) {
        $currentMetadata
    } else {
        $projectMetadata
    }
    if (Test-Path -LiteralPath $metadataSource) {
        Copy-Item -LiteralPath $metadataSource -Destination (Join-Path $stagingScenes 'scene-metadata.json') -Force
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stagingScenes 'scene-metadata.json') -PathType Leaf)) {
        throw "Portable publish is missing scenes\scene-metadata.json."
    }

    # Keep fonts added directly to an installed build. Relative paths are preserved so saved font choices remain valid.
    $stagingFonts = Join-Path $stagingDirectory 'fonts'
    $currentFonts = Join-Path $currentDirectory 'fonts'
    if (Test-Path -LiteralPath $currentFonts) {
        Get-ChildItem -LiteralPath $currentFonts -File -Recurse | Where-Object {
            $_.Extension -in @('.ttf', '.otf')
        } | ForEach-Object {
            $relativeFont = [IO.Path]::GetRelativePath($currentFonts, $_.FullName)
            $fontDestination = Join-Path $stagingFonts $relativeFont
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fontDestination) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $fontDestination -Force
        }
    }

    $toolsProject = Join-Path $projectRoot 'tools\DmdClock.Tools\DmdClock.Tools.csproj'
    $compatibilityOutput = & $dotnet run --project $toolsProject `
        --configuration $Configuration -- scan $stagingScenes
    if ($LASTEXITCODE -ne 0) {
        throw "SCN compatibility scan failed with exit code $LASTEXITCODE."
    }
    $compatibilityReport = @(
        'DMDClock SCN compatibility report'
        "Generated: $((Get-Date).ToString('o'))"
        "Source: .\scenes"
        ''
        $compatibilityOutput
    )
    Set-Content -LiteralPath (Join-Path $stagingDirectory 'SCN-COMPATIBILITY.txt') `
        -Value $compatibilityReport -Encoding utf8

    $buildInfo = [ordered]@{
        buildId = $buildId
        builtAt = (Get-Date).ToString('o')
        runtime = $Runtime
        configuration = $Configuration
        selfContained = $true
        screensaver = ($Runtime -eq 'win-x64')
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $stagingDirectory 'build-info.json') `
        -Value $buildInfo -Encoding utf8

    if ($Runtime -eq 'win-x64') {
        Copy-Item -LiteralPath (Join-Path $stagingDirectory 'DmdClock.App.exe') `
            -Destination (Join-Path $stagingDirectory 'DMDClock.scr') -Force

        Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') `
            -Destination (Join-Path $stagingDirectory 'README.md') -Force

        if (Test-Path -LiteralPath $stagingZipPath) {
            Remove-Item -LiteralPath $stagingZipPath -Force
        }
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $stagingDirectory,
            $stagingZipPath,
            [IO.Compression.CompressionLevel]::Optimal,
            $false)
        Write-Host "Created portable ZIP: $stagingZipPath"

        & $dotnet publish $projectFile `
            --configuration $Configuration `
            --runtime $Runtime `
            --self-contained true `
            "-p:InformationalVersion=$buildId" `
            "-p:PublishSingleFile=true" `
            "-p:IncludeNativeLibrariesForSelfExtract=true" `
            "-p:EnableCompressionInSingleFile=true" `
            "-p:PublishTrimmed=false" `
            "-p:DebugSymbols=false" `
            "-p:DebugType=None" `
            --output $standaloneStagingDirectory

        if ($LASTEXITCODE -ne 0) {
            throw "Standalone dotnet publish failed with exit code $LASTEXITCODE."
        }
        if (-not (Test-Path -LiteralPath (
            Join-Path $standaloneStagingDirectory 'scenes\scene-metadata.json') -PathType Leaf)) {
            throw "Standalone publish is missing scenes\scene-metadata.json."
        }

        $standaloneExe = Join-Path $standaloneStagingDirectory 'DmdClock.App.exe'
        $standaloneScr = Join-Path $standaloneStagingDirectory 'DMDClock.scr'
        Copy-Item -LiteralPath $standaloneExe -Destination $standaloneScr -Force
        Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') `
            -Destination (Join-Path $standaloneStagingDirectory 'README.md') -Force
        Copy-Item -LiteralPath (Join-Path $stagingDirectory 'SCN-COMPATIBILITY.txt') `
            -Destination (Join-Path $standaloneStagingDirectory 'SCN-COMPATIBILITY.txt') -Force

        $standaloneBuildInfo = [ordered]@{
            buildId = $buildId
            builtAt = (Get-Date).ToString('o')
            runtime = $Runtime
            configuration = $Configuration
            selfContained = $true
            singleFile = $true
            screensaver = $true
            nativeLibraryMode = 'self-extract'
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $standaloneStagingDirectory 'build-info.json') `
            -Value $standaloneBuildInfo -Encoding utf8

        Get-ChildItem -LiteralPath $standaloneStagingDirectory -File -Recurse -Filter *.pdb |
            Remove-Item -Force

        $unexpectedDlls = @(Get-ChildItem -LiteralPath $standaloneStagingDirectory -File -Recurse -Filter *.dll)
        if ($unexpectedDlls.Count -gt 0) {
            throw "Standalone publish left DLL files: $($unexpectedDlls.FullName -join ', ')"
        }

        $checksumFiles = @('DmdClock.App.exe', 'DMDClock.scr')
        $checksumLines = $checksumFiles | ForEach-Object {
            $hash = (Get-FileHash -LiteralPath (Join-Path $standaloneStagingDirectory $_) -Algorithm SHA256).Hash
            "$hash  $_"
        }
        $checksumPath = Join-Path $standaloneStagingDirectory 'SHA256SUMS.txt'
        Set-Content -LiteralPath $checksumPath `
            -Value $checksumLines -Encoding ascii
        $writtenChecksums = @(Get-Content -LiteralPath $checksumPath)
        foreach ($fileName in $checksumFiles) {
            $expectedLine = $writtenChecksums | Where-Object { $_.EndsWith("  $fileName") }
            $actualHash = (Get-FileHash -LiteralPath (Join-Path $standaloneStagingDirectory $fileName) -Algorithm SHA256).Hash
            if ($expectedLine -ne "$actualHash  $fileName") {
                throw "Standalone checksum verification failed for $fileName."
            }
        }

        if (Test-Path -LiteralPath $standaloneStagingZipPath) {
            Remove-Item -LiteralPath $standaloneStagingZipPath -Force
        }
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $standaloneStagingDirectory,
            $standaloneStagingZipPath,
            [IO.Compression.CompressionLevel]::Optimal,
            $false)
        Write-Host "Created standalone ZIP: $standaloneStagingZipPath"
    }

    if ((Test-Path -LiteralPath $currentDirectory) -and
        (Get-ChildItem -LiteralPath $currentDirectory -Force | Select-Object -First 1)) {
        New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
        Get-ChildItem -LiteralPath $currentDirectory -Force |
            Copy-Item -Destination $archiveDirectory -Recurse -Force

        $archiveManifest = [ordered]@{
            archivedAt = (Get-Date).ToString('o')
            runtime = $Runtime
            configuration = $Configuration
            source = $currentDirectory
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $archiveDirectory 'archive-manifest.json') -Value $archiveManifest -Encoding utf8

        Write-Host "Archived previous build to: $archiveDirectory"
    }

    if ($Runtime -eq 'win-x64' -and
        (Test-Path -LiteralPath $standaloneCurrentDirectory) -and
        (Get-ChildItem -LiteralPath $standaloneCurrentDirectory -Force | Select-Object -First 1)) {
        New-Item -ItemType Directory -Force -Path $standaloneArchiveDirectory | Out-Null
        Get-ChildItem -LiteralPath $standaloneCurrentDirectory -Force |
            Copy-Item -Destination $standaloneArchiveDirectory -Recurse -Force

        $standaloneArchiveManifest = [ordered]@{
            archivedAt = (Get-Date).ToString('o')
            runtime = "$Runtime-standalone"
            configuration = $Configuration
            source = $standaloneCurrentDirectory
        } | ConvertTo-Json
        Set-Content -LiteralPath (Join-Path $standaloneArchiveDirectory 'archive-manifest.json') `
            -Value $standaloneArchiveManifest -Encoding utf8

        Write-Host "Archived previous standalone build to: $standaloneArchiveDirectory"
    }

    Remove-ExpiredBuildArchives

    if (Test-Path -LiteralPath $currentDirectory) {
        Remove-Item -LiteralPath $currentDirectory -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $currentDirectory) | Out-Null
    Move-Item -LiteralPath $stagingDirectory -Destination $currentDirectory

    if ($Runtime -eq 'win-x64') {
        $portableZipPath = Join-Path $currentDirectory $portableZipName
        Move-Item -LiteralPath $stagingZipPath -Destination $portableZipPath
        Write-Host "Portable ZIP available at: $portableZipPath"

        if (Test-Path -LiteralPath $standaloneCurrentDirectory) {
            Remove-Item -LiteralPath $standaloneCurrentDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $standaloneStagingDirectory -Destination $standaloneCurrentDirectory
        $standaloneZipPath = Join-Path $standaloneCurrentDirectory $standaloneZipName
        Move-Item -LiteralPath $standaloneStagingZipPath -Destination $standaloneZipPath
        Write-Host "Standalone build available at: $standaloneCurrentDirectory"
        Write-Host "Standalone ZIP available at: $standaloneZipPath"
    }

    Write-Host "Published new build to: $currentDirectory"

    if ($Runtime -eq 'win-x64' -and -not $NoStart) {
        $publishedExe = Join-Path $currentDirectory 'DmdClock.App.exe'
        $startedProcess = Start-Process -FilePath $publishedExe -WorkingDirectory $currentDirectory -PassThru
        Write-Host "Started new build: $publishedExe (PID $($startedProcess.Id))"
    }
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $stagingZipPath) {
        Remove-Item -LiteralPath $stagingZipPath -Force
    }
    if (Test-Path -LiteralPath $standaloneStagingDirectory) {
        Remove-Item -LiteralPath $standaloneStagingDirectory -Recurse -Force
    }
    if (Test-Path -LiteralPath $standaloneStagingZipPath) {
        Remove-Item -LiteralPath $standaloneStagingZipPath -Force
    }
}
