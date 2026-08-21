[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'

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

# --- Mock port enumeration. The extracted flash functions run in this script's
#     scope, so plain (non-global) advanced stubs for Get-CimInstance and
#     Get-ItemProperty shadow the real cmdlets. Read-Host is consumed from a
#     global queue because the menu path resolves it from global scope. ---
$global:MockSerialPorts = @()
$global:MockPnPEntities = @()
$global:MockSerialcomm = $null
$global:MockReadHostQueue = [Collections.Generic.Queue[string]]::new()

function global:Get-CimInstance {
    [CmdletBinding()]
    param([string] $ClassName)
    switch ($ClassName) {
        'Win32_SerialPort' { return @($global:MockSerialPorts) }
        'Win32_PnPEntity' { return @($global:MockPnPEntities) }
        default { return @() }
    }
}

function global:Get-ItemProperty {
    [CmdletBinding()]
    param([string] $Path)
    if ($Path -like '*SERIALCOMM*') { return $global:MockSerialcomm }
    return $null
}

function global:Read-Host {
    [CmdletBinding()]
    param([string] $Prompt)
    Write-Host $Prompt -NoNewline
    if ($global:MockReadHostQueue.Count -eq 0) {
        throw 'Unexpected interactive Read-Host call with no queued answer.'
    }
    return $global:MockReadHostQueue.Dequeue()
}

function Set-MockPorts {
    param(
        [object[]] $SerialPorts,
        [object[]] $PnPEntities,
        [object] $Serialcomm
    )
    $global:MockSerialPorts = @($SerialPorts)
    $global:MockPnPEntities = @($PnPEntities)
    $global:MockSerialcomm = $Serialcomm
}

Import-Module $modulePath -Force

# --- Mock inventory: two serial ports (COM1 deduplicated against the registry,
#     COM5 from PnP), one PnP-only port (COM7), one registry-only port (COM4). ---
$fullSerialPorts = @(
    [pscustomobject]@{
        DeviceID = 'COM1'
        Name = 'Standard Serial over Bluetooth link (COM1)'
        PNPDeviceID = 'BTHENUM\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0000'
        Status = 'OK'
    }
)
$fullPnPEntities = @(
    [pscustomobject]@{
        Name = 'USB Serial (COM7)'
        PNPDeviceID = 'USB\VID_1A86&PID_7523\6&ABC'
        Manufacturer = 'WCH'
        Service = 'usbser'
        Status = 'OK'
    },
    [pscustomobject]@{
        Name = 'Silicon Labs CP210x USB to UART Bridge (COM5)'
        PNPDeviceID = 'USB\VID_10C4&PID_EA60\1'
        Manufacturer = 'Silicon Labs'
        Service = 'usbser'
        Status = 'OK'
    }
)
$fullSerialcomm = [pscustomobject]@{
    PSChildName = 'SERIALCOMM'
    COM1 = 'COM1'
    COM4 = 'COM4'
}

# --- Multiple connected ports are enumerated, deduplicated, and sorted. ---
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities $fullPnPEntities -Serialcomm $fullSerialcomm
$ports = @(Get-DmdClockConnectedPorts)
Assert-True ($ports.Count -eq 4) "Expected 4 connected ports; received $($ports.Count)."
Assert-True (($ports.Port -join ',') -eq 'COM1,COM4,COM5,COM7') `
    "Ports were not sorted and deduplicated: $($ports.Port -join ',')."
$com1 = @($ports | Where-Object Port -eq 'COM1')[0]
$com4 = @($ports | Where-Object Port -eq 'COM4')[0]
$com7 = @($ports | Where-Object Port -eq 'COM7')[0]
Assert-True (-not [string]::IsNullOrWhiteSpace($com1.InstanceId)) `
    'COM1 lost its PnP identity during deduplication.'
Assert-True ([string]::IsNullOrWhiteSpace($com4.InstanceId)) `
    'COM4 gained a PnP identity it should not have (registry-only port).'
Assert-True ($com7.Manufacturer -eq 'WCH' -and $com7.Service -eq 'usbser') `
    'PnP entity metadata was not merged into the port record.'

# --- Explicit port selection captures the PnP identity. ---
$selected = Select-DmdClockSerialPort -Port 'COM7'
Assert-True ($selected.Port -eq 'COM7') 'Explicit port selection returned the wrong port.'
Assert-True ($selected.Identity.InstanceId -eq 'USB\VID_1A86&PID_7523\6&ABC') `
    'Explicit selection did not capture the Windows PnP instance identity.'

# --- An identity-weak explicit selection is refused. ---
Assert-Throws { $null = Select-DmdClockSerialPort -Port 'COM4' } 'no Windows PnP instance identity'

# --- A port that is not connected is refused with the available list. ---
Assert-Throws { $null = Select-DmdClockSerialPort -Port 'COM9' } "Serial port 'COM9' is not connected"

# --- The menu path (no explicit port) honors the selection. ---
$global:MockReadHostQueue.Clear()
$global:MockReadHostQueue.Enqueue('3')
$selected = Select-DmdClockSerialPort
Assert-True ($selected.Port -eq 'COM5') 'Menu selection did not return the chosen port.'
Assert-True ($selected.Identity.Name -match 'CP210x') `
    'Menu selection did not capture the chosen identity.'

# --- A single detected port defaults to itself without prompting. ---
Set-MockPorts -SerialPorts @() -PnPEntities @($fullPnPEntities[0]) -Serialcomm $null
$global:MockReadHostQueue.Clear()
$global:MockReadHostQueue.Enqueue('')
$selected = Select-DmdClockSerialPort
Assert-True ($selected.Port -eq 'COM7') 'Single-port selection did not apply the default.'

# --- No detected port is refused. ---
Set-MockPorts -SerialPorts @() -PnPEntities @() -Serialcomm $null
Assert-Throws { $null = Select-DmdClockSerialPort } 'No serial port was detected'

# --- The captured identity is revalidated unchanged. ---
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities $fullPnPEntities -Serialcomm $fullSerialcomm
$selected = Select-DmdClockSerialPort -Port 'COM7'
$unchangedError = $null
try {
    Assert-DmdClockSerialPortUnchanged -SelectedPort 'COM7' -PortIdentity $selected.Identity
}
catch {
    $unchangedError = $_
}
Assert-True ($null -eq $unchangedError) `
    "An unchanged serial port was rejected: $unchangedError"

# --- A port that disappears before flashing is refused. ---
$selected = Select-DmdClockSerialPort -Port 'COM7'
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities @($fullPnPEntities[1]) -Serialcomm $fullSerialcomm
Assert-Throws {
    Assert-DmdClockSerialPortUnchanged -SelectedPort 'COM7' -PortIdentity $selected.Identity
} 'disappeared or became ambiguous'

# --- A port whose PnP identity changed before flashing is refused. ---
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities $fullPnPEntities -Serialcomm $fullSerialcomm
$selected = Select-DmdClockSerialPort -Port 'COM7'
$movedCom7 = [pscustomobject]@{
    Name = 'USB Serial (COM7)'
    PNPDeviceID = 'USB\VID_1A86&PID_7523\DIFFERENT'
    Manufacturer = 'WCH'
    Service = 'usbser'
    Status = 'OK'
}
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities @($movedCom7, $fullPnPEntities[1]) -Serialcomm $fullSerialcomm
Assert-Throws {
    Assert-DmdClockSerialPortUnchanged -SelectedPort 'COM7' -PortIdentity $selected.Identity
} 'changed before flashing'

# --- A port whose friendly name changed before flashing is refused. ---
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities $fullPnPEntities -Serialcomm $fullSerialcomm
$selected = Select-DmdClockSerialPort -Port 'COM7'
$renamedCom7 = [pscustomobject]@{
    Name = 'USB Serial CH340 (COM7)'
    PNPDeviceID = 'USB\VID_1A86&PID_7523\6&ABC'
    Manufacturer = 'WCH'
    Service = 'usbser'
    Status = 'OK'
}
Set-MockPorts -SerialPorts $fullSerialPorts -PnPEntities @($renamedCom7, $fullPnPEntities[1]) -Serialcomm $fullSerialcomm
Assert-Throws {
    Assert-DmdClockSerialPortUnchanged -SelectedPort 'COM7' -PortIdentity $selected.Identity
} 'changed before flashing'

Write-Host '[PASS] Serial ports: multiple connected ports are enumerated, deduplicated, sorted, explicitly or interactively selectable, identity-checked on selection, and revalidated unchanged before flashing.' -ForegroundColor Green
