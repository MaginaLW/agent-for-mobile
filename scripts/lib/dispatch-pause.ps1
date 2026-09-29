#Requires -Version 7
<#
两段式暂停件（`*.pause.md`）的解析与作废。

**为什么单独成册**：Read-Host 可以由程序经 stdin 或 PTY 输入，不能证明真人批准。
gateway 的 PC 输入只用于恢复纯人工前置条件，真正危险动作仍须走手机可见 ConfirmOverlay。
消费标记仅限制同一报告重复恢复，不是人控批准或动作绑定。解析与消费抽成纯函数，
让拒绝重放与作废变换都能离线验证。

暂停件格式：`key: value` 若干行 + `---` + 报告正文。保留未知合法字段以兼容后续扩展；
字段名不区分大小写且不得重复，非空头部行必须合法，显式 consumed 不得为空。
#>

# 刻意不写 Set-StrictMode：本册被 dispatch.ps1 dot-source，而 dot-source 的 StrictMode
# 会作用到调用方整个脚本作用域。dispatch.ps1 与另外三个 lib 现在都没开，在这里单方面打开
# 等于顺手改了它全篇的求值语义——那不是本次改动该捎带的事。

<# 解析暂停件文本；格式不合法即抛错，不做任何兜底猜测。 #>
function Read-DispatchPauseDocument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $parts = $Text -split '(?m)^---\s*$', 2
    if ($parts.Count -lt 2) { throw '暂停件格式异常（缺 --- 分隔）' }
    $meta = [ordered]@{}
    $lineNumber = 0
    foreach ($line in ($parts[0] -split "`r?`n")) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^(\w+):[ \t]*(.*)$') {
            throw "暂停件头部第 $lineNumber 行格式异常（应为 key: value）"
        }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        # ordered dictionary 的键不区分大小写；后写覆盖会让 consumed 或 executor 失去原义。
        if ($meta.Contains($key)) { throw "暂停件头部存在重复字段：$key" }
        if ($key -ieq 'consumed' -and [string]::IsNullOrWhiteSpace($value)) {
            throw '暂停件 consumed 字段不得为空；未消费的暂停件应省略此字段。'
        }
        $meta[$key] = $value
    }
    return [pscustomobject]@{
        Meta = $meta
        Header = $parts[0]
        Body = $parts[1].Trim()
        Consumed = [string]$(if ($meta.Contains('consumed')) { $meta['consumed'] } else { '' })
    }
}

<#
把暂停件标成已消费，返回新的文件文本。

**只加一行 meta，不改名**：路径可能已经被人复制到别处（派单结束时屏幕上就打了一条
`-Confirm "<路径>"`），改名会让那些引用凭空失效，而失效的形态是"文件不存在"——
和"还没跑过"长得一样。
#>
function Set-DispatchPauseConsumed {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$At
    )
    $document = Read-DispatchPauseDocument -Text $Text
    if ($document.Consumed) { throw "暂停件已于 $($document.Consumed) 被消费" }
    return $document.Header.TrimEnd() + "`nconsumed: $At`n---`n" + $document.Body + "`n"
}
