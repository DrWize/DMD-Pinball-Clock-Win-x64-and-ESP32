[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$flashPath = Join-Path $PSScriptRoot '..\Flash-DmdClockEsp32.ps1'
$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
Import-Module $modulePath -Force

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "Expected error matching '$Pattern'; received: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected an error matching '$Pattern', but no error was raised."
}

# --- Extract only the flash-local helpers without running its top-level body.
#     Shared probe and target functions come from the provisioning module. ---
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $flashPath, [ref] $tokens, [ref] $errors)
foreach ($functionName in @(
    'Resolve-DmdClockModelLabel', 'Get-DmdClockSuggestedName',
    'Write-DmdClockPortMap', 'Get-DmdClockDeviceProbe',
    'Assert-DmdFirmwareRevision')) {
    $function = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true) | Select-Object -First 1
    if ($null -eq $function) { throw "Flash function not found: $functionName" }
    Invoke-Expression $function.Extent.Text
}
$hardwareTargets = @(Get-DmdClockHardwareTargets)

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("DmdClockBoardProbeTests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$outputRoot = Join-Path $testRoot 'DmdClock'
$DmdClockCacheRoot = $outputRoot
$toolCacheRoot = Join-Path $DmdClockCacheRoot 'tools\esptool'

# --- Real captured boot-banner fixtures. ---
$banner7 = @'
ESP-ROM:esp32s3-20210327
Build:Mar 27 2021
rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)
I (123) boot: Chip Revision: v0.1
I (456) dmdclock: Initializing 800x480 RGB panel
I (789) touch: GT911 touch controller detected at 0x14
I (1023) net: Home Wi-Fi connected at 192.168.1.150
I (1111) app: App version: 1.6.0 (build 2026-08-10)
I (2222) sd: TF card mounted at /sd
'@

$banner349 = @'
ESP-ROM:esp32s3-20210327
rst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)
I (234) dmdclock: Initializing Waveshare 3.49B V2 panel as 640x172
I (567) touch: AXS15231B touch controller detected
I (890) imu: QMI8658 IMU ready
I (1201) net: sta ip: 192.168.1.151
I (1313) app: App version: 1.6.0 (build 2026-08-10)
I (2424) sd: TF card mounted at /sd
'@

# --- The 7-inch banner is parsed into probe signals. ---
$probe7 = Get-DmdClockBoardProbe -BannerText $banner7
Assert-True ($probe7.Resolution -eq '800x480') "7-inch resolution not parsed: $($probe7.Resolution)"
Assert-True ($probe7.TouchController -eq 'GT911') "7-inch touch not parsed: $($probe7.TouchController)"
Assert-True ($null -eq $probe7.Accelerometer) '7-inch banner must report no accelerometer.'
Assert-True ($probe7.AppVersion -eq '1.6.0') "7-inch app version not parsed: $($probe7.AppVersion)"
Assert-True ($probe7.LanIp -eq '192.168.1.150') "7-inch IP not parsed: $($probe7.LanIp)"

# --- The 3.49B banner is parsed into probe signals. ---
$probe349 = Get-DmdClockBoardProbe -BannerText $banner349
Assert-True ($probe349.Resolution -eq '640x172') "3.49B resolution not parsed: $($probe349.Resolution)"
Assert-True ($probe349.TouchController -eq 'AXS15231B') "3.49B touch not parsed: $($probe349.TouchController)"
Assert-True ($probe349.Accelerometer -eq 'QMI8658') "3.49B accelerometer not parsed: $($probe349.Accelerometer)"
Assert-True ($probe349.AppVersion -eq '1.6.0') "3.49B app version not parsed: $($probe349.AppVersion)"
Assert-True ($probe349.LanIp -eq '192.168.1.151') "3.49B IP not parsed: $($probe349.LanIp)"

# --- An unrecognized banner yields null signals. ---
$probeEmpty = Get-DmdClockBoardProbe -BannerText ''
Assert-True ($null -eq $probeEmpty.Resolution -and $null -eq $probeEmpty.TouchController -and
    $null -eq $probeEmpty.Accelerometer -and $null -eq $probeEmpty.AppVersion -and
    $null -eq $probeEmpty.LanIp) 'An empty banner must yield an all-null probe.'

# --- The classifier maps full probes to the matching hardware target. ---
Assert-True ((Resolve-DmdClockDeviceFromProbe -Probe $probe7).Key -eq 'Waveshare7') `
    'A 7-inch probe must classify as Waveshare7.'
Assert-True ((Resolve-DmdClockDeviceFromProbe -Probe $probe349).Key -eq 'Waveshare349B') `
    'A 3.49B probe must classify as Waveshare349B.'

# --- No usable signals, or a tie between targets, is inconclusive. ---
Assert-True ($null -eq (Resolve-DmdClockDeviceFromProbe -Probe $probeEmpty)) `
    'A zero-signal probe must be inconclusive.'
$contradictory = [pscustomobject]@{
    Resolution = '800x480'
    TouchController = 'AXS15231B'
    Accelerometer = $null
    AppVersion = '1.0.0'
    LanIp = $null
}
Assert-True ($null -eq (Resolve-DmdClockDeviceFromProbe -Probe $contradictory)) `
    'A contradictory probe (800x480 + AXS15231B) must tie and be inconclusive.'

# --- Device names derive from the trailing bytes of the chip MAC. ---
Assert-True ((Get-DmdClockSuggestedName -Mac '3c:0f:02:c3:59:d8') -eq 'DMDClock-59D8') `
    'COM4 MAC must suggest DMDClock-59D8.'
Assert-True ((Get-DmdClockSuggestedName -Mac '28:84:85:92:b1:34') -eq 'DMDClock-B134') `
    'COM5 MAC must suggest DMDClock-B134.'
Assert-True ($null -eq (Get-DmdClockSuggestedName -Mac 'ab')) `
    'A short MAC must yield no suggestion.'

# --- Model labels normalize user input to the friendly label. ---
Assert-True ((Resolve-DmdClockModelLabel -Value '7') -eq 'Waveshare 7') `
    "Confirmation '7' must map to 'Waveshare 7'."
Assert-True ((Resolve-DmdClockModelLabel -Value '7 inch') -eq 'Waveshare 7') `
    "'7 inch' must map to 'Waveshare 7'."
Assert-True ((Resolve-DmdClockModelLabel -Value '3.49B') -eq 'Waveshare 3.49B') `
    "Confirmation '3.49B' must map to 'Waveshare 3.49B'."
Assert-True ((Resolve-DmdClockModelLabel -Value 'Waveshare349B') -eq 'Waveshare 3.49B') `
    "Key 'Waveshare349B' must map to 'Waveshare 3.49B'."
Assert-True ((Resolve-DmdClockModelLabel -Value 'Waveshare ESP32-S3-Touch-LCD-3.49B') -eq 'Waveshare 3.49B') `
    "The full product name must map to 'Waveshare 3.49B'."
Assert-True ((Resolve-DmdClockModelLabel -Value 'unknown board') -eq 'unknown board') `
    'Unknown input must be echoed unchanged.'

# --- The startup device probe lists recognized boards and flags the rest. ---
$MockPorts = @()
$MockNativeProbeCalls = [Collections.Generic.List[string]]::new()
function Read-DmdClockSerialBanner {
    param([string] $Port, [int] $CaptureSeconds, [switch] $NativeUsbJtag, [string] $ToolCacheRoot)
    if ($NativeUsbJtag) { [void]$MockNativeProbeCalls.Add($Port) }
    if ($Port -eq 'COM8') { return '' }
    return $MockBanner
}
function Get-DmdClockConnectedPorts {
    return @($MockPorts)
}
$MockPorts = @(
    [pscustomobject]@{ Port = 'COM5'; Name = 'USB JTAG/serial debug unit (COM5)'; InstanceId = 'USB\VID_303A&PID_1001\1' },
    [pscustomobject]@{ Port = 'COM8'; Name = 'Unknown (COM8)'; InstanceId = 'USB\VID_1A86&PID_7523\8' }
)
$MockBanner = $banner349
$probeRows = @(Get-DmdClockDeviceProbe)
Assert-True ($probeRows.Count -eq 2) "Startup probe must report 2 rows; got: $($probeRows.Count)"
$row5 = @($probeRows | Where-Object Port -eq 'COM5')[0]
$row8 = @($probeRows | Where-Object Port -eq 'COM8')[0]
Assert-True ($row5.Model -eq 'Waveshare 3.49B') "COM5 model wrong: $($row5.Model)"
Assert-True ($row5.App -eq '1.6.0') "COM5 app wrong: $($row5.App)"
Assert-True ($row5.Status -eq 'OK to flash') "COM5 must be marked OK to flash: $($row5.Status)"
Assert-True ($row8.Model -eq 'no banner read') "COM8 model wrong: $($row8.Model)"
Assert-True ($row8.Status -eq 'Not verified') "COM8 must be marked Not verified: $($row8.Status)"
Assert-True ('COM5' -in $MockNativeProbeCalls -and 'COM8' -notin $MockNativeProbeCalls) `
    'Only the Espressif native USB-Serial/JTAG port (VID_303A) must use the native reset path.'

$MockBanner = 'ESP-ROM:esp32s3-20210327`nrst:0x1 (POWERON),boot:0x8 (SPI_FAST_FLASH_BOOT)'
$probeRows = @(Get-DmdClockDeviceProbe)
$rowUnrecognized = @($probeRows | Where-Object Port -eq 'COM5')[0]
Assert-True ($rowUnrecognized.Model -eq 'unrecognized') "An unreadable banner must be unrecognized: $($rowUnrecognized.Model)"
Assert-True ($rowUnrecognized.Status -eq 'Not verified') "An unrecognized device must be Not verified: $($rowUnrecognized.Status)"

$MockPorts = @()
$probeRows = @(Get-DmdClockDeviceProbe)
Assert-True ($probeRows.Count -eq 0) 'Startup probe with no ports must report no rows.'

# --- Probe rows carry a resolvable model key and the parsed PCB revision. ---
$MockPorts = @(
    [pscustomobject]@{ Port = 'COM5'; Name = 'USB JTAG/serial debug unit (COM5)'; InstanceId = 'USB\VID_303A&PID_1001\1' },
    [pscustomobject]@{ Port = 'COM8'; Name = 'Unknown (COM8)'; InstanceId = 'USB\VID_1A86&PID_7523\8' }
)
$MockBanner = $banner349
$probeRows = @(Get-DmdClockDeviceProbe)
$row5 = @($probeRows | Where-Object Port -eq 'COM5')[0]
$row8 = @($probeRows | Where-Object Port -eq 'COM8')[0]
Assert-True ($row5.ModelKey -eq 'Waveshare349B') "COM5 model key wrong: $($row5.ModelKey)"
Assert-True ($row5.Revision -eq 'V2') "COM5 revision wrong: $($row5.Revision)"
Assert-True ($null -eq $row8.ModelKey -and $null -eq $row8.Revision) `
    'A no-banner row must carry a null model key and revision.'

$MockBanner = @'
ESP-ROM:esp32s3-20210327
I (234) dmdclock: Initializing Waveshare 3.49B V1 panel as 640x172
I (1313) app: App version: 1.6.0
'@
$probeRows = @(Get-DmdClockDeviceProbe)
$rowV1 = @($probeRows | Where-Object Port -eq 'COM5')[0]
Assert-True ($rowV1.Revision -eq 'V1') "A V1 banner must parse revision V1: $($rowV1.Revision)"

$MockBanner = $banner7
$probeRows = @(Get-DmdClockDeviceProbe)
$row7 = @($probeRows | Where-Object Port -eq 'COM5')[0]
Assert-True ($null -eq $row7.Revision) 'A 7-inch banner must carry no PCB revision.'

# --- Assert-DmdFirmwareRevision uses the detected revision or falls back. ---
function Read-DmdClockHighlightedConfirmation {
    param([string] $Prefix, [string] $Token, [string] $Suffix, [string] $RequiredParameter, [string] $Color)
    return $MockRevisionConfirmation
}
$target349 = @($hardwareTargets | Where-Object Key -eq 'Waveshare349B')[0]
$target7 = @($hardwareTargets | Where-Object Key -eq 'Waveshare7')[0]

Assert-DmdFirmwareRevision -Target $target7 -DetectedRevision $null
Assert-DmdFirmwareRevision -Target $target349 -DetectedRevision 'V2'
Assert-Throws { Assert-DmdFirmwareRevision -Target $target349 -DetectedRevision 'V1' } 'Refusing'

$BoardRevision = $null
$MockRevisionConfirmation = 'V2'
try {
    Assert-DmdFirmwareRevision -Target $target349 -DetectedRevision $null
    $revisionError = $null
}
catch {
    $revisionError = $_
}
Assert-True ($null -eq $revisionError) `
    "A matching physical revision confirmation was rejected: $revisionError"

$MockRevisionConfirmation = 'V1'
Assert-Throws { Assert-DmdFirmwareRevision -Target $target349 -DetectedRevision $null } 'supports only'

# --- The port map is written atomically as UTF-8 without a BOM and replaced in place. ---
$entries = @(
    [pscustomobject]@{
        port = 'COM5'
        deviceName = 'DMDClock-B134'
        model = 'Waveshare 3.49B'
        probe = [pscustomobject]@{
            resolution = '640x172'
            touch = 'AXS15231B'
            accelerometer = 'QMI8658'
            app = '1.6.0'
        }
        mac = '28:84:85:92:b1:34'
        pnp = 'USB\VID_303A&PID_1001\1'
        ip = '192.168.1.151'
    }
)
$mapPath = Write-DmdClockPortMap -Entries $entries
Assert-True (Test-Path -LiteralPath $mapPath) 'The port map must be written to disk.'
$map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
Assert-True ($map.schema -eq 'dmdclock-port-map') 'The port map schema field is wrong.'
Assert-True ($map.version -eq 1) 'The port map version field is wrong.'
Assert-True (@($map.ports).Count -eq 1) 'The port map must contain the single port.'
Assert-True ($map.ports[0].deviceName -eq 'DMDClock-B134') 'The port map deviceName is wrong.'
Assert-True ($map.ports[0].model -eq 'Waveshare 3.49B') 'The port map model is wrong.'
Assert-True ($map.ports[0].ip -eq '192.168.1.151') 'The port map ip is wrong.'
$bytes = [IO.File]::ReadAllBytes($mapPath)
Assert-True ($bytes[0] -ne 0xEF) 'ports.json must be written without a BOM.'
$mapPathAgain = Write-DmdClockPortMap -Entries $entries
Assert-True ($mapPathAgain -eq $mapPath) 'Re-running the probe must atomically replace the same ports.json.'
Assert-True (@([IO.Directory]::GetFiles($outputRoot, '*.tmp')).Count -eq 0) `
    'No temporary port-map files may remain after the atomic replace.'

Remove-Item -LiteralPath $testRoot -Recurse -Force

Write-Host '[PASS] Board probe: boot banners are parsed into signals, classifiers resolve the model, probe rows carry model and PCB revision, firmware revision is confirmed from the probe or physical board, and the port map is written atomically without a BOM.' -ForegroundColor Green
