#Requires -Version 7.6
# Formal maintenance template; runtime values bind only during reviewed generation.
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSelfSha256,
 [Parameter(Mandatory)][string]$ManifestPath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ManifestSha256,
 [Parameter(Mandatory)][string]$SourcePath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSourceSha256,
 [Parameter(Mandatory)][string]$ArgumentsJsonPath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ArgumentsSha256,
 [Parameter(Mandatory)][string]$OutputDirectory
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
 $capturePin=[ordered]@{path='scripts/lib/c1b-host-process-capture.ps1';byte_length='__DEPENDENCY_HOST_CAPTURE_LENGTH__';sha256='__DEPENDENCY_HOST_CAPTURE_HASH__'}
 $entryAnswer=Invoke-C1bDeviceEntryHostCapture $entryNative 'SourcePublicationOuter' $SourcePath $ExpectedSourceSha256 $ArgumentsJsonPath $ArgumentsSha256 $OutputDirectory '__PWSH_PATH__' '__CANDIDATE_SHA__' $capturePin $ManifestPath $ManifestSha256 $PSCommandPath $ExpectedSelfSha256
 Assert-C1bEntryHeld $entryNative
} finally {
 try{Close-C1bEntryNativeContext $entryNative}finally{if($null -ne $entryBootstrap){$entryBootstrap.Dispose()}}
}
$entryAnswer|ConvertTo-Json -Depth 50 -Compress
if($entryAnswer.capture.status -cne 'passed'){exit 1};exit 0