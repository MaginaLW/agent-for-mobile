#Requires -Version 7.5
# Current-candidate host evidence only. No device, process, Git or build invocation.
Set-StrictMode -Version 3.0

if ($null -ne ('C1bHostAcceptanceNativeV1' -as [type])) { throw 'Host acceptance native authority is already loaded.' }
$null = Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class C1bHostAcceptanceIdentityV1 {
    public uint Attributes; public uint Links; public ulong Length;
    public long LastWrite; public string Id;
}
public static class C1bHostAcceptanceNativeV1 {
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct INFO {
        public uint Attributes; public FT Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string p,uint a,uint s,IntPtr security,uint c,uint f,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out INFO i);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint n,uint f);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindFirstFileNameW(string p,uint flags,ref uint size,StringBuilder name);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool FindNextFileNameW(IntPtr h,ref uint size,StringBuilder name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool FindClose(IntPtr h);
    public static SafeFileHandle Open(string p,bool directory) {
        var h=CreateFileW(p,directory?0x81u:0x80000000u,directory?3u:1u,IntPtr.Zero,3,
            0x00200000u|(directory?0x02000000u:0x08000080u),IntPtr.Zero);
        if(h.IsInvalid){int e=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(e);}return h;
    }
    public static C1bHostAcceptanceIdentityV1 Identity(SafeFileHandle h) {
        INFO i;if(!GetFileInformationByHandle(h,out i))throw new Win32Exception(Marshal.GetLastWin32Error());
        return new C1bHostAcceptanceIdentityV1{Attributes=i.Attributes,Links=i.Links,
            Length=((ulong)i.SizeHigh<<32)|i.SizeLow,LastWrite=unchecked((long)(((ulong)i.Write.High<<32)|i.Write.Low)),
            Id=i.Volume.ToString("X8")+":"+i.IndexHigh.ToString("X8")+i.IndexLow.ToString("X8")};
    }
    public static string FinalPath(SafeFileHandle h) {
        var b=new StringBuilder(32768);uint n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,0);
        if(n==0)throw new Win32Exception(Marshal.GetLastWin32Error());if(n>=b.Capacity)throw new InvalidOperationException("Final path too long.");
        string p=b.ToString();if(!p.StartsWith(@"\\?\")||p.StartsWith(@"\\?\UNC\"))throw new InvalidOperationException("Non-local final path.");return p.Substring(4);
    }
    public static string[] Hardlinks(string path) {
        var names=new System.Collections.Generic.List<string>();var b=new StringBuilder(32768);uint size=32768;
        IntPtr h=FindFirstFileNameW(path,0,ref size,b);if(h==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
        try{names.Add(b.ToString());while(true){b.Clear();size=32768;if(!FindNextFileNameW(h,ref size,b)){int e=Marshal.GetLastWin32Error();if(e==38)break;throw new Win32Exception(e);}if(names.Count>=1024)throw new InvalidOperationException("Hardlink closure too large.");names.Add(b.ToString());}}
        finally{if(!FindClose(h))throw new Win32Exception(Marshal.GetLastWin32Error());}return names.ToArray();
    }
}
'@

function Assert-C1bHA { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-C1bHAKeys {
    param($Value,[string[]]$Keys,[string]$Name)
    Assert-C1bHA ($null -ne $Value -and $Value -is [Collections.IDictionary]) "$Name must be an object."
    $actual=@($Value.Keys); Assert-C1bHA ($actual.Count -eq $Keys.Count) "$Name has unknown or missing fields."
    foreach($key in $Keys){ Assert-C1bHA ($actual -ccontains $key) "$Name missing $key." }
}
function Assert-C1bHAInt { param($Value,[long]$Minimum=0,[long]$Maximum=[long]::MaxValue,[string]$Name='integer') Assert-C1bHA ($Value -is [long] -or $Value -is [int]) "$Name must be an integer."; Assert-C1bHA ($Value -ge $Minimum -and $Value -le $Maximum) "$Name out of range." }
function Assert-C1bHABool { param($Value,[bool]$Expected,[string]$Name) Assert-C1bHA ($Value -is [bool] -and $Value -eq $Expected) "$Name unknown or unexpected." }
function Assert-C1bHAString { param($Value,[string]$Pattern,[string]$Name) Assert-C1bHA ($Value -is [string] -and $Value -cmatch $Pattern) "$Name invalid." }
function ConvertFrom-C1bHAStrictJson {
    param([Parameter(Mandatory)][string]$Raw)
    $ErrorActionPreference='Stop'
    $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=64
    $document=[Text.Json.JsonDocument]::Parse($Raw,$options)
    try {
        function Test-HAJsonElement([Text.Json.JsonElement]$Element) {
            switch ($Element.ValueKind) {
                Object { $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($property in $Element.EnumerateObject()){if(-not $names.Add($property.Name)){throw 'Duplicate JSON key.'};Test-HAJsonElement $property.Value} }
                Array { foreach($item in $Element.EnumerateArray()){Test-HAJsonElement $item} }
                Number { $number=[long]0; $token=$Element.GetRawText();if($token -cnotmatch '^(0|-?[1-9][0-9]*)$' -or -not $Element.TryGetInt64([ref]$number)){throw 'Noncanonical or noninteger JSON number.'} }
            }
        }
        Test-HAJsonElement $document.RootElement
        Assert-C1bHA ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) 'JSON root must be object.'
        return Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Raw -AsHashtable -Depth 64 -DateKind String
    } finally { $document.Dispose() }
}
function Get-C1bHASha256 { param([byte[]]$Bytes) return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Test-C1bHAEqual {
    param($Left,$Right)
    if($null-eq$Left -or $null-eq$Right){return $null-eq$Left -and $null-eq$Right}
    if($Left-is[Collections.IDictionary]){if($Right-isnot[Collections.IDictionary] -or $Left.Count-ne$Right.Count){return $false};foreach($key in $Left.Keys){if(-not(@($Right.Keys)-ccontains$key) -or -not(Test-C1bHAEqual $Left[$key] $Right[$key])){return $false}};return $true}
    if($Left-is[array]){if($Right-isnot[array] -or $Left.Count-ne$Right.Count){return $false};for($i=0;$i-lt$Left.Count;$i++){if(-not(Test-C1bHAEqual $Left[$i] $Right[$i])){return $false}};return $true}
    if(($Left-is[long] -or $Left-is[int]) -and ($Right-is[long] -or $Right-is[int])){return $Left-eq$Right}
    return $Left.GetType()-eq$Right.GetType() -and $Left-ceq$Right
}
function Get-C1bHAPath {
    param([string]$Path)
    Assert-C1bHA ($Path -cmatch '^[A-Za-z]:\\' -and $Path -notmatch '[\x00-\x1f*?]' -and $Path -notmatch '\\[.]{1,2}(\\|$)' -and $Path.Substring(2) -notmatch ':') 'Only canonical local absolute paths are accepted.'
    $full=[IO.Path]::GetFullPath($Path);if($full.Length-gt3){$full=$full.TrimEnd('\')};Assert-C1bHA ([string]::Equals($full.TrimEnd('\'),$Path.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) 'Noncanonical path.';return $full
}
function Test-C1bHAWithin { param([string]$Path,[string]$Root) return [string]::Equals($Path,$Root,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase) }
function New-C1bHASession {
    param([string[]]$Roots)
    $session=@{roots=@($Roots|ForEach-Object{Get-C1bHAPath $_});directories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);absences=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);bytes=[long]0}
    try { foreach($root in $session.roots){Open-C1bHADirectories $session $root} }
    catch { $primary=$_;try{Close-C1bHASession $session}catch{throw [AggregateException]::new('Host acceptance initialization and cleanup failed.',[Exception[]]@($primary.Exception,$_.Exception))};throw $primary }
    return $session
}
function Open-C1bHADirectories {
    param($Session,[string]$Path)
    $chain=[Collections.Generic.List[string]]::new();$current=Get-C1bHAPath $Path
    while($current.Length -ge 3){$chain.Insert(0,$current);$parent=[IO.Path]::GetDirectoryName($current);if([string]::IsNullOrEmpty($parent)){break};$current=$parent;if($current.Length-gt3){$current=$current.TrimEnd('\')}}
    foreach($directory in $chain){
        if($Session.directories.ContainsKey($directory)){continue}
        $handle=[C1bHostAcceptanceNativeV1]::Open($directory,$true)
        try{$identity=[C1bHostAcceptanceNativeV1]::Identity($handle);Assert-C1bHA (($identity.Attributes -band 0x400) -eq 0 -and ($identity.Attributes -band 0x10) -ne 0) 'Directory reparse or type rejected.';Assert-C1bHA ([string]::Equals([C1bHostAcceptanceNativeV1]::FinalPath($handle).TrimEnd('\'),$directory.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)) 'Directory final path mismatch.';$Session.directories.Add($directory,@{handle=$handle;identity=$identity})}catch{$handle.Dispose();throw}
    }
}
function Read-C1bHAFile {
    param($Session,$Pin,[long]$MaximumLength=134217728,[int]$ExpectedLinkCount=1)
    $bytes=$null
    Assert-C1bHAKeys $Pin @('path','byte_length','sha256') 'raw pin';Assert-C1bHAInt $Pin.byte_length 0 $MaximumLength 'raw pin length';Assert-C1bHAString $Pin.sha256 '^[0-9a-f]{64}$' 'raw pin SHA256'
    $path=Get-C1bHAPath $Pin.path;$inside=$false;foreach($root in $Session.roots){if(Test-C1bHAWithin $path $root){$inside=$true;break}};Assert-C1bHA $inside 'Raw pin is out of trusted roots.'
    if($Session.files.ContainsKey($path)){$known=$Session.files[$path];Assert-C1bHA ($known.pin.sha256 -ceq $Pin.sha256 -and $known.pin.byte_length -eq $Pin.byte_length) 'Conflicting pins for same path.';return ,$known.bytes}
    Open-C1bHADirectories $Session ([IO.Path]::GetDirectoryName($path));$handle=[C1bHostAcceptanceNativeV1]::Open($path,$false)
    try {
        $before=[C1bHostAcceptanceNativeV1]::Identity($handle)
        Assert-C1bHA (($before.Attributes -band 0x410) -eq 0 -and $before.Links -eq $ExpectedLinkCount -and $before.Length -eq [ulong]$Pin.byte_length) 'Raw file type/link/length rejected.'
        Assert-C1bHA ([string]::Equals([C1bHostAcceptanceNativeV1]::FinalPath($handle),$path,[StringComparison]::OrdinalIgnoreCase)) 'Raw file final path mismatch.'
        Assert-C1bHA ($Session.bytes+$Pin.byte_length -le 1073741824) 'Aggregate evidence exceeds bound.'
        $alias=[Microsoft.Win32.SafeHandles.SafeFileHandle]::new($handle.DangerousGetHandle(),$false)
        $stream=[IO.FileStream]::new($alias,[IO.FileAccess]::Read,65536,$false)
        try{$bytes=[byte[]]::new([int]$Pin.byte_length);$offset=0;while($offset -lt $bytes.Length){$count=$stream.Read($bytes,$offset,$bytes.Length-$offset);Assert-C1bHA ($count -gt 0) 'Raw file truncated.';$offset+=$count};Assert-C1bHA ($stream.ReadByte() -eq -1) 'Raw file grew.'}finally{$stream.Dispose()}
        Assert-C1bHA ((Get-C1bHASha256 $bytes) -ceq $Pin.sha256) 'Raw SHA256 mismatch.'
        $after=[C1bHostAcceptanceNativeV1]::Identity($handle);Assert-C1bHA ($before.Id -ceq $after.Id -and $before.LastWrite -eq $after.LastWrite -and $before.Length -eq $after.Length -and $before.Attributes -eq $after.Attributes -and $after.Links -eq $ExpectedLinkCount) 'Raw file identity changed.'
        $Session.files.Add($path,@{handle=$handle;identity=$after;expected_link_count=$ExpectedLinkCount;pin=$Pin;bytes=$bytes});$Session.bytes+=$Pin.byte_length;return ,$bytes
    }catch{$handle.Dispose();if($null-ne$bytes){[Array]::Clear($bytes,0,$bytes.Length)};throw}
}
function ConvertFrom-C1bHABytes { param([byte[]]$Bytes) Assert-C1bHA (-not($Bytes.Length-ge3 -and $Bytes[0]-eq239 -and $Bytes[1]-eq187 -and $Bytes[2]-eq191)) 'UTF8 BOM rejected.';return [Text.UTF8Encoding]::new($false,$true).GetString($Bytes) }
function Read-C1bHAJson { param($Session,$Pin) return ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes (Read-C1bHAFile $Session $Pin 8388608)) }
function Close-C1bHASession {
    param($Session)
    $failures=[Collections.Generic.List[string]]::new()
    foreach($path in $Session.absences){try{Assert-C1bHAAbsentFile $Session $path}catch{$failures.Add($_.Exception.Message)}}
    foreach($entry in $Session.files.GetEnumerator()){
        try{$fresh=[C1bHostAcceptanceNativeV1]::Identity($entry.Value.handle);Assert-C1bHA ($fresh.Id -ceq $entry.Value.identity.Id -and $fresh.LastWrite -eq $entry.Value.identity.LastWrite -and $fresh.Length -eq $entry.Value.identity.Length -and $fresh.Attributes -eq $entry.Value.identity.Attributes -and $fresh.Links -eq $entry.Value.expected_link_count) 'Held raw identity changed before release.';Assert-C1bHA ((Get-C1bHASha256 $entry.Value.bytes) -ceq $entry.Value.pin.sha256) 'Held raw buffer changed.';$reopen=[C1bHostAcceptanceNativeV1]::Open($entry.Key,$false);try{Assert-C1bHA (([C1bHostAcceptanceNativeV1]::Identity($reopen)).Id -ceq $fresh.Id) 'Raw path replacement.'}finally{$reopen.Dispose()}}catch{$failures.Add($_.Exception.Message)}finally{[Array]::Clear($entry.Value.bytes,0,$entry.Value.bytes.Length);$entry.Value.handle.Dispose()}
    }
    foreach($entry in $Session.directories.GetEnumerator()){
        try{$fresh=[C1bHostAcceptanceNativeV1]::Identity($entry.Value.handle);Assert-C1bHA ($fresh.Id -ceq $entry.Value.identity.Id -and ($fresh.Attributes-band0x410)-eq0x10) 'Held directory changed.';$reopen=[C1bHostAcceptanceNativeV1]::Open($entry.Key,$true);try{Assert-C1bHA (([C1bHostAcceptanceNativeV1]::Identity($reopen)).Id -ceq $fresh.Id) 'Directory path replacement.'}finally{$reopen.Dispose()}}catch{$failures.Add($_.Exception.Message)}finally{$entry.Value.handle.Dispose()}
    }
    if($failures.Count){throw ('Host acceptance guard cleanup failed: '+($failures -join '; '))}
}
function Assert-C1bHAAbsentFile {
    param($Session,[string]$Path)
    $path=Get-C1bHAPath $Path;Open-C1bHADirectories $Session ([IO.Path]::GetDirectoryName($path));$handle=$null
    try{$handle=[C1bHostAcceptanceNativeV1]::Open($path,$false)}catch{
        $exception=$_.Exception;while($null-ne$exception.InnerException){$exception=$exception.InnerException}
        if($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode-eq2){$null=$Session.absences.Add($path);return};throw
    }finally{if($null-ne$handle){$handle.Dispose()}}
    throw 'Required no-follow namespace absence was not observed.'
}

function Assert-C1bHACapture {
    param($Session,$Pin)
    $capture=Read-C1bHAJson $Session $Pin
    Assert-C1bHAKeys $capture @('schema','status','started_at_utc','completed_at_utc','elapsed_milliseconds','start_attempt_count','start_count','automatic_retry_count','child_pid','exit_code','root_exit_confirmed','natural_exit','timed_out','drain_timed_out','termination_requested','capture_limit_bytes_per_stream','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds','drains_completed','errors','publication_errors','cleanup','stdout','stderr','environment') 'capture'
    Assert-C1bHA ($capture.schema -ceq 'tl1-c1b-host-process-capture/v1' -and $capture.status -ceq 'passed') 'Capture status failed or unknown.'
    foreach($key in @('root_exit_confirmed','natural_exit','drains_completed')){Assert-C1bHABool $capture[$key] $true "capture.$key"};foreach($key in @('timed_out','drain_timed_out','termination_requested')){Assert-C1bHABool $capture[$key] $false "capture.$key"}
    Assert-C1bHAInt $capture.child_pid 1 2147483647 'capture PID';foreach($key in @('exit_code','automatic_retry_count')){Assert-C1bHAInt $capture[$key] 0 0 "capture.$key"};foreach($key in @('start_attempt_count','start_count')){Assert-C1bHAInt $capture[$key] 1 1 "capture.$key"}
    Assert-C1bHA ($capture.errors-is[array] -and $capture.publication_errors-is[array] -and $capture.errors.Count-eq0 -and $capture.publication_errors.Count-eq0) 'Capture errors absent or nonempty.'
    Assert-C1bHAInt $capture.elapsed_milliseconds 0 ([long]::MaxValue) 'capture elapsed';Assert-C1bHAInt $capture.capture_limit_bytes_per_stream 0 16777216 'capture byte cap';Assert-C1bHAInt $capture.timeout_milliseconds 1 86400000 'capture timeout';foreach($key in @('drain_timeout_milliseconds','cleanup_timeout_milliseconds')){Assert-C1bHAInt $capture[$key] 1 60000 "capture.$key"}
    Assert-C1bHAKeys $capture.environment @('mode','keys','sha256') 'capture environment';Assert-C1bHA (@('inherit','overlay','replace')-ccontains$capture.environment.mode) 'Capture environment mode.';Assert-C1bHAString $capture.environment.sha256 '^[0-9a-f]{64}$' 'environment hash';Assert-C1bHA ($capture.environment.keys-is[array] -and @($capture.environment.keys|Where-Object{$_-isnot[string]}).Count-eq0) 'Environment key types.'
    $envNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$previousName=$null;foreach($name in $capture.environment.keys){Assert-C1bHA ($name.Length-gt0 -and $name-ceq$name.ToUpperInvariant() -and $envNames.Add($name) -and ($null-eq$previousName -or [StringComparer]::Ordinal.Compare($previousName,$name)-lt0)) 'Environment names must be canonical sorted unique uppercase.';$previousName=$name}
    $cleanup=$capture.cleanup;Assert-C1bHAKeys $cleanup @('scope','job_assigned_before_resume','active_process_count','handles_closed','failure_count','errors','completed') 'capture cleanup'
    Assert-C1bHA ($cleanup.scope -ceq 'contained_job_processes_pipe_workers_owned_handles') 'Capture cleanup scope.';foreach($key in @('job_assigned_before_resume','handles_closed','completed')){Assert-C1bHABool $cleanup[$key] $true "cleanup.$key"};foreach($key in @('active_process_count','failure_count')){Assert-C1bHAInt $cleanup[$key] 0 0 "cleanup.$key"};Assert-C1bHA ($cleanup.errors-is[array] -and $cleanup.errors.Count-eq0) 'Capture cleanup errors.'
    foreach($name in @('stdout','stderr')){
        $value=$capture[$name];Assert-C1bHAKeys $value @('eof','aborted','error','overflowed','observed_byte_length','observed_sha256','total_byte_length','sha256','captured_byte_length','captured_sha256','first_byte_observed_elapsed_milliseconds','eof_observed_elapsed_milliseconds') "capture.$name"
        Assert-C1bHABool $value.eof $true "$name EOF";foreach($key in @('aborted','overflowed')){Assert-C1bHABool $value[$key] $false "$name.$key"};Assert-C1bHA ($null-eq$value.error) "$name stream error.";Assert-C1bHAInt $value.total_byte_length 0 134217728 "$name byte length"
        foreach($key in @('observed_byte_length','captured_byte_length')){Assert-C1bHAInt $value[$key] 0 134217728 "$name.$key"};foreach($key in @('sha256','observed_sha256','captured_sha256')){Assert-C1bHAString $value[$key] '^[0-9a-f]{64}$' "$name.$key"};Assert-C1bHAInt $value.eof_observed_elapsed_milliseconds 0 $capture.elapsed_milliseconds "$name EOF time";if($null-ne$value.first_byte_observed_elapsed_milliseconds){Assert-C1bHAInt $value.first_byte_observed_elapsed_milliseconds 0 $capture.elapsed_milliseconds "$name first byte time"}
        Assert-C1bHA ($value.total_byte_length-le$capture.capture_limit_bytes_per_stream) 'Successful stream exceeds capture cap.';if($value.total_byte_length-eq0){Assert-C1bHA ($null-eq$value.first_byte_observed_elapsed_milliseconds) 'Empty stream first-byte observation must be null.'}else{Assert-C1bHAInt $value.first_byte_observed_elapsed_milliseconds 0 $value.eof_observed_elapsed_milliseconds "$name first-byte ordering"}
        Assert-C1bHA ($value.total_byte_length-eq$value.observed_byte_length -and $value.total_byte_length-eq$value.captured_byte_length -and $value.sha256-ceq$value.observed_sha256 -and $value.sha256-ceq$value.captured_sha256) "$name full capture binding missing."
        $raw=@{path=[IO.Path]::Combine([IO.Path]::GetDirectoryName($Pin.path),$name+'.bin');byte_length=$value.total_byte_length;sha256=$value.sha256};$null=Read-C1bHAFile $Session $raw
    }
    Assert-C1bHA ($capture.stderr.total_byte_length-eq0) 'Successful host capture stderr must be empty.'
    return $capture
}
function Assert-C1bHARoot {
    param($Session,$Pin,$CapturePin,$Capture,[string]$CandidateSha,[string]$Phase,[string]$RunId,[long]$ProcessId)
    $root=Read-C1bHAJson $Session $Pin;Assert-C1bHAKeys $root @('schema','candidate_sha','phase','run_id','process_id','native_exit_code','capture_pin') 'root observation'
    Assert-C1bHA ($root.schema-ceq'c1b-host-root-observation/v1' -and $root.candidate_sha-ceq$CandidateSha -and $root.phase-ceq$Phase -and $root.run_id-ceq$RunId) 'Root observation binding mismatch.'
    Assert-C1bHAInt $root.native_exit_code 0 0 'root native exit';Assert-C1bHAInt $root.process_id 1 2147483647 'root PID'
    Assert-C1bHA ($root.process_id-eq$ProcessId -and $root.process_id-eq$Capture.child_pid -and $root.native_exit_code-eq$Capture.exit_code) 'Root/capture PID or native exit mismatch.'
    Assert-C1bHA ($root.capture_pin.path-ceq$CapturePin.path -and $root.capture_pin.sha256-ceq$CapturePin.sha256 -and $root.capture_pin.byte_length-eq$CapturePin.byte_length) 'Root capture raw pin mismatch.';Assert-C1bHAKeys $root.capture_pin @('path','byte_length','sha256') 'root capture pin'
}

function Get-C1bHAGitIndex {
    param([byte[]]$Bytes)
    Assert-C1bHA ($Bytes.Length-ge32 -and [Text.Encoding]::ASCII.GetString($Bytes,0,4)-ceq'DIRC') 'Git index header.'
    function Get-IndexU32([int]$Offset){return ([long]$Bytes[$Offset]*16777216+[long]$Bytes[$Offset+1]*65536+[long]$Bytes[$Offset+2]*256+[long]$Bytes[$Offset+3])}
    $version=Get-IndexU32 4;Assert-C1bHA ($version-eq2 -or $version-eq3) 'Git index v2/v3 required.';$count=Get-IndexU32 8;Assert-C1bHA ($count-gt0 -and $count-le100000) 'Git index entry count.'
    $body=[byte[]]::new($Bytes.Length-20);[Array]::Copy($Bytes,$body,$body.Length);$digest=[Security.Cryptography.SHA1]::HashData($body);for($i=0;$i-lt20;$i++){Assert-C1bHA ($digest[$i]-eq$Bytes[$Bytes.Length-20+$i]) 'Git index checksum.'};[Array]::Clear($body,0,$body.Length)
    $entries=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);$offset=12
    for($n=0;$n-lt$count;$n++){
        $start=$offset;Assert-C1bHA ($offset+62-lt$Bytes.Length-20) 'Git index truncated entry.';$mode=Get-IndexU32 ($offset+24);Assert-C1bHA ($mode-eq33188 -or $mode-eq33261) 'Git special entry mode.'
        $blob=[Convert]::ToHexString($Bytes[($offset+40)..($offset+59)]).ToLowerInvariant();$flags=[int]$Bytes[$offset+60]*256+$Bytes[$offset+61];Assert-C1bHA (($flags-band0xf000)-eq0) 'Git index special flags or stage.';$offset+=62;$pathStart=$offset
        while($offset-lt$Bytes.Length-20 -and $Bytes[$offset]-ne0){$offset++};Assert-C1bHA ($offset-lt$Bytes.Length-20) 'Git path unterminated.';$path=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes,$pathStart,$offset-$pathStart);Assert-C1bHA ($path-cnotmatch '(^/|\\|(^|/)\.{1,2}(/|$)|[\x00-\x1f])') 'Git path unsafe.';Assert-C1bHA ($entries.TryAdd($path,$blob)) 'Git index duplicate path.'
        $used=$offset-$start+1;$padding=8-($used%8);if($padding-eq8){$padding=0};$offset++;for($p=0;$p-lt$padding;$p++){Assert-C1bHA ($Bytes[$offset+$p]-eq0) 'Git index padding.'};$offset+=$padding
    }
    # Optional upper-case Git extensions may be ignored; lower-case mandatory extensions fail closed.
    while($offset-lt$Bytes.Length-20){Assert-C1bHA ($offset+8-le$Bytes.Length-20) 'Git index extension truncated.';$signature=[Text.Encoding]::ASCII.GetString($Bytes,$offset,4);Assert-C1bHA ($signature-cmatch'^[A-Z][A-Za-z]{3}$') 'Git index mandatory extension unsupported.';$length=Get-IndexU32 ($offset+4);$offset+=8+$length;Assert-C1bHA ($offset-le$Bytes.Length-20) 'Git index extension bound.'}
    return ,$entries
}

function Get-C1bHAObservedPin {
    param($Session,[string]$Path)
    $path=Get-C1bHAPath $Path
    if($Session.files.ContainsKey($path)){return $Session.files[$path].pin}
    $inside=$false;foreach($root in $Session.roots){if(Test-C1bHAWithin $path $root){$inside=$true}};Assert-C1bHA $inside 'Observed file out of trusted roots.'
    Open-C1bHADirectories $Session ([IO.Path]::GetDirectoryName($path));$handle=[C1bHostAcceptanceNativeV1]::Open($path,$false);$bytes=$null
    try {
        $identity=[C1bHostAcceptanceNativeV1]::Identity($handle);Assert-C1bHA ($identity.Length-le134217728 -and $identity.Links-eq1 -and ($identity.Attributes-band0x410)-eq0) 'Observed file bounds/type/link.'
        Assert-C1bHA ([string]::Equals([C1bHostAcceptanceNativeV1]::FinalPath($handle),$path,[StringComparison]::OrdinalIgnoreCase)) 'Observed file final path.'
        $alias=[Microsoft.Win32.SafeHandles.SafeFileHandle]::new($handle.DangerousGetHandle(),$false);$stream=[IO.FileStream]::new($alias,[IO.FileAccess]::Read,65536,$false)
        try{$bytes=[byte[]]::new([int]$identity.Length);$offset=0;while($offset-lt$bytes.Length){$n=$stream.Read($bytes,$offset,$bytes.Length-$offset);Assert-C1bHA ($n-gt0) 'Observed file truncated.';$offset+=$n};Assert-C1bHA ($stream.ReadByte()-eq-1) 'Observed file grew.'}finally{$stream.Dispose()}
        $pin=@{path=$path;byte_length=[long]$bytes.Length;sha256=Get-C1bHASha256 $bytes}
        # First handle remains held while the pinned second handle is registered.
        $null=Read-C1bHAFile $Session $pin
        return $pin
    }finally{if($null-ne$bytes){[Array]::Clear($bytes,0,$bytes.Length)};$handle.Dispose()}
}
function Read-C1bHAGitToolPin {
    param($Session,$Pin)
    $root=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),'Git');$expected=[IO.Path]::Combine($root,'cmd','git.exe');Assert-C1bHA ($Pin.path-ceq$expected) 'Only canonical Git executable may use tool hardlink closure.'
    Open-C1bHADirectories $Session ([IO.Path]::GetDirectoryName($Pin.path));$primary=[C1bHostAcceptanceNativeV1]::Open($Pin.path,$false)
    try{
        $identity=[C1bHostAcceptanceNativeV1]::Identity($primary);Assert-C1bHA ($identity.Links-ge1 -and $identity.Links-le1024) 'Git tool link count.'
        $names=[C1bHostAcceptanceNativeV1]::Hardlinks($Pin.path);Assert-C1bHA ($names.Count-eq$identity.Links) 'Git tool hardlink enumeration count.'
        $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($name in $names){Assert-C1bHA ($name.StartsWith('\') -and $name -notmatch ':') 'Git tool link name unsafe.';$path=Get-C1bHAPath ([IO.Path]::GetPathRoot($Pin.path).TrimEnd('\')+$name);Assert-C1bHA ((Test-C1bHAWithin $path $root) -and $paths.Add($path)) 'Git tool hardlink outside canonical tool tree.';$aliasPin=@{path=$path;byte_length=$Pin.byte_length;sha256=$Pin.sha256};$null=Read-C1bHAFile $Session $aliasPin 134217728 $identity.Links;Assert-C1bHA ($Session.files[$path].identity.Id-ceq$identity.Id) 'Git tool hardlink identity mismatch.'}
        Assert-C1bHA ($paths.Contains($Pin.path)) 'Git primary absent from hardlink closure.'
        $after=[C1bHostAcceptanceNativeV1]::Hardlinks($Pin.path);$afterSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($name in $after){$null=$afterSet.Add((Get-C1bHAPath ([IO.Path]::GetPathRoot($Pin.path).TrimEnd('\')+$name)))};Assert-C1bHA ($paths.SetEquals($afterSet)) 'Git hardlink closure changed.'
        return ,$Session.files[$Pin.path].bytes
    }finally{$primary.Dispose()}
}
function Get-C1bHAImplementationMap {
    param([string]$Source)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors);Assert-C1bHA ($errors.Count-eq0) 'Implementation map source parser failed.'
    $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'script:TL1C1bImplementationPathMap'},$true));Assert-C1bHA ($assignments.Count-eq1) 'Implementation map declaration cardinality.'
    $maps=@($assignments[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true));Assert-C1bHA ($maps.Count-eq1 -and $maps[0].KeyValuePairs.Count-eq42) 'Implementation map requires42 literal entries.'
    $result=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($pair in $maps[0].KeyValuePairs){
        Assert-C1bHA ($pair.Item1 -is [Management.Automation.Language.StringConstantExpressionAst]) 'Implementation key must be literal.'
        $values=@($pair.Item2.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true));Assert-C1bHA ($values.Count-eq1 -and $pair.Item2.Extent.Text.Trim() -ceq $values[0].Extent.Text) 'Implementation path must be literal.'
        $key=$pair.Item1.Value;$path=$values[0].Value;Assert-C1bHA ($key-cmatch'^[a-z0-9_]+_sha256$' -and $path-cmatch'^(scripts|docs|app)/' -and $path-cnotmatch'(^|/)\.{1,2}(/|$)|\\|:|[\x00-\x1f]') 'Implementation key/path unsafe.';Assert-C1bHA ($result.TryAdd($key,$path)) 'Implementation duplicate key.'
    }
    Assert-C1bHA ($result.ContainsKey('c1b_library_sha256') -and $result['c1b_library_sha256']-ceq'scripts/lib/tablet-layout-c1b.ps1') 'Implementation authority map self binding.'
    return ,$result
}
function Get-C1bHACaptureStdout {
    param($Session,$Pin,$Capture)
    return ,(Read-C1bHAFile $Session @{path=[IO.Path]::Combine([IO.Path]::GetDirectoryName($Pin.path),'stdout.bin');byte_length=$Capture.stdout.total_byte_length;sha256=$Capture.stdout.sha256})
}
function Assert-C1bHAAuthority {
    param($Session,$A1,[string]$CandidateSha,[string]$RepoRoot)
    Assert-C1bHAKeys $A1 @('index_pin','metadata_pins','implementation_map_pin','implementation_catalog_pin','git_audits','audit_receipt_pin','producer_capture_pin','producer_root_observation_pin','audit_run_id') 'A1'
    Assert-C1bHA ($A1.index_pin.path-ceq[IO.Path]::Combine($RepoRoot,'.git','index') -and $A1.implementation_map_pin.path-ceq[IO.Path]::Combine($RepoRoot,'scripts','lib','tablet-layout-c1b.ps1')) 'A1 index/map authority path mismatch.'
    Open-C1bHADirectories $Session ([IO.Path]::Combine($RepoRoot,'.git','objects'));Assert-C1bHAAbsentFile $Session ([IO.Path]::Combine($RepoRoot,'.git','commondir'));Assert-C1bHAAbsentFile $Session ([IO.Path]::Combine($RepoRoot,'.git','objects','info','alternates'));Assert-C1bHAAbsentFile $Session ([IO.Path]::Combine($RepoRoot,'.git','objects','info','http-alternates'))
    $index=Get-C1bHAGitIndex (Read-C1bHAFile $Session $A1.index_pin)
    Assert-C1bHAKeys $A1.metadata_pins @('head','ref','config','info_exclude','gitattributes','gitignore') 'A1 metadata pins'
    $metadataPaths=@{head='.git/HEAD';config='.git/config';info_exclude='.git/info/exclude';gitattributes='.gitattributes';gitignore='.gitignore'}
    foreach($name in $metadataPaths.Keys){Assert-C1bHA ($A1.metadata_pins[$name].path-ceq[IO.Path]::Combine($RepoRoot,$metadataPaths[$name].Replace('/','\'))) "A1 metadata path $name mismatch.";$null=Read-C1bHAFile $Session $A1.metadata_pins[$name]}
    $head=ConvertFrom-C1bHABytes (Read-C1bHAFile $Session $A1.metadata_pins.head);Assert-C1bHA ($head-cmatch'^ref: refs/heads/([^\r\n]+)\r?\n$') 'A1 ordinary branch HEAD required.';$branch=$Matches[1];Assert-C1bHA ($branch-cnotmatch'\.\.|[\\: ]|[\x00-\x1f]') 'A1 branch unsafe.'
    Assert-C1bHA ($A1.metadata_pins.ref.path-ceq[IO.Path]::Combine($RepoRoot,'.git','refs','heads',$branch.Replace('/','\'))) 'A1 ref path mismatch.'
    Assert-C1bHA ((ConvertFrom-C1bHABytes (Read-C1bHAFile $Session $A1.metadata_pins.ref)) -cmatch ('^'+[regex]::Escape($CandidateSha)+'\r?\n$')) 'A1 ref candidate SHA mismatch.'
    Assert-C1bHA (@($A1.git_audits).Count-eq4) 'A1 four actual Git audits required.';$auditByPhase=@{}
    foreach($audit in $A1.git_audits){
        Assert-C1bHAKeys $audit @('phase','run_id','capture_pin','root_observation_pin') 'A1 Git audit';Assert-C1bHA (@('A1Head','A1Branch','A1Status','A1Tree')-ccontains$audit.phase -and -not$auditByPhase.ContainsKey($audit.phase)) 'A1 audit phase duplicate/unknown.'
        $capture=Assert-C1bHACapture $Session $audit.capture_pin;Assert-C1bHARoot $Session $audit.root_observation_pin $audit.capture_pin $capture $CandidateSha $audit.phase $audit.run_id $capture.child_pid;$auditByPhase[$audit.phase]=Get-C1bHACaptureStdout $Session $audit.capture_pin $capture
    }
    Assert-C1bHA ((ConvertFrom-C1bHABytes $auditByPhase.A1Head)-cmatch('^'+[regex]::Escape($CandidateSha)+'\r?\n$')) 'A1 observed HEAD mismatch.'
    Assert-C1bHA ((ConvertFrom-C1bHABytes $auditByPhase.A1Branch)-cmatch('^'+[regex]::Escape($branch)+'\r?\n$')) 'A1 observed branch mismatch.';Assert-C1bHA ($auditByPhase.A1Status.Length-eq0) 'A1 clean worktree status required.'
    $tree=ConvertFrom-C1bHABytes $auditByPhase.A1Tree;Assert-C1bHA ($tree.EndsWith([string][char]0)) 'A1 tree must be NUL terminated.';$records=$tree.Split([char]0);$treePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($record in $records){if($record.Length-eq0){continue};Assert-C1bHA ($record-cmatch'^(100644|100755) blob ([0-9a-f]{40})\t([^\x00]+)$') 'A1 tree nonordinary entry.';$blob=$Matches[2];$path=$Matches[3];Assert-C1bHA ($treePaths.Add($path) -and $index.ContainsKey($path) -and $index[$path]-ceq$blob) 'A1 tree/index blob or path mismatch.'};Assert-C1bHA ($treePaths.Count-eq$index.Count) 'A1 index has missing/extra tracked path.'
    $map=Get-C1bHAImplementationMap (ConvertFrom-C1bHABytes (Read-C1bHAFile $Session $A1.implementation_map_pin));$hashes=[ordered]@{};$catalog=[Collections.Generic.List[string]]::new()
    $inputs=Read-C1bHAJson $Session $A1.implementation_catalog_pin;Assert-C1bHAKeys $inputs @('schema','candidate_sha','repo_root','held_inputs_during_git_queries','entries') 'A1 implementation inputs';Assert-C1bHA ($inputs.schema-ceq'c1b-candidate-implementation-inputs/v1' -and $inputs.candidate_sha-ceq$CandidateSha -and $inputs.repo_root-ceq$RepoRoot -and @($inputs.entries).Count-eq42) 'A1 implementation inputs binding/count.';Assert-C1bHABool $inputs.held_inputs_during_git_queries $true 'A1 held inputs through Git queries'
    $entries=@{};foreach($entry in $inputs.entries){Assert-C1bHAKeys $entry @('key','path','byte_length','raw_sha256','git_blob_sha1') 'A1 implementation entry';Assert-C1bHA ($map.ContainsKey($entry.key) -and $map[$entry.key]-ceq$entry.path -and -not$entries.ContainsKey($entry.key)) 'A1 implementation path/key mismatch.';Assert-C1bHA ($index.ContainsKey($entry.path) -and $entry.git_blob_sha1-ceq$index[$entry.path]) 'A1 raw entry canonical Git blob mismatch.';$entries[$entry.key]=$entry}
    foreach($entry in $map.GetEnumerator()){ $input=$entries[$entry.Key];$pin=@{path=[IO.Path]::Combine($RepoRoot,$entry.Value.Replace('/','\'));byte_length=$input.byte_length;sha256=$input.raw_sha256};$null=Read-C1bHAFile $Session $pin;$hashes[$entry.Key]='sha256:'+$pin.sha256;$catalog.Add($entry.Value+'=sha256:'+$pin.sha256) }
    $lines=$catalog.ToArray();[Array]::Sort($lines,[StringComparer]::Ordinal);$catalogSha='sha256:'+(Get-C1bHASha256 ([Text.Encoding]::UTF8.GetBytes($lines-join"`n")))
    $producerCapture=Assert-C1bHACapture $Session $A1.producer_capture_pin;$producerReceipt=Read-C1bHAJson $Session $A1.audit_receipt_pin
    Assert-C1bHA ($A1.audit_receipt_pin.path-ceq[IO.Path]::Combine([IO.Path]::GetDirectoryName($A1.producer_capture_pin.path),'stdout.bin') -and $A1.audit_receipt_pin.sha256-ceq$producerCapture.stdout.sha256 -and $A1.audit_receipt_pin.byte_length-eq$producerCapture.stdout.total_byte_length) 'A1 receipt is not actual producer stdout.'
    Assert-C1bHAKeys $producerReceipt @('schema','candidate_sha','repo_root','status','producer_process_id','audit_run_id','git_query_count','automatic_retry_count','adb_execution_count','build_execution_count','caller_declared_candidate_state','a1','tracked_path_count','implementation_count','implementation_pins','implementation_catalog_sha256','source_pins','git_invocations','cleanup_failure_count','readiness_or_device_authorization','object_store') 'A1 actual producer receipt'
    Assert-C1bHA ($producerReceipt.schema-ceq'c1b-candidate-authority-preparation/v1' -and $producerReceipt.candidate_sha-ceq$CandidateSha -and $producerReceipt.repo_root-ceq$RepoRoot -and $producerReceipt.status-ceq'passed_preparation_only' -and $producerReceipt.audit_run_id-ceq$A1.audit_run_id -and $producerReceipt.caller_declared_candidate_state-ceq'UnfrozenPreparation') 'A1 producer receipt identity/state.'
    Assert-C1bHARoot $Session $A1.producer_root_observation_pin $A1.producer_capture_pin $producerCapture $CandidateSha 'A1Audit' $A1.audit_run_id $producerReceipt.producer_process_id
    foreach($key in @('automatic_retry_count','adb_execution_count','build_execution_count','cleanup_failure_count')){Assert-C1bHAInt $producerReceipt[$key] 0 0 "A1 receipt.$key"};Assert-C1bHAInt $producerReceipt.git_query_count 4 4 'A1 query count';Assert-C1bHAInt $producerReceipt.implementation_count 42 42 'A1 implementation count';Assert-C1bHAInt $producerReceipt.tracked_path_count $index.Count $index.Count 'A1 tracked count';Assert-C1bHABool $producerReceipt.readiness_or_device_authorization $false 'A1 no execution authority'
    Assert-C1bHAKeys $producerReceipt.a1 @('index_pin','metadata_pins','implementation_map_pin','implementation_catalog_pin','git_audits') 'A1 receipt core'
    foreach($key in $producerReceipt.a1.Keys){Assert-C1bHA (Test-C1bHAEqual $producerReceipt.a1[$key] $A1[$key]) 'A1 actual producer/input core differs.'}
    Assert-C1bHA ($producerReceipt.implementation_catalog_sha256-ceq$catalogSha) 'A1 producer raw catalog differs from independent raw rehash.'
    Assert-C1bHAKeys $producerReceipt.implementation_pins @($map.Keys) 'A1 actual raw input map';Assert-C1bHA (@($producerReceipt.git_invocations).Count-eq4) 'A1 actual query evidence count.'
    foreach($key in $map.Keys){$pin=$producerReceipt.implementation_pins[$key];$null=Read-C1bHAFile $Session $pin;Assert-C1bHA ($pin.path-ceq[IO.Path]::Combine($RepoRoot,$map[$key].Replace('/','\')) -and $pin.sha256-ceq$entries[$key].raw_sha256 -and $pin.byte_length-eq$entries[$key].byte_length) 'A1 producer raw input differs from fixed catalog.'}
    $invokedPhases=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $gitPrefix=@('--no-optional-locks','-c','core.autocrlf=true','-c','core.fsmonitor=false','-c','core.untrackedCache=false','-c','core.hooksPath=NUL','-C',$RepoRoot)
    $gitQueries=@{A1Head=@('rev-parse','--verify','HEAD^{commit}');A1Branch=@('branch','--show-current');A1Status=@('status','--porcelain=v1','--untracked-files=all');A1Tree=@('ls-tree','-rz','--full-tree','HEAD')}
    $gitEnvironmentKeys=@('COMSPEC','GCM_INTERACTIVE','GIT_CONFIG_COUNT','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','GIT_OPTIONAL_LOCKS','GIT_TERMINAL_PROMPT','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','USERPROFILE','WINDIR')
    foreach($invocation in $producerReceipt.git_invocations){Assert-C1bHAKeys $invocation @('phase','run_id','executable_pin','argument_list','working_directory','environment','capture_pin','root_observation_pin') 'A1 actual Git invocation';Assert-C1bHA ($invokedPhases.Add($invocation.phase) -and $auditByPhase.ContainsKey($invocation.phase) -and $invocation.working_directory-ceq$RepoRoot) 'A1 Git invocation identity/cwd.';$audit=@($A1.git_audits|Where-Object{$_.phase-ceq$invocation.phase})[0];Assert-C1bHA ($invocation.run_id-ceq$audit.run_id -and (Test-C1bHAEqual $invocation.capture_pin $audit.capture_pin) -and (Test-C1bHAEqual $invocation.root_observation_pin $audit.root_observation_pin)) 'A1 actual Git invocation/capture/root mismatch.';$null=Read-C1bHAGitToolPin $Session $invocation.executable_pin;$actual=Read-C1bHAJson $Session $invocation.capture_pin;Assert-C1bHA (Test-C1bHAEqual $invocation.environment $actual.environment) 'A1 actual environment differs from capture.';Assert-C1bHA ($actual.environment.mode-ceq'replace' -and @($actual.environment.keys).Count-eq15) 'A1 exact canonical environment required.'}
    foreach($invocation in $producerReceipt.git_invocations){Assert-C1bHA ($invocation.argument_list-is[array] -and (Test-C1bHAEqual $invocation.argument_list ([object[]]($gitPrefix+$gitQueries[$invocation.phase])))) 'A1 exact canonical Git argv mismatch.';Assert-C1bHA (Test-C1bHAEqual $invocation.environment.keys $gitEnvironmentKeys) 'A1 exact canonical environment names mismatch.'}
    Assert-C1bHAKeys $producerReceipt.source_pins @('a1_auditor','capture','runtime') 'A1 producer sources';foreach($pin in $producerReceipt.source_pins.Values){$null=Read-C1bHAFile $Session $pin}
    $store=$producerReceipt.object_store;Assert-C1bHAKeys $store @('root','ordinary_directory_count','file_count','single_link_verified','object_pins','no_alternates','no_commondir','cleanup_failure_count') 'A1 independent object store';Assert-C1bHA ($store.root-ceq[IO.Path]::Combine($RepoRoot,'.git','objects')) 'A1 objects root.';foreach($key in @('single_link_verified','no_alternates','no_commondir')){Assert-C1bHABool $store[$key] $true "A1 object store.$key"};Assert-C1bHAInt $store.cleanup_failure_count 0 0 'A1 object store cleanup';Assert-C1bHAInt $store.file_count 0 100000 'A1 object count';Assert-C1bHAInt $store.ordinary_directory_count 1 100000 'A1 object directory count';Assert-C1bHA (@($store.object_pins).Count-eq$store.file_count) 'A1 object pin count.'
    $objectPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($pin in $store.object_pins){Assert-C1bHA ((Test-C1bHAWithin $pin.path $store.root) -and $objectPaths.Add($pin.path)) 'A1 object path out of root/duplicate.';$null=Read-C1bHAFile $Session $pin}
    $actualObjects=[Collections.Generic.List[string]]::new();$directories=[Collections.Generic.List[string]]::new();$directories.Add($store.root);for($d=0;$d-lt$directories.Count;$d++){Open-C1bHADirectories $Session $directories[$d];foreach($child in [IO.Directory]::EnumerateFileSystemEntries($directories[$d])){$attributes=[IO.File]::GetAttributes($child);Assert-C1bHA (($attributes-band[IO.FileAttributes]::ReparsePoint)-eq0) 'A1 object store reparse entry.';if(($attributes-band[IO.FileAttributes]::Directory)-ne0){$directories.Add($child)}else{$actualObjects.Add($child)}}};Assert-C1bHA ($directories.Count-eq$store.ordinary_directory_count -and $actualObjects.Count-eq$objectPaths.Count) 'A1 object enumeration count mismatch.';foreach($path in $actualObjects){Assert-C1bHA ($objectPaths.Contains($path)) 'A1 unpinned object store entry.'}
    return @{authority=[ordered]@{repo_root=$RepoRoot;branch=$branch;git_entry_kind='directory';git_index_sha256=$A1.index_pin.sha256;git_index_byte_length=$A1.index_pin.byte_length;tracked_path_count=$index.Count;implementation_catalog_sha256=$catalogSha;implementation_hashes=$hashes;git_metadata=$A1.metadata_pins};map=$map}
}

function Assert-C1bHAStage {
    param($Session,$Stage,[string]$CandidateSha,[string]$RepoRoot)
    Assert-C1bHAKeys $Stage @('phase','observation_pin','outer_capture_pin','root_observation_pin','reader') 'stage input'
    $observation=Read-C1bHAJson $Session $Stage.observation_pin
    Assert-C1bHAKeys $observation @('schema','run_id','candidate_sha','phase','candidate_state','candidate_state_pin','status','started_at_utc','completed_at_utc','bindings_pin','source_pins','runtime_pin','working_directory','argument_list','argument_list_sha256','capture_limits','producer','capture','artifact_inventory','errors','automatic_retry_count') 'stage observation'
    Assert-C1bHA ($observation.schema-ceq'c1b-candidate-host-stage/v1' -and $observation.candidate_sha-ceq$CandidateSha -and $observation.phase-ceq$Stage.phase -and $observation.status-ceq'passed' -and $observation.working_directory-ceq$RepoRoot) 'Stage identity/status/cwd mismatch.'
    Assert-C1bHAInt $observation.automatic_retry_count 0 0 'stage retry';Assert-C1bHA ($observation.errors-is[array] -and $observation.errors.Count-eq0) 'Stage errors unknown/nonempty.';Assert-C1bHA ($observation.artifact_inventory-is[array]) 'Stage artifact inventory must be array.'
    $expectedState=if($Stage.phase-ceq'Preflight'){'frozen_for_host'}elseif($Stage.phase-ceq'Readback'){'post_buildonly'}else{'preparation'};Assert-C1bHA ($observation.candidate_state-ceq$expectedState) 'Stage candidate state mismatch.'
    $state=Read-C1bHAJson $Session $observation.candidate_state_pin;Assert-C1bHAKeys $state @('schema','candidate_sha','state','working_directory') 'candidate state';Assert-C1bHA ($state.schema-ceq'c1b-candidate-host-state/v1' -and $state.candidate_sha-ceq$CandidateSha -and $state.state-ceq$expectedState -and $state.working_directory-ceq$RepoRoot) 'Caller-pinned state mismatch.'
    $bindings=Read-C1bHAJson $Session $observation.bindings_pin;Assert-C1bHAKeys $observation.runtime_pin @('path','byte_length','sha256','version') 'stage runtime';Assert-C1bHAString $observation.runtime_pin.version '^[0-9]+\.[0-9]+\.[0-9]+$' 'stage runtime version';$null=Read-C1bHAFile $Session @{path=$observation.runtime_pin.path;byte_length=$observation.runtime_pin.byte_length;sha256=$observation.runtime_pin.sha256}
    Assert-C1bHAKeys $bindings @('schema','run_id','candidate_sha','phase','candidate_state','candidate_state_pin','runtime','stage_source','transport_sources','working_directory','argument_list','argument_list_sha256','evidence_directory','artifact_inventory','capture_limits','automatic_retry_count','environment') 'stage bindings'
    Assert-C1bHA ($bindings.schema-ceq'c1b-candidate-host-stage-bindings/v1') 'Stage binding schema.'
    foreach($key in @('run_id','candidate_sha','phase','candidate_state','working_directory','argument_list_sha256','automatic_retry_count')){Assert-C1bHA ($bindings[$key]-ceq$observation[$key]) "Stage bindings $key mismatch."}
    Assert-C1bHAString $bindings.run_id '^[0-9a-f]{32}$' 'Stage run ID';Assert-C1bHAInt $bindings.automatic_retry_count 0 0 'Stage bindings retry'
    foreach($key in @('candidate_state_pin','argument_list','capture_limits')){Assert-C1bHA (Test-C1bHAEqual $bindings[$key] $observation[$key]) "Stage binding object $key mismatch."}
    Assert-C1bHAKeys $bindings.runtime @('path','byte_length','sha256','version') 'stage binding runtime';Assert-C1bHA ($bindings.runtime.path-ceq$observation.runtime_pin.path -and $bindings.runtime.byte_length-eq$observation.runtime_pin.byte_length -and $bindings.runtime.sha256-ceq$observation.runtime_pin.sha256 -and $bindings.runtime.version-ceq$observation.producer.runtime_version) 'Stage binding runtime mismatch.'
    Assert-C1bHAKeys $bindings.transport_sources @('invoker','module','capture') 'stage binding transport sources'
    foreach($name in @('invoker','module','capture')){Assert-C1bHA (Test-C1bHAEqual $bindings.transport_sources[$name] $observation.source_pins[$name]) 'Stage transport binding mismatch.'}
    Assert-C1bHA (Test-C1bHAEqual $bindings.stage_source $observation.source_pins.stage_source) 'Stage source binding mismatch.'
    Assert-C1bHA (@($bindings.argument_list).Count-ge3 -and $bindings.argument_list[0]-ceq'-NoProfile' -and $bindings.argument_list[1]-ceq'-File' -and $bindings.argument_list[2]-ceq$bindings.stage_source.path) 'Stage executable argv source mismatch.'
    Assert-C1bHAKeys $bindings.capture_limits @('capture_limit_bytes','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds') 'stage capture limits';Assert-C1bHAInt $bindings.capture_limits.capture_limit_bytes 0 16777216 'Stage capture cap';Assert-C1bHAInt $bindings.capture_limits.timeout_milliseconds 1 86400000 'Stage timeout';foreach($key in @('drain_timeout_milliseconds','cleanup_timeout_milliseconds')){Assert-C1bHAInt $bindings.capture_limits[$key] 1 60000 "Stage $key"}
    Assert-C1bHAKeys $observation.source_pins @('stage_source','invoker','module','capture') 'stage sources';foreach($pin in $observation.source_pins.Values){$null=Read-C1bHAFile $Session $pin}
    Assert-C1bHAKeys $observation.producer @('process_id','runtime_version') 'stage producer';Assert-C1bHAInt $observation.producer.process_id 1 2147483647 'stage producer PID'
    Assert-C1bHA ($observation.argument_list-is[array] -and $observation.argument_list.Count-gt0 -and @($observation.argument_list|Where-Object{$_-isnot[string]}).Count-eq0) 'Stage argv invalid.'
    Assert-C1bHAString $observation.argument_list_sha256 '^[0-9a-f]{64}$' 'stage argv SHA256'
    $argumentJson=Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject @($observation.argument_list) -Compress -Depth 4;Assert-C1bHA ((Get-C1bHASha256 ([Text.Encoding]::UTF8.GetBytes($argumentJson)))-ceq$observation.argument_list_sha256) 'Stage argv hash mismatch.'
    Assert-C1bHAKeys $observation.capture @('directory','execution_pin','reservation_pin','stdout_pin','stderr_pin','stage_native_exit_code','child_pid','stdout_eof','stderr_eof','drains_completed','status','cleanup','environment') 'stage inner capture'
    $inner=Assert-C1bHACapture $Session $observation.capture.execution_pin
    Assert-C1bHA ($Stage.observation_pin.path-ceq[IO.Path]::Combine($bindings.evidence_directory,'observation.json') -and $observation.capture.directory-ceq[IO.Path]::Combine($bindings.evidence_directory,'capture')) 'Stage exact observation/capture directory edge.'
    foreach($edge in @(@('execution_pin','execution.json'),@('reservation_pin','reservation.json'),@('stdout_pin','stdout.bin'),@('stderr_pin','stderr.bin'))){Assert-C1bHA ($observation.capture[$edge[0]].path-ceq[IO.Path]::Combine($observation.capture.directory,$edge[1])) 'Stage exact capture artifact edge.'}
    $stageReservation=Read-C1bHAJson $Session (Get-C1bHAObservedPin $Session ([IO.Path]::Combine($bindings.evidence_directory,'reservation.json')));Assert-C1bHAKeys $stageReservation @('schema','run_id','candidate_sha','phase','bindings_pin','automatic_retry_count') 'stage reservation';Assert-C1bHA ($stageReservation.schema-ceq'c1b-candidate-host-stage-reservation/v1' -and $stageReservation.run_id-ceq$observation.run_id -and $stageReservation.candidate_sha-ceq$CandidateSha -and $stageReservation.phase-ceq$Stage.phase) 'Stage reservation identity mismatch.';Assert-C1bHAInt $stageReservation.automatic_retry_count 0 0 'Stage reservation retry';Assert-C1bHA (Test-C1bHAEqual $stageReservation.bindings_pin $observation.bindings_pin) 'Stage reservation binding raw pin mismatch.'
    Assert-C1bHA ($inner.capture_limit_bytes_per_stream-eq$bindings.capture_limits.capture_limit_bytes -and $inner.timeout_milliseconds-eq$bindings.capture_limits.timeout_milliseconds -and $inner.drain_timeout_milliseconds-eq$bindings.capture_limits.drain_timeout_milliseconds -and $inner.cleanup_timeout_milliseconds-eq$bindings.capture_limits.cleanup_timeout_milliseconds) 'Actual capture limits differ from reviewed bindings.'
    if($null-eq$bindings.environment){Assert-C1bHA ($inner.environment.mode-ceq'inherit') 'Capture environment inheritance mismatch.'}else{Assert-C1bHAKeys $bindings.environment @('clear_environment','variables','sha256') 'stage environment bindings';Assert-C1bHA ($bindings.environment.clear_environment-is[bool] -and $bindings.environment.variables-is[Collections.IDictionary]) 'Environment binding types.';foreach($value in $bindings.environment.variables.Values){Assert-C1bHA ($value-is[string]) 'Environment variable type.'};$mode=if($bindings.environment.clear_environment){'replace'}else{'overlay'};Assert-C1bHA ($inner.environment.mode-ceq$mode -and $inner.environment.sha256-ceq$bindings.environment.sha256) 'Actual environment hash/mode differs from reviewed binding.'}
    Assert-C1bHA (Test-C1bHAEqual $observation.capture.environment $inner.environment) 'Stage environment/raw capture mismatch.';Assert-C1bHA (Test-C1bHAEqual $observation.capture.cleanup $inner.cleanup) 'Stage cleanup/raw capture mismatch.'
    Assert-C1bHA ($observation.capture.directory-ceq[IO.Path]::GetDirectoryName($observation.capture.execution_pin.path) -and $observation.capture.child_pid-eq$inner.child_pid -and $observation.capture.stage_native_exit_code-eq0 -and $observation.capture.status-ceq'passed') 'Stage inner capture binding mismatch.'
    foreach($key in @('stdout_eof','stderr_eof','drains_completed')){Assert-C1bHABool $observation.capture[$key] $true "stage.$key"}
    Assert-C1bHAInt $observation.capture.child_pid 1 2147483647 'stage child PID';Assert-C1bHAInt $observation.capture.stage_native_exit_code 0 0 'stage native exit'
    foreach($name in @('stdout','stderr')){$pin=$observation.capture[$name+'_pin'];Assert-C1bHA ($pin.path-ceq[IO.Path]::Combine($observation.capture.directory,$name+'.bin') -and $pin.sha256-ceq$inner[$name].sha256 -and $pin.byte_length-eq$inner[$name].total_byte_length) 'Stage stream raw pin mismatch.';$null=Read-C1bHAFile $Session $pin}
    $reservation=Read-C1bHAJson $Session $observation.capture.reservation_pin;Assert-C1bHAKeys $reservation @('schema','started_at_utc','parent_pid','automatic_retry_count') 'capture reservation';Assert-C1bHAInt $reservation.parent_pid 1 2147483647 'Capture reservation parent PID';Assert-C1bHAInt $reservation.automatic_retry_count 0 0 'Capture reservation retry';Assert-C1bHA ($reservation.schema-ceq'tl1-c1b-host-process-capture-reservation/v1' -and $reservation.parent_pid-eq$observation.producer.process_id -and $reservation.started_at_utc-ceq$inner.started_at_utc) 'Stage capture reservation mismatch.'
    $outer=Assert-C1bHACapture $Session $Stage.outer_capture_pin;Assert-C1bHARoot $Session $Stage.root_observation_pin $Stage.outer_capture_pin $outer $CandidateSha $Stage.phase $observation.run_id $observation.producer.process_id
    $outerReport=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes (Get-C1bHACaptureStdout $Session $Stage.outer_capture_pin $outer));Assert-C1bHA (Test-C1bHAEqual $outerReport $observation) 'Stage actual producer stdout differs from saved observation.'
    Assert-C1bHAKeys $Stage.reader @('report_pin','capture_pin','root_observation_pin') 'stage independent reader';$readerCapture=Assert-C1bHACapture $Session $Stage.reader.capture_pin
    Assert-C1bHA ($Stage.reader.report_pin.path-ceq[IO.Path]::Combine([IO.Path]::GetDirectoryName($Stage.reader.capture_pin.path),'stdout.bin') -and $Stage.reader.report_pin.sha256-ceq$readerCapture.stdout.sha256 -and $Stage.reader.report_pin.byte_length-eq$readerCapture.stdout.total_byte_length) 'Reader report is not actual captured stdout.'
    $report=Read-C1bHAJson $Session $Stage.reader.report_pin;Assert-C1bHAKeys $report @('schema','status','run_id','candidate_sha','phase','observation_pin','checked_pin_count','producer_process_id','reader_process_id','stage_native_exit_code','root_native_exit_observed') 'stage Read report'
    Assert-C1bHA ($report.schema-ceq'c1b-candidate-host-stage-read/v1' -and $report.status-ceq'passed' -and $report.run_id-ceq$observation.run_id -and $report.candidate_sha-ceq$CandidateSha -and $report.phase-ceq$Stage.phase -and $report.producer_process_id-eq$observation.producer.process_id -and $report.stage_native_exit_code-eq0) 'Stage Read report binding/status mismatch.'
    Assert-C1bHABool $report.root_native_exit_observed $false 'Reader cannot infer own final native exit';Assert-C1bHA ($report.observation_pin.path-ceq$Stage.observation_pin.path -and $report.observation_pin.sha256-ceq$Stage.observation_pin.sha256 -and $report.observation_pin.byte_length-eq$Stage.observation_pin.byte_length) 'Reader observation pin mismatch.'
    foreach($key in @('producer_process_id','reader_process_id')){Assert-C1bHAInt $report[$key] 1 2147483647 "stage Read $key"};Assert-C1bHAInt $report.stage_native_exit_code 0 0 'stage Read native exit';Assert-C1bHAInt $report.checked_pin_count 1 100000 'stage Read checked pins';$null=Read-C1bHAFile $Session $report.observation_pin
    Assert-C1bHA ($report.checked_pin_count-eq13+@($observation.artifact_inventory).Count) 'Stage Read checked pin count differs from actual required graph.'
    Assert-C1bHARoot $Session $Stage.reader.root_observation_pin $Stage.reader.capture_pin $readerCapture $CandidateSha $Stage.phase $observation.run_id $report.reader_process_id
    $artifacts=[Collections.Generic.List[object]]::new();$paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in $observation.artifact_inventory){Assert-C1bHAKeys $item @('path','required','present','byte_length','sha256') 'stage artifact';Assert-C1bHABool $item.present $true 'Required stage artifact presence';Assert-C1bHABool $item.required $true 'Stage artifact must be required';Assert-C1bHA ($paths.Add($item.path)) 'Stage artifact duplicate.';$pin=@{path=$item.path;byte_length=$item.byte_length;sha256=$item.sha256};$null=Read-C1bHAFile $Session $pin;$artifacts.Add($pin)}
    Assert-C1bHA (@($bindings.artifact_inventory).Count-eq$artifacts.Count) 'Stage binding artifact count mismatch.';foreach($item in $bindings.artifact_inventory){Assert-C1bHAKeys $item @('path','required') 'binding artifact';Assert-C1bHABool $item.required $true 'Binding artifact required';Assert-C1bHA ($paths.Contains($item.path)) 'Actual artifact not matching binding manifest.'}
    return @{observation=$observation;inner=$inner;stdout=(Get-C1bHACaptureStdout $Session $observation.capture.execution_pin $inner);artifacts=$artifacts.ToArray()}
}

function Assert-C1bHAReviewedSources {
    param($Session,$ReviewPin,[string]$CandidateSha,$Stages,$BuildOnly,$InputMap)
    $review=Read-C1bHAJson $Session $ReviewPin;Assert-C1bHAKeys $review @('schema','candidate_sha','status','reviewer_independent','reviewed_source_pins','unresolved_findings','forbidden_capability_count') 'independent source review'
    Assert-C1bHA ($review.schema-ceq'c1b-host-source-review/v1' -and $review.candidate_sha-ceq$CandidateSha -and $review.status-ceq'passed') 'Independent source review candidate/status mismatch.';Assert-C1bHABool $review.reviewer_independent $true 'Independent reviewer';Assert-C1bHAInt $review.forbidden_capability_count 0 0 'Reviewed forbidden capabilities';Assert-C1bHA ($review.unresolved_findings-is[array] -and $review.unresolved_findings.Count-eq0 -and $review.reviewed_source_pins-is[array]) 'Independent source review unresolved/unknown evidence.'
    $required=@('a1_auditor','stage_source','stage_invoker','stage_module','capture','build_only_wrapper','readback_reader','host_acceptance','host_acceptance_writer','device_maintenance','device_generator','device_entries','discovery_maintenance','discovery_consumer','schemas','launcher','helper','verifier','implementation_sources','raw_archive_producer','root_stage_driver')
    $roles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$pins=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in $review.reviewed_source_pins){Assert-C1bHAKeys $item @('role','pin') 'reviewed source';Assert-C1bHAString $item.role '^[a-z][a-z0-9_]*$' 'source role';$null=$roles.Add($item.role);$null=Read-C1bHAFile $Session $item.pin;if($pins.ContainsKey($item.pin.path)){Assert-C1bHA ($pins[$item.pin.path].sha256-ceq$item.pin.sha256) 'Reviewed source conflicting pin.'}else{$pins.Add($item.pin.path,$item.pin)}}
    foreach($role in $required){Assert-C1bHA ($roles.Contains($role)) "Independent review missing role $role."}
    $mustReview=[Collections.Generic.List[object]]::new();foreach($stage in $Stages.Values){foreach($pin in $stage.observation.source_pins.Values){$mustReview.Add($pin)}}
    foreach($key in @('launcher_source_pin','helper_source_pin','verifier_source_pin')){$mustReview.Add($BuildOnly[$key])};$mustReview.Add($BuildOnly.elevation.wrapper_source_pin)
    if($null-ne$InputMap){
        $a1Receipt=Read-C1bHAJson $Session $InputMap.a1.audit_receipt_pin;$mustReview.Add($a1Receipt.source_pins.a1_auditor);$mustReview.Add($a1Receipt.source_pins.capture);$mustReview.Add($InputMap.raw_archive_execution.producer_source_pin)
        $archiveCapture=Read-C1bHAJson $Session $InputMap.raw_archive_execution.capture_pin;$archiveOutput=Read-C1bHAJson $Session @{path=[IO.Path]::Combine([IO.Path]::GetDirectoryName($InputMap.raw_archive_execution.capture_pin.path),'stdout.bin');byte_length=$archiveCapture.stdout.total_byte_length;sha256=$archiveCapture.stdout.sha256};$archiveInputs=Read-C1bHAJson $Session $archiveOutput.inputs_pin;$mustReview.Add($archiveInputs.ha_module_pin)
        foreach($binding in @(@('a1_auditor',$a1Receipt.source_pins.a1_auditor),@('raw_archive_producer',$InputMap.raw_archive_execution.producer_source_pin),@('host_acceptance',$archiveInputs.ha_module_pin))){Assert-C1bHA (@($review.reviewed_source_pins|Where-Object{$_.role-ceq$binding[0] -and (Test-C1bHAEqual $_.pin $binding[1])}).Count-ge1) 'Review role does not bind actual executed or loaded source.'}
    }
    foreach($pin in $mustReview){Assert-C1bHA ($pins.ContainsKey($pin.path) -and $pins[$pin.path].sha256-ceq$pin.sha256 -and $pins[$pin.path].byte_length-eq$pin.byte_length) 'Current source is missing from independent review.'}
    # All current implementation raw pins are recognizable by their exact authoritative repo paths.
    $implementationMap=Get-C1bHAImplementationMap (ConvertFrom-C1bHABytes $Session.files[[IO.Path]::Combine($Stages.FullCheck.observation.working_directory,'scripts','lib','tablet-layout-c1b.ps1')].bytes)
    foreach($relative in $implementationMap.Values){$path=[IO.Path]::Combine($Stages.FullCheck.observation.working_directory,$relative.Replace('/','\'));Assert-C1bHA ($pins.ContainsKey($path) -and $pins[$path].sha256-ceq$Session.files[$path].pin.sha256) 'Current implementation source missing from independent review.'}
    return $review
}
function Assert-C1bHAPublishedSource {
    param($Session,[string]$Path,[long]$Length,[string]$Sha256)
    $pin=@{path=$Path;byte_length=$Length;sha256=$Sha256};$null=Read-C1bHAFile $Session $pin
    Assert-C1bHA (($Session.files[$Path].identity.Attributes-band1)-eq1) 'Published source must be read-only.';return $pin
}
function Assert-C1bHAStageSemantics {
    param($Session,$Stages,[string]$CandidateSha,$BuildOnly,$Authority)
    $check=$Stages.FullCheck;Assert-C1bHA (@($check.observation.argument_list|Where-Object{$_-match'(?i)SkipGradle'}).Count-eq0) 'Full gate must not skip Gradle.'
    $checkPin=$check.observation.source_pins.stage_source;Assert-C1bHA ($checkPin.path-ceq[IO.Path]::Combine($Authority.repo_root,'scripts','check.ps1')) 'FullCheck must execute exact candidate check.ps1.'
    $checkSource=ConvertFrom-C1bHABytes (Read-C1bHAFile $Session $checkPin);$tokens=$null;$errors=$null;$checkAst=[Management.Automation.Language.Parser]::ParseInput($checkSource,[ref]$tokens,[ref]$errors);Assert-C1bHA ($errors.Count-eq0) 'FullCheck source parser failed.'
    $calls=@($checkAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq'Invoke-Check'},$true));$titles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($call in $calls){Assert-C1bHA ($call.CommandElements.Count-ge2 -and $call.CommandElements[1]-is[Management.Automation.Language.StringConstantExpressionAst] -and $titles.Add($call.CommandElements[1].Value)) 'FullCheck source title must be unique literal.'}
    Assert-C1bHA ($titles.Count-eq14 -and $titles.Contains('Android JVM/Lint/构建')) 'Current full gate requires fourteen checked titles including Android.'
    $text=ConvertFrom-C1bHABytes $check.stdout;$lines=[regex]::Matches($text,'(?m)^PASS\s+(.+?)\s+[0-9]+(?:\.[0-9]+)?s\s*\r?$');$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($line in $lines){Assert-C1bHA ($titles.Contains($line.Groups[1].Value) -and $seen.Add($line.Groups[1].Value)) 'A2 actual PASS title unknown or duplicated.'}
    Assert-C1bHA ($seen.SetEquals($titles) -and [regex]::Matches($text,'(?m)^PASS\s+').Count-eq14 -and $text-cmatch'(?m)^全部通过。\r?$' -and $text-cnotmatch'(?m)^(FAIL|SKIP)\s') 'A2 all fourteen current gates including Android must pass.'
    $prepare=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes $Stages.PrepareSources.stdout)
    Assert-C1bHAKeys $prepare @('schema','commit_sha','output_directory','files','source_derivation_only','source_inputs','repository_library_hashes','clean_sha_verified','artifacts_published','preflight_executed','helper_or_launcher_executed','git_or_build_or_adb_executed') 'PrepareSources report'
    Assert-C1bHA ($prepare.schema-ceq'tablet-layout-c1b-review-source/v1' -and $prepare.commit_sha-ceq$CandidateSha) 'A3 PrepareSources identity.';Assert-C1bHABool $prepare.source_derivation_only $true 'Prepare source scope';foreach($key in @('artifacts_published','preflight_executed','helper_or_launcher_executed','git_or_build_or_adb_executed')){Assert-C1bHABool $prepare[$key] $false "Prepare.$key"}
    $helperPaths=[ordered]@{c1a='scripts/lib/tablet-layout-c1a.ps1';validator='scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1';c1b='scripts/lib/tablet-layout-c1b.ps1';artifact='scripts/lib/tablet-layout-c1b-artifact-proof.ps1';aapt2='scripts/lib/tablet-layout-c1b-aapt2.ps1';build='scripts/lib/tablet-layout-c1b-build-env.ps1';runner='scripts/run-tablet-layout-c1b.ps1'};Assert-C1bHAKeys $prepare.repository_library_hashes @($helperPaths.Keys) 'Prepare final repository library hashes'
    foreach($key in $helperPaths.Keys){$pin=Get-C1bHAObservedPin $Session ([IO.Path]::Combine($Authority.repo_root,$helperPaths[$key].Replace('/','\')));Assert-C1bHA ($prepare.repository_library_hashes[$key]-ceq('sha256:'+$pin.sha256)) 'Prepare final repository library raw hash differs from A1 current held input.'}
    $maintained=@('scripts/prepare-tablet-layout-c1b-candidate-source.ps1','scripts/lib/tablet-layout-c1b-candidate-source.ps1','scripts/lib/c1b-candidate-source/renderer-template.ps1','scripts/lib/c1b-candidate-source/helper-template.ps1','scripts/lib/c1b-candidate-source/launcher-template.ps1','scripts/lib/c1b-candidate-source/preflight-template.ps1','scripts/lib/tablet-layout-c1b-preflight-r14-checks.ps1')+@($helperPaths.Values);$sourcePaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    Assert-C1bHA ($prepare.source_inputs-is[array] -and $prepare.source_inputs.Count-eq14) 'Prepare exact fourteen maintained inputs required.';foreach($item in $prepare.source_inputs){Assert-C1bHAKeys $item @('path','sha256') 'Prepare maintained input';Assert-C1bHA ($maintained-ccontains$item.path -and $sourcePaths.Add($item.path)) 'Prepare maintained source unknown/duplicate.';$pin=Get-C1bHAObservedPin $Session ([IO.Path]::Combine($Authority.repo_root,$item.path.Replace('/','\')));Assert-C1bHA ($pin.sha256-ceq$item.sha256) 'Prepare maintained raw source hash mismatch.'}
    $preparedByHash=@{};$preparedByName=@{};Assert-C1bHA (@($prepare.files).Count-eq5) 'PrepareSources must bind exact five expected sources.';foreach($item in $prepare.files){Assert-C1bHAKeys $item @('name','byte_length','sha256') 'prepared file';Assert-C1bHA ($item.name -is [string] -and [IO.Path]::GetFileName($item.name)-ceq$item.name -and $item.name-cnotmatch'[:\\/]' -and -not$preparedByName.ContainsKey($item.name)) 'Prepared leaf unsafe or duplicate.';$pin=@{path=[IO.Path]::Combine($prepare.output_directory,$item.name);byte_length=$item.byte_length;sha256=$item.sha256};$null=Read-C1bHAFile $Session $pin;$preparedByHash[$item.sha256]=$pin;$preparedByName[$item.name]=$pin}
    $short=$CandidateSha.Substring(0,7);$names=@(('render-final-r12-'+$short+'.ps1'),('render-preflight-r14-'+$short+'.ps1'),('helper-'+$short+'-r11.expected.ps1'),('launcher-'+$short+'-r11.expected.ps1'),('preflight-'+$short+'-r14.expected.ps1'));foreach($name in $names){Assert-C1bHA ($preparedByName.ContainsKey($name)) 'Current expected source leaf missing.'}
    Assert-C1bHA (Test-C1bHAEqual $Stages.Pair.observation.source_pins.stage_source $preparedByName['render-final-r12-'+$short+'.ps1']) 'Pair renderer source differs from current derived source.';Assert-C1bHA (Test-C1bHAEqual $Stages.R14.observation.source_pins.stage_source $preparedByName['render-preflight-r14-'+$short+'.ps1']) 'R14 renderer source differs from current derived source.'
    $pair=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes $Stages.Pair.stdout);Assert-C1bHA ($pair.schema-ceq'tablet-layout-c1b-exact-launcher-r11-render/v1' -and $pair.commit_sha-ceq$CandidateSha -and $pair.renderer_execution_scope-ceq'artifact_generation_only') 'A3 exact pair identity/scope.'
    foreach($key in @('launcher_executed','helper_executed','preflight_executed','git_executed','build_executed','adb_or_device_operation_executed','failure_sidecar_created','smoke_outputs_created')){Assert-C1bHABool $pair[$key] $false "Pair.$key"}
    foreach($name in @('launcher','helper')){
        $pin=Assert-C1bHAPublishedSource $Session $pair[$name+'_path'] $pair[$name+'_byte_length'] $pair[$name+'_sha256'];Assert-C1bHA ($preparedByHash.ContainsKey($pin.sha256)) 'Pair differs from reviewed expected bytes.';Assert-C1bHA ($BuildOnly[$name+'_source_pin'].path-ceq$pin.path -and $BuildOnly[$name+'_source_pin'].sha256-ceq$pin.sha256 -and $BuildOnly[$name+'_source_pin'].byte_length-eq$pin.byte_length) 'BuildOnly source differs from exact pair.'
    }
    $r14=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes $Stages.R14.stdout);Assert-C1bHA ($r14.schema-ceq'tablet-layout-c1b-r14-render/v1' -and $r14.commit_sha-ceq$CandidateSha -and $r14.renderer_execution_scope-ceq'artifact_generation_only') 'A3 r14 identity/scope.'
    foreach($key in @('launcher_executed','helper_executed','preflight_executed','git_executed','build_executed','adb_or_device_operation_executed')){Assert-C1bHABool $r14[$key] $false "R14.$key"}
    $preflightPin=Assert-C1bHAPublishedSource $Session $r14.preflight_path $r14.preflight_byte_length $r14.preflight_sha256;Assert-C1bHA ($preparedByHash.ContainsKey($preflightPin.sha256)) 'R14 differs from reviewed expected bytes.'
    $receipts=[Collections.Generic.List[object]]::new()
    foreach($pin in $Stages.Preflight.artifacts){if($pin.path.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)){$item=Read-C1bHAJson $Session $pin;if($item.Contains('schema') -and $item.schema-ceq'tablet-layout-c1b-prepared-not-authorized-preflight/v1'){$receipts.Add($item)}}}
    Assert-C1bHA ($receipts.Count-eq1) 'Exactly one original Preflight receipt required.';$receipt=$receipts[0]
    Assert-C1bHA ($receipt.expected_commit_sha-ceq$CandidateSha -and $receipt.actual_head_sha-ceq$CandidateSha -and $receipt.actual_branch-ceq$Authority.branch) 'Preflight candidate/branch mismatch.'
    foreach($key in @('prepared_not_authorized','all_checks_passed','clean_head_verified','worktree_clean','git_index_special_flags_absent','git_submodules_absent','passive_host_adb_state_all_observations_available','passive_host_adb_state_all_observations_zero','held_guard_and_sensitive_buffer_cleanup_calls_completed_without_exception')){Assert-C1bHABool $receipt[$key] $true "Preflight.$key"}
    foreach($key in @('launcher_executed','helper_executed','build_executed','adb_or_device_operation_executed','adb_command_executed','receipt_is_execution_authority')){Assert-C1bHABool $receipt[$key] $false "Preflight.$key"}
    foreach($key in @('failure_count','pre_publication_failure_record_count','read_only_git_primary_failure_count','read_only_git_cleanup_failure_count','pre_publication_guard_cleanup_failure_count','device_enumeration_attempt_count')){Assert-C1bHAInt $receipt[$key] 0 0 "Preflight.$key"};Assert-C1bHA (@($receipt.failure_reasons).Count-eq0) 'Preflight failure reasons.'
    Assert-C1bHA ($receipt.git_tracked_path_count-eq$Authority.tracked_path_count -and $receipt.expected_git_tracked_path_count-eq$Authority.tracked_path_count) 'Preflight/A1 tracked count mismatch.'
    # Original r14 receipt records final generated file pins; require an exact hash reference for every pair source.
    Assert-C1bHA (Test-C1bHAEqual $Stages.Preflight.observation.source_pins.stage_source $preflightPin) 'Preflight actual executed source differs from R14 bytes.'
    Assert-C1bHAKeys $receipt.four_objects_held_and_hash_verified_during_static_inspection @('launcher','helper','verifier','pinned_pwsh') 'Preflight held objects'
    foreach($mapping in @(@('launcher','launcher_source_pin','launcher'),@('helper','helper_source_pin','helper'),@('verifier','verifier_source_pin','verifier'),@('pinned_pwsh','runtime_pin','pwsh'))){
        $pin=$BuildOnly[$mapping[1]];$item=$receipt.four_objects_held_and_hash_verified_during_static_inspection[$mapping[0]];Assert-C1bHA ($item.path-ceq$pin.path -and $item.expected_sha256-ceq$pin.sha256 -and $item.actual_sha256-ceq$pin.sha256 -and $item.byte_length-eq$pin.byte_length -and $item.link_count-eq1) 'Preflight exact held object differs from BuildOnly.';foreach($key in @('single_link_required','no_follow_verified','final_path_verified')){Assert-C1bHABool $item[$key] $true "Preflight object.$key"};Assert-C1bHA ($receipt['expected_'+$mapping[2]+'_sha256']-ceq$pin.sha256 -and $receipt['actual_'+$mapping[2]+'_sha256']-ceq$pin.sha256) 'Preflight typed expected/actual source hash mismatch.'
    }
    return @{pair=$pair;r14=$r14;receipt=$receipt}
}

function Initialize-C1bHASummaryVerifier {
    param($Session,$VerifierPin,$SummaryVerifierContext)
    $sourceBytes=Read-C1bHAFile $Session $VerifierPin;$source=ConvertFrom-C1bHABytes $sourceBytes
    if($null-ne$SummaryVerifierContext){
        Assert-C1bHAKeys $SummaryVerifierContext @('source_pin','native_authority_owner','source_bytes') 'Explicit private summary verifier context'
        Assert-C1bHA ($SummaryVerifierContext.native_authority_owner-ceq'c1b-device-entry-source' -and $SummaryVerifierContext.source_bytes-is[byte[]]) 'Untrusted private verifier native authority owner.'
        Assert-C1bHA (Test-C1bHAEqual $SummaryVerifierContext.source_pin $VerifierPin) 'Private verifier source pin differs from current held source.'
        Assert-C1bHA ($SummaryVerifierContext.source_bytes.Length-eq$VerifierPin.byte_length -and (Get-C1bHASha256 $SummaryVerifierContext.source_bytes)-ceq$VerifierPin.sha256) 'Private verifier source bytes differ from current held source.'
    }
    if($null-ne(Get-Variable C1bHAVerifierModule -Scope Script -ErrorAction SilentlyContinue)){Assert-C1bHA ($script:C1bHAVerifierHash-ceq$VerifierPin.sha256) 'Verifier source changed after authority load.';if($script:C1bHAVerifierOwner-ceq'c1b-device-entry-source'){Assert-C1bHA ($null-ne$SummaryVerifierContext) 'Externally owned verifier requires explicit owner context on every consumption.'};return}
    if($null-ne('TL1C1bRealBuildSmokeFileIdentityV1'-as[type])){
        Assert-C1bHA ($null-ne$SummaryVerifierContext) 'Preloaded summary native authority requires explicit verified owner context.'
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);Assert-C1bHA ($errors.Count-eq0) 'Explicit verifier source parser failed.'
        $definitions=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]},$false));Assert-C1bHA ($definitions.Count-eq16) 'Explicit verifier function graph cardinality.'
        $definitionSource=($definitions|ForEach-Object{$_.Extent.Text})-join"`n";$script:C1bHAVerifierModule=New-Module -ScriptBlock ([scriptblock]::Create($definitionSource))
        $script:C1bHAVerifierOwner='c1b-device-entry-source'
    }else{$script:C1bHAVerifierModule=New-Module -ScriptBlock ([scriptblock]::Create($source));$script:C1bHAVerifierOwner='host_acceptance'}
    $script:C1bHAVerifierHash=$VerifierPin.sha256
}
function Assert-C1bHAElevationMarkers {
    param($Session,$BuildOnly,$Result)
    # These are the exact permanent paths emitted by the reviewed wrapper.
    # The wrapper does not set ReadOnly; held raw pins and sealing supply preservation.
    $oncePath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($BuildOnly.launcher_source_pin.path),('build-only-'+$Result.candidate_sha+'.once.json'))
    $elevatedPath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($BuildOnly.elevation.result_pin.path),'elevated-start.json')
    $once=Read-C1bHAJson $Session (Get-C1bHAObservedPin $Session $oncePath)
    Assert-C1bHAKeys $once @('schema','candidate_sha','nonce','run_id','driver_pid','invocation_count','automatic_retry_count') 'BuildOnly permanent once marker'
    Assert-C1bHA ($once.schema-ceq'c1b-build-only-elevation-reservation/v1') 'BuildOnly once marker schema.'
    $start=Read-C1bHAJson $Session (Get-C1bHAObservedPin $Session $elevatedPath)
    Assert-C1bHAKeys $start @('schema','candidate_sha','nonce','run_id','elevated_pid','driver_pid','launcher_start_attempt_count','automatic_retry_count') 'BuildOnly elevated start marker'
    Assert-C1bHA ($start.schema-ceq'c1b-build-only-elevated-start/v1') 'BuildOnly elevated start schema.'
    foreach($record in @($once,$start)){foreach($key in @('candidate_sha','run_id','nonce')){Assert-C1bHA ($record[$key]-ceq$Result[$key]) ('BuildOnly marker '+$key+' binding.')};Assert-C1bHAInt $record.driver_pid $Result.driver_pid $Result.driver_pid 'BuildOnly marker driver PID';Assert-C1bHAInt $record.automatic_retry_count 0 0 'BuildOnly marker retry'}
    Assert-C1bHAInt $once.invocation_count 1 1 'BuildOnly permanent invocation';Assert-C1bHAInt $start.launcher_start_attempt_count 1 1 'BuildOnly actual launcher start attempts';Assert-C1bHAInt $start.elevated_pid $Result.elevated_pid $Result.elevated_pid 'BuildOnly marker elevated PID'
}
function Assert-C1bHABuildOnly {
    param($Session,$BuildOnly,$Stages,[string]$CandidateSha,$Authority,$SummaryVerifierContext)
    Assert-C1bHAKeys $BuildOnly @('run_id','capture_pin','root_observation_pin','launcher_source_pin','helper_source_pin','verifier_source_pin','runtime_pin','launcher_pin','summary_pin','log_pin','readback_report_pin','failure_sidecar_path','elevation') 'BuildOnly evidence'
    foreach($name in @('launcher_source_pin','helper_source_pin','verifier_source_pin','runtime_pin','launcher_pin','summary_pin','log_pin','readback_report_pin')){$null=Read-C1bHAFile $Session $BuildOnly[$name]}
    $capture=Assert-C1bHACapture $Session $BuildOnly.capture_pin;Assert-C1bHARoot $Session $BuildOnly.root_observation_pin $BuildOnly.capture_pin $capture $CandidateSha 'BuildOnly' $BuildOnly.run_id $capture.child_pid
    Assert-C1bHAAbsentFile $Session $BuildOnly.failure_sidecar_path
    $elevation=$BuildOnly.elevation;Assert-C1bHAKeys $elevation @('wrapper_source_pin','driver_capture_pin','driver_root_observation_pin','result_pin') 'elevation evidence';$null=Read-C1bHAFile $Session $elevation.wrapper_source_pin
    $driver=Assert-C1bHACapture $Session $elevation.driver_capture_pin;$result=Read-C1bHAJson $Session $elevation.result_pin
    Assert-C1bHAKeys $result @('schema','candidate_sha','status','run_id','nonce','invocation_count','automatic_retry_count','elevated_pid','driver_pid','token_elevated','launcher_capture_pin','launcher_source_pin','expected_launcher_sha256','argument_list','argument_list_sha256','native_exit_code','wrapper_source_pin','elevated_native_exit_code') 'elevated result'
    Assert-C1bHA ($result.schema-ceq'c1b-build-only-elevation-result/v1' -and $result.candidate_sha-ceq$CandidateSha -and $result.status-ceq'passed' -and $result.run_id-ceq$BuildOnly.run_id) 'UAC result binding/status.';Assert-C1bHAString $result.nonce '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' 'UAC nonce';Assert-C1bHAInt $result.invocation_count 1 1 'UAC invocation';foreach($key in @('automatic_retry_count','native_exit_code')){Assert-C1bHAInt $result[$key] 0 0 "UAC.$key"};Assert-C1bHABool $result.token_elevated $true 'UAC token';Assert-C1bHAInt $result.elevated_pid 1 2147483647 'elevated PID';Assert-C1bHAInt $result.driver_pid 1 2147483647 'driver PID';Assert-C1bHA ($result.driver_pid-ne$result.elevated_pid -and $result.elevated_pid-ne$capture.child_pid) 'UAC process roles conflated.'
    Assert-C1bHAInt $result.elevated_native_exit_code 0 0 'Elevated actual native exit'
    Assert-C1bHARoot $Session $elevation.driver_root_observation_pin $elevation.driver_capture_pin $driver $CandidateSha 'BuildOnlyDriver' $BuildOnly.run_id $result.driver_pid
    $driverOutput=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes (Read-C1bHAFile $Session @{path=[IO.Path]::Combine([IO.Path]::GetDirectoryName($elevation.driver_capture_pin.path),'stdout.bin');byte_length=$driver.stdout.total_byte_length;sha256=$driver.stdout.sha256}));Assert-C1bHAKeys $driverOutput @('schema','operation','result_pin') 'BuildOnly actual driver stdout';Assert-C1bHA ($driverOutput.schema-ceq'c1b-build-only-elevation-publication/v1' -and $driverOutput.operation-ceq'Drive' -and (Test-C1bHAEqual $driverOutput.result_pin $elevation.result_pin)) 'BuildOnly actual driver publication binding.'
    Assert-C1bHAElevationMarkers $Session $BuildOnly $result
    Assert-C1bHAKeys $result.wrapper_source_pin @('path','byte_length','sha256') 'UAC wrapper source pin';Assert-C1bHA ($result.wrapper_source_pin.path-ceq$elevation.wrapper_source_pin.path -and $result.wrapper_source_pin.sha256-ceq$elevation.wrapper_source_pin.sha256 -and $result.wrapper_source_pin.byte_length-eq$elevation.wrapper_source_pin.byte_length) 'UAC exact wrapper source binding.'
    $reservation=Read-C1bHAJson $Session (Get-C1bHAObservedPin $Session ([IO.Path]::Combine([IO.Path]::GetDirectoryName($BuildOnly.capture_pin.path),'reservation.json')));Assert-C1bHAKeys $reservation @('schema','started_at_utc','parent_pid','automatic_retry_count') 'launcher capture reservation';Assert-C1bHA ($reservation.schema-ceq'tl1-c1b-host-process-capture-reservation/v1' -and $reservation.parent_pid-eq$result.elevated_pid -and $reservation.automatic_retry_count-eq0) 'Launcher capture elevated parent PID mismatch.'
    Assert-C1bHAInt $reservation.parent_pid 1 2147483647 'Launcher reservation parent PID';Assert-C1bHAInt $reservation.automatic_retry_count 0 0 'Launcher reservation retry';Assert-C1bHA ($reservation.started_at_utc-ceq$capture.started_at_utc) 'Launcher reservation actual start timestamp mismatch.'
    foreach($mapping in @(@('launcher_capture_pin','capture_pin'),@('launcher_source_pin','launcher_source_pin'))){$left=$result[$mapping[0]];$right=$BuildOnly[$mapping[1]];Assert-C1bHAKeys $left @('path','byte_length','sha256') 'UAC raw pin';Assert-C1bHA ($left.path-ceq$right.path -and $left.sha256-ceq$right.sha256 -and $left.byte_length-eq$right.byte_length) 'UAC final source/capture raw binding.'}
    foreach($name in @('launcher_capture_pin','launcher_source_pin','wrapper_source_pin')){$null=Read-C1bHAFile $Session $result[$name]}
    Assert-C1bHA ($result.expected_launcher_sha256-ceq$BuildOnly.launcher_source_pin.sha256) 'UAC mandatory launcher SHA missing/mismatch.'
    $argv=@($result.argument_list);Assert-C1bHA ($argv.Count-eq5 -and @($argv|Where-Object{$_-isnot[string]}).Count-eq0 -and $argv[0]-ceq'-NoProfile' -and $argv[1]-ceq'-File' -and $argv[2]-ceq$BuildOnly.launcher_source_pin.path -and $argv[3]-ceq'-ExpectedLauncherSha256' -and $argv[4]-ceq$result.expected_launcher_sha256) 'UAC exact mandatory launcher argv missing or extra.'
    Assert-C1bHA ((Get-C1bHASha256 ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $argv -Compress -Depth 4))))-ceq$result.argument_list_sha256) 'UAC argv hash mismatch.'
    $launcher=Read-C1bHAJson $Session $BuildOnly.launcher_pin
    Assert-C1bHAKeys $launcher @('schema','started_at_utc','completed_at_utc','status','success_eligible_without_external_exit','external_exit_zero_required','failure_sidecar_absent_after_exit_required','pre_publication_pass_closure','final_status_authority','expected_commit_sha','bindings','runtime_pwsh','filesystem','verifier','helper','streams','outputs','cleanup','residual','failure_count','failure_reasons') 'launcher result'
    Assert-C1bHA ($launcher.schema-ceq'tablet-layout-c1b-real-build-smoke-launcher/v3' -and $launcher.status-ceq'candidate_pass_requires_external_exit' -and $launcher.expected_commit_sha-ceq$CandidateSha -and $launcher.final_status_authority-ceq'external_exit_zero_and_failure_sidecar_absent_after_process_exit') 'Launcher result status/binding.'
    Assert-C1bHABool $launcher.success_eligible_without_external_exit $false 'Launcher cannot self accept';foreach($key in @('external_exit_zero_required','failure_sidecar_absent_after_exit_required','pre_publication_pass_closure')){Assert-C1bHABool $launcher[$key] $true "launcher.$key"}
    Assert-C1bHAInt $launcher.failure_count 0 0 'launcher failures';Assert-C1bHA (@($launcher.failure_reasons).Count-eq0) 'Launcher failure reasons.'
    foreach($mapping in @(@('self','launcher_source_pin'),@('helper','helper_source_pin'),@('verifier','verifier_source_pin'),@('pwsh','runtime_pin'))){$bound=$launcher.bindings[$mapping[0]];$pin=$BuildOnly[$mapping[1]];Assert-C1bHA ($bound.path-ceq$pin.path -and $bound.actual_sha256-ceq('sha256:'+$pin.sha256) -and $bound.expected_sha256-ceq$bound.actual_sha256 -and $bound.byte_length-eq$pin.byte_length -and $bound.link_count-eq1) 'Launcher exact held source mismatch.'}
    foreach($key in @('start_attempt_count','start_count','release_after_job_assignment_count','helper_gate_signal_count')){Assert-C1bHAInt $launcher.helper[$key] 1 1 "helper.$key"};foreach($key in @('automatic_retry_count','exit_code','kill_attempt_count','job_termination_attempt_count','job_validation_active_process_count','job_cleanup_active_process_count')){Assert-C1bHAInt $launcher.helper[$key] 0 0 "helper.$key"};foreach($key in @('root_exit_confirmed','job_assignment_completed','job_active_processes_zero','helper_child_termination_validation_verified','helper_child_termination_cleanup_verified')){Assert-C1bHABool $launcher.helper[$key] $true "helper.$key"};Assert-C1bHABool $launcher.helper.timed_out $false 'helper timeout';Assert-C1bHA ($launcher.helper.termination-ceq'natural_root_exit') 'Helper natural exit required.'
    Assert-C1bHABool $launcher.streams.drain_completed $true 'Helper drains';foreach($name in @('stdout','stderr')){foreach($key in @('overflowed','forced_closed')){Assert-C1bHABool $launcher.streams[$name][$key] $false "helper.$name.$key"}};Assert-C1bHA ($launcher.streams.stderr.total_byte_length-eq0 -and $launcher.streams.stderr.captured_byte_length-eq0) 'Helper stderr not empty.'
    foreach($key in @('process_job_gate','fixed_file_guards','ancestor_directory_guards','sensitive_buffers')){Assert-C1bHA ($launcher.cleanup[$key]-ceq'completed') 'Launcher cleanup incomplete.'};Assert-C1bHAInt $launcher.cleanup.cleanup_failure_count 0 0 'Launcher cleanup failures';foreach($key in @('helper_root_process_alive','helper_job_active_processes_nonzero')){Assert-C1bHABool $launcher.residual[$key] $false "Launcher residual.$key"}
    foreach($mapping in @(@('summary','summary_pin'),@('log','log_pin'))){$output=$launcher.outputs[$mapping[0]];$pin=$BuildOnly[$mapping[1]];Assert-C1bHA ($output.path-ceq$pin.path -and $output.sha256-ceq('sha256:'+$pin.sha256) -and $output.byte_length-eq$pin.byte_length) 'Launcher raw output binding.';Assert-C1bHABool $output.preexisting $false 'Launcher output preexisting'}
    $summaryBytes=Read-C1bHAFile $Session $BuildOnly.summary_pin;$summary=Read-C1bHAJson $Session $BuildOnly.summary_pin
    Assert-C1bHA ($summary.repository_input_catalog_sha256-ceq$Authority.implementation_catalog_sha256) 'Summary/current A1 implementation catalog mismatch.'
    $expectedHelperOutput=[byte[]]::new($summaryBytes.Length+2);[Array]::Copy($summaryBytes,$expectedHelperOutput,$summaryBytes.Length);$expectedHelperOutput[$summaryBytes.Length]=13;$expectedHelperOutput[$summaryBytes.Length+1]=10
    Assert-C1bHA ($launcher.streams.stdout.total_byte_length-eq$expectedHelperOutput.Length -and $launcher.streams.stdout.captured_byte_length-eq$expectedHelperOutput.Length -and $launcher.streams.stdout.sha256-ceq('sha256:'+(Get-C1bHASha256 $expectedHelperOutput))) 'Helper stdout must equal exact summary plus CRLF.';[Array]::Clear($expectedHelperOutput,0,$expectedHelperOutput.Length)
    Initialize-C1bHASummaryVerifier $Session $BuildOnly.verifier_source_pin $SummaryVerifierContext
    $verification=& $script:C1bHAVerifierModule { param($Path,$Parent,$Sha,$HelperSha,$Start,$End) Assert-TL1C1bRealBuildSmokeSummaryFile -Path $Path -ExpectedParentDirectory $Parent -ExpectedCommitSha $Sha -ExpectedHelperSha256 $HelperSha -HelperProcessStartedNotBeforeUtc ([DateTimeOffset]::Parse($Start)) -HelperProcessExitedNotAfterUtc ([DateTimeOffset]::Parse($End)) -MaximumObserverTailSeconds 5 } $BuildOnly.summary_pin.path ([IO.Path]::GetDirectoryName($BuildOnly.summary_pin.path)) $CandidateSha $BuildOnly.helper_source_pin.sha256 $launcher.helper.process_started_not_before_utc $launcher.helper.process_exited_not_after_utc
    Assert-C1bHA ($verification.Sha256-ceq('sha256:'+$BuildOnly.summary_pin.sha256) -and $verification.ByteLength-eq$BuildOnly.summary_pin.byte_length) 'Independent raw summary verification mismatch.'
    $readback=Read-C1bHAJson $Session $BuildOnly.readback_report_pin
    Assert-C1bHAKeys $readback @('schema','observed_utc','completed_utc','candidate_sha','reader_process_id','reader_sha256','observed_outer_exit','acceptance_status','strict_pass_summary_independently_verified','readback_completed','primary_failure','cleanup_failure_count','cleanup_failures','inputs','observed_results','checks','limitations') 'A4 readback report'
    Assert-C1bHA ($readback.schema-ceq'c1b-build-only-independent-readback/v1' -and $readback.candidate_sha-ceq$CandidateSha -and $readback.acceptance_status-ceq'accepted_no_device' -and $readback.observed_outer_exit-eq0 -and $null-eq$readback.primary_failure) 'Independent A4 readback failed/unknown.'
    foreach($key in @('strict_pass_summary_independently_verified','readback_completed')){Assert-C1bHABool $readback[$key] $true "readback.$key"};Assert-C1bHAInt $readback.cleanup_failure_count 0 0 'Reader cleanup failures';Assert-C1bHA (@($readback.cleanup_failures).Count-eq0 -and @($readback.checks).Count-gt0) 'Reader checks/cleanup absent.';foreach($item in $readback.checks){Assert-C1bHA ($item.status-ceq'passed') 'A4 reader unknown/failed check blocks host acceptance.'}
    $requiredReaderChecks=@('reader.inputs','outer.capture_root_scopes','elevation.independent_driver_result','failure_sidecar.absent_after_exit','launcher.pass_closure','helper.summary_and_log_raw_bindings','repository.final_42_raw_inputs','summary.private_function_public_verification','namespace.residual_absence','reader.cleanup');Assert-C1bHA ($readback.cleanup_failures-is[array] -and $readback.checks-is[array] -and $readback.checks.Count-eq$requiredReaderChecks.Count) 'A4 exact reader checks/cleanup arrays required.';foreach($item in $readback.checks){Assert-C1bHAKeys $item @('id','status','detail') 'A4 reader check'};foreach($id in $requiredReaderChecks){Assert-C1bHA (@($readback.checks|Where-Object{$_.id-ceq$id -and $_.status-ceq'passed'}).Count-eq1) 'A4 required reader check missing/duplicate.'}
    Assert-C1bHAInt $readback.reader_process_id 1 2147483647 'A4 reader process PID';Assert-C1bHAInt $readback.observed_outer_exit 0 0 'A4 reader observed outer exit';Assert-C1bHA ($readback.reader_process_id-eq$Stages.Readback.inner.child_pid) 'A4 readback report PID differs from actual stage reader child.'
    $readerOutput=ConvertFrom-C1bHAStrictJson (ConvertFrom-C1bHABytes $Stages.Readback.stdout);Assert-C1bHAKeys $readerOutput @('report_path','report_sha256','acceptance_status','readback_completed') 'A4 actual stdout pointer';Assert-C1bHABool $readerOutput.readback_completed $true 'A4 actual pointer readback complete';Assert-C1bHA ($readerOutput.report_path-ceq$BuildOnly.readback_report_pin.path -and $readerOutput.report_sha256-ceq$BuildOnly.readback_report_pin.sha256 -and $readerOutput.acceptance_status-ceq'accepted_no_device') 'Reader actual stdout report pointer mismatch.'
    $readerSource=$Stages.Readback.observation.source_pins.stage_source;Assert-C1bHA ($readback.reader_sha256-ceq$readerSource.sha256) 'A4 report reader source hash mismatch.'
    return @{caller_exit=$capture.exit_code;reader_exit=$Stages.Readback.inner.exit_code}
}

function Assert-C1bHAArchive {
    param($Session,$ArchivePin,[string]$CandidateSha,[string]$EvidenceRoot,[string[]]$ExemptPaths)
    $required=@($Session.files.Values|ForEach-Object{$_.pin}|Where-Object{$ExemptPaths-cnotcontains$_.path});$archive=Read-C1bHAJson $Session $ArchivePin
    Assert-C1bHAKeys $archive @('schema','candidate_sha','status','source_mutation_count','cleanup_failure_count','members') 'raw archive';Assert-C1bHA ($archive.schema-ceq'c1b-host-raw-archive/v1' -and $archive.candidate_sha-ceq$CandidateSha -and $archive.status-ceq'sealed_raw_archive') 'Raw archive binding/status.';Assert-C1bHAInt $archive.source_mutation_count 0 0 'Archive source mutation';Assert-C1bHAInt $archive.cleanup_failure_count 0 0 'Archive cleanup failures';Assert-C1bHA ($archive.members-is[array]) 'Archive members must be array.'
    $sources=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);$copies=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($member in $archive.members){Assert-C1bHAKeys $member @('source_pin','copy_pin') 'raw archive member';$null=Read-C1bHAFile $Session $member.source_pin;$null=Read-C1bHAFile $Session $member.copy_pin;Assert-C1bHA ($sources.TryAdd($member.source_pin.path,$member.source_pin) -and $copies.Add($member.copy_pin.path)) 'Archive duplicate source/copy.';Assert-C1bHA (Test-C1bHAWithin $member.copy_pin.path $EvidenceRoot) 'Archive copy out of evidence root.';Assert-C1bHA ($member.source_pin.path-cne$member.copy_pin.path -and $member.source_pin.sha256-ceq$member.copy_pin.sha256 -and $member.source_pin.byte_length-eq$member.copy_pin.byte_length -and ($Session.files[$member.copy_pin.path].identity.Attributes-band1)-eq1) 'Archive copy bytes/read-only mismatch.'}
    foreach($pin in $required){Assert-C1bHA ($sources.ContainsKey($pin.path) -and $sources[$pin.path].sha256-ceq$pin.sha256 -and $sources[$pin.path].byte_length-eq$pin.byte_length) 'Raw archive does not cover consumed evidence.'}
}
function Assert-C1bHAArchiveExecution {
    param($Session,$Execution,$ArchivePin,[string]$CandidateSha)
    Assert-C1bHAKeys $Execution @('run_id','producer_source_pin','capture_pin','root_observation_pin') 'Raw archive execution';$null=Read-C1bHAFile $Session $Execution.producer_source_pin
    $capture=Assert-C1bHACapture $Session $Execution.capture_pin;$stdoutPin=@{path=[IO.Path]::Combine([IO.Path]::GetDirectoryName($Execution.capture_pin.path),'stdout.bin');byte_length=$capture.stdout.total_byte_length;sha256=$capture.stdout.sha256};$output=Read-C1bHAJson $Session $stdoutPin
    Assert-C1bHAKeys $output @('schema','candidate_sha','run_id','status','archive_pin','inputs_pin','producer_source_pin','producer_process_id') 'Raw archive actual stdout';Assert-C1bHA ($output.schema-ceq'c1b-host-raw-archive-write/v1' -and $output.candidate_sha-ceq$CandidateSha -and $output.run_id-ceq$Execution.run_id -and $output.status-ceq'sealed_raw_archive') 'Raw archive actual stdout binding/status.'
    Assert-C1bHA (Test-C1bHAEqual $output.archive_pin $ArchivePin) 'Raw archive actual manifest differs from caller map.';Assert-C1bHA (Test-C1bHAEqual $output.producer_source_pin $Execution.producer_source_pin) 'Raw archive actual producer source mismatch.'
    Assert-C1bHARoot $Session $Execution.root_observation_pin $Execution.capture_pin $capture $CandidateSha 'RawArchive' $Execution.run_id $output.producer_process_id
    $inputs=Read-C1bHAJson $Session $output.inputs_pin;Assert-C1bHAKeys $inputs @('schema','candidate_sha','run_id','evidence_root','archive_directory','trusted_source_roots','ha_module_pin','producer_source_pin','sources') 'Raw archive caller bindings'
    Assert-C1bHA ($inputs.schema-ceq'c1b-host-raw-archive-inputs/v1' -and $inputs.candidate_sha-ceq$CandidateSha -and $inputs.run_id-ceq$Execution.run_id -and $inputs.evidence_root-ceq$Session.roots[0] -and $ArchivePin.path-ceq[IO.Path]::Combine($inputs.archive_directory,'archive.json') -and (Test-C1bHAEqual $inputs.producer_source_pin $Execution.producer_source_pin)) 'Raw archive input/producer/path binding mismatch.'
    $null=Read-C1bHAFile $Session $inputs.ha_module_pin;$manifest=Read-C1bHAJson $Session $ArchivePin;Assert-C1bHA (($Session.files[$ArchivePin.path].identity.Attributes-band1)-eq1) 'Archive manifest must be read-only.'
    $reservationPin=Get-C1bHAObservedPin $Session ([IO.Path]::Combine($inputs.archive_directory,'reservation.json'));$reservation=Read-C1bHAJson $Session $reservationPin;Assert-C1bHAKeys $reservation @('schema','candidate_sha','run_id','inputs_pin','automatic_retry_count') 'Raw archive reservation';Assert-C1bHA ($reservation.schema-ceq'c1b-host-raw-archive-reservation/v1' -and $reservation.candidate_sha-ceq$CandidateSha -and $reservation.run_id-ceq$Execution.run_id -and (Test-C1bHAEqual $reservation.inputs_pin $output.inputs_pin)) 'Raw archive reservation binding mismatch.';Assert-C1bHAInt $reservation.automatic_retry_count 0 0 'Archive reservation retry';Assert-C1bHA (($Session.files[$reservationPin.path].identity.Attributes-band1)-eq1) 'Archive reservation must be read-only.'
    Assert-C1bHA ($inputs.sources-is[array] -and $manifest.members-is[array] -and $inputs.sources.Count-eq$manifest.members.Count) 'Raw archive reviewed source/member count.'
    for($i=0;$i-lt$inputs.sources.Count;$i++){$member=$manifest.members[$i];Assert-C1bHA (Test-C1bHAEqual $inputs.sources[$i] $member.source_pin) 'Raw archive source order differs from caller exact inventory.';Assert-C1bHA ($member.copy_pin.path-ceq[IO.Path]::Combine($inputs.archive_directory,'members',(('{0:D6}'-f($i+1))+'.bin'))) 'Raw archive exact copy path mismatch.'}
    $late=@($Execution.capture_pin.path,$Execution.root_observation_pin.path,$output.inputs_pin.path,[IO.Path]::Combine([IO.Path]::GetDirectoryName($Execution.capture_pin.path),'stdout.bin'),[IO.Path]::Combine([IO.Path]::GetDirectoryName($Execution.capture_pin.path),'stderr.bin'),[IO.Path]::Combine([IO.Path]::GetDirectoryName($Execution.capture_pin.path),'reservation.json'))
    return ,(@($late)+@($reservationPin.path))
}

function Assert-C1bHostAcceptanceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateSha,[Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][string]$InputMapPath,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$InputMapSha256,$SummaryVerifierContext)
    $ErrorActionPreference='Stop'
    $evidenceRoot=Get-C1bHAPath $EvidenceRoot;$inputPath=Get-C1bHAPath $InputMapPath;Assert-C1bHA (Test-C1bHAWithin $inputPath $evidenceRoot) 'InputMap out of evidence root.'
    $bootstrap=New-C1bHASession @($evidenceRoot);$session=$null;$contract=$null;$primary=$null
    try {
        $mapPin=Get-C1bHAObservedPin $bootstrap $inputPath;Assert-C1bHA ($mapPin.sha256-ceq$InputMapSha256) 'Caller-pinned InputMap SHA mismatch.';$map=Read-C1bHAJson $bootstrap $mapPin
        Assert-C1bHAKeys $map @('schema','candidate_sha','repo_root','trusted_source_roots','a1','source_review_pin','stage_runs','build_only','raw_archive_pin','raw_archive_execution') 'InputMap';Assert-C1bHA ($map.schema-ceq'c1b-host-acceptance-inputs/v1' -and $map.candidate_sha-ceq$CandidateSha) 'InputMap schema/candidate mismatch.'
        $repoRoot=Get-C1bHAPath $map.repo_root;Assert-C1bHA (@($map.trusted_source_roots|Where-Object{$_-isnot[string]}).Count-eq0) 'Trusted source root type.';$session=New-C1bHASession (@($evidenceRoot,$repoRoot)+@($map.trusted_source_roots));$null=Read-C1bHAFile $session $mapPin
        $authorityResult=Assert-C1bHAAuthority $session $map.a1 $CandidateSha $repoRoot;$authority=$authorityResult.authority
        Assert-C1bHA (@($map.stage_runs).Count-eq6) 'All six actual host stages required.';$stages=@{}
        foreach($stage in $map.stage_runs){Assert-C1bHA (@('FullCheck','PrepareSources','Pair','R14','Preflight','Readback')-ccontains$stage.phase -and -not$stages.ContainsKey($stage.phase)) 'Stage phase duplicate/unknown.';$stages[$stage.phase]=Assert-C1bHAStage $session $stage $CandidateSha $repoRoot}
        $review=Assert-C1bHAReviewedSources $session $map.source_review_pin $CandidateSha $stages $map.build_only $map
        $null=Assert-C1bHAStageSemantics $session $stages $CandidateSha $map.build_only $authority
        $build=Assert-C1bHABuildOnly $session $map.build_only $stages $CandidateSha $authority $SummaryVerifierContext
        # Review source pin scope is consumed independently and each source remains held through archive verification.
        $late=Assert-C1bHAArchiveExecution $session $map.raw_archive_execution $map.raw_archive_pin $CandidateSha
        $exempt=@($mapPin.path,$map.source_review_pin.path,$map.raw_archive_pin.path)+$late
        Assert-C1bHAArchive $session $map.raw_archive_pin $CandidateSha $evidenceRoot $exempt
        $pins=@($session.files.Values|ForEach-Object{$_.pin}|Sort-Object path)
        $contract=[ordered]@{schema='c1b-host-device-entry-acceptance/v1';candidate_sha=$CandidateSha;status='host_accepted_no_device';created_at_utc=[DateTimeOffset]::UtcNow.ToString('o');observed_buildonly_caller_exit=$build.caller_exit;observed_buildonly_reader_exit=$build.reader_exit;real_adb_call_count=0;device_stage_started=$false;device_evidence_verified=$false;unresolved_findings=@();cleanup_failure_count=0;authority=$authority;evidence_map_pin=$mapPin;source_review_pin=$map.source_review_pin;verified_evidence_pins=$pins}
    }catch{$primary=$_}
    $cleanup=[Collections.Generic.List[Exception]]::new();if($null-ne$session){try{Close-C1bHASession $session}catch{$cleanup.Add($_.Exception)}};try{Close-C1bHASession $bootstrap}catch{$cleanup.Add($_.Exception)}
    if($null-ne$primary){if($cleanup.Count){throw [AggregateException]::new('Host acceptance evidence and cleanup failed.',[Exception[]](@($primary.Exception)+$cleanup.ToArray()))};throw $primary};if($cleanup.Count){throw [AggregateException]::new('Host acceptance cleanup failed.',$cleanup.ToArray())}
    return $contract
}

function Assert-C1bHostAcceptanceContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateSha,[Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][string]$ContractPath,[Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ContractSha256,$SummaryVerifierContext)
    $ErrorActionPreference='Stop'
    $root=Get-C1bHAPath $EvidenceRoot;$path=Get-C1bHAPath $ContractPath;Assert-C1bHA (Test-C1bHAWithin $path $root) 'Contract out of evidence root.';$session=New-C1bHASession @($root)
    try {
        $pin=Get-C1bHAObservedPin $session $path;Assert-C1bHA ($pin.sha256-ceq$ContractSha256) 'Contract SHA mismatch.';$contract=Read-C1bHAJson $session $pin
        Assert-C1bHAKeys $contract @('schema','candidate_sha','status','created_at_utc','observed_buildonly_caller_exit','observed_buildonly_reader_exit','real_adb_call_count','device_stage_started','device_evidence_verified','unresolved_findings','cleanup_failure_count','authority','evidence_map_pin','source_review_pin','verified_evidence_pins') 'host acceptance contract'
        Assert-C1bHA ($contract.schema-ceq'c1b-host-device-entry-acceptance/v1' -and $contract.candidate_sha-ceq$CandidateSha -and $contract.status-ceq'host_accepted_no_device') 'Contract schema/status/candidate.'
        $verified=Assert-C1bHostAcceptanceEvidence -CandidateSha $CandidateSha -EvidenceRoot $root -InputMapPath $contract.evidence_map_pin.path -InputMapSha256 $contract.evidence_map_pin.sha256 -SummaryVerifierContext $SummaryVerifierContext
        foreach($key in @('observed_buildonly_caller_exit','observed_buildonly_reader_exit','real_adb_call_count','cleanup_failure_count')){Assert-C1bHAInt $contract[$key] 0 0 "contract.$key"};foreach($key in @('device_stage_started','device_evidence_verified')){Assert-C1bHABool $contract[$key] $false "contract.$key"};Assert-C1bHA (@($contract.unresolved_findings).Count-eq0) 'Contract unresolved findings.'
        foreach($key in @('authority','evidence_map_pin','source_review_pin','verified_evidence_pins')){Assert-C1bHA (Test-C1bHAEqual $contract[$key] $verified[$key]) "Contract $key differs from independently consumed evidence."}
        return $contract
    }finally{Close-C1bHASession $session}
}
