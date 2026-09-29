#Requires -Version 7.5
[CmdletBinding()]param([string]$EvidenceRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Join-Path $repoRoot '.checks\c1b-candidate-host-stages-offline'}
$runRoot=Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('run-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$entry=Join-Path $repoRoot 'scripts\invoke-c1b-candidate-host-stage.ps1'
$module=Join-Path $repoRoot 'scripts\lib\c1b-candidate-host-stages.ps1'
$captureModule=Join-Path $repoRoot 'scripts\lib\c1b-host-process-capture.ps1'
. $module;. $captureModule
$pwsh=[Environment]::ProcessPath;$utf8=[Text.UTF8Encoding]::new($false)
$worker=Join-Path $runRoot 'synthetic-stage.ps1'
[IO.File]::WriteAllText($worker,@'
param([string]$Counter,[string]$Artifact,[string]$Mode='pass')
$ErrorActionPreference='Stop'
[IO.File]::AppendAllText($Counter,"entry`n",[Text.UTF8Encoding]::new($false))
if($Mode-ceq'nonzero'){[Console]::Error.WriteLine('synthetic error');exit 31}
if($Mode-ceq'timeout'){Start-Sleep -Seconds 20;exit 0}
if($Mode-ceq'oversize'){$bytes=[byte[]]::new(8193);[Console]::OpenStandardOutput().Write($bytes);exit 0}
if($Mode-ceq'guard-probe'){
    $directoryDenied=$false;$writeDenied=$false;$sourceParent=[IO.Path]::GetDirectoryName($PSCommandPath)
    try{[IO.Directory]::Move($sourceParent,$sourceParent+'-moved')}catch{$directoryDenied=$true}
    try{$stream=[IO.File]::Open($PSCommandPath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose()}catch{$writeDenied=$true}
    [IO.File]::WriteAllText($Artifact,(@{directory_denied=$directoryDenied;write_denied=$writeDenied}|ConvertTo-Json -Compress))
    exit 0
}
if($Mode-cne'missing'){[IO.File]::WriteAllText($Artifact,'{"synthetic":true}',[Text.UTF8Encoding]::new($false))}
[Console]::Out.WriteLine('{"synthetic_stage":"passed"}')
exit 0
'@,$utf8)
$script:assertions=0;$cases=[Collections.Generic.List[object]]::new()
function Check([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Pin([string]$Path){$h=Open-C1bHostStagePin $Path;try{return $h.Pin}finally{Close-C1bHostStageHeld $h}}
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 24)+"`n",$utf8)}
function New-Input([string]$Case,[string]$Phase='Pair',[string]$Mode='pass'){
    $root=Join-Path $runRoot $Case;[void][IO.Directory]::CreateDirectory($root)
    $artifact=Join-Path $root 'artifact.json';$counter=Join-Path $root 'entries.txt';$bindingPath=Join-Path $root 'bindings.json';$statePath=Join-Path $root 'state.json'
    $state=if($Phase-ceq'Preflight'){'frozen_for_host'}elseif($Phase-ceq'Readback'){'post_buildonly'}else{'preparation'}
    $candidate='a'*40
    Save $statePath ([ordered]@{schema='c1b-candidate-host-state/v1';candidate_sha=$candidate;state=$state;working_directory=$root})
    $runtime=Pin $pwsh
    $argv=@('-NoProfile','-File',$worker,'-Counter',$counter,'-Artifact',$artifact,'-Mode',$Mode)
    $b=[pscustomobject][ordered]@{
        schema='c1b-candidate-host-stage-bindings/v1';run_id=[guid]::NewGuid().ToString('N');candidate_sha=$candidate;phase=$Phase;candidate_state=$state;candidate_state_pin=(Pin $statePath)
        runtime=[pscustomobject]@{path=$runtime.path;byte_length=$runtime.byte_length;sha256=$runtime.sha256;version=$PSVersionTable.PSVersion.ToString()}
        stage_source=(Pin $worker);transport_sources=[pscustomobject]@{invoker=(Pin $entry);module=(Pin $module);capture=(Pin $captureModule)}
        working_directory=$root;argument_list=$argv;argument_list_sha256=(Get-C1bHostStageArgvHash $argv);evidence_directory=(Join-Path $root 'stage')
        artifact_inventory=@([pscustomobject]@{path=$artifact;required=$true});capture_limits=[pscustomobject]@{capture_limit_bytes=1048576;timeout_milliseconds=15000;drain_timeout_milliseconds=1500;cleanup_timeout_milliseconds=4000};automatic_retry_count=0;environment=$null
    }
    Save $bindingPath $b
    return [pscustomobject]@{Root=$root;Binding=$b;BindingPath=$bindingPath;Counter=$counter;Artifact=$artifact}
}
function Run-Entry($InputCase,[string]$Suffix='run'){
    Save $InputCase.BindingPath $InputCase.Binding
    $argv=@('-NoProfile','-File',$entry,'-Operation','Run','-BindingsPath',$InputCase.BindingPath,'-ExpectedBindingsSha256',(Pin $InputCase.BindingPath).sha256)
    $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $InputCase.Root -EvidenceDirectory (Join-Path $InputCase.Root ('outer-'+$Suffix)) -TimeoutMilliseconds 25000 -DrainTimeoutMilliseconds 1500 -CleanupTimeoutMilliseconds 4000
    return $capture
}
function Read-Entry($InputCase,[string]$Suffix='reader'){
    $obs=Join-Path $InputCase.Binding.evidence_directory 'observation.json'
    $argv=@('-NoProfile','-File',$entry,'-Operation','Read','-ObservationPath',$obs,'-ExpectedObservationSha256',(Pin $obs).sha256)
    return Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $InputCase.Root -EvidenceDirectory (Join-Path $InputCase.Root ('outer-'+$Suffix)) -TimeoutMilliseconds 15000 -DrainTimeoutMilliseconds 1500 -CleanupTimeoutMilliseconds 4000
}
function Load([string]$Path){return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,$utf8)) -Depth 24 -DateKind String}
function Count-Entries([string]$Path){if(-not[IO.File]::Exists($Path)){return 0};return [IO.File]::ReadAllLines($Path).Length}
function Case([string]$Name,[scriptblock]$Body){try{&$Body;$cases.Add([pscustomobject]@{name=$Name;status='passed';error=$null});Write-Output "PASS $Name"}catch{$cases.Add([pscustomobject]@{name=$Name;status='failed';error=$_.Exception.Message});Write-Output "FAIL $Name`: $($_.Exception.Message)"}}
Case 'six_phase_actual_transport_and_independent_read' {
    foreach($phase in @('FullCheck','PrepareSources','Pair','R14','Preflight','Readback')){
        $inputCase=New-Input ('phase-'+$phase) $phase
        $outer=Run-Entry $inputCase
        Check ($outer.status-ceq'passed'-and$outer.exit_code-eq0-and$outer.stdout.eof-and$outer.stderr.eof-and$outer.cleanup.completed) "$phase outer exit/EOF/cleanup missing"
        $obs=Load (Join-Path $inputCase.Binding.evidence_directory 'observation.json')
        Check ($obs.status-ceq'passed'-and$obs.phase-ceq$phase-and$obs.producer.process_id-eq$outer.child_pid-and$obs.capture.stage_native_exit_code-eq0-and$obs.capture.stdout_eof-and$obs.capture.stderr_eof-and$obs.capture.cleanup.completed) "$phase stage actual transport missing"
        Check ((Count-Entries $inputCase.Counter)-eq1) "$phase synthetic stage was retried"
        $before=Pin (Join-Path $inputCase.Binding.evidence_directory 'observation.json')
        $reader=Read-Entry $inputCase
        Check ($reader.status-ceq'passed'-and$reader.exit_code-eq0-and$reader.stdout.eof-and$reader.stderr.eof-and$reader.cleanup.completed) "$phase actual reader transport failed"
        $report=Load (Join-Path $inputCase.Root 'outer-reader\stdout.bin')
        Check ($report.status-ceq'passed'-and$report.reader_process_id-eq$reader.child_pid-and$report.producer_process_id-eq$outer.child_pid-and-not$report.root_native_exit_observed-and$report.run_id-ceq$obs.run_id) "$phase reader self-exit or identity drift"
        Check ((Pin $before.path).sha256-ceq$before.sha256) "$phase reader changed source observation"
    }
}
Case 'admission_rejections_before_stage_start' {
    foreach($mutation in @('runtime','source','argv','cwd','state','candidate','retry','unknown')){
        $inputCase=New-Input ('reject-'+$mutation)
        switch($mutation){
            'runtime' {$inputCase.Binding.runtime.sha256='0'*64}
            'source' {$inputCase.Binding.stage_source.sha256='0'*64}
            'argv' {$inputCase.Binding.argument_list[2]=$entry}
            'cwd' {$inputCase.Binding.working_directory=$runRoot}
            'state' {$inputCase.Binding.candidate_state='frozen_for_host'}
            'candidate' {$inputCase.Binding.candidate_sha='4b37f344d5af988ce9b2f7610df98387a49cd2d0'}
            'retry' {$inputCase.Binding.automatic_retry_count=1}
            'unknown' {$inputCase.Binding|Add-Member extra $true}
        }
        $outer=Run-Entry $inputCase
        Check ($outer.status-ceq'failed'-and$outer.exit_code-eq1-and$outer.stdout.eof-and$outer.stderr.eof) "$mutation admission accepted"
        Check ((Count-Entries $inputCase.Counter)-eq0-and-not[IO.Directory]::Exists($inputCase.Binding.evidence_directory)) "$mutation admission started/reserved stage"
    }
}
Case 'nonzero_missing_oversize_and_timeout_fail_closed' {
    foreach($mode in @('nonzero','missing','oversize','timeout')){
        $inputCase=New-Input ('failed-'+$mode) 'Pair' $mode
        if($mode-ceq'oversize'){$inputCase.Binding.capture_limits.capture_limit_bytes=1024}
        if($mode-ceq'timeout'){$inputCase.Binding.capture_limits.timeout_milliseconds=2500}
        $outer=Run-Entry $inputCase
        $obs=Load (Join-Path $inputCase.Binding.evidence_directory 'observation.json')
        Check ($outer.exit_code-eq1-and$obs.status-ceq'failed'-and(Count-Entries $inputCase.Counter)-eq1) "$mode failure was hidden or retried"
        if($mode-ceq'nonzero'){Check ($obs.capture.stage_native_exit_code-eq31-and$obs.capture.stdout_eof-and$obs.capture.stderr_eof) 'native stage exit overwritten'}
        if($mode-ceq'timeout'){Check ($obs.capture.cleanup.completed-and$obs.capture.status-ceq'failed') 'timeout cleanup not independently retained'}
        $reader=Read-Entry $inputCase
        Check ($reader.exit_code-eq1-and$reader.status-ceq'failed') "$mode reader promoted failed stage"
    }
}
Case 'repeated_stage_evidence_rejected_no_retry' {
    $inputCase=New-Input 'repeat';$first=Run-Entry $inputCase
    $obs=Pin (Join-Path $inputCase.Binding.evidence_directory 'observation.json')
    $second=Run-Entry $inputCase 'repeat'
    Check ($first.status-ceq'passed'-and$second.exit_code-eq1-and(Count-Entries $inputCase.Counter)-eq1) 'repeated stage performed side effects'
    Check ((Pin $obs.path).sha256-ceq$obs.sha256) 'repeat overwrote original observation'
}
Case 'reader_detects_raw_artifact_and_summary_tamper' {
    foreach($kind in @('raw','artifact','summary')){
        $inputCase=New-Input ('tamper-'+$kind);$outer=Run-Entry $inputCase;Check ($outer.status-ceq'passed') 'tamper setup failed'
        $obsPath=Join-Path $inputCase.Binding.evidence_directory 'observation.json'
        switch($kind){
            'raw' {[IO.File]::AppendAllText((Join-Path $inputCase.Binding.evidence_directory 'capture\stdout.bin'),'tampered')}
            'artifact' {[IO.File]::AppendAllText($inputCase.Artifact,'tampered')}
            'summary' {$obs=Load $obsPath;$obs.capture.stage_native_exit_code=9;Save $obsPath $obs}
        }
        $reader=Read-Entry $inputCase
        Check ($reader.exit_code-eq1-and$reader.status-ceq'failed'-and$reader.stdout.eof-and$reader.stderr.eof-and$reader.cleanup.completed) "$kind tamper passed reader"
    }
}
Case 'duplicate_json_property_rejected' {
    $inputCase=New-Input 'duplicate'
    $text=[IO.File]::ReadAllText($inputCase.BindingPath);$text=$text -replace '"schema":','"schema":"c1b-candidate-host-stage-bindings/v1","SCHEMA":'
    [IO.File]::WriteAllText($inputCase.BindingPath,$text,$utf8)
    $argv=@('-NoProfile','-File',$entry,'-Operation','Run','-BindingsPath',$inputCase.BindingPath,'-ExpectedBindingsSha256',(Pin $inputCase.BindingPath).sha256)
    $outer=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $inputCase.Root -EvidenceDirectory (Join-Path $inputCase.Root 'outer-duplicate') -TimeoutMilliseconds 15000
    Check ($outer.exit_code-eq1-and(Count-Entries $inputCase.Counter)-eq0) 'duplicate JSON admitted'
}
Case 'reparse_source_rejected' {
    $inputCase=New-Input 'reparse';$link=Join-Path $inputCase.Root 'worker-link.ps1'
    try{[void](New-Item -ItemType SymbolicLink -Path $link -Target $worker -ErrorAction Stop)}catch{throw 'Symbolic-link privilege required; this test cannot be skipped.'}
    $inputCase.Binding.stage_source.path=$link;$inputCase.Binding.argument_list[2]=$link;$inputCase.Binding.argument_list_sha256=Get-C1bHostStageArgvHash $inputCase.Binding.argument_list
    $outer=Run-Entry $inputCase
    Check ($outer.exit_code-eq1-and(Count-Entries $inputCase.Counter)-eq0) 'reparse source admitted'
}
Case 'held_native_parent_and_leaf_deny_swap_write_then_release' {
    $inputCase=New-Input 'held-guard' 'Pair' 'guard-probe';$sourceDir=Join-Path $inputCase.Root 'source-only';[void][IO.Directory]::CreateDirectory($sourceDir)
    $sourcePath=Join-Path $sourceDir 'worker.ps1';[IO.File]::WriteAllBytes($sourcePath,[IO.File]::ReadAllBytes($worker))
    $inputCase.Binding.stage_source=Pin $sourcePath;$inputCase.Binding.argument_list[2]=$sourcePath;$inputCase.Binding.argument_list_sha256=Get-C1bHostStageArgvHash $inputCase.Binding.argument_list
    $outer=Run-Entry $inputCase;Check ($outer.status-ceq'passed') 'held guard probe did not complete'
    $probe=Load $inputCase.Artifact;Check ($probe.directory_denied-and$probe.write_denied) 'native held parent/file did not deny mutation while child ran'
    $stream=[IO.File]::Open($sourcePath,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose()
    [IO.Directory]::Move($sourceDir,$sourceDir+'-after');[IO.Directory]::Move($sourceDir+'-after',$sourceDir)
    Check ([IO.File]::Exists($sourcePath)) 'producer leaked native directory/leaf guards after completion'
}
Case 'reader_rejects_borrowed_capture_reservation_and_numeric_strings' {
    $borrow=New-Input 'borrow-origin';$null=Run-Entry $borrow;$borrowObs=Load (Join-Path $borrow.Binding.evidence_directory 'observation.json')
    foreach($kind in @('borrowed','reservation','integer')){
        $inputCase=New-Input ('edge-'+$kind);$null=Run-Entry $inputCase;$obsPath=Join-Path $inputCase.Binding.evidence_directory 'observation.json'
        if($kind-ceq'borrowed'){$obs=Load $obsPath;$obs.capture=$borrowObs.capture;Save $obsPath $obs}
        elseif($kind-ceq'reservation'){$reservationPath=Join-Path $inputCase.Binding.evidence_directory 'reservation.json';$reservation=Load $reservationPath;$reservation.run_id='0'*32;Save $reservationPath $reservation}
        else{
            $obs=Load $obsPath;$capturePath=$obs.capture.execution_pin.path;$raw=Load $capturePath;$raw.start_count='1';Save $capturePath $raw;$obs.capture.execution_pin=Pin $capturePath;Save $obsPath $obs
        }
        $reader=Read-Entry $inputCase;Check ($reader.exit_code-eq1-and$reader.status-ceq'failed') "$kind forgery passed reader"
    }
}
Case 'explicit_stage_environment_pin' {
    $inputCase=New-Input 'stage-env'
    $map=@{SYSTEMROOT=$env:SYSTEMROOT;TEMP=$inputCase.Root;TMP=$inputCase.Root;PATH=[IO.Path]::GetDirectoryName($pwsh);TL1_STAGE_MARKER='synthetic-marker'}
    $environment=Get-TL1C1bHostCaptureEnvironment -Environment $map -ClearEnvironment
    $inputCase.Binding.environment=[pscustomobject]@{clear_environment=$true;variables=[pscustomobject]$map;sha256=$environment.Record.sha256}
    $outer=Run-Entry $inputCase;Check ($outer.status-ceq'passed') 'explicit stage environment failed'
    $obs=Load (Join-Path $inputCase.Binding.evidence_directory 'observation.json')
    Check ($obs.capture.environment.mode-ceq'replace'-and$obs.capture.environment.sha256-ceq$environment.Record.sha256) 'stage environment raw binding drift'
    $reader=Read-Entry $inputCase;Check ($reader.status-ceq'passed') 'reader rejected actual explicit environment'
}
$passed=@($cases|Where-Object status -CEQ passed).Count;$failed=$cases.Count-$passed
$summary=[ordered]@{schema='c1b-candidate-host-stages-offline/v1';status=$(if($failed-eq0){'passed'}else{'failed'});runtime=$PSVersionTable.PSVersion.ToString();passed=$passed;failed=$failed;assertions=$script:assertions;cases=$cases.ToArray();real_git_call_count=0;real_gradle_buildonly_call_count=0;real_preflight_call_count=0;real_adb_device_call_count=0}
Save (Join-Path $runRoot 'summary.json') $summary
Write-Output "candidate-host-stages: $passed passed / $failed failed; $script:assertions assertions; evidence=$runRoot"
if($failed-gt0){exit 1};exit 0
