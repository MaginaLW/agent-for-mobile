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
$ReadOnlyLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b-readonly.ps1'
$ArtifactProofLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b-artifact-proof.ps1'
$Aapt2Library=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b-aapt2.ps1'
$BuildEnvironmentLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b-build-env.ps1'
$AdbServerLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b-adb-server.ps1'
$DispatchLockLibrary=Join-Path $PSScriptRoot 'lib\dispatch-lock.ps1'
$Validator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-validator.ps1'
$NativePathValidator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-validator.ps1'
$SidecarSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1b-sidecar-v1.schema.json'
$ArtifactProofSchema=Join-Path $RepoRoot 'docs\contracts\tablet-c1b-read-only-artifact-proof-v1.schema.json'
$ObservationSchema=Join-Path $RepoRoot 'docs\contracts\tablet-layout-observation-c1b-v1.schema.json'
$T0Runner=Join-Path $PSScriptRoot 'run-tablet-intake.ps1'
$T0Library=Join-Path $PSScriptRoot 'lib\tablet-intake.ps1'
$T0AdbCmd=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.cmd'
$T0AdbScript=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.ps1'
$Apk=Join-Path $RepoRoot 'app\tablet-c1b-probe\build\outputs\apk\debug\tablet-c1b-probe-debug.apk'
$ReleaseApk=Join-Path $RepoRoot 'app\tablet-c1b-probe\build\outputs\apk\release\tablet-c1b-probe-release-unsigned.apk'
$ArtifactProof=Join-Path $RepoRoot 'app\tablet-c1b-probe\build\reports\tablet-c1b-read-only-artifact-proof.json'
$EvidenceRoot=Join-Path $RepoRoot 'docs\runs\evidence'
$ImplementationPaths=[ordered]@{
    runner_sha256=$PSCommandPath; c1b_library_sha256=$Library; c1b_read_only_library_sha256=$ReadOnlyLibrary
    c1b_artifact_proof_library_sha256=$ArtifactProofLibrary; c1b_aapt2_library_sha256=$Aapt2Library
    c1b_build_environment_library_sha256=$BuildEnvironmentLibrary; c1b_adb_server_library_sha256=$AdbServerLibrary
    dispatch_lock_library_sha256=$DispatchLockLibrary
    c1a_low_level_library_sha256=$C1aLibrary
    t0_runner_sha256=$T0Runner; t0_library_sha256=$T0Library; t0_adb_sidecar_cmd_sha256=$T0AdbCmd
    t0_adb_sidecar_script_sha256=$T0AdbScript; validator_sha256=$Validator; native_path_validator_sha256=$NativePathValidator
    observation_schema_sha256=$ObservationSchema;sidecar_schema_sha256=$SidecarSchema;artifact_proof_schema_sha256=$ArtifactProofSchema
    android_layout_probe_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\TabletLayoutProbe.kt')
    android_layout_probe_model_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\TabletLayoutProbeModel.kt')
    android_model_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\TabletC1bModel.kt')
    android_probe_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\TabletC1bProbe.kt')
    android_source_sha256=(Join-Path $RepoRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\AndroidTabletC1bSource.kt')
    android_provider_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bContentProvider.kt')
    android_protocol_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bProtocol.kt')
    android_coordinator_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bReadCoordinator.kt')
    android_controller_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TabletC1bRuntimeController.kt')
    android_context_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\TrustedRuntimeContextFactory.kt')
    android_pending_registry_sha256=(Join-Path $RepoRoot 'app\gateway\src\debug\java\dev\magina\gateway\tablet\c1b\C1bPendingStartRegistry.kt')
    app_build_gradle_sha256=(Join-Path $RepoRoot 'app\build.gradle.kts')
    app_settings_gradle_sha256=(Join-Path $RepoRoot 'app\settings.gradle.kts')
    app_gradle_properties_sha256=(Join-Path $RepoRoot 'app\gradle.properties')
    app_gradlew_bat_sha256=(Join-Path $RepoRoot 'app\gradlew.bat')
    app_gradle_wrapper_jar_sha256=(Join-Path $RepoRoot 'app\gradle\wrapper\gradle-wrapper.jar')
    app_gradle_wrapper_properties_sha256=(Join-Path $RepoRoot 'app\gradle\wrapper\gradle-wrapper.properties')
    app_gradle_verification_metadata_sha256=(Join-Path $RepoRoot 'app\gradle\verification-metadata.xml')
    probe_build_gradle_sha256=(Join-Path $RepoRoot 'app\tablet-c1b-probe\build.gradle.kts')
    probe_manifest_sha256=(Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\AndroidManifest.xml')
    probe_service_sha256=(Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\java\dev\magina\gateway\a11y\GatewayA11yService.kt')
    probe_a11y_config_sha256=(Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\res\xml\a11y_config.xml')
    probe_strings_sha256=(Join-Path $RepoRoot 'app\tablet-c1b-probe\src\main\res\values\strings.xml')
}
$runId=$null;$runDirectory=$null;$c1bDirectory=$null;$serial=$null;$nonce=$null;$buildChallenge=$null
$expectedArtifactSha=$null;$sessionStarted=$false;$sessionConsumed=$false;$abortAttempted=$false;$abortSucceeded=$false
$failure=$null;$implementationHashes=$null;$adbTrustBefore=$null;$artifactProofBinding=$null
$staticReadOnlyProof=$null;$t0ReadOnlyProof=$null;$readOnlyCounts=$null
$deviceLease=$null;$buildEnvironmentGuard=$null;$buildEnvironmentBinding=$null;$buildEnvironmentBindingRaw=$null
$buildEnvironment=$null;$gitEnvironment=$null;$adbTrustEnvironment=$null;$adbEnvironment=$null;$Java=$null;$signerArguments=$null;$archivedSignerSha=$null
$adbServerGuard=$null;$adbServerBinding=$null;$adbServerBindingRaw=$null;$adbServerCleanupBinding=$null
$aapt2TrustGuard=$null;$aapt2TrustBinding=$null
$debugAxmlDumpBinding=$null;$releaseAxmlDumpBinding=$null
$artifactProofGuard=$null;$debugApkGuard=$null;$releaseApkGuard=$null
$debugMergedManifestGuard=$null;$releaseMergedManifestGuard=$null
$archivedProofGuard=$null;$archivedDebugApkGuard=$null;$archivedReleaseApkGuard=$null
$archivedDebugManifestGuard=$null;$archivedReleaseManifestGuard=$null
$archivedProofPath=$null;$archivedDebugApkPath=$null;$archivedReleaseApkPath=$null
$archivedDebugManifestPath=$null;$archivedReleaseManifestPath=$null
$controlRaw=[Collections.Generic.List[string]]::new();$statusReadCount=0
$abortExpectedGeneration=0L;$abortExpectedC1Count=0;$abortExpectedC2Count=0;$abortExpectedCommitted=[string[]]@()
$exitCode=1;$successMessage=$null;$needsUserPayload=$null;$sidecarPath=$null;$pendingSidecarBytes=$null

function Get-C1bTimestamp { [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",[Globalization.CultureInfo]::InvariantCulture) }
function Get-C1bImplementationHashes {
    $value=[ordered]@{};foreach($entry in $ImplementationPaths.GetEnumerator()){$value[$entry.Key]=Get-TL1C1aFileSha256 $entry.Value};return $value
}
function Assert-C1bImplementationSnapshot {
    if($null-eq$implementationHashes){throw 'C1b implementation 初始 snapshot 尚未建立。'}
    foreach($entry in $ImplementationPaths.GetEnumerator()){
        if((Get-TL1C1aFileSha256 $entry.Value)-cne $implementationHashes[$entry.Key]){
            throw "C1b implementation 漂移：$($entry.Key)。"
        }
    }
}
function Find-C1bTrustedGitPath {
    $programFiles=[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    if([string]::IsNullOrWhiteSpace($programFiles)){throw 'C1b 无法解析 Windows Program Files trust root。'}
    $canonical=[IO.Path]::GetFullPath((Join-Path $programFiles 'Git\cmd\git.exe'))
    [void](Resolve-TL1C1bBuildEnvironmentGitRoot -GitPath $canonical)
    return $canonical
}
function ConvertFrom-C1bSignerDigest([string]$Text) {
    $matches=@([regex]::Matches($Text,'(?im)^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$'))
    if($matches.Count-ne1){throw 'APK signer SHA-256 无法唯一解析。'}
    return 'sha256:'+$matches[0].Groups[1].Value.ToLowerInvariant()
}
function Assert-C1bFrozenState {
    if($null-eq$buildEnvironmentGuard-or$null-eq$buildEnvironmentBindingRaw){throw 'C1b build-environment trust guard 尚未建立。'}
    $currentBuildEnvironment=Assert-TL1C1bBuildEnvironmentFrozen $buildEnvironmentGuard
    $currentBuildEnvironmentRaw=$currentBuildEnvironment|ConvertTo-Json -Depth 20 -Compress
    if($currentBuildEnvironmentRaw-cne$buildEnvironmentBindingRaw){throw 'C1b build-environment trust binding 前后漂移。'}
    if($null-eq$gitEnvironment){throw 'C1b Git controlled environment 尚未建立。'}
    [void](Assert-TL1C1aGitProvenance $RepoRoot $ExpectedCommitSha `
        -GitPath $buildEnvironmentGuard.GitPath `
        -ProcessEnvironment $gitEnvironment -ClearEnvironment)
    Assert-C1bImplementationSnapshot
}
function Assert-C1bPrivateAdbServerFrozenState {
    if($null-eq$adbServerGuard-or$null-eq$adbServerBindingRaw-or$null-eq$adbTrustBefore){
        throw 'C1b private adb server trust guard 尚未建立。'
    }
    $current=Assert-TL1C1bPrivateAdbServerGuardUnchanged $adbServerGuard
    $currentRaw=$current|ConvertTo-Json -Depth 5 -Compress
    if($currentRaw-cne$adbServerBindingRaw-or
       $current.server_executable_sha256-cne$adbTrustBefore.executable_sha256){
        throw 'C1b private adb server trust binding 漂移。'
    }
    return $current
}
function Assert-C1bArtifactFrozenState {
    if($null-eq$artifactProofBinding){throw 'C1b read-only artifact proof 尚未建立。'}
    $current=Assert-TL1C1bReadOnlyArtifactProof -RepoRoot $RepoRoot -ProofPath $ArtifactProof `
        -ProofSchemaPath $ArtifactProofSchema -ExpectedCommitSha $ExpectedCommitSha `
        -BuildChallenge $buildChallenge -DebugApkPath $Apk -Aapt2TrustBinding $aapt2TrustBinding `
        -ProofGuard $artifactProofGuard `
        -DebugApkGuard $debugApkGuard -ReleaseApkGuard $releaseApkGuard
    foreach($path in @(
        'ProofSha256','DependencyArtifactCatalogSha256',
        'Debug.ApkSha256','Debug.MergedManifestSha256','Debug.PackagedManifestSha256','Debug.PackagedManifestAxmlDumpSha256','Debug.PackagedA11yAxmlDumpSha256','Debug.PackagedManifestExactTreeVerified','Debug.PackagedA11yExactTreeVerified','Debug.DexEntryCount','Debug.DexSha256','Debug.DexCatalogSha256',
        'Release.ApkSha256','Release.MergedManifestSha256','Release.PackagedManifestSha256','Release.PackagedManifestAxmlDumpSha256','Release.PackagedA11yAxmlDumpSha256','Release.PackagedManifestExactTreeVerified','Release.PackagedA11yExactTreeVerified','Release.DexEntryCount','Release.DexSha256','Release.DexCatalogSha256'
    )){
        $segments=$path-split'\.';$before=$artifactProofBinding;$after=$current
        foreach($segment in $segments){$before=$before.$segment;$after=$after.$segment}
        if([string]$before-cne[string]$after){throw "C1b read-only artifact proof 漂移：$path。"}
    }
    if($current.ForbiddenMatchCount-ne0-or$current.ManifestMutatingCapabilityCount-ne0-or
       $current.ManifestExtraComponentCount-ne0-or-not$current.DependencyAllowlistVerified){
        throw 'C1b read-only artifact proof 零能力结论漂移。'
    }
    $aapt2Current=Assert-TL1C1bAapt2TrustGuardUnchanged $aapt2TrustGuard
    foreach($name in @('schema','trust_root','build_tools_version','canonical_relative_path','sdk_roots_equal','executable_sha256','signature_status','signature_subject','signature_certificate_sha256')){
        if([string]$aapt2Current.$name-cne[string]$aapt2TrustBinding.$name){throw "C1b aapt2 trust binding 漂移：$name。"}
    }
    if($null-eq$debugAxmlDumpBinding-or$null-eq$releaseAxmlDumpBinding-or
       $debugAxmlDumpBinding.ApkSha256-cne$artifactProofBinding.Debug.ApkSha256-or
       $debugAxmlDumpBinding.PackagedManifestAxmlDumpSha256-cne$artifactProofBinding.Debug.PackagedManifestAxmlDumpSha256-or
       $debugAxmlDumpBinding.PackagedA11yAxmlDumpSha256-cne$artifactProofBinding.Debug.PackagedA11yAxmlDumpSha256-or
       $releaseAxmlDumpBinding.ApkSha256-cne$artifactProofBinding.Release.ApkSha256-or
       $releaseAxmlDumpBinding.PackagedManifestAxmlDumpSha256-cne$artifactProofBinding.Release.PackagedManifestAxmlDumpSha256-or
       $releaseAxmlDumpBinding.PackagedA11yAxmlDumpSha256-cne$artifactProofBinding.Release.PackagedA11yAxmlDumpSha256){
        throw 'C1b host packaged AXML dump proof 漂移。'
    }
}
function Assert-C1bArchivedArtifactEvidence {
    if($null-eq$artifactProofBinding-or$null-eq$archivedProofGuard-or$null-eq$archivedDebugApkGuard-or
       $null-eq$archivedReleaseApkGuard-or$null-eq$archivedDebugManifestGuard-or$null-eq$archivedReleaseManifestGuard){
        throw 'C1b archived artifact evidence 尚未建立。'
    }
    $proof=$artifactProofBinding.Proof
    if($archivedProofGuard.Sha256-cne$artifactProofBinding.ProofSha256-or
       $proof.git_sha-cne$ExpectedCommitSha-or$proof.build_challenge_sha256-cne(Get-TL1C1aSha256Text $buildChallenge)-or
       $proof.policy-cne$script:TL1C1bReadOnlyPolicy-or$proof.application_id-cne'dev.magina.gateway'-or
       $proof.provider_component-cne'dev.magina.gateway.tablet.c1b.TabletC1bContentProvider'-or
       $proof.provider_authority-cne$script:TL1C1bAuthority-or
       $proof.axml_parser.tool-cne'aapt2'-or
       $proof.axml_parser.build_tools_version-cne$aapt2TrustBinding.build_tools_version-or
       $proof.axml_parser.aapt2_relative_path-cne$aapt2TrustBinding.canonical_relative_path-or
       $proof.axml_parser.aapt2_sha256-cne$aapt2TrustBinding.executable_sha256-or
       $proof.variants[0].packaged_manifest_axml_dump_sha256-cne$debugAxmlDumpBinding.PackagedManifestAxmlDumpSha256-or
       $proof.variants[0].packaged_a11y_axml_dump_sha256-cne$debugAxmlDumpBinding.PackagedA11yAxmlDumpSha256-or
       $proof.variants[1].packaged_manifest_axml_dump_sha256-cne$releaseAxmlDumpBinding.PackagedManifestAxmlDumpSha256-or
       $proof.variants[1].packaged_a11y_axml_dump_sha256-cne$releaseAxmlDumpBinding.PackagedA11yAxmlDumpSha256){
        throw 'C1b archived proof identity/Git/challenge 绑定失败。'
    }
    foreach($entry in @(
        [pscustomobject]@{Guard=$archivedDebugApkGuard;Expected=$artifactProofBinding.Debug.ApkSha256;Name='debug APK'}
        [pscustomobject]@{Guard=$archivedReleaseApkGuard;Expected=$artifactProofBinding.Release.ApkSha256;Name='release APK'}
        [pscustomobject]@{Guard=$archivedDebugManifestGuard;Expected=$artifactProofBinding.Debug.MergedManifestSha256;Name='debug merged manifest'}
        [pscustomobject]@{Guard=$archivedReleaseManifestGuard;Expected=$artifactProofBinding.Release.MergedManifestSha256;Name='release merged manifest'}
    )){
        if([string]$entry.Guard.Sha256-cne[string]$entry.Expected){throw "C1b archived $($entry.Name) hash 绑定失败。"}
    }
    foreach($variant in @(
        [pscustomobject]@{Path=$archivedDebugApkPath;Binding=$artifactProofBinding.Debug;Name='debug'}
        [pscustomobject]@{Path=$archivedReleaseApkPath;Binding=$artifactProofBinding.Release;Name='release'}
    )){
        if(-not[bool]$variant.Binding.PackagedManifestExactTreeVerified-or
           -not[bool]$variant.Binding.PackagedA11yExactTreeVerified){
            throw "C1b archived $($variant.Name) packaged AXML exact-tree 证明缺失。"
        }
        $zipProof=Get-TL1C1bZipDexProof $variant.Path
        if($zipProof.EntryCount-ne$variant.Binding.DexEntryCount-or$zipProof.Sha256-cne$variant.Binding.DexSha256-or
           $zipProof.CatalogSha256-cne$variant.Binding.DexCatalogSha256-or
           $zipProof.PackagedManifestSha256-cne$variant.Binding.PackagedManifestSha256){
            throw "C1b archived $($variant.Name) packaged manifest/DEX 绑定失败。"
        }
    }
    if($null-eq$archivedSignerSha-or$archivedSignerSha-cne$signerSha){
        throw 'C1b archived debug APK signer 绑定失败。'
    }
}
function Assert-C1bHostReadOnlyFrozenState {
    if($null-eq$staticReadOnlyProof-or$null-eq$t0ReadOnlyProof){throw 'C1b host read-only proof 尚未建立。'}
    $currentRunner=Assert-TL1C1bRunnerReadOnlyAst $PSCommandPath
    $currentT0=Assert-TL1C1bT0ReadOnlySurface $T0Runner $T0Library
    if($currentRunner.runner_sha256-cne$staticReadOnlyProof.runner_sha256-or
       $currentT0.runner_sha256-cne$t0ReadOnlyProof.runner_sha256-or
       $currentT0.library_sha256-cne$t0ReadOnlyProof.library_sha256){
        throw 'C1b host read-only AST proof 漂移。'
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
    $result=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name $Name -Value $Uri -TimeoutSec 30 `
        -ProcessEnvironment $adbEnvironment -ClearEnvironment `
        -PrivateAdbServerGuard $adbServerGuard
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
    $JavaHome=[string]$env:JAVA_HOME;$GradleHome=[string]$env:TL1_C1B_GRADLE_HOME
    $sourceAndroidSdkRoot=[string]$env:ANDROID_SDK_ROOT;$sourceAndroidHome=[string]$env:ANDROID_HOME
    if([string]::IsNullOrWhiteSpace($JavaHome)){throw 'C1b 必须显式设置 JAVA_HOME。'}
    if([string]::IsNullOrWhiteSpace($GradleHome)){throw 'C1b 必须显式设置 TL1_C1B_GRADLE_HOME。'}
    if([string]::IsNullOrWhiteSpace($sourceAndroidSdkRoot)-or[string]::IsNullOrWhiteSpace($sourceAndroidHome)){throw 'C1b 必须显式设置 ANDROID_SDK_ROOT 与 ANDROID_HOME。'}
    if(-not[IO.Path]::IsPathFullyQualified($sourceAndroidSdkRoot)-or-not[IO.Path]::IsPathFullyQualified($sourceAndroidHome)){throw 'C1b Android SDK source roots 必须是绝对路径。'}
    $sourceAndroidSdkRoot=[IO.Path]::GetFullPath($sourceAndroidSdkRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $sourceAndroidHome=[IO.Path]::GetFullPath($sourceAndroidHome).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if(-not[StringComparer]::OrdinalIgnoreCase.Equals($sourceAndroidSdkRoot,$sourceAndroidHome)){throw 'C1b ANDROID_SDK_ROOT/ANDROID_HOME source roots 不一致。'}
    $sourceAdbPath=[IO.Path]::GetFullPath((Join-Path $sourceAndroidSdkRoot 'platform-tools\adb.exe'))
    if(-not[StringComparer]::OrdinalIgnoreCase.Equals($AdbPath,$sourceAdbPath)){throw '-AdbPath 必须是 source Android SDK 的 canonical platform-tools/adb.exe。'}
    foreach($path in @($ImplementationPaths.Values)){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)-or((Get-Item $path -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw "C1b 依赖缺失或非普通文件：$path"}
    }
    . $NativePathValidator; . $C1aLibrary; . $Validator; . $Library; . $ReadOnlyLibrary
    . $ArtifactProofLibrary; . $Aapt2Library; . $BuildEnvironmentLibrary; . $AdbServerLibrary; . $DispatchLockLibrary
    $staticReadOnlyProof=Assert-TL1C1bRunnerReadOnlyAst $PSCommandPath
    $t0ReadOnlyProof=Assert-TL1C1bT0ReadOnlySurface $T0Runner $T0Library
    Assert-C1bHostReadOnlyFrozenState
    $deviceLease=Open-DispatchLock -Path (Get-DispatchGlobalLockPath) `
        -Owner "tablet-layout-c1b:$ExpectedCommitSha"
    $gitPath=Find-C1bTrustedGitPath
    $repositoryInputPaths=[Collections.Generic.List[string]]::new()
    foreach($path in $ImplementationPaths.Values){
        $relative=[IO.Path]::GetRelativePath($RepoRoot,[IO.Path]::GetFullPath([string]$path)).Replace('\','/')
        if($relative.StartsWith('../',[StringComparison]::Ordinal)-or[IO.Path]::IsPathFullyQualified($relative)){throw 'C1b repository input 越出仓库。'}
        $repositoryInputPaths.Add($relative)
    }
    $repositoryInputs=[string[]]@($repositoryInputPaths|Sort-Object -CaseSensitive -Unique)
    if($repositoryInputs.Count-ne$ImplementationPaths.Count){throw 'C1b repository input/implementation closure 非一一对应。'}
    $repositoryInputDirectories=[string[]]@(
        'app/tablet-c1b-probe/src/main',
        'app/gateway/src/main/java/dev/magina/gateway/tablet',
        'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b'
    )
    $buildEnvironmentGuard=Open-TL1C1bBuildEnvironmentTrustGuard `
        -RepoRoot $RepoRoot -JavaHome $JavaHome -GradleHome $GradleHome `
        -AndroidSdkRoot $sourceAndroidSdkRoot -GitPath $gitPath `
        -GradleUserHomeParent ([IO.Path]::GetTempPath()) `
        -RepositoryInputPaths $repositoryInputs `
        -RepositoryInputDirectories $repositoryInputDirectories
    $buildEnvironmentBinding=Assert-TL1C1bBuildEnvironmentFrozen $buildEnvironmentGuard
    $buildEnvironmentBindingRaw=$buildEnvironmentBinding|ConvertTo-Json -Depth 20 -Compress
    $AndroidSdkRoot=[IO.Path]::GetFullPath([string]$buildEnvironmentGuard.AndroidSdkRoot)
    $AndroidHome=$AndroidSdkRoot
    $AdbPath=[IO.Path]::GetFullPath((Join-Path $AndroidSdkRoot 'platform-tools\adb.exe'))
    $buildEnvironment=Get-TL1C1bBuildEnvironmentBuildEnvironment $buildEnvironmentGuard
    $gitEnvironment=Get-TL1C1bBuildEnvironmentGitEnvironment $buildEnvironmentGuard
    $adbUserProfile=Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'ADB user profile'
    $adbTrustEnvironment=@{
        SYSTEMROOT=[string]$buildEnvironmentGuard.HostPaths.SystemRoot
        WINDIR=[string]$buildEnvironmentGuard.HostPaths.SystemRoot
        COMSPEC=[string]$buildEnvironmentGuard.HostPaths.CmdPath
        PATHEXT='.COM;.EXE;.BAT;.CMD'
        PATH=[string]$buildEnvironmentGuard.HostPaths.SystemDirectory
        TEMP=[string]$buildEnvironment['TEMP'];TMP=[string]$buildEnvironment['TMP']
        USERPROFILE=$adbUserProfile;HOME=$adbUserProfile
        ANDROID_SDK_ROOT=$AndroidSdkRoot;ANDROID_HOME=$AndroidHome
    }
    $testOnlySynthetic=$null-ne$buildEnvironmentGuard.PSObject.Properties['TestOnlySynthetic']-and[bool]$buildEnvironmentGuard.TestOnlySynthetic
    if($testOnlySynthetic){
        foreach($name in @('TL1_C1B_E2E_STATE','TL1_C1B_E2E_SCENARIO')){
            if($buildEnvironment.Contains($name)){$adbTrustEnvironment[$name]=[string]$buildEnvironment[$name]}
        }
    }
    Write-Host ([string]::Format(
        'C1b ACL recovery reference: journal={0}; sha256={1}',
        $buildEnvironmentGuard.RecoveryJournal.Path,
        $buildEnvironmentBinding.recovery_journal.sha256))
    $adbTrustBefore=Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -ProcessEnvironment $adbTrustEnvironment -ClearEnvironment
    $aapt2TrustGuard=Open-TL1C1bAapt2TrustGuard -RepoRoot $RepoRoot -AndroidSdkRoot $AndroidSdkRoot -AndroidHome $AndroidHome
    $aapt2TrustBinding=$aapt2TrustGuard.Binding
    [void](Assert-TL1C1aGitProvenance $RepoRoot $ExpectedCommitSha `
        -GitPath $buildEnvironmentGuard.GitPath `
        -ProcessEnvironment $gitEnvironment -ClearEnvironment)
    $implementationHashes=Get-C1bImplementationHashes;Assert-C1bFrozenState
    $buildChallenge='c1b-'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $buildEnvironment['TABLET_C1B_BUILD_CHALLENGE']=$buildChallenge
    $buildEnvironment['TL1_C1B_EXPECTED_COMMIT_SHA']=$ExpectedCommitSha
    $gradleInvocation=Get-TL1C1bBuildEnvironmentGradleInvocation $buildEnvironmentGuard
    $signerInvocation=Get-TL1C1bBuildEnvironmentApkSignerInvocation $buildEnvironmentGuard
    $Java=[string]$gradleInvocation.FilePath
    if($Java-cne[string]$signerInvocation.FilePath){throw 'C1b Gradle/apksigner 未绑定同一 held Java。'}
    $signerArguments=[string[]]@($signerInvocation.Arguments)
    $gradleArguments=[string[]]@(
        @($gradleInvocation.Arguments)+
        @(Get-TL1C1bBuildEnvironmentGradleArguments $buildEnvironmentGuard)+
        @('-p',(Join-Path $RepoRoot 'app'),':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact',
          '--dependency-verification=strict','--no-build-cache','--no-configuration-cache',
          '--rerun-tasks','--no-daemon','--console=plain','--quiet')
    )
    $buildStarted=[DateTime]::UtcNow
    [void](Invoke-TL1C1aProcess -FilePath $Java -Arguments $gradleArguments `
        -Operation 'fresh C1b dedicated read-only APK 构建与闭包证明' `
        -Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300)
    Assert-C1bFrozenState
    foreach($freshPath in @($Apk,$ReleaseApk,$ArtifactProof)){
        if(-not(Test-Path -LiteralPath $freshPath -PathType Leaf)){throw "fresh C1b dedicated artifact 缺失：$freshPath。"}
        $freshItem=Get-Item $freshPath -Force
        if(($freshItem.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$freshItem.LastWriteTimeUtc-lt$buildStarted.AddSeconds(-2)){
            throw "C1b dedicated artifact 不是本轮 fresh build：$freshPath。"
        }
    }
    $artifactProofGuard=Open-TL1C1bArtifactGuard $RepoRoot $ArtifactProof
    $debugApkGuard=Open-TL1C1bArtifactGuard $RepoRoot $Apk
    $releaseApkGuard=Open-TL1C1bArtifactGuard $RepoRoot $ReleaseApk
    $artifactProofBinding=Assert-TL1C1bReadOnlyArtifactProof -RepoRoot $RepoRoot -ProofPath $ArtifactProof `
        -ProofSchemaPath $ArtifactProofSchema -ExpectedCommitSha $ExpectedCommitSha `
        -BuildChallenge $buildChallenge -DebugApkPath $Apk -Aapt2TrustBinding $aapt2TrustBinding `
        -ProofGuard $artifactProofGuard `
        -DebugApkGuard $debugApkGuard -ReleaseApkGuard $releaseApkGuard
    $debugMergedManifestGuard=Open-TL1C1bArtifactGuard $RepoRoot $artifactProofBinding.Debug.MergedManifestPath
    $releaseMergedManifestGuard=Open-TL1C1bArtifactGuard $RepoRoot $artifactProofBinding.Release.MergedManifestPath
    if($debugMergedManifestGuard.Sha256-cne$artifactProofBinding.Debug.MergedManifestSha256-or
       $releaseMergedManifestGuard.Sha256-cne$artifactProofBinding.Release.MergedManifestSha256){
        throw 'C1b merged manifest guard 绑定失败。'
    }
    $debugAxmlDumpBinding=Get-TL1C1bPackagedAxmlDumpBinding -TrustGuard $aapt2TrustGuard `
        -ArtifactGuard $debugApkGuard -Variant debug `
        -ProcessEnvironment $buildEnvironment -ClearEnvironment
    $releaseAxmlDumpBinding=Get-TL1C1bPackagedAxmlDumpBinding -TrustGuard $aapt2TrustGuard `
        -ArtifactGuard $releaseApkGuard -Variant release `
        -ProcessEnvironment $buildEnvironment -ClearEnvironment
    $expectedArtifactSha=$artifactProofBinding.Debug.ApkSha256
    Assert-C1bArtifactFrozenState
    $signerResult=Invoke-TL1C1aProcess -FilePath $Java `
        -Arguments ([string[]]@($signerArguments+@('verify','--print-certs',$Apk))) `
        -Operation 'C1b debug APK signer 证书复核' -Environment $buildEnvironment `
        -ClearEnvironment -TimeoutSec 60
    $signerSha=ConvertFrom-C1bSignerDigest $signerResult.Text

    $adbServerGuard=Open-TL1C1bPrivateAdbServerGuard `
        -AdbPath $AdbPath -ProcessEnvironment $adbTrustEnvironment
    $adbServerBinding=Assert-TL1C1bPrivateAdbServerGuardUnchanged $adbServerGuard
    if($adbServerBinding.server_executable_sha256-cne$adbTrustBefore.executable_sha256){
        throw 'C1b private adb server executable 未绑定受信 adb。'
    }
    $adbServerBindingRaw=$adbServerBinding|ConvertTo-Json -Depth 5 -Compress
    $adbEnvironment=Get-TL1C1bPrivateAdbClientEnvironment $adbServerGuard
    [void](Assert-C1bPrivateAdbServerFrozenState)

    $serial=Get-TL1C1aSingleDevice $AdbPath -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard;$serialHash=Get-TL1C1aSha256Text $serial
    $preBinding=Test-TL1C1aDeviceBinding `
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name fingerprint -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text `
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name boot_id -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    # 唯一一次 install；任何失败都直接冻结本轮，代码中没有 uninstall/retry 分支。
    [void](Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name install -Value $Apk -TimeoutSec 180 -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard)
    $installedPathBefore=Get-TL1C1aInstalledApkPath (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name package_path -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    $installedPathHashBefore=Get-TL1C1aSha256Text $installedPathBefore
    $installedShaBefore=Get-TL1C1aInstalledApkHostSha256 $AdbPath $serial $installedPathBefore 180 -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard
    if($installedShaBefore-cne$expectedArtifactSha){throw 'C1b installed APK 与本地 APK 不一致。'}
    $packageBefore=Get-TL1C1aPackageBinding (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name package_dump -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    $a11y=Wait-TL1C1aA11yReady $AdbPath $serial -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard
    if(-not$a11y.Ready){
        $needsUserPayload=[pscustomobject][ordered]@{schema='tablet-layout-c1b-needs-user/v1';status='needs-user';reason_code='a11y_service_not_enabled_or_bound';settings_changed=$false;retry_allowed_after_user_action=$true}
        throw 'C1b 需要用户启用并绑定无障碍服务。'
    }

    $runId=(New-TL1C1aRunId)-replace'c1a','c1b';$runDirectory=Join-Path $EvidenceRoot $runId
    $pwsh=(Get-Process -Id $PID).Path
    $t0Environment=[hashtable]$adbEnvironment.Clone()
    $t0Environment['TL1_C1A_PWSH_PATH']=$pwsh;$t0Environment['TL1_C1A_T0_SIDECAR_SCRIPT']=$T0AdbScript
    $t0Environment['TL1_C1A_REAL_ADB_PATH']=$AdbPath;$t0Environment['TL1_C1A_BOUND_SERIAL']=$serial
    $t0Environment['TL1_C1A_T0_LIBRARY_PATH']=$T0Library;$t0Environment['TL1_C1A_DISPATCH_LOCK_LIBRARY']=$DispatchLockLibrary
    $t0Environment['AGENT_MOBILE_DEVICE_LOCK_LEASE']=[string]$deviceLease.LeaseToken
    [void](Invoke-TL1C1bPrivateAdbGuardedProcess -Guard $adbServerGuard -FilePath $pwsh `
        -Arguments @('-NoProfile','-File',$T0Runner,'-AdbPath',$T0AdbCmd,'-RunId',$runId) `
        -Operation 'fresh T0-L v5' -ProcessEnvironment $t0Environment -ClearEnvironment `
        -TimeoutSec 180 -ClientKind T0Root)
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
    $archivedProofPath=Join-Path $c1bDirectory 'tablet-c1b-read-only-artifact-proof-v1.json'
    $archivedDebugApkPath=Join-Path $c1bDirectory 'tablet-c1b-probe-debug.apk'
    $archivedReleaseApkPath=Join-Path $c1bDirectory 'tablet-c1b-probe-release-unsigned.apk'
    $archivedDebugManifestPath=Join-Path $c1bDirectory 'tablet-c1b-probe-debug-merged-AndroidManifest.xml'
    $archivedReleaseManifestPath=Join-Path $c1bDirectory 'tablet-c1b-probe-release-merged-AndroidManifest.xml'
    $archivedProofGuard=Copy-TL1C1bGuardedArtifactAtomic $RepoRoot $artifactProofGuard $archivedProofPath $artifactProofBinding.ProofSha256
    $archivedDebugApkGuard=Copy-TL1C1bGuardedArtifactAtomic $RepoRoot $debugApkGuard $archivedDebugApkPath $artifactProofBinding.Debug.ApkSha256
    $archivedReleaseApkGuard=Copy-TL1C1bGuardedArtifactAtomic $RepoRoot $releaseApkGuard $archivedReleaseApkPath $artifactProofBinding.Release.ApkSha256
    $archivedDebugManifestGuard=Copy-TL1C1bGuardedArtifactAtomic $RepoRoot $debugMergedManifestGuard $archivedDebugManifestPath $artifactProofBinding.Debug.MergedManifestSha256
    $archivedReleaseManifestGuard=Copy-TL1C1bGuardedArtifactAtomic $RepoRoot $releaseMergedManifestGuard $archivedReleaseManifestPath $artifactProofBinding.Release.MergedManifestSha256
    $archivedSignerResult=Invoke-TL1C1aProcess -FilePath $Java `
        -Arguments ([string[]]@($signerArguments+@('verify','--print-certs',$archivedDebugApkPath))) `
        -Operation 'C1b archived debug APK signer 证书复核' -Environment $buildEnvironment `
        -ClearEnvironment -TimeoutSec 60
    $archivedSignerSha=ConvertFrom-C1bSignerDigest $archivedSignerResult.Text
    Assert-C1bArchivedArtifactEvidence

    $nonce='n-'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $uris=[ordered]@{t0=New-TL1C1bUri t0 $runId $nonce $ExpectedCommitSha $expectedArtifactSha;status=New-TL1C1bUri status $runId $nonce
        c1=New-TL1C1bUri c1 $runId $nonce;c2=New-TL1C1bUri c2 $runId $nonce;result=New-TL1C1bUri result $runId $nonce;abort=New-TL1C1bUri abort $runId $nonce}
    $endpointSetSha=Get-TL1C1aSha256Text (@($uris.GetEnumerator()|%{"$($_.Key)=$($_.Value)"})-join"`n")
    $sessionStarted=$true
    $write=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name content_t0 -Value $uris.t0 -InputBytes $t0Bytes -TimeoutSec 30 -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard
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
    $result=Invoke-TL1C1bAdb -AdbPath $AdbPath -Serial $serial -Name content_result -Value $uris.result -TimeoutSec 30 -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard
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

    $postSerial=Get-TL1C1aSingleDevice $AdbPath -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard;$postSerialHash=Get-TL1C1aSha256Text $postSerial
    $postBinding=Test-TL1C1aDeviceBinding `
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name fingerprint -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text `
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name boot_id -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    if($postSerial-cne$serial-or$postBinding.FingerprintHash-cne$preBinding.FingerprintHash-or$postBinding.BootIdHash-cne$preBinding.BootIdHash){throw 'C1b device binding 前后漂移。'}
    $adbTrustAfter=Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -ProcessEnvironment $adbTrustEnvironment -ClearEnvironment
    if($adbTrustAfter.executable_sha256-cne$adbTrustBefore.executable_sha256-or$adbTrustAfter.version_output_sha256-cne$adbTrustBefore.version_output_sha256-or
       $adbTrustAfter.signature_status-cne$adbTrustBefore.signature_status-or
       $adbTrustAfter.signature_subject-cne$adbTrustBefore.signature_subject-or
       $adbTrustAfter.signature_certificate_sha256-cne$adbTrustBefore.signature_certificate_sha256-or
       $adbTrustAfter.protocol_version-cne$adbTrustBefore.protocol_version-or$adbTrustAfter.package_version-cne$adbTrustBefore.package_version){throw 'C1b adb transport trust binding 前后漂移。'}
    $installedPathAfter=Get-TL1C1aInstalledApkPath (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name package_path -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    $installedPathHashAfter=Get-TL1C1aSha256Text $installedPathAfter;$installedShaAfter=Get-TL1C1aInstalledApkHostSha256 $AdbPath $serial $installedPathAfter 180 -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard
    $localShaAfter=Get-TL1C1aFileSha256 $Apk;$packageAfter=Get-TL1C1aPackageBinding (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name package_dump -ProcessEnvironment $adbEnvironment -ClearEnvironment -PrivateAdbServerGuard $adbServerGuard).Text
    if($installedPathAfter-cne$installedPathBefore-or$installedShaAfter-cne$installedShaBefore-or$localShaAfter-cne$expectedArtifactSha-or
        $packageAfter.PackageName-cne$packageBefore.PackageName-or$packageAfter.VersionName-cne$packageBefore.VersionName-or$packageAfter.VersionCode-ne$packageBefore.VersionCode){throw 'C1b APK/package 前后漂移。'}
    $secrets=@($serial,$nonce,$buildChallenge);Assert-TL1C1aNoRawSecret $observationRaw $secrets
    $observationPath=Join-Path $c1bDirectory 'tablet-layout-observation-c1b-v1.json';[void](Write-TL1C1aBytesAtomic $RepoRoot $observationPath $result.Bytes);$observationSha=Get-TL1C1aFileSha256 $observationPath
    $validation=Test-TabletLayoutObservationC1BV1TrustedRuntimeFile $observationPath $c1bDirectory $runId $ExpectedCommitSha $expectedArtifactSha
    if(-not$validation.fixture_contract_valid-or-not$validation.runtime_binding_inputs_match-or$validation.runtime_origin_verified-or$validation.runtime_evidence-or$validation.layout_accepted-or$validation.execution_grant){throw 'C1b observation validator scope/binding 失败。'}
    $validationPath=Join-Path $c1bDirectory 'tablet-layout-observation-validation-c1b-v1.json';$validationRaw=$validation|ConvertTo-Json -Depth 40 -Compress;Assert-TL1C1aNoRawSecret $validationRaw $secrets
    $validationBytes=[Text.UTF8Encoding]::new($false).GetBytes($validationRaw);try{[void](Write-TL1C1aBytesAtomic $RepoRoot $validationPath $validationBytes)}finally{[Array]::Clear($validationBytes,0,$validationBytes.Length)};$validationSha=Get-TL1C1aFileSha256 $validationPath
    Assert-C1bFrozenState;Assert-C1bArtifactFrozenState;Assert-C1bHostReadOnlyFrozenState
    if($staticReadOnlyProof.runner_sha256-cne$implementationHashes.runner_sha256-or
       $t0ReadOnlyProof.runner_sha256-cne$implementationHashes.t0_runner_sha256-or
       $t0ReadOnlyProof.library_sha256-cne$implementationHashes.t0_library_sha256){
        throw 'C1b host read-only AST proof 与 implementation hashes 未绑定。'
    }
    $readOnlyCounts=ConvertTo-TL1C1bReadOnlyCounts `
        -CaptureTuple ([pscustomobject][ordered]@{c1_requests_accepted=[long]1;c2_requests_accepted=[long]1;result_read_count=[long]1;recapture_count=[long]0}) `
        -ControlTuple ([pscustomobject][ordered]@{c1_requests_accepted=[long]$complete.c1_requests_accepted;c2_requests_accepted=[long]$complete.c2_requests_accepted;committed_tokens=[object[]]@($complete.committed_tokens);recapture_count=[long]$complete.recapture_count}) `
        -StaticProof $staticReadOnlyProof
    $hostForbiddenCommandCount=0L
    foreach($property in $staticReadOnlyProof.static_zero_counts.PSObject.Properties){$hostForbiddenCommandCount+=[long]$property.Value}
    if($hostForbiddenCommandCount-ne0){throw 'C1b host read-only static proof 非零。'}
    # /result 也可能合法返回 control 且不消费 provider session；只有 observation 的 exact
    # bytes 已经通过 strict parse、独立锚点、schema/validator 与冻结绑定后才视为已消费。
    $sessionConsumed=$true
    [void](Assert-C1bPrivateAdbServerFrozenState)
    $adbServerCleanupBinding=Close-TL1C1bPrivateAdbServerGuard $adbServerGuard
    if(-not$adbServerCleanupBinding.server_cleanup_verified-or
       -not$adbServerCleanupBinding.private_kill_server_requested-or
       -not$adbServerCleanupBinding.port_rebind_verified-or
       ([bool]$adbServerCleanupBinding.graceful_exit_verified-eq[bool]$adbServerCleanupBinding.job_fallback_used)){
        throw 'C1b private adb server cleanup proof 不完整。'
    }
    $adbEnvironment=$null

    $sidecar=[ordered]@{schema=$script:TL1C1bSidecarSchema;run_id=$runId;completed_at_utc=Get-C1bTimestamp;expected_commit_sha=$ExpectedCommitSha;capture_scope='pure_a11y'
        provenance_strategy='clean_content_provider_independently_attested';static_read_only_policy_version=$script:TL1C1bReadOnlyPolicy;implementation_hashes=$implementationHashes
        build_environment=$buildEnvironmentBinding
        transport=[ordered]@{trust_root=$adbTrustBefore.trust_root;canonical_relative_path=$adbTrustBefore.canonical_relative_path;sdk_roots_equal=$true;executable_sha256_before=$adbTrustBefore.executable_sha256;executable_sha256_after=$adbTrustAfter.executable_sha256;version_output_sha256_before=$adbTrustBefore.version_output_sha256;version_output_sha256_after=$adbTrustAfter.version_output_sha256
            signature_status=$adbTrustBefore.signature_status;signature_subject=$adbTrustBefore.signature_subject;signature_certificate_sha256_before=$adbTrustBefore.signature_certificate_sha256;signature_certificate_sha256_after=$adbTrustAfter.signature_certificate_sha256
            protocol_version=$adbTrustBefore.protocol_version;package_version=$adbTrustBefore.package_version;installed_as_canonical=$true
            server_schema=$adbServerBinding.schema;server_mode=$adbServerBinding.server_mode;server_socket=$adbServerBinding.server_socket
            server_executable_sha256=$adbServerBinding.server_executable_sha256;job_kill_on_close=[bool]$adbServerBinding.job_kill_on_close
            listener_pid_verified=[bool]$adbServerBinding.listener_pid_verified;server_status_executable_path_verified=[bool]$adbServerBinding.server_status_executable_path_verified
            server_ready_verified=[bool]$adbServerBinding.server_ready_verified;server_cleanup_verified=[bool]$adbServerCleanupBinding.server_cleanup_verified
            private_kill_server_requested=[bool]$adbServerCleanupBinding.private_kill_server_requested;graceful_exit_verified=[bool]$adbServerCleanupBinding.graceful_exit_verified
            job_fallback_used=[bool]$adbServerCleanupBinding.job_fallback_used;port_rebind_verified=[bool]$adbServerCleanupBinding.port_rebind_verified
            default_server_used=[bool]$adbServerBinding.default_server_used}
        apk=[ordered]@{fresh_build=$true;install_attempt_count=1;uninstall_count=0;automatic_retry_count=0;local_sha256_before=$expectedArtifactSha;local_sha256_after=$localShaAfter
            installed_base_apk_path_hash_before=$installedPathHashBefore;installed_base_apk_path_hash_after=$installedPathHashAfter;installed_base_apk_sha256_before=$installedShaBefore;installed_base_apk_sha256_after=$installedShaAfter
            signer_certificate_sha256=$signerSha;package_name_before=$packageBefore.PackageName;package_name_after=$packageAfter.PackageName;version_name_before=$packageBefore.VersionName;version_name_after=$packageAfter.VersionName;version_code_before=$packageBefore.VersionCode;version_code_after=$packageAfter.VersionCode}
        device=[ordered]@{serial_hash_before=$serialHash;serial_hash_after=$postSerialHash;fingerprint_hash_before=$preBinding.FingerprintHash;fingerprint_hash_after=$postBinding.FingerprintHash;boot_id_hash_before=$preBinding.BootIdHash;boot_id_hash_after=$postBinding.BootIdHash;unique_device_before_after=$true}
        upstream_t0=[ordered]@{producer_commit_sha='4ca32b131007df58f7752c5ee9b2d049cb1cd54e';original_relative_path=$t0SourceRelative;original_sha256=$t0Sha;original_byte_count=$t0Bytes.Length;original_crlf_count=$crlf;original_bytes_forwarded=$true;exec_in_write_count=1;device_binding_verified=$true}
        provider=[ordered]@{authority=$script:TL1C1bAuthority;protocol_version='1';package_name=$complete.provider.package_name;version_name=$complete.provider.version_name;version_code=$complete.provider.version_code;embedded_git_head=$complete.provider.embedded_git_head
            build_challenge_hash=Get-TL1C1aSha256Text $buildChallenge;expected_title_hash=$script:TL1C1bExpectedTitleHash;producer_artifact_sha256=$expectedArtifactSha;a11y_service_ready=$true;control_transcript_sha256=Get-TL1C1bTranscriptSha256 $controlRaw.ToArray();endpoint_set_sha256=$endpointSetSha}
        capture=[ordered]@{generation=$generation;c1_requested_at_utc=$c1Requested;c1_committed_at_utc=$c1Committed;c2_requested_at_utc=$c2Requested;c2_committed_at_utc=$c2Committed;host_wait_ms=[long]$hostWait.ElapsedMilliseconds;total_span_ms=[long]$captureWatch.ElapsedMilliseconds;status_poll_count=$statusReadCount;c1_requests_accepted=1;c2_requests_accepted=1;result_read_count=1;recapture_count=0}
        artifacts=[ordered]@{
            upstream_t0=[ordered]@{relative_path='upstream-t0-v5.json';sha256=$t0Sha}
            observation=[ordered]@{relative_path='tablet-layout-observation-c1b-v1.json';sha256=$observationSha}
            validation=[ordered]@{relative_path='tablet-layout-observation-validation-c1b-v1.json';sha256=$validationSha}
            artifact_proof=[ordered]@{relative_path='tablet-c1b-read-only-artifact-proof-v1.json';sha256=$archivedProofGuard.Sha256}
            debug_apk=[ordered]@{relative_path='tablet-c1b-probe-debug.apk';sha256=$archivedDebugApkGuard.Sha256}
            release_apk=[ordered]@{relative_path='tablet-c1b-probe-release-unsigned.apk';sha256=$archivedReleaseApkGuard.Sha256}
            debug_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-debug-merged-AndroidManifest.xml';sha256=$archivedDebugManifestGuard.Sha256}
            release_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-release-merged-AndroidManifest.xml';sha256=$archivedReleaseManifestGuard.Sha256}
        }
        read_only_counts=$readOnlyCounts
        read_only_proof=[ordered]@{schema='tablet-layout-c1b-read-only-proof/v1';policy_version=$script:TL1C1bReadOnlyPolicy;artifact_module=':tablet-c1b-probe';artifact_proof_relative_path=$script:TL1C1bArtifactProofRelativePath;artifact_proof_sha256=$artifactProofBinding.ProofSha256
            runner_ast_sha256=$staticReadOnlyProof.runner_sha256;t0_runner_ast_sha256=$t0ReadOnlyProof.runner_sha256;t0_library_ast_sha256=$t0ReadOnlyProof.library_sha256;host_forbidden_command_count=$hostForbiddenCommandCount
            axml_parser=[ordered]@{schema=$aapt2TrustBinding.schema;trust_root=$aapt2TrustBinding.trust_root;build_tools_version=$aapt2TrustBinding.build_tools_version;canonical_relative_path=$aapt2TrustBinding.canonical_relative_path;sdk_roots_equal=[bool]$aapt2TrustBinding.sdk_roots_equal;executable_sha256=$aapt2TrustBinding.executable_sha256;signature_status=$aapt2TrustBinding.signature_status;signature_subject=$aapt2TrustBinding.signature_subject;signature_certificate_sha256=$aapt2TrustBinding.signature_certificate_sha256}
            packaged_axml_exact_verified=([bool]$artifactProofBinding.Debug.PackagedManifestExactTreeVerified-and[bool]$artifactProofBinding.Debug.PackagedA11yExactTreeVerified-and[bool]$artifactProofBinding.Release.PackagedManifestExactTreeVerified-and[bool]$artifactProofBinding.Release.PackagedA11yExactTreeVerified)
            dependency_artifact_catalog_sha256=$artifactProofBinding.DependencyArtifactCatalogSha256
            debug_apk_sha256=$artifactProofBinding.Debug.ApkSha256;debug_merged_manifest_sha256=$artifactProofBinding.Debug.MergedManifestSha256;debug_packaged_manifest_sha256=$artifactProofBinding.Debug.PackagedManifestSha256;debug_packaged_manifest_axml_dump_sha256=$debugAxmlDumpBinding.PackagedManifestAxmlDumpSha256;debug_packaged_a11y_axml_dump_sha256=$debugAxmlDumpBinding.PackagedA11yAxmlDumpSha256;debug_dex_entry_count=$artifactProofBinding.Debug.DexEntryCount;debug_dex_sha256=$artifactProofBinding.Debug.DexSha256;debug_dex_catalog_sha256=$artifactProofBinding.Debug.DexCatalogSha256
            release_apk_sha256=$artifactProofBinding.Release.ApkSha256;release_merged_manifest_sha256=$artifactProofBinding.Release.MergedManifestSha256;release_packaged_manifest_sha256=$artifactProofBinding.Release.PackagedManifestSha256;release_packaged_manifest_axml_dump_sha256=$releaseAxmlDumpBinding.PackagedManifestAxmlDumpSha256;release_packaged_a11y_axml_dump_sha256=$releaseAxmlDumpBinding.PackagedA11yAxmlDumpSha256;release_dex_entry_count=$artifactProofBinding.Release.DexEntryCount;release_dex_sha256=$artifactProofBinding.Release.DexSha256;release_dex_catalog_sha256=$artifactProofBinding.Release.DexCatalogSha256
            artifact_forbidden_match_count=$artifactProofBinding.ForbiddenMatchCount;manifest_mutating_capability_count=$artifactProofBinding.ManifestMutatingCapabilityCount;manifest_extra_component_count=$artifactProofBinding.ManifestExtraComponentCount;dependency_allowlist_verified=$artifactProofBinding.DependencyAllowlistVerified}
        attestations=[ordered]@{full_clean_head_verified=$true;implementation_hashes_verified=$true;origin_binding_verified=$true;probe_entrypoint_read_only=$true;dedicated_read_only_artifact_verified=$true;host_read_only_ast_verified=$true;observation_schema_valid=$true;artifact_hashes_recomputed=$true}
        claims=[ordered]@{runtime_origin_verified=$true;runtime_evidence=$true;wechat_window_ownership_observed=[bool]$validation.wechat_window_ownership_observed;wechat_window_ownership_verified=[bool]$validation.wechat_window_ownership_observed
            window_root_projection_observed=[bool]$validation.window_root_projection_observed;window_root_projection_verified=[bool]$validation.window_root_projection_observed;application_window_topology_observed=[bool]$validation.application_window_topology_observed;application_window_topology_verified=[bool]$validation.application_window_topology_observed
            ime_hidden_observed=[bool]$validation.ime_hidden_observed;ime_hidden_verified=[bool]$validation.ime_hidden_observed;semantic_tree_usable=[bool]$validation.semantic_tree_usable;navigation_pane_verified=$false;conversation_pane_verified=$false;target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false}
        cleanup=[ordered]@{required=$false;status='not_required';abort_attempt_count=0}}
    Assert-TL1C1bSidecarCrossBindings $sidecar
    $artifactMap=@{
        $t0Source=$t0Sha;$t0Path=$t0Sha;$observationPath=$observationSha;$validationPath=$validationSha
        $archivedProofPath=$archivedProofGuard.Sha256;$archivedDebugApkPath=$archivedDebugApkGuard.Sha256
        $archivedReleaseApkPath=$archivedReleaseApkGuard.Sha256;$archivedDebugManifestPath=$archivedDebugManifestGuard.Sha256
        $archivedReleaseManifestPath=$archivedReleaseManifestGuard.Sha256
    }
    Assert-C1bFrozenState;Assert-C1bArtifactFrozenState;Assert-C1bHostReadOnlyFrozenState
    Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap;Assert-C1bArchivedArtifactEvidence
    $prePublishAdbTrust=Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -ProcessEnvironment $adbTrustEnvironment -ClearEnvironment
    if($prePublishAdbTrust.executable_sha256-cne$adbTrustBefore.executable_sha256-or
       $prePublishAdbTrust.version_output_sha256-cne$adbTrustBefore.version_output_sha256-or
       $prePublishAdbTrust.signature_status-cne$adbTrustBefore.signature_status-or
       $prePublishAdbTrust.signature_subject-cne$adbTrustBefore.signature_subject-or
       $prePublishAdbTrust.signature_certificate_sha256-cne$adbTrustBefore.signature_certificate_sha256){throw 'C1b pre-publish adb trust binding 漂移。'}
    $sidecarRaw=$sidecar|ConvertTo-Json -Depth 40 -Compress;Assert-TL1C1aNoRawSecret $sidecarRaw $secrets
    if(-not($sidecarRaw|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)){throw 'C1b success sidecar schema 失败。'}
    $sidecarPath=Join-Path $c1bDirectory 'tablet-layout-c1b-sidecar-v1.json'
    $pendingSidecarBytes=[Text.UTF8Encoding]::new($false).GetBytes($sidecarRaw)
    $successMessage="T-L1 C1b 受控只读采集完成：$sidecarPath";$exitCode=0
}catch{
    if($null-ne$needsUserPayload){$exitCode=2}else{$failure=$_.Exception.Message;$exitCode=1}
}
finally{
    if($sessionStarted-and-not$sessionConsumed-and-not$abortAttempted-and$serial-and$nonce){$abortAttempted=$true;try{$abort=Read-C1bControl content_abort $uris.abort;Assert-TL1C1bAbortTerminalControl $abort $abortExpectedGeneration $abortExpectedC1Count $abortExpectedC2Count $abortExpectedCommitted;$abortSucceeded=$true}catch{$abortSucceeded=$false}}
    $cleanupFailures=[Collections.Generic.List[string]]::new()
    if($null-ne$adbServerGuard-and-not[bool]$adbServerGuard.Disposed){
        try{$adbServerCleanupBinding=Close-TL1C1bPrivateAdbServerGuard $adbServerGuard}
        catch{$cleanupFailures.Add($_.Exception.Message)}
    }
    foreach($guard in @(
        $archivedReleaseManifestGuard,$archivedDebugManifestGuard,$archivedReleaseApkGuard,$archivedDebugApkGuard,$archivedProofGuard,
        $releaseMergedManifestGuard,$debugMergedManifestGuard,$releaseApkGuard,$debugApkGuard,$artifactProofGuard,
        $aapt2TrustGuard
    )){if($null-ne$guard){try{$guard.Guard.Dispose()}catch{$cleanupFailures.Add($_.Exception.Message)}}}
    if($null-ne$buildEnvironmentGuard){try{Close-TL1C1bBuildEnvironmentTrustGuard $buildEnvironmentGuard}catch{$cleanupFailures.Add($_.Exception.Message)}}
    if($null-ne$deviceLease){try{[void](Close-DispatchLockLease -Lease $deviceLease)}catch{$cleanupFailures.Add($_.Exception.Message)}}
    if($cleanupFailures.Count-ne0){
        $cleanupFailure='C1b guard cleanup 未完整完成：'+($cleanupFailures-join' | ')
        if([string]::IsNullOrWhiteSpace($failure)){$failure=$cleanupFailure}else{$failure+='；'+$cleanupFailure}
        $exitCode=1;$needsUserPayload=$null
    }
}
if($exitCode-eq0){
    try{
        if($null-eq$pendingSidecarBytes-or$pendingSidecarBytes.Length-eq0){throw 'C1b success sidecar staging bytes 缺失。'}
        [void](Write-TL1C1aBytesAtomic $RepoRoot $sidecarPath $pendingSidecarBytes -PostWriteValidation {
            $publishedPath=Assert-TL1C1aOrdinaryPath $RepoRoot $sidecarPath
            $publishedBytes=[IO.File]::ReadAllBytes($publishedPath);$publishedRaw=ConvertFrom-TL1C1aStrictUtf8 $publishedBytes 'C1b published sidecar'
            try{
                $published=ConvertFrom-TL1C1bClosedJson $publishedRaw
                if($null-eq$published-or-not($publishedRaw|Test-Json -SchemaFile $SidecarSchema -ErrorAction SilentlyContinue)){throw 'C1b published sidecar strict/schema readback 失败。'}
                Assert-TL1C1bSidecarCrossBindings $published;Assert-TL1C1aNoRawSecret $publishedRaw $secrets
                Assert-TL1C1bPublishedEvidenceBinding $RepoRoot $artifactMap
                Assert-C1bImplementationSnapshot
            }finally{if($publishedBytes.Length){[Array]::Clear($publishedBytes,0,$publishedBytes.Length)}}
        })
    }catch{$failure=$_.Exception.Message;$exitCode=1;$successMessage=$null}
    finally{if($null-ne$pendingSidecarBytes-and$pendingSidecarBytes.Length){[Array]::Clear($pendingSidecarBytes,0,$pendingSidecarBytes.Length)};$pendingSidecarBytes=$null}
}elseif($null-ne$pendingSidecarBytes){
    if($pendingSidecarBytes.Length){[Array]::Clear($pendingSidecarBytes,0,$pendingSidecarBytes.Length)};$pendingSidecarBytes=$null
}
if($exitCode-eq0){Write-Host $successMessage;exit 0}
if($exitCode-eq2){$needsUserPayload|ConvertTo-Json -Compress;exit 2}
try{Write-C1bFailureEvidence 'c1b_runner_failed'}catch{if($failure){$failure+='；且 failure evidence 写入失败。'}else{$failure='C1b failure evidence 写入失败。'}}
[Console]::Error.WriteLine("T-L1 C1b 失败：$failure");exit 1
