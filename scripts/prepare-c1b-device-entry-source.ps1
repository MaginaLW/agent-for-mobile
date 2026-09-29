#Requires -Version 7.6
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$RepoRoot,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommitSha,
 [Parameter(Mandatory)][string]$EntryRoot,
 [Parameter(Mandatory)][string]$ReviewDirectory,
 [Parameter(Mandatory)][string]$AuthorityPath,
 [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$AuthoritySha256,
 [Parameter(Mandatory)][string]$PwshPath
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
# Preparation writes review material only. No process, candidate stage or device entry is invoked.
. (Join-Path $PSScriptRoot 'lib/c1b-device-entry-source.ps1')
$RepoRoot=Get-C1bEntryCanonicalPath $RepoRoot;$EntryRoot=Get-C1bEntryCanonicalPath $EntryRoot
Assert-C1bEntry ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\','/') -ceq $RepoRoot) 'Run the prepare entry from the selected candidate repository.'
$ReviewDirectory=Get-C1bEntryCanonicalPath $ReviewDirectory;$PwshPath=Get-C1bEntryCanonicalPath $PwshPath
Assert-C1bEntry ([Environment]::ProcessPath -ceq $PwshPath -and $PSVersionTable.PSVersion.ToString() -ceq '7.6.5') 'Pinned runtime required.'
Assert-C1bEntryOrdinaryChain $AuthorityPath
$authorityBytes=[IO.File]::ReadAllBytes($AuthorityPath)
Assert-C1bEntry ((Get-C1bEntryHash $authorityBytes) -ceq $AuthoritySha256) 'A1 authority raw pin differs.'
$authority=ConvertFrom-C1bEntryJson $authorityBytes
Assert-C1bEntryKeys $authority @('repo_root','branch','git_entry_kind','git_index_sha256','git_index_byte_length','tracked_path_count','implementation_catalog_sha256','implementation_hashes','git_metadata')
Assert-C1bEntry ($authority.repo_root -ceq $RepoRoot) 'Authority repository differs.'
$strictPath=Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
$strictBytes=[IO.File]::ReadAllBytes($strictPath)
$strictPin=[ordered]@{path='scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1';sha256=(Get-C1bEntryHash $strictBytes);byte_length=$strictBytes.Length}
$native=$null;$answer=$null
try{
 $native=New-C1bEntryNativeContext $RepoRoot $strictPin.sha256 $strictPin.byte_length
 $null=Read-C1bEntryHeldFile $native $AuthorityPath $AuthoritySha256 $authorityBytes.Length
 $null=Read-C1bEntryHeldFile $native $PwshPath '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139' 301368 $false
 $dependencyPaths=[ordered]@{maintenance='scripts/lib/c1b-device-entry-source.ps1';host_acceptance='scripts/lib/c1b-host-acceptance.ps1';terminal_discovery='scripts/lib/c1b-terminal-discovery.ps1';terminal_discovery_bridge='scripts/read-c1b-terminal-discovery.ps1';host_capture='scripts/lib/c1b-host-process-capture.ps1'}
 $dependencyPins=[ordered]@{}
 foreach($name in $dependencyPaths.Keys){
  $path=Join-Path $RepoRoot $dependencyPaths[$name];Assert-C1bEntryOrdinaryChain $path
  $raw=[IO.File]::ReadAllBytes($path);$h=Read-C1bEntryHeldFile $native $path (Get-C1bEntryHash $raw) $raw.Length $false
  $dependencyPins[$name]=[ordered]@{path=$dependencyPaths[$name];byte_length=$h.Length;sha256=$h.Hash}
 }
 $templatePins=Get-C1bDeviceEntryTemplatePins $RepoRoot
 foreach($pin in $templatePins.Values){$null=Read-C1bEntryHeldFile $native (Join-Path $RepoRoot $pin.path) $pin.sha256 $pin.byte_length $false}
 $map=Get-C1bEntryImplementationPathMap $RepoRoot $authority.implementation_hashes.c1b_library_sha256.Substring(7)
 Assert-C1bEntryKeys $authority.implementation_hashes @($map.Keys)
 foreach($key in $map.Keys){$null=Read-C1bEntryHeldFile $native (Join-Path $RepoRoot $map[$key]) $authority.implementation_hashes[$key].Substring(7) -1 $false}
 $context=[ordered]@{schema='c1b-device-entry-generation-context/v1';candidate_sha=$ExpectedCommitSha;repo_root=$RepoRoot;entry_root=$EntryRoot;pwsh_path=$PwshPath;runtime_sha256='362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139';strict_pin=$strictPin;implementation_hashes=$authority.implementation_hashes;implementation_catalog_sha256=$authority.implementation_catalog_sha256;authority=$authority;dependency_pins=$dependencyPins;template_pins=$templatePins}
 Assert-C1bDeviceEntryGenerationContext $context
 Assert-C1bEntryCandidateAuthority $native $context
 $sources=New-C1bDeviceEntrySources $context
 Assert-C1bEntry (-not [IO.File]::Exists($ReviewDirectory) -and -not [IO.Directory]::Exists($ReviewDirectory)) 'Review directory already reserved; no overwrite.'
 Assert-C1bEntryOrdinaryChain ([IO.Path]::GetDirectoryName($ReviewDirectory))
 Add-C1bEntryHeldDirectories $native ([IO.Path]::GetDirectoryName($ReviewDirectory));Assert-C1bEntryHeld $native
 $null=New-Item -ItemType Directory -Path $ReviewDirectory -ErrorAction Stop
 $outputPins=[ordered]@{}
 foreach($leaf in $sources.Keys){
  $null=Write-C1bEntryNewReadonly $native (Join-Path $ReviewDirectory $leaf) $sources[$leaf]
  $outputPins[$leaf]=[ordered]@{path=(Join-Path $EntryRoot $leaf);byte_length=$sources[$leaf].Length;sha256=(Get-C1bEntryHash $sources[$leaf])}
 }
 $manifest=[ordered]@{schema='c1b-device-entry-source-manifest/v1';context=$context;outputs=$outputPins;source_pins=@($templatePins.Values)+@($dependencyPins.Values)+@($strictPin);device_execution_count=0}
 $manifestPin=Write-C1bEntryNewReadonly $native (Join-Path $ReviewDirectory 'source-manifest.json') ([Text.UTF8Encoding]::new($false).GetBytes(($manifest|ConvertTo-Json -Depth 50 -Compress)))
 Assert-C1bEntryHeld $native
 $answer=[ordered]@{schema='c1b-device-entry-source-preparation/v1';candidate_sha=$ExpectedCommitSha;manifest=$manifestPin;review_directory=$ReviewDirectory;output_count=$sources.Count;publication_performed=$false;ready_published=$false;device_execution_count=0;independent_source_review_required=$true}
}finally{Close-C1bEntryNativeContext $native}
$answer|ConvertTo-Json -Depth 10 -Compress
