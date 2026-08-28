#Requires -Version 7.5
# T-L1 C1b v1 宿主侧闭合协议与独立来源绑定。设备/进程原语复用冻结的 C1a library。

Set-StrictMode -Version 3.0

$script:TL1C1bAuthority = 'dev.magina.gateway.tablet.c1b'
$script:TL1C1bProtocolSchema = 'tablet-c1b-control/v1'
$script:TL1C1bSidecarSchema = 'tablet-layout-c1b-sidecar/v1'
$script:TL1C1bObservationSchema = 'tablet-layout-observation/c1b-v1'
$script:TL1C1bPackageName = 'dev.magina.gateway'
$script:TL1C1bExpectedTitleHash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
$script:TL1C1bGoogleAdbSignerSubject = 'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US, SERIALNUMBER=3582691, OID.2.5.4.15=Private Organization, OID.1.3.6.1.4.1.311.60.2.1.2=Delaware, OID.1.3.6.1.4.1.311.60.2.1.3=US'
$script:TL1C1bImplementationPathMap = [ordered]@{
    runner_sha256='scripts/run-tablet-layout-c1b.ps1'
    c1b_library_sha256='scripts/lib/tablet-layout-c1b.ps1'
    c1b_read_only_library_sha256='scripts/lib/tablet-layout-c1b-readonly.ps1'
    c1b_artifact_proof_library_sha256='scripts/lib/tablet-layout-c1b-artifact-proof.ps1'
    c1b_aapt2_library_sha256='scripts/lib/tablet-layout-c1b-aapt2.ps1'
    c1b_build_environment_library_sha256='scripts/lib/tablet-layout-c1b-build-env.ps1'
    c1b_adb_server_library_sha256='scripts/lib/tablet-layout-c1b-adb-server.ps1'
    dispatch_lock_library_sha256='scripts/lib/dispatch-lock.ps1'
    c1a_low_level_library_sha256='scripts/lib/tablet-layout-c1a.ps1'
    t0_runner_sha256='scripts/run-tablet-intake.ps1'
    t0_library_sha256='scripts/lib/tablet-intake.ps1'
    t0_adb_sidecar_cmd_sha256='scripts/lib/tablet-layout-c1a-t0-adb-sidecar.cmd'
    t0_adb_sidecar_script_sha256='scripts/lib/tablet-layout-c1a-t0-adb-sidecar.ps1'
    validator_sha256='scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1'
    native_path_validator_sha256='scripts/lib/tablet-layout-observation-v2-validator.ps1'
    observation_schema_sha256='docs/contracts/tablet-layout-observation-c1b-v1.schema.json'
    sidecar_schema_sha256='docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json'
    artifact_proof_schema_sha256='docs/contracts/tablet-c1b-read-only-artifact-proof-v1.schema.json'
    android_layout_probe_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt'
    android_layout_probe_model_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt'
    android_model_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt'
    android_probe_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt'
    android_source_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt'
    android_provider_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt'
    android_protocol_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bProtocol.kt'
    android_coordinator_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator.kt'
    android_controller_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController.kt'
    android_context_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory.kt'
    android_pending_registry_sha256='app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry.kt'
    app_build_gradle_sha256='app/build.gradle.kts'
    app_settings_gradle_sha256='app/settings.gradle.kts'
    app_gradle_properties_sha256='app/gradle.properties'
    app_gradlew_bat_sha256='app/gradlew.bat'
    app_gradle_wrapper_jar_sha256='app/gradle/wrapper/gradle-wrapper.jar'
    app_gradle_wrapper_properties_sha256='app/gradle/wrapper/gradle-wrapper.properties'
    app_gradle_verification_metadata_sha256='app/gradle/verification-metadata.xml'
    probe_build_gradle_sha256='app/tablet-c1b-probe/build.gradle.kts'
    probe_manifest_sha256='app/tablet-c1b-probe/src/main/AndroidManifest.xml'
    probe_service_sha256='app/tablet-c1b-probe/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt'
    probe_a11y_config_sha256='app/tablet-c1b-probe/src/main/res/xml/a11y_config.xml'
    probe_strings_sha256='app/tablet-c1b-probe/src/main/res/values/strings.xml'
}
$script:TL1C1bRequiredOfflineCoverage = [string[]]@(
    'canonical_uri','fake_adb_exec_in_exact_bytes','fake_adb_read_quoting','control_exact_schema',
    'provider_provenance','replay_rejection','duplicate_capture_rejection','recapture_rejection',
    'bounded_status_success','bounded_status_timeout','host_wait_900ms','single_c1_c2_result',
    'single_install_no_retry_uninstall','controlled_path_hash','sidecar_closed_schema','sidecar_cross_binding',
    'release_debug_boundary','validator_origin_scope','failure_atomic_cleanup','abort_terminal_control_closed',
    'summary_deception_rejection','sdk_adb_trust_root','runner_e2e_success','runner_e2e_result_control_abort',
    'runner_e2e_malformed_abort_fail_closed','runner_e2e_tamper_abort'
)

if($null-eq('TL1C1bFileIdentity'-as[type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bFileIdentityResult {
    public uint LinkCount { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bFileIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    public static TL1C1bFileIdentityResult Read(SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return new TL1C1bFileIdentityResult {
            LinkCount = information.NumberOfLinks,
            StableId = information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") +
                information.FileIndexLow.ToString("X8")
        };
    }
}
'@
}

function Test-TL1C1bGoogleAdbSignerSubject {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Subject)
    return $Subject-ceq$script:TL1C1bGoogleAdbSignerSubject
}

function Open-TL1C1bAdbTrustGuard {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome
    )
    if(-not[IO.Path]::IsPathFullyQualified($AdbPath)-or-not[IO.Path]::IsPathFullyQualified($AndroidSdkRoot)-or-not[IO.Path]::IsPathFullyQualified($AndroidHome)){throw 'C1b adb 与 Android SDK trust root 必须是绝对路径。'}
    $sdk=[IO.Path]::GetFullPath($AndroidSdkRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sdkHomeFull=[IO.Path]::GetFullPath($AndroidHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if($sdk-cne$sdkHomeFull){throw 'C1b ANDROID_SDK_ROOT/ANDROID_HOME trust root 不一致。'}
    $platformTools=Join-Path $sdk 'platform-tools';$canonical=[IO.Path]::GetFullPath((Join-Path $platformTools 'adb.exe'))
    foreach($directory in @($sdk,$platformTools)){
        $directoryItem=Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if(-not$directoryItem.PSIsContainer-or($directoryItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or
           -not[string]::IsNullOrWhiteSpace([string]$directoryItem.LinkType)){throw 'C1b Android SDK trust root 非 ordinary directory。'}
    }
    $actual=[IO.Path]::GetFullPath($AdbPath)
    $actualItem=Get-Item -LiteralPath $actual -Force -ErrorAction Stop
    if($actual-cne$canonical-or$actualItem.PSIsContainer-or
       ($actualItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0-or
       ((-not[string]::IsNullOrWhiteSpace([string]$actualItem.LinkType))-and[string]$actualItem.LinkType-cne'HardLink')){
        throw 'C1b adb 必须是 canonical Android SDK platform-tools/adb.exe ordinary file。'
    }
    $guard=[IO.File]::Open($actual,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $identity=[TL1C1bFileIdentity]::Read($guard.SafeFileHandle)
        if($identity.LinkCount-ne1){throw 'C1b adb hardlink count 必须 exact 1。'}
        $signature=Get-AuthenticodeSignature -LiteralPath $actual
        if([string]$signature.Status-cne'Valid'-or$null-eq$signature.SignerCertificate){
            throw 'C1b adb Authenticode/OS trust 必须是 Valid。'
        }
        $certificate=$signature.SignerCertificate
        $subject=[string]$certificate.Subject
        if(-not(Test-TL1C1bGoogleAdbSignerSubject $subject)){
            throw 'C1b adb Authenticode signer 必须精确是 Google LLC。'
        }
        $certificateBytes=[byte[]]$certificate.RawData
        try{$certificateSha256=Get-TL1C1aSha256Bytes $certificateBytes}
        finally{if($certificateBytes.Length-ne0){[Array]::Clear($certificateBytes,0,$certificateBytes.Length)}}
        $guard.Position=0
        $executableSha256='sha256:'+[Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($guard)).ToLowerInvariant()
        $guard.Position=0
        return [pscustomobject][ordered]@{
            Guard=$guard;CanonicalPath=$canonical;FileIdentity=$identity.StableId
            ExecutableSha256=$executableSha256;SignatureStatus='Valid'
            SignatureSubject=$subject;SignatureCertificateSha256=$certificateSha256
        }
    }catch{$guard.Dispose();throw}
}

function Get-TL1C1bAdbTrustBinding {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome,
        [hashtable]$ProcessEnvironment,
        [switch]$ClearEnvironment
    )
    $fileTrust=Open-TL1C1bAdbTrustGuard $AdbPath $AndroidSdkRoot $AndroidHome
    try{
        # version 只能在 ordinary path/hardlink/OS trust/Google signer 全部成功后执行；
        # guard 一直持有 deny-write/delete，不给验签后替换可执行体的窗口。
        $version=Invoke-TL1C1aProcess -FilePath $fileTrust.CanonicalPath -Arguments @('version') -Operation 'C1b adb trust identity' -TimeoutSec 10 `
            -Environment $ProcessEnvironment -ClearEnvironment:$ClearEnvironment
        if($version.Stderr.Length-ne0){throw 'C1b adb version stderr 必须 exact empty。'}
        $lines=@($version.Text-split'\r?\n'|Where-Object{$_.Length-ne0})
        if($lines.Count-lt3-or$lines.Count-gt4-or$lines[0]-cnotmatch'^Android Debug Bridge version ([0-9]+\.[0-9]+\.[0-9]+)$'-or
           $lines[1]-cnotmatch'^Version ([A-Za-z0-9][A-Za-z0-9._-]{0,79})$'-or$lines[2]-cnotmatch'^Installed as (.+)$'){
            throw 'C1b adb version identity grammar 错误。'
        }
        if([IO.Path]::GetFullPath($Matches[1])-cne$fileTrust.CanonicalPath){throw 'C1b adb version Installed-as 未绑定 canonical executable。'}
        return [ordered]@{trust_root='android_sdk_platform_tools';canonical_relative_path='platform-tools/adb.exe';sdk_roots_equal=$true
            executable_sha256=$fileTrust.ExecutableSha256;version_output_sha256=Get-TL1C1aSha256Bytes $version.Bytes
            signature_status=$fileTrust.SignatureStatus;signature_subject=$fileTrust.SignatureSubject
            signature_certificate_sha256=$fileTrust.SignatureCertificateSha256
            protocol_version=([regex]::Match($lines[0],'^Android Debug Bridge version (.+)$').Groups[1].Value)
            package_version=([regex]::Match($lines[1],'^Version (.+)$').Groups[1].Value);installed_as_canonical=$true}
    }finally{$fileTrust.Guard.Dispose()}
}

function New-TL1C1bUri {
    param(
        [Parameter(Mandatory)][ValidateSet('t0','status','c1','c2','result','abort')][string]$Endpoint,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Nonce,
        [string]$ExpectedCommitSha,
        [string]$ArtifactSha256
    )
    if ($RunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { throw 'C1b run_id 格式错误。' }
    if ($Nonce -cnotmatch '^n-[0-9a-f]{32}$') { throw 'C1b nonce 格式错误。' }
    $path = switch ($Endpoint) {
        't0' { "/t0/$RunId" }
        'status' { "/status/$RunId" }
        'c1' { "/capture/c1/$RunId" }
        'c2' { "/capture/c2/$RunId" }
        'result' { "/result/$RunId" }
        'abort' { "/abort/$RunId" }
    }
    $query = [Collections.Generic.List[string]]::new()
    $query.Add("nonce=$Nonce")
    if ($Endpoint -eq 't0') {
        if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
            $ArtifactSha256 -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'C1b T0 URI provenance 参数错误。' }
        $query.Add("title_hash=$script:TL1C1bExpectedTitleHash")
        $query.Add("producer_commit_sha=$ExpectedCommitSha")
        $query.Add("producer_artifact_sha256=$ArtifactSha256")
    }
    return "content://$script:TL1C1bAuthority${path}?" + ($query -join '&')
}

function ConvertTo-TL1C1bContentUriArgument {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][bool]$BinaryStdin
    )
    $runPattern='[a-z0-9][a-z0-9._-]{0,79}';$noncePattern='n-[0-9a-f]{32}'
    $pathPattern=switch($Name){
        content_t0{"t0/$runPattern"};content_status{"status/$runPattern"};content_c1{"capture/c1/$runPattern"}
        content_c2{"capture/c2/$runPattern"};content_result{"result/$runPattern"};content_abort{"abort/$runPattern"}
    }
    $queryPattern=if($Name-ceq'content_t0'){
        'nonce='+$noncePattern+'&title_hash='+[regex]::Escape($script:TL1C1bExpectedTitleHash)+
        '&producer_commit_sha=[0-9a-f]{40}&producer_artifact_sha256=sha256:[0-9a-f]{64}'
    }else{'nonce='+$noncePattern}
    $expected='^content://'+[regex]::Escape($script:TL1C1bAuthority)+'/'+$pathPattern+'\?'+$queryPattern+'$'
    if($Uri-cnotmatch$expected-or$Uri-match"['\x00-\x20\x7f%+]"){throw 'C1b Content URI 不符合 fixed closed grammar。'}
    if(($Name-ceq'content_t0')-ne$BinaryStdin){throw 'C1b Content URI transport 与 endpoint 不一致。'}
    if($BinaryStdin){return $Uri};return "'$Uri'"
}

function Invoke-TL1C1bAdb {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][ValidateSet(
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [Parameter(Mandatory)][string]$Value,
        [byte[]]$InputBytes,
        [int]$TimeoutSec=30,
        [hashtable]$ProcessEnvironment,
        [switch]$ClearEnvironment,
        [AllowNull()]$PrivateAdbServerGuard
    )
    $argument=ConvertTo-TL1C1bContentUriArgument -Name $Name -Uri $Value -BinaryStdin:($Name-ceq'content_t0')
    $tail=switch($Name){
        content_t0{@('exec-in','content','write','--uri',$argument)}
        content_status{@('shell','content','read','--uri',$argument)}
        content_c1{@('shell','content','read','--uri',$argument)}
        content_c2{@('shell','content','read','--uri',$argument)}
        content_result{@('shell','content','read','--uri',$argument)}
        content_abort{@('shell','content','read','--uri',$argument)}
    }
    $clientArguments=Get-TL1C1aAdbClientArguments $ProcessEnvironment
    if(@($clientArguments).Count-ne0){
        if($null-eq$PrivateAdbServerGuard){throw 'private ADB endpoint 必须提供 server Guard。'}
        $result=Invoke-TL1C1bPrivateAdbGuardedProcess `
            -Guard $PrivateAdbServerGuard -FilePath $AdbPath `
            -Arguments ($clientArguments+@('-s',$Serial)+$tail) `
            -Operation "C1b adb/$Name" -InputBytes $InputBytes `
            -ProcessEnvironment $ProcessEnvironment -ClearEnvironment:$ClearEnvironment `
            -TimeoutSec $TimeoutSec -ClientKind Adb
    }else{
        if($null-ne$PrivateAdbServerGuard){throw 'server Guard 不得绑定非 private ADB endpoint。'}
        $result=Invoke-TL1C1aProcess -FilePath $AdbPath `
            -Arguments ($clientArguments+@('-s',$Serial)+$tail) `
            -Operation "C1b adb/$Name" -InputBytes $InputBytes -TimeoutSec $TimeoutSec `
            -Environment $ProcessEnvironment -ClearEnvironment:$ClearEnvironment
    }
    if($result.Stderr.Length-ne0){throw "C1b adb/$Name stderr 必须 exact empty。"}
    return $result
}

function Assert-TL1C1bExactObjectKeys {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string[]]$Expected,[string]$Name='object')
    if ($Value -isnot [pscustomobject]) { throw "C1b $Name 必须是 JSON object。" }
    $actual = [string[]]@($Value.PSObject.Properties.Name)
    $copy = [string[]]@($Expected)
    [Array]::Sort($actual,[StringComparer]::Ordinal); [Array]::Sort($copy,[StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($copy -join "`n")) { throw "C1b $Name 字段集合漂移。" }
}

function ConvertFrom-TL1C1bClosedJson {
    param([Parameter(Mandatory)][string]$Raw)
    $document=$null
    try{
        $document=[Text.Json.JsonDocument]::Parse($Raw)
        $duplicates=[Collections.Generic.List[string]]::new();Find-TL1C1BV1DuplicateJsonProperty $document.RootElement '' $duplicates
        $invalidNumbers=[Collections.Generic.List[string]]::new();Find-TL1C1BV1InvalidNumber $document.RootElement '' $invalidNumbers
        if($duplicates.Count-ne0-or$invalidNumbers.Count-ne0){throw 'C1b closed JSON 含 duplicate key 或非 Int64 number。'}
        return $Raw|ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    }catch{throw 'C1b closed JSON strict parse 失败。'}finally{if($null-ne$document){$document.Dispose()}}
}

function ConvertFrom-TL1C1bControl {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$BuildChallenge
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt 65536 -or $Raw -match '[\r\n]') {
        throw 'C1b control 必须是 64 KiB 内单行 JSON。'
    }
    $issues = [Collections.Generic.List[object]]::new()
    $value = ConvertFrom-TL1C1BV1StrictJson $Raw $issues
    if ($null -eq $value -or $issues.Count -ne 0) { throw 'C1b control 不是 strict JSON。' }
    Assert-TL1C1bExactObjectKeys $value @(
        'schema','ok','run_id','generation','state','next','reason_code','in_flight_token',
        'c1_requests_accepted','c2_requests_accepted','committed_tokens','recapture_count',
        'expected_title_hash','producer_commit_sha','producer_artifact_sha256','provider'
    ) 'control'
    Assert-TL1C1bExactObjectKeys $value.provider @(
        'authority','protocol_version','package_name','version_name','version_code',
        'embedded_git_head','build_challenge','a11y_service_ready'
    ) 'control/provider'
    foreach ($name in @('schema','run_id','state','next')) {
        if ($value.$name -isnot [string]) { throw "C1b control/$name 类型错误。" }
    }
    foreach ($name in @('reason_code','in_flight_token','expected_title_hash','producer_commit_sha','producer_artifact_sha256')) {
        if ($null -ne $value.$name -and $value.$name -isnot [string]) { throw "C1b control/$name 类型错误。" }
    }
    foreach ($name in @('generation','c1_requests_accepted','c2_requests_accepted','recapture_count')) {
        if ($value.$name -isnot [long]) { throw "C1b control/$name 类型错误。" }
    }
    if ($value.ok -isnot [bool] -or $value.committed_tokens -isnot [object[]]) { throw 'C1b control scalar/list 类型错误。' }
    foreach ($token in @($value.committed_tokens)) { if ($token -isnot [string]) { throw 'C1b committed token 类型错误。' } }
    foreach ($name in @('authority','protocol_version','package_name','version_name','embedded_git_head','build_challenge')) {
        if ($value.provider.$name -isnot [string]) { throw "C1b provider/$name 类型错误。" }
    }
    if ($value.provider.version_code -isnot [long] -or $value.provider.a11y_service_ready -isnot [bool]) {
        throw 'C1b provider scalar 类型错误。'
    }
    if ($value.schema -cne $script:TL1C1bProtocolSchema -or $value.run_id -cne $RunId -or
        $value.recapture_count -ne 0 -or $value.provider.authority -cne $script:TL1C1bAuthority -or
        $value.provider.protocol_version -cne '1' -or $value.provider.package_name -cne $script:TL1C1bPackageName -or
        $value.provider.embedded_git_head -cne $ExpectedCommitSha -or
        $value.provider.build_challenge -cne $BuildChallenge -or
        $value.provider.version_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $value.provider.version_code -lt 1) { throw 'C1b control provider/build 绑定失败。' }
    if ($value.state -eq 'absent') {
        if ($null -ne $value.expected_title_hash -or $null -ne $value.producer_commit_sha -or
            $null -ne $value.producer_artifact_sha256) { throw 'C1b absent control 夹带 producer binding。' }
    } elseif ($value.expected_title_hash -cne $script:TL1C1bExpectedTitleHash -or
        $value.producer_commit_sha -cne $ExpectedCommitSha -or
        $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256) {
        throw 'C1b control producer binding 失败。'
    }
    return $value
}

function Assert-TL1C1bControlTuple {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][string]$ExpectedState,
        [Parameter(Mandatory)][string]$ExpectedNext,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][int]$C1Count,
        [Parameter(Mandatory)][int]$C2Count,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Committed,
        [AllowNull()][object]$InFlight
    )
    if ($null -ne $InFlight -and $InFlight -cnotin @('c1','c2')) { throw 'C1b expected in-flight token 错误。' }
    if ($Control.ok -ne ($ExpectedState -in @('ready_c1','capturing_c1','ready_c2','capturing_c2','complete')) -or
        $Control.state -cne $ExpectedState -or $Control.next -cne $ExpectedNext -or
        [long]$Control.generation -ne $Generation -or [long]$Control.c1_requests_accepted -ne $C1Count -or
        [long]$Control.c2_requests_accepted -ne $C2Count -or $Control.in_flight_token -cne $InFlight -or
        [long]$Control.recapture_count -ne 0 -or
        $null -ne $Control.reason_code -or (@($Control.committed_tokens) -join "`n") -cne ($Committed -join "`n")) {
        throw 'C1b control state/counter/prefix tuple 不一致。'
    }
}

function Assert-TL1C1bAbortTerminalControl {
    param(
        [Parameter(Mandatory)]$Control,
        [Parameter(Mandatory)][long]$ExpectedGeneration,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$ExpectedC1Count,
        [Parameter(Mandatory)][ValidateRange(0,1)][int]$ExpectedC2Count,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedCommitted
    )
    $expectedTuple="$ExpectedC1Count|$ExpectedC2Count|$($ExpectedCommitted-join',')"
    if($ExpectedGeneration-lt0-or$expectedTuple-cnotin@('0|0|','1|0|','1|0|c1','1|1|c1','1|1|c1,c2')){
        throw 'C1b abort 发起前 snapshot 不在闭合 prefix。'
    }
    $reasonAllowed=switch([string]$Control.state){
        absent {@('coordinator_closed','nonce_reused','replay_ledger_full','run_id_reused','session_not_found')}
        failed {@('a11y_service_replaced','a11y_service_unavailable','build_identity_mismatch','capture_c1_failed','capture_c1_timeout','capture_c2_failed','capture_c2_timeout','capture_sequence_invalid','capture_timeout_scheduler_rejected','capture_worker_inline','capture_worker_rejected','observation_assembly_failed','session_expiry_scheduler_rejected','start_replayed','t0_invalid')}
        aborted {@('coordinator_shutdown','session_aborted')}
        expired {@('session_expired')}
        default {throw 'C1b abort 未进入允许终态。'}
    }
    if(($Control.state-cin@('failed','aborted')-and$expectedTuple-ceq'1|1|c1,c2')-or
        ($Control.state-ceq'expired'-and$ExpectedGeneration-lt1)){
        throw 'C1b abort terminal state/prefix 组合不在 producer 协议内。'
    }
    if($Control.ok-or$Control.next-cne'none'-or$null-ne$Control.in_flight_token-or
        [long]$Control.recapture_count-ne0-or$Control.reason_code-isnot[string]-or
        $reasonAllowed-cnotcontains[string]$Control.reason_code){
        throw 'C1b abort terminal scalar/reason tuple 不闭合。'
    }
    if($Control.state-ceq'absent'){
        if([long]$Control.generation-ne0-or[long]$Control.c1_requests_accepted-ne0-or
            [long]$Control.c2_requests_accepted-ne0-or@($Control.committed_tokens).Count-ne0){
            throw 'C1b absent abort 必须是 exact empty/reset tuple。'
        }
        return
    }
    if([long]$Control.generation-ne$ExpectedGeneration-or
        [long]$Control.c1_requests_accepted-ne$ExpectedC1Count-or
        [long]$Control.c2_requests_accepted-ne$ExpectedC2Count-or
        (@($Control.committed_tokens)-join"`n")-cne($ExpectedCommitted-join"`n")){
        throw 'C1b abort terminal 未绑定发起前 trusted snapshot。'
    }
}

function Wait-TL1C1bTerminalState {
    param(
        [Parameter(Mandatory)][scriptblock]$ReadStatus,
        [Parameter(Mandatory)][ValidateSet('ready_c2','complete')][string]$ExpectedState,
        [Parameter(Mandatory)][long]$Generation,
        [int]$MaximumPolls = 40,
        [int]$PollMilliseconds = 100,
        [scriptblock]$Sleep = { param($ms) Start-Sleep -Milliseconds $ms }
    )
    if ($MaximumPolls -notin 1..100 -or $PollMilliseconds -notin 10..1000) { throw 'C1b poll 边界错误。' }
    $capturingState = if ($ExpectedState -eq 'ready_c2') { 'capturing_c1' } else { 'capturing_c2' }
    for ($index=0; $index -lt $MaximumPolls; $index++) {
        $control = & $ReadStatus
        if ($control.state -ceq $ExpectedState) {
            if ($ExpectedState -eq 'ready_c2') {
                Assert-TL1C1bControlTuple $control ready_c2 capture_c2 $Generation 1 0 @('c1') $null
            } else {
                Assert-TL1C1bControlTuple $control complete read_result $Generation 1 1 @('c1','c2') $null
            }
            return $control
        }
        if ($control.state -cne $capturingState) { throw "C1b status 提前终止：$($control.state)/$($control.reason_code)。" }
        if ($capturingState -eq 'capturing_c1') {
            Assert-TL1C1bControlTuple $control capturing_c1 wait $Generation 1 0 @() 'c1'
        } else {
            Assert-TL1C1bControlTuple $control capturing_c2 wait $Generation 1 1 @('c1') 'c2'
        }
        if ($index + 1 -lt $MaximumPolls) { & $Sleep $PollMilliseconds }
    }
    throw "C1b status bounded poll 超时：$ExpectedState。"
}

function Get-TL1C1bTranscriptSha256 {
    param([Parameter(Mandatory)][string[]]$RawControls)
    if ($RawControls.Count -lt 3 -or $RawControls.Count -gt 100 -or @($RawControls | Where-Object { $_ -match '[\r\n]' }).Count) {
        throw 'C1b control transcript 数量或格式错误。'
    }
    return Get-TL1C1aSha256Text ($RawControls -join "`n")
}

function Assert-TL1C1bPublishedEvidenceBinding {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Artifacts
    )
    foreach ($entry in $Artifacts.GetEnumerator()) {
        $path = Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path ([string]$entry.Key)
        if ((Get-TL1C1aFileSha256 $path) -cne [string]$entry.Value) { throw "C1b published artifact 漂移：$path。" }
    }
}

function Get-TL1C1bImplementationCatalogSha256 {
    param([Parameter(Mandatory)]$ImplementationHashes)

    $entries=[Collections.Generic.List[object]]::new()
    if($ImplementationHashes-is[Collections.IDictionary]){
        foreach($entry in $ImplementationHashes.GetEnumerator()){
            $entries.Add([pscustomobject]@{Key=[string]$entry.Key;Value=[string]$entry.Value})
        }
    }else{
        foreach($property in $ImplementationHashes.PSObject.Properties){
            $entries.Add([pscustomobject]@{Key=[string]$property.Name;Value=[string]$property.Value})
        }
    }
    if($entries.Count-ne$script:TL1C1bImplementationPathMap.Count){
        throw 'C1b implementation catalog 字段数漂移。'
    }
    $actual=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($entry in $entries){
        if(-not$actual.TryAdd($entry.Key,$entry.Value)){throw 'C1b implementation catalog 字段重复。'}
    }
    $lines=[Collections.Generic.List[string]]::new()
    foreach($expected in $script:TL1C1bImplementationPathMap.GetEnumerator()){
        $hash=$null
        if(-not$actual.TryGetValue([string]$expected.Key,[ref]$hash)){
            throw "C1b implementation catalog 缺少字段：$($expected.Key)。"
        }
        if($hash-cnotmatch'^sha256:[0-9a-f]{64}$'){
            throw "C1b implementation hash 格式无效：$($expected.Key)。"
        }
        $lines.Add(([string]$expected.Value)+'='+$hash)
    }
    $ordered=$lines.ToArray();[Array]::Sort($ordered,[StringComparer]::Ordinal)
    return Get-TL1C1aSha256Text ($ordered-join"`n")
}

function Assert-TL1C1bBuildEnvironmentBinding {
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$ImplementationHashes
    )
    Assert-TL1C1bExactObjectKeys $Binding @(
        'schema','platform','threat_boundary','java_home_explicit','gradle_home_explicit',
        'gradle_user_home_fresh','project_cache_fresh','kotlin_runtime_fresh',
        'module_build_output_fresh','inherited_injection_variables_absent',
        'repo_local_properties_empty_guarded','repo_implicit_build_logic_absent',
        'path_chain_directories_deny_rename','concurrency_guard','recovery_journal',
        'debug_keystore','host_process','repository_inputs','jdk','git','android_sdk','gradle'
    ) 'build_environment'
    foreach($entry in @(
        [pscustomobject]@{Value=$Binding.concurrency_guard;Keys=@('scope','canonical_trust_tuple_sha256','named_mutex_held');Name='build_environment/concurrency_guard'},
        [pscustomobject]@{Value=$Binding.recovery_journal;Keys=@('schema','directory_entry_count','sha256','file_deny_write_delete');Name='build_environment/recovery_journal'},
        [pscustomobject]@{Value=$Binding.debug_keystore;Keys=@('sha256','source_ordinary_single_link_guarded','isolated_copy_equal','isolated_user_home_other_config_absent','files_deny_write_delete','directories_acl_protected');Name='build_environment/debug_keystore'},
        [pscustomobject]@{Value=$Binding.host_process;Keys=@('windows_system_directory_api_trust_root','host_launcher_cmd_not_executed','runner_direct_launcher_is_java','comspec_is_os_trust_root','wrapper_not_executed','gradle_entrypoint','minimal_path','fresh_process_temp');Name='build_environment/host_process'},
        [pscustomobject]@{Value=$Binding.repository_inputs;Keys=@('file_count','catalog_sha256','directory_root_count','protected_directory_count','files_deny_write_delete','directories_acl_protected');Name='build_environment/repository_inputs'},
        [pscustomobject]@{Value=$Binding.jdk;Keys=@('vendor','version','archive_sha256','file_count','catalog_sha256','java_sha256','jvm_sha256','release_sha256','modules_sha256','signature_status','signature_subject','signature_certificate_sha256','tree_files_deny_write_delete','tree_directories_acl_protected');Name='build_environment/jdk'},
        [pscustomobject]@{Value=$Binding.git;Keys=@('version','file_count','identity_count','internal_hardlink_group_count','catalog_sha256','cmd_git_sha256','mingw64_bin_git_sha256','mingw64_libexec_git_core_git_sha256','libcurl_sha256','libssl_sha256','libcrypto_sha256','signature_status','signature_subject','signature_certificate_sha256','child_environment_cleared','minimal_path','system_and_global_config_disabled','hardlink_topology_internal','tree_files_deny_write_delete','tree_directories_acl_protected');Name='build_environment/git'},
        [pscustomobject]@{Value=$Binding.android_sdk;Keys=@('build_tools','platform','platform_tools','isolated','source_trees_files_deny_write_delete','child_uses_only_isolated_sdk','tree_files_deny_write_delete','tree_directories_acl_protected');Name='build_environment/android_sdk'},
        [pscustomobject]@{Value=$Binding.android_sdk.build_tools;Keys=@('version','file_count','catalog_sha256','source_properties_sha256','package_xml_sha256','apksigner_jar_sha256');Name='build_environment/android_sdk/build_tools'},
        [pscustomobject]@{Value=$Binding.android_sdk.platform;Keys=@('version','file_count','catalog_sha256','android_jar_sha256','source_properties_sha256','package_xml_sha256','framework_aidl_sha256','core_for_system_modules_jar_sha256');Name='build_environment/android_sdk/platform'},
        [pscustomobject]@{Value=$Binding.android_sdk.platform_tools;Keys=@('version','file_count','catalog_sha256','source_properties_sha256','package_xml_sha256');Name='build_environment/android_sdk/platform_tools'},
        [pscustomobject]@{Value=$Binding.android_sdk.isolated;Keys=@('file_count','catalog_sha256','package_roots','dot_known_packages_absent','tools_package_xml_absent','emulator_package_xml_absent');Name='build_environment/android_sdk/isolated'},
        [pscustomobject]@{Value=$Binding.gradle;Keys=@('version','distribution','file_count','catalog_sha256','wrapper_not_executed','entrypoint','cli_main_jar','cli_main_jar_sha256','instrumentation_agent_sha256','tree_files_deny_write_delete','tree_directories_acl_protected','init_d_acl_protected');Name='build_environment/gradle'}
    )){Assert-TL1C1bExactObjectKeys $entry.Value $entry.Keys $entry.Name}
    $implementationCatalogSha256=Get-TL1C1bImplementationCatalogSha256 $ImplementationHashes
    $expectedThreatBoundary='filesystem-and-environment integrity after guard establishment; excludes same-user process-memory injection, pre-existing writable handles/mappings, ACL/ownership takeover, and same-user concurrent mutation of all intentionally writable fresh build working state (including dependency/project/Kotlin caches, process temp, Gradle daemon/native/transform state, and module outputs) during Gradle execution and the post-exit-to-final-guard window'
    $requiredTrue=@(
        $Binding.java_home_explicit,$Binding.gradle_home_explicit,$Binding.gradle_user_home_fresh,
        $Binding.project_cache_fresh,$Binding.kotlin_runtime_fresh,$Binding.module_build_output_fresh,
        $Binding.inherited_injection_variables_absent,$Binding.repo_local_properties_empty_guarded,
        $Binding.repo_implicit_build_logic_absent,$Binding.path_chain_directories_deny_rename,
        $Binding.concurrency_guard.named_mutex_held,$Binding.recovery_journal.file_deny_write_delete,
        $Binding.debug_keystore.source_ordinary_single_link_guarded,$Binding.debug_keystore.isolated_copy_equal,
        $Binding.debug_keystore.isolated_user_home_other_config_absent,$Binding.debug_keystore.files_deny_write_delete,
        $Binding.debug_keystore.directories_acl_protected,$Binding.host_process.windows_system_directory_api_trust_root,
        $Binding.host_process.host_launcher_cmd_not_executed,$Binding.host_process.runner_direct_launcher_is_java,
        $Binding.host_process.comspec_is_os_trust_root,$Binding.host_process.wrapper_not_executed,
        $Binding.host_process.minimal_path,$Binding.host_process.fresh_process_temp,
        $Binding.repository_inputs.files_deny_write_delete,$Binding.repository_inputs.directories_acl_protected,
        $Binding.jdk.tree_files_deny_write_delete,$Binding.jdk.tree_directories_acl_protected,
        $Binding.git.child_environment_cleared,$Binding.git.minimal_path,
        $Binding.git.system_and_global_config_disabled,$Binding.git.hardlink_topology_internal,
        $Binding.git.tree_files_deny_write_delete,$Binding.git.tree_directories_acl_protected,
        $Binding.android_sdk.source_trees_files_deny_write_delete,
        $Binding.android_sdk.child_uses_only_isolated_sdk,$Binding.android_sdk.tree_files_deny_write_delete,
        $Binding.android_sdk.tree_directories_acl_protected,$Binding.android_sdk.isolated.dot_known_packages_absent,
        $Binding.android_sdk.isolated.tools_package_xml_absent,$Binding.android_sdk.isolated.emulator_package_xml_absent,
        $Binding.gradle.wrapper_not_executed,$Binding.gradle.tree_files_deny_write_delete,
        $Binding.gradle.tree_directories_acl_protected,$Binding.gradle.init_d_acl_protected
    )
    $hashValues=@(
        $Binding.concurrency_guard.canonical_trust_tuple_sha256,$Binding.recovery_journal.sha256,
        $Binding.debug_keystore.sha256,$Binding.repository_inputs.catalog_sha256,
        $Binding.jdk.archive_sha256,$Binding.jdk.catalog_sha256,$Binding.jdk.java_sha256,
        $Binding.jdk.jvm_sha256,$Binding.jdk.release_sha256,$Binding.jdk.modules_sha256,
        $Binding.jdk.signature_certificate_sha256,$Binding.git.catalog_sha256,
        $Binding.git.cmd_git_sha256,$Binding.git.mingw64_bin_git_sha256,
        $Binding.git.mingw64_libexec_git_core_git_sha256,$Binding.git.libcurl_sha256,
        $Binding.git.libssl_sha256,$Binding.git.libcrypto_sha256,
        $Binding.git.signature_certificate_sha256,$Binding.android_sdk.build_tools.catalog_sha256,
        $Binding.android_sdk.build_tools.source_properties_sha256,$Binding.android_sdk.build_tools.package_xml_sha256,
        $Binding.android_sdk.build_tools.apksigner_jar_sha256,$Binding.android_sdk.platform.catalog_sha256,
        $Binding.android_sdk.platform.android_jar_sha256,$Binding.android_sdk.platform.source_properties_sha256,
        $Binding.android_sdk.platform.package_xml_sha256,$Binding.android_sdk.platform.framework_aidl_sha256,
        $Binding.android_sdk.platform.core_for_system_modules_jar_sha256,$Binding.android_sdk.platform_tools.catalog_sha256,
        $Binding.android_sdk.platform_tools.source_properties_sha256,$Binding.android_sdk.platform_tools.package_xml_sha256,
        $Binding.android_sdk.isolated.catalog_sha256,$Binding.gradle.catalog_sha256,
        $Binding.gradle.cli_main_jar_sha256,$Binding.gradle.instrumentation_agent_sha256
    )
    if($Binding.schema-cne'tablet-layout-c1b-build-environment-trust/v1'-or$Binding.platform-cne'windows'-or
       $Binding.threat_boundary-cne$expectedThreatBoundary-or@($requiredTrue|Where-Object{$_-isnot[bool]-or-not$_}).Count-ne0-or
       $Binding.concurrency_guard.scope-cne'windows-logon-session-all-c1b-builds'-or
       $Binding.recovery_journal.schema-cne'tablet-layout-c1b-build-environment-acl-recovery/v1'-or
       [long]$Binding.recovery_journal.directory_entry_count-lt1-or
       [long]$Binding.repository_inputs.file_count-ne$script:TL1C1bImplementationPathMap.Count-or
       $Binding.repository_inputs.catalog_sha256-cne$implementationCatalogSha256-or
       [long]$Binding.repository_inputs.directory_root_count-ne3-or
       [long]$Binding.repository_inputs.protected_directory_count-lt3-or
       @($hashValues|Where-Object{[string]$_-cnotmatch'^sha256:[0-9a-f]{64}$'}).Count-ne0-or
       $Binding.host_process.gradle_entrypoint-cne'org.gradle.launcher.GradleMain'-or
       $Binding.jdk.vendor-cne'Oracle Corporation'-or$Binding.jdk.version-cne'21.0.5'-or[long]$Binding.jdk.file_count-ne418-or
       $Binding.jdk.archive_sha256-cne'sha256:6cce98ce38b86737c63912fd1df9ecfee1fe209ab08c0e1e16500f054e67de48'-or
       $Binding.jdk.catalog_sha256-cne'sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9'-or
       $Binding.jdk.signature_status-cne'Valid'-or
       $Binding.jdk.signature_subject-cne'CN="Oracle America, Inc.", O="Oracle America, Inc.", L=Redwood City, S=California, C=US'-or
        $Binding.git.version-cne'2.55.0.windows.3'-or[long]$Binding.git.file_count-ne9576-or
        [long]$Binding.git.identity_count-ne9489-or[long]$Binding.git.internal_hardlink_group_count-ne85-or
        $Binding.git.catalog_sha256-cne'sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458'-or
        $Binding.git.cmd_git_sha256-cne'sha256:7b7971dd13f0c3a284e538601f2f9770b3a87dfaccb5fb52d68141c67ed22364'-or
        $Binding.git.mingw64_bin_git_sha256-cne'sha256:1a0043555d254618f2d56c936c3d9a1fbfb878bc878416a133c346bc7835eda9'-or
        $Binding.git.mingw64_libexec_git_core_git_sha256-cne'sha256:1a0043555d254618f2d56c936c3d9a1fbfb878bc878416a133c346bc7835eda9'-or
        $Binding.git.libcurl_sha256-cne'sha256:799f7eefc3c9da9c80ec5aea221a02b3afe2c5350c6b45fd5a4865e7e2d4e574'-or
        $Binding.git.libssl_sha256-cne'sha256:feb5b300e0b3a021fed481178f3d66896426576d4d13b85a304d2a3809b25bfd'-or
        $Binding.git.libcrypto_sha256-cne'sha256:0330b5f558996f297d687e1a2b2fcc2cacf883b16baef74aaef35285d7c1231c'-or
        $Binding.git.signature_status-cne'Valid'-or
        $Binding.git.signature_subject-cne'CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE'-or
        $Binding.git.signature_certificate_sha256-cne'sha256:1668941fff36fec818a596ffde6589f34daa6c6434069e60f356b7755f084e63'-or
       $Binding.android_sdk.build_tools.version-cne'35.0.0'-or[long]$Binding.android_sdk.build_tools.file_count-ne170-or
       $Binding.android_sdk.platform.version-cne'android-35'-or[long]$Binding.android_sdk.platform.file_count-ne11163-or
       $Binding.android_sdk.platform_tools.version-cne'37.0.1'-or[long]$Binding.android_sdk.platform_tools.file_count-ne15-or
       [long]$Binding.android_sdk.isolated.file_count-ne11348-or
       (@($Binding.android_sdk.isolated.package_roots)-join"`n")-cne("build-tools/35.0.0`nplatform-tools`nplatforms/android-35")-or
       $Binding.gradle.version-cne'8.9'-or$Binding.gradle.distribution-cne'gradle-8.9-bin'-or
       [long]$Binding.gradle.file_count-ne299-or$Binding.gradle.entrypoint-cne'org.gradle.launcher.GradleMain'-or
       $Binding.gradle.cli_main_jar-cne'lib/gradle-gradle-cli-main-8.9.jar'){
        throw 'C1b build_environment binding 不成立。'
    }
}

function Assert-TL1C1bSidecarCrossBindings {
    param([Parameter(Mandatory)]$Sidecar)
    $expectedT0Path="docs/runs/evidence/$($Sidecar.run_id)/tablet-profile.json"
    $zeroReadOnlyNames=@('display_screenshot_call_count','window_screenshot_call_count','ocr_invocation_count','action_call_count','gesture_call_count','input_call_count','settings_mutation_count','target_app_start_count','mcp_call_count','dispatch_call_count')
    $readOnlyNonZero=@($zeroReadOnlyNames|Where-Object{[long]$Sidecar.read_only_counts.$_-ne0}).Count-ne0
    $artifactHashNames=@('artifact_proof_sha256','dependency_artifact_catalog_sha256','debug_apk_sha256','debug_merged_manifest_sha256','debug_packaged_manifest_sha256','debug_packaged_manifest_axml_dump_sha256','debug_packaged_a11y_axml_dump_sha256','debug_dex_sha256','debug_dex_catalog_sha256','release_apk_sha256','release_merged_manifest_sha256','release_packaged_manifest_sha256','release_packaged_manifest_axml_dump_sha256','release_packaged_a11y_axml_dump_sha256','release_dex_sha256','release_dex_catalog_sha256')
    $invalidArtifactHash=@($artifactHashNames|Where-Object{[string]$Sidecar.read_only_proof.$_-cnotmatch'^sha256:[0-9a-f]{64}$'}).Count-ne0
    Assert-TL1C1bBuildEnvironmentBinding $Sidecar.build_environment $Sidecar.implementation_hashes
    if ($Sidecar.static_read_only_policy_version -cne 'tl1-c1b-read-only/v2' -or
        $Sidecar.apk.local_sha256_before -cne $Sidecar.apk.local_sha256_after -or
        $Sidecar.transport.trust_root -cne 'android_sdk_platform_tools' -or
        $Sidecar.transport.canonical_relative_path -cne 'platform-tools/adb.exe' -or
        -not $Sidecar.transport.sdk_roots_equal -or -not $Sidecar.transport.installed_as_canonical -or
        $Sidecar.transport.executable_sha256_before -cne $Sidecar.transport.executable_sha256_after -or
        $Sidecar.transport.version_output_sha256_before -cne $Sidecar.transport.version_output_sha256_after -or
        $Sidecar.transport.signature_status -cne 'Valid' -or
        $Sidecar.transport.signature_subject -cne $script:TL1C1bGoogleAdbSignerSubject -or
        $Sidecar.transport.signature_certificate_sha256_before -cne $Sidecar.transport.signature_certificate_sha256_after -or
        $Sidecar.transport.server_schema-cne'tablet-layout-c1b-private-adb-server/v1'-or
        $Sidecar.transport.server_mode-cne'private_nodaemon'-or
        [string]$Sidecar.transport.server_socket-cnotmatch'^tcp:127\.0\.0\.1:([0-9]{5})$'-or
        [int]$Matches[1]-lt49152-or[int]$Matches[1]-gt65535-or
        $Sidecar.transport.server_executable_sha256-cne$Sidecar.transport.executable_sha256_before-or
        -not$Sidecar.transport.job_kill_on_close-or-not$Sidecar.transport.listener_pid_verified-or
        -not$Sidecar.transport.server_status_executable_path_verified-or-not$Sidecar.transport.server_ready_verified-or
        -not$Sidecar.transport.server_cleanup_verified-or-not$Sidecar.transport.private_kill_server_requested-or
        ([bool]$Sidecar.transport.graceful_exit_verified-eq[bool]$Sidecar.transport.job_fallback_used)-or
        -not$Sidecar.transport.port_rebind_verified-or[bool]$Sidecar.transport.default_server_used-or
        $Sidecar.apk.local_sha256_before -cne $Sidecar.apk.installed_base_apk_sha256_before -or
        $Sidecar.apk.local_sha256_before -cne $Sidecar.apk.installed_base_apk_sha256_after -or
        $Sidecar.apk.installed_base_apk_path_hash_before -cne $Sidecar.apk.installed_base_apk_path_hash_after -or
        $Sidecar.apk.package_name_before -cne $Sidecar.apk.package_name_after -or
        $Sidecar.apk.version_name_before -cne $Sidecar.apk.version_name_after -or
        [long]$Sidecar.apk.version_code_before -ne [long]$Sidecar.apk.version_code_after -or
        $Sidecar.provider.package_name -cne $Sidecar.apk.package_name_before -or
        $Sidecar.provider.version_name -cne $Sidecar.apk.version_name_before -or
        [long]$Sidecar.provider.version_code -ne [long]$Sidecar.apk.version_code_before -or
        $Sidecar.device.serial_hash_before -cne $Sidecar.device.serial_hash_after -or
        $Sidecar.device.fingerprint_hash_before -cne $Sidecar.device.fingerprint_hash_after -or
        $Sidecar.device.boot_id_hash_before -cne $Sidecar.device.boot_id_hash_after -or
        -not $Sidecar.device.unique_device_before_after -or
        $Sidecar.expected_commit_sha -cne $Sidecar.provider.embedded_git_head -or
        $Sidecar.provider.producer_artifact_sha256 -cne $Sidecar.apk.local_sha256_before -or
        $Sidecar.upstream_t0.original_sha256 -cne $Sidecar.artifacts.upstream_t0.sha256 -or
        $Sidecar.upstream_t0.original_relative_path -cne $expectedT0Path -or
        $Sidecar.artifacts.upstream_t0.relative_path -cne 'upstream-t0-v5.json' -or
        $Sidecar.artifacts.observation.relative_path -cne 'tablet-layout-observation-c1b-v1.json' -or
        $Sidecar.artifacts.validation.relative_path -cne 'tablet-layout-observation-validation-c1b-v1.json' -or
        $Sidecar.artifacts.artifact_proof.relative_path-cne'tablet-c1b-read-only-artifact-proof-v1.json'-or
        $Sidecar.artifacts.debug_apk.relative_path-cne'tablet-c1b-probe-debug.apk'-or
        $Sidecar.artifacts.release_apk.relative_path-cne'tablet-c1b-probe-release-unsigned.apk'-or
        $Sidecar.artifacts.debug_merged_manifest.relative_path-cne'tablet-c1b-probe-debug-merged-AndroidManifest.xml'-or
        $Sidecar.artifacts.release_merged_manifest.relative_path-cne'tablet-c1b-probe-release-merged-AndroidManifest.xml'-or
        $Sidecar.capture.c1_requests_accepted -ne 1 -or
        $Sidecar.capture.c2_requests_accepted -ne 1 -or $Sidecar.capture.recapture_count -ne 0 -or
        [long]$Sidecar.read_only_counts.a11y_frame_capture_count-ne(
            [long]$Sidecar.capture.c1_requests_accepted+[long]$Sidecar.capture.c2_requests_accepted) -or
        [long]$Sidecar.read_only_counts.recapture_count-ne[long]$Sidecar.capture.recapture_count-or$readOnlyNonZero-or
        $Sidecar.read_only_proof.schema-cne'tablet-layout-c1b-read-only-proof/v1'-or
        $Sidecar.read_only_proof.policy_version-cne$Sidecar.static_read_only_policy_version-or
        $Sidecar.read_only_proof.artifact_module-cne':tablet-c1b-probe'-or
        $Sidecar.read_only_proof.artifact_proof_relative_path-cne'app/tablet-c1b-probe/build/reports/tablet-c1b-read-only-artifact-proof.json'-or
        $Sidecar.read_only_proof.runner_ast_sha256-cne$Sidecar.implementation_hashes.runner_sha256-or
        $Sidecar.read_only_proof.t0_runner_ast_sha256-cne$Sidecar.implementation_hashes.t0_runner_sha256-or
        $Sidecar.read_only_proof.t0_library_ast_sha256-cne$Sidecar.implementation_hashes.t0_library_sha256-or
        $Sidecar.read_only_proof.axml_parser.schema-cne'tablet-layout-c1b-aapt2-trust/v1'-or
        $Sidecar.read_only_proof.axml_parser.trust_root-cne'android_sdk_build_tools'-or
        $Sidecar.read_only_proof.axml_parser.build_tools_version-cne'35.0.0'-or
        $Sidecar.read_only_proof.axml_parser.canonical_relative_path-cne'build-tools/35.0.0/aapt2.exe'-or
        -not[bool]$Sidecar.read_only_proof.axml_parser.sdk_roots_equal-or
        $Sidecar.read_only_proof.axml_parser.executable_sha256-cne'sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'-or
        $Sidecar.read_only_proof.axml_parser.signature_status-cne'Valid'-or
        $Sidecar.read_only_proof.axml_parser.signature_subject-cne'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'-or
        $Sidecar.read_only_proof.axml_parser.signature_certificate_sha256-cne'sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'-or
        -not[bool]$Sidecar.read_only_proof.packaged_axml_exact_verified-or
        $Sidecar.read_only_proof.debug_apk_sha256-cne$Sidecar.apk.local_sha256_before-or
        $Sidecar.read_only_proof.artifact_proof_sha256-cne$Sidecar.artifacts.artifact_proof.sha256-or
        $Sidecar.read_only_proof.debug_apk_sha256-cne$Sidecar.artifacts.debug_apk.sha256-or
        $Sidecar.read_only_proof.release_apk_sha256-cne$Sidecar.artifacts.release_apk.sha256-or
        $Sidecar.read_only_proof.debug_merged_manifest_sha256-cne$Sidecar.artifacts.debug_merged_manifest.sha256-or
        $Sidecar.read_only_proof.release_merged_manifest_sha256-cne$Sidecar.artifacts.release_merged_manifest.sha256-or
        $invalidArtifactHash-or
        [long]$Sidecar.read_only_proof.debug_dex_entry_count-notin 1..32-or
        [long]$Sidecar.read_only_proof.release_dex_entry_count-notin 1..32-or
        [long]$Sidecar.read_only_proof.host_forbidden_command_count-ne0-or
        [long]$Sidecar.read_only_proof.artifact_forbidden_match_count-ne0-or
        [long]$Sidecar.read_only_proof.manifest_mutating_capability_count-ne0-or
        [long]$Sidecar.read_only_proof.manifest_extra_component_count-ne0-or
        -not[bool]$Sidecar.read_only_proof.dependency_allowlist_verified-or
        -not[bool]$Sidecar.attestations.full_clean_head_verified-or
        -not[bool]$Sidecar.attestations.implementation_hashes_verified-or
        -not[bool]$Sidecar.attestations.origin_binding_verified-or
        -not[bool]$Sidecar.attestations.probe_entrypoint_read_only-or
        -not[bool]$Sidecar.attestations.dedicated_read_only_artifact_verified-or
        -not[bool]$Sidecar.attestations.host_read_only_ast_verified-or
        -not[bool]$Sidecar.attestations.observation_schema_valid-or
        -not[bool]$Sidecar.attestations.artifact_hashes_recomputed-or
        $Sidecar.capture.status_poll_count -lt 1 -or $Sidecar.capture.result_read_count -ne 1 -or
        $Sidecar.capture.host_wait_ms -lt 900 -or $Sidecar.capture.total_span_ms -lt $Sidecar.capture.host_wait_ms -or
        $Sidecar.capture.total_span_ms -gt 15000 -or
        $Sidecar.apk.install_attempt_count -ne 1 -or $Sidecar.apk.uninstall_count -ne 0 -or
        $Sidecar.apk.automatic_retry_count -ne 0 -or $Sidecar.upstream_t0.exec_in_write_count -ne 1 -or
        -not $Sidecar.claims.runtime_origin_verified -or -not $Sidecar.claims.runtime_evidence) {
        throw 'C1b sidecar cross-binding 不成立。'
    }
    try{
        $c1Requested=[DateTimeOffset]::ParseExact($Sidecar.capture.c1_requested_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c1Committed=[DateTimeOffset]::ParseExact($Sidecar.capture.c1_committed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c2Requested=[DateTimeOffset]::ParseExact($Sidecar.capture.c2_requested_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $c2Committed=[DateTimeOffset]::ParseExact($Sidecar.capture.c2_committed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
    }catch{throw 'C1b sidecar capture timestamp 解析失败。'}
    if($c1Committed-lt$c1Requested-or$c2Requested-lt$c1Committed-or$c2Committed-lt$c2Requested-or
       ($c2Requested-$c1Committed).TotalMilliseconds-lt900){throw 'C1b sidecar capture timestamp/host wait 不成立。'}
    foreach ($stem in @('wechat_window_ownership','window_root_projection','application_window_topology','ime_hidden')) {
        if ([bool]$Sidecar.claims."${stem}_observed" -ne [bool]$Sidecar.claims."${stem}_verified") {
            throw "C1b sidecar observed/verified 不等价：$stem。"
        }
    }
}

function ConvertFrom-TL1C1bOfflineSummary {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$ExpectedGateRunId,
        [Parameter(Mandatory)][DateTimeOffset]$GateStartedAtUtc,
        [Parameter(Mandatory)][DateTimeOffset]$GateCompletedAtUtc,
        [Parameter(Mandatory)][long]$GateElapsedMilliseconds
    )
    if([Text.Encoding]::UTF8.GetByteCount($Raw)-gt65536-or$Raw-match'[\r\n]'){throw 'C1b offline summary 必须是单行 bounded JSON。'}
    $issues=[Collections.Generic.List[object]]::new();$value=ConvertFrom-TL1C1BV1StrictJson $Raw $issues
    if($null-eq$value-or$issues.Count-ne0){throw 'C1b offline summary 不是 strict JSON。'}
    Assert-TL1C1bExactObjectKeys $value @('schema','gate_run_id','started_at_utc','completed_at_utc','status','fake_adb','real_adb_call_count','test_case_count','coverage_case_count','coverage','claims') 'offline-summary'
    Assert-TL1C1bExactObjectKeys $value.claims @('runtime_origin_verified','runtime_evidence','layout_accepted','wechat_layout_verified','editor_action_ready','p0_capability','execution_grant') 'offline-summary/claims'
    if($value.schema-cne'tablet-layout-c1b-host-offline-summary/v1'-or$value.gate_run_id-cne$ExpectedGateRunId-or
       $value.status-cne'passed'-or$value.fake_adb-isnot[bool]-or-not$value.fake_adb-or
       $value.real_adb_call_count-isnot[long]-or$value.real_adb_call_count-ne0-or
       $value.test_case_count-isnot[long]-or$value.coverage_case_count-isnot[long]-or
       $value.test_case_count-ne$script:TL1C1bRequiredOfflineCoverage.Count-or$value.coverage_case_count-ne$value.test_case_count-or
       $value.coverage-isnot[object[]]-or(@($value.coverage|Select-Object -Unique)).Count-ne$value.coverage.Count-or
       (@($value.coverage|Sort-Object -CaseSensitive)-join"`n")-cne(@($script:TL1C1bRequiredOfflineCoverage|Sort-Object -CaseSensitive)-join"`n")-or
       @($value.claims.PSObject.Properties|Where-Object{$_.Name-cne'p0_capability'-and($_.Value-isnot[bool]-or$_.Value)}).Count-ne0-or
       $value.claims.p0_capability-cne'unsupported'){
        throw 'C1b offline summary 结论、计数或 coverage 绑定失败。'
    }
    try{$started=[DateTimeOffset]::ParseExact($value.started_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal);$completed=[DateTimeOffset]::ParseExact($value.completed_at_utc,'yyyy-MM-ddTHH:mm:ss.fffffffZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)}catch{throw 'C1b offline summary 时间戳错误。'}
    $now=[DateTimeOffset]::UtcNow
    $maximumSpanMilliseconds=[long]300000
    $envelopeToleranceMilliseconds=[long]15000
    $summarySpanMilliseconds=($completed-$started).TotalMilliseconds
    if($GateCompletedAtUtc-lt$GateStartedAtUtc-or$GateElapsedMilliseconds-lt0-or$GateElapsedMilliseconds-gt$maximumSpanMilliseconds-or
       $completed-lt$started-or$summarySpanMilliseconds-gt$maximumSpanMilliseconds-or
       $completed-gt$now.AddSeconds(5)-or($now-$completed).TotalMinutes-gt2-or
       [Math]::Abs(($started-$GateStartedAtUtc).TotalMilliseconds)-gt$envelopeToleranceMilliseconds-or
       [Math]::Abs(($completed-$GateCompletedAtUtc).TotalMilliseconds)-gt$envelopeToleranceMilliseconds-or
       [Math]::Abs($summarySpanMilliseconds-$GateElapsedMilliseconds)-gt$envelopeToleranceMilliseconds){
        throw 'C1b offline summary freshness/span/gate envelope 失败。'
    }
    return $value
}
