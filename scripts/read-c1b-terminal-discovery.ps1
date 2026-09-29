#Requires -Version 7.6
[CmdletBinding()]param(
    [Parameter(Mandatory)][ValidateSet('Read','Freeze',IgnoreCase=$false)][string]$Mode,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{40}$')][string]$ExpectedCommitSha,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ExpectedSelfSha256,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ExpectedLibrarySha256,
    [Parameter(Mandatory)][string]$SourcePinsPath,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$SourcePinsSha256,
    [Parameter(Mandatory)][string]$TerminalReadbackPath,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$TerminalReadbackSha256,
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ObservationSha256,
    [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ExpectedBindingSha256
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version 3.0
$context=$null;$bootstrap=$null;$pinStream=$null;$primary=$null;$cleanup=$null;$answer=$null
try {
    # Only externally pinned library bytes are evaluated before native no-follow guards.
    $library=Join-Path $PSScriptRoot 'lib/c1b-terminal-discovery.ps1'
    $cursor=[IO.Path]::GetFullPath($library)
    while ($cursor) {
        if (([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0) { throw 'Library bootstrap reparse path rejected.' }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    $bootstrap=[IO.File]::Open($library,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if ($bootstrap.Length -notin 1..4194304) { throw 'Library bootstrap length outside bounds.' }
    $bytes=[byte[]]::new([int]$bootstrap.Length);$bootstrap.ReadExactly($bytes)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $ExpectedLibrarySha256) { throw 'Library bootstrap hash differs.' }
    . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($bytes)))
    Assert-C1bTdOrdinaryPath $SourcePinsPath
    $pinStream=[IO.File]::Open($SourcePinsPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    Assert-C1bTd ($pinStream.Length -in 1..65536) 'Source pin manifest length outside bounds.'
    $pinBytes=[byte[]]::new([int]$pinStream.Length);$pinStream.ReadExactly($pinBytes)
    Assert-C1bTd ((Get-C1bTdHash $pinBytes) -ceq $SourcePinsSha256) 'Source pin manifest raw hash differs.'
    $pins=ConvertFrom-C1bTdJson $pinBytes
    $context=New-C1bTerminalDiscoveryContext $RepoRoot $ExpectedCommitSha $pins
    [void](Add-C1bTdHeldFile $context $library $ExpectedLibrarySha256)
    [void](Add-C1bTdHeldFile $context $PSCommandPath $ExpectedSelfSha256)
    [void](Add-C1bTdHeldFile $context $SourcePinsPath $SourcePinsSha256 $pinBytes.Length)
    $authorityArgs=@{Context=$context;TerminalReadbackPath=$TerminalReadbackPath;TerminalReadbackSha256=$TerminalReadbackSha256;
        ReceiptRoot=$ReceiptRoot;ObservationSha256=$ObservationSha256;ExpectedBindingSha256=$ExpectedBindingSha256}
    if ($Mode -ceq 'Freeze') {
        $answer=Invoke-C1bTerminalDiscoveryFreeze @authorityArgs
    } else {
        $authority=Read-C1bTerminalDiscoveryAuthority @authorityArgs
        $identity=$authority.identity;$read=$null
        if ($identity.status -ceq 'verified') {
            $read=Invoke-C1bTdPinnedReader $context Read $identity $authority.terminal_status
            Assert-C1bTdConsumption $context $read $identity $authority.terminal_status
        }
        $answer=[ordered]@{schema='c1b-terminal-discovery-read/v1';candidate_sha=$ExpectedCommitSha;discovery_identity=$identity;read=$read;
            freeze_performed=$false;device_acceptance_proven_by_this_read=$false;device_or_adb_invocations=0}
    }
    Assert-C1bTdContextBound $context
} catch { $primary=$_.Exception }
finally {
    if ($null -ne $context) { try { Close-C1bTerminalDiscoveryContext $context } catch { $cleanup=$_.Exception } }
    if ($null -ne $pinStream) { $pinStream.Dispose() }
    if ($null -ne $bootstrap) { $bootstrap.Dispose() }
}
if ($null -ne $primary) {
    if ($null -ne $cleanup) { throw [AggregateException]::new('Terminal discovery primary and cleanup failures; never retry Freeze.',[Exception[]]@($primary,$cleanup)) }
    throw $primary
}
if ($null -ne $cleanup) { throw $cleanup }
$answer.cleanup_failure_count=0
$answer | ConvertTo-Json -Depth 30 -Compress
