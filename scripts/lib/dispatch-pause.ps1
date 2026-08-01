#Requires -Version 7
<#
两段式暂停件（`*.pause.md`）的解析与作废。

**为什么单独成册**：作废那一步只在"人真的键入了 CONFIRM"之后才走，而那条路离线跑不到
（DryRun 不派单，Read-Host 也不该被自动化代答）。留在 dispatch.ps1 里就意味着"拒绝重放"
这条判据只有一半能验——挡住已消费文件的那一半有用例，而**把文件标成已消费**的那一半没有。
本仓踩过同一形态的坑：Deny 腿四条判据全部来自被测组件自报，看起来铁证如山。
抽成纯函数后两半都能离线钉住。

暂停件格式：`key: value` 若干行 + `---` + 报告正文。
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
    foreach ($line in ($parts[0] -split "`r?`n")) {
        if ($line -match '^(\w+):\s*(.*)$') { $meta[$Matches[1]] = $Matches[2].Trim() }
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
