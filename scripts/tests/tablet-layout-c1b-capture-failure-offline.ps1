#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1a.ps1')
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-observation-v2-validator.ps1')
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b.ps1')
$runner=Join-Path $RepoRoot 'scripts/run-tablet-layout-c1b.ps1'
$parseTokens=$null;$parseErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$parseTokens,[ref]$parseErrors)
if($parseErrors.Count-ne0){throw 'runner parse failed'}
# Execute the actual runner's read/copy/write functions, never its device entrypoint.
foreach($name in @('Read-C1bControl','Set-C1bAbortExpectedSnapshot','Write-C1bFailureEvidence')){
    $matches=@($runnerAst.FindAll({param($node) $node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true))
    if($matches.Count-ne1){throw 'runner function extraction is not unique'}
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
$testRoot=Join-Path $RepoRoot ('.checks/c1b-capture-diagnostics/cases-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$passed=0;$failed=0;$assertions=0
function Check([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Copy-Value($Value){return ($Value|ConvertTo-Json -Depth 12 -Compress)|ConvertFrom-Json -Depth 12 -DateKind String}
function Reject([scriptblock]$Body){$message=$null;try{&$Body}catch{$message=$_.Exception.Message};Check ($null-ne$message) 'invalid value accepted';return $message}
function New-Control([string]$Phase='c1',[string]$Reason='capture_c1_probe_illegal_state'){
    $tokens=[object[]]@();if($Phase-ceq'c2'){$tokens=[object[]]@('c1')}
    return [ordered]@{schema='tablet-c1b-control/v1';ok=$false;run_id='tl1-c1b-diagnostic-test';generation=[long]7;state='failed';next='none';reason_code=$Reason;in_flight_token=$null
        c1_requests_accepted=[long]1;c2_requests_accepted=[long]$(if($Phase-ceq'c2'){1}else{0});committed_tokens=$tokens;recapture_count=[long]0
        expected_title_hash=$script:TL1C1bExpectedTitleHash;producer_commit_sha=('a'*40);producer_artifact_sha256=('sha256:'+'b'*64)
        provider=[ordered]@{authority=$script:TL1C1bAuthority;protocol_version='1';package_name=$script:TL1C1bPackageName;version_name='0.1.0-c1b-read-only';version_code=[long]1
            embedded_git_head=('a'*40);build_challenge=('c1b-'+'c'*32);a11y_service_ready=$true}}
}
function Parse-Control($Value){return ConvertFrom-TL1C1bControl ($Value|ConvertTo-Json -Depth 8 -Compress) 'tl1-c1b-diagnostic-test' ('a'*40) ('sha256:'+'b'*64) ('c1b-'+'c'*32)}
function Reset-Runner([string]$Name,[string]$Phase='c1'){
    $script:runId='tl1-c1b-diagnostic-test';$script:ExpectedCommitSha='a'*40;$script:expectedArtifactSha='sha256:'+'b'*64;$script:buildChallenge='c1b-'+'c'*32
    $script:capturePhase=$Phase;$script:providerFailure=$null;$script:generation=[long]7
    $script:AdbPath='fake-offline';$script:serial='FAKE123';$script:adbEnvironment=@{};$script:adbServerGuard=$null
    $script:controlRaw=[Collections.Generic.List[string]]::new();$script:statusReadCount=0
    $script:fakeCalls=[Collections.Generic.List[string]]::new();$script:fakeResponses=[Collections.Generic.Queue[string]]::new()
    $script:abortExpectedGeneration=[long]7;$script:abortExpectedC1Count=0;$script:abortExpectedC2Count=0;$script:abortExpectedCommitted=[string[]]@()
    $script:sessionStarted=$true;$script:sessionConsumed=$false;$script:abortAttempted=$false;$script:abortSucceeded=$false
    $script:c1bDirectory=Join-Path $testRoot $Name;[void](New-Item -ItemType Directory -Path $script:c1bDirectory)
}
function Enqueue-Control($Value){$script:fakeResponses.Enqueue(($Value|ConvertTo-Json -Depth 8 -Compress))}
function Invoke-TL1C1bAdb {
    param($AdbPath,$Serial,$Name,$Value,$TimeoutSec,$ProcessEnvironment,[switch]$ClearEnvironment,$PrivateAdbServerGuard)
    $script:fakeCalls.Add($Name)
    if($script:fakeResponses.Count-eq0){throw 'fake transport called without a response'}
    return [pscustomobject]@{Text=$script:fakeResponses.Dequeue()}
}
function Read-Failure {
    Write-C1bFailureEvidence 'c1b_runner_failed'
    $path=Join-Path $script:c1bDirectory 'tablet-layout-c1b-failure.json'
    $value=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true)))
    Assert-TL1C1bFailureEvidence $value
    return $value
}
function Finish-Abort($Control){
    $script:abortAttempted=$true;Enqueue-Control $Control
    try{$abort=Read-C1bControl content_abort fake;Assert-TL1C1bAbortTerminalControl $abort $script:abortExpectedGeneration $script:abortExpectedC1Count $script:abortExpectedC2Count $script:abortExpectedCommitted;$script:abortSucceeded=$true}
    catch{$script:abortSucceeded=$false}
}
Test-Case closed_reason_matrix {
    Check ($script:TL1C1bCaptureReasonDetails.Count-eq50) 'reason set changed'
    foreach($phase in @('c1','c2')){foreach($stage in @('binding','display','probe','frame_validation','unknown')){foreach($category in @('security','illegal_argument','illegal_state','unsupported','unknown')){
        $reason="capture_${phase}_${stage}_${category}";$control=Parse-Control (New-Control $phase $reason)
        $value=ConvertTo-TL1C1bCaptureFailure $control $phase 7
        Check ($value.phase-ceq$phase-and$value.stage-ceq$stage-and$value.category-ceq$category-and$value.reason_code-ceq$reason) 'closed reason not preserved'
    }}}
}
Test-Case legacy_reason_remains_unclassified {
    foreach($phase in @('c1','c2')){foreach($suffix in @('failed','timeout')){
        $value=ConvertTo-TL1C1bCaptureFailure (Parse-Control (New-Control $phase "capture_${phase}_${suffix}")) $phase 7
        Check ($null-eq$value.stage-and$null-eq$value.category) 'legacy reason acquired invented classification'
    }}
}
Test-Case new_reason_requires_failed_exact_prefix {
    foreach($phase in @('c1','c2')){foreach($mutation in @('state','generation','c1','c2','committed','in_flight','recapture','case')){
        $value=New-Control $phase "capture_${phase}_display_security"
        switch($mutation){state{$value.state='ready_c2'};generation{$value.generation=0};c1{$value.c1_requests_accepted=0};c2{$value.c2_requests_accepted=2};committed{$value.committed_tokens=@('c1','c2')};in_flight{$value.in_flight_token='c1'};recapture{$value.recapture_count=1};case{$value.reason_code=$value.reason_code.ToUpperInvariant()}}
        [void](Reject {$parsed=Parse-Control $value;ConvertTo-TL1C1bCaptureFailure $parsed $phase 7})
    }}
    [void](Reject {ConvertTo-TL1C1bCaptureFailure (Parse-Control (New-Control c2 capture_c2_probe_security)) c1 7})
}
Test-Case malicious_unknown_wire_reason_not_saved_or_echoed {
    foreach($reason in @('capture_c1_probe_new_class','capture_c1_probe_security SECRET-NONCE /private/chat',('capture_c1_probe_security'+[char]10+'PRIVATE-STACK'),'Capture_c1_probe_security')){
        Reset-Runner ('unknown-'+[guid]::NewGuid().ToString('N'));Enqueue-Control (New-Control c1 $reason)
        $message=Reject {Read-C1bControl content_c1 fake}
        Check ($null-eq$script:providerFailure-and$script:fakeCalls.Count-eq1) 'invalid control retained or retried'
        Check (-not$message.Contains($reason)-and$message-cnotmatch'SECRET|PRIVATE|/private') 'wire reason leaked into exception'
        $failure=Read-Failure;Check ($null-eq$failure.provider_failure) 'invalid control published'
    }
}
Test-Case provider_binding_and_generation_precede_diagnostic {
    foreach($mutation in @('commit','nonce_binding','run_id','generation')){
        Reset-Runner ('binding-'+$mutation);$value=New-Control
        switch($mutation){commit{$value.provider.embedded_git_head='d'*40};nonce_binding{$value.provider.build_challenge='c1b-'+'d'*32};run_id{$value.run_id='other-run'};generation{$value.generation=8}}
        Enqueue-Control $value;[void](Reject {Read-C1bControl content_c1 fake})
        Check ($null-eq$script:providerFailure) 'unbound control became diagnostic'
    }
}
Test-Case immediate_c1_failure_persisted_after_abort {
    Reset-Runner immediate-c1;$original=New-Control;Enqueue-Control $original
    [void](Reject {Read-C1bControl content_c1 fake})
    $original.reason_code='capture_c1_display_security';Finish-Abort $original
    $value=Read-Failure
    Check ($value.cleanup-ceq'completed'-and$value.provider_failure.reason_code-ceq'capture_c1_probe_illegal_state') 'abort replaced first reason'
    Check ($value.provider_failure.c1_requests_accepted-eq1-and$value.provider_failure.c2_requests_accepted-eq0-and$value.provider_failure.committed_tokens.Count-eq0) 'c1 tuple drift'
    Check (($script:fakeCalls-join',')-ceq'content_c1,content_abort') 'immediate failure retried capture or reached c2/result'
    Check (($value|ConvertTo-Json -Depth 8)-cnotmatch'FAKE123|build_challenge|embedded_git_head|stack|message|nonce|content://') 'private control fields retained'
}
Test-Case polled_c2_failure_persisted_after_abort {
    Reset-Runner polled-c2 c2;$capturing=New-Control c2;$capturing.ok=$true;$capturing.state='capturing_c2';$capturing.next='wait';$capturing.reason_code=$null;$capturing.in_flight_token='c2'
    Enqueue-Control $capturing;Enqueue-Control (New-Control c2 capture_c2_frame_validation_illegal_argument)
    [void](Reject {Wait-TL1C1bTerminalState -ExpectedState complete -Generation 7 -MaximumPolls 3 -PollMilliseconds 10 -Sleep {} -ReadStatus {Read-C1bControl content_status fake}})
    $abort=New-Control c2 capture_c2_probe_unknown;$abort.state='aborted';$abort.reason_code='session_aborted';Finish-Abort $abort
    $value=Read-Failure
    Check ($value.cleanup-ceq'completed'-and$value.provider_failure.reason_code-ceq'capture_c2_frame_validation_illegal_argument') 'polled c2 reason lost'
    Check ($value.provider_failure.c2_requests_accepted-eq1-and($value.provider_failure.committed_tokens-join',')-ceq'c1') 'c2 tuple drift'
    Check (($script:fakeCalls-join',')-ceq'content_status,content_status,content_abort') 'poll failure retried or exceeded failing poll'
}
Test-Case malformed_abort_preserves_original_failure {
    Reset-Runner bad-abort;Enqueue-Control (New-Control c1 capture_c1_binding_security);[void](Reject {Read-C1bControl content_c1 fake})
    Finish-Abort (New-Control c1 'SECRET-ABORT-STACK')
    $value=Read-Failure
    Check ($value.cleanup-ceq'failed'-and$value.provider_failure.reason_code-ceq'capture_c1_binding_security') 'malformed abort overwrote diagnostic or passed cleanup'
}
Test-Case failure_validator_rejects_shape_types_and_claims {
    Reset-Runner validator;Enqueue-Control (New-Control);[void](Reject {Read-C1bControl content_c1 fake});$valid=Read-Failure
    foreach($mutation in @('extra','schema','run_id','reason','claim','bool_type','missing','phase','phase_case','stage','category','category_null','reason_unknown','generation_type','generation_zero','c1_type','c1_count','c2_count','tokens_type','tokens_value','recapture','diagnostic_extra')){
        $value=Copy-Value $valid
        switch($mutation){extra{$value|Add-Member bad 1};schema{$value.schema='tablet-layout-c1b-failure/v1'};run_id{$value.run_id='/private/path'};reason{$value.reason_code='other'};claim{$value.runtime_evidence=$true};bool_type{$value.execution_grant='false'};missing{$value.PSObject.Properties.Remove('cleanup')}
            phase{$value.provider_failure.phase='c2'};phase_case{$value.provider_failure.phase='C1'};stage{$value.provider_failure.stage='SECRET-STACK'};category{$value.provider_failure.category='security'};category_null{$value.provider_failure.category=$null};reason_unknown{$value.provider_failure.reason_code='arbitrary'};generation_type{$value.provider_failure.generation='7'};generation_zero{$value.provider_failure.generation=[long]0};c1_type{$value.provider_failure.c1_requests_accepted=[int]1};c1_count{$value.provider_failure.c1_requests_accepted=[long]0};c2_count{$value.provider_failure.c2_requests_accepted=[long]1};tokens_type{$value.provider_failure.committed_tokens='c1'};tokens_value{$value.provider_failure.committed_tokens=@('SECRET-NODE')};recapture{$value.provider_failure.recapture_count=[long]1};diagnostic_extra{$value.provider_failure|Add-Member message 'SECRET-STACK'}}
        [void](Reject {Assert-TL1C1bFailureEvidence $value})
    }
}
Test-Case general_failure_has_explicit_null_diagnostic {
    Reset-Runner no-diagnostic;$value=Read-Failure
    Check ($value.schema-ceq'tablet-layout-c1b-failure/v2'-and$null-eq$value.provider_failure) 'generic failure has invented provider diagnostic'
}
Test-Case unvalidated_status_never_echoes_wire_fields {
    $value=New-Control;$value.state='SECRET-STATE';$value.reason_code='PRIVATE-STACK'
    $message=Reject {Wait-TL1C1bTerminalState -ExpectedState ready_c2 -Generation 7 -MaximumPolls 1 -PollMilliseconds 10 -Sleep {} -ReadStatus {[pscustomobject]$value}}
    Check ($message-cnotmatch'SECRET|PRIVATE') 'raw terminal fields leaked'
}
Test-Case published_failure_is_not_overwritten {
    Reset-Runner preserve-file;Enqueue-Control (New-Control);[void](Reject {Read-C1bControl content_c1 fake});[void](Read-Failure)
    $path=Join-Path $script:c1bDirectory 'tablet-layout-c1b-failure.json';$before=[IO.File]::ReadAllText($path)
    $script:providerFailure=$null;Write-C1bFailureEvidence 'c1b_runner_failed'
    Check ([IO.File]::ReadAllText($path)-ceq$before) 'published failure overwritten'
}
Test-Case writer_validates_diagnostic_before_publish {
    Reset-Runner reject-write;Enqueue-Control (New-Control);[void](Reject {Read-C1bControl content_c1 fake})
    $script:providerFailure.stage='SECRET-STACK';[void](Reject {Write-C1bFailureEvidence 'c1b_runner_failed'})
    Check (-not(Test-Path -LiteralPath (Join-Path $script:c1bDirectory 'tablet-layout-c1b-failure.json'))) 'malformed diagnostic published'
}
[pscustomobject]@{schema='tablet-layout-c1b-capture-failure-offline/v1';passed=$passed;failed=$failed;assertions=$assertions;real_adb_call_count=0;runner_entrypoint_executed=$false}|ConvertTo-Json -Compress
if($failed-ne0){exit 1}
