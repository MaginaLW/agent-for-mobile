#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$CandidateSha,
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$StagingRoot,
    [Parameter(Mandatory)][string]$PwshPath,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][string]$InputMapPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$InputMapSha256,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$HostAcceptanceSourceSha256,
    [Parameter(Mandatory)][string]$ReportPath
)
# Read-only host evidence consumer. No launcher, Git, build, UAC or device action.
# Exit 0 means one CreateNew report was published; acceptance is a report field.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
Set-StrictMode -Version 3.0
$utf8 = [Text.UTF8Encoding]::new($false,$true)
$haCommands = @{}
$checks = [Collections.Generic.List[object]]::new()

function Assert-C1bRB {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
function Add-C1bRBCheck {
    param([string]$Id,[scriptblock]$Body)
    try { & $Body; $checks.Add([ordered]@{id=$Id;status='passed';detail=$null}) }
    catch { $checks.Add([ordered]@{id=$Id;status='failed';detail=$_.Exception.Message}) }
}
function Import-C1bRBPrivateFunctions {
    param([byte[]]$Bytes,[string[]]$Names,[string]$Label)
    Assert-C1bRB (-not ($Bytes.Length-ge3 -and $Bytes[0]-eq239 -and $Bytes[1]-eq187 -and $Bytes[2]-eq191)) 'Private source UTF-8 BOM rejected.'
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Assert-C1bRB ($errors.Count-eq0) 'Private source Parser rejected.'
    $module = Microsoft.PowerShell.Core\New-Module -Name ($Label+'-'+[guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($text))
    $functions=@{}
    foreach($name in $Names){
        $definitions=@($ast.EndBlock.Statements | Where-Object {
            $_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name
        })
        $items=@(& $module { param($Name) Microsoft.PowerShell.Management\Get-Item -LiteralPath ('Function:\'+$Name) } $name)
        Assert-C1bRB ($definitions.Count-eq1-and$items.Count-eq1-and
            $items[0].GetType()-eq[Management.Automation.FunctionInfo]-and
            [object]::ReferenceEquals($items[0].ScriptBlock.Module,$module)-and
            $items[0].ScriptBlock.Ast.Extent.Text-ceq$definitions[0].Extent.Text) 'Private FunctionInfo does not match the held source AST.'
        $functions[$name]=$items[0]
    }
    return @{module=$module;functions=$functions;source_ast=$ast}
}
function Read-C1bRBBootstrap {
    param([string]$Path,[string]$ExpectedHash)
    Assert-C1bRB ([IO.Path]::IsPathFullyQualified($Path)) 'Bootstrap path must be absolute.'
    $cursor=$Path
    while(-not[string]::IsNullOrEmpty($cursor)){
        Assert-C1bRB (([IO.File]::GetAttributes($cursor)-band[IO.FileAttributes]::ReparsePoint)-eq0) 'Bootstrap reparse path rejected.'
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        Assert-C1bRB ($stream.Length-ge1-and$stream.Length-le1048576) 'Bootstrap byte bound rejected.'
        $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
        Assert-C1bRB ($stream.ReadByte()-eq-1-and$stream.Length-eq$bytes.Length) 'Bootstrap EOF or length changed.'
        $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Assert-C1bRB ($hash-ceq$ExpectedHash) 'Bootstrap source hash mismatch.'
        return @{stream=$stream;bytes=$bytes;pin=@{path=$Path;byte_length=[long]$bytes.Length;sha256=$hash}}
    } catch {$stream.Dispose();throw}
}
function Assert-C1bRBPinEqual {
    param($Actual,$Expected,[string]$Name)
    & $haCommands['Assert-C1bHAKeys'] $Actual @('path','byte_length','sha256') $Name
    Assert-C1bRB ($Actual.path-ceq$Expected.path-and$Actual.byte_length-eq$Expected.byte_length-and$Actual.sha256-ceq$Expected.sha256) "$Name raw pin mismatch."
}
function Assert-C1bRBFields {
    param($Object,[Collections.IDictionary]$Expected,[string]$Name)
    foreach($entry in $Expected.GetEnumerator()){
        Assert-C1bRB ($null-ne$Object-and$Object.Contains($entry.Key)) "$Name missing $($entry.Key)."
        $actual=$Object[$entry.Key];$wanted=$entry.Value
        if($null-eq$wanted){Assert-C1bRB ($null-eq$actual) "$Name.$($entry.Key) must be null."}
        elseif($wanted-is[bool]){Assert-C1bRB ($actual-is[bool]-and$actual-eq$wanted) "$Name.$($entry.Key) bool mismatch."}
        elseif($wanted-is[int]-or$wanted-is[long]){Assert-C1bRB (($actual-is[int]-or$actual-is[long])-and$actual-eq$wanted) "$Name.$($entry.Key) integer mismatch."}
        else{Assert-C1bRB ($actual-is[string]-and$actual-ceq$wanted) "$Name.$($entry.Key) literal mismatch."}
    }
}
function Assert-C1bRBTransport {
    param($Session,$Map,[string]$Candidate)
    $capture=& $haCommands['Assert-C1bHACapture'] $Session $Map.launcher_capture_pin
    & $haCommands['Assert-C1bHARoot'] $Session $Map.root_observation_pin $Map.launcher_capture_pin $capture $Candidate 'BuildOnly' $Map.run_id $capture.child_pid
    Assert-C1bRB ($capture.stdout.total_byte_length-eq0) 'Actual r11 launcher stdout must be empty.'
    $driver=& $haCommands['Assert-C1bHACapture'] $Session $Map.driver_capture_pin
    & $haCommands['Assert-C1bHARoot'] $Session $Map.driver_root_observation_pin $Map.driver_capture_pin $driver $Candidate 'BuildOnlyDriver' $Map.run_id $driver.child_pid
    Assert-C1bRB ($driver.child_pid-ne$capture.child_pid) 'Driver PID cannot substitute for launcher PID.'
    return @{launcher=$capture;driver=$driver}
}
function Assert-C1bRBElevation {
    param($Map,$Transport,$Value)
    & $haCommands['Assert-C1bHAKeys'] $Value @('schema','candidate_sha','status','run_id','nonce','invocation_count','automatic_retry_count','elevated_pid','driver_pid','token_elevated','launcher_capture_pin','launcher_source_pin','wrapper_source_pin','expected_launcher_sha256','argument_list','argument_list_sha256','native_exit_code','elevated_native_exit_code') 'elevation result'
    Assert-C1bRBFields $Value ([ordered]@{schema='c1b-build-only-elevation-result/v1';candidate_sha=$Map.candidate_sha;status='passed';run_id=$Map.run_id;nonce=$Map.nonce;invocation_count=1L;automatic_retry_count=0L;token_elevated=$true;expected_launcher_sha256=$Map.launcher_source_pin.sha256;native_exit_code=0L;elevated_native_exit_code=0L}) 'elevation'
    & $haCommands['Assert-C1bHAInt'] $Value.elevated_pid 1 2147483647 'elevated PID'
    & $haCommands['Assert-C1bHAInt'] $Value.driver_pid 1 2147483647 'driver PID'
    Assert-C1bRB ($Value.driver_pid-eq$Transport.driver.child_pid-and
        $Value.elevated_pid-ne$Value.driver_pid-and$Value.elevated_pid-ne$Transport.launcher.child_pid) 'Elevation/driver/launcher PID scopes mismatched.'
    Assert-C1bRBPinEqual $Value.launcher_capture_pin $Map.launcher_capture_pin 'elevation launcher capture'
    Assert-C1bRBPinEqual $Value.launcher_source_pin $Map.launcher_source_pin 'elevation launcher source'
    Assert-C1bRBPinEqual $Value.wrapper_source_pin $Map.wrapper_source_pin 'elevation wrapper source'
    $expected=[string[]]@('-NoProfile','-File',$Map.launcher_source_pin.path,'-ExpectedLauncherSha256',$Map.launcher_source_pin.sha256)
    Assert-C1bRB ($Value.argument_list-is[Array]-and$Value.argument_list.Count-eq$expected.Count) 'Elevation argv count/type mismatch.'
    for($i=0;$i-lt$expected.Count;$i++){Assert-C1bRB ($Value.argument_list[$i]-is[string]-and$Value.argument_list[$i]-ceq$expected[$i]) 'Elevation launcher argv mismatch.'}
    $argvBytes=[Text.UTF8Encoding]::new($false).GetBytes(($expected | ConvertTo-Json -Compress))
    $argvHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($argvBytes)).ToLowerInvariant()
    Assert-C1bRB ($Value.argument_list_sha256-ceq$argvHash) 'Elevation launcher argv hash mismatch.'
}
function Assert-C1bRBFailureAbsent {
    param($Session,[string]$Path,[string]$ExpectedParent)
    $canonical=& $haCommands['Get-C1bHAPath'] $Path
    Assert-C1bRB ([IO.Path]::GetDirectoryName($canonical)-ceq$ExpectedParent) 'Failure sidecar escaped staging parent.'
    & $haCommands['Assert-C1bHAAbsentFile'] $Session $canonical
}
function Get-C1bRBLiteral {
    param([string]$Source,[string]$Name)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    Assert-C1bRB ($errors.Count-eq0) 'Source binding Parser rejected.'
    $assignments=@($ast.EndBlock.Statements|Where-Object{
        $_-is[Management.Automation.Language.AssignmentStatementAst]-and
        $_.Left-is[Management.Automation.Language.VariableExpressionAst]-and
        $_.Left.VariablePath.UserPath-ceq$Name
    })
    Assert-C1bRB ($assignments.Count-eq1-and
        $assignments[0].Right-is[Management.Automation.Language.CommandExpressionAst]-and
        $assignments[0].Right.Expression-is[Management.Automation.Language.StringConstantExpressionAst]) 'Source binding must be one top-level string literal.'
    return [string]$assignments[0].Right.Expression.Value
}
function Assert-C1bRBHelperEnvelope {
    param($Capture,$Helper)
    $texts=@($Capture.started_at_utc,$Capture.completed_at_utc,$Helper.process_started_not_before_utc,$Helper.process_exited_not_after_utc)
    foreach($text in $texts){
        Assert-C1bRB ($text-is[string]-and$text-cmatch'\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}(Z|\+00:00)\z') 'Process envelope timestamp is not canonical UTC.'
    }
    $times=@($texts|ForEach-Object{[DateTimeOffset]::Parse($_,[Globalization.CultureInfo]::InvariantCulture)})
    Assert-C1bRB ($times[0]-le$times[2]-and$times[2]-le$times[3]-and$times[3]-le$times[1]) 'Helper envelope is outside the actual launcher capture lifetime.'
}

$session=$null;$bootstrap=$null;$privateVerifier=$null;$outputSession=$null
$primary=$null;$cleanupFailures=[Collections.Generic.List[string]]::new()
$strictPass=$false;$transport=$null;$map=$null;$observedResults=@{};$inputs=@{}
$readerPinHash=$null
$observedUtc=[DateTimeOffset]::UtcNow.ToString('o')
try {
    Assert-C1bRB ($PSVersionTable.PSVersion.ToString()-ceq'7.6.5'-and[Environment]::ProcessPath-ieq$PwshPath) 'Reader must run in the pinned PowerShell 7.6.5 path.'
    foreach($path in @($RepoRoot,$StagingRoot,$PwshPath,$EvidenceRoot,$InputMapPath,$ReportPath)){
        Assert-C1bRB ([IO.Path]::IsPathFullyQualified($path)) 'Reader runtime paths must be absolute.'
    }
    $authorityPath=[IO.Path]::Combine($RepoRoot,'scripts','lib','c1b-host-acceptance.ps1')
    $bootstrap=Read-C1bRBBootstrap $authorityPath $HostAcceptanceSourceSha256
    $haNames=@('Assert-C1bHAKeys','Assert-C1bHAInt','Assert-C1bHABool','Assert-C1bHAString','ConvertFrom-C1bHAStrictJson','Get-C1bHAPath','New-C1bHASession','Read-C1bHAFile','Read-C1bHAJson','Close-C1bHASession','Assert-C1bHACapture','Assert-C1bHARoot','Get-C1bHAImplementationMap','Get-C1bHAObservedPin','Open-C1bHADirectories','Assert-C1bHAAbsentFile')
    $privateAuthority=Import-C1bRBPrivateFunctions $bootstrap.bytes $haNames 'C1bReadbackAuthority'
    $haCommands=$privateAuthority.functions
    $RepoRoot=& $haCommands['Get-C1bHAPath'] $RepoRoot
    $StagingRoot=& $haCommands['Get-C1bHAPath'] $StagingRoot
    $EvidenceRoot=& $haCommands['Get-C1bHAPath'] $EvidenceRoot
    $InputMapPath=& $haCommands['Get-C1bHAPath'] $InputMapPath
    $ReportPath=& $haCommands['Get-C1bHAPath'] $ReportPath
    Assert-C1bRB ([IO.Path]::GetDirectoryName($ReportPath)-ceq$EvidenceRoot) 'Report must be a direct evidence-root child.'
    Assert-C1bRB ([IO.Path]::GetDirectoryName($InputMapPath)-ceq$EvidenceRoot) 'Input map must be a direct evidence-root child.'
    $session=& $haCommands['New-C1bHASession'] @($RepoRoot,$StagingRoot,$EvidenceRoot,[IO.Path]::GetDirectoryName($PwshPath))
    $bootstrapHeld=& $haCommands['Read-C1bHAFile'] $session $bootstrap.pin
    $identity=[C1bHostAcceptanceNativeV1]::Identity($bootstrap.stream.SafeFileHandle)
    Assert-C1bRB ($identity.Id-ceq$session.files[$authorityPath].identity.Id-and
        [C1bHostAcceptanceNativeV1]::FinalPath($bootstrap.stream.SafeFileHandle)-ceq$authorityPath) 'Bootstrap native held identity differs from the loaded bytes.'
    $mapPin=@{path=$InputMapPath;byte_length=[long]([IO.FileInfo]::new($InputMapPath)).Length;sha256=$InputMapSha256}
    $map=& $haCommands['Read-C1bHAJson'] $session $mapPin
    $mapKeys=@('schema','candidate_sha','repo_root','staging_root','evidence_root','trusted_source_roots','run_id','nonce','runtime_pin','host_acceptance_source_pin','reader_source_pin','wrapper_source_pin','launcher_source_pin','helper_source_pin','verifier_source_pin','implementation_map_pin','repository_input_pins','launcher_capture_pin','root_observation_pin','driver_capture_pin','driver_root_observation_pin','elevation_result_pin','launcher_pin','summary_pin','log_pin','failure_sidecar_path')
    & $haCommands['Assert-C1bHAKeys'] $map $mapKeys 'BuildOnly reader input map'
    Assert-C1bRBFields $map ([ordered]@{schema='c1b-build-only-readback-inputs/v1';candidate_sha=$CandidateSha;repo_root=$RepoRoot;staging_root=$StagingRoot;evidence_root=$EvidenceRoot}) 'reader input'
    & $haCommands['Assert-C1bHAString'] $map.run_id '\A[A-Za-z0-9][A-Za-z0-9._-]{0,95}\z' 'run ID'
    & $haCommands['Assert-C1bHAString'] $map.nonce '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z' 'nonce'
    Assert-C1bRB ($map.trusted_source_roots-is[Array]) 'Trusted source roots must be an explicit array.'
    foreach($root in $map.trusted_source_roots){
        $sourceRoot=& $haCommands['Get-C1bHAPath'] $root
        Assert-C1bRB (@($session.roots | Where-Object {$_-ceq$sourceRoot}).Count-eq1) 'Reader source roots must be the explicit repo/staging/evidence/runtime roots.'
    }
    Assert-C1bRBPinEqual $map.host_acceptance_source_pin $bootstrap.pin 'host authority source'
    Assert-C1bRB ($map.runtime_pin.path-ceq$PwshPath-and$map.runtime_pin.sha256-ceq'362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139') 'Runtime path/hash binding mismatch.'
    Assert-C1bRB ($map.reader_source_pin.path-ceq$PSCommandPath-and
        $map.reader_source_pin.path-ceq[IO.Path]::Combine($RepoRoot,'scripts','read-c1b-build-only-host.ps1')) 'Reader source path binding mismatch.'
    Assert-C1bRB ($map.wrapper_source_pin.path-ceq[IO.Path]::Combine($RepoRoot,'scripts','invoke-c1b-build-only-elevated.ps1')) 'BuildOnly wrapper source path binding mismatch.'
    foreach($name in @('runtime_pin','reader_source_pin','wrapper_source_pin','launcher_source_pin','helper_source_pin','verifier_source_pin','implementation_map_pin','launcher_pin','summary_pin','log_pin')){
        $null=& $haCommands['Read-C1bHAFile'] $session $map[$name]
    }
    $readerPinHash=$map.reader_source_pin.sha256
    $short=$CandidateSha.Substring(0,7)
    foreach($binding in @(
        @('launcher_source_pin',[IO.Path]::Combine($StagingRoot,"launcher-$short-r11.ps1")),
        @('helper_source_pin',[IO.Path]::Combine($StagingRoot,"helper-$short-r11.ps1")),
        @('verifier_source_pin',[IO.Path]::Combine($RepoRoot,'scripts','lib','tablet-layout-c1b-real-build-smoke-verifier.ps1')),
        @('implementation_map_pin',[IO.Path]::Combine($RepoRoot,'scripts','lib','tablet-layout-c1b.ps1')),
        @('launcher_pin',[IO.Path]::Combine($RepoRoot,'.checks',"tablet-c1b-real-build-smoke-$short.launcher.json")),
        @('summary_pin',[IO.Path]::Combine($RepoRoot,'.checks',"tablet-c1b-real-build-smoke-$short.summary.json")),
        @('log_pin',[IO.Path]::Combine($RepoRoot,'.checks',"tablet-c1b-real-build-smoke-$short.log")))){
        Assert-C1bRB ($map[$binding[0]].path-ceq$binding[1]) 'BuildOnly source/output path binding mismatch.'
    }
    Assert-C1bRB ($map.failure_sidecar_path-ceq[IO.Path]::Combine($StagingRoot,"launcher-$short-r11.failure.json")) 'Failure sidecar exact path mismatch.'
    $launcherSource=$utf8.GetString((& $haCommands['Read-C1bHAFile'] $session $map.launcher_source_pin))
    foreach($entry in ([ordered]@{expectedCommitSha=$CandidateSha;expectedCommitShort=$short;repoRoot=$RepoRoot;failureSidecarPath=$map.failure_sidecar_path;helperPath=$map.helper_source_pin.path;expectedHelperSha256=$map.helper_source_pin.sha256;expectedVerifierSha256=$map.verifier_source_pin.sha256;pwshPath=$PwshPath;expectedPwshSha256=$map.runtime_pin.sha256}).GetEnumerator()){
        Assert-C1bRB ((Get-C1bRBLiteral $launcherSource $entry.Key)-ceq$entry.Value) 'Launcher literal source binding mismatch.'
    }
    Assert-C1bRB ((Get-C1bRBLiteral $utf8.GetString((& $haCommands['Read-C1bHAFile'] $session $map.helper_source_pin)) 'expectedSha')-ceq$CandidateSha) 'Helper source candidate literal mismatch.'
    $checks.Add([ordered]@{id='reader.inputs';status='passed';detail=$null})
    Add-C1bRBCheck 'outer.capture_root_scopes' {$script:transport=Assert-C1bRBTransport $session $map $CandidateSha}
    Add-C1bRBCheck 'elevation.independent_driver_result' {
        Assert-C1bRB ($null-ne$transport) 'Capture transport was not accepted.'
        $elevation=& $haCommands['Read-C1bHAJson'] $session $map.elevation_result_pin
        Assert-C1bRBElevation $map $transport $elevation
        $reservationPath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($map.launcher_capture_pin.path),'reservation.json')
        $reservationPin=& $haCommands['Get-C1bHAObservedPin'] $session $reservationPath
        $reservation=& $haCommands['Read-C1bHAJson'] $session $reservationPin
        & $haCommands['Assert-C1bHAKeys'] $reservation @('schema','started_at_utc','parent_pid','automatic_retry_count') 'launcher capture reservation'
        Assert-C1bRBFields $reservation ([ordered]@{schema='tl1-c1b-host-process-capture-reservation/v1';parent_pid=$elevation.elevated_pid;automatic_retry_count=0L;started_at_utc=$transport.launcher.started_at_utc}) 'launcher reservation'
        $observedResults.elevation=$elevation
    }
    Add-C1bRBCheck 'failure_sidecar.absent_after_exit' {
        Assert-C1bRB ($null-ne$transport-and$transport.launcher.root_exit_confirmed-and$transport.launcher.exit_code-eq0) 'Actual launcher native exit was not accepted.'
        Assert-C1bRBFailureAbsent $session $map.failure_sidecar_path $StagingRoot
    }
    $verifierBytes=& $haCommands['Read-C1bHAFile'] $session $map.verifier_source_pin
    $privateVerifier=Import-C1bRBPrivateFunctions $verifierBytes @('ConvertFrom-TL1C1bRealBuildSmokeSummaryJson','Assert-TL1C1bRealBuildSmokeSummaryExactProperties','Assert-TL1C1bRealBuildSmokeSummaryFile') 'C1bReadbackVerifier'
    $summaryBytes=& $haCommands['Read-C1bHAFile'] $session $map.summary_pin
    $summary=& $privateVerifier.functions['ConvertFrom-TL1C1bRealBuildSmokeSummaryJson'] -Raw $utf8.GetString($summaryBytes)
    $launcher=& $haCommands['Read-C1bHAJson'] $session $map.launcher_pin
    $log=& $haCommands['Read-C1bHAJson'] $session $map.log_pin
    $observedResults.launcher=$launcher;$observedResults.log=$log;$observedResults.summary=$summary
    Add-C1bRBCheck 'launcher.pass_closure' {
        Assert-C1bRB ($null-ne$transport) 'Actual launcher capture was not accepted.'
        Assert-C1bRBHelperEnvelope $transport.launcher $launcher.helper
        Assert-C1bRBFields $launcher ([ordered]@{schema='tablet-layout-c1b-real-build-smoke-launcher/v3';expected_commit_sha=$CandidateSha;status='candidate_pass_requires_external_exit';success_eligible_without_external_exit=$false;external_exit_zero_required=$true;failure_sidecar_absent_after_exit_required=$true;pre_publication_pass_closure=$true;final_status_authority='external_exit_zero_and_failure_sidecar_absent_after_process_exit';failure_count=0L}) 'launcher'
        foreach($binding in @(@('self',$map.launcher_source_pin),@('helper',$map.helper_source_pin),@('verifier',$map.verifier_source_pin),@('pwsh',$map.runtime_pin))){
            Assert-C1bRBFields $launcher.bindings[$binding[0]] ([ordered]@{expected_sha256=('sha256:'+$binding[1].sha256);actual_sha256=('sha256:'+$binding[1].sha256);link_count=1L}) 'launcher source binding'
        }
        Assert-C1bRBFields $launcher.verifier ([ordered]@{load_attempt_count=1L;load_count=1L;summary_parse_attempt_count=1L;summary_parse_count=1L;invoke_attempt_count=1L;invoke_count=1L;accepted=$true;summary_status='passed';failure_summary_accepted=$false;failure_count=0L}) 'launcher verifier'
        Assert-C1bRBFields $launcher.helper ([ordered]@{start_attempt_count=1L;start_count=1L;release_after_job_assignment_count=1L;helper_gate_signal_count=1L;job_assignment_completed=$true;automatic_retry_count=0L;exit_code=0L;deadline_milliseconds=2700000L;kill_wait_milliseconds=30000L;drain_wait_milliseconds=30000L;timed_out=$false;kill_attempt_count=0L;job_termination_attempt_count=0L;root_exit_confirmed=$true;job_active_processes_zero=$true;job_validation_active_process_count=0L;job_cleanup_active_process_count=0L;helper_child_termination_validation_verified=$true;helper_child_termination_cleanup_verified=$true;termination='natural_root_exit'}) 'launcher helper'
        Assert-C1bRBFields $launcher.cleanup ([ordered]@{process_job_gate='completed';fixed_file_guards='completed';ancestor_directory_guards='completed';sensitive_buffers='completed';cleanup_failure_count=0L}) 'launcher cleanup'
        Assert-C1bRBFields $launcher.residual ([ordered]@{helper_root_process_alive=$false;helper_job_active_processes_nonzero=$false;expected_summary_present=$true;expected_log_present=$true}) 'launcher residual'
    }
    Add-C1bRBCheck 'helper.summary_and_log_raw_bindings' {
        Assert-C1bRBFields $launcher.streams ([ordered]@{capture_cap_bytes_per_stream=1048576L;drain_completed=$true}) 'helper streams'
        $empty='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]@())).ToLowerInvariant())
        Assert-C1bRBFields $launcher.streams.stderr ([ordered]@{total_byte_length=0L;captured_byte_length=0L;sha256=$empty;overflowed=$false;forced_closed=$false}) 'helper stderr'
        $stdoutBytes=[byte[]]::new($summaryBytes.Length+2);[Buffer]::BlockCopy($summaryBytes,0,$stdoutBytes,0,$summaryBytes.Length);$stdoutBytes[-2]=13;$stdoutBytes[-1]=10
        try {$stdoutHash='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stdoutBytes)).ToLowerInvariant())}
        finally {[Array]::Clear($stdoutBytes,0,$stdoutBytes.Length)}
        Assert-C1bRBFields $launcher.streams.stdout ([ordered]@{total_byte_length=([long]$summaryBytes.Length+2L);captured_byte_length=([long]$summaryBytes.Length+2L);sha256=$stdoutHash;overflowed=$false;forced_closed=$false}) 'helper stdout'
        Assert-C1bRBFields $launcher.outputs.summary ([ordered]@{path=$map.summary_pin.path;preexisting=$false;create_new_and_stdout_bound=$true;byte_length=$map.summary_pin.byte_length;sha256=('sha256:'+$map.summary_pin.sha256)}) 'summary output'
        Assert-C1bRBFields $launcher.outputs.log ([ordered]@{preexisting=$false;atomic_no_overwrite_published=$true;byte_length=$map.log_pin.byte_length;sha256=('sha256:'+$map.log_pin.sha256)}) 'log output'
        Assert-C1bRBFields $log ([ordered]@{schema='tablet-layout-c1b-real-build-smoke-launcher-log/v2';expected_commit_sha=$CandidateSha}) 'launcher log'
        foreach($name in @('stdout','stderr')){
            foreach($field in @('total_byte_length','captured_byte_length','sha256','overflowed','forced_closed')){
                Assert-C1bRB ($log.streams[$name][$field]-ceq$launcher.streams[$name][$field]) 'Log/helper stream binding mismatch.'
            }
        }
        foreach($field in @('byte_length','sha256')){Assert-C1bRB ($log.summary[$field]-ceq$launcher.outputs.summary[$field]) 'Log summary raw binding mismatch.'}
    }
    Add-C1bRBCheck 'repository.final_42_raw_inputs' {
        $implementation=& $haCommands['Get-C1bHAImplementationMap'] $utf8.GetString((& $haCommands['Read-C1bHAFile'] $session $map.implementation_map_pin))
        Assert-C1bRB ($map.repository_input_pins-is[Array]-and$map.repository_input_pins.Count-eq42) 'Final repository requires 42 raw pins.'
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $catalog=[Collections.Generic.List[string]]::new()
        foreach($entry in $map.repository_input_pins){
            & $haCommands['Assert-C1bHAKeys'] $entry @('key','pin') 'repository input'
            Assert-C1bRB ($implementation.ContainsKey($entry.key)-and$seen.Add($entry.key)) 'Unknown or duplicate repository key.'
            $expectedPath=[IO.Path]::Combine($RepoRoot,$implementation[$entry.key].Replace('/','\'))
            Assert-C1bRB ($entry.pin.path-ceq$expectedPath) 'Final repository pin is outside its literal implementation map.'
            $null=& $haCommands['Read-C1bHAFile'] $session $entry.pin
            $catalog.Add($implementation[$entry.key]+'=sha256:'+$entry.pin.sha256)
        }
        $lines=$catalog.ToArray();[Array]::Sort($lines,[StringComparer]::Ordinal)
        $catalogHash='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes(($lines-join"`n")))).ToLowerInvariant())
        Assert-C1bRB ($summary.repository_input_catalog_sha256-ceq$catalogHash) 'Summary repository catalog does not match final raw inputs.'
    }
    Add-C1bRBCheck 'summary.private_function_public_verification' {
        & $privateVerifier.functions['Assert-TL1C1bRealBuildSmokeSummaryExactProperties'] -Value $summary
        $strict=& $privateVerifier.functions['Assert-TL1C1bRealBuildSmokeSummaryFile'] -Path $map.summary_pin.path -ExpectedParentDirectory ([IO.Path]::Combine($RepoRoot,'.checks')) -ExpectedCommitSha $CandidateSha -ExpectedHelperSha256 $map.helper_source_pin.sha256 -HelperProcessStartedNotBeforeUtc ([DateTimeOffset]::Parse($launcher.helper.process_started_not_before_utc)) -HelperProcessExitedNotAfterUtc ([DateTimeOffset]::Parse($launcher.helper.process_exited_not_after_utc)) -MaximumObserverTailSeconds 5.0
        Assert-C1bRB ($strict.ByteLength-eq$map.summary_pin.byte_length-and$strict.Sha256-ceq('sha256:'+$map.summary_pin.sha256)) 'Independent public verifier raw summary binding mismatch.'
        $script:strictPass=$true
    }
    Add-C1bRBCheck 'namespace.residual_absence' {
        & $haCommands['Open-C1bHADirectories'] $session ([IO.Path]::Combine($RepoRoot,'app','tablet-c1b-probe'))
        foreach($relative in @('app\tablet-c1b-probe\build','app\tablet-c1b-probe\.gradle','app\tablet-c1b-probe\local.properties')){
            $residual=[IO.Path]::Combine($RepoRoot,$relative)
            & $haCommands['Assert-C1bHAAbsentFile'] $session $residual
        }
    }
} catch {
    $primary=$_.Exception.Message
    $checks.Add([ordered]@{id='reader.primary';status='failed';detail=$primary})
} finally {
    if($null-ne$session){
        foreach($entry in $session.files.GetEnumerator()){$inputs[$entry.Key]=$entry.Value.pin}
        try {
            # Independent complete ancestor chains survive the input-session release.
            # Absence claims are checked again through final report publication.
            $outputSession=& $haCommands['New-C1bHASession'] @($EvidenceRoot,$StagingRoot,$RepoRoot)
            foreach($path in $session.absences){& $haCommands['Assert-C1bHAAbsentFile'] $outputSession $path}
        }catch{$cleanupFailures.Add('output parent: '+$_.Exception.Message)}
        try {& $haCommands['Close-C1bHASession'] $session}catch{$cleanupFailures.Add($_.Exception.Message)}
    }
    if($null-ne$bootstrap){
        try {[Array]::Clear($bootstrap.bytes,0,$bootstrap.bytes.Length);$bootstrap.stream.Dispose()}
        catch {$cleanupFailures.Add('bootstrap: '+$_.Exception.Message)}
    }
}
$checks.Add([ordered]@{id='reader.cleanup';status=$(if($cleanupFailures.Count-eq0){'passed'}else{'failed'});detail=@($cleanupFailures)})
$requiredChecks=@('reader.inputs','outer.capture_root_scopes','elevation.independent_driver_result','failure_sidecar.absent_after_exit','launcher.pass_closure','helper.summary_and_log_raw_bindings','repository.final_42_raw_inputs','summary.private_function_public_verification','namespace.residual_absence','reader.cleanup')
$allRequired=($checks.Count-eq$requiredChecks.Count)
foreach($id in $requiredChecks){if(@($checks|Where-Object{$_.id-ceq$id-and$_.status-ceq'passed'}).Count-ne1){$allRequired=$false}}
$accepted=($null-eq$primary-and$strictPass-and$cleanupFailures.Count-eq0-and$allRequired)
$report=[ordered]@{
    schema='c1b-build-only-independent-readback/v1';observed_utc=$observedUtc;completed_utc=[DateTimeOffset]::UtcNow.ToString('o')
    candidate_sha=$CandidateSha;reader_process_id=$PID;reader_sha256=$readerPinHash
    observed_outer_exit=$(if($null-ne$transport){$transport.launcher.exit_code}else{$null})
    acceptance_status=$(if($accepted){'accepted_no_device'}elseif($null-ne$primary-or$cleanupFailures.Count){'reader_failed'}else{'not_accepted_or_incomplete'})
    strict_pass_summary_independently_verified=$strictPass;readback_completed=($null-eq$primary-and$cleanupFailures.Count-eq0)
    primary_failure=$primary;cleanup_failure_count=$cleanupFailures.Count;cleanup_failures=@($cleanupFailures)
    inputs=$inputs;observed_results=$observedResults;checks=@($checks)
    limitations=@('Captures observe their own contained Job scopes; RunAs driver, elevated wrapper, launcher and helper identities are separate.','Default ADB and process observer evidence remains boundary snapshots and host-wide best-effort WMI.','This report performs no device operation and creates no Ready contract.','Reader native exit, including final publication guards and namespace rechecks, is independently observed by its caller after this report is published.')
}
$reportBytes=$utf8.GetBytes(($report|ConvertTo-Json -Depth 40)+"`n")
Assert-C1bRB ($null-ne$outputSession) 'No held output ancestor chain; report publication rejected.'
$output=$null
try {
    $outputParent=$outputSession.directories[$EvidenceRoot].handle
    $parentIdentity=[C1bHostAcceptanceNativeV1]::Identity($outputParent)
    Assert-C1bRB (($parentIdentity.Attributes-band0x410)-eq0x10-and[C1bHostAcceptanceNativeV1]::FinalPath($outputParent)-ceq$EvidenceRoot) 'Report output parent reparse/final path rejected.'
    $output=[IO.File]::Open($ReportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $identity=[C1bHostAcceptanceNativeV1]::Identity($output.SafeFileHandle)
    Assert-C1bRB (($identity.Attributes-band0x410)-eq0-and$identity.Links-eq1-and[C1bHostAcceptanceNativeV1]::FinalPath($output.SafeFileHandle)-ceq$ReportPath) 'New report output native identity rejected.'
    $output.Write($reportBytes);$output.Flush($true)
    $output.Dispose();$output=$null
    $publishedPin=@{path=$ReportPath;byte_length=[long]$reportBytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant()}
    $null=& $haCommands['Read-C1bHAFile'] $outputSession $publishedPin
} finally {
    try {if($null-ne$output){$output.Dispose()}}
    finally {& $haCommands['Close-C1bHASession'] $outputSession}
}
$reportHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($reportBytes)).ToLowerInvariant()
[ordered]@{report_path=$ReportPath;report_sha256=$reportHash;acceptance_status=$report.acceptance_status;readback_completed=$report.readback_completed}|ConvertTo-Json -Compress
exit 0
