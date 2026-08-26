#Requires -Version 7.5

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [switch]$FixtureMode
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1')
$result = Test-TabletLayoutObservationC1BV1File -Path $Path -EvidenceRoot $EvidenceRoot -FixtureMode:$FixtureMode
$result | ConvertTo-Json -Depth 100
if (-not $result.fixture_contract_valid) { exit 1 }
