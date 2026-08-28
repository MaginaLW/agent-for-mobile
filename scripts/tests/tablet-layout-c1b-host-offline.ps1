#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$GateRunId)

$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0;[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Text.UTF8Encoding]::new($false)
$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Runner=Join-Path $RepoRoot 'scripts\run-tablet-layout-c1b.ps1'
$C1aLibrary=Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1'
$Validator=Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1'
$Library=Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b.ps1'
$SidecarSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1b-sidecar-v1.schema.json'
$BuildEnvironmentFixture=Join-Path $PSScriptRoot 'fixtures\tablet-layout-c1b-build-environment.json'
. $C1aLibrary;. $Validator;. $Library

$started=[DateTime]::UtcNow;$passed=[Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$threw=$false;try{&$Action}catch{$threw=$true};if(-not$threw){throw $Message}}
function Pass([string]$Coverage,[scriptblock]$Action){&$Action;$passed.Add($Coverage)}
function New-Control([string]$State='ready_c1',[long]$Generation=7,[long]$C1=0,[long]$C2=0,[object[]]$Tokens=@(),[object]$InFlight=$null){
    $next=switch($State){ready_c1{'capture_c1'};capturing_c1{'wait'};ready_c2{'capture_c2'};capturing_c2{'wait'};complete{'read_result'};default{'none'}}
    $o=[ordered]@{schema='tablet-c1b-control/v1';ok=($State-in@('ready_c1','capturing_c1','ready_c2','capturing_c2','complete'));run_id='tl1-c1b-test';generation=$Generation;state=$State;next=$next;reason_code=$null;in_flight_token=$InFlight;c1_requests_accepted=$C1;c2_requests_accepted=$C2;committed_tokens=$Tokens;recapture_count=[long]0;expected_title_hash=$script:TL1C1bExpectedTitleHash;producer_commit_sha=('a'*40);producer_artifact_sha256=('sha256:'+'b'*64);provider=[ordered]@{authority=$script:TL1C1bAuthority;protocol_version='1';package_name='dev.magina.gateway';version_name='1.0';version_code=[long]1;embedded_git_head=('a'*40);build_challenge=('c1b-'+'c'*32);a11y_service_ready=$true}}
    return $o
}
function Parse-Control($Control){ConvertFrom-TL1C1bControl ($Control|ConvertTo-Json -Depth 8 -Compress) 'tl1-c1b-test' ('a'*40) ('sha256:'+'b'*64) ('c1b-'+'c'*32)}
function New-AbortControl([string]$State,[string]$Reason,[long]$Generation,[long]$C1,[long]$C2,[object[]]$Tokens){
    $o=New-Control -State $State -Generation $Generation -C1 $C1 -C2 $C2 -Tokens $Tokens
    $o.reason_code=$Reason
    if($State-ceq'absent'){$o.expected_title_hash=$null;$o.producer_commit_sha=$null;$o.producer_artifact_sha256=$null}
    return $o
}
function New-SidecarFixture {
    $h='sha256:'+'d'*64;$impl=[ordered]@{};foreach($name in @(
        'runner_sha256','c1b_library_sha256','c1b_read_only_library_sha256','c1b_artifact_proof_library_sha256','c1b_aapt2_library_sha256','c1b_build_environment_library_sha256','c1b_adb_server_library_sha256','dispatch_lock_library_sha256','c1a_low_level_library_sha256',
        't0_runner_sha256','t0_library_sha256','t0_adb_sidecar_cmd_sha256','t0_adb_sidecar_script_sha256','validator_sha256','native_path_validator_sha256',
        'observation_schema_sha256','sidecar_schema_sha256','artifact_proof_schema_sha256','android_layout_probe_sha256','android_layout_probe_model_sha256','android_model_sha256','android_probe_sha256','android_source_sha256',
        'android_provider_sha256','android_protocol_sha256','android_coordinator_sha256','android_controller_sha256','android_context_sha256','android_pending_registry_sha256',
        'app_build_gradle_sha256','app_settings_gradle_sha256','app_gradle_properties_sha256','app_gradlew_bat_sha256','app_gradle_wrapper_jar_sha256','app_gradle_wrapper_properties_sha256','app_gradle_verification_metadata_sha256','probe_build_gradle_sha256','probe_manifest_sha256','probe_service_sha256','probe_a11y_config_sha256','probe_strings_sha256'
    )){$impl[$name]=$h}
    $buildEnvironment=Get-Content -LiteralPath $BuildEnvironmentFixture -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    $buildEnvironment.repository_inputs.file_count=[long]$impl.Count
    $buildEnvironment.repository_inputs.catalog_sha256=Get-TL1C1bImplementationCatalogSha256 $impl
    return [ordered]@{schema='tablet-layout-c1b-sidecar/v1';run_id='tl1-c1b-test';completed_at_utc='2026-08-26T01:02:03.1234567Z';expected_commit_sha=('a'*40);capture_scope='pure_a11y';provenance_strategy='clean_content_provider_independently_attested';static_read_only_policy_version='tl1-c1b-read-only/v2';implementation_hashes=$impl
        build_environment=$buildEnvironment
        transport=[ordered]@{trust_root='android_sdk_platform_tools';canonical_relative_path='platform-tools/adb.exe';sdk_roots_equal=$true;executable_sha256_before=$h;executable_sha256_after=$h;version_output_sha256_before=$h;version_output_sha256_after=$h;signature_status='Valid';signature_subject=$script:TL1C1bGoogleAdbSignerSubject;signature_certificate_sha256_before=$h;signature_certificate_sha256_after=$h;protocol_version='1.0.41';package_version='36.0.0-13206524';installed_as_canonical=$true;server_schema='tablet-layout-c1b-private-adb-server/v1';server_mode='private_nodaemon';server_socket='tcp:127.0.0.1:55001';server_executable_sha256=$h;job_kill_on_close=$true;listener_pid_verified=$true;server_status_executable_path_verified=$true;server_ready_verified=$true;server_cleanup_verified=$true;private_kill_server_requested=$true;graceful_exit_verified=$true;job_fallback_used=$false;port_rebind_verified=$true;default_server_used=$false}
        apk=[ordered]@{fresh_build=$true;install_attempt_count=1;uninstall_count=0;automatic_retry_count=0;local_sha256_before=$h;local_sha256_after=$h;installed_base_apk_path_hash_before=$h;installed_base_apk_path_hash_after=$h;installed_base_apk_sha256_before=$h;installed_base_apk_sha256_after=$h;signer_certificate_sha256=$h;package_name_before='dev.magina.gateway';package_name_after='dev.magina.gateway';version_name_before='1.0';version_name_after='1.0';version_code_before=1;version_code_after=1}
        device=[ordered]@{serial_hash_before=$h;serial_hash_after=$h;fingerprint_hash_before=$h;fingerprint_hash_after=$h;boot_id_hash_before=$h;boot_id_hash_after=$h;unique_device_before_after=$true}
        upstream_t0=[ordered]@{producer_commit_sha='4ca32b131007df58f7752c5ee9b2d049cb1cd54e';original_relative_path='docs/runs/evidence/tl1-c1b-test/tablet-profile.json';original_sha256=$h;original_byte_count=10;original_crlf_count=1;original_bytes_forwarded=$true;exec_in_write_count=1;device_binding_verified=$true}
        provider=[ordered]@{authority=$script:TL1C1bAuthority;protocol_version='1';package_name='dev.magina.gateway';version_name='1.0';version_code=1;embedded_git_head=('a'*40);build_challenge_hash=$h;expected_title_hash=$script:TL1C1bExpectedTitleHash;producer_artifact_sha256=$h;a11y_service_ready=$true;control_transcript_sha256=$h;endpoint_set_sha256=$h}
        capture=[ordered]@{generation=7;c1_requested_at_utc='2026-08-26T01:02:03.1234567Z';c1_committed_at_utc='2026-08-26T01:02:03.2234567Z';c2_requested_at_utc='2026-08-26T01:02:04.2234567Z';c2_committed_at_utc='2026-08-26T01:02:04.3234567Z';host_wait_ms=1000;total_span_ms=1200;status_poll_count=1;c1_requests_accepted=1;c2_requests_accepted=1;result_read_count=1;recapture_count=0}
        artifacts=[ordered]@{upstream_t0=[ordered]@{relative_path='upstream-t0-v5.json';sha256=$h};observation=[ordered]@{relative_path='tablet-layout-observation-c1b-v1.json';sha256=$h};validation=[ordered]@{relative_path='tablet-layout-observation-validation-c1b-v1.json';sha256=$h};artifact_proof=[ordered]@{relative_path='tablet-c1b-read-only-artifact-proof-v1.json';sha256=$h};debug_apk=[ordered]@{relative_path='tablet-c1b-probe-debug.apk';sha256=$h};release_apk=[ordered]@{relative_path='tablet-c1b-probe-release-unsigned.apk';sha256=$h};debug_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-debug-merged-AndroidManifest.xml';sha256=$h};release_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-release-merged-AndroidManifest.xml';sha256=$h}}
        read_only_counts=[ordered]@{a11y_frame_capture_count=2;recapture_count=0;display_screenshot_call_count=0;window_screenshot_call_count=0;ocr_invocation_count=0;action_call_count=0;gesture_call_count=0;input_call_count=0;settings_mutation_count=0;target_app_start_count=0;mcp_call_count=0;dispatch_call_count=0}
        read_only_proof=[ordered]@{schema='tablet-layout-c1b-read-only-proof/v1';policy_version='tl1-c1b-read-only/v2';artifact_module=':tablet-c1b-probe';artifact_proof_relative_path='app/tablet-c1b-probe/build/reports/tablet-c1b-read-only-artifact-proof.json';artifact_proof_sha256=$h;runner_ast_sha256=$h;t0_runner_ast_sha256=$h;t0_library_ast_sha256=$h;host_forbidden_command_count=0;axml_parser=[ordered]@{schema='tablet-layout-c1b-aapt2-trust/v1';trust_root='android_sdk_build_tools';build_tools_version='35.0.0';canonical_relative_path='build-tools/35.0.0/aapt2.exe';sdk_roots_equal=$true;executable_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564';signature_status='Valid';signature_subject='CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US';signature_certificate_sha256='sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'};packaged_axml_exact_verified=$true;dependency_artifact_catalog_sha256=$h;debug_apk_sha256=$h;debug_merged_manifest_sha256=$h;debug_packaged_manifest_sha256=$h;debug_packaged_manifest_axml_dump_sha256=$h;debug_packaged_a11y_axml_dump_sha256=$h;debug_dex_entry_count=6;debug_dex_sha256=$h;debug_dex_catalog_sha256=$h;release_apk_sha256=$h;release_merged_manifest_sha256=$h;release_packaged_manifest_sha256=$h;release_packaged_manifest_axml_dump_sha256=$h;release_packaged_a11y_axml_dump_sha256=$h;release_dex_entry_count=1;release_dex_sha256=$h;release_dex_catalog_sha256=$h;artifact_forbidden_match_count=0;manifest_mutating_capability_count=0;manifest_extra_component_count=0;dependency_allowlist_verified=$true}
        attestations=[ordered]@{full_clean_head_verified=$true;implementation_hashes_verified=$true;origin_binding_verified=$true;probe_entrypoint_read_only=$true;dedicated_read_only_artifact_verified=$true;host_read_only_ast_verified=$true;observation_schema_valid=$true;artifact_hashes_recomputed=$true}
        claims=[ordered]@{runtime_origin_verified=$true;runtime_evidence=$true;wechat_window_ownership_observed=$true;wechat_window_ownership_verified=$true;window_root_projection_observed=$true;window_root_projection_verified=$true;application_window_topology_observed=$true;application_window_topology_verified=$true;ime_hidden_observed=$true;ime_hidden_verified=$true;semantic_tree_usable=$true;navigation_pane_verified=$false;conversation_pane_verified=$false;target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}
        cleanup=[ordered]@{required=$false;status='not_required';abort_attempt_count=0}}
}

$temp=Join-Path ([IO.Path]::GetTempPath()) ('tl1-c1b-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory $temp)
try{
    Pass canonical_uri {
        $nonce='n-'+'1'*32;$t0=New-TL1C1bUri t0 'tl1-c1b-test' $nonce ('a'*40) ('sha256:'+'b'*64)
        Assert-True ($t0-ceq("content://dev.magina.gateway.tablet.c1b/t0/tl1-c1b-test?nonce=$nonce&title_hash=$script:TL1C1bExpectedTitleHash&producer_commit_sha="+('a'*40)+'&producer_artifact_sha256=sha256:'+('b'*64))) 'T0 canonical URI 漂移'
        Assert-Throws {ConvertTo-TL1C1bContentUriArgument content_t0 ($t0+'&extra=1') $true} 'extra query 未拒绝'
        Assert-Throws {ConvertTo-TL1C1bContentUriArgument content_t0 ($t0-replace'tablet.c1b','tablet.c1a') $true} 'authority spoof 未拒绝'
    }
    $fakeSource=@'
using System;using System.IO;using System.Text;
public static class FakeAdb { public static int Main(string[] a){
 var root=Environment.GetEnvironmentVariable("TL1_C1B_FAKE_ROOT");File.WriteAllText(Path.Combine(root,"last-uri.txt"),a.Length>6?a[6]:"",new UTF8Encoding(false));
 if(a.Length==7&&a[2]=="exec-in"){using(var i=Console.OpenStandardInput())using(var o=File.Create(Path.Combine(root,"stdin.bin")))i.CopyTo(o);return 0;}
 if(a.Length==7&&a[2]=="shell"){Console.Out.Write(Environment.GetEnvironmentVariable("TL1_C1B_FAKE_RESPONSE"));return 0;}return 91;}}
'@
    $fakeSourcePath=Join-Path $temp 'fake-adb.cs';[IO.File]::WriteAllText($fakeSourcePath,$fakeSource,[Text.UTF8Encoding]::new($false))
    $fakeExe=Join-Path $temp 'fake-adb.exe';$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe';if(-not(Test-Path $csc)){$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
    if(-not(Test-Path $csc)){throw 'fake-ADB test 缺少 Windows csc.exe。'};&$csc /nologo /target:exe "/out:$fakeExe" $fakeSourcePath;if($LASTEXITCODE-ne0){throw 'fake-ADB shim 编译失败。'}
    $env:TL1_C1B_FAKE_ROOT=$temp;$nonce='n-'+'2'*32
    Pass fake_adb_exec_in_exact_bytes {
        $bytes=[byte[]](0,13,10,255,1,2,3);$uri=New-TL1C1bUri t0 'tl1-c1b-test' $nonce ('a'*40) ('sha256:'+'b'*64)
        $r=Invoke-TL1C1bAdb $fakeExe 'FAKE123' content_t0 $uri $bytes 10
        Assert-True ($r.Bytes.Length-eq0-and$r.Stderr.Length-eq0) 'fake write 伪 ACK'
        Assert-True (([Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $temp 'stdin.bin'))))-ceq([Convert]::ToHexString($bytes))) 'exec-in bytes 漂移'
    }
    Pass fake_adb_read_quoting {
        $env:TL1_C1B_FAKE_RESPONSE='{}';$uri=New-TL1C1bUri status 'tl1-c1b-test' $nonce
        [void](Invoke-TL1C1bAdb $fakeExe 'FAKE123' content_status $uri $null 10)
        $argument=Get-Content (Join-Path $temp 'last-uri.txt') -Raw
        Assert-True ($argument-ceq("'$uri'")) 'read URI 未按远端 shell 单引号封装'
    }
    Pass control_exact_schema {
        $v=Parse-Control (New-Control);Assert-TL1C1bControlTuple $v ready_c1 capture_c1 7 0 0 @() $null
        $x=New-Control;$x.extra=$true;Assert-Throws {Parse-Control $x} 'control extra field 未拒绝'
    }
    Pass provider_provenance {
        foreach($field in @('embedded_git_head','build_challenge','authority')){$x=New-Control;$x.provider[$field]='spoof';Assert-Throws {Parse-Control $x} "provider $field spoof 未拒绝"}
        $x=New-Control;$x.producer_artifact_sha256='sha256:'+'e'*64;Assert-Throws {Parse-Control $x} 'artifact spoof 未拒绝'
    }
    Pass replay_rejection {$x=New-Control;$x.run_id='old-run';Assert-Throws {Parse-Control $x} 'run replay 未拒绝';$v=Parse-Control (New-Control -Generation 8);Assert-Throws {Assert-TL1C1bControlTuple $v ready_c1 capture_c1 7 0 0 @() $null} 'generation replay 未拒绝'}
    Pass duplicate_capture_rejection {$v=Parse-Control (New-Control -State ready_c2 -C1 2 -Tokens @('c1'));Assert-Throws {Assert-TL1C1bControlTuple $v ready_c2 capture_c2 7 1 0 @('c1') $null} 'duplicate c1 未拒绝'}
    Pass recapture_rejection {$x=New-Control;$x.recapture_count=1;Assert-Throws {Parse-Control $x} 'recapture 未拒绝'}
    Pass bounded_status_success {
        $stages=@(
            @{expected='ready_c2';capturing=(Parse-Control (New-Control -State capturing_c1 -C1 1 -InFlight c1));terminal=(Parse-Control (New-Control -State ready_c2 -C1 1 -Tokens @('c1')))},
            @{expected='complete';capturing=(Parse-Control (New-Control -State capturing_c2 -C1 1 -C2 1 -Tokens @('c1') -InFlight c2));terminal=(Parse-Control (New-Control -State complete -C1 1 -C2 1 -Tokens @('c1','c2')))}
        )
        foreach($stage in $stages){
            $script:i=0;$v=Wait-TL1C1bTerminalState -ExpectedState $stage.expected -Generation 7 -MaximumPolls 3 -PollMilliseconds 10 -Sleep {} -ReadStatus {$script:i++;if($script:i-eq1){$stage.capturing}else{$stage.terminal}}
            Assert-True ($v.state-ceq$stage.expected-and$script:i-eq2) "bounded status success 错误: $($stage.expected)"
            foreach($mutation in @('ok','next','reason','generation','c1','c2','committed','in_flight','recapture')){
                $x=($stage.capturing|ConvertTo-Json -Depth 8)|ConvertFrom-Json -DateKind String
                switch($mutation){
                    ok{$x.ok=$false};next{$x.next='read_result'};reason{$x.reason_code='capture_c1_timeout'};generation{$x.generation=8};c1{$x.c1_requests_accepted=0}
                    c2{$x.c2_requests_accepted=if($stage.expected-ceq'ready_c2'){1}else{0}}
                    committed{$x.committed_tokens=if($stage.expected-ceq'ready_c2'){@('c1')}else{@()}}
                    in_flight{$x.in_flight_token=$null};recapture{$x.recapture_count=1}
                }
                $script:mutationPolls=0
                Assert-Throws {Wait-TL1C1bTerminalState -ExpectedState $stage.expected -Generation 7 -MaximumPolls 2 -PollMilliseconds 10 -Sleep {} -ReadStatus {$script:mutationPolls++;if($script:mutationPolls-eq1){$x}else{$stage.terminal}}} "status $($stage.expected) intermediate $mutation 漂移未拒绝"
                Assert-True ($script:mutationPolls-eq1) "status $($stage.expected) intermediate $mutation 未在首条畸形 poll 失败"
            }
            $terminalDrift=($stage.terminal|ConvertTo-Json -Depth 8)|ConvertFrom-Json -DateKind String;$terminalDrift.next='wait'
            Assert-Throws {Wait-TL1C1bTerminalState -ExpectedState $stage.expected -Generation 7 -MaximumPolls 1 -PollMilliseconds 10 -Sleep {} -ReadStatus {$terminalDrift}} "status $($stage.expected) terminal tuple 漂移未拒绝"
        }
    }
    Pass bounded_status_timeout {$script:i=0;Assert-Throws {Wait-TL1C1bTerminalState -ExpectedState ready_c2 -Generation 7 -MaximumPolls 2 -PollMilliseconds 10 -Sleep {} -ReadStatus {$script:i++;Parse-Control (New-Control -State capturing_c1 -C1 1 -InFlight c1)}} 'bounded status timeout 未拒绝';Assert-True ($script:i-eq2) 'timeout poll 数漂移'}
    $runnerRaw=Get-Content $Runner -Raw
    Pass host_wait_900ms {Assert-True ($runnerRaw-match'ElapsedMilliseconds-lt900'-and$runnerRaw-match'host_wait_ms=\[long\]\$hostWait') '900ms host wait 缺失'}
    Pass single_c1_c2_result {Assert-True ([regex]::Matches($runnerRaw,'Read-C1bControl content_c1').Count-eq1) 'content_c1 调用数漂移';Assert-True ([regex]::Matches($runnerRaw,'Read-C1bControl content_c2').Count-eq1) 'content_c2 调用数漂移';Assert-True ([regex]::Matches($runnerRaw,'-Name content_result').Count-eq1) 'content_result 调用数漂移';Assert-True ($runnerRaw-match'ConvertTo-TL1C1bReadOnlyCounts'-and$runnerRaw-cnotmatch'read_only_counts=\[ordered\]') 'read_only_counts 未机械导出'}
    Pass single_install_no_retry_uninstall {Assert-True ([regex]::Matches($runnerRaw,'-Name install').Count-eq1) 'install 次数漂移';Assert-True ($runnerRaw-cnotmatch'-Name\s+uninstall|automatic_retry_count=[1-9]|install_attempt_count=[2-9]') '出现 uninstall/retry'}
    Pass sdk_adb_trust_root {Assert-True ($runnerRaw-match'Get-TL1C1bAdbTrustBinding'-and$runnerRaw-match'ANDROID_SDK_ROOT'-and$runnerRaw-match'ANDROID_HOME') 'runner 缺失 canonical SDK adb trust root';$libraryRaw=Get-Content $Library -Raw;Assert-True ($libraryRaw-match'Get-AuthenticodeSignature'-and$libraryRaw-match'TL1C1bGoogleAdbSignerSubject') 'ADB Authenticode/Google signer 门缺失';foreach($mutation in @('executable','certificate','subject')){$s=New-SidecarFixture;switch($mutation){executable{$s.transport.executable_sha256_after='sha256:'+'e'*64};certificate{$s.transport.signature_certificate_sha256_after='sha256:'+'e'*64};subject{$s.transport.signature_subject='CN=Evil LLC'}};Assert-Throws {Assert-TL1C1bSidecarCrossBindings ([pscustomobject](($s|ConvertTo-Json -Depth 30)|ConvertFrom-Json -DateKind String))} "adb $mutation drift 未拒绝"}}
    Pass controlled_path_hash {$p=Join-Path $temp 'artifact.json';[IO.File]::WriteAllText($p,'{}',[Text.UTF8Encoding]::new($false));$h=Get-TL1C1aFileSha256 $p;Assert-TL1C1bPublishedEvidenceBinding $temp @{$p=$h};Assert-Throws {Assert-TL1C1bPublishedEvidenceBinding $temp @{$p=('sha256:'+'0'*64)}} 'hash spoof 未拒绝';Assert-Throws {Assert-TL1C1bPublishedEvidenceBinding $temp @{(Join-Path $temp '..\escape.json')=$h}} 'path escape 未拒绝'}
    Pass sidecar_closed_schema {$s=New-SidecarFixture;$raw=$s|ConvertTo-Json -Depth 30 -Compress;Assert-True ($raw|Test-Json -SchemaFile $SidecarSchema) 'valid sidecar schema 拒绝';foreach($invalidSocket in @('tcp:127.0.0.1:49151','tcp:127.0.0.1:65536')){$invalid=New-SidecarFixture;$invalid.transport.server_socket=$invalidSocket;Assert-True (-not($invalid|ConvertTo-Json -Depth 30 -Compress|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)) "sidecar schema 未拒绝 private socket：$invalidSocket"};$s.extra=$true;Assert-True (-not($s|ConvertTo-Json -Depth 30 -Compress|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)) 'sidecar extra 未拒绝'}
    Pass sidecar_cross_binding {
        $s=New-SidecarFixture
        Assert-TL1C1bSidecarCrossBindings ([pscustomobject](($s|ConvertTo-Json -Depth 30)|ConvertFrom-Json -DateKind String))
        foreach($path in @(
            'apk.local_sha256_after','provider.embedded_git_head','capture.host_wait_ms','capture.c1_requests_accepted',
            'transport.server_socket','transport.server_executable_sha256','transport.listener_pid_verified',
            'transport.server_cleanup_verified','transport.default_server_used','transport.cleanup_mode',
            'upstream_t0.original_sha256','read_only_counts.action_call_count','read_only_proof.runner_ast_sha256',
            'read_only_proof.debug_apk_sha256','read_only_proof.dependency_artifact_catalog_sha256',
            'read_only_proof.debug_packaged_manifest_sha256','read_only_proof.debug_packaged_a11y_axml_dump_sha256','read_only_proof.axml_parser.executable_sha256','read_only_proof.packaged_axml_exact_verified','read_only_proof.debug_dex_entry_count',
            'read_only_proof.release_dex_entry_count','artifacts.artifact_proof.sha256','artifacts.release_apk.sha256',
            'artifacts.debug_merged_manifest.sha256','attestations.host_read_only_ast_verified',
            'claims.wechat_window_ownership_verified','build_environment.host_process.wrapper_not_executed',
            'build_environment.repository_inputs.file_count','build_environment.repository_inputs.catalog_sha256','build_environment.extra'
        )){
            $x=($s|ConvertTo-Json -Depth 30)|ConvertFrom-Json -DateKind String
            switch($path){
                'apk.local_sha256_after'{$x.apk.local_sha256_after='sha256:'+'e'*64}
                'provider.embedded_git_head'{$x.provider.embedded_git_head='e'*40}
                'capture.host_wait_ms'{$x.capture.host_wait_ms=899}
                'capture.c1_requests_accepted'{$x.capture.c1_requests_accepted=2}
                'transport.server_socket'{$x.transport.server_socket='tcp:127.0.0.1:49151'}
                'transport.server_executable_sha256'{$x.transport.server_executable_sha256='sha256:'+'e'*64}
                'transport.listener_pid_verified'{$x.transport.listener_pid_verified=$false}
                'transport.server_cleanup_verified'{$x.transport.server_cleanup_verified=$false}
                'transport.default_server_used'{$x.transport.default_server_used=$true}
                'transport.cleanup_mode'{$x.transport.graceful_exit_verified=$true;$x.transport.job_fallback_used=$true}
                'upstream_t0.original_sha256'{$x.upstream_t0.original_sha256='sha256:'+'e'*64}
                'read_only_counts.action_call_count'{$x.read_only_counts.action_call_count=1}
                'read_only_proof.runner_ast_sha256'{$x.read_only_proof.runner_ast_sha256='sha256:'+'e'*64}
                'read_only_proof.debug_apk_sha256'{$x.read_only_proof.debug_apk_sha256='sha256:'+'e'*64}
                'read_only_proof.dependency_artifact_catalog_sha256'{$x.read_only_proof.dependency_artifact_catalog_sha256='invalid'}
                'read_only_proof.debug_packaged_manifest_sha256'{$x.read_only_proof.debug_packaged_manifest_sha256='invalid'}
                'read_only_proof.debug_packaged_a11y_axml_dump_sha256'{$x.read_only_proof.debug_packaged_a11y_axml_dump_sha256='invalid'}
                'read_only_proof.axml_parser.executable_sha256'{$x.read_only_proof.axml_parser.executable_sha256='sha256:'+'e'*64}
                'read_only_proof.packaged_axml_exact_verified'{$x.read_only_proof.packaged_axml_exact_verified=$false}
                'read_only_proof.debug_dex_entry_count'{$x.read_only_proof.debug_dex_entry_count=0}
                'read_only_proof.release_dex_entry_count'{$x.read_only_proof.release_dex_entry_count=33}
                'artifacts.artifact_proof.sha256'{$x.artifacts.artifact_proof.sha256='sha256:'+'e'*64}
                'artifacts.release_apk.sha256'{$x.artifacts.release_apk.sha256='sha256:'+'e'*64}
                'artifacts.debug_merged_manifest.sha256'{$x.artifacts.debug_merged_manifest.sha256='sha256:'+'e'*64}
                'attestations.host_read_only_ast_verified'{$x.attestations.host_read_only_ast_verified=$false}
                'build_environment.host_process.wrapper_not_executed'{$x.build_environment.host_process.wrapper_not_executed=$false}
                'build_environment.repository_inputs.file_count'{$x.build_environment.repository_inputs.file_count=39}
                'build_environment.repository_inputs.catalog_sha256'{$x.build_environment.repository_inputs.catalog_sha256='sha256:'+'e'*64}
                'build_environment.extra'{$x.build_environment|Add-Member extra $true}
                default{$x.claims.wechat_window_ownership_verified=$false}
            }
            Assert-Throws {Assert-TL1C1bSidecarCrossBindings $x} "cross spoof 未拒绝: $path"
        }
    }
    Pass release_debug_boundary {
        $manifest=Get-Content (Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\AndroidManifest.xml') -Raw
        $service=Get-Content (Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\java\dev\magina\gateway\a11y\GatewayA11yService.kt') -Raw
        $a11yConfig=Get-Content (Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\res\xml\a11y_config.xml') -Raw
        $build=Get-Content (Join-Path $RepoRoot 'app\tablet-c1b-probe\build.gradle.kts') -Raw
        Assert-True ($manifest-match[regex]::Escape($script:TL1C1bAuthority)-and$manifest-match'android\.permission\.DUMP'-and
            $manifest-cnotmatch'<uses-permission|<activity|<receiver') '专用 C1b manifest 非零权限/缺 provider 或含额外组件'
        Assert-True ($service-cnotmatch'performAction|dispatchGesture|performGlobalAction|takeScreenshot') '专用 a11y service 暴露动作能力'
        Assert-True ($a11yConfig-match'canRetrieveWindowContent="true"'-and$a11yConfig-cnotmatch'canPerformGestures|canTakeScreenshot') '专用 a11y config 越出只读能力'
        Assert-True ($build-match'verifyTabletC1bReadOnlyArtifact'-and$build-match'packaged_manifest_sha256'-and
            $build-match'allowedRuntimeArtifactHashes'-and$build-match'allowedAppDescriptorRoots'-and
            $runnerRaw-match':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact'-and$runnerRaw-cnotmatch'gateway-debug\.apk') `
            'runner 未固定专用 artifact、包内 manifest、依赖 hash 或 DEX closure proof'
    }
    Pass validator_origin_scope {$validatorRaw=Get-Content $Validator -Raw;Assert-True ($validatorRaw-match'runtime_origin_verified\s*=\s*\$false'-and$validatorRaw-match'runtime_evidence\s*=\s*\$false') 'validator 越权自证 origin'}
    Pass failure_atomic_cleanup {
        $c1aRaw=Get-Content $C1aLibrary -Raw
        $cleanupIndex=$runnerRaw.LastIndexOf('Close-DispatchLockLease',[StringComparison]::Ordinal)
        $publishIndex=$runnerRaw.LastIndexOf('Write-TL1C1aBytesAtomic $RepoRoot $sidecarPath',[StringComparison]::Ordinal)
        Assert-True ($runnerRaw-match'Write-C1bFailureEvidence'-and$runnerRaw-match'not\$sessionConsumed'-and$runnerRaw-match'content_abort'-and$c1aRaw-match'Remove-Item -LiteralPath \$destinationFull') 'failure/abort 原子边界缺失'
        Assert-True ($cleanupIndex-ge0-and$publishIndex-gt$cleanupIndex) 'success sidecar 在 guard/device cleanup 之前发布'
    }
    Pass abort_terminal_control_closed {
        $valid=@(
            @{state='aborted';reason='session_aborted';generation=7;c1=1;c2=0;tokens=@('c1');expectedGeneration=7;expectedC1=1;expectedC2=0;expectedTokens=@('c1')},
            @{state='failed';reason='capture_c2_failed';generation=7;c1=1;c2=1;tokens=@('c1');expectedGeneration=7;expectedC1=1;expectedC2=1;expectedTokens=@('c1')},
            @{state='expired';reason='session_expired';generation=7;c1=1;c2=1;tokens=@('c1','c2');expectedGeneration=7;expectedC1=1;expectedC2=1;expectedTokens=@('c1','c2')},
            @{state='absent';reason='session_not_found';generation=0;c1=0;c2=0;tokens=@();expectedGeneration=7;expectedC1=1;expectedC2=1;expectedTokens=@('c1','c2')}
        )
        foreach($case in $valid){$v=Parse-Control (New-AbortControl $case.state $case.reason $case.generation $case.c1 $case.c2 $case.tokens);Assert-TL1C1bAbortTerminalControl $v $case.expectedGeneration $case.expectedC1 $case.expectedC2 $case.expectedTokens}
        foreach($stateCase in $valid){$x=New-AbortControl $stateCase.state 'not_a_closed_reason' $stateCase.generation $stateCase.c1 $stateCase.c2 $stateCase.tokens;Assert-Throws {$v=Parse-Control $x;Assert-TL1C1bAbortTerminalControl $v $stateCase.expectedGeneration $stateCase.expectedC1 $stateCase.expectedC2 $stateCase.expectedTokens} "abort $($stateCase.state) reason 未拒绝"}
        foreach($nonAbortAbsentReason in @('t0_pending','session_busy','generation_exhausted')){$x=New-AbortControl absent $nonAbortAbsentReason 0 0 0 @();Assert-Throws {$v=Parse-Control $x;Assert-TL1C1bAbortTerminalControl $v 7 1 1 @('c1','c2')} "abort absent 非端点终态 reason 未拒绝: $nonAbortAbsentReason"}
        $base=New-AbortControl aborted session_aborted 7 1 0 @('c1')
        foreach($mutation in @('ok','next','in_flight','generation','c1','c2','tokens','recapture')){
            $x=($base|ConvertTo-Json -Depth 8)|ConvertFrom-Json -DateKind String
            switch($mutation){ok{$x.ok=$true};next{$x.next='wait'};in_flight{$x.in_flight_token='c1'};generation{$x.generation=8};c1{$x.c1_requests_accepted=0};c2{$x.c2_requests_accepted=1};tokens{$x.committed_tokens=@()};recapture{$x.recapture_count=1}}
            Assert-Throws {$v=Parse-Control $x;Assert-TL1C1bAbortTerminalControl $v 7 1 0 @('c1')} "abort terminal $mutation 未拒绝"
        }
        $completeAbort=Parse-Control (New-AbortControl aborted session_aborted 7 1 1 @('c1','c2'));Assert-Throws {Assert-TL1C1bAbortTerminalControl $completeAbort 7 1 1 @('c1','c2')} 'aborted complete tuple 未拒绝'
    }
    Pass summary_deception_rejection {
        $gateStarted=[DateTimeOffset]::UtcNow.AddSeconds(-1);$gateCompleted=[DateTimeOffset]::UtcNow;$gateElapsed=[long]1000
        $summary=[ordered]@{schema='tablet-layout-c1b-host-offline-summary/v1';gate_run_id=$GateRunId;started_at_utc=$gateStarted.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");completed_at_utc=$gateCompleted.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");status='passed';fake_adb=$true;real_adb_call_count=[long]0;test_case_count=[long]$script:TL1C1bRequiredOfflineCoverage.Count;coverage_case_count=[long]$script:TL1C1bRequiredOfflineCoverage.Count;coverage=$script:TL1C1bRequiredOfflineCoverage;claims=[ordered]@{runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}}
        [void](ConvertFrom-TL1C1bOfflineSummary ($summary|ConvertTo-Json -Depth 8 -Compress) $GateRunId $gateStarted $gateCompleted $gateElapsed)
        foreach($mutation in @('extra','fake','count','claim','reversed','old','future','overlong','elapsed_mismatch')){
            $x=($summary|ConvertTo-Json -Depth 8)|ConvertFrom-Json -DateKind String;$testGateStarted=$gateStarted;$testGateCompleted=$gateCompleted;$testElapsed=$gateElapsed
            switch($mutation){
                extra{$x|Add-Member extra $true};fake{$x.fake_adb=$false};count{$x.test_case_count--};claim{$x.claims.runtime_evidence=$true}
                reversed{$x.started_at_utc=$gateCompleted.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$x.completed_at_utc=$gateStarted.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'")}
                old{$x.started_at_utc=$gateStarted.AddMinutes(-4).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$x.completed_at_utc=$gateCompleted.AddMinutes(-4).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$testGateStarted=$gateStarted.AddMinutes(-4);$testGateCompleted=$gateCompleted.AddMinutes(-4)}
                future{$x.started_at_utc=$gateStarted.AddMinutes(4).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$x.completed_at_utc=$gateCompleted.AddMinutes(4).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$testGateStarted=$gateStarted.AddMinutes(4);$testGateCompleted=$gateCompleted.AddMinutes(4)}
                overlong{$x.started_at_utc=$gateCompleted.AddMinutes(-11).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");$testGateStarted=$gateCompleted.AddMinutes(-11);$testElapsed=[long]660000}
                elapsed_mismatch{$testElapsed=[long]90000}
            }
            Assert-Throws {ConvertFrom-TL1C1bOfflineSummary ($x|ConvertTo-Json -Depth 8 -Compress) $GateRunId $testGateStarted $testGateCompleted $testElapsed} "summary $mutation 欺骗未拒绝"
        }
    }
    $e2ePath=Join-Path $PSScriptRoot 'tablet-layout-c1b-host-e2e.ps1';$e2eRaw=& (Get-Process -Id $PID).Path -NoProfile -File $e2ePath
    if($LASTEXITCODE-ne0){throw 'actual runner fake-ADB E2E 失败。'};$e2e=$e2eRaw|ConvertFrom-Json
    Assert-True ($e2e.schema-ceq'tablet-layout-c1b-host-e2e/v1'-and$e2e.status-ceq'passed'-and$e2e.fake_adb) 'E2E summary 欺骗'
    foreach($coverage in @('runner_e2e_success','runner_e2e_result_control_abort','runner_e2e_malformed_abort_fail_closed','runner_e2e_tamper_abort')){Assert-True ($e2e.coverage-ccontains$coverage) "E2E coverage 缺失 $coverage";$passed.Add($coverage)}
    Assert-True ($passed.Count-eq$script:TL1C1bRequiredOfflineCoverage.Count) 'coverage case count 漂移'
    $completed=[DateTime]::UtcNow;[pscustomobject][ordered]@{schema='tablet-layout-c1b-host-offline-summary/v1';gate_run_id=$GateRunId;started_at_utc=$started.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");completed_at_utc=$completed.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");status='passed';fake_adb=$true;real_adb_call_count=[long]0;test_case_count=[long]$passed.Count;coverage_case_count=[long]$passed.Count;coverage=$passed.ToArray();claims=[ordered]@{runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}}|ConvertTo-Json -Depth 8 -Compress
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue;Remove-Item Env:TL1_C1B_FAKE_ROOT -ErrorAction SilentlyContinue;Remove-Item Env:TL1_C1B_FAKE_RESPONSE -ErrorAction SilentlyContinue}
