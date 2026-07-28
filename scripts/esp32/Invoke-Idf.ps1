[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ProjectPath,

    [Parameter(ValueFromRemainingArguments)]
    [string[]] $IdfArguments
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$workspaceRoot = Split-Path -Parent $repoRoot
$eim = Join-Path $workspaceRoot '.tools\eim\v0.17.1\eim.exe'
$registry = Join-Path $workspaceRoot '.tools\esp-idf\tools'
$idfVersion = 'v5.5.2'
$resolvedProject = (Resolve-Path -LiteralPath $ProjectPath).Path

if (-not (Test-Path -LiteralPath $eim -PathType Leaf)) {
    throw "ESP-IDF Environment Manager was not found at '$eim'."
}

if (-not (Test-Path -LiteralPath (Join-Path $resolvedProject 'CMakeLists.txt') -PathType Leaf)) {
    throw "'$resolvedProject' is not an ESP-IDF project (CMakeLists.txt is missing)."
}

if ($IdfArguments.Count -eq 0) {
    $IdfArguments = @('build')
}

function ConvertTo-PowerShellSingleQuotedLiteral([string] $Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

$projectLiteral = ConvertTo-PowerShellSingleQuotedLiteral $resolvedProject
$argumentLiterals = $IdfArguments | ForEach-Object {
    ConvertTo-PowerShellSingleQuotedLiteral $_
}
$idfCommand = 'idf.py ' + ($argumentLiterals -join ' ')
$command = "Set-Location -LiteralPath $projectLiteral; $idfCommand"

Write-Host "ESP-IDF $idfVersion"
Write-Host "Project: $resolvedProject"
Write-Host "Command: idf.py $($IdfArguments -join ' ')"

$idfOutput = @(& $eim run $command $idfVersion --do-not-track true --esp-idf-json-path $registry 2>&1)
$eimExitCode = $LASTEXITCODE
$idfOutput | Write-Output

$outputText = $idfOutput | Out-String
$reportedFailure = $outputText -match '(?m)^ninja failed with exit code \d+' -or
    $outputText -match '(?m)^FAILED: ' -or
    $outputText -match '(?m)^CMake Error' -or
    $outputText -match '(?m)fatal error:'
if ($eimExitCode -ne 0 -or $reportedFailure) {
    throw "ESP-IDF command failed. Review the build output above."
}
