[CmdletBinding()]
param(
    [switch] $Build
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$mainDirectory = (
    Resolve-Path -LiteralPath (Join-Path $repoRoot 'firmware\dmdclock-esp32\main')
).Path
$headerPath = [IO.Path]::GetFullPath(
    (Join-Path $mainDirectory 'dmd_bootstrap_wifi.h'))
if ([IO.Path]::GetDirectoryName($headerPath) -ne $mainDirectory) {
    throw 'Refusing to remove a bootstrap file outside the firmware main directory.'
}

if (Test-Path -LiteralPath $headerPath -PathType Leaf) {
    Remove-Item -LiteralPath $headerPath -Force
    Write-Host 'Removed the local bootstrap Wi-Fi header.'
} else {
    Write-Host 'No local bootstrap Wi-Fi header was present.'
}

Write-Host 'Saved NVS credentials are preserved by a normal application flash.'
Write-Host 'Rebuild and reflash to remove the bootstrap password from the application image.'

if ($Build) {
    & (Join-Path $PSScriptRoot 'Build-DmdClock.ps1')
}
