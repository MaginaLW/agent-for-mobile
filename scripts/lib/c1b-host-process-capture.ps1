#Requires -Version 7.5
# Pure host transport only. The caller owns runtime/source pins, UAC and authorization.
# Dot-sourcing never starts a process. Invocation reserves fresh evidence and starts at most once.
# Raw bounded draining follows c1b-candidate-source/launcher-template.ps1; a suspended
# Windows start and restricted inherited handle list close the pre-Job execution race.
if ($null -eq ('TL1C1bHostCapture.NativeV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace TL1C1bHostCapture {
public sealed class StreamResultV1 {
    public byte[] CapturedBytes = Array.Empty<byte>();
    public long ObservedByteLength;
    public string ObservedSha256;
    public string FullSha256;
    public string CapturedSha256;
    public bool Eof;
    public bool Aborted;
    public bool Overflowed;
    public string Error;
    public long? FirstByteObservedElapsedMilliseconds;
    public long? EofObservedElapsedMilliseconds;
}
public sealed class ResultV1 {
    public int StartAttemptCount;
    public int StartCount;
    public int? ProcessId;
    public int? ExitCode;
    public bool RootExitConfirmed;
    public bool NaturalExit;
    public bool TimedOut;
    public bool DrainTimedOut;
    public bool TerminationRequested;
    public bool JobAssignedBeforeResume;
    public uint? CleanupActiveProcessCount;
    public bool HandlesClosed;
    public bool DrainsCompleted;
    public bool Passed;
    public long ElapsedMilliseconds;
    public StreamResultV1 Stdout = new StreamResultV1();
    public StreamResultV1 Stderr = new StreamResultV1();
    public readonly List<string> Errors = new List<string>();
    public readonly List<string> CleanupErrors = new List<string>();
}
public static class NativeV1 {
    [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {
        public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
        public int Size; public string Reserved; public string Desktop; public string Title;
        public uint X,Y,XSize,YSize,XCountChars,YCountChars,FillAttribute,Flags;
        public ushort ShowWindow,Reserved2Size; public IntPtr Reserved2,Stdin,Stdout,Stderr;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupInfoEx {
        public StartupInfo Startup; public IntPtr Attributes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInformation {
        public IntPtr Process,Thread; public uint ProcessId,ThreadId;
    }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
        public long PerProcessTime,PerJobTime; public uint Flags;
        public UIntPtr MinWorkingSet,MaxWorkingSet; public uint ActiveProcessLimit;
        public UIntPtr Affinity; public uint PriorityClass,SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOperations,WriteOperations,OtherOperations,ReadBytes,WriteBytes,OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit {
        public BasicLimit Basic; public IoCounters Io;
        public UIntPtr ProcessMemoryLimit,JobMemoryLimit,PeakProcessMemory,PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct Accounting {
        public long UserTime,KernelTime,PeriodUserTime,PeriodKernelTime;
        public uint PageFaultCount,TotalProcesses,ActiveProcesses,TerminatedProcesses;
    }
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CreatePipe(out SafeFileHandle read,out SafeFileHandle write,ref SecurityAttributes attributes,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(SafeFileHandle handle,uint mask,uint flags);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool PeekNamedPipe(SafeFileHandle handle,IntPtr buffer,uint size,IntPtr read,out uint available,IntPtr left);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadFile(SafeFileHandle handle,byte[] buffer,uint count,out uint read,IntPtr overlapped);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern SafeFileHandle CreateJobObjectW(IntPtr attributes,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job,int kind,ref ExtendedLimit information,uint size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool QueryInformationJobObject(SafeFileHandle job,int kind,out Accounting information,uint size,out uint returned);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job,IntPtr process);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateJobObject(SafeFileHandle job,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,uint flags,ref IntPtr size);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr size,IntPtr previous,IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)] static extern bool CreateProcessW(string application,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInformation information);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr handle);

    static Exception NativeError(string phase) { return new Win32Exception(Marshal.GetLastWin32Error(),phase); }
    static string Bounded(Exception error) {
        string text = error.GetType().Name + ": " + error.Message;
        return text.Length <= 1024 ? text : text.Substring(0,1024);
    }
    static string Digest(byte[] bytes) { return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(); }
    static uint Active(SafeFileHandle job) {
        Accounting info; uint returned;
        if(!QueryInformationJobObject(job,1,out info,(uint)Marshal.SizeOf<Accounting>(),out returned)) throw NativeError("job_query");
        return info.ActiveProcesses;
    }
    static bool Exited(IntPtr process) {
        uint wait=WaitForSingleObject(process,0);
        if(wait==0) return true;
        if(wait==258) return false;
        throw NativeError("process_wait");
    }
    static string Quote(string value) {
        if(value==null || value.IndexOf('\0')>=0) throw new ArgumentException("Invalid argument");
        StringBuilder text=new StringBuilder("\""); int slashes=0;
        foreach(char c in value) {
            if(c=='\\') { slashes++; continue; }
            if(c=='\"') { text.Append('\\',slashes*2+1).Append(c); slashes=0; continue; }
            text.Append('\\',slashes).Append(c); slashes=0;
        }
        return text.Append('\\',slashes*2).Append('"').ToString();
    }
    static StreamResultV1 Drain(SafeFileHandle input,int cap,CancellationToken cancellation,Stopwatch watch) {
        StreamResultV1 result=new StreamResultV1(); byte[] buffer=new byte[65536];
        using(IncrementalHash hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
        using(MemoryStream captured=new MemoryStream(Math.Min(cap,65536))) {
            try {
                while(true) {
                    if(cancellation.IsCancellationRequested) { result.Aborted=true; break; }
                    uint available;
                    if(!PeekNamedPipe(input,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)) {
                        int error=Marshal.GetLastWin32Error();
                        // ERROR_BROKEN_PIPE is the Windows anonymous-pipe EOF terminal.
                        if(error==109) { result.Eof=true; break; }
                        throw new Win32Exception(error,"pipe_peek");
                    }
                    if(available==0) { Thread.Sleep(10); continue; }
                    uint read;
                    if(!ReadFile(input,buffer,Math.Min(available,(uint)buffer.Length),out read,IntPtr.Zero)) {
                        int error=Marshal.GetLastWin32Error();
                        if(error==109) { result.Eof=true; break; }
                        throw new Win32Exception(error,"pipe_read");
                    }
                    if(read==0) { result.Eof=true; break; }
                    if(result.ObservedByteLength==0) result.FirstByteObservedElapsedMilliseconds=watch.ElapsedMilliseconds;
                    result.ObservedByteLength=checked(result.ObservedByteLength+read);
                    hash.AppendData(buffer,0,(int)read);
                    int keep=Math.Min(cap-(int)captured.Length,(int)read);
                    if(keep>0) captured.Write(buffer,0,keep);
                    result.Overflowed=result.ObservedByteLength>cap;
                    Array.Clear(buffer,0,(int)read);
                }
            } catch(Exception error) { result.Error=Bounded(error); }
            finally {
                if(result.Eof) result.EofObservedElapsedMilliseconds=watch.ElapsedMilliseconds;
                result.CapturedBytes=captured.ToArray();
                result.ObservedSha256=Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                result.FullSha256=result.Eof && result.Error==null ? result.ObservedSha256 : null;
                result.CapturedSha256=Digest(result.CapturedBytes);
                Array.Clear(buffer,0,buffer.Length);
            }
        }
        return result;
    }
    static bool Done(Task<StreamResultV1> stdout,Task<StreamResultV1> stderr) {
        return stdout!=null && stderr!=null && stdout.IsCompleted && stderr.IsCompleted;
    }
    static void Close(ref SafeFileHandle handle,ResultV1 result) {
        if(handle==null) return;
        try { handle.Dispose(); } catch(Exception error) { result.CleanupErrors.Add(Bounded(error)); }
        handle=null;
    }
    public static ResultV1 Run(string executable,string[] arguments,string directory,int cap,int deadlineMs,int drainMs,int cleanupMs,string environmentBlock,bool useEnvironmentBlock) {
        if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows Job Object required");
        ResultV1 result=new ResultV1(); Stopwatch watch=Stopwatch.StartNew();
        SafeFileHandle job=null,outRead=null,outWrite=null,errRead=null,errWrite=null,inRead=null,inWrite=null;
        IntPtr attributes=IntPtr.Zero,handles=IntPtr.Zero,environment=IntPtr.Zero; bool attributesInitialized=false;
        ProcessInformation process=new ProcessInformation(); bool created=false,assigned=false;
        Task<StreamResultV1> stdout=null,stderr=null;
        CancellationTokenSource cancellation=new CancellationTokenSource();
        try {
            SecurityAttributes security=new SecurityAttributes { Length=Marshal.SizeOf<SecurityAttributes>(),Inherit=true };
            if(!CreatePipe(out outRead,out outWrite,ref security,0) ||
               !CreatePipe(out errRead,out errWrite,ref security,0) ||
               !CreatePipe(out inRead,out inWrite,ref security,0)) throw NativeError("pipe_create");
            if(!SetHandleInformation(outRead,1,0) || !SetHandleInformation(errRead,1,0) || !SetHandleInformation(inWrite,1,0)) throw NativeError("pipe_noninherit");
            // No interactive input. Closing the parent writer makes child stdin EOF.
            inWrite.Dispose(); inWrite=null;
            job=CreateJobObjectW(IntPtr.Zero,null);
            if(job.IsInvalid) throw NativeError("job_create");
            ExtendedLimit limit=new ExtendedLimit(); limit.Basic.Flags=0x2000;
            if(!SetInformationJobObject(job,9,ref limit,(uint)Marshal.SizeOf<ExtendedLimit>())) throw NativeError("job_limits");
            IntPtr size=IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref size);
            if(size==IntPtr.Zero) throw NativeError("attribute_size");
            attributes=Marshal.AllocHGlobal(size);
            if(!InitializeProcThreadAttributeList(attributes,1,0,ref size)) throw NativeError("attribute_init");
            attributesInitialized=true; handles=Marshal.AllocHGlobal(IntPtr.Size*3);
            Marshal.WriteIntPtr(handles,0,inRead.DangerousGetHandle());
            Marshal.WriteIntPtr(handles,IntPtr.Size,outWrite.DangerousGetHandle());
            Marshal.WriteIntPtr(handles,IntPtr.Size*2,errWrite.DangerousGetHandle());
            if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero)) throw NativeError("handle_list");
            StartupInfoEx startup=new StartupInfoEx(); startup.Startup.Size=Marshal.SizeOf<StartupInfoEx>();
            startup.Startup.Flags=0x100; startup.Startup.Stdin=inRead.DangerousGetHandle();
            startup.Startup.Stdout=outWrite.DangerousGetHandle(); startup.Startup.Stderr=errWrite.DangerousGetHandle(); startup.Attributes=attributes;
            StringBuilder command=new StringBuilder(Quote(executable));
            foreach(string argument in arguments) command.Append(' ').Append(Quote(argument));
            if(useEnvironmentBlock) environment=Marshal.StringToHGlobalUni(environmentBlock);
            result.StartAttemptCount=1;
            if(!CreateProcessW(executable,command,IntPtr.Zero,IntPtr.Zero,true,0x08080004u|(useEnvironmentBlock ? 0x400u : 0u),environment,directory,ref startup,out process)) throw NativeError("process_create");
            created=true; result.StartCount=1; result.ProcessId=checked((int)process.ProcessId);
            Close(ref outWrite,result); Close(ref errWrite,result); Close(ref inRead,result);
            if(!AssignProcessToJobObject(job,process.Process)) throw NativeError("job_assign");
            assigned=true; result.JobAssignedBeforeResume=true;
            stdout=Task.Run(()=>Drain(outRead,cap,cancellation.Token,watch));
            stderr=Task.Run(()=>Drain(errRead,cap,cancellation.Token,watch));
            if(ResumeThread(process.Thread)==uint.MaxValue) throw NativeError("process_resume");
            while(true) {
                if(watch.ElapsedMilliseconds>=deadlineMs) { result.TimedOut=true; throw new TimeoutException("host_process_deadline"); }
                result.RootExitConfirmed=Exited(process.Process);
                if(result.RootExitConfirmed && Active(job)==0) { result.NaturalExit=true; break; }
                if((stdout.IsCompletedSuccessfully && stdout.Result.Error!=null) || (stderr.IsCompletedSuccessfully && stderr.Result.Error!=null)) throw new IOException("raw_stream_drain_failed");
                Thread.Sleep(10);
            }
            Stopwatch drain=Stopwatch.StartNew();
            while(!Done(stdout,stderr) && drain.ElapsedMilliseconds<drainMs) Thread.Sleep(10);
            if(!Done(stdout,stderr)) { result.DrainTimedOut=true; throw new TimeoutException("dual_stream_drain_deadline"); }
        } catch(Exception error) { result.Errors.Add(Bounded(error)); }
        finally {
            Stopwatch cleanup=Stopwatch.StartNew();
            if(created) {
                try {
                    bool rootExited=Exited(process.Process); uint active=assigned ? Active(job) : (rootExited ? 0u : 1u);
                    if(!rootExited || active!=0) {
                        result.TerminationRequested=true;
                        if(assigned) { if(!TerminateJobObject(job,1)) throw NativeError("job_terminate"); }
                        else if(!TerminateProcess(process.Process,1)) throw NativeError("suspended_root_terminate");
                    }
                    while(cleanup.ElapsedMilliseconds<cleanupMs) {
                        rootExited=Exited(process.Process); active=assigned ? Active(job) : (rootExited ? 0u : 1u);
                        if(rootExited && active==0) break;
                        Thread.Sleep(10);
                    }
                    result.RootExitConfirmed=rootExited;
                    result.CleanupActiveProcessCount=assigned ? active : (uint?)null;
                    if(!rootExited || active!=0) result.CleanupErrors.Add("process_or_job_cleanup_unknown");
                    if(rootExited) {
                        uint code; if(!GetExitCodeProcess(process.Process,out code)) throw NativeError("native_exit_read");
                        result.ExitCode=unchecked((int)code);
                    }
                } catch(Exception error) { result.CleanupErrors.Add(Bounded(error)); }
            }
            // First allow termination to produce real pipe EOF; cancellation never means EOF.
            long drainEnd=Math.Min(cleanupMs,cleanup.ElapsedMilliseconds+drainMs);
            while(!Done(stdout,stderr) && (stdout!=null || stderr!=null) && cleanup.ElapsedMilliseconds<drainEnd) Thread.Sleep(10);
            if(!Done(stdout,stderr)) cancellation.Cancel();
            while(!Done(stdout,stderr) && (stdout!=null || stderr!=null) && cleanup.ElapsedMilliseconds<cleanupMs) Thread.Sleep(10);
            result.DrainsCompleted=Done(stdout,stderr);
            if(stdout!=null && stdout.IsCompletedSuccessfully) result.Stdout=stdout.Result;
            if(stderr!=null && stderr.IsCompletedSuccessfully) result.Stderr=stderr.Result;
            if((stdout!=null || stderr!=null) && !result.DrainsCompleted) result.CleanupErrors.Add("drain_workers_cleanup_unknown");
            if(result.Stdout.Error!=null) result.Errors.Add("stdout: "+result.Stdout.Error);
            if(result.Stderr.Error!=null) result.Errors.Add("stderr: "+result.Stderr.Error);
            Close(ref outRead,result); Close(ref errRead,result); Close(ref outWrite,result); Close(ref errWrite,result); Close(ref inRead,result); Close(ref inWrite,result); Close(ref job,result);
            if(process.Thread!=IntPtr.Zero && !CloseHandle(process.Thread)) result.CleanupErrors.Add("thread_handle_close_failed");
            if(process.Process!=IntPtr.Zero && !CloseHandle(process.Process)) result.CleanupErrors.Add("process_handle_close_failed");
            if(attributesInitialized) DeleteProcThreadAttributeList(attributes);
            if(attributes!=IntPtr.Zero) Marshal.FreeHGlobal(attributes);
            if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
            if(environment!=IntPtr.Zero) Marshal.FreeHGlobal(environment);
            cancellation.Dispose(); result.HandlesClosed=result.CleanupErrors.Count==0;
            result.ElapsedMilliseconds=watch.ElapsedMilliseconds;
        }
        result.Passed=result.StartCount==1 && result.JobAssignedBeforeResume && result.RootExitConfirmed && result.NaturalExit &&
            result.ExitCode==0 && !result.TimedOut && !result.DrainTimedOut && !result.TerminationRequested && result.CleanupActiveProcessCount==0 &&
            result.DrainsCompleted && result.Stdout.Eof && result.Stderr.Eof && !result.Stdout.Aborted && !result.Stderr.Aborted &&
            !result.Stdout.Overflowed && !result.Stderr.Overflowed && result.Stdout.FullSha256!=null && result.Stderr.FullSha256!=null &&
            result.Errors.Count==0 && result.CleanupErrors.Count==0 && result.HandlesClosed;
        return result;
    }
}
}
'@
}

function Get-TL1C1bHostCaptureEnvironment {
    [CmdletBinding()]
    param([AllowNull()][Collections.IDictionary]$Environment,[switch]$ClearEnvironment)
    $effective=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    if(-not$ClearEnvironment){foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$effective[[string]$entry.Key]=[string]$entry.Value}}
    $declared=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if($null-ne$Environment){
        foreach($entry in $Environment.GetEnumerator()){
            if($entry.Key-isnot[string]-or[string]::IsNullOrEmpty($entry.Key)-or$entry.Key.Contains([char]0)-or$entry.Key.Contains('=')-or$entry.Value-isnot[string]-or$entry.Value.Contains([char]0)-or-not$declared.Add($entry.Key)){throw 'Environment keys/values invalid or duplicated ignoring case.'}
            $effective[$entry.Key]=$entry.Value
        }
    }
    $keys=[string[]]@($effective.Keys|ForEach-Object{$_.ToUpperInvariant()})
    [Array]::Sort($keys,[StringComparer]::Ordinal)
    $builder=[Text.StringBuilder]::new()
    foreach($key in $keys){[void]$builder.Append($key).Append('=').Append($effective[$key]).Append([char]0)}
    [void]$builder.Append([char]0)
    if($keys.Count-eq0){[void]$builder.Append([char]0)}
    $block=$builder.ToString();$bytes=[Text.Encoding]::Unicode.GetBytes($block)
    try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
    $mode=if($ClearEnvironment){'replace'}elseif($null-ne$Environment){'overlay'}else{'inherit'}
    return [pscustomobject]@{Block=$(if($mode-ceq'inherit'){$null}else{$block});Record=[pscustomobject][ordered]@{mode=$mode;keys=$keys;sha256=$hash}}
}

function Invoke-TL1C1bHostProcessCapture {
    <#
    .SYNOPSIS
    Starts one noninteractive Windows host process and records raw separate streams.
    .DESCRIPTION
    The evidence directory is a one-shot reservation and must not exist. No retry,
    elevation, BuildOnly, Git, build or device policy is selected by this function.
    The caller must bind the exact executable, argument list and authorization first.
    Capture success is transport evidence only; it is not host acceptance or Ready.
    Full stream total/hash is authoritative only with EOF and a null stream error.
    Cleanup covers the contained Job processes, pipe workers and owned handles.
    Environment defaults to inheritance. Explicit replacement/overlay is passed to
    CreateProcessW without mutating the parent; only names and a canonical UTF-16LE
    environment-block hash are recorded. Inherit hash is the observed parent snapshot.
    Runtime/environment pins remain caller responsibilities. Captured stream files
    are prefixes when overflowed.
    The returned status must be checked by the caller: a function return does not
    translate the child's native exit code into the caller's native exit code.
    .EXAMPLE
    $capture = Invoke-TL1C1bHostProcessCapture -ExecutablePath $pinnedRuntime -ArgumentList $reviewedArguments -WorkingDirectory $boundWorkingDirectory -EvidenceDirectory $freshEvidenceDirectory
    if ($capture.status -cne 'passed') { throw 'Host process capture failed.' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$EvidenceDirectory,
        [ValidateRange(0,16777216)][int]$CaptureLimitBytes = 1048576,
        [ValidateRange(1,86400000)][int]$TimeoutMilliseconds = 2700000,
        [ValidateRange(1,60000)][int]$DrainTimeoutMilliseconds = 30000,
        [ValidateRange(1,60000)][int]$CleanupTimeoutMilliseconds = 30000,
        [AllowNull()][Collections.IDictionary]$Environment,
        [switch]$ClearEnvironment
    )
    if (-not $IsWindows) { throw 'Windows Job Object required.' }
    foreach ($path in @($ExecutablePath,$WorkingDirectory,$EvidenceDirectory)) {
        if (-not [IO.Path]::IsPathFullyQualified($path) -or $path.Contains([char]0)) { throw 'Capture paths must be absolute and NUL-free.' }
    }
    if (-not [IO.File]::Exists($ExecutablePath) -or -not [IO.Directory]::Exists($WorkingDirectory)) { throw 'Executable or working directory absent.' }
    foreach ($argument in $ArgumentList) {
        if ($null -eq $argument -or $argument.Contains([char]0)) { throw 'Capture argument invalid.' }
    }
    $environmentBinding=Get-TL1C1bHostCaptureEnvironment -Environment $Environment -ClearEnvironment:$ClearEnvironment
    if ([IO.Directory]::Exists($EvidenceDirectory) -or [IO.File]::Exists($EvidenceDirectory)) { throw 'Capture evidence is already reserved; retry forbidden.' }
    [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
    $utf8 = [Text.UTF8Encoding]::new($false)
    function Save-CaptureNewBytes([string]$Name,[byte[]]$Bytes) {
        $stream = [IO.File]::Open((Join-Path $EvidenceDirectory $Name),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    }
    $startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    # CreateNew is the concurrent reservation boundary, before native process creation.
    Save-CaptureNewBytes 'reservation.json' ($utf8.GetBytes((@{schema='tl1-c1b-host-process-capture-reservation/v1';started_at_utc=$startedUtc;parent_pid=$PID;automatic_retry_count=0}|ConvertTo-Json -Compress)+"`n"))
    $native = [TL1C1bHostCapture.NativeV1]::Run($ExecutablePath,$ArgumentList,$WorkingDirectory,$CaptureLimitBytes,$TimeoutMilliseconds,$DrainTimeoutMilliseconds,$CleanupTimeoutMilliseconds,$environmentBinding.Block,($environmentBinding.Record.mode-cne'inherit'))
    $record = [ordered]@{
        schema='tl1-c1b-host-process-capture/v1';status=$(if ($native.Passed) {'passed'} else {'failed'})
        started_at_utc=$startedUtc;completed_at_utc=[DateTimeOffset]::UtcNow.ToString('o');elapsed_milliseconds=$native.ElapsedMilliseconds
        start_attempt_count=$native.StartAttemptCount;start_count=$native.StartCount;automatic_retry_count=0
        child_pid=$native.ProcessId;exit_code=$native.ExitCode;root_exit_confirmed=$native.RootExitConfirmed;natural_exit=$native.NaturalExit
        timed_out=$native.TimedOut;drain_timed_out=$native.DrainTimedOut;termination_requested=$native.TerminationRequested
        capture_limit_bytes_per_stream=$CaptureLimitBytes;timeout_milliseconds=$TimeoutMilliseconds;drain_timeout_milliseconds=$DrainTimeoutMilliseconds;cleanup_timeout_milliseconds=$CleanupTimeoutMilliseconds
        drains_completed=$native.DrainsCompleted;errors=@($native.Errors.ToArray());publication_errors=@()
        environment=$environmentBinding.Record
        cleanup=[ordered]@{scope='contained_job_processes_pipe_workers_owned_handles';job_assigned_before_resume=$native.JobAssignedBeforeResume;active_process_count=$native.CleanupActiveProcessCount;handles_closed=$native.HandlesClosed;failure_count=$native.CleanupErrors.Count;errors=@($native.CleanupErrors.ToArray());completed=($native.HandlesClosed -and $native.DrainsCompleted -and $native.RootExitConfirmed -and $native.CleanupActiveProcessCount -eq 0 -and $native.CleanupErrors.Count -eq 0)}
    }
    foreach ($name in @('stdout','stderr')) {
        $streamResult = if ($name -ceq 'stdout') { $native.Stdout } else { $native.Stderr }
        $record[$name] = [ordered]@{
            eof=$streamResult.Eof;aborted=$streamResult.Aborted;error=$streamResult.Error;overflowed=$streamResult.Overflowed
            observed_byte_length=$streamResult.ObservedByteLength;observed_sha256=$streamResult.ObservedSha256
            total_byte_length=$(if ($streamResult.Eof -and $null -eq $streamResult.Error) {$streamResult.ObservedByteLength} else {$null})
            sha256=$streamResult.FullSha256;captured_byte_length=$streamResult.CapturedBytes.Length;captured_sha256=$streamResult.CapturedSha256
            first_byte_observed_elapsed_milliseconds=$streamResult.FirstByteObservedElapsedMilliseconds;eof_observed_elapsed_milliseconds=$streamResult.EofObservedElapsedMilliseconds
        }
        try { Save-CaptureNewBytes ($name+'.bin') $streamResult.CapturedBytes }
        catch { $record.status='failed';$record.publication_errors+=($name+': '+$_.Exception.GetType().Name) }
        finally { if ($streamResult.CapturedBytes.Length) { [Array]::Clear($streamResult.CapturedBytes,0,$streamResult.CapturedBytes.Length) } }
    }
    # Publication exceptions remain exceptions; absent execution.json is never a pass.
    Save-CaptureNewBytes 'execution.json' ($utf8.GetBytes(($record|ConvertTo-Json -Depth 10)+"`n"))
    return [pscustomobject]$record
}
