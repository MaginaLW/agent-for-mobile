#Requires -Version 7.5

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot 'run-tablet-layout-observation-c1b-v1-offline-gate.ps1'
& $gate
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
