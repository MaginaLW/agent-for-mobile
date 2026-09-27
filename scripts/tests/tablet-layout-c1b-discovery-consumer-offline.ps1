#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $source 'scripts/lib/tablet-layout-c1a.ps1')
. (Join-Path $source 'scripts/lib/tablet-layout-observation-v2-validator.ps1')
. (Join-Path $source 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $source 'scripts/lib/tablet-layout-c1b.ps1')
. (Join-Path $source 'scripts/lib/tablet-layout-c1b-discovery-consumer.ps1')
$base=Join-Path $source ('.checks/c1b-discovery-consumer/cases-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
$script:passed=0;$script:failed=0;$script:assertions=0
$script:attemptId='tl1-c1b-20260927t010203z-123456789abc';$script:sha='a'*40
function Check([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Reject([scriptblock]$Body){$message=$null;try{&$Body}catch{$message=$_.Exception.Message};Check ($null-ne$message) 'invalid bundle accepted';return $message}
function New-Repo([string]$Name){
    $repo=Join-Path $base $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $repo 'docs/runs/evidence'))
    [void][IO.Directory]::CreateDirectory((Join-Path $repo '.checks/freeze'))
    [void][IO.Directory]::CreateDirectory((Join-Path $repo 'docs/contracts'))
    Copy-Item -LiteralPath (Join-Path $source 'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json') -Destination (Join-Path $repo 'docs/contracts')
    return $repo
}
function New-Diagnostic([int]$Count=1){
    $bytes=if($Count-eq1){[Text.Encoding]::UTF8.GetBytes("List of devices attached`r`nFAKE123`tdevice`r`n")}
        else{[Text.Encoding]::UTF8.GetBytes("List of devices attached`r`n")}
    return [pscustomobject][ordered]@{
        schema='tablet-layout-device-discovery-diagnostic/v1';started_utc='2026-09-27T01:02:03Z';completed_utc='2026-09-27T01:02:04Z'
        actual_exit=0;device_count=$Count;device_states=[string[]]@(if($Count-eq1){'device'})
        outcome=if($Count-eq1){'succeeded'}else{'failed'};failure_stage=if($Count-eq1){$null}else{'device_count'};client_failure_substage=$null
        stdout_bytes=$bytes;stdout_capture_status='complete';stdout_observed_byte_count=$bytes.Length
        stderr_bytes=[byte[]]@();stderr_capture_status='complete';stderr_observed_byte_count=0
        stderr_capture_basis='strict_utf8_reencoded_from_process_result'
    }
}
function Publish([string]$Repo,[string]$Checkpoint,$Diagnostic){
    return Write-TL1C1bDeviceDiscoveryEvidence -RepoRoot $Repo -AttemptId $script:attemptId `
        -ExpectedCommitSha $script:sha -Checkpoint $Checkpoint -Diagnostic $Diagnostic -ServerDiagnostic $null
}
function Read-Bundle([string]$Repo,[string]$Terminal='failed',[AllowNull()][string]$Run=$null){
    return Read-TL1C1bDiscoveryEvidenceBundle -RepoRoot $Repo -AttemptId $script:attemptId `
        -ExpectedCommitSha $script:sha -RunId $Run -TerminalStatus $Terminal
}
function Freeze-Bundle([string]$Repo,[string]$Terminal='failed',[AllowNull()][string]$Run=$null){
    return Freeze-TL1C1bDiscoveryEvidenceBundle -RepoRoot $Repo -AttemptId $script:attemptId `
        -ExpectedCommitSha $script:sha -RunId $Run -TerminalStatus $Terminal `
        -DestinationDirectory (Join-Path $Repo '.checks/freeze')
}
function Mutate([string]$Path,[scriptblock]$Body){
    $value=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json -Depth 30 -DateKind String
    & $Body $value
    [IO.File]::WriteAllText($Path,($value|ConvertTo-Json -Depth 30 -Compress),[Text.UTF8Encoding]::new($false))
}
function Publish-AttemptFailure([string]$Repo){
    $diagnostic=[ordered]@{schema='tablet-layout-c1b-private-adb-startup-diagnostic/v1';outcome='failed';final_substage='port_selection_timeout';server_attempt_count=0;attempts=@()}
    $value=[ordered]@{
        schema='tablet-layout-c1b-attempt-failure/v1';attempt_id=$script:attemptId;run_id=$null;status='failed'
        reason_code='private_adb_startup_failed';failure_stage='private_adb_startup';expected_commit_sha=$script:sha
        commit_verified=$true;recorded_at_utc='2026-09-27T01:02:03.0000000Z';runner_invocation_count=1;automatic_runner_retry_count=0
        pre_device_operations=[ordered]@{build_completed=$true;artifact_checks_completed=$true;private_adb_guard_created=$false;
            device_discovery_count=0;install_count=0;t0_count=0;c1_count=0;c2_count=0;result_count=0;abort_count=0;capture_count=0}
        private_adb_startup=$diagnostic
        cleanup=[ordered]@{provider_session='not_required';private_adb_startup='not_acquired';private_adb_guard='not_acquired';
            artifact_guards='completed';build_environment='completed';device_lease='completed';overall='completed'}
        runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;
        editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false
    }
    $path=Join-Path $Repo "docs/runs/evidence/tablet-layout-c1b-attempt-$script:attemptId.json"
    [IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 30 -Compress),[Text.UTF8Encoding]::new($false))
    return $path
}

Case 'two checkpoints are collected read and frozen by exact attempt' {
    $repo=New-Repo both
    $first=Publish $repo before_install (New-Diagnostic)
    $second=Publish $repo after_capture (New-Diagnostic)
    $read=Read-Bundle $repo success $script:attemptId
    Check ($read.checkpoints.before_install.status-ceq'present' -and $read.checkpoints.after_capture.status-ceq'present' -and
        $read.attempt_failure.status-ceq'absent_unknown' -and -not$read.acceptance_proven_by_this_bundle) 'reader lost checkpoint or overclaimed acceptance'
    $freeze=Freeze-Bundle $repo success $script:attemptId
    Check ($freeze.member_count-eq2 -and (Test-Path -LiteralPath $freeze.manifest_path)) 'freeze missed two records'
    $manifest=[IO.File]::ReadAllText($freeze.manifest_path)|ConvertFrom-Json -Depth 20
    foreach($name in @('before_install','after_capture')){
        $member=$manifest.members.$name
        $copy=Join-Path $repo ('.checks/freeze/'+$member.frozen_file)
        Check ($member.status-ceq'present' -and $member.sha256-ceq(Get-TL1C1aFileSha256 $copy) -and
            $member.byte_length-eq(Get-Item -LiteralPath $copy).Length) "freeze member $name drift"
    }
    Check ($manifest.members.attempt_failure.status-ceq'absent_unknown' -and -not$manifest.acceptance_proven_by_this_freeze) 'freeze invented attempt failure'
}
Case 'versioned command reads and freezes the producer records' {
    $repo=New-Repo command
    [void](Publish $repo before_install (New-Diagnostic))
    [void](Publish $repo after_capture (New-Diagnostic))
    $commandPath=Join-Path $source 'scripts/read-tablet-layout-c1b-discovery-evidence.ps1'
    $pwsh=Join-Path $PSHOME 'pwsh.exe'
    $readText=(& $pwsh -NoProfile -File $commandPath -Mode Read -RepoRoot $repo `
        -AttemptId $script:attemptId -ExpectedCommitSha $script:sha -RunId $script:attemptId `
        -TerminalStatus success) -join "`n"
    Check ($LASTEXITCODE-eq0) 'versioned Read command failed'
    $read=$readText|ConvertFrom-Json -Depth 20
    Check ($read.checkpoints.before_install.status-ceq'present' -and
        $read.checkpoints.after_capture.status-ceq'present') 'versioned Read command omitted checkpoint'
    $destination=Join-Path $repo '.checks/freeze-command'
    [void][IO.Directory]::CreateDirectory($destination)
    $freezeText=(& $pwsh -NoProfile -File $commandPath -Mode Freeze -RepoRoot $repo `
        -AttemptId $script:attemptId -ExpectedCommitSha $script:sha -RunId $script:attemptId `
        -TerminalStatus success -DestinationDirectory $destination) -join "`n"
    Check ($LASTEXITCODE-eq0) 'versioned Freeze command failed'
    $freeze=$freezeText|ConvertFrom-Json -Depth 20
    Check ($freeze.member_count-eq2 -and (Test-Path -LiteralPath $freeze.manifest_path -PathType Leaf)) `
        'versioned Freeze command did not preserve two records'
}
Case 'first checkpoint failure keeps second absence unknown' {
    $repo=New-Repo first;[void](Publish $repo before_install (New-Diagnostic 0))
    $read=Read-Bundle $repo failed
    Check ($read.checkpoints.before_install.discovery.device_count-eq0 -and
        $read.checkpoints.after_capture.status-ceq'absent_unknown') 'zero-device or absence lost'
    $freeze=Freeze-Bundle $repo failed
    Check ($freeze.member_count-eq1 -and $freeze.readback.checkpoints.after_capture.status-ceq'absent_unknown') 'freeze omitted first failure'
    [void](Reject {Read-Bundle $repo success $script:attemptId})
}
Case 'run id null attempt failure proves neither checkpoint was reached' {
    $repo=New-Repo early;[void](Publish-AttemptFailure $repo)
    $read=Read-Bundle $repo failed
    Check ($null-eq$read.run_id -and $read.attempt_failure.status-ceq'present' -and
        $read.checkpoints.before_install.status-ceq'not_reached' -and $read.checkpoints.after_capture.status-ceq'not_reached') 'early failure not grouped'
    $freeze=Freeze-Bundle $repo failed
    Check ($freeze.member_count-eq1 -and (Test-Path -LiteralPath (Join-Path $repo ('.checks/freeze/tablet-layout-c1b-attempt-'+$script:attemptId+'.json')))) 'early failure not frozen'
    [void](Reject {Read-Bundle $repo failed $script:attemptId})
}
Case 'attempt and SHA binding rejects mismatches' {
    $repo=New-Repo identity;$path=Publish $repo before_install (New-Diagnostic)
    Mutate $path {$args[0].attempt_id='tl1-c1b-other'}
    [void](Reject {Read-Bundle $repo})
    Mutate $path {$args[0].attempt_id=$script:attemptId;$args[0].expected_commit_sha='b'*40}
    [void](Reject {Read-Bundle $repo})
}
Case 'raw length hash and canonical base64 are checked' {
    foreach($kind in @('length','hash','base64')){
        $repo=New-Repo ('raw-'+$kind);$path=Publish $repo before_install (New-Diagnostic)
        switch($kind){
            length {Mutate $path {$args[0].discovery.stdout.byte_length++}}
            hash {Mutate $path {$args[0].discovery.stdout.sha256='sha256:'+('0'*64)}}
            base64 {Mutate $path {$args[0].discovery.stdout.data+=' '}}
        }
        [void](Reject {Read-Bundle $repo})
    }
}
Case 'empty unknown and over limit are distinct' {
    $repo=New-Repo statuses;$diagnostic=New-Diagnostic
    $diagnostic.stdout_bytes=$null;$diagnostic.stdout_capture_status='over_limit';$diagnostic.stdout_observed_byte_count=65537
    $diagnostic.stderr_bytes=$null;$diagnostic.stderr_capture_status='unavailable';$diagnostic.stderr_observed_byte_count=$null;$diagnostic.stderr_capture_basis=$null
    [void](Publish $repo before_install $diagnostic)
    $read=Read-Bundle $repo failed
    Check ($read.checkpoints.before_install.discovery.stdout_capture_status-ceq'over_limit' -and
        $read.checkpoints.before_install.discovery.stderr_capture_status-ceq'unavailable') 'unknown/over-limit collapsed'
    $repo2=New-Repo empty;[void](Publish $repo2 before_install (New-Diagnostic))
    $read2=Read-Bundle $repo2 failed
    Check ($read2.checkpoints.before_install.status-ceq'present' -and
        $read2.checkpoints.before_install.discovery.stderr_capture_status-ceq'complete') 'empty stream rejected'
    $path=Join-Path $repo ("docs/runs/evidence/tablet-layout-c1b-discovery-$($script:attemptId)-before_install.json")
    Mutate $path {$args[0].discovery.stdout_observed_byte_count=0}
    [void](Reject {Read-Bundle $repo})
}
Case 'freeze target failure never publishes a manifest' {
    $repo=New-Repo freeze-failure;[void](Publish $repo before_install (New-Diagnostic 0))
    [IO.File]::WriteAllText((Join-Path $repo '.checks/freeze/blocker.txt'),'blocked')
    [void](Reject {Freeze-Bundle $repo})
    Check (-not(Test-Path -LiteralPath (Join-Path $repo '.checks/freeze/freeze-manifest.json'))) 'failed freeze published manifest'
}
Case 'after checkpoint without first is rejected' {
    $repo=New-Repo after-only;[void](Publish $repo after_capture (New-Diagnostic 0))
    [void](Reject {Read-Bundle $repo failed})
}
"tablet-layout-c1b discovery consumer offline: $($script:passed) passed, $($script:failed) failed, $($script:assertions) assertions; real ADB/device calls=0"
if($script:failed-ne0){exit 1}
