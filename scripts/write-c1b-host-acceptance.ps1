#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateSha,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$InputMapPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$InputMapSha256,
    [Parameter(Mandatory)][string]$ContractPath
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'lib/c1b-host-acceptance.ps1')
$contract=Assert-C1bHostAcceptanceEvidence -CandidateSha $CandidateSha -EvidenceRoot $EvidenceRoot -InputMapPath $InputMapPath -InputMapSha256 $InputMapSha256
$root=Get-C1bHAPath $EvidenceRoot;$path=Get-C1bHAPath $ContractPath
Assert-C1bHA (Test-C1bHAWithin $path $root) 'Contract destination outside evidence root.'
$guard=New-C1bHASession @($root)
try {
    Open-C1bHADirectories $guard ([IO.Path]::GetDirectoryName($path))
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $contract -Depth 64)+"`n")
    # Parent chains remain held. CreateNew cannot overwrite another contract.
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,65536,[IO.FileOptions]::WriteThrough)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    $pin=@{path=$path;byte_length=[long]$bytes.Length;sha256=Get-C1bHASha256 $bytes};$null=Read-C1bHAFile $guard $pin
}finally{if($null-ne(Get-Variable bytes -Scope Local -ErrorAction SilentlyContinue)){[Array]::Clear($bytes,0,$bytes.Length)};Close-C1bHASession $guard}
[ordered]@{schema='c1b-host-acceptance-write-result/v1';candidate_sha=$CandidateSha;status='host_accepted_no_device';contract_pin=$pin;device_stage_started=$false}|Microsoft.PowerShell.Utility\ConvertTo-Json -Depth 4 -Compress
