#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $SourceRoot 'scripts/lib/tablet-layout-c1a.ps1')
. (Join-Path $SourceRoot 'scripts/lib/tablet-layout-observation-v2-validator.ps1')
. (Join-Path $SourceRoot 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $SourceRoot 'scripts/lib/tablet-layout-c1b.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'scripts/run-tablet-layout-c1b.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count-ne0){throw 'runner parse failed'}
$functions=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq'Write-C1bDiscoveryEvidence'},$true))
if($functions.Count-ne1){throw 'runner helper extraction is not unique'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$testRoot=Join-Path $SourceRoot ('.checks/c1b-discovery-evidence/cases-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$passed=0;$failed=0;$assertions=0
function Check([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Reject([scriptblock]$Body){$message=$null;try{&$Body}catch{$message=$_.Exception.Message};Check ($null-ne$message) 'invalid value accepted';return $message}
function New-Diagnostic {
    return [pscustomobject][ordered]@{schema='tablet-layout-device-discovery-diagnostic/v1';started_utc='2026-09-13T00:00:00.0000000Z';completed_utc='2026-09-13T00:00:01.0000000Z';actual_exit=0;device_count=0;device_states=[string[]]@();outcome='failed';failure_stage='device_count';client_failure_substage=$null;
        stdout_bytes=[Text.Encoding]::UTF8.GetBytes("List of devices attached`r`n`r`n");stdout_capture_status='complete';stdout_observed_byte_count=28;
        stderr_bytes=[byte[]]@();stderr_capture_status='complete';stderr_observed_byte_count=0;stderr_capture_basis='strict_utf8_reencoded_from_process_result'}
}
function Reset-Case([string]$Name){
    $script:RepoRoot=Join-Path $testRoot $Name
    [void](New-Item -ItemType Directory -Path (Join-Path $script:RepoRoot 'docs/runs/evidence'))
    $script:attemptId='c1b-discovery-test';$script:ExpectedCommitSha='a'*40;$script:adbServerGuard='fake-guard'
}
function Publish($Value,[string]$Checkpoint='before_install',$Server=$null){return Write-TL1C1bDeviceDiscoveryEvidence $script:RepoRoot $script:attemptId $script:ExpectedCommitSha $Checkpoint $Value $Server}
function Read-Record([string]$Path){return [IO.File]::ReadAllText($Path)|ConvertFrom-Json -Depth 30 -DateKind String}
function Get-TL1C1bPrivateAdbServerDiagnostic {param($Guard)throw 'mock server snapshot unavailable'}
Test-Case empty_and_missing_raw_are_distinct {
    $empty=ConvertTo-TL1C1bDiscoveryRaw ([byte[]]@())
    Check ($empty.byte_length-eq0-and$empty.data-ceq''-and$empty.sha256-ceq'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'empty stream changed'
    Check ($null-eq(ConvertTo-TL1C1bDiscoveryRaw $null)) 'missing stream became empty'
}
Test-Case raw_exact_bytes_and_sha {
    $bytes=[byte[]]@(0,255,13,10,128,65);$raw=ConvertTo-TL1C1bDiscoveryRaw $bytes
    Check ($raw.encoding-ceq'base64'-and$raw.byte_length-eq6-and$raw.sha256-ceq(Get-TL1C1aSha256Bytes $bytes)) 'raw metadata drift'
    Check ([Convert]::ToHexString([Convert]::FromBase64String($raw.data))-ceq[Convert]::ToHexString($bytes)) 'raw bytes drift'
    $bytes[0]=1;Check ([Convert]::FromBase64String($raw.data)[0]-eq0) 'published value aliases source'
}
Test-Case raw_limit_rejects_without_truncating {
    Check ((ConvertTo-TL1C1bDiscoveryRaw ([byte[]]::new(65536))).byte_length-eq65536) 'exact cap rejected'
    [void](Reject {ConvertTo-TL1C1bDiscoveryRaw ([byte[]]::new(65537))})
}
Test-Case first_failure_published_without_run_id {
    Reset-Case first;$diag=New-Diagnostic;$path=Publish $diag;$value=Read-Record $path
    Check ($value.attempt_id-ceq$attemptId-and$value.checkpoint-ceq'before_install'-and$value.expected_commit_sha-ceq$ExpectedCommitSha) 'attempt binding lost'
    Check ($value.discovery.actual_exit-eq0-and$value.discovery.device_count-eq0-and$value.discovery.failure_stage-ceq'device_count'-and$value.discovery.device_states.Count-eq0) 'zero device facts lost'
    Check ($value.discovery.stderr.byte_length-eq0-and$value.discovery.stdout.data-ceq[Convert]::ToBase64String($diag.stdout_bytes)) 'raw lost'
    Check ($value.diagnostic_only-and-not$value.device_acceptance_verified-and-not$value.cleanup_verified_by_this_record-and-not$value.server_diagnostic_available-and$null-eq$value.server) 'diagnostic became acceptance'
}
Test-Case checkpoint_paths_are_separate {
    Reset-Case checkpoints;$first=Publish (New-Diagnostic);$second=Publish (New-Diagnostic) after_capture
    Check ($first-cne$second-and(Test-Path -LiteralPath $first)-and(Test-Path -LiteralPath $second)) 'checkpoint overwritten'
    Check ((Read-Record $second).checkpoint-ceq'after_capture') 'wrong second checkpoint'
}
Test-Case fresh_clone_creates_only_fixed_evidence_child {
    $script:RepoRoot=Join-Path $testRoot fresh-clone
    [void](New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'docs/runs'))
    $value=Read-Record (Publish (New-Diagnostic))
    Check ($value.discovery.device_count-eq0-and$value.checkpoint-ceq'before_install') 'first discovery in fresh clone lost'
    $children=@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs/runs'))
    Check ($children.Count-eq1-and$children[0].Name-ceq'evidence') 'created directory outside fixed child'
}
Test-Case no_overwrite_retains_original {
    Reset-Case overwrite;$path=Publish (New-Diagnostic);$hash=Get-TL1C1aFileSha256 $path
    [void](Reject {Publish (New-Diagnostic)})
    Check ((Get-TL1C1aFileSha256 $path)-ceq$hash) 'existing evidence changed'
    Check (@(Get-ChildItem -LiteralPath (Split-Path $path) -Filter '*.tmp' -Force).Count-eq0) 'temporary residue'
}
Test-Case invalid_binding_rejected {
    Reset-Case binding
    foreach($id in @('../escape','BAD','x/y')){[void](Reject {Write-TL1C1bDeviceDiscoveryEvidence $RepoRoot $id $ExpectedCommitSha before_install $null $null})}
    foreach($checkpoint in @('wrong_checkpoint','BEFORE_INSTALL')){[void](Reject {Publish (New-Diagnostic) $checkpoint})}
    [void](Reject {Write-TL1C1bDeviceDiscoveryEvidence $RepoRoot $attemptId ('A'*40) before_install $null $null})
    Check (@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs/runs/evidence')).Count-eq0) 'invalid binding published'
}
Test-Case schema_drift_rejected {
    Reset-Case schema;$diag=New-Diagnostic;$diag.schema='unknown'
    [void](Reject {Publish $diag})
}
Test-Case unavailable_and_over_limit_stay_explicit {
    Reset-Case missing;$diag=New-Diagnostic;$diag.stdout_bytes=$null;$diag.stdout_capture_status='over_limit';$diag.stdout_observed_byte_count=65537;$diag.actual_exit=$null;$diag.device_count=$null;$diag.device_states=$null
    $value=Read-Record (Publish $diag)
    Check ($null-eq$value.discovery.stdout-and$value.discovery.stdout_capture_status-ceq'over_limit'-and$value.discovery.stdout_observed_byte_count-eq65537) 'oversize disguised as empty or truncated'
    Check ($null-eq$value.discovery.actual_exit-and$null-eq$value.discovery.device_count-and$null-eq$value.discovery.device_states) 'unknown became zero'
}
Test-Case server_snapshot_is_not_final_stream_or_cleanup {
    Reset-Case server
    $stream=[pscustomobject]@{availability='available';captured_utc='2026-09-13T00:00:01Z';captured_bytes=2;observed_bytes=2;maximum_bytes=65536;overflowed=$false;eof_observed=$false;scope='bounded_inflight_snapshot_not_final_stream_readback';snapshot_bytes=[byte[]]@(65,10)}
    $server=[pscustomobject]@{schema='tablet-layout-c1b-private-adb-server-diagnostic/v1';captured_utc='2026-09-13T00:00:01Z';guard_verified=$true;server_running_verified=$true;server_pid=123;server_socket='tcp:127.0.0.1:50001';server_executable_sha256='sha256:'+('b'*64);
        startup_server_status=[pscustomobject]@{availability='available';captured_utc='2026-09-13T00:00:00Z';encoding='utf-8';representation='lossless_utf8_reencoding_of_validated_client_stdout';bytes=[byte[]]@(66,10)};stdout=$stream;stderr=$stream}
    $value=Read-Record (Publish (New-Diagnostic) before_install $server)
    Check ($value.server_diagnostic_available-and$value.server.server_pid-eq123-and$value.server.startup_server_status.raw.data-ceq'Qgo=') 'server metadata lost'
    Check (-not$value.server.stdout.eof_observed-and-not$value.cleanup_verified_by_this_record-and$value.server.stdout.scope-ceq$stream.scope-and$value.server.stdout.raw.data-ceq'QQo=') 'snapshot upgraded to final stream'
    $stream.snapshot_bytes=[byte[]]@();$stream.captured_bytes=0;$stream.observed_bytes=0
    $empty=Read-Record (Publish (New-Diagnostic) after_capture $server)
    Check ($empty.server.stdout.raw.byte_length-eq0-and$empty.server.stderr.raw.data-ceq'') 'normal empty server streams lost'
}
Test-Case oversized_record_fails_before_publication {
    Reset-Case oversized;$diag=New-Diagnostic;$diag.device_states=[string[]]@(('device'*200000))
    [void](Reject {Publish $diag})
    Check (@(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs/runs/evidence') -Force).Count-eq0) 'oversized record partly published'
}
Test-Case reparse_parent_is_rejected {
    $script:RepoRoot=Join-Path $testRoot reparse;$parent=Join-Path $RepoRoot 'docs/runs';$target=Join-Path $testRoot reparse-target
    [void](New-Item -ItemType Directory -Path $parent);[void](New-Item -ItemType Directory -Path $target)
    $junction=Join-Path $parent evidence;[void](New-Item -ItemType Junction -Path $junction -Target $target)
    try{[void](Reject {Publish (New-Diagnostic)});Check (@(Get-ChildItem -LiteralPath $target -Force).Count-eq0) 'evidence escaped via reparse'}
    finally{Remove-Item -LiteralPath $junction -Force}
}
Test-Case missing_directory_fails_without_artifact {
    $script:RepoRoot=Join-Path $testRoot absent
    [void](Reject {Publish (New-Diagnostic)})
    Check (-not(Test-Path -LiteralPath $RepoRoot)) 'writer created unreviewed directory'
}
Test-Case helper_clears_only_diagnostic_copy {
    Reset-Case clear;$diag=New-Diagnostic;$source=$diag.stdout_bytes.Clone()
    Write-C1bDiscoveryEvidence before_install $diag $false 6>$null
    Check (@($diag.stdout_bytes|Where-Object{$_-ne0}).Count-eq0) 'diagnostic bytes not cleared'
    $value=Read-Record (Join-Path $RepoRoot "docs/runs/evidence/tablet-layout-c1b-discovery-$attemptId-before_install.json")
    Check ($value.discovery.stdout.data-ceq[Convert]::ToBase64String($source)) 'clear changed published evidence'
}
Test-Case successful_discovery_cannot_ignore_writer_failure {
    $script:RepoRoot=Join-Path $testRoot helper-failure;$diag=New-Diagnostic
    $originalError=[Console]::Error;$capturedError=[IO.StringWriter]::new()
    try{[Console]::SetError($capturedError);$message=Reject {Write-C1bDiscoveryEvidence before_install $diag $false}}
    finally{[Console]::SetError($originalError)}
    Check ($message-ceq'C1b discovery evidence publication failed.') 'writer failure swallowed or path leaked'
    Check ($capturedError.ToString().Trim()-ceq'C1b discovery evidence publication failed: checkpoint=before_install.') 'raw or local path leaked'
    Check (@($diag.stdout_bytes|Where-Object{$_-ne0}).Count-eq0) 'failure retained diagnostic bytes'
}
Test-Case failed_discovery_preserves_original_exception {
    $script:RepoRoot=Join-Path $testRoot original-failure;$diag=New-Diagnostic
    $original=[InvalidOperationException]::new('original zero devices');$caught=$null
    $originalError=[Console]::Error;$capturedError=[IO.StringWriter]::new()
    try{[Console]::SetError($capturedError);try{try{throw $original}finally{Write-C1bDiscoveryEvidence before_install $diag $true}}catch{$caught=$_.Exception}}
    finally{[Console]::SetError($originalError)}
    Check ([object]::ReferenceEquals($original,$caught)) 'writer failure replaced original exception'
}
[ordered]@{schema='tablet-layout-c1b-discovery-evidence-offline/v1';passed=$passed;failed=$failed;assertions=$assertions;real_adb_call_count=0;runner_entrypoint_executed=$false}|ConvertTo-Json -Compress
if($failed-ne0){exit 1}
