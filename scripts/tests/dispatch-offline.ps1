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
$LockPath = Join-Path $TestRoot 'localappdata\agent-for-mobile\locks\device-v1.lock'
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
    $start.Environment['LOCALAPPDATA'] = Join-Path $TestRoot 'localappdata'

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

function Invoke-TranscriptFixture {
    param(
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$Brain,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines,
        [switch]$AllowPartial
    )
    $trace = Join-Path $SentinelDir ("transcript-$([guid]::NewGuid().ToString('N')).jsonl")
    try {
        $Lines | Set-Content -LiteralPath $trace -Encoding utf8
        if ($AllowPartial) {
            return Read-DispatchTraceTranscript -TracePath $trace -Brain $Brain -AllowPartial
        }
        return Read-DispatchTraceTranscript -TracePath $trace -Brain $Brain
    }
    finally { Remove-Item -LiteralPath $trace -Force -ErrorAction SilentlyContinue }
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
    $fakeClaude = @'
@echo off
>>"%DISPATCH_TEST_SENTINEL_DIR%\claude-called.txt" echo %*
>"%DISPATCH_TEST_SENTINEL_DIR%\claude-lock-env.txt" echo [%AGENT_MOBILE_DEVICE_LOCK_LEASE%]
echo {"type":"result","subtype":"success","result":"\u7ed3\u679c\uff1a\u6210\u529f","usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0},"num_turns":1,"total_cost_usd":0}
exit /b 0
'@
    Set-Content -LiteralPath (Join-Path $FakeBin 'claude.cmd') -Value $fakeClaude -Encoding ascii

    # 真正启动一个完全离线的 fake codex.exe，锁住 argv/stdin/env/JSONL/exit-code 契约；
    # 生产 resolver 没有测试后门，只有 TEMP fixture 的调用点被显式注入 executable+version override。
    $fakeCodexSource = Join-Path $SentinelDir 'fake-codex.cs'
    $fakeCodexExe = Join-Path $FakeBin 'codex.exe'
    @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class Program {
    public static int Main(string[] args) {
        string sentinel = Environment.GetEnvironmentVariable("DISPATCH_TEST_SENTINEL_DIR");
        if (String.IsNullOrEmpty(sentinel)) return 91;
        if (Array.IndexOf(args, "--dispatch-flood-descendant") >= 0) {
            string descendantScenario = Environment.GetEnvironmentVariable("DISPATCH_TEST_CODEX_SCENARIO") ?? "unknown";
            File.WriteAllText(Path.Combine(sentinel, descendantScenario + "-descendant-started.txt"),
                Process.GetCurrentProcess().Id.ToString(), Encoding.ASCII);
            Thread.Sleep(2500);
            File.WriteAllText(Path.Combine(sentinel, descendantScenario + "-descendant-survived.txt"),
                "survived", Encoding.ASCII);
            Thread.Sleep(10000);
            return 0;
        }
        File.WriteAllLines(Path.Combine(sentinel, "codex-argv.txt"), args, Encoding.UTF8);
        File.WriteAllText(Path.Combine(sentinel, "codex-prompt.txt"), Console.In.ReadToEnd(), Encoding.UTF8);
        File.WriteAllText(Path.Combine(sentinel, "codex-cwd.txt"), Directory.GetCurrentDirectory(), Encoding.UTF8);
        File.WriteAllText(Path.Combine(sentinel, "codex-cwd-empty.txt"),
            (Directory.GetFileSystemEntries(Directory.GetCurrentDirectory()).Length == 0).ToString().ToLowerInvariant(), Encoding.ASCII);
        List<string> secretNames = new List<string>();
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
            string name = (string)entry.Key;
            if (name.StartsWith("AGENT_MOBILE_MCP_", StringComparison.Ordinal)) secretNames.Add(name);
        }
        bool secretOk = secretNames.Count == 1 &&
            Environment.GetEnvironmentVariable(secretNames[0]) == "fixture-bearer-value-must-never-leak";
        File.WriteAllText(Path.Combine(sentinel, "codex-secret-ok.txt"), secretOk.ToString().ToLowerInvariant(), Encoding.ASCII);
        bool environmentOk = Environment.GetEnvironmentVariable("OPENAI_API_KEY") == null &&
            Environment.GetEnvironmentVariable("CODEX_ACCESS_TOKEN") == null &&
            Environment.GetEnvironmentVariable("ARBITRARY_PARENT_SECRET") == null &&
            Environment.GetEnvironmentVariable("AGENT_MOBILE_DEVICE_LOCK_LEASE") == null &&
            Environment.GetEnvironmentVariable("RUST_LOG") == "error" &&
            Environment.GetEnvironmentVariable("NO_PROXY") == "127.0.0.1,localhost";
        File.WriteAllText(Path.Combine(sentinel, "codex-environment-ok.txt"), environmentOk.ToString().ToLowerInvariant(), Encoding.ASCII);

        Console.OutputEncoding = new UTF8Encoding(false);
        string scenario = Environment.GetEnvironmentVariable("DISPATCH_TEST_CODEX_SCENARIO") ?? "success";
        if (scenario == "stdout-flood" || scenario == "stderr-flood") {
            ProcessStartInfo descendantInfo = new ProcessStartInfo(
                typeof(Program).Assembly.Location, "--dispatch-flood-descendant");
            descendantInfo.UseShellExecute = false;
            descendantInfo.CreateNoWindow = true;
            Process descendant = Process.Start(descendantInfo);
            string startedPath = Path.Combine(sentinel, scenario + "-descendant-started.txt");
            Stopwatch ready = Stopwatch.StartNew();
            while (!File.Exists(startedPath) && ready.ElapsedMilliseconds < 3000) Thread.Sleep(10);
            if (!File.Exists(startedPath)) return 92;

            Stream flood = scenario == "stdout-flood"
                ? Console.OpenStandardOutput()
                : Console.OpenStandardError();
            byte[] block = new byte[64 * 1024];
            for (int index = 0; index < block.Length; index++) block[index] = (byte)'X';
            while (true) flood.Write(block, 0, block.Length);
        }
        if (scenario == "malformed") { Console.WriteLine("{not-json"); return 0; }
        Console.WriteLine("{\"type\":\"thread.started\",\"thread_id\":\"offline-codex-thread\"}");
        Console.WriteLine("{\"type\":\"turn.started\"}");
        string server = scenario == "wrong-server" ? "evil" : "gateway";
        Console.WriteLine("{\"type\":\"item.started\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"" + server + "\",\"tool\":\"foreground_app\",\"arguments\":{}}}");
        if (scenario == "exit-partial") return 23;
        string ok = scenario == "gateway-ok-false" ? "false" : "true";
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"call-1\",\"type\":\"mcp_tool_call\",\"server\":\"" + server + "\",\"tool\":\"foreground_app\",\"arguments\":{},\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"ok\\\":" + ok + "}\"}]},\"error\":null,\"status\":\"completed\"}}");
        Console.WriteLine("{\"type\":\"item.completed\",\"item\":{\"id\":\"message-1\",\"type\":\"agent_message\",\"text\":\"结果：成功\"}}");
        if (scenario == "missing-usage") Console.WriteLine("{\"type\":\"turn.completed\"}");
        else Console.WriteLine("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":11,\"cached_input_tokens\":2,\"output_tokens\":7,\"cache_write_input_tokens\":3}}");
        return 0;
    }
}
'@ | Set-Content -LiteralPath $fakeCodexSource -Encoding utf8
    $cscPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    $compilerOutput = & $cscPath /nologo /target:exe "/out:$fakeCodexExe" $fakeCodexSource 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeCodexExe -PathType Leaf)) `
        "测试设施错误：无法编译 fake codex.exe：$compilerOutput"

    # 版本探针的根进程打印版本后立刻退出，但会留下一个 30 秒 sleeper。只有根进程从出生
    # 就在 KILL_ON_JOB_CLOSE Job 内，且成功路径也等待 Job 归零，函数返回时 sleeper 才必然消失。
    $fakeVersionChildSource = Join-Path $SentinelDir 'fake-version-child.cs'
    $fakeVersionChildExe = Join-Path $FakeBin 'fake-version-child.exe'
    $fakeVersionChildPid = Join-Path $SentinelDir 'fake-version-child.pid'
    $childPidLiteral = $fakeVersionChildPid.Replace('\', '\\').Replace('"', '\"')
    @"
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class Program {
    public static int Main() {
        File.WriteAllText("$childPidLiteral", Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(30000);
        return 0;
    }
}
"@ | Set-Content -LiteralPath $fakeVersionChildSource -Encoding utf8
    $compilerOutput = & $cscPath /nologo /target:exe "/out:$fakeVersionChildExe" $fakeVersionChildSource 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $fakeVersionChildExe -PathType Leaf)) `
        "测试设施错误：无法编译 fake version child：$compilerOutput"

    $fakeVersionProbeSource = Join-Path $SentinelDir 'fake-version-probe.cs'
    $fakeVersionProbeExe = Join-Path $FakeBin 'fake-version-probe.exe'
    $fakeVersionStdoutFloodExe = Join-Path $FakeBin 'fake-version-stdout-flood.exe'
    $fakeVersionStderrFloodExe = Join-Path $FakeBin 'fake-version-stderr-flood.exe'
    $childExeLiteral = $fakeVersionChildExe.Replace('\', '\\').Replace('"', '\"')
    @"
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

public static class Program {
    public static int Main(string[] args) {
        if (args.Length != 1 || args[0] != "--version") return 94;
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = "$childExeLiteral";
        start.UseShellExecute = false;
        Process child = Process.Start(start);
        DateTime deadline = DateTime.UtcNow.AddSeconds(2);
        while (!File.Exists("$childPidLiteral") && DateTime.UtcNow < deadline) Thread.Sleep(10);
        if (!File.Exists("$childPidLiteral")) return 95;
        string executableName = Path.GetFileNameWithoutExtension(
            Process.GetCurrentProcess().MainModule.FileName);
        if (executableName.EndsWith("-flood", StringComparison.Ordinal)) {
            Stream flood = executableName.Contains("stdout")
                ? Console.OpenStandardOutput()
                : Console.OpenStandardError();
            byte[] block = new byte[64 * 1024];
            for (int index = 0; index < block.Length; index++) block[index] = (byte)'V';
            while (true) flood.Write(block, 0, block.Length);
        }
        byte[] version = new System.Text.UTF8Encoding(false).GetBytes("codex-cli 0.149.0\r\n");
        using (Stream stdout = Console.OpenStandardOutput()) {
            stdout.Write(version, 0, version.Length);
            stdout.Flush();
        }
        return 0;
    }
}
"@ | Set-Content -LiteralPath $fakeVersionProbeSource -Encoding utf8
    foreach ($versionProbeTarget in @(
        $fakeVersionProbeExe, $fakeVersionStdoutFloodExe, $fakeVersionStderrFloodExe
    )) {
        $compilerOutput = & $cscPath /nologo /target:exe "/out:$versionProbeTarget" `
            $fakeVersionProbeSource 2>&1
        Assert-True ($LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $versionProbeTarget -PathType Leaf)) `
            "测试设施错误：无法编译 fake version probe：$compilerOutput"
    }

    $fixtureDispatchSource = Get-Content -LiteralPath $DispatchPath -Raw -Encoding utf8
    $codexSpecNeedle = '-WorkspacePath $codexWorkspace -Model $Model -ModelWasExplicit $ModelWasExplicit -Leg $Leg'
    Assert-True $fixtureDispatchSource.Contains($codexSpecNeedle, [StringComparison]::Ordinal) `
        '测试设施错误：无法定位 Codex launch spec seam。'
    $fixtureDispatchSource = $fixtureDispatchSource.Replace(
        $codexSpecNeedle,
        "$codexSpecNeedle -CodexExecutableOverride '$($fakeCodexExe -replace "'","''")' " +
            "-CodexVersionOverride 'codex-cli 0.149.0'"
    )
    # 仅 TEMP fixture 暴露一个可执行文件路径 seam，用于证明 .cmd/.bat 的 executable
    # 自身含 shell 元字符时也在 CreateProcess 前 fail closed；生产脚本没有该后门。
    $claudeExecutableNeedle = '$brainExecutable = [string]$claudeBin.Source'
    Assert-True $fixtureDispatchSource.Contains($claudeExecutableNeedle, [StringComparison]::Ordinal) `
        '测试设施错误：无法定位 Claude executable seam。'
    $fixtureDispatchSource = $fixtureDispatchSource.Replace(
        $claudeExecutableNeedle,
        $claudeExecutableNeedle + "`n" +
            '        if (-not [string]::IsNullOrWhiteSpace($env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE)) {' + "`n" +
            '            $brainExecutable = [string]$env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE' + "`n" +
            '        }'
    )
    $preserveNeedle = '$preserveEnvironmentNames = @()'
    Assert-True $fixtureDispatchSource.Contains($preserveNeedle, [StringComparison]::Ordinal) `
        '测试设施错误：无法定位 Codex wrapper environment seam。'
    $fixtureDispatchSource = $fixtureDispatchSource.Replace(
        $preserveNeedle,
        '$preserveEnvironmentNames = @(''DISPATCH_TEST_SENTINEL_DIR'',''DISPATCH_TEST_CODEX_SCENARIO'')'
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

    $before = Get-RepoEffectState
    $taskArgs = @('-Task', 'offline profile contract', '-Slug', 'offline-profile', '-DryRun')

    $fixtureLedgerHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-ledger.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureLedgerHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch ledger helper。'
    . $fixtureLedgerHelper
    $fixtureBrainHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-brain.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureBrainHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch brain helper。'
    . $fixtureBrainHelper
    $fixtureLockHelper = Join-Path $RepoRoot 'scripts\lib\dispatch-lock.ps1'
    Assert-True (Test-Path -LiteralPath $fixtureLockHelper -PathType Leaf) `
        '测试设施错误：fixture 缺少 dispatch lock helper。'
    . $fixtureLockHelper

    Test-Case 'DryRun 不创建主机级锁目录' {
        $lockDirectory = Split-Path -Parent $LockPath
        Assert-True (-not (Test-Path -LiteralPath $lockDirectory)) '测试开始前锁目录已存在。'
        $result = Invoke-Dispatch $taskArgs
        Assert-ExitCode $result 0
        Assert-Matches $result.Text 'budget=\$2(?:\.0)?'
        Assert-Matches $result.Text '机械成本上限 2(?:\.0)? 美元'
        Assert-NotMatches $result.Text '\{\{BUDGET_(?:USD|POLICY)\}\}'
        Assert-True (-not (Test-Path -LiteralPath $lockDirectory)) 'DryRun 创建了主机级锁目录。'

        $codexDry = Invoke-Dispatch @(
            '-Task','offline codex dry budget','-Slug','offline-codex-dry-budget',
            '-Brain','codex','-Executor','gateway','-DryRun'
        )
        Assert-ExitCode $codexDry 0
        Assert-Contains $codexDry.Text '订阅通道/无 API 硬上限'
        Assert-Contains $codexDry.Text '走 ChatGPT 订阅通道，不提供 API 美元硬上限'
        Assert-NotMatches $codexDry.Text 'budget=\$|≤\$'
        Assert-NotMatches $codexDry.Text '机械成本上限\s+2(?:\.0)?|\{\{BUDGET_(?:USD|POLICY)\}\}'
        Assert-True (-not (Test-Path -LiteralPath $lockDirectory)) 'Codex DryRun 创建了主机级锁目录。'
    }

    Test-Case 'Codex mobile 在任何 preflight/设备副作用前 fail closed' {
        $beforeMobile = Get-RepoEffectState
        $result = Invoke-Dispatch @(
            '-Task','offline codex mobile must fail closed','-Slug','offline-codex-mobile-blocked',
            '-Brain','codex','-Executor','mobile'
        )
        Assert-True ($result.ExitCode -ne 0) 'Codex + mobile 未被硬拒绝。'
        Assert-Matches $result.Text '可信 npx runtime.*仅支持 gateway'
        Assert-NoExternalTools $result
        Assert-NoRepoEffects $beforeMobile
    }

    Test-Case 'Codex 版本解析只接受精确验证输出' {
        foreach ($version in @(
            'codex-cli 0.147.0',
            'codex-cli 0.149.0',
            'codex-cli 0.149.0-alpha.4.1'
        )) {
            Assert-True (Test-DispatchSupportedCodexVersion -VersionOutput $version) `
                "已验证 Codex 版本被误拒：$version"
        }
        foreach ($version in @(
            'codex-cli 0.150.0-alpha.1',
            'codex-cli 0.150.0',
            'codex-cli 0.149.1',
            "warning`ncodex-cli 0.149.0",
            'codex-cli 0.149.0 extra',
            ''
        )) {
            Assert-True (-not (Test-DispatchSupportedCodexVersion -VersionOutput $version)) `
                "未验证或带污染的 Codex 版本被误放行：$version"
        }
    }

    Test-Case 'Codex 版本探针 Assign 失败不遗留 suspended orphan' {
        $failure = $null
        $orphans = @()
        try {
            try {
                Invoke-DispatchCodexVersionProbe -ExecutablePath $fakeVersionProbeExe `
                    -ForceAssignFailureForTest | Out-Null
            }
            catch { $failure = $_ }
            Assert-True ($null -ne $failure) 'Assign 失败 seam 未使版本探针 fail closed。'
            Assert-Matches $failure.Exception.ToString() 'fixture_forced_assign_failure'

            # seam 只会在 CreateProcess(CREATE_SUSPENDED) 成功后触发；若异常路径只关句柄，
            # 这个唯一 TEMP 路径的进程会永久保持 suspended。按完整路径核对，避免误认并行 fixture。
            $expectedPath = [IO.Path]::GetFullPath($fakeVersionProbeExe)
            $orphans = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($fakeVersionProbeExe)) `
                    -ErrorAction SilentlyContinue | Where-Object {
                    try { [IO.Path]::GetFullPath($_.Path) -ceq $expectedPath }
                    catch { $false }
                })
            Assert-True ($orphans.Count -eq 0) `
                'Assign 失败后仍遗留未入 Job 的 suspended version probe。'
        }
        finally {
            # 回归失败本身也不能给开发机留下孤儿；仅清理由本次唯一 TEMP executable 派生的 PID。
            foreach ($orphan in $orphans) {
                try {
                    $orphan.Kill($true)
                    [void]$orphan.WaitForExit(5000)
                }
                catch { Write-Warning "清理 fake version probe orphan 失败：$($_.Exception.Message)" }
                finally { $orphan.Dispose() }
            }
        }
    }

    Test-Case 'Codex 版本探针 stdout/stderr 超限时硬截断并清空后代' {
        $probeEnvironment = @(
            "SystemRoot=$env:SystemRoot", "WINDIR=$env:WINDIR", "ComSpec=$env:ComSpec",
            "TEMP=$env:TEMP", "TMP=$env:TMP", "PATH=$env:PATH", "PATHEXT=$env:PATHEXT"
        )
        foreach ($case in @(
            @{ Name='stdout'; Executable=$fakeVersionStdoutFloodExe },
            @{ Name='stderr'; Executable=$fakeVersionStderrFloodExe }
        )) {
            Remove-Item -LiteralPath $fakeVersionChildPid -Force -ErrorAction SilentlyContinue
            $probeStdout = Join-Path $SentinelDir "version-$($case.Name).stdout"
            $probeStderr = Join-Path $SentinelDir "version-$($case.Name).stderr"
            $failure = $null
            try {
                [void][AgentMobileDispatchVersionProbe]::Run(
                    [IO.Path]::GetFullPath([string]$case.Executable),
                    [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$case.Executable)),
                    $probeStdout, $probeStderr, [string[]]$probeEnvironment,
                    4096L, 4096L, 5000, $false)
            }
            catch { $failure = $_ }
            Assert-True ($null -ne $failure) "version $($case.Name) flood 没有 fail closed。"
            Assert-Matches $failure.Exception.ToString() 'exceeded byte limit'
            Assert-True ((Get-Item -LiteralPath $probeStdout -Force).Length -le 4096) `
                "version stdout 文件超过硬 cap：$((Get-Item -LiteralPath $probeStdout).Length)"
            Assert-True ((Get-Item -LiteralPath $probeStderr -Force).Length -le 4096) `
                "version stderr 文件超过硬 cap：$((Get-Item -LiteralPath $probeStderr).Length)"
            Assert-True (Test-Path -LiteralPath $fakeVersionChildPid -PathType Leaf) `
                "version $($case.Name) flood 未证明派生后代。"
            $childPid = [int](Get-Content -LiteralPath $fakeVersionChildPid -Raw -Encoding ascii)
            Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) `
                "version $($case.Name) flood 返回后仍有后代存活。"
        }
    }

    Test-Case 'Codex 版本探针成功返回前机械清空快速退出根进程留下的后代' {
        $version = Invoke-DispatchCodexVersionProbe -ExecutablePath $fakeVersionProbeExe
        Assert-True ($version -ceq 'codex-cli 0.149.0') `
            "fake Codex 版本探针输出未被完整保留：[$version] type=$($version.GetType().FullName) length=$($version.Length)"
        Assert-True (Test-Path -LiteralPath $fakeVersionChildPid -PathType Leaf) `
            'fake version child 没有在根进程退出前写入 PID sentinel。'
        $childPid = [int](Get-Content -LiteralPath $fakeVersionChildPid -Raw -Encoding ascii)
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) `
            '版本探针根进程已退出，但其后代在函数返回后仍存活。'
    }

    Test-Case 'Codex 候选按显式契约优先级而不是 mtime 或随机目录名' {
        $selection = Select-DispatchCodexExecutableCandidate -Candidates @(
            [pscustomobject]@{
                Path = (Join-Path $TestRoot 'ffff-newer\codex.exe')
                VersionOutput = 'codex-cli 0.147.0'
                Sha256 = '47'
                LastWriteTimeUtc = [datetime]'2099-01-01'
            },
            [pscustomobject]@{
                Path = (Join-Path $TestRoot '0000-older\codex.exe')
                VersionOutput = 'codex-cli 0.149.0'
                Sha256 = '49'
                LastWriteTimeUtc = [datetime]'2000-01-01'
            },
            [pscustomobject]@{
                Path = (Join-Path $TestRoot 'zzzz-unknown\codex.exe')
                VersionOutput = 'codex-cli 0.150.0-alpha.1'
                Sha256 = '50'
                LastWriteTimeUtc = [datetime]'2100-01-01'
            }
        )
        Assert-True ($selection.VersionOutput -ceq 'codex-cli 0.149.0') `
            'mtime 更新的旧版/未知版盖过了显式 0.149 stable 优先级。'
        Assert-True ($selection.SelectedPath -like '*0000-older*') `
            '候选选择仍受随机目录名或 mtime 影响。'
        Assert-True ($selection.UnknownVersions -contains 'codex-cli 0.150.0-alpha.1') `
            '已知与未知候选并存时没有保留未知版本诊断。'

        $unknownOnlyRejected = $false
        try {
            $null = Select-DispatchCodexExecutableCandidate -Candidates @(
                [pscustomobject]@{Path=(Join-Path $TestRoot 'unknown\codex.exe');VersionOutput='codex-cli 0.150.0-alpha.1';Sha256='50'}
            )
        }
        catch { $unknownOnlyRejected = $_.Exception.Message -match '0\.150\.0-alpha\.1' }
        Assert-True $unknownOnlyRejected '只有未知 0.150 候选时没有带诊断 fail closed。'

        $hashConflictRejected = $false
        try {
            $null = Select-DispatchCodexExecutableCandidate -Candidates @(
                [pscustomobject]@{Path=(Join-Path $TestRoot 'a\codex.exe');VersionOutput='codex-cli 0.149.0';Sha256='AA'},
                [pscustomobject]@{Path=(Join-Path $TestRoot 'b\codex.exe');VersionOutput='codex-cli 0.149.0';Sha256='BB'}
            )
        }
        catch { $hashConflictRejected = $_.Exception.Message -match '不同二进制哈希' }
        Assert-True $hashConflictRejected '同优先级不同哈希的 Codex 候选没有 fail closed。'
    }

    Test-Case 'Codex MCP 配置拒绝顶层与字段的单元素数组降维' {
        $profile = Get-ExecutorProfile -Executor gateway -RepoRoot $RepoRoot `
            -ScriptsRoot (Join-Path $RepoRoot 'scripts')
        $configPath = Join-Path $SentinelDir 'strict-codex-mcp.json'
        $validJson = '{"mcpServers":{"gateway":{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":{"Authorization":"Bearer fixture"}}}}'
        Set-Content -LiteralPath $configPath -Value $validJson -Encoding utf8
        $validSpec = New-DispatchCodexLaunchSpec -Profile $profile -ConfigPath $configPath `
            -WorkspacePath $TestRoot -Model '' -ModelWasExplicit $false -Leg 1 `
            -CodexExecutableOverride $fakeCodexExe -CodexVersionOverride 'codex-cli 0.149.0'
        Assert-True ($validSpec.Arguments -contains 'mcp_servers.gateway.enabled=true') `
            '严格 MCP 配置门误拒绝了合法 object/string/number token。'
        foreach ($key in @($validSpec.SensitiveEnvironment.Keys)) {
            $validSpec.SensitiveEnvironment[$key] = $null
            [void]$validSpec.SensitiveEnvironment.Remove($key)
        }

        foreach ($bad in @(
            @{ Name='top-array'; Json="[$validJson]" },
            @{ Name='mcpServers-array'; Json='{"mcpServers":[{"gateway":{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":{"Authorization":"Bearer fixture"}}}]}' },
            @{ Name='server-array'; Json='{"mcpServers":{"gateway":[{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":{"Authorization":"Bearer fixture"}}]}}' },
            @{ Name='type-array'; Json='{"mcpServers":{"gateway":{"type":["http"],"url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":{"Authorization":"Bearer fixture"}}}}' },
            @{ Name='url-number'; Json='{"mcpServers":{"gateway":{"type":"http","url":8848,"timeout":420000,"headers":{"Authorization":"Bearer fixture"}}}}' },
            @{ Name='timeout-string'; Json='{"mcpServers":{"gateway":{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":"420000","headers":{"Authorization":"Bearer fixture"}}}}' },
            @{ Name='headers-array'; Json='{"mcpServers":{"gateway":{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":[{"Authorization":"Bearer fixture"}]}}}' },
            @{ Name='authorization-array'; Json='{"mcpServers":{"gateway":{"type":"http","url":"http://127.0.0.1:8848/mcp","timeout":420000,"headers":{"Authorization":["Bearer fixture"]}}}}' }
        )) {
            Set-Content -LiteralPath $configPath -Value $bad.Json -Encoding utf8
            $rejected = $false
            try {
                $null = New-DispatchCodexLaunchSpec -Profile $profile -ConfigPath $configPath `
                    -WorkspacePath $TestRoot -Model '' -ModelWasExplicit $false -Leg 1 `
                    -CodexExecutableOverride $fakeCodexExe -CodexVersionOverride 'codex-cli 0.149.0'
            }
            catch { $rejected = $true }
            Assert-True $rejected "Codex MCP 配置 $($bad.Name) 被数组降维/类型强制转换接受。"
        }
    }

    Test-Case 'Codex JSONL 完整与 partial 契约严格区分' {
        $complete = @(
            '{"type":"thread.started","thread_id":"offline-thread"}',
            '{"type":"turn.started"}',
            '{"type":"item.started","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"foreground_app","arguments":{}}}',
            '{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"foreground_app","arguments":{},"result":{"content":[{"type":"text","text":"{\"ok\":true}"}]},"error":null,"status":"completed"}}',
            '{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"结果：成功"}}',
            '{"type":"turn.completed","usage":{"input_tokens":11,"cached_input_tokens":2,"output_tokens":7,"cache_write_input_tokens":3}}'
        )
        $transcript = Invoke-TranscriptFixture -Brain codex -Lines $complete
        Assert-True ($transcript.Terminal.Success -and $transcript.SessionId -ceq 'offline-thread') `
            '完整 Codex JSONL 没有得到成功 canonical 终态。'
        Assert-True ($transcript.Usage.InputTokens -eq 11 -and
            $transcript.Usage.CachedInputTokens -eq 2 -and
            $transcript.Usage.OutputTokens -eq 7 -and
            $transcript.Usage.CacheWriteTokens -eq 3) 'Codex usage 字段映射不完整。'

        foreach ($invalidUsage in @(
            '{"input_tokens":"11","cached_input_tokens":2,"output_tokens":7}',
            '{"input_tokens":true,"cached_input_tokens":2,"output_tokens":7}',
            '{"input_tokens":1.5,"cached_input_tokens":2,"output_tokens":7}',
            '{"input_tokens":[11],"cached_input_tokens":2,"output_tokens":7}',
            '[{"input_tokens":11,"cached_input_tokens":2,"output_tokens":7}]',
            '{"input_tokens":11,"cached_input_tokens":2,"output_tokens":7,"cache_write_input_tokens":-1}'
        )) {
            $badUsage = @($complete[0..4] + "{`"type`":`"turn.completed`",`"usage`":$invalidUsage}")
            $usageRejected = $false
            try { $null = Invoke-TranscriptFixture -Brain codex -Lines $badUsage }
            catch { $usageRejected = $true }
            Assert-True $usageRejected "Codex usage 原始值不是非负整数却被接受：$invalidUsage"
        }

        $businessFailure = @($complete)
        $businessFailure[3] = '{"type":"item.completed","item":{"id":"call-1","type":"mcp_tool_call","server":"gateway","tool":"foreground_app","arguments":{},"result":{"content":[{"type":"text","text":"{\"ok\":false}"}]},"error":null,"status":"completed"}}'
        $businessTranscript = Invoke-TranscriptFixture -Brain codex -Lines $businessFailure
        Assert-True ($businessTranscript.Calls.Count -eq 1 -and
            $businessTranscript.Calls[0].Outcome -ceq 'failed') `
            'gateway JSON boolean ok=false 被当作成功调用。'

        foreach ($badResult in @(
            '{"content":[{"type":"text","text":"[{\"ok\":true}]"}]}',
            '{"content":[{"type":"text","text":"{\"ok\":[true]}"}]}',
            '{"content":[{"type":"text","text":"{\"ok\":true}"}],"isError":[false]}'
        )) {
            $badEnvelope = @($complete)
            $badEnvelope[3] = "{`"type`":`"item.completed`",`"item`":{`"id`":`"call-1`",`"type`":`"mcp_tool_call`",`"server`":`"gateway`",`"tool`":`"foreground_app`",`"arguments`":{},`"result`":$badResult,`"error`":null,`"status`":`"completed`"}}"
            $envelopeRejected = $false
            try { $null = Invoke-TranscriptFixture -Brain codex -Lines $badEnvelope }
            catch { $envelopeRejected = $true }
            Assert-True $envelopeRejected "Codex gateway 单元素数组降维绕过：$badResult"
        }

        $prefix = $complete[0..2]
        $strictRejected = $false
        try { $null = Invoke-TranscriptFixture -Brain codex -Lines $prefix }
        catch { $strictRejected = $true }
        Assert-True $strictRejected '缺终态 trace 被默认完整模式接受。'
        $partial = Invoke-TranscriptFixture -Brain codex -Lines $prefix -AllowPartial
        Assert-True ($null -eq $partial.Terminal -and $partial.Calls.Count -eq 1 -and
            $partial.Calls[0].Outcome -ceq 'started') '合法 EOF partial 没有保留未完成尾调用。'

        foreach ($bad in @(
            @('{not-json'),
            @($complete + $complete[-1]),
            @($complete[0..1] + '{"type":"unknown"}')
        )) {
            $rejected = $false
            try { $null = Invoke-TranscriptFixture -Brain codex -Lines $bad -AllowPartial }
            catch { $rejected = $true }
            Assert-True $rejected '坏帧/重复终态/未知事件在 partial 模式下被接受。'
        }
    }

    Test-Case 'Claude gateway 结果同样要求 boolean ok=true' {
        $prefix = @(
            '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"call-1","name":"mcp__gateway__foreground_app","input":{}}]}}',
            '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":[{"type":"text","text":"{\"ok\":false}"}],"is_error":false}]}}',
            '{"type":"result","subtype":"success","result":"结果：成功","usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0},"num_turns":1,"total_cost_usd":0}'
        )
        $transcript = Invoke-TranscriptFixture -Brain claude -Lines $prefix
        Assert-True ($transcript.Calls.Count -eq 1 -and $transcript.Calls[0].Outcome -ceq 'failed') `
            'Claude gateway 的 ok=false 被当作成功调用。'

        $badBoolean = @($prefix)
        foreach ($badIsError in @('"false"','[false]')) {
            $badBoolean[1] = "{`"type`":`"user`",`"message`":{`"content`":[{`"type`":`"tool_result`",`"tool_use_id`":`"call-1`",`"content`":[{`"type`":`"text`",`"text`":`"{\`"ok\`":true}`"}],`"is_error`":$badIsError}]}}"
            $rejected = $false
            try { $null = Invoke-TranscriptFixture -Brain claude -Lines $badBoolean }
            catch { $rejected = $true }
            Assert-True $rejected "Claude tool_result 的非 boolean is_error 被接受：$badIsError"
        }

        $badCost = @($prefix)
        $badCost[2] = '{"type":"result","subtype":"success","result":"结果：成功","usage":{"input_tokens":1,"output_tokens":1},"num_turns":1,"total_cost_usd":[0]}'
        $costRejected = $false
        try { $null = Invoke-TranscriptFixture -Brain claude -Lines $badCost }
        catch { $costRejected = $true }
        Assert-True $costRejected 'Claude total_cost_usd 单元素数组被降维接受。'

        foreach ($badTerminal in @(
            '{"type":"result","subtype":"success","result":"结果：成功","num_turns":1,"total_cost_usd":0}',
            '{"type":"result","subtype":"success","result":"结果：成功","usage":{"input_tokens":1,"output_tokens":1},"num_turns":1,"total_cost_usd":0}',
            '{"type":"result","subtype":"success","result":"结果：成功","usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0},"total_cost_usd":0}',
            '{"type":"result","subtype":"success","result":"结果：成功","usage":{"input_tokens":1,"cache_read_input_tokens":0,"output_tokens":1,"cache_creation_input_tokens":0},"num_turns":1}'
        )) {
            $missingAccounting = @($prefix)
            $missingAccounting[2] = $badTerminal
            $rejected = $false
            try { $null = Invoke-TranscriptFixture -Brain claude -Lines $missingAccounting }
            catch { $rejected = $true }
            Assert-True $rejected "Claude success 缺少完整 usage/num_turns/total_cost_usd 却被接受：$badTerminal"
        }

        $failureWithoutAccounting = @($prefix)
        $failureWithoutAccounting[2] = `
            '{"type":"result","subtype":"error","result":"结果：失败"}'
        $failureTranscript = Invoke-TranscriptFixture -Brain claude -Lines $failureWithoutAccounting
        Assert-True (-not $failureTranscript.Terminal.Success -and
            $null -eq $failureTranscript.Usage.InputTokens -and $null -eq $failureTranscript.CostUsd) `
            'Claude 失败终态被误要求 success-only 计量字段。'
    }

    Test-Case 'cmd/bat executable 与 Model 参数含 shell 元字符时 fail closed' {
        $gatewayConfig = Join-Path $RepoRoot 'configs\gateway-mcp.json'
        Copy-Item -LiteralPath $validGatewayConfig -Destination $gatewayConfig -Force
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        $savedOverride = $env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE
        $injectedPath = Join-Path $SentinelDir 'cmd-injected.txt'
        try {
            foreach ($model in @(
                'sonnet&echo injected>%DISPATCH_TEST_SENTINEL_DIR%\cmd-injected.txt',
                'sonnet"&echo injected>cmd-injected.txt'
            )) {
                Remove-Item -LiteralPath $injectedPath -Force -ErrorAction SilentlyContinue
                $env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE = $null
                $slug = 'offline-cmd-arg-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                $result = Invoke-Dispatch @(
                    '-Task','offline cmd argument injection guard','-Slug',$slug,
                    '-Brain','claude','-Executor','gateway','-Model',$model
                )
                Assert-True ($result.ExitCode -ne 0) "恶意 Model 未被拒绝：$model"
                Assert-True (-not (Test-Path -LiteralPath $injectedPath)) '恶意 Model 执行了 cmd 注入载荷。'
                Assert-True (-not (Test-Path -LiteralPath (Join-Path $SentinelDir 'claude-called.txt'))) `
                    '含 shell 元字符的 Model 仍启动了 fake Claude。'
                $errorFile = Get-ChildItem -LiteralPath $TracesDir -Filter "*-$slug-gateway-claude-leg1.err.txt" |
                    Select-Object -Last 1
                Assert-True ($null -ne $errorFile) 'cmd 参数拒绝路径没有留下有界 stderr。'
                # PowerShell 的原生 stderr 在重定向时可能包成 CLIXML；匹配稳定的 ASCII 前缀，
                # 同时由上面的进程未启动/无注入副作用断言证明这里确实 fail closed。
                Assert-Matches (Get-Content -LiteralPath $errorFile.FullName -Raw) 'cmd/bat executable'
            }

            $unsafeDirectory = Join-Path $TestRoot 'unsafe(parent)'
            New-Item -ItemType Directory -Path $unsafeDirectory -Force | Out-Null
            $unsafeExecutable = Join-Path $unsafeDirectory 'claude.cmd'
            Copy-Item -LiteralPath (Join-Path $FakeBin 'claude.cmd') -Destination $unsafeExecutable
            $env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE = $unsafeExecutable
            $pathSlug = 'offline-cmd-executable-unsafe'
            $pathResult = Invoke-Dispatch @(
                '-Task','offline cmd executable injection guard','-Slug',$pathSlug,
                '-Brain','claude','-Executor','gateway'
            )
            Assert-True ($pathResult.ExitCode -ne 0) '含括号的 .cmd executable 未被拒绝。'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $SentinelDir 'claude-called.txt'))) `
                '含 shell 元字符的 executable 仍被启动。'
            $pathError = Get-ChildItem -LiteralPath $TracesDir `
                -Filter "*-$pathSlug-gateway-claude-leg1.err.txt" | Select-Object -Last 1
            Assert-Matches (Get-Content -LiteralPath $pathError.FullName -Raw) 'cmd/bat executable'
        }
        finally {
            $env:DISPATCH_TEST_CLAUDE_EXECUTABLE_OVERRIDE = $savedOverride
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object Name -like '*-offline-cmd-*-gateway-claude-leg1.*' |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ((Test-Path -LiteralPath $TracesDir -PathType Container) -and
                @(Get-ChildItem -LiteralPath $TracesDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $TracesDir -Force
            }
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $gatewayConfig -Force -ErrorAction SilentlyContinue
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) {
                [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length)
            }
        }
    }

    Test-Case 'fake Codex 端到端锁住 argv、环境、exit code、partial 与 usage' {
        $gatewayConfig = Join-Path $RepoRoot 'configs\gateway-mcp.json'
        Copy-Item -LiteralPath $validGatewayConfig -Destination $gatewayConfig -Force
        $ledgerExisted = Test-Path -LiteralPath $LedgerPath -PathType Leaf
        $ledgerBytes = if ($ledgerExisted) { [IO.File]::ReadAllBytes($LedgerPath) } else { $null }
        $oldScenario = $env:DISPATCH_TEST_CODEX_SCENARIO
        $oldOpenAiKey = $env:OPENAI_API_KEY
        $oldCodexToken = $env:CODEX_ACCESS_TOKEN
        $oldArbitrary = $env:ARBITRARY_PARENT_SECRET
        $oldDeviceLease = $env:AGENT_MOBILE_DEVICE_LOCK_LEASE
        $parentLease = $null
        try {
            $env:OPENAI_API_KEY = 'must-not-reach-fake-codex'
            $env:CODEX_ACCESS_TOKEN = 'must-not-reach-fake-codex'
            $env:ARBITRARY_PARENT_SECRET = 'must-not-reach-fake-codex'
            $parentLease = Open-DispatchLock -Path $LockPath -Owner 'offline-parent' -LeaseToken ''
            $env:AGENT_MOBILE_DEVICE_LOCK_LEASE = $parentLease.LeaseToken

            $claudeResult = Invoke-Dispatch @(
                '-Task','offline fake claude lease isolation','-Slug','offline-claude-lease',
                '-Brain','claude','-Executor','gateway'
            )
            Assert-ExitCode $claudeResult 0
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'claude-lock-env.txt') -Raw).Trim() -ceq '[]') `
                'Claude brain 继承了 runner→dispatch 的设备 lease token。'

            $cases = @(
                @{ Scenario='success'; Exit=0; Pattern='派单结果：success' },
                @{ Scenario='exit-partial'; Exit=1; Pattern='brain-process-exit-23.*partial-trace' },
                @{ Scenario='malformed'; Exit=1; Pattern='trace-invalid-or-incomplete' },
                @{ Scenario='wrong-server'; Exit=1; Pattern='unauthorized-mcp-server' },
                @{ Scenario='gateway-ok-false'; Exit=1; Pattern='mcp-transport-failure' },
                @{ Scenario='missing-usage'; Exit=1; Pattern='trace-invalid-or-incomplete' }
            )
            foreach ($case in $cases) {
                $env:DISPATCH_TEST_CODEX_SCENARIO = $case.Scenario
                $slug = "offline-codex-$($case.Scenario)"
                $result = Invoke-Dispatch @(
                    '-Task','offline fake codex contract','-Slug',$slug,
                    '-Brain','codex','-Executor','gateway'
                )
                Assert-ExitCode $result $case.Exit
                Assert-Matches $result.Text $case.Pattern
                Assert-NotMatches $result.Text 'fixture-bearer-value-must-never-leak|must-not-reach-fake-codex'
            }
            Assert-Contains (Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-prompt.txt') -Raw) `
                'offline fake codex contract'

            foreach ($flood in @(
                @{ Scenario='stdout-flood'; Slug='offline-codex-stdout-flood'; Cap=16L*1024L*1024L; Extension='.jsonl' },
                @{ Scenario='stderr-flood'; Slug='offline-codex-stderr-flood'; Cap=4L*1024L*1024L; Extension='.err.txt' }
            )) {
                $env:DISPATCH_TEST_CODEX_SCENARIO = $flood.Scenario
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $floodResult = Invoke-Dispatch @(
                    '-Task','offline fake codex output flood','-Slug',$flood.Slug,
                    '-Brain','codex','-Executor','gateway'
                )
                $watch.Stop()
                Assert-ExitCode $floodResult 1
                Assert-Contains $floodResult.Text 'brain-output-limit'
                Assert-Contains $floodResult.Text '订阅通道/无 API 硬上限'
                Assert-True ($watch.Elapsed.TotalSeconds -lt 10) `
                    "$($flood.Scenario) 没有快速失败，耗时 $([math]::Round($watch.Elapsed.TotalSeconds, 2))s。"

                $trace = Get-ChildItem -LiteralPath $TracesDir `
                    -Filter "*-$($flood.Slug)-gateway-codex-leg1.jsonl" | Select-Object -Last 1
                $error = Get-ChildItem -LiteralPath $TracesDir `
                    -Filter "*-$($flood.Slug)-gateway-codex-leg1.err.txt" | Select-Object -Last 1
                Assert-True ($null -ne $trace -and $null -ne $error) '泛洪路径缺少 stdout/stderr 证据文件。'
                Assert-True ($trace.Length -le 16L * 1024L * 1024L) `
                    "stdout 超过 16 MiB：$($trace.Length)"
                Assert-True ($error.Length -le 4L * 1024L * 1024L) `
                    "stderr 超过 4 MiB：$($error.Length)"
                $cappedFile = if ($flood.Extension -ceq '.jsonl') { $trace } else { $error }
                Assert-True ($cappedFile.Length -eq [long]$flood.Cap) `
                    "$($flood.Scenario) 未在精确 cap 触发：$($cappedFile.Length) / $($flood.Cap)"

                $startedPath = Join-Path $SentinelDir "$($flood.Scenario)-descendant-started.txt"
                $survivedPath = Join-Path $SentinelDir "$($flood.Scenario)-descendant-survived.txt"
                Assert-True (Test-Path -LiteralPath $startedPath -PathType Leaf) '泛洪前没有真正派生后代。'
                $descendantPid = [int](Get-Content -LiteralPath $startedPath -Raw)
                Assert-True ($null -eq (Get-Process -Id $descendantPid -ErrorAction SilentlyContinue)) `
                    '输出超限返回后仍有 Job 后代存活。'
                Assert-True (-not (Test-Path -LiteralPath $survivedPath)) `
                    '输出超限后代活到延迟 sentinel，Job 未及时收口。'
            }

            $argv = Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-argv.txt') -Raw -Encoding utf8
            foreach ($required in @('exec','--json','--ephemeral','--ignore-user-config','--strict-config','read-only')) {
                Assert-Contains $argv $required
            }
            Assert-NotMatches $argv '(?m)^--model\s*$|(?m)^sonnet\s*$|fixture-bearer-value-must-never-leak'
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-cwd-empty.txt') -Raw).Trim() -ceq 'true') `
                'Codex 没有在 repo 外的空 workspace 启动。'
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-secret-ok.txt') -Raw).Trim() -ceq 'true') `
                'gateway bearer 没有只经随机 child env 传递。'
            Assert-True ((Get-Content -LiteralPath (Join-Path $SentinelDir 'codex-environment-ok.txt') -Raw).Trim() -ceq 'true') `
                'Codex child 环境未按 allowlist 清理。'
            $successTrace = Get-ChildItem -LiteralPath $TracesDir -Filter '*-offline-codex-success-gateway-codex-leg1.jsonl'
            Assert-True ($successTrace.Count -eq 1) '成功 fake Codex trace 未按 brain basename 落盘。'
            $rows = @(Import-Csv -LiteralPath $LedgerPath)
            $successRow = @($rows | Where-Object { $_.slug -ceq 'offline-codex-success' } | Select-Object -Last 1)
            Assert-True ($successRow.Count -eq 1 -and $successRow[0].brain -ceq 'codex' -and
                $successRow[0].model -ceq '' -and $successRow[0].turns -ceq '1' -and
                $successRow[0].in_tok -ceq '11' -and $successRow[0].cache_read -ceq '2' -and
                $successRow[0].out_tok -ceq '7' -and $successRow[0].cache_write -ceq '3' -and
                $successRow[0].cost_usd -ceq '') 'Codex usage/订阅成本没有严格写入台账。'
            $partialRow = @($rows | Where-Object { $_.slug -ceq 'offline-codex-exit-partial' } | Select-Object -Last 1)
            Assert-True ($partialRow.Count -eq 1 -and $partialRow[0].result -ceq 'fail' -and
                $partialRow[0].in_tok -ceq '' -and $partialRow[0].out_tok -ceq '') `
                'partial/非零退出被伪造为成功 usage。'
            foreach ($floodSlug in @('offline-codex-stdout-flood','offline-codex-stderr-flood')) {
                $floodRow = @($rows | Where-Object { $_.slug -ceq $floodSlug } | Select-Object -Last 1)
                Assert-True ($floodRow.Count -eq 1 -and $floodRow[0].result -ceq 'fail' -and
                    $floodRow[0].note -match 'brain-output-limit') `
                    "$floodSlug 未稳定记为 brain-output-limit。"
            }
        }
        finally {
            $env:DISPATCH_TEST_CODEX_SCENARIO = $oldScenario
            $env:OPENAI_API_KEY = $oldOpenAiKey
            $env:CODEX_ACCESS_TOKEN = $oldCodexToken
            $env:ARBITRARY_PARENT_SECRET = $oldArbitrary
            $env:AGENT_MOBILE_DEVICE_LOCK_LEASE = $oldDeviceLease
            if ($null -ne $parentLease) { [void](Close-DispatchLockLease -Lease $parentLease) }
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object Name -like '*-offline-codex-*-gateway-codex-leg1.*' |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $TracesDir -File -ErrorAction SilentlyContinue |
                Where-Object Name -like '*-offline-claude-lease-gateway-claude-leg1.*' |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ((Test-Path -LiteralPath $TracesDir -PathType Container) -and
                @(Get-ChildItem -LiteralPath $TracesDir -Force).Count -eq 0) {
                Remove-Item -LiteralPath $TracesDir -Force
            }
            if ($ledgerExisted) { [IO.File]::WriteAllBytes($LedgerPath, $ledgerBytes) }
            else { Remove-Item -LiteralPath $LedgerPath -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $gatewayConfig -Force -ErrorAction SilentlyContinue
            if ($null -ne $ledgerBytes -and $ledgerBytes.Length -gt 0) {
                [Array]::Clear($ledgerBytes, 0, $ledgerBytes.Length)
            }
        }
    }

    Test-Case 'TimeoutMin 非正值与溢出值在任何外部调用前拒绝' {
        foreach ($badTimeout in @('0','-1','61','2147483647')) {
            $result = Invoke-Dispatch @('-Task','offline timeout guard','-Slug','offline-timeout','-TimeoutMin',$badTimeout)
            Assert-True ($result.ExitCode -ne 0) "TimeoutMin=$badTimeout 不得进入预检或派单。"
            Assert-Matches $result.Text 'TimeoutMin|1.*60'
            Assert-NoExternalTools $result
            Assert-NoRepoEffects $before
        }
    }

    Test-Case 'MaxBudgetUsd 非正值与非有限值在任何外部调用前拒绝' {
        foreach ($badBudget in @('0','-1','NaN','Infinity','-Infinity')) {
            $result = Invoke-Dispatch @(
                '-Task','offline budget guard','-Slug','offline-budget','-MaxBudgetUsd',$badBudget
            )
            Assert-True ($result.ExitCode -ne 0) "MaxBudgetUsd=$badBudget 不得进入预检或派单。"
            Assert-Matches $result.Text 'MaxBudgetUsd|大于 0|有限数字'
            Assert-NoExternalTools $result
            Assert-NoRepoEffects $before
        }
    }

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
        finally { [void](Close-DispatchLockLease -Lease $stream) }
    }

    Test-Case '崩溃残留的锁自动清理后取锁成功' {
        $path = Join-Path $lockProbeDir 'stale.lock'
        # 上一次派单崩溃：文件留下，句柄已被 OS 回收。
        Set-Content -LiteralPath $path -Value 'pid=999999 owner=crashed/leg1/gateway at=2026-07-26T00:00:00' -Encoding utf8
        $stream = Open-DispatchLock -Path $path -Owner 'offline/leg1/gateway'
        try {
            Assert-True ($null -ne $stream) '残锁未被自动清理。'
            $metadata = Read-DispatchLockMetadata -Stream $stream.Stream
        }
        finally { [void](Close-DispatchLockLease -Lease $stream) }
        Assert-True ($metadata.schema_version -eq 1 -and
            -not [string]::IsNullOrWhiteSpace([string]$metadata.owner_fingerprint)) `
            '残锁没有被替换成结构化租约元数据。'
        Assert-NotMatches ($metadata | ConvertTo-Json -Compress) 'crashed'
    }

    Test-Case '设备锁 hardlink 必须 fail closed 且不覆写目标' {
        $victim = Join-Path $lockProbeDir 'victim.txt'
        $path = Join-Path $lockProbeDir 'hardlink.lock'
        [IO.File]::WriteAllText($victim, 'victim-must-remain-byte-identical', [Text.UTF8Encoding]::new($false))
        New-Item -ItemType HardLink -Path $path -Target $victim | Out-Null
        $beforeVictim = [Convert]::ToHexString([IO.File]::ReadAllBytes($victim))
        $threw = $false
        try { Open-DispatchLock -Path $path -Owner 'must-not-overwrite-victim' -LeaseToken '' | Out-Null }
        catch { $threw = $true }
        Assert-True $threw 'hardlink 设备锁未 fail closed。'
        Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($victim)) -ceq $beforeVictim) `
            'hardlink 设备锁覆写了目标文件。'
    }

    Test-Case '主机级锁拒绝 junction 且租约期间目录不可换链' {
        $junctionBase = Join-Path $TestRoot 'junction-localappdata'
        $junctionTarget = Join-Path $TestRoot 'junction-target'
        New-Item -ItemType Directory -Path $junctionBase, $junctionTarget -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $junctionBase 'agent-for-mobile') `
            -Target $junctionTarget | Out-Null
        $junctionRejected = $false
        try { $null = Get-DispatchGlobalLockPath -LocalAppDataPath $junctionBase }
        catch { $junctionRejected = $true }
        Assert-True $junctionRejected 'LocalAppData 下的 junction 绕过了设备锁路径验证。'

        $stableBase = Join-Path $TestRoot 'stable-localappdata'
        New-Item -ItemType Directory -Path $stableBase -Force | Out-Null
        $stablePath = Get-DispatchGlobalLockPath -LocalAppDataPath $stableBase
        $stableLease = Open-DispatchLock -Path $stablePath -Owner 'directory-guard-test' -LeaseToken ''
        try {
            $agentDirectory = Join-Path $stableBase 'agent-for-mobile'
            $movedDirectory = Join-Path $stableBase 'agent-for-mobile-moved'
            $renameRejected = $false
            try { [IO.Directory]::Move($agentDirectory, $movedDirectory) }
            catch { $renameRejected = $true }
            if (-not $renameRejected -and (Test-Path -LiteralPath $movedDirectory)) {
                [IO.Directory]::Move($movedDirectory, $agentDirectory)
            }
            Assert-True $renameRejected '活跃租约未用目录 guard 阻止锁路径换链。'
        }
        finally { [void](Close-DispatchLockLease -Lease $stableLease) }
    }

    Test-Case '仍被持有的锁必拒且不删锁文件' {
        $path = Join-Path $lockProbeDir 'active.lock'
        $held = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
        try {
            $threw = $false
            try { Open-DispatchLock -Path $path -Owner 'offline/leg1/gateway' | Out-Null }
            catch {
                $threw = $true
                Assert-Matches $_.Exception.Message '疑似另一次.*任务进行中|设备任务进行中'
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
