#Requires -Version 7.5
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$driver=Join-Path $repoRoot 'scripts/run-local-testbench.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($driver,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Driver parse failed'}
foreach($name in @('Assert-Bench','Assert-BenchRemaining','Assert-BenchToolOk','Assert-BenchForeground','Get-BenchSnapshot','Get-BenchCount','Read-BenchR5Receipts','Invoke-BenchR5Failure','Read-BenchIntentObservation','Assert-BenchR5FailureAudit','Read-BenchStaleCounter','Invoke-BenchStaleAllow','Assert-BenchStaleAudit')){
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing production function $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$routes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains("'r5-process-before'")},$true))
$audits=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('Assert-BenchR5Observations $audit')},$true))
if($routes.Count -ne 1 -or $audits.Count -ne 1){throw 'Mode branches ambiguous'}
$r5Body=[scriptblock]::Create($routes[0].Clauses[2].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$staleBody=[scriptblock]::Create($routes[0].Clauses[3].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$r5Audit=[scriptblock]::Create($audits[0].Clauses[2].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$staleAudit=[scriptblock]::Create($audits[0].Clauses[3].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$ready=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -ceq 'if($StaleAllowProbe){Wait-BenchHumanReady}'},$true))
if($ready.Count -ne 1){throw 'Stale readiness branch missing'}
$readyBody=[scriptblock]::Create($ready[0].Extent.Text)
$main=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
$statements=@($main[0].Body.Statements)
$argvStart=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text.StartsWith('$emulatorArguments=@(')})
$argvEnd=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text.StartsWith('$emulator=Start-BenchProcess $emulatorExe $emulatorArguments')})
if($argvStart.Count -ne 1 -or $argvEnd.Count -ne 1){throw 'Emulator argument block ambiguous'}
$argvBody=[scriptblock]::Create(($statements[$argvStart[0]..$argvEnd[0]].Extent.Text -join "`n"))
$script:passed=0
function Check([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Host "PASS $Name"}
function Expect-Rejected([scriptblock]$Body,[string]$Reason){$failure=$null;try{& $Body}catch{$failure=$_.Exception.Message};if($failure -cne $Reason){throw "Expected $Reason, got $failure"}}
function New-Observation([string]$Id,[string]$Poll){
    $note=[ordered]@{v=1;available=$true;audit_id=$Id;pid=1234;process_instance='12345678-1234-4234-8234-123456789abc';dispatch='returned';dispatch_entered_ms=100;dispatch_returned_ms=101;poll=$Poll;poll_start_ms=102;poll_end_ms=$(if($Poll -ceq 'timeout'){3102}else{300});checks=15}
    return ';r5_observation='+($note|ConvertTo-Json -Compress)
}
function New-Receipt([string]$Nonce){return [ordered]@{schema=1;source='test_target_onCreate';scenario='r5_no_display_finish';nonce=$Nonce;package='dev.magina.testtarget';component='dev.magina.testtarget.R5NoDisplayActivity';pid=4321;process_start_elapsed_realtime_ms=50;received_elapsed_realtime_ms=200}}
function Reset-Fixture([string]$Mode){
    $script:HumanAllowProbe=$false;$script:R5ObservationOnly=$false;$script:ImeProbe=$false;$script:R5FailureProbe=($Mode -ceq 'r5');$script:StaleAllowProbe=($Mode -ceq 'stale')
    $script:mode=$Mode;$script:RuntimeSeconds=900;$script:clock=[Diagnostics.Stopwatch]::StartNew();$script:output=Join-Path $repoRoot '.checks/negative-paths-20261113/virtual-output'
    $script:calls=[Collections.Generic.List[object]]::new();$script:phases=[Collections.Generic.List[string]]::new();$script:audit=@();$script:control=$null;$script:uri=$null
    $script:summary=@{routes_verified=@();callback_count_before='UNKNOWN';callback_count_after='UNKNOWN';confirmation_result='UNKNOWN';human_allow_verified=$false;r5_failure_verified=$false;stale_allow_verified=$false;stale_target_callback_zero_verified=$false}
    $script:options=@{BaselineApp='dev.magina.gateway';BaselineKnown=$true;BeforeRaw='R5_RECEIPTS_ABSENT';AfterRaw=$null;ReceiptMutation=$null;DuplicateReceipt=$false;HistoryChanged=$false;CounterBeforeMutation=$null;CounterAfterMutation=$null;StateMutation=$null;AuditMutation=$null;DuplicateAudit=$false;ExtraAudit=$false;GatewayAfter='1234';TargetAfter='4321';ResponseMutation=$null}
}
function Set-BenchPhase([string]$Phase){$script:phases.Add($Phase)}
function Wait-BenchHumanReady {$script:calls.Add([pscustomobject]@{Kind='ready';Name='ready';Arguments=@{}})}
function Write-BenchJson([string]$Name,$Value){if($Name -cne 'stale-control.json'){throw 'Unexpected local write'};$script:control=$Value}
function Invoke-BenchTool([string]$Tool,$Arguments,[string]$Name,[int]$TimeoutSeconds=25){
    $script:calls.Add([pscustomobject]@{Kind=$Tool;Name=$Name;Arguments=$Arguments;Timeout=$TimeoutSeconds})
    if($Tool -ceq 'foreground_app'){
        $app=if($script:mode -ceq 'r5'){$script:options.BaselineApp}else{'dev.magina.testtarget'}
        return [pscustomobject]@{ok=$true;ctx=[pscustomobject]@{app=$app;foreground_known=$script:options.BaselineKnown}}
    }
    if($Tool -ceq 'ui_snapshot'){
        if($Name -cne 'stale-before'){throw 'Unexpected post-HOME snapshot'}
        return [pscustomobject]@{ok=$true;ctx=[pscustomobject]@{app='dev.magina.testtarget';foreground_known=$true};data=[pscustomobject]@{truncated=$false;elements=@([pscustomobject]@{text='本地发送回调次数：0';source='a11y';role='text';ref='count-1'},[pscustomobject]@{text='发送（仅本地计数）';source='a11y';role='button';ref='node-1'})}}
    }
    if($Tool -ceq 'intent_send' -and $script:mode -ceq 'stale'){
        $script:audit+=,[pscustomobject]@{id='a-000001';tool='intent_send';result='OK';channel='intent';args=[pscustomobject]$Arguments;note=(New-Observation 'a-000001' 'hit')}
        return [pscustomobject]@{ok=$true;audit_id='a-000001'}
    }
    if($Tool -ceq 'intent_send' -and $script:mode -ceq 'r5'){
        if($Arguments.ContainsKey('component') -or $Arguments.action -cne 'android.intent.action.VIEW' -or $Arguments.package -cne 'dev.magina.testtarget'){throw 'Wrong negative intent shape'}
        $script:uri=$Arguments.uri
        $response=[pscustomobject]@{ok=$false;audit_id='a-000003';error=[pscustomobject]@{code='E_VERIFY_FAIL';channel='intent';retryable=$false}}
        $script:audit+=,[pscustomobject]@{id='a-000003';tool='intent_send';result='E_VERIFY_FAIL';channel='intent';args=[pscustomobject]$Arguments;note=(New-Observation 'a-000003' 'timeout')}
    }elseif($Tool -ceq 'ui_action' -and $script:mode -ceq 'stale'){
        if($Name -cne 'stale-allowed-click' -or $Arguments.action -cne 'click' -or $Arguments.ref -cne 'node-1' -or $TimeoutSeconds -le 60){throw 'Unexpected stale click'}
        $response=[pscustomobject]@{ok=$false;audit_id='a-000003';error=[pscustomobject]@{code='E_STALE_REF';channel='safety';retryable=$false}}
        $script:audit+=,[pscustomobject]@{id='a-000003';tool='ui_action';result='E_STALE_REF';channel='safety';args=[pscustomobject]$Arguments;note='confirmation=requested;confirmation=allowed;decided_via=overlay;context=rechecked'}
    }else{throw 'Unexpected gateway tool'}
    if($null -ne $script:options.ResponseMutation){& $script:options.ResponseMutation $response}
    return $response
}
function Invoke-BenchAdb([string[]]$Arguments,[string]$Name,[int]$TimeoutSeconds=30){
    $script:calls.Add([pscustomobject]@{Kind='adb-fixture';Name=$Name;Arguments=$Arguments})
    switch -CaseSensitive ($Name){
        'r5-failure-process-before' {return '1234'}
        'r5-failure-process-after' {return $script:options.GatewayAfter}
        'stale-gateway-process-before' {return '1234'}
        'stale-gateway-process-after' {return $script:options.GatewayAfter}
        'stale-target-process-before' {return '4321'}
        'stale-target-process-after' {return $script:options.TargetAfter}
        'r5-receipts-before' {return $script:options.BeforeRaw}
        'r5-receipts-after' {
            if($null -ne $script:options.AfterRaw){return $script:options.AfterRaw}
            $nonce=$script:uri.Substring('agent-testbench://r5/finish?nonce='.Length)
            $row=New-Receipt $nonce
            if($null -ne $script:options.ReceiptMutation){& $script:options.ReceiptMutation $row}
            $line=$row|ConvertTo-Json -Compress
            $prefix=if($script:options.BeforeRaw -ceq 'R5_RECEIPTS_ABSENT'){''}else{$script:options.BeforeRaw+"`n"}
            if($script:options.HistoryChanged){$prefix=$prefix.Replace('"received_elapsed_realtime_ms":200','"received_elapsed_realtime_ms":201')}
            if($script:options.DuplicateReceipt){$line+="`n"+$line}
            return $prefix+$line
        }
        'stale-counter-before' {
            $r=[ordered]@{schema=1;process_id=4321;activity_instance='12345678-1234-4234-8234-123456789abd';page_generation=3;page_generated_elapsed_realtime_ms=200;callback_count=0}
            if($null -ne $script:options.CounterBeforeMutation){& $script:options.CounterBeforeMutation $r}
            return $r|ConvertTo-Json -Compress
        }
        'stale-counter-after' {
            $r=[ordered]@{schema=1;process_id=4321;activity_instance='12345678-1234-4234-8234-123456789abd';page_generation=3;page_generated_elapsed_realtime_ms=200;callback_count=0}
            if($null -ne $script:options.CounterAfterMutation){& $script:options.CounterAfterMutation $r}
            return $r|ConvertTo-Json -Compress
        }
        'stale-device-clock' {return '1700000000'}
        'stale-confirm-state' {
            $state=[ordered]@{run_id=$script:control.run_id;confirm_id='abcdef123456';state='allowed';tool='ui_action';time='2023-11-14T22:13:21Z';leg='stale';nonce=$script:control.nonce;action='click';initial_package='dev.magina.testtarget';evidence_file='confirmation-abcdef123456.png';decided_via='overlay';card_visible=$true;capture_attempts=1}
            if($null -ne $script:options.StateMutation){& $script:options.StateMutation $state}
            return $state|ConvertTo-Json -Compress
        }
        {$_ -cin @('stale-control-upload','stale-control-install','stale-control-mode','stale-control-temp-remove')} {return ''}
        default {throw 'Unexpected native fixture call'}
    }
}
function Change-Observation($Entry,[string]$Key,$Value){$o=$Entry.note.Substring(';r5_observation='.Length)|ConvertFrom-Json -AsHashtable;$o[$Key]=$Value;$Entry.note=';r5_observation='+($o|ConvertTo-Json -Compress)}
function Run-Mode {
    if($script:mode -ceq 'r5'){. $r5Body}else{. $readyBody;. $staleBody}
    if($script:options.DuplicateAudit){$script:audit+=,$script:audit[-1]}
    if($script:options.ExtraAudit){$extra=$script:audit[-1]|ConvertTo-Json -Depth 20|ConvertFrom-Json;$extra.id='a-999999';$script:audit+=,$extra}
    if($null -ne $script:options.AuditMutation){& $script:options.AuditMutation $script:audit}
    $audit=$script:audit
    if($script:mode -ceq 'r5'){. $r5Audit;$script:lastInvocation=$r5Failure}else{. $staleAudit;$script:lastInvocation=$staleAllowed}
}
Check 'fresh absent receipts are a true empty array and one real-format receipt passes timeout semantics' {
    Reset-Fixture 'r5';$empty=Read-BenchR5Receipts 'r5-receipts-before'
    if($empty.Lines.Count -ne 0 -or $empty.Rows.Count -ne 0){throw 'Absent receipt became phantom element'}
    Run-Mode
    if(-not $summary.r5_failure_verified -or @($script:calls|Where-Object Kind -CEQ 'intent_send').Count -ne 1 -or
        @($script:calls|Where-Object Kind -CEQ 'ui_action').Count -ne 0){throw 'R5 failure did not remain one non-action dispatch'}
}
Check 'existing local receipt prefix is preserved with one new nonce' {
    Reset-Fixture 'r5';$script:options.BeforeRaw=(New-Receipt ('r5-'+('e'*32)))|ConvertTo-Json -Compress;Run-Mode
}
foreach($case in @(
    @('already target foreground',{ $script:options.BaselineApp='dev.magina.testtarget' },'r5_failure_baseline_not_gateway'),
    @('unknown baseline',{ $script:options.BaselineKnown=$false },'r5_failure_baseline_not_gateway'),
    @('malformed receipt',{ $script:options.AfterRaw='{broken' },'r5_local_receipt_invalid_json'),
    @('duplicate receipt',{ $script:options.DuplicateReceipt=$true },'r5_failure_receipt_increment_not_one'),
    @('changed receipt history',{ $script:options.BeforeRaw=(New-Receipt ('r5-'+('e'*32)))|ConvertTo-Json -Compress;$script:options.HistoryChanged=$true },'r5_failure_receipt_history_changed'),
    @('wrong nonce',{ $script:options.ReceiptMutation={param($r)$r.nonce='r5-'+('f'*32)} },'r5_failure_receipt_nonce_mismatch'),
    @('array source',{ $script:options.ReceiptMutation={param($r)$r.source=@('test_target_onCreate')} },'r5_local_receipt_invalid'),
    @('wrong component',{ $script:options.ReceiptMutation={param($r)$r.component='wrong.Activity'} },'r5_local_receipt_invalid'),
    @('receipt late',{ $script:options.ReceiptMutation={param($r)$r.received_elapsed_realtime_ms=5000} },'r5_failure_receipt_outside_call'),
    @('process changed',{ $script:options.GatewayAfter='1235' },'r5_failure_process_changed'),
    @('normal landing response',{ $script:options.ResponseMutation={param($r)$r.ok=$true} },'r5_failure_expected_error_not_observed'),
    @('no receiver response',{ $script:options.ResponseMutation={param($r)$r.error.code='E_NOT_FOUND'} },'r5_failure_expected_error_not_observed'),
    @('error code array',{ $script:options.ResponseMutation={param($r)$r.error.code=@('E_VERIFY_FAIL')} },'r5_failure_expected_error_not_observed'),
    @('error channel array',{ $script:options.ResponseMutation={param($r)$r.error.channel=@('intent')} },'r5_failure_expected_error_not_observed'),
    @('positive poll',{ $script:options.AuditMutation={param($a)Change-Observation $a[0] poll hit} },'intent_observation_invalid'),
    @('no a11y poll',{ $script:options.AuditMutation={param($a)Change-Observation $a[0] poll no_a11y} },'intent_observation_invalid'),
    @('wrong observation pid',{ $script:options.AuditMutation={param($a)Change-Observation $a[0] pid 1235} },'intent_observation_invalid'),
    @('duplicate audit',{ $script:options.DuplicateAudit=$true },'r5_failure_audit_missing_or_duplicate'),
    @('second intent audit',{ $script:options.ExtraAudit=$true },'r5_failure_audit_call_mismatch'),
    @('array audit URI',{ $script:options.AuditMutation={param($a)$a[0].args.uri=@($a[0].args.uri)} },'r5_failure_audit_call_mismatch')
)){
    Check ('R5 '+$case[0]) {Reset-Fixture 'r5';& $case[1];Expect-Rejected {Run-Mode} $case[2];if(@($script:calls|Where-Object Kind -CEQ 'intent_send').Count -gt 1){throw 'Negative dispatch retried'}}
}
Check 'Stale uses one route then one click, reads same live background instance and accepts original stale audit' {
    Reset-Fixture 'stale';Run-Mode
    if(-not $summary.stale_allow_verified -or -not $summary.stale_target_callback_zero_verified -or $summary.human_allow_verified -or
        $summary.callback_count_after -ne 0 -or $script:calls[0].Kind -cne 'ready' -or
        @($script:calls|Where-Object Kind -CEQ 'intent_send').Count -ne 1 -or @($script:calls|Where-Object Kind -CEQ 'ui_action').Count -ne 1 -or
        @($script:calls|Where-Object Kind -CEQ 'ui_snapshot').Count -ne 1 -or $script:control.Count -ne 8){throw 'Stale flow weakened or reset target'}
}
foreach($case in @(
    @('nonzero callback',{ $script:options.CounterAfterMutation={param($r)$r.callback_count=1} },'stale_counter_invalid_or_nonzero'),
    @('counter type array',{ $script:options.CounterAfterMutation={param($r)$r.callback_count=@(0)} },'stale_counter_invalid_or_nonzero'),
    @('activity replaced',{ $script:options.CounterAfterMutation={param($r)$r.activity_instance='12345678-1234-4234-8234-123456789abe'} },'stale_target_instance_changed'),
    @('page reset',{ $script:options.CounterAfterMutation={param($r)$r.page_generation=4} },'stale_target_instance_changed'),
    @('target died',{ $script:options.TargetAfter='' },'stale_process_changed'),
    @('gateway restarted',{ $script:options.GatewayAfter='1235' },'stale_process_changed'),
    @('old generation time',{ $script:options.CounterBeforeMutation={param($r)$r.page_generated_elapsed_realtime_ms=10};$script:options.CounterAfterMutation=$script:options.CounterBeforeMutation },'stale_counter_outside_route'),
    @('home failed',{ $script:options.ResponseMutation={param($r)$r.error.code='E_CHANNEL_DOWN'} },'stale_expected_error_not_observed'),
    @('card timeout',{ $script:options.ResponseMutation={param($r)$r.error.code='E_CONFIRM_TIMEOUT'} },'stale_expected_error_not_observed'),
    @('error code array',{ $script:options.ResponseMutation={param($r)$r.error.code=@('E_STALE_REF')} },'stale_expected_error_not_observed'),
    @('error channel array',{ $script:options.ResponseMutation={param($r)$r.error.channel=@('safety')} },'stale_expected_error_not_observed'),
    @('state wrong nonce',{ $script:options.StateMutation={param($s)$s.nonce='other-nonce'} },'stale_confirmation_binding_invalid'),
    @('state card invisible',{ $script:options.StateMutation={param($s)$s.card_visible=$false} },'stale_confirmation_binding_invalid'),
    @('state channel notification',{ $script:options.StateMutation={param($s)$s.decided_via='notification'} },'stale_confirmation_binding_invalid'),
    @('state expired time',{ $script:options.StateMutation={param($s)$s.time='2000-01-01T00:00:00Z'} },'stale_confirmation_time_invalid'),
    @('state confirm mismatch',{ $script:options.StateMutation={param($s)$s.evidence_file='confirmation-other.png'} },'stale_confirmation_binding_invalid'),
    @('duplicate click audit',{ $script:options.DuplicateAudit=$true },'stale_audit_missing_or_duplicate'),
    @('second click audit',{ $script:options.ExtraAudit=$true },'stale_audit_call_mismatch'),
    @('audit wrong ref',{ $script:options.AuditMutation={param($a)$a[1].args.ref='wrong-ref'} },'stale_audit_call_mismatch'),
    @('audit no context recheck',{ $script:options.AuditMutation={param($a)$a[1].note='confirmation=requested;confirmation=allowed;decided_via=overlay'} },'stale_audit_decision_not_proven'),
    @('route observation missing',{ $script:options.AuditMutation={param($a)$a[0].note=''} },'intent_observation_missing_or_duplicate'),
    @('route audit tool array',{ $script:options.AuditMutation={param($a)$a[0].tool=@('intent_send')} },'stale_route_audit_invalid'),
    @('route audit URI array',{ $script:options.AuditMutation={param($a)$a[0].args.uri=@('agent-testbench://target/stale-conversation')} },'stale_route_audit_invalid')
)){
    Check ('Stale '+$case[0]) {Reset-Fixture 'stale';& $case[1];Expect-Rejected {Run-Mode} $case[2];if(@($script:calls|Where-Object Kind -CEQ 'ui_action').Count -gt 1 -or @($script:calls|Where-Object Kind -CEQ 'intent_send').Count -gt 1){throw 'Stale flow retried or reset target'}}
}
function Start-BenchProcess([string]$File,[string[]]$Arguments){$script:observedArguments=$Arguments;return [pscustomobject]@{Process=$null}}
foreach($mode in @('default','r5','human','stale')){
    Check "actual emulator visibility $mode" {
        $HumanAllowProbe=($mode -ceq 'human');$StaleAllowProbe=($mode -ceq 'stale');$R5FailureProbe=($mode -ceq 'r5')
        $summary=@{avd_name='fixture-avd'};$ConsolePort=5580;$emulatorExe='fixture-emulator'
        . $argvBody
        $visible=$mode -cin @('human','stale')
        if(($script:observedArguments -ccontains '-no-window') -eq $visible -or -not($script:observedArguments -ccontains '-no-snapshot') -or
            -not($script:observedArguments -ccontains '5580,5581')){throw 'Emulator visibility or isolation changed'}
    }
}
foreach($flag in @('R5FailureProbe','StaleAllowProbe')){
    foreach($other in @('HumanAllowProbe','R5ObservationOnly','ImeProbe')){
        Check "CLI $flag conflicts with $other before native" {
            $scratch=Join-Path $repoRoot ('.checks/negative-paths-20261113/cli-'+[guid]::NewGuid().ToString('N'));$missing=Join-Path $scratch absent
            $arguments=@('-NoProfile','-File',$driver,'-SdkRoot',$missing,'-AvdManagerPath',$missing,'-JavaHome',$missing,'-ApkSignerPath',$missing,'-GatewayApk',$missing,'-TargetApk',$missing,'-ExpectedSourceSha',('a'*40),'-ExpectedGatewaySha256',('b'*64),'-ExpectedTargetSha256',('c'*64),'-OutputDirectory',$scratch,'-Run',('-'+$flag),('-'+$other))
            & (Get-Process -Id $PID).Path @arguments|Out-Null
            if($LASTEXITCODE -ne 1){throw 'Conflict did not fail'}
            $r=Get-Content (Join-Path $scratch summary.json) -Raw|ConvertFrom-Json
            if($r.failure_reason -cne 'negative_probe_mode_conflict' -or $r.production_execution_grant -cne $false -or @(Get-ChildItem $scratch -Filter '*.stdout.txt').Count -ne 0){throw 'Conflict entered native phase'}
        }
    }
}
Check 'CLI new modes conflict with each other before native' {
    $scratch=Join-Path $repoRoot ('.checks/negative-paths-20261113/cli-'+[guid]::NewGuid().ToString('N'));$missing=Join-Path $scratch absent
    $arguments=@('-NoProfile','-File',$driver,'-SdkRoot',$missing,'-AvdManagerPath',$missing,'-JavaHome',$missing,'-ApkSignerPath',$missing,'-GatewayApk',$missing,'-TargetApk',$missing,'-ExpectedSourceSha',('a'*40),'-ExpectedGatewaySha256',('b'*64),'-ExpectedTargetSha256',('c'*64),'-OutputDirectory',$scratch,'-Run','-R5FailureProbe','-StaleAllowProbe')
    & (Get-Process -Id $PID).Path @arguments|Out-Null
    if($LASTEXITCODE -ne 1){throw 'New-mode conflict did not fail'}
    $r=Get-Content (Join-Path $scratch summary.json) -Raw|ConvertFrom-Json
    if($r.failure_reason -cne 'negative_probe_mode_conflict' -or @(Get-ChildItem $scratch -Filter '*.stdout.txt').Count -ne 0){throw 'New modes reached native'}
}
Write-Host "local-testbench-negative-paths-offline: $script:passed passed; no SDK/ADB/network/runtime executed"
