#Requires -Version 7
<#
台账归因。

台账里 43 fail / 24 success，而 note 列基本只有 `executor=gateway`——回头做归因只能一条条
翻 trace。归因本身很有价值："安全门按预期拦下"与"通道挂了"是完全不同的两件事，却都记成 fail。

判据优先取 trace 里**最后一个 gateway 错误码**：它比模型的自述准确。取不到才退回派单层的信号。
注意 `E_BLOCKED` 在 Deny 腿是**期望结果**——`safety-denied` 表示安全门尽到了职责，不是故障。
#>

<#
终态报告的匹配模式。

模型写 `**结果：失败**` 是常态，而旧模式只认裸行首 `^结果：失败`——两条都不匹配时
dispatch 会落到兜底分支**把失败记成 success**（2026-07-31 真机实锤）。
这里统一容忍：行首空白、markdown 强调（`*`/`_`，任意重数）、以及冒号后的空格。
#>
$script:P0AwaitConfirmPattern = '(?m)^[ \t]*[*_]{0,3}\[AWAIT_CONFIRM\]'

function Get-P0FinalVerdictPattern {
    param([Parameter(Mandatory)][ValidateSet('成功', '失败')][string]$Outcome)
    return "(?m)^[ \t]*[*_]{0,3}结果[：:][ \t]*$Outcome"
}

<#
台账表头与写行。**两处共用一份**：dispatch 正常收尾写一行，runner 在"人已经花了时间、
但派单被提前掐掉"时也要写一行——各写各的必然漂移，而台账列的语义漂移正是归因失效的开始。

`fail_reason` 追加在末尾而不是插在 result 后面：既有 60+ 行历史记录列数少一列，
`Import-Csv` 会把缺的尾列读成空，插在中间则会整体错位。
#>
$P0LedgerHeader = 'time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note,fail_reason'

function ConvertTo-P0CsvField {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    $text = [string]$Value
    if ($text -match '[",\r\n]') { return '"' + $text.Replace('"', '""') + '"' }
    return $text
}

function Add-P0LedgerRow {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][int]$Leg,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Brain,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Result,
        [AllowEmptyString()][string]$Turns = '',
        [AllowEmptyString()][string]$InTok = '',
        [AllowEmptyString()][string]$OutTok = '',
        [AllowEmptyString()][string]$CacheRead = '',
        [AllowEmptyString()][string]$CacheWrite = '',
        [AllowEmptyString()][string]$CostUsd = '',
        [AllowEmptyString()][string]$DurS = '',
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$TraceFile = '',
        [AllowEmptyString()][string]$Note = '',
        [AllowEmptyString()][string]$FailReason = ''
    )
    $directory = Split-Path -Parent $LedgerPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    if (-not (Test-Path -LiteralPath $LedgerPath)) {
        Set-Content -LiteralPath $LedgerPath -Value $P0LedgerHeader -Encoding utf8
    }
    $row = @(
        (Get-Date -Format 's'), (ConvertTo-P0CsvField $Slug), $Leg, $Brain, $Model,
        $Turns, $InTok, $OutTok, $CacheRead, $CacheWrite, $CostUsd, $DurS,
        $Result, $SessionId, (ConvertTo-P0CsvField $TraceFile),
        (ConvertTo-P0CsvField $Note), $FailReason
    ) -join ','
    Add-Content -LiteralPath $LedgerPath -Value $row -Encoding utf8
}

<#
监督式跑测被提前掐掉时的归因。

runner 检出真人决定与本腿预期不符就立刻 kill dispatch——这是对的（Deny 腿若真被批准，
再让它跑下去就会真的发出去），代价是 dispatch 来不及写自己那行台账。2026-08-01 三轮跑测
（一次误点拒绝、两次确认超时）因此在台账上**零留痕**：消耗了真人时间却完全不可见，
而台账存在的全部意义就是让烧掉的东西可见。

三类必须分得开——它们要采取的行动完全不同：
- `safety-denied`      真人点了拒绝，而本腿期望允许。安全门尽职，是人或剧本的问题。
- `decision-mismatch`  本腿期望拒绝、真人却点了允许。**最严重**：Deny 腿被批准了。
- `confirm-timeout`    没等到任何决定。人没看见卡/通知，或者根本没弹。
#>
function Get-P0AbortedLegFailReason {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Actual
    )
    if ([string]::IsNullOrWhiteSpace($Actual)) { return 'confirm-timeout' }
    switch ($Actual) {
        'timed_out' { return 'confirm-timeout' }
        'denied'    { return $(if ($Expected -ceq 'denied') { '' } else { 'safety-denied' }) }
        'allowed'   { return $(if ($Expected -ceq 'allowed') { '' } else { 'decision-mismatch' }) }
        'error'     { return 'confirm-error' }
        'dismissed' { return 'confirm-dismissed' }
        default     { return "confirm-$Actual" }
    }
}

function Get-FailReason {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Verdict,
        [AllowEmptyString()][string]$Subtype = '',
        [AllowEmptyString()][string]$TraceFile = ''
    )
    if ($Verdict -in @('success', 'paused')) { return '' }
    switch ($Verdict) {
        'preflight-fail' { return 'preflight' }
        'timeout'        { return 'dispatch-timeout' }
        'step-cap'       { return 'step-cap' }
    }

    $lastCode = ''
    $lastChannel = ''
    if ($TraceFile -and (Test-Path -LiteralPath $TraceFile -PathType Leaf)) {
        # 只尾读（会话纪律 3）；不整读、不做完整 JSON 解析——这里只要一个归因线索。
        #
        # 反斜杠必须可选：信封是被当成**字符串**塞进 tool_result 的，落到 trace 里是
        # `\"code\":\"E_BLOCKED\"`（转义），只写未转义形式的话真机 trace 一个码都匹配不到。
        # 这个错误是离线测试用真实形态的夹具抓出来的。
        # channel 与 code 一起取：同一个错误码可能来自完全不同的东西（见下面 E_BLOCKED 分支）。
        # 惰性上界 400 是为了只吃掉中间那截 message，不跨到下一个信封去认领 channel。
        $pattern = '\\?"code\\?"\s*:\s*\\?"(E_[A-Z_]+)\\?"' +
            '(?:.{0,400}?\\?"channel\\?"\s*:\s*\\?"([A-Za-z0-9_.\-]+)\\?")?'
        foreach ($line in (Get-Content -LiteralPath $TraceFile -Tail 200 -Encoding utf8)) {
            foreach ($m in [regex]::Matches($line, $pattern)) {
                $lastCode = $m.Groups[1].Value
                $lastChannel = $m.Groups[2].Value
            }
        }
    }
    if ($lastCode) {
        switch ($lastCode) {
            'E_BLOCKED'          {
                # 同一个 E_BLOCKED 可以来自两件毫不相干的事：
                #   channel=overlay      真人在确认卡上点了拒绝——安全门尽职，这才是 safety-denied；
                #   channel=test-control debug 测试控制自己拒收这条腿——**确认卡根本没弹**。
                # 2026-08-01 实锤：Deny 腿白名单漏了 deny，那一轮与真正的拒绝在台账里记成了
                # 一模一样的 safety-denied，而归因列存在的全部意义就是区分这两种。
                # 只特判 test-control：其余通道维持原判据，不为了这一条去搅动历史归因。
                if ($lastChannel -ceq 'test-control') { return 'test-control-blocked' }
                return 'safety-denied'
            }
            'E_STALE_REF'        { return 'stale-context' }
            'E_VERIFY_FAIL'      { return 'verify-fail' }
            'E_CONFIRM_TIMEOUT'  { return 'confirm-timeout' }
            'E_CONFIRM_REQUIRED' { return 'confirm-required' }
            'E_CHANNEL_DOWN'     { return 'channel-down' }
            'E_PERM_MISSING'     { return 'perm-missing' }
            'E_NOT_FOUND'        { return 'not-found' }
            'E_TIMEOUT'          { return 'tool-timeout' }
            default              { return $lastCode.ToLowerInvariant().Replace('_', '-') }
        }
    }
    if ($Subtype -and $Subtype -ne 'success') { return "executor-$Subtype" }
    return 'reported-fail'
}
