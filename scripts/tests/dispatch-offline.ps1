#Requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$SourceRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$SourceDispatchPath = Join-Path $SourceRepoRoot 'scripts\dispatch.ps1'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("agent-mobile-dispatch-offline-" + [guid]::NewGuid().ToString('N'))
$RepoRoot = Join-Path $TestRoot 'repo'
$DispatchPath = Join-Path $RepoRoot 'scripts\dispatch.ps1'
$TracesDir = Join-Path $RepoRoot 'docs\runs\traces'
$LedgerPath = Join-Path $RepoRoot 'docs\runs\ledger.csv'
$LockPath = Join-Path $RepoRoot 'scripts\.dispatch.lock'
$PwshPath = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $SourceDispatchPath -PathType Leaf)) {
    throw "测试设施错误：找不到真实 wrapper：$SourceDispatchPath"
}

$FakeBin = Join-Path $TestRoot 'bin'
$SentinelDir = Join-Path $TestRoot 'sentinels'
$ExternalTools = @('adb', 'npx', 'claude', 'codex')
$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw $Because }
}

function Assert-ExitCode {
    param($Result, [int]$Expected)
    Assert-True ($Result.ExitCode -eq $Expected) "期望退出码 $Expected，实际 $($Result.ExitCode)。输出：`n$($Result.Text)"
}

function Assert-Contains {
    param([string]$Actual, [string]$Expected)
    Assert-True $Actual.Contains($Expected, [StringComparison]::OrdinalIgnoreCase) "输出缺少：$Expected`n实际输出：`n$Actual"
}

function Assert-Matches {
    param([string]$Actual, [string]$Pattern)
    Assert-True ($Actual -match $Pattern) "输出不匹配 /$Pattern/：`n$Actual"
}

function Assert-NotMatches {
    param([string]$Actual, [string]$Pattern)
    Assert-True ($Actual -notmatch $Pattern) "输出不应匹配 /$Pattern/：`n$Actual"
}

function Get-RepoEffectState {
    $traceState = if (Test-Path -LiteralPath $TracesDir) {
        @(Get-ChildItem -LiteralPath $TracesDir -File -Recurse | Sort-Object FullName | ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($TracesDir, $_.FullName)
            "$relative|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
        }) -join "`n"
    }
    else { '<missing>' }

    $ledgerState = if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
        $item = Get-Item -LiteralPath $LedgerPath
        $hash = (Get-FileHash -LiteralPath $LedgerPath -Algorithm SHA256).Hash
        "$($item.Length)|$hash"
    }
    else { '<missing>' }

    [pscustomobject]@{
        Traces = $traceState
        Ledger = $ledgerState
        Lock = Test-Path -LiteralPath $LockPath
    }
}

function Assert-NoRepoEffects {
    param($Before)
    $after = Get-RepoEffectState
    Assert-True ($after.Traces -ceq $Before.Traces) 'DryRun 新增或修改了 trace/暂停件。'
    Assert-True ($after.Ledger -ceq $Before.Ledger) 'DryRun 新增了 ledger 行或修改了 ledger。'
    Assert-True ($after.Lock -eq $Before.Lock) 'DryRun 新增或删除了派单锁。'
}

function Assert-NoExternalTools {
    param($Result)
    Assert-True ($Result.ToolCalls.Count -eq 0) "DryRun 触发了外部工具：`n$($Result.ToolCalls -join "`n")"
}

function Invoke-Dispatch {
    param([string[]]$Arguments)

    foreach ($tool in $ExternalTools) {
        $oldToolSentinel = Join-Path $SentinelDir "$tool-called.txt"
        if (Test-Path -LiteralPath $oldToolSentinel) {
            Remove-Item -LiteralPath $oldToolSentinel -Force -ErrorAction Stop
        }
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PwshPath
    $start.WorkingDirectory = $RepoRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-File')
    $start.ArgumentList.Add($DispatchPath)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment['PATH'] = $FakeBin + [IO.Path]::PathSeparator + $start.Environment['PATH']
    $start.Environment['DISPATCH_TEST_SENTINEL_DIR'] = $SentinelDir

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw '测试设施错误：无法启动 dispatch 子进程。' }
        $started = $true
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit(15000)
        if ($timedOut) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) {
                throw '测试设施错误：终止 dispatch 后进程树仍未在 5 秒内退出。'
            }
        }

        # 进程树退出后必须回收两个异步读取任务，避免管道句柄拖住 TEMP 清理。
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($timedOut) {
            throw "dispatch 子进程 15 秒未退出；可能错误地等待了键盘输入。输出：`n$stdout`n$stderr"
        }

        $toolCalls = @()
        foreach ($tool in $ExternalTools) {
            $sentinel = Join-Path $SentinelDir "$tool-called.txt"
            if (Test-Path -LiteralPath $sentinel) {
                $log = Get-Content -LiteralPath $sentinel -Raw
                $toolCalls += "$tool`: $($log.Trim())"
            }
        }

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdout
            Stderr = $stderr
            Text = $stdout + "`n" + $stderr
            ToolCalls = $toolCalls
        }
    }
    finally {
        if ($started -and -not $process.HasExited) {
            try {
                $process.Kill($true)
                if (-not $process.WaitForExit(5000)) {
                    Write-Warning 'dispatch 进程树清理后仍未退出。'
                }
            }
            catch { Write-Warning "清理 dispatch 进程树失败：$($_.Exception.Message)" }
        }
        foreach ($readTask in @($stdoutTask, $stderrTask)) {
            if ($null -ne $readTask -and -not $readTask.IsCompleted) {
                try {
                    if (-not $readTask.Wait(5000)) { Write-Warning 'dispatch 输出读取任务未能在 5 秒内回收。' }
                }
                catch { Write-Warning "回收 dispatch 输出读取任务失败：$($_.Exception.Message)" }
            }
        }
        $process.Dispose()
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message -replace "`r?`n", "`n      ")"
    }
}

try {
    # 用真实仓库当前文件构造最小 TEMP fixture；所有被测副作用都只能落在 fixture。
    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $SourceDispatchPath -Destination $DispatchPath
    foreach ($relativeDir in @('scripts\prompts', 'scripts\lib')) {
        $sourceDir = Join-Path $SourceRepoRoot $relativeDir
        if (Test-Path -LiteralPath $sourceDir -PathType Container) {
            $destinationParent = Split-Path (Join-Path $RepoRoot $relativeDir) -Parent
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
            Copy-Item -LiteralPath $sourceDir -Destination $destinationParent -Recurse
        }
    }
    # DryRun 只需要配置路径，不需要配置内容；fixture 禁止复制仓库里可能存在的私密 gateway 配置。
    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'configs') -Force | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $SourceDispatchPath).Hash -ceq (Get-FileHash -LiteralPath $DispatchPath).Hash) `
        '测试设施错误：fixture wrapper 与真实仓库当前文件不一致。'

    # 配置校验 helper 必须在 fixture 中直接加载，避免测试误读仓库里的私密配置。
    $fixtureProfileHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-profile.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureProfileHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch profile helper。'
    . $fixtureProfileHelper

    $fixtureConfigDir = Join-Path $RepoRoot 'configs\offline-fixtures'
    New-Item -ItemType Directory -Path $fixtureConfigDir -Force | Out-Null
    $testBearer = 'fixture-bearer-value-must-never-leak'
    $validGatewayConfig = Join-Path $fixtureConfigDir 'valid.json'
    $placeholderGatewayConfig = Join-Path $fixtureConfigDir 'placeholder.json'
    $wrongUrlGatewayConfig = Join-Path $fixtureConfigDir 'wrong-url.json'
    $malformedGatewayConfig = Join-Path $fixtureConfigDir 'malformed.json'

    @{
        mcpServers = @{
            gateway = @{
                type = 'http'
                url = 'http://127.0.0.1:8848/mcp'
                headers = @{ Authorization = "Bearer $testBearer" }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $validGatewayConfig -Encoding utf8
    @{
        mcpServers = @{
            gateway = @{
                type = 'http'
                url = 'http://127.0.0.1:8848/mcp'
                headers = @{ Authorization = 'Bearer <GATEWAY_TOKEN>' }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $placeholderGatewayConfig -Encoding utf8
    @{
        mcpServers = @{
            gateway = @{
                type = 'http'
                url = 'http://127.0.0.1:9999/mcp'
                headers = @{ Authorization = "Bearer $testBearer" }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $wrongUrlGatewayConfig -Encoding utf8
    Set-Content -LiteralPath $malformedGatewayConfig -Encoding utf8 `
        -Value "{ `"headers`": { `"Authorization`": `"Bearer $testBearer`" }"

    New-Item -ItemType Directory -Path $FakeBin, $SentinelDir -Force | Out-Null
    $fakeAdb = @'
@echo off
>>"%DISPATCH_TEST_SENTINEL_DIR%\adb-called.txt" echo %*
if /I "%1"=="get-serialno" (
  echo FAKE-DISPATCH-DEVICE
  exit /b 0
)
exit /b 97
'@
    Set-Content -LiteralPath (Join-Path $FakeBin 'adb.cmd') -Value $fakeAdb -Encoding ascii

    foreach ($tool in @('npx', 'claude', 'codex')) {
        $fakeTool = @"
@echo off
>>"%DISPATCH_TEST_SENTINEL_DIR%\$tool-called.txt" echo %*
exit /b 97
"@
        Set-Content -LiteralPath (Join-Path $FakeBin "$tool.cmd") -Value $fakeTool -Encoding ascii
    }

    # 先显式执行 fake adb，证明隔离设施会记录调用；随后清掉 sentinel 再测 wrapper。
    $adbSentinel = Join-Path $SentinelDir 'adb-called.txt'
    $oldSentinelDir = $env:DISPATCH_TEST_SENTINEL_DIR
    try {
        $env:DISPATCH_TEST_SENTINEL_DIR = $SentinelDir
        & (Join-Path $FakeBin 'adb.cmd') get-serialno *> $null
        Assert-True (Test-Path -LiteralPath $adbSentinel) '测试设施错误：fake adb 未写入 sentinel。'
    }
    finally {
        $env:DISPATCH_TEST_SENTINEL_DIR = $oldSentinelDir
        if (Test-Path -LiteralPath $adbSentinel) {
            Remove-Item -LiteralPath $adbSentinel -Force -ErrorAction Stop
        }
    }

    $before = Get-RepoEffectState
    $taskArgs = @('-Task', 'offline profile contract', '-Slug', 'offline-profile', '-DryRun')

    $fixtureLedgerHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-ledger.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureLedgerHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch ledger helper。'
    . $fixtureLedgerHelper

    Test-Case '执行器拒绝名单覆盖本机 shell、派生执行体与汇报类工具' {
        $src = Get-Content -LiteralPath $SourceDispatchPath -Raw -Encoding utf8
        # 两个 shell 必须成对出现：本机是 Windows，只禁 Bash 等于没禁
        # （2026-07-31 复查发现 PowerShell 一直漏在名单外）。
        foreach ($shell in @('Bash', 'PowerShell')) {
            Assert-Matches $src "'$shell'"
        }
        # 派生执行体会绕开本名单本身。
        foreach ($spawner in @('Task', 'Agent', 'Workflow')) {
            Assert-Matches $src "'$spawner'"
        }
        # 汇报/交互类：对驱动手机无用，一旦出现就会被 trace 审计判成越权，
        # 在真人已点确认、危险动作已执行之后把整腿判死（2026-07-31 ReportFindings 实锤）。
        foreach ($noise in @('ReportFindings', 'AskUserQuestion', 'TodoWrite')) {
            Assert-Matches $src "'$noise'"
        }
        # ToolSearch 必须**不在**拒绝名单里：延迟注册的 MCP 工具要靠它加载 schema。
        Assert-NotMatches $src "'ToolSearch'"
    }

    Test-Case '终态判据容忍 markdown 强调，且失败绝不落成成功' {
        # 模型写 `**结果：失败**` 是常态。旧模式只认裸行首，两条都不匹配 → dispatch 落到兜底分支
        # **把失败记成 success**。这是台账层面最危险的一种错分（2026-07-31 真机实锤同一根因）。
        $fail = Get-P0FinalVerdictPattern '失败'
        $ok = Get-P0FinalVerdictPattern '成功'
        foreach ($text in @('结果：失败', '**结果：失败**', '  **结果：失败**', '结果: 失败', '__结果：失败__')) {
            Assert-True ($text -match $fail) "应判为失败：$text"
            Assert-True ($text -notmatch $ok) "失败文本绝不能同时匹配成功：$text"
        }
        foreach ($text in @('结果：成功', '**结果：成功**', '  *结果：成功*')) {
            Assert-True ($text -match $ok) "应判为成功：$text"
            Assert-True ($text -notmatch $fail) "成功文本不该匹配失败：$text"
        }
        # 行首之外的提及不算终态（模型正文里复述"结果：成功"时不能被误判）。
        Assert-True (('前面有字 结果：成功') -notmatch $ok) '非行首的提及不该被当成终态。'
        Assert-True (("正文…`n**结果：失败**") -match $fail) '多行文本里的行首终态必须能匹配。'
    }

    Test-Case '台账归因：成功与暂停不产生 fail_reason' {
        Assert-True ((Get-FailReason -Verdict 'success') -ceq '') 'success 不该有归因。'
        Assert-True ((Get-FailReason -Verdict 'paused') -ceq '') 'paused 不是失败。'
    }

    Test-Case '台账归因：派单层信号直接成枚举' {
        Assert-True ((Get-FailReason -Verdict 'preflight-fail') -ceq 'preflight') 'preflight 归因不符。'
        Assert-True ((Get-FailReason -Verdict 'timeout') -ceq 'dispatch-timeout') 'timeout 归因不符。'
        Assert-True ((Get-FailReason -Verdict 'step-cap') -ceq 'step-cap') 'step-cap 归因不符。'
    }

    Test-Case '台账归因：优先取 trace 里最后一个 gateway 错误码' {
        # 放仓库外：这套件有"DryRun 不得有仓库副作用"的不变量，往 docs/runs/traces 里写会撞上它。
        # 前缀已纳入 dev-env.ps1 的清扫模式；用 try/finally 保证中途抛错也不泄漏。
        $traceDir = Join-Path ([IO.Path]::GetTempPath()) "agent-mobile-failreason-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $traceDir -Force | Out-Null
        $trace = Join-Path $traceDir 'fail-reason-fixture.jsonl'
        try {
        # 先出现 E_NOT_FOUND、最后是 E_BLOCKED：必须取最后一个，中间的失败往往已被重试绕过。
        @(
            '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_NOT_FOUND\"}}"}]}]}}',
            '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_BLOCKED\"}}"}]}]}}'
        ) | Set-Content -LiteralPath $trace -Encoding utf8
        # E_BLOCKED 在 Deny 腿是期望结果：safety-denied 表示安全门尽到职责，不是故障。
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'safety-denied') `
            '未取到 trace 里最后一个错误码。'

        # 同一个 E_BLOCKED，channel 不同就是两件毫不相干的事。两条夹具都用真机原样形态：
        #   overlay      真人在确认卡上点了拒绝 —— 安全门尽职
        #   test-control debug 测试控制拒收这条腿 —— **确认卡根本没弹**
        # 2026-08-01 实锤：Deny 腿白名单漏了 deny，这两种在台账里并排记成了同一个 safety-denied。
        @('{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_BLOCKED\",\"message\":\"用户拒绝了危险操作：press_key\",\"channel\":\"overlay\",\"retryable\":false}}"}]}]}}') |
            Set-Content -LiteralPath $trace -Encoding utf8
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'safety-denied') `
            '真人拒绝（channel=overlay）必须仍归因为 safety-denied。'

        @('{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_BLOCKED\",\"message\":\"debug 测试腿不在白名单\",\"channel\":\"test-control\",\"retryable\":false}}"}]}]}}') |
            Set-Content -LiteralPath $trace -Encoding utf8
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'test-control-blocked') `
            '测试控制拒收（channel=test-control）不能记成 safety-denied——那一轮确认卡根本没弹。'

        @('{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_STALE_REF\"}}"}]}]}}') |
            Set-Content -LiteralPath $trace -Encoding utf8
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'stale-context') `
            'E_STALE_REF 归因不符。'

        # 未转义形态（信封若直接落成 JSON 而非字符串）也要认。
        @('{"error":{"code":"E_CHANNEL_DOWN"}}') | Set-Content -LiteralPath $trace -Encoding utf8
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'channel-down') `
            '未转义形态的错误码也必须能匹配。'

        # 未列入映射表的错误码也要给出可读枚举，不能落到兜底把信息丢掉。
        @('{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_RATE_LIMITED\"}}"}]}]}}') |
            Set-Content -LiteralPath $trace -Encoding utf8
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile $trace) -ceq 'e-rate-limited') `
            '未映射错误码应转成可读枚举。'
        }
        finally { Remove-Item -LiteralPath $traceDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '台账归因：trace 无错误码时退回派单层信号' {
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'error_during_execution') -ceq 'executor-error_during_execution') `
            '应退回 subtype。'
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success') -ceq 'reported-fail') `
            '模型自报失败应落 reported-fail。'
        Assert-True ((Get-FailReason -Verdict 'fail' -Subtype 'success' -TraceFile 'Z:\不存在的 trace.jsonl') -ceq 'reported-fail') `
            'trace 不存在不该抛错。'
    }

    Test-Case 'gateway 有效私密配置通过纯校验' {
        $problem = Get-GatewayConfigProblem -ConfigPath $validGatewayConfig
        Assert-True ($null -eq $problem) "有效配置不应返回问题：$problem"
    }

    Test-Case 'gateway token 占位符被拒绝' {
        $problem = Get-GatewayConfigProblem -ConfigPath $placeholderGatewayConfig
        Assert-True (-not [string]::IsNullOrWhiteSpace($problem)) '占位 token 应返回问题。'
        Assert-NotMatches $problem ([regex]::Escape($testBearer))
    }

    Test-Case 'gateway 错误 URL 被拒绝且不泄露 Bearer' {
        $problem = Get-GatewayConfigProblem -ConfigPath $wrongUrlGatewayConfig
        Assert-True (-not [string]::IsNullOrWhiteSpace($problem)) '错误 URL 应返回问题。'
        Assert-NotMatches $problem ([regex]::Escape($testBearer))
    }

    Test-Case 'gateway 畸形 JSON 被拒绝且不泄露 Bearer' {
        $problem = Get-GatewayConfigProblem -ConfigPath $malformedGatewayConfig
        Assert-True (-not [string]::IsNullOrWhiteSpace($problem)) '畸形 JSON 应返回问题。'
        Assert-NotMatches $problem ([regex]::Escape($testBearer))
    }

    Test-Case 'DryRun 不得调用 adb' {
        $result = Invoke-Dispatch $taskArgs
        Assert-ExitCode $result 0
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '省略 Executor 默认 mobile' {
        $result = Invoke-Dispatch $taskArgs
        Assert-ExitCode $result 0
        Assert-Contains $result.Text 'executor=mobile'
        Assert-Matches $result.Text 'configs[\\/]mobile-mcp\.json'
        Assert-Contains $result.Text 'mcp__mobile'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '显式 mobile profile' {
        $result = Invoke-Dispatch ($taskArgs + @('-Executor', 'mobile'))
        Assert-ExitCode $result 0
        Assert-Contains $result.Text 'executor=mobile'
        Assert-Matches $result.Text 'configs[\\/]mobile-mcp\.json'
        Assert-Contains $result.Text 'mcp__mobile'
        Assert-NotMatches $result.Text '文件传输助手'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case 'gateway profile 与专用安全站规' {
        $result = Invoke-Dispatch ($taskArgs + @('-Executor', 'gateway'))
        Assert-ExitCode $result 0
        Assert-Contains $result.Text 'executor=gateway'
        Assert-Matches $result.Text 'configs[\\/]gateway-mcp\.json'
        Assert-Contains $result.Text 'mcp__gateway'
        Assert-Matches $result.Text '(?i)\bref\b'
        Assert-Contains $result.Text '统一硬门'
        Assert-NotMatches $result.Text '×\s*3\.5|中文(?:文本)?输入通道当前不可用|文件传输助手'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '非法 executor 被参数校验拒绝' {
        $result = Invoke-Dispatch ($taskArgs + @('-Executor', 'invalid-profile'))
        Assert-True ($result.ExitCode -ne 0) '非法 executor 不应成功。'
        Assert-Contains $result.Text 'Executor'
        Assert-Contains $result.Text 'mobile'
        Assert-Contains $result.Text 'gateway'
        Assert-NotMatches $result.Text '(?i)parameter cannot be found|找不到[^\r\n]*参数名称'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    $gatewayPause = Join-Path $TestRoot 'gateway.pause.md'
    Set-Content -LiteralPath $gatewayPause -Encoding utf8 -Value @'
slug: offline-gateway-confirm
leg: 1
executor: gateway
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：离线测试，不存在真实手机动作。
待执行动作：离线验证 profile 继承。
剩余步骤：无。
'@

    Test-Case '确认腿自动继承 gateway 且不请求键盘' {
        $result = Invoke-Dispatch @('-Confirm', $gatewayPause, '-DryRun')
        Assert-ExitCode $result 0
        Assert-Contains $result.Text 'executor=gateway'
        Assert-Contains $result.Text 'leg=2'
        Assert-Matches $result.Text 'configs[\\/]gateway-mcp\.json'
        Assert-Contains $result.Text 'mcp__gateway'
        Assert-NotMatches $result.Text '键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    $gatewaySafetyPause = Join-Path $TestRoot 'gateway-safety-terminal.pause.md'
    Set-Content -LiteralPath $gatewaySafetyPause -Encoding utf8 -Value @'
slug: offline-gateway-safety-terminal
leg: 1
executor: gateway
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：secret-pause-body-must-not-leak
待执行动作：危险工具已返回 E_CONFIRM_TIMEOUT。
剩余步骤：不得恢复。
'@

    Test-Case 'gateway safety 终态暂停件机械拒绝恢复' {
        $result = Invoke-Dispatch @('-Confirm', $gatewaySafetyPause, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'gateway safety 终态不应允许进入第二腿。'
        Assert-Contains $result.Text 'E_CONFIRM_TIMEOUT'
        Assert-Contains $result.Text '拒绝恢复'
        Assert-NotMatches $result.Text 'secret-pause-body-must-not-leak|键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '确认腿显式不同 executor 时 fail-fast' {
        $result = Invoke-Dispatch @('-Confirm', $gatewayPause, '-Executor', 'mobile', '-DryRun')
        Assert-True ($result.ExitCode -ne 0) '确认腿不应允许切换 executor。'
        Assert-Contains $result.Text 'gateway'
        Assert-Contains $result.Text 'mobile'
        Assert-Matches $result.Text '(?i)不一致|不同|冲突|继承|mismatch'
        Assert-NotMatches $result.Text '(?i)parameter cannot be found|找不到[^\r\n]*参数名称'
        Assert-NotMatches $result.Text '键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '暂停件作废是真的写得进去（拒绝重放的另一半）' {
        # 「拒绝重放」有两半：挡住已消费文件的那一半下面有用例，**把文件标成已消费**的那一半
        # 只在人真的键入 CONFIRM 之后才走，离线跑不到。所以那一半抽成了纯函数单独钉住——
        # 否则这条判据看起来有两条用例撑着，实际只验了一半。
        . (Join-Path $RepoRoot 'scripts\lib\dispatch-pause.ps1')

        $raw = "slug: s1`nleg: 1`nexecutor: gateway`n---`n[AWAIT_CONFIRM]`n屏幕现状：x`n"
        $document = Read-DispatchPauseDocument -Text $raw
        Assert-True ($document.Meta['slug'] -ceq 's1') 'meta 解析错误。'
        Assert-True ($document.Consumed -ceq '') '未消费的暂停件不该带 consumed。'
        Assert-Contains $document.Body '[AWAIT_CONFIRM]'

        $marked = Set-DispatchPauseConsumed -Text $raw -At '2026-08-01T12:00:00Z'
        $after = Read-DispatchPauseDocument -Text $marked
        Assert-True ($after.Consumed -ceq '2026-08-01T12:00:00Z') '作废后必须带 consumed 时刻。'
        # 作废只加一行，正文与其余 meta 一字不改——第二腿的提示词就是从正文来的。
        Assert-True ($after.Body -ceq $document.Body) '作废不得改动报告正文。'
        Assert-True ($after.Meta['slug'] -ceq 's1' -and $after.Meta['leg'] -ceq '1') '作废不得改动原有 meta。'

        $threw = $false
        try { $null = Set-DispatchPauseConsumed -Text $marked -At '2026-08-01T13:00:00Z' }
        catch { $threw = $true }
        Assert-True $threw '已消费的暂停件不得被二次作废（否则重放窗口会被刷新）。'

        foreach ($bad in @('没有分隔符的文本', '')) {
            $threw = $false
            try { $null = Read-DispatchPauseDocument -Text $bad } catch { $threw = $true }
            Assert-True $threw "格式非法必须抛错，不得兜底猜测：「$bad」"
        }
    }

    Test-Case '暂停件 leg 接龙被拒（两段式只有第二腿）' {
        $chained = Join-Path $TestRoot 'chained.pause.md'
        Set-Content -LiteralPath $chained -Encoding utf8 -Value @'
slug: offline-chained
leg: 2
executor: gateway
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：离线测试。
待执行动作：不该被允许。
剩余步骤：无。
'@
        $result = Invoke-Dispatch @('-Confirm', $chained, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'leg=2 的暂停件会产生第三腿，必须拒绝。'
        Assert-Matches $result.Text '两段式只有第二腿|接龙'
        Assert-NoRepoEffects $before
    }

    Test-Case '暂停件 leg 非数字时 fail-fast' {
        $bogus = Join-Path $TestRoot 'bogus-leg.pause.md'
        Set-Content -LiteralPath $bogus -Encoding utf8 -Value @'
slug: offline-bogus-leg
leg: 一
executor: gateway
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：离线测试。
待执行动作：无。
剩余步骤：无。
'@
        $result = Invoke-Dispatch @('-Confirm', $bogus, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'leg 非数字必须直接失败，不能悄悄当 0。'
        Assert-Contains $result.Text 'leg'
        Assert-NoRepoEffects $before
    }

    Test-Case '已消费的暂停件拒绝重放' {
        # 一次人工确认只授权一次执行（硬门不变量 4）。落盘的暂停件天然可重放——
        # 同一份 -Confirm 跑两次就是两次执行，而人只点过一次头。
        $consumed = Join-Path $TestRoot 'consumed.pause.md'
        Set-Content -LiteralPath $consumed -Encoding utf8 -Value @'
slug: offline-consumed
leg: 1
executor: gateway
session_id: offline
consumed: 2026-08-01T00:00:00.0000000Z
---
[AWAIT_CONFIRM]
屏幕现状：secret-consumed-body-must-not-leak
待执行动作：不该被允许。
剩余步骤：无。
'@
        $result = Invoke-Dispatch @('-Confirm', $consumed, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) '已消费的暂停件必须拒绝。'
        Assert-Matches $result.Text '已.*消费|重放'
        Assert-NotMatches $result.Text 'secret-consumed-body-must-not-leak'
        Assert-NoRepoEffects $before
    }

    Test-Case 'slug 不得带路径分隔符或 ..' {
        # slug 直接拼进 trace 文件名与台账 trace_file 列，而它有两个来源不是本机人手打的。
        foreach ($bad in @('../escape', 'a/b', 'a\b', 'ok..ok')) {
            $result = Invoke-Dispatch @('-Task', '离线', '-Slug', $bad, '-DryRun')
            Assert-True ($result.ExitCode -ne 0) "非法 slug 应被拒绝：$bad"
            Assert-Contains $result.Text 'slug'
        }
        $ok = Invoke-Dispatch @('-Task', '离线', '-Slug', 'p0-safety-allow_1.2', '-DryRun')
        Assert-ExitCode $ok 0
        Assert-NoRepoEffects $before
    }

    $legacyPause = Join-Path $TestRoot 'legacy.pause.md'
    Set-Content -LiteralPath $legacyPause -Encoding utf8 -Value @'
slug: offline-legacy-confirm
leg: 1
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：离线测试，不存在真实手机动作。
待执行动作：验证旧暂停件兼容。
剩余步骤：无。
'@

    Test-Case '旧暂停件无 executor 时按 mobile' {
        $result = Invoke-Dispatch @('-Confirm', $legacyPause, '-DryRun')
        Assert-ExitCode $result 0
        Assert-Contains $result.Text 'executor=mobile'
        Assert-Contains $result.Text 'leg=2'
        Assert-Matches $result.Text 'configs[\\/]mobile-mcp\.json'
        Assert-Contains $result.Text 'mcp__mobile'
        Assert-NotMatches $result.Text '键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    # ── 单机单派锁（残锁自清 vs 活锁必拒）────────────────────────────────────
    $fixtureLockHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-lock.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureLockHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch lock helper。'
    . $fixtureLockHelper
    $lockProbeDir = Join-Path $TestRoot 'lock-probe'
    New-Item -ItemType Directory -Path $lockProbeDir -Force | Out-Null

    Test-Case '无锁时正常取得并写入可读的持有者信息' {
        $path = Join-Path $lockProbeDir 'fresh.lock'
        $stream = Open-DispatchLock -Path $path -Owner 'offline/leg1/gateway'
        try {
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) '取锁后锁文件不存在。'
            $holder = Get-DispatchLockHolder -Path $path
            Assert-True $holder.Active '自己持有句柄期间应判为活锁。'
        }
        finally { $stream.Close(); Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '崩溃残留的锁自动清理后取锁成功' {
        $path = Join-Path $lockProbeDir 'stale.lock'
        # 上一次派单崩溃：文件留下，句柄已被 OS 回收。
        Set-Content -LiteralPath $path -Value 'pid=999999 owner=crashed/leg1/gateway at=2026-07-26T00:00:00' -Encoding utf8
        $stream = Open-DispatchLock -Path $path -Owner 'offline/leg1/gateway'
        try {
            Assert-True ($null -ne $stream) '残锁未被自动清理。'
        }
        finally { $stream.Close() }
        # 持锁期间独占，内容只能等释放后核对：旧残锁已被换成本次派单的记录。
        $content = [IO.File]::ReadAllText($path)
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        Assert-Contains $content 'owner=offline/leg1/gateway'
        Assert-NotMatches $content 'crashed'
    }

    Test-Case '仍被持有的锁必拒且不删锁文件' {
        $path = Join-Path $lockProbeDir 'active.lock'
        $held = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
        try {
            $threw = $false
            try { Open-DispatchLock -Path $path -Owner 'offline/leg1/gateway' | Out-Null }
            catch {
                $threw = $true
                Assert-Contains $_.Exception.Message '疑似另一次派单进行中'
            }
            Assert-True $threw '活锁未被拒绝。'
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) '活锁被错误删除。'
        }
        finally { $held.Close(); Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '全部 DryRun 汇总后仍无仓库副作用' {
        Assert-NoRepoEffects $before
        foreach ($tool in $ExternalTools) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $SentinelDir "$tool-called.txt"))) `
                "最后一次 DryRun 仍触发了 fake $tool。"
        }
    }

    Write-Host ''
    Write-Host "dispatch offline: $($script:Passed) passed, $($script:Failed) failed"
    if ($script:Failed -gt 0) { exit 1 }
    exit 0
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        try {
            Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $TestRoot) { Write-Warning "TEMP fixture 清理后仍存在：$TestRoot" }
        }
        catch { Write-Warning "清理 TEMP fixture 失败（$TestRoot）：$($_.Exception.Message)" }
    }
}
