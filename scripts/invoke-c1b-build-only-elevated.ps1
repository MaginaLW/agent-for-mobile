#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Drive','Elevated','Probe')][string]$Operation,
    [Parameter(Mandatory)][string]$BindingsPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedBindingsSha256,
    [Parameter(Mandatory)][string]$HostAcceptanceSourcePath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$HostAcceptanceSourceSha256,
    [ValidatePattern('\A[0-9a-f]{64}\z')][string]$ReservationSha256
)

# Drive owns the RunAs process observation. Elevated owns launcher capture.
# The broker-created elevated process is not claimed to belong to Drive's Job.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
Set-StrictMode -Version 3.0
$bootstrap=$null;$session=$null;$binding=$null;$primary=$null
$cleanupFailures=[Collections.Generic.List[string]]::new()
$record=$null;$outputPath=$null;$reserved=$false
$utf8=[Text.UTF8Encoding]::new($false,$true)

function ConvertTo-C1bBOArgument([string]$Value) {
    if($null-eq$Value-or$Value.Contains([char]0)){throw 'Invalid RunAs argument.'}
    $builder=[Text.StringBuilder]::new();[void]$builder.Append('"');$slashes=0
    foreach($character in $Value.ToCharArray()){
        if($character-eq'\'){$slashes++;continue}
        if($character-eq'"'){[void]$builder.Append(('\'*(2*$slashes+1)));[void]$builder.Append('"')}
        else{[void]$builder.Append(('\'*$slashes));[void]$builder.Append($character)}
        $slashes=0
    }
    [void]$builder.Append(('\'*(2*$slashes)));[void]$builder.Append('"');return $builder.ToString()
}
function Write-C1bBONewJson([string]$Path,$Value) {
    $bytes=$utf8.GetBytes(($Value|ConvertTo-Json -Depth 40)+"`n")
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    return @{path=$Path;byte_length=[long]$bytes.Length;sha256=(Get-C1bHASha256 $bytes)}
}
function Assert-C1bBOBoundary {
    $adb=@(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop|Where-Object{$_.Name-ieq'adb.exe'})
    $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object{$_.Port-eq5037})
    Assert-C1bHA ($adb.Count-eq0-and$listeners.Count-eq0) 'Host ADB/default listener boundary is not empty.'
}
function Assert-C1bBOLauncherConstants([string]$Source,$Binding) {
    $errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
    Assert-C1bHA ($errors.Count-eq0) 'Launcher parser errors.'
    foreach($entry in @(@{name='expectedCommitSha';value=$Binding.candidate_sha},@{name='repoRoot';value=$Binding.repo_root},@{name='failureSidecarPath';value=$Binding.failure_sidecar_path})){
        $assignments=@($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left-is[Management.Automation.Language.VariableExpressionAst]-and$_.Left.VariablePath.UserPath-ceq$entry.name})
        Assert-C1bHA ($assignments.Count-eq1-and$assignments[0].Right-is[Management.Automation.Language.CommandExpressionAst]-and$assignments[0].Right.Expression-is[Management.Automation.Language.StringConstantExpressionAst]-and$assignments[0].Right.Expression.Value-ceq$entry.value) 'Launcher literal authority mismatch.'
    }
}

try {
    if(-not$IsWindows){throw 'Windows elevation and Job capture required.'}
    # Bootstrap executes only caller-pinned definition bytes. Native no-follow
    # admission below revalidates this same source before any external action.
    $bootstrap=[IO.File]::Open($HostAcceptanceSourcePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    if($bootstrap.Length-lt1-or$bootstrap.Length-gt1048576){throw 'Acceptance bootstrap bound.'}
    $sourceBytes=[byte[]]::new([int]$bootstrap.Length);$bootstrap.ReadExactly($sourceBytes)
    if($bootstrap.ReadByte()-ne-1-or[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sourceBytes)).ToLowerInvariant()-cne$HostAcceptanceSourceSha256){throw 'Acceptance bootstrap pin mismatch.'}
    if($sourceBytes.Length-ge3-and$sourceBytes[0]-eq239-and$sourceBytes[1]-eq187-and$sourceBytes[2]-eq191){throw 'Bootstrap BOM rejected.'}
    . ([scriptblock]::Create($utf8.GetString($sourceBytes)))
    [Array]::Clear($sourceBytes,0,$sourceBytes.Length)
    $session=New-C1bHASession @([IO.Path]::GetDirectoryName((Get-C1bHAPath $HostAcceptanceSourcePath)),[IO.Path]::GetDirectoryName((Get-C1bHAPath $BindingsPath)))
    $acceptancePin=Get-C1bHAObservedPin $session $HostAcceptanceSourcePath
    Assert-C1bHA ($acceptancePin.sha256-ceq$HostAcceptanceSourceSha256) 'Native acceptance bootstrap mismatch.'
    $mapPin=Get-C1bHAObservedPin $session $BindingsPath
    Assert-C1bHA ($mapPin.sha256-ceq$ExpectedBindingsSha256) 'Bindings pin mismatch.'
    $binding=Read-C1bHAJson $session $mapPin
    Assert-C1bHAKeys $binding @('schema','candidate_sha','repo_root','evidence_directory','trusted_source_roots','run_id','nonce','runtime','wrapper_source_pin','host_acceptance_source_pin','capture_source_pin','launcher_source_pin','helper_source_pin','verifier_source_pin','preflight_receipt_pin','preflight_stage_run','authorization_pin','argument_list','argument_list_sha256','failure_sidecar_path','summary_path','launcher_result_path','log_path','once_marker_path') 'BuildOnly bindings'
    Assert-C1bHA ($binding.schema-ceq'c1b-build-only-elevation-bindings/v1') 'Bindings schema.'
    Assert-C1bHAString $binding.candidate_sha '^[0-9a-f]{40}$' 'candidate SHA'
    Assert-C1bHA ($binding.candidate_sha-cne'4b37f344d5af988ce9b2f7610df98387a49cd2d0') 'Consumed candidate is forbidden.'
    Assert-C1bHAString $binding.run_id '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$' 'run ID'
    Assert-C1bHAString $binding.nonce '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' 'nonce'
    $repo=Get-C1bHAPath $binding.repo_root;$evidence=Get-C1bHAPath $binding.evidence_directory
    Assert-C1bHA ($repo-cnotmatch'(?i)(^|\\)agent-for-mobile-c1b-candidate-20260929-r3(\\|$)') 'Consumed clone path is forbidden.'
    Assert-C1bHA (-not(Test-C1bHAWithin $evidence $repo)-and-not(Test-C1bHAWithin $repo $evidence)) 'Evidence/clone overlap.'
    foreach($root in @($binding.trusted_source_roots)+@($repo,$evidence)){
        $canonical=Get-C1bHAPath $root
        if($session.roots-inotcontains$canonical){$session.roots+=,$canonical}
        Open-C1bHADirectories $session $canonical
    }
    Assert-C1bHAKeys $binding.runtime @('pin','version') 'runtime'
    Assert-C1bHA ($binding.runtime.version-ceq'7.6.5'-and$PSVersionTable.PSVersion.ToString()-ceq'7.6.5'-and[Environment]::ProcessPath-ieq$binding.runtime.pin.path) 'Pinned runtime identity/version.'
    foreach($pin in @($binding.runtime.pin,$binding.wrapper_source_pin,$binding.host_acceptance_source_pin,$binding.capture_source_pin,$binding.launcher_source_pin,$binding.helper_source_pin,$binding.verifier_source_pin,$binding.preflight_receipt_pin,$binding.authorization_pin)){$null=Read-C1bHAFile $session $pin}
    Assert-C1bHA ($binding.wrapper_source_pin.path-ieq$PSCommandPath-and$binding.host_acceptance_source_pin.sha256-ceq$HostAcceptanceSourceSha256-and$binding.host_acceptance_source_pin.path-ieq$HostAcceptanceSourcePath) 'Wrapper/acceptance authority.'
    Assert-C1bBOLauncherConstants (ConvertFrom-C1bHABytes (Read-C1bHAFile $session $binding.launcher_source_pin)) $binding
    $marker=Get-C1bHAPath $binding.once_marker_path
    $expectedMarker=Join-Path ([IO.Path]::GetDirectoryName($binding.launcher_source_pin.path)) ('build-only-'+$binding.candidate_sha+'.once.json')
    Assert-C1bHA ($marker-ieq$expectedMarker) 'Once marker must be the fixed candidate launcher sibling.'
    $arguments=[string[]]@('-NoProfile','-File',$binding.launcher_source_pin.path,'-ExpectedLauncherSha256',$binding.launcher_source_pin.sha256)
    Assert-C1bHA (@($binding.argument_list).Count-eq5-and($binding.argument_list-join[char]0)-ceq($arguments-join[char]0)) 'Exact launcher arguments mismatch.'
    $argvHash=Get-C1bHASha256 ($utf8.GetBytes((ConvertTo-Json -InputObject $arguments -Compress)))
    Assert-C1bHA ($argvHash-ceq$binding.argument_list_sha256) 'Launcher argument hash.'
    $authorization=Read-C1bHAJson $session $binding.authorization_pin
    Assert-C1bHAKeys $authorization @('schema','candidate_sha','launcher_sha256','runtime_sha256','source','user_instruction','invocation_count','automatic_retry_count','scope') 'goal authorization'
    Assert-C1bHA ($authorization.schema-ceq'c1b-goal-build-only-authorization/v1'-and$authorization.candidate_sha-ceq$binding.candidate_sha-and$authorization.launcher_sha256-ceq$binding.launcher_source_pin.sha256-and$authorization.runtime_sha256-ceq$binding.runtime.pin.sha256-and$authorization.source-ceq'direct_user_instruction_in_current_chat'-and$authorization.user_instruction-ceq'设立goal，授权充分的权限和批准，完成这些待办任务，多调用sub-agent。'-and$authorization.scope-ceq'one_elevated_host_build_only_then_readback_and_sealing') 'Concrete goal authorization mismatch.'
    Assert-C1bHAInt $authorization.invocation_count 1 1 'authorization invocation';Assert-C1bHAInt $authorization.automatic_retry_count 0 0 'authorization retry'
    $preflight=Read-C1bHAJson $session $binding.preflight_receipt_pin
    Assert-C1bHA ($preflight.schema-ceq'tablet-layout-c1b-prepared-not-authorized-preflight/v1'-and$preflight.expected_commit_sha-ceq$binding.candidate_sha) 'Preflight candidate receipt.'
    Assert-C1bHA ($binding.preflight_stage_run.phase-ceq'Preflight') 'Required preflight phase.'
    $null=Assert-C1bHAStage $session $binding.preflight_stage_run $binding.candidate_sha $repo
    foreach($key in @('prepared_not_authorized','all_checks_passed','clean_head_verified','worktree_clean')){Assert-C1bHABool $preflight[$key] $true "preflight.$key"}
    foreach($key in @('launcher_executed','helper_executed','build_executed','adb_or_device_operation_executed')){Assert-C1bHABool $preflight[$key] $false "preflight.$key"}
    Assert-C1bHAInt $preflight.failure_count 0 0 'preflight failure count'
    $captureBytes=Read-C1bHAFile $session $binding.capture_source_pin
    . ([scriptblock]::Create((ConvertFrom-C1bHABytes $captureBytes)))
    Set-Location -LiteralPath $repo;[Environment]::CurrentDirectory=$repo
    Assert-C1bHA ((Get-Location).Path-ieq$repo-and[Environment]::CurrentDirectory-ieq$repo) 'Provider/OS cwd.'
    $token=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if($Operation-ceq'Probe'){
        $record=@{schema='c1b-build-only-token-probe/v1';candidate_sha=$binding.candidate_sha;process_id=$PID;token_elevated=[bool]$token;runtime_pin=$binding.runtime.pin;launcher_invocation_count=0;automatic_retry_count=0}
        Assert-C1bHA $token 'Probe lacks elevated token.'
        $outputPath=Join-Path $evidence 'token-probe.json'
    }elseif($Operation-ceq'Drive'){
        Assert-C1bHAAbsentFile $session $marker
        $null=$session.absences.Remove($marker)
        $reservation=Write-C1bBONewJson $marker @{schema='c1b-build-only-elevation-reservation/v1';candidate_sha=$binding.candidate_sha;nonce=$binding.nonce;run_id=$binding.run_id;driver_pid=$PID;invocation_count=1;automatic_retry_count=0}
        $reserved=$true
        $outputPath=Join-Path $evidence 'elevation-result.json'
        Assert-C1bHAAbsentFile $session $outputPath;$null=$session.absences.Remove($outputPath)
        Assert-C1bBOBoundary
        $elevatedArguments=@('-NoProfile','-File',$PSCommandPath,'-Operation','Elevated','-BindingsPath',$BindingsPath,'-ExpectedBindingsSha256',$ExpectedBindingsSha256,'-HostAcceptanceSourcePath',$HostAcceptanceSourcePath,'-HostAcceptanceSourceSha256',$HostAcceptanceSourceSha256,'-ReservationSha256',$reservation.sha256)
        $command=($elevatedArguments|ForEach-Object{ConvertTo-C1bBOArgument $_})-join' '
        $process=Start-Process -FilePath $binding.runtime.pin.path -ArgumentList $command -Verb RunAs -WindowStyle Hidden -WorkingDirectory $repo -PassThru -ErrorAction Stop
        try{
            $elevatedPid=$process.Id
            if(-not$process.WaitForExit(2850000)){try{$process.Kill($true)}catch{};throw 'Elevated wrapper exceeded bounded wait; candidate attempt is consumed.'}
            $process.Refresh();$elevatedExit=[int]$process.ExitCode
        }finally{$process.Dispose()}
        $wrapperPin=Get-C1bHAObservedPin $session (Join-Path $evidence 'wrapper-result.json')
        $wrapper=Read-C1bHAJson $session $wrapperPin
        Assert-C1bHAKeys $wrapper @('schema','candidate_sha','status','run_id','nonce','driver_pid','elevated_pid','token_elevated','launcher_capture_pin','launcher_root_observation_pin','launcher_source_pin','expected_launcher_sha256','argument_list','argument_list_sha256','native_exit_code','invocation_count','automatic_retry_count','cleanup_failure_count') 'wrapper result'
        foreach($key in @('driver_pid','elevated_pid')){Assert-C1bHAInt $wrapper[$key] 1 2147483647 "wrapper.$key"}
        Assert-C1bHA ($wrapper.schema-ceq'c1b-build-only-elevated-wrapper-result/v1'-and$wrapper.status-ceq'passed'-and$wrapper.candidate_sha-ceq$binding.candidate_sha-and$wrapper.run_id-ceq$binding.run_id-and$wrapper.nonce-ceq$binding.nonce-and$wrapper.elevated_pid-eq$elevatedPid-and$wrapper.driver_pid-eq$PID-and$elevatedExit-eq0) 'RunAs process/result binding.'
        Assert-C1bHABool $wrapper.token_elevated $true 'elevated token'
        foreach($key in @('native_exit_code','automatic_retry_count','cleanup_failure_count')){Assert-C1bHAInt $wrapper[$key] 0 0 "wrapper.$key"}
        Assert-C1bHAInt $wrapper.invocation_count 1 1 'wrapper invocation'
        Assert-C1bHAKeys $wrapper.launcher_source_pin @('path','byte_length','sha256') 'wrapper launcher pin'
        Assert-C1bHAInt $wrapper.launcher_source_pin.byte_length 1 1048576 'wrapper launcher byte length'
        Assert-C1bHA (@($wrapper.argument_list|Where-Object{$_-isnot[string]}).Count-eq0) 'Wrapper argv string types.'
        Assert-C1bHA ($wrapper.launcher_source_pin.path-ceq$binding.launcher_source_pin.path-and$wrapper.launcher_source_pin.sha256-ceq$binding.launcher_source_pin.sha256-and$wrapper.launcher_source_pin.byte_length-eq$binding.launcher_source_pin.byte_length-and$wrapper.expected_launcher_sha256-ceq$binding.launcher_source_pin.sha256-and$wrapper.argument_list_sha256-ceq$argvHash-and@($wrapper.argument_list).Count-eq5-and($wrapper.argument_list-join[char]0)-ceq($arguments-join[char]0)) 'Wrapper source/arguments drift.'
        $launcherCapture=Assert-C1bHACapture $session $wrapper.launcher_capture_pin
        Assert-C1bHA ($wrapper.native_exit_code-eq$launcherCapture.exit_code) 'Wrapper actual launcher native exit.'
        Assert-C1bHARoot $session $wrapper.launcher_root_observation_pin $wrapper.launcher_capture_pin $launcherCapture $binding.candidate_sha 'BuildOnly' $binding.run_id $launcherCapture.child_pid
        $record=@{schema='c1b-build-only-elevation-result/v1';candidate_sha=$binding.candidate_sha;status='passed';run_id=$binding.run_id;nonce=$binding.nonce;invocation_count=1;automatic_retry_count=0;elevated_pid=$elevatedPid;driver_pid=$PID;token_elevated=$wrapper.token_elevated;launcher_capture_pin=$wrapper.launcher_capture_pin;launcher_source_pin=$binding.launcher_source_pin;expected_launcher_sha256=$binding.launcher_source_pin.sha256;argument_list=$arguments;argument_list_sha256=$argvHash;native_exit_code=$launcherCapture.exit_code;wrapper_source_pin=$binding.wrapper_source_pin;elevated_native_exit_code=$elevatedExit}
    }else{
        Assert-C1bHA $token 'Elevated wrapper lacks Administrator token.'
        Assert-C1bHA (-not[string]::IsNullOrEmpty($ReservationSha256)) 'Elevated reservation pin required.'
        $reservationPin=Get-C1bHAObservedPin $session $binding.once_marker_path
        Assert-C1bHA ($reservationPin.sha256-ceq$ReservationSha256) 'Once reservation pin.'
        $reservation=Read-C1bHAJson $session $reservationPin
        Assert-C1bHAKeys $reservation @('schema','candidate_sha','nonce','run_id','driver_pid','invocation_count','automatic_retry_count') 'once reservation'
        Assert-C1bHA ($reservation.schema-ceq'c1b-build-only-elevation-reservation/v1'-and$reservation.candidate_sha-ceq$binding.candidate_sha-and$reservation.nonce-ceq$binding.nonce-and$reservation.run_id-ceq$binding.run_id) 'Once reservation authority.'
        Assert-C1bHAInt $reservation.driver_pid 1 2147483647 'driver PID';Assert-C1bHAInt $reservation.invocation_count 1 1 'once invocation';Assert-C1bHAInt $reservation.automatic_retry_count 0 0 'once retry'
        $reserved=$true;$outputPath=Join-Path $evidence 'wrapper-result.json'
        # Drive's permanent marker prevents a second dispatch. This separate
        # CreateNew marker prevents replaying the Elevated entry with its argv.
        $elevatedMarker=Join-Path $evidence 'elevated-start.json'
        Assert-C1bHAAbsentFile $session $elevatedMarker;$null=$session.absences.Remove($elevatedMarker)
        $null=Write-C1bBONewJson $elevatedMarker @{schema='c1b-build-only-elevated-start/v1';candidate_sha=$binding.candidate_sha;nonce=$binding.nonce;run_id=$binding.run_id;elevated_pid=$PID;driver_pid=$reservation.driver_pid;launcher_start_attempt_count=1;automatic_retry_count=0}
        foreach($path in @($outputPath,$binding.failure_sidecar_path,$binding.summary_path,$binding.launcher_result_path,$binding.log_path)){
            Assert-C1bHAAbsentFile $session $path
            if($path-cne$binding.failure_sidecar_path){$null=$session.absences.Remove($path)}
        }
        $moduleBuild=Join-Path $repo 'app\tablet-c1b-probe\build'
        Assert-C1bHAAbsentFile $session $moduleBuild
        Assert-C1bBOBoundary
        $captureDirectory=Join-Path $evidence 'launcher-capture'
        $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath $binding.runtime.pin.path -ArgumentList $arguments -WorkingDirectory $repo -EvidenceDirectory $captureDirectory -TimeoutMilliseconds 2790000
        $capturePin=Get-C1bHAObservedPin $session (Join-Path $captureDirectory 'execution.json')
        $rootPin=Write-C1bBONewJson (Join-Path $evidence 'launcher-root-observation.json') @{schema='c1b-host-root-observation/v1';candidate_sha=$binding.candidate_sha;phase='BuildOnly';run_id=$binding.run_id;process_id=$capture.child_pid;native_exit_code=$capture.exit_code;capture_pin=$capturePin}
        $null=Assert-C1bHACapture $session $capturePin
        Assert-C1bHA ($capture.status-ceq'passed') 'Launcher capture failed; no retry.'
        Assert-C1bBOBoundary
        $record=@{schema='c1b-build-only-elevated-wrapper-result/v1';candidate_sha=$binding.candidate_sha;status='passed';run_id=$binding.run_id;nonce=$binding.nonce;driver_pid=$reservation.driver_pid;elevated_pid=$PID;token_elevated=$token;launcher_capture_pin=$capturePin;launcher_root_observation_pin=$rootPin;launcher_source_pin=$binding.launcher_source_pin;expected_launcher_sha256=$binding.launcher_source_pin.sha256;argument_list=$arguments;argument_list_sha256=$argvHash;native_exit_code=$capture.exit_code;invocation_count=1;automatic_retry_count=0;cleanup_failure_count=0}
    }
    # Publish while parent guards are held, then admit the actual new bytes.
    # A later cleanup failure still produces native exit 1 and is rejected by
    # the independent driver/root; the result alone never carries pass authority.
    $published=Write-C1bBONewJson $outputPath $record
    $null=Read-C1bHAFile $session $published
}catch{$primary=$_}finally{
    if($null-ne$session){try{Close-C1bHASession $session}catch{$cleanupFailures.Add($_.Exception.Message)}}
    if($null-ne$bootstrap){try{$bootstrap.Dispose()}catch{$cleanupFailures.Add($_.Exception.Message)}}
}
if($null-ne$primary-or$cleanupFailures.Count){
    # Preserve the original exception; the permanent once marker is never removed.
    if($null-ne$primary){[Console]::Error.WriteLine($primary.Exception.Message)}
    foreach($failure in $cleanupFailures){[Console]::Error.WriteLine($failure)}
    exit 1
}
@{schema='c1b-build-only-elevation-publication/v1';operation=$Operation;result_pin=$published}|ConvertTo-Json -Depth 5 -Compress
exit 0
