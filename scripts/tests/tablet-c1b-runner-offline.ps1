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
    'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1', 'docs\contracts\tablet-layout-observation-c1b-v1.schema.json'
)) {
    $target = Join-Path $Sandbox $relative
    [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
    Copy-Item -LiteralPath (Join-Path $RepoRoot $relative) -Destination $target
}
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
    if ($scenario -ceq 'same_apk') { Out-Text "package:/data/app/fake/base.apk`n"; exit 0 } else { exit 1 }
}
if ($cmd -ceq "shell sha256sum '/data/app/fake/base.apk'") { Out-Text "$($env:FAKE_ADB_APK_SHA)  /data/app/fake/base.apk`n"; exit 0 }
if ($cmd -match '^install -r -t ') { Out-Text "Performing Streamed Install`nSuccess`n"; exit 0 }
if ($cmd -ceq 'shell settings get secure enabled_accessibility_services') {
    Out-Text $(if ($scenario -ceq 'a11y_off') { "null`n" } else { "dev.magina.gateway/.a11y.GatewayA11yService`n" }); exit 0
}
if ($cmd -ceq 'shell dumpsys accessibility') {
    # vivo 实测：探针已连接但 dumpsys 绑定列表只列出 vivo 输入法；runner 须以 provider 自报为准。
    $boundLine = if ($scenario -ceq 'vivo_hidden_bound') { 'Service[label=vivo输入法, component=com.vivo.ai.ime.pad/x.AutoSendImageService]' } else { 'Service[label=gw, component=dev.magina.gateway/.a11y.GatewayA11yService]' }
    Out-Text "ACCESSIBILITY MANAGER (dumpsys accessibility)`nUser state[`n  Bound services:{$boundLine}`n]`n"; exit 0
}
if ($cmd -notmatch '^(exec-in content write|shell content read) --uri (?<uri>.+)$') { [Console]::Error.WriteLine("fake adb: unsupported $cmd"); exit 1 }
$uri = $Matches.uri
if (-not ($uri.StartsWith("'") -and $uri.EndsWith("'"))) { [Console]::Error.WriteLine('fake adb: URI must be single-quoted'); exit 1 }
$uri = $uri.Trim("'")
if ($uri -notmatch '^content://dev\.magina\.gateway\.tablet\.c1b/(?<path>[a-z0-9/._-]+)\?(?<query>.+)$') { exit 1 }
$path = $Matches.path; $query = @{}
foreach ($pair in $Matches.query -split '&') { $kv = $pair -split '=', 2; $query[$kv[0]] = $kv[1] }
if ($path -match '^t0/(?<run>.+)$') {
    $ms = [IO.MemoryStream]::new(); [Console]::OpenStandardInput().CopyTo($ms); $bytes = $ms.ToArray()
    $t0 = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -DateKind String
    $session = @{ run_id = $Matches.run; nonce = $query.nonce; state = 'ready_c1'; generation = 1; c1 = 0; c2 = 0; committed = @(); inflight = $null; reason = $null
        commit = $query.producer_commit_sha; artifact = $query.producer_artifact_sha256; title = $query.title_hash
        t0_sha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant(); t0_at = $t0.captured_at_utc }
    Save; exit 0
}
if ($null -eq $session -and $path -match '^status/(?<run>.+)$') {
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
            if ($scenario -ceq 'drift') { $session.generation = 2 }
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
        Out-Text ($o | ConvertTo-Json -Depth 100 -Compress); break
    }
    default { exit 1 }
}
exit 0
'@, [Text.UTF8Encoding]::new($false))

function New-T0Profile([string]$RunId) {
    $path = Join-Path $Temp "t0-$RunId.json"
    $profile = [ordered]@{
        schema_version = 5; run_id = $RunId; captured_at_utc = [DateTime]::UtcNow.AddSeconds(-5).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        device = [ordered]@{ serial_hash = (Get-Sha256Text $FakeSerial); model = 'FakeTab' }
        assessment = [ordered]@{ device_class = 'tablet'; intake_status = 'accepted'; readiness_status = 'blocked'
            readiness_block_reasons = @('focus_absent'); p0_capability = 'unsupported'
            p0_unsupported_reasons = @('wechat_layout_unverified', 'tablet_landscape_p0_unimplemented') }
    }
    [IO.File]::WriteAllText($path, ($profile | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
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
        Exit = $exit; Output = ($output -join "`n"); Evidence = $evidence; RunId = $runId
        RunRaw = if (Test-Path -LiteralPath $runJsonPath) { Get-Content -Raw -LiteralPath $runJsonPath } else { '' }
        Run = if (Test-Path -LiteralPath $runJsonPath) { Get-Content -Raw -LiteralPath $runJsonPath | ConvertFrom-Json -DateKind String } else { $null }
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
        Assert-True (@($r.Log | Where-Object { $_ -match 'exec-in content write' }).Count -eq 1 -and @($r.Log | Where-Object { $_ -match '/result/' }).Count -eq 1) 'T0 写入/result 读取次数不符'
        Assert-NoForbiddenAdb $r
    }
    Test-Case 'same-apk-skips-install' {
        $r = Invoke-Runner 'sameapk' 'same_apk'
        Assert-True ($r.Exit -eq 0 -and $r.Run.install_skipped) "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not ($r.Log -match '^-s \S+ install ')) '设备上已是同一 APK 时不应重装'
        Assert-NoForbiddenAdb $r
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
    Test-Case 'observation-anchor-mismatch-fails' {
        $r = Invoke-Runner 'anchor' 'bad_anchor'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match '锚点') "exit=$($r.Exit) $($r.Output)"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $r.Evidence 'tablet-layout-observation-c1b-v1.json'))) '锚点不符时不应写 observation'
    }
    Test-Case 'stale-apk-head-mismatch-fails' {
        $r = Invoke-Runner 'stale' 'stale_apk'
        Assert-True ($r.Exit -eq 1 -and $r.Run.failure_reason -match 'embedded_git_head') "exit=$($r.Exit) $($r.Output)"
    }
    Test-Case 'vivo-dumpsys-hides-bound-uses-provider' {
        $r = Invoke-Runner 'vivo' 'vivo_hidden_bound'
        Assert-True ($r.Exit -eq 0 -and $r.Run.outcome -ceq 'passed') "exit=$($r.Exit) $($r.Output)"
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
