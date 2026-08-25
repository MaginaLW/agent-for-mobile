#Requires -Version 7.5
[CmdletBinding()]
param(
    [ValidateScript({ $_ -cmatch '\A[0-9a-f]{32}\z' })]
    [string]$InvocationId = ([guid]::NewGuid().ToString('N'))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$FixedRepository = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-offline-gate.ps1')

$issues = [Collections.Generic.List[object]]::new()
$paths = Get-TL1V2OfflineChecksPaths $FixedRepository $issues -CreateChecksRoot
if ($null -eq $paths -or $issues.Count -ne 0) {
    throw "T-L1 v2 固定 .checks 路径不安全：$(@(Get-TL1V2ReasonCodes $issues) -join ',')"
}
$gateRunId = "gate-$InvocationId"
$pwsh = (Get-Process -Id $PID).Path
$selfTest = Join-Path $PSScriptRoot 'tests\tablet-layout-observation-v2-offline-gate.ps1'
$suite = Join-Path $PSScriptRoot 'tests\tablet-layout-observation-v2-offline.ps1'

& $pwsh -NoLogo -NoProfile -File $selfTest
if ($LASTEXITCODE -ne 0) { throw "T-L1 v2 gate self-test 失败（exit=$LASTEXITCODE）。" }
& $pwsh -NoLogo -NoProfile -File $suite -SummaryPath $paths.SummaryPath -GateRunId $gateRunId
$suiteExit = $LASTEXITCODE
$validation = Read-TL1V2OfflineSummary $FixedRepository $paths.SummaryPath $gateRunId
if ($suiteExit -ne 0) { throw "T-L1 v2 offline suite 失败（exit=$suiteExit）。" }
if (-not $validation.accepted) {
    throw "T-L1 v2 machine summary 验收失败：$($validation.reason_codes -join ',')"
}
Write-Host (
    'tablet T-L1 v2 diagnostic-only gate：{0}/{1} cases，{2}/{3} coverage；layout=false，P0=unsupported，exec=false' -f
    $validation.passed_cases,$validation.total_cases,$validation.covered_required_count,$validation.required_coverage_count
) -ForegroundColor Green
