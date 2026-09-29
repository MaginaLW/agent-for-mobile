#Requires -Version 7.6
# Maintained source, not a byte derivation of an unavailable historical inline capture.
# Root must review/freeze this file and supply hashes of the unchanged preparation
# binding and a separately recorded fresh user confirmation. Never run to test it.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedBindingSha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$CurrentUserConfirmationSha256
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$prep='__ENTRY_ROOT__'
$repo='__REPO_ROOT__';$candidate='__CANDIDATE_SHA__';$attempt='r1'
$source=Join-Path $prep 'observe-next-device-launch-r1.ps1'
$sourceHash='__SOURCE_OBSERVE_NEXT_DEVICE_LAUNCH_R1_HASH__';$sourceLength='__SOURCE_OBSERVE_NEXT_DEVICE_LAUNCH_R1_LENGTH__'
$runtime='__PWSH_PATH__'
$runtimeHash='362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
$receiptRoot=Join-Path $repo '.checks\c1b-device-once\__CANDIDATE_SHORT__\r1'
$bindingPath=Join-Path $receiptRoot 'binding.json'
$confirmationPath=Join-Path $prep 'device-ready-confirmation-r1.json'
$readyPath=Join-Path $repo '.checks/c1b-host-readiness/__CANDIDATE_SHORT__/host-ready-r1.json'
$outDir=Join-Path $prep 'observer-device-r1'
$held=[Collections.Generic.List[IO.FileStream]]::new();$errors=[Collections.Generic.List[string]]::new()
$utf8=[Text.UTF8Encoding]::new($false,$true);$p=$null;$stdout=$null;$stderr=$null;$stdoutTask=$null;$stderrTask=$null
$reserved=$false;$started=$false;$launchCalls=0;$actualExit=$null;$actualPid=$null;$creationUtc=$null;$eof=$false
$startedUtc=[DateTimeOffset]::UtcNow.ToString('O');$parentElevated=$null;$readyHash=$null;$selfPin=$null
function Require-Capture([bool]$Condition,[string]$Reason){if(-not$Condition){throw $Reason}}
function Require-Bool($Value,[bool]$Expected,[string]$Reason){Require-Capture ($Value-is[bool]-and$Value-eq$Expected) $Reason}
function Hash-Capture([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function Check-Ordinary([string]$Path,[bool]$Directory=$false){
    $item=Get-Item -LiteralPath $Path -Force
    Require-Capture (($item-is[IO.DirectoryInfo])-eq$Directory-and($item-is[IO.DirectoryInfo]-or$item-is[IO.FileInfo])) 'Unexpected filesystem kind.'
    while($null-ne$item){Require-Capture (-not($item.Attributes-band[IO.FileAttributes]::ReparsePoint)) 'Reparse path is not allowed.';$item=if($item-is[IO.DirectoryInfo]){$item.Parent}else{$item.Directory}}
}
function Read-Frozen([string]$Path,[string]$ExpectedHash='', [long]$ExpectedLength=0){
    Check-Ordinary $Path
    Require-Capture ((Get-Item -LiteralPath $Path).IsReadOnly) 'Input must already be read-only.'
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$held.Add($stream)
    Require-Capture ($stream.Length-gt0-and$stream.Length-le1048576-and($ExpectedLength-eq0-or$stream.Length-eq$ExpectedLength)) 'Input length differs.'
    $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes);$hash=Hash-Capture $bytes
    Require-Capture (-not$ExpectedHash-or$hash-ceq$ExpectedHash) 'Input raw hash differs.'
    [pscustomobject]@{bytes=$bytes;sha256=$hash;length=$bytes.Length}
}
function Write-CaptureRecord([string]$Name,$Value){
    $path=Join-Path $outDir $Name;$bytes=$utf8.GetBytes(($Value|ConvertTo-Json -Depth 15 -Compress)+"`n")
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::SetAttributes($path,[IO.File]::GetAttributes($path)-bor[IO.FileAttributes]::ReadOnly)
}
try{
    Require-Capture ($PSVersionTable.PSVersion.ToString()-ceq'7.6.5'-and[Environment]::ProcessPath-ceq$runtime) 'Pinned PowerShell 7.6.5 required.'
    Require-Capture ((Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash.ToLowerInvariant()-ceq$runtimeHash) 'Runtime hash differs.'
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try{$parentElevated=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}finally{$identity.Dispose()}
    Require-Capture (-not$parentElevated) 'Capture parent must be unelevated; UAC belongs to the observer.'
    $selfPin=Read-Frozen $PSCommandPath
    [void](Read-Frozen $source $sourceHash $sourceLength)
    $bindingFile=Read-Frozen $bindingPath $ExpectedBindingSha256
    $binding=$utf8.GetString($bindingFile.bytes)|ConvertFrom-Json -Depth 100
    Require-Capture ($binding.schema-ceq'c1b-device-root-preparation-binding/v1'-and$binding.commit_sha-ceq$candidate-and$binding.repo_root-ceq$repo-and$binding.attempt-ceq$attempt) 'Preparation binding identity differs.'
    Require-Bool $binding.tablet_scene_ready_confirmed_by_user $false 'Preparation binding must retain scene-ready=false.'
    Require-Bool $binding.tablet_scene_reconfirmation_required_before_device_stage $true 'Preparation binding must require reconfirmation.'
    foreach($name in @('device_stage_started','device_stage_authorized_by_this_binding','device_evidence_verified','wrapper_enforces_binding')){Require-Bool $binding.$name $false ('Preparation binding boundary differs: '+$name)}
    $confirmationFile=Read-Frozen $confirmationPath $CurrentUserConfirmationSha256
    $confirmation=$utf8.GetString($confirmationFile.bytes)|ConvertFrom-Json -Depth 20
    Require-Capture ($confirmation.schema-ceq'c1b-device-scene-user-confirmation/v1'-and$confirmation.candidate_sha-ceq$candidate-and$confirmation.attempt-ceq$attempt) 'Fresh confirmation identity differs.'
    Require-Capture ($confirmation.user_message-is[string]-and-not[string]::IsNullOrWhiteSpace($confirmation.user_message)) 'Fresh user message is missing.'
    Require-Bool $confirmation.scene_ready_user_confirmed $true 'Fresh scene confirmation is required.'
    Require-Bool $confirmation.scene_measured_by_runner $false 'User confirmation is not runner measurement.'
    Require-Bool $confirmation.preparation_binding_unchanged $true 'Preparation binding must remain unchanged.'
    Require-Bool $confirmation.device_evidence_verified $false 'User confirmation is not device acceptance.'
    Require-Bool $confirmation.automatic_retry_authorized $false 'Automatic retry is not authorized.'
    Require-Capture ($confirmation.preparation_binding_sha256-ceq$ExpectedBindingSha256-and$confirmation.host_ready_sha256-cmatch'^[0-9a-f]{64}$') 'Confirmation preparation pins differ.'
    $readyFile=Read-Frozen $readyPath $confirmation.host_ready_sha256;$readyHash=$readyFile.sha256
    $ready=$utf8.GetString($readyFile.bytes)|ConvertFrom-Json -Depth 100
    Require-Capture ($ready.schema-ceq'c1b-pre-device-ready-freeze/v1'-and$ready.status-ceq'host_ready_waiting_for_device_assistance'-and$ready.candidate_sha-ceq$candidate) 'Host-ready identity/status differs.'
    Require-Capture ($ready.binding.path-ceq$bindingPath-and$ready.binding.sha256-ceq$ExpectedBindingSha256-and$ready.binding.byte_length-eq$bindingFile.length) 'Host-ready binding differs.'
    Require-Capture ($ready.tools.external_observer.path-ceq$source-and$ready.tools.external_observer.sha256-ceq$sourceHash-and$ready.tools.external_observer.byte_length-eq$sourceLength) 'Host-ready observer differs.'
    Require-Bool $ready.device_stage_started $false 'Host-ready record must precede the device stage.'
    Require-Bool $ready.device_evidence_verified $false 'Host-ready record is not device acceptance.'
    Require-Bool $ready.current_scene_verified $false 'Host-ready scene must remain unmeasured.'
    Require-Capture ([DateTimeOffset]$confirmation.recorded_utc-ge[DateTimeOffset]$ready.created_utc-and[DateTimeOffset]$confirmation.recorded_utc-le[DateTimeOffset]::UtcNow) 'Fresh confirmation must follow host-ready publication.'
    Check-Ordinary $receiptRoot $true
    $leaves=@(Get-ChildItem -LiteralPath $receiptRoot -Force)
    Require-Capture ($leaves.Count-eq1-and$leaves[0].Name-ceq'binding.json') 'Attempt already contains device evidence; no replay.'
    Check-Ordinary $prep $true
    Require-Capture (-not(Test-Path -LiteralPath $outDir)) 'Capture output directory exists; no retry.'
    [void](New-Item -ItemType Directory -Path $outDir -ErrorAction Stop)
    Write-CaptureRecord 'launch-reservation.json' ([ordered]@{schema='c1b-observer-external-capture-reservation/v1';candidate_sha=$candidate;attempt=$attempt;reserved_utc=$startedUtc;source_sha256=$sourceHash;binding_sha256=$ExpectedBindingSha256;current_user_confirmation_sha256=$CurrentUserConfirmationSha256;host_ready_sha256=$readyHash;maximum_observer_launch_calls=1;automatic_retry_authorized=$false})
    $reserved=$true
    $stdout=[IO.File]::Open((Join-Path $outDir 'stdout.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $stderr=[IO.File]::Open((Join-Path $outDir 'stderr.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $p=[Diagnostics.Process]::new();$p.StartInfo=[Diagnostics.ProcessStartInfo]::new($runtime)
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true;$p.StartInfo.WorkingDirectory=$repo
    foreach($argValue in @('-NoLogo','-NoProfile','-NonInteractive','-File',$source,'-ExpectedBindingSha256',$ExpectedBindingSha256)){$p.StartInfo.ArgumentList.Add($argValue)}
    $launchCalls=1
    Require-Capture ($p.Start()) 'Observer process did not start.'
    $started=$true;$actualPid=$p.Id
    $stdoutTask=$p.StandardOutput.BaseStream.CopyToAsync($stdout);$stderrTask=$p.StandardError.BaseStream.CopyToAsync($stderr)
    $creationUtc=$p.StartTime.ToUniversalTime().ToString('O')
    Write-CaptureRecord 'started.json' ([ordered]@{schema='c1b-observer-external-capture-started/v1';actual_observer_pid=$actualPid;actual_observer_creation_utc=$creationUtc;observer_launch_call_count=$launchCalls;observer_started=$started;automatic_retry_count=0;capture_parent_elevated=$parentElevated;source_sha256=$sourceHash;expected_binding_sha256=$ExpectedBindingSha256;uac_or_wrapper_status='Not observed by capture parent; owned by exact observer';stdout_path=(Join-Path $outDir 'stdout.bin');stderr_path=(Join-Path $outDir 'stderr.bin')})
}catch{$errors.Add($_.Exception.Message)}finally{
    if($started){
        try{$p.WaitForExit();$actualExit=[int]$p.ExitCode}catch{$errors.Add('Observer termination/actual exit observation failed: '+$_.Exception.Message)}
        $stdoutEof=$false;$stderrEof=$false
        try{Require-Capture ($null-ne$stdoutTask) 'stdout task is missing.';[void]$stdoutTask.GetAwaiter().GetResult();$stdoutEof=$true}catch{$errors.Add('stdout completion failed: '+$_.Exception.Message)}
        try{Require-Capture ($null-ne$stderrTask) 'stderr task is missing.';[void]$stderrTask.GetAwaiter().GetResult();$stderrEof=$true}catch{$errors.Add('stderr completion failed: '+$_.Exception.Message)}
        $eof=$stdoutEof-and$stderrEof
    }
    foreach($stream in @($stdout,$stderr)){if($null-ne$stream){
        try{$stream.Flush($true)}catch{$errors.Add('Raw stream flush failed: '+$_.Exception.Message)}
        try{$stream.Dispose()}catch{$errors.Add('Raw stream disposal failed: '+$_.Exception.Message)}
    }}
    foreach($stream in $held){try{$stream.Dispose()}catch{$errors.Add('Held input disposal failed: '+$_.Exception.Message)}}
    if($null-ne$p){try{$p.Dispose()}catch{$errors.Add('Observer process disposal failed: '+$_.Exception.Message)}}
}
if(-not$reserved){throw ('Capture refused before launch reservation: '+($errors-join'; '))}
$raw=[ordered]@{}
foreach($name in @('stdout','stderr')){
    $path=Join-Path $outDir ($name+'.bin')
    $raw[$name+'_byte_length']=$null;$raw[$name+'_sha256']=$null
    try{
        Require-Capture (Test-Path -LiteralPath $path) ($name+' raw file is missing.')
        [IO.File]::SetAttributes($path,[IO.File]::GetAttributes($path)-bor[IO.FileAttributes]::ReadOnly)
        $raw[$name+'_byte_length']=(Get-Item -LiteralPath $path).Length
        $raw[$name+'_sha256']=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }catch{$errors.Add($name+' raw metadata/freeze failed: '+$_.Exception.Message)}
}
$record=[ordered]@{
    schema='c1b-device-observer-external-capture/v1';candidate_sha=$candidate;attempt=$attempt;source_path=$source;source_sha256=$sourceHash;source_byte_length=$sourceLength
    capture_source_path=$PSCommandPath;capture_source_sha256=$selfPin.sha256;capture_source_basis='New reviewed source preserving historical reservation/started/execution protocol; not historical source byte derivation'
    runtime='7.6.5';runtime_path=$runtime;runtime_sha256=$runtimeHash;argument_list=@('-NoLogo','-NoProfile','-NonInteractive','-File',$source,'-ExpectedBindingSha256',$ExpectedBindingSha256)
    binding_sha256=$ExpectedBindingSha256;current_user_confirmation_sha256=$CurrentUserConfirmationSha256;host_ready_sha256=$readyHash;capture_parent_elevated=$parentElevated
    observer_launch_call_count=$launchCalls;observer_started=$started;actual_observer_pid=$actualPid;actual_observer_creation_utc=$creationUtc;actual_observer_exit_code=$actualExit
    started_utc=$startedUtc;completed_utc=[DateTimeOffset]::UtcNow.ToString('O');stdout_byte_length=$raw.stdout_byte_length;stdout_sha256=$raw.stdout_sha256;stderr_byte_length=$raw.stderr_byte_length;stderr_sha256=$raw.stderr_sha256
    raw_stream_capture=$true;both_raw_streams_reached_eof=$eof;capture_errors=@($errors);automatic_retry_count=0;processes_killed=0;runner_receipts_read_by_capture=0;device_commands_issued_by_capture=0
    observer_exit_basis='Actual Process.ExitCode after process termination; no receipt fallback';device_pass_claimed=$false
}
try{Write-CaptureRecord 'execution.json' $record}catch{$errors.Add('Execution record publication failed: '+$_.Exception.Message);$record.capture_errors=@($errors)}
$record|ConvertTo-Json -Depth 15 -Compress
if($errors.Count-gt0-or-not$started-or-not$eof-or$null-eq$actualExit){exit 1}
exit $actualExit
