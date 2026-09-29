#Requires -Version 7.5
[CmdletBinding()]
param([string]$FixtureRoot,[string]$AuthorityFixtureOuterDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$repositoryRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if([string]::IsNullOrWhiteSpace($FixtureRoot)){$FixtureRoot=Join-Path $repositoryRoot ('.checks/goal-20260930/host-contract/tests/run-'+[Guid]::NewGuid().ToString('N'))}
$FixtureRoot=[IO.Path]::GetFullPath($FixtureRoot);if([IO.Directory]::Exists($FixtureRoot)-or[IO.File]::Exists($FixtureRoot)){throw 'Test fixture namespace must be new.'};$null=[IO.Directory]::CreateDirectory($FixtureRoot)
. (Join-Path $repositoryRoot 'scripts/lib/c1b-host-acceptance.ps1')
. (Join-Path $repositoryRoot 'scripts/lib/c1b-host-process-capture.ps1')
$cases=[Collections.Generic.List[object]]::new();$assertions=0;$candidate='a'*40;$runtime=[Environment]::ProcessPath
function Assert-Test([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Invoke-Case([string]$Name,[scriptblock]$Body){try{&$Body;$cases.Add(@{name=$Name;status='passed'})}catch{$cases.Add(@{name=$Name;status='failed';error=$_.Exception.Message})}}
function Reject([scriptblock]$Body,[string]$Pattern='.'){$rejected=$false;try{&$Body|Out-Null}catch{$rejected=$true;Assert-Test ($_.Exception.Message-match$Pattern) ('Unexpected rejection: '+$_.Exception.Message)};Assert-Test $rejected 'Expected fail-closed rejection.'}
function Pin([string]$Path){$bytes=[IO.File]::ReadAllBytes($Path);return @{path=$Path;byte_length=[long]$bytes.Length;sha256=Get-C1bHASha256 $bytes}}
function Save([string]$Relative,[byte[]]$Bytes){$path=Join-Path $FixtureRoot $Relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path));$s=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$s.Write($Bytes);$s.Flush($true)}finally{$s.Dispose()};return Pin $path}
function Json([string]$Relative,$Value){return Save $Relative ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 64)+"`n"))}
function Clone($Value){return ConvertFrom-C1bHAStrictJson (ConvertTo-Json -InputObject $Value -Depth 64)}

Invoke-Case 'strict JSON valid canonical primitives' { $v=ConvertFrom-C1bHAStrictJson '{"a":1,"b":true,"c":[0,-1]}';Assert-Test ($v.a-eq1 -and $v.b -and $v.c.Count-eq2) 'Canonical JSON parse.' }
foreach($raw in @('{"a":1,"a":2}','{"o":{"a":1,"a":2}}','{"x":1.0}','{"x":1e0}','{"x":-0}','{"x":9223372036854775808}','{"x":1,}','[1]')){$testRaw=$raw;Invoke-Case ('strict JSON rejects '+$raw) {Reject {ConvertFrom-C1bHAStrictJson $testRaw}}}
Invoke-Case 'closed objects and strict types' {Reject {Assert-C1bHAKeys @{a=1;b=2} @('a') 'fixture'};Reject {Assert-C1bHAInt '0' 0 0};Reject {Assert-C1bHABool 'true' $true 'fixture'};Assert-Test (Test-C1bHAEqual @{a=1;b=@(2)} @{b=@(2);a=[long]1}) 'Semantic equality ignores object order.' }
$rawPin=Save 'raw/data.bin' ([byte[]]@(0,1,2,255))
Invoke-Case 'held native raw pin stable and blocks data overwrite/delete' {
    $s=New-C1bHASession @($FixtureRoot);try{$bytes=Read-C1bHAFile $s $rawPin;Assert-Test ($bytes.Length-eq4 -and $bytes[3]-eq255) 'Held raw bytes.';Reject {$w=[IO.File]::Open($rawPin.path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read);$w.Dispose()};Reject {[IO.File]::Delete($rawPin.path)};Assert-Test ($s.directories.ContainsKey([IO.Path]::GetPathRoot($rawPin.path))) 'Drive-root ancestor is held.'}finally{Close-C1bHASession $s}
}
Invoke-Case 'raw pin tamper length hash and conflicting repeated binding' {
    $s=New-C1bHASession @($FixtureRoot);try{$bad=Clone $rawPin;$bad.sha256='0'*64;Reject {Read-C1bHAFile $s $bad} 'SHA256';$bad=Clone $rawPin;$bad.byte_length=3;Reject {Read-C1bHAFile $s $bad} 'length';$null=Read-C1bHAFile $s $rawPin;$bad=Clone $rawPin;$bad.sha256='0'*64;Reject {Read-C1bHAFile $s $bad} 'Conflicting'}finally{Close-C1bHASession $s}
}
Invoke-Case 'raw out of tree rejected' {$s=New-C1bHASession @((Join-Path $FixtureRoot 'raw'));try{Reject {Read-C1bHAFile $s (Pin (Join-Path $repositoryRoot 'scripts/lib/c1b-host-acceptance.ps1'))} 'trusted roots'}finally{Close-C1bHASession $s}}
Invoke-Case 'second-root failure releases prior directory handles' {
    Reject {New-C1bHASession @($FixtureRoot,(Join-Path $FixtureRoot 'does-not-exist'))}
    $moveFrom=Join-Path $FixtureRoot 'release-probe';$moveTo=Join-Path $FixtureRoot 'release-probe-renamed';$null=[IO.Directory]::CreateDirectory($moveFrom);[IO.Directory]::Move($moveFrom,$moveTo);Assert-Test ([IO.Directory]::Exists($moveTo)) 'Factory leaked namespace lock.'
}
Invoke-Case 'no-follow junction and hardlink rejection' {
    $target=Join-Path $FixtureRoot 'raw';$junction=Join-Path $FixtureRoot 'junction';$null=New-Item -ItemType Junction -Path $junction -Target $target
    $s=New-C1bHASession @($FixtureRoot);try{$p=Clone $rawPin;$p.path=Join-Path $junction 'data.bin';Reject {Read-C1bHAFile $s $p} 'reparse';$hardlink=Join-Path $FixtureRoot 'hardlink.bin';$null=New-Item -ItemType HardLink -Path $hardlink -Target $rawPin.path;Reject {Read-C1bHAFile $s $rawPin} 'link'}finally{Close-C1bHASession $s}
}
Invoke-Case 'held sensitive buffer drift rejected and zeroized' {$pin=Save 'buffer.bin' ([byte[]]@(4,5,6));$s=New-C1bHASession @($FixtureRoot);$bytes=Read-C1bHAFile $s $pin;$bytes[0]=0;Reject {Close-C1bHASession $s} 'buffer';Assert-Test ($bytes[1]-eq0 -and $bytes[2]-eq0) 'Cleanup did not zeroize.'}
Invoke-Case 'required absence is no-follow and boundary checked' {$s=New-C1bHASession @($FixtureRoot);try{Assert-C1bHAAbsentFile $s (Join-Path $FixtureRoot 'absent.json');Reject {Assert-C1bHAAbsentFile $s $rawPin.path} 'absence';Assert-Test ($s.absences.Count-eq1) 'Absence record missing.'}finally{Close-C1bHASession $s}}
if(-not[string]::IsNullOrWhiteSpace($AuthorityFixtureOuterDirectory)){
    Invoke-Case 'independent actual A1 producer receipt raw tree index and 42 catalog consumed' {
        $outerPath=[IO.Path]::GetFullPath($AuthorityFixtureOuterDirectory);$receipt=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText((Join-Path $outerPath 'stdout.bin')));$a1=Clone $receipt.a1
        $a1.audit_receipt_pin=Pin (Join-Path $outerPath 'stdout.bin');$a1.producer_capture_pin=Pin (Join-Path $outerPath 'execution.json');$a1.producer_root_observation_pin=Pin (Join-Path $outerPath 'root-observation.json');$a1.audit_run_id=$receipt.audit_run_id
        $gitRoot=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),'Git');$s=New-C1bHASession @($repositoryRoot,$receipt.repo_root,$gitRoot,[IO.Path]::GetDirectoryName($runtime))
        try{$verified=Assert-C1bHAAuthority $s $a1 $receipt.candidate_sha $receipt.repo_root;Assert-Test ($verified.authority.implementation_hashes.Count-eq42) 'Actual 42 catalog missing.';Assert-Test ($verified.authority.implementation_catalog_sha256-ceq$receipt.implementation_catalog_sha256 -and $verified.authority.tracked_path_count-eq$receipt.tracked_path_count) 'Independent A1 authority differs from actual producer.';Assert-Test ($s.files.ContainsKey([IO.Path]::Combine($gitRoot,'cmd','git.exe'))) 'Canonical actual Git tool closure not registered.'}finally{Close-C1bHASession $s}
    }
}
Invoke-Case 'explicit same-source private verifier context verifies synthetic raw summary' {
    $verifierPin=Pin (Join-Path $repositoryRoot 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1');$verifierBytes=[IO.File]::ReadAllBytes($verifierPin.path)
    . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($verifierBytes)))
    $s=New-C1bHASession @($repositoryRoot,$FixtureRoot)
    try{
        Reject {Initialize-C1bHASummaryVerifier $s $verifierPin $null} 'explicit';$context=@{source_pin=$verifierPin;native_authority_owner='c1b-device-entry-source';source_bytes=$verifierBytes}
        $wrong=@{source_pin=$verifierPin;native_authority_owner='unknown';source_bytes=$verifierBytes};Reject {Initialize-C1bHASummaryVerifier $s $verifierPin $wrong} 'owner'
        $wrong=@{source_pin=$verifierPin;native_authority_owner='c1b-device-entry-source';source_bytes=[byte[]]@(1,2)};Reject {Initialize-C1bHASummaryVerifier $s $verifierPin $wrong} 'bytes'
        Initialize-C1bHASummaryVerifier $s $verifierPin $context
        $summary=@{};$properties=&$script:C1bHAVerifierModule {Get-TL1C1bRealBuildSmokeSummaryRequiredProperties};foreach($name in $properties){if($name.EndsWith('_count')){$summary[$name]=0L}elseif($name.EndsWith('_sha256')){$summary[$name]='sha256:'+('0'*64)}else{$summary[$name]='completed'}}
        foreach($name in @('bootstrap_git_provenance_verified','pre_git_provenance_verified','post_git_provenance_verified','wrapper_not_executed','dependency_allowlist_verified','packaged_axml_verified','post_gradle_lock_sealed')){$summary[$name]=$true};foreach($name in @('workspace_residual','recovery_journal_residual','module_build_residual','module_gradle_residual','local_properties_residual')){$summary[$name]=$false}
        $summary.schema='tablet-layout-c1b-real-build-smoke-summary/v1';$summary.status='passed';$summary.expected_commit_sha=$candidate;$summary.helper_sha256='sha256:'+('1'*64);$summary.started_at_utc='2020-01-01T00:00:01.0000000Z';$summary.completed_at_utc='2020-01-01T00:00:03.0000000Z';$summary.process_start_observation_ended_at_utc='2020-01-01T00:00:02.0000000Z';$summary.bootstrap_git_execution_count=2L;$summary.repository_input_count=42L;$summary.repository_input_directory_root_count=3L;$summary.real_jdk_gradlemain_execution_count=1L;$summary.real_apksigner_execution_count=1L;$summary.held_aapt2_verification_execution_count=4L;$summary.held_git_execution_count=32L;$summary.observed_direct_child_java_process_start_count=2L;$summary.build_environment_schema='tablet-layout-c1b-build-environment-trust/v1';$summary.process_start_observer_scope='host_wide_best_effort_wmi';$summary.process_start_observer_limitation='Win32_ProcessStartTrace is operational observation, not a persistent kernel or syscall audit.';$summary.default_adb_listener_observation='boundary_snapshots_only';$summary.jdk_version='21.0.5';$summary.jdk_catalog_sha256='sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9';$summary.gradle_version='8.9';$summary.gradle_catalog_sha256='sha256:d0974b974d9471723cccf083f59e8772448b5bb6672f479bddd63897ba665189';$summary.gradle_entrypoint='org.gradle.launcher.GradleMain';$summary.apksigner_jar_sha256='sha256:00ef9948f843fe395d2440ae3ef41405b8040a6d5d46493bd1902ac0ee6deae7';$summary.failure_reasons=@()
        $summaryPin=Json 'synthetic-summary.json' $summary
        $verified=&$script:C1bHAVerifierModule {param($p,$sha) Assert-TL1C1bRealBuildSmokeSummaryFile -Path $p -ExpectedParentDirectory ([IO.Path]::GetDirectoryName($p)) -ExpectedCommitSha $sha -ExpectedHelperSha256 ('1'*64) -HelperProcessStartedNotBeforeUtc ([DateTimeOffset]'2020-01-01T00:00:00Z') -HelperProcessExitedNotAfterUtc ([DateTimeOffset]'2020-01-01T00:00:04Z') -MaximumObserverTailSeconds 5} $summaryPin.path $candidate
        Assert-Test ($verified.Sha256-ceq('sha256:'+$summaryPin.sha256) -and $verified.ByteLength-eq$summaryPin.byte_length) 'Private raw summary verification failed.'
        Reject {Initialize-C1bHASummaryVerifier $s $verifierPin $null} 'explicit'
    }finally{Close-C1bHASession $s;[Array]::Clear($verifierBytes,0,$verifierBytes.Length)}
}

# Real process transport of a harmless fixture script. These are actual native
# captures, not fabricated BuildOnly/Git/device records.
$toySource=Save 'transport/toy.ps1' ([Text.Encoding]::UTF8.GetBytes("[Console]::Out.WriteLine('fixture stdout'); exit 0`n"))
$invoker=Pin (Join-Path $repositoryRoot 'scripts/invoke-c1b-candidate-host-stage.ps1');$stageModule=Pin (Join-Path $repositoryRoot 'scripts/lib/c1b-candidate-host-stages.ps1');$captureModule=Pin (Join-Path $repositoryRoot 'scripts/lib/c1b-host-process-capture.ps1');$runtimePin=Pin $runtime
$runId=[Guid]::NewGuid().ToString('N');$state=Json 'transport/state.json' @{schema='c1b-candidate-host-state/v1';candidate_sha=$candidate;state='preparation';working_directory=$FixtureRoot}
$argv=@('-NoProfile','-File',$toySource.path);$binding=@{schema='c1b-candidate-host-stage-bindings/v1';run_id=$runId;candidate_sha=$candidate;phase='FullCheck';candidate_state='preparation';candidate_state_pin=$state;runtime=@{path=$runtime;byte_length=$runtimePin.byte_length;sha256=$runtimePin.sha256;version=$PSVersionTable.PSVersion.ToString()};stage_source=$toySource;transport_sources=@{invoker=$invoker;module=$stageModule;capture=$captureModule};working_directory=$FixtureRoot;argument_list=$argv;argument_list_sha256=(Get-C1bHASha256 ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $argv -Compress -Depth 4))));evidence_directory=(Join-Path $FixtureRoot 'transport/stage');artifact_inventory=@();capture_limits=@{capture_limit_bytes=1048576;timeout_milliseconds=30000;drain_timeout_milliseconds=5000;cleanup_timeout_milliseconds=5000};automatic_retry_count=0;environment=$null}
$bindingPin=Json 'transport/bindings.json' $binding;$stageInput=$null
Invoke-Case 'actual producer and independent Read root native exit captured' {
    $outerDir=Join-Path $FixtureRoot 'transport/outer';$outer=Invoke-TL1C1bHostProcessCapture -ExecutablePath $runtime -ArgumentList @('-NoProfile','-File',$invoker.path,'-Operation','Run','-BindingsPath',$bindingPin.path,'-ExpectedBindingsSha256',$bindingPin.sha256) -WorkingDirectory $FixtureRoot -EvidenceDirectory $outerDir -TimeoutMilliseconds 30000
    Assert-Test ($outer.status-ceq'passed' -and $outer.exit_code-eq0) 'Actual stage producer failed.'
    $observationPin=Pin (Join-Path $binding.evidence_directory 'observation.json');$observation=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($observationPin.path));$outerPin=Pin (Join-Path $outerDir 'execution.json')
    $rootPin=Json 'transport/producer-root.json' @{schema='c1b-host-root-observation/v1';candidate_sha=$candidate;phase='FullCheck';run_id=$runId;process_id=$outer.child_pid;native_exit_code=$outer.exit_code;capture_pin=$outerPin}
    $readerDir=Join-Path $FixtureRoot 'transport/reader';$reader=Invoke-TL1C1bHostProcessCapture -ExecutablePath $runtime -ArgumentList @('-NoProfile','-File',$invoker.path,'-Operation','Read','-ObservationPath',$observationPin.path,'-ExpectedObservationSha256',$observationPin.sha256) -WorkingDirectory $FixtureRoot -EvidenceDirectory $readerDir -TimeoutMilliseconds 30000
    Assert-Test ($reader.status-ceq'passed' -and $reader.exit_code-eq0) 'Actual stage Read failed.';$readerCapturePin=Pin (Join-Path $readerDir 'execution.json');$readerRootPin=Json 'transport/reader-root.json' @{schema='c1b-host-root-observation/v1';candidate_sha=$candidate;phase='FullCheck';run_id=$runId;process_id=$reader.child_pid;native_exit_code=$reader.exit_code;capture_pin=$readerCapturePin}
    $script:stageInput=@{phase='FullCheck';observation_pin=$observationPin;outer_capture_pin=$outerPin;root_observation_pin=$rootPin;reader=@{report_pin=(Pin (Join-Path $readerDir 'stdout.bin'));capture_pin=$readerCapturePin;root_observation_pin=$readerRootPin}}
    $s=New-C1bHASession @($FixtureRoot,$repositoryRoot,[IO.Path]::GetDirectoryName($runtime));try{$verified=Assert-C1bHAStage $s $script:stageInput $candidate $FixtureRoot;Assert-Test ((ConvertFrom-C1bHABytes $verified.stdout).Trim()-ceq'fixture stdout') 'Stage semantic stdout incorrectly selected.';Assert-Test ($verified.observation.runtime_pin.version-ceq$PSVersionTable.PSVersion.ToString()) 'Runtime four-field pin not consumed.'}finally{Close-C1bHASession $s}
}
if($null-ne$stageInput){
    foreach($mutation in @('stdout-eof','stderr-eof','native-exit','cleanup','capture-hash','root-pid','root-native-exit','reader-self-exit','runtime-version','manifest-state','observation-path')){
        $mutationName=$mutation
        Invoke-Case ('actual stage rejects '+$mutation) {
            $stage=Clone $stageInput;$subdir='negative-'+$mutationName
            if($mutationName-eq'root-pid'-or$mutationName-eq'root-native-exit'){$r=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($stage.root_observation_pin.path));if($mutationName-eq'root-pid'){$r.process_id+=1}else{$r.native_exit_code=1};$stage.root_observation_pin=Json ($subdir+'/root.json') $r}
            elseif($mutationName-eq'reader-self-exit'){$r=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($stage.reader.report_pin.path));$r.root_native_exit_observed=$true;$stage.reader.report_pin=Json ($subdir+'/report.json') $r}
            elseif($mutationName-eq'runtime-version'-or$mutationName-eq'manifest-state'-or$mutationName-eq'observation-path'){$o=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($stage.observation_pin.path));if($mutationName-eq'runtime-version'){$o.runtime_pin.version='0.0.0'}elseif($mutationName-eq'manifest-state'){$o.candidate_state='frozen_for_host'};$stage.observation_pin=Json ($subdir+'/observation.json') $o}
            else{$c=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($stage.outer_capture_pin.path));switch($mutationName){'stdout-eof'{$c.stdout.eof=$false};'stderr-eof'{$c.stderr.eof=$false};'native-exit'{$c.exit_code=1};'cleanup'{$c.cleanup.completed=$false};'capture-hash'{$c.stdout.sha256='0'*64}};$stage.outer_capture_pin=Json ($subdir+'/execution.json') $c}
            $s=New-C1bHASession @($FixtureRoot,$repositoryRoot,[IO.Path]::GetDirectoryName($runtime));try{Reject {Assert-C1bHAStage $s $stage $candidate $FixtureRoot}}finally{Close-C1bHASession $s}
        }
    }
}
Invoke-Case 'full acceptance requires all authority and stage gates' {
    $map=Json 'incomplete-map.json' @{schema='c1b-host-acceptance-inputs/v1';candidate_sha=$candidate;repo_root=$FixtureRoot;trusted_source_roots=@();a1=@{};source_review_pin=$rawPin;stage_runs=@();build_only=@{};raw_archive_pin=$rawPin;raw_archive_execution=@{}}
    Reject {Assert-C1bHostAcceptanceEvidence -CandidateSha $candidate -EvidenceRoot $FixtureRoot -InputMapPath $map.path -InputMapSha256 $map.sha256} 'A1'
    Reject {Assert-C1bHostAcceptanceEvidence -CandidateSha $candidate -EvidenceRoot $FixtureRoot -InputMapPath $map.path -InputMapSha256 ('0'*64)} 'InputMap SHA'
}
$semanticCheckPin=Save 'scripts/check.ps1' ([IO.File]::ReadAllBytes((Join-Path $repositoryRoot 'scripts/check.ps1')))
$semanticObservation=@{argument_list=@('-NoProfile','-File',$semanticCheckPin.path);source_pins=@{stage_source=$semanticCheckPin}}
$checkTokens=$null;$checkErrors=$null;$checkAst=[Management.Automation.Language.Parser]::ParseFile($semanticCheckPin.path,[ref]$checkTokens,[ref]$checkErrors);$semanticTitles=@($checkAst.FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Invoke-Check'},$true)|ForEach-Object{$_.CommandElements[1].Value})
$semanticPassText=($semanticTitles|ForEach-Object{'PASS  '+$_+'  1s'})-join"`n";$semanticPassText+="`n全部通过。`n"
Invoke-Case 'A2 skip Android or incomplete full gate cannot accept' {$s=New-C1bHASession @($FixtureRoot);try{Reject {Assert-C1bHAStageSemantics $s @{FullCheck=@{observation=@{argument_list=@('-SkipGradle')};stdout=[Text.Encoding]::UTF8.GetBytes('PASS fixture')}} $candidate @{} @{repo_root=$FixtureRoot}} 'skip';Reject {Assert-C1bHAStageSemantics $s @{FullCheck=@{observation=$semanticObservation;stdout=[Text.Encoding]::UTF8.GetBytes("PASS  fixture  1s`n全部通过。")}} $candidate @{} @{repo_root=$FixtureRoot}} 'A2'}finally{Close-C1bHASession $s}}
foreach($kind in @('old-thirteen','missing-android','duplicate-title','extra-title','explicit-skip')){
    $gateKind=$kind;Invoke-Case ('A2 exact titles reject '+$kind) {$text=$semanticPassText;switch($gateKind){'old-thirteen'{$text=($text-split"`n"|Select-Object -Skip 1)-join"`n"};'missing-android'{$text=$text.Replace('PASS  Android JVM/Lint/构建  1s','')};'duplicate-title'{$text+='PASS  '+$semanticTitles[0]+"  1s`n"};'extra-title'{$text+="PASS  extra  1s`n"};'explicit-skip'{$text+="SKIP  extra  1s`n"}};$s=New-C1bHASession @($FixtureRoot);try{Reject {Assert-C1bHAStageSemantics $s @{FullCheck=@{observation=$semanticObservation;stdout=[Text.Encoding]::UTF8.GetBytes($text)}} $candidate @{} @{repo_root=$FixtureRoot}} 'A2'}finally{Close-C1bHASession $s}}
}
Invoke-Case 'A3 empty PrepareSources cannot accept after actual fourteen-title gate' {$s=New-C1bHASession @($FixtureRoot);try{Assert-Test ($semanticTitles.Count-eq14) 'Candidate check AST title count.';Reject {Assert-C1bHAStageSemantics $s @{FullCheck=@{observation=$semanticObservation;stdout=[Text.Encoding]::UTF8.GetBytes($semanticPassText)};PrepareSources=@{stdout=[Text.Encoding]::UTF8.GetBytes('{}')}} $candidate @{} @{repo_root=$FixtureRoot}} 'PrepareSources'}finally{Close-C1bHASession $s}}
Invoke-Case 'A4 missing actual BuildOnly closure cannot accept' {$s=New-C1bHASession @($FixtureRoot);try{Reject {Assert-C1bHABuildOnly $s @{} @{} $candidate @{} $null} 'BuildOnly'}finally{Close-C1bHASession $s}}
foreach($markerCase in @('valid','wrong-nonce','wrong-driver','wrong-elevated','retry','duplicate-start','numeric-string')){
    $markerKind=$markerCase;Invoke-Case ('A4 permanent raw markers '+$markerCase) {
        $prefix='markers-'+$markerKind;$base=Join-Path $FixtureRoot $prefix;$launcherPath=Join-Path $base 'launcher.ps1';$resultPath=Join-Path $base 'evidence/result.json'
        $result=@{candidate_sha=$candidate;run_id='b'*32;nonce='11111111-1111-1111-1111-111111111111';driver_pid=123;elevated_pid=456}
        $once=@{schema='c1b-build-only-elevation-reservation/v1';candidate_sha=$candidate;run_id=$result.run_id;nonce=$result.nonce;driver_pid=123;invocation_count=1;automatic_retry_count=0}
        $start=@{schema='c1b-build-only-elevated-start/v1';candidate_sha=$candidate;run_id=$result.run_id;nonce=$result.nonce;driver_pid=123;elevated_pid=456;launcher_start_attempt_count=1;automatic_retry_count=0}
        switch($markerKind){'wrong-nonce'{$once.nonce='22222222-2222-2222-2222-222222222222'};'wrong-driver'{$once.driver_pid=124};'wrong-elevated'{$start.elevated_pid=457};'retry'{$once.automatic_retry_count=1};'duplicate-start'{$start.launcher_start_attempt_count=2};'numeric-string'{$start.elevated_pid='456'}}
        $oncePin=Json ($prefix+'/build-only-'+$candidate+'.once.json') $once;$startPin=Json ($prefix+'/evidence/elevated-start.json') $start
        $build=@{launcher_source_pin=@{path=$launcherPath};elevation=@{result_pin=@{path=$resultPath}}};$s=New-C1bHASession @($FixtureRoot)
        try{if($markerKind-ceq'valid'){Assert-C1bHAElevationMarkers $s $build $result;Assert-Test ($s.files.ContainsKey($oncePin.path)-and$s.files.ContainsKey($startPin.path)) 'Both actual marker raw pins remain held for archive coverage.'}else{Reject {Assert-C1bHAElevationMarkers $s $build $result} 'marker|invocation|attempt'}}finally{Close-C1bHASession $s}
    }
}
Invoke-Case 'source review cannot be missing independent evidence' {$p=Json 'review-negative.json' @{schema='c1b-host-source-review/v1';candidate_sha=$candidate;status='passed';reviewer_independent=$false;reviewed_source_pins=@();unresolved_findings=@();forbidden_capability_count=0};$s=New-C1bHASession @($FixtureRoot);try{Reject {Assert-C1bHAReviewedSources $s $p $candidate @{} @{}} 'Independent'}finally{Close-C1bHASession $s}}
Invoke-Case 'raw seal cannot omit consumed evidence' {$p=Json 'archive-negative.json' @{schema='c1b-host-raw-archive/v1';candidate_sha=$candidate;status='sealed_raw_archive';source_mutation_count=0;cleanup_failure_count=0;members=@()};$probe=Save 'must-seal.bin' ([byte[]]@(7));$s=New-C1bHASession @($FixtureRoot);try{$null=Read-C1bHAFile $s $probe;Reject {Assert-C1bHAArchive $s $p $candidate $FixtureRoot @($p.path)} 'cover'}finally{Close-C1bHASession $s}}
Invoke-Case 'contract cannot declare host pass without reconsumption' {$p=Json 'forged-contract.json' @{schema='c1b-host-device-entry-acceptance/v1';candidate_sha=$candidate;status='host_accepted_no_device';created_at_utc=[DateTimeOffset]::UtcNow.ToString('o');observed_buildonly_caller_exit=0;observed_buildonly_reader_exit=0;real_adb_call_count=0;device_stage_started=$false;device_evidence_verified=$false;unresolved_findings=@();cleanup_failure_count=0;authority=@{};evidence_map_pin=(Pin (Join-Path $FixtureRoot 'incomplete-map.json'));source_review_pin=$rawPin;verified_evidence_pins=@()};Reject {Assert-C1bHostAcceptanceContract -CandidateSha $candidate -EvidenceRoot $FixtureRoot -ContractPath $p.path -ContractSha256 $p.sha256} 'A1'}
$failed=@($cases|Where-Object{$_.status-ceq'failed'});$summary=@{schema='c1b-host-acceptance-offline-tests/v1';status=$(if($failed.Count){'failed'}else{'passed'});case_count=$cases.Count;assertion_count=$assertions;failed_count=$failed.Count;cases=$cases.ToArray();fixture_root=$FixtureRoot;real_git_buildonly_preflight_device_invocation_count=0;full_candidate_acceptance_executed=$false;limitations=@('Positive transport uses actual harmless processes; formal all-gates acceptance requires new-candidate evidence. This suite never fabricates a real candidate Ready.')};$summaryPin=Json 'summary.json' $summary
ConvertTo-Json -InputObject @{status=$summary.status;case_count=$cases.Count;assertion_count=$assertions;failed_count=$failed.Count;summary_pin=$summaryPin} -Depth 4 -Compress
if($failed.Count){exit 1};exit 0
