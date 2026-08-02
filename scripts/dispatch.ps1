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
$ProfileHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-profile.ps1'
. $ProfileHelperPath
$LockHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-lock.ps1'
. $LockHelperPath
$LedgerHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-ledger.ps1'
. $LedgerHelperPath
$PauseHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-pause.ps1'
. $PauseHelperPath


function Add-LedgerRow([int]$Turns, [long]$InTok, [long]$OutTok, [long]$CacheRead, [long]$CacheWrite,
                       [double]$CostUsd, [int]$DurS, [string]$Result, [string]$SessionId, [string]$Trace,
                       [string]$Note, [string]$FailReason = '') {
    # 表头与拼行都在 dispatch-ledger.ps1：runner 也要写台账（派单被提前掐掉那种），
    # 各写各的必然漂移，而台账列的语义漂移正是归因失效的开始。
    $noteWithExecutor = if ([string]::IsNullOrWhiteSpace($Note)) { "executor=$Executor" } else { "executor=$Executor | $Note" }
    Add-P0LedgerRow -LedgerPath $LedgerPath -Slug $Slug -Leg $Leg -Brain $Brain -Model $Model `
        -Result $Result -Turns "$Turns" -InTok "$InTok" -OutTok "$OutTok" `
        -CacheRead "$CacheRead" -CacheWrite "$CacheWrite" -CostUsd "$([math]::Round($CostUsd, 4))" `
        -DurS "$DurS" -SessionId $SessionId -TraceFile $Trace -Note $noteWithExecutor -FailReason $FailReason
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
    $pauseDocument = Read-DispatchPauseDocument -Text $pauseRaw
    $meta = $pauseDocument.Meta

    # 暂停件是"人在键盘上按过一次 CONFIRM"的凭据，与手机确认卡同属**一次性授权**
    # （硬门不变量 4：一次确认只授权当前这一次调用，不生成可重放令牌）。而落盘的文件天然
    # 可重放：同一份 -Confirm 跑两次就是两次执行，人却只点过一次头。所以消费即作废。
    if ($pauseDocument.Consumed) {
        throw "暂停件已于 $($pauseDocument.Consumed) 被消费，拒绝重放：$Confirm`n" +
            '一次人工确认只授权一次执行。要再跑一次就重跑第一腿，重新走一遍两段式。'
    }

    $Slug = [string]$(if ($meta.Contains('slug')) { $meta['slug'] } else { '' })
    # leg 直接进 trace 文件名与台账，且**没有上界的话，pause→confirm 可以无限接龙**，
    # 每一跳还把上一跳的报告原样再灌进提示词。两段式按定义只有第二腿。
    if ([string]$meta['leg'] -notmatch '^\d+$') { throw "暂停件 leg 非法：$($meta['leg'])" }
    $Leg = [int]$meta['leg'] + 1
    if ($Leg -gt 2) {
        throw "暂停件 leg=$($meta['leg']) 会产生第 $Leg 腿；两段式只有第二腿，拒绝接龙。"
    }
    $pauseReport = $pauseDocument.Body
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
        # 就地作废：写在**人点头之后、派单之前**。派单失败也不回滚——那次授权已经用掉了，
        # 想再来一次就得有一次新的人工决定。取消（非 CONFIRM）不作废，因为什么都没执行。
        # 不改名、只加一行 meta：路径可能已经被人复制到别处，改名会让那些引用凭空失效。
        Set-Content -LiteralPath $Confirm -Encoding utf8 -Value (
            Set-DispatchPauseConsumed -Text $pauseRaw -At ([DateTime]::UtcNow.ToString('o'))
        )
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

# slug 直接拼进 trace/pause 文件名（$base）与台账行。四个来源里有两个不是本机人手打的：
# 暂停件的 meta 与任务卡文件名。带上路径分隔符或 .. 就能把 trace 写到 docs/runs 之外，
# 而台账的 trace_file 列正是跑测判据的锚点（runner 已为此单独校验过一次文件名）。
if ($Slug -notmatch '^[A-Za-z0-9._-]{1,80}$' -or $Slug -match '\.\.') {
    throw "slug 非法（只允许字母数字与 . _ -，且不含 ..，长度 1..80）：$Slug"
}

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
    Add-LedgerRow 0 0 0 0 0 0 0 'preflight-fail' '' '' $pf 'preflight'
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
    $lockFs = Open-DispatchLock -Path $LockFile -Owner "$Slug/leg$Leg/$Executor"

    # ── 派单 ──────────────────────────────────────────────────────────────
    Set-Content -Path $PromptFile -Value $prompt -Encoding utf8
    $claudeBin = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claudeBin) { throw '找不到 claude 可执行文件。' }

    # 环境卫生：从 Claude 会话内派单时，子进程须按普通 headless 跑，清掉宿主注入的 CLAUDE* 变量。
    # ANTHROPIC_BASE_URL 有意保留——它是回落通道的合法开关（主设计 §5）；派单认证异常时先查它。
    Get-ChildItem Env: | Where-Object { $_.Name -like 'CLAUDE*' } |
        ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }

    # --allowedTools 只是"免确认"名单，不阻止别的工具（2026-07-26 实测执行器在派单里
    # 真的跑起了本机 Bash）。执行器的职责只有驱动手机，本机 shell / 文件 / 网络一律拒绝：
    # 仓库里就放着 gateway 私密 token，让它能读本机文件等于给证据脱敏链开后门。
    # ToolSearch 不在此列——延迟注册的 MCP 工具要靠它加载 schema，禁掉 gateway 工具就没法调。
    #
    # **这份名单是"枚举已知工具"，天生会漏——两次真机事故都栽在漏项上：**
    # · 2026-07-26 ToolSearch 被 trace 审计当成越权（那次是白名单漏）；
    # · 2026-07-31 执行器调了 ReportFindings，Allow 腿在真人已点允许、危险动作已执行之后
    #   被判死，白烧一轮真机。
    # 同一轮复查还发现 **PowerShell 一直没被禁**：注释说"本机 shell 一律拒绝"，实际只禁了
    # Bash，而本机是 Windows——执行器手里很可能一直握着一个等价的本机 shell。
    # 所以除了补齐漏项，下面按类分组列出，加新工具时对着组补，别再一条条追。
    $LocalToolDenyList = @(
        # 本机 shell（Bash 与 PowerShell 等价，漏一个等于没禁）
        'Bash', 'BashOutput', 'KillShell', 'PowerShell',
        # 本机文件与检索
        'Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Glob', 'Grep',
        # 网络
        'WebFetch', 'WebSearch',
        # 派生执行体（会绕开本名单）
        'Task', 'Agent', 'Workflow', 'SendMessage', 'TaskCreate', 'TaskUpdate',
        'TaskGet', 'TaskList', 'TaskOutput', 'TaskStop',
        # 汇报 / 交互 / 调度类：对驱动手机毫无用处，出现即污染 trace 审计
        'ReportFindings', 'TodoWrite', 'AskUserQuestion', 'ExitPlanMode', 'EnterPlanMode',
        'SlashCommand', 'Skill', 'Artifact', 'SendUserFile', 'Monitor', 'PushNotification',
        'ScheduleWakeup', 'CronCreate', 'CronDelete', 'CronList', 'RemoteTrigger',
        'EnterWorktree', 'ExitWorktree', 'DesignSync'
    ) -join ','
    $argList = @('-p', '--output-format', 'stream-json', '--verbose',
                 '--mcp-config', $McpConfig, '--strict-mcp-config',
                 '--allowedTools', $AllowedTools,
                 '--disallowedTools', $LocalToolDenyList,
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
        # 全文按行首匹配（模型偶尔在报告前多说一句话）；暂停标记优先——宁可误暂停交人看，不可漏暂停。
        #
        # **必须容忍 markdown 强调**：模型很自然会写 `**结果：失败**`。旧模式只认裸行首，于是
        # 失败与成功两条都不匹配，一路落到 else —— **把一次失败的危险动作记成 success**。
        # 2026-07-31 真机实锤（那轮台账 note 写着"报告未循例"，正是同一根因的良性表现）。
        if ($final -match $script:P0AwaitConfirmPattern) { $verdict = 'paused' }
        elseif ($final -match (Get-P0FinalVerdictPattern '失败')) { $verdict = 'fail' }
        elseif ($final -match (Get-P0FinalVerdictPattern '成功')) { $verdict = 'success' }
        # **兜底绝不能是 success。** 上面那条注释记的是"模式漏了 markdown 强调"，可真正让
        # 一次失败被记成成功的是**这一行**：三条都不匹配时旧代码直接判 success。
        # 2026-08-02 又撞一次（这回是反引号）——runner 判整腿死，dispatch 对同一段文字记 success，
        # 两个组件结论相反。模式可以继续补，但"判不了"永远补不完；判不了就说判不了。
        else { $verdict = 'unparsed'; $note = '报告未循例，无法判定成败' }
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
    $failReason = Get-FailReason -Verdict $verdict -Subtype "$($resultEvent.subtype)" -TraceFile $TraceFile
    Add-LedgerRow $turns $inTok $outTok $cacheRead $cacheWrite $cost $durS $verdict $sid "$base.jsonl" $note $failReason
    Write-Host ''
    Write-Host "───── 派单结果：$verdict（$Executor · $turns 轮 · `$$([math]::Round($cost, 4)) · ${durS}s）─────"
    if ($final) { Write-Host $final }
    elseif ($lastSay) { Write-Host "（会话被上限截断，以下为末条 assistant 报告）`n$lastSay" }
    if ($note) { Write-Host "note: $note" }
    if ($failReason) { Write-Host "fail_reason: $failReason" }
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
