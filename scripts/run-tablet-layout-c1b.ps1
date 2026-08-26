#Requires -Version 7.5
<#
T-L1 C1b v1 pure-a11y 宿主受控 runner。一次 fresh build/install；c1/c2 各一次；不卸载、不补拍。
没有 screenshot/OCR/action/gesture/input/settings/target-start/MCP/dispatch 路径。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdbPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedCommitSha,
    [switch]$Provision
)

$ErrorActionPreference='Stop'; Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8
$RepoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$C1aLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1'
$Library=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b.ps1'
$Validator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-validator.ps1'
$NativePathValidator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-validator.ps1'
$SidecarSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1b-sidecar-v1.schema.json'
$ObservationSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-observation-c1b-v1.schema.json'
$T0Runner=Join-Path $PSScriptRoot 'run-tablet-intake.ps1'
$T0Library=Join-Path $PSScriptRoot 'lib\tablet-intake.ps1'
$T0AdbCmd=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.cmd'
$T0AdbScript=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.ps1'
$Gradle=Join-Path $RepoRoot 'app\gradlew.bat'
$Apk=Join-Path $RepoRoot 'app\gateway\build\outputs\apk\debug\gateway-debug.apk'
$EvidenceRoot=Join-Path $RepoRoot 'docs\runs\evidence'
$ImplementationPaths=[ordered]@{
    runner_sha256=$PSCommandPath; c1b_library_sha256=$Library; c1a_low_level_library_sha256=$C1aLibrary
    t0_runner_sha256=$T0Runner; t0_library_sha256=$T0Library; t0_adb_sidecar_cmd_sha256=$T0AdbCmd
    t0_adb_sidecar_script_sha256=$T0AdbScript; validator_sha256=$Validator; native_path_validator_sha256=$NativePathValidator;observation_schema_sha256=$ObservationSchema;sidecar_schema_sha256=$SidecarSchema
    android_model_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\TabletC1bModel.kt')
    android_probe_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\TabletC1bProbe.kt')
    android_source_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\AndroidTabletC1bSource.kt')
    android_provider_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bContentProvider.kt')
    android_protocol_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bProtocol.kt')
    android_coordinator_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bReadCoordinator.kt')
    android_controller_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bRuntimeController.kt')
    android_context_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TrustedRuntimeContextFactory.kt')
    android_pending_registry_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\C1bPendingStartRegistry.kt')
    debug_manifest_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\AndroidManifest.xml')
    gateway_build_gradle_sha256=(Join-Path $RepoRoot 'app\gateway\build.gradle.kts')
}
$runId=$null;$runDirectory=$null;$c1bDirectory=$null;$serial=$null;$nonce=$null;$buildChallenge=$null
$expectedArtifactSha=$null;$sessionStarted=$false;$sessionConsumed=$false;$abortAttempted=$false;$abortSucceeded=$false
$failure=$null;$implementationHashes=$null;$adbTrustBefore=$null;$controlRaw=[Collections.Generic.List[string]]::new();$statusReadCount=0
$abortExpectedGeneration=0L;$abortExpectedC1Count=0;$abortExpectedC2Count=0;$abortExpectedCommitted=[string[]]@()

function Get-C1bTimestamp { [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture) }
function Get-C1bImplementationHashes {
    $value=[ordered]@{};foreach($entry in $ImplementationPaths.GetEnumerator()){$value[$entry.Key]=Get-TL1C1aFileSha256 $entry.Value};return $value
}
function Assert-C1bFrozenState {
    [void](Assert-TL1C1aGitProvenance $RepoRoot $ExpectedCommitSha)
    foreach($entry in $ImplementationPaths.GetEnumerator()){
        if((Get-TL1C1aFileSha256 $entry.Value)-cne $implementationHashes[$entry.Key]){throw "C1b implementation 漂移：$($entry.Key)。"}
    }
}
function Write-C1bFailureEvidence([string]$ReasonCode) {
    if([string]::IsNullOrWhiteSpace($c1bDirectory)-or -not(Test-Path -LiteralPath $c1bDirectory -PathType Container)){return}
    $path=Join-Path $c1bDirectory 'tablet-layout-c1b-failure.json';if(Test-Path -LiteralPath $path){return}
    $payload=[ordered]@{schema='tablet-layout-c1b-failure/v1';run_id=$runId;status='failed';reason_code=$ReasonCode
        cleanup=if(-not $sessionStarted-or$sessionConsumed){'not_required'}elseif($abortAttempted-and$abortSucceeded){'completed'}else{'failed'}
        runtime_origin_verified=$false;runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false
        editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}
    [void](Write-TL1C1aJsonAtomic $RepoRoot $path $payload)
}
function Read-C1bControl([string]$Name,[string]$Uri) {
    $result=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name $Name -Value $Uri -TimeoutSec 30
    if($Name-ceq'content_status'){$script:statusReadCount++}
    $controlRaw.Add($result.Text)
    return ConvertFrom-TL1C1bControl $result.Text $runId $ExpectedCommitSha $expectedArtifactSha $buildChallenge
}
function Set-C1bAbortExpectedSnapshot($Control) {
    $script:abortExpectedGeneration=[long]$Control.generation
    $script:abortExpectedC1Count=[int]$Control.c1_requests_accepted
    $script:abortExpectedC2Count=[int]$Control.c2_requests_accepted
    $script:abortExpectedCommitted=[string[]]@($Control.committed_tokens)
}

try {
    if(-not $Provision){throw 'C1b 真机入口必须显式传入 -Provision。'}
    if(-not[IO.Path]::IsPathFullyQualified($AdbPath)){throw '-AdbPath 必须是绝对路径。'}
    $AdbPath=[IO.Path]::GetFullPath($AdbPath)
    if(-not(Test-Path -LiteralPath $AdbPath -PathType Leaf)-or((Get-Item $AdbPath -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw '-AdbPath 必须是普通文件。'}
    if($ExpectedCommitSha-cnotmatch'^[0-9a-f]{40}$'){throw '-ExpectedCommitSha 必须是完整小写 SHA。'}
    foreach($path in @($ImplementationPaths.Values)+@($Gradle)){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or((Get-Item $path -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw "C1b 依赖缺失或非普通文件：$path"}
    }
    . $NativePathValidator; . $C1aLibrary; . $Validator; . $Library
    $adbTrustBefore=Get-TL1C1bAdbTrustBinding $AdbPath $env:ANDROID_SDK_ROOT $env:ANDROID_HOME
    [void](Assert-TL1C1aGitProvenance $RepoRoot $ExpectedCommitSha)
    $implementationHashes=Get-C1bImplementationHashes;Assert-C1bFrozenState
    $apksigner=Find-TL1C1aApkSigner
    $buildChallenge='c1b-'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $buildStarted=[DateTime]::UtcNow
    [void](Invoke-TL1C1aProcess -FilePath $Gradle -Arguments @('-p',(Join-Path $RepoRoot 'app'),':gateway:clean',':gateway:assembleDebug','--no-daemon','--console=plain','--quiet') `
        -Operation 'fresh C1b debug APK 构建' -Environment @{TABLET_C1B_BUILD_CHALLENGE=$buildChallenge;TL1_C1B_EXPECTED_COMMIT_SHA=$ExpectedCommitSha} -TimeoutSec 300)
    Assert-C1bFrozenState
    if(-not(Test-Path -LiteralPath $Apk -PathType Leaf)){throw 'fresh C1b APK 缺失。'}
    $apkItem=Get-Item $Apk -Force;if(($apkItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$apkItem.LastWriteTimeUtc-lt$buildStarted.AddSeconds(-2)){throw 'C1b APK 不是本轮 fresh build。'}
    $expectedArtifactSha=Get-TL1C1aFileSha256 $Apk;$signerSha=Get-TL1C1aSignerDigest $apksigner $Apk

    $serial=Get-TL1C1aSingleDevice $AdbPath;$serialHash=Get-TL1C1aSha256Text $serial
    $preBinding=Test-TL1C1aDeviceBinding (Invoke-TL1C1aAdb $AdbPath $serial fingerprint).Text (Invoke-TL1C1aAdb $AdbPath $serial boot_id).Text
    # 唯一一次 install；任何失败都直接冻结本轮，代码中没有 uninstall/retry 分支。
    [void](Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name install -Value $Apk -TimeoutSec 180)
    $installedPathBefore=Get-TL1C1aInstalledApkPath (Invoke-TL1C1aAdb $AdbPath $serial package_path).Text
    $installedPathHashBefore=Get-TL1C1aSha256Text $installedPathBefore
    $installedShaBefore=Get-TL1C1aInstalledApkHostSha256 $AdbPath $serial $installedPathBefore 180
    if($installedShaBefore-cne$expectedArtifactSha){throw 'C1b installed APK 与本地 APK 不一致。'}
    $packageBefore=Get-TL1C1aPackageBinding (Invoke-TL1C1aAdb $AdbPath $serial package_dump).Text
    $a11y=Wait-TL1C1aA11yReady $AdbPath $serial
    if(-not$a11y.Ready){[pscustomobject][ordered]@{schema='tablet-layout-c1b-needs-user/v1';status='needs-user';reason_code='a11y_service_not_enabled_or_bound';settings_changed=$false;retry_allowed_after_user_action=$true}|ConvertTo-Json -Compress;exit 2}

    $runId=(New-TL1C1aRunId)-replace'c1a','c1b';$runDirectory=Join-Path $EvidenceRoot $runId
    $pwsh=(Get-Process -Id $PID).Path
    [void](Invoke-TL1C1aProcess -FilePath $pwsh -Arguments @('-NoProfile','-File',$T0Runner,'-AdbPath',$T0AdbCmd,'-RunId',$runId) -Operation 'fresh T0-L v5' `
        -Environment @{TL1_C1A_PWSH_PATH=$pwsh;TL1_C1A_T0_SIDECAR_SCRIPT=$T0AdbScript;TL1_C1A_REAL_ADB_PATH=$AdbPath;TL1_C1A_BOUND_SERIAL=$serial;TL1_C1A_T0_LIBRARY_PATH=$T0Library} -TimeoutSec 180)
    $t0Source=Assert-TL1C1aOrdinaryPath $RepoRoot (Join-Path $runDirectory 'tablet-profile.json')
    $t0SourceRelative=[IO.Path]::GetRelativePath($RepoRoot,$t0Source).Replace('\','/')
    $t0Bytes=[IO.File]::ReadAllBytes($t0Source);if($t0Bytes.Length-notin 1..65536){throw 'C1b T0 byte count 越界。'}
    $t0Raw=ConvertFrom-TL1C1aStrictUtf8 $t0Bytes 'C1b fresh T0';$t0Issues=[Collections.Generic.List[object]]::new()
    $t0Object=ConvertFrom-TL1C1BV1StrictJson $t0Raw $t0Issues;if($null-eq$t0Object-or$t0Issues.Count){throw 'C1b T0 strict JSON 失败。'}
    Assert-TL1C1aT0DeviceBinding $t0Object $runId $serialHash $preBinding.FingerprintHash
    $t0Sha=Get-TL1C1aSha256Bytes $t0Bytes;$crlf=0;for($i=0;$i-lt$t0Bytes.Length-1;$i++){if($t0Bytes[$i]-eq13-and$t0Bytes[$i+1]-eq10){$crlf++}}
    $c1bDirectory=Join-Path $runDirectory 'tablet-layout-c1b';[void](Assert-TL1C1aOrdinaryPath $RepoRoot $c1bDirectory -AllowMissingLeaf)
    if(Test-Path -LiteralPath $c1bDirectory){throw 'C1b evidence 目录已存在。'};[void](New-Item -ItemType Directory -Path $c1bDirectory)
    $t0Path=Join-Path $c1bDirectory 'upstream-t0-v5.json';[void](Write-TL1C1aBytesAtomic $RepoRoot $t0Path $t0Bytes)
    if((Get-TL1C1aFileSha256 $t0Path)-cne$t0Sha){throw 'C1b T0 固定副本漂移。'}

    $nonce='n-'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $uris=[ordered]@{t0=New-TL1C1bUri t0 $runId $nonce $ExpectedCommitSha $expectedArtifactSha;status=New-TL1C1bUri status $runId $nonce
        c1=New-TL1C1bUri c1 $runId $nonce;c2=New-TL1C1bUri c2 $runId $nonce;result=New-TL1C1bUri result $runId $nonce;abort=New-TL1C1bUri abort $runId $nonce}
    $endpointSetSha=Get-TL1C1aSha256Text (@($uris.GetEnumerator()|%{"$($_.Key)=$($_.Value)"})-join"`n")
    $sessionStarted=$true
    $write=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name content_t0 -Value $uris.t0 -InputBytes $t0Bytes -TimeoutSec 30
    if($write.Bytes.Length-or$write.Stderr.Length){throw 'C1b T0 write 不得返回伪 ACK。'}
    $start=Read-C1bControl content_status $uris.status;$generation=[long]$start.generation
    Assert-TL1C1bControlTuple $start ready_c1 capture_c1 $generation 0 0 @() $null
    Set-C1bAbortExpectedSnapshot $start
    if(-not$start.provider.a11y_service_ready-or$start.provider.version_name-cne$packageBefore.VersionName-or[long]$start.provider.version_code-ne$packageBefore.VersionCode){throw 'C1b provider/package/a11y 绑定失败。'}

    $captureWatch=[Diagnostics.Stopwatch]::StartNew();$c1Requested=Get-C1bTimestamp
    $c1Initial=Read-C1bControl content_c1 $uris.c1
    if($c1Initial.state-eq'ready_c2'){$c1Ready=$c1Initial}else{
        Assert-TL1C1bControlTuple $c1Initial capturing_c1 wait $generation 1 0 @() 'c1'
        Set-C1bAbortExpectedSnapshot $c1Initial
        $c1Ready=Wait-TL1C1bTerminalState -ExpectedState ready_c2 -Generation $generation -ReadStatus {Read-C1bControl content_status $uris.status}
    }
    Assert-TL1C1bControlTuple $c1Ready ready_c2 capture_c2 $generation 1 0 @('c1') $null;Set-C1bAbortExpectedSnapshot $c1Ready;$c1Committed=Get-C1bTimestamp
    $hostWait=[Diagnostics.Stopwatch]::StartNew();while($hostWait.ElapsedMilliseconds-lt900){Start-Sleep -Milliseconds ([Math]::Min(100,900-[int]$hostWait.ElapsedMilliseconds))};$hostWait.Stop()
    if($captureWatch.ElapsedMilliseconds-ge15000){throw 'C1b c2 前已越过总时序门。'}
    $c2Requested=Get-C1bTimestamp;$c2Initial=Read-C1bControl content_c2 $uris.c2
    if($c2Initial.state-eq'complete'){$complete=$c2Initial}else{
        Assert-TL1C1bControlTuple $c2Initial capturing_c2 wait $generation 1 1 @('c1') 'c2'
        Set-C1bAbortExpectedSnapshot $c2Initial
        $complete=Wait-TL1C1bTerminalState -ExpectedState complete -Generation $generation -ReadStatus {Read-C1bControl content_status $uris.status}
    }
    Assert-TL1C1bControlTuple $complete complete read_result $generation 1 1 @('c1','c2') $null;Set-C1bAbortExpectedSnapshot $complete;$c2Committed=Get-C1bTimestamp;$captureWatch.Stop()
    if($hostWait.ElapsedMilliseconds-lt900-or$captureWatch.ElapsedMilliseconds-gt15000){throw 'C1b 宿主时序越界。'}
    if($complete.provider.version_name-cne$packageBefore.VersionName-or[long]$complete.provider.version_code-ne$packageBefore.VersionCode){throw 'C1b provider/package 在 capture 后漂移。'}
    $result=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name content_result -Value $uris.result -TimeoutSec 30
    $observationRaw=ConvertFrom-TL1C1aStrictUtf8 $result.Bytes 'C1b observation'
    $observationIssues=[Collections.Generic.List[object]]::new();$observationObject=ConvertFrom-TL1C1BV1StrictJson $observationRaw $observationIssues
    if($null-eq$observationObject-or$observationIssues.Count-ne0-or$observationObject.run_id-cne$runId-or
        $observationObject.expected_title_hash-cne$script:TL1C1bExpectedTitleHash-or
        $observationObject.provenance.kind-cne'gateway_runtime_probe'-or$observationObject.provenance.producer_commit_sha-cne$ExpectedCommitSha-or
        $observationObject.provenance.producer_artifact_sha256-cne$expectedArtifactSha-or
        $observationObject.upstream_t0.source_kind-cne'trusted_runtime'-or$observationObject.upstream_t0.run_id-cne$runId-or
        $observationObject.upstream_t0.artifact_sha256-cne$t0Sha-or
        $observationObject.upstream_t0.producer_commit_sha-cne$script:TL1C1aT0Baseline-or
        $observationObject.upstream_t0.captured_at-cne$t0Object.captured_at_utc){throw 'C1b observation 与 provider/T0 独立锚点不一致。'}

    $postSerial=Get-TL1C1aSingleDevice $AdbPath;$postSerialHash=Get-TL1C1aSha256Text $postSerial
    $postBinding=Test-TL1C1aDeviceBinding (Invoke-TL1C1aAdb $AdbPath $serial fingerprint).Text (Invoke-TL1C1aAdb $AdbPath $serial boot_id).Text
    if($postSerial-cne$serial-or$postBinding.FingerprintHash-cne$preBinding.FingerprintHash-or$postBinding.BootIdHash-cne$preBinding.BootIdHash){throw 'C1b device binding 前后漂移。'}
    $adbTrustAfter=Get-TL1C1bAdbTrustBinding $AdbPath $env:ANDROID_SDK_ROOT $env:ANDROID_HOME
    if($adbTrustAfter.executable_sha256-cne$adbTrustBefore.executable_sha256-or$adbTrustAfter.version_output_sha256-cne$adbTrustBefore.version_output_sha256-or
       $adbTrustAfter.protocol_version-cne$adbTrustBefore.protocol_version-or$adbTrustAfter.package_version-cne$adbTrustBefore.package_version){throw 'C1b adb transport trust binding 前后漂移。'}
    $installedPathAfter=Get-TL1C1aInstalledApkPath (Invoke-TL1C1aAdb $AdbPath $serial package_path).Text
    $installedPathHashAfter=Get-TL1C1aSha256Text $installedPathAfter;$installedShaAfter=Get-TL1C1aInstalledApkHostSha256 $AdbPath $serial $installedPathAfter 180
    $localShaAfter=Get-TL1C1aFileSha256 $Apk;$packageAfter=Get-TL1C1aPackageBinding (Invoke-TL1C1aAdb $AdbPath $serial package_dump).Text
    if($installedPathAfter-cne$installedPathBefore-or$installedShaAfter-cne$installedShaBefore-or$localShaAfter-cne$expectedArtifactSha-or
        $packageAfter.PackageName-cne$packageBefore.PackageName-or$packageAfter.VersionName-cne$packageBefore.VersionName-or$packageAfter.VersionCode-ne$packageBefore.VersionCode){throw 'C1b APK/package 前后漂移。'}
    $secrets=@($serial,$nonce,$buildChallenge);Assert-TL1C1aNoRawSecret $observationRaw $secrets
    $observationPath=Join-Path $c1bDirectory 'tablet-layout-observation-c1b-v1.json';[void](Write-TL1C1aBytesAtomic $RepoRoot $observationPath $result.Bytes);$observationSha=Get-TL1C1aFileSha256 $observationPath
    $validation=Test-TabletLayoutObservationC1BV1TrustedRuntimeFile $observationPath $c1bDirectory $runId $ExpectedCommitSha $expectedArtifactSha
    if(-not$validation.fixture_contract_valid-or-not$validation.runtime_binding_inputs_match-or$validation.runtime_origin_verified-or$validation.runtime_evidence-or$validation.layout_accepted-or$validation.execution_grant){throw 'C1b observation validator scope/binding 失败。'}
    $validationPath=Join-Path $c1bDirectory 'tablet-layout-observation-validation-c1b-v1.json';$validationRaw=$validation|ConvertTo-Json -Depth 40 -Compress;Assert-TL1C1aNoRawSecret $validationRaw $secrets
    $validationBytes=[Text.UTF8Encoding]::new($false).GetBytes($validationRaw);try{[void](Write-TL1C1aBytesAtomic $RepoRoot $validationPath $validationBytes)}finally{[Array]::Clear($validationBytes,0,$validationBytes.Length)};$validationSha=Get-TL1C1aFileSha256 $validationPath
    Assert-C1bFrozenState
    # /result 也可能合法返回 control 且不消费 provider session；只有 observation 的 exact
    # bytes 已经通过 strict parse、独立锚点、schema/validator 与冻结绑定后才视为已消费。
    $sessionConsumed=$true

    $sidecar=[ordered]@{schema=$script:TL1C1bSidecarSchema;run_id=$runId;completed_at_utc=Get-C1bTimestamp;expected_commit_sha=$ExpectedCommitSha;capture_scope='pure_a11y'
        provenance_strategy='clean_content_provider_independently_attested';static_read_only_policy_version='tl1-c1b-read-only/v1';implementation_hashes=$implementationHashes
        transport=[ordered]@{trust_root=$adbTrustBefore.trust_root;canonical_relative_path=$adbTrustBefore.canonical_relative_path;sdk_roots_equal=$true;executable_sha256_before=$adbTrustBefore.executable_sha256;executable_sha256_after=$adbTrustAfter.executable_sha256;version_output_sha256_before=$adbTrustBefore.version_output_sha256;version_output_sha256_after=$adbTrustAfter.version_output_sha256;protocol_version=$adbTrustBefore.protocol_version;package_version=$adbTrustBefore.package_version;installed_as_canonical=$true}
        apk=[ordered]@{fresh_build=$true;install_attempt_count=1;uninstall_count=0;automatic_retry_count=0;local_sha256_before=$expectedArtifactSha;local_sha256_after=$localShaAfter
            installed_base_apk_path_hash_before=$installedPathHashBefore;installed_base_apk_path_hash_after=$installedPathHashAfter;installed_base_apk_sha256_before=$installedShaBefore;installed_base_apk_sha256_after=$installedShaAfter
            signer_certificate_sha256=$signerSha;package_name_before=$packageBefore.PackageName;package_name_after=$packageAfter.PackageName;version_name_before=$packageBefore.VersionName;version_name_after=$packageAfter.VersionName;version_code_before=$packageBefore.VersionCode;version_code_after=$packageAfter.VersionCode}
        device=[ordered]@{serial_hash_before=$serialHash;serial_hash_after=$postSerialHash;fingerprint_hash_before=$preBinding.FingerprintHash;fingerprint_hash_after=$postBinding.FingerprintHash;boot_id_hash_before=$preBinding.BootIdHash;boot_id_hash_after=$postBinding.BootIdHash;unique_device_before_after=$true}
        upstream_t0=[ordered]@{producer_commit_sha='4ca32b131007df58f7752c5ee9b2d049cb1cd54e';original_relative_path=$t0SourceRelative;original_sha256=$t0Sha;original_byte_count=$t0Bytes.Length;original_crlf_count=$crlf;original_bytes_forwarded=$true;exec_in_write_count=1;device_binding_verified=$true}
        provider=[ordered]@{authority=$script:TL1C1bAuthority;protocol_version='1';package_name=$complete.provider.package_name;version_name=$complete.provider.version_name;version_code=$complete.provider.version_code;embedded_git_head=$complete.provider.embedded_git_head
            build_challenge_hash=Get-TL1C1aSha256Text $buildChallenge;expected_title_hash=$script:TL1C1bExpectedTitleHash;producer_artifact_sha256=$expectedArtifactSha;a11y_service_ready=$true;control_transcript_sha256=Get-TL1C1bTranscriptSha256 $controlRaw.ToArray();endpoint_set_sha256=$endpointSetSha}
        capture=[ordered]@{generation=$generation;c1_requested_at_utc=$c1Requested;c1_committed_at_utc=$c1Committed;c2_requested_at_utc=$c2Requested;c2_committed_at_utc=$c2Committed;host_wait_ms=[long]$hostWait.ElapsedMilliseconds;total_span_ms=[long]$captureWatch.ElapsedMilliseconds;status_poll_count=$statusReadCount;c1_requests_accepted=1;c2_requests_accepted=1;result_read_count=1;recapture_count=0}
        artifacts=[ordered]@{upstream_t0=[ordered]@{relative_path='upstream-t0-v5.json';sha256=$t0Sha};observation=[ordered]@{relative_path='tablet-layout-observation-c1b-v1.json';sha256=$observationSha};validation=[ordered]@{relative_path='tablet-layout-observation-validation-c1b-v1.json';sha256=$validationSha}}
        read_only_counts=[ordered]@{a11y_frame_capture_count=2;recapture_count=0;display_screenshot_call_count=0;window_screenshot_call_count=0;ocr_invocation_count=0;action_call_count=0;gesture_call_count=0;input_call_count=0;settings_mutation_count=0;target_app_start_count=0;mcp_call_count=0;dispatch_call_count=0}
        attestations=[ordered]@{full_clean_head_verified=$true;implementation_hashes_verified=$true;origin_binding_verified=$true;probe_entrypoint_read_only=$true;observation_schema_valid=$true;artifact_hashes_recomputed=$true}
        claims=[ordered]@{runtime_origin_verified=$true;runtime_evidence=$true;wechat_window_ownership_observed=[bool]$validation.wechat_window_ownership_observed;wechat_window_ownership_verified=[bool]$validation.wechat_window_ownership_observed
            window_root_projection_observed=[bool]$validation.window_root_projection_observed;window_root_projection_verified=[bool]$validation.window_root_projection_observed;application_window_topology_observed=[bool]$validation.application_window_topology_observed;application_window_topology_verified=[bool]$validation.application_window_topology_observed
            ime_hidden_observed=[bool]$validation.ime_hidden_observed;ime_hidden_verified=[bool]$validation.ime_hidden_observed;semantic_tree_usable=[bool]$validation.semantic_tree_usable;navigation_pane_verified=$false;conversation_pane_verified=$false;target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}
        cleanup=[ordered]@{required=$false;status='not_required';abort_attempt_count=0}}
    Assert-TL1C1bSidecarCrossBindings $sidecar
    $artifactMap=@{$t0Source=$t0Sha;$t0Path=$t0Sha;$observationPath=$observationSha;$validationPath=$validationSha};Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap
    $sidecarRaw=$sidecar|ConvertTo-Json -Depth 40 -Compress;Assert-TL1C1aNoRawSecret $sidecarRaw $secrets
    if(-not($sidecarRaw|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)){throw 'C1b success sidecar schema 失败。'}
    $sidecarPath=Join-Path $c1bDirectory 'tablet-layout-c1b-sidecar-v1.json';$sidecarBytes=[Text.UTF8Encoding]::new($false).GetBytes($sidecarRaw)
    try{[void](Write-TL1C1aBytesAtomic $RepoRoot $sidecarPath $sidecarBytes -PostWriteValidation {
        Assert-C1bFrozenState;Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap
        $publishedAdbTrust=Get-TL1C1bAdbTrustBinding $AdbPath $env:ANDROID_SDK_ROOT $env:ANDROID_HOME
        if($publishedAdbTrust.executable_sha256-cne$adbTrustBefore.executable_sha256-or$publishedAdbTrust.version_output_sha256-cne$adbTrustBefore.version_output_sha256){throw 'C1b published sidecar adb trust binding 漂移。'}
        $publishedPath=Assert-TL1C1aOrdinaryPath $RepoRoot $sidecarPath
        $publishedBytes=[IO.File]::ReadAllBytes($publishedPath);$publishedRaw=ConvertFrom-TL1C1aStrictUtf8 $publishedBytes 'C1b published sidecar'
        try{
            $published=ConvertFrom-TL1C1bClosedJson $publishedRaw
            if($null-eq$published-or-not($publishedRaw|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)){throw 'C1b published sidecar strict/schema readback 失败。'}
            Assert-TL1C1bSidecarCrossBindings $published;Assert-TL1C1aNoRawSecret $publishedRaw $secrets
            Assert-C1bFrozenState;Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap
        }finally{if($publishedBytes.Length){[Array]::Clear($publishedBytes,0,$publishedBytes.Length)}}
    })}finally{[Array]::Clear($sidecarBytes,0,$sidecarBytes.Length)}
    Write-Host "T-L1 C1b 受控只读采集完成：$sidecarPath";exit 0
}catch{$failure=$_.Exception.Message}
finally{
    if($sessionStarted-and-not$sessionConsumed-and-not$abortAttempted-and$serial-and$nonce){$abortAttempted=$true;try{$abort=Read-C1bControl content_abort $uris.abort;Assert-TL1C1bAbortTerminalControl $abort $abortExpectedGeneration $abortExpectedC1Count $abortExpectedC2Count $abortExpectedCommitted;$abortSucceeded=$true}catch{$abortSucceeded=$false}}
}
try{Write-C1bFailureEvidence 'c1b_runner_failed'}catch{if($failure){$failure+='；且 failure evidence 写入失败。'}else{$failure='C1b failure evidence 写入失败。'}}
[Console]::Error.WriteLine("T-L1 C1b 失败：$failure");exit 1
