[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\DmdClock.Provisioning.psm1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'DmdClockCancellationTests-' + [Guid]::NewGuid().ToString('N'))

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

# --- Mock Read-Host. The module's Read-DmdClockMenuChoice resolves Read-Host
# from global scope, so the stub is defined globally and consumed from a queue
# to simulate repeated user input (including aborted/empty and invalid entries). ---
$global:MockReadHostQueue = [Collections.Generic.Queue[string]]::new()

function global:Read-Host {
    [CmdletBinding()]
    param([string] $Prompt)
    Write-Host $Prompt -NoNewline
    if ($global:MockReadHostQueue.Count -eq 0) {
        throw 'Unexpected interactive Read-Host call with no queued answer.'
    }
    return $global:MockReadHostQueue.Dequeue()
}

function Reset-Answers {
    param([string[]] $Answers)
    $global:MockReadHostQueue.Clear()
    foreach ($answer in $Answers) {
        $global:MockReadHostQueue.Enqueue($answer)
    }
}

try {
    Import-Module $modulePath -Force

    # --- A valid numeric answer is returned immediately. ---
    Reset-Answers @('3')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 5
    Assert-True ($choice -eq 3) 'A valid numeric answer was not returned.'
    Assert-True ($global:MockReadHostQueue.Count -eq 0) `
        'The prompt loop consumed more input than expected for a valid answer.'

    # --- An empty answer applies the in-range default. ---
    Reset-Answers @('')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 5 -Default 2
    Assert-True ($choice -eq 2) 'An empty answer did not return the configured default.'
    Assert-True ($global:MockReadHostQueue.Count -eq 0) `
        'The prompt loop consumed more input than expected for the default path.'

    # --- Invalid input is rejected and the prompt is repeated until a valid
    #     answer arrives (no crash, no early/partial return). ---
    Reset-Answers @('abc', '5')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 5 `
        -AllowRetryOnRedirectedInput
    Assert-True ($choice -eq 5) 'Invalid input did not re-prompt before accepting a valid answer.'
    Assert-True ($global:MockReadHostQueue.Count -eq 0) `
        'The prompt loop did not retry after invalid input.'

    # --- An empty answer without an in-range default re-prompts instead of
    #     silently returning a value. ---
    Reset-Answers @('', '2')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 3 `
        -AllowRetryOnRedirectedInput
    Assert-True ($choice -eq 2) 'An empty answer without a default did not re-prompt.'

    # --- Out-of-range numbers are rejected and the prompt repeats. ---
    Reset-Answers @('9', '1')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 3 `
        -AllowRetryOnRedirectedInput
    Assert-True ($choice -eq 1) 'An out-of-range number did not re-prompt.'

    # --- An out-of-range default is ignored (no default text, no silent return). ---
    Reset-Answers @('', '2')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 3 -Default 0 `
        -AllowRetryOnRedirectedInput
    Assert-True ($choice -eq 2) 'An out-of-range default was not ignored.'
    Assert-True ($global:MockReadHostQueue.Count -eq 0) `
        'The prompt loop did not re-prompt when the default was out of range.'

    # --- Redirected invalid input fails once and names the selector instead of
    #     retrying against exhausted input. ---
    Reset-Answers @('not-a-number')
    Assert-Throws {
        Read-DmdClockMenuChoice -Prompt 'Select board' -Minimum 1 -Maximum 2 `
            -RequiredParameter '-Board'
    } 'Provide -Board when input is redirected'

    # --- The wizard-header branch still returns the selected answer. ---
    $wizard = New-DmdClockWizard -Title 'DMDClock SD card wizard'
    Reset-Answers @('3')
    $choice = Read-DmdClockMenuChoice -Prompt 'Select' -Minimum 1 -Maximum 3 -Wizard $wizard
    Assert-True ($choice -eq 3) 'Menu choice with an active wizard did not return the answer.'

    # --- A wizard without probe results renders the plain status area. ---
    Assert-True ($null -eq $wizard.Devices) `
        'A wizard created without -Devices must carry no device rows.'
    try {
        Show-DmdClockWizardHeader -Wizard $wizard
        $wizardHeaderError = $null
    }
    catch {
        $wizardHeaderError = $_
    }
    Assert-True ($null -eq $wizardHeaderError) `
        "The plain wizard header must render without error: $wizardHeaderError"

    # --- A wizard with probe results carries them and renders them in the menu. ---
    $probeRows = @(
        [pscustomobject]@{
            Port = 'COM5'
            Model = 'Waveshare 3.49B'
            App = '1.6.0'
            Signals = '640x172 / AXS15231B / QMI8658'
            Status = 'OK to flash'
            Identified = $true
        },
        [pscustomobject]@{
            Port = 'COM8'
            Model = 'no banner read'
            App = '-'
            Signals = '-'
            Status = 'Not verified'
            Identified = $false
        }
    )
    $wizardProbe = New-DmdClockWizard -Title 'DMDClock ESP32 flash' -Devices $probeRows
    Assert-True (@($wizardProbe.Devices).Count -eq 2) `
        'The wizard must carry the detected device rows.'
    try {
        Show-DmdClockWizardHeader -Wizard $wizardProbe
        $wizardHeaderError = $null
    }
    catch {
        $wizardHeaderError = $_
    }
    Assert-True ($null -eq $wizardHeaderError) `
        "The wizard header with devices must render without error: $wizardHeaderError"

    # --- A cancelled run is recorded in the provisioning log. ---
    $logDir = Join-Path $testRoot 'logs'
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $logPath = Start-DmdClockProvisioningLog -LogDirectory $logDir -Operation 'sync-sd-DmdLarge'
    Complete-DmdClockProvisioningLog -Outcome cancelled
    Assert-True (Test-Path -LiteralPath $logPath) 'The cancellation log was not written.'
    $logText = Get-Content -LiteralPath $logPath -Raw
    Assert-True ($logText -match 'outcome=cancelled') `
        'The provisioning log did not record the cancelled outcome.'
    Assert-True ($logText -match 'operation=sync-sd-DmdLarge') `
        'The provisioning log did not record the operation.'

    # --- Child scripts may emit formatted display objects. They must be shown
    #     without contaminating the single structured operation result. ---
    $childScript = Join-Path $testRoot 'display-output-child.ps1'
    Set-Content -LiteralPath $childScript -Value @'
[pscustomobject]@{ Artifact = 'sd.library'; Status = 'reused' } | Format-Table
Set-DmdClockOperationResult -Status completed -Operation 'Display output child'
'@ -Encoding utf8NoBOM
    $childResult = Invoke-DmdClockChildOperation -Operation 'Display output child' `
        -ScriptPath $childScript
    Assert-True ($childResult.PSTypeNames -contains 'DmdClock.OperationResult') `
        'Formatted child output contaminated the structured operation result.'
    Assert-True ($childResult.Status -eq 'completed') `
        'Child operation did not return its completed status.'

    Write-Host '[PASS] Cancellation: menu-choice input handling, child display/result separation, and the cancelled log outcome all behave correctly.' -ForegroundColor Green
}
finally {
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ((Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith('DmdClockCancellationTests-')) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
