#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) { $EvidenceRoot=Join-Path $repoRoot '.checks\c1b-host-process-capture-offline' }
$EvidenceRoot=[IO.Path]::GetFullPath($EvidenceRoot)
$runRoot=Join-Path $EvidenceRoot ('run-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$utf8=[Text.UTF8Encoding]::new($false)
$pwsh=[Environment]::ProcessPath
. (Join-Path $repoRoot 'scripts\lib\c1b-host-process-capture.ps1')
$workerPath=Join-Path $runRoot 'synthetic-worker.ps1'
$worker=@'
#Requires -Version 7.5
param([string]$Mode,[string]$Counter,[string]$ChildPid,[AllowEmptyString()][string]$Value)
$ErrorActionPreference='Stop'
[IO.File]::AppendAllText($Counter,"entry`n",[Text.UTF8Encoding]::new($false))
$stdout=[Console]::OpenStandardOutput();$stderr=[Console]::OpenStandardError()
switch ($Mode) {
    'binary' {$stdout.Write([byte[]](0,255,13,10,65,0,66));$stderr.Write([byte[]](128,254,10,13,67));break}
    'empty' {break}
    'nonzero' {$stderr.Write([byte[]](69,82,82));exit 23}
    'oversize' {$bytes=[byte[]]::new(8193);for($i=0;$i-lt$bytes.Length;$i++){$bytes[$i]=[byte]($i%251)};$stdout.Write($bytes);$stderr.Write($bytes);break}
    'stderr-after-stdout-eof' {
        Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class CloseSyntheticStdout{[DllImport("kernel32.dll")]static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll",SetLastError=true)]static extern bool CloseHandle(IntPtr h);public static void Close(){if(!CloseHandle(GetStdHandle(-11)))throw new Exception("Synthetic stdout close failed");}}'
        [CloseSyntheticStdout]::Close();Start-Sleep -Milliseconds 120;$stderr.Write([byte[]](128,254,10,13,67));break
    }
    'timeout' {$stdout.Write([byte[]](84));$stdout.Flush();Start-Sleep -Seconds 30;break}
    'child-sleep' {[IO.File]::WriteAllText($ChildPid,[string]$PID);Start-Sleep -Seconds 30;break}
    'descendant' {
        $psi=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        foreach($item in @('-NoProfile','-File',$PSCommandPath,'-Mode','child-sleep','-Counter',$Counter,'-ChildPid',$ChildPid)){[void]$psi.ArgumentList.Add($item)}
        $child=[Diagnostics.Process]::Start($psi)
        $until=[DateTime]::UtcNow.AddSeconds(10)
        while(-not[IO.File]::Exists($ChildPid)-and[DateTime]::UtcNow-lt$until){Start-Sleep -Milliseconds 10}
        if(-not[IO.File]::Exists($ChildPid)){throw 'Synthetic descendant did not enter'}
        $child.Dispose();break
    }
    'argument' {$stdout.Write([Text.UTF8Encoding]::new($false).GetBytes($Value));break}
    'stdin-eof' {if([Console]::OpenStandardInput().ReadByte()-ne-1){exit 88};break}
    'environment' {
        $environmentProbe=[ordered]@{explicit=[Environment]::GetEnvironmentVariable('TL1_CAPTURE_EXPLICIT');parent_leak_present=($null-ne[Environment]::GetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY'));empty_value=[Environment]::GetEnvironmentVariable('TL1_CAPTURE_EMPTY')}
        $stdout.Write([Text.UTF8Encoding]::new($false).GetBytes(($environmentProbe|ConvertTo-Json -Compress)));break
    }
    default {exit 89}
}
if($Mode-cne'stderr-after-stdout-eof'){$stdout.Flush()};$stderr.Flush()
exit 0
'@
[IO.File]::WriteAllText($workerPath,$worker,$utf8)
$script:assertions=0
$cases=[Collections.Generic.List[object]]::new()
function Assert-Capture([bool]$Condition,[string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw $Message }
}
function Hash-Bytes([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Assert-Bytes([string]$Path,[byte[]]$Expected,[string]$Label) {
    $actual=[IO.File]::ReadAllBytes($Path)
    Assert-Capture ($actual.Length -eq $Expected.Length -and (Hash-Bytes $actual) -ceq (Hash-Bytes $Expected)) "$Label raw bytes differ"
}
function Count-Entries([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return 0 }
    return [IO.File]::ReadAllLines($Path).Length
}
function Run-Synthetic([string]$Case,[string]$Mode,[int]$Cap=1048576,[int]$Deadline=15000,[string]$Value='') {
    $counter=Join-Path $runRoot ($Case+'-entries.txt')
    $childPid=Join-Path $runRoot ($Case+'-child-pid.txt')
    $output=Join-Path $runRoot $Case
    $arguments=@('-NoProfile','-File',$workerPath,'-Mode',$Mode,'-Counter',$counter,'-ChildPid',$childPid,'-Value',$Value)
    $record=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $arguments -WorkingDirectory $runRoot -EvidenceDirectory $output -CaptureLimitBytes $Cap -TimeoutMilliseconds $Deadline -DrainTimeoutMilliseconds 1500 -CleanupTimeoutMilliseconds 4000
    return [pscustomobject]@{Record=$record;Directory=$output;Counter=$counter;ChildPid=$childPid;Arguments=$arguments}
}
function Assert-TransportCleanup($Record) {
    Assert-Capture ($Record.start_count -eq 1 -and $Record.start_attempt_count -eq 1 -and $Record.automatic_retry_count -eq 0) 'one-shot start count drift'
    Assert-Capture ($Record.root_exit_confirmed -and $Record.drains_completed) 'root or drain completion missing'
    Assert-Capture ($Record.cleanup.completed -and $Record.cleanup.failure_count -eq 0 -and $Record.cleanup.active_process_count -eq 0 -and $Record.cleanup.handles_closed -and $Record.cleanup.job_assigned_before_resume) 'capture cleanup incomplete'
    Assert-Capture ($Record.stdout.eof -and $Record.stderr.eof -and -not $Record.stdout.aborted -and -not $Record.stderr.aborted) 'real dual EOF missing'
    Assert-Capture ($null -eq (Get-Process -Id $Record.child_pid -ErrorAction SilentlyContinue)) 'synthetic root survived'
}
function Case([string]$Name,[scriptblock]$Body) {
    try { & $Body; $cases.Add([pscustomobject]@{name=$Name;status='passed';error=$null});Write-Output "PASS $Name" }
    catch { $cases.Add([pscustomobject]@{name=$Name;status='failed';error=$_.Exception.Message});Write-Output "FAIL $Name`: $($_.Exception.Message)" }
}
Case 'binary_stdout_stderr' {
    $r=Run-Synthetic 'binary' 'binary';Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'passed' -and $r.Record.exit_code -eq 0) 'binary capture failed'
    Assert-Bytes (Join-Path $r.Directory 'stdout.bin') ([byte[]](0,255,13,10,65,0,66)) 'stdout'
    Assert-Bytes (Join-Path $r.Directory 'stderr.bin') ([byte[]](128,254,10,13,67)) 'stderr'
    Assert-Capture ($r.Record.stdout.total_byte_length -eq 7 -and $r.Record.stdout.captured_byte_length -eq 7 -and $r.Record.stdout.sha256 -ceq (Hash-Bytes ([byte[]](0,255,13,10,65,0,66)))) 'stdout total/hash drift'
    Assert-Capture ($r.Record.stderr.total_byte_length -eq 5 -and $r.Record.stderr.sha256 -ceq (Hash-Bytes ([byte[]](128,254,10,13,67)))) 'stderr total/hash drift'
    Assert-Capture ((Count-Entries $r.Counter) -eq 1) 'binary process retried'
}
Case 'empty_dual_streams' {
    $r=Run-Synthetic 'empty' 'empty';Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'passed') 'empty capture failed'
    foreach($name in @('stdout','stderr')) {
        Assert-Capture ($r.Record.$name.total_byte_length -eq 0 -and $r.Record.$name.sha256 -ceq (Hash-Bytes ([byte[]]@()))) 'empty hash or total drift'
        Assert-Bytes (Join-Path $r.Directory ($name+'.bin')) ([byte[]]@()) $name
    }
}
Case 'native_nonzero_no_retry' {
    $r=Run-Synthetic 'nonzero' 'nonzero';Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'failed' -and $r.Record.exit_code -eq 23 -and $r.Record.natural_exit) 'native nonzero exit was hidden'
    Assert-Capture ((Count-Entries $r.Counter) -eq 1) 'nonzero process retried'
    Assert-Bytes (Join-Path $r.Directory 'stderr.bin') ([byte[]](69,82,82)) 'nonzero stderr'
}
Case 'oversize_full_hash_bounded_prefix' {
    $r=Run-Synthetic 'oversize' 'oversize' 1024;Assert-TransportCleanup $r.Record
    $bytes=[byte[]]::new(8193);for($i=0;$i -lt $bytes.Length;$i++) {$bytes[$i]=[byte]($i%251)}
    Assert-Capture ($r.Record.status -ceq 'failed' -and $r.Record.exit_code -eq 0) 'oversize transport incorrectly passed'
    foreach($name in @('stdout','stderr')) {
        Assert-Capture ($r.Record.$name.overflowed -and $r.Record.$name.total_byte_length -eq 8193 -and $r.Record.$name.captured_byte_length -eq 1024 -and $r.Record.$name.sha256 -ceq (Hash-Bytes $bytes)) 'oversize full-stream total/hash drift'
        Assert-Bytes (Join-Path $r.Directory ($name+'.bin')) ([byte[]]$bytes[0..1023]) ($name+' bounded prefix')
    }
}
Case 'stderr_after_stdout_eof' {
    $r=Run-Synthetic 'late-stderr' 'stderr-after-stdout-eof';Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'passed' -and $r.Record.stdout.total_byte_length -eq 0) 'late stderr capture failed'
    Assert-Capture ($r.Record.stdout.eof_observed_elapsed_milliseconds -lt $r.Record.stderr.first_byte_observed_elapsed_milliseconds) 'stdout EOF before later stderr was not exercised'
    Assert-Bytes (Join-Path $r.Directory 'stderr.bin') ([byte[]](128,254,10,13,67)) 'late stderr'
}
Case 'timeout_job_cleanup_no_retry' {
    $r=Run-Synthetic 'timeout' 'timeout' 1048576 2500;Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'failed' -and $r.Record.timed_out -and $r.Record.termination_requested -and -not $r.Record.natural_exit) 'timeout incorrectly passed'
    Assert-Capture ($r.Record.elapsed_milliseconds -lt 8500 -and (Count-Entries $r.Counter) -eq 1) 'timeout was unbounded or retried'
    Assert-Bytes (Join-Path $r.Directory 'stdout.bin') ([byte[]](84)) 'timeout prefix'
}
Case 'root_exit_descendant_job_cleanup' {
    $r=Run-Synthetic 'descendant' 'descendant' 1048576 3500;Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'failed' -and $r.Record.timed_out -and $r.Record.termination_requested -and $r.Record.exit_code -eq 0) 'root exit hid the surviving descendant'
    Assert-Capture ([IO.File]::Exists($r.ChildPid)) 'descendant was not exercised'
    $childId=[int][IO.File]::ReadAllText($r.ChildPid)
    Assert-Capture ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'synthetic descendant survived Job cleanup'
    Assert-Capture ((Count-Entries $r.Counter) -eq 2) 'descendant run was retried'
}
Case 'repeated_evidence_rejected_before_start' {
    $r=Run-Synthetic 'repeat' 'empty';$executionBefore=Hash-Bytes ([IO.File]::ReadAllBytes((Join-Path $r.Directory 'execution.json')))
    $rejected=$false
    try { $null=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $r.Arguments -WorkingDirectory $runRoot -EvidenceDirectory $r.Directory }
    catch { $rejected=$_.Exception.Message -like '*already reserved*' }
    Assert-Capture $rejected 'repeated evidence did not fail before process start'
    Assert-Capture ((Count-Entries $r.Counter) -eq 1) 'repeated invocation started another process'
    Assert-Capture ((Hash-Bytes ([IO.File]::ReadAllBytes((Join-Path $r.Directory 'execution.json')))) -ceq $executionBefore) 'repeated invocation overwrote evidence'
}
Case 'windows_argument_quote_and_stdin_eof' {
    $value='space " quote \\ tail\'
    $r=Run-Synthetic 'argument' 'argument' 1048576 15000 $value;Assert-TransportCleanup $r.Record
    Assert-Capture ($r.Record.status -ceq 'passed') 'argument capture failed'
    Assert-Bytes (Join-Path $r.Directory 'stdout.bin') ($utf8.GetBytes($value)) 'quoted argument'
    $empty=Run-Synthetic 'argument-empty' 'argument' 1048576 15000 '';Assert-Capture ($empty.Record.status -ceq 'passed' -and $empty.Record.stdout.total_byte_length -eq 0) 'empty argument lost'
    $input=Run-Synthetic 'stdin' 'stdin-eof';Assert-Capture ($input.Record.status -ceq 'passed') 'noninteractive stdin was not EOF'
}
Case 'native_start_failure_stays_failed' {
    $invalid=Join-Path $runRoot 'not-an-executable.bin';[IO.File]::WriteAllBytes($invalid,[byte[]](1,2,3))
    $record=Invoke-TL1C1bHostProcessCapture -ExecutablePath $invalid -ArgumentList @() -WorkingDirectory $runRoot -EvidenceDirectory (Join-Path $runRoot 'start-failure') -TimeoutMilliseconds 1000 -DrainTimeoutMilliseconds 100 -CleanupTimeoutMilliseconds 1000
    Assert-Capture ($record.status -ceq 'failed' -and $record.start_attempt_count -eq 1 -and $record.start_count -eq 0 -and $null -eq $record.exit_code -and -not $record.stdout.eof -and -not $record.stderr.eof) 'start failure fabricated exit or EOF'
    Assert-Capture ($null -eq $record.stdout.total_byte_length -and $null -eq $record.stdout.sha256 -and -not $record.cleanup.completed) 'unknown stream/cleanup promoted to pass'
}
Case 'explicit_environment_replacement_no_parent_mutation' {
    $prior=[Environment]::GetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY');$priorExplicit=[Environment]::GetEnvironmentVariable('TL1_CAPTURE_EXPLICIT')
    try{
        [Environment]::SetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY','synthetic-parent-marker')
        $counter=Join-Path $runRoot 'environment-entries.txt';$output=Join-Path $runRoot 'environment-replace'
        $argv=@('-NoProfile','-File',$workerPath,'-Mode','environment','-Counter',$counter)
        $map=@{TL1_CAPTURE_EXPLICIT="synthetic unicode 漢字 = newline`n";TL1_CAPTURE_EMPTY=''}
        $r=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $runRoot -EvidenceDirectory $output -Environment $map -ClearEnvironment
        Assert-TransportCleanup $r
        $child=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $output 'stdout.bin'),$utf8))
        Assert-Capture ($r.status-ceq'passed'-and$r.environment.mode-ceq'replace'-and$r.environment.keys.Count-eq2-and-not$child.parent_leak_present-and$child.explicit-ceq$map.TL1_CAPTURE_EXPLICIT) 'explicit environment leaked inherited values or lost Unicode'
        Assert-Capture ([Environment]::GetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY')-ceq'synthetic-parent-marker'-and[Environment]::GetEnvironmentVariable('TL1_CAPTURE_EXPLICIT')-ceq$priorExplicit) 'capture mutated parent environment'
        $serialized=[IO.File]::ReadAllText((Join-Path $output 'execution.json'))
        Assert-Capture (-not$serialized.Contains('synthetic unicode')-and-not$serialized.Contains('synthetic-parent-marker')) 'environment values appeared in capture receipt'
        $equivalent=[ordered]@{tl1_capture_empty='';tl1_capture_explicit=$map.TL1_CAPTURE_EXPLICIT}
        $equivalentBinding=Get-TL1C1bHostCaptureEnvironment -Environment $equivalent -ClearEnvironment
        Assert-Capture ($r.environment.sha256-ceq$equivalentBinding.Record.sha256) 'canonical environment hash depends on key case/order'
    }finally{[Environment]::SetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY',$prior)}
}
Case 'empty_environment_and_overlay' {
    $prior=[Environment]::GetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY')
    try{
        [Environment]::SetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY','synthetic-parent-marker')
        foreach($clear in @($true,$false)){
            $case=if($clear){'environment-empty'}else{'environment-overlay'};$output=Join-Path $runRoot $case
            $argv=@('-NoProfile','-File',$workerPath,'-Mode','environment','-Counter',(Join-Path $runRoot ($case+'-entries.txt')))
            $map=if($clear){@{}}else{@{TL1_CAPTURE_EXPLICIT='synthetic-overlay'}}
            $r=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $runRoot -EvidenceDirectory $output -Environment $map -ClearEnvironment:$clear
            Assert-TransportCleanup $r
            $child=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $output 'stdout.bin'),$utf8))
            if($clear){Assert-Capture ($r.status-ceq'passed'-and$r.environment.keys.Count-eq0-and$r.environment.mode-ceq'replace'-and-not$child.parent_leak_present-and$null-eq$child.explicit) 'empty replacement inherited a parent variable'}
            else{Assert-Capture ($r.status-ceq'passed'-and$r.environment.mode-ceq'overlay'-and$child.parent_leak_present-and$child.explicit-ceq'synthetic-overlay') 'overlay lost parent variables or explicit override'}
        }
    }finally{[Environment]::SetEnvironmentVariable('TL1_CAPTURE_PARENT_ONLY',$prior)}
}
Case 'environment_invalid_keys_values_rejected_before_start' {
    $counter=Join-Path $runRoot 'environment-invalid-entries.txt';$argv=@('-NoProfile','-File',$workerPath,'-Mode','empty','-Counter',$counter)
    $duplicate=[Collections.Hashtable]::new([StringComparer]::Ordinal);$duplicate.Add('NAME','a');$duplicate.Add('name','b')
    $invalid=@($duplicate,@{'bad=name'='a'},@{("bad"+[char]0)='a'},@{good=("bad"+[char]0)},@{good=1})
    for($i=0;$i-lt$invalid.Count;$i++){
        $output=Join-Path $runRoot ('invalid-environment-'+$i);$rejected=$false
        try{$null=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $runRoot -EvidenceDirectory $output -Environment $invalid[$i] -ClearEnvironment}catch{$rejected=$_.Exception.Message-like'*Environment keys/values invalid*'}
        Assert-Capture ($rejected-and-not[IO.Directory]::Exists($output)-and(Count-Entries $counter)-eq0) 'invalid environment reached reservation/process launch'
    }
}
$passed=@($cases|Where-Object status -CEQ 'passed').Count
$failed=$cases.Count-$passed
$summary=[ordered]@{schema='tl1-c1b-host-process-capture-offline/v1';status=$(if($failed -eq 0){'passed'}else{'failed'});runtime=$PSVersionTable.PSVersion.ToString();passed=$passed;failed=$failed;assertions=$script:assertions;cases=$cases.ToArray();real_buildonly_call_count=0;real_git_call_count=0;real_jdk_gradle_call_count=0;real_adb_device_call_count=0}
[IO.File]::WriteAllText((Join-Path $runRoot 'summary.json'),($summary|ConvertTo-Json -Depth 8)+"`n",$utf8)
Write-Output "host-process-capture: $passed passed / $failed failed; $script:assertions assertions; evidence=$runRoot"
if($failed -gt 0){exit 1}
exit 0
