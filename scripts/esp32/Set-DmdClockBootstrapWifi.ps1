[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $WifiSsid,

    [Security.SecureString] $WifiPassword,

    [switch] $Build
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function ConvertTo-CStringLiteral {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
    $encoded = [Text.StringBuilder]::new()
    foreach ($byte in $bytes) {
        if ($byte -ge 0x20 -and $byte -le 0x7e -and
            $byte -notin [byte[]]@(0x22, 0x5c)) {
            [void]$encoded.Append([char]$byte)
        } else {
            [void]$encoded.Append('\')
            [void]$encoded.Append(
                [Convert]::ToString($byte, 8).PadLeft(3, '0'))
        }
    }
    return '"' + $encoded.ToString() + '"'
}

if ($null -eq $WifiPassword) {
    $WifiPassword = Read-Host `
        -Prompt 'Wi-Fi password (stored only in the ignored local header and NVS)' `
        -AsSecureString
}

$passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($WifiPassword)
$plainPassword = $null
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    $ssidBytes = [Text.Encoding]::UTF8.GetByteCount($WifiSsid)
    $passwordBytes = [Text.Encoding]::UTF8.GetByteCount($plainPassword)
    if ($ssidBytes -lt 1 -or $ssidBytes -gt 32) {
        throw 'Wi-Fi SSID must contain 1 to 32 UTF-8 bytes.'
    }
    if ($passwordBytes -gt 64) {
        throw 'Wi-Fi password must contain at most 64 UTF-8 bytes.'
    }

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $headerPath = Join-Path `
        $repoRoot `
        'firmware\dmdclock-esp32\main\dmd_bootstrap_wifi.h'
    $content = @"
#pragma once

// Generated locally by Set-DmdClockBootstrapWifi.ps1. Never commit this file.
#define DMD_BOOTSTRAP_WIFI_SSID $(ConvertTo-CStringLiteral $WifiSsid)
#define DMD_BOOTSTRAP_WIFI_PASSWORD $(ConvertTo-CStringLiteral $plainPassword)
"@
    [IO.File]::WriteAllText(
        $headerPath,
        $content + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
} finally {
    $plainPassword = $null
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
}

Write-Host "Bootstrap Wi-Fi header created for SSID '$WifiSsid'."
Write-Host 'The password was not printed. The generated header is ignored by Git.'
Write-Host 'After a successful connection, clear it and rebuild/reflash to remove it from the application image.'

if ($Build) {
    & (Join-Path $PSScriptRoot 'Build-DmdClock.ps1')
}
