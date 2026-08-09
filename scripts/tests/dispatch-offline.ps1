#Requires -Version 7
[CmdletBinding()]
param([string]$Filter = '*')

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
$FixturePowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
        @(Get-ChildItem -LiteralPath $TracesDir -File -Recurse |
            Where-Object { $_.Name -notlike 'fixture-*.pause.md' } |
            Sort-Object FullName | ForEach-Object {
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
    param(
        [string[]]$Arguments,
        [AllowNull()][string]$StandardInput = $null
    )

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
    $start.Environment['DISPATCH_TEST_LOCK_PATH'] = $LockPath

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw '测试设施错误：无法启动 dispatch 子进程。' }
        $started = $true
        if ($null -ne $StandardInput) { $process.StandardInput.Write($StandardInput) }
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
        # 若被测实现错误地遗留了仍持有管道句柄的孤儿孙进程，这里也必须有界失败，
        # 不能让 RED fixture 自己无限挂住整个离线套件。
        foreach ($readTask in @($stdoutTask, $stderrTask)) {
            if (-not $readTask.Wait(5000)) {
                throw '测试设施错误：dispatch 已退出但输出管道仍被遗留孙进程持有。'
            }
        }
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
    if ($Name -notlike $Filter) { return }
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

    # provisioner 也要加载：那条"把写和查接起来"的用例要调它真正的写入函数，
    # **不是复刻一份等价实现**——复刻的话，写入路径改了用例照样绿，等于白写。
    $fixtureProvisioner = Join-Path $RepoRoot 'scripts\lib\p0-device-provision.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureProvisioner -PathType Leaf) `
        '测试设施错误：fixture 缺少 provisioner。'
    . $fixtureProvisioner

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
                timeout = 420000
                headers = @{ Authorization = "Bearer $testBearer" }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $validGatewayConfig -Encoding utf8
    @{
        mcpServers = @{
            gateway = @{
                type = 'http'
                url = 'http://127.0.0.1:8848/mcp'
                timeout = 420000
                headers = @{ Authorization = 'Bearer <GATEWAY_TOKEN>' }
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $placeholderGatewayConfig -Encoding utf8
    @{
        mcpServers = @{
            gateway = @{
                type = 'http'
                url = 'http://127.0.0.1:9999/mcp'
                timeout = 420000
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
if /I "%1"=="get-state" (
  echo device
  exit /b 0
)
if /I "%1"=="shell" if /I "%2"=="input" if /I "%3"=="keyevent" exit /b 0
if /I "%1"=="get-serialno" (
  echo FAKE-DISPATCH-DEVICE
  exit /b 0
)
if /I "%1"=="forward" exit /b 0
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

    # Codex 行为夹具必须像真实 `codex exec --json` 一样从 stdin 取 prompt、向 stdout
    # 写 JSONL。敏感 token 只在进程内与已知夹具值做恒定比较；落盘只记随机 env 名与
    # 布尔结果，绝不把值写进 sentinel。
    $fakeCodexSource = Join-Path $SentinelDir 'fake-codex.cs'
    $fakeCodexExe = Join-Path $FakeBin 'codex.exe'
    @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

public static class Program {
    public static int Main(string[] args) {
        string sentinel = Environment.GetEnvironmentVariable("DISPATCH_TEST_SENTINEL_DIR");
        if (Array.IndexOf(args, "tools.view_image=false") >= 0) {
            Console.Error.WriteLine("strict-config fixture: unknown configuration field tools.view_image");
            return 64;
        }
        if (Array.IndexOf(args, "code_mode_host") >= 0) {
            Console.Error.WriteLine("strict fixture: MCP tool host was disabled");
            return 65;
        }
        File.AppendAllText(Path.Combine(sentinel, "codex-called.txt"), string.Join(" ", args) + "\n", Encoding.UTF8);
        File.WriteAllLines(Path.Combine(sentinel, "codex-argv.txt"), args, Encoding.UTF8);
        string cwd = Directory.GetCurrentDirectory();
        File.WriteAllText(Path.Combine(sentinel, "codex-cwd.txt"), cwd, Encoding.UTF8);
        File.WriteAllText(Path.Combine(sentinel, "codex-cwd-empty.txt"),
            (Directory.GetFileSystemEntries(cwd).Length == 0).ToString().ToLowerInvariant(), Encoding.ASCII);
        File.WriteAllText(Path.Combine(sentinel, "codex-prompt.txt"), Console.In.ReadToEnd(), Encoding.UTF8);
        List<string> secretNames = new List<string>();
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
            string name = (string)entry.Key;
            if (name.StartsWith("AGENT_MOBILE_MCP_", StringComparison.Ordinal)) secretNames.Add(name);
        }
        File.WriteAllLines(Path.Combine(sentinel, "codex-secret-env-names.txt"), secretNames, Encoding.ASCII);
        bool secretOk = secretNames.Count == 1 &&
            Environment.GetEnvironmentVariable(secretNames[0]) == "fixture-bearer-value-must-never-leak";
        File.WriteAllText(Path.Combine(sentinel, "codex-secret-ok.txt"),
            secretOk.ToString().ToLowerInvariant(), Encoding.ASCII);
        bool environmentOk = Environment.GetEnvironmentVariable("CODEX_ACCESS_TOKEN") == null &&
            Environment.GetEnvironmentVariable("CODEX_SQLITE_HOME") == null &&
            Environment.GetEnvironmentVariable("OPENAI_API_KEY") == null &&
            Environment.GetEnvironmentVariable("DEEPSEEK_API_KEY") == null &&
            Environment.GetEnvironmentVariable("ARBITRARY_PARENT_SECRET") == null &&
            Environment.GetEnvironmentVariable("RUST_BACKTRACE") == null &&
            Environment.GetEnvironmentVariable("RUST_LOG") == "error" &&
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("SystemRoot")) &&
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("TEMP")) &&
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("PATH")) &&
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("LOCALAPPDATA")) &&
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("USERPROFILE")) &&
            Environment.GetEnvironmentVariable("CODEX_HOME") ==
                Environment.GetEnvironmentVariable("DISPATCH_TEST_EXPECTED_CODEX_HOME") &&
            Environment.GetEnvironmentVariable("NO_PROXY") == "127.0.0.1,localhost" &&
            Environment.GetEnvironmentVariable("no_proxy") == "127.0.0.1,localhost";
        File.WriteAllText(Path.Combine(sentinel, "codex-environment-ok.txt"),
            environmentOk.ToString().ToLowerInvariant(), Encoding.ASCII);
        Console.OutputEncoding = new UTF8Encoding(false);
        string scenario = Environment.GetEnvironmentVariable("DISPATCH_TEST_CODEX_SCENARIO") ?? "paused";
        if (scenario == "malformed") {
            Console.WriteLine("{not-json");
            return 0;
        }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"offline-codex-thread\"}");
        if (scenario == "turn-failed") {
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"error-1\",\"type\":\"error\",\"message\":\"redacted fixture diagnostic\"}}");
            Console.WriteLine("{\"type\":\"turn.started\"}");
            Console.WriteLine("{\"type\":\"error\",\"message\":\"redacted fixture diagnostic\"}");
            Console.WriteLine("{\"type\":\"turn.failed\",\"error\":{\"message\":\"redacted fixture diagnostic\"}}");
            return 1;
        }
        Console.WriteLine("{\"type\":\"turn.started\"}");
        if (scenario == "success") {
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"Result: success\\nResult line follows.\\n结果：成功\"}}");
            Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,\"output_tokens\":2}}");
            return 0;
        }
        if (scenario == "other-server") {
            Console.WriteLine("{\"type\":\"item.started\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"evil\",\"tool\":\"foreground_app\",\"arguments\":{}}}");
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"evil\",\"tool\":\"foreground_app\",\"arguments\":{},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true}\"}]},\"error\":null,\"status\":\"completed\"}}");
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"结果：成功\"}}");
            Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,\"output_tokens\":2}}");
            return 0;
        }
        Console.WriteLine("{\"type\":\"item.started\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"gateway\",\"tool\":\"foreground_app\",\"arguments\":{}}}");
        if (scenario == "tool-failure") {
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"gateway\",\"tool\":\"foreground_app\",\"arguments\":{},\"result\":null,\"error\":{\"message\":\"redacted fixture failure\"},\"status\":\"failed\"}}");
            Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"结果：失败\"}}");
            Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,\"output_tokens\":2}}");
            return 0;
        }
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"gateway\",\"tool\":\"foreground_app\",\"arguments\":{},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":true,\\\"data\\\":{\\\"package\\\":\\\"com.tencent.mm\\\"}}\"}],\"structured_content\":null},\"error\":null,\"status\":\"completed\"}}");
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"[AWAIT_CONFIRM]\\nstate: offline readonly proof.\\naction: wait for human confirmation.\\nremaining: none.\"}}");
        Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":11,\"cached_input_tokens\":2,\"output_tokens\":7,\"cache_write_input_tokens\":3}}");
        return 0;
    }
}
'@ | Set-Content -LiteralPath $fakeCodexSource -Encoding utf8
    $cscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compilerOutput = & $cscPath /nologo /target:exe "/out:$fakeCodexExe" $fakeCodexSource 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeCodexExe -PathType Leaf)) `
        "测试设施错误：无法编译 fake codex.exe：$compilerOutput"
    # 生产 resolver 只接受 OpenAI 签名的桌面应用 bundled exe；离线 fake 不得靠 PATH
    # 冒充。只改 TEMP fixture 的调用点，显式传入测试 override，生产文件没有该入口参数。
    $fixtureDispatchSource = Get-Content -LiteralPath $DispatchPath -Raw -Encoding utf8
    $codexSpecNeedle = '-WorkspacePath $codexWorkspace -Model $Model -ModelWasExplicit $ModelWasExplicit'
    Assert-True $fixtureDispatchSource.Contains($codexSpecNeedle, [StringComparison]::Ordinal) `
        '测试设施错误：无法定位 Codex launch spec seam。'
    $fixtureDispatchSource = $fixtureDispatchSource.Replace(
        $codexSpecNeedle,
        "$codexSpecNeedle -CodexExecutableOverride '$($fakeCodexExe -replace "'","''")'"
    )
    $environmentSeam = '-EnvironmentAllowList $childEnvironmentAllowList -ChildEnvironmentOverrides'
    Assert-True $fixtureDispatchSource.Contains($environmentSeam, [StringComparison]::Ordinal) `
        '测试设施错误：无法定位 Codex environment allowlist seam。'
    $fixtureDispatchSource = $fixtureDispatchSource.Replace(
        $environmentSeam,
        "-PreserveEnvironmentNames @('DISPATCH_TEST_SENTINEL_DIR','DISPATCH_TEST_CODEX_SCENARIO'," +
            "'DISPATCH_TEST_EXPECTED_CODEX_HOME') $environmentSeam"
    )
    Set-Content -LiteralPath $DispatchPath -Value $fixtureDispatchSource -Encoding utf8

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

    # gateway -Confirm 的正向证据必须来自固定 traces 目录；夹具先造好，再冻结 DryRun 副作用快照。
    $gatewaySafeTraceName = '20260809-000001-offline-gateway-confirm-gateway-claude-leg1.jsonl'
    $gatewaySafeTrace = Join-Path $TracesDir $gatewaySafeTraceName
    $gatewaySafetyTraceName = '20260809-000002-offline-gateway-safety-terminal-gateway-claude-leg1.jsonl'
    $gatewaySafetyTrace = Join-Path $TracesDir $gatewaySafetyTraceName
    $gatewayVerifyFailTraceName = '20260809-000000-offline-gateway-verify-fail-gateway-claude-leg1.jsonl'
    $gatewayVerifyFailTrace = Join-Path $TracesDir $gatewayVerifyFailTraceName
    $gatewayEmptySessionTraceName = '20260809-000003-offline-gateway-empty-session-gateway-claude-leg1.jsonl'
    $gatewayEmptySessionTrace = Join-Path $TracesDir $gatewayEmptySessionTraceName
    New-Item -ItemType Directory -Path $TracesDir -Force | Out-Null
    @(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r1","name":"mcp__gateway__foreground_app","input":{}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":[{"type":"text","text":"{\"ok\":true,\"data\":{\"package\":\"com.tencent.mm\"}}"}]}]}}',
        '{"type":"result","subtype":"success","session_id":"offline","result":"[AWAIT_CONFIRM]\n屏幕现状：离线测试，不存在真实手机动作。\n待执行动作：离线验证 profile 继承。\n剩余步骤：无。"}'
    ) | Set-Content -LiteralPath $gatewaySafeTrace -Encoding utf8
    @(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"mcp__gateway__press_key","input":{"key":"enter"}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"p1","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_CONFIRM_TIMEOUT\",\"channel\":\"safety\",\"retryable\":false}}"}]}]}}',
        '{"type":"result","subtype":"success","session_id":"offline","result":"[AWAIT_CONFIRM]\n屏幕现状：secret-pause-body-must-not-leak\n待执行动作：危险工具已返回 E_CONFIRM_TIMEOUT。\n剩余步骤：不得恢复。"}'
    ) | Set-Content -LiteralPath $gatewaySafetyTrace -Encoding utf8
    @(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"mcp__gateway__press_key","input":{"key":"enter"}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"p1","content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_VERIFY_FAIL\",\"channel\":\"safety\",\"retryable\":false}}"}]}]}}',
        '{"type":"result","subtype":"success","session_id":"offline-verify-fail","result":"[AWAIT_CONFIRM]\n屏幕现状：危险调用已经返回。\n待执行动作：危险工具已返回 E_VERIFY_FAIL。\n剩余步骤：不得恢复。"}'
    ) | Set-Content -LiteralPath $gatewayVerifyFailTrace -Encoding utf8
    @(
        '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r1","name":"mcp__gateway__foreground_app","input":{}}]}}',
        '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":[{"type":"text","text":"{\"ok\":true,\"data\":{\"package\":\"com.tencent.mm\"}}"}]}]}}',
        '{"type":"result","subtype":"success","result":"[AWAIT_CONFIRM]\n屏幕现状：空 session 不能建立关联。\n待执行动作：不得恢复。\n剩余步骤：无。"}'
    ) | Set-Content -LiteralPath $gatewayEmptySessionTrace -Encoding utf8

    $before = Get-RepoEffectState
    $taskArgs = @('-Task', 'offline profile contract', '-Slug', 'offline-profile', '-DryRun')

    $fixtureLedgerHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-ledger.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureLedgerHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch ledger helper。'
    . $fixtureLedgerHelper

    Test-Case 'Codex 非 DryRun 必须启动官方 CLI、产出 trace/ledger 并进入真人确认窗口' {
        $privateGatewayConfig = Join-Path $RepoRoot 'configs\gateway-mcp.json'
        Copy-Item -LiteralPath $validGatewayConfig -Destination $privateGatewayConfig -Force
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        $poisonNames = @(
            'CODEX_ACCESS_TOKEN','CODEX_SQLITE_HOME','OPENAI_API_KEY','RUST_LOG','RUST_BACKTRACE',
            'DEEPSEEK_API_KEY','ARBITRARY_PARENT_SECRET','CODEX_HOME','DISPATCH_TEST_EXPECTED_CODEX_HOME'
        )
        $oldPoison = @{}
        foreach ($name in $poisonNames) { $oldPoison[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            $env:CODEX_ACCESS_TOKEN = 'fixture-codex-access-token-must-not-reach-child'
            $env:CODEX_SQLITE_HOME = 'fixture-codex-sqlite-must-not-reach-child'
            $env:OPENAI_API_KEY = 'fixture-openai-key-must-not-reach-child'
            $env:DEEPSEEK_API_KEY = 'fixture-deepseek-key-must-not-reach-child'
            $env:ARBITRARY_PARENT_SECRET = 'fixture-arbitrary-secret-must-not-reach-child'
            $env:RUST_LOG = 'trace'
            $env:RUST_BACKTRACE = 'full'
            $safeCodexHome = Join-Path $TestRoot 'fixture-codex-home-safe'
            New-Item -ItemType Directory -Path $safeCodexHome -Force | Out-Null
            $env:CODEX_HOME = $safeCodexHome
            $env:DISPATCH_TEST_EXPECTED_CODEX_HOME = $safeCodexHome
            $result = Invoke-Dispatch @(
                '-Task','Codex dispatch offline contract','-Slug','offline-codex-channel',
                '-Brain','codex','-Executor','gateway'
            )
            if ($result.ExitCode -ne 0) {
                $fixtureErr = @(Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                    Where-Object Name -like '*-offline-codex-channel-gateway-codex-leg1.err.txt' |
                    Select-Object -First 1)
                if ($fixtureErr.Count -eq 1) {
                    throw "Codex fixture 启动失败：$((Get-Content -LiteralPath $fixtureErr[0].FullName -Raw) -replace $testBearer,'<redacted>')"
                }
            }
            Assert-ExitCode $result 0
            Assert-True (@($result.ToolCalls | Where-Object { $_ -match '^codex:' }).Count -eq 1) `
                'Codex 分支没有实际调用 fake codex。'
            Assert-NotMatches $result.Text '接口已预留|实现推迟|Bearer\s+fixture'
            Assert-Matches $result.Text '派单结果：paused|危险动作已暂停'

            $argv = Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-argv.txt') -Raw -Encoding utf8
            foreach ($required in @(
                'exec','--json','--ephemeral','--ignore-user-config','--ignore-rules',
                '--sandbox','read-only','--disable','shell_tool',
                'tools.web_search=false',
                'mcp_servers.gateway.required=true','default_tools_approval_mode="approve"',
                'shell_environment_policy.inherit="none"'
            )) { Assert-Contains $argv $required }
            # Codex 0.147 的 strict-config 不认识 tools.view_image；传它会在 MCP/model 前 exit 1。
            # image_generation feature 仍被关闭，但 view_image 本身没有上游 disable flag，
            # 不能在这里声称已机械禁用；外部 sandbox 边界由独立真实 smoke 验证。
            Assert-NotMatches $argv 'tools\.view_image|unknown configuration field'
            foreach ($disabledCodeFeature in @('code_mode','code_mode_buffered_exec','code_mode_only')) {
                Assert-Contains $argv $disabledCodeFeature
            }
            Assert-NotMatches $argv '(?m)^code_mode_host$|MCP tool host was disabled'
            Assert-NotMatches $argv '(?m)^--model\s*$|(?m)^sonnet\s*$|dangerously-bypass|approval_policy'
            $codexCwd = (Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-cwd.txt') -Raw).Trim()
            Assert-True (-not $codexCwd.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) `
                'Codex 仍在 repo/project root 内运行。'
            Assert-Contains $argv $codexCwd
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-cwd-empty.txt') -Raw).Trim() -ceq 'true') `
                'Codex 启动时的受控 workspace 非空。'
            Assert-Contains (Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-prompt.txt') -Raw) `
                'Codex dispatch offline contract'
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-secret-ok.txt') -Raw).Trim() -ceq 'true') `
                'Codex 子进程没有通过随机 env 名取得 gateway token。'
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-environment-ok.txt') -Raw).Trim() -ceq 'true') `
                'Codex child env 未完整 scrub token/debug 变量、保留 CODEX_HOME 或固定 loopback no_proxy。'
            $secretNames = @(Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-secret-env-names.txt'))
            Assert-True ($secretNames.Count -eq 1 -and $secretNames[0] -match '^AGENT_MOBILE_MCP_[A-F0-9]{32}$') `
                'gateway token env 名不唯一或不可预测性不足。'

            $trace = @(Get-ChildItem -LiteralPath $TracesDir -File |
                Where-Object Name -like '*-offline-codex-channel-gateway-codex-leg1.jsonl')
            $pause = @(Get-ChildItem -LiteralPath $TracesDir -File |
                Where-Object Name -like '*-offline-codex-channel-gateway-codex-leg1.pause.md')
            Assert-True ($trace.Count -eq 1) 'Codex JSONL trace 未按 brain basename 落盘。'
            Assert-True ($pause.Count -eq 1) 'Codex paused 未落真人确认暂停件。'
            Assert-Matches (Get-Content -LiteralPath $pause[0].FullName -Raw) 'gateway_pause_evidence: readonly-trace-v1'
            Assert-Matches (Get-Content -LiteralPath $pause[0].FullName -Raw) '(?m)^brain: codex$'
            $confirmDryRun = Invoke-Dispatch @('-Confirm',$pause[0].FullName,'-DryRun')
            Assert-ExitCode $confirmDryRun 0
            Assert-Matches $confirmDryRun.Text 'brain=codex'
            Assert-NoExternalTools $confirmDryRun

            $brainHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1'
            Assert-True (Test-Path -LiteralPath $brainHelper -PathType Leaf) `
                'dispatch 未提供 runner 可复用的双 schema helper。'
            . $brainHelper
            $transcript = Read-DispatchTraceTranscript -TracePath $trace[0].FullName -Brain codex
            Assert-True ($transcript.Brain -ceq 'codex' -and $transcript.Schema -ceq 'codex-jsonl-v1') `
                'canonical transcript 缺 brain/schema。'
            Assert-True ($transcript.SessionId -ceq 'offline-codex-thread' -and
                $transcript.Terminal.Status -ceq 'success' -and $transcript.Terminal.Success) `
                'Codex session/terminal 未归一。'
            Assert-True ($transcript.Calls.Count -eq 1 -and $transcript.Calls[0].Name -ceq 'foreground_app' -and
                $transcript.Calls[0].ResultCount -eq 1 -and $transcript.Calls[0].Outcome -ceq 'success') `
                'Codex MCP started/completed 未归一。'
            $ledgerTail = Get-Content -LiteralPath $LedgerPath -Tail 1
            Assert-Matches $ledgerTail ',codex,,1,11,7,2,3,,.*paused,offline-codex-thread,.*gateway-codex-leg1\.jsonl'
            Assert-NotMatches ($result.Text + "`n" + (Get-Content -LiteralPath $trace[0].FullName -Raw) + "`n" + $ledgerTail) `
                'fixture-bearer-value-must-never-leak'
        }
        finally {
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object Name -like '*-offline-codex-channel-gateway-codex-leg1.*' |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) { [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length) }
            foreach ($name in @(
                'codex-called.txt','codex-argv.txt','codex-prompt.txt','codex-cwd.txt','codex-cwd-empty.txt',
                'codex-secret-env-names.txt','codex-secret-ok.txt','codex-environment-ok.txt'
            )) { Remove-Item -LiteralPath (Join-Path $SentinelDir $name) -Force -ErrorAction SilentlyContinue }
            foreach ($name in $poisonNames) {
                [Environment]::SetEnvironmentVariable($name, $oldPoison[$name])
            }
        }
    }

    Test-Case 'Codex JSONL 失败面与非选中 MCP server 必须 fail closed' {
        Copy-Item -LiteralPath $validGatewayConfig -Destination (Join-Path $RepoRoot 'configs\gateway-mcp.json') -Force
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        $oldScenario = $env:DISPATCH_TEST_CODEX_SCENARIO
        try {
            $cases = @(
                @{ Scenario='success'; Exit=0; Pattern='派单结果：success' },
                @{ Scenario='malformed'; Exit=1; Pattern='trace-invalid-or-incomplete' },
                @{ Scenario='tool-failure'; Exit=1; Pattern='mcp-transport-failure' },
                @{ Scenario='turn-failed'; Exit=1; Pattern='brain-process-exit-1' },
                @{ Scenario='other-server'; Exit=1; Pattern='unauthorized-mcp-server' }
            )
            foreach ($case in $cases) {
                $env:DISPATCH_TEST_CODEX_SCENARIO = $case.Scenario
                $slug = "offline-codex-$($case.Scenario)"
                $result = Invoke-Dispatch @(
                    '-Task',"Codex $($case.Scenario) contract",'-Slug',$slug,
                    '-Brain','codex','-Executor','gateway'
                )
                Assert-ExitCode $result $case.Exit
                Assert-Matches $result.Text $case.Pattern
                Assert-NotMatches $result.Text 'redacted fixture diagnostic|redacted fixture failure|fixture-bearer-value'
                $ledgerTail = Get-Content -LiteralPath $LedgerPath -Tail 1
                Assert-NotMatches $ledgerTail 'redacted fixture diagnostic|redacted fixture failure|fixture-bearer-value'
                Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                    Where-Object Name -like "*-$slug-gateway-codex-leg1.*" |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                foreach ($name in @(
                    'codex-called.txt','codex-argv.txt','codex-prompt.txt','codex-cwd.txt','codex-cwd-empty.txt',
                    'codex-secret-env-names.txt','codex-secret-ok.txt','codex-environment-ok.txt'
                )) { Remove-Item -LiteralPath (Join-Path $SentinelDir $name) -Force -ErrorAction SilentlyContinue }
            }
        }
        finally {
            $env:DISPATCH_TEST_CODEX_SCENARIO = $oldScenario
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object Name -like '*-offline-codex-*-gateway-codex-leg1.*' |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) { [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length) }
        }
    }

    Test-Case 'Codex version probe 在启动官方 exe 前清空父环境' {
        $source = Get-Content -LiteralPath (Join-Path $SourceRepoRoot 'scripts\lib\dispatch-brain.ps1') -Raw -Encoding utf8
        $start = $source.IndexOf('function Resolve-DispatchTrustedCodexExecutable', [StringComparison]::Ordinal)
        $end = $source.IndexOf('function New-DispatchCodexLaunchSpec', $start, [StringComparison]::Ordinal)
        Assert-True ($start -ge 0 -and $end -gt $start) '无法定位 Codex version resolver。'
        $resolver = $source.Substring($start, $end - $start)
        Assert-Contains $resolver '$start.Environment.Clear()'
        foreach ($required in @('SystemRoot','WINDIR','ComSpec','TEMP','PATH','PATHEXT')) {
            Assert-Contains $resolver "'$required'"
        }
        Assert-NotMatches $resolver 'CODEX_HOME|ACCESS_TOKEN|API_KEY|DEEPSEEK|PROXY'
    }

    Test-Case 'shared transcript helper 在 StrictMode 3 下安全读取 Claude 可选字段并保留工具 inventory' {
        $trace = Join-Path $SentinelDir 'claude-strictmode-transcript.jsonl'
        try {
            @(
                '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"ToolSearch","input":{"query":"gateway"}}]}}',
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"schema loaded"}]}]}}',
                '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"forbidden fixture"}}]}}',
                '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"not executed"}]}]}}',
                '{"type":"result","subtype":"success","session_id":"strict-claude","result":"结果：成功"}'
            ) | Set-Content -LiteralPath $trace -Encoding utf8
            $transcript = & {
                Set-StrictMode -Version 3.0
                . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                Read-DispatchTraceTranscript -TracePath $trace -Brain claude
            }
            Assert-True ($transcript.SessionId -ceq 'strict-claude' -and $transcript.Terminal.Success) `
                'StrictMode 3 下 Claude terminal/session 未归一。'
            Assert-True ($null -eq $transcript.Usage.InputTokens -and $null -eq $transcript.Turns -and
                $null -eq $transcript.CostUsd) '缺省 usage/turns/cost 被伪造成 0 或触发 StrictMode。'
            Assert-True ($transcript.Calls.Count -eq 2 -and
                $transcript.Calls[0].RawName -ceq 'ToolSearch' -and
                $transcript.Calls[1].RawName -ceq 'Bash') 'ToolSearch/Bash inventory 在 shared helper 中丢失。'
            Assert-True (@($transcript.Calls | Where-Object {
                $_.Outcome -cne 'success' -or -not $_.CompletedBeforeNext
            }).Count -eq 0) '缺省 is_error 应按 transport success 处理，且时序必须保留。'
        }
        finally { Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue }
    }

    Test-Case 'Codex 多条 agent_message 只把最后正文归一为 FinalText' {
        $trace = Join-Path $SentinelDir 'codex-multiple-agent-messages.jsonl'
        try {
            @(
                '{"type":"thread.started","thread_id":"codex-multi-message"}',
                '{"type":"turn.started"}',
                '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"intermediate-secret-must-not-escape"}}',
                '{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"foreground_app","arguments":{}}}',
                '{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"foreground_app","arguments":{},"result":{"content":[{"type":"text","text":"{\"ok\":true}"}]},"error":null,"status":"completed"}}',
                '{"type":"item.completed","item":{"id":"message-2","type":"agent_message","text":"结果：成功"}}',
                '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":2}}'
            ) | Set-Content -LiteralPath $trace -Encoding utf8
            $transcript = & {
                Set-StrictMode -Version 3.0
                . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                Read-DispatchTraceTranscript -TracePath $trace -Brain codex
            }
            Assert-True ($transcript.Terminal.Success -and $transcript.FinalText -ceq '结果：成功') `
                'Codex 多条 agent_message 应以最后一条作为 FinalText。'
            $canonical = $transcript | ConvertTo-Json -Compress -Depth 20
            Assert-NotMatches $canonical 'intermediate-secret-must-not-escape'
            Assert-True ($null -eq $transcript.PSObject.Properties['Messages']) `
                'canonical transcript 不得额外暴露前序 agent_message 集合。'
        }
        finally { Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue }
    }

    Test-Case 'Codex 最后 agent_message 早于 MCP completed 必须 fail closed' {
        $trace = Join-Path $SentinelDir 'codex-message-before-call-completed.jsonl'
        try {
            @(
                '{"type":"thread.started","thread_id":"codex-early-message"}',
                '{"type":"turn.started"}',
                '{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"press_key","arguments":{"key":"enter"}}}',
                '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"结果：成功"}}',
                '{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"press_key","arguments":{"key":"enter"},"result":{"content":[{"type":"text","text":"{\"ok\":false,\"error\":{\"code\":\"E_BLOCKED\"}}"}]},"error":null,"status":"completed"}}',
                '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":2}}'
            ) | Set-Content -LiteralPath $trace -Encoding utf8
            $rejected = $false
            $rejectionMessage = ''
            try {
                $null = & {
                    Set-StrictMode -Version 3.0
                    . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                    Read-DispatchTraceTranscript -TracePath $trace -Brain codex
                }
            }
            catch {
                $rejectionMessage = $_.Exception.Message
                $rejected = $rejectionMessage -match 'agent_message|MCP|completed|时序'
            }
            Assert-True $rejected "MCP 结果前的最后正文被错误接受或因错误理由拒绝：$rejectionMessage"
        }
        finally { Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue }
    }

    Test-Case 'Codex mobile 成功内容仅归一为脱敏 transport marker' {
        $trace = Join-Path $SentinelDir 'codex-mobile-content.jsonl'
        try {
            $validCases = @(
                @{
                    Name='text'
                    Result='{"content":[{"type":"text","text":"mobile-raw-text-secret-must-not-escape"}],"isError":false}'
                    Type='text'; Sentinel='mobile-raw-text-secret-must-not-escape'
                },
                @{
                    Name='image'
                    Result='{"content":[{"type":"image","data":"c2VjcmV0LWltYWdlLXBheWxvYWQ=","mimeType":"image/png"}],"isError":false}'
                    Type='image'; Sentinel='c2VjcmV0LWltYWdlLXBheWxvYWQ='
                }
            )
            foreach ($case in $validCases) {
                @(
                    '{"type":"thread.started","thread_id":"codex-mobile-content"}',
                    '{"type":"turn.started"}',
                    '{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"mobile","tool":"fixture_tool","arguments":{}}}',
                    ('{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"mobile","tool":"fixture_tool","arguments":{},"result":' + $case.Result + ',"error":null,"status":"completed"}}'),
                    '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"结果：成功"}}',
                    '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":2}}'
                ) | Set-Content -LiteralPath $trace -Encoding utf8
                $transcript = & {
                    Set-StrictMode -Version 3.0
                    . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                    Read-DispatchTraceTranscript -TracePath $trace -Brain codex
                }
                Assert-True ($transcript.Calls.Count -eq 1 -and
                    $transcript.Calls[0].Outcome -ceq 'success' -and
                    $transcript.Calls[0].ResultEnvelope.Transport -ceq 'mobile-content' -and
                    $transcript.Calls[0].ResultEnvelope.ContentCount -eq 1 -and
                    $transcript.Calls[0].ResultEnvelope.ContentTypes[0] -ceq $case.Type) `
                    "mobile $($case.Name) 未归一为脱敏 marker。"
                Assert-NotMatches ($transcript | ConvertTo-Json -Compress -Depth 20) ([regex]::Escape($case.Sentinel))
            }

            $invalidResults = @(
                '{"content":[],"isError":false}',
                '{"content":[{"type":"resource","uri":"file:///forbidden"}],"isError":false}',
                '{"content":[{"type":"image","data":"not-base64!","mimeType":"image/png"}],"isError":false}',
                '{"content":[{"type":"text","text":"must-reject"}],"isError":true}'
            )
            foreach ($invalidResult in $invalidResults) {
                @(
                    '{"type":"thread.started","thread_id":"codex-mobile-invalid"}',
                    '{"type":"turn.started"}',
                    '{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"mobile","tool":"fixture_tool","arguments":{}}}',
                    ('{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"mobile","tool":"fixture_tool","arguments":{},"result":' + $invalidResult + ',"error":null,"status":"completed"}}'),
                    '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"结果：成功"}}',
                    '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":0,"output_tokens":2}}'
                ) | Set-Content -LiteralPath $trace -Encoding utf8
                $rejected = $false
                try {
                    $null = & {
                        Set-StrictMode -Version 3.0
                        . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                        Read-DispatchTraceTranscript -TracePath $trace -Brain codex
                    }
                }
                catch { $rejected = $true }
                Assert-True $rejected "非法 mobile MCP result 被接受：$invalidResult"
            }
        }
        finally { Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue }
    }

    Test-Case 'Codex mobile launch spec 固定关闭 telemetry 且拒绝配置注入 env' {
        $config = Join-Path $SentinelDir 'mobile-codex-config.json'
        try {
            . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
            @{
                mcpServers=@{
                    mobile=@{ type='stdio'; command='npx'; args=@('-y','@mobilenext/mobile-mcp@0.0.62') }
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config -Encoding utf8
            $spec = & {
                Set-StrictMode -Version 3.0
                . (Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1')
                New-DispatchCodexLaunchSpec -Profile ([pscustomobject]@{Name='mobile'}) `
                    -ConfigPath $config -WorkspacePath $SentinelDir -Model '' -ModelWasExplicit $false `
                    -Leg 1 -CodexExecutableOverride $fakeCodexExe
            }
            $telemetryArgs = @($spec.Arguments | Where-Object {
                $_ -like 'mcp_servers.mobile.env=*'
            })
            Assert-True ($telemetryArgs.Count -eq 1 -and
                $telemetryArgs[0] -ceq 'mcp_servers.mobile.env={MOBILEMCP_DISABLE_TELEMETRY="1"}') `
                'mobile server 未固定 MOBILEMCP_DISABLE_TELEMETRY=1。'
            $enabledToolArgs = @($spec.Arguments | Where-Object {
                $_ -like 'mcp_servers.mobile.enabled_tools=*'
            })
            Assert-True ($enabledToolArgs.Count -eq 1) 'mobile server 缺少唯一 enabled_tools 白名单。'
            $enabledTools = @(
                'mobile_list_available_devices','mobile_list_apps','mobile_launch_app','mobile_terminate_app',
                'mobile_get_screen_size','mobile_click_on_screen_at_coordinates',
                'mobile_double_tap_on_screen','mobile_long_press_on_screen_at_coordinates',
                'mobile_list_elements_on_screen','mobile_press_button','mobile_open_url',
                'mobile_swipe_on_screen','mobile_type_keys','mobile_take_screenshot','mobile_set_orientation',
                'mobile_get_orientation','mobile_list_crashes','mobile_get_crash'
            )
            $actualEnabledTools = @(($enabledToolArgs[0].Substring(
                $enabledToolArgs[0].IndexOf('=', [StringComparison]::Ordinal) + 1)) |
                ConvertFrom-Json -ErrorAction Stop)
            Assert-True ($actualEnabledTools.Count -eq $enabledTools.Count) `
                "mobile enabled_tools 数量漂移：expected=$($enabledTools.Count), actual=$($actualEnabledTools.Count)。"
            $expectedSet = @($enabledTools | Sort-Object) -join "`n"
            $actualSet = @($actualEnabledTools | ForEach-Object { [string]$_ } | Sort-Object) -join "`n"
            Assert-True ($actualSet -ceq $expectedSet) `
                "mobile leg1 enabled_tools 必须与锁定18项 exact set 深等。actual=$($actualEnabledTools -join ',')"
            foreach ($forbidden in @(
                'mobile_uninstall_app','mobile_install_app','mobile_save_screenshot',
                'mobile_start_screen_recording','mobile_stop_screen_recording'
            )) { Assert-True ($forbidden -notin $actualEnabledTools) "forbidden mobile tool 出现在白名单：$forbidden" }
            Assert-True ($spec.SensitiveEnvironment.Count -eq 0) 'mobile launch spec 不得携带 gateway bearer。'

            $leg2Spec = New-DispatchCodexLaunchSpec -Profile ([pscustomobject]@{Name='mobile'}) `
                -ConfigPath $config -WorkspacePath $SentinelDir -Model '' -ModelWasExplicit $false `
                -Leg 2 -CodexExecutableOverride $fakeCodexExe
            $leg2Arg = @($leg2Spec.Arguments | Where-Object {
                $_ -like 'mcp_servers.mobile.enabled_tools=*'
            })
            Assert-True ($leg2Arg.Count -eq 1) 'mobile leg2 缺少唯一 enabled_tools 白名单。'
            $leg2Actual = @(($leg2Arg[0].Substring($leg2Arg[0].IndexOf('=') + 1)) |
                ConvertFrom-Json -ErrorAction Stop)
            $leg2Expected = @($enabledTools + 'mobile_uninstall_app' | Sort-Object) -join "`n"
            Assert-True ($leg2Actual.Count -eq 19 -and
                (@($leg2Actual | Sort-Object) -join "`n") -ceq $leg2Expected) `
                'mobile leg2 必须仅比 leg1 多出 uninstall。'

            $dispatchTokens = $null
            $dispatchParseErrors = $null
            $dispatchAst = [Management.Automation.Language.Parser]::ParseFile(
                $SourceDispatchPath, [ref]$dispatchTokens, [ref]$dispatchParseErrors)
            Assert-True ($dispatchParseErrors.Count -eq 0) 'dispatch.ps1 AST 解析失败。'
            $publicParameters = @($dispatchAst.ParamBlock.Parameters | ForEach-Object {
                $_.Name.VariablePath.UserPath
            })
            Assert-True ('Leg' -notin $publicParameters) 'dispatch CLI 不得暴露可直达第二腿的 -Leg 参数。'

            @{
                mcpServers=@{
                    mobile=@{
                        type='stdio'; command='npx'; args=@('-y','@mobilenext/mobile-mcp@0.0.62')
                        env=@{ DEEPSEEK_API_KEY='must-not-enter-mobile-mcp' }
                    }
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config -Encoding utf8
            $rejected = $false
            try {
                $null = New-DispatchCodexLaunchSpec -Profile ([pscustomobject]@{Name='mobile'}) `
                    -ConfigPath $config -WorkspacePath $SentinelDir -Model '' -ModelWasExplicit $false `
                    -Leg 1 -CodexExecutableOverride $fakeCodexExe
            }
            catch { $rejected = $true }
            Assert-True $rejected 'mobile 配置内自带 env 被错误接受。'
        }
        finally { Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '执行器拒绝名单覆盖本机 shell、派生执行体与汇报类工具' {
        $src = Get-Content -LiteralPath $SourceDispatchPath -Raw -Encoding utf8
        $denyMatch = [regex]::Match($src, '(?s)\$LocalToolDenyList\s*=\s*@\((?<body>.*?)\)\s*-join')
        Assert-True $denyMatch.Success '无法定位 LocalToolDenyList。'
        $denyBody = $denyMatch.Groups['body'].Value
        # 两个 shell 必须成对出现：本机是 Windows，只禁 Bash 等于没禁
        # （2026-07-31 复查发现 PowerShell 一直漏在名单外）。
        foreach ($shell in @('Bash', 'PowerShell')) {
            Assert-Matches $denyBody "'$shell'"
        }
        # 派生执行体会绕开本名单本身。
        foreach ($spawner in @('Task', 'Agent', 'Workflow')) {
            Assert-Matches $denyBody "'$spawner'"
        }
        # 汇报/交互类：对驱动手机无用，一旦出现就会被 trace 审计判成越权，
        # 在真人已点确认、危险动作已执行之后把整腿判死（2026-07-31 ReportFindings 实锤）。
        foreach ($noise in @('ReportFindings', 'AskUserQuestion', 'TodoWrite')) {
            Assert-Matches $denyBody "'$noise'"
        }
        # ToolSearch 必须**不在**拒绝名单里：延迟注册的 MCP 工具要靠它加载 schema。
        Assert-NotMatches $denyBody "'ToolSearch'"
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

    Test-Case 'gateway 私密配置缺 timeout 或过小一律拒跑' {
        # HTTP 传输的「首字节」计时器默认 60s（stdio/WebSocket 没有这一层），而危险动作
        # 要阻塞到「决定 90s + 等前台 300s + 开销」≈420s。2026-08-08 真机上就是这么被砍的，
        # 现场看到的是"客户端超时、无响应体、无错误码"，与功能坏了分不开。
        # **配置是 gitignored 的私密文件，不随 checkout 过来**，所以只能在开跑前查。
        $probe = Join-Path ([IO.Path]::GetTempPath()) "gw-cfg-$([guid]::NewGuid().ToString('N')).json"
        try {
            $missing = @{ mcpServers = @{ gateway = [ordered]@{
                type = 'http'; url = 'http://127.0.0.1:8848/mcp'
                headers = @{ Authorization = "Bearer $testBearer" } } } }
            $missing | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $probe -Encoding utf8
            $problem = Get-GatewayConfigProblem -ConfigPath $probe
            Assert-True ($problem -like '*timeout*') "缺 timeout 应被拒：$problem"
            Assert-NotMatches $problem ([regex]::Escape($testBearer))

            $tooSmall = @{ mcpServers = @{ gateway = [ordered]@{
                type = 'http'; url = 'http://127.0.0.1:8848/mcp'; timeout = 60000
                headers = @{ Authorization = "Bearer $testBearer" } } } }
            $tooSmall | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $probe -Encoding utf8
            $problem = Get-GatewayConfigProblem -ConfigPath $probe
            Assert-True ($problem -like '*下限*') "timeout 过小应被拒：$problem"
            Assert-NotMatches $problem ([regex]::Escape($testBearer))
        }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force } }
    }

    Test-Case 'provision 实际写出的配置必须能通过闸门（把"写"和"查"接起来的那一条）' {
        # **这条用例是 2026-08-08 那次翻车的直接产物，注释写长一点值得。**
        #
        # 当时给 `timeout` 加了开跑前闸门，`Get-GatewayConfigProblem` 有用例、
        # `Set-P0GatewayConfigToken` 也有它自己的路径——**两个函数各自都对，
        # 缺的是把它们接起来的这一条**。而 `-Provision` 每轮都会覆盖那份配置
        # （覆盖在前、校验在后），于是四腿在第 1 腿开跑前被自己的闸门拒掉，每轮复现，
        # 且 check.ps1 五项全绿一点都没拦住。
        #
        # **这条用例对将来新增的任何闸门字段都自动生效**：它比"维护一张字段清单"结实，
        # 因为它不依赖有人记得同步那张清单。
        $probeDir = Join-Path ([IO.Path]::GetTempPath()) "gw-prov-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        try {
            $configPath = Join-Path $probeDir 'gateway-mcp.json'
            $session = [pscustomobject]@{
                ConfigPath = $configPath
                PrivateTemporaryFiles = [Collections.Generic.List[string]]::new()
                CleanupIssues = [Collections.Generic.List[string]]::new()
            }
            Set-P0GatewayConfigToken -Session $session -Token $testBearer

            $problem = Get-GatewayConfigProblem -ConfigPath $configPath
            Assert-True ($null -eq $problem) "provision 写出的配置被闸门拒了：$problem"

            # 顺带把主会话点名的穷举核对钉住：闸门查的每个字段，产出路径都真的写了。
            $written = (Get-Content -LiteralPath $configPath -Raw -Encoding utf8 |
                ConvertFrom-Json).mcpServers.gateway
            foreach ($field in $GatewayMcpGatedFields) {
                Assert-True ($null -ne $written.PSObject.Properties[$field]) `
                    "闸门校验 $field，而 provision 写出的配置里没有它。"
            }
            Assert-True ($written.timeout -eq $GatewayMcpMinTimeoutMs) `
                "provision 必须从同一个常量取下限，实际写出 $($written.timeout)"
        }
        finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '模板里的 gateway MCP 示例自己就满足那条下限' {
        # 例子不满足下限的话，照着抄的人一定被拒跑，而他会以为是校验坏了。
        $example = Get-Content -LiteralPath (Join-Path $SourceRepoRoot 'configs\gateway-mcp.json.example') `
            -Raw -Encoding utf8 | ConvertFrom-Json
        Assert-True ($example.mcpServers.gateway.timeout -ge 420000) `
            "example 里的 timeout 低于下限：$($example.mcpServers.gateway.timeout)"
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

    $gatewayPause = Join-Path $TracesDir 'fixture-gateway.pause.md'
    Set-Content -LiteralPath $gatewayPause -Encoding utf8 -Value @"
slug: offline-gateway-confirm
leg: 1
executor: gateway
session_id: offline
trace: $gatewaySafeTraceName
---
[AWAIT_CONFIRM]
屏幕现状：离线测试，不存在真实手机动作。
待执行动作：离线验证 profile 继承。
剩余步骤：无。
"@

    $redirectedPause = Join-Path $TracesDir 'fixture-redirected-confirm.pause.md'
    Set-Content -LiteralPath $redirectedPause -Encoding utf8 -Value @'
slug: offline-redirected-confirm
leg: 1
executor: mobile
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：离线测试。
待执行动作：不得由重定向 stdin 授权。
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

    Test-Case '-Confirm 暂停件 direct leaf hardlink 必须在首次读取前拒绝' {
        $outsidePause = Join-Path $SentinelDir 'confirm-pause-link-target.md'
        $linkedPause = Join-Path $TracesDir 'fixture-confirm-pause-link.pause.md'
        Set-Content -LiteralPath $outsidePause -Encoding utf8 -Value @"
slug: offline-gateway-confirm
leg: 1
executor: gateway
session_id: offline
trace: $gatewaySafeTraceName
---
[AWAIT_CONFIRM]
屏幕现状：离线测试，不存在真实手机动作。
待执行动作：离线验证 profile 继承。
剩余步骤：无。
"@
        $expectedHash = (Get-FileHash -LiteralPath $outsidePause -Algorithm SHA256).Hash
        try {
            New-Item -ItemType HardLink -Path $linkedPause -Target $outsidePause -ErrorAction Stop | Out-Null
            Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-Item -LiteralPath $linkedPause -Force).LinkType)) `
                'fixture 未实际建立 pause hardlink。'
            $result = Invoke-Dispatch @('-Confirm', $linkedPause, '-DryRun')
            Assert-True ($result.ExitCode -ne 0) 'Confirm pause hardlink 必须 fail closed。'
            Assert-Contains $result.Text 'unsafe_artifact_path'
            Assert-NotMatches $result.Text '(?i)Bearer\s+|confirm-pause-link-target'
            Assert-NoExternalTools $result
            Assert-True ((Get-FileHash -LiteralPath $outsidePause -Algorithm SHA256).Hash -ceq $expectedHash) `
                'dispatch 跟随或改写了根外 pause target。'
        }
        finally { Remove-Item -LiteralPath $linkedPause -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '-Confirm 暂停件 ancestor junction 必须在首次读取前拒绝且不泄漏正文' {
        $outsideRoot = Join-Path $SentinelDir 'confirm-ancestor-target'
        $outsideSub = Join-Path $outsideRoot 'ordinary-subdirectory'
        $outsidePause = Join-Path $outsideSub 'nested.pause.md'
        $junction = Join-Path $TracesDir 'fixture-confirm-ancestor-link'
        New-Item -ItemType Directory -Path $outsideSub -Force | Out-Null
        Set-Content -LiteralPath $outsidePause -Encoding utf8 -Value @'
slug: offline-confirm-ancestor
leg: 1
executor: mobile
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：Authorization: Bearer confirm-ancestor-fixture-secret
待执行动作：不得跟随 ancestor junction 读取。
剩余步骤：无。
'@
        $expectedHash = (Get-FileHash -LiteralPath $outsidePause -Algorithm SHA256).Hash
        try {
            New-Item -ItemType Junction -Path $junction -Target $outsideRoot -ErrorAction Stop | Out-Null
            $item = Get-Item -LiteralPath $junction -Force
            Assert-True (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
                'fixture 未实际建立 Confirm ancestor junction。'
            $result = Invoke-Dispatch @(
                '-Confirm', (Join-Path (Join-Path $junction 'ordinary-subdirectory') 'nested.pause.md'), '-DryRun')
            Assert-True ($result.ExitCode -ne 0) 'Confirm ancestor junction 必须 fail closed。'
            Assert-Contains $result.Text 'unsafe_artifact_path'
            Assert-NotMatches $result.Text '(?i)Bearer\s+confirm-ancestor-fixture-secret|confirm-ancestor-target'
            Assert-NoExternalTools $result
            Assert-True ((Get-FileHash -LiteralPath $outsidePause -Algorithm SHA256).Hash -ceq $expectedHash) `
                'dispatch 跟随/消费了 ancestor junction 根外 pause。'
        }
        finally { Remove-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue }
    }

    Test-Case '-Confirm 引用的固定 trace direct leaf hardlink 必须在首次读取前拒绝' {
        $traceName = '20260809-000004-offline-gateway-trace-link-gateway-claude-leg1.jsonl'
        $traceLink = Join-Path $TracesDir $traceName
        $outsideTrace = Join-Path $SentinelDir 'confirm-trace-link-target.jsonl'
        Copy-Item -LiteralPath $gatewaySafeTrace -Destination $outsideTrace
        $expectedHash = (Get-FileHash -LiteralPath $outsideTrace -Algorithm SHA256).Hash
        $pause = Join-Path $TracesDir 'fixture-confirm-trace-link.pause.md'
        Set-Content -LiteralPath $pause -Encoding utf8 -Value @"
slug: offline-gateway-trace-link
leg: 1
executor: gateway
session_id: offline
trace: $traceName
---
[AWAIT_CONFIRM]
屏幕现状：离线测试，不存在真实手机动作。
待执行动作：离线验证 profile 继承。
剩余步骤：无。
"@
        try {
            New-Item -ItemType HardLink -Path $traceLink -Target $outsideTrace -ErrorAction Stop | Out-Null
            Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-Item -LiteralPath $traceLink -Force).LinkType)) `
                'fixture 未实际建立 trace hardlink。'
            $result = Invoke-Dispatch @('-Confirm', $pause, '-DryRun')
            Assert-True ($result.ExitCode -ne 0) 'Confirm trace hardlink 必须 fail closed。'
            Assert-Contains $result.Text 'unsafe_artifact_path'
            Assert-NotMatches $result.Text 'confirm-trace-link-target'
            Assert-NoExternalTools $result
            Assert-True ((Get-FileHash -LiteralPath $outsideTrace -Algorithm SHA256).Hash -ceq $expectedHash) `
                'dispatch 跟随或改写了根外 trace target。'
        }
        finally { Remove-Item -LiteralPath $traceLink -Force -ErrorAction SilentlyContinue }
    }

    $gatewaySafetyPause = Join-Path $TracesDir 'fixture-gateway-safety-terminal.pause.md'
    Set-Content -LiteralPath $gatewaySafetyPause -Encoding utf8 -Value @"
slug: offline-gateway-safety-terminal
leg: 1
executor: gateway
session_id: offline
trace: $gatewaySafetyTraceName
---
[AWAIT_CONFIRM]
屏幕现状：secret-pause-body-must-not-leak
待执行动作：危险工具已返回 E_CONFIRM_TIMEOUT。
剩余步骤：不得恢复。
"@

    Test-Case 'gateway safety 终态暂停件机械拒绝恢复' {
        $result = Invoke-Dispatch @('-Confirm', $gatewaySafetyPause, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'gateway safety 终态不应允许进入第二腿。'
        Assert-Matches $result.Text '只读|危险或未知工具|结构化 trace|拒绝恢复'
        Assert-NotMatches $result.Text 'secret-pause-body-must-not-leak|键入\s*CONFIRM|Read-Host'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case '旧 gateway 暂停件缺 trace 正向证据时 fail closed' {
        $legacyGateway = Join-Path $TracesDir 'fixture-legacy-gateway-no-trace.pause.md'
        Set-Content -LiteralPath $legacyGateway -Encoding utf8 -Value @'
slug: offline-legacy-gateway
leg: 1
executor: gateway
session_id: offline
---
[AWAIT_CONFIRM]
屏幕现状：旧格式。
待执行动作：无法证明。
剩余步骤：无。
'@
        $result = Invoke-Dispatch @('-Confirm', $legacyGateway, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) '旧 gateway 暂停件不能证明危险工具未调用，必须拒绝。'
        Assert-Matches $result.Text 'trace.*证明|正向证明|拒绝恢复'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $before
    }

    Test-Case 'gateway pause 与 trace 的 session_id 同为空也不能冒充正向关联' {
        $emptySessionPause = Join-Path $TracesDir 'fixture-gateway-empty-session.pause.md'
        Set-Content -LiteralPath $emptySessionPause -Encoding utf8 -Value @"
slug: offline-gateway-empty-session
leg: 1
executor: gateway
session_id:
trace: $gatewayEmptySessionTraceName
---
[AWAIT_CONFIRM]
屏幕现状：空 session 不能建立关联。
待执行动作：不得恢复。
剩余步骤：无。
"@
        $result = Invoke-Dispatch @('-Confirm', $emptySessionPause, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) '空 session_id 不能用空==空伪造 trace/pause 关联。'
        Assert-Contains $result.Text 'gateway 暂停件 session_id 不能为空'
        Assert-NoExternalTools $result
    }

    Test-Case 'gateway trace 的 terminal session_id 缺失必须由 proof 显式拒绝' {
        $missingTerminalSessionPause = Join-Path $TracesDir 'fixture-gateway-missing-terminal-session.pause.md'
        Set-Content -LiteralPath $missingTerminalSessionPause -Encoding utf8 -Value @"
slug: offline-gateway-empty-session
leg: 1
executor: gateway
session_id: offline-present-in-pause
trace: $gatewayEmptySessionTraceName
---
[AWAIT_CONFIRM]
屏幕现状：空 session 不能建立关联。
待执行动作：不得恢复。
剩余步骤：无。
"@
        $result = Invoke-Dispatch @('-Confirm', $missingTerminalSessionPause, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) 'trace terminal session_id 缺失必须 fail closed。'
        Assert-Contains $result.Text 'gateway trace terminal session_id 不能为空'
        Assert-NoExternalTools $result
    }

    $gatewayVerifyFailPause = Join-Path $TracesDir 'fixture-gateway-verify-fail.pause.md'
    Set-Content -LiteralPath $gatewayVerifyFailPause -Encoding utf8 -Value @"
slug: offline-gateway-verify-fail
leg: 1
executor: gateway
session_id: offline-verify-fail
trace: $gatewayVerifyFailTraceName
---
[AWAIT_CONFIRM]
屏幕现状：危险调用已经返回。
待执行动作：危险工具已返回 E_VERIFY_FAIL。
剩余步骤：不得恢复。
"@

    Test-Case 'gateway 危险调用后返回 E_VERIFY_FAIL 的暂停件不得进入第二腿' {
        $result = Invoke-Dispatch @('-Confirm', $gatewayVerifyFailPause, '-DryRun')
        Assert-True ($result.ExitCode -ne 0) '危险调用已经发生，E_VERIFY_FAIL 不得被恢复。'
        Assert-Matches $result.Text '危险工具|结构化 trace|拒绝恢复|E_VERIFY_FAIL'
        Assert-NotMatches $result.Text 'executor=gateway.*leg=2'
        Assert-NoExternalTools $result
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
        $chained = Join-Path $TracesDir 'fixture-chained.pause.md'
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
        $bogus = Join-Path $TracesDir 'fixture-bogus-leg.pause.md'
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
        $consumed = Join-Path $TracesDir 'fixture-consumed.pause.md'
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

    $legacyPause = Join-Path $TracesDir 'fixture-legacy.pause.md'
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

    function New-DispatchLockLinkVariants {
        param(
            [Parameter(Mandatory)][string]$Prefix,
            [Parameter(Mandatory)][string]$Target
        )

        $variants = @()
        $hardLink = Join-Path $lockProbeDir "$Prefix-hardlink.lock"
        New-Item -ItemType HardLink -Path $hardLink -Target $Target -ErrorAction Stop | Out-Null
        $hardLinkItem = Get-Item -LiteralPath $hardLink -Force -ErrorAction Stop
        Assert-True ([string]$hardLinkItem.LinkType -ceq 'HardLink') `
            '测试设施错误：未创建真实 HardLink 锁叶子。'
        $variants += [pscustomobject]@{ Kind = 'HardLink'; Path = $hardLink }

        $symbolicLink = Join-Path $lockProbeDir "$Prefix-symlink.lock"
        try {
            New-Item -ItemType SymbolicLink -Path $symbolicLink -Target $Target -ErrorAction Stop | Out-Null
            $symbolicLinkItem = Get-Item -LiteralPath $symbolicLink -Force -ErrorAction Stop
            Assert-True (
                [string]$symbolicLinkItem.LinkType -ceq 'SymbolicLink' -and
                ($symbolicLinkItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
            ) '测试设施错误：未创建真实 SymbolicLink 重解析锁叶子。'
            $variants += [pscustomobject]@{ Kind = 'SymbolicLink'; Path = $symbolicLink }
        }
        catch {
            Write-Host 'INFO  当前 Windows 权限不允许创建 SymbolicLink；HardLink 负例仍为强制覆盖。'
            Remove-Item -LiteralPath $symbolicLink -Force -ErrorAction SilentlyContinue
        }
        return $variants
    }

    function Assert-DispatchLockLinkRejected {
        param(
            [Parameter(Mandatory)]$Variant,
            [Parameter(Mandatory)][string]$ExternalTarget,
            [Parameter(Mandatory)][string]$Secret,
            [Parameter(Mandatory)][ValidateSet('GetHolder', 'Open')][string]$Operation
        )

        $hashBefore = (Get-FileHash -LiteralPath $ExternalTarget -Algorithm SHA256).Hash
        $captured = @(& {
            try {
                if ($Operation -ceq 'GetHolder') {
                    $value = Get-DispatchLockHolder -Path $Variant.Path
                }
                else {
                    $value = Open-DispatchLock -Path $Variant.Path -Owner 'offline/link-rejection'
                }
                [pscustomobject]@{
                    DispatchLockLinkOutcome = $true
                    Threw = $false
                    Message = if ($Operation -ceq 'GetHolder') { [string]$value.Detail } else { '' }
                    Stream = if ($Operation -ceq 'Open') { $value } else { $null }
                }
            }
            catch {
                [pscustomobject]@{
                    DispatchLockLinkOutcome = $true
                    Threw = $true
                    Message = $_.Exception.Message
                    Stream = $null
                }
            }
        } 6>&1)
        $outcome = @($captured | Where-Object { $_.PSObject.Properties['DispatchLockLinkOutcome'] })[-1]
        $observable = (@(
            $captured | Where-Object { $_ -is [Management.Automation.InformationRecord] } |
                ForEach-Object { $_.ToString() }
        ) + @($outcome.Message)) -join "`n"

        $issues = @()
        try {
            if (-not $outcome.Threw) { $issues += "$Operation 未拒绝 $($Variant.Kind) 锁叶子" }
            if ($outcome.Message -cne 'unsafe_dispatch_lock_path') { $issues += "$Operation 未返回固定错误" }
            if ($observable -match [regex]::Escape($Secret)) { $issues += "$Operation 泄露了外部 Bearer sentinel" }
            if ($observable -match [regex]::Escape($ExternalTarget)) { $issues += "$Operation 泄露了外部目标路径" }
            if (-not (Test-Path -LiteralPath $Variant.Path -PathType Leaf)) {
                $issues += "$Operation 删除了链接锁叶子"
            }
            else {
                $leafAfter = Get-Item -LiteralPath $Variant.Path -Force -ErrorAction Stop
                if ([string]$leafAfter.LinkType -cne [string]$Variant.Kind) {
                    $issues += "$Operation 把链接锁叶子替换成了普通文件"
                }
            }
            $hashAfter = (Get-FileHash -LiteralPath $ExternalTarget -Algorithm SHA256).Hash
            if ($hashAfter -cne $hashBefore) { $issues += "$Operation 修改了外部目标内容"
            }
        }
        finally {
            if ($null -ne $outcome.Stream) { $outcome.Stream.Dispose() }
        }
        Assert-True ($issues.Count -eq 0) ($issues -join '；')
    }

    Test-Case 'GetHolder 在读取前拒绝链接锁叶子且不泄露外部 sentinel' {
        $secret = 'Bearer dispatch-lock-getholder-sentinel-must-not-leak'
        $externalTarget = Join-Path $lockProbeDir 'getholder-external-sentinel.txt'
        Set-Content -LiteralPath $externalTarget -Value $secret -Encoding utf8
        $variants = @(New-DispatchLockLinkVariants -Prefix 'getholder' -Target $externalTarget)
        try {
            foreach ($variant in $variants) {
                Assert-DispatchLockLinkRejected -Variant $variant -ExternalTarget $externalTarget `
                    -Secret $secret -Operation GetHolder
            }
        }
        finally {
            foreach ($variant in $variants) {
                Remove-Item -LiteralPath $variant.Path -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $externalTarget -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'Open 在清理或读取前拒绝链接锁叶子且不改外部 sentinel' {
        $secret = 'Bearer dispatch-lock-open-sentinel-must-not-leak'
        $externalTarget = Join-Path $lockProbeDir 'open-external-sentinel.txt'
        Set-Content -LiteralPath $externalTarget -Value $secret -Encoding utf8
        $variants = @(New-DispatchLockLinkVariants -Prefix 'open' -Target $externalTarget)
        try {
            foreach ($variant in $variants) {
                Assert-DispatchLockLinkRejected -Variant $variant -ExternalTarget $externalTarget `
                    -Secret $secret -Operation Open
            }
        }
        finally {
            foreach ($variant in $variants) {
                Remove-Item -LiteralPath $variant.Path -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $externalTarget -Force -ErrorAction SilentlyContinue
        }
    }

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

    Test-Case 'runner 设备 lease 存续时普通 dispatch 在任何 adb 预检前被拒绝' {
        $token = [guid]::NewGuid().ToString('N')
        $lease = Open-DispatchLock -Path $LockPath -Owner 'offline-runner/full-lifecycle' `
            -LeaseOwnerToken $token
        try {
            $result = Invoke-Dispatch @('-Task', '不得插入 runner 生命周期', '-Slug', 'offline-overlap')
            Assert-True ($result.ExitCode -ne 0) '普通 dispatch 不得插入 runner 的 provision/inter-leg/teardown。'
            Assert-Matches $result.Text '设备|lease|派单进行中|锁'
            Assert-NoExternalTools $result
        }
        finally {
            $lease.Close()
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '设备 lease owner 与真实继承句柄可共存且继续排斥普通 writer' {
        $path = Join-Path $lockProbeDir 'inherited.lock'
        $token = [guid]::NewGuid().ToString('N')
        $ownerLease = Open-DispatchLock -Path $path -Owner 'offline-runner/full-lifecycle' `
            -LeaseOwnerToken $token
        $childLease = $null
        try {
            $childLease = Open-DispatchLock -Path $path -Owner 'offline-child/leg1' `
                -LeaseOwnerToken $token -InheritLease
            Assert-True ($null -ne $childLease) '真实子 dispatch 句柄无法加入 owner lease。'
            $ordinaryRejected = $false
            try { Open-DispatchLock -Path $path -Owner 'ordinary-dispatch' | Out-Null }
            catch { $ordinaryRejected = $true }
            Assert-True $ordinaryRejected 'owner+child 共存时普通 writer 插入了设备 lease。'

            # 模拟 runner 崩溃：owner 句柄由 OS 回收、来不及删文件；仍活着的 child 必须独自
            # 维持设备排他，直到它也退出，不能给普通 dispatch 留插入窗口。
            $ownerLease.Dispose()
            $ownerLease = $null
            $ordinaryRejected = $false
            try { Open-DispatchLock -Path $path -Owner 'ordinary-after-owner-crash' | Out-Null }
            catch { $ordinaryRejected = $true }
            Assert-True $ordinaryRejected 'owner 先退出后，仍活着的 child 没有继续排斥普通 writer。'
        }
        finally {
            if ($null -ne $childLease) { Close-DispatchLock -Stream $childLease -Path $path }
            if ($null -ne $ownerLease) { Close-DispatchLock -Stream $ownerLease -Path $path }
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case 'TimeoutMin 越界必须在任何外部工具或子进程前 fail-fast' {
        foreach ($badTimeout in @(-1, 0, 61, 2147483647)) {
            $result = Invoke-Dispatch @(
                '-Task', 'timeout 参数离线负例', '-Slug', "offline-timeout-$badTimeout",
                '-TimeoutMin', "$badTimeout"
            )
            Assert-True ($result.ExitCode -ne 0) "TimeoutMin=$badTimeout 不得进入预检或派单。"
            Assert-Matches $result.Text 'TimeoutMin.*1.*60|1\.\.60'
            Assert-NoExternalTools $result
            Assert-NoRepoEffects $before
        }
    }

    Test-Case 'standalone dispatch 必须在 adb 前拒绝预存 traces root junction' {
        $backup = Join-Path $TestRoot 'standalone-traces-root-backup'
        $outsideRoot = Join-Path $SentinelDir 'standalone-traces-root-target'
        $sentinel = Join-Path $outsideRoot 'outside-sentinel.txt'
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        try {
            Move-Item -LiteralPath $TracesDir -Destination $backup
            New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
            Set-Content -LiteralPath $sentinel -Encoding utf8 `
                -Value 'Authorization: Bearer standalone-trace-root-fixture-secret'
            $expectedHash = (Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash
            $beforeNames = @(Get-ChildItem -LiteralPath $outsideRoot -Force | Sort-Object Name |
                ForEach-Object Name)
            New-Item -ItemType Junction -Path $TracesDir -Target $outsideRoot -ErrorAction Stop | Out-Null
            $rootItem = Get-Item -LiteralPath $TracesDir -Force
            Assert-True (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
                'fixture 未实际建立 traces root junction。'

            $result = Invoke-Dispatch @('-Task','standalone first-use root','-Slug','offline-root-link')
            Assert-True ($result.ExitCode -ne 0) '预存 traces junction 必须 fail closed。'
            Assert-Contains $result.Text 'unsafe_artifact_path'
            Assert-NotMatches $result.Text '(?i)Bearer\s+standalone-trace-root-fixture-secret'
            Assert-NoExternalTools $result
            Assert-True ((Get-FileHash -LiteralPath $sentinel -Algorithm SHA256).Hash -ceq $expectedHash) `
                'dispatch 改写了 junction 根外 sentinel。'
            $afterNames = @(Get-ChildItem -LiteralPath $outsideRoot -Force | Sort-Object Name |
                ForEach-Object Name)
            Assert-True (($afterNames -join "`n") -ceq ($beforeNames -join "`n")) `
                "dispatch 在根外 traces 目标新建了文件：$($afterNames -join ',')"
        }
        finally {
            if (Test-Path -LiteralPath $TracesDir) { Remove-Item -LiteralPath $TracesDir -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $backup -PathType Container) {
                Move-Item -LiteralPath $backup -Destination $TracesDir
            }
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) { [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length) }
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            foreach ($tool in $ExternalTools) {
                Remove-Item -LiteralPath (Join-Path $SentinelDir "$tool-called.txt") -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Test-Case 'standalone dispatch 必须在 adb 前拒绝预存 ledger hardlink' {
        $traceBackup = Join-Path $TestRoot 'standalone-ledger-traces-backup'
        $ledgerBackup = Join-Path $TestRoot 'standalone-ledger-backup.csv'
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        try {
            Move-Item -LiteralPath $TracesDir -Destination $traceBackup
            New-Item -ItemType Directory -Path $TracesDir -Force | Out-Null
            if ($ledgerExisted) { Move-Item -LiteralPath $LedgerPath -Destination $ledgerBackup }
            $outsideLedger = Join-Path $SentinelDir 'standalone-ledger-target.csv'
            @(
                'time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note',
                '2026-08-09T00:00:00,"outside-sentinel",1,claude,sonnet,0,0,0,0,0,0,0,fail,,,"Authorization: Bearer standalone-ledger-fixture-secret"'
            ) | Set-Content -LiteralPath $outsideLedger -Encoding utf8
            $expectedHash = (Get-FileHash -LiteralPath $outsideLedger -Algorithm SHA256).Hash
            New-Item -ItemType HardLink -Path $LedgerPath -Target $outsideLedger -ErrorAction Stop | Out-Null
            Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-Item -LiteralPath $LedgerPath -Force).LinkType)) `
                'fixture 未实际建立 ledger hardlink。'

            $result = Invoke-Dispatch @('-Task','standalone first-use ledger','-Slug','offline-ledger-link')
            Assert-True ($result.ExitCode -ne 0) '预存 ledger hardlink 必须 fail closed。'
            Assert-Contains $result.Text 'unsafe_artifact_path'
            Assert-NotMatches $result.Text '(?i)Bearer\s+standalone-ledger-fixture-secret'
            Assert-NoExternalTools $result
            Assert-True ((Get-FileHash -LiteralPath $outsideLedger -Algorithm SHA256).Hash -ceq $expectedHash) `
                'dispatch 在安全验证前跟随 ledger hardlink 追加了根外 sentinel。'
        }
        finally {
            Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue
            if ($ledgerExisted -and (Test-Path -LiteralPath $ledgerBackup -PathType Leaf)) {
                Move-Item -LiteralPath $ledgerBackup -Destination $LedgerPath
            }
            Remove-Item -LiteralPath $TracesDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $traceBackup -PathType Container) {
                Move-Item -LiteralPath $traceBackup -Destination $TracesDir
            }
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            foreach ($tool in $ExternalTools) {
                Remove-Item -LiteralPath (Join-Path $SentinelDir "$tool-called.txt") -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Test-Case 'standalone dispatch 动态 prompt/trace/err/pause 叶子 link 均须在 adb 前拒绝' {
        $originalDispatch = Get-Content -LiteralPath $DispatchPath -Raw -Encoding utf8
        $fixedStamp = '20260809-010203'
        $oldFixedStamp = $env:DISPATCH_TEST_FIXED_STAMP
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        try {
            $stampNeedle = '$stamp = Get-Date -Format ''yyyyMMdd-HHmmss'''
            Assert-True $originalDispatch.Contains($stampNeedle, [StringComparison]::Ordinal) `
                '测试设施错误：无法定位 dispatch stamp seam。'
            $fixedSource = $originalDispatch.Replace(
                $stampNeedle,
                '$stamp = if ($env:DISPATCH_TEST_FIXED_STAMP) { $env:DISPATCH_TEST_FIXED_STAMP } else { Get-Date -Format ''yyyyMMdd-HHmmss'' }'
            )
            Set-Content -LiteralPath $DispatchPath -Value $fixedSource -Encoding utf8
            $env:DISPATCH_TEST_FIXED_STAMP = $fixedStamp

            $suffixes = @('.prompt.md','.jsonl','.err.txt','.pause.md')
            for ($index = 0; $index -lt $suffixes.Count; $index++) {
                $suffix = $suffixes[$index]
                $slug = "offline-dynamic-leaf-$index"
                $prefix = "$fixedStamp-$slug-mobile-claude-leg1"
                $outside = Join-Path $SentinelDir "dynamic-leaf-$index-target.txt"
                Set-Content -LiteralPath $outside -Encoding utf8 `
                    -Value "Authorization: Bearer dynamic-leaf-$index-fixture-secret"
                $expectedHash = (Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash
                $link = Join-Path $TracesDir "$prefix$suffix"
                try {
                    New-Item -ItemType HardLink -Path $link -Target $outside -ErrorAction Stop | Out-Null
                    Assert-True (-not [string]::IsNullOrWhiteSpace([string](Get-Item -LiteralPath $link -Force).LinkType)) `
                        "fixture 未实际建立 $suffix hardlink。"
                    $result = Invoke-Dispatch @('-Task','dynamic leaf first-use','-Slug',$slug)
                    Assert-True ($result.ExitCode -ne 0) "$suffix 预存 link 必须 fail closed。"
                    Assert-Contains $result.Text 'unsafe_artifact_path'
                    Assert-NotMatches $result.Text "(?i)Bearer\s+dynamic-leaf-$index-fixture-secret"
                    Assert-NoExternalTools $result
                    Assert-True ((Get-FileHash -LiteralPath $outside -Algorithm SHA256).Hash -ceq $expectedHash) `
                        "dispatch 跟随 $suffix hardlink 改写了根外 sentinel。"
                }
                finally {
                    Get-ChildItem -LiteralPath $TracesDir -Filter "$prefix*" -File -Force -ErrorAction SilentlyContinue |
                        Remove-Item -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
                    foreach ($tool in $ExternalTools) {
                        Remove-Item -LiteralPath (Join-Path $SentinelDir "$tool-called.txt") -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        finally {
            $env:DISPATCH_TEST_FIXED_STAMP = $oldFixedStamp
            Set-Content -LiteralPath $DispatchPath -Value $originalDispatch -Encoding utf8
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) { [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length) }
        }
    }

    Test-Case 'dispatch 启动后异常路径必须在 finally 回收 Job 后再释放 lease' {
        $source = Get-Content -LiteralPath $SourceDispatchPath -Raw -Encoding utf8
        $outerFinallyIndex = $source.LastIndexOf("`nfinally {", [StringComparison]::Ordinal)
        Assert-True ($outerFinallyIndex -ge 0) 'dispatch 缺少外层 finally。'
        $outerFinally = $source.Substring($outerFinallyIndex)
        $jobStopIndex = $outerFinally.IndexOf('Stop-DispatchJobProcesses', [StringComparison]::Ordinal)
        $leaseCloseIndex = $outerFinally.IndexOf('Close-DispatchLock', [StringComparison]::Ordinal)
        Assert-True ($jobStopIndex -ge 0 -and $leaseCloseIndex -gt $jobStopIndex) `
            'dispatch 外层 finally 必须先机械清空 Job，再释放设备 lease。'
    }

    Test-Case '根进程先退出后异常仍须在释放 lease 前终止长寿孙进程' {
        $grandchildScript = Join-Path $SentinelDir 'dispatch-grandchild.ps1'
        $grandchildPidPath = Join-Path $SentinelDir 'dispatch-grandchild.pid'
        $leaseViolationPath = Join-Path $SentinelDir 'lease-released-while-grandchild-alive.txt'
        $fakeClaudeSource = Join-Path $SentinelDir 'dispatch-fake-claude.cs'
        $fakeClaudeExe = Join-Path $FakeBin 'claude.exe'
        $originalDispatch = Get-Content -LiteralPath $DispatchPath -Raw -Encoding utf8
        $oldFault = $env:DISPATCH_TEST_POST_START_FAILURE
        $oldFixturePowerShell = $env:DISPATCH_TEST_FIXTURE_POWERSHELL
        $grandchildPid = $null
        try {
            @'
$PID | Set-Content -LiteralPath (Join-Path $env:DISPATCH_TEST_SENTINEL_DIR 'dispatch-grandchild.pid') -NoNewline -Encoding ascii
while ($true) {
    if (-not (Test-Path -LiteralPath $env:DISPATCH_TEST_LOCK_PATH -PathType Leaf)) {
        Set-Content -LiteralPath (Join-Path $env:DISPATCH_TEST_SENTINEL_DIR 'lease-released-while-grandchild-alive.txt') `
            -Value '1' -NoNewline -Encoding ascii
    }
    Start-Sleep -Milliseconds 25
}
'@ | Set-Content -LiteralPath $grandchildScript -Encoding utf8

            @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class Program {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(
        string applicationName, string commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, bool inheritHandles, int creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    public static int Main() {
        string sentinel = Environment.GetEnvironmentVariable("DISPATCH_TEST_SENTINEL_DIR");
        string executable = Environment.GetEnvironmentVariable("DISPATCH_TEST_FIXTURE_POWERSHELL");
        string script = Path.Combine(sentinel, "dispatch-grandchild.ps1");
        string pidPath = Path.Combine(sentinel, "dispatch-grandchild.pid");
        string commandLine = "\"" + executable + "\" -NoProfile -File \"" + script + "\"";
        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = Marshal.SizeOf<STARTUPINFO>();
        PROCESS_INFORMATION process;
        const int CREATE_NO_WINDOW = 0x08000000;
        const int CREATE_SUSPENDED = 0x00000004;
        if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero,
            false, CREATE_NO_WINDOW | CREATE_SUSPENDED, IntPtr.Zero, null, ref startup, out process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        try {
            File.WriteAllText(pidPath, process.dwProcessId.ToString(), Encoding.ASCII);
            if (ResumeThread(process.hThread) == 0xffffffff) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        } catch {
            TerminateProcess(process.hProcess, 1);
            throw;
        } finally {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        return 0;
    }
}
'@ | Set-Content -LiteralPath $fakeClaudeSource -Encoding utf8
            $cscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            Assert-True (Test-Path -LiteralPath $cscPath -PathType Leaf) '测试设施错误：缺少系统 C# 编译器。'
            $compilerOutput = & $cscPath /nologo /target:exe "/out:$fakeClaudeExe" $fakeClaudeSource 2>&1
            Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeClaudeExe -PathType Leaf)) `
                "测试设施错误：无法编译 fake claude.exe：$compilerOutput"
            $env:DISPATCH_TEST_FIXTURE_POWERSHELL = $FixturePowerShellPath

            # 故障必须落在 root WaitForExit 已返回、首次 normal Job drain 尚未发生的窄窗：
            # fake root 已派生长寿孙进程并退出，此时唯一能收口的是 outer finally。
            $faultNeedle = '    $finished = $proc.WaitForExit($TimeoutMin * 60 * 1000)'
            Assert-True $originalDispatch.Contains($faultNeedle, [StringComparison]::Ordinal) `
                '测试设施错误：无法定位 dispatch post-start 故障注入点。'
            $faultedDispatch = $originalDispatch.Replace(
                $faultNeedle,
                "$faultNeedle`r`n    if (`$env:DISPATCH_TEST_POST_START_FAILURE -ceq '1') { throw 'fixture_post_start_failure' }"
            )
            if ($env:DISPATCH_TEST_MUTATE_OUTER_JOB_CLEANUP -ceq '1') {
                # 隔离 RED 控制：只改 TEMP fixture，故意在 outer-finally drain Job 前释放 lease，
                # 留 500ms 让仍活的孙进程机械记录顺序违规。正常回归永不启用此开关。
                $cleanupNeedle = '    $treeCleanupFailure = $null'
                Assert-True $faultedDispatch.Contains($cleanupNeedle, [StringComparison]::Ordinal) `
                    '测试设施错误：无法定位 outer-finally cleanup seam。'
                $faultedDispatch = $faultedDispatch.Replace(
                    $cleanupNeedle,
                    "    if (`$lockFs) { Close-DispatchLock -Stream `$lockFs -Path `$LockFile; `$lockFs = `$null; Start-Sleep -Milliseconds 500 }`r`n$cleanupNeedle"
                )
            }
            Set-Content -LiteralPath $DispatchPath -Value $faultedDispatch -Encoding utf8
            $env:DISPATCH_TEST_POST_START_FAILURE = '1'

            $result = Invoke-Dispatch @('-Task','孙进程生命周期离线负例','-Slug','offline-grandchild-lifetime')
            Assert-True ($result.ExitCode -ne 0) 'post-start 故障必须令 dispatch 非零退出。'
            Assert-Contains $result.Text 'fixture_post_start_failure'

            $pidDeadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf) -and
                [DateTime]::UtcNow -lt $pidDeadline) { Start-Sleep -Milliseconds 25 }
            Assert-True (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf) `
                "fake claude.exe 没有实际 CreateProcess 长寿孙进程。dispatch output=$($result.Text)"
            $grandchildPid = [int](Get-Content -LiteralPath $grandchildPidPath -Raw)
            Assert-True ($grandchildPid -gt 0) 'fake claude.exe 落下了无效孙进程 PID。'
            $exitDeadline = [DateTime]::UtcNow.AddSeconds(3)
            $grandchildProcess = Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue
            while ($null -ne $grandchildProcess -and [DateTime]::UtcNow -lt $exitDeadline) {
                try { if ($grandchildProcess.HasExited) { break } } catch { break }
                Start-Sleep -Milliseconds 25
                $grandchildProcess = Get-Process -Id $grandchildPid -ErrorAction SilentlyContinue
            }
            $grandchildStillAlive = $false
            if ($null -ne $grandchildProcess) {
                try { $grandchildStillAlive = -not $grandchildProcess.HasExited }
                catch { $grandchildStillAlive = $false }
            }
            $grandchildCim = Get-CimInstance Win32_Process -Filter "ProcessId=$grandchildPid" -ErrorAction SilentlyContinue
            $grandchildCimText = if ($null -eq $grandchildCim) { '<absent>' } else {
                "name=$($grandchildCim.Name);ppid=$($grandchildCim.ParentProcessId);cmd=$($grandchildCim.CommandLine)"
            }
            Assert-True (-not (Test-Path -LiteralPath $leaseViolationPath -PathType Leaf)) `
                "dispatch 在孙进程仍活着时提前释放了设备 lease（孙进程仍活=$grandchildStillAlive）。"
            Assert-True (-not $grandchildStillAlive) `
                "dispatch 根进程已退出，但长寿孙进程仍存活（$grandchildCimText）。"
            Assert-True (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) `
                '确认孙进程退出后 dispatch 仍未释放 lease。'
        }
        finally {
            $env:DISPATCH_TEST_POST_START_FAILURE = $oldFault
            $env:DISPATCH_TEST_FIXTURE_POWERSHELL = $oldFixturePowerShell
            Set-Content -LiteralPath $DispatchPath -Value $originalDispatch -Encoding utf8
            if ($null -eq $grandchildPid -and (Test-Path -LiteralPath $grandchildPidPath -PathType Leaf)) {
                $grandchildPid = [int](Get-Content -LiteralPath $grandchildPidPath -Raw)
            }
            if ($null -ne $grandchildPid) {
                Stop-Process -Id $grandchildPid -Force -ErrorAction SilentlyContinue
                try { Wait-Process -Id $grandchildPid -Timeout 5 -ErrorAction SilentlyContinue } catch {}
            }
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*-offline-grandchild-lifetime-mobile-claude-leg1.*' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ($before.Ledger -ceq '<missing>' -and (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
                Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $fakeClaudeExe -Force -ErrorAction SilentlyContinue
            foreach ($name in @(
                'adb-called.txt','claude-called.txt','dispatch-grandchild.pid',
                'dispatch-grandchild.ps1','dispatch-fake-claude.cs',
                'lease-released-while-grandchild-alive.txt'
            )) {
                Remove-Item -LiteralPath (Join-Path $SentinelDir $name) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Test-Case '硬杀仅 dispatch 根时 Job close 必须终止 wrapper 与全部后代再允许取 lease' {
        $claudeCmd = Join-Path $FakeBin 'claude.cmd'
        $originalClaudeCmd = Get-Content -LiteralPath $claudeCmd -Raw -Encoding utf8
        $childScript = Join-Path $SentinelDir 'dispatch-rootkill-child.ps1'
        $childPidPath = Join-Path $SentinelDir 'dispatch-rootkill-child.pid'
        $leaseViolationPath = Join-Path $SentinelDir 'dispatch-rootkill-lease-violation.txt'
        $dispatchProcess = $null
        $childPid = $null
        $fakeRootPid = $null
        $wrapperPid = $null
        try {
            @'
Set-Content -LiteralPath (Join-Path $env:DISPATCH_TEST_SENTINEL_DIR 'dispatch-rootkill-child.pid') `
    -Value $PID -NoNewline -Encoding ascii
while ($true) {
    $probe = $null
    try {
        $lockPath = $env:DISPATCH_TEST_LOCK_PATH
        if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            $probe = [IO.File]::Open($lockPath, 'Open', 'ReadWrite', 'None')
        }
        else {
            $probe = [IO.File]::Open($lockPath, 'CreateNew', 'ReadWrite', 'None')
        }
        Set-Content -LiteralPath (Join-Path $env:DISPATCH_TEST_SENTINEL_DIR `
            'dispatch-rootkill-lease-violation.txt') -Value '1' -NoNewline -Encoding ascii
    }
    catch { }
    finally { if ($null -ne $probe) { $probe.Dispose() } }
    Start-Sleep -Milliseconds 10
}
'@ | Set-Content -LiteralPath $childScript -Encoding utf8

            @'
@echo off
start "" /b "%DISPATCH_TEST_FIXTURE_POWERSHELL%" -NoProfile -File "%DISPATCH_TEST_SENTINEL_DIR%\dispatch-rootkill-child.ps1"
:hold
ping -n 2 127.0.0.1 >nul
goto hold
'@ | Set-Content -LiteralPath $claudeCmd -Encoding ascii

            foreach ($path in @($childPidPath,$leaseViolationPath,$LockPath)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $PwshPath
            $start.WorkingDirectory = $RepoRoot
            $start.UseShellExecute = $false
            $start.RedirectStandardInput = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.CreateNoWindow = $true
            foreach ($arg in @(
                '-NoProfile','-File',$DispatchPath,'-Task','root hard-kill lifetime fixture',
                '-Slug','offline-root-hardkill','-TimeoutMin','5'
            )) { $start.ArgumentList.Add($arg) }
            $start.Environment['PATH'] = $FakeBin + [IO.Path]::PathSeparator + $start.Environment['PATH']
            $start.Environment['DISPATCH_TEST_SENTINEL_DIR'] = $SentinelDir
            $start.Environment['DISPATCH_TEST_LOCK_PATH'] = $LockPath
            $start.Environment['DISPATCH_TEST_FIXTURE_POWERSHELL'] = $FixturePowerShellPath
            $dispatchProcess = [Diagnostics.Process]::new()
            $dispatchProcess.StartInfo = $start
            Assert-True ($dispatchProcess.Start()) '测试设施错误：无法启动 root-hardkill dispatch。'
            $dispatchProcess.StandardInput.Close()

            $pidDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while (-not (Test-Path -LiteralPath $childPidPath -PathType Leaf) -and
                [DateTime]::UtcNow -lt $pidDeadline) { Start-Sleep -Milliseconds 20 }
            Assert-True (Test-Path -LiteralPath $childPidPath -PathType Leaf) `
                'root-hardkill fixture 未实际启动长寿 child。'
            $childPid = [int](Get-Content -LiteralPath $childPidPath -Raw)
            $childCim = Get-CimInstance Win32_Process -Filter "ProcessId=$childPid" -ErrorAction SilentlyContinue
            Assert-True ($null -ne $childCim) '无法读取长寿 child 进程关系。'
            $fakeRootPid = [int]$childCim.ParentProcessId
            $fakeRootCim = Get-CimInstance Win32_Process -Filter "ProcessId=$fakeRootPid" -ErrorAction SilentlyContinue
            Assert-True ($null -ne $fakeRootCim) '无法读取 fake Claude 根进程。'
            $wrapperPid = [int]$fakeRootCim.ParentProcessId
            $wrapperCim = Get-CimInstance Win32_Process -Filter "ProcessId=$wrapperPid" -ErrorAction SilentlyContinue
            Assert-True ($null -ne $wrapperCim -and $wrapperCim.ParentProcessId -eq $dispatchProcess.Id) `
                'fixture 没有形成 dispatch → wrapper → fake Claude → child 的真实进程链。'
            Assert-True (Test-Path -LiteralPath $LockPath -PathType Leaf) `
                'dispatch 根尚未硬杀时没有持有设备 lease。'

            # 只杀根；绝不能用 Kill(true)，否则测试会替生产 Job 兜底把后代清掉。
            $dispatchProcess.Kill()
            Assert-True ($dispatchProcess.WaitForExit(5000)) 'dispatch 根硬杀后 5s 未退出。'

            $exitDeadline = [DateTime]::UtcNow.AddSeconds(5)
            do {
                $alive = @($wrapperPid,$fakeRootPid,$childPid | Where-Object {
                    $candidate = Get-Process -Id $_ -ErrorAction SilentlyContinue
                    if ($null -eq $candidate) { return $false }
                    try { return -not $candidate.HasExited } catch { return $false }
                })
                if ($alive.Count -eq 0) { break }
                Start-Sleep -Milliseconds 20
            } while ([DateTime]::UtcNow -lt $exitDeadline)

            Assert-True (-not (Test-Path -LiteralPath $leaseViolationPath -PathType Leaf)) `
                'dispatch 根退出后仍活的 Job 后代取得了设备 lease。'
            Assert-True ($alive.Count -eq 0) `
                "dispatch 根硬杀后 Job 后代仍存活：$($alive -join ',')"

            . (Join-Path $RepoRoot 'scripts\lib\dispatch-lock.ps1')
            $releasedLease = Open-DispatchLock -Path $LockPath -Owner 'root-hardkill-after-drain'
            Close-DispatchLock -Stream $releasedLease -Path $LockPath
        }
        finally {
            foreach ($processId in @($childPid,$fakeRootPid,$wrapperPid)) {
                if ($null -ne $processId) {
                    Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
                    try { Wait-Process -Id $processId -Timeout 5 -ErrorAction SilentlyContinue } catch {}
                }
            }
            if ($null -ne $dispatchProcess) {
                try {
                    if (-not $dispatchProcess.HasExited) {
                        $dispatchProcess.Kill($true)
                        [void]$dispatchProcess.WaitForExit(5000)
                    }
                }
                finally { $dispatchProcess.Dispose() }
            }
            Set-Content -LiteralPath $claudeCmd -Value $originalClaudeCmd -Encoding utf8
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            foreach ($path in @($childScript,$childPidPath,$leaseViolationPath)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            # 本用例故意走真实（fake）adb/claude 生命周期；通用 called sentinel 属于夹具输出，
            # 必须在交还给后续 DryRun 全局不变量前清掉，不能把行为用例误报成 DryRun 副作用。
            foreach ($tool in $ExternalTools) {
                Remove-Item -LiteralPath (Join-Path $SentinelDir "$tool-called.txt") `
                    -Force -ErrorAction SilentlyContinue
            }
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '*-offline-root-hardkill-mobile-claude-leg1.*' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    Test-Case '全部 DryRun 汇总后仍无仓库副作用' {
        Assert-NoRepoEffects $before
        foreach ($tool in $ExternalTools) {
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $SentinelDir "$tool-called.txt"))) `
                "最后一次 DryRun 仍触发了 fake $tool。"
        }
    }

    # 放在 DryRun 不变量之后：旧实现会错误消费暂停件并进入 adb 预检；这条 RED 不应污染
    # 前面的无副作用断言，TEMP fixture 会在套件 finally 中统一回收。
    Test-Case '重定向 stdin 即使含 CONFIRM 也必须在消费暂停件或启动子进程前拒绝' {
        $beforePause = Get-Content -LiteralPath $redirectedPause -Raw -Encoding utf8
        $result = Invoke-Dispatch -Arguments @('-Confirm', $redirectedPause) -StandardInput "CONFIRM`n"
        Assert-True ($result.ExitCode -ne 0) '重定向 stdin 不得构成人工身份。'
        Assert-Matches $result.Text '(?i)stdin|重定向|交互终端|人工确认'
        Assert-True ((Get-Content -LiteralPath $redirectedPause -Raw -Encoding utf8) -ceq $beforePause) `
            '非交互输入被错误消费，暂停件已被作废。'
        Assert-NoExternalTools $result
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
