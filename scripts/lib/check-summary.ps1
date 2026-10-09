#Requires -Version 7.5
# 离线门消费真实子套件结果；任何缺失、跳过或版本漂移均不得伪装成通过。
function Get-RunnerOfflinePassedCount {
    param([Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Summaries)
    if ($Summaries.Count -eq 0) { throw 'runner 没有任何套件汇总。' }
    $total = 0L
    $matched = -1L
    for ($index = 0; $index -lt $Summaries.Count; $index++) {
        $line = $Summaries[$index]
        if ($line -cnotmatch '\A离线监督式 runner：([1-9][0-9]*) passed, 0 failed(?:（分片 ([1-9][0-9]*)/([1-9][0-9]*)，另 (0|[1-9][0-9]*) 条归其它分片）)?\z') {
            throw "runner 汇总缺失、空跑或失败：$line"
        }
        $passed = [long]$Matches[1]
        if ($Summaries.Count -eq 1) {
            if ($Matches.ContainsKey(2)) { throw '顺序 runner 不应携带分片标签。' }
        }
        else {
            if (-not $Matches.ContainsKey(2) -or [long]$Matches[2] -ne ($index + 1) -or
                [long]$Matches[3] -ne $Summaries.Count) { throw 'runner 分片身份或分片总数不一致。' }
            $caseCount = $passed + [long]$Matches[4]
            if ($matched -ge 0 -and $matched -ne $caseCount) { throw 'runner 各分片看到的用例总数不一致。' }
            $matched = $caseCount
        }
        $total += $passed
    }
    if ($matched -ge 0 -and $total -ne $matched) { throw 'runner 分片通过数未覆盖全部用例。' }
    return $total
}
