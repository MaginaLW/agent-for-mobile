#Requires -Version 7.6
# Maintenance template: root must pin this script's raw SHA256 and freeze it before invocation.
# Run only after this exact candidate full gate, exact host/preflight, and BuildOnly pass.
# This observes one reviewed UAC wrapper; it never retries, kills, or reads runner receipts.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedBindingSha256)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$repo='__REPO_ROOT__'
$commit='__CANDIDATE_SHA__'
$pwsh='__PWSH_PATH__'
$runtimeHash='362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
$wrapper='__ENTRY_ROOT__\invoke-next-device-once-r1.ps1'
$wrapperHash='__SOURCE_INVOKE_NEXT_DEVICE_ONCE_R1_HASH__'
$strictPath=Join-Path $repo 'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1'
$strictHash='__STRICT_VERIFIER_HASH__'
$receiptRoot=Join-Path $repo '.checks\c1b-device-once\__CANDIDATE_SHORT__\r1'
$bindingPath=Join-Path $receiptRoot 'binding.json'
$observationPath=Join-Path $receiptRoot 'external-process-observation.json'
$heldFiles=[Collections.Generic.List[object]]::new()
$heldDirectories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$errors=[Collections.Generic.List[string]]::new()
$outer=$null;$parentHandle=[IntPtr]::Zero;$childHandle=[IntPtr]::Zero;$observationFile=$null
$childIdentified=$false;$parentIdentity=$null;$childIdentity=$null;$nativeOuterExit=$null
$record=[ordered]@{
    schema='c1b-device-external-process-observation/v1';expected_commit_sha=$commit
    wrapper_sha256=$wrapperHash;runtime_sha256=$runtimeHash;expected_binding_sha256=$ExpectedBindingSha256;binding_sha256=$null
    file_identity_library_sha256=$strictHash
    wrapper_launch_call_count=0;wrapper_started=$false;automatic_wrapper_retry_count=0
    wrapper_pid=$null;wrapper_creation_utc=$null;wrapper_creation_filetime=$null;wrapper_image_path=$null
    runner_pid=$null;runner_creation_utc=$null;runner_creation_filetime=$null;runner_image_path=$null
    runner_cim_parent_pid=$null;runner_cim_creation_utc=$null;runner_creation_delta_ticks=$null
    observed_wrapper_exit=$null;observed_runner_exit=$null;native_wrapper_exit=$null
    observation_started_utc=[DateTimeOffset]::UtcNow.ToString('O');launch_requested_utc=$null;completed_utc=$null
    observation_status='incomplete';errors=@()
    identity_basis='Live held wrapper; unique direct CIM pwsh child; native image and creation time; held native child handle through exit.'
    admin_command_line_observed=$false
    runner_argv_basis='Pinned reviewed wrapper has one fixed runner Process.Start and fixed ArgumentList; child argv is not directly observed.'
    missing_identity_or_exit_must_not_be_filled_from_receipts=$true
    runner_receipts_read=0;device_commands_issued_by_observer=0;processes_killed=0
    scope='Process identity and actual exit observation only; root separately verifies binding, host gates, and terminal runner evidence.'
}
function Assert-OrdinaryPath([string]$Path,[bool]$Directory=$false){
    $full=[IO.Path]::GetFullPath($Path)
    $item=Get-Item -LiteralPath $full -Force
    if($item -isnot [IO.FileInfo] -and $item -isnot [IO.DirectoryInfo]){throw 'Expected a .NET filesystem object.'}
    if(($item -is [IO.DirectoryInfo])-ne$Directory){throw 'Unexpected file/directory kind.'}
    while($null-ne$item){
        if($item.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Reparse path is not allowed.'}
        $next=if($item -is [IO.DirectoryInfo]){$item.Parent}else{$item.Directory}
        $item=$next
    }
    return $full
}
function ConvertTo-C1bObserverWindowsArgument([string]$Value){
    if($null-eq$Value-or$Value.Contains([char]0)){throw 'Invalid Windows argument.'}
    if($Value.Length-gt0-and$Value-cnotmatch'[\s"]'){return $Value}
    $b=[Text.StringBuilder]::new();[void]$b.Append('"');$slashes=0
    foreach($ch in $Value.ToCharArray()){
        if($ch-eq[char]92){$slashes++;continue}
        if($ch-eq[char]34){[void]$b.Append(([string][char]92)*($slashes*2+1)).Append($ch)}
        else{[void]$b.Append(([string][char]92)*$slashes).Append($ch)}
        $slashes=0
    }
    [void]$b.Append(([string][char]92)*($slashes*2)).Append('"');return $b.ToString()
}
function Hold-File([string]$Path,[long]$ExpectedLength=0,[string]$ExpectedHash='', [bool]$RequireReadOnly=$false){
    $full=Assert-OrdinaryPath $Path
    foreach($dir in (Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain ([IO.Path]::GetDirectoryName($full)))){
        if($heldDirectories.ContainsKey($dir)){continue}
        $handle=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete($dir)
        $directory=[pscustomobject]@{Path=$dir;Handle=$handle;Identity=$null}
        $heldDirectories.Add($dir,$directory)
        $directory.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($handle)
        Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity $directory.Identity
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $handle $dir
    }
    $handle=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete($full)
    $binding=[pscustomobject]@{Path=$full;Handle=$handle;Stream=$null;Identity=$null;Length=0L;Hash=$null;RequireReadOnly=$RequireReadOnly}
    $heldFiles.Add($binding)
    $stream=[IO.FileStream]::new($handle,[IO.FileAccess]::Read);$binding.Stream=$stream;$binding.Length=$stream.Length
    if($stream.Length-le0-or($ExpectedLength-gt0-and$stream.Length-ne$ExpectedLength)){throw 'Held file length differs.'}
    $binding.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($handle)
    Assert-TL1C1bRealBuildSmokeHeldFileIdentity $binding.Identity $binding.Length
    Assert-TL1C1bRealBuildSmokeHandleFinalPath $handle $full
    if($RequireReadOnly-and-not($binding.Identity.FileAttributes-band[uint32][IO.FileAttributes]::ReadOnly)){throw 'Root binding must already be read-only.'}
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    $binding.Hash=$hash
    if($ExpectedHash-and$hash-cne$ExpectedHash){throw 'Held file raw SHA256 differs from reviewed expected value.'}
    Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $full $binding.Identity $binding.Length
    return $hash
}
function Recheck-FileGuards{
    foreach($binding in $heldFiles){
        $now=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($binding.Handle)
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity $now $binding.Length
        if($now.StableId-cne$binding.Identity.StableId-or$now.LastWriteTimeUtcFileTime-ne$binding.Identity.LastWriteTimeUtcFileTime){throw 'Held source identity changed.'}
        if($binding.RequireReadOnly-and-not($now.FileAttributes-band[uint32][IO.FileAttributes]::ReadOnly)){throw 'Root binding lost read-only state.'}
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $binding.Handle $binding.Path
        Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $binding.Path $now $binding.Length
        $binding.Stream.Position=0
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($binding.Stream)).ToLowerInvariant()-cne$binding.Hash){throw 'Held source raw hash changed.'}
    }
    foreach($directory in $heldDirectories.Values){Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld $directory}
}
try{
    if($PSVersionTable.PSVersion.ToString()-cne'7.6.5'-or[Environment]::ProcessPath-cne$pwsh){throw 'Pinned PowerShell 7.6.5 required.'}
    # Load only the existing verifier's definitions from these exact checked in-memory bytes.
    # No verifier entry function, stage, runner, Git, ADB, or build is invoked here.
    $bootstrap=[IO.File]::Open($strictPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($bootstrap.Length-ne'__STRICT_VERIFIER_LENGTH__'){throw 'Native file-identity library length differs.'}
        $libraryBytes=[byte[]]::new([int]$bootstrap.Length);$bootstrap.ReadExactly($libraryBytes)
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($libraryBytes)).ToLowerInvariant()-cne$strictHash){throw 'Native file-identity library raw SHA256 differs.'}
        . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($libraryBytes)))
    }finally{$bootstrap.Dispose()}
    [void](Hold-File $pwsh 301368 $runtimeHash)
    [void](Hold-File $wrapper '__SOURCE_INVOKE_NEXT_DEVICE_ONCE_R1_LENGTH__' $wrapperHash)
    [void](Assert-OrdinaryPath $receiptRoot $true)
    $record.binding_sha256=Hold-File $bindingPath 0 $ExpectedBindingSha256 $true
    foreach($name in @('reservation.json','exit.json','runner.stdout.bin','runner.stderr.bin')){
        if(Test-Path -LiteralPath (Join-Path $receiptRoot $name)){throw 'This r1 attempt already has a runner artifact; launch refused.'}
    }
    # CreateNew before UAC also prevents this observer from launching twice into r1.
    # Interruption may leave an empty/incomplete file; that is evidence of an incomplete observation, never permission to retry.
    $observationFile=[IO.File]::Open($observationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class C1bExternalProcessObserverV1 {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint GetProcessId(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool QueryFullProcessImageName(IntPtr handle, uint flags, StringBuilder image, ref uint size);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetProcessTimes(IntPtr handle, out long creation, out long exit, out long kernel, out long user);
}
'@
    function Native-Error([string]$Operation){return "$Operation failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)"}
    function Open-ObservedProcess([int]$ProcessId){
        $handle=[C1bExternalProcessObserverV1]::OpenProcess(0x101000,$false,$ProcessId)
        if($handle-eq[IntPtr]::Zero){throw (Native-Error 'OpenProcess QUERY_LIMITED_INFORMATION|SYNCHRONIZE')}
        return $handle
    }
    function Read-ProcessIdentity([IntPtr]$Handle){
        $identityPid=[C1bExternalProcessObserverV1]::GetProcessId($Handle)
        if($identityPid-eq0){throw (Native-Error 'GetProcessId')}
        $image=[Text.StringBuilder]::new(32768);$size=[uint32]32768
        if(-not[C1bExternalProcessObserverV1]::QueryFullProcessImageName($Handle,0,$image,[ref]$size)){throw (Native-Error 'QueryFullProcessImageName')}
        $created=0L;$ended=0L;$kernel=0L;$userTime=0L
        if(-not[C1bExternalProcessObserverV1]::GetProcessTimes($Handle,[ref]$created,[ref]$ended,[ref]$kernel,[ref]$userTime)){throw (Native-Error 'GetProcessTimes')}
        if(-not[StringComparer]::OrdinalIgnoreCase.Equals($image.ToString(),$pwsh)){throw 'Native process image differs from pinned PowerShell.'}
        if($created-le0){throw 'Process creation time is absent.'}
        return [pscustomobject]@{ProcessId=$identityPid;Image=$image.ToString();Created=$created;CreatedUtc=[DateTime]::FromFileTimeUtc($created)}
    }
    function Wait-State([IntPtr]$Handle,[uint32]$Milliseconds=0){
        $state=[C1bExternalProcessObserverV1]::WaitForSingleObject($Handle,$Milliseconds)
        if($state-notin @([uint32]0,[uint32]258)){throw (Native-Error 'WaitForSingleObject')}
        return $state
    }
    function Read-EndedProcessExit([IntPtr]$Handle){
        if((Wait-State $Handle)-ne0){throw 'Exit requested before actual process termination.'}
        $code=[uint32]0
        if(-not[C1bExternalProcessObserverV1]::GetExitCodeProcess($Handle,[ref]$code)){throw (Native-Error 'GetExitCodeProcess')}
        return [long]$code
    }
    $launchRequested=[DateTime]::UtcNow;$record.launch_requested_utc=$launchRequested.ToString('O')
    Recheck-FileGuards
    $record.wrapper_launch_call_count=1
    # This is the only launch statement. The reviewed wrapper has no space in its pinned path.
    $outer=Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',(ConvertTo-C1bObserverWindowsArgument $wrapper)) -WorkingDirectory $repo -Verb RunAs -WindowStyle Hidden -PassThru
    if($null-eq$outer){throw 'UAC launch returned no actual wrapper process.'}
    $record.wrapper_started=$true;$record.wrapper_pid=$outer.Id
    $parentHandle=Open-ObservedProcess $outer.Id
    $parentIdentity=Read-ProcessIdentity $parentHandle
    if($parentIdentity.ProcessId-ne$outer.Id){throw 'Native wrapper PID differs from the actual UAC process object.'}
    if($parentIdentity.CreatedUtc-lt$launchRequested-or$parentIdentity.CreatedUtc-gt[DateTime]::UtcNow){throw 'Wrapper creation time is outside this launch.'}
    $record.wrapper_creation_utc=$parentIdentity.CreatedUtc.ToString('O');$record.wrapper_creation_filetime=$parentIdentity.Created
    $record.wrapper_image_path=$parentIdentity.Image
    $discovery=[Diagnostics.Stopwatch]::StartNew()
    while($true){
        if((Wait-State $parentHandle)-ne258){throw 'Wrapper ended before an independent runner identity was captured.'}
        if($discovery.Elapsed.TotalSeconds-ge30){throw 'Runner discovery exceeded 30 seconds; no relaunch is allowed.'}
        $children=@(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$($outer.Id) AND Name='pwsh.exe'" -OperationTimeoutSec 2)
        if($children.Count-gt1){throw 'Multiple direct PowerShell children make runner identity ambiguous.'}
        if($children.Count-eq0){Start-Sleep -Milliseconds 200;continue}
        if((Wait-State $parentHandle)-ne258){throw 'Wrapper ended during runner discovery.'}
        $candidate=$children[0]
        if([int]$candidate.ParentProcessId-ne$outer.Id-or[string]$candidate.Name-cne'pwsh.exe'-or$null-eq$candidate.CreationDate){throw 'CIM child identity is incomplete.'}
        $childHandle=Open-ObservedProcess ([int]$candidate.ProcessId)
        $childIdentity=Read-ProcessIdentity $childHandle
        if($childIdentity.ProcessId-ne[uint32]$candidate.ProcessId){throw 'Native child PID differs from the CIM candidate.'}
        $cimCreated=([DateTime]$candidate.CreationDate).ToUniversalTime()
        $creationDelta=[Math]::Abs($childIdentity.CreatedUtc.Ticks-$cimCreated.Ticks)
        if($creationDelta-gt10){throw 'CIM/native child creation times differ; possible PID reuse.'}
        if($childIdentity.Created-lt$parentIdentity.Created-or$childIdentity.CreatedUtc-gt[DateTime]::UtcNow){throw 'Child creation is outside the wrapper lifetime.'}
        $recheck=@(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$($outer.Id) AND Name='pwsh.exe'" -OperationTimeoutSec 2)
        if($recheck.Count-ne1-or[uint32]$recheck[0].ProcessId-ne$childIdentity.ProcessId-or
           [int]$recheck[0].ParentProcessId-ne$outer.Id-or$null-eq$recheck[0].CreationDate-or
           ([DateTime]$recheck[0].CreationDate).ToUniversalTime().Ticks-ne$cimCreated.Ticks){
            throw 'Live wrapper direct-child association changed during native identity binding.'
        }
        if((Wait-State $parentHandle)-ne258){throw 'Wrapper ended before child identity binding completed.'}
        $record.runner_pid=[int]$candidate.ProcessId;$record.runner_cim_parent_pid=[int]$candidate.ParentProcessId
        $record.runner_creation_utc=$childIdentity.CreatedUtc.ToString('O');$record.runner_creation_filetime=$childIdentity.Created
        $record.runner_cim_creation_utc=$cimCreated.ToString('O');$record.runner_creation_delta_ticks=$creationDelta
        $record.runner_image_path=$childIdentity.Image;$childIdentified=$true
        break
    }
}catch{$errors.Add($_.Exception.Message)}
finally{
    # Even an observation error never kills or restarts the already launched wrapper.
    if($childIdentified){
        try{
            while((Wait-State $childHandle 250)-eq258){}
            $record.observed_runner_exit=Read-EndedProcessExit $childHandle
            # The same native handle was retained continuously from identity binding through this wait/exit read.
            # Do not require image-name queries to remain available after process termination.
        }catch{$errors.Add($_.Exception.Message)}
    }
    if($null-ne$outer){
        try{
            while(-not$outer.WaitForExit(250)){}
            $record.observed_wrapper_exit=$outer.ExitCode
        }catch{$errors.Add($_.Exception.Message)}
        if($parentHandle-ne[IntPtr]::Zero){
            try{
                while((Wait-State $parentHandle 250)-eq258){}
                $nativeOuterExit=Read-EndedProcessExit $parentHandle;$record.native_wrapper_exit=$nativeOuterExit
                if($null-ne$record.observed_wrapper_exit-and$record.observed_wrapper_exit-ne$nativeOuterExit){throw 'Actual wrapper object/native exit codes differ.'}
            }catch{$errors.Add($_.Exception.Message)}
        }
    }
    foreach($handle in @($childHandle,$parentHandle)){
        if($handle-ne[IntPtr]::Zero-and-not[C1bExternalProcessObserverV1]::CloseHandle($handle)){$errors.Add('Native process handle close failed.')}
    }
    if($null-ne$outer){try{$outer.Dispose()}catch{$errors.Add($_.Exception.Message)}}
    if($heldFiles.Count-eq3){try{Recheck-FileGuards}catch{$errors.Add($_.Exception.Message)}}
    foreach($binding in $heldFiles){try{if($null-ne$binding.Stream){$binding.Stream.Dispose()}else{$binding.Handle.Dispose()}}catch{$errors.Add($_.Exception.Message)}}
}
if($record.wrapper_started-and$childIdentified-and$null-ne$record.observed_runner_exit-and$null-ne$record.observed_wrapper_exit-and$errors.Count-eq0){
    $record.observation_status='observed'
}else{$record.observation_status='incomplete'}
$record.errors=$errors.ToArray();$record.completed_utc=[DateTimeOffset]::UtcNow.ToString('O')
try{
    if($null-eq$observationFile){[Console]::Error.WriteLine(($record|ConvertTo-Json -Depth 6 -Compress));exit 1}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 6 -Compress))
    $observationFile.Write($bytes);$observationFile.Flush($true)
    [IO.File]::SetAttributes($observationPath,([IO.File]::GetAttributes($observationPath)-bor[IO.FileAttributes]::ReadOnly))
    $observationFile.Dispose();$observationFile=$null
}finally{
    if($null-ne$observationFile){$observationFile.Dispose()}
    foreach($directory in $heldDirectories.Values){$directory.Handle.Dispose()}
}
$record|ConvertTo-Json -Depth 6 -Compress
if($record.observation_status-cne'observed'){exit 1};exit 0
