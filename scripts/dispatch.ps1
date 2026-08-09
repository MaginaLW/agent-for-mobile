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

# `WaitForExit(Int32)` 的毫秒参数有界；越界若拖到子进程启动后才抛，会留下脱管执行器。
# 因此必须早于 profile/任务装配、设备 lease 与任何 adb/claude 子进程 fail-fast。
if ($TimeoutMin -lt 1 -or $TimeoutMin -gt 60) {
    throw 'TimeoutMin 必须为 1..60。'
}

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

# Confirm 的 pause/trace 读取发生在设备预检之前；固定 traces 容器必须先做 no-follow
# 验证。允许目录缺失仅为普通新派单保留，真正写入会在拿到 lease 后创建并重验。
[void](Resolve-DispatchSafePersistentPath -Path $TracesDir -ExpectedRoot $TracesDir `
    -BoundaryRoot $RepoRoot -PathKind Container -AllowMissing)

function Add-LedgerRow([int]$Turns, [long]$InTok, [long]$OutTok, [long]$CacheRead, [long]$CacheWrite,
                       [double]$CostUsd, [int]$DurS, [string]$Result, [string]$SessionId, [string]$Trace,
                       [string]$Note, [string]$FailReason = '') {
    # 表头与拼行都在 dispatch-ledger.ps1：runner 也要写台账（派单被提前掐掉那种），
    # 各写各的必然漂移，而台账列的语义漂移正是归因失效的开始。
    $noteWithExecutor = if ([string]::IsNullOrWhiteSpace($Note)) { "executor=$Executor" } else { "executor=$Executor | $Note" }
    $ledgerRoot = Split-Path $LedgerPath -Parent
    $safeLedger = Resolve-DispatchSafePersistentPath -Path $LedgerPath -ExpectedRoot $ledgerRoot `
        -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
    Add-P0LedgerRow -LedgerPath $safeLedger -Slug $Slug -Leg $Leg -Brain $Brain -Model $Model `
        -Result $Result -Turns "$Turns" -InTok "$InTok" -OutTok "$OutTok" `
        -CacheRead "$CacheRead" -CacheWrite "$CacheWrite" -CostUsd "$([math]::Round($CostUsd, 4))" `
        -DurS "$DurS" -SessionId $SessionId -TraceFile $Trace -Note $noteWithExecutor -FailReason $FailReason
    [void](Resolve-DispatchSafePersistentPath -Path $safeLedger -ExpectedRoot $ledgerRoot `
        -BoundaryRoot $RepoRoot -PathKind Leaf)
}

function Test-DispatchHumanConfirmationConsole {
    # Read-Host 只负责读字符，不证明字符来自现场人；`echo CONFIRM | pwsh ...` 同样能喂进去。
    # 身份门先要求真实交互 ConsoleHost，任何判不清的宿主都 fail closed。
    try {
        return [Environment]::UserInteractive -and
            $Host.Name -ceq 'ConsoleHost' -and
            -not [Console]::IsInputRedirected
    }
    catch { return $false }
}

function Get-GatewayPauseTraceProof {
    param(
        [Parameter(Mandatory)][string]$TraceName,
        [Parameter(Mandatory)][string]$ExpectedSlug,
        [Parameter(Mandatory)][int]$ExpectedLeg,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedSessionId,
        [Parameter(Mandatory)][string]$ExpectedPauseBody
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedSessionId)) {
        throw 'gateway 暂停件 session_id 不能为空，无法形成 trace 正向关联。'
    }

    # pause 里的 trace 只当索引：必须是固定 traces 目录下的 basename，不能让可编辑 pause
    # 把校验器指到任意文件。文件名同时绑定 slug/executor/brain/leg。
    if ([string]::IsNullOrWhiteSpace($TraceName) -or
        [IO.Path]::GetFileName($TraceName) -cne $TraceName -or
        [IO.Path]::IsPathRooted($TraceName)) {
        throw 'gateway 暂停件缺少合法的 trace basename，无法证明危险工具尚未调用。'
    }
    $expectedPattern = '^\d{8}-\d{6}-' + [regex]::Escape($ExpectedSlug) +
        '-gateway-claude-leg' + $ExpectedLeg + '\.jsonl$'
    if ($TraceName -notmatch $expectedPattern) {
        throw 'gateway 暂停件的 trace 与 slug/executor/brain/leg 不关联，拒绝恢复。'
    }
    $tracePath = Resolve-DispatchSafePersistentPath -Path (Join-Path $TracesDir $TraceName) `
        -ExpectedRoot $TracesDir -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
    if (-not (Test-Path -LiteralPath $tracePath -PathType Leaf)) {
        throw 'gateway 暂停件引用的固定目录 trace 不存在，无法证明危险工具尚未调用。'
    }
    $tracePath = Resolve-DispatchSafePersistentPath -Path $tracePath -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf

    # 这是正向、fail-closed 的证明集合：仅接受 ToolRegistry 中明确的 R 级只读工具；
    # 未知/新增工具默认拒绝，而不是靠一张会漏项的 safety code denylist 猜危险调用发生过没有。
    $readOnlyGatewayTools = [Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'device_info','system_get_state','system_verify_state','foreground_app','keyboard_state',
            'media_query','notifications_list','ui_snapshot','ui_diff','ui_find','wait_for','screen_capture'
        ), [StringComparer]::Ordinal)
    $infrastructureTools = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('ToolSearch'), [StringComparer]::Ordinal)
    $toolUses = [Collections.Generic.List[object]]::new()
    $resultCounts = @{}
    $infrastructureIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $resultEvents = [Collections.Generic.List[object]]::new()

    foreach ($line in Get-Content -LiteralPath $tracePath -Encoding utf8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json -Depth 30 }
        catch { throw 'gateway trace 含无法解析的非空 JSON 行，无法形成正向证明。' }
        if ($event.type -eq 'assistant') {
            foreach ($content in @($event.message.content)) {
                if ($content.type -ne 'tool_use') { continue }
                $id = [string]$content.id
                $rawName = [string]$content.name
                if ([string]::IsNullOrWhiteSpace($id) -or -not $seenIds.Add($id)) {
                    throw 'gateway trace 的 tool_use id 缺失或重复，无法形成正向证明。'
                }
                if ($infrastructureTools.Contains($rawName)) {
                    [void]$infrastructureIds.Add($id)
                    $toolUses.Add([pscustomobject]@{ Id=$id; Name=$rawName; Infrastructure=$true })
                    continue
                }
                $nameMatch = [regex]::Match($rawName, '^mcp__gateway__(.+)$')
                if (-not $nameMatch.Success) {
                    throw "gateway trace 含非 gateway 工具调用（$rawName），拒绝恢复。"
                }
                $name = $nameMatch.Groups[1].Value
                if (-not $readOnlyGatewayTools.Contains($name)) {
                    throw "gateway trace 不能正向证明工具 $name 为只读；危险或未知工具可能已经调用，拒绝恢复。"
                }
                if ($name -ceq 'ui_find') {
                    $scrollProperty = $content.input.PSObject.Properties['scroll_search']
                    if ($null -ne $scrollProperty -and $scrollProperty.Value -eq $true) {
                        throw 'gateway trace 的 ui_find 启用了 scroll_search，不属于纯只读暂停证据。'
                    }
                }
                $toolUses.Add([pscustomobject]@{ Id=$id; Name=$name; Infrastructure=$false })
            }
        }
        elseif ($event.type -eq 'user') {
            foreach ($content in @($event.message.content)) {
                if ($content.type -ne 'tool_result') { continue }
                $id = [string]$content.tool_use_id
                if ([string]::IsNullOrWhiteSpace($id) -or -not $seenIds.Contains($id)) {
                    throw 'gateway trace 含孤儿 tool_result，无法形成正向证明。'
                }
                if (-not $resultCounts.ContainsKey($id)) { $resultCounts[$id] = 0 }
                $resultCounts[$id] = [int]$resultCounts[$id] + 1
                if (-not $infrastructureIds.Contains($id)) {
                    $texts = @($content.content | Where-Object { $_.type -eq 'text' -and $_.text -is [string] })
                    if ($texts.Count -ne 1) { throw 'gateway trace 含无法唯一解析的 tool_result。' }
                    try { $null = $texts[0].text | ConvertFrom-Json -Depth 30 }
                    catch { throw 'gateway trace 的 gateway tool_result 不是结构化信封。' }
                }
            }
        }
        elseif ($event.type -eq 'result') {
            $resultEvents.Add($event)
        }
    }

    foreach ($call in $toolUses) {
        if (-not $resultCounts.ContainsKey($call.Id) -or [int]$resultCounts[$call.Id] -ne 1) {
            throw "gateway trace 的 $($call.Name) 没有唯一结构化结果，无法形成正向证明。"
        }
    }
    if ($resultEvents.Count -ne 1) { throw 'gateway trace 必须恰有一个 result 终态。' }
    $terminal = $resultEvents[0]
    $terminalSessionId = [string]$terminal.session_id
    if ([string]::IsNullOrWhiteSpace($terminalSessionId)) {
        throw 'gateway trace terminal session_id 不能为空，无法形成暂停件关联。'
    }
    if ([string]$terminal.subtype -cne 'success' -or $terminalSessionId -cne $ExpectedSessionId -or
        -not ($terminal.result -is [string])) {
        throw 'gateway trace 的 result subtype/session 与暂停件不关联，拒绝恢复。'
    }
    $traceBody = ([string]$terminal.result -replace "`r`n", "`n").Trim()
    $pauseBody = ($ExpectedPauseBody -replace "`r`n", "`n").Trim()
    if ($traceBody -cne $pauseBody -or $traceBody -notmatch $script:P0AwaitConfirmPattern) {
        throw 'gateway trace 终态与暂停正文不一致，拒绝恢复。'
    }
    return [pscustomobject]@{
        TraceName = $TraceName
        ReadOnlyGatewayCalls = @($toolUses | Where-Object { -not $_.Infrastructure }).Count
        EvidenceVersion = 'readonly-trace-v1'
    }
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
    # 生产暂停件只由本 wrapper 落在固定 traces 根。禁止“任意 parent 自证安全”：若更高层
    # ancestor 是 junction，Get-Item(direct parent) 会看到目标内普通目录并漏过。锚定 RepoRoot
    # 后逐级检查所有 ancestor，且 pause 必须是 traces 的 direct leaf。
    $Confirm = Resolve-DispatchSafePersistentPath -Path $Confirm -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
    if (-not (Test-Path -LiteralPath $Confirm -PathType Leaf)) { throw "暂停件不存在：$Confirm" }
    $Confirm = Resolve-DispatchSafePersistentPath -Path $Confirm -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf
    $pauseRaw = Get-Content -LiteralPath $Confirm -Raw -Encoding utf8
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
        $traceName = [string]$(if ($meta.Contains('trace')) { $meta['trace'] } else { '' })
        try {
            $null = Get-GatewayPauseTraceProof -TraceName $traceName -ExpectedSlug $Slug `
                -ExpectedLeg ([int]$meta['leg']) -ExpectedSessionId ([string]$meta['session_id']) `
                -ExpectedPauseBody $pauseReport
        }
        catch {
            throw "gateway 暂停件缺少『危险工具尚未调用』的结构化 trace 正向证明，拒绝恢复：$($_.Exception.Message)"
        }
    }

    if (-not $DryRun -and -not (Test-DispatchHumanConfirmationConsole)) {
        throw ('两段式确认门要求现场人在真实交互终端键入 CONFIRM；当前 stdin 已重定向或宿主非交互，' +
            '拒绝读取、拒绝消费暂停件，也不会启动任何子进程。')
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
        $Confirm = Resolve-DispatchSafePersistentPath -Path $Confirm -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf
        Set-Content -LiteralPath $Confirm -Encoding utf8 -Value (
            Set-DispatchPauseConsumed -Text $pauseRaw -At ([DateTime]::UtcNow.ToString('o'))
        )
        [void](Resolve-DispatchSafePersistentPath -Path $Confirm -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf)
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
$PauseCandidateFile = Join-Path $TracesDir "$base.pause.md"

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

# Job Object 把 claude/MCP/任何后代变成一个可机械收口的生命周期单位。
# wrapper 在 named gate 上等待；父进程先 Assign，再 signal，消除“子进程出生后、入 Job 前”派生逃逸竞态。
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class AgentMobileDispatchJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose(string name) {
        IntPtr job = CreateJobObject(IntPtr.Zero, name);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref info,
            (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error);
        }
        return job;
    }

    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Terminate(IntPtr job) {
        if (!TerminateJobObject(job, 1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static bool WaitEmpty(IntPtr job, uint milliseconds) {
        uint result = WaitForSingleObject(job, milliseconds);
        if (result == 0) return true;
        if (result == 0x00000102) return false;
        throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero && !CloseHandle(job)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@

function Start-DispatchJobRoot {
    param(
        [Parameter(Mandatory)][IntPtr]$JobHandle,
        [Parameter(Mandatory)][string]$ClaudePath,
        [Parameter(Mandatory)][string[]]$ClaudeArguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$ErrorPath,
        [Parameter(Mandatory)][string]$JobName
    )

    $gateName = "Local\AgentMobileDispatch-$PID-$([guid]::NewGuid().ToString('N'))"
    $createdNew = $false
    $gate = [Threading.EventWaitHandle]::new(
        $false, [Threading.EventResetMode]::ManualReset, $gateName, [ref]$createdNew)
    if (-not $createdNew) {
        $gate.Dispose()
        throw '无法建立 dispatch 启动 gate。'
    }
    $payload = [ordered]@{
        claude = $ClaudePath
        arguments = @($ClaudeArguments)
        working_directory = $WorkingDirectory
        prompt = $PromptPath
        trace = $TracePath
        error = $ErrorPath
        job_name = $JobName
    } | ConvertTo-Json -Compress -Depth 4
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $wrapper = @'
$ErrorActionPreference = 'Stop'
$gate = [Threading.EventWaitHandle]::OpenExisting($env:AGENT_MOBILE_DISPATCH_GATE)
try {
    if (-not $gate.WaitOne(30000)) { throw 'dispatch launch gate timeout' }
}
finally { $gate.Dispose() }
$payload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:AGENT_MOBILE_DISPATCH_PAYLOAD)) | ConvertFrom-Json
Remove-Item Env:AGENT_MOBILE_DISPATCH_GATE -ErrorAction SilentlyContinue
Remove-Item Env:AGENT_MOBILE_DISPATCH_PAYLOAD -ErrorAction SilentlyContinue
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class AgentMobileDispatchSuspendedChild {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
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
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share,
        ref SECURITY_ATTRIBUTES security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startup,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inheritHandle, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new [] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    public static int Run(string executable, string[] arguments, string workingDirectory,
        string stdinPath, string stdoutPath, string stderrPath, string jobName) {
        SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
        security.nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>();
        security.bInheritHandle = true;
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint OPEN_EXISTING = 3;
        const uint CREATE_ALWAYS = 2;
        IntPtr input = CreateFile(stdinPath, GENERIC_READ, FILE_SHARE_READ, ref security,
            OPEN_EXISTING, 0, IntPtr.Zero);
        IntPtr output = CreateFile(stdoutPath, GENERIC_WRITE, FILE_SHARE_READ, ref security,
            CREATE_ALWAYS, 0, IntPtr.Zero);
        IntPtr error = CreateFile(stderrPath, GENERIC_WRITE, FILE_SHARE_READ, ref security,
            CREATE_ALWAYS, 0, IntPtr.Zero);
        IntPtr invalid = new IntPtr(-1);
        if (input == invalid || output == invalid || error == invalid) {
            int openError = Marshal.GetLastWin32Error();
            if (input != invalid) CloseHandle(input);
            if (output != invalid) CloseHandle(output);
            if (error != invalid) CloseHandle(error);
            throw new Win32Exception(openError);
        }
        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        try {
            const uint JOB_OBJECT_ASSIGN_PROCESS = 0x0001;
            const uint JOB_OBJECT_QUERY = 0x0004;
            job = OpenJobObject(JOB_OBJECT_ASSIGN_PROCESS | JOB_OBJECT_QUERY, false, jobName);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            string application = executable;
            List<string> commandArguments = new List<string>(arguments);
            string extension = System.IO.Path.GetExtension(executable);
            StringBuilder commandLine;
            if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".bat", StringComparison.OrdinalIgnoreCase)) {
                application = Environment.GetEnvironmentVariable("ComSpec");
                StringBuilder inner = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) inner.Append(' ').Append(Quote(argument));
                commandLine = new StringBuilder(Quote(application) + " /d /s /c \"" + inner + "\"");
            } else {
                commandLine = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) commandLine.Append(' ').Append(Quote(argument));
            }

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf<STARTUPINFO>();
            startup.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
            startup.hStdInput = input;
            startup.hStdOutput = output;
            startup.hStdError = error;
            const uint CREATE_SUSPENDED = 0x00000004;
            const uint CREATE_NO_WINDOW = 0x08000000;
            if (!CreateProcess(application, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero, workingDirectory,
                ref startup, out process)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            bool inTargetJob;
            if (!IsProcessInJob(process.hProcess, job, out inTargetJob)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            // wrapper 已在目标 Job 中，Windows 默认会在 CreateProcess 时把 child 原子地加入
            // immediate job/job chain；同 Job 二次 Assign 反而可能 ACCESS_DENIED。
            if (!inTargetJob) {
                if (!AssignProcessToJobObject(job, process.hProcess)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (!IsProcessInJob(process.hProcess, job, out inTargetJob) || !inTargetJob) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            // membership 已机械确认后，wrapper 不再需要自己的 Job handle。必须在 Resume 前
            // 关闭它：否则 dispatch owner 被硬杀时这会成为“最后一个 handle”，KILL_ON_JOB_CLOSE
            // 不触发，wrapper/Claude/MCP 全部脱管且根 lease 已释放。
            if (!CloseHandle(job)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            job = IntPtr.Zero;
            if (ResumeThread(process.hThread) == 0xffffffff) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (WaitForSingleObject(process.hProcess, 0xffffffff) != 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            uint exitCode;
            if (!GetExitCodeProcess(process.hProcess, out exitCode)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return unchecked((int)exitCode);
        } catch {
            // Resume 前任一步失败都必须原地杀掉 suspended child；只 CloseHandle 会留下孤儿。
            if (process.hProcess != IntPtr.Zero) {
                TerminateProcess(process.hProcess, 1);
                WaitForSingleObject(process.hProcess, 5000);
            }
            throw;
        } finally {
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
            CloseHandle(input);
            CloseHandle(output);
            CloseHandle(error);
        }
    }
}
"@
$childExit = [AgentMobileDispatchSuspendedChild]::Run(
    [string]$payload.claude, [string[]]@($payload.arguments),
    [string]$payload.working_directory, [string]$payload.prompt,
    [string]$payload.trace, [string]$payload.error, [string]$payload.job_name)
exit $childExit
'@
    $wrapperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Process -Id $PID).Path
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-EncodedCommand')
    $start.ArgumentList.Add($wrapperEncoded)
    $start.Environment['AGENT_MOBILE_DISPATCH_GATE'] = $gateName
    $start.Environment['AGENT_MOBILE_DISPATCH_PAYLOAD'] = $payloadBase64
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    try {
        if (-not $process.Start()) { throw 'dispatch gate wrapper 启动失败。' }
        $started = $true
        # wrapper 此时只能 WaitOne；Assign 成功之前没有任何路径能启动 claude/MCP。
        [AgentMobileDispatchJob]::Assign($JobHandle, $process.Handle)
        if (-not $gate.Set()) { throw 'dispatch 启动 gate 放行失败。' }
        return [pscustomobject]@{ Process = $process; Gate = $gate }
    }
    catch {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
        }
        finally {
            $gate.Dispose()
            $process.Dispose()
        }
        throw
    }
}

function Stop-DispatchJobProcesses {
    param([Parameter(Mandatory)][IntPtr]$JobHandle)
    [AgentMobileDispatchJob]::Terminate($JobHandle)
    if (-not [AgentMobileDispatchJob]::WaitEmpty($JobHandle, 15000)) {
        # 再发一次不是“最好努力”：第二次后仍不归零就抛，调用方不得走显式 lease release。
        [AgentMobileDispatchJob]::Terminate($JobHandle)
        if (-not [AgentMobileDispatchJob]::WaitEmpty($JobHandle, 15000)) {
            throw 'dispatch Job 终止后仍有设备执行后代存活。'
        }
    }
}

# ── 设备级 lease ──────────────────────────────────────────────────────────
# 必须早于任何 adb 预检：否则普通 dispatch 虽最终拿不到锁，仍能在 runner provision / 腿间 /
# teardown 期间点亮屏幕或改端口转发。runner 子 dispatch 用一次性 owner token 只读加入同一 lease。
$lockFs = $null
$proc = $null
$dispatchJobHandle = [IntPtr]::Zero
$dispatchJobName = ''
$dispatchJobGate = $null
$dispatchJobDrained = $false
try {
    $leaseOwnerToken = [string]$env:AGENT_MOBILE_DEVICE_LEASE_TOKEN
    try {
        if ([string]::IsNullOrWhiteSpace($leaseOwnerToken)) {
            $lockFs = Open-DispatchLock -Path $LockFile -Owner "$Slug/leg$Leg/$Executor"
        }
        else {
            $lockFs = Open-DispatchLock -Path $LockFile -Owner "$Slug/leg$Leg/$Executor" `
                -LeaseOwnerToken $leaseOwnerToken -InheritLease
        }
    }
    finally {
        # token 只用于加入 lease；不能继续继承给大脑进程或 MCP server。
        Remove-Item Env:AGENT_MOBILE_DEVICE_LEASE_TOKEN -ErrorAction SilentlyContinue
        $leaseOwnerToken = $null
    }

    # lease 内、任何 adb/claude/ledger 首用之前重新验证固定持久面。缺失 traces 只在验证后
    # 创建，并立即 post-verify；所有本轮可能写入的 sidecar（包括仅 paused 时才写的文件）
    # 也预先拒绝 direct leaf link/hardlink。
    [void](Resolve-DispatchSafePersistentPath -Path $TracesDir -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Container -AllowMissing)
    if (-not (Test-Path -LiteralPath $TracesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $TracesDir -Force | Out-Null
    }
    [void](Resolve-DispatchSafePersistentPath -Path $TracesDir -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Container)
    $ledgerRoot = Split-Path $LedgerPath -Parent
    [void](Resolve-DispatchSafePersistentPath -Path $LedgerPath -ExpectedRoot $ledgerRoot `
        -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing)
    foreach ($artifactPath in @($TraceFile,$PromptFile,$ErrFile,$PauseCandidateFile)) {
        [void](Resolve-DispatchSafePersistentPath -Path $artifactPath -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing)
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

    # ── 派单 ──────────────────────────────────────────────────────────────
    $PromptFile = Resolve-DispatchSafePersistentPath -Path $PromptFile -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
    Set-Content -LiteralPath $PromptFile -Value $prompt -Encoding utf8
    [void](Resolve-DispatchSafePersistentPath -Path $PromptFile -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf)
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
    $dispatchJobName = "AgentMobileDispatchJob-$PID-$([guid]::NewGuid().ToString('N'))"
    $dispatchJobHandle = [AgentMobileDispatchJob]::CreateKillOnClose($dispatchJobName)
    $jobRoot = Start-DispatchJobRoot -JobHandle $dispatchJobHandle -ClaudePath $claudeBin.Source `
        -ClaudeArguments $argList -WorkingDirectory $RepoRoot -PromptPath $PromptFile `
        -TracePath $TraceFile -ErrorPath $ErrFile -JobName $dispatchJobName
    $proc = $jobRoot.Process
    $dispatchJobGate = $jobRoot.Gate
    $finished = $proc.WaitForExit($TimeoutMin * 60 * 1000)
    # 根进程退出不代表 MCP/孙进程退出；终态解析前先终止并等待 Job 归零。
    Stop-DispatchJobProcesses -JobHandle $dispatchJobHandle
    $dispatchJobDrained = $true
    $sw.Stop()
    $durS = [int][math]::Round($sw.Elapsed.TotalSeconds)

    foreach ($completedArtifact in @($PromptFile,$ErrFile)) {
        $completedArtifact = Resolve-DispatchSafePersistentPath -Path $completedArtifact `
            -ExpectedRoot $TracesDir -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
        if (Test-Path -LiteralPath $completedArtifact -PathType Leaf) {
            [void](Resolve-DispatchSafePersistentPath -Path $completedArtifact -ExpectedRoot $TracesDir `
                -BoundaryRoot $RepoRoot -PathKind Leaf)
        }
    }

    # ── 解析终态（trace 只尾读，不整读；会话纪律 3）───────────────────────
    $resultEvent = $null
    $TraceFile = Resolve-DispatchSafePersistentPath -Path $TraceFile -ExpectedRoot $TracesDir `
        -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
    if (Test-Path -LiteralPath $TraceFile -PathType Leaf) {
        $TraceFile = Resolve-DispatchSafePersistentPath -Path $TraceFile -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf
        foreach ($line in (Get-Content -LiteralPath $TraceFile -Tail 30 -Encoding utf8)) {
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
    $gatewayPauseProof = $null
    if ($verdict -eq 'paused' -and $Executor -eq 'gateway') {
        try {
            $gatewayPauseProof = Get-GatewayPauseTraceProof -TraceName "$base.jsonl" `
                -ExpectedSlug $Slug -ExpectedLeg $Leg -ExpectedSessionId $sid -ExpectedPauseBody $final
        }
        catch {
            # 模型把危险调用后的 safety 终态包装成 AWAIT 时，不能先落一个可恢复暂停件再靠
            # -Confirm 补救；生产写入点本身就 fail closed。
            $verdict = 'fail'
            $note = "gateway 暂停拒绝：$($_.Exception.Message)"
        }
    }
    if ($verdict -eq 'paused') {
        $PauseFile = Resolve-DispatchSafePersistentPath -Path $PauseCandidateFile -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf -AllowMissing
        $proofMeta = if ($null -eq $gatewayPauseProof) { '' } else {
            "gateway_pause_evidence: $($gatewayPauseProof.EvidenceVersion)`n" +
                "gateway_readonly_calls: $($gatewayPauseProof.ReadOnlyGatewayCalls)`n"
        }
        $pauseDoc = "slug: $Slug`nleg: $Leg`nexecutor: $Executor`nsession_id: $sid`ntime: $stamp`n" +
            "trace: $base.jsonl`n$proofMeta---`n$final"
        Set-Content -LiteralPath $PauseFile -Value $pauseDoc -Encoding utf8
        [void](Resolve-DispatchSafePersistentPath -Path $PauseFile -ExpectedRoot $TracesDir `
            -BoundaryRoot $RepoRoot -PathKind Leaf)
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
    # 任何启动后异常（trace/ledger/暂停件写入也包括）都必须回收完整进程树。嵌套 finally
    # 保证 Kill 自身报错时仍会释放句柄与设备 lease，而不是用清理失败制造永久活锁。
    $treeCleanupFailure = $null
    try {
        if ($dispatchJobHandle -ne [IntPtr]::Zero -and -not $dispatchJobDrained) {
            Stop-DispatchJobProcesses -JobHandle $dispatchJobHandle
            $dispatchJobDrained = $true
        }
    }
    catch { $treeCleanupFailure = $_ }
    finally {
        if ($null -ne $dispatchJobGate) { $dispatchJobGate.Dispose() }
        if ($null -ne $proc) { $proc.Dispose() }
    }

    # 只有 Job 已被机械确认清空，才显式关闭 Job 与设备 lease。失败时保留两者到进程退出，
    # KILL_ON_JOB_CLOSE 仍是内核兜底；绝不在已知后代仍存活时主动放开普通 dispatch。
    if ($null -ne $treeCleanupFailure) { throw $treeCleanupFailure }
    if ($dispatchJobHandle -ne [IntPtr]::Zero) {
        [AgentMobileDispatchJob]::Close($dispatchJobHandle)
        $dispatchJobHandle = [IntPtr]::Zero
    }
    if ($lockFs) { Close-DispatchLock -Stream $lockFs -Path $LockFile }
}
