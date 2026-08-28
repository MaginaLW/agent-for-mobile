#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$helper=Join-Path $root 'scripts\lib\tablet-layout-c1b-readonly.ps1'
$runner=Join-Path $root 'scripts\run-tablet-layout-c1b.ps1'
$t0Runner=Join-Path $root 'scripts\run-tablet-intake.ps1'
$t0Library=Join-Path $root 'scripts\lib\tablet-intake.ps1'
. $helper
$passed=0;$failed=0;$temp=Join-Path ([IO.Path]::GetTempPath()) ('tl1-c1b-readonly-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temp)
function Pass([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function Throws([scriptblock]$Body,[string]$Message){$threw=$false;try{&$Body}catch{$threw=$true};if(-not$threw){throw $Message}}
function Mutate([string]$Source,[string]$Old,[string]$New,[string]$Name){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8);if(-not$raw.Contains($Old)){throw "mutation anchor missing: $Old"}
    $path=Join-Path $temp $Name;[IO.File]::WriteAllText($path,$raw.Replace($Old,$New),[Text.UTF8Encoding]::new($false));return $path
}
function MutateOnce([string]$Source,[string]$Old,[string]$New,[string]$Name){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8)
    $index=$raw.IndexOf($Old,[StringComparison]::Ordinal);if($index-lt0){throw "mutation anchor missing: $Old"}
    $mutated=$raw.Substring(0,$index)+$New+$raw.Substring($index+$Old.Length)
    $path=Join-Path $temp $Name;[IO.File]::WriteAllText($path,$mutated,[Text.UTF8Encoding]::new($false));return $path
}
try{
    $proof=$null;$t0Proof=$null
    Pass ast_positive {
        $script:proof=Assert-TL1C1bRunnerReadOnlyAst $runner;if($proof.schema-cne'tablet-layout-c1b-runner-readonly-ast/v1'){throw 'schema'}
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `\":tablet-c1b-probe:clean`\"" 'double-clean.ps1')} 'double-quoted clean accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    'org.gradle.wrapper.' + 'GradleWrapperMain'" 'concat-wrapper.ps1')} 'concatenated WrapperMain accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment' 'adb-env-inherit.ps1')} 'ADB inherited environment accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment:$false' 'adb-env-false.ps1')} 'ADB ClearEnvironment false accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbTrustEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' 'adb-trust-env-rebind.ps1')} 'ADB trust command accepted device/server environment'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $buildEnvironment' 'aapt2-env-inherit.ps1')} 'aapt2 inherited environment accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' 'aapt2-env-rebind.ps1')} 'aapt2 process environment rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $buildEnvironment -ClearEnvironment:$false' 'aapt2-env-false.ps1')} 'aapt2 ClearEnvironment false accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $adbEnvironment -ClearEnvironment -TimeoutSec 300' 'java-env-rebind.ps1')} 'Gradle process environment rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $buildEnvironment -ClearEnvironment:$false -TimeoutSec 300' 'java-env-false.ps1')} 'Gradle ClearEnvironment false accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $buildEnvironment -ClearEnvironment $false -TimeoutSec 300' 'java-env-separate-false.ps1')} 'Gradle ClearEnvironment separate false accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner '-ProcessEnvironment $t0Environment' '-ProcessEnvironment $buildEnvironment' 'pwsh-env-rebind.ps1')} 'T0 pwsh process environment rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '$Java=[string]$gradleInvocation.FilePath' '$Java=[string]$signerInvocation.FilePath' 'java-source-rebind.ps1')} 'held Java source rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "@('verify','--print-certs',`$Apk)" "@('verify','--verbose',`$Apk)" 'signer-argv-rebind.ps1')} 'apksigner argv rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact' ':tablet-c1b-probe:assembleDebug' 'gradle-task-rebind.ps1')} 'Gradle task rebinding accepted'
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '                Assert-C1bImplementationSnapshot' "                Write-Output 'skip-post-write-implementation-snapshot'" 'implementation-postwrite-removed.ps1')} 'post-write implementation snapshot removal accepted'
    }
    Pass t0_positive {$script:t0Proof=Assert-TL1C1bT0ReadOnlySurface $t0Runner $t0Library;if($t0Proof.query_invocation_counts.devices-ne1){throw 'devices'}}
    Pass parse_error {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' 'try { {' 'parse.ps1')} 'parse error accepted'}
    Pass ampersand_dynamic {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    & `$AdbPath version" 'amp.ps1')} 'dynamic invocation accepted'}
    Pass invoke_expression {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-Expression 'adb version'" 'iex.ps1')} 'Invoke-Expression accepted'}
    Pass start_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Start-Process adb.exe" 'start.ps1')} 'Start-Process accepted'}
    Pass direct_adb_command {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    adb.exe version" 'adb.ps1')} 'direct adb accepted'}
    Pass direct_adb_generic_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-TL1C1aProcess -FilePath `$AdbPath -Arguments @('version')" 'generic.ps1')} 'generic adb accepted'}
    Pass unbound_generic_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-TL1C1aProcess -FilePath (Join-Path `$env:TEMP 'adb.exe') -Arguments @('version')" 'generic-computed.ps1')} 'computed generic process accepted'}
    Pass c1a_name_allowlist {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name install ' ' -Name a11y_enabled ' 'c1a-name.ps1')} 'C1a name accepted'}
    Pass c1a_dynamic_name {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name install ' ' -Name $dynamicName ' 'c1a-dynamic.ps1')} 'C1a dynamic name accepted'}
    Pass c1b_name_allowlist {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name content_result ' ' -Name content_unknown ' 'c1b-name.ps1')} 'C1b name accepted'}
    Pass read_control_dynamic_callsite {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Read-C1bControl content_c1 $uris.c1' 'Read-C1bControl $dynamicName $uris.c1' 'read-dynamic.ps1')} 'dynamic wrapper callsite accepted'}
    Pass read_control_reassignment {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'function Read-C1bControl([string]$Name,[string]$Uri) {' "function Read-C1bControl([string]`$Name,[string]`$Uri) {`n    `$Name='content_status'" 'read-assign.ps1')} 'Name reassignment accepted'}
    Pass dot_source_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "Join-Path `$PSScriptRoot 'lib\tablet-layout-c1b.ps1'" "Join-Path `$PSScriptRoot 'lib\evil.ps1'" 'dot-rebind.ps1')} 'dot-source rebinding accepted'}
    Pass private_adb_dot_source_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "Join-Path `$PSScriptRoot 'lib\tablet-layout-c1b-adb-server.ps1'" "Join-Path `$PSScriptRoot 'lib\evil-adb-server.ps1'" 'private-adb-dot-rebind.ps1')} 'private adb dot-source rebinding accepted'}
    Pass private_adb_open_environment_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-AdbPath $AdbPath -ProcessEnvironment $adbTrustEnvironment' '-AdbPath $AdbPath -ProcessEnvironment $adbEnvironment' 'private-adb-open-env.ps1')} 'private adb open environment rebinding accepted'}
    Pass private_adb_client_guard_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Get-TL1C1bPrivateAdbClientEnvironment $adbServerGuard' 'Get-TL1C1bPrivateAdbClientEnvironment $otherGuard' 'private-adb-client-guard.ps1')} 'private adb client guard rebinding accepted'}
    Pass private_adb_business_guard_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner ' -PrivateAdbServerGuard $adbServerGuard' '' 'private-adb-business-guard-removed.ps1')} 'single private business ADB wrapper Guard removal accepted'}
    Pass private_adb_business_guard_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner ' -PrivateAdbServerGuard $adbServerGuard' ' -PrivateAdbServerGuard $otherGuard' 'private-adb-business-guard-rebound.ps1')} 'single private business ADB wrapper Guard rebinding accepted'}
    Pass private_adb_t0_guarded_launcher_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Invoke-TL1C1bPrivateAdbGuardedProcess' 'Invoke-TL1C1aProcess' 'private-adb-t0-generic-launcher.ps1')} 'T0 generic launcher fallback accepted'}
    Pass private_adb_t0_arguments_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "@('-NoProfile','-File',`$T0Runner,'-AdbPath',`$T0AdbCmd,'-RunId',`$runId)" "@('-NoProfile','-File',`$T0Runner,'-RunId',`$runId,'-AdbPath',`$T0AdbCmd)" 'private-adb-t0-arguments.ps1')} 'T0 guarded launcher argument reordering accepted'}
    Pass private_adb_t0_client_kind_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-ClientKind T0Root' '-ClientKind AdbCli' 'private-adb-t0-kind.ps1')} 'T0 guarded launcher ClientKind rebinding accepted'}
    Pass private_adb_t0_extra_argument {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-ClientKind T0Root' "-ClientKind T0Root 'extra'" 'private-adb-t0-extra-argument.ps1')} 'T0 guarded launcher extra positional argument accepted'}
    Pass adb_trust_private_guard_injected {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -ProcessEnvironment' 'Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -PrivateAdbServerGuard $adbServerGuard -ProcessEnvironment' 'adb-trust-private-guard.ps1')} 'adb trust version private socket Guard accepted'}
    Pass private_adb_cleanup_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Close-TL1C1bPrivateAdbServerGuard $adbServerGuard' "Write-Output 'skip-private-adb-close'" 'private-adb-close-removed.ps1')} 'private adb close removal accepted'}
    Pass private_adb_frozen_recheck_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '[void](Assert-C1bPrivateAdbServerFrozenState)' "[void](Write-Output 'skip-private-adb-recheck')" 'private-adb-recheck-removed.ps1')} 'private adb frozen recheck removal accepted'}
    Pass private_adb_cleanup_after_sidecar {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '$sessionConsumed=$true' '$sessionConsumed=$true;$sidecar=[ordered]@{}' 'private-adb-cleanup-after-sidecar.ps1')} 'sidecar construction before private adb cleanup accepted'}
    Pass process_start_bypass {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    [Diagnostics.Process]::Start(`$AdbPath)" 'process-start.ps1')} 'Process.Start accepted'}
    Pass scriptblock_dynamic_invoke {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `$dynamic={ adb.exe version }; `$dynamic.Invoke()" 'scriptblock-invoke.ps1')} 'scriptblock Invoke accepted'}
    $categoryMutations=[ordered]@{
        display_screenshot='Get-DisplayScreenshot';window_screenshot='Get-WindowScreenshot';ocr='Invoke-Host-Ocr'
        action='Invoke-MobileAction';gesture='Invoke-Gesture';input='Send-DeviceInput';settings='Set-AndroidSetting'
        target='Start-TargetApp';mcp='mcp__mobile__read';dispatch='Invoke-TaskDispatch'
    }
    foreach($entry in $categoryMutations.GetEnumerator()){
        Pass ("category_"+$entry.Key) {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' ("try {`n    "+$entry.Value) ("category-"+$entry.Key+'.ps1'))} ("category accepted: "+$entry.Key)}
    }
    Pass t0_validate_set {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'devices', 'prop_brand'" "'devices', 'evil', 'prop_brand'" 't0-set.ps1')} 'T0 ValidateSet mutation accepted'}
    Pass t0_mapping_command {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "@('shell', 'wm', 'size')" "@('shell', 'wm', 'reset')" 't0-map.ps1')} 'T0 mapping mutation accepted'}
    Pass t0_settings_put {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'settings', 'get', 'global'" "'settings', 'put', 'global'" 't0-settings.ps1')} 'settings put accepted'}
    Pass t0_am_start {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'am', 'get-config'" "'am', 'start'" 't0-am.ps1')} 'am start accepted'}
    Pass t0_runner_foreach {Throws {Assert-TL1C1bT0ReadOnlySurface (Mutate $t0Runner "'zen', 'default_ime'" "'zen', 'evil', 'default_ime'" 't0-runner-loop.ps1') $t0Library} 'T0 foreach mutation accepted'}
    Pass t0_runner_dynamic {Throws {Assert-TL1C1bT0ReadOnlySurface (Mutate $t0Runner '-Name activity -Serial $serial' '-Name $outsideName -Serial $serial' 't0-runner-dynamic.ps1') $t0Library} 'T0 outside dynamic name accepted'}
    Pass t0_library_direct_adb {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'Set-StrictMode -Version 3.0' "Set-StrictMode -Version 3.0`nadb.exe version" 't0-direct-adb.ps1')} 'T0 direct adb accepted'}
    Pass t0_library_second_process_start {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'Set-StrictMode -Version 3.0' "Set-StrictMode -Version 3.0`n[Diagnostics.Process]::Start('adb.exe')" 't0-process-start.ps1')} 'T0 second Process.Start accepted'}
    Pass t0_arguments_reassignment {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library '$start = [Diagnostics.ProcessStartInfo]::new()' "`$arguments=@('shell','settings','put','secure','x','1')`n    `$start = [Diagnostics.ProcessStartInfo]::new()" 't0-args-reassign.ps1')} 'T0 arguments reassignment accepted'}
    Pass t0_argument_list_injection {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }' "foreach (`$argument in `$arguments) { `$start.ArgumentList.Add(`$argument) }`n    `$start.ArgumentList.Add('shell')" 't0-args-add.ps1')} 'T0 ArgumentList injection accepted'}
    $capture=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;result_read_count=1L;recapture_count=0L}
    $control=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;committed_tokens=[string[]]@('c1','c2');recapture_count=0L}
    Pass counts_positive {$counts=ConvertTo-TL1C1bReadOnlyCounts $capture $control $proof;if($counts.a11y_frame_capture_count-ne2L-or$counts.recapture_count-ne0L){throw 'derived counts'}}
    Pass capture_extra_property {$x=$capture|Select-Object *;$x|Add-Member extra 0L;Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'capture extra accepted'}
    Pass capture_wrong_integer_type {$x=[pscustomobject][ordered]@{c1_requests_accepted=1;c2_requests_accepted=1L;result_read_count=1L;recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'Int32 accepted'}
    Pass control_tuple_mismatch {$x=[pscustomobject][ordered]@{c1_requests_accepted=0L;c2_requests_accepted=1L;committed_tokens=[string[]]@('c1','c2');recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $x $proof} 'control mismatch accepted'}
    Pass committed_tokens_scalar {$x=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;committed_tokens='c1';recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $x $proof} 'token scalar accepted'}
    Pass proof_invocation_count_mutation {$x=$proof|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$x.c1a_invocation_counts.fingerprint=3L;Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $control $x} 'proof invocation count accepted'}
    Pass recapture_nonzero {$x=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;result_read_count=1L;recapture_count=1L};Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'recapture accepted'}
    foreach($name in $script:TL1C1bReadonlyZeroNames){
        Pass ("nonzero_"+$name) {$x=$proof|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$x.static_zero_counts|Add-Member -Force -NotePropertyName $name -NotePropertyValue 1L;Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $control $x} ("nonzero accepted: "+$name)}
    }
}finally{
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
"RESULT passed=$passed failed=$failed"
if($failed-ne0){exit 1}
