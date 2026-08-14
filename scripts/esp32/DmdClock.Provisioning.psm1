Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProvisioningLogPath = $null
$script:ProvisioningLogStartedUtc = $null
$script:ProvisioningLogOperation = $null

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
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-DmdClockPathBelowRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root
    )

    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith(
        "$fullRoot$([IO.Path]::DirectorySeparatorChar)",
        [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing staging operation outside '$fullRoot': $fullPath"
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
        [Parameter(Mandatory)][ValidateSet('Check', 'Download', 'Offline', 'SdCard', 'Flash')]
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

    $isWindows = $env:OS -eq 'Windows_NT'
    Add-Check 'Operating system' $isWindows ([string]$PSVersionTable.OS) `
        'Windows 11' 'Run this workflow on a Windows 11 x64 computer.'

    $osVersion = [Environment]::OSVersion.Version
    $isWindows11 = $isWindows -and $osVersion.Major -eq 10 -and $osVersion.Build -ge 22000
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
            'Close this session and open PowerShell 7 with Run as administrator only for the SD erase/format stage.'
    }

    Write-Host ''
    Write-Host "DMDClock requirements: $Operation" -ForegroundColor Cyan
    foreach ($check in $checks) {
        $label = if ($check.Passed) { '[OK]' } else { '[FAIL]' }
        $color = if ($check.Passed) { 'Green' } else { 'Red' }
        Write-Host "$label $($check.Name): $($check.Detected)" -ForegroundColor $color
        if (-not $check.Passed) {
            Write-Host "       Required: $($check.Required)"
            Write-Host "       Fix: $($check.Remediation)"
        }
    }

    $failed = @($checks | Where-Object { -not $_.Passed })
    $result = [pscustomobject]@{
        Operation = $Operation
        Passed = $failed.Count -eq 0
        Checks = @($checks)
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

function Get-DmdClockProvisioningLogPath {
    [CmdletBinding()]
    param()
    return $script:ProvisioningLogPath
}

Export-ModuleMember -Function @(
    'Assert-DmdClockPathBelowRoot',
    'Complete-DmdClockProvisioningLog',
    'Get-DmdClockFreeBytes',
    'Get-DmdClockNearestExistingPath',
    'Get-DmdClockProvisioningLogPath',
    'Get-DmdClockSha256',
    'Invoke-DmdClockRequirementsCheck',
    'New-DmdClockStagingLayout',
    'Save-DmdClockStagedDownload',
    'Start-DmdClockProvisioningLog',
    'Test-DmdClockAdministrator',
    'Test-DmdClockGitHubHttps',
    'Test-DmdClockStagingManifest',
    'Update-DmdClockStagingManifest',
    'Write-DmdClockProvisioningLog',
    'Write-DmdClockRequirementsLog'
)
