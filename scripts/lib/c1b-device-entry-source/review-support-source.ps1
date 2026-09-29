#Requires -Version 7.6
# Formal maintenance template; runtime values bind only during reviewed generation.
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSelfSha256,
 [Parameter(Mandatory)][string]$ManifestPath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSha256
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$entryBootstrap=$null;$entryNative=$null
try {
 if([Environment]::ProcessPath -cne '__PWSH_PATH__' -or $PSVersionTable.PSVersion.ToString() -cne '7.6.5'){throw 'Pinned runtime required.'}
 $entryBootstrap=[IO.File]::Open('__DEPENDENCY_MAINTENANCE_PATH__',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
 if($entryBootstrap.Length -ne '__DEPENDENCY_MAINTENANCE_LENGTH__'){throw 'Maintenance source length differs.'}
 $entryBytes=[byte[]]::new([int]$entryBootstrap.Length);$entryBootstrap.ReadExactly($entryBytes)
 if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entryBytes)).ToLowerInvariant() -cne '__DEPENDENCY_MAINTENANCE_HASH__'){throw 'Maintenance source raw hash differs.'}
 . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($entryBytes)))
 $entryNative=New-C1bEntryNativeContext '__REPO_ROOT__' '__STRICT_VERIFIER_HASH__' '__STRICT_VERIFIER_LENGTH__'
 $null=Read-C1bEntryHeldFile $entryNative '__DEPENDENCY_MAINTENANCE_PATH__' '__DEPENDENCY_MAINTENANCE_HASH__' '__DEPENDENCY_MAINTENANCE_LENGTH__' $false
 $null=Read-C1bEntryHeldFile $entryNative $PSCommandPath $ExpectedSelfSha256
 $null=Read-C1bEntryHeldFile $entryNative '__PWSH_PATH__' '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139' 301368 $false
  $m=Assert-C1bDeviceEntryManifest $entryNative $ManifestPath $ManifestSha256
 $entryAnswer=[ordered]@{schema='c1b-device-entry-source-audit/v1';candidate_sha='__CANDIDATE_SHA__';manifest_sha256=$ManifestSha256;status='verified';maintenance_raw_pins=$m.source_pins;output_raw_pins=$m.outputs;deterministic_render_matches=$true;independent_semantic_review_required=$true;producer_invocations=0;device_invocations=0;formal_reservation_created=$false}
 Assert-C1bEntryHeld $entryNative
} finally {
 try{Close-C1bEntryNativeContext $entryNative}finally{if($null -ne $entryBootstrap){$entryBootstrap.Dispose()}}
}
$entryAnswer|ConvertTo-Json -Depth 50 -Compress
exit 0