#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
foreach($name in @('tablet-layout-c1a.ps1','tablet-layout-observation-v2-validator.ps1',
    'tablet-layout-observation-c1b-v1-validator.ps1','tablet-layout-c1b.ps1','tablet-layout-c1b-readonly.ps1')){
    . (Join-Path $RepoRoot ('scripts/lib/'+$name))
}
$runner=Join-Path $RepoRoot 'scripts/run-tablet-layout-c1b.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'runner parse failed'}
# Execute the real failure functions and terminal catch, never the runner body.
foreach($name in @('Get-C1bTimestamp','Write-C1bFailureReference','Write-C1bFailureEvidence')){
    $matches=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true))
    if($matches.Count-ne1){throw 'runner function extraction is not unique'}
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
$terminalMatches=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.TryStatementAst]-and
    $node.Extent.Text.StartsWith("try{Write-C1bFailureEvidence 'c1b_runner_failed'}",[StringComparison]::Ordinal)},$true))
if($terminalMatches.Count-ne1){throw 'runner terminal failure catch extraction is not unique'}
$terminalFailure=[scriptblock]::Create($terminalMatches[0].Extent.Text)
$testRoot=Join-Path $RepoRoot ('.checks/c1b-runner-failure-reference/cases-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$passed=0;$failed=0;$assertions=0;$publicationError=$null;$publicationRecords=@()
function Check([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Capture-Publication([scriptblock]$Body){
    $records=[Collections.Generic.List[object]]::new();$script:publicationError=$null
    try{&$Body 6>&1|ForEach-Object{$records.Add($_)}}catch{$script:publicationError=$_}
    $script:publicationRecords=@($records)
    return @($records|ForEach-Object{$_.ToString()}|Where-Object{$_.StartsWith('C1b failure evidence reference: ',[StringComparison]::Ordinal)})
}
function Read-Reference([string[]]$Lines){
    Check ($Lines.Count-eq1) 'publication must emit exactly one reference'
    $value=ConvertFrom-TL1C1bClosedJson $Lines[0].Substring('C1b failure evidence reference: '.Length)
    Assert-TL1C1bExactObjectKeys $value @('schema','attempt_id','run_id','expected_commit_sha','kind','path','bytes','sha256') 'failure reference'
    Check ($value.schema-ceq'tablet-layout-c1b-failure-reference/v1'-and$value.bytes-is[long]-and
        $value.sha256-cmatch'^[0-9a-f]{64}$'-and$value.path-cnotmatch'\\|(^|/)\.\.?(/|$)') 'reference grammar/type is not canonical'
    $path=Join-Path $RepoRoot $value.path;$rawBytes=[IO.File]::ReadAllBytes($path)
    Check ($value.bytes-eq$rawBytes.Length-and$value.sha256-ceq
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes)).ToLowerInvariant()) 'reference is not bound to actual bytes'
    return $value
}
function Reset-Runner([string]$Name,[switch]$Early){
    $script:attemptId='tl1-c1b-20260829t010203z-123456789abc';$script:runId=if($Early){$null}else{$script:attemptId}
    $script:ExpectedCommitSha='a'*40;$script:providerFailure=$null
    $script:sessionStarted=$false;$script:sessionConsumed=$false;$script:abortAttempted=$false;$script:abortSucceeded=$false
    $casePath=Join-Path $testRoot $Name;[void](New-Item -ItemType Directory -Path $casePath)
    $script:c1bDirectory=if($Early){$null}else{$casePath};$script:EvidenceRoot=$casePath
    $script:AttemptFailureSchema=Join-Path $RepoRoot 'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json'
    $script:privateAdbStartupDiagnostic=if($Early){[pscustomobject][ordered]@{
        schema='tablet-layout-c1b-private-adb-startup-diagnostic/v1';outcome='failed'
        final_substage='port_selection_timeout';server_attempt_count=0;attempts=@()
    }}else{$null}
    $script:buildCompleted=[bool]$Early;$script:artifactChecksCompleted=[bool]$Early
    $script:artifactGuardsCleanup='not_acquired';$script:buildEnvironmentCleanup='not_acquired';$script:deviceLeaseCleanup='not_acquired'
}
function Run-FailurePath {return Join-Path $script:c1bDirectory 'tablet-layout-c1b-failure.json'}
function Assert-NoReference([string[]]$Lines,[string]$Message){Check ($Lines.Count-eq0) $Message}

Test-Case run_failure_publishes_raw_bound_real_identity {
    Reset-Runner run
    $lines=@(Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    Check ($null-eq$publicationError) 'run failure publication threw'
    $reference=Read-Reference $lines
    Check ($reference.kind-ceq'run_failure'-and$reference.attempt_id-ceq$attemptId-and$reference.run_id-ceq$runId-and
        $reference.expected_commit_sha-ceq$ExpectedCommitSha) 'run/attempt identity was invented'
    $payload=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText((Run-FailurePath)))
    Check ($payload.status-ceq'failed'-and$null-eq$payload.provider_failure-and-not$payload.execution_grant) 'failure payload changed'
}
Test-Case early_failure_keeps_null_run_id {
    Reset-Runner early -Early
    $lines=@(Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    if($null-ne$publicationError){throw ('early publication threw: '+$publicationError.Exception.Message)}
    Check ($null-eq$publicationError) 'early publication threw'
    $reference=Read-Reference $lines
    Check ($reference.kind-ceq'attempt_failure'-and$reference.attempt_id-ceq$attemptId-and$null-eq$reference.run_id) 'early id was promoted'
    $payload=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText((Join-Path $RepoRoot $reference.path)))
    Check ($payload.run_id-eq$null-and$payload.pre_device_operations.install_count-eq0-and
        $payload.pre_device_operations.device_discovery_count-eq0) 'early failure acquired device facts'
}
Test-Case unavailable_early_diagnostic_publishes_nothing {
    Reset-Runner unavailable -Early;$script:privateAdbStartupDiagnostic=$null
    $lines=@(Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    Assert-NoReference $lines 'unavailable evidence became a reference'
    Check ($null-eq$publicationError-and@(Get-ChildItem $EvidenceRoot -File).Count-eq0) 'unavailable diagnostic became a file'
}
Test-Case run_collision_is_preserved_without_new_reference {
    Reset-Runner run-collision
    [void](Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    $before=[IO.File]::ReadAllBytes((Run-FailurePath))
    $lines=@(Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    Assert-NoReference $lines 'existing run failure republished as new evidence'
    Check ($null-eq$publicationError-and(Get-TL1C1aSha256Bytes ([IO.File]::ReadAllBytes((Run-FailurePath))))-ceq
        (Get-TL1C1aSha256Bytes $before)) 'run collision overwrote primary record'
}
Test-Case attempt_collision_preserves_primary_terminal_failure {
    Reset-Runner attempt-collision -Early
    [void](Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    if($null-ne$publicationError){throw ('initial attempt publication threw: '+$publicationError.Exception.Message)}
    $path=Join-Path $EvidenceRoot ("tablet-layout-c1b-attempt-$attemptId.json");$before=Get-TL1C1aFileSha256 $path
    $output=@(&{$failure='PRIMARY-SENTINEL';. $terminalFailure;[pscustomobject]@{failure=$failure}} 6>&1)
    Check ($output.Count-eq1-and$output[0].failure-ceq'PRIMARY-SENTINEL；且 failure evidence 写入失败。') 'secondary publication replaced primary failure'
    Check ((Get-TL1C1aFileSha256 $path)-ceq$before) 'attempt collision changed original bytes'
}
Test-Case raw_hash_drift_cannot_publish_reference {
    Reset-Runner raw-drift
    [void](Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    $path=Run-FailurePath;$payload=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText($path))
    $raw=[IO.File]::ReadAllText($path).Replace('c1b_runner_failed','c1b_runnez_failed')
    [IO.File]::WriteAllText($path,$raw,[Text.UTF8Encoding]::new($false))
    $lines=@(Capture-Publication {Write-C1bFailureReference $path run_failure $payload})
    Assert-NoReference $lines 'raw drift was advertised'
    Check ($null-ne$publicationError-and$publicationError.Exception.Message.Contains('原始 hash')) 'raw bytes were not checked'
}
Test-Case mismatched_id_cannot_publish_reference {
    Reset-Runner identity
    [void](Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    $path=Run-FailurePath;$payload=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText($path));$script:runId='tl1-c1b-other'
    $lines=@(Capture-Publication {Write-C1bFailureReference $path run_failure $payload})
    Assert-NoReference $lines 'mismatched id was advertised'
    Check ($null-ne$publicationError) 'id mismatch accepted'
}
Test-Case native_hardlink_is_rejected {
    Reset-Runner hardlink
    [void](Capture-Publication {Write-C1bFailureEvidence c1b_runner_failed})
    $path=Run-FailurePath;$payload=ConvertFrom-TL1C1bClosedJson ([IO.File]::ReadAllText($path))
    [void](New-Item -ItemType HardLink -Path (Join-Path $c1bDirectory 'second-link.json') -Target $path)
    $lines=@(Capture-Publication {Write-C1bFailureReference $path run_failure $payload})
    Assert-NoReference $lines 'hardlink file was advertised'
    Check ($null-ne$publicationError) 'native single-link identity gate did not reject'
}
Test-Case controlled_writer_failure_cannot_replace_primary_or_publish {
    Reset-Runner write-failure
    $output=@(&{
        function Write-TL1C1aJsonAtomic {param($RepoRoot,$Destination,$Value)throw 'CONTROLLED-WRITE-FAILURE'}
        $failure='PRIMARY-SENTINEL';. $terminalFailure;[pscustomobject]@{failure=$failure}
    } 6>&1)
    Check ($output.Count-eq1-and$output[0].failure-ceq'PRIMARY-SENTINEL；且 failure evidence 写入失败。') 'write failure replaced primary or emitted reference'
    Check (-not(Test-Path -LiteralPath (Run-FailurePath))) 'failed writer produced a payload'
}
Test-Case real_atomic_root_escape_cannot_replace_primary_or_publish {
    Reset-Runner outside-root
    $isolatedRoot=Join-Path $testRoot 'separate-root';[void](New-Item -ItemType Directory -Path $isolatedRoot)
    $output=@(&{
        $RepoRoot=$isolatedRoot;$failure='PRIMARY-SENTINEL'
        . $terminalFailure;[pscustomobject]@{failure=$failure}
    } 6>&1)
    Check ($output.Count-eq1-and$output[0].failure-ceq'PRIMARY-SENTINEL；且 failure evidence 写入失败。') 'actual atomic path refusal replaced primary or emitted reference'
    Check (-not(Test-Path -LiteralPath (Run-FailurePath))) 'actual atomic path refusal published a file'
}

Test-Case readonly_proof_preserves_exact_device_surface {
    $proof=Assert-TL1C1bRunnerReadOnlyAst $runner
    Check ($proof.c1a_invocation_counts.install-eq1-and$proof.c1b_invocation_counts.content_c1-eq1-and
        $proof.c1b_invocation_counts.content_c2-eq1-and$proof.static_zero_counts.action_call_count-eq0) 'read-only device surface changed'
}
Test-Case readonly_semantic_reference_mutations_rejected {
    $source=[IO.File]::ReadAllText($runner);$originalToken=$script:TL1C1bReadonlyRunnerTokenSha256
    $cases=@(
        @('$hash-cne[Convert]','$hash-ceq[Convert]','raw-hash'),
        @('$stream.SafeFileHandle $full $issues','$stream.SafeFileHandle $Path $issues','native-binding'),
        @('run_id=$runId','run_id=$attemptId','run-promotion'),
        @('C1b failure evidence reference: ','C1b failure evidence ref: ','grammar'),
        @('C1b failure evidence reference: ','C1bfailureevidencereference:','literal-spaces'),
        @("Write-C1bFailureReference `$path 'attempt_failure' `$payload","Write-C1bFailureReference `$path 'attempt_failure' `$otherPayload",'early-value')
    )
    try{
        foreach($case in $cases){
            $position=$source.IndexOf($case[0],[StringComparison]::Ordinal);Check ($position-ge0) 'mutation anchor missing'
            $candidate=$source.Substring(0,$position)+$case[1]+$source.Substring($position+$case[0].Length)
            $path=Join-Path $testRoot ($case[2]+'.ps1');[IO.File]::WriteAllText($path,$candidate,[Text.UTF8Encoding]::new($false))
            $parsed=Read-TL1C1bReadonlyAst $path 'reference mutation';$script:TL1C1bReadonlyRunnerTokenSha256=$parsed.TokenSha256
            $message=$null;try{[void](Assert-TL1C1bRunnerReadOnlyAst $path)}catch{$message=$_.Exception.Message}
            Check ($null-ne$message-and$message-cmatch'failure reference .*binding 漂移。$') 'semantic reference mutation was accepted or stopped only at token gate'
        }
    }finally{$script:TL1C1bReadonlyRunnerTokenSha256=$originalToken}
}
[pscustomobject]@{schema='c1b-runner-failure-reference-offline/v1';passed=$passed;failed=$failed;assertions=$assertions
    runner_entrypoint_executed=$false;real_adb_call_count=0;real_device_operation_count=0}|ConvertTo-Json -Compress
if($failed){exit 1}
