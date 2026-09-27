#Requires -Version 7.5
[CmdletBinding()]param(
    [Parameter(Mandatory)][ValidateSet('Read','Freeze',IgnoreCase=$false)][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[a-z0-9][a-z0-9._-]{0,79}$')][string]$AttemptId,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{40}$')][string]$ExpectedCommitSha,
    [AllowNull()][string]$RunId=$null,
    [Parameter(Mandatory)][ValidateSet('success','failed','needs-user',IgnoreCase=$false)][string]$TerminalStatus,
    [string]$DestinationDirectory,
    [string]$RepoRoot=(Join-Path $PSScriptRoot '..')
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$RepoRoot=[IO.Path]::GetFullPath($RepoRoot)
. (Join-Path $PSScriptRoot 'lib/tablet-layout-c1a.ps1')
. (Join-Path $PSScriptRoot 'lib/tablet-layout-observation-v2-validator.ps1')
. (Join-Path $PSScriptRoot 'lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $PSScriptRoot 'lib/tablet-layout-c1b.ps1')
. (Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-discovery-consumer.ps1')
if($Mode-ceq'Freeze'){
    if([string]::IsNullOrWhiteSpace($DestinationDirectory)){throw 'Freeze 需要既有 .checks 目标目录。'}
    $result=Freeze-TL1C1bDiscoveryEvidenceBundle -RepoRoot $RepoRoot -AttemptId $AttemptId `
        -ExpectedCommitSha $ExpectedCommitSha -RunId $RunId -TerminalStatus $TerminalStatus `
        -DestinationDirectory $DestinationDirectory
}else{
    if($PSBoundParameters.ContainsKey('DestinationDirectory')){throw 'Read 不接受 freeze 目标目录。'}
    $result=Read-TL1C1bDiscoveryEvidenceBundle -RepoRoot $RepoRoot -AttemptId $AttemptId `
        -ExpectedCommitSha $ExpectedCommitSha -RunId $RunId -TerminalStatus $TerminalStatus
}
$result|ConvertTo-Json -Depth 16 -Compress
