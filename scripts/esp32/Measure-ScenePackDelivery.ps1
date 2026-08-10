# Measures the current ESP32 ZIP installation in QEMU or compares the same ZIP
# with sequential downloads of every source scene on the host. All generated
# archives, expanded files, CSV samples, and summaries stay under output/.

[CmdletBinding()]
param(
    [ValidateSet('QemuZip', 'HostComparison')]
    [string] $Mode = 'HostComparison',
    [string] $PackId = 'dotclk-original',
    [string] $QemuUrl = 'http://127.0.0.1:8081',
    [string] $OutputRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot 'output\benchmarks\scene-pack-delivery'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $OutputRoot "$stamp-$($Mode.ToLowerInvariant())-$PackId"
New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
$eventLog = Join-Path $runDirectory 'events.log'

function Write-BenchmarkEvent([string] $Message) {
    $line = '{0:o} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $eventLog -Value $line
    Write-Host $line
}

function Write-Summary([hashtable] $Summary) {
    $path = Join-Path $runDirectory 'summary.json'
    $Summary['logPath'] = $eventLog
    $Summary['summaryPath'] = $path
    $Summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    Write-BenchmarkEvent "Summary written to $path"
    $Summary | ConvertTo-Json -Depth 8
}

if ($Mode -eq 'QemuZip') {
    $baseUri = $QemuUrl.TrimEnd('/')
    $csvPath = Join-Path $runDirectory 'qemu-phases.csv'
    'elapsedSeconds,phase,completedBytes,totalBytes,extractedScenes,expectedScenes,message' |
        Set-Content -LiteralPath $csvPath -Encoding utf8
    $body = @{ action = 'repair'; packId = $PackId } | ConvertTo-Json -Compress
    Write-BenchmarkEvent "Starting QEMU ZIP repair at $baseUri for $PackId"
    Invoke-RestMethod "$baseUri/api/scene-pack" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null

    $timer = [Diagnostics.Stopwatch]::StartNew()
    $phaseStarted = 0.0
    $currentPhase = ''
    $phaseResults = [Collections.Generic.List[object]]::new()
    $maxBytes = 0L
    $maxTotalBytes = 0L
    $maxScenes = 0
    $final = $null
    while ($true) {
        try {
            $status = Invoke-RestMethod "$baseUri/api/scene-pack" -TimeoutSec 30
        } catch {
            Write-BenchmarkEvent "Status request failed and will be retried: $($_.Exception.Message)"
            Start-Sleep -Seconds 1
            continue
        }
        $elapsed = $timer.Elapsed.TotalSeconds
        if ($currentPhase -ne [string]$status.phase) {
            if ($currentPhase) {
                $phaseResults.Add([pscustomobject]@{
                    phase = $currentPhase
                    seconds = [Math]::Round($elapsed - $phaseStarted, 3)
                })
            }
            $currentPhase = [string]$status.phase
            $phaseStarted = $elapsed
            Write-BenchmarkEvent "QEMU phase: $currentPhase"
        }
        $maxBytes = [Math]::Max($maxBytes, [long]$status.completedBytes)
        $maxTotalBytes = [Math]::Max($maxTotalBytes, [long]$status.totalBytes)
        $maxScenes = [Math]::Max($maxScenes, [int]$status.extractedScenes)
        $message = ([string]$status.message).Replace('"', '""')
        [string]::Format(
            [Globalization.CultureInfo]::InvariantCulture,
            '{0:F3},{1},{2},{3},{4},{5},"{6}"',
            $elapsed, $status.phase, $status.completedBytes, $status.totalBytes,
            $status.extractedScenes, $status.expectedScenes, $message) |
            Add-Content -LiteralPath $csvPath
        if (-not $status.running) {
            $final = $status
            break
        }
        Start-Sleep -Seconds 1
    }
    $timer.Stop()
    $phaseResults.Add([pscustomobject]@{
        phase = $currentPhase
        seconds = [Math]::Round($timer.Elapsed.TotalSeconds - $phaseStarted, 3)
    })
    $summary = @{
        mode = $Mode
        packId = $PackId
        qemuUrl = $baseUri
        result = [string]$final.phase
        message = [string]$final.message
        totalSeconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
        payloadRequests = 1
        downloadedBytes = if ($maxTotalBytes -gt $maxBytes) { $maxTotalBytes } else { $maxBytes }
        extractedScenes = $maxScenes
        phases = @($phaseResults)
        samplesPath = $csvPath
    }
    Write-Summary $summary
    if ($final.phase -ne 'complete') { exit 1 }
    return
}

$catalogPath = Join-Path $repoRoot 'scenes\catalog.json'
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
$pack = $catalog.packs | Where-Object packId -EQ $PackId
if ($null -eq $pack) { throw "Pack '$PackId' is not present in $catalogPath" }
if ($PackId -ne 'dotclk-original') {
    throw 'HostComparison currently requires dotclk-original because it has a revision-pinned raw source.'
}
if ([string]$pack.sourcePageUrl -notmatch
    '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+)/tree/(?<revision>[^/]+)/(?<folder>.+)$') {
    throw "Could not derive raw source URLs from $($pack.sourcePageUrl)"
}
$rawBase = 'https://raw.githubusercontent.com/{0}/{1}/{2}/{3}/' -f
    $Matches.owner, $Matches.repo, $Matches.revision, $Matches.folder.TrimEnd('/')
$archivePath = Join-Path $runDirectory 'pack.zip'
$zipFiles = Join-Path $runDirectory 'zip-files'
$singleFiles = Join-Path $runDirectory 'single-files'
New-Item -ItemType Directory -Path $zipFiles, $singleFiles | Out-Null

$handler = [Net.Http.HttpClientHandler]::new()
$handler.AutomaticDecompression = [Net.DecompressionMethods]::All
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromMinutes(5)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('DMDClock-scene-pack-benchmark/1.0')

try {
    Write-BenchmarkEvent "Downloading ZIP from $($pack.downloadUrl)"
    $zipTimer = [Diagnostics.Stopwatch]::StartNew()
    $response = $client.GetAsync(
        [string]$pack.downloadUrl,
        [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $response.EnsureSuccessStatusCode() | Out-Null
    $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $target = [IO.File]::Create($archivePath)
    try { $source.CopyTo($target) } finally { $target.Dispose(); $source.Dispose(); $response.Dispose() }
    $zipDownloadSeconds = $zipTimer.Elapsed.TotalSeconds
    $downloadedZipBytes = (Get-Item -LiteralPath $archivePath).Length

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $marker = [string]$pack.scenesPathMarker
        $entries = @($archive.Entries | Where-Object {
            $_.FullName.Contains($marker, [StringComparison]::Ordinal) -and
            $_.Name.EndsWith('.scn', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($entries.Count -ne [int]$pack.sceneCount) {
            throw "ZIP contains $($entries.Count) scenes; expected $($pack.sceneCount)."
        }
        $zipHashes = @{}
        $zipBytes = 0L
        $extractTimer = [Diagnostics.Stopwatch]::StartNew()
        for ($index = 0; $index -lt $entries.Count; $index++) {
            $entry = $entries[$index]
            $destination = Join-Path $zipFiles $entry.Name
            $input = $entry.Open()
            $output = [IO.File]::Create($destination)
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            $zipBytes += (Get-Item -LiteralPath $destination).Length
            $zipHashes[$entry.Name] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ((($index + 1) % 250) -eq 0) {
                Write-BenchmarkEvent "ZIP extracted $($index + 1)/$($entries.Count) scenes"
            }
        }
        $zipExtractSeconds = $extractTimer.Elapsed.TotalSeconds
    } finally {
        $archive.Dispose()
    }

    $singleCsv = Join-Path $runDirectory 'single-files.csv'
    'index,file,bytes,elapsedMilliseconds' | Set-Content -LiteralPath $singleCsv -Encoding utf8
    $singleTimer = [Diagnostics.Stopwatch]::StartNew()
    $singleBytes = 0L
    $mismatches = 0
    for ($index = 0; $index -lt $entries.Count; $index++) {
        $name = $entries[$index].Name
        $url = $rawBase + [Uri]::EscapeDataString($name)
        $fileTimer = [Diagnostics.Stopwatch]::StartNew()
        $bytes = $client.GetByteArrayAsync($url).GetAwaiter().GetResult()
        [IO.File]::WriteAllBytes((Join-Path $singleFiles $name), $bytes)
        $singleBytes += $bytes.Length
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        if ($hash -ne $zipHashes[$name]) { $mismatches++ }
        $escapedName = $name.Replace('"', '""')
        [string]::Format(
            [Globalization.CultureInfo]::InvariantCulture,
            '{0},"{1}",{2},{3:F3}',
            ($index + 1), $escapedName, $bytes.Length,
            $fileTimer.Elapsed.TotalMilliseconds) | Add-Content -LiteralPath $singleCsv
        if ((($index + 1) % 100) -eq 0) {
            Write-BenchmarkEvent "Single-file download $($index + 1)/$($entries.Count) scenes"
        }
    }
    $singleSeconds = $singleTimer.Elapsed.TotalSeconds
    $zipTotalSeconds = $zipDownloadSeconds + $zipExtractSeconds
    $summary = @{
        mode = $Mode
        packId = $PackId
        sceneCount = $entries.Count
        equivalentFiles = ($mismatches -eq 0 -and $singleBytes -eq $zipBytes)
        hashMismatches = $mismatches
        zip = @{
            requests = 1
            transferredBytes = $downloadedZipBytes
            installedBytes = $zipBytes
            downloadSeconds = [Math]::Round($zipDownloadSeconds, 3)
            extractAndHashSeconds = [Math]::Round($zipExtractSeconds, 3)
            totalSeconds = [Math]::Round($zipTotalSeconds, 3)
        }
        singleFiles = @{
            requests = $entries.Count
            transferredBytes = $singleBytes
            totalSeconds = [Math]::Round($singleSeconds, 3)
            samplesPath = $singleCsv
        }
        ratios = @{
            requestCount = [Math]::Round($entries.Count / 1.0, 1)
            transferredBytes = [Math]::Round($singleBytes / [double]$downloadedZipBytes, 2)
            elapsedTime = [Math]::Round($singleSeconds / $zipTotalSeconds, 2)
        }
    }
    Write-Summary $summary
} finally {
    $client.Dispose()
    $handler.Dispose()
}
