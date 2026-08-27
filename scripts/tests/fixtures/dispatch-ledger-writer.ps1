#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LibraryPath,
    [Parameter(Mandatory)][string]$LedgerPath,
    [Parameter(Mandatory)][int]$Index
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. $LibraryPath
Add-P0LedgerRow `
    -LedgerPath $LedgerPath `
    -Slug "concurrent-$Index" `
    -Leg $Index `
    -Brain codex `
    -Model test-model `
    -Result success
