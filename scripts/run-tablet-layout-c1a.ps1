#Requires -Version 7.5
<#
T-L1 C1a 平板原生双窗只读真机 runner。

唯一公开入口只接受绝对 adb、完整固定 HEAD 与显式 -Provision。它会 fresh build/install debug APK，
但不启动 Activity/Service，不调用 MCP/forward/dispatch，不点击、不输入、不截图、不改系统设置。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdbPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ExpectedCommitSha,
    [switch]$Provision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$LibraryPath = Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1'
$ValidatorPath = Join-Path $PSScriptRoot 'lib\tablet-layout-observation-v2-validator.ps1'
$SidecarSchemaPath = Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1a-sidecar-v1.schema.json'
$T0RunnerPath = Join-Path $PSScriptRoot 'run-tablet-intake.ps1'
$T0LibraryPath = Join-Path $PSScriptRoot 'lib\tablet-intake.ps1'
$T0AdbSidecarPath = Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.cmd'
$T0AdbSidecarScriptPath = Join-Path $PSScriptRoot 'lib\tablet-layout-c1a-t0-adb-sidecar.ps1'
$DispatchLockPath = Join-Path $PSScriptRoot 'lib\dispatch-lock.ps1'
$GradlePath = Join-Path $RepoRoot 'app\gradlew.bat'
$ApkPath = Join-Path $RepoRoot 'app\gateway\build\outputs\apk\debug\gateway-debug.apk'
$EvidenceRoot = Join-Path $RepoRoot 'docs\runs\evidence'
$ImplementationPaths = [ordered]@{
    runner_sha256 = $PSCommandPath
    c1a_library_sha256 = $LibraryPath
    t0_adb_sidecar_cmd_sha256 = $T0AdbSidecarPath
    t0_adb_sidecar_script_sha256 = $T0AdbSidecarScriptPath
    validator_sha256 = $ValidatorPath
    sidecar_schema_sha256 = $SidecarSchemaPath
}

$runId = $null
$runDirectory = $null
$c1aDirectory = $null
$sessionStarted = $false
$sessionConsumed = $false
$abortAttempted = $false
$abortSucceeded = $false
$abortCleanupStatus = 'not_required'
$serial = $null
$nonce = $null
$expectedArtifactSha = $null
$buildChallenge = $null
$failure = $null
$implementationHashes = $null
$dispatchLockSha256 = $null
$deviceLease = $null
$needsUserPayload = $null
$sidecarPath = $null
$sidecarBytes = $null
$successDiagnostic = $null
$exitCode = 1

function Get-ControlRaw {
    param([Parameter(Mandatory)]$Result)
    return $Result.Text
}

function Get-C1aImplementationHashSnapshot {
    $snapshot = [ordered]@{}
    foreach ($entry in $ImplementationPaths.GetEnumerator()) {
        $snapshot[[string]$entry.Key] = Get-TL1C1aFileSha256 ([string]$entry.Value)
    }
    return $snapshot
}

function Assert-C1aImplementationHashSnapshot {
    if ($null -eq $implementationHashes) { throw 'C1a implementation hash snapshot 未冻结。' }
    foreach ($entry in $ImplementationPaths.GetEnumerator()) {
        $name = [string]$entry.Key
        if ((Get-TL1C1aFileSha256 ([string]$entry.Value)) -cne [string]$implementationHashes[$name]) {
            throw "C1a implementation 漂移：$name。"
        }
    }
}

function Assert-C1aDispatchLockHashSnapshot {
    if ([string]::IsNullOrWhiteSpace($dispatchLockSha256)) {
        throw 'C1a dispatch-lock hash snapshot 未冻结。'
    }
    if ((Get-TL1C1aFileSha256 $DispatchLockPath) -cne $dispatchLockSha256) {
        throw 'C1a production dispatch-lock 漂移。'
    }
}

function Assert-C1aFrozenLocalState {
    [void](Assert-TL1C1aGitProvenance -RepoRoot $RepoRoot -ExpectedCommitSha $ExpectedCommitSha)
    Assert-C1aImplementationHashSnapshot
    Assert-C1aDispatchLockHashSnapshot
}

function Write-C1aFailureEvidence {
    param([Parameter(Mandatory)][string]$ReasonCode)
    if ([string]::IsNullOrWhiteSpace($c1aDirectory) -or -not (Test-Path -LiteralPath $c1aDirectory -PathType Container)) {
        return
    }
    $path = Join-Path $c1aDirectory 'tablet-layout-c1a-failure.json'
    if (Test-Path -LiteralPath $path) { return }
    $payload = [ordered]@{
        schema = 'tablet-layout-c1a-failure/v1'
        run_id = $runId
        status = 'failed'
        reason_code = $ReasonCode
        cleanup = if (-not $sessionStarted -or $sessionConsumed) { 'not_required' }
            elseif ($abortAttempted -and $abortSucceeded) { $abortCleanupStatus } else { 'failed' }
        c1a_origin_binding_verified = $false
        c1a_probe_entrypoint_read_only = $false
        observation_schema_valid = $false
        runtime_evidence = $false
        layout_accepted = $false
        wechat_layout_verified = $false
        editor_action_ready = $false
        p0_capability = 'unsupported'
        execution_grant = $false
    }
    [void](Write-TL1C1aJsonAtomic -RepoRoot $RepoRoot -Destination $path -Value $payload)
}

try {
    if (-not $Provision) { throw 'C1a 真机入口必须显式传入 -Provision。' }
    if (-not [IO.Path]::IsPathFullyQualified($AdbPath)) { throw '-AdbPath 必须是绝对路径。' }
    $AdbPath = [IO.Path]::GetFullPath($AdbPath)
    if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { throw '-AdbPath 指向的文件不存在。' }
    if ((Get-Item -LiteralPath $AdbPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw '-AdbPath 不得是 reparse point。'
    }
    if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$') {
        throw '-ExpectedCommitSha 必须是完整小写 40 位 Git SHA。'
    }
    foreach ($required in @(
        $LibraryPath,$ValidatorPath,$T0RunnerPath,$T0LibraryPath,$T0AdbSidecarPath,
        $T0AdbSidecarScriptPath,$DispatchLockPath,$GradlePath,$SidecarSchemaPath
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少 C1a 依赖：$required" }
        if (((Get-Item -LiteralPath $required -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "C1a 依赖不得是 reparse point：$required"
        }
    }
    . $LibraryPath
    . $ValidatorPath

    # 所有设备访问之前先冻结本地来源；构建前、构建后、证据完成后三次复核同一 HEAD/clean/blob。
    [void](Assert-TL1C1aGitProvenance -RepoRoot $RepoRoot -ExpectedCommitSha $ExpectedCommitSha)
    $implementationHashes = Get-C1aImplementationHashSnapshot
    Assert-C1aImplementationHashSnapshot
    $dispatchLockSha256 = Get-TL1C1aFileSha256 $DispatchLockPath
    . $DispatchLockPath
    Assert-C1aFrozenLocalState
    $deviceLease = Open-DispatchLock -Path (Get-DispatchGlobalLockPath) `
        -Owner "tablet-layout-c1a:$ExpectedCommitSha" -LeaseToken ''
    $apksigner = Find-TL1C1aApkSigner
    $buildChallenge = 'c1a-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $buildStarted = [DateTime]::UtcNow
    $build = Invoke-TL1C1aProcess -FilePath $GradlePath -Arguments @(
        '-p',(Join-Path $RepoRoot 'app'),':gateway:clean',':gateway:assembleDebug','--no-daemon','--console=plain','--quiet'
    ) -Operation 'fresh C1a debug APK 构建' -Environment @{
        TABLET_C1A_BUILD_CHALLENGE = $buildChallenge
        TL1_C1A_EXPECTED_COMMIT_SHA = $ExpectedCommitSha
    } -TimeoutSec 300
    [void]$build
    Assert-C1aFrozenLocalState
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw 'fresh build 未生成固定 debug APK。' }
    $apkItem = Get-Item -LiteralPath $ApkPath -Force
    if (($apkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $apkItem.LastWriteTimeUtc -lt $buildStarted.AddSeconds(-2)) { throw 'debug APK 不是本轮 fresh build 普通文件。' }
    $expectedArtifactSha = Get-TL1C1aFileSha256 $ApkPath
    $signerSha = Get-TL1C1aSignerDigest -ApkSignerPath $apksigner -ApkPath $ApkPath

    $serial = Get-TL1C1aSingleDevice -AdbPath $AdbPath
    $serialHash = Get-TL1C1aSha256Text $serial
    $preFingerprint = (Invoke-TL1C1aAdb $AdbPath $serial fingerprint).Text
    $preBoot = (Invoke-TL1C1aAdb $AdbPath $serial boot_id).Text
    $preBinding = Test-TL1C1aDeviceBinding -Fingerprint $preFingerprint -BootId $preBoot

    # Provision 只有一次 install；失败即停，不做卸载或盲重试。
    [void](Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name install -Value $ApkPath -TimeoutSec 180)
    $installedPathBefore = Get-TL1C1aInstalledApkPath (
        (Invoke-TL1C1aAdb $AdbPath $serial package_path).Text
    )
    $installedPathHashBefore = Get-TL1C1aSha256Text $installedPathBefore
    $installedShaBefore = Get-TL1C1aInstalledApkHostSha256 -AdbPath $AdbPath -Serial $serial `
        -RemotePath $installedPathBefore -TimeoutSec 180
    if ($installedShaBefore -cne $expectedArtifactSha) { throw 'installed base.apk 与本地 fresh APK SHA-256 不一致。' }
    $packageBindingBefore = Get-TL1C1aPackageBinding (
        (Invoke-TL1C1aAdb $AdbPath $serial package_dump).Text
    )

    $a11y = Wait-TL1C1aA11yReady -AdbPath $AdbPath -Serial $serial
    if (-not $a11y.Ready) {
        $needsUserPayload = [pscustomobject][ordered]@{
            schema = 'tablet-layout-c1a-needs-user/v1'
            status = 'needs-user'
            reason_code = 'a11y_service_not_enabled_or_bound'
            settings_changed = $false
            retry_allowed_after_user_action = $true
        }
        throw 'C1a 需要用户启用并绑定无障碍服务。'
    }

    $runId = New-TL1C1aRunId
    $runDirectory = Join-Path $EvidenceRoot $runId
    # fresh T0 是同一 run_id 的固定 clean producer；输出后只读取原始 BOM-less bytes。
    $pwsh = (Get-Process -Id $PID).Path
    $t0 = Invoke-TL1C1aProcess -FilePath $pwsh -Arguments @(
        '-NoProfile','-File',$T0RunnerPath,'-AdbPath',$T0AdbSidecarPath,'-RunId',$runId
    ) -Operation 'fresh T0-L v5' -Environment @{
        TL1_C1A_PWSH_PATH = $pwsh
        TL1_C1A_T0_SIDECAR_SCRIPT = $T0AdbSidecarScriptPath
        TL1_C1A_REAL_ADB_PATH = $AdbPath
        TL1_C1A_BOUND_SERIAL = $serial
        TL1_C1A_T0_LIBRARY_PATH = $T0LibraryPath
        TL1_C1A_DISPATCH_LOCK_LIBRARY = $DispatchLockPath
        AGENT_MOBILE_DEVICE_LOCK_LEASE = [string]$deviceLease.LeaseToken
    } -TimeoutSec 180
    [void]$t0
    $t0Path = Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path (Join-Path $runDirectory 'tablet-profile.json')
    $t0Bytes = [IO.File]::ReadAllBytes($t0Path)
    if ($t0Bytes.Length -lt 1 -or $t0Bytes.Length -gt 65536) { throw 'fresh T0 raw bytes 超出 app 构造边界。' }
    $t0Raw = ConvertFrom-TL1C1aStrictUtf8 -Bytes $t0Bytes -Operation 'fresh T0'
    $t0Issues = [Collections.Generic.List[object]]::new()
    $t0Object = ConvertFrom-TL1V2StrictJson $t0Raw $t0Issues -CheckSyntheticPrivacyCanary
    if ($null -eq $t0Object -or $t0Issues.Count -ne 0) { throw 'fresh T0 strict JSON 复核失败。' }
    Assert-TL1C1aT0DeviceBinding -T0 $t0Object -RunId $runId -SerialHash $serialHash `
        -FingerprintHash $preBinding.FingerprintHash
    $t0ArtifactSha = Get-TL1C1aSha256Bytes $t0Bytes

    $c1aDirectory = Join-Path $runDirectory 'tablet-layout-c1a'
    [void](Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path $c1aDirectory -AllowMissingLeaf)
    if (Test-Path -LiteralPath $c1aDirectory) { throw 'C1a evidence 目录已存在，拒绝覆盖。' }
    New-Item -ItemType Directory -Path $c1aDirectory | Out-Null
    $c1aDirectoryItem = Get-Item -LiteralPath $c1aDirectory -Force
    if (-not $c1aDirectoryItem.PSIsContainer -or
        ($c1aDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'C1a evidence 目录不是普通目录。'
    }
    [void](Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot `
        -Path (Join-Path $c1aDirectory '.path-guard.json') -AllowMissingLeaf)
    $validatorT0Path = Join-Path $c1aDirectory 'upstream-t0-v5.json'
    [void](Write-TL1C1aBytesAtomic -RepoRoot $RepoRoot -Destination $validatorT0Path -Bytes $t0Bytes)
    if ((Get-TL1C1aFileSha256 $validatorT0Path) -cne $t0ArtifactSha) { throw 'T0 原始 bytes 固定副本漂移。' }

    $nonce = 'n-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $t0Uri = New-TL1C1aUri -Endpoint t0 -RunId $runId -Nonce $nonce `
        -ExpectedCommitSha $ExpectedCommitSha -ArtifactSha256 $expectedArtifactSha
    $statusUri = New-TL1C1aUri status $runId $nonce
    $c1Uri = New-TL1C1aUri c1 $runId $nonce
    $c2Uri = New-TL1C1aUri c2 $runId $nonce
    $resultUri = New-TL1C1aUri result $runId $nonce
    $abortUri = New-TL1C1aUri abort $runId $nonce

    # open/write 过程中即可能已在 provider 建立 session；先标记，任何失败都尝试一次 abort。
    $sessionStarted = $true
    $t0Write = Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_t0 `
        -Value $t0Uri -InputBytes $t0Bytes -TimeoutSec 30
    if ($t0Write.Bytes.Length -ne 0 -or $t0Write.Stderr.Length -ne 0) {
        throw 'content write 必须只完成匿名管道写入，不得伪造 ACK 输出。'
    }
    # AOSP content write 不从 write FD 返回 ACK；provider 在首次 status 内 bounded wait reader 完成。
    # 宿主只读一次 status，不轮询、不盲重试。
    $statusAck = ConvertFrom-TL1C1aControl (
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_status -Value $statusUri).Text
    ) $runId $ExpectedCommitSha $expectedArtifactSha $buildChallenge awaiting_c1 capture_c1 $null
    foreach ($control in @($statusAck)) {
        if ($control.provider.version_name -cne $packageBindingBefore.VersionName -or
            [long]$control.provider.version_code -ne $packageBindingBefore.VersionCode) {
            throw 'provider package/version 与 installed package 不一致。'
        }
    }

    # 两帧只有这一条序列：一次 c1，宿主等待 >=900 ms，一次 c2；不补拍、不轮询。
    $captureWatch = [Diagnostics.Stopwatch]::StartNew()
    $c1Ack = ConvertFrom-TL1C1aControl (
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_c1 -Value $c1Uri -TimeoutSec 30).Text
    ) $runId $ExpectedCommitSha $expectedArtifactSha $buildChallenge awaiting_c2 capture_c2 'c1'
    $hostWait = [Diagnostics.Stopwatch]::StartNew()
    while ($hostWait.ElapsedMilliseconds -lt 900) {
        Start-Sleep -Milliseconds ([Math]::Min(100, 900 - [int]$hostWait.ElapsedMilliseconds))
    }
    $hostWait.Stop()
    if ($captureWatch.Elapsed.TotalSeconds -ge 15) { throw 'C1a 在 c2 前已超出 15 秒总门，拒绝补拍。' }
    $c2Ack = ConvertFrom-TL1C1aControl (
        (Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_c2 -Value $c2Uri -TimeoutSec 30).Text
    ) $runId $ExpectedCommitSha $expectedArtifactSha $buildChallenge complete read_result 'c2'
    $captureWatch.Stop()
    if ($hostWait.ElapsedMilliseconds -lt 900 -or $captureWatch.Elapsed.TotalSeconds -gt 15) {
        throw 'C1a 两帧宿主时序越界。'
    }
    foreach ($control in @($c1Ack,$c2Ack)) {
        if ($control.provider.version_name -cne $packageBindingBefore.VersionName -or
            [long]$control.provider.version_code -ne $packageBindingBefore.VersionCode) {
            throw 'capture provider package/version 与 installed package 不一致。'
        }
    }

    $result = Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_result -Value $resultUri -TimeoutSec 30
    $observationRaw = ConvertFrom-TL1C1aStrictUtf8 -Bytes $result.Bytes -Operation 'C1a observation'
    $runtimeSecrets = [object[]]@(
        $serial,$preFingerprint.Trim(),$preBoot.Trim(),$preBoot.Trim().ToLowerInvariant(),$nonce,$buildChallenge
    )
    Assert-TL1C1aNoRawSecret -Content $observationRaw -Secrets $runtimeSecrets
    $resultIssues = [Collections.Generic.List[object]]::new()
    $resultObject = ConvertFrom-TL1V2StrictJson $observationRaw $resultIssues -CheckPrivacy
    if ($null -eq $resultObject -or $resultIssues.Count -ne 0 -or
        $resultObject.schema -cne $script:TL1C1aObservationSchema) {
        throw 'result 未返回 strict tablet-layout-observation/v2。'
    }
    # provider 只有在返回 observation 的这条分支才单次消费并清理 session。
    $sessionConsumed = $true

    $postFingerprint = (Invoke-TL1C1aAdb $AdbPath $serial fingerprint).Text
    $postBoot = (Invoke-TL1C1aAdb $AdbPath $serial boot_id).Text
    $postSerial = Get-TL1C1aSingleDevice -AdbPath $AdbPath
    if ($postSerial -cne $serial) { throw 'C1a 前后唯一设备 serial 漂移。' }
    $postSerialHash = Get-TL1C1aSha256Text $postSerial
    $postBinding = Test-TL1C1aDeviceBinding -Fingerprint $postFingerprint -BootId $postBoot
    if ($postBinding.FingerprintHash -cne $preBinding.FingerprintHash -or
        $postBinding.BootIdHash -cne $preBinding.BootIdHash) { throw '设备 fingerprint/boot 在 C1a 前后漂移。' }
    $installedPathAfter = Get-TL1C1aInstalledApkPath (
        (Invoke-TL1C1aAdb $AdbPath $serial package_path).Text
    )
    if ($installedPathAfter -cne $installedPathBefore) { throw 'installed base.apk path 在 C1a 前后漂移。' }
    $installedPathHashAfter = Get-TL1C1aSha256Text $installedPathAfter
    $installedShaAfter = Get-TL1C1aInstalledApkHostSha256 -AdbPath $AdbPath -Serial $serial `
        -RemotePath $installedPathAfter -TimeoutSec 180
    $localShaAfter = Get-TL1C1aFileSha256 $ApkPath
    if ($installedShaAfter -cne $installedShaBefore -or $installedShaAfter -cne $expectedArtifactSha -or
        $localShaAfter -cne $expectedArtifactSha) { throw 'local/installed APK 在 C1a 前后漂移。' }
    $packageBindingAfter = Get-TL1C1aPackageBinding (
        (Invoke-TL1C1aAdb $AdbPath $serial package_dump).Text
    )
    if ($packageBindingAfter.PackageName -cne $packageBindingBefore.PackageName -or
        $packageBindingAfter.VersionName -cne $packageBindingBefore.VersionName -or
        $packageBindingAfter.VersionCode -ne $packageBindingBefore.VersionCode) {
        throw 'installed package/version 在 C1a 前后漂移。'
    }
    $runtimeSecrets = [object[]]@(
        $serial,$postSerial,$preFingerprint.Trim(),$postFingerprint.Trim(),
        $preBoot.Trim(),$preBoot.Trim().ToLowerInvariant(),
        $postBoot.Trim(),$postBoot.Trim().ToLowerInvariant(),$nonce,$buildChallenge
    )
    Assert-TL1C1aNoRawSecret -Content $observationRaw -Secrets $runtimeSecrets
    $observationPath = Join-Path $c1aDirectory 'tablet-layout-observation-v2.json'
    [void](Write-TL1C1aBytesAtomic -RepoRoot $RepoRoot -Destination $observationPath -Bytes $result.Bytes)
    $observationSha = Get-TL1C1aFileSha256 $observationPath
    Assert-C1aFrozenLocalState

    $validation = Test-TabletLayoutObservationV2TrustedRuntimeFile -Path $observationPath `
        -EvidenceRoot $c1aDirectory -ExpectedRunId $runId `
        -ExpectedProducerCommitSha $ExpectedCommitSha -ExpectedProducerArtifactSha256 $expectedArtifactSha
    $validationPath = Join-Path $c1aDirectory 'tablet-layout-observation-validation-v2.json'
    $validationRaw = $validation | ConvertTo-Json -Depth 30 -Compress
    Assert-TL1C1aNoRawSecret -Content $validationRaw -Secrets $runtimeSecrets
    $validationBytes = [Text.UTF8Encoding]::new($false).GetBytes($validationRaw)
    try { [void](Write-TL1C1aBytesAtomic -RepoRoot $RepoRoot -Destination $validationPath -Bytes $validationBytes) }
    finally { if ($validationBytes.Length -gt 0) { [Array]::Clear($validationBytes, 0, $validationBytes.Length) } }
    $validationSha = Get-TL1C1aFileSha256 $validationPath
    $schemaValid = [bool]$validation.fixture_contract_valid
    if (-not $schemaValid -or [bool]$validation.runtime_evidence -or
        [bool]$validation.layout_accepted -or [bool]$validation.wechat_layout_verified -or
        [bool]$validation.editor_action_ready -or [bool]$validation.execution_grant -or
        [string]$validation.p0_capability -cne 'unsupported') { throw 'trusted-runtime validation 未保持 C1a claim scope。' }

    $sidecar = [ordered]@{
        schema = $script:TL1C1aSidecarSchema
        run_id = $runId
        completed_at_utc = [DateTime]::UtcNow.ToString('o')
        expected_commit_sha = $ExpectedCommitSha
        provenance_strategy = 'clean_port_content_attested'
        static_read_only_policy_version = 'tl1-c1a-read-only/v1'
        trusted_blobs = @($script:TL1C1aTrustedBlobs.GetEnumerator() | ForEach-Object {
            [ordered]@{ path = [string]$_.Key; blob_oid = [string]$_.Value }
        })
        implementation_hashes = $implementationHashes
        producer_baseline_sha = $script:TL1C1aProducerBaseline
        t0_baseline_sha = $script:TL1C1aT0Baseline
        title_hash = $script:TL1C1aExpectedTitleHash
        apk = [ordered]@{
            local_sha256_before = $expectedArtifactSha
            local_sha256_after = $localShaAfter
            installed_base_apk_path_hash_before = $installedPathHashBefore
            installed_base_apk_path_hash_after = $installedPathHashAfter
            installed_base_apk_sha256_before = $installedShaBefore
            installed_base_apk_sha256_after = $installedShaAfter
            signer_certificate_sha256 = $signerSha
            package_name_before = $packageBindingBefore.PackageName
            package_name_after = $packageBindingAfter.PackageName
            version_name_before = $packageBindingBefore.VersionName
            version_name_after = $packageBindingAfter.VersionName
            version_code_before = $packageBindingBefore.VersionCode
            version_code_after = $packageBindingAfter.VersionCode
            embedded_git_head = $c2Ack.provider.embedded_git_head
            build_challenge_hash = Get-TL1C1aSha256Text $buildChallenge
        }
        device = [ordered]@{
            serial_hash_before = $serialHash
            serial_hash_after = $postSerialHash
            fingerprint_hash_before = $preBinding.FingerprintHash
            fingerprint_hash_after = $postBinding.FingerprintHash
            boot_id_hash_before = $preBinding.BootIdHash
            boot_id_hash_after = $postBinding.BootIdHash
            unique_device_before_after = $true
        }
        upstream_t0 = [ordered]@{
            producer_commit_sha = $script:TL1C1aT0Baseline
            artifact_sha256 = $t0ArtifactSha
            original_bytes_forwarded = $true
        }
        capture = [ordered]@{
            tokens = @('c1','c2')
            host_wait_ms = [long]$hostWait.ElapsedMilliseconds
            total_span_ms = [long]$captureWatch.ElapsedMilliseconds
            recapture_count = 0
        }
        observation = [ordered]@{
            artifact_sha256 = $observationSha
            relative_path = 'tablet-layout-observation-v2.json'
        }
        validation = [ordered]@{
            artifact_sha256 = $validationSha
            relative_path = 'tablet-layout-observation-validation-v2.json'
        }
        c1a_origin_binding_verified = $true
        c1a_probe_entrypoint_read_only = $true
        observation_schema_valid = $true
        mcp_used = $false
        dispatch_used = $false
        screen_capture_used = $false
        settings_mutation_used = $false
        target_app_started = $false
        cleanup_status = 'not_required'
        runtime_evidence = $false
        layout_accepted = $false
        wechat_layout_verified = $false
        editor_action_ready = $false
        p0_capability = 'unsupported'
        execution_grant = $false
    }
    $sidecarPath = Join-Path $c1aDirectory 'tablet-layout-c1a-sidecar-v1.json'
    $sidecarRaw = $sidecar | ConvertTo-Json -Depth 30 -Compress
    Assert-TL1C1aNoRawSecret -Content $sidecarRaw -Secrets $runtimeSecrets
    Assert-C1aFrozenLocalState
    if ((Get-TL1C1aFileSha256 $ApkPath) -cne $expectedArtifactSha) { throw 'local APK 在 sidecar 发布前漂移。' }
    Assert-TL1C1aPublishedEvidenceBinding -RepoRoot $RepoRoot `
        -T0Path $validatorT0Path -T0Sha256 $t0ArtifactSha `
        -ObservationPath $observationPath -ObservationSha256 $observationSha `
        -ValidationPath $validationPath -ValidationSha256 $validationSha
    if (-not ($sidecarRaw | Test-Json -SchemaFile $SidecarSchemaPath -ErrorAction SilentlyContinue)) {
        throw 'C1a sidecar 未通过固定 schema。'
    }
    # 成功 sidecar 只暂存在内存；设备租约在 finally 中完整释放后才允许发布。
    $sidecarBytes = [Text.UTF8Encoding]::new($false).GetBytes($sidecarRaw)
    $successDiagnostic = [string]$validation.diagnostic_status
    $exitCode = 0
}
catch {
    if ($null -ne $needsUserPayload) { $exitCode = 2 }
    else { $failure = $_.Exception.Message; $exitCode = 1 }
}
finally {
    if ($sessionStarted -and -not $sessionConsumed -and -not $abortAttempted -and
        -not [string]::IsNullOrWhiteSpace($serial) -and -not [string]::IsNullOrWhiteSpace($nonce)) {
        $abortAttempted = $true
        try {
            $abortUri = New-TL1C1aUri abort $runId $nonce
            $abort = Invoke-TL1C1aAdb -AdbPath $AdbPath -Serial $serial -Name content_abort -Value $abortUri
            $cleanup = ConvertFrom-TL1C1aCleanupControl $abort.Text $runId $ExpectedCommitSha `
                $expectedArtifactSha $buildChallenge
            $abortCleanupStatus = [string]$cleanup.CleanupStatus
            $abortSucceeded = $true
        }
        catch {
            $abortSucceeded = $false
            if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'C1a cleanup 失败。' }
            else { $failure += '；且 C1a cleanup 失败。' }
            $exitCode = 1
            $needsUserPayload = $null
        }
    }
    if ($null -ne $deviceLease) {
        try {
            if (-not (Close-DispatchLockLease -Lease $deviceLease)) {
                throw '仍有子进程持有同一设备租约。'
            }
            $deviceLease = $null
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'C1a device lease cleanup 失败。' }
            else { $failure += '；且 device lease cleanup 失败。' }
            $exitCode = 1
            $needsUserPayload = $null
        }
    }
}

if ($exitCode -eq 0) {
    try {
        if ($null -eq $sidecarBytes -or [string]::IsNullOrWhiteSpace($sidecarPath)) {
            throw 'C1a success sidecar 未完成内存暂存。'
        }
        [void](Write-TL1C1aBytesAtomic -RepoRoot $RepoRoot -Destination $sidecarPath -Bytes $sidecarBytes `
            -PostWriteValidation {
                Assert-C1aFrozenLocalState
                if ((Get-TL1C1aFileSha256 $ApkPath) -cne $expectedArtifactSha) {
                    throw 'local APK 在 sidecar 发布后漂移。'
                }
                Assert-TL1C1aPublishedEvidenceBinding -RepoRoot $RepoRoot `
                    -T0Path $validatorT0Path -T0Sha256 $t0ArtifactSha `
                    -ObservationPath $observationPath -ObservationSha256 $observationSha `
                    -ValidationPath $validationPath -ValidationSha256 $validationSha
            })
    }
    catch {
        $failure = "C1a success sidecar 发布失败：$($_.Exception.Message)"
        $exitCode = 1
    }
}
if ($null -ne $sidecarBytes -and $sidecarBytes.Length -gt 0) {
    [Array]::Clear($sidecarBytes, 0, $sidecarBytes.Length)
}
$sidecarBytes = $null

if ($exitCode -eq 0) {
    Write-Host "T-L1 C1a 只读采集完成：$sidecarPath"
    Write-Host "diagnostic_status=$successDiagnostic runtime_evidence=false layout=false P0=unsupported exec=false"
    exit 0
}
if ($exitCode -eq 2 -and $null -ne $needsUserPayload) {
    $needsUserPayload | ConvertTo-Json -Compress
    exit 2
}

try { Write-C1aFailureEvidence -ReasonCode 'c1a_runner_failed' }
catch {
    if ([string]::IsNullOrWhiteSpace($failure)) { $failure = 'C1a failure evidence 写入失败。' }
    else { $failure += '；且 failure evidence 写入失败。' }
}
[Console]::Error.WriteLine("T-L1 C1a 失败：$failure")
exit 1
