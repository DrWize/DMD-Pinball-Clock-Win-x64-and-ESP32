Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$nvsRegionOffset = '0x9000'
$nvsRegionSize = '0x6000'
$esptoolRepository = 'espressif/esptool'
$DmdClockCacheRoot = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::LocalApplicationData)) 'DmdClock'

$script:ProvisioningLogPath = $null
$script:ProvisioningLogStartedUtc = $null
$script:ProvisioningLogOperation = $null
$global:DmdClockOperationResult = $null

function Clear-DmdClockOperationResult {
    [CmdletBinding()]
    param()

    $global:DmdClockOperationResult = $null
}

function Set-DmdClockOperationResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('completed', 'cancelled', 'dry-run', 'failed')]
        [string] $Status,
        [Parameter(Mandatory)][string] $Operation,
        [string] $Detail = ''
    )

    $global:DmdClockOperationResult = [pscustomobject]@{
        PSTypeName = 'DmdClock.OperationResult'
        Status = $Status
        Operation = $Operation
        Detail = $Detail
    }
}

function Get-DmdClockOperationResult {
    [CmdletBinding()]
    param()

    return $global:DmdClockOperationResult
}

function Invoke-DmdClockChildOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Operation,
        [Parameter(Mandatory)][string] $ScriptPath,
        [hashtable] $Arguments = @{}
    )

    Clear-DmdClockOperationResult
    try {
        & $ScriptPath @Arguments | Out-Host
        $childSucceeded = $?
        if (-not $childSucceeded) {
            throw "$Operation failed with exit code $LASTEXITCODE."
        }
    }
    catch {
        if ($null -eq (Get-DmdClockOperationResult)) {
            Set-DmdClockOperationResult -Status failed -Operation $Operation `
                -Detail $_.Exception.Message
        }
        throw
    }

    $result = Get-DmdClockOperationResult
    if ($null -eq $result) {
        throw "$Operation did not report an operation result."
    }
    if ($result.Status -eq 'failed') {
        throw "$Operation failed: $($result.Detail)"
    }
    return $result
}

function Get-DmdClockConfig {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        CacheRoot = $DmdClockCacheRoot
        NvsRegionOffset = $nvsRegionOffset
        NvsRegionSize = $nvsRegionSize
        EsptoolRepository = $esptoolRepository
    }
}

function Get-DmdClockPowerShellPath {
    $process = [Diagnostics.Process]::GetCurrentProcess()
    try {
        return $process.MainModule.FileName
    }
    finally {
        $process.Dispose()
    }
}

function Get-DmdClockNearestExistingPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not (Test-Path -LiteralPath $candidate)) {
        $parent = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            throw "No existing parent was found for '$Path'."
        }
        $candidate = $parent
    }
    return (Get-Item -LiteralPath $candidate -Force).FullName
}

function Get-DmdClockFreeBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $existing = Get-DmdClockNearestExistingPath -Path $Path
    $root = [IO.Path]::GetPathRoot($existing)
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady) {
        throw "The destination drive '$root' is not ready."
    }
    return [long]$drive.AvailableFreeSpace
}

function Get-DmdClockSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Assert-DmdClockPathBelowRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [string] $Description = 'Path'
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith(
        "$fullRoot$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Description resolves outside its required root '$fullRoot': $fullPath"
    }
    return $fullPath
}

function New-DmdClockStagingLayout {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Destination)

    $root = [IO.Path]::GetFullPath($Destination)
    $paths = [ordered]@{
        Root = $root
        Manifest = Join-Path $root 'staging-manifest.json'
        ESP32 = Join-Path $root 'ESP32'
        SDCard = Join-Path $root 'SDCard'
        Tools = Join-Path $root 'Tools'
        Logs = Join-Path $root 'Logs'
    }
    if ($PSCmdlet.ShouldProcess($root, 'Create DMDClock staging layout')) {
        foreach ($path in @($paths.Root, $paths.ESP32, $paths.SDCard, $paths.Tools, $paths.Logs)) {
            [IO.Directory]::CreateDirectory($path) | Out-Null
        }
    }
    return [pscustomobject]$paths
}

function Save-DmdClockStagedDownload {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ArtifactId,
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $StagingRoot,
        [long] $ExpectedBytes = 0,
        [string] $ExpectedSha256,
        [long] $MaximumBytes = 256MB,
        [string] $Kind = 'file',
        [string] $Version = '',
        [string] $Target = ''
    )

    if ($Uri.Scheme -ne 'https') { throw "Refusing non-HTTPS download: $Uri" }
    $destinationPath = Assert-DmdClockPathBelowRoot -Path $Destination -Root $StagingRoot
    if ($ExpectedSha256 -and $ExpectedSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "Invalid expected SHA-256 for '$ArtifactId'."
    }

    $previousInvalid = $false
    $previousUnpinned = $false
    $previousHash = ''
    $previousSize = 0L
    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $destinationPath
        $hash = Get-DmdClockSha256 -Path $destinationPath
        $valid = $item.Length -gt 0 -and $item.Length -le $MaximumBytes -and
            ($ExpectedBytes -le 0 -or $item.Length -eq $ExpectedBytes) -and
            (-not $ExpectedSha256 -or $hash -eq $ExpectedSha256.ToLowerInvariant())
        if ($valid -and ($ExpectedBytes -gt 0 -or $ExpectedSha256)) {
            Write-Host "[REUSED] $ArtifactId" -ForegroundColor Green
            Write-DmdClockProvisioningLog -Event 'artifact-reused' -Detail (
                "id=$ArtifactId url=$($Uri.AbsoluteUri) destination=$destinationPath size=$($item.Length) " +
                "sha256=$hash version=$Version target=$Target")
            return [pscustomobject]@{
                artifactId = $ArtifactId; kind = $Kind; sourceUrl = $Uri.AbsoluteUri
                relativePath = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($StagingRoot), $destinationPath).Replace('\', '/')
                size = [long]$item.Length; sha256 = $hash; version = $Version
                target = $Target; status = 'reused'
            }
        }
        if ($valid) {
            # A mutable support URL has no independently known digest. Refresh
            # it transactionally and compare before deciding reuse/replacement.
            $previousUnpinned = $true
            $previousHash = $hash
            $previousSize = [long]$item.Length
        } else {
            $previousInvalid = $true
            Write-Warning "Replacing invalid staged artifact '$ArtifactId': $destinationPath"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($destinationPath, "Download and verify $ArtifactId from $Uri")) {
        Write-Host "[PLANNED] $ArtifactId -> $destinationPath" -ForegroundColor Yellow
        return [pscustomobject]@{
            artifactId = $ArtifactId; kind = $Kind; sourceUrl = $Uri.AbsoluteUri
            relativePath = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($StagingRoot), $destinationPath).Replace('\', '/')
            size = $ExpectedBytes; sha256 = $(if ($ExpectedSha256) { $ExpectedSha256.ToLowerInvariant() } else { '' })
            version = $Version; target = $Target; status = 'planned'
        }
    }

    [IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath)) | Out-Null
    $temporary = Join-Path (Split-Path -Parent $destinationPath) (
        '.' + [IO.Path]::GetFileName($destinationPath) + '.partial-' + [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $temporary -Headers @{
            'User-Agent' = 'DMDClock-Provisioning'
        }
        $item = Get-Item -LiteralPath $temporary
        if ($item.Length -le 0 -or $item.Length -gt $MaximumBytes) {
            throw "Downloaded size $($item.Length) is outside the accepted range 1-$MaximumBytes bytes for '$ArtifactId'."
        }
        if ($ExpectedBytes -gt 0 -and $item.Length -ne $ExpectedBytes) {
            throw "Downloaded size mismatch for '$ArtifactId': expected $ExpectedBytes; received $($item.Length)."
        }
        $hash = Get-DmdClockSha256 -Path $temporary
        if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToLowerInvariant()) {
            throw "Downloaded SHA-256 mismatch for '$ArtifactId': expected $($ExpectedSha256.ToLowerInvariant()); received $hash."
        }
        if ($previousUnpinned -and $item.Length -eq $previousSize -and
            $hash -eq $previousHash) {
            Write-Host "[REUSED] $ArtifactId" -ForegroundColor Green
            Write-DmdClockProvisioningLog -Event 'artifact-reused' -Detail (
                "id=$ArtifactId refreshed=true url=$($Uri.AbsoluteUri) destination=$destinationPath " +
                "size=$($item.Length) sha256=$hash version=$Version target=$Target")
            return [pscustomobject]@{
                artifactId = $ArtifactId; kind = $Kind; sourceUrl = $Uri.AbsoluteUri
                relativePath = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($StagingRoot), $destinationPath).Replace('\', '/')
                size = [long]$item.Length; sha256 = $hash; version = $Version
                target = $Target; status = 'reused'
            }
        }
        Move-Item -LiteralPath $temporary -Destination $destinationPath -Force
        $status = if ($previousInvalid -or $previousUnpinned) { 'replaced' } else { 'downloaded' }
        Write-Host "[$($status.ToUpperInvariant())] $ArtifactId" -ForegroundColor Green
        Write-DmdClockProvisioningLog -Event "artifact-$status" -Detail (
            "id=$ArtifactId url=$($Uri.AbsoluteUri) destination=$destinationPath size=$($item.Length) " +
            "sha256=$hash version=$Version target=$Target")
        return [pscustomobject]@{
            artifactId = $ArtifactId; kind = $Kind; sourceUrl = $Uri.AbsoluteUri
            relativePath = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($StagingRoot), $destinationPath).Replace('\', '/')
            size = [long]$item.Length; sha256 = $hash; version = $Version
            target = $Target; status = $status
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Update-DmdClockStagingManifest {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $StagingRoot,
        [Parameter(Mandatory)][object[]] $Artifacts
    )

    $root = [IO.Path]::GetFullPath($StagingRoot)
    $manifestPath = Join-Path $root 'staging-manifest.json'
    $all = [ordered]@{}
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        $current = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ([int]$current.schemaVersion -ne 1) {
            throw "Unsupported staging manifest schema '$($current.schemaVersion)'."
        }
        foreach ($artifact in @($current.artifacts)) {
            $all[[string]$artifact.artifactId] = $artifact
        }
    }
    foreach ($artifact in $Artifacts) {
        if ([string]$artifact.status -eq 'planned') { continue }
        $all[[string]$artifact.artifactId] = $artifact
    }
    $document = [ordered]@{
        schema = 'dmdclock-provisioning-staging'
        schemaVersion = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        artifacts = @($all.Values | Sort-Object artifactId)
    } | ConvertTo-Json -Depth 8
    if (-not $PSCmdlet.ShouldProcess($manifestPath, 'Atomically update verified staging inventory')) {
        return $manifestPath
    }
    $temporary = Join-Path $root ('.staging-manifest.partial-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temporary, $document, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $manifestPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
    Write-DmdClockProvisioningLog -Event 'manifest-updated' -Detail "$manifestPath $($all.Count) artifacts"
    return $manifestPath
}

function Test-DmdClockStagingManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string[]] $RequiredArtifactIds
    )

    $root = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).Path
    $manifestPath = Join-Path $root 'staging-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Staging manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.schema -ne 'dmdclock-provisioning-staging' -or
        [int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported or invalid staging manifest: $manifestPath"
    }
    $byId = @{}
    foreach ($artifact in @($manifest.artifacts)) {
        $id = [string]$artifact.artifactId
        if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id)) {
            throw "The staging manifest contains a missing or duplicate artifact id '$id'."
        }
        $byId[$id] = $artifact
    }
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($id in $RequiredArtifactIds) {
        if (-not $byId.ContainsKey($id)) {
            $failures.Add("missing inventory entry '$id'")
            continue
        }
        $artifact = $byId[$id]
        $relative = [string]$artifact.relativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            $failures.Add("unsafe relative path for '$id': '$relative'")
            continue
        }
        try {
            $path = Assert-DmdClockPathBelowRoot -Path (Join-Path $root $relative) -Root $root
        }
        catch {
            $failures.Add("unsafe resolved path for '$id': $($_.Exception.Message)")
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failures.Add("missing file '$id': $path")
            continue
        }
        $item = Get-Item -LiteralPath $path
        if ([long]$artifact.size -le 0 -or $item.Length -ne [long]$artifact.size) {
            $failures.Add("size mismatch '$id': inventory=$($artifact.size), actual=$($item.Length)")
            continue
        }
        if ([string]$artifact.sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            $failures.Add("invalid SHA-256 inventory value for '$id'")
            continue
        }
        $hash = Get-DmdClockSha256 -Path $path
        if ($hash -ne ([string]$artifact.sha256).ToLowerInvariant()) {
            $failures.Add("SHA-256 mismatch '$id': inventory=$($artifact.sha256), actual=$hash")
            continue
        }
        Add-Member -InputObject $artifact -NotePropertyName ResolvedPath -NotePropertyValue $path -Force
    }
    if ($failures.Count -gt 0) {
        throw "Staged source validation failed before hardware access:`n - $($failures -join "`n - ")"
    }
    Write-Host "[OK] Verified staged manifest and $($RequiredArtifactIds.Count) required artifact(s)." -ForegroundColor Green
    return [pscustomobject]@{
        Root = $root
        ManifestPath = $manifestPath
        Manifest = $manifest
        Artifacts = $byId
    }
}

function Test-DmdClockPathAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $existing = Get-DmdClockNearestExistingPath -Path $Path
    $item = Get-Item -LiteralPath $existing -Force
    if (-not $item.PSIsContainer) {
        $existing = Split-Path -Parent $item.FullName
    }

    # This is deliberately an ACL inspection, not a probe file: requirements
    # checking must not change the destination.
    $acl = Get-Acl -LiteralPath $existing
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $allow = $false
    $deny = $false
    foreach ($rule in $acl.Access) {
        $matches = $identity.User -eq $rule.IdentityReference -or
            $principal.IsInRole($rule.IdentityReference)
        if (-not $matches) { continue }
        $rights = [Security.AccessControl.FileSystemRights]$rule.FileSystemRights
        $writes = ($rights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0 -or
            ($rights -band [Security.AccessControl.FileSystemRights]::Modify) -ne 0 -or
            ($rights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne 0
        if (-not $writes) { continue }
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) {
            $deny = $true
        } else {
            $allow = $true
        }
    }
    return $allow -and -not $deny
}

function Test-DmdClockGitHubHttps {
    [CmdletBinding()]
    param()

    try {
        $response = Invoke-WebRequest -Uri 'https://api.github.com/meta' `
            -Method Head -Headers @{
                Accept = 'application/vnd.github+json'
                'User-Agent' = 'DMDClock-Provisioning'
                'X-GitHub-Api-Version' = '2022-11-28'
            } -ConnectionTimeoutSeconds 10 -OperationTimeoutSeconds 20
        return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400
    }
    catch {
        return $false
    }
}

function Test-DmdClockAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-DmdClockRequirementsCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Check', 'Download', 'Offline', 'SdCard', 'Flash', 'Reset')]
        [string] $Operation,
        [Parameter(Mandatory)][string] $DataPath,
        [long] $MinimumFreeBytes = 512MB,
        [string[]] $RequiredCommands = @(),
        [switch] $RequireNetwork,
        [switch] $RequireAdministrator,
        [switch] $ThrowOnFailure
    )

    $checks = [Collections.Generic.List[object]]::new()
    function Add-Check {
        param(
            [string] $Name,
            [bool] $Passed,
            [string] $Detected,
            [string] $Required,
            [string] $Remediation
        )
        $checks.Add([pscustomobject]@{
            Name = $Name
            Passed = $Passed
            Detected = $Detected
            Required = $Required
            Remediation = $Remediation
        })
    }

    $isWindowsHost = $env:OS -eq 'Windows_NT'
    Add-Check 'Operating system' $isWindowsHost ([string]$PSVersionTable.OS) `
        'Windows 11' 'Run this workflow on a Windows 11 x64 computer.'

    $osVersion = [Environment]::OSVersion.Version
    $isWindows11 = $isWindowsHost -and $osVersion.Major -eq 10 -and $osVersion.Build -ge 22000
    Add-Check 'Windows release' $isWindows11 ($osVersion.ToString()) `
        'Windows build 22000 or newer' 'Install a supported Windows 11 update.'

    $isX64 = [Environment]::Is64BitOperatingSystem -and
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq
            [Runtime.InteropServices.Architecture]::X64 -and
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq
            [Runtime.InteropServices.Architecture]::X64
    $architecture = 'OS={0}; Process={1}' -f
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture,
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    Add-Check 'Architecture' $isX64 $architecture 'x64 OS and x64 process' `
        'Install and run the x64 build of PowerShell 7.'

    $pwshPath = Get-DmdClockPowerShellPath
    $isPwsh = $PSVersionTable.PSEdition -eq 'Core' -and
        [IO.Path]::GetFileNameWithoutExtension($pwshPath) -ieq 'pwsh'
    Add-Check 'PowerShell host' $isPwsh `
        "$($PSVersionTable.PSEdition); $pwshPath" 'pwsh (PowerShell Core)' `
        'Open PowerShell 7 by running pwsh.exe, not Windows PowerShell.'

    $versionOk = $PSVersionTable.PSVersion -ge [Version]'7.0'
    Add-Check 'PowerShell version' $versionOk ($PSVersionTable.PSVersion.ToString()) `
        '7.0 or newer' 'Install PowerShell 7 x64 from Microsoft, then rerun with pwsh.'

    foreach ($commandName in $RequiredCommands) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue
        Add-Check "Command $commandName" ($null -ne $command) `
            $(if ($command) { [string]$command.Source } else { 'not found' }) `
            'available in this PowerShell session' `
            "Repair PowerShell or Windows so '$commandName' is available; nothing is installed automatically."
    }

    try {
        $existing = Get-DmdClockNearestExistingPath -Path $DataPath
        $writable = Test-DmdClockPathAccess -Path $DataPath
        Add-Check 'Destination access' $writable $existing 'writable by the current user' `
            'Choose a writable folder owned by the current user or correct its permissions manually.'
    }
    catch {
        Add-Check 'Destination access' $false $_.Exception.Message 'existing writable parent' `
            'Choose a destination with an existing writable parent directory.'
    }

    try {
        $free = Get-DmdClockFreeBytes -Path $DataPath
        Add-Check 'Free disk space' ($free -ge $MinimumFreeBytes) "$free bytes" `
            "$MinimumFreeBytes bytes" 'Free disk space or choose another destination.'
    }
    catch {
        Add-Check 'Free disk space' $false $_.Exception.Message "$MinimumFreeBytes bytes" `
            'Choose a ready local drive with sufficient free space.'
    }

    if ($RequireNetwork) {
        $githubOk = Test-DmdClockGitHubHttps
        Add-Check 'GitHub HTTPS' $githubOk $(if ($githubOk) { 'reachable' } else { 'unreachable' }) `
            'TLS/HTTPS access to api.github.com' `
            'Check internet, proxy, firewall, TLS inspection, and GitHub availability; then retry.'
    }

    if ($RequireAdministrator) {
        $isAdministrator = Test-DmdClockAdministrator
        Add-Check 'Administrator' $isAdministrator $(if ($isAdministrator) { 'elevated' } else { 'not elevated' }) `
            'elevated session for disk partitioning/formatting only' `
            'Close this session and open PowerShell 7 with Run as administrator only for the microSD erase/format stage.'
    }

    $failed = @($checks | Where-Object { -not $_.Passed })
    $result = [pscustomobject]@{
        Operation = $Operation
        Passed = $failed.Count -eq 0
        Checks = @($checks)
    }

    Write-Host ''
    if ($result.Passed) {
        Write-Host "DMDClock requirements: $Operation - all $($checks.Count) checks passed" `
            -ForegroundColor Green
    } else {
        Write-Host "DMDClock requirements: $Operation - $($failed.Count) of $($checks.Count) checks failed" `
            -ForegroundColor Red
        foreach ($check in $failed) {
            Write-Host "[FAIL] $($check.Name): $($check.Detected)" -ForegroundColor Red
            Write-Host "       Required: $($check.Required)"
            Write-Host "       Fix: $($check.Remediation)"
        }
    }

    if ($ThrowOnFailure -and -not $result.Passed) {
        throw "Requirements check failed for '$Operation' ($($failed.Count) failed check(s))."
    }
    return $result
}

function Start-DmdClockProvisioningLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LogDirectory,
        [Parameter(Mandatory)][string] $Operation
    )

    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($LogDirectory)) | Out-Null
    $safeOperation = $Operation -replace '[^0-9A-Za-z._-]', '_'
    $name = '{0}-{1}-{2}.log' -f (
        (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')),
        $safeOperation,
        [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:ProvisioningLogPath = Join-Path ([IO.Path]::GetFullPath($LogDirectory)) $name
    $script:ProvisioningLogStartedUtc = (Get-Date).ToUniversalTime()
    $script:ProvisioningLogOperation = $Operation
    $header = @(
        "timestamp=$($script:ProvisioningLogStartedUtc.ToString('o'))",
        "operation=$Operation",
        "run_id=$([Guid]::NewGuid().ToString('D'))",
        "powershell=$($PSVersionTable.PSVersion)",
        "psedition=$($PSVersionTable.PSEdition)",
        "process=$(Get-DmdClockPowerShellPath)",
        "windows=$($PSVersionTable.OS)",
        "os_architecture=$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)",
        "process_architecture=$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)",
        "administrator=$(Test-DmdClockAdministrator)"
    )
    [IO.File]::WriteAllLines($script:ProvisioningLogPath, $header, [Text.UTF8Encoding]::new($false))
    return $script:ProvisioningLogPath
}

function Write-DmdClockProvisioningLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Event,
        [string] $Detail = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:ProvisioningLogPath)) { return }
    $safeDetail = $Detail -replace `
        '(?i)\b(authorization|bearer|token|password|passwd|secret|wifi_password|wifiPassword)\b\s*[=:]\s*\S+', `
        '$1=[REDACTED]'
    $safeDetail = $safeDetail -replace '(?i)\bbearer\s+\S+', 'Bearer [REDACTED]'
    $safeDetail = $safeDetail -replace '(?i)(https?://[^\s?#]+)\?\S+', '$1?[REDACTED]'
    $line = "{0}`tevent={1}`tdetail={2}" -f (
        (Get-Date).ToUniversalTime().ToString('o')),
        ($Event -replace '[\r\n\t]', ' '),
        ($safeDetail -replace '[\r\n\t]', ' ')
    [IO.File]::AppendAllText(
        $script:ProvisioningLogPath,
        $line + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
}

function Write-DmdClockRequirementsLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Requirements)

    foreach ($check in @($Requirements.Checks)) {
        $status = if ($check.Passed) { 'passed' } else { 'failed' }
        Write-DmdClockProvisioningLog -Event 'requirement' -Detail (
            "name=$($check.Name) status=$status detected=$($check.Detected) " +
            "required=$($check.Required) remediation=$($check.Remediation)")
    }
}

function Complete-DmdClockProvisioningLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('completed', 'cancelled', 'failed')]
        [string] $Outcome,
        [string] $Detail = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:ProvisioningLogPath)) { return }
    $durationMs = if ($null -eq $script:ProvisioningLogStartedUtc) {
        0
    } else {
        [Math]::Round(((Get-Date).ToUniversalTime() - $script:ProvisioningLogStartedUtc).TotalMilliseconds)
    }
    Write-DmdClockProvisioningLog -Event 'run-finished' -Detail (
        "outcome=$Outcome operation=$($script:ProvisioningLogOperation) " +
        "duration_ms=$durationMs $Detail")
}

function Complete-DmdClockProvisioningLogSafely {
    [CmdletBinding()]
    param(
        [string] $LogPath,
        [Parameter(Mandatory)][ValidateSet('completed', 'cancelled', 'failed')]
        [string] $Outcome,
        [string] $Detail = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    if ($Outcome -eq 'failed') {
        try {
            Complete-DmdClockProvisioningLog -Outcome $Outcome -Detail $Detail
        }
        catch {
            Write-Warning "Could not finalize the failed provisioning log: $($_.Exception.Message)"
        }
    } else {
        Complete-DmdClockProvisioningLog -Outcome $Outcome -Detail $Detail
    }
}

function Get-DmdClockProvisioningLogPath {
    [CmdletBinding()]
    param()
    return $script:ProvisioningLogPath
}

function New-DmdClockWizard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Title,
        [object[]] $Devices = $null
    )

    return [pscustomobject]@{
        Title = $Title
        Selections = [Collections.Generic.List[object]]::new()
        Devices = if ($Devices) { @($Devices) } else { $null }
    }
}

function Add-DmdClockWizardSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Wizard,
        [Parameter(Mandatory)][string] $Label,
        [Parameter(Mandatory)][string] $Value
    )

    $Wizard.Selections.Add([pscustomobject]@{
        Label = $Label
        Value = $Value
    })
}

function Show-DmdClockWizardHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Wizard)

    try {
        Clear-Host
    }
    catch {
        [void]$_
    }
    $width = 78
    $bar = ('=' * $width)
    Write-Host ''
    Write-Host ("  {0}" -f $Wizard.Title) -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor DarkGray
    if ($Wizard.Selections.Count -eq 0) {
        Write-Host '  (no choices made yet)' -ForegroundColor DarkGray
    } else {
        foreach ($selection in @($Wizard.Selections)) {
            Write-Host ("  {0,-22} {1}" -f ($selection.Label + ':'), $selection.Value)
        }
    }
    if ($Wizard.Devices) {
        Write-Host ''
        Write-Host '  Detected serial devices:' -ForegroundColor Cyan
        Write-Host ('  {0,-3} {1,-6} {2,-18} {3,-7} {4,-30} {5}' -f '#', 'COM', 'Model', 'App', 'Signals', 'Status') -ForegroundColor DarkGray
        $index = 0
        foreach ($device in @($Wizard.Devices)) {
            $index++
            $color = if ($device.Identified) { 'Green' } else { 'Yellow' }
            Write-Host ('  {0,-3} {1,-6} {2,-18} {3,-7} {4,-30} {5}' -f
                "[$index]", $device.Port, $device.Model, $device.App, $device.Signals, $device.Status) -ForegroundColor $color
        }
        Write-Host ("  {0,-3}" -f "[$($Wizard.Devices.Count + 1)] Exit") -ForegroundColor DarkGray
        Write-Host '  Chip model and the required 16 MB flash are verified on the selected port before flashing.' -ForegroundColor DarkGray
    }
    Write-Host $bar -ForegroundColor DarkGray
    Write-Host ''
}

function Read-DmdClockMenuChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][int] $Minimum,
        [Parameter(Mandatory)][int] $Maximum,
        [int] $Default = 0,
        [Parameter()] $Wizard = $null,
        [string] $RequiredParameter = 'the required command-line parameter',
        [switch] $AllowRetryOnRedirectedInput
    )

    while ($true) {
        if ($null -ne $Wizard) {
            Show-DmdClockWizardHeader -Wizard $Wizard
        }
        $defaultText = if ($Default -ge $Minimum -and $Default -le $Maximum) {
            " [$Default]"
        } else {
            ''
        }
        $rawAnswer = Read-Host "$Prompt$defaultText"
        if ($null -eq $rawAnswer) {
            throw "Input ended before '$Prompt' was selected. Provide $RequiredParameter when input is redirected."
        }
        $answer = $rawAnswer.Trim()
        if ([string]::IsNullOrWhiteSpace($answer) -and $defaultText) {
            return $Default
        }
        $choice = 0
        if ([int]::TryParse($answer, [ref]$choice) -and
            $choice -ge $Minimum -and $choice -le $Maximum) {
            return $choice
        }
        if ([Console]::IsInputRedirected -and -not $AllowRetryOnRedirectedInput) {
            throw "No valid selection was supplied for '$Prompt'. Provide $RequiredParameter when input is redirected."
        }
        Write-Warning "Enter a number from $Minimum to $Maximum."
    }
}

function Get-DmdClockHardwareTargets {
    [CmdletBinding()]
    param()

    return @(
        [pscustomobject]@{
            Key = 'Waveshare7'
            Id = 'waveshare-esp32-s3-touch-lcd-7-800x480-n16r8'
            Product = 'Waveshare ESP32-S3-Touch-LCD-7'
            ShortLabel = 'Waveshare 7'
            Display = '800x480'
            Module = 'ESP32-S3-WROOM-1-N16R8'
            Confirmation = '7'
            UnsupportedConfirmation = '7B'
            RequiredFirmwareRevision = $null
            SupportedBoard = '7'
            TouchEnabled = $true
            TouchController = 'GT911'
            Accelerometer = $null
            Homepage = 'https://www.waveshare.com/esp32-s3-touch-lcd-7.htm'
            Documentation = 'https://www.waveshare.com/wiki/ESP32-S3-Touch-LCD-7'
            Driver = 'https://www.wch-ic.com/downloads/CH343SER_EXE.html'
            PortInstructions = @(
                'Use a data-capable USB cable.',
                'Connect it to the USB TO UART Type-C port.',
                'Do not assume that every USB or power connector supports UART.'
            )
        },
        [pscustomobject]@{
            Key = 'Waveshare349B'
            Id = 'waveshare-esp32-s3-touch-lcd-3-49b-v2-640x172-n16r8'
            Product = 'Waveshare ESP32-S3-Touch-LCD-3.49B'
            ShortLabel = 'Waveshare 3.49B'
            Display = '640x172'
            Module = 'ESP32-S3-WROOM-1-N16R8'
            Confirmation = '3.49B'
            UnsupportedConfirmation = $null
            RequiredFirmwareRevision = 'V2'
            SupportedBoard = '3.49B V2 / Rev1.1'
            TouchEnabled = $true
            TouchController = 'AXS15231B'
            Accelerometer = 'QMI8658'
            Homepage = 'https://www.waveshare.com/esp32-s3-touch-lcd-3.49.htm'
            Documentation = 'https://docs.waveshare.com/ESP32-S3-Touch-LCD-3.49'
            Driver = $null
            PortInstructions = @(
                'Use a data-capable USB cable.',
                'Use the Type-C connector identified by Waveshare for program flashing and log output.',
                'Check the official interface diagram; not every connector provides a flashing UART.'
            )
        }
    )
}

function Resolve-DmdClockDeviceFromProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Probe)

    $targets = @(Get-DmdClockHardwareTargets)
    $scores = @{}
    foreach ($target in $targets) {
        $scores[$target.Key] = 0
        if ($Probe.Resolution -and $Probe.Resolution -eq $target.Display) {
            $scores[$target.Key]++
        }
        if ($Probe.TouchController -and $Probe.TouchController -eq $target.TouchController) {
            $scores[$target.Key]++
        }
        if ($Probe.Accelerometer -and $Probe.Accelerometer -eq $target.Accelerometer) {
            $scores[$target.Key]++
        }
    }
    $best = $null
    $bestScore = 0
    $tied = $false
    foreach ($key in $scores.Keys) {
        if ($scores[$key] -gt $bestScore) {
            $best = $key
            $bestScore = $scores[$key]
            $tied = $false
        } elseif ($scores[$key] -eq $bestScore -and $scores[$key] -gt 0) {
            $tied = $true
        }
    }
    if ($bestScore -eq 0 -or $tied) {
        return $null
    }
    return ($targets | Where-Object Key -eq $best | Select-Object -First 1)
}

function Get-DmdClockCacheLocations {
    [CmdletBinding()]
    param()

    $root = $DmdClockCacheRoot
    return [pscustomobject]@{
        Root = $root
        Firmware = Join-Path $root 'cache\firmware'
        Tools = Join-Path $root 'tools\esptool'
        SceneLibraries = Join-Path $root 'cache\scene-libraries'
        Logs = Join-Path $root 'Logs\Provisioning'
    }
}

function Read-DmdClockHighlightedConfirmation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $Suffix,
        [string] $RequiredParameter = 'the required confirmation parameter',
        [ConsoleColor] $Color = [ConsoleColor]::Yellow
    )

    Write-Host $Prefix -NoNewline
    Write-Host $Token -ForegroundColor $Color -NoNewline
    Write-Host ($Suffix + ': ') -NoNewline
    $answer = Read-Host
    if ($null -eq $answer -or
        ([Console]::IsInputRedirected -and [string]::IsNullOrWhiteSpace($answer))) {
        throw "Confirmation input was not supplied. Pass $RequiredParameter when input is redirected."
    }
    return $answer.Trim()
}

function Get-DmdClockGitHubHeaders {
    [CmdletBinding()]
    param(
        [string] $UserAgent = 'DMDClock-Provisioning'
    )

    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = $UserAgent
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($env:GITHUB_TOKEN) {
        $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
    }
    return $headers
}

function Save-DmdClockRemoteFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][long] $MaximumBytes,
        [hashtable] $Headers = @{},
        [ValidateRange(1, 10)][int] $MaximumAttempts = 3,
        [ValidateRange(0, 60)][int] $RetryDelaySeconds = 2
    )

    if ($Uri.Scheme -ne 'https') {
        throw "Refusing non-HTTPS download: $Uri"
    }
    if ($Uri.Host -notin @(
        'github.com',
        'api.github.com',
        'objects.githubusercontent.com',
        'raw.githubusercontent.com'
    )) {
        throw "Refusing download from an unexpected host: $($Uri.Host)"
    }

    $fullHeaders = Get-DmdClockGitHubHeaders
    foreach ($key in $Headers.Keys) {
        $fullHeaders[$key] = $Headers[$key]
    }

    $temporary = "$Destination.partial-$([Guid]::NewGuid().ToString('N'))"
    Write-DmdClockProvisioningLog -Event 'download-started' -Detail (
        "url=$($Uri.AbsoluteUri) destination=$Destination maximum_bytes=$MaximumBytes")
    try {
        for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Uri -Headers $fullHeaders -OutFile $temporary `
                    -UseBasicParsing
                break
            }
            catch {
                $downloadError = $_
                $statusCode = $null
                $statusProperty = $downloadError.Exception.PSObject.Properties['StatusCode']
                $responseProperty = $downloadError.Exception.PSObject.Properties['Response']
                if ($null -ne $statusProperty -and $null -ne $statusProperty.Value) {
                    $statusCode = [int]$statusProperty.Value
                } elseif ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                    $responseStatusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
                    if ($null -ne $responseStatusProperty -and
                        $null -ne $responseStatusProperty.Value) {
                        $statusCode = [int]$responseStatusProperty.Value
                    }
                }
                $retryableStatusCodes = @(408, 429, 500, 502, 503, 504)
                $isTransient = ($null -eq $statusCode -or $statusCode -in $retryableStatusCodes)
                Write-DmdClockProvisioningLog -Event 'download-attempt-failed' -Detail (
                    "url=$($Uri.AbsoluteUri) attempt=$attempt maximum_attempts=$MaximumAttempts " +
                    "status=$statusCode error=$($downloadError.Exception.Message)")
                if (-not $isTransient -or $attempt -ge $MaximumAttempts) {
                    throw
                }
                if (Test-Path -LiteralPath $temporary) {
                    Remove-Item -LiteralPath $temporary -Force
                }
                $delay = [Math]::Min(30, $RetryDelaySeconds * [Math]::Pow(2, $attempt - 1))
                $reason = if ($null -ne $statusCode) {
                    "HTTP $statusCode"
                } else {
                    $downloadError.Exception.Message
                }
                Write-Warning (
                    "Download attempt $attempt of $MaximumAttempts failed ($reason). " +
                    "Retrying in $delay second(s)...")
                if ($delay -gt 0) {
                    Start-Sleep -Seconds $delay
                }
            }
        }
        $size = (Get-Item -LiteralPath $temporary).Length
        if ($size -le 0 -or $size -gt $MaximumBytes) {
            throw "Downloaded file size $size is outside the accepted range 1-$MaximumBytes bytes."
        }
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
        $hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-DmdClockProvisioningLog -Event 'download-completed' -Detail (
            "url=$($Uri.AbsoluteUri) destination=$Destination size=$size sha256=$hash")
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-DmdClockSafeRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)' -or
        $RelativePath.Contains(':')) {
        throw "Unsafe package path: '$RelativePath'."
    }
}

function Assert-DmdClockSha256Hash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedHash
    )

    if ($ExpectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "Invalid SHA-256 value for '$Path'."
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ne $ExpectedHash) {
        throw "SHA-256 verification failed for '$Path'. Expected $ExpectedHash, found $actual."
    }
}

function Expand-DmdClockSafeArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $Destination,
        [Parameter(Mandatory)][string] $ContainmentRoot
    )

    $staging = "$Destination.staging-$([Guid]::NewGuid().ToString('N'))"
    $resolvedDest = [IO.Path]::GetFullPath($Destination)
    $resolvedStaging = [IO.Path]::GetFullPath($staging)
    $resolvedRoot = [IO.Path]::GetFullPath($ContainmentRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    foreach ($p in @($resolvedDest, $resolvedStaging)) {
        if (-not $p.StartsWith("$resolvedRoot$([IO.Path]::DirectorySeparatorChar)",
            [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing operation outside '$resolvedRoot': $p"
        }
    }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $archive.Entries) {
                if ([string]::IsNullOrEmpty($entry.FullName)) { continue }
                Assert-DmdClockSafeRelativePath -RelativePath $entry.FullName
                $entryDestination = [IO.Path]::GetFullPath((Join-Path $staging $entry.FullName))
                if (-not $entryDestination.StartsWith("$resolvedStaging$([IO.Path]::DirectorySeparatorChar)",
                    [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Unsafe archive entry: $($entry.FullName)"
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $staging)
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
        }
        Move-Item -LiteralPath $staging -Destination $Destination
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

function Get-DmdClockConnectedPorts {
    [CmdletBinding()]
    param()

    $found = @{}
    Get-CimInstance Win32_SerialPort -ErrorAction SilentlyContinue | ForEach-Object {
        $found[$_.DeviceID] = [pscustomobject]@{
            Port = [string]$_.DeviceID
            Name = [string]$_.Name
            InstanceId = [string]$_.PNPDeviceID
            Manufacturer = ''
            Service = ''
            Status = [string]$_.Status
        }
    }
    Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '\((COM\d+)\)') {
            $found[$Matches[1]] = [pscustomobject]@{
                Port = [string]$Matches[1]
                Name = [string]$_.Name
                InstanceId = [string]$_.PNPDeviceID
                Manufacturer = [string]$_.Manufacturer
                Service = [string]$_.Service
                Status = [string]$_.Status
            }
        }
    }
    $serialMap = Get-ItemProperty -Path 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction SilentlyContinue
    if ($null -ne $serialMap) {
        $serialMap.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS' -and $_.Value -match '^COM\d+$'
        } | ForEach-Object {
            if (-not $found.ContainsKey([string]$_.Value)) {
                $found[[string]$_.Value] = [pscustomobject]@{
                    Port = [string]$_.Value
                    Name = [string]$_.Name
                    InstanceId = ''
                    Manufacturer = ''
                    Service = ''
                    Status = ''
                }
            }
        }
    }
    return @($found.Values | Sort-Object { [int]($_.Port -replace '^COM', '') })
}

function Select-DmdClockSerialPort {
    [CmdletBinding()]
    param(
        [string] $Port,
        [string] $QuickPort,
        $WizardState,
        [string] $Context = 'flashing'
    )

    $ports = @(Get-DmdClockConnectedPorts)
    if ($QuickPort) {
        $identity = @($ports | Where-Object Port -eq $QuickPort) | Select-Object -First 1
        if ($null -ne $identity) {
            if ([string]::IsNullOrWhiteSpace($identity.InstanceId)) {
                throw "Serial port '$QuickPort' has no Windows PnP instance identity; refusing an identity-weak selection."
            }
            Write-Host "Using detected device on $QuickPort ($($identity.Name))." -ForegroundColor Green
            return [pscustomobject]@{ Port = $QuickPort; Identity = $identity }
        }
        Write-Warning "The detected device on $QuickPort is no longer connected; choose the port manually."
    }
    if ($Port) {
        if ($Port -notin @($ports.Port)) {
            $available = if ($ports.Count) { $ports.Port -join ', ' } else { 'none' }
            throw "Serial port '$Port' is not connected. Available ports: $available."
        }
        $identity = @($ports | Where-Object Port -eq $Port)[0]
        if ([string]::IsNullOrWhiteSpace($identity.InstanceId)) {
            throw "Serial port '$Port' has no Windows PnP instance identity; refusing an identity-weak selection."
        }
        return [pscustomobject]@{ Port = $Port; Identity = $identity }
    }
    if ($ports.Count -eq 0) {
        throw 'No serial port was detected.'
    }
    if ($null -ne $WizardState) {
        Show-DmdClockWizardHeader -Wizard $WizardState
    }
    Write-Host ''
    Write-Host 'Connected serial ports:'
    for ($index = 0; $index -lt $ports.Count; $index++) {
        Write-Host ("  [{0}] {1,-7} {2}" -f ($index + 1), $ports[$index].Port, $ports[$index].Name)
    }
    $choice = Read-DmdClockMenuChoice -Prompt "Select the ESP32 port ($Context)" -Minimum 1 -Maximum $ports.Count `
        -Default $(if ($ports.Count -eq 1) { 1 } else { 0 }) -RequiredParameter '-Port'
    $identity = $ports[$choice - 1]
    if ([string]::IsNullOrWhiteSpace($identity.InstanceId)) {
        throw "Serial port '$($identity.Port)' has no Windows PnP instance identity; refusing an identity-weak selection."
    }
    if ($null -ne $WizardState) {
        Add-DmdClockWizardSelection -Wizard $WizardState -Label 'Serial port' -Value $identity.Port
    }
    return [pscustomobject]@{ Port = $identity.Port; Identity = $identity }
}

function Assert-DmdClockSerialPortUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SelectedPort,
        [Parameter(Mandatory)] $PortIdentity,
        [string] $Context = 'flashing'
    )

    $matches = @(Get-DmdClockConnectedPorts | Where-Object Port -eq $SelectedPort)
    if ($matches.Count -ne 1) {
        throw "Serial port '$SelectedPort' disappeared or became ambiguous before $Context."
    }
    $current = $matches[0]
    if ([string]::IsNullOrWhiteSpace($current.InstanceId) -or
        [string]$current.InstanceId -cne [string]$PortIdentity.InstanceId -or
        [string]$current.Name -cne [string]$PortIdentity.Name) {
        throw "The Windows PnP device on '$SelectedPort' changed before $Context. Disconnect other serial devices and restart selection."
    }
    Write-Host "[OK] Revalidated $SelectedPort PnP identity: $($current.Name)" -ForegroundColor Green
}

function Get-DmdClockCachedEsptool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ToolCacheRoot
    )

    $cached = @(Get-ChildItem -LiteralPath $ToolCacheRoot -Filter 'esptool.exe' `
        -File -Recurse -ErrorAction SilentlyContinue)
    if ($cached.Count -gt 0) {
        return $cached[0].FullName
    }
    return $null
}

function Get-DmdClockEsptoolReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [string] $QueryFailureMessage,
        [string] $DigestFailureMessage = 'The official esptool asset has no usable GitHub SHA-256 digest.'
    )

    $releasesUrl = "https://github.com/$Repository/releases"
    $uri = "https://api.github.com/repos/$Repository/releases?per_page=20"
    Write-DmdClockProvisioningLog -Event 'metadata-query' -Detail "url=$uri kind=esptool"
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers (Get-DmdClockGitHubHeaders)
        $releases = @($response)
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($QueryFailureMessage)) {
            throw $QueryFailureMessage
        }
        throw
    }

    $candidates = @()
    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease -or
            [string]$release.tag_name -notmatch '^v5\.') { continue }
        $assets = @($release.assets | Where-Object {
            [string]$_.name -match '^esptool-v[0-9.]+-windows-amd64\.zip$'
        })
        if ($assets.Count -eq 1) {
            $candidates += [pscustomobject]@{ Release = $release; Asset = $assets[0] }
        }
    }
    if ($candidates.Count -eq 0) {
        throw "No supported official Windows x64 esptool v5 package was found. See $releasesUrl"
    }

    $selection = $candidates[0]
    $digest = [string]$selection.Asset.digest
    if ($digest -notmatch '^sha256:([A-Fa-f0-9]{64})$') {
        throw $DigestFailureMessage
    }
    return [pscustomobject]@{
        Release = $selection.Release
        Asset = $selection.Asset
        Sha256 = $Matches[1]
    }
}

function Get-DmdClockPortableEsptool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ToolCacheRoot,
        [long] $MaximumToolBytes = 128MB
    )

    $esptoolReleasesUrl = "https://github.com/$esptoolRepository/releases"
    Write-Host ''
    Write-Host 'Checking the portable Espressif flashing tool...'
    $selection = Get-DmdClockEsptoolReleaseAsset -Repository $esptoolRepository `
        -QueryFailureMessage "Unable to check official esptool releases. See $esptoolReleasesUrl" `
        -DigestFailureMessage "The official esptool asset has no usable GitHub SHA-256 digest. See $esptoolReleasesUrl"
    $asset = $selection.Asset
    $expectedHash = $selection.Sha256
    if ([long]$asset.size -le 0 -or [long]$asset.size -gt $MaximumToolBytes) {
        throw 'The official esptool archive size is outside the accepted range.'
    }

    $safeVersion = ([string]$selection.Release.tag_name) -replace '[^A-Za-z0-9_.-]', '_'
    $versionRoot = Join-Path $ToolCacheRoot $safeVersion
    $archivePath = Join-Path $versionRoot ([string]$asset.name)
    $packagePath = Join-Path $versionRoot 'package'
    New-Item -ItemType Directory -Force -Path $versionRoot | Out-Null

    $archiveIsValid = $false
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
        try {
            if ((Get-Item -LiteralPath $archivePath).Length -ne [long]$asset.size) {
                throw 'Cached size mismatch.'
            }
            Assert-DmdClockSha256Hash -Path $archivePath -ExpectedHash $expectedHash
            $archiveIsValid = $true
        }
        catch {
            Remove-Item -LiteralPath $archivePath -Force
        }
    }
    if (-not $archiveIsValid) {
        Write-Host "Downloading official esptool $($selection.Release.tag_name)..."
        Save-DmdClockRemoteFile -Uri $asset.browser_download_url -Destination $archivePath `
            -MaximumBytes $MaximumToolBytes
        if ((Get-Item -LiteralPath $archivePath).Length -ne [long]$asset.size) {
            throw 'Downloaded esptool size does not match GitHub metadata.'
        }
        Assert-DmdClockSha256Hash -Path $archivePath -ExpectedHash $expectedHash
    }

    $null = Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) {
        Expand-DmdClockSafeArchive -ArchivePath $archivePath -Destination $packagePath `
            -ContainmentRoot $ToolCacheRoot
    }
    $executables = @(Get-ChildItem -LiteralPath $packagePath -Filter 'esptool.exe' -File -Recurse)
    if ($executables.Count -ne 1) {
        if (Test-Path -LiteralPath $packagePath) {
            Remove-Item -LiteralPath $packagePath -Recurse -Force
        }
        Expand-DmdClockSafeArchive -ArchivePath $archivePath -Destination $packagePath `
            -ContainmentRoot $ToolCacheRoot
        $executables = @(Get-ChildItem -LiteralPath $packagePath -Filter 'esptool.exe' -File -Recurse)
    }
    if ($executables.Count -ne 1) {
        throw "The official esptool archive does not contain exactly one esptool.exe. See $esptoolReleasesUrl"
    }

    $versionOutput = @(& $executables[0].FullName version 2>&1)
    if ($LASTEXITCODE -ne 0 -or
        ($versionOutput | Out-String) -notmatch [Regex]::Escape(
            ([string]$selection.Release.tag_name).TrimStart('v'))) {
        throw "The portable esptool executable could not be verified. Antivirus software may have blocked it. See $esptoolReleasesUrl"
    }
    Write-Host "[OK] esptool $($selection.Release.tag_name)" -ForegroundColor Green
    Write-DmdClockProvisioningLog -Event 'tool-ready' -Detail (
        "tool=esptool version=$($selection.Release.tag_name) executable=$($executables[0].FullName) " +
        "archive=$archivePath size=$($asset.size) sha256=$expectedHash")
    return [pscustomobject]@{
        Path = $executables[0].FullName
        Version = [string]$selection.Release.tag_name
    }
}

function Assert-DmdClockEsp32s3WithFlash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EsptoolPath,
        [Parameter(Mandatory)][string] $Port
    )

    Write-Host "Checking the device on $Port..."
    $chipOutput = Invoke-DmdClockEsptoolChecked -EsptoolPath $EsptoolPath `
        -Arguments @('--chip', 'esp32s3', '--port', $Port, 'chip-id') -SuppressOutput
    if ($chipOutput -notmatch '(?i)ESP32-S3') {
        throw 'The connected chip is not an ESP32-S3.'
    }
    Write-Host '[OK] Chip: ESP32-S3' -ForegroundColor Green

    $flashOutput = Invoke-DmdClockEsptoolChecked -EsptoolPath $EsptoolPath `
        -Arguments @('--chip', 'esp32s3', '--port', $Port, 'flash-id') -SuppressOutput
    if ($flashOutput -notmatch '(?i)(Detected flash size:\s*16MB|flash size.*16\s*MB)') {
        throw 'The connected device did not report the required 16 MB flash. Refusing to continue.'
    }
    Write-Host '[OK] Flash: 16 MB' -ForegroundColor Green
}

function Invoke-DmdClockEsptoolChecked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EsptoolPath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $SuppressOutput
    )

    if (-not (Test-Path -LiteralPath $EsptoolPath -PathType Leaf)) {
        throw "The portable esptool executable is unavailable."
    }
    Write-DmdClockProvisioningLog -Event 'command-started' -Detail (
        "executable=$EsptoolPath arguments=$($Arguments -join ' ')")
    $output = @(& $EsptoolPath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if (-not $SuppressOutput) {
        $output | Write-Host
    }
    if ($exitCode -ne 0) {
        Write-DmdClockProvisioningLog -Event 'command-failed' `
            -Detail "executable=$EsptoolPath exit_code=$exitCode"
        throw "esptool failed with exit code $exitCode."
    }
    Write-DmdClockProvisioningLog -Event 'command-completed' `
        -Detail "executable=$EsptoolPath exit_code=0"
    return ($output | Out-String)
}

function Read-DmdClockSerialBuffer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SerialPort,
        [int] $CaptureSeconds
    )

    $captured = ''
    $sb = [Text.StringBuilder]::new()
    $deadline = [DateTime]::UtcNow.AddSeconds($CaptureSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        while ($SerialPort.BytesToRead -gt 0) {
            $buffer = New-Object byte[] ([Math]::Min($SerialPort.BytesToRead, 4096))
            $count = $SerialPort.Read($buffer, 0, $buffer.Length)
            if ($count -gt 0) {
                [void]$sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $count))
            }
        }
        $captured = $sb.ToString()
        if ($captured -match 'Initializing[^\r\n]*?\d+x\d+' -and
            $captured -match 'App version:' -and $captured.Length -gt 400) {
            break
        }
        Start-Sleep -Milliseconds 50
    }
    return $captured
}

function Read-DmdClockSerialBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Port,
        [int] $CaptureSeconds = 12,
        [switch] $NativeUsbJtag,
        [string] $ToolCacheRoot
    )

    Add-Type -AssemblyName System.IO.Ports

    if ([string]::IsNullOrWhiteSpace($ToolCacheRoot)) {
        $ToolCacheRoot = (Get-DmdClockConfig).CacheRoot
    }

    if ($NativeUsbJtag) {
        try {
            $esptool = Get-DmdClockPortableEsptool -ToolCacheRoot $ToolCacheRoot
        }
        catch {
            Write-Debug "Could not resolve esptool for the native USB probe on ${Port}: $($_.Exception.Message)"
            return $null
        }
        $null = @(& $esptool.Path '--port' $Port '--before' 'default-reset' '--after' 'hard-reset' 'chip-id' 2>&1)
        $sp = $null
        for ($attempt = 0; $attempt -lt 25 -and $null -eq $sp; $attempt++) {
            try {
                $sp = [IO.Ports.SerialPort]::new(
                    $Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                $sp.ReadTimeout = 500
                $sp.Open()
            }
            catch {
                if ($null -ne $sp) {
                    $sp.Dispose()
                    $sp = $null
                }
                Start-Sleep -Milliseconds 250
            }
        }
        if ($null -eq $sp) {
            return $null
        }
        try {
            $captured = Read-DmdClockSerialBuffer -SerialPort $sp -CaptureSeconds $CaptureSeconds
        }
        finally {
            if ($sp.IsOpen) {
                try {
                    $sp.Close()
                }
                catch {
                    Write-Debug "Could not close the native USB probe port ${Port}: $($_.Exception.Message)"
                }
            }
            $sp.Dispose()
        }
        if ([string]::IsNullOrWhiteSpace($captured)) {
            return $null
        }
        return $captured
    }

    $sequences = @(
        @{ First = 'DtrEnable'; Second = 'RtsEnable' },
        @{ First = 'RtsEnable'; Second = 'DtrEnable' }
    )
    foreach ($sequence in $sequences) {
        $sp = [IO.Ports.SerialPort]::new(
            $Port, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
        $sp.ReadTimeout = 500
        $captured = ''
        try {
            $sp.DtrEnable = $true
            $sp.RtsEnable = $true
            $sp.Open()
            Start-Sleep -Milliseconds 400
            $sp.$($sequence.First) = $false
            Start-Sleep -Milliseconds 120
            $sp.$($sequence.Second) = $false
            $captured = Read-DmdClockSerialBuffer -SerialPort $sp -CaptureSeconds $CaptureSeconds
        }
        catch {
            $captured = ''
        }
        finally {
            if ($sp.IsOpen) {
                try {
                    $sp.DtrEnable = $false
                    $sp.RtsEnable = $true
                    Start-Sleep -Milliseconds 150
                    $sp.RtsEnable = $false
                    $sp.Close()
                }
                catch {
                    Write-Debug "Could not reset DTR/RTS on ${Port}: $($_.Exception.Message)"
                }
            }
            $sp.Dispose()
        }
        if ($captured -match 'ESP-ROM|rst:') {
            return $captured
        }
    }
    return $null
}

function Get-DmdClockBoardProbe {
    param([string] $BannerText)

    $probe = [pscustomobject]@{
        Resolution = $null
        TouchController = $null
        Accelerometer = $null
        AppVersion = $null
        LanIp = $null
        Revision = $null
    }
    if ($BannerText -match 'Initializing[^\r\n]*?\b(?<w>\d+)x(?<h>\d+)\b') {
        $probe.Resolution = "$($Matches.w)x$($Matches.h)"
    }
    if ($BannerText -match 'GT911') {
        $probe.TouchController = 'GT911'
    } elseif ($BannerText -match 'AXS15231B') {
        $probe.TouchController = 'AXS15231B'
    }
    if ($BannerText -match 'QMI8658') {
        $probe.Accelerometer = 'QMI8658'
    }
    if ($BannerText -match '3\.49B\s+V(?<rev>\d)') {
        $probe.Revision = "V$($Matches.rev)"
    }
    if ($BannerText -match 'App version:\s*([0-9][^\s]*)') {
        $probe.AppVersion = $Matches[1]
    }
    if ($BannerText -match 'Home Wi-Fi connected at ([0-9]{1,3}(\.[0-9]{1,3}){3})') {
        $probe.LanIp = $Matches[1]
    } elseif ($BannerText -match 'sta ip: ([0-9]{1,3}(\.[0-9]{1,3}){3})') {
        $probe.LanIp = $Matches[1]
    }
    return $probe
}

function Show-DmdClockDeviceTable {
    param([Parameter(Mandatory)] [object[]] $Rows)

    $hasApp = $null -ne $Rows[0].PSObject.Properties['App']
    $hasSignals = $null -ne $Rows[0].PSObject.Properties['Signals']
    Write-Host ''
    Write-Host 'Detected devices:' -ForegroundColor Cyan
    if ($hasApp -and $hasSignals) {
        Write-Host ('  {0,-7} {1,-20} {2,-12} {3,-6}' -f 'COM', 'Model', 'App', 'Signals') -ForegroundColor DarkGray
    }
    for ($index = 0; $index -lt $Rows.Count; $index++) {
        $row = $Rows[$index]
        $color = if ($row.Identified) { 'Green' } else { 'Yellow' }
        if ($hasApp -and $hasSignals) {
            Write-Host ('  [{0}] {1,-7} {2,-20} {3,-12} {4}' -f
                ($index + 1), $row.Port, $row.Model, $row.App, $row.Signals) -ForegroundColor $color
        } else {
            Write-Host ('  [{0}] {1,-7} {2,-20} {3}' -f
                ($index + 1), $row.Port, $row.Model, $row.Name) -ForegroundColor $color
        }
    }
    Write-Host ('  [{0}] Exit' -f ($Rows.Count + 1)) -ForegroundColor DarkGray
}

Export-ModuleMember -Function @(
    'Clear-DmdClockOperationResult',
    'Get-DmdClockConfig',
    'Assert-DmdClockPathBelowRoot',
    'Assert-DmdClockEsp32s3WithFlash',
    'Assert-DmdClockSafeRelativePath',
    'Assert-DmdClockSha256Hash',
    'Assert-DmdClockSerialPortUnchanged',
    'Complete-DmdClockProvisioningLog',
    'Complete-DmdClockProvisioningLogSafely',
    'Expand-DmdClockSafeArchive',
    'Get-DmdClockCacheLocations',
    'Get-DmdClockCachedEsptool',
    'Get-DmdClockConnectedPorts',
    'Get-DmdClockEsptoolReleaseAsset',
    'Get-DmdClockBoardProbe',
    'Get-DmdClockFreeBytes',
    'Get-DmdClockGitHubHeaders',
    'Get-DmdClockHardwareTargets',
    'Get-DmdClockNearestExistingPath',
    'Get-DmdClockPortableEsptool',
    'Get-DmdClockProvisioningLogPath',
    'Get-DmdClockOperationResult',
    'Get-DmdClockSha256',
    'Invoke-DmdClockEsptoolChecked',
    'Invoke-DmdClockChildOperation',
    'Invoke-DmdClockRequirementsCheck',
    'New-DmdClockStagingLayout',
    'New-DmdClockWizard',
    'Add-DmdClockWizardSelection',
    'Read-DmdClockHighlightedConfirmation',
    'Read-DmdClockMenuChoice',
    'Read-DmdClockSerialBanner',
    'Read-DmdClockSerialBuffer',
    'Resolve-DmdClockDeviceFromProbe',
    'Save-DmdClockRemoteFile',
    'Save-DmdClockStagedDownload',
    'Select-DmdClockSerialPort',
    'Set-DmdClockOperationResult',
    'Show-DmdClockDeviceTable',
    'Show-DmdClockWizardHeader',
    'Start-DmdClockProvisioningLog',
    'Test-DmdClockAdministrator',
    'Test-DmdClockGitHubHttps',
    'Test-DmdClockStagingManifest',
    'Update-DmdClockStagingManifest',
    'Write-DmdClockProvisioningLog',
    'Write-DmdClockRequirementsLog'
)
