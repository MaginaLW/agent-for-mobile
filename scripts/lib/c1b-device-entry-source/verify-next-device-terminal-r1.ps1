#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedSelfSha256,
    [Parameter(Mandatory)][string]$SourcePinsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SourcePinsSha256,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$ReceiptRoot,
    [Parameter(Mandatory)][ValidateSet(0,1,2)][int]$ObservedRunnerExit,
    [Parameter(Mandatory)][ValidateSet(0,1,2)][int]$ObservedWrapperExit,
    [Parameter(Mandatory)][ValidateRange(1,2147483647)][int]$ObservedRunnerPid
)
# Exact __CANDIDATE_SHORT__/r1 terminal readback. Independently observed exits/PID are supplied by root.
# Root must pin this reviewed reader's SHA256 before invocation; no candidate run is authorized here.
# Fixed hashes below were read from the ordinary clone, including its actual LF/CRLF bytes.
# The v1 wrapper propagates runner exit only after raw streams close and wrapper_failure stays null.
# No runner, ADB, Git, Gradle, aapt2, new capture, historical freshness replay, or file write.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$expectedCommit='__CANDIDATE_SHA__'
$expectedRepo='__REPO_ROOT__'
$expectedEntryRoot='__ENTRY_ROOT__'
$expectedRunner='__INPUT_RUNNER_SHA256__'
$expectedCatalog='sha256:__IMPLEMENTATION_CATALOG_HASH__'
$strictHash='__STRICT_VERIFIER_HASH__'
$libraryHashes=[ordered]@{
    'scripts/lib/tablet-layout-observation-v2-validator.ps1'='__INPUT_NATIVE_PATH_VALIDATOR_SHA256__'
    'scripts/lib/tablet-layout-c1a.ps1'='__INPUT_C1A_LOW_LEVEL_LIBRARY_SHA256__'
    'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1'='__INPUT_VALIDATOR_SHA256__'
    'scripts/lib/tablet-layout-c1b.ps1'='__INPUT_C1B_LIBRARY_SHA256__'
    'scripts/lib/tablet-layout-c1b-artifact-proof.ps1'='__INPUT_C1B_ARTIFACT_PROOF_LIBRARY_SHA256__'
}
$checks=0;$primary=$null;$answer=$null;$bootstrap=$null;$discoveryBootstrap=$null;$discoveryContext=$null;$identitySources=[Collections.Generic.List[object]]::new()
$heldFiles=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$heldDirectories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$cleanupFailures=[Collections.Generic.List[string]]::new()
function Ensure-Readback([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw $Message}}
function Hash-Bytes([AllowEmptyCollection()][byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function Check-Fields($Value,[hashtable]$Expected){
    foreach($key in $Expected.Keys){
        $p=$Value.PSObject.Properties[$key];Ensure-Readback ($null-ne$p) "Missing field: $key"
        $wanted=$Expected[$key];$actual=$p.Value
        $typed=if($wanted-is[bool]){$actual-is[bool]}elseif($wanted-is[string]){$actual-is[string]}else{$actual-is[long]-or$actual-is[int]}
        Ensure-Readback ($typed-and$actual-ceq$wanted) "Field mismatch: $key"
    }
}
function Read-Held([string]$Path,[bool]$WithBytes=$true){
    $full=[IO.Path]::GetFullPath($Path)
    Ensure-Readback ($full.StartsWith($RepoRoot+'\',[StringComparison]::OrdinalIgnoreCase)-or[StringComparer]::OrdinalIgnoreCase.Equals($full,(Join-Path $expectedEntryRoot 'verify-next-device-terminal-r1.ps1'))) 'Readback path escaped selected repository or exact reviewed reader.'
    if($heldFiles.ContainsKey($full)){return $heldFiles[$full]}
    foreach($dir in (Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain ([IO.Path]::GetDirectoryName($full)))){
        if($heldDirectories.ContainsKey($dir)){continue}
        $h=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete($dir)
        $b=[pscustomobject]@{Path=$dir;Handle=$h;Identity=$null};$heldDirectories.Add($dir,$b)
        $b.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($h)
        Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity $b.Identity
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $h $dir
    }
    $h=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete($full)
    $b=[pscustomobject]@{Path=$full;Handle=$h;Stream=$null;Identity=$null;Length=0L;Hash=$null;Bytes=$null};$heldFiles.Add($full,$b)
    $b.Stream=[IO.FileStream]::new($h,[IO.FileAccess]::Read);$b.Length=$b.Stream.Length
    Ensure-Readback ($b.Length-le$(if($WithBytes){8388608L}else{268435456L})) 'Readback file exceeds bound.'
    $b.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($h)
    Assert-TL1C1bRealBuildSmokeHeldFileIdentity $b.Identity $b.Length
    Assert-TL1C1bRealBuildSmokeHandleFinalPath $h $full
    $b.Hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b.Stream)).ToLowerInvariant()
    if($WithBytes){$b.Stream.Position=0;$b.Bytes=[byte[]]::new([int]$b.Length);$b.Stream.ReadExactly($b.Bytes)}
    return $b
}
function Read-Closed($Binding){
    Ensure-Readback ($null-ne$Binding.Bytes-and$Binding.Bytes.Length-gt0) 'JSON file is empty.'
    $raw=[Text.UTF8Encoding]::new($false,$true).GetString($Binding.Bytes)
    Ensure-Readback (-not$raw.StartsWith([char]0xfeff)) 'JSON BOM is not allowed.'
    return ConvertFrom-TL1C1bClosedJson $raw
}
function Check-Schema($Binding,[string]$RelativeSchema){
    $schema=Read-Held (Join-Path $RepoRoot $RelativeSchema)
    $raw=[Text.UTF8Encoding]::new($false,$true).GetString($Binding.Bytes)
    Ensure-Readback ($raw|Test-Json -SchemaFile $schema.Path -ErrorAction Stop) 'Evidence schema rejected.'
}
try{
    $RepoRoot=[IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/');$ReceiptRoot=[IO.Path]::GetFullPath($ReceiptRoot).TrimEnd('\','/')
    Ensure-Readback ([StringComparer]::OrdinalIgnoreCase.Equals($RepoRoot,$expectedRepo)) 'Repo root is not the reviewed ordinary clone.'
    Ensure-Readback ($ObservedWrapperExit-eq$ObservedRunnerExit) 'Independently observed wrapper and runner exits differ.'
    Ensure-Readback ([StringComparer]::OrdinalIgnoreCase.Equals($ReceiptRoot,(Join-Path $RepoRoot '.checks/c1b-device-once/__CANDIDATE_SHORT__/r1'))) 'Receipt root is not this exact clone r1 attempt.'
    Ensure-Readback ($PSVersionTable.PSVersion.ToString()-ceq'7.6.5'-and[Environment]::ProcessPath-ceq'__PWSH_PATH__') 'Pinned PowerShell 7.6.5 required.'
    # The independently pinned R3 context establishes native authority first.
    $discoveryPath='__DEPENDENCY_TERMINAL_DISCOVERY_PATH__'
    $discoveryBootstrap=[IO.File]::Open($discoveryPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    Ensure-Readback ($discoveryBootstrap.Length-eq'__DEPENDENCY_TERMINAL_DISCOVERY_LENGTH__') 'Discovery producer source length drift.'
    $discoveryBytes=[byte[]]::new([int]$discoveryBootstrap.Length);$discoveryBootstrap.ReadExactly($discoveryBytes)
    Ensure-Readback ((Hash-Bytes $discoveryBytes)-ceq'__DEPENDENCY_TERMINAL_DISCOVERY_HASH__') 'Discovery producer raw hash drift.'
    . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($discoveryBytes)))
    Assert-C1bTdOrdinaryPath $SourcePinsPath
    $sourcePinBytes=[IO.File]::ReadAllBytes($SourcePinsPath)
    Ensure-Readback ((Hash-Bytes $sourcePinBytes)-ceq$SourcePinsSha256) 'R3 source pin manifest drift.'
    $discoveryPins=ConvertFrom-C1bTdJson $sourcePinBytes
    $discoveryContext=New-C1bTerminalDiscoveryContext $RepoRoot $expectedCommit $discoveryPins
    $strictPath=Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
    $bootstrap=[IO.File]::Open($strictPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    Ensure-Readback ($bootstrap.Length-gt0-and$bootstrap.Length-le1048576) 'Strict library bound.'
    $bytes=[byte[]]::new([int]$bootstrap.Length);$bootstrap.ReadExactly($bytes)
    Ensure-Readback ((Hash-Bytes $bytes)-ceq$strictHash) 'Strict library hash drift.'
    # Definitions were installed by the independently verified R3 context; do not reload native authority.
    Ensure-Readback ((Read-Held $strictPath).Hash-ceq$strictHash) 'Strict library path binding drift.'
    Ensure-Readback ((Read-Held $PSCommandPath).Hash-ceq$ExpectedSelfSha256) 'Terminal reader self raw pin drift.'
    Ensure-Readback ((Read-Held $discoveryPath).Hash-ceq'__DEPENDENCY_TERMINAL_DISCOVERY_HASH__') 'Discovery producer native path drift.'
    $sourcePinsHeld=Read-Held $SourcePinsPath
    Ensure-Readback ($sourcePinsHeld.Hash-ceq$SourcePinsSha256-and($sourcePinsHeld.Identity.FileAttributes-band1)-ne0) 'Frozen R3 pin manifest differs.'
    foreach($entry in $libraryHashes.GetEnumerator()){
        $binding=Read-Held (Join-Path $RepoRoot $entry.Key)
        Ensure-Readback ($binding.Hash-ceq$entry.Value) 'Production reader library hash drift.'
        . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($binding.Bytes)))
    }
    $onceFile=Read-Held (Join-Path $ReceiptRoot 'reservation.json');$exitFile=Read-Held (Join-Path $ReceiptRoot 'exit.json')
    $outFile=Read-Held (Join-Path $ReceiptRoot 'runner.stdout.bin');$errFile=Read-Held (Join-Path $ReceiptRoot 'runner.stderr.bin')
    $once=Read-Closed $onceFile;$exitRecord=Read-Closed $exitFile
    Assert-TL1C1bExactObjectKeys $once @('schema','commit_sha','runner_sha256','started_at_utc','automatic_retry_count') 'once receipt'
    Assert-TL1C1bExactObjectKeys $exitRecord @('schema','commit_sha','runner_sha256','runner_started','runner_pid','runner_exit_code','wrapper_failure','started_at_utc','completed_at_utc','automatic_retry_count','success_requires_runner_evidence_validation') 'exit receipt'
    foreach($value in @($once,$exitRecord)){Check-Fields $value @{commit_sha=$expectedCommit;runner_sha256=$expectedRunner;automatic_retry_count=0}}
    Check-Fields $once @{schema='c1b-device-cli-once/v1'}
    Check-Fields $exitRecord @{schema='c1b-device-cli-exit/v1';runner_started=$true;runner_pid=$ObservedRunnerPid;runner_exit_code=$ObservedRunnerExit;success_requires_runner_evidence_validation=$true;started_at_utc=$once.started_at_utc}
    Ensure-Readback ($null-eq$exitRecord.wrapper_failure-and($exitRecord.runner_pid-is[long]-or$exitRecord.runner_pid-is[int])-and$exitRecord.runner_pid-gt0) 'Wrapper failure or invalid runner PID.'
    $started=[DateTimeOffset]::Parse($once.started_at_utc);$ended=[DateTimeOffset]::Parse($exitRecord.completed_at_utc)
    Ensure-Readback ($started-le$ended) 'Wrapper timestamp envelope invalid.'
    Ensure-Readback ((Read-Held (Join-Path $RepoRoot 'scripts/run-tablet-layout-c1b.ps1')).Hash-ceq$expectedRunner) 'Runner actual hash differs.'
    $actualImplementation=[ordered]@{}
    foreach($entry in $script:TL1C1bImplementationPathMap.GetEnumerator()){$actualImplementation[$entry.Key]='sha256:'+(Read-Held (Join-Path $RepoRoot $entry.Value) $false).Hash}
    Ensure-Readback ($actualImplementation.Count-eq42-and(Get-TL1C1bImplementationCatalogSha256 $actualImplementation)-ceq$expectedCatalog) 'Actual 42-file candidate catalog differs.'
    $stdout=[Text.UTF8Encoding]::new($false,$true).GetString($outFile.Bytes)
    $successLines=[regex]::Matches($stdout,'(?m)^T-L1 C1b 受控只读采集完成：([^\r\n]+)\r?$')
    if($ObservedRunnerExit-ne0){Ensure-Readback ($successLines.Count-eq0) 'Failed/needs-user output conflicts with a success publication.'}
    $evidenceRoot=Join-Path $RepoRoot 'docs/runs/evidence';$details=[ordered]@{}
    if($ObservedRunnerExit-eq0){
        Ensure-Readback ($successLines.Count-eq1) 'Success output must identify exactly one sidecar.'
        $sidecarFile=Read-Held $successLines[0].Groups[1].Value;$sidecar=Read-Closed $sidecarFile
        Ensure-Readback ($sidecar.run_id-cmatch'^[a-z0-9][a-z0-9._-]{0,79}$') 'Unsafe run ID.'
        $runRoot=Join-Path $evidenceRoot $sidecar.run_id;$captureRoot=Join-Path $runRoot 'tablet-layout-c1b'
        Ensure-Readback ([StringComparer]::OrdinalIgnoreCase.Equals($sidecarFile.Path,(Join-Path $captureRoot 'tablet-layout-c1b-sidecar-v1.json'))) 'Success sidecar path/run binding differs.'
        Check-Schema $sidecarFile 'docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json'
        $completed=[DateTimeOffset]::Parse($sidecar.completed_at_utc)
        Ensure-Readback ($completed-ge$started-and$completed-le$ended) 'Sidecar timestamp is outside this attempt.'
        Check-Fields $sidecar @{expected_commit_sha=$expectedCommit;capture_scope='pure_a11y'}
        Assert-TL1C1bSidecarCrossBindings $sidecar
        foreach($key in $actualImplementation.Keys){Check-Fields $sidecar.implementation_hashes @{$key=$actualImplementation[$key]}}
        $artifactMap=@{};$artifacts=@{}
        foreach($property in $sidecar.artifacts.PSObject.Properties){
            $artifact=Read-Held (Join-Path $captureRoot $property.Value.relative_path) ($property.Name-notin@('debug_apk','release_apk'))
            Ensure-Readback (('sha256:'+$artifact.Hash)-ceq$property.Value.sha256) 'Published artifact hash differs.'
            $artifacts[$property.Name]=$artifact;$artifactMap[$artifact.Path]=$property.Value.sha256
        }
        $originalT0=Read-Held (Join-Path $runRoot 'tablet-profile.json')
        Ensure-Readback (('sha256:'+$originalT0.Hash)-ceq$sidecar.upstream_t0.original_sha256-and$originalT0.Hash-ceq$artifacts.upstream_t0.Hash) 'Original/copied T0 hash differs.'
        $artifactMap[$originalT0.Path]='sha256:'+$originalT0.Hash
        Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap
        Ensure-Readback (@([IO.Directory]::EnumerateFileSystemEntries($captureRoot)).Count-eq9) 'Success evidence directory must contain exactly nine artifacts.'
        $observation=Read-Closed $artifacts.observation;Check-Schema $artifacts.observation 'docs/contracts/tablet-layout-observation-c1b-v1.schema.json'
        Check-Fields $observation @{run_id=$sidecar.run_id;expected_title_hash=$sidecar.provider.expected_title_hash}
        Check-Fields $observation.provenance @{kind='gateway_runtime_probe';producer_commit_sha=$expectedCommit;producer_artifact_sha256=$sidecar.apk.local_sha256_before}
        $t0=Read-Closed $originalT0
        Check-Fields $observation.upstream_t0 @{source_kind='trusted_runtime';run_id=$sidecar.run_id;artifact_sha256='sha256:'+$originalT0.Hash;producer_commit_sha=$sidecar.upstream_t0.producer_commit_sha;captured_at=$t0.captured_at_utc}
        $validation=Read-Closed $artifacts.validation
        Check-Fields $validation @{schema='tablet-layout-observation-validation/c1b-v1';fixture_contract_valid=$true;runtime_binding_inputs_match=$true;runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;execution_grant=$false}
        foreach($stem in @('wechat_window_ownership','window_root_projection','application_window_topology','ime_hidden')){Check-Fields $sidecar.claims @{($stem+'_observed')=$validation.($stem+'_observed');($stem+'_verified')=$validation.($stem+'_observed')}}
        Check-Fields $sidecar.claims @{semantic_tree_usable=$validation.semantic_tree_usable}
        $proof=Read-Closed $artifacts.artifact_proof;Check-Schema $artifacts.artifact_proof 'docs/contracts/tablet-c1b-read-only-artifact-proof-v1.schema.json'
        Check-Fields $proof @{git_sha=$expectedCommit;build_challenge_sha256=$sidecar.provider.build_challenge_hash}
        foreach($variant in @('debug','release')){
            $zip=Get-TL1C1bZipDexProof $artifacts[$variant+'_apk'].Path
            Check-Fields $sidecar.read_only_proof @{($variant+'_dex_entry_count')=$zip.EntryCount;($variant+'_dex_sha256')=$zip.Sha256;($variant+'_dex_catalog_sha256')=$zip.CatalogSha256;($variant+'_packaged_manifest_sha256')=$zip.PackagedManifestSha256}
        }
        $identitySources.Add(@{kind='sidecar';path=[IO.Path]::GetRelativePath($RepoRoot,$sidecarFile.Path).Replace('\','/');sha256=$sidecarFile.Hash;byte_length=$sidecarFile.Length})
        $terminal='success';$details=[ordered]@{run_id=$sidecar.run_id;sidecar_sha256='sha256:'+$sidecarFile.Hash;published_artifact_count=$artifactMap.Count;historical_validation_preserved=$true;freshness_replayed=$false;claims=$sidecar.claims;private_server_cleanup_verified=$sidecar.transport.server_cleanup_verified;port_rebind_verified=$sidecar.transport.port_rebind_verified;provider_abort_cleanup=$sidecar.cleanup}
    }elseif($ObservedRunnerExit-eq2){
        $lines=@($stdout-split'\r?\n'|Where-Object{$_-match'"schema"\s*:\s*"tablet-layout-c1b-needs-user/v1"'})
        Ensure-Readback ($lines.Count-eq1) 'Needs-user output must contain one exact payload.'
        $payload=ConvertFrom-TL1C1bClosedJson $lines[0]
        Assert-TL1C1bExactObjectKeys $payload @('schema','status','reason_code','settings_changed','retry_allowed_after_user_action') 'needs-user'
        Check-Fields $payload @{schema='tablet-layout-c1b-needs-user/v1';status='needs-user';reason_code='a11y_service_not_enabled_or_bound';settings_changed=$false;retry_allowed_after_user_action=$true}
        $terminal='needs-user';$details=[ordered]@{payload=$payload;device_install_already_attempted=$true;t0_started=$false;automatic_retry_authorized=$false}
    }else{
        $terminal='failed';$failures=[Collections.Generic.List[object]]::new()
        # Only one exact raw publication pointer from this runner selects failure evidence.
        $references=@($stdout-split'\r?\n'|Where-Object{$_.StartsWith('C1b failure evidence reference: ',[StringComparison]::Ordinal)})
        Ensure-Readback ($references.Count-le1) 'Multiple current failure references are ambiguous.'
        $candidates=@()
        if($references.Count-eq1){
            $reference=ConvertFrom-TL1C1bClosedJson $references[0].Substring(32)
            Assert-TL1C1bExactObjectKeys $reference @('schema','attempt_id','run_id','expected_commit_sha','kind','path','bytes','sha256') 'failure publication reference'
            Check-Fields $reference @{schema='tablet-layout-c1b-failure-reference/v1';expected_commit_sha=$expectedCommit}
            Ensure-Readback ($reference.kind-cin@('run_failure','attempt_failure')-and$reference.sha256-cmatch'^[0-9a-f]{64}$'-and($reference.bytes-is[int]-or$reference.bytes-is[long])-and$reference.bytes-in 1..65536) 'Failure reference raw pin invalid.'
            $failurePath=Resolve-C1bTdRelativePath $RepoRoot $reference.path 'docs/runs/evidence/'
            $candidates=@($failurePath)
        }
        foreach($candidate in $candidates){
            $f=Read-Held $candidate;$v=Read-Closed $f
            Ensure-Readback ($f.Length-eq$reference.bytes-and$f.Hash-ceq$reference.sha256) 'Failure publication raw pin differs.'
            $identitySources.Add(@{kind=$reference.kind;path=$reference.path;sha256=$f.Hash;byte_length=$f.Length})
            if($v.schema-ceq'tablet-layout-c1b-attempt-failure/v1'){
                Ensure-Readback ($f.Length-le65536) 'Attempt failure exceeds bound.'
                Check-Schema $f 'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json'
                Check-Fields $v @{expected_commit_sha=$expectedCommit;status='failed';runner_invocation_count=1;automatic_runner_retry_count=0}
                Ensure-Readback ([IO.Path]::GetFileName($f.Path)-ceq("tablet-layout-c1b-attempt-$($v.attempt_id).json")) 'Attempt ID/path binding differs.'
                $recorded=[DateTimeOffset]::Parse($v.recorded_at_utc)
                Ensure-Readback ($recorded-ge$started-and$recorded-le$ended) 'Attempt failure timestamp is outside this attempt.'
                Assert-TL1C1bAttemptFailureCrossBindings $v
                $failures.Add([ordered]@{schema=$v.schema;sha256='sha256:'+$f.Hash;reason_code=$v.reason_code;pre_device_operations=$v.pre_device_operations;cleanup=$v.cleanup})
            }elseif($v.schema-ceq'tablet-layout-c1b-failure/v2'){
                Ensure-Readback ($f.Length-in 1..65536) 'Run failure exceeds bound.'
                Assert-TL1C1bFailureEvidence $v
                $expectedFailurePath=Join-Path (Join-Path (Join-Path $evidenceRoot $v.run_id) 'tablet-layout-c1b') 'tablet-layout-c1b-failure.json'
                Ensure-Readback ([StringComparer]::OrdinalIgnoreCase.Equals($f.Path,$expectedFailurePath)) 'Failed run ID/path binding differs.'
                $failures.Add([ordered]@{schema=$v.schema;sha256='sha256:'+$f.Hash;run_id=$v.run_id;reason_code=$v.reason_code;provider_failure=$v.provider_failure;provider_abort_cleanup=$v.cleanup;host_cleanup_not_proven_by_this_record=$true})
            }else{throw 'Unknown failure evidence schema.'}
        }
        Ensure-Readback ($failures.Count-le1) 'Multiple current-attempt failure records are ambiguous.'
        $details=[ordered]@{failure_evidence=$failures.ToArray();failure_evidence_absence_is_allowed=$true;failure_stage_not_inferred_from_absence=$true;device_operation_count_not_inferred=$true;raw_diagnostics_preserved_in_receipt_root=$true}
    }
    # Checkpoint selection also comes only from exact current stdout publication lines.
    foreach($line in @($stdout-split'\r?\n')){
        if(-not$line.StartsWith('C1b discovery evidence: ',[StringComparison]::Ordinal)){continue}
        $match=[regex]::Match($line,'^C1b discovery evidence: checkpoint=(before_install|after_capture); path=(docs/runs/evidence/[a-zA-Z0-9._/-]+); sha256=sha256:([0-9a-f]{64})$')
        Ensure-Readback $match.Success 'Malformed current discovery publication reference.'
        $checkpointPath=Resolve-C1bTdRelativePath $RepoRoot $match.Groups[2].Value 'docs/runs/evidence/'
        $checkpoint=Read-Held $checkpointPath
        Ensure-Readback ($checkpoint.Hash-ceq$match.Groups[3].Value) 'Current checkpoint raw pin differs.'
        $identitySources.Add(@{kind='checkpoint';path=$match.Groups[2].Value;sha256=$checkpoint.Hash;byte_length=$checkpoint.Length})
    }
    $discoveryIdentity=Get-C1bTerminalDiscoveryIdentity -Context $discoveryContext -TerminalStatus $terminal -EvidenceSources $identitySources.ToArray() -RunnerStdoutBytes $outFile.Bytes -CheckpointPrePromotionVerified:($terminal-ceq'needs-user')
    foreach($b in $heldFiles.Values){
        $now=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($b.Handle)
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity $now $b.Length
        Ensure-Readback ($now.StableId-ceq$b.Identity.StableId-and$now.LastWriteTimeUtcFileTime-eq$b.Identity.LastWriteTimeUtcFileTime) 'Held file identity changed.'
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $b.Handle $b.Path;Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $b.Path $now $b.Length
        $b.Stream.Position=0;Ensure-Readback ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b.Stream)).ToLowerInvariant()-ceq$b.Hash) 'Held file hash changed.'
    }
    foreach($b in $heldDirectories.Values){Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld $b}
    $answer=[ordered]@{schema='c1b-device-terminal-readback/v1';verification_status='verified';overall_run_passed=($ObservedRunnerExit-eq0);terminal_status=$terminal;expected_commit_sha=$expectedCommit;observed_outer_exit=$ObservedWrapperExit;observed_runner_exit=$ObservedRunnerExit;observed_runner_pid=$ObservedRunnerPid;runner_exit=$exitRecord.runner_exit_code;runner_pid=$exitRecord.runner_pid;reservation_sha256='sha256:'+$onceFile.Hash;exit_receipt_sha256='sha256:'+$exitFile.Hash;stdout_byte_length=$outFile.Length;stdout_sha256='sha256:'+$outFile.Hash;stderr_byte_length=$errFile.Length;stderr_sha256='sha256:'+$errFile.Hash;implementation_file_count=42;implementation_catalog_sha256=$expectedCatalog;details=$details;discovery_identity=$discoveryIdentity;assertion_count=$checks;cleanup_failure_count=0;readback_external_process_invocation_count=0;readback_device_invocation_count=0}
}catch{$primary=$_.Exception.Message}
finally{
    if($null-ne$discoveryContext){try{Close-C1bTerminalDiscoveryContext $discoveryContext}catch{$cleanupFailures.Add($_.Exception.Message)}}
    if($null-ne$discoveryBootstrap){try{$discoveryBootstrap.Dispose()}catch{$cleanupFailures.Add($_.Exception.Message)}}
    foreach($b in $heldFiles.Values){try{if($null-ne$b.Stream){$b.Stream.Dispose()}else{$b.Handle.Dispose()}}catch{$cleanupFailures.Add($_.Exception.Message)}}
    foreach($b in $heldDirectories.Values){try{$b.Handle.Dispose()}catch{$cleanupFailures.Add($_.Exception.Message)}}
    if($null-ne$bootstrap){try{$bootstrap.Dispose()}catch{$cleanupFailures.Add($_.Exception.Message)}}
}
if($null-ne$primary-or$cleanupFailures.Count-ne0){[ordered]@{schema='c1b-device-terminal-readback/v1';verification_status='rejected';overall_run_passed=$false;observed_outer_exit=$ObservedWrapperExit;observed_runner_exit=$ObservedRunnerExit;observed_runner_pid=$ObservedRunnerPid;primary=$primary;cleanup_failure_count=$cleanupFailures.Count;assertion_count=$checks}|ConvertTo-Json -Depth 8 -Compress;exit 1}
$answer|ConvertTo-Json -Depth 15 -Compress
exit 0
