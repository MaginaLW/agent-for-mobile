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
$script:P0AwaitConfirmPattern = '(?m)^[ \t]*[*_`]{0,3}\[AWAIT_CONFIRM\]'

function Get-P0FinalVerdictPattern {
    param([Parameter(Mandatory)][ValidateSet('成功', '失败')][string]$Outcome)
    # 反引号与 `*`/`_` 同族：模型会把整段报告包成 `` `结果：成功…` ``。
    # 2026-08-02 真机实锤——runner 判"终态报告不是成功"整腿判死，而 dispatch 对**同一段文字**
    # 落进兜底记成 success，两个组件对同一文本给出相反结论。
    return "(?m)^[ \t]*[*_``]{0,3}结果[：:][ \t]*$Outcome"
}

<#
台账表头与写行。**两处共用一份**：dispatch 正常收尾写一行，runner 在"人已经花了时间、
但派单被提前掐掉"时也要写一行——各写各的必然漂移，而台账列的语义漂移正是归因失效的开始。

`fail_reason` 追加在末尾而不是插在 result 后面：既有 60+ 行历史记录列数少一列，
`Import-Csv` 会把缺的尾列读成空，插在中间则会整体错位。
#>
$P0LedgerHeader = 'time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note,fail_reason'

function ConvertTo-P0CsvField {
    param([AllowEmptyString()][AllowNull()][object]$Value)
    $text = if ($null -eq $Value) { '' } else {
        [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    # CSV 语法正确不等于用表格软件打开时安全。任何可在前导空白后被解释成公式的
    # 单元格都加一个文字前缀；台账是证据，不允许 slug/model/fail_reason 变成可执行公式。
    if ($text -match '^[\s\p{Cf}]*[=+\-@]') { $text = "'$text" }
    if ($text -match '[",\r\n]') { return '"' + $text.Replace('"', '""') + '"' }
    return $text
}

function Open-P0LedgerWriteLock {
    param(
        [Parameter(Mandatory)][string]$LedgerPath,
        [ValidateRange(1, 60000)][int]$TimeoutMs = 10000
    )
    $lockPath = "$LedgerPath.write.lock"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if (Test-Path -LiteralPath $lockPath) {
            $lockItem = Get-Item -LiteralPath $lockPath -Force -ErrorAction Stop
            if ($lockItem.PSIsContainer -or
                ($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "台账写锁路径不是普通文件：$lockPath"
            }
        }
        try {
            return [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            if ($watch.ElapsedMilliseconds -ge $TimeoutMs) {
                throw "等待台账独占写锁超时（${TimeoutMs}ms）：$LedgerPath"
            }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Assert-P0LedgerCsvContract {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$LedgerPath
    )
    if ($Bytes.Length -eq 0) { return '' }
    # StreamReader 的 BOM 自动探测会把 UTF-16 文件“正常”读出，随后再追加 UTF-8，生成
    # 混合编码证据。台账契约只接受无 BOM 的严格 UTF-8。
    $bomPrefixes = @(
        [byte[]](0xEF,0xBB,0xBF), [byte[]](0xFF,0xFE), [byte[]](0xFE,0xFF),
        [byte[]](0xFF,0xFE,0x00,0x00), [byte[]](0x00,0x00,0xFE,0xFF)
    )
    foreach ($prefix in $bomPrefixes) {
        if ($Bytes.Length -ge $prefix.Length) {
            $matches = $true
            for ($i = 0; $i -lt $prefix.Length; $i++) {
                if ($Bytes[$i] -ne $prefix[$i]) { $matches = $false; break }
            }
            if ($matches) { throw "台账必须是无 BOM 的 UTF-8，拒绝混合编码：$LedgerPath" }
        }
    }
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $encoding.GetString($Bytes) }
    catch { throw "台账不是严格 UTF-8，拒绝追加：$LedgerPath" }
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        throw "台账尾部不是完整换行记录，疑似中断写入，拒绝追加：$LedgerPath"
    }
    $firstLineEnd = $text.IndexOf("`n", [StringComparison]::Ordinal)
    $header = $text.Substring(0, $firstLineEnd).TrimEnd("`r")
    if ($header -cne $P0LedgerHeader) {
        throw "台账表头与当前契约不一致，拒绝追加：$LedgerPath"
    }

    # 严格扫描 RFC 4180 子集。ConvertFrom-Csv 会吞掉未闭合引号，不能用来证明尾行完整。
    $recordFieldCounts = [Collections.Generic.List[int]]::new()
    $fieldCount = 1
    $atFieldStart = $true
    $inQuotes = $false
    $quoteClosed = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $character = $text[$i]
        if ($inQuotes) {
            if ($character -eq '"') {
                if ($i + 1 -lt $text.Length -and $text[$i + 1] -eq '"') { $i++ }
                else { $inQuotes = $false; $quoteClosed = $true }
            }
            continue
        }
        if ($quoteClosed) {
            if ($character -eq ',') {
                $fieldCount++; $atFieldStart = $true; $quoteClosed = $false; continue
            }
            if ($character -eq "`r") {
                if ($i + 1 -ge $text.Length -or $text[$i + 1] -ne "`n") {
                    throw "台账含裸 CR，拒绝追加：$LedgerPath"
                }
                continue
            }
            if ($character -eq "`n") {
                $recordFieldCounts.Add($fieldCount)
                $fieldCount = 1; $atFieldStart = $true; $quoteClosed = $false; continue
            }
            throw "台账引号字段闭合后含非法字符，拒绝追加：$LedgerPath"
        }
        switch ($character) {
            '"' {
                if (-not $atFieldStart) { throw "台账未转义引号，拒绝追加：$LedgerPath" }
                $inQuotes = $true
            }
            ',' { $fieldCount++; $atFieldStart = $true }
            "`r" {
                if ($i + 1 -ge $text.Length -or $text[$i + 1] -ne "`n") {
                    throw "台账含裸 CR，拒绝追加：$LedgerPath"
                }
            }
            "`n" {
                $recordFieldCounts.Add($fieldCount)
                $fieldCount = 1; $atFieldStart = $true
            }
            default { $atFieldStart = $false }
        }
    }
    if ($inQuotes -or $quoteClosed -or $fieldCount -ne 1 -or -not $atFieldStart) {
        throw "台账尾行不完整，拒绝追加：$LedgerPath"
    }
    if ($recordFieldCounts.Count -lt 1 -or $recordFieldCounts[0] -ne 17) {
        throw "台账表头列数不为 17，拒绝追加：$LedgerPath"
    }
    # 历史行早于 fail_reason 列，只含 16 列；新行必须由本函数写成 17 列。
    $seenCurrentSchema = $false
    foreach ($count in $recordFieldCounts | Select-Object -Skip 1) {
        if ($count -eq 17) { $seenCurrentSchema = $true; continue }
        if ($count -ne 16) { throw "台账历史行列数非法（$count），拒绝追加：$LedgerPath" }
        if ($seenCurrentSchema) {
            throw "台账在 17 列新记录之后再次出现 16 列旧记录，拒绝追加：$LedgerPath"
        }
    }
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
    $fields = @(
        (Get-Date -Format 's'), $Slug, $Leg, $Brain, $Model,
        $Turns, $InTok, $OutTok, $CacheRead, $CacheWrite, $CostUsd, $DurS,
        $Result, $SessionId, $TraceFile, $Note, $FailReason
    )
    $row = ($fields | ForEach-Object { ConvertTo-P0CsvField $_ }) -join ','
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    $writeLock = $null
    $temporary = "$LedgerPath.tmp.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        $writeLock = Open-P0LedgerWriteLock -LedgerPath $LedgerPath

        [byte[]]$existingBytes = @()
        if (Test-Path -LiteralPath $LedgerPath -PathType Leaf) {
            $item = Get-Item -LiteralPath $LedgerPath -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "台账不得是 reparse point：$LedgerPath"
            }
            $existingBytes = [IO.File]::ReadAllBytes($LedgerPath)
        }
        try {
            $existingText = Assert-P0LedgerCsvContract -Bytes $existingBytes -LedgerPath $LedgerPath
        }
        finally { if ($existingBytes.Length -gt 0) { [Array]::Clear($existingBytes, 0, $existingBytes.Length) } }
        $nextText = if ([string]::IsNullOrEmpty($existingText)) {
            $P0LedgerHeader + [Environment]::NewLine + $row + [Environment]::NewLine
        }
        else { $existingText + $row + [Environment]::NewLine }
        $nextBytes = $encoding.GetBytes($nextText)
        try {
            $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($nextBytes, 0, $nextBytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            [IO.File]::Move($temporary, $LedgerPath, $true)
        }
        finally { [Array]::Clear($nextBytes, 0, $nextBytes.Length) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if ($null -ne $writeLock) { $writeLock.Dispose() }
    }
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
        # 报告没循例 → 成败判不了。**归因不能空着**，否则台账上它看起来像一次普通失败。
        'unparsed'       { return 'report-unparsed' }
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
