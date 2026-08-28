#Requires -Version 7.5
[CmdletBinding()]param()

$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$schema=Join-Path $root 'docs\contracts\tablet-layout-c1b-attempt-failure-v1.schema.json'
$library=Join-Path $root 'scripts\lib\tablet-layout-c1b.ps1'
. $library
$passed=0;$failed=0
function Test-Case([string]$Name,[scriptblock]$Body){
    try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}
}
function Assert-True([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Copy-Value($Value){return ($Value|ConvertTo-Json -Depth 30 -Compress)|ConvertFrom-Json -Depth 30 -DateKind String}
function Test-Schema($Value){return ($Value|ConvertTo-Json -Depth 30 -Compress)|Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue}
function Test-CrossBindings($Value){try{Assert-TL1C1bAttemptFailureCrossBindings $Value;return $true}catch{return $false}}
function Assert-ValidEvidence($Value,[string]$Message){
    Assert-True (Test-Schema $Value) "$Message (schema)"
    Assert-True (Test-CrossBindings $Value) "$Message (cross-bindings)"
}
function Assert-SchemaAndCrossRejected($Value,[string]$Message){
    Assert-True (-not(Test-Schema $Value)) "$Message (schema accepted)"
    Assert-True (-not(Test-CrossBindings $Value)) "$Message (cross-bindings accepted)"
}
function Assert-CrossRejected($Value,[string]$Message){
    Assert-True (Test-Schema $Value) "$Message (precondition schema rejected)"
    Assert-True (-not(Test-CrossBindings $Value)) "$Message (cross-bindings accepted)"
}

$hash='sha256:'+('a'*64)
$emptyStream=[pscustomobject][ordered]@{observed_bytes=0;captured_bytes=0;overflowed=$false;captured_sha256=$hash;strict_utf8=$true;classification='empty'}
$stderrStream=[pscustomobject][ordered]@{observed_bytes=64;captured_bytes=64;overflowed=$false;captured_sha256=('sha256:'+('b'*64));strict_utf8=$true;classification='fatal'}
$process=[pscustomobject][ordered]@{started=$true;exit_observed=$true;exit_code=86;stdout=$emptyStream;stderr=$stderrStream}
$attempt=[pscustomobject][ordered]@{ordinal=1;terminal_substage='server_process_exit_before_ready';listener_observed=$false;server_process=$process;status_clients=@();cleanup=[pscustomobject][ordered]@{status='completed';process_exit_observed=$true;streams_drained=$true;port_rebind_verified=$true}}
$valid=[pscustomobject][ordered]@{
    schema='tablet-layout-c1b-attempt-failure/v1';attempt_id='tl1-c1b-20260829t010203z-123456789abc';run_id=$null
    status='failed';reason_code='private_adb_startup_failed';failure_stage='private_adb_startup'
    expected_commit_sha=('c'*40);commit_verified=$true;recorded_at_utc='2026-08-29T01:02:03.1234567Z'
    runner_invocation_count=1;automatic_runner_retry_count=0
    pre_device_operations=[pscustomobject][ordered]@{build_completed=$true;artifact_checks_completed=$true;private_adb_guard_created=$false;device_discovery_count=0;install_count=0;t0_count=0;c1_count=0;c2_count=0;result_count=0;abort_count=0;capture_count=0}
    private_adb_startup=[pscustomobject][ordered]@{schema='tablet-layout-c1b-private-adb-startup-diagnostic/v1';outcome='failed';final_substage='server_process_exit_before_ready';server_attempt_count=1;attempts=@($attempt)}
    cleanup=[pscustomobject][ordered]@{provider_session='not_required';private_adb_startup='completed';private_adb_guard='not_acquired';artifact_guards='completed';build_environment='completed';device_lease='completed';overall='completed'}
    runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false
    editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false
}

Test-Case 'valid closed early-attempt record' {Assert-ValidEvidence $valid 'valid record rejected'}
Test-Case 'valid zero-attempt port selection timeout' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='port_selection_timeout'
    $x.private_adb_startup.server_attempt_count=0
    $x.private_adb_startup.attempts=@()
    $x.cleanup.private_adb_startup='not_acquired'
    Assert-ValidEvidence $x 'valid zero-attempt record rejected'
}
Test-Case 'valid failed host cleanup has failed component' {
    $x=Copy-Value $valid;$x.cleanup.device_lease='failed';$x.cleanup.overall='failed'
    Assert-ValidEvidence $x 'valid failed cleanup record rejected'
}
Test-Case 'valid bounded overflow diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].server_process.stderr.observed_bytes=5000
    $x.private_adb_startup.attempts[0].server_process.stderr.captured_bytes=4096
    $x.private_adb_startup.attempts[0].server_process.stderr.overflowed=$true
    Assert-ValidEvidence $x 'valid overflow diagnostic rejected'
}
Test-Case 'server-status job-membership category accepted' {
    $x=Copy-Value $valid
    $client=[pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_job-membership';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    }
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@($client)
    Assert-ValidEvidence $x 'job-membership diagnostic rejected'
}
Test-Case 'valid failed status-client cleanup aggregates startup and overall failed' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_cleanup';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='failed';endpoint_contained='unverified'}
    })
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-ValidEvidence $x 'valid failed status-client cleanup rejected'
}
Test-Case 'valid server exit during status carries client diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_process_exit_during_status'
    $x.private_adb_startup.attempts[0].terminal_substage='server_process_exit_during_status'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_process-exit';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-ValidEvidence $x 'valid server exit during status rejected'
}
Test-Case 'valid status contract failure has listener without failed client diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_contract'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_contract'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    Assert-ValidEvidence $x 'valid status contract failure rejected'
}
Test-Case 'valid server cleanup override binds failed last attempt cleanup' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_attempt_cleanup'
    $x.private_adb_startup.attempts[0].cleanup.status='failed'
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-ValidEvidence $x 'valid server cleanup override rejected'
}
Test-Case 'valid null server process requires failed cleanup' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].server_process=$null
    $x.private_adb_startup.attempts[0].cleanup.status='failed'
    $x.private_adb_startup.attempts[0].cleanup.process_exit_observed=$false
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-ValidEvidence $x 'valid null server diagnostic rejected'
}
Test-Case 'valid null status-client process requires failed cleanup' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_cleanup';process=$null
        cleanup=[pscustomobject][ordered]@{status='failed';endpoint_contained='unverified'}
    })
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-ValidEvidence $x 'valid null status-client diagnostic rejected'
}
Test-Case 'top-level extra field rejected' {$x=Copy-Value $valid;$x|Add-Member -NotePropertyName raw_error -NotePropertyValue 'secret';Assert-True (-not(Test-Schema $x)) 'extra top-level field accepted'}
Test-Case 'raw diagnostic excerpt rejected' {$x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.stderr|Add-Member -NotePropertyName excerpt -NotePropertyValue 'C:\synthetic-private\secret.txt';Assert-True (-not(Test-Schema $x)) 'raw diagnostic excerpt accepted'}
Test-Case 'unknown stream classification rejected' {$x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.stderr.classification='raw_text';Assert-True (-not(Test-Schema $x)) 'unknown classification accepted'}
Test-Case 'unknown startup substage rejected' {$x=Copy-Value $valid;$x.private_adb_startup.final_substage='retry_forever';Assert-True (-not(Test-Schema $x)) 'unknown substage accepted'}
Test-Case 'unknown status client category rejected' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_job_membership';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-True (-not(Test-Schema $x)) 'unknown status client category accepted'
}
Test-Case 'run id promotion cannot be forged' {$x=Copy-Value $valid;$x.run_id=$x.attempt_id;Assert-True (-not(Test-Schema $x)) 'non-null run_id accepted'}
Test-Case 'automatic runner retry cannot be claimed' {$x=Copy-Value $valid;$x.automatic_runner_retry_count=1;Assert-True (-not(Test-Schema $x)) 'retry count accepted'}
Test-Case 'device operation cannot be claimed' {$x=Copy-Value $valid;$x.pre_device_operations.install_count=1;Assert-True (-not(Test-Schema $x)) 'install count accepted'}
Test-Case 'runtime claim cannot be promoted' {$x=Copy-Value $valid;$x.runtime_origin_verified=$true;Assert-True (-not(Test-Schema $x)) 'runtime claim accepted'}
Test-Case 'cleanup vocabulary is closed' {$x=Copy-Value $valid;$x.cleanup.private_adb_startup='server_cleanup_verified';Assert-True (-not(Test-Schema $x)) 'misleading cleanup state accepted'}
Test-Case 'attempt count must equal attempt list length' {
    $x=Copy-Value $valid;$x.private_adb_startup.server_attempt_count=2
    Assert-CrossRejected $x 'count/list mismatch'
}
Test-Case 'zero attempts require port selection timeout' {
    $x=Copy-Value $valid;$x.private_adb_startup.server_attempt_count=0;$x.private_adb_startup.attempts=@()
    Assert-SchemaAndCrossRejected $x 'zero attempt wrong final substage'
}
Test-Case 'port selection timeout requires zero attempts' {
    $x=Copy-Value $valid;$x.private_adb_startup.final_substage='port_selection_timeout'
    Assert-SchemaAndCrossRejected $x 'port selection timeout with attempt'
}
Test-Case 'server attempt ordinals must be continuous' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].ordinal=2
    Assert-CrossRejected $x 'server attempt ordinal gap'
}
Test-Case 'status client ordinals must be continuous' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=2;terminal_substage='server-status_process-exit';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-CrossRejected $x 'status client ordinal gap'
}
Test-Case 'top final stage must bind last server attempt stage' {
    $x=Copy-Value $valid;$x.private_adb_startup.final_substage='startup_timeout'
    Assert-CrossRejected $x 'top/last attempt stage mismatch'
}
Test-Case 'before-ready attempt cannot carry status client diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_process-exit';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-SchemaAndCrossRejected $x 'before-ready attempt with status client'
}
Test-Case 'status client diagnostic requires observed listener' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_process-exit';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-SchemaAndCrossRejected $x 'status client without listener'
}
Test-Case 'status client terminal stage requires diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    Assert-SchemaAndCrossRejected $x 'status client stage without diagnostic'
}
Test-Case 'status client diagnostic is confined to last server attempt' {
    $x=Copy-Value $valid
    $first=Copy-Value $x.private_adb_startup.attempts[0]
    $first.terminal_substage='server_status_client';$first.listener_observed=$true
    $first.status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_process-exit';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    $last=Copy-Value $x.private_adb_startup.attempts[0]
    $last.ordinal=2;$last.terminal_substage='startup_timeout'
    $x.private_adb_startup.final_substage='startup_timeout'
    $x.private_adb_startup.server_attempt_count=2
    $x.private_adb_startup.attempts=@($first,$last)
    Assert-CrossRejected $x 'non-final attempt carried status client diagnostic'
}
Test-Case 'unstarted process cannot have observed exit' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.started=$false
    Assert-SchemaAndCrossRejected $x 'unstarted process with exit'
}
Test-Case 'unobserved exit cannot have exit code' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.exit_observed=$false
    Assert-SchemaAndCrossRejected $x 'unobserved exit with code'
}
Test-Case 'observed exit requires exit code' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.exit_code=$null
    Assert-SchemaAndCrossRejected $x 'observed exit without code'
}
Test-Case 'captured bytes cannot exceed observed bytes' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.stderr.captured_bytes=65
    Assert-CrossRejected $x 'captured bytes exceed observed bytes'
}
Test-Case 'non-overflow stream captures all observed bytes' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].server_process.stderr.captured_bytes=63
    Assert-CrossRejected $x 'non-overflow partial capture'
}
Test-Case 'overflow stream must observe more than captured bytes' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].server_process.stderr.observed_bytes=5000
    $x.private_adb_startup.attempts[0].server_process.stderr.captured_bytes=5000
    $x.private_adb_startup.attempts[0].server_process.stderr.overflowed=$true
    Assert-CrossRejected $x 'contradictory overflow tuple'
}
Test-Case 'completed attempt cleanup requires drained streams' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].cleanup.streams_drained=$false
    Assert-SchemaAndCrossRejected $x 'completed cleanup with undrained streams'
}
Test-Case 'completed attempt cleanup requires reusable port' {
    $x=Copy-Value $valid;$x.private_adb_startup.attempts[0].cleanup.port_rebind_verified=$false
    Assert-SchemaAndCrossRejected $x 'completed cleanup without port rebind'
}
Test-Case 'completed attempt cleanup requires started process exit' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].server_process.exit_observed=$false
    $x.private_adb_startup.attempts[0].server_process.exit_code=$null
    $x.private_adb_startup.attempts[0].cleanup.process_exit_observed=$false
    Assert-SchemaAndCrossRejected $x 'completed cleanup before process exit'
}
Test-Case 'attempt cleanup exit observation binds server process' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].cleanup.status='failed'
    $x.private_adb_startup.attempts[0].cleanup.process_exit_observed=$false
    $x.private_adb_startup.attempts[0].cleanup.streams_drained=$false
    $x.private_adb_startup.attempts[0].cleanup.port_rebind_verified=$false
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-CrossRejected $x 'cleanup/server exit mismatch'
}
Test-Case 'completed server attempt cleanup rejects null process diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].server_process=$null
    $x.private_adb_startup.attempts[0].cleanup.process_exit_observed=$false
    Assert-SchemaAndCrossRejected $x 'completed server cleanup with null process'
}
Test-Case 'server cleanup override rejects completed last attempt cleanup' {
    $x=Copy-Value $valid;$x.private_adb_startup.final_substage='server_attempt_cleanup'
    Assert-SchemaAndCrossRejected $x 'cleanup override with completed cleanup'
}
Test-Case 'server cleanup override rejects recursive terminal stage' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_attempt_cleanup'
    $x.private_adb_startup.attempts[0].terminal_substage='server_attempt_cleanup'
    $x.private_adb_startup.attempts[0].cleanup.status='failed'
    $x.cleanup.private_adb_startup='failed';$x.cleanup.overall='failed'
    Assert-SchemaAndCrossRejected $x 'recursive cleanup override terminal'
}
Test-Case 'failed server attempt cleanup cannot aggregate startup completed' {
    $x=Copy-Value $valid
    $x.private_adb_startup.attempts[0].cleanup.status='failed'
    Assert-CrossRejected $x 'failed server attempt cleanup hidden by startup completed'
}
Test-Case 'failed status-client cleanup cannot aggregate startup completed' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_cleanup';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='failed';endpoint_contained='unverified'}
    })
    Assert-CrossRejected $x 'failed status-client cleanup hidden by startup completed'
}
Test-Case 'completed status-client cleanup rejects unverified endpoint containment' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_cleanup';process=Copy-Value $process
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='unverified'}
    })
    Assert-SchemaAndCrossRejected $x 'completed status-client cleanup with unverified endpoint'
}
Test-Case 'completed status-client cleanup rejects null process diagnostic' {
    $x=Copy-Value $valid
    $x.private_adb_startup.final_substage='server_status_client'
    $x.private_adb_startup.attempts[0].terminal_substage='server_status_client'
    $x.private_adb_startup.attempts[0].listener_observed=$true
    $x.private_adb_startup.attempts[0].status_clients=@([pscustomobject][ordered]@{
        ordinal=1;terminal_substage='server-status_cleanup';process=$null
        cleanup=[pscustomobject][ordered]@{status='completed';endpoint_contained='reusable'}
    })
    Assert-SchemaAndCrossRejected $x 'completed status-client cleanup with null process'
}
Test-Case 'completed host cleanup rejects failed component' {
    $x=Copy-Value $valid;$x.cleanup.private_adb_startup='failed'
    Assert-SchemaAndCrossRejected $x 'completed host cleanup with failed component'
}
Test-Case 'failed host cleanup requires failed component' {
    $x=Copy-Value $valid;$x.cleanup.overall='failed'
    Assert-SchemaAndCrossRejected $x 'failed host cleanup without failed component'
}
Test-Case 'unverified host cleanup cannot hide fully completed components' {
    $x=Copy-Value $valid;$x.cleanup.overall='unverified'
    Assert-CrossRejected $x 'unverified overall with completed components'
}

"tablet-layout-c1b attempt failure schema offline: $passed passed, $failed failed"
if($failed-ne0){exit 1}
