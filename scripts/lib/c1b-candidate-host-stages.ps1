#Requires -Version 7.5
# A transport receipt is not host acceptance. State is a caller-reviewed pinned input,
# not an independent observation of all candidate freeze markers or Git state.
$script:C1bHostStagesModulePath=$PSCommandPath
if($null-eq('C1bHostStageGuardV1'-as[type])){
    # Same no-follow/deny-delete directory discipline as dispatch-lock.ps1 and the
    # C1b verifier: acquire root-to-leaf native handles, then validate each opened
    # ordinary identity/final path. File handles deny both writes and deletion.
    Add-Type -TypeDefinition @'
using System;using System.ComponentModel;using System.IO;using System.Runtime.InteropServices;using System.Text;using Microsoft.Win32.SafeHandles;
public static class C1bHostStageGuardV1 {
 [StructLayout(LayoutKind.Sequential)]struct Time {public uint Low,High;}
 [StructLayout(LayoutKind.Sequential)]struct Info {public uint Attributes;public Time Creation,Access,Write;public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder path,uint length,uint flags);
 public static SafeFileHandle Open(string path,bool directory){
  var handle=CreateFileW(path,directory?0x80u:0x80000000u,directory?3u:1u,IntPtr.Zero,3,0x00200000u|(directory?0x02000000u:0u),IntPtr.Zero);
  if(handle.IsInvalid){int code=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(code,"no_follow_open");}
  try{Validate(handle,path,directory);return handle;}catch{handle.Dispose();throw;}
 }
 public static string Validate(SafeFileHandle handle,string path,bool directory){
  Info info;if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error(),"held_identity");
  if((info.Attributes&0x400)!=0 || ((info.Attributes&0x10)!=0)!=directory)throw new IOException("Opened object is not an ordinary expected-kind object");
  var final=new StringBuilder(32768);uint size=GetFinalPathNameByHandleW(handle,final,(uint)final.Capacity,0);
  if(size==0||size>=final.Capacity)throw new IOException("Held final path unavailable");
  string actual=final.ToString();if(actual.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))actual=@"\\"+actual.Substring(8);else if(actual.StartsWith(@"\\?\",StringComparison.Ordinal))actual=actual.Substring(4);
  if(!String.Equals(Path.GetFullPath(actual),Path.GetFullPath(path),StringComparison.OrdinalIgnoreCase))throw new IOException("Held final path differs from bound path");
  return info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8");
 }
}
'@
}

function Open-C1bHostStageDirectoryGuards([string]$Directory,[switch]$NearestExisting){
    $paths=[Collections.Generic.List[string]]::new();$cursor=$Directory
    while(-not[string]::IsNullOrEmpty($cursor)){
        if([IO.Directory]::Exists($cursor)){$paths.Add($cursor)}elseif(-not$NearestExisting){throw 'Directory chain absent.'}
        $parent=[IO.Directory]::GetParent($cursor);$cursor=if($null-eq$parent){$null}else{$parent.FullName}
    }
    $guards=[Collections.Generic.List[object]]::new()
    try{for($i=$paths.Count-1;$i-ge0;$i--){$handle=[C1bHostStageGuardV1]::Open($paths[$i],$true);$guards.Add($handle)};return ,$guards.ToArray()}
    catch{for($i=$guards.Count-1;$i-ge0;$i--){$guards[$i].Dispose()};throw}
}
function Close-C1bHostStageHeld($Held){
    try{$Held.Stream.Dispose()}finally{for($i=$Held.Guards.Count-1;$i-ge0;$i--){$Held.Guards[$i].Dispose()}}
}

function Assert-C1bHostStageKeys($Value,[string[]]$Keys) {
    if($Value -isnot [pscustomobject]){throw 'Expected a JSON object.'}
    $actual=@($Value.PSObject.Properties.Name|Sort-Object -CaseSensitive)
    $expected=@($Keys|Sort-Object -CaseSensitive)
    if(($actual -join "`n") -cne ($expected -join "`n")){throw 'Closed JSON property set mismatch.'}
}
function Assert-C1bHostStageJsonElement([System.Text.Json.JsonElement]$Element) {
    if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($property in $Element.EnumerateObject()){
            if(-not$names.Add($property.Name)){throw 'Duplicate JSON property.'}
            Assert-C1bHostStageJsonElement $property.Value
        }
    }elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){
        foreach($item in $Element.EnumerateArray()){Assert-C1bHostStageJsonElement $item}
    }
}
function Assert-C1bHostStagePath([string]$Path,[switch]$AllowMissing) {
    if([string]::IsNullOrWhiteSpace($Path)-or-not[IO.Path]::IsPathFullyQualified($Path)-or$Path.Contains([char]0)-or[IO.Path]::GetFullPath($Path)-cne$Path){throw 'Path must be canonical, absolute and NUL-free.'}
    if($Path -match '(?i)(^|[\\/])(afm-c1b-4b37f34|agent-for-mobile-c1b-candidate-20260929-r3)([\\/]|$)'){throw 'Consumed 4b37f34 candidate path is forbidden.'}
    $cursor=$Path
    while(-not[string]::IsNullOrEmpty($cursor)){
        if([IO.File]::Exists($cursor)-or[IO.Directory]::Exists($cursor)){
            if(([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'Reparse path forbidden.'}
        }elseif(-not$AllowMissing){throw 'Pinned path absent.'}
        $parent=[IO.Directory]::GetParent($cursor)
        $cursor=if($null-eq$parent){$null}else{$parent.FullName}
    }
}
function Get-C1bHostStageBytesHash([byte[]]$Bytes){return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function Get-C1bHostStageArgvHash([string[]]$Arguments){
    # Canonical compact JSON string array, UTF-8 without a BOM or trailing newline.
    $json=ConvertTo-Json -InputObject ([object[]]$Arguments) -Compress -Depth 4
    return Get-C1bHostStageBytesHash ([Text.UTF8Encoding]::new($false).GetBytes($json))
}
function Open-C1bHostStagePin([string]$Path,$Expected=$null){
    Assert-C1bHostStagePath $Path
    $guards=Open-C1bHostStageDirectoryGuards ([IO.Path]::GetDirectoryName($Path));$stream=$null;$handle=$null
    try{
        $handle=[C1bHostStageGuardV1]::Open($Path,$false)
        $identity=[C1bHostStageGuardV1]::Validate($handle,$Path,$false)
        $stream=[IO.FileStream]::new($handle,[IO.FileAccess]::Read);$handle=$null
        if($stream.Length-gt268435456){throw 'Pinned file exceeds the 256 MiB input bound.'}
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        $pin=[pscustomobject][ordered]@{path=$Path;byte_length=$stream.Length;sha256=$hash}
        if($null-ne$Expected){
            Assert-C1bHostStageKeys $Expected @('path','byte_length','sha256')
            if($Expected.path-isnot[string]-or$Expected.sha256-isnot[string]-or$Expected.sha256-cnotmatch'^[a-f0-9]{64}$'-or($Expected.byte_length-isnot[int]-and$Expected.byte_length-isnot[long])-or$Expected.byte_length-lt0-or$Expected.path-cne$Path-or$Expected.byte_length-ne$pin.byte_length-or$Expected.sha256-cne$hash){throw 'Exact file pin mismatch.'}
        }
        return [pscustomobject]@{Pin=$pin;Stream=$stream;Guards=$guards;Identity=$identity}
    }catch{if($null-ne$stream){$stream.Dispose()};if($null-ne$handle){$handle.Dispose()};for($i=$guards.Count-1;$i-ge0;$i--){$guards[$i].Dispose()};throw}
}
function Read-C1bHostStageHeldJson($Held){
    if($Held.Stream.Length-gt4194304){throw 'JSON exceeds the 4 MiB bound.'}
    $Held.Stream.Position=0;$bytes=[byte[]]::new([int]$Held.Stream.Length);$Held.Stream.ReadExactly($bytes)
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $document=[System.Text.Json.JsonDocument]::Parse($text)
    try{Assert-C1bHostStageJsonElement $document.RootElement}finally{$document.Dispose()}
    return ConvertFrom-Json -InputObject $text -Depth 32 -DateKind String
}
function Save-C1bHostStageNewJson([string]$Path,$Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 24)+"`n")
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Assert-C1bHostStageCapture($Capture,$StdoutPin,$StderrPin){
    Assert-C1bHostStageKeys $Capture @('schema','status','started_at_utc','completed_at_utc','elapsed_milliseconds','start_attempt_count','start_count','automatic_retry_count','child_pid','exit_code','root_exit_confirmed','natural_exit','timed_out','drain_timed_out','termination_requested','capture_limit_bytes_per_stream','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds','drains_completed','errors','publication_errors','cleanup','stdout','stderr','environment')
    Assert-C1bHostStageKeys $Capture.environment @('mode','keys','sha256')
    if($Capture.environment.mode-isnot[string]-or$Capture.environment.mode-cnotin@('inherit','overlay','replace')-or$Capture.environment.keys-isnot[Array]-or$Capture.environment.sha256-isnot[string]-or$Capture.environment.sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'Environment receipt invalid.'}
    $envKeys=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($key in $Capture.environment.keys){if($key-isnot[string]-or[string]::IsNullOrEmpty($key)-or$key.Contains([char]0)-or-not$envKeys.Add($key)){throw 'Environment key list invalid.'}}
    foreach($field in @('start_attempt_count','start_count','automatic_retry_count','child_pid','exit_code','elapsed_milliseconds','capture_limit_bytes_per_stream','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')){if($Capture.$field-isnot[int]-and$Capture.$field-isnot[long]){throw 'Capture integer type mismatch.'}}
    foreach($field in @('active_process_count','failure_count')){if($Capture.cleanup.$field-isnot[int]-and$Capture.cleanup.$field-isnot[long]){throw 'Cleanup integer type mismatch.'}}
    Assert-C1bHostStageKeys $Capture.cleanup @('scope','job_assigned_before_resume','active_process_count','handles_closed','failure_count','errors','completed')
    foreach($field in @('root_exit_confirmed','natural_exit','timed_out','drain_timed_out','termination_requested','drains_completed')){if($Capture.$field-isnot[bool]){throw 'Capture boolean type mismatch.'}}
    foreach($field in @('job_assigned_before_resume','handles_closed','completed')){if($Capture.cleanup.$field-isnot[bool]){throw 'Cleanup boolean type mismatch.'}}
    if($Capture.schema-cne'tl1-c1b-host-process-capture/v1'-or$Capture.status-cne'passed'-or($Capture.exit_code-isnot[int]-and$Capture.exit_code-isnot[long])-or$Capture.exit_code-ne0-or$Capture.start_attempt_count-ne1-or$Capture.start_count-ne1-or$Capture.automatic_retry_count-ne0-or-not$Capture.root_exit_confirmed-or-not$Capture.natural_exit-or$Capture.timed_out-or$Capture.drain_timed_out-or$Capture.termination_requested-or-not$Capture.drains_completed-or@($Capture.errors).Count-ne0-or@($Capture.publication_errors).Count-ne0){throw 'Actual capture did not pass.'}
    if($Capture.cleanup.scope-cne'contained_job_processes_pipe_workers_owned_handles'-or-not$Capture.cleanup.job_assigned_before_resume-or-not$Capture.cleanup.handles_closed-or-not$Capture.cleanup.completed-or$Capture.cleanup.failure_count-ne0-or$Capture.cleanup.active_process_count-ne0-or@($Capture.cleanup.errors).Count-ne0){throw 'Capture Job/stream/handle cleanup incomplete.'}
    foreach($name in @('stdout','stderr')){
        $value=$Capture.$name;$pin=if($name-ceq'stdout'){$StdoutPin}else{$StderrPin}
        Assert-C1bHostStageKeys $value @('eof','aborted','error','overflowed','observed_byte_length','observed_sha256','total_byte_length','sha256','captured_byte_length','captured_sha256','first_byte_observed_elapsed_milliseconds','eof_observed_elapsed_milliseconds')
        foreach($field in @('eof','aborted','overflowed')){if($value.$field-isnot[bool]){throw 'Stream boolean type mismatch.'}}
        foreach($field in @('observed_byte_length','total_byte_length','captured_byte_length','eof_observed_elapsed_milliseconds')){if($value.$field-isnot[int]-and$value.$field-isnot[long]){throw 'Stream integer type mismatch.'}}
        if(-not$value.eof-or$value.aborted-or$value.overflowed-or$null-ne$value.error-or$null-eq$value.total_byte_length-or$value.total_byte_length-lt0-or$value.total_byte_length-gt$Capture.capture_limit_bytes_per_stream-or$value.total_byte_length-ne$pin.byte_length-or$value.captured_byte_length-ne$pin.byte_length-or$value.observed_byte_length-ne$pin.byte_length-or$value.sha256-cne$pin.sha256-or$value.observed_sha256-cne$pin.sha256-or$value.captured_sha256-cne$pin.sha256){throw 'Raw stream EOF/length/hash closure incomplete.'}
    }
}

function Assert-C1bHostStageBindingsStructure($b){
    Assert-C1bHostStageKeys $b @('schema','run_id','candidate_sha','phase','candidate_state','candidate_state_pin','runtime','stage_source','transport_sources','working_directory','argument_list','argument_list_sha256','evidence_directory','artifact_inventory','capture_limits','automatic_retry_count','environment')
    foreach($name in @('schema','run_id','candidate_sha','phase','candidate_state','working_directory','argument_list_sha256','evidence_directory')){if($b.$name-isnot[string]){throw 'Binding string type mismatch.'}}
    if($b.schema-cne'c1b-candidate-host-stage-bindings/v1'-or$b.candidate_sha-cnotmatch'^[a-f0-9]{40}$'-or$b.candidate_sha-ceq'4b37f344d5af988ce9b2f7610df98387a49cd2d0'-or$b.run_id-cnotmatch'^[a-f0-9]{32}$'-or$b.phase-cnotin@('FullCheck','PrepareSources','Pair','R14','Preflight','Readback')-or($b.automatic_retry_count-isnot[int]-and$b.automatic_retry_count-isnot[long])-or$b.automatic_retry_count-ne0){throw 'Binding stage identity/retry invalid.'}
    $expectedState=if($b.phase-ceq'Preflight'){'frozen_for_host'}elseif($b.phase-ceq'Readback'){'post_buildonly'}else{'preparation'}
    if($b.candidate_state-cne$expectedState){throw 'Phase/candidate state mismatch.'}
    Assert-C1bHostStagePath $b.working_directory;Assert-C1bHostStagePath $b.evidence_directory -AllowMissing
    Assert-C1bHostStageKeys $b.runtime @('path','byte_length','sha256','version');Assert-C1bHostStageKeys $b.transport_sources @('invoker','module','capture')
    if($b.runtime.version-isnot[string]){throw 'Runtime version invalid.'}
    if($b.argument_list-isnot[Array]-or$b.argument_list.Count-lt3-or$b.argument_list.Count-gt512){throw 'Argv array invalid.'}
    foreach($arg in $b.argument_list){if($arg-isnot[string]-or$arg.Contains([char]0)){throw 'Argv element invalid.'}}
    if($b.argument_list[0]-cne'-NoProfile'-or$b.argument_list[1]-cne'-File'-or$b.argument_list[2]-cne$b.stage_source.path-or(Get-C1bHostStageArgvHash $b.argument_list)-cne$b.argument_list_sha256){throw 'Exact argv/source binding mismatch.'}
    Assert-C1bHostStageKeys $b.capture_limits @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')
    foreach($name in @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')){if($b.capture_limits.$name-isnot[int]-and$b.capture_limits.$name-isnot[long]){throw 'Capture limit must be integer.'}}
    if($b.capture_limits.capture_limit_bytes-lt0-or$b.capture_limits.capture_limit_bytes-gt16777216-or$b.capture_limits.timeout_milliseconds-lt1-or$b.capture_limits.timeout_milliseconds-gt86400000-or$b.capture_limits.drain_timeout_milliseconds-lt1-or$b.capture_limits.drain_timeout_milliseconds-gt60000-or$b.capture_limits.cleanup_timeout_milliseconds-lt1-or$b.capture_limits.cleanup_timeout_milliseconds-gt60000){throw 'Capture limit invalid.'}
    if($b.artifact_inventory-isnot[Array]-or$b.artifact_inventory.Count-gt256){throw 'Artifact inventory invalid.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($artifact in $b.artifact_inventory){Assert-C1bHostStageKeys $artifact @('path','required');Assert-C1bHostStagePath $artifact.path -AllowMissing;if($artifact.required-isnot[bool]-or-not$paths.Add($artifact.path)){throw 'Artifact inventory type/duplicate invalid.'}}
    if($null-ne$b.environment){
        Assert-C1bHostStageKeys $b.environment @('clear_environment','variables','sha256')
        if($b.environment.clear_environment-isnot[bool]-or$b.environment.variables-isnot[pscustomobject]-or$b.environment.sha256-isnot[string]-or$b.environment.sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'Environment binding invalid.'}
        foreach($property in $b.environment.variables.PSObject.Properties){if([string]::IsNullOrEmpty($property.Name)-or$property.Name.Contains('=')-or$property.Name.Contains([char]0)-or$property.Value-isnot[string]-or$property.Value.Contains([char]0)){throw 'Environment variable binding invalid.'}}
    }
}

function Invoke-C1bCandidateHostStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BindingsPath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedBindingsSha256,[Parameter(Mandatory)][string]$InvokerPath)
    $held=[Collections.Generic.List[object]]::new();$directoryGuards=[Collections.Generic.List[object]]::new()
    try{
        $bindingsHeld=Open-C1bHostStagePin $BindingsPath;$held.Add($bindingsHeld)
        if($bindingsHeld.Pin.sha256-cne$ExpectedBindingsSha256){throw 'Bindings SHA mismatch.'}
        $b=Read-C1bHostStageHeldJson $bindingsHeld
        Assert-C1bHostStageBindingsStructure $b
        Assert-C1bHostStageKeys $b @('schema','run_id','candidate_sha','phase','candidate_state','candidate_state_pin','runtime','stage_source','transport_sources','working_directory','argument_list','argument_list_sha256','evidence_directory','artifact_inventory','capture_limits','automatic_retry_count','environment')
        if($b.schema-cne'c1b-candidate-host-stage-bindings/v1'-or$b.candidate_sha-isnot[string]-or$b.candidate_sha-cnotmatch'^[a-f0-9]{40}$'-or$b.candidate_sha-ceq'4b37f344d5af988ce9b2f7610df98387a49cd2d0'){throw 'Candidate/schema invalid or consumed candidate.'}
        if($b.run_id-isnot[string]-or$b.run_id-cnotmatch'^[a-f0-9]{32}$'-or$b.phase-cnotin@('FullCheck','PrepareSources','Pair','R14','Preflight','Readback')-or$b.automatic_retry_count-isnot[long]-and$b.automatic_retry_count-isnot[int]-or$b.automatic_retry_count-ne0){throw 'Stage identity/retry policy invalid.'}
        $expectedState=if($b.phase-ceq'Preflight'){'frozen_for_host'}elseif($b.phase-ceq'Readback'){'post_buildonly'}else{'preparation'}
        if($b.candidate_state-cne$expectedState){throw 'Phase cannot run in the declared candidate state.'}
        $stateHeld=Open-C1bHostStagePin $b.candidate_state_pin.path $b.candidate_state_pin;$held.Add($stateHeld)
        $state=Read-C1bHostStageHeldJson $stateHeld;Assert-C1bHostStageKeys $state @('schema','candidate_sha','state','working_directory')
        if($state.schema-cne'c1b-candidate-host-state/v1'-or$state.candidate_sha-cne$b.candidate_sha-or$state.state-cne$b.candidate_state-or$state.working_directory-cne$b.working_directory){throw 'Caller-reviewed candidate state pin mismatch.'}
        Assert-C1bHostStagePath $b.working_directory
        foreach($guard in (Open-C1bHostStageDirectoryGuards $b.working_directory)){$directoryGuards.Add($guard)}
        if(-not[IO.Directory]::Exists($b.working_directory)-or(Get-Location).Provider.Name-cne'FileSystem'-or(Get-Location).ProviderPath-cne$b.working_directory-or[Environment]::CurrentDirectory-cne$b.working_directory){throw 'Provider/OS/current candidate cwd mismatch.'}
        Assert-C1bHostStageKeys $b.runtime @('path','byte_length','sha256','version')
        $runtimeExpected=[pscustomobject]@{path=$b.runtime.path;byte_length=$b.runtime.byte_length;sha256=$b.runtime.sha256}
        $runtimeHeld=Open-C1bHostStagePin $b.runtime.path $runtimeExpected;$held.Add($runtimeHeld)
        if([Environment]::ProcessPath-cne$b.runtime.path-or$PSVersionTable.PSVersion.ToString()-cne$b.runtime.version){throw 'Current runtime does not match the exact pinned runtime.'}
        Assert-C1bHostStageKeys $b.transport_sources @('invoker','module','capture')
        $actualPaths=@{invoker=$InvokerPath;module=$script:C1bHostStagesModulePath;capture=(Join-Path $PSScriptRoot 'c1b-host-process-capture.ps1')}
        $sourcePins=[ordered]@{stage_source=$null;invoker=$null;module=$null;capture=$null}
        foreach($name in @('stage_source','invoker','module','capture')){
            $expected=if($name-ceq'stage_source'){$b.stage_source}else{$b.transport_sources.$name}
            if($name-cne'stage_source'-and$expected.path-cne$actualPaths[$name]){throw 'Transport source path mismatch.'}
            $sourceHeld=Open-C1bHostStagePin $expected.path $expected;$held.Add($sourceHeld);$sourcePins[$name]=$sourceHeld.Pin
        }
        if($b.argument_list-isnot[Array]-or$b.argument_list.Count-lt3-or$b.argument_list.Count-gt512){throw 'Exact argv array absent or out of bounds.'}
        foreach($arg in $b.argument_list){if($arg-isnot[string]-or$arg.Contains([char]0)){throw 'Argv element invalid.'}}
        if($b.argument_list[0]-cne'-NoProfile'-or$b.argument_list[1]-cne'-File'-or$b.argument_list[2]-cne$b.stage_source.path-or(Get-C1bHostStageArgvHash $b.argument_list)-cne$b.argument_list_sha256){throw 'Exact -File/argv pin mismatch.'}
        Assert-C1bHostStageKeys $b.capture_limits @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')
        foreach($name in @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')){if($b.capture_limits.$name-isnot[int]-and$b.capture_limits.$name-isnot[long]){throw 'Capture limit must be an integer.'}}
        if($b.capture_limits.capture_limit_bytes-lt0-or$b.capture_limits.capture_limit_bytes-gt16777216-or$b.capture_limits.timeout_milliseconds-lt1-or$b.capture_limits.timeout_milliseconds-gt86400000-or$b.capture_limits.drain_timeout_milliseconds-lt1-or$b.capture_limits.drain_timeout_milliseconds-gt60000-or$b.capture_limits.cleanup_timeout_milliseconds-lt1-or$b.capture_limits.cleanup_timeout_milliseconds-gt60000){throw 'Capture limit invalid.'}
        if($b.artifact_inventory-isnot[Array]-or$b.artifact_inventory.Count-gt256){throw 'Artifact inventory invalid.'}
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($artifact in $b.artifact_inventory){Assert-C1bHostStageKeys $artifact @('path','required');Assert-C1bHostStagePath $artifact.path -AllowMissing;if($artifact.required-isnot[bool]-or-not$paths.Add($artifact.path)){throw 'Artifact inventory type/duplicate invalid.'}}
        Assert-C1bHostStagePath $b.evidence_directory -AllowMissing
        if([IO.Directory]::Exists($b.evidence_directory)-or[IO.File]::Exists($b.evidence_directory)){throw 'Stage evidence is already reserved; retry forbidden.'}
        . $actualPaths.capture
        $environmentArguments=@{}
        if($null-ne$b.environment){
            Assert-C1bHostStageKeys $b.environment @('clear_environment','variables','sha256')
            if($b.environment.clear_environment-isnot[bool]-or$b.environment.variables-isnot[pscustomobject]){throw 'Explicit environment binding invalid.'}
            $map=[Collections.Hashtable]::new([StringComparer]::Ordinal)
            foreach($property in $b.environment.variables.PSObject.Properties){$map.Add($property.Name,$property.Value)}
            $envBinding=Get-TL1C1bHostCaptureEnvironment -Environment $map -ClearEnvironment:$b.environment.clear_environment
            if($envBinding.Record.sha256-cne$b.environment.sha256){throw 'Explicit environment SHA mismatch.'}
            $environmentArguments=@{Environment=$map;ClearEnvironment=$b.environment.clear_environment}
        }
        foreach($guard in (Open-C1bHostStageDirectoryGuards ([IO.Path]::GetDirectoryName($b.evidence_directory)) -NearestExisting)){$directoryGuards.Add($guard)}
        [void][IO.Directory]::CreateDirectory($b.evidence_directory)
        foreach($guard in (Open-C1bHostStageDirectoryGuards $b.evidence_directory)){$directoryGuards.Add($guard)}
        $started=[DateTimeOffset]::UtcNow.ToString('o')
        Save-C1bHostStageNewJson (Join-Path $b.evidence_directory 'reservation.json') ([ordered]@{schema='c1b-candidate-host-stage-reservation/v1';run_id=$b.run_id;candidate_sha=$b.candidate_sha;phase=$b.phase;bindings_pin=$bindingsHeld.Pin;automatic_retry_count=0})
        $captureDir=Join-Path $b.evidence_directory 'capture'
        $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath $b.runtime.path -ArgumentList $b.argument_list -WorkingDirectory $b.working_directory -EvidenceDirectory $captureDir -CaptureLimitBytes $b.capture_limits.capture_limit_bytes -TimeoutMilliseconds $b.capture_limits.timeout_milliseconds -DrainTimeoutMilliseconds $b.capture_limits.drain_timeout_milliseconds -CleanupTimeoutMilliseconds $b.capture_limits.cleanup_timeout_milliseconds @environmentArguments
        $capture=ConvertFrom-Json -InputObject ($capture|ConvertTo-Json -Depth 16) -DateKind String
        $capturePins=[ordered]@{}
        foreach($pair in @(@('execution_pin','execution.json'),@('reservation_pin','reservation.json'),@('stdout_pin','stdout.bin'),@('stderr_pin','stderr.bin'))){$item=Open-C1bHostStagePin (Join-Path $captureDir $pair[1]);try{$capturePins[$pair[0]]=$item.Pin}finally{Close-C1bHostStageHeld $item}}
        $errors=[Collections.Generic.List[string]]::new();$inventory=[Collections.Generic.List[object]]::new()
        if($capture.status-cne'passed'){$errors.Add('Actual child capture failed.')}
        foreach($artifact in $b.artifact_inventory){
            $pin=$null;$present=[IO.File]::Exists($artifact.path)
            if($present){try{$item=Open-C1bHostStagePin $artifact.path;try{$pin=$item.Pin}finally{Close-C1bHostStageHeld $item}}catch{$errors.Add('Artifact pin failed.');$present=$false}}
            if($artifact.required-and-not$present){$errors.Add('Required artifact absent.')}
            $inventory.Add([pscustomobject][ordered]@{path=$artifact.path;required=$artifact.required;present=$present;byte_length=$(if($null-ne$pin){$pin.byte_length}else{$null});sha256=$(if($null-ne$pin){$pin.sha256}else{$null})})
        }
        if($capture.status-ceq'passed'){try{Assert-C1bHostStageCapture $capture $capturePins.stdout_pin $capturePins.stderr_pin}catch{$errors.Add($_.Exception.Message)}}
        $observation=[ordered]@{
            schema='c1b-candidate-host-stage/v1';run_id=$b.run_id;candidate_sha=$b.candidate_sha;phase=$b.phase;candidate_state=$b.candidate_state;candidate_state_pin=$stateHeld.Pin
            status=$(if($errors.Count-eq0){'passed'}else{'failed'});started_at_utc=$started;completed_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
            bindings_pin=$bindingsHeld.Pin;source_pins=$sourcePins;runtime_pin=$b.runtime;working_directory=$b.working_directory;argument_list=$b.argument_list;argument_list_sha256=$b.argument_list_sha256;capture_limits=$b.capture_limits
            producer=[ordered]@{process_id=$PID;runtime_version=$PSVersionTable.PSVersion.ToString()}
            capture=[ordered]@{directory=$captureDir;execution_pin=$capturePins.execution_pin;reservation_pin=$capturePins.reservation_pin;stdout_pin=$capturePins.stdout_pin;stderr_pin=$capturePins.stderr_pin;stage_native_exit_code=$capture.exit_code;child_pid=$capture.child_pid;stdout_eof=$capture.stdout.eof;stderr_eof=$capture.stderr.eof;drains_completed=$capture.drains_completed;status=$capture.status;cleanup=$capture.cleanup;environment=$capture.environment}
            artifact_inventory=$inventory.ToArray();errors=$errors.ToArray();automatic_retry_count=0
        }
        Save-C1bHostStageNewJson (Join-Path $b.evidence_directory 'observation.json') $observation
        return [pscustomobject]$observation
    }finally{for($i=$held.Count-1;$i-ge0;$i--){Close-C1bHostStageHeld $held[$i]};for($i=$directoryGuards.Count-1;$i-ge0;$i--){$directoryGuards[$i].Dispose()}}
}

function Read-C1bCandidateHostStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ObservationPath,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedObservationSha256)
    $held=[Collections.Generic.List[object]]::new()
    try{
        $obsHeld=Open-C1bHostStagePin $ObservationPath;$held.Add($obsHeld)
        if($obsHeld.Pin.sha256-cne$ExpectedObservationSha256){throw 'Observation SHA mismatch.'}
        $o=Read-C1bHostStageHeldJson $obsHeld
        Assert-C1bHostStageKeys $o @('schema','run_id','candidate_sha','phase','candidate_state','candidate_state_pin','status','started_at_utc','completed_at_utc','bindings_pin','source_pins','runtime_pin','working_directory','argument_list','argument_list_sha256','capture_limits','producer','capture','artifact_inventory','errors','automatic_retry_count')
        foreach($name in @('schema','run_id','candidate_sha','phase','candidate_state','status','started_at_utc','completed_at_utc','working_directory','argument_list_sha256')){if($o.$name-isnot[string]){throw 'Observation string type invalid.'}}
        if($o.automatic_retry_count-isnot[int]-and$o.automatic_retry_count-isnot[long]){throw 'Observation retry integer invalid.'}
        if($o.schema-cne'c1b-candidate-host-stage/v1'-or$o.status-cne'passed'-or@($o.errors).Count-ne0-or$o.automatic_retry_count-ne0-or$o.candidate_sha-ceq'4b37f344d5af988ce9b2f7610df98387a49cd2d0'-or$o.candidate_sha-cnotmatch'^[a-f0-9]{40}$'-or$o.run_id-cnotmatch'^[a-f0-9]{32}$'-or$o.phase-cnotin@('FullCheck','PrepareSources','Pair','R14','Preflight','Readback')){throw 'Stage did not pass or identity invalid.'}
        Assert-C1bHostStageKeys $o.source_pins @('stage_source','invoker','module','capture')
        Assert-C1bHostStageKeys $o.producer @('process_id','runtime_version')
        Assert-C1bHostStageKeys $o.runtime_pin @('path','byte_length','sha256','version')
        Assert-C1bHostStageKeys $o.capture_limits @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')
        Assert-C1bHostStageKeys $o.capture @('directory','execution_pin','reservation_pin','stdout_pin','stderr_pin','stage_native_exit_code','child_pid','stdout_eof','stderr_eof','drains_completed','status','cleanup','environment')
        foreach($name in @('process_id')){if(($o.producer.$name-isnot[int]-and$o.producer.$name-isnot[long])-or$o.producer.$name-lt1){throw 'Producer PID invalid.'}}
        foreach($name in @('stage_native_exit_code','child_pid')){if($o.capture.$name-isnot[int]-and$o.capture.$name-isnot[long]){throw 'Stage capture integer type invalid.'}}
        $pins=@($o.bindings_pin,$o.candidate_state_pin)+@($o.source_pins.stage_source,$o.source_pins.invoker,$o.source_pins.module,$o.source_pins.capture)+@($o.capture.execution_pin,$o.capture.reservation_pin,$o.capture.stdout_pin,$o.capture.stderr_pin)
        $runtimePin=[pscustomobject]@{path=$o.runtime_pin.path;byte_length=$o.runtime_pin.byte_length;sha256=$o.runtime_pin.sha256};$pins+=,$runtimePin
        foreach($pin in $pins){$held.Add((Open-C1bHostStagePin $pin.path $pin))}
        $b=Read-C1bHostStageHeldJson $held[1];$state=Read-C1bHostStageHeldJson $held[2]
        Assert-C1bHostStageBindingsStructure $b
        Assert-C1bHostStageKeys $state @('schema','candidate_sha','state','working_directory')
        if($state.schema-cne'c1b-candidate-host-state/v1'){throw 'State schema invalid.'}
        if($ObservationPath-cne(Join-Path $b.evidence_directory 'observation.json')-or$o.capture.directory-cne(Join-Path $b.evidence_directory 'capture')){throw 'Exact observation/capture directory binding mismatch.'}
        foreach($pair in @(@('execution_pin','execution.json'),@('reservation_pin','reservation.json'),@('stdout_pin','stdout.bin'),@('stderr_pin','stderr.bin'))){if($o.capture.($pair[0]).path-cne(Join-Path $o.capture.directory $pair[1])){throw 'Exact capture artifact path edge mismatch.'}}
        $stageReservation=Open-C1bHostStagePin (Join-Path $b.evidence_directory 'reservation.json');$held.Add($stageReservation)
        $reservation=Read-C1bHostStageHeldJson $stageReservation
        Assert-C1bHostStageKeys $reservation @('schema','run_id','candidate_sha','phase','bindings_pin','automatic_retry_count')
        if($reservation.schema-cne'c1b-candidate-host-stage-reservation/v1'-or$reservation.run_id-cne$o.run_id-or$reservation.candidate_sha-cne$o.candidate_sha-or$reservation.phase-cne$o.phase-or($reservation.automatic_retry_count-isnot[int]-and$reservation.automatic_retry_count-isnot[long])-or$reservation.automatic_retry_count-ne0){throw 'Actual stage reservation identity differs.'}
        foreach($field in @('path','byte_length','sha256')){if($reservation.bindings_pin.$field-cne$o.bindings_pin.$field){throw 'Stage reservation binding pin differs.'}}
        foreach($field in @('path','byte_length','sha256')){if($b.candidate_state_pin.$field-cne$o.candidate_state_pin.$field){throw 'State evidence pin differs from admitted binding.'}}
        if($b.candidate_sha-cne$o.candidate_sha-or$b.run_id-cne$o.run_id-or$b.phase-cne$o.phase-or$b.candidate_state-cne$o.candidate_state-or$b.working_directory-cne$o.working_directory-or$b.argument_list_sha256-cne$o.argument_list_sha256-or(Get-C1bHostStageArgvHash $o.argument_list)-cne$o.argument_list_sha256-or$state.candidate_sha-cne$o.candidate_sha-or$state.state-cne$o.candidate_state-or$state.working_directory-cne$o.working_directory){throw 'Stage bindings/state/argv differ.'}
        foreach($name in @('stage_source','invoker','module','capture')){$expected=if($name-ceq'stage_source'){$b.stage_source}else{$b.transport_sources.$name};foreach($field in @('path','byte_length','sha256')){if($expected.$field-cne$o.source_pins.$name.$field){throw 'Stage source pin differs from admitted binding.'}}}
        foreach($field in @('path','byte_length','sha256','version')){if($b.runtime.$field-cne$o.runtime_pin.$field){throw 'Runtime pin differs from admitted binding.'}}
        if([Environment]::ProcessPath-cne$o.runtime_pin.path-or$PSVersionTable.PSVersion.ToString()-cne$o.runtime_pin.version-or$o.producer.runtime_version-cne$o.runtime_pin.version){throw 'Reader/producer runtime differs from bound runtime.'}
        $captureHeld=@($held|Where-Object {$_.Pin.path-ceq$o.capture.execution_pin.path})[0]
        $capture=Read-C1bHostStageHeldJson $captureHeld;Assert-C1bHostStageCapture $capture $o.capture.stdout_pin $o.capture.stderr_pin
        if($o.capture.stage_native_exit_code-ne$capture.exit_code-or$o.capture.child_pid-ne$capture.child_pid-or$o.capture.stdout_eof-isnot[bool]-or-not$o.capture.stdout_eof-or$o.capture.stderr_eof-isnot[bool]-or-not$o.capture.stderr_eof-or$o.capture.drains_completed-isnot[bool]-or-not$o.capture.drains_completed-or$o.capture.status-cne$capture.status-or($o.capture.cleanup|ConvertTo-Json -Compress)-cne($capture.cleanup|ConvertTo-Json -Compress)-or($o.capture.environment|ConvertTo-Json -Compress)-cne($capture.environment|ConvertTo-Json -Compress)){throw 'Capture summary does not match actual raw execution.'}
        foreach($pair in @(@('capture_limit_bytes','capture_limit_bytes_per_stream'),@('timeout_milliseconds','timeout_milliseconds'),@('drain_timeout_milliseconds','drain_timeout_milliseconds'),@('cleanup_timeout_milliseconds','cleanup_timeout_milliseconds'))){if($b.capture_limits.($pair[0])-cne$o.capture_limits.($pair[0])-or$b.capture_limits.($pair[0])-ne$capture.($pair[1])){throw 'Actual capture limits differ from binding.'}}
        if($null-eq$b.environment){if($capture.environment.mode-cne'inherit'){throw 'Inherited environment mode differs.'}}else{$mode=if($b.environment.clear_environment){'replace'}else{'overlay'};if($capture.environment.mode-cne$mode-or$capture.environment.sha256-cne$b.environment.sha256){throw 'Explicit environment differs from binding.'}}
        $captureReservationHeld=@($held|Where-Object {$_.Pin.path-ceq$o.capture.reservation_pin.path})[0]
        $captureReservation=Read-C1bHostStageHeldJson $captureReservationHeld
        Assert-C1bHostStageKeys $captureReservation @('schema','started_at_utc','parent_pid','automatic_retry_count')
        foreach($name in @('parent_pid','automatic_retry_count')){if($captureReservation.$name-isnot[int]-and$captureReservation.$name-isnot[long]){throw 'Capture reservation integer type invalid.'}}
        if($captureReservation.schema-cne'tl1-c1b-host-process-capture-reservation/v1'-or$captureReservation.started_at_utc-cne$capture.started_at_utc-or$captureReservation.parent_pid-ne$o.producer.process_id-or$captureReservation.automatic_retry_count-ne0){throw 'Capture reservation source/PID/retry differs.'}
        if($o.artifact_inventory-isnot[Array]-or$o.artifact_inventory.Count-ne$b.artifact_inventory.Count){throw 'Artifact inventory differs.'}
        for($i=0;$i-lt$o.artifact_inventory.Count;$i++){
            $artifact=$o.artifact_inventory[$i];$declared=$b.artifact_inventory[$i]
            Assert-C1bHostStageKeys $artifact @('path','required','present','byte_length','sha256')
            if($artifact.path-cne$declared.path-or$artifact.required-isnot[bool]-or$artifact.present-isnot[bool]-or$artifact.required-ne$declared.required-or($artifact.required-and-not$artifact.present)){throw 'Artifact declaration mismatch.'}
            if($artifact.present){$pin=[pscustomobject]@{path=$artifact.path;byte_length=$artifact.byte_length;sha256=$artifact.sha256};$held.Add((Open-C1bHostStagePin $pin.path $pin))}elseif($null-ne$artifact.byte_length-or$null-ne$artifact.sha256-or[IO.File]::Exists($artifact.path)){throw 'Absent artifact state drift.'}
        }
        return [pscustomobject][ordered]@{schema='c1b-candidate-host-stage-read/v1';status='passed';run_id=$o.run_id;candidate_sha=$o.candidate_sha;phase=$o.phase;observation_pin=$obsHeld.Pin;checked_pin_count=$held.Count;producer_process_id=$o.producer.process_id;reader_process_id=$PID;stage_native_exit_code=$capture.exit_code;root_native_exit_observed=$false}
    }finally{for($i=$held.Count-1;$i-ge0;$i--){Close-C1bHostStageHeld $held[$i]}}
}
