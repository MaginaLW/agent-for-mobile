#Requires -Version 7.5
<#
T-L1 C1b 平板 pure-a11y 布局观测的简单 runner（替代旧固定候选主机链）。

一次调用 = 一次采集，不自动重试；换新 run_id 再次调用即可，不再有 once 标记。
流程：clean HEAD → 全局设备锁 → 单设备 → （可选）Gradle 构建探针 → install -r -t →
只读检查无障碍已启用并绑定 → T0-L v5 intake → C1b content 协议 → 证据落盘 → validator。

只读边界（App 代码不变，本脚本只做下列 adb 动作）：
* adb devices；adb -s <serial> install -r -t <apk>（不卸载）；
* shell settings get secure enabled_accessibility_services；shell dumpsys accessibility；
* exec-in content write（仅 C1b t0 URI）；shell content read（仅 C1b status/capture/result/abort URI）；
* 另调用只读的 scripts/run-tablet-intake.ps1。
不调用 input/tap/swipe/am start/settings put/uninstall/screencap，不修改任何设备设置；
无障碍未开启时只打印开启步骤并以 2 退出。

退出码：0 通过；1 失败；2 需要用户操作。
证据：docs/runs/evidence/<run_id>/tablet-layout-c1b/（已 gitignore），失败也写 run.json；
证据只记录 serial 的 sha256，不写原始 serial。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdbPath,
    [string]$Serial,
    [string]$ApkPath,
    [switch]$SkipBuild,
    [string]$RunId,
    # 仅离线测试：用给定 T0 画像代替真实 intake；生产调用不得传。
    [string]$TestOnlyT0ProfilePath,
    # 仅离线测试：-AdbPath 指向 fake adb 的 .ps1，由当前 pwsh 执行；生产调用不得传。
    [switch]$TestOnlyAdbIsScript
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$Authority = 'dev.magina.gateway.tablet.c1b'
$PackageName = 'dev.magina.gateway'
$A11yShort = 'dev.magina.gateway/.a11y.GatewayA11yService'
$TitleHash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
$T0ProducerSha = '4ca32b131007df58f7752c5ee9b2d049cb1cd54e'
$Pwsh = (Get-Process -Id $PID).Path

. (Join-Path $PSScriptRoot 'lib\dispatch-lock.ps1')
. (Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1')
. (Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-validator.ps1')

class C1bNeedsUser : Exception { C1bNeedsUser([string]$m) : base($m) {} }

function Get-Utc { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
function Get-Sha256Bytes([byte[]]$Bytes) { 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }
function Get-Sha256Text([string]$Text) { Get-Sha256Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) }

function Invoke-Process {
    param([string]$FilePath, [string[]]$Arguments, [byte[]]$InputBytes, [int]$TimeoutSec = 60, [string]$WorkingDirectory)
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($WorkingDirectory) { $info.WorkingDirectory = $WorkingDirectory }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $buffer = [IO.MemoryStream]::new()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($buffer)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($null -ne $InputBytes -and $InputBytes.Length) { $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "子进程超时（${TimeoutSec}s）。"
        }
        $process.WaitForExit(); $stdoutTask.Wait(); $stderrTask.Wait()
        $bytes = $buffer.ToArray()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode; Bytes = $bytes; Stderr = $stderrTask.Result
            Text = [Text.UTF8Encoding]::new($false).GetString($bytes)
        }
    }
    finally { $process.Dispose() }
}

function Invoke-Adb {
    param([string[]]$Arguments, [byte[]]$InputBytes, [int]$TimeoutSec = 30, [switch]$AllowFailure)
    $all = if ($script:SelectedSerial) { @('-s', $script:SelectedSerial) + $Arguments } else { $Arguments }
    $result = if ($TestOnlyAdbIsScript) {
        Invoke-Process $Pwsh (@('-NoProfile', '-NonInteractive', '-File', $AdbPath) + $all) $InputBytes $TimeoutSec
    } else { Invoke-Process $AdbPath $all $InputBytes $TimeoutSec }
    if (-not $AllowFailure -and $result.ExitCode -ne 0) {
        throw "adb $($Arguments[0..([Math]::Min(2, $Arguments.Count - 1))] -join ' ') 失败（exit $($result.ExitCode)）。"
    }
    return $result
}

function New-C1bUri([string]$Endpoint) {
    $path = switch ($Endpoint) { 'c1' { 'capture/c1' } 'c2' { 'capture/c2' } default { $Endpoint } }
    $uri = "content://$Authority/$path/$($script:Run.run_id)?nonce=$script:Nonce"
    if ($Endpoint -ceq 't0') {
        $uri += "&title_hash=$TitleHash&producer_commit_sha=$($script:Run.commit_sha)&producer_artifact_sha256=$($script:Run.apk_sha256)"
    }
    # 设备端 adbd 以 sh -c 解释 shell/exec-in 命令，URI 中的 & 必须整体单引号包裹。
    if ($uri -match "['\s%+]") { throw 'C1b URI 含非法字符。' }
    return "'$uri'"
}

function Read-C1bControl([string]$Endpoint) {
    $script:Run.capture.content_reads++
    $result = Invoke-Adb @('shell', 'content', 'read', '--uri', (New-C1bUri $Endpoint))
    $raw = $result.Text.Trim()
    try { $control = $raw | ConvertFrom-Json -Depth 20 -DateKind String } catch { throw "C1b $Endpoint 返回的不是 JSON control。" }
    if ($null -eq $control -or $control -isnot [pscustomobject] -or $null -eq $control.PSObject.Properties['schema'] -or
        $control.schema -cne 'tablet-c1b-control/v1') { throw "C1b $Endpoint control schema 不符。" }
    if ($control.run_id -cne $script:Run.run_id -or $control.provider.authority -cne $Authority -or
        $control.provider.package_name -cne $PackageName -or [long]$control.recapture_count -ne 0) {
        throw "C1b $Endpoint control 的 run_id/provider 绑定不符。"
    }
    if ($control.state -cne 'absent' -and ($control.expected_title_hash -cne $TitleHash -or
        $control.producer_commit_sha -cne $script:Run.commit_sha -or $control.producer_artifact_sha256 -cne $script:Run.apk_sha256)) {
        throw "C1b $Endpoint control 的 producer 绑定不符。"
    }
    if ($control.provider.embedded_git_head -cne $script:Run.commit_sha) {
        throw "设备上探针 APK 的 embedded_git_head 与 HEAD 不一致（APK 不是从当前 HEAD 构建）。"
    }
    return $control
}

function Assert-C1bState($Control, [string]$State, [int]$C1, [int]$C2, [string[]]$Committed, $InFlight) {
    $ok = $State -in @('ready_c1', 'capturing_c1', 'ready_c2', 'capturing_c2', 'complete')
    if ($Control.state -cne $State -or [bool]$Control.ok -ne $ok -or $null -ne $Control.reason_code -or
        [long]$Control.generation -ne $script:Run.capture.generation -or
        [long]$Control.c1_requests_accepted -ne $C1 -or [long]$Control.c2_requests_accepted -ne $C2 -or
        (@($Control.committed_tokens) -join ',') -cne ($Committed -join ',') -or $Control.in_flight_token -cne $InFlight) {
        throw "C1b control 状态漂移：期望 $State/gen=$($script:Run.capture.generation)，实际 $($Control.state)/gen=$($Control.generation)/reason=$($Control.reason_code)。"
    }
}

function Wait-C1bState([string]$Target, [Diagnostics.Stopwatch]$Watch) {
    $capturing = if ($Target -ceq 'ready_c2') { 'capturing_c1' } else { 'capturing_c2' }
    while ($Watch.ElapsedMilliseconds -lt 15000) {
        $script:Run.capture.status_polls++
        $control = Read-C1bControl 'status'
        if ($control.state -ceq $Target) { return $control }
        if ($control.state -cne $capturing) { throw "C1b 会话提前终止：$($control.state)/$($control.reason_code)。" }
        if ($capturing -ceq 'capturing_c1') { Assert-C1bState $control capturing_c1 1 0 @() 'c1' }
        else { Assert-C1bState $control capturing_c2 1 1 @('c1') 'c2' }
        Start-Sleep -Milliseconds 100
    }
    throw "C1b 等待 $Target 超过 15s 总时序门。"
}

function Set-Stage([string]$Name) { $script:Run.stage = $Name; $script:Run.timestamps[$Name] = Get-Utc }

$script:Run = [ordered]@{
    schema = 'tablet-c1b-run/v1'; run_id = $null; outcome = 'failed'; exit_code = 1; failure_reason = $null; stage = 'init'
    commit_sha = $null; apk_sha256 = $null; apk_built = (-not $SkipBuild); serial_sha256 = $null
    t0_sha256 = $null; observation_sha256 = $null
    timestamps = [ordered]@{ started_at = Get-Utc }
    capture = [ordered]@{ generation = $null; host_wait_ms = $null; total_span_ms = $null; status_polls = 0; content_reads = 0 }
    abort = [ordered]@{ attempted = $false; state = $null; reason_code = $null }
    validation = $null
}
$script:SelectedSerial = $null; $script:Nonce = $null
$sessionStarted = $false; $sessionConsumed = $false; $lease = $null; $evidenceDir = $null; $exitCode = 1

try {
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = 'c1b-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ').ToLowerInvariant() + '-' +
            [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(4)).ToLowerInvariant()
    }
    if ($RunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { throw 'run_id 只允许小写字母、数字、._-，长度 1..80。' }
    $script:Run.run_id = $RunId
    $runDir = Join-Path $RepoRoot "docs\runs\evidence\$RunId"
    if (Test-Path -LiteralPath $runDir) { throw "run_id 已存在证据目录，拒绝覆盖：$RunId" }
    $evidenceDir = Join-Path $runDir 'tablet-layout-c1b'
    if (-not [IO.Path]::IsPathFullyQualified($AdbPath) -or -not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
        throw '-AdbPath 必须是存在的绝对路径。'
    }

    Set-Stage 'git_checked'
    $status = Invoke-Process 'git' @('-C', $RepoRoot, 'status', '--porcelain', '--untracked-files=normal')
    if ($status.ExitCode -ne 0) { throw 'git status 失败。' }
    if ($status.Text.Trim().Length) { throw 'git 工作树不干净；请先提交或清理改动再采集。' }
    $head = (Invoke-Process 'git' @('-C', $RepoRoot, 'rev-parse', 'HEAD')).Text.Trim()
    if ($head -cnotmatch '^[0-9a-f]{40}$') { throw '无法取得完整 HEAD SHA。' }
    $script:Run.commit_sha = $head

    Set-Stage 'lock_acquired'
    $lease = Open-DispatchLock -Path (Get-DispatchGlobalLockPath) -Owner "tablet-c1b/$RunId"

    Set-Stage 'device_selected'
    $rows = @(((Invoke-Adb @('devices')).Text -split "`r?`n") | Select-Object -Skip 1 |
        ForEach-Object { [regex]::Match($_.Trim(), '^(\S+)\s+(\S+)') } | Where-Object Success |
        ForEach-Object { [pscustomobject]@{ Serial = $_.Groups[1].Value; State = $_.Groups[2].Value } })
    if ($rows.Count -eq 0) { throw [C1bNeedsUser]::new('未发现设备：请连接平板并在设备上允许 USB 调试。') }
    # T0 intake 只支持恰好一台设备；-Serial 只用于确认该台设备。
    if ($rows.Count -ne 1) { throw "要求恰好一台已连接设备，当前 $($rows.Count) 台；请断开其他设备。" }
    if ($Serial -and $rows[0].Serial -cne $Serial) { throw '-Serial 与唯一已连接设备不符。' }
    if ($rows[0].State -cne 'device') { throw [C1bNeedsUser]::new("设备状态为 $($rows[0].State)：请在设备上授权 USB 调试。") }
    $script:SelectedSerial = $rows[0].Serial
    $script:Run.serial_sha256 = Get-Sha256Text $script:SelectedSerial

    Set-Stage 'apk_ready'
    if (-not $SkipBuild) {
        $gradle = Join-Path $RepoRoot 'app\gradlew.bat'
        & $gradle -p (Join-Path $RepoRoot 'app') ':tablet-c1b-probe:assembleDebug' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw ":tablet-c1b-probe:assembleDebug 失败（exit $LASTEXITCODE）。" }
    }
    if (-not $ApkPath) {
        $apks = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'app\tablet-c1b-probe\build\outputs\apk\debug') -Filter '*.apk' -File -ErrorAction SilentlyContinue)
        if ($apks.Count -ne 1) { throw "未能唯一定位 debug APK（找到 $($apks.Count) 个）。" }
        $ApkPath = $apks[0].FullName
    }
    $ApkPath = [IO.Path]::GetFullPath($ApkPath)
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "APK 不存在：$ApkPath" }
    $script:Run.apk_sha256 = Get-Sha256Bytes ([IO.File]::ReadAllBytes($ApkPath))

    Set-Stage 'installed'
    $install = Invoke-Adb @('install', '-r', '-t', $ApkPath) -TimeoutSec 180 -AllowFailure
    if ($install.ExitCode -ne 0 -or $install.Text -notmatch '(?m)^Success') { throw "adb install 失败：$($install.Text.Trim()) $($install.Stderr.Trim())" }

    Set-Stage 'a11y_checked'
    $enabled = (Invoke-Adb @('shell', 'settings', 'get', 'secure', 'enabled_accessibility_services')).Text
    $a11y = Test-TL1C1aA11yReady -EnabledText $enabled -BoundText ''
    if (-not $a11y.Enabled) {
        Write-Host '需要用户操作：请在平板上开启无障碍服务后重新运行（本脚本不修改设置）：'
        Write-Host '  设置 → 无障碍 →（已下载的应用/已安装的服务）→「执行网关」→ 打开并确认授权。'
        throw [C1bNeedsUser]::new('无障碍服务 dev.magina.gateway/.a11y.GatewayA11yService 未启用。')
    }
    $boundWatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $bound = Test-TL1C1aA11yReady -EnabledText $enabled -BoundText (Invoke-Adb @('shell', 'dumpsys', 'accessibility')).Text
        if ($bound.Ready) { break }
        Start-Sleep -Milliseconds 1000
    } while ($boundWatch.Elapsed.TotalSeconds -lt 30)
    if (-not $bound.Ready) { throw [C1bNeedsUser]::new('无障碍已启用但服务未绑定：请在设置中关闭再打开「执行网关」后重试。') }

    Set-Stage 't0_captured'
    $t0Source = Join-Path $runDir 'tablet-profile.json'
    if ($TestOnlyT0ProfilePath) {
        [void](New-Item -ItemType Directory -Path $runDir)
        Copy-Item -LiteralPath $TestOnlyT0ProfilePath -Destination $t0Source
    } else {
        & $Pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-tablet-intake.ps1') -AdbPath $AdbPath -RunId $RunId | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "T0 intake 失败或设备不是平板（exit $LASTEXITCODE）。" }
    }
    $t0Bytes = [IO.File]::ReadAllBytes($t0Source)
    if ($t0Bytes.Length -notin 1..65536) { throw 'T0 字节数越界。' }
    $t0 = [Text.UTF8Encoding]::new($false, $true).GetString($t0Bytes) | ConvertFrom-Json -Depth 50 -DateKind String
    if ($t0.schema_version -ne 5 -or $t0.run_id -cne $RunId -or $t0.device.serial_hash -cne $script:Run.serial_sha256 -or
        $t0.assessment.intake_status -cne 'accepted' -or $t0.assessment.readiness_status -cne 'blocked' -or
        $t0.assessment.p0_capability -cne 'unsupported') {
        throw 'T0-L v5 画像不满足 C1b 前置（run_id/serial/accepted/blocked/unsupported）。'
    }
    $script:Run.t0_sha256 = Get-Sha256Bytes $t0Bytes
    [void](New-Item -ItemType Directory -Path $evidenceDir -Force)
    [IO.File]::WriteAllBytes((Join-Path $evidenceDir 'upstream-t0-v5.json'), $t0Bytes)

    Set-Stage 't0_written'
    $script:Nonce = 'n-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
    $sessionStarted = $true
    $write = Invoke-Adb @('exec-in', 'content', 'write', '--uri', (New-C1bUri 't0')) -InputBytes $t0Bytes
    if ($write.Bytes.Length -or $write.Stderr.Trim().Length) { throw "T0 write 返回了意外输出：$($write.Text.Trim()) $($write.Stderr.Trim())" }
    $start = Read-C1bControl 'status'
    if ($start.state -cne 'ready_c1' -or [long]$start.generation -lt 1) { throw "T0 写入后状态应为 ready_c1，实际 $($start.state)/$($start.reason_code)。" }
    $script:Run.capture.generation = [long]$start.generation
    Assert-C1bState $start ready_c1 0 0 @() $null
    if (-not $start.provider.a11y_service_ready) { throw 'provider 报告无障碍服务未就绪。' }

    Set-Stage 'c1_requested'
    $span = [Diagnostics.Stopwatch]::StartNew()
    $c1 = Read-C1bControl 'c1'
    if ($c1.state -cne 'ready_c2') { Assert-C1bState $c1 capturing_c1 1 0 @() 'c1'; $c1 = Wait-C1bState 'ready_c2' $span }
    Assert-C1bState $c1 ready_c2 1 0 @('c1') $null
    Set-Stage 'c1_committed'
    $hostWait = [Diagnostics.Stopwatch]::StartNew()
    while ($hostWait.ElapsedMilliseconds -lt 900) { Start-Sleep -Milliseconds ([Math]::Max(10, 900 - [int]$hostWait.ElapsedMilliseconds)) }
    $script:Run.capture.host_wait_ms = [long]$hostWait.ElapsedMilliseconds
    if ($span.ElapsedMilliseconds -ge 15000) { throw 'c2 前已超过 15s 总时序门。' }

    Set-Stage 'c2_requested'
    $c2 = Read-C1bControl 'c2'
    if ($c2.state -cne 'complete') { Assert-C1bState $c2 capturing_c2 1 1 @('c1') 'c2'; $c2 = Wait-C1bState 'complete' $span }
    Assert-C1bState $c2 complete 1 1 @('c1', 'c2') $null
    $script:Run.capture.total_span_ms = [long]$span.ElapsedMilliseconds
    if ($span.ElapsedMilliseconds -gt 15000) { throw 'c1→c2 总时长超过 15s。' }
    Set-Stage 'c2_committed'

    Set-Stage 'result_read'
    $result = Invoke-Adb @('shell', 'content', 'read', '--uri', (New-C1bUri 'result')) -TimeoutSec 60
    $observationBytes = $result.Bytes
    if ($observationBytes.Length -notin 1..1048576) { throw 'observation 字节数越界。' }
    $observationRaw = [Text.UTF8Encoding]::new($false, $true).GetString($observationBytes)
    if ($observationRaw.Contains($script:SelectedSerial) -or $observationRaw.Contains($script:Nonce)) { throw 'observation 含原始 serial 或 nonce。' }
    $observation = $observationRaw | ConvertFrom-Json -Depth 100 -DateKind String
    if ($observation.schema -cne 'tablet-layout-observation/c1b-v1' -or $observation.run_id -cne $RunId -or
        $observation.expected_title_hash -cne $TitleHash -or $observation.provenance.kind -cne 'gateway_runtime_probe' -or
        $observation.provenance.producer_commit_sha -cne $script:Run.commit_sha -or
        $observation.provenance.producer_artifact_sha256 -cne $script:Run.apk_sha256 -or
        $observation.upstream_t0.source_kind -cne 'trusted_runtime' -or $observation.upstream_t0.run_id -cne $RunId -or
        $observation.upstream_t0.artifact_sha256 -cne $script:Run.t0_sha256 -or
        $observation.upstream_t0.producer_commit_sha -cne $T0ProducerSha -or
        $observation.upstream_t0.captured_at -cne $t0.captured_at_utc) {
        throw 'observation 的 run_id/commit/artifact/T0 锚点与本次采集不一致。'
    }
    $sessionConsumed = $true
    $observationPath = Join-Path $evidenceDir 'tablet-layout-observation-c1b-v1.json'
    [IO.File]::WriteAllBytes($observationPath, $observationBytes)
    $script:Run.observation_sha256 = Get-Sha256Bytes $observationBytes

    Set-Stage 'validated'
    $validation = Test-TabletLayoutObservationC1BV1TrustedRuntimeFile -Path $observationPath -EvidenceRoot $evidenceDir `
        -ExpectedRunId $RunId -ExpectedProducerCommitSha $script:Run.commit_sha -ExpectedProducerArtifactSha256 $script:Run.apk_sha256
    $script:Run.validation = [ordered]@{
        fixture_contract_valid = [bool]$validation.fixture_contract_valid
        runtime_binding_inputs_match = [bool]$validation.runtime_binding_inputs_match
        reason_codes = @($validation.reason_codes)
        application_window_topology_observed = [bool]$validation.application_window_topology_observed
        semantic_tree_usable = [bool]$validation.semantic_tree_usable
    }
    if (-not $validation.fixture_contract_valid -or -not $validation.runtime_binding_inputs_match) {
        throw "observation validator 未通过：$(@($validation.reason_codes) -join ',')"
    }
    $script:Run.outcome = 'passed'; $exitCode = 0
}
catch {
    $script:Run.failure_reason = $_.Exception.Message
    if ($_.Exception -is [C1bNeedsUser]) { $script:Run.outcome = 'needs_user'; $exitCode = 2 } else { $exitCode = 1 }
    if ($sessionStarted -and -not $sessionConsumed) {
        $script:Run.abort.attempted = $true
        try {
            $abort = Read-C1bControl 'abort'
            $script:Run.abort.state = [string]$abort.state; $script:Run.abort.reason_code = $abort.reason_code
        } catch { $script:Run.abort.state = 'unreadable' }
    }
    [Console]::Error.WriteLine("tablet C1b 采集失败（$($script:Run.stage)）：$($_.Exception.Message)")
}
finally {
    if ($null -ne $lease) { try { [void](Close-DispatchLockLease -Lease $lease) } catch { } }
    $script:Run.exit_code = $exitCode
    $script:Run.timestamps['finished_at'] = Get-Utc
    if ($null -ne $evidenceDir) {
        try {
            [void](New-Item -ItemType Directory -Path $evidenceDir -Force)
            $json = $script:Run | ConvertTo-Json -Depth 10
            if ($script:SelectedSerial -and $json.Contains($script:SelectedSerial)) { $json = $json.Replace($script:SelectedSerial, '<serial>') }
            [IO.File]::WriteAllText((Join-Path $evidenceDir 'run.json'), $json + "`n", [Text.UTF8Encoding]::new($false))
            Write-Host "tablet C1b 证据目录：$evidenceDir"
        } catch { [Console]::Error.WriteLine("run.json 写入失败：$($_.Exception.Message)") }
    }
    Write-Host "tablet C1b outcome=$($script:Run.outcome) exit=$exitCode run_id=$($script:Run.run_id)"
}
exit $exitCode
