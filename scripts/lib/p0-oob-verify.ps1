#Requires -Version 7
<#
Deny 腿带外验证的纯判据（批次 3）。

**这一册只做判断，不碰设备。** 截屏与 OCR 分别由 runner 的 adb 通道和
`p0-oob-ocr.ps1` 完成；这里把「词 + 位置」变成两条**分开记录**的证据和一个三态结论，
好让每一条都能被离线用例钉住。

## 两条证据的证明力完全不同，绝不能合并成一个布尔

- **输入框里 marker 还在 = 正证据。** 微信发送后会清空输入栏，文字还在就说明发送没发生。
  这是 Deny 腿唯一一条强证据。
- **消息区没有该 marker = 负证据，而且很弱。** 消息列表可能已经往上滚，没看见不等于没有
  （2026-08-01 手工那次正是如此：结论靠的是输入框那条正证据，"消息区无 marker"**未被视觉证实**）。
  所以本册对"消息区没找到"只记 `absent_unverified`，**永远不把它当成"没发出去"的证据**。
- 反过来，**消息区找到了 marker = 强反证**：Deny 腿声称拦下了，而消息确实发出去了。

## 判不了就说判不了

OCR 读不出来时不许倒向任何一边。本仓最典型的谎报成功就是 `fromOcrReadback` 把
"一个字没读到"判成已发送。这里读不到一律 `unreadable` → 结论 `inconclusive`。
#>

# 刻意不写 Set-StrictMode：本册被 runner dot-source，会作用到调用方整个作用域
# （同 dispatch-pause.ps1 / p0-foreground-bootstrap.ps1 的理由）。

<#
把 OCR helper 的输出解析成词列表。

解析不出来的行**直接丢弃**：它既不能当"读到了"，也不该让整次判定失败——
少一个词的后果由上层的三态结论承担。
#>
function ConvertFrom-P0OcrWords {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    $words = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($words) }
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split '\|'
        if ($parts.Count -ne 5) { continue }
        $x = 0; $y = 0; $w = 0; $h = 0
        if (-not ([int]::TryParse($parts[1], [ref]$x) -and [int]::TryParse($parts[2], [ref]$y) -and
                  [int]::TryParse($parts[3], [ref]$w) -and [int]::TryParse($parts[4], [ref]$h))) { continue }
        $words.Add([pscustomobject]@{ Text = $parts[0]; X = $x; Y = $y; Width = $w; Height = $h })
    }
    return @($words)
}

<#
按纵向位置把词归成"行"，再把同一行的词按 x 拼起来。

**必须先拼再匹配**：OCR 会把 marker 切成好几个词（实测 `P0ALLOW-1D97824FD778` →
`POALLOW-` / `1` / `D97824FD778`），拿单个词去比对必然漏判。
行的归并阈值取词高的一半——比这更宽会把相邻两行的文字串成一行，制造出并不存在的 marker。
#>
function Join-P0OcrLines {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Words)

    $lines = [Collections.Generic.List[object]]::new()
    foreach ($word in ($Words | Sort-Object Y, X)) {
        $centerY = $word.Y + [int]($word.Height / 2)
        $tolerance = [Math]::Max(8, [int]($word.Height / 2))
        $target = $null
        foreach ($line in $lines) {
            if ([Math]::Abs($line.CenterY - $centerY) -le $tolerance) { $target = $line; break }
        }
        if ($null -eq $target) {
            $target = [pscustomobject]@{
                CenterY = $centerY
                Top = $word.Y
                Bottom = $word.Y + $word.Height
                Items = [Collections.Generic.List[object]]::new()
            }
            $lines.Add($target)
        }
        $target.Items.Add($word)
        if ($word.Y -lt $target.Top) { $target.Top = $word.Y }
        if (($word.Y + $word.Height) -gt $target.Bottom) { $target.Bottom = $word.Y + $word.Height }
    }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        $ordered = @($line.Items | Sort-Object X)
        $result.Add([pscustomobject]@{
            Text = (($ordered | ForEach-Object { $_.Text }) -join '')
            Top = $line.Top
            Bottom = $line.Bottom
            CenterY = $line.CenterY
        })
    }
    return @($result | Sort-Object Top)
}

<#
在给定的纵向带里找 marker。三态：

- `present`    带里有一行归一后包含该 marker
- `absent`     带里有可读文字，但没有该 marker
- `unreadable` 带里一个字都没读到——**不是 absent**，两者要采取的行动完全不同

[Normalize] 必须传入仓库既有的 marker 归一函数（大写 + 去符号 + O→0）：
OCR 把 `P0` 读成 `PO` 是常态，不归一必然漏判。
#>
function Get-P0OcrMarkerPresence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lines,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][int]$BandTop,
        [Parameter(Mandatory)][int]$BandBottom,
        [Parameter(Mandatory)][scriptblock]$Normalize
    )

    $expected = & $Normalize $Marker
    $inBand = @($Lines | Where-Object { $_.CenterY -ge $BandTop -and $_.CenterY -lt $BandBottom })
    if ($inBand.Count -eq 0) { return 'unreadable' }
    foreach ($line in $inBand) {
        if ((& $Normalize $line.Text).Contains($expected)) { return 'present' }
    }
    return 'absent'
}

<#
从 `dumpsys notification` 里读审批通知的真实状态。

**为什么要它**：2026-08-01 批次 2 验收，锁屏上根本看不到审批通知，而"为什么"当时只能靠猜——
posted 了、importance 也对、actions 也在，唯独没人能说出系统把它过滤掉的理由。这一册把
系统自己报的 flags 抓下来，让下一轮不必再猜（"修不动的时候先加可观测性，别加假设"）。

`FLAG_ONGOING_EVENT`(0x2) 是当前最强嫌疑：锁屏通知列表历来过滤 ongoing 通知，而同机旁证是
本包那条常驻前台服务通知同样不上锁屏。**这个函数就是用来证实或推翻它的**——
去掉 `setOngoing` 之后仍然看不到的话，看这里的 flags 就知道该往哪查。

读不出来一律回 `$null` 字段，不猜。
#>
<#
把 `dumpsys notification` 拆成一条条通知记录，供**差集比较**。

2026-08-02 第三次验收把判据 1 收敛成只剩「可见」一件，并给出了天然对照组：同一时刻
锁屏上另一条 app 通知正常显示，网关那条就是不在。**下一步该做的是列全两条的属性差异，
而不是继续挨个试开关**——这个函数就是为此存在的。

字段按"能解析多少算多少"取，取不到就留空：`dumpsys` 的格式随版本变，硬要求某个字段
只会让整份数据在新系统上一起失效。
#>
function Get-P0NotificationRecords {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$DumpText)

    $records = [Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($DumpText)) { return @($records) }
    # 以 NotificationRecord( 为界切块；最后一块吃到文本末尾。
    $starts = @([regex]::Matches($DumpText, 'NotificationRecord\(') | ForEach-Object { $_.Index })
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $from = $starts[$i]
        $to = if ($i + 1 -lt $starts.Count) { $starts[$i + 1] } else { $DumpText.Length }
        $block = $DumpText.Substring($from, $to - $from)
        function Read-Field([string]$Pattern) {
            $m = [regex]::Match($block, $Pattern)
            if ($m.Success) { return $m.Groups[1].Value } else { return '' }
        }
        $flagsText = Read-Field 'flags=0x([0-9a-fA-F]+)'
        $flags = if ($flagsText) { [Convert]::ToInt32($flagsText, 16) } else { $null }
        $records.Add([pscustomobject]@{
            Package = Read-Field 'pkg=([A-Za-z0-9_.]+)'
            Id = Read-Field 'id=(\d+)'
            ChannelId = Read-Field '(?:channel|mChannelId)=([A-Za-z0-9_.\-]+)'
            Flags = $flags
            Ongoing = $(if ($null -eq $flags) { $null } else { ($flags -band 0x2) -ne 0 })
            Category = Read-Field 'category=([A-Za-z0-9_.]+)'
            Visibility = Read-Field '(?:mVisibility|visibility)=(-?\d+)'
            Group = Read-Field '(?:mGroupKey|groupKey)=(\S+)'
            SortKey = Read-Field 'sortKey=(\S+)'
        })
    }
    return @($records)
}

<#
把本包的审批通知与**同一份 dump 里其它 App 的通知**做差集。

只列"两边都解析出来、而且不一样"的字段——一致的字段列出来只会淹没信号。
#>
function Get-P0NotificationDiff {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$ChannelId,
        [Parameter(Mandatory)][string]$OwnPackage
    )
    $ours = @($Records | Where-Object { $_.ChannelId -ceq $ChannelId }) | Select-Object -First 1
    $others = @($Records | Where-Object { $_.Package -and $_.Package -cne $OwnPackage })
    if ($null -eq $ours -or $others.Count -eq 0) { return @() }
    $diff = [Collections.Generic.List[string]]::new()
    foreach ($field in @('Category', 'Flags', 'Visibility', 'Group', 'Ongoing')) {
        $mine = [string]$ours.$field
        foreach ($other in $others) {
            $theirs = [string]$other.$field
            if ([string]::IsNullOrEmpty($mine) -and [string]::IsNullOrEmpty($theirs)) { continue }
            if ($mine -cne $theirs) {
                $diff.Add("$field：本包=$($mine -replace '^$','-') / $($other.Package)=$($theirs -replace '^$','-')")
            }
        }
    }
    return @($diff | Select-Object -Unique)
}

function Get-P0NotificationState {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$DumpText,
        [Parameter(Mandatory)][string]$ChannelId
    )

    $state = [pscustomobject]@{
        Found = $false
        Flags = $null
        Ongoing = $null
        Visibility = $null
    }
    if ([string]::IsNullOrWhiteSpace($DumpText)) { return $state }
    # 只认属于本审批通道的那一段：同一份 dump 里还有前台服务那条常驻通知，
    # 把两者混起来读出来的 flags 正好是最容易得出错误结论的那种。
    $lines = $DumpText -split "`r?`n"
    $index = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape("channel=$ChannelId") -or
            $lines[$i] -match ('mChannelId=' + [regex]::Escape($ChannelId))) { $index = $i; break }
    }
    if ($index -lt 0) { return $state }
    $state.Found = $true
    # flags/visibility 与 channel 行的相对位置在各版本上不一样，围绕命中行取一窗口。
    $from = [Math]::Max(0, $index - 40)
    $to = [Math]::Min($lines.Count - 1, $index + 40)
    $window = ($lines[$from..$to] -join "`n")
    $flagMatch = [regex]::Match($window, 'flags=0x([0-9a-fA-F]+)')
    if ($flagMatch.Success) {
        $flags = [Convert]::ToInt32($flagMatch.Groups[1].Value, 16)
        $state.Flags = $flags
        # FLAG_ONGOING_EVENT = 0x00000002
        $state.Ongoing = (($flags -band 0x2) -ne 0)
    }
    $visMatch = [regex]::Match($window, '(?:mVisibility|visibility)=(-?\d+)')
    if ($visMatch.Success) { $state.Visibility = [int]$visMatch.Groups[1].Value }
    return $state
}

<#
Deny 腿的带外结论。

**注意 `MessageArea` 的 `absent` 不参与"没发出去"的判定**——消息列表可能滚上去了。
它只在 `present` 时说话，而那一说就是重大失败。
#>
function Get-P0DenyOobVerdict {
    param(
        [Parameter(Mandatory)][string]$InputBox,
        [Parameter(Mandatory)][string]$MessageArea
    )

    if ($MessageArea -eq 'present') {
        return [pscustomobject]@{
            Verdict = 'sent_detected'
            Postcondition = 'independent_ocr_found_marker_in_message_area'
            Reason = 'Deny 腿声称已拦下，而带外截图在消息区读到了该 marker——消息很可能真的发出去了'
        }
    }
    if ($InputBox -eq 'present') {
        return [pscustomobject]@{
            Verdict = 'not_sent_confirmed'
            # 只说验到的那一条：marker 原封不动留在输入框。**不写成"已确认未发送"**——
            # 消息区那条负证据仍未被视觉证实（列表可能滚过），合起来说等于夸大。
            Postcondition = 'independent_ocr_marker_still_in_input_box'
            Reason = ''
        }
    }
    return [pscustomobject]@{
        Verdict = 'inconclusive'
        # 判不了就退回原样，不许因为"跑过一次带外验证"就把结论写得更强。
        Postcondition = 'gateway_reported_blocked_no_independent_check'
        Reason = "带外证据不足以判定（输入框=$InputBox，消息区=$MessageArea）"
    }
}
