#Requires -Version 7
<#
手机执行 harness · 派单 wrapper
设计：docs/specs/2026-07-17-执行harness-design.md（§4–§7）

用法：
  scripts/dispatch.ps1 -TaskFile scripts/tasks/xxx.md [-Slug 短名] [-MaxBudgetUsd 2.0] [-TimeoutMin 15] [-Model sonnet]
  scripts/dispatch.ps1 -Task "<内联任务文本>" [-Slug 短名]
  scripts/dispatch.ps1 -Confirm docs/runs/traces/xxx.pause.md    # 两段式确认腿（非 DryRun 需人工键入 CONFIRM）
  加 -Executor mobile|gateway 选择执行器；省略时保持 mobile。
  加 -DryRun 只打印组装后的提示词与参数，不预检不派单。

约束：路径参数不要含空格（Start-Process 参数按空格分词，本仓路径无空格即可）。
#>
[CmdletBinding()]
param(
    [string]$Task,
    [string]$TaskFile,
    [string]$Slug,
    [double]$MaxBudgetUsd = 2.0,
    [int]$TimeoutMin = 15,
    [string]$Model = 'sonnet',
    [ValidateSet('claude', 'codex')][string]$Brain = 'claude',
    [ValidateSet('mobile', 'gateway')][string]$Executor = 'mobile',
    [string]$Confirm,
    [switch]$DryRun
)

$ExecutorWasExplicit = $PSBoundParameters.ContainsKey('Executor')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot     = Split-Path $PSScriptRoot -Parent
$TracesDir    = Join-Path $RepoRoot 'docs\runs\traces'
$LedgerPath   = Join-Path $RepoRoot 'docs\runs\ledger.csv'
$LockFile     = Join-Path $PSScriptRoot '.dispatch.lock'
$LedgerHeader = 'time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note'
$ProfileHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-profile.ps1'
. $ProfileHelperPath

function CsvQuote([string]$s) { '"' + ("$s" -replace '"', '""') + '"' }

function Add-LedgerRow([int]$Turns, [long]$InTok, [long]$OutTok, [long]$CacheRead, [long]$CacheWrite,
                       [double]$CostUsd, [int]$DurS, [string]$Result, [string]$SessionId, [string]$Trace, [string]$Note) {
    if (-not (Test-Path $LedgerPath)) { Set-Content -Path $LedgerPath -Value $LedgerHeader -Encoding utf8 }
    $noteWithExecutor = if ([string]::IsNullOrWhiteSpace($Note)) { "executor=$Executor" } else { "executor=$Executor | $Note" }
    $row = @((Get-Date -Format 's'), (CsvQuote $Slug), $Leg, $Brain, $Model,
             $Turns, $InTok, $OutTok, $CacheRead, $CacheWrite,
             [math]::Round($CostUsd, 4), $DurS, $Result, $SessionId, (CsvQuote $Trace), (CsvQuote $noteWithExecutor)) -join ','
    Add-Content -Path $LedgerPath -Value $row -Encoding utf8
}

# ── codex 接口占位（spec §8，决策点 4：首个真实对照需求再实现）──────────────
if ($Brain -eq 'codex') {
    Write-Host 'codex 对照通道：接口已预留，实现推迟至首个对照需求（spec §8）。'
    exit 2
}

# ── 输入解析：普通腿 or 确认腿 ──────────────────────────────────────────────
$Leg = 1
$TaskText = ''
if ($Confirm) {
    if (-not (Test-Path $Confirm)) { throw "暂停件不存在：$Confirm" }
    $pauseRaw = Get-Content $Confirm -Raw -Encoding utf8
    $parts = $pauseRaw -split '(?m)^---\s*$', 2
    if ($parts.Count -lt 2) { throw "暂停件格式异常（缺 --- 分隔）：$Confirm" }
    $meta = @{}
    foreach ($line in ($parts[0] -split "`r?`n")) {
        if ($line -match '^(\w+):\s*(.*)$') { $meta[$Matches[1]] = $Matches[2].Trim() }
    }
    $Slug = $meta['slug']
    $Leg = [int]$meta['leg'] + 1
    $pauseReport = $parts[1].Trim()
    $pauseExecutor = if ([string]::IsNullOrWhiteSpace($meta['executor'])) { 'mobile' } else { $meta['executor'] }
    if ($pauseExecutor -notin @('mobile', 'gateway')) {
        throw "暂停件 executor 无效：$pauseExecutor"
    }
    if ($ExecutorWasExplicit -and $Executor -cne $pauseExecutor) {
        throw "确认腿 executor 冲突：暂停件要求 $pauseExecutor，显式参数为 $Executor。确认腿必须继承原执行器。"
    }
    $Executor = $pauseExecutor
    if ($Executor -eq 'gateway') {
        $terminalSafetyCodes = @(
            'E_CONFIRM_TIMEOUT', 'E_STALE_REF', 'E_BLOCKED', 'E_CONFIRM_REQUIRED',
            'E_PERM_MISSING', 'E_CHANNEL_DOWN'
        )
        $matchedSafetyCodes = @($terminalSafetyCodes | Where-Object {
            $pauseReport -match "(?<![A-Z0-9_])$([regex]::Escape($_))(?![A-Z0-9_])"
        })
        if ($matchedSafetyCodes.Count -gt 0) {
            $codeList = $matchedSafetyCodes -join ', '
            throw "gateway 暂停件已含 safety 终态（$codeList），拒绝恢复；不得重发危险动作。"
        }
    }

    Write-Host ''
    Write-Host "───── 暂停报告（$Slug · 第 $($Leg - 1) 腿留下）─────"
    Write-Host $pauseReport
    Write-Host '─────────────────────────────────────────────'
    if (-not $DryRun) {
        # 交互硬门（spec §5.2，决策点 3）：必须有人在键盘上打字；
        # 代理经非交互 shell 调用时 Read-Host 直接报错，机械上无法代答。
        $answer = Read-Host '两段式确认门：人工核对暂停报告与手机屏幕后，键入 CONFIRM 执行（其他输入取消）'
        if ($answer -cne 'CONFIRM') { Write-Host '已取消，未执行任何动作。'; exit 3 }
    }

    if ($Executor -eq 'gateway') {
        $TaskText = @"
# 任务：带外暂停后的第二腿（仅获准恢复）

此腿只用于恢复「尚未调用任何危险工具」时发现的纯人工前置条件。现已获人工键盘许可恢复；该许可不替代 gateway 的手机确认卡，也不授权绕过统一硬门。
1. 先核对当前屏幕与下方暂停报告的「屏幕现状」是否一致；不一致则不要执行动作，报失败并说明差异。
2. 若暂停报告表明上一腿已经调用危险工具并得到拒绝、超时、stale、blocked、缺权限或其他 safety 终态，立即报告失败，绝不重发。
3. 只有确认上一腿未调用危险工具时才可继续「待执行动作」；如随后将首次调用危险工具，仍须通过手机确认卡。随后完成「剩余步骤」。

--- 暂停报告 ---
$pauseReport
"@
    }
    else {
        $TaskText = @"
# 任务：两段式第二腿（已获人工确认）

此任务此前在危险动作前暂停，现已获人工键盘确认。手机屏幕应仍停留在暂停时的状态。
1. 先核对当前屏幕与下方暂停报告的「屏幕现状」是否一致；不一致则不要执行动作，报失败并说明差异。
2. 一致则执行「待执行动作」，随后完成「剩余步骤」。

--- 暂停报告 ---
$pauseReport
"@
    }
}
elseif ($TaskFile) {
    if (-not (Test-Path $TaskFile)) { throw "任务卡不存在：$TaskFile" }
    $TaskText = Get-Content $TaskFile -Raw -Encoding utf8
    if (-not $Slug) { $Slug = [IO.Path]::GetFileNameWithoutExtension($TaskFile) }
}
elseif ($Task) {
    $TaskText = $Task
    if (-not $Slug) { $Slug = 'adhoc' }
}
else { throw '需要 -Task / -TaskFile / -Confirm 之一。' }

# ── executor profile + 只读提示词模板 ────────────────────────────────────
$profile = Get-ExecutorProfile -Executor $Executor -RepoRoot $RepoRoot -ScriptsRoot $PSScriptRoot
$PreamblePath = $profile.PreamblePath
$McpConfig = $profile.McpConfigPath
$AllowedTools = $profile.AllowedTools
$preambleTemplate = Get-Content -LiteralPath $PreamblePath -Raw -Encoding utf8
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = "$stamp-$Slug-$Executor-$Brain-leg$Leg"
$TraceFile  = Join-Path $TracesDir "$base.jsonl"
$PromptFile = Join-Path $TracesDir "$base.prompt.md"
$ErrFile    = Join-Path $TracesDir "$base.err.txt"

if ($DryRun) {
    $preamble = $preambleTemplate `
        -replace '\{\{BUDGET_USD\}\}', $MaxBudgetUsd -replace '\{\{DEVICE\}\}', '<dry-run-no-device>'
    $prompt = $preamble + "`n`n" + $TaskText
    Write-Host "[DryRun] executor=$Executor slug=$Slug leg=$Leg model=$Model budget=`$$MaxBudgetUsd timeout=${TimeoutMin}min"
    Write-Host "[DryRun] MCP config：$McpConfig"
    Write-Host "[DryRun] allowed tools：$AllowedTools"
    Write-Host "[DryRun] preamble：$PreamblePath"
    Write-Host "[DryRun] trace 将写入：$TraceFile"
    Write-Host '[DryRun] ───── 组装后的提示词 ─────'
    Write-Host $prompt
    exit 0
}

# ── 预检（零 token，fail-fast；spec §4.2）──────────────────────────────────
# 注：不做 npm registry 探测——国内网络下假阴性比假阳性多；mobile-mcp 版本由
# configs/mobile-mcp.json 锁定，server 启动失败会体现为首轮 fail，代价可忽略。
function Test-Preflight {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { return 'adb 不在 PATH' }
    $stateOutput = @(& adb get-state 2>&1)
    $stateExitCode = $LASTEXITCODE
    $state = "$($stateOutput | Select-Object -Last 1)".Trim()
    if ($stateExitCode -ne 0 -or $state -ne 'device') { return "无已授权设备（adb get-state → $state）" }
    & adb shell input keyevent KEYCODE_WAKEUP *> $null   # 黑屏点亮；已亮无副作用
    if ($LASTEXITCODE -ne 0) { return '设备唤醒失败（adb shell input keyevent）。' }

    if ($profile.RequiresNpx -and -not (Get-Command npx -ErrorAction SilentlyContinue)) {
        return 'npx 不在 PATH'
    }
    if ($profile.RequiresGatewayConfig) {
        $configProblem = Get-GatewayConfigProblem -ConfigPath $profile.McpConfigPath
        if ($configProblem) { return $configProblem }
    }
    if ($profile.RequiresPortForward) {
        & adb forward tcp:8848 tcp:8848 *> $null
        if ($LASTEXITCODE -ne 0) { return 'gateway 端口转发失败（adb forward tcp:8848 tcp:8848）。' }
    }
    return $null
}
$pf = Test-Preflight
if ($pf) {
    Write-Host "预检失败：$pf" -ForegroundColor Red
    Add-LedgerRow 0 0 0 0 0 0 0 'preflight-fail' '' '' $pf
    exit 4
}

$serial = "$(& adb get-serialno 2>$null)".Trim()
if (-not $serial) { $serial = 'unknown' }
$preamble = $preambleTemplate `
    -replace '\{\{BUDGET_USD\}\}', $MaxBudgetUsd -replace '\{\{DEVICE\}\}', $serial
$prompt = $preamble + "`n`n" + $TaskText
New-Item -ItemType Directory -Force -Path $TracesDir | Out-Null

# ── 单机单派锁（spec §4.2）────────────────────────────────────────────────
$lockFs = $null
try {
    try { $lockFs = [IO.File]::Open($LockFile, 'CreateNew', 'Write', 'None') }
    catch { throw "疑似另一次派单进行中（锁 $LockFile 已存在）。确认无并发后手动删除锁文件重试。" }

    # ── 派单 ──────────────────────────────────────────────────────────────
    Set-Content -Path $PromptFile -Value $prompt -Encoding utf8
    $claudeBin = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claudeBin) { throw '找不到 claude 可执行文件。' }

    # 环境卫生：从 Claude 会话内派单时，子进程须按普通 headless 跑，清掉宿主注入的 CLAUDE* 变量。
    # ANTHROPIC_BASE_URL 有意保留——它是回落通道的合法开关（主设计 §5）；派单认证异常时先查它。
    Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE*' } |
        ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }

    $argList = @('-p', '--output-format', 'stream-json', '--verbose',
                 '--mcp-config', $McpConfig, '--strict-mcp-config',
                 '--allowedTools', $AllowedTools,
                 '--max-budget-usd', "$MaxBudgetUsd", '--model', $Model)
    Write-Host "派单：$Slug · 第 $Leg 腿 · $Executor · $Model · ≤`$$MaxBudgetUsd · ≤${TimeoutMin}min ..."
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $claudeBin.Source -ArgumentList $argList -WorkingDirectory $RepoRoot `
        -RedirectStandardInput $PromptFile -RedirectStandardOutput $TraceFile -RedirectStandardError $ErrFile `
        -PassThru -NoNewWindow
    $finished = $proc.WaitForExit($TimeoutMin * 60 * 1000)
    if (-not $finished) { $proc.Kill($true); Start-Sleep -Seconds 1 }
    $sw.Stop()
    $durS = [int][math]::Round($sw.Elapsed.TotalSeconds)

    # ── 解析终态（trace 只尾读，不整读；会话纪律 3）───────────────────────
    $resultEvent = $null
    if (Test-Path $TraceFile) {
        foreach ($line in (Get-Content $TraceFile -Tail 30 -Encoding utf8)) {
            try { $evt = $line | ConvertFrom-Json } catch { continue }
            if ($evt.type -eq 'result') { $resultEvent = $evt }
        }
    }
    $turns = 0; $inTok = 0; $outTok = 0; $cacheRead = 0; $cacheWrite = 0; $cost = 0.0; $sid = ''; $final = ''
    if ($resultEvent) {
        $turns = [int]($resultEvent.num_turns ?? 0)
        $cost = [double]($resultEvent.total_cost_usd ?? 0)
        $sid = "$($resultEvent.session_id)"
        if ($resultEvent.usage) {
            $inTok = [long]($resultEvent.usage.input_tokens ?? 0)
            $outTok = [long]($resultEvent.usage.output_tokens ?? 0)
            $cacheRead = [long]($resultEvent.usage.cache_read_input_tokens ?? 0)
            $cacheWrite = [long]($resultEvent.usage.cache_creation_input_tokens ?? 0)
        }
        if ($resultEvent.result -is [string]) { $final = $resultEvent.result }
    }

    $note = ''
    if (-not $finished) { $verdict = 'timeout'; $note = "超时 ${TimeoutMin}min 被杀" }
    elseif (-not $resultEvent) { $verdict = 'fail'; $note = '无 result 事件，见 err 文件' }
    elseif ("$($resultEvent.subtype)" -match 'budget|max_turns') { $verdict = 'step-cap'; $note = $resultEvent.subtype }
    elseif ("$($resultEvent.subtype)" -ne 'success') { $verdict = 'fail'; $note = $resultEvent.subtype }
    else {
        # 全文按行首匹配（模型偶尔在报告前多说一句话）；暂停标记优先——宁可误暂停交人看，不可漏暂停
        if ($final -match '(?m)^\[AWAIT_CONFIRM\]') { $verdict = 'paused' }
        elseif ($final -match '(?m)^结果：失败') { $verdict = 'fail' }
        elseif ($final -match '(?m)^结果：成功') { $verdict = 'success' }
        else { $verdict = 'success'; $note = '报告未循例' }
    }

    # 上限/超时截断时，从 trace 捞末条 assistant 文本——任务可能已完成、只是报告被截断（④ 实测教训）
    $lastSay = ''
    if (($verdict -in @('step-cap', 'timeout')) -and (Test-Path $TraceFile)) {
        foreach ($line in (Get-Content $TraceFile -Tail 200 -Encoding utf8)) {
            if ($line -notmatch '"type":"assistant"') { continue }
            try { $evt2 = $line | ConvertFrom-Json } catch { continue }
            foreach ($c in $evt2.message.content) { if ($c.type -eq 'text' -and $c.text) { $lastSay = $c.text } }
        }
        if ($lastSay) {
            $flat = $lastSay -replace "\s+", " "
            $note = "$note | 末条报告: " + $flat.Substring(0, [Math]::Min(150, $flat.Length))
        }
    }

    # ── 暂停件（spec §5.1）────────────────────────────────────────────────
    $PauseFile = ''
    if ($verdict -eq 'paused') {
        $PauseFile = Join-Path $TracesDir "$base.pause.md"
        $pauseDoc = "slug: $Slug`nleg: $Leg`nexecutor: $Executor`nsession_id: $sid`ntime: $stamp`ntrace: $base.jsonl`n---`n$final"
        Set-Content -Path $PauseFile -Value $pauseDoc -Encoding utf8
    }

    # ── 台账 + 摘要 ───────────────────────────────────────────────────────
    Add-LedgerRow $turns $inTok $outTok $cacheRead $cacheWrite $cost $durS $verdict $sid "$base.jsonl" $note
    Write-Host ''
    Write-Host "───── 派单结果：$verdict（$Executor · $turns 轮 · `$$([math]::Round($cost, 4)) · ${durS}s）─────"
    if ($final) { Write-Host $final }
    elseif ($lastSay) { Write-Host "（会话被上限截断，以下为末条 assistant 报告）`n$lastSay" }
    if ($note) { Write-Host "note: $note" }
    if ($verdict -eq 'paused') {
        Write-Host ''
        Write-Host '>>> 危险动作已暂停，手机屏幕停在原地。人工核对后运行：' -ForegroundColor Yellow
        Write-Host ">>>   scripts/dispatch.ps1 -Confirm `"$PauseFile`"" -ForegroundColor Yellow
    }
    Write-Host "trace: $TraceFile"
    if ($verdict -in @('success', 'paused')) { exit 0 } else { exit 1 }
}
finally {
    if ($lockFs) { $lockFs.Close(); Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }
}
