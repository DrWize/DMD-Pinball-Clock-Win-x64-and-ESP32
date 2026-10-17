[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../DmdClock.Provisioning.psm1') -Force

class FakeWifiSerial {
    [string] $InputBuffer = ''
    [string] $OutputBuffer = ''
    [string] $Mode = ''
    [string] $Board = 'Waveshare349B'
    [string] $Mac = '28:84:85:92:b1:34'
    [int] $CredentialWrites = 0
    [int] $WriteAttempts = 0
    [bool] $Disposed = $false
    [bool] $Opened = $false
    [bool] $DtrEnable
    [bool] $RtsEnable
    [int] $WriteTimeout
    [object] $Encoding
    [string] $ReceivedSsid
    [string] $ReceivedPassword
    [void] Open() { $this.Opened = $true }
    [void] Dispose() { $this.Disposed = $true }
    [void] Write([byte[]] $bytes, [int] $offset, [int] $count) {
        # Byte chunks may split a multibyte character: accumulate bytes as Latin1.
        $this.Write([Text.Encoding]::Latin1.GetString($bytes, $offset, $count))
    }
    [void] Write([string] $text) {
        $this.WriteAttempts++
        if ($this.Mode -eq 'write-timeout') { throw [IO.IOException]::new('DO-NOT-PRINT-SECRET') }
        $this.InputBuffer += $text
        if (-not $this.InputBuffer.Contains("`n")) { return }
        foreach ($line in ($this.InputBuffer -split "`n")) {
            if (-not $line.StartsWith('DMDWIFI:')) { continue }
            $unicode = [Text.Encoding]::UTF8.GetString([Text.Encoding]::Latin1.GetBytes($line.Substring(8)))
            try { $req = ConvertFrom-Json -InputObject $unicode -AsHashtable -ErrorAction Stop }
            catch { continue }
            if ($req.op -eq 'setWifi') {
                $this.CredentialWrites++
                $this.ReceivedSsid = $req.ssid
                $this.ReceivedPassword = $req.password
            }
            if ($this.Mode -eq 'silent') { continue }
            $reply = @{ protocol = 1; id = $req.id; ok = $true; board = $this.Board;
                mac = $this.Mac; firmware = 'test-serial'; connected = $true; ip = '192.168.1.150'; ssid = $this.ReceivedSsid }
            if ($this.Mode -eq 'save-failed' -and $req.op -eq 'setWifi') { $reply.ok = $false; $reply.error = 'save_failed' }
            if ($this.Mode -eq 'untrusted-error') { $reply.ok = $false; $reply.error = 'DO-NOT-PRINT-SECRET' }
            if ($this.Mode -eq 'protocol') { $reply.protocol = 99 }
            if ($this.Mode -eq 'no-ip') { $reply.connected = $false; $reply.ip = '' }
            if ($this.Mode -eq 'wrong-ssid') { $reply.ssid = 'old-network' }
            if ($this.Mode -eq 'changed-mac' -and $req.op -eq 'status') { $reply.mac = 'aa:bb:cc:dd:ee:ff' }
            if ($this.Mode -eq 'noise') {
                $this.OutputBuffer += "boot log`nDMDWIFI:broken JSON`nDMDWIFI:{`"protocol`":1,`"id`":`"unrelated`",`"ok`":true}`n"
            }
            $this.OutputBuffer += 'DMDWIFI:' + ($reply | ConvertTo-Json -Compress) + "`r`n"
        }
        $this.InputBuffer = ''
    }
    [string] ReadExisting() {
        # Fragment all replies to exercise framing across reads.
        $size = [Math]::Min(73, $this.OutputBuffer.Length)
        $value = $this.OutputBuffer.Substring(0, $size)
        $this.OutputBuffer = $this.OutputBuffer.Substring($size)
        return $value
    }
}

function Assert-True([bool] $Value, [string] $Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
        Assert-True (-not $_.Exception.Message.Contains('DO-NOT-PRINT-SECRET')) 'Untrusted serial data leaked.'
        return
    }
    throw "Expected failure: $Pattern"
}
$module = Get-Module DmdClock.Provisioning
# Replace only the transport/USB discovery boundary; the real host state machine runs.
& $module {
    function script:Get-DmdClockConnectedPorts { [pscustomobject]@{ Port = 'COM3'; InstanceId = 'test-usb' } }
    function script:New-DmdClockWifiSerialPort { param($Port) return $script:WifiFake }
}
function Use-Fake([string] $Mode = '') {
    $fake = [FakeWifiSerial]::new(); $fake.Mode = $Mode
    & $module { param($Fake) $script:WifiFake = $Fake } $fake
    return $fake
}
$password = ConvertTo-SecureString 'p"äss\word' -AsPlainText -Force
$common = @{ Board = 'Waveshare349B'; Port = 'COM3'; ExpectedInstanceId = 'test-usb'; WifiSsid = 'Hem-å'; WifiPassword = $password }

$fake = Use-Fake 'noise'
$result = Set-DmdClockWifi @common
Assert-True ($result.Ip -eq '192.168.1.150' -and $fake.CredentialWrites -eq 1) 'Connection not verified.'
Assert-True ($fake.ReceivedPassword -ceq 'p"äss\word' -and $fake.ReceivedSsid -ceq 'Hem-å') 'Credentials changed during encoding.'
Assert-True ($fake.Disposed -and -not $fake.DtrEnable -and -not $fake.RtsEnable) 'Port lifecycle or reset lines incorrect.'

$fake = Use-Fake
$fake.Board = 'Waveshare7'
Assert-Throws { Set-DmdClockWifi @common } 'does not match'
Assert-True ($fake.CredentialWrites -eq 0 -and $fake.Disposed) 'Credentials sent to wrong target.'

$fake = Use-Fake 'save-failed'
Assert-Throws { Set-DmdClockWifi @common } 'Could not save'
Assert-True $fake.Disposed 'Port left open on save error.'

$fake = Use-Fake 'write-timeout'
Assert-Throws { Set-DmdClockWifi @common } 'COM communication failed'
Assert-True ($fake.Disposed -and $fake.CredentialWrites -eq 0 -and $fake.WriteAttempts -eq 1) 'Failed COM handle was reused or left open.'

$fake = Use-Fake 'changed-mac'
Assert-Throws { Set-DmdClockWifi @common } 'identity changed'
$fake = Use-Fake 'no-ip'
Assert-Throws { Set-DmdClockWifi @common -ConnectionTimeoutSeconds 1 } 'did not obtain an IP'
$fake = Use-Fake 'wrong-ssid'
Assert-Throws { Set-DmdClockWifi @common -ConnectionTimeoutSeconds 1 } 'did not obtain an IP'

foreach ($case in @(@('protocol', 'Unsupported'), @('silent', 'may not support'), @('untrusted-error', 'rejected'))) {
    $fake = Use-Fake $case[0]
    Assert-Throws { Invoke-DmdClockWifiRequest -Connection $fake -Request @{ op = 'hello' } -TimeoutSeconds 1 } $case[1]
}
$fake = Use-Fake
$req = @{ op = 'setWifi'; ssid = 'test'; password = 'temporary-secret' }
$null = Invoke-DmdClockWifiRequest -Connection $fake -Request $req
Assert-True (-not $req.ContainsKey('password')) 'Credential request retained its password.'
Assert-Throws { Invoke-DmdClockWifiRequest -Connection $fake -Request @{ op = 'setWifi'; password = ('x' * 1100) } } 'limit'

$fake = Use-Fake
Set-DmdClockWifi -Board Waveshare349B -Port COM3 -WhatIf
Assert-True (-not $fake.Opened -and $fake.CredentialWrites -eq 0) 'Dry run opened a port.'
$invalid = $common.Clone(); $invalid.WifiSsid = 'å' * 17
Assert-Throws { Set-DmdClockWifi @invalid } '1-32 UTF-8'
Assert-True ($fake.CredentialWrites -eq 0) 'Invalid credential request sent.'

$fake = Use-Fake
$maximum = $common.Clone()
$maximum.WifiSsid = 'a' * 32
$maximum.WifiPassword = ConvertTo-SecureString ('a' * 64) -AsPlainText -Force
$null = Set-DmdClockWifi @maximum
Assert-True ($fake.ReceivedSsid.Length -eq 32 -and $fake.ReceivedPassword.Length -eq 64) 'Maximum byte lengths truncated.'
$fake = Use-Fake
$openNetwork = $common.Clone(); $openNetwork.WifiPassword = [Security.SecureString]::new()
$null = Set-DmdClockWifi @openNetwork
Assert-True ($fake.CredentialWrites -eq 1 -and $fake.ReceivedPassword.Length -eq 0) 'Open network not handled explicitly.'

Write-Host '[PASS] Serial Wi-Fi framing, identity, UTF-8, connection verification, save errors, redaction, unsupported firmware, timeouts, disposal, and dry-run checks.'
