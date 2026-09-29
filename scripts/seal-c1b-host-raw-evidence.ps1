#Requires -Version 7.5
<#
.SYNOPSIS
Seal a caller-pinned exact host evidence inventory into one fresh raw archive.
.DESCRIPTION
Bindings use c1b-host-raw-archive-inputs/v1: schema, candidate_sha, run_id,
evidence_root, archive_directory, trusted_source_roots, ha_module_pin,
producer_source_pin, sources. Every source pin is path, byte_length, sha256.
The caller must hold the reviewed producer source before spawning this entry,
then independently capture its actual native exit, both stream EOFs and cleanup.
This entry performs no Git, build or device command, and never retries a namespace.
The canonical Git executable may register its complete independently held native
hardlink group; all group aliases must appear in the exact source inventory.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BindingsPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBindingsSha256
)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$utf8=[Text.UTF8Encoding]::new($false,$true)
$bootstrap=@();$session=$null;$primary=$null;$cleanupFailures=[Collections.Generic.List[Exception]]::new();$archivePin=$null;$inputsPin=$null;$reserved=$false;$b=$null
function Read-ArchiveBootstrap([string]$Path,[string]$ExpectedSha){
    if(-not[IO.Path]::IsPathFullyQualified($Path)-or[IO.Path]::GetFullPath($Path)-cne$Path){throw 'Bootstrap path must be canonical and absolute.'}
    # Load only the exact hash-admitted bytes, never dot-source a subsequently reopened path.
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length-gt8388608){throw 'Bootstrap input exceeds bound.'}
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()-cne$ExpectedSha){throw 'Bootstrap SHA mismatch.'}
        return [pscustomobject]@{Stream=$stream;Bytes=$bytes}
    }catch{$stream.Dispose();throw}
}
function Write-ArchiveNew([string]$Path,[byte[]]$Bytes){
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{
        $stream.Write($Bytes);$stream.Flush($true)
        # Set the path attribute while the newly created leaf still denies delete
        # and other writers; its already-held parent cannot be replaced either.
        [IO.File]::SetAttributes($Path,[IO.File]::GetAttributes($Path)-bor[IO.FileAttributes]::ReadOnly)
    }finally{$stream.Dispose()}
}
try{
    $inputBootstrap=Read-ArchiveBootstrap $BindingsPath $ExpectedBindingsSha256;$bootstrap+=,$inputBootstrap
    $initial=ConvertFrom-Json -InputObject ($utf8.GetString($inputBootstrap.Bytes)) -AsHashtable -Depth 32 -DateKind String
    if($initial-isnot[Collections.IDictionary]){throw 'Bootstrap input must be a JSON object.'}
    if($initial.ha_module_pin-isnot[Collections.IDictionary]-or$initial.ha_module_pin.path-isnot[string]-or$initial.ha_module_pin.sha256-isnot[string]-or$initial.ha_module_pin.sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'Bootstrap module raw pin types are invalid.'}
    if($initial.ha_module_pin.path-cne(Join-Path $PSScriptRoot 'lib\c1b-host-acceptance.ps1')){throw 'Archive bootstrap must use the colocated reviewed HA module.'}
    $moduleBootstrap=Read-ArchiveBootstrap $initial.ha_module_pin.path $initial.ha_module_pin.sha256;$bootstrap+=,$moduleBootstrap
    . ([scriptblock]::Create($utf8.GetString($moduleBootstrap.Bytes)))
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class C1bRawArchiveNativeV1 {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateDirectoryW(string path, IntPtr security);
    public static void CreateNewDirectory(string path) {
        if (!CreateDirectoryW(path, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@
    # Strict JSON + native no-follow/full ancestor/ordinary single-link guards now
    # re-read the same hash-admitted bootstrap files and hold all inputs to cleanup.
    $b=ConvertFrom-C1bHAStrictJson ($utf8.GetString($inputBootstrap.Bytes))
    Assert-C1bHAKeys $b @('schema','candidate_sha','run_id','evidence_root','archive_directory','trusted_source_roots','ha_module_pin','producer_source_pin','sources') 'archive bindings'
    Assert-C1bHA ($b.schema-is[string]-and$b.schema-ceq'c1b-host-raw-archive-inputs/v1') 'Archive inputs schema.'
    Assert-C1bHAString $b.candidate_sha '^[a-f0-9]{40}$' 'candidate SHA';Assert-C1bHAString $b.run_id '^[a-f0-9]{32}$' 'archive run ID'
    Assert-C1bHA ($b.candidate_sha-cne'4b37f344d5af988ce9b2f7610df98387a49cd2d0') 'Consumed candidate cannot be resealed.'
    Assert-C1bHA ($b.evidence_root-is[string]-and$b.archive_directory-is[string]) 'Archive root types invalid.'
    foreach($pin in @($b.ha_module_pin,$b.producer_source_pin)){
        Assert-C1bHAKeys $pin @('path','byte_length','sha256') 'archive source authority pin';Assert-C1bHA ($pin.path-is[string]) 'Source authority path must be a string.';Assert-C1bHAInt $pin.byte_length 0 8388608 'source authority bytes';Assert-C1bHAString $pin.sha256 '^[a-f0-9]{64}$' 'source authority hash'
    }
    $evidenceRoot=Get-C1bHAPath $b.evidence_root;$archiveDirectory=Get-C1bHAPath $b.archive_directory
    Assert-C1bHA (Test-C1bHAWithin (Get-C1bHAPath $BindingsPath) $evidenceRoot) 'Archive inputs outside evidence root.'
    Assert-C1bHA ((Test-C1bHAWithin $archiveDirectory $evidenceRoot)-and$archiveDirectory-cne$evidenceRoot) 'Archive namespace outside evidence root.'
    Assert-C1bHA ($b.trusted_source_roots-is[Array]-and$b.trusted_source_roots.Count-le32-and@($b.trusted_source_roots|Where-Object{$_-isnot[string]}).Count-eq0) 'Trusted source roots invalid.'
    $roots=@($evidenceRoot)+@($b.trusted_source_roots|ForEach-Object{Get-C1bHAPath $_})
    $session=New-C1bHASession $roots
    $inputsPin=Get-C1bHAObservedPin $session (Get-C1bHAPath $BindingsPath);Assert-C1bHA ($inputsPin.sha256-ceq$ExpectedBindingsSha256) 'Native held inputs differ from bootstrap.'
    $null=Read-C1bHAFile $session $b.ha_module_pin
    Assert-C1bHA ($b.producer_source_pin.path-ceq$PSCommandPath) 'Archive producer source path mismatch.';$null=Read-C1bHAFile $session $b.producer_source_pin
    Assert-C1bHA ($b.sources-is[Array]-and$b.sources.Count-ge1-and$b.sources.Count-le4096) 'Exact source inventory invalid.'
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pin in $b.sources){
        Assert-C1bHAKeys $pin @('path','byte_length','sha256') 'archive source pin';Assert-C1bHA ($pin.path-is[string]) 'Source path must be a string.';Assert-C1bHAInt $pin.byte_length 0 134217728 'source bytes';Assert-C1bHAString $pin.sha256 '^[a-f0-9]{64}$' 'source hash'
        $path=Get-C1bHAPath $pin.path;$inside=$false;foreach($root in $roots){if(Test-C1bHAWithin $path $root){$inside=$true;break}}
        Assert-C1bHA ($inside-and$paths.Add($path)-and-not(Test-C1bHAWithin $path $archiveDirectory)) 'Duplicate, escaped or recursive source inventory.'
        Assert-C1bHA ($path-cnotmatch'(?i)(^|\\)(afm-c1b-4b37f34|agent-for-mobile-c1b-candidate-20260929-r3)(\\|$)') 'Consumed candidate source forbidden.'
    }
    # Hold the existing parent before reserving an irreversible one-shot namespace.
    Open-C1bHADirectories $session ([IO.Path]::GetDirectoryName($archiveDirectory))
    Assert-C1bHA (-not[IO.Directory]::Exists($archiveDirectory)-and-not[IO.File]::Exists($archiveDirectory)) 'Archive namespace already reserved; retry forbidden.'
    [C1bRawArchiveNativeV1]::CreateNewDirectory($archiveDirectory);$reserved=$true;Open-C1bHADirectories $session $archiveDirectory
    Write-ArchiveNew (Join-Path $archiveDirectory 'reservation.json') ($utf8.GetBytes((@{schema='c1b-host-raw-archive-reservation/v1';candidate_sha=$b.candidate_sha;run_id=$b.run_id;inputs_pin=$inputsPin;automatic_retry_count=0}|ConvertTo-Json -Depth 8)+"`n"))
    $copies=Join-Path $archiveDirectory 'members';[C1bRawArchiveNativeV1]::CreateNewDirectory($copies);Open-C1bHADirectories $session $copies
    # The only admitted multi-link source is the independently guarded canonical
    # Git tool group. Register its complete native identity closure before the
    # ordinary single-link loop; every alias must also be in the exact inventory.
    $canonicalGit=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),'Git','cmd','git.exe')
    $gitPin=@($b.sources|Where-Object{$_.path-ceq$canonicalGit})
    if($gitPin.Count-eq1){
        $null=Read-C1bHAGitToolPin $session $gitPin[0]
        $gitIdentity=$session.files[$canonicalGit].identity.Id
        foreach($entry in $session.files.GetEnumerator()){
            if($entry.Value.identity.Id-ceq$gitIdentity){Assert-C1bHA ($paths.Contains($entry.Key)) 'Canonical Git alias missing from exact archive inventory.'}
        }
    }
    $members=[Collections.Generic.List[object]]::new();$ordinal=0
    foreach($sourcePin in $b.sources){
        $bytes=Read-C1bHAFile $session $sourcePin;$ordinal++
        $copyPath=Join-Path $copies ($ordinal.ToString('D6')+'.bin')
        Write-ArchiveNew $copyPath $bytes
        $copyPin=@{path=$copyPath;byte_length=$sourcePin.byte_length;sha256=$sourcePin.sha256};$copy=Read-C1bHAFile $session $copyPin
        Assert-C1bHA ($copy.Length-eq$bytes.Length-and(Get-C1bHASha256 $copy)-ceq(Get-C1bHASha256 $bytes)) 'Actual copy differs from held source.'
        $members.Add([ordered]@{source_pin=$sourcePin;copy_pin=$copyPin})
    }
    $manifest=[ordered]@{schema='c1b-host-raw-archive/v1';candidate_sha=$b.candidate_sha;status='sealed_raw_archive';source_mutation_count=0;cleanup_failure_count=0;members=$members.ToArray()}
    $manifestPath=Join-Path $archiveDirectory 'archive.json';Write-ArchiveNew $manifestPath ($utf8.GetBytes(($manifest|ConvertTo-Json -Depth 12)+"`n"))
    $archivePin=Get-C1bHAObservedPin $session $manifestPath
}catch{$primary=$_}
if($null-ne$session){try{Close-C1bHASession $session}catch{$cleanupFailures.Add($_.Exception)}}
foreach($item in $bootstrap){try{$item.Stream.Dispose()}catch{$cleanupFailures.Add($_.Exception)}finally{if($item.Bytes.Length){[Array]::Clear($item.Bytes,0,$item.Bytes.Length)}}}
if($null-ne$primary-or$cleanupFailures.Count-ne0){
    # Preserve failed reservation/copies. Never repair, delete or retry this namespace.
    # All ancestor guards have now been released. Publish no diagnostic file through
    # an unguarded path; the independent outer capture keeps this actual failure.
    if($reserved){[Console]::Error.WriteLine('Raw archive failed; reserved namespace remains consumed.')}
    else{[Console]::Error.WriteLine('Raw archive failed before namespace reservation.')}
    exit 1
}
# This report is emitted only after native held input/copy cleanup. An independent
# outer capture/root observation must bind the actual producer PID and native exit.
[ordered]@{schema='c1b-host-raw-archive-write/v1';candidate_sha=$b.candidate_sha;run_id=$b.run_id;status='sealed_raw_archive';archive_pin=$archivePin;inputs_pin=$inputsPin;producer_source_pin=$b.producer_source_pin;producer_process_id=$PID}|ConvertTo-Json -Compress -Depth 8
exit 0
