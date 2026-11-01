#Requires -Version 7.5
<#
scripts/run-tablet-c1b.ps1 的离线测试：fake adb（.ps1，经 -TestOnlyAdbIsScript 由 pwsh 执行）模拟
devices/install/settings/dumpsys/content read/write；T0 经 -TestOnlyT0ProfilePath 桩化；-SkipBuild -ApkPath 假 APK。
runner 在临时 git 仓副本中运行，不触碰真实设备、adb、Gradle 与本仓 HEAD。
注意：runner 会短暂获取主机全局设备锁（生产路径，不注入锁目录）；若真机派单正在进行，本测试会失败。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Pwsh = (Get-Process -Id $PID).Path
$Fixture = Join-Path $PSScriptRoot 'fixtures\tablet-layout-observation\c1b-v1\real-shape-topology-only.json'
if (-not (Test-Path -LiteralPath $Fixture -PathType Leaf)) { throw "缺少 observation fixture：$Fixture" }
$Temp = [IO.Directory]::CreateTempSubdirectory('tablet-c1b-runner-').FullName
$Sandbox = Join-Path $Temp 'repo'
$FakeSerial = 'FAKESERIAL01'
$script:Passed = 0; $script:Failed = 0

function Get-Sha256Text([string]$Text) {
    'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Invoke-Git([string[]]$Arguments) {
    $output = & git -C $Sandbox @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') 失败：$output" }
    return $output
}

# ---- 临时 git 仓：只复制 runner 及其保留依赖 ----
foreach ($relative in @(
    'scripts\run-tablet-c1b.ps1', 'scripts\lib\dispatch-lock.ps1', 'scripts\lib\tablet-layout-c1a.ps1',
    'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1', 'docs\contracts\tablet-layout-observation-c1b-v1.schema.json',
    'scripts\lib\tablet-c1b-inventory-result.ps1', 'docs\contracts\tablet-c1b-inventory-result-v1.schema.json'
)) {
    $target = Join-Path $Sandbox $relative
    [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
}
# 在测试副本中注入释放后的失败，确保真实锁仍被释放；生产库不增加测试开关。
Add-Content -LiteralPath (Join-Path $Sandbox 'scripts/lib/dispatch-lock.ps1') -Value @'
$script:OfflineCloseDispatchLockLease = ${function:Close-DispatchLockLease}
function Close-DispatchLockLease {
    param($Lease)
    $closed = & $script:OfflineCloseDispatchLockLease -Lease $Lease
    if ($env:FAKE_ADB_SCENARIO -in @('cleanup_fail', 'drift_cleanup_fail')) { throw 'fake lease cleanup failure' }
    if ($env:FAKE_ADB_SCENARIO -ceq 'cleanup_false') { return $false }
    return $closed
}
'@
[IO.File]::WriteAllText((Join-Path $Sandbox '.gitignore'), "docs/runs/evidence/`n")
& git init -q $Sandbox
Invoke-Git @('add', '-A') | Out-Null
Invoke-Git @('-c', 'user.name=offline', '-c', 'user.email=offline@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'sandbox') | Out-Null
$Head = ([string](Invoke-Git @('rev-parse', 'HEAD'))).Trim()
$FakeApk = Join-Path $Temp 'fake-probe.apk'
[IO.File]::WriteAllBytes($FakeApk, [Text.Encoding]::ASCII.GetBytes('fake apk bytes for offline runner test'))
$ApkSha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($FakeApk))).ToLowerInvariant()

# ---- fake adb ----
$FakeAdb = Join-Path $Temp 'fake-adb.ps1'
[IO.File]::WriteAllText($FakeAdb, @'
$ErrorActionPreference = 'Stop'
$a = [string[]]$args
$state = $env:FAKE_ADB_STATE; $scenario = $env:FAKE_ADB_SCENARIO
Add-Content -LiteralPath (Join-Path $state 'adb.log') -Value ($a -join ' ')
function Out-Text([string]$Text) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $out = [Console]::OpenStandardOutput(); $out.Write($bytes, 0, $bytes.Length); $out.Flush()
}
if ($a[0] -ceq 'devices') {
    $text = "List of devices attached`nFAKESERIAL01`tdevice`n"
    if ($scenario -ceq 'multi') { $text += "OTHER0002`tdevice`n" }
    Out-Text ($text + "`n"); exit 0
}
if ($a[0] -cne '-s' -or $a[1] -cne 'FAKESERIAL01') { [Console]::Error.WriteLine('fake adb: unexpected serial'); exit 1 }
$cmd = ($a[2..($a.Count - 1)] -join ' ')
$sessionPath = Join-Path $state 'session.json'
$session = if (Test-Path -LiteralPath $sessionPath) { Get-Content -Raw -LiteralPath $sessionPath | ConvertFrom-Json -AsHashtable -DateKind String } else { $null }
function Save { $session | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sessionPath -Encoding utf8 }
function Out-Control {
    $s = $session; $active = $s.state -in @('ready_c1', 'capturing_c1', 'ready_c2', 'capturing_c2', 'complete')
    $next = switch ($s.state) { 'ready_c1' { 'capture_c1' } 'ready_c2' { 'capture_c2' } 'complete' { 'read_result' } { $_ -like 'capturing*' } { 'wait' } default { 'none' } }
    Out-Text (([ordered]@{
        schema = 'tablet-c1b-control/v1'; ok = $active; run_id = $s.run_id; generation = $s.generation; state = $s.state; next = $next
        reason_code = $s.reason; in_flight_token = $s.inflight; c1_requests_accepted = $s.c1; c2_requests_accepted = $s.c2
        committed_tokens = @($s.committed); recapture_count = 0
        expected_title_hash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
        producer_commit_sha = $s.commit; producer_artifact_sha256 = $s.artifact
        provider = (Get-Provider)
    } | ConvertTo-Json -Depth 5 -Compress) + "`n")
}
function Get-Provider {
    $head = if ($scenario -ceq 'stale_apk') { '0' * 40 } else { $env:FAKE_ADB_HEAD }
    [ordered]@{ authority = 'dev.magina.gateway.tablet.c1b'; protocol_version = '1'; package_name = 'dev.magina.gateway'
        version_name = '0.1.0'; version_code = 1; embedded_git_head = $head; build_challenge = 'offline-c1b-read-only-placeholder'; a11y_service_ready = $true }
}
if ($cmd -ceq 'shell pm path dev.magina.gateway') {
    if ($scenario -ceq 'installed_missing') { exit 0 }
    if ($scenario -in @('same_apk', 'installed_mismatch', 'installed_pm_failure', 'installed_pm_stderr', 'installed_pm_whitespace_stderr', 'installed_sha_failure', 'installed_sha_stderr')) {
        Out-Text "package:/data/app/fake/base.apk`n"
        if ($scenario -ceq 'installed_pm_failure') { exit 1 }
        if ($scenario -ceq 'installed_pm_stderr') { [Console]::Error.WriteLine('fake pm read failure') }
        if ($scenario -ceq 'installed_pm_whitespace_stderr') { [Console]::Error.Write(' ') }
        exit 0
    } else { exit 1 }
}
if ($cmd -ceq "shell sha256sum '/data/app/fake/base.apk'") {
    $sha = if ($scenario -ceq 'installed_mismatch') { '0' * 64 } else { $env:FAKE_ADB_APK_SHA }
    Out-Text "$sha  /data/app/fake/base.apk`n"
    if ($scenario -ceq 'installed_sha_failure') { exit 1 }
    if ($scenario -ceq 'installed_sha_stderr') { [Console]::Error.WriteLine('fake sha read failure') }
    exit 0
}
if ($cmd -match '^install -r -t ') { Out-Text "Performing Streamed Install`nSuccess`n"; exit 0 }
if ($cmd -ceq 'shell settings get secure enabled_accessibility_services') {
    Out-Text $(if ($scenario -ceq 'a11y_off') { "null`n" } else { "dev.magina.gateway/.a11y.GatewayA11yService`n" }); exit 0
}
if ($cmd -ceq 'shell dumpsys accessibility') {
    # vivo 实测：探针已连接但 dumpsys 绑定列表只列出 vivo 输入法；runner 须以 provider 自报为准。
    $boundLine = if ($scenario -ceq 'vivo_hidden_bound') { 'Service[label=vivo输入法, component=com.vivo.ai.ime.pad/x.AutoSendImageService]' } else { 'Service[label=gw, component=dev.magina.gateway/.a11y.GatewayA11yService]' }
    Out-Text "ACCESSIBILITY MANAGER (dumpsys accessibility)`nUser state[`n  Bound services:{$boundLine}`n]`n"; exit 0
}
$base64Wire = $cmd -match '^shell -T set -o pipefail && toybox base64 -d \| content write --uri (?<uri>.+)$'
if ($base64Wire) { $transport = 'shell -T'; $operation = 'write'; $uri = $Matches.uri }
else {
    if ($cmd -notmatch '^(?<transport>exec-in|shell -T|shell) content (?<operation>write|read) --uri (?<uri>.+)$') { [Console]::Error.WriteLine("fake adb: unsupported $cmd"); exit 1 }
    $transport = $Matches.transport; $operation = $Matches.operation; $uri = $Matches.uri
}
if (($operation -ceq 'read' -and $transport -cne 'shell') -or ($operation -ceq 'write' -and $transport -ceq 'shell')) { exit 1 }
# AOSP: shell joins argv before sh parsing; exec-in escape_arg preserves each argv verbatim.
# Only shell consumes the deliberate outer quotes. exec-in must never Trim them.
if ($transport -ne 'exec-in') {
    if ($uri -cnotmatch "^'([^']+)'$") { [Console]::Error.WriteLine('fake adb: unquoted shell URI'); exit 1 }
    $uri = $Matches[1]
}
if ($uri -notmatch '^content://dev\.magina\.gateway\.tablet\.c1b/(?<path>[a-z0-9/._-]+)\?(?<query>[^''\s]+)$') {
    # exec-in discards remote output/exit: an invalid quoted URI creates no session yet returns host exit 0.
    if ($transport -ceq 'exec-in') { [Console]::OpenStandardInput().CopyTo([IO.Stream]::Null); exit 0 }
    [Console]::Error.WriteLine('fake adb: invalid content URI'); exit 1
}
$path = $Matches.path; $query = @{}
foreach ($pair in $Matches.query -split '&') { $kv = $pair -split '=', 2; $query[$kv[0]] = $kv[1] }
if ($path -match '^t0/(?<run>.+)$') {
    $run = $Matches.run
    if ($scenario -ceq 'shell_protocol_unsupported') { [Console]::Error.WriteLine('fake adb: -T requires shell protocol'); exit 1 }
    $ms = [IO.MemoryStream]::new(); [Console]::OpenStandardInput().CopyTo($ms); $wire = $ms.ToArray()
    [IO.File]::WriteAllBytes((Join-Path $state 't0-wire.bin'), $wire)
    # Windows CRT text reads collapse CRLF; the binary scenario preserves input exactly.
    $crtInput = if ($scenario -ceq 'crt_binary') { $wire } else { [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString($wire).Replace("`r`n", "`n")) }
    [IO.File]::WriteAllBytes((Join-Path $state 't0-crt-stdin.bin'), $crtInput)
    if ($base64Wire) {
        if ($scenario -ceq 'pipefail_unsupported') { [Console]::Error.WriteLine('fake shell: pipefail unsupported'); exit 2 }
        if ($scenario -ceq 'base64_unavailable') { [Console]::Error.WriteLine('fake toybox: base64 unavailable'); exit 127 }
        $encoded = [Text.Encoding]::ASCII.GetString($crtInput)
        if ($encoded -cnotmatch '^[A-Za-z0-9+/]+={0,2}$') { [Console]::Error.WriteLine('fake decoder: wire is not single-line base64'); exit 8 }
        if ($scenario -ceq 'base64_decode_fail') { exit 8 } # Left-side nonzero must fail even with empty output.
        $bytes = [Convert]::FromBase64String($encoded)
    } else { $bytes = $crtInput }
    [IO.File]::WriteAllBytes((Join-Path $state 't0-stdin.bin'), $bytes)
    # content catches provider exceptions, so an error can be exit 0. Include identifiers to test redaction.
    if ($scenario -ceq 't0_remote_exit') { exit 7 }
    if ($scenario -ceq 't0_remote_whitespace_stderr') { [Console]::Error.Write(' '); exit 0 }
    if ($scenario -ceq 't0_remote_stdout') { Out-Text "remote output FAKESERIAL01 $uri"; exit 0 }
    $t0 = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -DateKind String
    $session = @{ run_id = $run; nonce = $query.nonce; state = 'ready_c1'; generation = 1; c1 = 0; c2 = 0; committed = @(); inflight = $null; reason = $null
        commit = $query.producer_commit_sha; artifact = $query.producer_artifact_sha256; title = $query.title_hash
        t0_sha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant(); t0_at = $t0.captured_at_utc }
    Save
    # A decoder can emit a valid prefix, allow content to create a session, then fail on trailing input.
    if ($base64Wire -and $scenario -ceq 'base64_partial_decode_failure') { [Console]::Error.WriteLine('fake decoder: invalid trailing input'); exit 8 }
    if ($scenario -ceq 't0_remote_stderr') { [Console]::Error.WriteLine("remote failure FAKESERIAL01 $uri") }
    exit 0
}
if ($null -eq $session -and $path -match '^(?:status|abort)/(?<run>.+)$') {
    Out-Text (([ordered]@{
        schema = 'tablet-c1b-control/v1'; ok = $false; run_id = $Matches.run; generation = 0; state = 'absent'; next = 'none'
        reason_code = 'session_not_found'; in_flight_token = $null; c1_requests_accepted = 0; c2_requests_accepted = 0
        committed_tokens = @(); recapture_count = 0; expected_title_hash = $null; producer_commit_sha = $null; producer_artifact_sha256 = $null
        provider = (Get-Provider)
    } | ConvertTo-Json -Depth 5 -Compress) + "`n"); exit 0
}
if ($null -eq $session -or $query.nonce -cne $session.nonce) { [Console]::Error.WriteLine('fake adb: nonce mismatch'); exit 1 }
switch -regex ($path) {
    '^status/' {
        if ($session.state -ceq 'capturing_c1') {
            $session.state = 'ready_c2'; $session.inflight = $null; $session.committed = @('c1')
            if ($scenario -in @('drift', 'drift_cleanup_fail')) { $session.generation = 2 }
        } elseif ($session.state -ceq 'capturing_c2') { $session.state = 'complete'; $session.inflight = $null; $session.committed = @('c1', 'c2') }
        Save; Out-Control; break
    }
    '^capture/c1/' { $session.state = 'capturing_c1'; $session.c1 = 1; $session.inflight = 'c1'; Save; Out-Control; break }
    '^capture/c2/' { $session.state = 'capturing_c2'; $session.c2 = 1; $session.inflight = 'c2'; Save; Out-Control; break }
    '^abort/' { $session.state = 'aborted'; $session.reason = 'session_aborted'; $session.inflight = $null; Save; Out-Control; break }
    '^result/' {
        $o = Get-Content -Raw -LiteralPath $env:FAKE_ADB_FIXTURE | ConvertFrom-Json -Depth 100 -DateKind String
        $now = [DateTime]::UtcNow; $fmt = 'yyyy-MM-ddTHH:mm:ss.fffffffZ'
        $o.run_id = $session.run_id; $o.expected_title_hash = $session.title
        $o.provenance.kind = 'gateway_runtime_probe'; $o.provenance.producer_commit_sha = $session.commit
        $o.provenance.producer_artifact_sha256 = if ($scenario -ceq 'bad_anchor') { 'sha256:' + ('e' * 64) } else { $session.artifact }
        $o.upstream_t0.source_kind = 'trusted_runtime'; $o.upstream_t0.run_id = $session.run_id
        $o.upstream_t0.artifact_sha256 = $session.t0_sha; $o.upstream_t0.captured_at = $session.t0_at
        $o.frames[0].captured_at = $now.AddMilliseconds(-1200).ToString($fmt); $o.frames[1].captured_at = $now.AddMilliseconds(-200).ToString($fmt)
        $o.captured_at = $o.frames[1].captured_at
        switch ($scenario) {
            'bad_schema' { $o.schema = 'untrusted-schema' }
            'bad_run_id' { $o.run_id = 'other-run' }
            'bad_title' { $o.expected_title_hash = 'sha256:' + ('d' * 64) }
            'bad_kind' { $o.provenance.kind = 'offline_fixture' }
            'bad_commit' { $o.provenance.producer_commit_sha = '0' * 40 }
            'bad_t0_source' { $o.upstream_t0.source_kind = 'offline_fixture' }
            'bad_t0_run' { $o.upstream_t0.run_id = 'other-t0-run' }
            'bad_t0_artifact' { $o.upstream_t0.artifact_sha256 = 'sha256:' + ('d' * 64) }
            'bad_t0_commit' { $o.upstream_t0.producer_commit_sha = '0' * 40 }
            'bad_t0_time' { $o.upstream_t0.captured_at = '2020-01-01T00:00:00.0000000Z' }
            'result_missing' { $o.PSObject.Properties.Remove('upstream_t0') }
            'result_serial' { $o | Add-Member -NotePropertyName unexpected -NotePropertyValue 'FAKESERIAL01' }
            'result_nonce' { $o | Add-Member -NotePropertyName unexpected -NotePropertyValue $session.nonce }
            'result_serial_escaped' { $o | Add-Member -NotePropertyName unexpected -NotePropertyValue 'FAKESERIAL01' }
            'result_nonce_escaped' { $o | Add-Member -NotePropertyName unexpected -NotePropertyValue $session.nonce }
        }
        if ($scenario -ceq 'run_json_fail') {
            [void](New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot "repo/docs/runs/evidence/$($session.run_id)/tablet-layout-c1b/run.json"))
        }
        if ($scenario -ceq 'result_control') { Out-Control; break }
        $inner = $o | ConvertTo-Json -Depth 100 -Compress
        if ($scenario -ceq 'result_serial_escaped') { $inner = $inner.Replace('FAKESERIAL01', '\u0046AKESERIAL01') }
        if ($scenario -ceq 'result_nonce_escaped') { $inner = $inner.Replace($session.nonce, '\u006e' + $session.nonce.Substring(1)) }
        if ($scenario -ceq 'inner_format') {
            $inner = ($o | ConvertTo-Json -Depth 100).Replace("`r`n", "`n").Replace("`n", "`r`n").Replace('"schema"', '"\u0073chema"') + "`r`n"
        }
        if ($scenario -ceq 'inner_invalid_json') { $inner = '{"untrusted":"DO_NOT_RETAIN_RESULT_VALUE"' }
        if ($scenario -ceq 'inner_duplicate') { $inner = $inner.Replace('"schema":', '"schema":"duplicate","schema":') }
        if ($scenario -ceq 'inner_bom') { $inner = [string][char]0xfeff + $inner }
        $inventoryFrames = @($o.frames | ForEach-Object {
            $saved = $_.a11y_windows.Count
            [ordered]@{
                capture_id = $_.capture_id; capture_token = $_.capture.token
                enumeration_status = 'complete'; count_status = 'exact'; maximum_windows = 16
                input_count = $saved; unattempted_count = 0; attempted_count = $saved; saved_count = $saved; dropped_count = 0
                first_stop_counts = [ordered]@{
                    window_type_read_failed = 0; window_type_invalid = 0; window_display_read_failed = 0; window_display_invalid = 0
                    window_layer_read_failed = 0; window_layer_invalid = 0; window_touchable_bounds_read_failed = 0; window_touchable_bounds_invalid = 0
                    window_active_read_failed = 0; window_focus_read_failed = 0; window_id_read_failed = 0; window_id_invalid = 0
                }
            }
        })
        switch ($scenario) {
            'count_mismatch' { $inventoryFrames[0].input_count++ }
            'capture_mismatch' { $inventoryFrames[0].capture_id = 'other-capture' }
            'count_overflow' { $inventoryFrames[0].count_status = 'overflow'; $inventoryFrames[0].input_count = $null; $inventoryFrames[0].unattempted_count = $null }
            'invalid_observation' { $inner = $inner.Replace('"device_action_allowed":false', '"device_action_allowed":true') }
            'diagnostic_serial' { $inventoryFrames[0].capture_id = 'FAKESERIAL01' }
            'diagnostic_serial_escaped' { $inventoryFrames[0].capture_id = 'FAKESERIAL01' }
            'diagnostic_nonce' { $inventoryFrames[0].capture_id = $session.nonce }
            'diagnostic_nonce_escaped' { $inventoryFrames[0].capture_id = $session.nonce }
        }
        $envelope = [ordered]@{ schema = 'tablet-c1b-inventory-result/v1'; observation_json = $inner; inventory_frames = $inventoryFrames }
        if ($scenario -ceq 'outer_version') { $envelope.schema = 'tablet-c1b-inventory-result/v9' }
        if ($scenario -ceq 'outer_unknown') { $envelope.extra = 'DO_NOT_RETAIN_RESULT_VALUE' }
        $raw = $envelope | ConvertTo-Json -Depth 100 -Compress
        switch ($scenario) {
            'result_invalid_json' { $raw = '{"untrusted":"DO_NOT_RETAIN_RESULT_VALUE"' }
            'bare_v1' { $raw = $inner }
            'outer_duplicate' { $raw = $raw.Replace('"schema":', '"schema":"duplicate","schema":') }
            'outer_surrogate' { $raw = '{"schema":"tablet-c1b-inventory-result/v1","observation_json":"\ud800","inventory_frames":[]}' }
            'outer_bom' { $raw = [string][char]0xfeff + $raw }
            'oversized_result' { $raw = ' ' * 1048577 }
            'diagnostic_serial_escaped' { $raw = $raw.Replace('FAKESERIAL01', '\u0046AKESERIAL01') }
            'diagnostic_nonce_escaped' { $raw = $raw.Replace($session.nonce, '\u006e' + $session.nonce.Substring(1)) }
        }
        $rawBytes = if ($scenario -ceq 'invalid_utf8') { [byte[]]@(0xc3, 0x28) } else { [Text.UTF8Encoding]::new($false).GetBytes($raw) }
        [IO.File]::WriteAllBytes((Join-Path $state 'result-response.bin'), $rawBytes)
        [IO.File]::WriteAllText((Join-Path $state 'observation-response.bin'), $inner, [Text.UTF8Encoding]::new($false))
        # The real controller consumes an observation before returning its bytes to the host.
        $session = $null; Save
        $stdout = [Console]::OpenStandardOutput(); $stdout.Write($rawBytes, 0, $rawBytes.Length); $stdout.Flush(); break
    }
    default { exit 1 }
}
exit 0
'@, [Text.UTF8Encoding]::new($false))

function New-T0Profile([string]$RunId) {
    $path = Join-Path $Temp "t0-$RunId.json"
    $profile = [ordered]@{
        schema_version = 5; run_id = $RunId; captured_at_utc = [DateTime]::UtcNow.AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        device = [ordered]@{ serial_hash = (Get-Sha256Text $FakeSerial); model = 'FakeTab中文' }
        assessment = [ordered]@{ device_class = 'tablet'; intake_status = 'accepted'; readiness_status = 'blocked'
            readiness_block_reasons = @('focus_absent'); p0_capability = 'unsupported'
            p0_unsupported_reasons = @('wechat_layout_unverified', 'tablet_landscape_p0_unimplemented') }
    }
    $json = ($profile | ConvertTo-Json -Depth 10).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-Runner([string]$Name, [string]$Scenario, [string[]]$Extra = @()) {
    $state = Join-Path $Temp "state-$Name"; [void](New-Item -ItemType Directory -Path $state)
    $runId = "t-$Name"
    $env:FAKE_ADB_STATE = $state; $env:FAKE_ADB_SCENARIO = $Scenario; $env:FAKE_ADB_FIXTURE = $Fixture; $env:FAKE_ADB_HEAD = $Head; $env:FAKE_ADB_APK_SHA = $ApkSha.Substring(7)
    $output = & $Pwsh -NoProfile -NonInteractive -File (Join-Path $Sandbox 'scripts\run-tablet-c1b.ps1') -AdbPath $FakeAdb -TestOnlyAdbIsScript `
        -SkipBuild -ApkPath $FakeApk -RunId $runId -TestOnlyT0ProfilePath (New-T0Profile $runId) @Extra 2>&1
    $exit = $LASTEXITCODE
    $evidence = Join-Path $Sandbox "docs\runs\evidence\$runId\tablet-layout-c1b"
    $runJsonPath = Join-Path $evidence 'run.json'
    $logPath = Join-Path $state 'adb.log'
    return [pscustomobject]@{
        Exit = $exit; Output = ($output -join "`n"); Evidence = $evidence; RunId = $runId; State = $state
        RunRaw = if (Test-Path -LiteralPath $runJsonPath -PathType Leaf) { Get-Content -Raw -LiteralPath $runJsonPath } else { '' }
        Run = if (Test-Path -LiteralPath $runJsonPath -PathType Leaf) { Get-Content -Raw -LiteralPath $runJsonPath | ConvertFrom-Json -DateKind String } else { $null }
        Log = [string[]]@(if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath })
    }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name：$($_.Exception.Message)" }
}

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

function Assert-NoForbiddenAdb($Result) {
    foreach ($line in $Result.Log) {
        Assert-True ($line -notmatch '\b(input|tap|swipe|uninstall|screencap)\b|am start|settings put') "出现禁止的 adb 命令：$line"
    }
}

try {
    Test-Case 'success' {
        $r = Invoke-Runner 'success' 'ok'
        Assert-True ($r.Exit -eq 0) "exit=$($r.Exit) $($r.Output)"
        Assert-True ($r.Run.outcome -ceq 'passed' -and $r.Run.commit_sha -ceq $Head -and $r.Run.apk_sha256 -ceq $ApkSha) 'run.json 绑定错误'
        Assert-True ($r.Run.serial_sha256 -ceq (Get-Sha256Text $FakeSerial) -and -not $r.RunRaw.Contains($FakeSerial)) 'serial 未脱敏'
        Assert-True ([long]$r.Run.capture.host_wait_ms -ge 900 -and -not $r.Run.abort.attempted) 'host wait/abort 不符'
        $t0Copy = [IO.File]::ReadAllBytes((Join-Path $r.Evidence 'upstream-t0-v5.json'))
        Assert-True ([Linq.Enumerable]::SequenceEqual($t0Copy, [IO.File]::ReadAllBytes((Join-Path $Temp "t0-$($r.RunId).json")))) 'T0 副本字节不一致'
        $observation = Get-Content -Raw -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json') | ConvertFrom-Json -DateKind String
        Assert-True ($observation.provenance.producer_commit_sha -ceq $Head -and $observation.upstream_t0.artifact_sha256 -ceq $r.Run.t0_sha256) 'observation 锚点错误'
        Assert-True ($r.Run.validation.fixture_contract_valid -and $r.Run.validation.runtime_binding_inputs_match) 'validator 未通过'
        $response = [IO.File]::ReadAllBytes((Join-Path $r.State 'result-response.bin'))
        $innerResponse = [IO.File]::ReadAllBytes((Join-Path $r.State 'observation-response.bin'))
        Assert-True ($r.Run.result_diagnostic.bytes -eq $innerResponse.Length -and $r.Run.result_diagnostic.sha256 -ceq $r.Run.observation_sha256 -and $null -eq $r.Run.result_diagnostic.binding_failure) '成功内层结果摘要错误'
        Assert-True ($r.Run.schema -ceq 'tablet-c1b-run/v2' -and $r.Run.result_schema -ceq 'tablet-c1b-inventory-result/v1' -and $r.Run.inventory_validation.status -ceq 'passed' -and $r.Run.inventory_validation.reason_codes.Count -eq 0) '新版本收据错误'
        $envelopeCopy = [IO.File]::ReadAllBytes((Join-Path $r.Evidence 'tablet-c1b-inventory-result-v1.json'))
        Assert-True ([Linq.Enumerable]::SequenceEqual($response, $envelopeCopy)) '封套原始字节未保留'
        Assert-True ($r.Run.result_envelope_sha256 -ceq ('sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($response)).ToLowerInvariant()) -and $r.Run.result_envelope_sha256 -cne $r.Run.observation_sha256) '外层哈希不能替代内层哈希'
        Assert-True (@($r.Log | Where-Object { $_ -match 'shell -T set -o pipefail && toybox base64 -d \| content write' }).Count -eq 1 -and @($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1) 'T0 应通过无 PTY 的解码管道写入一次，result 读取一次'
        Assert-True ([Linq.Enumerable]::SequenceEqual($t0Copy, [IO.File]::ReadAllBytes((Join-Path $r.State 't0-stdin.bin')))) '远端 stdin 字节与 T0 不同'
        Assert-NoForbiddenAdb $r
    }
    foreach ($scenario in @('crt_text', 'crt_binary')) {
        Test-Case "$scenario-base64-preserves-exact-t0" {
            $r = Invoke-Runner $scenario $scenario
            Assert-True ($r.Exit -eq 0 -and $r.Run.outcome -ceq 'passed') "exit=$($r.Exit) $($r.Output)"
            $t0 = [IO.File]::ReadAllBytes((Join-Path $r.Evidence 'upstream-t0-v5.json'))
            $wire = [IO.File]::ReadAllBytes((Join-Path $r.State 't0-wire.bin'))
            $crtInput = [IO.File]::ReadAllBytes((Join-Path $r.State 't0-crt-stdin.bin'))
            $decoded = [IO.File]::ReadAllBytes((Join-Path $r.State 't0-stdin.bin'))
            Assert-True ([Text.Encoding]::UTF8.GetString($t0).Contains("`r`n") -and [Text.Encoding]::UTF8.GetString($t0).Contains('中文')) '风险样例须含 CRLF 与非 ASCII UTF-8'
            Assert-True ([Linq.Enumerable]::SequenceEqual($wire, [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($t0)))) 'wire 必须精确为无换行/BOM 的标准 Base64'
            Assert-True ([Linq.Enumerable]::SequenceEqual($wire, $crtInput) -and [Linq.Enumerable]::SequenceEqual($t0, $decoded)) 'CRT 模式不应改变线缆或解码后的原始 T0 字节'
            Assert-True (@($r.Log | Where-Object { $_ -match 'content write' }).Count -eq 1 -and -not ($r.Log -match 'exec-in|shell -T content write')) '必须只写一次且无原始 stdin/exec-in 回退'
            Assert-NoForbiddenAdb $r
        }
    }
    foreach ($scenario in @('pipefail_unsupported', 'base64_unavailable', 'base64_decode_fail', 'base64_partial_decode_failure')) {
        Test-Case "$scenario-stops-before-capture" {
            $r = Invoke-Runner $scenario $scenario
            Assert-True ($r.Exit -eq 1 -and $r.Run.stage -ceq 't0_written' -and $r.Run.failure_reason -match 'adb shell -T set 失败') "exit=$($r.Exit) $($r.Output)"
            $abortState = if ($scenario -ceq 'base64_partial_decode_failure') { 'aborted' } else { 'absent' }
            Assert-True ($r.Run.abort.attempted -and $r.Run.abort.state -ceq $abortState) '解码/能力失败后须保留必要 abort，不能假定写入未发生'
            Assert-True (@($r.Log | Where-Object { $_ -match 'content write' }).Count -eq 1 -and -not ($r.Log -match '/capture/|/result/|exec-in|shell -T content write')) '失败后不得采帧、重写或回退'
            Assert-True ($null -eq $r.Run.result_diagnostic -and -not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '失败后不得产生结果证据'
            Assert-NoForbiddenAdb $r
        }
    }
    foreach ($scenario in @('t0_remote_exit', 't0_remote_stderr', 't0_remote_whitespace_stderr', 't0_remote_stdout', 'shell_protocol_unsupported')) {
        Test-Case "$scenario-stops-before-capture" {
            $r = Invoke-Runner $scenario $scenario
            Assert-True ($r.Exit -eq 1 -and $r.Run.outcome -ceq 'failed' -and $r.Run.stage -ceq 't0_written') "exit=$($r.Exit) $($r.Output)"
            $reason = if ($scenario -in @('t0_remote_exit', 'shell_protocol_unsupported')) { 'adb shell -T set 失败' } else { 'T0 write 返回了意外输出' }
            Assert-True ($r.Run.failure_reason -like "*$reason*") '未在远端写入失败处停止'
            Assert-True (@($r.Log | Where-Object { $_ -match 'content write' }).Count -eq 1 -and -not ($r.Log -match '/capture/|/result/')) '写失败后重试或请求了采集'
            $abortState = if ($scenario -ceq 't0_remote_stderr') { 'aborted' } else { 'absent' }
            Assert-True ($r.Run.abort.attempted -and $r.Run.abort.state -ceq $abortState) '写入可能已发生，须保留原 abort 尝试'
            Assert-True ($r.RunRaw -notmatch 'FAKESERIAL01|content://|n-[0-9a-f]{32}' -and $r.Output -notmatch 'FAKESERIAL01|content://|n-[0-9a-f]{32}') '远端输出泄漏到错误记录'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '写失败不应生成 observation'
            Assert-True ($null -eq $r.Run.result_diagnostic) '未读 result 时不应产生摘要'
            Assert-NoForbiddenAdb $r
        }
    }
    Test-Case 'same-apk-skips-install' {
        $r = Invoke-Runner 'sameapk' 'same_apk'
        Assert-True ($r.Exit -eq 0 -and $r.Run.install_skipped) "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match '^-s \S+ install ')) '设备上已是同一 APK 时不应重装'
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'required-installed-apk-match-skips-install' {
        $r = Invoke-Runner 'requiredsameapk' 'same_apk' @('-RequireInstalledApkMatch')
        Assert-True ($r.Exit -eq 0 -and $r.Run.outcome -ceq 'passed' -and $r.Run.install_skipped) "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match '^-s \S+ install ')) '要求现装匹配时不应安装'
        Assert-True (@($r.Log | Where-Object { $_ -match 'shell pm path ' }).Count -eq 1 -and @($r.Log | Where-Object { $_ -match 'shell sha256sum ' }).Count -eq 1) '现装匹配检查不应重试'
        Assert-NoForbiddenAdb $r
    }
    foreach ($scenario in @('installed_missing', 'installed_mismatch', 'installed_pm_failure', 'installed_pm_stderr', 'installed_pm_whitespace_stderr', 'installed_sha_failure', 'installed_sha_stderr')) {
        Test-Case "required-$scenario-stops-before-install" {
            $r = Invoke-Runner "required-$scenario" $scenario @('-RequireInstalledApkMatch')
            $reason = if ($scenario -like 'installed_pm_*') { 'pm path 读取失败' } elseif ($scenario -like 'installed_sha_*') { 'sha256sum 读取失败' } else { '未确认已安装探针 APK' }
            Assert-True ($r.Exit -eq 1 -and $r.Run.outcome -ceq 'failed' -and $r.Run.failure_reason -match [regex]::Escape($reason)) "exit=$($r.Exit) $($r.Output)"
            Assert-True (-not ($r.Log -match '^-s \S+ install |content|settings|dumpsys') -and -not $r.Run.abort.attempted) '匹配未确认时应在安装、权限检查和 provider 访问前停止'
            Assert-True (@($r.Log | Where-Object { $_ -match 'shell pm path ' }).Count -eq 1) 'pm path 不应重试'
            $expectedShaReads = if ($scenario -eq 'installed_missing' -or $scenario -like 'installed_pm_*') { 0 } else { 1 }
            Assert-True (@($r.Log | Where-Object { $_ -match 'shell sha256sum ' }).Count -eq $expectedShaReads) 'SHA 读取次数不符'
            Assert-NoForbiddenAdb $r
        }
    }
    Test-Case 'multi-device-rejected' {
        $r = Invoke-Runner 'multi' 'multi'
        Assert-True ($r.Exit -eq 1 -and $r.Run.outcome -ceq 'failed' -and $r.Run.failure_reason -match '恰好一台') "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match 'install')) '多设备时不应安装'
    }
    Test-Case 'serial-mismatch-rejected' {
        $r = Invoke-Runner 'serial' 'ok' @('-Serial', 'NOTTHISONE')
        Assert-True ($r.Exit -eq 1 -and -not ($r.Log -match 'install')) "exit=$($r.Exit) $($r.Output)"
    }
    Test-Case 'a11y-off-needs-user' {
        $r = Invoke-Runner 'a11y' 'a11y_off'
        Assert-True ($r.Exit -eq 2 -and $r.Run.outcome -ceq 'needs_user' -and $r.Output -match '无障碍') "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match 'content')) '无障碍未开时不应访问 provider'
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'status-drift-fails-and-aborts' {
        $r = Invoke-Runner 'drift' 'drift'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match '漂移') "exit=$($r.Exit) $($r.Output)"
        Assert-True ($r.Run.abort.attempted -and $r.Run.abort.state -ceq 'aborted' -and ($r.Log -match '/abort/')) 'abort 未尝试'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '失败时不应写 observation'
    }
    foreach ($case in @(
        @('bad_schema', 'schema'), @('bad_run_id', 'run_id'), @('bad_title', 'expected_title_hash'),
        @('bad_kind', 'provenance.kind'), @('bad_commit', 'provenance.producer_commit_sha'),
        @('bad_anchor', 'provenance.producer_artifact_sha256'), @('bad_t0_source', 'upstream_t0.source_kind'),
        @('bad_t0_run', 'upstream_t0.run_id'), @('bad_t0_artifact', 'upstream_t0.artifact_sha256'),
        @('bad_t0_commit', 'upstream_t0.producer_commit_sha'), @('bad_t0_time', 'upstream_t0.captured_at'),
        @('result_missing', 'structure')
    )) {
        Test-Case "result-diagnostic-$($case[0])" {
            $r = Invoke-Runner $case[0] $case[0]
            Assert-True ($r.Exit -eq 1 -and $r.Run.stage -ceq 'result_read') "exit=$($r.Exit) $($r.Output)"
            Assert-True ($r.Run.result_diagnostic.binding_failure -ceq $case[1]) '未准确记录闭合失败字段'
            if ($case[0] -cne 'result_control') {
                $raw = [IO.File]::ReadAllBytes((Join-Path $r.State 'observation-response.bin'))
                $sha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
                Assert-True ($r.Run.result_diagnostic.bytes -eq $raw.Length -and $r.Run.result_diagnostic.sha256 -ceq $sha) '失败结果摘要不匹配原始字节'
                Assert-True ($r.Run.abort.attempted -and $r.Run.abort.state -ceq 'absent') '真实 result 消费后 abort 应 absent，不证明清理'
            }
            Assert-True (@($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1) '失败后重复读取 result'
            Assert-True ($r.RunRaw -notmatch 'FAKESERIAL01|content://|n-[0-9a-f]{32}|DO_NOT_RETAIN_RESULT_VALUE' -and $r.Output -notmatch 'DO_NOT_RETAIN_RESULT_VALUE') '结果原文泄漏'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '锚点不符时不应写 observation'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-c1b-inventory-result-v1.json')) -and $r.Run.inventory_validation.reason_codes[0] -ceq 'run_binding_mismatch') '锚点不符不得持久化封套'
            Assert-NoForbiddenAdb $r
        }
    }
    foreach ($case in @(
        @('result_invalid_json', 'encoding_invalid'), @('result_control', 'version_mismatch'),
        @('bare_v1', 'version_mismatch'), @('outer_version', 'version_mismatch'),
        @('outer_unknown', 'shape_invalid'), @('outer_duplicate', 'duplicate_key'),
        @('inner_duplicate', 'duplicate_key'), @('inner_invalid_json', 'encoding_invalid'),
        @('outer_bom', 'encoding_invalid'), @('inner_bom', 'encoding_invalid'),
        @('outer_surrogate', 'encoding_invalid'), @('invalid_utf8', 'encoding_invalid'),
        @('oversized_result', 'output_size_exceeded')
    )) {
        Test-Case "result-envelope-$($case[0])" {
            $r = Invoke-Runner $case[0] $case[0]
            Assert-True ($r.Exit -eq 1 -and $r.Run.stage -ceq 'result_read') "exit=$($r.Exit) $($r.Output)"
            Assert-True ($r.Run.inventory_validation.status -ceq 'failed' -and $r.Run.inventory_validation.reason_codes.Count -eq 1 -and $r.Run.inventory_validation.reason_codes[0] -ceq $case[1]) "wrong rejection $($r.RunRaw)"
            Assert-True ($null -eq $r.Run.result_diagnostic -and $null -eq $r.Run.result_schema -and $null -eq $r.Run.result_envelope_sha256) '解封失败不得冒充已识别结果'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json')) -and -not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-c1b-inventory-result-v1.json'))) '未绑定内容不得落盘'
            Assert-True (@($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1 -and $r.Run.abort.attempted) '失败不得重读或跳过终止'
            Assert-True ($r.RunRaw -notmatch 'DO_NOT_RETAIN_RESULT_VALUE|FAKESERIAL01|content://|n-[0-9a-f]{32}' -and $r.Output -notmatch 'DO_NOT_RETAIN_RESULT_VALUE') '坏值泄漏'
            Assert-NoForbiddenAdb $r
        }
    }
    foreach ($case in @(@('count_mismatch', 'count_mismatch'), @('capture_mismatch', 'capture_binding_mismatch'), @('count_overflow', 'count_overflow'), @('invalid_observation', 'observation_invalid'))) {
        Test-Case "bound-result-$($case[0])-retained" {
            $r = Invoke-Runner $case[0] $case[0]
            Assert-True ($r.Exit -eq 1 -and $r.Run.inventory_validation.status -ceq 'failed' -and $r.Run.inventory_validation.reason_codes[0] -ceq $case[1]) "wrong failure $($r.RunRaw)"
            Assert-True (-not $r.Run.abort.attempted -and @($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1) '已绑定已消费结果不能重读或再次终止'
            foreach ($pair in @(@('result-response.bin','tablet-c1b-inventory-result-v1.json'), @('observation-response.bin','tablet-layout-observation-c1b-v1.json'))) {
                Assert-True ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes((Join-Path $r.State $pair[0])), [IO.File]::ReadAllBytes((Join-Path $r.Evidence $pair[1])))) '失败证据原文被丢弃或改写'
            }
            Assert-NoForbiddenAdb $r
        }
    }
    Test-Case 'inner-format-and-escape-preserved' {
        $r = Invoke-Runner 'innerformat' 'inner_format'
        Assert-True ($r.Exit -eq 0) "exit=$($r.Exit) $($r.Output)"
        $original = [IO.File]::ReadAllBytes((Join-Path $r.State 'observation-response.bin'))
        Assert-True ([Text.Encoding]::UTF8.GetString($original).Contains('"\u0073chema"') -and [Text.Encoding]::UTF8.GetString($original).Contains("`r`n")) '样例须含原始转义与 CRLF'
        Assert-True ([Linq.Enumerable]::SequenceEqual($original, [IO.File]::ReadAllBytes((Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json')))) '内层被重排、trim 或规范化'
    }
    foreach ($scenario in @('result_serial', 'result_nonce', 'result_serial_escaped', 'result_nonce_escaped',
        'diagnostic_serial', 'diagnostic_serial_escaped', 'diagnostic_nonce', 'diagnostic_nonce_escaped')) {
        Test-Case "$scenario-before-diagnostic" {
            $r = Invoke-Runner $scenario $scenario
            Assert-True ($r.Exit -eq 1 -and $null -eq $r.Run.result_diagnostic -and $null -eq $r.Run.result_envelope_sha256 -and $null -eq $r.Run.result_schema) '隐私门之前不应保存摘要'
            if ($scenario -like 'diagnostic_serial*') {
                Assert-True ($r.Run.inventory_validation.reason_codes[0] -ceq 'shape_invalid') '大写 serial 应先被 capture_id 形状检查拒绝'
            } else {
                Assert-True ($r.Run.failure_reason -match '原始 serial 或 nonce') '解码后标识必须由隐私门拒绝'
            }
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-c1b-inventory-result-v1.json')) -and -not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '含私有标识的外层或内层内容不得落盘'
            Assert-True ($r.RunRaw -notmatch 'FAKESERIAL01|content://|n-[0-9a-f]{32}') 'run.json 泄漏标识'
            Assert-True ($r.Output -notmatch 'FAKESERIAL01|content://|n-[0-9a-f]{32}') '失败输出泄漏标识'
            Assert-True (@($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1 -and $r.Run.abort.attempted) '隐私失败不能重读结果'
            Assert-NoForbiddenAdb $r
        }
    }
    Test-Case 'stale-apk-head-mismatch-fails' {
        $r = Invoke-Runner 'stale' 'stale_apk'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match 'embedded_git_head') "exit=$($r.Exit) $($r.Output)"
    }
    Test-Case 'vivo-dumpsys-hides-bound-uses-provider' {
        $r = Invoke-Runner 'vivo' 'vivo_hidden_bound'
        Assert-True ($r.Exit -eq 0 -and $r.Run.outcome -ceq 'passed') "exit=$($r.Exit) $($r.Output)"
    }
    Test-Case 'lease-cleanup-failure-is-not-success' {
        $r = Invoke-Runner 'cleanup' 'cleanup_fail'
        Assert-True ($r.Exit -eq 1 -and $r.Run.outcome -ceq 'failed' -and $r.Run.exit_code -eq 1) "exit=$($r.Exit) $($r.Output)"
        Assert-True ($r.Run.failure_reason -match '设备锁释放失败' -and $r.Output -match 'fake lease cleanup failure') '清理失败未记录'
        Assert-True (@($r.Log | Where-Object { $_ -match '/capture/c1/' }).Count -eq 1 -and @($r.Log | Where-Object { $_ -match '/capture/c2/' }).Count -eq 1) '清理失败后重试了采集'
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'cleanup-failure-preserves-primary' {
        $r = Invoke-Runner 'primarycleanup' 'drift_cleanup_fail'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match '漂移' -and $r.Output -match 'fake lease cleanup failure') "exit=$($r.Exit) $($r.Output)"
        Assert-True ($r.Run.abort.attempted -and $r.Run.abort.state -ceq 'aborted') '原采集失败未终止会话'
    }
    Test-Case 'lease-cleanup-incomplete-is-not-success' {
        $r = Invoke-Runner 'cleanupfalse' 'cleanup_false'
        Assert-True ($r.Exit -eq 1 -and $r.Run.outcome -ceq 'failed' -and $r.Run.failure_reason -match '租约清理未完成') "exit=$($r.Exit) $($r.Output)"
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'run-json-write-failure-is-not-success' {
        $r = Invoke-Runner 'record' 'run_json_fail'
        Assert-True ($r.Exit -eq 1 -and $null -eq $r.Run -and $r.Output -match 'run.json 写入失败' -and $r.Output -match 'outcome=failed exit=1') "exit=$($r.Exit) $($r.Output)"
        Assert-True (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json') -PathType Leaf) '已采集的 observation 被丢弃'
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'dirty-tree-rejected' {
        $dirty = Join-Path $Sandbox 'dirty.txt'; [IO.File]::WriteAllText($dirty, 'x')
        try { $r = Invoke-Runner 'dirty' 'ok' } finally { Remove-Item -LiteralPath $dirty -Force }
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match '工作树不干净' -and $r.Log.Count -eq 0) "exit=$($r.Exit) $($r.Output)"
    }
    # 以下两例会在沙箱里追加提交，须放在最后：APK 的 embedded head 保持旧 $Head。
    Test-Case 'docs-only-commit-after-build-passes' {
        [IO.File]::WriteAllText((Join-Path $Sandbox 'notes.md'), 'docs only')
        Invoke-Git @('add', '-A') | Out-Null
        Invoke-Git @('-c', 'user.name=offline', '-c', 'user.email=offline@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'docs') | Out-Null
        $r = Invoke-Runner 'docsafter' 'ok'
        Assert-True ($r.Exit -eq 0 -and $r.Run.producer_commit_sha -ceq $Head -and $r.Run.commit_sha -cne $Head) "exit=$($r.Exit) $($r.Output)"
    }
    Test-Case 'app-change-after-build-rejected' {
        [void](New-Item -ItemType Directory -Path (Join-Path $Sandbox 'app') -Force)
        [IO.File]::WriteAllText((Join-Path $Sandbox 'app/x.kt'), 'changed')
        Invoke-Git @('add', '-A') | Out-Null
        Invoke-Git @('-c', 'user.name=offline', '-c', 'user.email=offline@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'app') | Out-Null
        $r = Invoke-Runner 'appafter' 'ok'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match 'app/') "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match 'content write')) 'APK 过期时不应开始会话'
    }
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($name in 'FAKE_ADB_STATE', 'FAKE_ADB_SCENARIO', 'FAKE_ADB_FIXTURE', 'FAKE_ADB_HEAD', 'FAKE_ADB_APK_SHA') { Remove-Item "env:$name" -ErrorAction SilentlyContinue }
}

Write-Host "tablet-c1b runner offline: $($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -ne 0) { exit 1 }
exit 0
