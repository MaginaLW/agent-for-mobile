#Requires -Version 7
<#
P0 监督式 smoke 的任务提示词装配。

危险动作的提示词是安全资产：它决定了真机上会发生什么，必须可评审、可 diff、可单测。
正文因此只存在于 scripts/tasks/p0-safety-<leg>.tmpl.md 一处，本文件只做「取正文 + 换 marker」，
不内联任何兜底文本——模板缺失或损坏一律硬失败，静默回退等于又造一份影子提示词。

模板格式：`---` 分隔线以上是给人读的说明（不进提示词），以下是派发正文，
正文里的 <RUNNER_GENERATED_MARKER> 由本轮随机 marker 替换。
#>

$P0TaskMarkerPlaceholder = '<RUNNER_GENERATED_MARKER>'

function Get-P0DynamicTaskText {
    param(
        [Parameter(Mandatory)][ValidateSet('Allow','Stale')][string]$Leg,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$TemplateDir
    )
    if ([string]::IsNullOrWhiteSpace($Marker)) { throw "$Leg 腿 marker 不能为空。" }
    $templatePath = Join-Path $TemplateDir ("p0-safety-{0}.tmpl.md" -f $Leg.ToLowerInvariant())
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "$Leg 腿任务模板缺失：$templatePath。"
    }
    $raw = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8
    $separator = [regex]::Match($raw, '(?m)^---[ \t]*\r?$')
    if (-not $separator.Success) {
        throw "$Leg 腿任务模板缺少 --- 分隔线，无法区分人读说明与派发正文：$templatePath。"
    }
    $body = $raw.Substring($separator.Index + $separator.Length).Trim()
    if (-not $body.Contains($P0TaskMarkerPlaceholder)) {
        throw "$Leg 腿任务模板正文缺少 $P0TaskMarkerPlaceholder 占位符：$templatePath。"
    }
    # 换行统一成 CRLF：模板文件的行尾取决于 git autocrlf，派发正文的字节不该随之漂移。
    return $body.Replace($P0TaskMarkerPlaceholder, $Marker) -replace "`r?`n", "`r`n"
}

function Write-P0DynamicTask {
    param(
        [Parameter(Mandatory)][ValidateSet('Allow','Stale')][string]$Leg,
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TemplateDir
    )
    $task = Get-P0DynamicTaskText -Leg $Leg -Marker $Marker -TemplateDir $TemplateDir
    Set-Content -LiteralPath $Path -Value $task -Encoding utf8
}
