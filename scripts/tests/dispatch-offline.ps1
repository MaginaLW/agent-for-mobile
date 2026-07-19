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

    $legacyPause = Join-Path $TestRoot 'legacy.pause.md'
    Set-Content -LiteralPath $legacyPause -Encoding utf8 -Value @'
slug: offline-legacy-confirm
leg: 2
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
        Assert-Contains $result.Text 'leg=3'
        Assert-Matches $result.Text 'configs[\\/]mobile-mcp\.json'
        Assert-Contains $result.Text 'mcp__mobile'
        Assert-NotMatches $result.Text '键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
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
