#Requires -Version 7.5
<#!
.SYNOPSIS
Captures four bounded read-only Git A1 queries for a fresh ordinary clone.
.DESCRIPTION
Preparation only. The caller selects a new, unfrozen clone and pins Git, runtime
and capture source. This script never builds, freezes, runs a launcher or uses ADB.
Frozen/post-BuildOnly candidate directories are rejected before Git can start.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CandidateSha,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$AuditRunId,
    [Parameter(Mandatory)][ValidateSet('UnfrozenPreparation')][string]$CandidateState,
    [Parameter(Mandatory)][string]$GitPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedGitSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedRuntimeSha256,
    [Parameter(Mandatory)][string]$CaptureSourcePath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedCaptureSourceSha256,
    [Parameter(Mandatory)][string]$EvidenceDirectory
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)

if($null-eq('C1bA1NativeV1'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
using Microsoft.Win32.SafeHandles;
public sealed class C1bA1IdentityV1 {
 public uint Attributes,Links; public ulong Length; public long WriteTime; public string Id;
}
public static class C1bA1NativeV1 {
 [StructLayout(LayoutKind.Sequential)] struct FT {public uint Low,High;}
 [StructLayout(LayoutKind.Sequential)] struct Info {public uint Attributes;public FT Created,Accessed,Written;public uint Volume,High,Low,Links,IndexHigh,IndexLow;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr x,uint d,uint f,IntPtr t);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint n,uint f);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr FindFirstFileNameW(string p,uint f,ref uint n,StringBuilder b);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool FindNextFileNameW(IntPtr h,ref uint n,StringBuilder b);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool FindClose(IntPtr h);
 public static string[] LinkNames(string path) {
  var result=new List<string>();uint n=32768;var b=new StringBuilder(32768);var h=FindFirstFileNameW(path,0,ref n,b);
  if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
  try{result.Add(b.ToString());for(;;){n=32768;b.Clear();if(!FindNextFileNameW(h,ref n,b)){int e=Marshal.GetLastWin32Error();if(e!=38)throw new Win32Exception(e);break;}result.Add(b.ToString());if(result.Count>100000)throw new InvalidOperationException("Hardlink bound.");}}
  finally{if(!FindClose(h))throw new Win32Exception(Marshal.GetLastWin32Error());}return result.ToArray();
 }
 public static SafeFileHandle Open(string p,bool directory) {
  var h=CreateFileW(p,directory?0x81u:0x80000000u,directory?3u:1u,IntPtr.Zero,3u,directory?0x02200000u:0x08200080u,IntPtr.Zero);
  if(h.IsInvalid){int e=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(e);}return h;
 }
 public static C1bA1IdentityV1 Identity(SafeFileHandle h) {
  Info i;if(!GetFileInformationByHandle(h,out i))throw new Win32Exception(Marshal.GetLastWin32Error());
  return new C1bA1IdentityV1 {Attributes=i.Attributes,Links=i.Links,Length=((ulong)i.High<<32)|i.Low,
   WriteTime=unchecked((long)(((ulong)i.Written.High<<32)|i.Written.Low)),Id=i.Volume.ToString("X8")+":"+i.IndexHigh.ToString("X8")+i.IndexLow.ToString("X8")};
 }
 public static string FinalPath(SafeFileHandle h) {
  var b=new StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);
  if(n==0||n>=b.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());
  string p=b.ToString();if(p.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))return @"\\"+p.Substring(8);
  return p.StartsWith(@"\\?\",StringComparison.Ordinal)?p.Substring(4):p;
 }
}
'@
}

function Assert-C1bA1([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Get-C1bA1Sha([byte[]]$Bytes){return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function ConvertFrom-C1bA1Utf8([byte[]]$Bytes){
    Assert-C1bA1 (-not($Bytes.Length-ge3-and$Bytes[0]-eq239-and$Bytes[1]-eq187-and$Bytes[2]-eq191)) 'UTF8 BOM rejected.'
    return [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
}
function Get-C1bA1Path([string]$Path){
    Assert-C1bA1 ([IO.Path]::IsPathFullyQualified($Path)-and-not$Path.Contains([char]0)) 'A1 paths must be absolute and NUL-free.'
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-C1bA1 ($full-cnotmatch'^\\\\|:' -or $full-cmatch'^[A-Za-z]:\\[^:]*$') 'A1 local drive path required.'
    return $full
}
function New-C1bA1Session {
    return @{directories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);order=[Collections.Generic.List[object]]::new()}
}
function Open-C1bA1Directories($Session,[string]$Path){
    $path=Get-C1bA1Path $Path;$chain=[Collections.Generic.List[string]]::new();$cursor=$path
    while($null-ne$cursor){$chain.Insert(0,$cursor);$parent=[IO.Directory]::GetParent($cursor);$cursor=if($null-eq$parent){$null}else{$parent.FullName}}
    foreach($item in $chain){
        if($Session.directories.ContainsKey($item)){continue}
        $h=[C1bA1NativeV1]::Open($item,$true)
        try{$i=[C1bA1NativeV1]::Identity($h);Assert-C1bA1 (($i.Attributes-band0x410)-eq0x10) 'A1 directory reparse/non-directory rejected.';Assert-C1bA1 ([string]::Equals([C1bA1NativeV1]::FinalPath($h),$item,[StringComparison]::OrdinalIgnoreCase)) 'A1 directory final path mismatch.'
            $entry=@{kind='directory';path=$item;handle=$h;identity=$i};$Session.directories.Add($item,$entry);$Session.order.Add($entry);$h=$null
        }finally{if($null-ne$h){$h.Dispose()}}
    }
}
function Read-C1bA1HeldFile($Session,[string]$Path,[long]$MaximumBytes=16777216,[long]$MaximumLinks=1){
    $path=Get-C1bA1Path $Path
    if(-not$Session.files.ContainsKey($path)){
        Open-C1bA1Directories $Session ([IO.Path]::GetDirectoryName($path));$h=[C1bA1NativeV1]::Open($path,$false)
        try{$i=[C1bA1NativeV1]::Identity($h);Assert-C1bA1 (($i.Attributes-band0x410)-eq0-and$i.Links-ge1-and$i.Links-le$MaximumLinks-and$i.Length-le$MaximumBytes) "A1 file type/link/bounds rejected: $path (links=$($i.Links), bytes=$($i.Length)).";Assert-C1bA1 ([string]::Equals([C1bA1NativeV1]::FinalPath($h),$path,[StringComparison]::OrdinalIgnoreCase)) 'A1 file final path mismatch.'
            $entry=@{kind='file';path=$path;handle=$h;identity=$i;pin=$null};$Session.files.Add($path,$entry);$Session.order.Add($entry);$h=$null
        }finally{if($null-ne$h){$h.Dispose()}}
    }
    $entry=$Session.files[$path];$i=[C1bA1NativeV1]::Identity($entry.handle)
    Assert-C1bA1 ($i.Length-le$MaximumBytes-and$i.Id-ceq$entry.identity.Id-and$i.Length-eq$entry.identity.Length-and$i.WriteTime-eq$entry.identity.WriteTime-and$i.Links-eq$entry.identity.Links-and($i.Attributes-band0x410)-eq0) 'A1 held file identity drift.'
    $alias=[Microsoft.Win32.SafeHandles.SafeFileHandle]::new($entry.handle.DangerousGetHandle(),$false);$stream=[IO.FileStream]::new($alias,[IO.FileAccess]::Read,65536,$false)
    try{$stream.Position=0;$bytes=[byte[]]::new([int]$i.Length);$offset=0;while($offset-lt$bytes.Length){$n=$stream.Read($bytes,$offset,$bytes.Length-$offset);Assert-C1bA1 ($n-gt0) 'A1 held file truncated.';$offset+=$n};Assert-C1bA1 ($stream.ReadByte()-eq-1) 'A1 held file grew.'}finally{$stream.Dispose()}
    $hash=Get-C1bA1Sha $bytes
    if($null-ne$entry.pin){Assert-C1bA1 ($hash-ceq$entry.pin.sha256) 'A1 held file hash drift.'}
    $entry.pin=@{path=$path;byte_length=[long]$bytes.Length;sha256=$hash}
    return ,$bytes
}
function Get-C1bA1Pin($Session,[string]$Path,[long]$MaximumBytes=16777216,[long]$MaximumLinks=1){$null=Read-C1bA1HeldFile $Session $Path $MaximumBytes $MaximumLinks;return $Session.files[(Get-C1bA1Path $Path)].pin}
function Assert-C1bA1ToolLinks($Session,[string]$Path,[string]$ToolRoot){
    $entry=$Session.files[$Path];$names=[C1bA1NativeV1]::LinkNames($Path);Assert-C1bA1 ($names.Count-eq$entry.identity.Links) 'A1 tool hardlinks incomplete.'
    $volume=[IO.Path]::GetPathRoot($Path);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $names){
        $alias=Get-C1bA1Path (Join-Path $volume $name.TrimStart('\'))
        Assert-C1bA1 ($seen.Add($alias)-and$alias.StartsWith($ToolRoot+'\',[StringComparison]::OrdinalIgnoreCase)) 'A1 tool hardlink outside controlled tree.'
        $pin=Get-C1bA1Pin $Session $alias 134217728 $entry.identity.Links
        Assert-C1bA1 ($Session.files[$alias].identity.Id-ceq$entry.identity.Id-and$pin.sha256-ceq$entry.pin.sha256) 'A1 tool hardlink native identity/hash mismatch.'
    }
}
function Assert-C1bA1Absent($Session,[string]$Path){
    Open-C1bA1Directories $Session ([IO.Path]::GetDirectoryName($Path))
    try{$null=[IO.File]::GetAttributes($Path);throw 'A1 forbidden metadata/marker exists.'}
    catch [IO.FileNotFoundException]{} catch [IO.DirectoryNotFoundException]{}
}
function Assert-C1bA1Preparation($Session,[string]$Root){
    Open-C1bA1Directories $Session $Root;Open-C1bA1Directories $Session (Join-Path $Root '.git')
    Open-C1bA1Directories $Session (Join-Path $Root '.git\objects');Open-C1bA1Directories $Session (Join-Path $Root '.git\objects\info')
    foreach($relative in @('.git\commondir','.git\shallow','.git\worktrees','.git\objects\info\alternates','.git\objects\info\http-alternates')){Assert-C1bA1Absent $Session (Join-Path $Root $relative)}
    $checks=Join-Path $Root '.checks'
    if([IO.Directory]::Exists($checks)){
        Open-C1bA1Directories $Session $checks
        foreach($item in [IO.Directory]::EnumerateFileSystemEntries($checks)){
            $leaf=[IO.Path]::GetFileName($item)
            Assert-C1bA1 ($leaf-cnotmatch'(?i)(?:c1b.*(?:candidate-a[345]|preflight|build.?only|ready|frozen)|tablet-c1b-real-build-smoke|candidate-a[345])') 'A1 frozen/post-BuildOnly marker; ordinary Git forbidden.'
        }
    }elseif([IO.File]::Exists($checks)){throw 'A1 .checks must be ordinary directory or absent.'}
}
function Assert-C1bA1Unconsumed([string]$Sha,[string]$Root){
    Assert-C1bA1 ($Sha-cne'4b37f344d5af988ce9b2f7610df98387a49cd2d0') 'A1 consumed 4b37f34 SHA; ordinary Git forbidden.'
    Assert-C1bA1 ($Root.Split('\')-inotcontains'agent-for-mobile-c1b-candidate-20260929-r3') 'A1 historical consumed clone component; ordinary Git forbidden.'
}
function Get-C1bA1Environment {
    $system=[Environment]::SystemDirectory;$windows=[IO.Directory]::GetParent($system).FullName
    $profile=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile);$temp=[IO.Path]::GetTempPath().TrimEnd('\','/')
    return [ordered]@{SYSTEMROOT=$windows;WINDIR=$windows;COMSPEC=(Join-Path $system 'cmd.exe');PATHEXT='.COM;.EXE;.BAT;.CMD';PATH=$system;TEMP=$temp;TMP=$temp;USERPROFILE=$profile;HOME=$profile;GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL='NUL';GIT_CONFIG_COUNT='0';GIT_TERMINAL_PROMPT='0';GCM_INTERACTIVE='Never';GIT_OPTIONAL_LOCKS='0'}
}
function Get-C1bA1ObjectStore($Session,[string]$Root){
    $objects=Join-Path $Root '.git\objects';$pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($objects)
    $pins=[Collections.Generic.List[object]]::new();$directoryCount=0
    while($pending.Count-gt0){
        $directory=$pending.Dequeue();Open-C1bA1Directories $Session $directory;$directoryCount++
        Assert-C1bA1 ($directoryCount-le100000) 'A1 object directory bound exceeded.'
        foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)){
            $attributes=[IO.File]::GetAttributes($entry);Assert-C1bA1 (($attributes-band[IO.FileAttributes]::ReparsePoint)-eq0) 'A1 object store reparse entry rejected.'
            if(($attributes-band[IO.FileAttributes]::Directory)-ne0){$pending.Enqueue($entry)}else{
                Assert-C1bA1 ($pins.Count-lt100000) 'A1 object file bound exceeded.';$pins.Add((Get-C1bA1Pin $Session $entry 134217728))
            }
        }
    }
    return @{root=$objects;ordinary_directory_count=$directoryCount;file_count=$pins.Count;single_link_verified=$true;object_pins=$pins.ToArray();no_alternates=$true;no_commondir=$true;cleanup_failure_count=0}
}
function Get-C1bA1Map([byte[]]$Source){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput((ConvertFrom-C1bA1Utf8 $Source),[ref]$tokens,[ref]$errors)
    Assert-C1bA1 ($errors.Count-eq0) 'A1 map parser failed.'
    $assign=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left-is[Management.Automation.Language.VariableExpressionAst]-and$n.Left.VariablePath.UserPath-ceq'script:TL1C1bImplementationPathMap'},$true));Assert-C1bA1 ($assign.Count-eq1) 'A1 literal map declaration cardinality.'
    $maps=@($assign[0].Right.FindAll({param($n)$n-is[Management.Automation.Language.HashtableAst]},$true));Assert-C1bA1 ($maps.Count-eq1-and$maps[0].KeyValuePairs.Count-eq42) 'A1 literal implementation map requires42 entries.'
    $result=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($pair in $maps[0].KeyValuePairs){
        Assert-C1bA1 ($pair.Item1-is[Management.Automation.Language.StringConstantExpressionAst]) 'A1 map key must be literal.'
        $values=@($pair.Item2.FindAll({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]},$true));Assert-C1bA1 ($values.Count-eq1-and$pair.Item2.Extent.Text.Trim()-ceq$values[0].Extent.Text) 'A1 map path must be literal.'
        $key=$pair.Item1.Value;$value=$values[0].Value;Assert-C1bA1 ($key-cmatch'^[a-z0-9_]+_sha256$'-and$value-cmatch'^(scripts|docs|app)/'-and$value-cnotmatch'(^|/)\.{1,2}(/|$)|\\|:|[\x00-\x1f]'-and$result.TryAdd($key,$value)-and$paths.Add($value)) 'A1 implementation key/path unsafe or duplicate.'
    }
    Assert-C1bA1 ($result.ContainsKey('c1b_library_sha256')-and$result['c1b_library_sha256']-ceq'scripts/lib/tablet-layout-c1b.ps1') 'A1 map self authority binding.'
    return ,$result
}
function Get-C1bA1Index([byte[]]$Bytes){
    Assert-C1bA1 ($Bytes.Length-ge32-and[Text.Encoding]::ASCII.GetString($Bytes,0,4)-ceq'DIRC') 'A1 index header.'
    function U32([int]$At){Assert-C1bA1 ($At-ge0-and$At+4-le$Bytes.Length-20) 'A1 index U32 bounds.';return ([long]$Bytes[$At]*16777216+[long]$Bytes[$At+1]*65536+[long]$Bytes[$At+2]*256+[long]$Bytes[$At+3])}
    $version=U32 4;$count=U32 8;Assert-C1bA1 ($version-in@(2,3)-and$count-gt0-and$count-le100000) 'A1 index v2/v3/count required.'
    $body=[byte[]]::new($Bytes.Length-20);[Array]::Copy($Bytes,$body,$body.Length);$sha=[Security.Cryptography.SHA1]::HashData($body)
    for($i=0;$i-lt20;$i++){Assert-C1bA1 ($sha[$i]-eq$Bytes[$Bytes.Length-20+$i]) 'A1 index checksum.'}
    $entries=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);$at=12
    for($n=0;$n-lt$count;$n++){
        $start=$at;Assert-C1bA1 ($at+62-lt$Bytes.Length-20) 'A1 index truncated entry.';$mode=U32 ($at+24);Assert-C1bA1 ($mode-in@(33188,33261)) 'A1 index ordinary mode required.'
        $blob=[Convert]::ToHexString($Bytes[($at+40)..($at+59)]).ToLowerInvariant();$flags=[int]$Bytes[$at+60]*256+$Bytes[$at+61];Assert-C1bA1 (($flags-band0xf000)-eq0) 'A1 index stage/special flags rejected.'
        $at+=62;$pathStart=$at;while($at-lt$Bytes.Length-20-and$Bytes[$at]-ne0){$at++};Assert-C1bA1 ($at-lt$Bytes.Length-20) 'A1 index path terminated.'
        $path=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes,$pathStart,$at-$pathStart);Assert-C1bA1 ($path-cnotmatch'(^/|\\|(^|/)\.{1,2}(/|$)|[\x00-\x1f])'-and$path.Length-gt0-and$entries.TryAdd($path,$blob)) 'A1 index unsafe/duplicate path.'
        Assert-C1bA1 (($flags-band0xfff)-eq[Math]::Min(4095,$at-$pathStart)) 'A1 index path length flags mismatch.'
        $padding=(8-(($at-$start+1)%8))%8;$at++;Assert-C1bA1 ($at+$padding-le$Bytes.Length-20) 'A1 index padding bound.'
        for($p=0;$p-lt$padding;$p++){Assert-C1bA1 ($Bytes[$at+$p]-eq0) 'A1 index nonzero padding.'};$at+=$padding
    }
    while($at-lt$Bytes.Length-20){Assert-C1bA1 ($at+8-le$Bytes.Length-20) 'A1 index extension header.';$sig=[Text.Encoding]::ASCII.GetString($Bytes,$at,4);Assert-C1bA1 ($sig-cmatch'^[A-Z][A-Za-z]{3}$') 'A1 index mandatory extension rejected.';$length=U32 ($at+4);$at+=8+$length;Assert-C1bA1 ($at-le$Bytes.Length-20) 'A1 index extension bounds.'}
    return ,$entries
}
function Assert-C1bA1Query([string]$Phase,[byte[]]$Bytes,[string]$Sha,[string]$Branch,$Index){
    $text=ConvertFrom-C1bA1Utf8 $Bytes
    switch -CaseSensitive ($Phase){
        A1Head {Assert-C1bA1 ($text-cmatch('^'+[regex]::Escape($Sha)+'\r?\n$')) 'A1 captured HEAD mismatch.'}
        A1Branch {Assert-C1bA1 ($text-cmatch('^'+[regex]::Escape($Branch)+'\r?\n$')) 'A1 captured branch mismatch.'}
        A1Status {Assert-C1bA1 ($Bytes.Length-eq0) 'A1 captured worktree must be exactly empty clean status.'}
        A1Tree {
            Assert-C1bA1 ($text.Length-gt0-and$text.EndsWith([string][char]0)) 'A1 binary tree NUL termination required.'
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($row in $text.Substring(0,$text.Length-1).Split([char]0)){
                Assert-C1bA1 ($row-cmatch'^(100644|100755) blob ([0-9a-f]{40})\t([^\x00]+)$') 'A1 tree ordinary file record required.'
                $oid=$Matches[2];$path=$Matches[3];Assert-C1bA1 ($seen.Add($path)-and$Index.ContainsKey($path)-and$Index[$path]-ceq$oid) 'A1 tree/index mismatch.'
            }
            Assert-C1bA1 ($seen.Count-eq$Index.Count) 'A1 tree/index extra or missing paths.'
        }
        default {throw 'A1 phase unsupported.'}
    }
}
function Save-C1bA1NewJson([string]$Path,$Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 20)+"`n")
    $s=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$s.Write($bytes);$s.Flush($true)}finally{$s.Dispose()}
}
function Close-C1bA1Session($Session){
    $errors=[Collections.Generic.List[string]]::new()
    for($n=$Session.order.Count-1;$n-ge0;$n--){$e=$Session.order[$n]
        try{$i=[C1bA1NativeV1]::Identity($e.handle);Assert-C1bA1 ($i.Id-ceq$e.identity.Id-and($i.Attributes-band0x400)-eq0-and[string]::Equals([C1bA1NativeV1]::FinalPath($e.handle),$e.path,[StringComparison]::OrdinalIgnoreCase)) 'A1 terminal identity/path drift.'
            if($e.kind-ceq'file'){$null=Read-C1bA1HeldFile $Session $e.path 134217728}
        }catch{$errors.Add($_.Exception.Message)}finally{try{$e.handle.Dispose()}catch{$errors.Add('A1 held handle disposal failed.')}}
    }
    return ,$errors
}

$session=New-C1bA1Session;$outputSession=New-C1bA1Session;$audits=[Collections.Generic.List[object]]::new();$invocations=[Collections.Generic.List[object]]::new();$receipt=$null;$failure=$null;$reserved=$false;$resultExit=1
try{
    Assert-C1bA1 $IsWindows 'A1 requires Windows native file/Job authority.'
    $repo=Get-C1bA1Path $RepositoryRoot;$evidence=Get-C1bA1Path $EvidenceDirectory;$git=Get-C1bA1Path $GitPath;$captureSource=Get-C1bA1Path $CaptureSourcePath
    Assert-C1bA1Unconsumed $CandidateSha $repo
    Assert-C1bA1 (-not($evidence.Equals($repo,[StringComparison]::OrdinalIgnoreCase)-or$evidence.StartsWith($repo+'\',[StringComparison]::OrdinalIgnoreCase))) 'A1 evidence must be outside candidate clone.'
    Assert-C1bA1 ([string]::Equals($git,(Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Git\cmd\git.exe'),[StringComparison]::OrdinalIgnoreCase)) 'A1 canonical Git executable required.'
    Assert-C1bA1 (-not[IO.Directory]::Exists($evidence)-and-not[IO.File]::Exists($evidence)) 'A1 evidence already reserved; no automatic retry.'
    Open-C1bA1Directories $outputSession ([IO.Path]::GetDirectoryName($evidence));Assert-C1bA1Preparation $session $repo
    $gitPin=Get-C1bA1Pin $session $git 134217728 100000;Assert-C1bA1 ($gitPin.sha256-ceq$ExpectedGitSha256) 'A1 Git executable pin mismatch.'
    $gitToolRoot=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Git';Assert-C1bA1ToolLinks $session $git $gitToolRoot
    $runtimePin=Get-C1bA1Pin $session ([Environment]::ProcessPath) 134217728;Assert-C1bA1 ($runtimePin.sha256-ceq$ExpectedRuntimeSha256) 'A1 current runtime pin mismatch.'
    $sourcePin=Get-C1bA1Pin $session $PSCommandPath 1048576;$captureBytes=Read-C1bA1HeldFile $session $captureSource 1048576;$capturePin=$session.files[$captureSource].pin
    Assert-C1bA1 ($capturePin.sha256-ceq$ExpectedCaptureSourceSha256) 'A1 capture source pin mismatch.'
    $captureText=ConvertFrom-C1bA1Utf8 $captureBytes;$tok=$null;$err=$null;$null=[Management.Automation.Language.Parser]::ParseInput($captureText,[ref]$tok,[ref]$err);Assert-C1bA1 ($err.Count-eq0) 'A1 capture source parser failed.'
    . ([scriptblock]::Create($captureText))
    $headPath=Join-Path $repo '.git\HEAD';$head=ConvertFrom-C1bA1Utf8 (Read-C1bA1HeldFile $session $headPath 65536)
    Assert-C1bA1 ($head-cmatch'^ref: refs/heads/([^\r\n]+)\r?\n$') 'A1 ordinary named branch required.';$branch=$Matches[1]
    Assert-C1bA1 ($branch-cnotmatch'\.\.|[\\: ]|[\x00-\x1f]|(^|/)\.(?:/|$)|@\{') 'A1 branch unsafe.'
    $metadata=[ordered]@{head=(Get-C1bA1Pin $session $headPath);ref=(Get-C1bA1Pin $session (Join-Path $repo ('.git\refs\heads\'+$branch.Replace('/','\'))));config=(Get-C1bA1Pin $session (Join-Path $repo '.git\config'));info_exclude=(Get-C1bA1Pin $session (Join-Path $repo '.git\info\exclude'));gitattributes=(Get-C1bA1Pin $session (Join-Path $repo '.gitattributes'));gitignore=(Get-C1bA1Pin $session (Join-Path $repo '.gitignore'))}
    Assert-C1bA1 ((ConvertFrom-C1bA1Utf8 (Read-C1bA1HeldFile $session $metadata.ref.path))-cmatch('^'+[regex]::Escape($CandidateSha)+'\r?\n$')) 'A1 raw branch ref does not match candidate.'
    $config=ConvertFrom-C1bA1Utf8 (Read-C1bA1HeldFile $session $metadata.config.path)
    Assert-C1bA1 ($config-cnotmatch'(?im)^\s*\[(?:include|includeIf|filter|extensions)(?:\s|\])|^\s*(?:worktree|fsmonitor|hooksPath|attributesFile|excludesFile)\s*=') 'A1 unsafe external Git configuration rejected.'
    $objectStore=Get-C1bA1ObjectStore $session $repo
    $indexPin=Get-C1bA1Pin $session (Join-Path $repo '.git\index');$index=Get-C1bA1Index (Read-C1bA1HeldFile $session $indexPin.path)
    $mapPath=Join-Path $repo 'scripts\lib\tablet-layout-c1b.ps1';$mapPin=Get-C1bA1Pin $session $mapPath;$map=Get-C1bA1Map (Read-C1bA1HeldFile $session $mapPath)
    $implementation=[ordered]@{};$catalog=[Collections.Generic.List[string]]::new();foreach($entry in $map.GetEnumerator()){
        Assert-C1bA1 ($index.ContainsKey($entry.Value)) 'A1 implementation input absent from index.';$pin=Get-C1bA1Pin $session (Join-Path $repo $entry.Value.Replace('/','\'));$implementation[$entry.Key]=$pin;$catalog.Add($entry.Value+'=sha256:'+$pin.sha256)
    }
    [void][IO.Directory]::CreateDirectory($evidence);Open-C1bA1Directories $outputSession $evidence
    Save-C1bA1NewJson (Join-Path $evidence 'reservation.json') @{schema='c1b-candidate-authority-reservation/v1';candidate_sha=$CandidateSha;parent_process_id=$PID;automatic_retry_count=0;caller_declared_candidate_state=$CandidateState};$reserved=$true
    $catalogPath=Join-Path $evidence 'implementation-inputs.json';$catalogEntries=[Collections.Generic.List[object]]::new()
    foreach($entry in $map.GetEnumerator()){$pin=$implementation[$entry.Key];$catalogEntries.Add(@{key=$entry.Key;path=$entry.Value;byte_length=$pin.byte_length;raw_sha256=$pin.sha256;git_blob_sha1=$index[$entry.Value]})}
    Save-C1bA1NewJson $catalogPath @{schema='c1b-candidate-implementation-inputs/v1';candidate_sha=$CandidateSha;repo_root=$repo;held_inputs_during_git_queries=$true;entries=$catalogEntries.ToArray()}
    $catalogPin=Get-C1bA1Pin $session $catalogPath
    $environment=Get-C1bA1Environment;$environmentBinding=Get-TL1C1bHostCaptureEnvironment -Environment $environment -ClearEnvironment
    Assert-C1bA1 ($environment.Count-eq15-and$environmentBinding.Record.mode-ceq'replace') 'A1 exact15-key clear environment required.'
    $prefix=@('--no-optional-locks','-c','core.autocrlf=true','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-c','core.hooksPath=NUL','-C',$repo)
    $queries=[ordered]@{A1Head=@('rev-parse','--verify','HEAD^{commit}');A1Branch=@('branch','--show-current');A1Status=@('status','--porcelain=v1','--untracked-files=all');A1Tree=@('ls-tree','-rz','--full-tree','HEAD')}
    foreach($phase in $queries.Keys){
        Assert-C1bA1Preparation $session $repo;$runId=[Guid]::NewGuid().ToString('N');$phaseRoot=Join-Path $evidence $phase;[void][IO.Directory]::CreateDirectory($phaseRoot);Open-C1bA1Directories $session $phaseRoot
        $argv=[string[]]($prefix+$queries[$phase]);$r=Invoke-TL1C1bHostProcessCapture -ExecutablePath $git -ArgumentList $argv -WorkingDirectory $repo -EvidenceDirectory (Join-Path $phaseRoot 'capture') -Environment $environment -ClearEnvironment -CaptureLimitBytes 16777216 -TimeoutMilliseconds 30000
        $actualCapturePin=Get-C1bA1Pin $session (Join-Path $phaseRoot 'capture\execution.json');$rootPath=Join-Path $phaseRoot 'root-observation.json'
        Save-C1bA1NewJson $rootPath @{schema='c1b-host-root-observation/v1';candidate_sha=$CandidateSha;phase=$phase;run_id=$runId;process_id=$r.child_pid;native_exit_code=$r.exit_code;capture_pin=$actualCapturePin}
        $audits.Add(@{phase=$phase;run_id=$runId;capture_pin=$actualCapturePin;root_observation_pin=(Get-C1bA1Pin $session $rootPath)})
        $invocations.Add(@{phase=$phase;run_id=$runId;executable_pin=$gitPin;argument_list=$argv;working_directory=$repo;environment=$environmentBinding.Record;capture_pin=$actualCapturePin;root_observation_pin=(Get-C1bA1Pin $session $rootPath)})
        Assert-C1bA1 ($r.status-ceq'passed'-and$r.exit_code-eq0-and$r.root_exit_confirmed-and$r.natural_exit-and$r.stdout.eof-and$r.stderr.eof-and$r.stdout.total_byte_length-eq$r.stdout.captured_byte_length-and$r.stderr.total_byte_length-eq0-and$r.cleanup.completed-and$r.cleanup.failure_count-eq0-and$r.environment.sha256-ceq$environmentBinding.Record.sha256) 'A1 actual Git capture/native exit/dual EOF/cleanup failed.'
        $stdout=Read-C1bA1HeldFile $session (Join-Path $phaseRoot 'capture\stdout.bin');$stderrPin=Get-C1bA1Pin $session (Join-Path $phaseRoot 'capture\stderr.bin')
        Assert-C1bA1 ((Get-C1bA1Sha $stdout)-ceq$r.stdout.sha256-and$stderrPin.byte_length-eq0-and$stderrPin.sha256-ceq$r.stderr.sha256) 'A1 captured raw stream pin mismatch.'
        Assert-C1bA1Query $phase $stdout $CandidateSha $branch $index
    }
    Assert-C1bA1Preparation $session $repo
    $finalObjects=Get-C1bA1ObjectStore $session $repo
    Assert-C1bA1 ($finalObjects.file_count-eq$objectStore.file_count-and$finalObjects.ordinary_directory_count-eq$objectStore.ordinary_directory_count) 'A1 object store inventory drift.'
    $oldObjectPins=@{};foreach($pin in $objectStore.object_pins){$oldObjectPins[$pin.path]=$pin.sha256}
    foreach($pin in $finalObjects.object_pins){Assert-C1bA1 ($oldObjectPins.ContainsKey($pin.path)-and$oldObjectPins[$pin.path]-ceq$pin.sha256) 'A1 object store path/hash drift.'}
    Assert-C1bA1ToolLinks $session $git $gitToolRoot
    $lines=$catalog.ToArray();[Array]::Sort($lines,[StringComparer]::Ordinal)
    $receipt=[ordered]@{schema='c1b-candidate-authority-preparation/v1';candidate_sha=$CandidateSha;repo_root=$repo;status='passed_preparation_only';producer_process_id=$PID;audit_run_id=$AuditRunId;git_query_count=$audits.Count;automatic_retry_count=0;adb_execution_count=0;build_execution_count=0;caller_declared_candidate_state=$CandidateState;a1=@{index_pin=$indexPin;metadata_pins=$metadata;implementation_map_pin=$mapPin;implementation_catalog_pin=$catalogPin;git_audits=$audits.ToArray()};tracked_path_count=$index.Count;implementation_count=$map.Count;implementation_pins=$implementation;implementation_catalog_sha256='sha256:'+(Get-C1bA1Sha ([Text.Encoding]::UTF8.GetBytes($lines-join"`n")));source_pins=@{a1_auditor=$sourcePin;capture=$capturePin;runtime=$runtimePin};git_invocations=$invocations.ToArray();object_store=$objectStore;cleanup_failure_count=0;readiness_or_device_authorization=$false}
    $resultExit=0
}catch{$failure=$_.Exception.Message;$resultExit=1}
finally{
    $cleanup=Close-C1bA1Session $session
    if($cleanup.Count-gt0){$resultExit=1;if($null-ne$receipt){$receipt.status='failed';$receipt.cleanup_failure_count=$cleanup.Count;$receipt.object_store.cleanup_failure_count=$cleanup.Count}}
    if($reserved){
        if($null-eq$receipt){$receipt=@{schema='c1b-candidate-authority-preparation/v1';candidate_sha=$CandidateSha;status='failed';producer_process_id=$PID;audit_run_id=$AuditRunId;git_query_count=$audits.Count;automatic_retry_count=0;git_audits=$audits.ToArray();git_invocations=$invocations.ToArray();failure=$failure;cleanup_failure_count=$cleanup.Count;cleanup_errors=$cleanup.ToArray();readiness_or_device_authorization=$false}}
        Save-C1bA1NewJson (Join-Path $evidence 'a1-receipt.json') $receipt
    }
    $outputCleanup=Close-C1bA1Session $outputSession
    if($outputCleanup.Count-gt0){$resultExit=1;$failure='A1 output directory guard cleanup failed.'}
}
if($resultExit-ne0){[Console]::Error.WriteLine('A1 failed: '+$failure);exit 1}
ConvertTo-Json -InputObject $receipt -Depth 20 -Compress
exit 0
