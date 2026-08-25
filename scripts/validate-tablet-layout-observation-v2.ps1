#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    # 第一阶段没有 runtime producer/runner attest；只允许显式 synthetic fixture。
    [switch]$FixtureMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-validator.ps1')

$result = Test-TabletLayoutObservationV2File -Path $Path -EvidenceRoot $EvidenceRoot -FixtureMode:$FixtureMode
$result | ConvertTo-Json -Depth 20
if ($result.fixture_contract_valid -and $result.diagnostic_observed) { exit 0 }
exit 1
