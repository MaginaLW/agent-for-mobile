#Requires -Version 7.6
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
if(-not$IsWindows){throw 'Windows native admission tests required.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$wrapperPath=Join-Path $repo 'scripts/invoke-c1b-build-only-elevated.ps1'
$libraryPath=Join-Path $repo 'scripts/lib/c1b-host-acceptance.ps1'
$pwsh=[Environment]::ProcessPath
if($PSVersionTable.PSVersion.ToString()-cne'7.6.5'){throw 'Pinned PowerShell 7.6.5 required.'}
$testRoot=Join-Path $repo ('.checks/goal-20260930/elevation-test/cases-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$sourceBytes=[IO.File]::ReadAllBytes($wrapperPath);$sourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes)).ToLowerInvariant()
$wrapperSnapshot=Join-Path $testRoot 'wrapper-source-snapshot.ps1';[IO.File]::WriteAllBytes($wrapperSnapshot,$sourceBytes)
$libraryBytes=[IO.File]::ReadAllBytes($libraryPath);$librarySha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($libraryBytes)).ToLowerInvariant()
$librarySnapshot=Join-Path $testRoot 'acceptance-source-snapshot.ps1';[IO.File]::WriteAllBytes($librarySnapshot,$libraryBytes)
$source=[Text.UTF8Encoding]::new($false,$true).GetString($sourceBytes)
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Wrapper parser errors.'}
. ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($libraryBytes)))
$utf8=[Text.UTF8Encoding]::new($false,$true)
foreach($name in @('ConvertTo-C1bBOArgument','Write-C1bBONewJson','Assert-C1bBOLauncherConstants')){
    $matches=@($ast.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$name},$true))
    if($matches.Count-ne1){throw 'Wrapper function extraction is not unique.'}
    . ([scriptblock]::Create($matches[0].Extent.Text))
}
$main=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.TryStatementAst]})
if($main.Count-ne1){throw 'Wrapper main try extraction is not unique.'}
$main=$main[0]
$operationBranch=@($main.Body.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and
    $_.Clauses[0].Item1.Extent.Text.Contains("`$Operation-ceq'Probe'")})
if($operationBranch.Count-ne1){throw 'Wrapper operation branches not unique.'}
$operationBranch=$operationBranch[0]
$driveBody=$operationBranch.Clauses[1].Item2;$elevatedBody=$operationBranch.ElseClause
function Slice-Statements($Statements,[string]$First,[string]$Stop){
    $begin=-1;$end=-1
    for($i=0;$i-lt$Statements.Count;$i++){
        if($Statements[$i].Extent.Text.StartsWith($First,[StringComparison]::Ordinal)){$begin=$i}
        if($begin-ge0-and$Statements[$i].Extent.Text.StartsWith($Stop,[StringComparison]::Ordinal)){$end=$i;break}
    }
    if($begin-lt0-or$end-lt$begin){throw 'Safe AST slice boundary missing.'}
    return [scriptblock]::Create(($Statements[$begin..($end-1)]|ForEach-Object{$_.Extent.Text})-join"`n")
}
$authorizationChecks=Slice-Statements $main.Body.Statements 'Assert-C1bHAKeys $authorization ' '$preflight='
$sharedMarkerChecks=Slice-Statements $main.Body.Statements '$marker=' '$arguments='
$driveMarker=Slice-Statements $driveBody.Statements 'Assert-C1bHAAbsentFile $session $marker' '$outputPath='
$elevatedMarkerSlice=Slice-Statements $elevatedBody.Statements '$elevatedMarker=' 'foreach($path '
$reservationChecks=Slice-Statements $elevatedBody.Statements 'Assert-C1bHAKeys $reservation ' '$reserved='
$wrapperChecks=Slice-Statements $driveBody.Statements 'Assert-C1bHAKeys $wrapper ' '$launcherCapture='
$failureBranch=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.IfStatementAst]-and
    $_.Clauses[0].Item1.Extent.Text.Contains('$cleanupFailures.Count')})
if($failureBranch.Count-ne1){throw 'Cleanup/native failure branch missing.'}
$finallySource=$main.Finally.Extent.Text;$failureSource=$failureBranch[0].Extent.Text
$passed=0;$failed=0;$assertions=0;$admissionChildren=0;$syntheticChildren=0
function Check([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Reject([scriptblock]$Body,[string]$Pattern='.'){
    $message=$null;try{&$Body}catch{$message=$_.Exception.Message}
    Check ($null-ne$message-and$message-cmatch$Pattern) 'Expected fail-closed rejection missing or wrong reason.'
}
function Copy-Map($Value){return ConvertFrom-C1bHAStrictJson ($Value|ConvertTo-Json -Depth 30 -Compress)}
function New-Pin([string]$Path){$bytes=[IO.File]::ReadAllBytes($Path);return @{path=$Path;byte_length=[long]$bytes.Length;sha256=Get-C1bHASha256 $bytes}}
function New-Directory([string]$Name){$path=Join-Path $testRoot $Name;[void](New-Item -ItemType Directory -Path $path);return $path}
function Literal([string]$Value){return "'"+$Value.Replace("'","''")+"'"}
$null=Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class C1bElevationQuoteTestV1 {
  [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr CommandLineToArgvW(string value, out int count);
  [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
  public static string[] Parse(string value) {
    int count; IntPtr p=CommandLineToArgvW(value,out count);
    if(p==IntPtr.Zero)throw new InvalidOperationException("CommandLineToArgvW failed.");
    try { var a=new string[count];for(int i=0;i<count;i++)a[i]=Marshal.PtrToStringUni(Marshal.ReadIntPtr(p,i*IntPtr.Size));return a; }
    finally {LocalFree(p);}
  }
}
'@

Test-Case windows_quote_roundtrip_and_nul_rejection {
    $values=@('', 'simple', 'space value', '中文 参数', '\', '\\', 'trailing\', 'a"b', '\"', 'one\"two\\', '$() ` ; literal', "line`nbreak")
    $command='program.exe '+(($values|ForEach-Object{ConvertTo-C1bBOArgument $_})-join' ')
    $parsed=[C1bElevationQuoteTestV1]::Parse($command)
    Check ($parsed.Count-eq$values.Count+1) 'Windows argument count drift.'
    for($i=0;$i-lt$values.Count;$i++){Check ([StringComparer]::Ordinal.Equals($parsed[$i+1],$values[$i])) 'Windows quoted argument differs.'}
    Reject {ConvertTo-C1bBOArgument ('a'+[char]0+'b')} 'Invalid RunAs argument'
}
Test-Case launcher_authority_literals_and_ast_counterexamples {
    $binding=@{candidate_sha=('a'*40);repo_root=(Join-Path $testRoot 'clone');failure_sidecar_path=(Join-Path $testRoot 'failure.json')}
    $launcher="`$expectedCommitSha="+(Literal $binding.candidate_sha)+"`n`$repoRoot="+(Literal $binding.repo_root)+"`n`$failureSidecarPath="+(Literal $binding.failure_sidecar_path)
    Assert-C1bBOLauncherConstants $launcher $binding;Check $true 'Literal baseline rejected.'
    foreach($candidate in @(
        ($launcher+"`n`$repoRoot="+(Literal $binding.repo_root)),
        $launcher.Replace((Literal $binding.candidate_sha),"('a'*40)"),
        $launcher.Replace('$expectedCommitSha=','$ExpectedCommitSha='),
        ('if($true){'+$launcher+'}'),
        $launcher.Replace((Literal $binding.repo_root),(Literal (Join-Path $testRoot 'other')))
    )){Reject {Assert-C1bBOLauncherConstants $candidate $binding} 'Launcher literal authority mismatch'}
    Reject {Assert-C1bBOLauncherConstants ($launcher+"`n'") $binding} 'Launcher parser errors'
}
Test-Case actual_authorization_admission_is_closed_and_exact {
    $binding=@{candidate_sha=('a'*40);launcher_source_pin=@{sha256=('b'*64)};runtime=@{pin=@{sha256=('c'*64)}}}
    $valid=@{schema='c1b-goal-build-only-authorization/v1';candidate_sha=$binding.candidate_sha;launcher_sha256=$binding.launcher_source_pin.sha256
        runtime_sha256=$binding.runtime.pin.sha256;source='direct_user_instruction_in_current_chat'
        user_instruction='设立goal，授权充分的权限和批准，完成这些待办任务，多调用sub-agent。';invocation_count=[long]1;automatic_retry_count=[long]0
        scope='one_elevated_host_build_only_then_readback_and_sealing'}
    $authorization=Copy-Map $valid;. $authorizationChecks;Check $true 'Valid authorization was rejected.'
    foreach($mutation in @('extra','missing','candidate','launcher','runtime','source','instruction','scope','invocation','retry','boolean')){
        $authorization=Copy-Map $valid
        switch($mutation){
            extra{$authorization.extra=$true};missing{$authorization.Remove('scope')};candidate{$authorization.candidate_sha='d'*40}
            launcher{$authorization.launcher_sha256='d'*64};runtime{$authorization.runtime_sha256='d'*64};source{$authorization.source='old_report'}
            instruction{$authorization.user_instruction='continue'};scope{$authorization.scope='device_and_build'};invocation{$authorization.invocation_count=[long]2}
            retry{$authorization.automatic_retry_count=[long]1};boolean{$authorization.invocation_count=$true}
        }
        Reject {. $authorizationChecks}
    }
    Reject {ConvertFrom-C1bHAStrictJson '{"invocation_count":1,"invocation_count":1}'} 'Duplicate JSON key'
    Reject {ConvertFrom-C1bHAStrictJson '{"invocation_count":1.0}'} 'Noncanonical or noninteger'
}
Test-Case actual_driver_wrapper_admission_checks_all_authority {
    $launcherPin=@{path=(Join-Path $testRoot 'launcher.ps1');byte_length=[long]123;sha256=('b'*64)}
    $binding=@{candidate_sha=('a'*40);nonce='11111111-1111-1111-1111-111111111111';run_id='synthetic-wrapper';launcher_source_pin=$launcherPin}
    $arguments=[string[]]@('-NoProfile','-File',$launcherPin.path,'-ExpectedLauncherSha256',$launcherPin.sha256)
    $argvHash=Get-C1bHASha256 ($utf8.GetBytes((ConvertTo-Json -InputObject $arguments -Compress)))
    $elevatedPid=123;$elevatedExit=0
    $valid=@{schema='c1b-build-only-elevated-wrapper-result/v1';candidate_sha=$binding.candidate_sha;status='passed';run_id=$binding.run_id
        nonce=$binding.nonce;driver_pid=[long]$PID;elevated_pid=[long]$elevatedPid;token_elevated=$true;launcher_capture_pin=@{}
        launcher_root_observation_pin=@{};launcher_source_pin=$launcherPin;expected_launcher_sha256=$launcherPin.sha256
        argument_list=$arguments;argument_list_sha256=$argvHash;native_exit_code=[long]0;invocation_count=[long]1;automatic_retry_count=[long]0;cleanup_failure_count=[long]0}
    $wrapper=Copy-Map $valid;. $wrapperChecks;Check $true 'Valid synthetic wrapper admission rejected.'
    $acceptedMutations=[Collections.Generic.List[string]]::new()
    foreach($mutation in @('extra','missing','candidate','nonce','driver','elevated','driver-string','elevated-string','token','invocation','retry','cleanup','exit','pin-extra','pin-hash','pin-length','pin-length-string','expected-hash','argv','argv-hash')){
        $wrapper=Copy-Map $valid
        switch($mutation){
            extra{$wrapper.extra=$true};missing{$wrapper.Remove('nonce')};candidate{$wrapper.candidate_sha='c'*40};nonce{$wrapper.nonce='22222222-2222-2222-2222-222222222222'}
            driver{$wrapper.driver_pid=[long]$PID+1};elevated{$wrapper.elevated_pid=[long]$elevatedPid+1};'driver-string'{$wrapper.driver_pid=[string]$PID};'elevated-string'{$wrapper.elevated_pid=[string]$elevatedPid}
            token{$wrapper.token_elevated=$false};invocation{$wrapper.invocation_count=[long]2};retry{$wrapper.automatic_retry_count=[long]1};cleanup{$wrapper.cleanup_failure_count=[long]1};exit{$wrapper.native_exit_code=[long]1}
            'pin-extra'{$wrapper.launcher_source_pin.extra=1};'pin-hash'{$wrapper.launcher_source_pin.sha256='c'*64};'pin-length'{$wrapper.launcher_source_pin.byte_length=[long]124}
            'pin-length-string'{$wrapper.launcher_source_pin.byte_length='123'};'expected-hash'{$wrapper.expected_launcher_sha256='c'*64};argv{$wrapper.argument_list[4]='c'*64};'argv-hash'{$wrapper.argument_list_sha256='c'*64}
        }
        try{Reject {. $wrapperChecks}}catch{$acceptedMutations.Add($mutation)}
    }
    Check ($acceptedMutations.Count-eq0) ('Wrapper authority mutations accepted: '+($acceptedMutations-join', '))
}
Test-Case actual_producer_results_have_exact_eighteen_fields {
    $specs=@(
        @{body=$driveBody;keys=@('schema','candidate_sha','status','run_id','nonce','invocation_count','automatic_retry_count','elevated_pid','driver_pid','token_elevated','launcher_capture_pin','launcher_source_pin','expected_launcher_sha256','argument_list','argument_list_sha256','native_exit_code','wrapper_source_pin','elevated_native_exit_code')},
        @{body=$elevatedBody;keys=@('schema','candidate_sha','status','run_id','nonce','driver_pid','elevated_pid','token_elevated','launcher_capture_pin','launcher_root_observation_pin','launcher_source_pin','expected_launcher_sha256','argument_list','argument_list_sha256','native_exit_code','invocation_count','automatic_retry_count','cleanup_failure_count')}
    )
    foreach($spec in $specs){
        $recordAssignments=@($spec.body.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-ceq'$record'})
        Check ($recordAssignments.Count-eq1) 'Producer result assignment is not unique.'
        $maps=@($recordAssignments[0].FindAll({param($node)$node-is[Management.Automation.Language.HashtableAst]},$true))
        Check ($maps.Count-eq1-and$maps[0].KeyValuePairs.Count-eq18) 'Producer result field count is not eighteen.'
        $keys=@($maps[0].KeyValuePairs|ForEach-Object{$_.Item1.Value})
        foreach($key in $spec.keys){Check ($keys-ccontains$key) 'Producer result key is missing or drifted.'}
    }
}
Test-Case create_new_writer_collision_preserves_first_bytes {
    $directory=New-Directory writer;$path=Join-Path $directory 'result.json'
    $pin=Write-C1bBONewJson $path @{schema='synthetic-only';status='first'}
    Check ($pin.byte_length-eq(Get-Item $path).Length-and$pin.sha256-ceq(Get-C1bHASha256 ([IO.File]::ReadAllBytes($path)))) 'Writer pin is not actual bytes.'
    Reject {Write-C1bBONewJson $path @{schema='synthetic-only';status='second'}}
    Check ((New-Pin $path).sha256-ceq$pin.sha256) 'CreateNew collision replaced prior bytes.'
}
Test-Case actual_driver_marker_is_fixed_and_consumed_once {
    $directory=New-Directory drive-marker;$stage=Join-Path $directory 'stage';[void](New-Item -ItemType Directory -Path $stage)
    $binding=@{candidate_sha=('a'*40);nonce='11111111-1111-1111-1111-111111111111';run_id='synthetic-drive'
        launcher_source_pin=@{path=(Join-Path $stage 'launcher.ps1')};once_marker_path=(Join-Path $stage ('build-only-'+('a'*40)+'.once.json'))}
    $session=New-C1bHASession @($directory)
    try{
        . $sharedMarkerChecks;. $driveMarker;$before=New-Pin $binding.once_marker_path
        Check ($reserved-and$reservation.sha256-ceq$before.sha256) 'Marker was not actually reserved.'
        Reject {. $driveMarker} 'Required no-follow namespace absence'
        Check ((New-Pin $binding.once_marker_path).sha256-ceq$before.sha256) 'Second driver changed marker.'
        $binding.once_marker_path=Join-Path $stage 'other-marker.json'
        Reject {. $sharedMarkerChecks;. $driveMarker} 'Once marker must be the fixed candidate launcher sibling'
        Check (-not(Test-Path $binding.once_marker_path)) 'Alternate marker namespace created.'
    }finally{Close-C1bHASession $session}
}
Test-Case shared_admission_rejects_elevated_alternate_reservation_path {
    $directory=New-Directory shared-marker;$launcherPath=Join-Path $directory 'launcher.ps1'
    $binding=@{candidate_sha=('a'*40);nonce='11111111-1111-1111-1111-111111111111';run_id='synthetic-reservation'
        launcher_source_pin=@{path=$launcherPath};once_marker_path=(Join-Path $directory ('build-only-'+('a'*40)+'.once.json'))}
    $Operation='Elevated';$reservation=@{schema='c1b-build-only-elevation-reservation/v1';candidate_sha=$binding.candidate_sha
        nonce='11111111-1111-1111-1111-111111111111';run_id='synthetic-reservation';driver_pid=[long]123;invocation_count=[long]1;automatic_retry_count=[long]0}
    . $reservationChecks;. $sharedMarkerChecks;Check $true 'Valid reservation tuple or fixed shared marker admission rejected.'
    $markerAssignment=@($main.Body.Statements|Where-Object{$_.Extent.Text.StartsWith('$marker=',[StringComparison]::Ordinal)})
    Check ($markerAssignment.Count-eq1-and$markerAssignment[0].Extent.StartOffset-lt$operationBranch.Extent.StartOffset) 'Fixed marker gate is confined to an operation branch.'
    foreach($path in @((Join-Path $directory 'different.once.json'),(Join-Path $testRoot ('build-only-'+('a'*40)+'.once.json')))){
        $binding.once_marker_path=$path
        Reject {. $sharedMarkerChecks} 'Once marker must be the fixed candidate launcher sibling'
        Check (-not(Test-Path -LiteralPath $path)) 'Alternate elevated reservation namespace written.'
    }
}
Test-Case actual_elevated_replay_marker_is_create_new {
    $evidence=New-Directory elevated-marker;$binding=@{candidate_sha=('a'*40);nonce='11111111-1111-1111-1111-111111111111';run_id='synthetic-elevated'}
    $reservation=@{driver_pid=[long]123};$session=New-C1bHASession @($evidence)
    try{
        . $elevatedMarkerSlice;$path=Join-Path $evidence 'elevated-start.json';$before=New-Pin $path
        Reject {. $elevatedMarkerSlice} 'Required no-follow namespace absence'
        Check ((New-Pin $path).sha256-ceq$before.sha256) 'Elevated argv replay overwrote marker.'
    }finally{Close-C1bHASession $session}
}
Test-Case native_readback_rejects_hardlink_and_conflicting_pin {
    $directory=New-Directory native-file;$path=Join-Path $directory 'one.json';[IO.File]::WriteAllText($path,'{}',$utf8)
    $pin=New-Pin $path;$session=New-C1bHASession @($directory)
    try{
        $actual=Read-C1bHAFile $session $pin;Check ($actual.Length-eq2) 'Native baseline read rejected.'
        $other=Copy-Map $pin;$other.sha256='a'*64;Reject {Read-C1bHAFile $session $other} 'Conflicting pins'
    }finally{Close-C1bHASession $session}
    [void](New-Item -ItemType HardLink -Path (Join-Path $directory 'two.json') -Target $path)
    $session=New-C1bHASession @($directory)
    try{Reject {Read-C1bHAFile $session $pin} 'Raw file type/link/length rejected'}finally{Close-C1bHASession $session}
}
Test-Case native_directory_reparse_is_rejected {
    $directory=New-Directory native-directory;$target=Join-Path $directory 'target';[void](New-Item -ItemType Directory -Path $target)
    $junction=Join-Path $directory 'junction';[void](New-Item -ItemType Junction -Path $junction -Target $target)
    Reject {$unexpected=New-C1bHASession @($junction);Close-C1bHASession $unexpected} 'Directory reparse or type rejected'
}
Test-Case actual_wrapper_negative_admission_never_reaches_elevation {
    $directory=New-Directory admission;$admissionLibrary=Join-Path $directory 'acceptance-source.ps1'
    [IO.File]::WriteAllBytes($admissionLibrary,$libraryBytes);$libraryPin=New-Pin $admissionLibrary
    $bindingKeys=@($main.Body.Statements|Where-Object{$_.Extent.Text.StartsWith('Assert-C1bHAKeys $binding ',[StringComparison]::Ordinal)})
    if($bindingKeys.Count-ne1){throw 'Binding closure extraction missing.'}
    $keys=@($bindingKeys[0].FindAll({param($node)$node-is[Management.Automation.Language.ArrayExpressionAst]},$true))[0]
    $keyTokens=$null;$keyErrors=$null
    $keyValues=&([scriptblock]::Create($keys.Extent.Text))
    $base=@{};foreach($key in $keyValues){$base[$key]=$null}
    $base.schema='c1b-build-only-elevation-bindings/v1';$base.candidate_sha='4b37f344d5af988ce9b2f7610df98387a49cd2d0'
    foreach($case in @('consumed','extra','bindings-pin','bootstrap-pin','bootstrap-bom')){
        $bindings=Copy-Map $base;if($case-ceq'extra'){$bindings.extra=$true}
        $path=Join-Path $directory ($case+'.json');[IO.File]::WriteAllText($path,($bindings|ConvertTo-Json -Depth 4),$utf8)
        $mapPin=New-Pin $path;$hostPath=$admissionLibrary;$hostHash=$libraryPin.sha256;$mapHash=$mapPin.sha256
        if($case-ceq'bindings-pin'){$mapHash='0'*64}
        if($case-ceq'bootstrap-pin'){$hostHash='0'*64}
        if($case-ceq'bootstrap-bom'){
            $hostPath=Join-Path $directory 'bom-source.ps1';[IO.File]::WriteAllBytes($hostPath,[byte[]]@(239,187,191,35,32,120));$hostHash=(New-Pin $hostPath).sha256
        }
        $log=Join-Path $directory ($case+'.log')
        # Execute the same held source bytes; concurrent source edits cannot alter this negative admission.
        & $pwsh -NoProfile -File $wrapperSnapshot -Operation Probe -BindingsPath $path -ExpectedBindingsSha256 $mapHash -HostAcceptanceSourcePath $hostPath -HostAcceptanceSourceSha256 $hostHash *> $log
        $exit=$LASTEXITCODE;$script:admissionChildren++;$raw=[IO.File]::ReadAllText($log)
        $pattern=switch($case){consumed{'Consumed candidate is forbidden'};extra{'BuildOnly bindings has unknown or missing fields'};'bindings-pin'{'Bindings pin mismatch'};'bootstrap-pin'{'Acceptance bootstrap pin mismatch'};'bootstrap-bom'{'Bootstrap BOM rejected'}}
        Check ($exit-eq1-and$raw.Contains($pattern)) 'Actual admission did not stop at intended safe guard.'
        Check ($raw-cnotmatch'c1b-build-only-elevation-publication/v1') 'Negative admission published pass authority.'
    }
}
Test-Case actual_finally_cleanup_failure_preserves_primary_and_native_exit {
    $directory=New-Directory cleanup;$dataPath=Join-Path $directory 'held.json';[IO.File]::WriteAllText($dataPath,'{}',$utf8)
    $harness=Join-Path $directory 'cleanup-harness.ps1'
    $header=@'
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
'@
    $header+="`n. "+(Literal $librarySnapshot)+"`n`$directory="+(Literal $directory)+"`n`$dataPath="+(Literal $dataPath)+"`n"
    $header+=@'
$bytes=[IO.File]::ReadAllBytes($dataPath);$pin=@{path=$dataPath;byte_length=[long]$bytes.Length;sha256=Get-C1bHASha256 $bytes}
$session=New-C1bHASession @($directory);$held=Read-C1bHAFile $session $pin
$held[0]=0;$primary=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('PRIMARY-SENTINEL'),'synthetic',[Management.Automation.ErrorCategory]::NotSpecified,$null)
$cleanupFailures=[Collections.Generic.List[string]]::new();$bootstrap=$null
'@
    $header+="`n& "+$finallySource+"`n"+$failureSource+"`nthrow 'Native failure gate unexpectedly returned.'`n"
    [IO.File]::WriteAllText($harness,$header,$utf8);$log=Join-Path $directory 'cleanup.log'
    & $pwsh -NoProfile -File $harness *> $log;$exit=$LASTEXITCODE;$script:syntheticChildren++
    $raw=[IO.File]::ReadAllText($log)
    Check ($exit-eq1-and$raw.Contains('PRIMARY-SENTINEL')-and$raw.Contains('Held raw buffer changed')) 'Actual finally lost primary or native cleanup failure.'
    Check ($raw-cnotmatch'c1b-build-only-elevation-publication/v1') 'Cleanup failure published success authority.'
}
[pscustomobject][ordered]@{schema='c1b-build-only-elevation-offline/v1';passed=$passed;failed=$failed;assertions=$assertions
    wrapper_source_sha256=$sourceSha;host_acceptance_source_sha256=$librarySha;actual_negative_admission_child_count=$admissionChildren;synthetic_cleanup_child_count=$syntheticChildren
    runas_invocation_count=0;launcher_invocation_count=0;real_buildonly_invocation_count=0;real_adb_call_count=0;real_device_operation_count=0
    uac_elevation_verified=$false}|ConvertTo-Json -Compress
if($failed){exit 1}
