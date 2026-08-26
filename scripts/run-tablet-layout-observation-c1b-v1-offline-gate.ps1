#Requires -Version 7.5

[CmdletBinding()]
param(
    [ValidateScript({ $_ -cmatch '^[0-9a-f]{32}$' })]
    [string]$InvocationId = ([guid]::NewGuid().ToString('N'))
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-offline-gate.ps1')

$issues = [Collections.Generic.List[object]]::new()
$paths = Get-TL1C1BV1OfflineChecksPaths $repoRoot $issues -CreateChecksRoot
if($null -eq $paths -or $issues.Count -ne 0){
    throw "C1b fixed .checks path unsafe: $(@(Get-TL1C1BV1OfflineGateReasonCodes $issues) -join ',')"
}
$gateRunId = "gate-$InvocationId"
$pwsh = (Get-Process -Id $PID).Path
$selfTest = Join-Path $PSScriptRoot 'tests\tablet-layout-observation-c1b-v1-offline-gate.ps1'
$suite = Join-Path $PSScriptRoot 'tests\tablet-layout-observation-c1b-v1-offline.ps1'

& $pwsh -NoLogo -NoProfile -NonInteractive -File $selfTest
if($LASTEXITCODE -ne 0){throw "C1b offline gate self-test failed (exit=$LASTEXITCODE)."}
& $pwsh -NoLogo -NoProfile -NonInteractive -File $suite -SummaryPath $paths.SummaryPath -GateRunId $gateRunId
$suiteExit = $LASTEXITCODE
$validation = Read-TL1C1BV1OfflineSummary $repoRoot $paths.SummaryPath $gateRunId
if($suiteExit -ne 0){throw "C1b offline suite failed (exit=$suiteExit)."}
if(-not $validation.accepted){throw "C1b machine summary rejected: $($validation.reason_codes -join ',')"}

"C1B_GATE_PASS cases=$($validation.passed_cases)/$($validation.total_cases) " +
    "coverage=$($validation.covered_required_count)/$($validation.required_coverage_count) " +
    "cross_layer=$($validation.cross_layer_requirements[0]) summary=.checks/$script:TL1C1BV1OfflineSummaryFileName " +
    'runtime=false semantics=false layout=false action=false p0=unsupported exec=false'
