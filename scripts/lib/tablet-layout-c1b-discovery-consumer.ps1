#Requires -Version 7.5
# Read-only C1b discovery collector/reader and an ignored-directory freeze helper.
# Caller loads tablet-layout-c1a.ps1, tablet-layout-observation-v2-validator.ps1,
# tablet-layout-observation-c1b-v1-validator.ps1, and tablet-layout-c1b.ps1 first.

function Assert-TL1C1bConsumer([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "C1b discovery consumer: $Message" }
}

function Test-TL1C1bConsumerInteger($Value) {
    return ($Value -is [int] -or $Value -is [long])
}

function Assert-TL1C1bConsumerTime($Value,[string]$Name) {
    $parsed=[DateTimeOffset]::MinValue
    Assert-TL1C1bConsumer ($Value -is [string] -and
        [DateTimeOffset]::TryParse($Value,[ref]$parsed) -and
        $parsed.Offset-eq[TimeSpan]::Zero) "$Name 时间无效。"
}

function Assert-TL1C1bConsumerRaw($Value,[string]$Name) {
    Assert-TL1C1bExactObjectKeys $Value @('byte_length','sha256','encoding','data') $Name
    Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $Value.byte_length) -and
        $Value.byte_length-ge0 -and $Value.byte_length-le65536 -and
        $Value.sha256 -is [string] -and $Value.sha256 -cmatch '^sha256:[0-9a-f]{64}$' -and
        $Value.encoding -ceq 'base64' -and $Value.data -is [string] -and
        $Value.data -cmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$') "$Name raw 元数据无效。"
    $bytes=[Convert]::FromBase64String($Value.data)
    try {
        Assert-TL1C1bConsumer ($bytes.Length-eq$Value.byte_length -and
            [Convert]::ToBase64String($bytes)-ceq$Value.data -and
            ('sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant())-ceq$Value.sha256) "$Name raw 长度/hash/编码不一致。"
    } finally { if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)} }
}

function Assert-TL1C1bConsumerDiscovery($Value) {
    if($null-eq$Value){return}
    Assert-TL1C1bExactObjectKeys $Value @(
        'started_utc','completed_utc','actual_exit','device_count','device_states','outcome',
        'failure_stage','client_failure_substage','stdout_capture_status','stdout_observed_byte_count',
        'stderr_capture_status','stderr_observed_byte_count','stderr_capture_basis','stdout','stderr'
    ) 'discovery'
    Assert-TL1C1bConsumerTime $Value.started_utc 'discovery/started'
    Assert-TL1C1bConsumerTime $Value.completed_utc 'discovery/completed'
    if($null-ne$Value.actual_exit){Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $Value.actual_exit)) 'actual_exit 类型错误。'}
    if($null-ne$Value.device_count){
        Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $Value.device_count) -and $Value.device_count-ge0 -and
            $Value.device_states -is [array] -and $Value.device_states.Count-eq$Value.device_count) 'device_count/states 不一致。'
        foreach($state in $Value.device_states){Assert-TL1C1bConsumer ($state -cin @('device','offline','unauthorized','no permissions')) 'device state 未知。'}
    }else{Assert-TL1C1bConsumer ($null-eq$Value.device_states) '未知设备数被写成已知状态。'}
    Assert-TL1C1bConsumer ($Value.outcome -cin @('succeeded','failed')) 'discovery outcome 未知。'
    Assert-TL1C1bConsumer ($Value.failure_stage -cin @($null,'endpoint','client','parser','device_count','device_state','serial')) 'failure_stage 未知。'
    if($Value.outcome-ceq'succeeded'){
        Assert-TL1C1bConsumer ($null-eq$Value.failure_stage -and $Value.device_count-eq1 -and
            $Value.device_states[0]-ceq'device') '成功设备发现事实不一致。'
    }else{Assert-TL1C1bConsumer ($null-ne$Value.failure_stage) '失败缺少阶段。'}
    if($null-ne$Value.client_failure_substage){
        Assert-TL1C1bConsumer ($Value.failure_stage-ceq'client' -and $Value.client_failure_substage -cin @(
            'create-job','start','job_membership','stream_start','stdin','process_wait','output_overflow',
            'timeout','stream_drain','stderr_utf8','stdout_utf8','process_exit','postcondition','diagnostic','cleanup')) 'client_failure_substage 未知。'
    }
    foreach($name in @('stdout','stderr')){
        $status=$Value.($name+'_capture_status');$observed=$Value.($name+'_observed_byte_count');$raw=$Value.$name
        $allowed=if($name-ceq'stdout'){@('complete','over_limit','unavailable')}else{@('complete','over_limit','unavailable','encoding_failed')}
        Assert-TL1C1bConsumer ($status -cin $allowed) "$name capture status 未知。"
        if($null-ne$observed){Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $observed)-and$observed-ge0) "$name observed length 无效。"}
        if($status-ceq'complete'){
            Assert-TL1C1bConsumer ($null-ne$raw -and $null-ne$observed) "$name 完整流缺少 raw/长度。"
            Assert-TL1C1bConsumerRaw $raw "discovery/$name"
            Assert-TL1C1bConsumer ($raw.byte_length-eq$observed) "$name 完整流长度不一致。"
        }elseif($status-ceq'over_limit'){
            Assert-TL1C1bConsumer ($null-eq$raw -and $null-ne$observed -and $observed-gt65536) "$name 超限流被伪装。"
        }else{Assert-TL1C1bConsumer ($null-eq$raw) "$name 未取得流不应含 raw。"}
    }
    if($Value.stderr_capture_status -cin @('complete','over_limit')){
        Assert-TL1C1bConsumer ($Value.stderr_capture_basis-ceq'strict_utf8_reencoded_from_process_result') 'stderr 编码来源不符。'
    }else{Assert-TL1C1bConsumer ($null-eq$Value.stderr_capture_basis) 'stderr 未取得却声明编码来源。'}
}

function Assert-TL1C1bConsumerServer($Value) {
    if($null-eq$Value){return}
    Assert-TL1C1bExactObjectKeys $Value @('schema','captured_utc','guard_verified','server_running_verified',
        'server_pid','server_socket','server_executable_sha256','startup_server_status','stdout','stderr') 'server'
    Assert-TL1C1bConsumer ($Value.schema-ceq'tablet-layout-c1b-private-adb-server-diagnostic/v1' -and
        $Value.guard_verified -is [bool] -and $Value.guard_verified -and
        $Value.server_running_verified -is [bool] -and $Value.server_running_verified -and
        (Test-TL1C1bConsumerInteger $Value.server_pid) -and $Value.server_pid-gt0 -and
        $Value.server_socket -is [string] -and $Value.server_socket -cmatch '^tcp:127\.0\.0\.1:[0-9]{1,5}$' -and
        $Value.server_executable_sha256 -is [string] -and
        $Value.server_executable_sha256 -cmatch '^sha256:[0-9a-f]{64}$') 'server 绑定无效。'
    Assert-TL1C1bConsumerTime $Value.captured_utc 'server/captured'
    $status=$Value.startup_server_status
    Assert-TL1C1bExactObjectKeys $status @('availability','captured_utc','encoding','representation','raw') 'server/status'
    if($status.availability-ceq'observed'){
        Assert-TL1C1bConsumerTime $status.captured_utc 'server/status'
        Assert-TL1C1bConsumer ($status.encoding-ceq'strict_utf8' -and
            $status.representation-ceq'lossless_utf8_reencoding_of_validated_client_stdout' -and
            $null-ne$status.raw) 'server/status 来源无效。'
        Assert-TL1C1bConsumerRaw $status.raw 'server/status'
    }else{Assert-TL1C1bConsumer ($status.availability-ceq'unknown' -and $null-eq$status.captured_utc -and
        $null-eq$status.encoding -and $null-eq$status.representation -and $null-eq$status.raw) 'server/status unknown 不一致。'}
    foreach($name in @('stdout','stderr')){
        $stream=$Value.$name
        Assert-TL1C1bExactObjectKeys $stream @('availability','captured_utc','captured_bytes','observed_bytes',
            'maximum_bytes','overflowed','eof_observed','scope','raw') "server/$name"
        Assert-TL1C1bConsumer ($stream.scope-ceq'bounded_inflight_snapshot_not_final_stream_readback') "server/$name scope 无效。"
        if($stream.availability-ceq'observed'){
            Assert-TL1C1bConsumerTime $stream.captured_utc "server/$name"
            Assert-TL1C1bConsumer ($null-ne$stream.raw -and (Test-TL1C1bConsumerInteger $stream.captured_bytes) -and
                $stream.captured_bytes-ge0 -and $stream.captured_bytes-le65536) "server/$name snapshot 元数据无效。"
            Assert-TL1C1bConsumerRaw $stream.raw "server/$name"
            Assert-TL1C1bConsumer ($stream.raw.byte_length-eq$stream.captured_bytes) "server/$name snapshot 长度不一致。"
        }else{Assert-TL1C1bConsumer ($stream.availability-ceq'unknown' -and $null-eq$stream.raw -and
            $null-eq$stream.captured_utc -and $null-eq$stream.captured_bytes) "server/$name unknown 不一致。"}
        if($null-ne$stream.observed_bytes){Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $stream.observed_bytes)-and$stream.observed_bytes-ge0) "server/$name observed bytes 无效。"}
        if($null-ne$stream.maximum_bytes){Assert-TL1C1bConsumer ((Test-TL1C1bConsumerInteger $stream.maximum_bytes)-and$stream.maximum_bytes-ge0) "server/$name maximum bytes 无效。"}
        foreach($flag in @('overflowed','eof_observed')){if($null-ne$stream.$flag){Assert-TL1C1bConsumer ($stream.$flag -is [bool]) "server/$name $flag 类型错误。"}}
    }
}

function Get-TL1C1bDiscoveryEvidenceInventory {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[a-z0-9][a-z0-9._-]{0,79}$')][string]$AttemptId,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{40}$')][string]$ExpectedCommitSha)
    $root=[IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/')
    $evidence=Join-Path $root 'docs/runs/evidence'
    Assert-TL1C1bConsumer (Test-Path -LiteralPath $evidence -PathType Container) 'evidence 根目录不存在。'
    [void](Assert-TL1C1aOrdinaryPath $root (Join-Path $evidence 'placeholder.json') -AllowMissingLeaf)
    $records=[ordered]@{}
    foreach($checkpoint in @('before_install','after_capture')){
        $path=Join-Path $evidence "tablet-layout-c1b-discovery-$AttemptId-$checkpoint.json"
        [void](Assert-TL1C1aOrdinaryPath $root $path -AllowMissingLeaf)
        $records[$checkpoint]=[pscustomobject]@{path=$path;present=[IO.File]::Exists($path)}
    }
    $path=Join-Path $evidence "tablet-layout-c1b-attempt-$AttemptId.json"
    [void](Assert-TL1C1aOrdinaryPath $root $path -AllowMissingLeaf)
    $records.attempt_failure=[pscustomobject]@{path=$path;present=[IO.File]::Exists($path)}
    return [pscustomobject]@{repo_root=$root;attempt_id=$AttemptId;expected_commit_sha=$ExpectedCommitSha;records=$records}
}

function Read-TL1C1bConsumerFile([string]$RepoRoot,[string]$Path,[long]$Limit) {
    $full=Assert-TL1C1aOrdinaryPath $RepoRoot $Path
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        Assert-TL1C1bConsumer ($stream.Length-ge1 -and $stream.Length-le$Limit) '证据文件长度越界。'
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        $hash='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
        $raw=ConvertFrom-TL1C1aStrictUtf8 $bytes 'C1b discovery consumer'
        Assert-TL1C1bConsumer (-not$raw.StartsWith([char]0xfeff)) '证据含 UTF-8 BOM。'
        $value=ConvertFrom-TL1C1bClosedJson $raw
        Assert-TL1C1bConsumer ((Get-TL1C1aFileSha256 $full)-ceq$hash) '证据读取期间发生变化。'
        return [pscustomobject]@{path=$full;bytes=$bytes;sha256=$hash;value=$value}
    }finally{$stream.Dispose()}
}

function Read-TL1C1bDiscoveryEvidenceBundle {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AttemptId,[Parameter(Mandatory)][string]$ExpectedCommitSha,
        [AllowNull()][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('success','failed','needs-user',IgnoreCase=$false)][string]$TerminalStatus)
    $inventory=Get-TL1C1bDiscoveryEvidenceInventory $RepoRoot $AttemptId $ExpectedCommitSha
    # A typed [string] parameter coerces $null to ''; keep an untyped null for
    # the pre-promotion failure path and the JSON manifest.
    $runBinding=if([string]::IsNullOrEmpty($RunId)){$null}else{[string]$RunId}
    if($null-ne$runBinding){Assert-TL1C1bConsumer ($runBinding -cmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -and
        $runBinding-ceq$AttemptId) 'run ID 与 attempt 不一致。'}
    $result=[ordered]@{schema='tablet-layout-c1b-discovery-consumption/v1';attempt_id=$AttemptId;
        expected_commit_sha=$ExpectedCommitSha;run_id=$runBinding;observed_terminal_status=$TerminalStatus;
        checkpoints=[ordered]@{};attempt_failure=$null;acceptance_proven_by_this_bundle=$false}
    foreach($checkpoint in @('before_install','after_capture')){
        $entry=$inventory.records[$checkpoint]
        if(-not$entry.present){$result.checkpoints[$checkpoint]=[ordered]@{status='absent_unknown';path=$null;byte_length=$null;sha256=$null;discovery=$null};continue}
        $file=Read-TL1C1bConsumerFile $inventory.repo_root $entry.path 1048576
        $value=$file.value
        Assert-TL1C1bExactObjectKeys $value @('schema','attempt_id','checkpoint','expected_commit_sha','recorded_at_utc',
            'discovery','server','server_diagnostic_available','diagnostic_only','device_acceptance_verified',
            'cleanup_verified_by_this_record') 'discovery evidence'
        Assert-TL1C1bConsumer ($value.schema-ceq'tablet-layout-c1b-device-discovery-evidence/v1' -and
            $value.attempt_id-ceq$AttemptId -and $value.expected_commit_sha-ceq$ExpectedCommitSha -and
            $value.checkpoint-ceq$checkpoint -and $value.server_diagnostic_available -is [bool] -and
            $value.server_diagnostic_available-eq($null-ne$value.server) -and
            $value.diagnostic_only -is [bool] -and $value.diagnostic_only -and
            $value.device_acceptance_verified -is [bool] -and -not$value.device_acceptance_verified -and
            $value.cleanup_verified_by_this_record -is [bool] -and -not$value.cleanup_verified_by_this_record) 'checkpoint/attempt/SHA/声明不一致。'
        Assert-TL1C1bConsumerTime $value.recorded_at_utc 'discovery/recorded'
        Assert-TL1C1bConsumerDiscovery $value.discovery
        Assert-TL1C1bConsumerServer $value.server
        $result.checkpoints[$checkpoint]=[ordered]@{status='present';path=[IO.Path]::GetRelativePath($inventory.repo_root,$file.path).Replace('\','/');
            byte_length=$file.bytes.Length;sha256=$file.sha256;discovery=if($null-eq$value.discovery){$null}else{
                [ordered]@{outcome=$value.discovery.outcome;failure_stage=$value.discovery.failure_stage;
                    actual_exit=$value.discovery.actual_exit;device_count=$value.discovery.device_count;
                    stdout_capture_status=$value.discovery.stdout_capture_status;stderr_capture_status=$value.discovery.stderr_capture_status}}}
    }
    $attempt=$inventory.records.attempt_failure
    if($attempt.present){
        Assert-TL1C1bConsumer ($null-eq$runBinding -and $TerminalStatus-ceq'failed') 'attempt failure 与 run/终态冲突。'
        $file=Read-TL1C1bConsumerFile $inventory.repo_root $attempt.path 65536
        $value=$file.value
        $schema=Join-Path $inventory.repo_root 'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json'
        Assert-TL1C1bConsumer ((ConvertFrom-TL1C1aStrictUtf8 $file.bytes 'attempt failure')|Test-Json -SchemaFile $schema -ErrorAction Stop) 'attempt failure schema 无效。'
        Assert-TL1C1bAttemptFailureCrossBindings $value
        Assert-TL1C1bConsumer ($value.attempt_id-ceq$AttemptId -and $null-eq$value.run_id -and
            $value.expected_commit_sha-ceq$ExpectedCommitSha) 'attempt failure ID/SHA/run 绑定错误。'
        foreach($checkpoint in @('before_install','after_capture')){
            Assert-TL1C1bConsumer ($result.checkpoints[$checkpoint].status-ceq'absent_unknown') 'run_id=null 失败不能含设备发现。'
            $result.checkpoints[$checkpoint].status='not_reached'
        }
        $result.attempt_failure=[ordered]@{status='present';path=[IO.Path]::GetRelativePath($inventory.repo_root,$file.path).Replace('\','/');
            byte_length=$file.bytes.Length;sha256=$file.sha256;reason_code=$value.reason_code;run_id=$null}
    }else{$result.attempt_failure=[ordered]@{status='absent_unknown';path=$null;byte_length=$null;sha256=$null;reason_code=$null;run_id=$null}}
    Assert-TL1C1bConsumer ($result.checkpoints.after_capture.status-cne'present' -or
        $result.checkpoints.before_install.status-ceq'present') 'after_capture 出现但 before_install 缺失。'
    if($TerminalStatus-ceq'success'){
        Assert-TL1C1bConsumer ($null-ne$runBinding -and $result.checkpoints.before_install.status-ceq'present' -and
            $result.checkpoints.after_capture.status-ceq'present') '成功终态缺少两个检查点。'
        foreach($checkpoint in @('before_install','after_capture')){
            Assert-TL1C1bConsumer ($result.checkpoints[$checkpoint].discovery.outcome-ceq'succeeded' -and
                $result.checkpoints[$checkpoint].discovery.device_count-eq1) '成功终态的设备发现未成功。'
        }
    }
    return [pscustomobject]$result
}

function Freeze-TL1C1bDiscoveryEvidenceBundle {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AttemptId,[Parameter(Mandatory)][string]$ExpectedCommitSha,
        [AllowNull()][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('success','failed','needs-user',IgnoreCase=$false)][string]$TerminalStatus,
        [Parameter(Mandatory)][string]$DestinationDirectory)
    $read=Read-TL1C1bDiscoveryEvidenceBundle -RepoRoot $RepoRoot -AttemptId $AttemptId -ExpectedCommitSha $ExpectedCommitSha -RunId $RunId -TerminalStatus $TerminalStatus
    $root=[IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/')
    $destination=[IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\','/')
    $checks=Join-Path $root '.checks'
    Assert-TL1C1bConsumer ($destination.StartsWith($checks+'\',[StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $destination -PathType Container)) 'freeze 目标必须是仓库 .checks 下既有目录。'
    [void](Assert-TL1C1aOrdinaryPath $root (Join-Path $destination 'freeze-manifest.json') -AllowMissingLeaf)
    Assert-TL1C1bConsumer (@(Get-ChildItem -LiteralPath $destination -Force).Count-eq0) 'freeze 目标目录必须为空。'
    $copies=[Collections.Generic.List[object]]::new()
    foreach($name in @('before_install','after_capture','attempt_failure')){
        $record=if($name-ceq'attempt_failure'){$read.attempt_failure}else{$read.checkpoints[$name]}
        if($record.status-cne'present'){continue}
        $source=Join-Path $root $record.path
        $file=Read-TL1C1bConsumerFile $root $source 1048576
        Assert-TL1C1bConsumer ($file.bytes.Length-eq$record.byte_length -and $file.sha256-ceq$record.sha256) 'freeze 前源证据发生变化。'
        $copies.Add([pscustomobject]@{name=$name;file=$file;source=$record.path;leaf=[IO.Path]::GetFileName($source)})
    }
    $created=[Collections.Generic.List[string]]::new()
    try{
        foreach($copy in $copies){
            $target=Join-Path $destination $copy.leaf
            [void](Assert-TL1C1aOrdinaryPath $root $target -AllowMissingLeaf)
            $stream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $created.Add($target)
            try{$stream.Write($copy.file.bytes);$stream.Flush($true)}finally{$stream.Dispose()}
            Assert-TL1C1bConsumer ((Get-TL1C1aFileSha256 $target)-ceq$copy.file.sha256) 'freeze 副本 hash 读回不一致。'
        }
        $members=[ordered]@{}
        foreach($name in @('before_install','after_capture','attempt_failure')){
            $record=if($name-ceq'attempt_failure'){$read.attempt_failure}else{$read.checkpoints[$name]}
            $members[$name]=[ordered]@{status=$record.status;source_path=$record.path;frozen_file=if($record.status-ceq'present'){
                [IO.Path]::GetFileName($record.path)}else{$null};byte_length=$record.byte_length;sha256=$record.sha256}
        }
        $manifest=[ordered]@{schema='tablet-layout-c1b-discovery-freeze/v1';attempt_id=$AttemptId;
            expected_commit_sha=$ExpectedCommitSha;run_id=$read.run_id;observed_terminal_status=$TerminalStatus;
            members=$members;acceptance_proven_by_this_freeze=$false}
        $manifestPath=Join-Path $destination 'freeze-manifest.json'
        [void](Write-TL1C1aJsonAtomic $root $manifestPath $manifest)
        $created.Add($manifestPath)
        $manifestRead=Read-TL1C1bConsumerFile $root $manifestPath 1048576
        Assert-TL1C1bConsumer ($manifestRead.value.schema-ceq'tablet-layout-c1b-discovery-freeze/v1' -and
            $manifestRead.value.attempt_id-ceq$AttemptId -and $manifestRead.value.expected_commit_sha-ceq$ExpectedCommitSha) 'freeze manifest 读回不一致。'
        return [pscustomobject]@{manifest_path=$manifestPath;manifest_sha256=$manifestRead.sha256;member_count=$copies.Count;readback=$read}
    }catch{
        foreach($path in $created){if(Test-Path -LiteralPath $path -PathType Leaf){Remove-Item -LiteralPath $path -Force}}
        throw
    }finally{
        foreach($copy in $copies){if($copy.file.bytes.Length){[Array]::Clear($copy.file.bytes,0,$copy.file.bytes.Length)}}
    }
}
