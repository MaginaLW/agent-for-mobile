#Requires -Version 7.5
# T-L1 C1b v1 宿主侧闭合协议与独立来源绑定。设备/进程原语复用冻结的 C1a library。

Set-StrictMode -Version 3.0

$script:TL1C1bAuthority = 'dev.magina.gateway.tablet.c1b'
$script:TL1C1bProtocolSchema = 'tablet-c1b-control/v1'
$script:TL1C1bSidecarSchema = 'tablet-layout-c1b-sidecar/v1'
$script:TL1C1bObservationSchema = 'tablet-layout-observation/c1b-v1'
$script:TL1C1bPackageName = 'dev.magina.gateway'
$script:TL1C1bExpectedTitleHash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
$script:TL1C1bRequiredOfflineCoverage = [string[]]@(
    'canonical_uri','fake_adb_exec_in_exact_bytes','fake_adb_read_quoting','control_exact_schema',
    'provider_provenance','replay_rejection','duplicate_capture_rejection','recapture_rejection',
    'bounded_status_success','bounded_status_timeout','host_wait_900ms','single_c1_c2_result',
    'single_install_no_retry_uninstall','controlled_path_hash','sidecar_closed_schema','sidecar_cross_binding',
    'release_debug_boundary','validator_origin_scope','failure_atomic_cleanup','abort_terminal_control_closed',
    'summary_deception_rejection','sdk_adb_trust_root','runner_e2e_success','runner_e2e_result_control_abort',
    'runner_e2e_malformed_abort_fail_closed','runner_e2e_tamper_abort'
)

function Get-TL1C1bAdbTrustBinding {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome
    )
    if(-not[IO.Path]::IsPathFullyQualified($AndroidSdkRoot)-or-not[IO.Path]::IsPathFullyQualified($AndroidHome)){throw 'C1b Android SDK trust root 必须是绝对路径。'}
    $sdk=[IO.Path]::GetFullPath($AndroidSdkRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sdkHomeFull=[IO.Path]::GetFullPath($AndroidHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if($sdk-cne$sdkHomeFull){throw 'C1b ANDROID_SDK_ROOT/ANDROID_HOME trust root 不一致。'}
    $platformTools=Join-Path $sdk 'platform-tools';$canonical=[IO.Path]::GetFullPath((Join-Path $platformTools 'adb.exe'))
    foreach($directory in @($sdk,$platformTools)){
        if(-not(Test-Path -LiteralPath $directory -PathType Container)-or((Get-Item $directory -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'C1b Android SDK trust root 非 ordinary directory。'}
    }
    $actual=[IO.Path]::GetFullPath($AdbPath)
    if($actual-cne$canonical-or-not(Test-Path -LiteralPath $actual -PathType Leaf)-or((Get-Item $actual -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'C1b adb 必须是 canonical Android SDK platform-tools/adb.exe ordinary file。'}
    $version=Invoke-TL1C1aProcess -FilePath $actual -Arguments @('version') -Operation 'C1b adb trust identity' -TimeoutSec 10
    if($version.Stderr.Length-ne0){throw 'C1b adb version stderr 必须 exact empty。'}
    $lines=@($version.Text-split'\r?\n'|Where-Object{$_.Length-ne0})
    if($lines.Count-lt3-or$lines.Count-gt4-or$lines[0]-cnotmatch'^Android Debug Bridge version ([0-9]+\.[0-9]+\.[0-9]+)$'-or
       $lines[1]-cnotmatch'^Version ([A-Za-z0-9][A-Za-z0-9._-]{0,79})$'-or$lines[2]-cnotmatch'^Installed as (.+)$'){
        throw 'C1b adb version identity grammar 错误。'
    }
    if([IO.Path]::GetFullPath($Matches[1])-cne$canonical){throw 'C1b adb version Installed-as 未绑定 canonical executable。'}
    return [ordered]@{trust_root='android_sdk_platform_tools';canonical_relative_path='platform-tools/adb.exe';sdk_roots_equal=$true
        executable_sha256=Get-TL1C1aFileSha256 $actual;version_output_sha256=Get-TL1C1aSha256Bytes $version.Bytes
        protocol_version=([regex]::Match($lines[0],'^Android Debug Bridge version (.+)$').Groups[1].Value)
        package_version=([regex]::Match($lines[1],'^Version (.+)$').Groups[1].Value);installed_as_canonical=$true}
}

function New-TL1C1bUri {
    param(
        [Parameter(Mandatory)][ValidateSet('t0','status','c1','c2','result','abort')][string]$Endpoint,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Nonce,
        [string]$ExpectedCommitSha,
        [string]$ArtifactSha256
    )
    if ($RunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { throw 'C1b run_id 格式错误。' }
    if ($Nonce -cnotmatch '^n-[0-9a-f]{32}$') { throw 'C1b nonce 格式错误。' }
    $path = switch ($Endpoint) {
        't0' { "/t0/$RunId" }
        'status' { "/status/$RunId" }
        'c1' { "/capture/c1/$RunId" }
        'c2' { "/capture/c2/$RunId" }
        'result' { "/result/$RunId" }
        'abort' { "/abort/$RunId" }
    }
    $query = [Collections.Generic.List[string]]::new()
    $query.Add("nonce=$Nonce")
    if ($Endpoint -eq 't0') {
        if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
            $ArtifactSha256 -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'C1b T0 URI provenance 参数错误。' }
        $query.Add("title_hash=$script:TL1C1bExpectedTitleHash")
        $query.Add("producer_commit_sha=$ExpectedCommitSha")
        $query.Add("producer_artifact_sha256=$ArtifactSha256")
    }
    return "content://$script:TL1C1bAuthority${path}?" + ($query -join '&')
}

function ConvertTo-TL1C1bContentUriArgument {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][bool]$BinaryStdin
    )
    $runPattern='[a-z0-9][a-z0-9._-]{0,79}';$noncePattern='n-[0-9a-f]{32}'
    $pathPattern=switch($Name){
        content_t0{"t0/$runPattern"};content_status{"status/$runPattern"};content_c1{"capture/c1/$runPattern"}
        content_c2{"capture/c2/$runPattern"};content_result{"result/$runPattern"};content_abort{"abort/$runPattern"}
    }
    $queryPattern=if($Name-ceq'content_t0'){
        'nonce='+$noncePattern+'&title_hash='+[regex]::Escape($script:TL1C1bExpectedTitleHash)+
        '&producer_commit_sha=[0-9a-f]{40}&producer_artifact_sha256=sha256:[0-9a-f]{64}'
    }else{'nonce='+$noncePattern}
    $expected='^content://'+[regex]::Escape($script:TL1C1bAuthority)+'/'+$pathPattern+'\?'+$queryPattern+'$'
    if($Uri-cnotmatch$expected-or$Uri-match"['\x00-\x20\x7f%+]"){throw 'C1b Content URI 不符合 fixed closed grammar。'}
    if(($Name-ceq'content_t0')-ne$BinaryStdin){throw 'C1b Content URI transport 与 endpoint 不一致。'}
    if($BinaryStdin){return $Uri};return "'$Uri'"
}

function Invoke-TL1C1bAdb {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][ValidateSet(
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [byte[]]$InputBytes,
        [int]$TimeoutSec=30
    )
    $argument=ConvertTo-TL1C1bContentUriArgument -Name $Name -Uri $Value -BinaryStdin:($Name-ceq'content_t0')
    $tail=switch($Name){
        content_t0{@('exec-in','content','write','--uri',$argument)}
        content_status{@('shell','content','read','--uri',$argument)}
        content_c1{@('shell','content','read','--uri',$argument)}
        content_c2{@('shell','content','read','--uri',$argument)}
        content_result{@('shell','content','read','--uri',$argument)}
        content_abort{@('shell','content','read','--uri',$argument)}
    }
    $result=Invoke-TL1C1aProcess -FilePath $AdbPath -Arguments (@('-s',$Serial)+$tail) `
        -Operation "C1b adb/$Name" -InputBytes $InputBytes -TimeoutSec $TimeoutSec
    if($result.Stderr.Length-ne0){throw "C1b adb/$Name stderr 必须 exact empty。"}
    return $result
}

function Assert-TL1C1bExactObjectKeys {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string[]]$Expected,[string]$Name='object')
    if ($Value -isnot [pscustomobject]) { throw "C1b $Name 必须是 JSON object。" }
    $actual = [string[]]@($Value.PSObject.Properties.Name)
    $copy = [string[]]@($Expected)
    [Array]::Sort($actual,[StringComparer]::Ordinal); [Array]::Sort($copy,[StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($copy -join "`n")) { throw "C1b $Name 字段集合漂移。" }
}

function ConvertFrom-TL1C1bClosedJson {
    param([Parameter(Mandatory)][string]$Raw)
    $document=$null
    try{
        $document=[Text.Json.JsonDocument]::Parse($Raw)
        $duplicates=[Collections.Generic.List[string]]::new();Find-TL1C1BV1DuplicateJsonProperty $document.RootElement '' $duplicates
        $invalidNumbers=[Collections.Generic.List[string]]::new();Find-TL1C1BV1InvalidNumber $document.RootElement '' $invalidNumbers
        if($duplicates.Count-ne0-or$invalidNumbers.Count-ne0){throw 'C1b closed JSON 含 duplicate key 或非 Int64 number。'}
        return $Raw|ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    }catch{throw 'C1b closed JSON strict parse 失败。'}finally{if($null-ne$document){$document.Dispose()}}
}

function ConvertFrom-TL1C1bControl {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$BuildChallenge
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt 65536 -or $Raw -match '[\r\n]') {
        throw 'C1b control 必须是 64 KiB 内单行 JSON。'
    }
    $issues = [Collections.Generic.List[object]]::new()
    $value = ConvertFrom-TL1C1BV1StrictJson $Raw $issues
    if ($null -eq $value -or $issues.Count -ne 0) { throw 'C1b control 不是 strict JSON。' }
    Assert-TL1C1bExactObjectKeys $value @(
        'schema','ok','run_id','generation','state','next','reason_code','in_flight_token',
        'c1_requests_accepted','c2_requests_accepted','committed_tokens','recapture_count',
        'expected_title_hash','producer_commit_sha','producer_artifact_sha256','provider'
    ) 'control'
    Assert-TL1C1bExactObjectKeys $value.provider @(
        'authority','protocol_version','package_name','version_name','version_code',
        'embedded_git_head','build_challenge','a11y_service_ready'
    ) 'control/provider'
    foreach ($name in @('schema','run_id','state','next')) {
        if ($value.$name -isnot [string]) { throw "C1b control/$name 类型错误。" }
    }
    foreach ($name in @('reason_code','in_flight_token','expected_title_hash','producer_commit_sha','producer_artifact_sha256')) {
        if ($null -ne $value.$name -and $value.$name -isnot [string]) { throw "C1b control/$name 类型错误。" }
    }
    foreach ($name in @('generation','c1_requests_accepted','c2_requests_accepted','recapture_count')) {
        if ($value.$name -isnot [long]) { throw "C1b control/$name 类型错误。" }
    }
    if ($value.ok -isnot [bool] -or $value.committed_tokens -isnot [object[]]) { throw 'C1b control scalar/list 类型错误。' }
    foreach ($token in @($value.committed_tokens)) { if ($token -isnot [string]) { throw 'C1b committed token 类型错误。' } }
    foreach ($name in @('authority','protocol_version','package_name','version_name','embedded_git_head','build_challenge')) {
        if ($value.provider.$name -isnot [string]) { throw "C1b provider/$name 类型错误。" }
    }
    if ($value.provider.version_code -isnot [long] -or $value.provider.a11y_service_ready -isnot [bool]) {
        throw 'C1b provider scalar 类型错误。'
    }
    if ($value.schema -cne $script:TL1C1bProtocolSchema -or $value.run_id -cne $RunId -or
        $value.recapture_count -ne 0 -or $value.provider.authority -cne $script:TL1C1bAuthority -or
        $value.provider.protocol_version -cne '1' -or $value.provider.package_name -cne $script:TL1C1bPackageName -or
        $value.provider.embedded_git_head -cne $ExpectedCommitSha -or
        $value.provider.build_challenge -cne $BuildChallenge -or
        $value.provider.version_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $value.provider.version_code -lt 1) { throw 'C1b control provider/build 绑定失败。' }
    if ($value.state -eq 'absent') {
        if ($null -ne $value.expected_title_hash -or $null -ne $value.producer_commit_sha -or
            $null -ne $value.producer_artifact_sha256) { throw 'C1b absent control 夹带 producer binding。' }
    } elseif ($value.expected_title_hash -cne $script:TL1C1bExpectedTitleHash -or
        $value.producer_commit_sha -cne $ExpectedCommitSha -or
        $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256) {
        throw 'C1b control producer binding 失败。'
    }
    return $value
}

function Assert-TL1C1bControlTuple {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][string]$ExpectedState,
        [Parameter(Mandatory)][string]$ExpectedNext,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][int]$C1Count,
        [Parameter(Mandatory)][int]$C2Count,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Committed,
        [AllowNull()][object]$InFlight
    )
    if ($null -ne $InFlight -and $InFlight -cnotin @('c1','c2')) { throw 'C1b expected in-flight token 错误。' }
    if ($Control.ok -ne ($ExpectedState -in @('ready_c1','capturing_c1','ready_c2','capturing_c2','complete')) -or
        $Control.state -cne $ExpectedState -or $Control.next -cne $ExpectedNext -or
        [long]$Control.generation -ne $Generation -or [long]$Control.c1_requests_accepted -ne $C1Count -or
        [long]$Control.c2_requests_accepted -ne $C2Count -or $Control.in_flight_token -cne $InFlight -or
        [long]$Control.recapture_count -ne 0 -or
        $null -ne $Control.reason_code -or (@($Control.committed_tokens) -join "`n") -cne ($Committed -join "`n")) {
        throw 'C1b control state/counter/prefix tuple 不一致。'
    }
}

function Assert-TL1C1bAbortTerminalControl {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][long]$ExpectedGeneration,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$ExpectedC1Count,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$ExpectedC2Count,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedCommitted
    )
    $expectedTuple="$ExpectedC1Count|$ExpectedC2Count|$($ExpectedCommitted-join',')"
    if($ExpectedGeneration-lt0-or$expectedTuple-cnotin@('0|0|','1|0|','1|0|c1','1|1|c1','1|1|c1,c2')){
        throw 'C1b abort 发起前 snapshot 不在闭合 prefix。'
    }
    $reasonAllowed=switch([string]$Control.state){
        absent {@('coordinator_closed','nonce_reused','replay_ledger_full','run_id_reused','session_not_found')}
        failed {@('a11y_service_replaced','a11y_service_unavailable','build_identity_mismatch','capture_c1_failed','capture_c1_timeout','capture_c2_failed','capture_c2_timeout','capture_sequence_invalid','capture_timeout_scheduler_rejected','capture_worker_inline','capture_worker_rejected','observation_assembly_failed','session_expiry_scheduler_rejected','start_replayed','t0_invalid')}
        aborted {@('coordinator_shutdown','session_aborted')}
        expired {@('session_expired')}
        default {throw 'C1b abort 未进入允许终态。'}
    }
    if(($Control.state-cin@('failed','aborted')-and$expectedTuple-ceq'1|1|c1,c2')-or
        ($Control.state-ceq'expired'-and$ExpectedGeneration-lt1)){
        throw 'C1b abort terminal state/prefix 组合不在 producer 协议内。'
    }
    if($Control.ok-or$Control.next-cne'none'-or$null-ne$Control.in_flight_token-or
        [long]$Control.recapture_count-ne0-or$Control.reason_code-isnot[string]-or
        $reasonAllowed-cnotcontains[string]$Control.reason_code){
        throw 'C1b abort terminal scalar/reason tuple 不闭合。'
    }
    if($Control.state-ceq'absent'){
        if([long]$Control.generation-ne0-or[long]$Control.c1_requests_accepted-ne0-or
            [long]$Control.c2_requests_accepted-ne0-or@($Control.committed_tokens).Count-ne0){
            throw 'C1b absent abort 必须是 exact empty/reset tuple。'
        }
        return
    }
    if([long]$Control.generation-ne$ExpectedGeneration-or
        [long]$Control.c1_requests_accepted-ne$ExpectedC1Count-or
        [long]$Control.c2_requests_accepted-ne$ExpectedC2Count-or
        (@($Control.committed_tokens)-join"`n")-cne($ExpectedCommitted-join"`n")){
        throw 'C1b abort terminal 未绑定发起前 trusted snapshot。'
    }
}

function Wait-TL1C1bTerminalState {
    param(
        [Parameter(Mandatory)][scriptblock]$ReadStatus,
        [Parameter(Mandatory)][ValidateSet('ready_c2','complete')][string]$ExpectedState,
        [Parameter(Mandatory)][long]$Generation,
        [int]$MaximumPolls = 40,
        [int]$PollMilliseconds = 100,
        [scriptblock]$Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
    )
    if ($MaximumPolls -notin 1..100 -or $PollMilliseconds -notin 10..1000) { throw 'C1b poll 边界错误。' }
    $capturingState = if ($ExpectedState -eq 'ready_c2') { 'capturing_c1' } else { 'capturing_c2' }
    for ($index=0; $index -lt $MaximumPolls; $index++) {
        $control = & $ReadStatus
        if ($control.state -ceq $ExpectedState) {
            if ($ExpectedState -eq 'ready_c2') {
                Assert-TL1C1bControlTuple $control ready_c2 capture_c2 $Generation 1 0 @('c1') $null
            } else {
                Assert-TL1C1bControlTuple $control complete read_result $Generation 1 1 @('c1','c2') $null
            }
            return $control
        }
        if ($control.state -cne $capturingState) { throw "C1b status 提前终止：$($control.state)/$($control.reason_code)。" }
        if ($capturingState -eq 'capturing_c1') {
            Assert-TL1C1bControlTuple $control capturing_c1 wait $Generation 1 0 @() 'c1'
        } else {
            Assert-TL1C1bControlTuple $control capturing_c2 wait $Generation 1 1 @('c1') 'c2'
        }
        if ($index + 1 -lt $MaximumPolls) { & $Sleep $PollMilliseconds }
    }
    throw "C1b status bounded poll 超时：$ExpectedState。"
}

function Get-TL1C1bTranscriptSha256 {
    param([Parameter(Mandatory)][string[]]$RawControls)
    if ($RawControls.Count -lt 3 -or $RawControls.Count -gt 100 -or @($RawControls | Where-Object { $_ -match '[\r\n]' }).Count) {
        throw 'C1b control transcript 数量或格式错误。'
    }
    return Get-TL1C1aSha256Text ($RawControls -join "`n")
}

function Assert-TL1C1bPublishedEvidenceBinding {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Artifacts
    )
    foreach ($entry in $Artifacts.GetEnumerator()) {
        $path = Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path ([string]$entry.Key)
        if ((Get-TL1C1aFileSha256 $path) -cne [string]$entry.Value) { throw "C1b published artifact 漂移：$path。" }
    }
}

function Assert-TL1C1bSidecarCrossBindings {
    param([Parameter(Mandatory)]$Sidecar)
    $expectedT0Path="docs/runs/evidence/$($Sidecar.run_id)/tablet-profile.json"
    if ($Sidecar.apk.local_sha256_before -cne $Sidecar.apk.local_sha256_after -or
        $Sidecar.transport.trust_root -cne 'android_sdk_platform_tools' -or
        $Sidecar.transport.canonical_relative_path -cne 'platform-tools/adb.exe' -or
        -not $Sidecar.transport.sdk_roots_equal -or -not $Sidecar.transport.installed_as_canonical -or
        $Sidecar.transport.executable_sha256_before -cne $Sidecar.transport.executable_sha256_after -or
        $Sidecar.transport.version_output_sha256_before -cne $Sidecar.transport.version_output_sha256_after -or
        $Sidecar.apk.local_sha256_before -cne $Sidecar.apk.installed_base_apk_sha256_before -or
        $Sidecar.apk.local_sha256_before -cne $Sidecar.apk.installed_base_apk_sha256_after -or
        $Sidecar.apk.installed_base_apk_path_hash_before -cne $Sidecar.apk.installed_base_apk_path_hash_after -or
        $Sidecar.apk.package_name_before -cne $Sidecar.apk.package_name_after -or
        $Sidecar.apk.version_name_before -cne $Sidecar.apk.version_name_after -or
        [long]$Sidecar.apk.version_code_before -ne [long]$Sidecar.apk.version_code_after -or
        $Sidecar.provider.package_name -cne $Sidecar.apk.package_name_before -or
        $Sidecar.provider.version_name -cne $Sidecar.apk.version_name_before -or
        [long]$Sidecar.provider.version_code -ne [long]$Sidecar.apk.version_code_before -or
        $Sidecar.device.serial_hash_before -cne $Sidecar.device.serial_hash_after -or
        $Sidecar.device.fingerprint_hash_before -cne $Sidecar.device.fingerprint_hash_after -or
        $Sidecar.device.boot_id_hash_before -cne $Sidecar.device.boot_id_hash_after -or
        -not $Sidecar.device.unique_device_before_after -or
        $Sidecar.expected_commit_sha -cne $Sidecar.provider.embedded_git_head -or
        $Sidecar.provider.producer_artifact_sha256 -cne $Sidecar.apk.local_sha256_before -or
        $Sidecar.upstream_t0.original_sha256 -cne $Sidecar.artifacts.upstream_t0.sha256 -or
        $Sidecar.upstream_t0.original_relative_path -cne $expectedT0Path -or
        $Sidecar.artifacts.upstream_t0.relative_path -cne 'upstream-t0-v5.json' -or
        $Sidecar.artifacts.observation.relative_path -cne 'tablet-layout-observation-c1b-v1.json' -or
        $Sidecar.artifacts.validation.relative_path -cne 'tablet-layout-observation-validation-c1b-v1.json' -or
        $Sidecar.capture.c1_requests_accepted -ne 1 -or
        $Sidecar.capture.c2_requests_accepted -ne 1 -or $Sidecar.capture.recapture_count -ne 0 -or
        $Sidecar.capture.status_poll_count -lt 1 -or $Sidecar.capture.result_read_count -ne 1 -or
        $Sidecar.capture.host_wait_ms -lt 900 -or $Sidecar.capture.total_span_ms -lt $Sidecar.capture.host_wait_ms -or
        $Sidecar.capture.total_span_ms -gt 15000 -or
        $Sidecar.apk.install_attempt_count -ne 1 -or $Sidecar.apk.uninstall_count -ne 0 -or
        $Sidecar.apk.automatic_retry_count -ne 0 -or $Sidecar.upstream_t0.exec_in_write_count -ne 1 -or
        -not $Sidecar.claims.runtime_origin_verified -or -not $Sidecar.claims.runtime_evidence) {
        throw 'C1b sidecar cross-binding 不成立。'
    }
    try{
        $c1Requested=[DateTimeOffset]::ParseExact($Sidecar.capture.c1_requested_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c1Committed=[DateTimeOffset]::ParseExact($Sidecar.capture.c1_committed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c2Requested=[DateTimeOffset]::ParseExact($Sidecar.capture.c2_requested_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c2Committed=[DateTimeOffset]::ParseExact($Sidecar.capture.c2_committed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    }catch{throw 'C1b sidecar capture timestamp 解析失败。'}
    if($c1Committed-lt$c1Requested-or$c2Requested-lt$c1Committed-or$c2Committed-lt$c2Requested-or
       ($c2Requested-$c1Committed).TotalMilliseconds-lt900){throw 'C1b sidecar capture timestamp/host wait 不成立。'}
    foreach ($stem in @('wechat_window_ownership','window_root_projection','application_window_topology','ime_hidden')) {
        if ([bool]$Sidecar.claims."${stem}_observed" -ne [bool]$Sidecar.claims."${stem}_verified") {
            throw "C1b sidecar observed/verified 不等价：$stem。"
        }
    }
}

function ConvertFrom-TL1C1bOfflineSummary {
    param([Parameter(Mandatory)][string]$Raw,[Parameter(Mandatory)][string]$ExpectedGateRunId)
    if([Text.Encoding]::UTF8.GetByteCount($Raw)-gt65536-or$Raw-match'[\r\n]'){throw 'C1b offline summary 必须是单行 bounded JSON。'}
    $issues=[Collections.Generic.List[object]]::new();$value=ConvertFrom-TL1C1BV1StrictJson $Raw $issues
    if($null-eq$value-or$issues.Count-ne0){throw 'C1b offline summary 不是 strict JSON。'}
    Assert-TL1C1bExactObjectKeys $value @('schema','gate_run_id','started_at_utc','completed_at_utc','status','fake_adb','real_adb_call_count','test_case_count','coverage_case_count','coverage','claims') 'offline-summary'
    Assert-TL1C1bExactObjectKeys $value.claims @('runtime_origin_verified','runtime_evidence','layout_accepted','wechat_layout_verified','editor_action_ready','p0_capability','execution_grant') 'offline-summary/claims'
    if($value.schema-cne'tablet-layout-c1b-host-offline-summary/v1'-or$value.gate_run_id-cne$ExpectedGateRunId-or
       $value.status-cne'passed'-or$value.fake_adb-isnot[bool]-or-not$value.fake_adb-or
       $value.real_adb_call_count-isnot[long]-or$value.real_adb_call_count-ne0-or
       $value.test_case_count-isnot[long]-or$value.coverage_case_count-isnot[long]-or
       $value.test_case_count-ne$script:TL1C1bRequiredOfflineCoverage.Count-or$value.coverage_case_count-ne$value.test_case_count-or
       $value.coverage-isnot[object[]]-or(@($value.coverage|Select-Object -Unique)).Count-ne$value.coverage.Count-or
       (@($value.coverage|Sort-Object -CaseSensitive)-join"`n")-cne(@($script:TL1C1bRequiredOfflineCoverage|Sort-Object -CaseSensitive)-join"`n")-or
       @($value.claims.PSObject.Properties|Where-Object{$_.Name-cne'p0_capability'-and($_.Value-isnot[bool]-or$_.Value)}).Count-ne0-or
       $value.claims.p0_capability-cne'unsupported'){
        throw 'C1b offline summary 结论、计数或 coverage 绑定失败。'
    }
    try{$started=[DateTimeOffset]::ParseExact($value.started_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal);$completed=[DateTimeOffset]::ParseExact($value.completed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)}catch{throw 'C1b offline summary 时间戳错误。'}
    if($completed-lt$started-or($completed-$started).TotalMinutes-gt2-or([DateTimeOffset]::UtcNow-$completed).Duration().TotalMinutes-gt2){throw 'C1b offline summary freshness/span 失败。'}
    return $value
}
