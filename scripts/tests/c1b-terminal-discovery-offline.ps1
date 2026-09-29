#Requires -Version 7.6
[CmdletBinding()]param([string]$CandidateSourceRoot=(Join-Path $PSScriptRoot '../..'))
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'scripts/lib/c1b-terminal-discovery.ps1')
$source=[IO.Path]::GetFullPath($CandidateSourceRoot)
$base=Join-Path $repo ('.checks/goal-20260930/discovery/cases-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
$sha='a'*40;$id='tl1-c1b-20260930t010203z-123456789abc';$passed=0;$failed=0;$assertions=0
function Check([bool]$Condition,[string]$Message){$script:assertions++;if(-not $Condition){throw $Message}}
function Case([string]$Name,[scriptblock]$Body){try{& $Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Reject([scriptblock]$Body,[string]$Pattern=''){$caught=$null;try{& $Body}catch{$caught=$_.Exception};Check ($null -ne $caught) 'invalid input accepted';if($Pattern){Check ($caught.Message -match $Pattern) ('unexpected rejection: '+$caught.Message)}}
function Write-Json([string]$Path,$Value){$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 40 -Compress));[IO.File]::WriteAllBytes($Path,$bytes);return @{bytes=$bytes;sha256=(Get-C1bTdHash $bytes);path=$Path}}
function New-Repo([string]$Name){
    $root=Join-Path $base $Name
    foreach($relative in @((Get-C1bTerminalDiscoverySourcePaths))+@('docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json')){
        $target=Join-Path $root $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes((Join-Path $source $relative)))
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'docs/runs/evidence'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.checks/c1b-device-once/aaaaaaa/r1/discovery-freeze'))
    [IO.File]::WriteAllText((Join-Path $root 'scripts/run-tablet-layout-c1b.ps1'),'# Synthetic runner bytes; never invoked.',[Text.UTF8Encoding]::new($false))
    return $root
}
function New-AttemptFailure {
    return [ordered]@{schema='tablet-layout-c1b-attempt-failure/v1';attempt_id=$id;run_id=$null;status='failed';reason_code='private_adb_startup_failed';failure_stage='private_adb_startup';expected_commit_sha=$sha;commit_verified=$true;
        recorded_at_utc='2026-09-30T01:02:03.0000000Z';runner_invocation_count=1;automatic_runner_retry_count=0;
        pre_device_operations=[ordered]@{build_completed=$true;artifact_checks_completed=$true;private_adb_guard_created=$false;device_discovery_count=0;install_count=0;t0_count=0;c1_count=0;c2_count=0;result_count=0;abort_count=0;capture_count=0};
        private_adb_startup=[ordered]@{schema='tablet-layout-c1b-private-adb-startup-diagnostic/v1';outcome='failed';final_substage='port_selection_timeout';server_attempt_count=0;attempts=@()};
        cleanup=[ordered]@{provider_session='not_required';private_adb_startup='not_acquired';private_adb_guard='not_acquired';artifact_guards='completed';build_environment='completed';device_lease='completed';overall='completed'};
        runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}
}
function Publish-Record([string]$Root,[string]$Kind='attempt_failure'){
    $value=if($Kind -ceq 'attempt_failure'){New-AttemptFailure}else{[ordered]@{schema='tablet-layout-c1b-failure/v2';run_id=$id;status='failed';reason_code='c1b_runner_failed';provider_failure=$null;cleanup='not_required';runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}}
    $relative=if($Kind -ceq 'attempt_failure'){"docs/runs/evidence/tablet-layout-c1b-attempt-$id.json"}else{"docs/runs/evidence/$id/tablet-layout-c1b/tablet-layout-c1b-failure.json"}
    $path=Join-Path $Root $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));$file=Write-Json $path $value
    $reference=[ordered]@{schema='tablet-layout-c1b-failure-reference/v1';attempt_id=$id;run_id=if($Kind -ceq 'attempt_failure'){$null}else{$id};expected_commit_sha=$sha;kind=$Kind;path=$relative;bytes=$file.bytes.Length;sha256=$file.sha256}
    return @{source=@{kind=$Kind;path=$relative;sha256=$file.sha256;byte_length=$file.bytes.Length};reference=$reference;stdout=[Text.UTF8Encoding]::new($false).GetBytes(('C1b failure evidence reference: '+($reference|ConvertTo-Json -Compress)+"`n"));value=$value;file=$file}
}
function New-Fixture([string]$Name,[string]$Kind='attempt_failure'){
    $root=New-Repo $Name;$pins=New-C1bTerminalDiscoverySourcePins $root $sha;$ctx=New-C1bTerminalDiscoveryContext $root $sha $pins
    $record=Publish-Record $root $Kind
    $identity=Get-C1bTerminalDiscoveryIdentity -Context $ctx -TerminalStatus failed -EvidenceSources @($record.source) -RunnerStdoutBytes $record.stdout
    $receipt=Join-Path $root '.checks/c1b-device-once/aaaaaaa/r1'
    [IO.File]::WriteAllBytes((Join-Path $receipt 'runner.stdout.bin'),$record.stdout);[IO.File]::WriteAllBytes((Join-Path $receipt 'runner.stderr.bin'),[byte[]]@())
    $runnerHash=Get-C1bTdHash ([IO.File]::ReadAllBytes((Join-Path $root 'scripts/run-tablet-layout-c1b.ps1')))
    $binding=Write-Json (Join-Path $receipt 'binding.json') ([ordered]@{schema='c1b-device-root-preparation-binding/v1';commit_sha=$sha;repo_root=$root;runner_sha256=$runnerHash;attempt='r1'})
    $once=Write-Json (Join-Path $receipt 'reservation.json') ([ordered]@{schema='c1b-device-cli-once/v1';commit_sha=$sha;runner_sha256=$runnerHash;started_at_utc='2026-09-30T01:02:00Z';automatic_retry_count=0})
    $exit=Write-Json (Join-Path $receipt 'exit.json') ([ordered]@{schema='c1b-device-cli-exit/v1';commit_sha=$sha;runner_sha256=$runnerHash;runner_started=$true;runner_pid=123;runner_exit_code=1;wrapper_failure=$null;started_at_utc='2026-09-30T01:02:00Z';completed_at_utc='2026-09-30T01:02:05Z';automatic_retry_count=0;success_requires_runner_evidence_validation=$true})
    $observer=[ordered]@{schema='c1b-device-external-process-observation/v1';expected_commit_sha=$sha;observation_status='observed';wrapper_started=$true;wrapper_launch_call_count=1;automatic_wrapper_retry_count=0;errors=@();binding_sha256=$binding.sha256;expected_binding_sha256=$binding.sha256;observed_runner_exit=1;observed_wrapper_exit=1;native_wrapper_exit=1;runner_pid=123;wrapper_pid=124}
    $obs=Write-Json (Join-Path $receipt 'external-process-observation.json') $observer
    $terminal=[ordered]@{schema='c1b-device-terminal-readback/v1';verification_status='verified';expected_commit_sha=$sha;cleanup_failure_count=0;readback_external_process_invocation_count=0;readback_device_invocation_count=0;observed_runner_exit=1;runner_exit=1;observed_outer_exit=1;observed_runner_pid=123;runner_pid=123;terminal_status='failed';reservation_sha256='sha256:'+$once.sha256;exit_receipt_sha256='sha256:'+$exit.sha256;stdout_sha256='sha256:'+(Get-C1bTdHash $record.stdout);stdout_byte_length=$record.stdout.Length;stderr_sha256='sha256:'+(Get-C1bTdHash ([byte[]]@()));stderr_byte_length=0;discovery_identity=$identity}
    $term=Write-Json (Join-Path $root '.checks/terminal.json') $terminal
    return @{Root=$root;Pins=$pins;Context=$ctx;Record=$record;Identity=$identity;Receipt=$receipt;Binding=$binding;Observer=$observer;Observation=$obs;Terminal=$terminal;Term=$term}
}
function Freeze-Args($Fixture){return @{Context=$Fixture.Context;TerminalReadbackPath=$Fixture.Term.path;TerminalReadbackSha256=$Fixture.Term.sha256;ReceiptRoot=$Fixture.Receipt;ObservationSha256=$Fixture.Observation.sha256;ExpectedBindingSha256=$Fixture.Binding.sha256}}

Case 'real native guard accepts ordinary source and denies concurrent write, delete and parent rename' {
    $f=New-Fixture native
    try{
        $path=Join-Path $f.Root 'docs/runs/evidence/held.json';[IO.File]::WriteAllText($path,'{}');$bytes=[IO.File]::ReadAllBytes($path)
        [void](Add-C1bTdHeldFile $f.Context $path (Get-C1bTdHash $bytes) $bytes.Length)
        Reject {[IO.File]::WriteAllText($path,'changed')}
        Reject {[IO.File]::Delete($path)}
        Reject {[IO.Directory]::Move([IO.Path]::GetDirectoryName($path),(Join-Path $f.Root 'docs/runs/moved'))}
        Assert-C1bTdContextBound $f.Context
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'real native guard rejects hard-linked evidence and junction parents' {
    $f=New-Fixture links
    try{
        $path=Join-Path $f.Root 'docs/runs/evidence/original.json';[IO.File]::WriteAllText($path,'{}')
        $link=Join-Path $f.Root 'docs/runs/evidence/hard.json';[void](New-Item -ItemType HardLink -Path $link -Target $path)
        Reject {Add-C1bTdHeldFile $f.Context $path (Get-C1bTdHash ([IO.File]::ReadAllBytes($path)))} 'hard-link'
        $target=Join-Path $f.Root '.checks/junction-target';[void][IO.Directory]::CreateDirectory($target);[IO.File]::WriteAllText((Join-Path $target 'a.json'),'{}')
        $junction=Join-Path $f.Root '.checks/junction';[void](New-Item -ItemType Junction -Path $junction -Target $target)
        Reject {Add-C1bTdHeldFile $f.Context (Join-Path $junction 'a.json') (Get-C1bTdHash ([Text.Encoding]::UTF8.GetBytes('{}')))} 'Reparse'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'source pin SHA, count, candidate and held input length reject mismatches' {
    $root=New-Repo pins;$pins=New-C1bTerminalDiscoverySourcePins $root $sha
    $bad=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($pins|ConvertTo-Json -Depth 8)))
    $bad.sources['scripts/lib/tablet-layout-c1a.ps1'].sha256='0'*64
    Reject {New-C1bTerminalDiscoveryContext $root $sha $bad} 'hash differs'
    $bad=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($pins|ConvertTo-Json -Depth 8)));$bad.sources.Remove('scripts/lib/tablet-layout-c1a.ps1')
    Reject {New-C1bTerminalDiscoveryContext $root $sha $bad} 'eight'
    Reject {New-C1bTerminalDiscoveryContext $root ('b'*40) $pins} 'candidate'
    $ctx=New-C1bTerminalDiscoveryContext $root $sha $pins
    try{Reject {Add-C1bTdHeldFile $ctx (Join-Path $root 'scripts/lib/tablet-layout-c1a.ps1') $pins.sources['scripts/lib/tablet-layout-c1a.ps1'].sha256 1} 'length'}finally{Close-C1bTerminalDiscoveryContext $ctx}
}
Case 'early attempt identity uses content and actual stdout pointer and retains null run' {
    $f=New-Fixture early
    try{Check ($f.Identity.attempt_id -ceq $id -and $null -eq $f.Identity.run_id -and $f.Identity.status -ceq 'verified') 'early identity lost null run';$freezeArguments=Freeze-Args $f;$authority=Read-C1bTerminalDiscoveryAuthority @freezeArguments;Check ($authority.identity.status -ceq 'verified') 'authority rejected actual held raw fixture'}finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'current pointer ID, raw SHA, byte length, candidate and duplicate properties are rejected' {
    foreach($mutation in @('id','hash','length','sha','duplicate')){
        $f=New-Fixture ('ref-'+$mutation)
        try{
            $ref=(ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($f.Record.reference|ConvertTo-Json -Compress))))
            switch($mutation){id{$ref.attempt_id='r1'} hash{$ref.sha256='0'*64} length{$ref.bytes++} sha{$ref.expected_commit_sha='b'*40}}
            $line='C1b failure evidence reference: '+($ref|ConvertTo-Json -Compress)
            if($mutation -ceq 'duplicate'){$line=$line.Replace('"kind":"attempt_failure"','"kind":"attempt_failure","kind":"run_failure"')}
            Reject {Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus failed -EvidenceSources @($f.Record.source) -RunnerStdoutBytes ([Text.Encoding]::UTF8.GetBytes($line))}
        }finally{Close-C1bTerminalDiscoveryContext $f.Context}
    }
}
Case 'absence stays unavailable and no r1 or timestamp identity is guessed' {
    $f=New-Fixture absent
    try{
        $identity=Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus failed -EvidenceSources @() -RunnerStdoutBytes ([byte[]]@())
        Check ($identity.status -ceq 'unavailable' -and $null -eq $identity.attempt_id -and $identity.run_id_knowledge -ceq 'unknown') 'absence invented identity'
        Reject {Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus failed -EvidenceSources @($f.Record.source) -RunnerStdoutBytes ([byte[]]@())} 'publication pointer'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'checkpoint internal ID is verified while failed run promotion remains unknown' {
    $f=New-Fixture checkpoint-only
    try{
        $relative="docs/runs/evidence/tablet-layout-c1b-discovery-$id-before_install.json"
        $file=Write-Json (Join-Path $f.Root $relative) ([ordered]@{schema='tablet-layout-c1b-device-discovery-evidence/v1';attempt_id=$id;checkpoint='before_install';expected_commit_sha=$sha;recorded_at_utc='2026-09-30T01:02:03Z';discovery=$null;server=$null;server_diagnostic_available=$false;diagnostic_only=$true;device_acceptance_verified=$false;cleanup_verified_by_this_record=$false})
        $checkpoint=@{kind='checkpoint';path=$relative;sha256=$file.sha256;byte_length=$file.bytes.Length}
        $bytes=[Text.Encoding]::UTF8.GetBytes("C1b discovery evidence: checkpoint=before_install; path=$relative; sha256=sha256:$($file.sha256)`n")
        $identity=Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus failed -EvidenceSources @($checkpoint) -RunnerStdoutBytes $bytes
        Check ($identity.attempt_id -ceq $id -and $identity.status -ceq 'unavailable' -and $identity.run_id_knowledge -ceq 'unknown' -and $identity.unavailable_reason -ceq 'run_promotion_unknown') 'checkpoint guessed run promotion'
        $needs=Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus needs-user -EvidenceSources @($checkpoint) -RunnerStdoutBytes $bytes -CheckpointPrePromotionVerified
        Check ($needs.status -ceq 'verified' -and $null -eq $needs.run_id -and $needs.run_id_knowledge -ceq 'known') 'verified pre-promotion checkpoint lost actual null run'
        Reject {Get-C1bTerminalDiscoveryIdentity -Context $f.Context -TerminalStatus failed -EvidenceSources @() -RunnerStdoutBytes $bytes} 'omitted'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'ended observer tuple, actual binding raw pin and terminal claimed identity reject contradictions' {
    foreach($mutation in @('incomplete','pid','binding','identity')){
        $f=New-Fixture ('authority-'+$mutation)
        try{
            switch($mutation){incomplete{$f.Observer.observation_status='incomplete'} pid{$f.Observer.runner_pid=125} binding{$f.Observer.binding_sha256='0'*64} identity{$f.Terminal.discovery_identity.attempt_id='r1'}}
            if($mutation -ceq 'identity'){$f.Term=Write-Json $f.Term.path $f.Terminal}else{$f.Observation=Write-Json $f.Observation.path $f.Observer}
            $freezeArguments=Freeze-Args $f;Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments}
            Check (-not[IO.File]::Exists((Join-Path $f.Receipt 'discovery-freeze-once.json'))) 'invalid authority reserved Freeze'
        }finally{Close-C1bTerminalDiscoveryContext $f.Context}
    }
}
Case 'actual versioned Read Freeze preserves early not_reached and raw byte identity' {
    $f=New-Fixture freeze
    try{
        $freezeArguments=Freeze-Args $f;$result=Invoke-C1bTerminalDiscoveryFreeze @freezeArguments
        Check ($result.read.checkpoints.before_install.status -ceq 'not_reached' -and $result.read.checkpoints.after_capture.status -ceq 'not_reached' -and $null -eq $result.read.run_id) 'early unreachable stages changed'
        $member=$result.freeze.readback.attempt_failure
        $copy=Join-Path $f.Receipt ('discovery-freeze/'+[IO.Path]::GetFileName($member.path))
        Check ((Get-C1bTdHash ([IO.File]::ReadAllBytes($copy))) -ceq $f.Record.file.sha256) 'raw copy changed'
        Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments} 'already reserved'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'run failure identity preserves absent_unknown checkpoints through real consumer Freeze' {
    $f=New-Fixture unknown run_failure
    try{$freezeArguments=Freeze-Args $f;$result=Invoke-C1bTerminalDiscoveryFreeze @freezeArguments;Check ($result.read.run_id -ceq $id -and $result.read.checkpoints.before_install.status -ceq 'absent_unknown' -and $result.read.checkpoints.after_capture.status -ceq 'absent_unknown' -and -not$result.device_acceptance_proven_by_this_bridge) 'unknown stages became completed or unreached'}finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'synthetic consumer failure retains real permanent reservation and refuses retry' {
    $f=New-Fixture fail-freeze
    try{
        # Fault injection begins only after actual authority and CreateNew reservation.
        $manifest=Join-Path $f.Receipt 'discovery-freeze/freeze-manifest.json'
        $original=${function:Invoke-C1bTdPinnedReader}
        function Invoke-C1bTdPinnedReader($Context,[string]$Mode,$Identity,[string]$TerminalStatus,[string]$DestinationDirectory=''){
            if($Mode -ceq 'Freeze'){throw 'synthetic consumer failure after reservation'}
            return & $original $Context $Mode $Identity $TerminalStatus $DestinationDirectory
        }
        $freezeArguments=Freeze-Args $f;Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments} 'synthetic consumer failure'
        Check ([IO.File]::Exists((Join-Path $f.Receipt 'discovery-freeze-once.json')) -and -not[IO.File]::Exists($manifest)) 'failed Freeze lost marker or fabricated manifest'
        Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments} 'already reserved'
        Set-Item function:Invoke-C1bTdPinnedReader $original
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'nonempty destination rejects before permanent reservation' {
    $f=New-Fixture nonempty
    try{[IO.File]::WriteAllText((Join-Path $f.Receipt 'discovery-freeze/existing.txt'),'preserve');$freezeArguments=Freeze-Args $f;Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments} 'empty';Check (-not[IO.File]::Exists((Join-Path $f.Receipt 'discovery-freeze-once.json'))) 'nonempty target reserved Freeze'}finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
Case 'typed observer terminal counters and source pins reject JSON coercion' {
    $f=New-Fixture typed
    try{
        foreach($kind in @('observer_bool','observer_counter','terminal_counter','terminal_pid')){
            $obs=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($f.Observer|ConvertTo-Json -Depth 20)))
            $term=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($f.Terminal|ConvertTo-Json -Depth 20)))
            switch($kind){observer_bool{$obs.wrapper_started=1} observer_counter{$obs.automatic_wrapper_retry_count='0'} terminal_counter{$term.cleanup_failure_count='0'} terminal_pid{$term.runner_pid='123'}}
            Reject {Assert-C1bTdTerminalAuthority $f.Context $obs $term (ConvertFrom-C1bTdJson $f.Binding.bytes) $f.Binding.sha256} 'type'
        }
        $pins=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes(($f.Pins|ConvertTo-Json -Depth 8)))
        $pins.sources['scripts/lib/tablet-layout-c1a.ps1'].byte_length=[string]$pins.sources['scripts/lib/tablet-layout-c1a.ps1'].byte_length
        Reject {New-C1bTerminalDiscoveryContext $f.Root $sha $pins} 'Invalid source pin'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
    foreach($kind in @('once_counter','exit_pid')){
        $f=New-Fixture ('typed-'+$kind)
        try{
            $leaf=if($kind -ceq 'once_counter'){'reservation.json'}else{'exit.json'};$path=Join-Path $f.Receipt $leaf
            $value=ConvertFrom-C1bTdJson ([IO.File]::ReadAllBytes($path))
            if($kind -ceq 'once_counter'){$value.automatic_retry_count='0'}else{$value.runner_pid='123'}
            $changed=Write-Json $path $value
            if($kind -ceq 'once_counter'){$f.Terminal.reservation_sha256='sha256:'+$changed.sha256}else{$f.Terminal.exit_receipt_sha256='sha256:'+$changed.sha256}
            $f.Term=Write-Json $f.Term.path $f.Terminal;$freezeArguments=Freeze-Args $f
            Reject {Invoke-C1bTerminalDiscoveryFreeze @freezeArguments} 'type'
            Check (-not[IO.File]::Exists((Join-Path $f.Receipt 'discovery-freeze-once.json'))) 'untyped receipt started Freeze'
        }finally{Close-C1bTerminalDiscoveryContext $f.Context}
    }
}
Case 'tracked command reads then freezes only synthetic candidate evidence with self library and manifest pins' {
    $f=New-Fixture command run_failure
    try{
        $pinFile=Write-Json (Join-Path $f.Root '.checks/source-pins.json') $f.Pins
        $entry=Join-Path $repo 'scripts/read-c1b-terminal-discovery.ps1'
        $entryHash=Get-C1bTdHash ([IO.File]::ReadAllBytes($entry));$libraryHash=Get-C1bTdHash ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/c1b-terminal-discovery.ps1')))
        $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$entry,'-RepoRoot',$f.Root,'-ExpectedCommitSha',$sha,'-ExpectedSelfSha256',$entryHash,
            '-ExpectedLibrarySha256',$libraryHash,'-SourcePinsPath',$pinFile.path,'-SourcePinsSha256',$pinFile.sha256,
            '-TerminalReadbackPath',$f.Term.path,'-TerminalReadbackSha256',$f.Term.sha256,'-ReceiptRoot',$f.Receipt,
            '-ObservationSha256',$f.Observation.sha256,'-ExpectedBindingSha256',$f.Binding.sha256)
        $runtime=Join-Path $PSHOME 'pwsh.exe'
        $readText=(& $runtime @arguments -Mode Read) -join "`n"
        Check ($LASTEXITCODE -eq 0) 'tracked Read command failed'
        $read=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes($readText));Check ($read.read.checkpoints.before_install.status -ceq 'absent_unknown' -and -not$read.freeze_performed) 'tracked Read changed unknown checkpoint'
        $freezeText=(& $runtime @arguments -Mode Freeze) -join "`n"
        Check ($LASTEXITCODE -eq 0) 'tracked Freeze command failed'
        $freeze=ConvertFrom-C1bTdJson ([Text.Encoding]::UTF8.GetBytes($freezeText));Check ([IO.File]::Exists($freeze.freeze_once_reservation) -and $freeze.cleanup_failure_count -eq 0) 'tracked Freeze missed marker/readback'
    }finally{Close-C1bTerminalDiscoveryContext $f.Context}
}
"c1b terminal discovery offline: $passed passed, $failed failed, $assertions assertions; real candidate executions=0; device/ADB/provider invocations=0; native held file guards executed on synthetic files"
if($failed){exit 1}
