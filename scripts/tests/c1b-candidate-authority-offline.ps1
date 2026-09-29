#Requires -Version 7.5
[CmdletBinding()]
param([string]$EvidenceRoot)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
if(-not$IsWindows){throw 'Windows native A1/capture tests required.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if([string]::IsNullOrEmpty($EvidenceRoot)){$EvidenceRoot=Join-Path $repo '.checks\goal-20260930\a1'}
[void][IO.Directory]::CreateDirectory($EvidenceRoot)
$runRoot=Join-Path $EvidenceRoot ('run-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($runRoot)
$producer=Join-Path $repo 'scripts\audit-c1b-candidate-authority.ps1';$captureSource=Join-Path $repo 'scripts\lib\c1b-host-process-capture.ps1'
$runtime=[Environment]::ProcessPath;$git=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Git\cmd\git.exe'
$runtimeSha=(Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant();$gitSha=(Get-FileHash -LiteralPath $git -Algorithm SHA256).Hash.ToLowerInvariant();$captureSha=(Get-FileHash -LiteralPath $captureSource -Algorithm SHA256).Hash.ToLowerInvariant()
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($producer,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Producer parser failed.'}
# Load actual helper AST and native declaration only; never execute the producer main body here.
$native=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and$_.Extent.Text.Contains('C1bA1NativeV1')-and$_.Extent.Text.Contains('Add-Type')})
if($native.Count-ne1){throw 'Producer native declaration cardinality.'};. ([scriptblock]::Create($native[0].Extent.Text))
foreach($function in @($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})){. ([scriptblock]::Create($function.Extent.Text))}
. $captureSource
$assertions=0;$cases=[Collections.Generic.List[object]]::new();$fixtureCommands=[Collections.Generic.List[object]]::new()
function Check([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Message){$rejected=$false;try{&$Action}catch{$rejected=$true};Check $rejected $Message}
function Case([string]$Name,[scriptblock]$Action){&$Action;$script:cases.Add(@{name=$Name;status='passed'});Write-Host ('PASS '+$Name)}
function Bytes([string]$Text){return ,([Text.UTF8Encoding]::new($false).GetBytes($Text))}
function FixtureGit([string[]]$Arguments,[string]$Directory){
    $dir=Join-Path $runRoot ('fixture-git-'+[Guid]::NewGuid().ToString('N'))
    $argv=@('--no-optional-locks','-c','core.fsmonitor=false','-c','core.hooksPath=NUL','-C',$Directory)+$Arguments
    $r=Invoke-TL1C1bHostProcessCapture -ExecutablePath $git -ArgumentList $argv -WorkingDirectory $Directory -EvidenceDirectory $dir -Environment (Get-C1bA1Environment) -ClearEnvironment -TimeoutMilliseconds 30000
    $script:fixtureCommands.Add(@{directory=$Directory;arguments=$argv;capture_path=(Join-Path $dir 'execution.json');actual_exit=$r.exit_code})
    Check ($r.status-ceq'passed'-and$r.exit_code-eq0-and$r.stdout.eof-and$r.stderr.eof-and$r.cleanup.completed) 'Synthetic fixture Git command failed.'
    return ,([IO.File]::ReadAllBytes((Join-Path $dir 'stdout.bin')))
}
$fixture=Join-Path $runRoot 'fixture-source';[void][IO.Directory]::CreateDirectory($fixture)
$paths=[Collections.Generic.List[string]]::new();$paths.Add('scripts/lib/tablet-layout-c1b.ps1')
for($n=0;$n-lt41;$n++){$path=if($n-eq7){'docs/中文 名称.md'}else{'scripts/fixture-'+$n.ToString('00')+'.txt'};$paths.Add($path);$full=Join-Path $fixture $path.Replace('/','\');[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full));[IO.File]::WriteAllBytes($full,(Bytes ('synthetic-content-'+$n+"`n")))}
$mapText='$script:TL1C1bImplementationPathMap = [ordered]@{' + "`n" + "    c1b_library_sha256='scripts/lib/tablet-layout-c1b.ps1'`n"
for($n=1;$n-lt$paths.Count;$n++){$mapText+="    fixture_$($n.ToString('00'))_sha256='$($paths[$n])'`n"};$mapText+="}`n"
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts\lib'))
[IO.File]::WriteAllBytes((Join-Path $fixture $paths[0]),(Bytes $mapText));[IO.File]::WriteAllBytes((Join-Path $fixture '.gitattributes'),(Bytes "* text eol=lf`n"));[IO.File]::WriteAllBytes((Join-Path $fixture '.gitignore'),(Bytes ".checks/`n"))
$null=FixtureGit @('init','--initial-branch=synthetic-a1') $fixture
$null=FixtureGit @('-c','core.autocrlf=false','add','--all') $fixture
$null=FixtureGit @('-c','user.name=Synthetic Fixture','-c','user.email=synthetic@example.invalid','-c','commit.gpgsign=false','commit','--no-verify','-m','Synthetic A1 fixture') $fixture
$fixtureSha=(ConvertFrom-C1bA1Utf8 (FixtureGit @('rev-parse','--verify','HEAD^{commit}') $fixture)).Trim()
function New-FixtureClone([string]$Name){
    $clone=Join-Path $runRoot $Name;$null=FixtureGit @('clone','--no-hardlinks','--no-local',$fixture,$clone) $runRoot
    return $clone
}
function Run-Producer([string]$Clone,[string]$Name,[string]$Sha=$fixtureSha,[string]$GitPin=$gitSha,[string]$CapturePin=$captureSha){
    $auditId=[Guid]::NewGuid().ToString('N');$evidence=Join-Path $runRoot ($Name+'-a1');$outer=Join-Path $runRoot ($Name+'-outer')
    $argv=@('-NoProfile','-File',$producer,'-RepositoryRoot',$Clone,'-CandidateSha',$Sha,'-AuditRunId',$auditId,'-CandidateState','UnfrozenPreparation','-GitPath',$git,'-ExpectedGitSha256',$GitPin,'-ExpectedRuntimeSha256',$runtimeSha,'-CaptureSourcePath',$captureSource,'-ExpectedCaptureSourceSha256',$CapturePin,'-EvidenceDirectory',$evidence)
    $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath $runtime -ArgumentList $argv -WorkingDirectory $runRoot -EvidenceDirectory $outer -CaptureLimitBytes 16777216 -TimeoutMilliseconds 120000
    $capturePinActual=@{path=(Join-Path $outer 'execution.json');byte_length=[long](Get-Item -LiteralPath (Join-Path $outer 'execution.json')).Length;sha256=(Get-FileHash -LiteralPath (Join-Path $outer 'execution.json')).Hash.ToLowerInvariant()}
    Save-C1bA1NewJson (Join-Path $outer 'root-observation.json') @{schema='c1b-host-root-observation/v1';candidate_sha=$Sha;phase='A1Audit';run_id=$auditId;process_id=$capture.child_pid;native_exit_code=$capture.exit_code;capture_pin=$capturePinActual}
    return @{capture=$capture;evidence=$evidence;outer=$outer;audit_id=$auditId}
}

Case 'actual-synthetic-clone-four-canonical-Git-captures' {
    $clone=New-FixtureClone 'valid-clone';$run=Run-Producer $clone 'valid'
    Check ($run.capture.status-ceq'passed'-and$run.capture.exit_code-eq0) 'Actual A1 producer failed on synthetic ordinary clone.'
    $receipt=ConvertFrom-C1bA1Utf8 ([IO.File]::ReadAllBytes((Join-Path $run.outer 'stdout.bin')))|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($receipt.status-ceq'passed_preparation_only'-and$receipt.git_query_count-eq4-and$receipt.implementation_count-eq42-and$receipt.tracked_path_count-eq$paths.Count+2) 'Actual synthetic A1 counts or preparation status.'
    Check ($receipt.producer_process_id-eq$run.capture.child_pid-and$receipt.audit_run_id-ceq$run.audit_id-and$receipt.cleanup_failure_count-eq0) 'Actual producer identity/cleanup mismatch.'
    Check ($receipt.object_store.single_link_verified-and$receipt.object_store.file_count-gt0-and$receipt.object_store.no_alternates-and$receipt.object_store.no_commondir) 'Independent object store evidence.'
    $catalog=[IO.File]::ReadAllText($receipt.a1.implementation_catalog_pin.path)|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($catalog.entries.Count-eq42-and$catalog.held_inputs_during_git_queries) 'Actual held raw catalog evidence.'
    foreach($audit in $receipt.a1.git_audits){
        $cap=[IO.File]::ReadAllText($audit.capture_pin.path)|ConvertFrom-Json -AsHashtable -DateKind String
        $root=[IO.File]::ReadAllText($audit.root_observation_pin.path)|ConvertFrom-Json -AsHashtable -DateKind String
        Check ($root.process_id-eq$cap.child_pid-and$root.native_exit_code-eq0-and$cap.stdout.eof-and$cap.stderr.eof-and$cap.cleanup.completed) 'A1 actual child/root/EOF/cleanup.'
        Check ($cap.environment.mode-ceq'replace'-and$cap.environment.keys.Count-eq15) 'A1 exact15-key environment not actual replacement.'
    }
    Check ((Get-Item -LiteralPath (Join-Path $run.evidence 'A1Status\capture\stdout.bin')).Length-eq0) 'Git clean status was not actual empty raw stream.'
    $tree=[IO.File]::ReadAllBytes((Join-Path $run.evidence 'A1Tree\capture\stdout.bin'))
    Check ($tree[-1]-eq0-and(ConvertFrom-C1bA1Utf8 $tree).Contains('docs/中文 名称.md')) 'Git binary tree/Unicode path not preserved.'
    $script:validReceipt=$receipt;$script:validRun=$run
}
Case 'actual-producer-stdout-strict-UTF8-with-Unicode-path' {
    $text=ConvertFrom-C1bA1Utf8 ([IO.File]::ReadAllBytes((Join-Path $validRun.outer 'stdout.bin')))
    Check ($text.Contains('中文 名称.md')) 'Actual outer stdout lost its Unicode source path.'
    $disk=[IO.File]::ReadAllText((Join-Path $validRun.evidence 'a1-receipt.json'))|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($validReceipt.candidate_sha-ceq$disk.candidate_sha-and$validReceipt.producer_process_id-eq$disk.producer_process_id-and$validReceipt.a1.implementation_catalog_pin.sha256-ceq$disk.a1.implementation_catalog_pin.sha256-and$validReceipt.source_pins.a1_auditor.sha256-ceq$disk.source_pins.a1_auditor.sha256) 'Native stdout and readable receipt identity/source/catalog differ.'
    Reject {ConvertFrom-C1bA1Utf8 ([byte[]]@(0xd6,0xd0,0xce,0xc4))} 'CP936 bytes accepted as strict UTF8 authority.'
}
Case 'literal-map-admission' {
    Check ((Get-C1bA1Map (Bytes $mapText)).Count-eq42) 'Literal42 map parser.'
    Reject {Get-C1bA1Map (Bytes ($mapText.Replace("'scripts/fixture-00.txt'",'(Get-Date)')))} 'Nonliteral map path accepted.'
    Reject {Get-C1bA1Map (Bytes ($mapText.Replace("'scripts/fixture-01.txt'","'scripts/fixture-00.txt'")))} 'Duplicate implementation path accepted.'
}
Case 'binary-empty-and-failed-fakeGit-real-capture' {
    $worker=Join-Path $runRoot 'fake-git-stream-worker.ps1'
    [IO.File]::WriteAllBytes($worker,(Bytes @'
param([ValidateSet('binary','empty','failed')][string]$Scenario)
if($Scenario-ceq'binary'){$b=[Text.UTF8Encoding]::new($false).GetBytes("100644 blob $('a'*40)`tdocs/中文 名称.md$([char]0)");[Console]::OpenStandardOutput().Write($b)}
if($Scenario-ceq'failed'){[Console]::Error.WriteLine('synthetic fakeGit failure');exit 7}
exit 0
'@))
    foreach($scenario in @('binary','empty','failed')){
        $directory=Join-Path $runRoot ('fake-'+$scenario);$r=Invoke-TL1C1bHostProcessCapture -ExecutablePath $runtime -ArgumentList @('-NoProfile','-File',$worker,'-Scenario',$scenario) -WorkingDirectory $runRoot -EvidenceDirectory $directory -Environment (Get-C1bA1Environment) -ClearEnvironment -TimeoutMilliseconds 30000
        if($scenario-ceq'failed'){Check ($r.status-ceq'failed'-and$r.exit_code-eq7-and$r.stdout.eof-and$r.stderr.eof-and$r.cleanup.completed) 'Actual failed fakeGit exit was hidden.'}
        else{$bytes=[IO.File]::ReadAllBytes((Join-Path $directory 'stdout.bin'));$index=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal);$index.Add('docs/中文 名称.md',('a'*40));$phase=if($scenario-ceq'binary'){'A1Tree'}else{'A1Status'};Assert-C1bA1Query $phase $bytes ('b'*40) 'fake' $index;Check ($r.exit_code-eq0-and$r.stdout.eof-and$r.stderr.eof) 'Actual fakeGit transport failed.'}
    }
}
Case 'captured-query-semantic-negative-cases' {
    Reject {Assert-C1bA1Query 'A1Head' (Bytes (('b'*40)+"`n")) ('a'*40) 'x' @{}} 'HEAD SHA mismatch accepted.'
    Reject {Assert-C1bA1Query 'A1Status' (Bytes " `n") ('a'*40) 'x' @{}} 'Whitespace clean status accepted.'
    Reject {Assert-C1bA1Query 'A1Tree' (Bytes "100644 blob $('a'*40)`tscripts/a.txt") ('a'*40) 'x' @{}} 'Non-NUL binary tree accepted.'
    Reject {Assert-C1bA1Query 'A1Tree' (Bytes "160000 commit $('a'*40)`tscripts/a.txt$([char]0)") ('a'*40) 'x' @{}} 'Submodule tree entry accepted.'
}
Case 'wrong-candidate-sha-before-query' {
    $clone=New-FixtureClone 'wrong-sha-clone';$run=Run-Producer $clone 'wrong-sha' ('f'*40)
    Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Wrong raw ref SHA did not reject before query reservation.'
}
Case 'wrong-executable-or-capture-pin-before-query' {
    foreach($name in @('wrong-git','wrong-capture')){
        $clone=New-FixtureClone ($name+'-clone');$pin=if($name-ceq'wrong-git'){'0'*64}else{$gitSha};$source=if($name-ceq'wrong-capture'){'0'*64}else{$captureSha};$run=Run-Producer $clone $name $fixtureSha $pin $source
        Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Wrong executable/source pin did not reject before query.'
    }
}
Case 'frozen-postBuildOnly-marker-before-query' {
    $clone=New-FixtureClone 'frozen-clone';[void][IO.Directory]::CreateDirectory((Join-Path $clone '.checks\c1b-candidate-a4'))
    $run=Run-Producer $clone 'frozen';Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Frozen marker did not block all ordinary Git queries.'
}
Case 'consumed-SHA-and-historical-clone-component-early-admission' {
    # Pure helper checks: these paths are synthetic strings and are never opened.
    Reject {Assert-C1bA1Unconsumed '4b37f344d5af988ce9b2f7610df98387a49cd2d0' (Join-Path $runRoot 'new-clean-placeholder')} 'Consumed full SHA admitted without marker.'
    Reject {Assert-C1bA1Unconsumed $fixtureSha (Join-Path $runRoot 'agent-for-mobile-c1b-candidate-20260929-r3')} 'Historical clone component admitted without marker.'
    Reject {Assert-C1bA1Unconsumed $fixtureSha (Join-Path $runRoot 'AGENT-FOR-MOBILE-C1B-CANDIDATE-20260929-R3\child')} 'Historical clone case/descendant bypass admitted.'
    Assert-C1bA1Unconsumed $fixtureSha (Join-Path $runRoot 'new-clean-placeholder')
    Check $true 'Ordinary new clone admission.'
}
Case 'alternates-and-hardlinks-native-admission' {
    $clone=New-FixtureClone 'alternates-clone';[IO.File]::WriteAllBytes((Join-Path $clone '.git\objects\info\alternates'),(Bytes ($fixture+"`n")))
    $run=Run-Producer $clone 'alternates';Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Alternates accepted.'
    $original=Join-Path $runRoot 'hardlink-source.bin';$alias=Join-Path $runRoot 'hardlink-alias.bin';[IO.File]::WriteAllBytes($original,(Bytes 'synthetic'))
    New-Item -ItemType HardLink -Path $alias -Target $original | Out-Null
    $session=New-C1bA1Session;try{Reject {Read-C1bA1HeldFile $session $alias} 'Native multi-link file admitted.'}finally{$errors=Close-C1bA1Session $session;Check ($errors.Count-eq0) 'Hardlink-reject cleanup.'}
}
Case 'ordinary-dotgit-and-shared-or-shallow-admission' {
    $fileGit=Join-Path $runRoot 'dotgit-file-clone';[void][IO.Directory]::CreateDirectory($fileGit);[IO.File]::WriteAllBytes((Join-Path $fileGit '.git'),(Bytes "gitdir: ../elsewhere`n"))
    $run=Run-Producer $fileGit 'dotgit-file';Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Worktree .git file admitted.'
    foreach($marker in @('commondir','shallow')){
        $clone=New-FixtureClone ($marker+'-clone');[IO.File]::WriteAllBytes((Join-Path $clone ('.git\'+$marker)),(Bytes "synthetic`n"));$run=Run-Producer $clone $marker
        Check ($run.capture.exit_code-eq1-and-not[IO.Directory]::Exists($run.evidence)) 'Shared/shallow metadata did not reject before Git.'
    }
}
Case 'native-object-directory-reparse-admission' {
    $junction=Join-Path $runRoot 'object-junction';New-Item -ItemType Junction -Path $junction -Target $fixture | Out-Null
    $session=New-C1bA1Session;try{Reject {Open-C1bA1Directories $session $junction} 'Native reparse directory admitted.'}finally{$errors=Close-C1bA1Session $session;Check ($errors.Count-eq0) 'Native reparse rejection cleanup.'}
}
Case 'dirty-status-actual-canonical-Git-fails-no-retry' {
    $clone=New-FixtureClone 'dirty-clone';[IO.File]::WriteAllBytes((Join-Path $clone 'scripts\fixture-00.txt'),(Bytes 'synthetic changed source'))
    $run=Run-Producer $clone 'dirty';$receipt=[IO.File]::ReadAllText((Join-Path $run.evidence 'a1-receipt.json'))|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($run.capture.exit_code-eq1-and$receipt.status-ceq'failed'-and$receipt.git_query_count-eq3-and$receipt.automatic_retry_count-eq0) 'Actual dirty status did not fail after third query.'
    Check (-not[IO.Directory]::Exists((Join-Path $run.evidence 'A1Tree'))) 'Failed dirty status continued into fourth Git query.'
}
Case 'actual-Git-nonzero-first-query-preserved-no-retry' {
    $clone=New-FixtureClone 'missing-object-clone';$objectPath=Join-Path $clone ('.git\objects\'+$fixtureSha.Substring(0,2)+'\'+$fixtureSha.Substring(2))
    # --no-local may pack objects. Remove the exact pack inputs from this owned disposable fixture only.
    $ownedObjectRoot=[IO.Path]::GetFullPath((Join-Path $clone '.git\objects'))
    if([IO.File]::Exists($objectPath)){$targets=@($objectPath)}else{$targets=@([IO.Directory]::EnumerateFiles((Join-Path $ownedObjectRoot 'pack'),'*.pack'))}
    Check ($targets.Count-gt0) 'Synthetic corrupt-object fixture missing exact deletion target.'
    foreach($target in $targets){Check ([IO.Path]::GetFullPath($target).StartsWith($ownedObjectRoot+'\',[StringComparison]::OrdinalIgnoreCase)) 'Synthetic object deletion leaves owned fixture.';[IO.File]::SetAttributes($target,([IO.File]::GetAttributes($target)-band(-bnot[IO.FileAttributes]::ReadOnly)));[IO.File]::Delete($target)}
    $run=Run-Producer $clone 'missing-object';$receipt=[IO.File]::ReadAllText((Join-Path $run.evidence 'a1-receipt.json'))|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($run.capture.exit_code-eq1-and$receipt.status-ceq'failed'-and$receipt.git_query_count-eq1-and$receipt.automatic_retry_count-eq0) 'Actual canonical Git failure not preserved or retried.'
    $root=[IO.File]::ReadAllText($receipt.git_audits[0].root_observation_pin.path)|ConvertFrom-Json -AsHashtable -DateKind String
    Check ($root.native_exit_code-ne0-and$root.process_id-gt0) 'Root observer did not preserve actual failed Git exit.'
}
Case 'native-held-write-block-and-end-readback' {
    $path=Join-Path $runRoot 'held-file.txt';[IO.File]::WriteAllBytes($path,(Bytes 'fixed'));$session=New-C1bA1Session
    try{$first=Get-C1bA1Pin $session $path;$second=Get-C1bA1Pin $session $path;Check ($first.sha256-ceq$second.sha256) 'Same-handle repeat read did not rewind.';Reject {[IO.File]::WriteAllBytes($path,(Bytes 'drift'))} 'Held nofollow file allowed writes.'}
    finally{$errors=Close-C1bA1Session $session;Check ($errors.Count-eq0) 'Terminal held guard rehash/release failed.'}
}
$summary=@{schema='c1b-candidate-authority-offline/v1';status='passed';synthetic=$true;production_candidate_a1_claim=$false;case_count=$cases.Count;assertions=$assertions;actual_canonical_git_queries=4;fake_git_stream_scenarios=3;producer_source_sha256=(Get-FileHash $producer).Hash.ToLowerInvariant();capture_source_sha256=$captureSha;runtime_sha256=$runtimeSha;git_sha256=$gitSha;valid_a1_receipt_path=(Join-Path $validRun.evidence 'a1-receipt.json');valid_a1_outer_capture_path=(Join-Path $validRun.outer 'execution.json');fixture_commands=$fixtureCommands.ToArray();cases=$cases.ToArray();adb_execution_count=0;build_execution_count=0}
Save-C1bA1NewJson (Join-Path $runRoot 'summary.json') $summary
Write-Host "C1b A1 offline: $($cases.Count)/$($cases.Count) passed, $assertions assertions, synthetic only."
Write-Output (ConvertTo-Json -InputObject $summary -Depth 8 -Compress)
