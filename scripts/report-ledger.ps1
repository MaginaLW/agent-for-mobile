#Requires -Version 7.5
<#
只读聚合 docs/runs/ledger.csv，按任务类别输出成功率、耗时与 token 统计基线。
用法：
  scripts/report-ledger.ps1
  scripts/report-ledger.ps1 -Since 2026-11-18
  scripts/report-ledger.ps1 -Brain all -Json
#>
[CmdletBinding()]
param(
    [string]$LedgerPath = '',
    [string]$Since = '',
    [string]$Brain = 'codex',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Get-LedgerTaskCategory {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Slug)

    $s = $Slug.ToLowerInvariant()
    switch -Regex ($s) {
        '^skill-macro|^macro-|^m3-' { return 'macro' }
        'xhs' { return 'xhs' }
        'taobao|jd-' { return 'taobao_jd' }
        'bluetooth' { return 'bluetooth' }
        'wechat' { return 'wechat' }
        '^p0-' { return 'p0' }
        default { return 'other' }
    }
}

function Try-ParseLedgerNumber {
    param([AllowNull()][AllowEmptyString()][string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $val = 0.0
    if ([double]::TryParse($Raw.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
        return $val
    }
    return $null
}

function Get-LedgerMedian {
    param([double[]]$Values)

    if ($null -eq $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $mid = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) {
        return [Math]::Round($sorted[$mid], 2)
    }
    return [Math]::Round((($sorted[$mid - 1] + $sorted[$mid]) / 2.0), 2)
}

function Get-LedgerGroupStats {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][object[]]$Rows
    )

    $list = @($Rows)
    $total = $list.Count
    $success = @($list | Where-Object { $_.result -ceq 'success' -or $_.result -ceq 'pass' }).Count
    $fail = @($list | Where-Object { $_.result -ceq 'fail' }).Count
    $paused = @($list | Where-Object { $_.result -ceq 'paused' }).Count
    $timeout = @($list | Where-Object { $_.result -ceq 'timeout' }).Count
    $preflight = @($list | Where-Object { $_.result -ceq 'preflight-fail' }).Count
    $other = $total - $success - $fail - $paused - $timeout - $preflight

    $durs = [Collections.Generic.List[double]]::new()
    $inToks = [Collections.Generic.List[double]]::new()
    $outToks = [Collections.Generic.List[double]]::new()
    $cacheRatios = [Collections.Generic.List[double]]::new()

    foreach ($row in $list) {
        $d = Try-ParseLedgerNumber $row.dur_s
        if ($null -ne $d) { $durs.Add($d) }
        $inV = Try-ParseLedgerNumber $row.in_tok
        if ($null -ne $inV) {
            $inToks.Add($inV)
            $cr = Try-ParseLedgerNumber $row.cache_read
            if ($null -ne $cr -and $inV -gt 0) {
                $cacheRatios.Add($cr / $inV)
            }
        }
        $outV = Try-ParseLedgerNumber $row.out_tok
        if ($null -ne $outV) { $outToks.Add($outV) }
    }

    $successRate = if ($total -gt 0) { [Math]::Round(($success * 100.0) / $total, 1) } else { 0.0 }
    $avgDur = if ($durs.Count -gt 0) { [Math]::Round((($durs | Measure-Object -Average).Average), 1) } else { $null }
    $medDur = Get-LedgerMedian $durs.ToArray()
    $avgIn = if ($inToks.Count -gt 0) { [int64][Math]::Round((($inToks | Measure-Object -Average).Average), 0) } else { $null }
    $avgOut = if ($outToks.Count -gt 0) { [int64][Math]::Round((($outToks | Measure-Object -Average).Average), 0) } else { $null }
    $avgCacheRate = if ($cacheRatios.Count -gt 0) { [Math]::Round((($cacheRatios | Measure-Object -Average).Average) * 100.0, 1) } else { $null }

    return [pscustomobject]@{
        category = $Name
        runs = $total
        success = $success
        fail = $fail
        paused = $paused
        timeout = $timeout
        preflight_fail = $preflight
        other = $other
        success_rate_pct = $successRate
        avg_dur_s = $avgDur
        median_dur_s = $medDur
        avg_in_tok = $avgIn
        avg_out_tok = $avgOut
        avg_cache_hit_pct = $avgCacheRate
    }
}

function Get-LedgerReportData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SinceDate = '',
        [string]$BrainFilter = 'codex'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到台账文件：$Path"
    }
    if (-not [string]::IsNullOrWhiteSpace($SinceDate) -and $SinceDate -notmatch '^\d{4}-\d{2}-\d{2}$') {
        throw "Since 日期格式须为 YYYY-MM-DD：$SinceDate"
    }

    $rawRows = @(Import-Csv -LiteralPath $Path -Encoding utf8)
    $filtered = [Collections.Generic.List[object]]::new()
    foreach ($row in $rawRows) {
        if ($BrainFilter -cne 'all' -and ([string]$row.brain) -cne $BrainFilter) { continue }
        $t = [string]$row.time
        if (-not [string]::IsNullOrWhiteSpace($SinceDate)) {
            if ($t -notmatch '^\d{4}-\d{2}-\d{2}') { continue }
            if ($t.Substring(0, 10) -lt $SinceDate) { continue }
        }
        $filtered.Add($row)
    }

    $order = @('xhs', 'taobao_jd', 'bluetooth', 'wechat', 'p0', 'macro', 'other')
    $grouped = @{}
    foreach ($cat in $order) { $grouped[$cat] = [Collections.Generic.List[object]]::new() }
    foreach ($row in $filtered) {
        $cat = Get-LedgerTaskCategory ([string]$row.slug)
        $grouped[$cat].Add($row)
    }

    $categories = [Collections.Generic.List[object]]::new()
    foreach ($cat in $order) {
        if ($grouped[$cat].Count -gt 0) {
            $categories.Add((Get-LedgerGroupStats -Name $cat -Rows $grouped[$cat].ToArray()))
        }
    }

    $failReasons = @($filtered |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.fail_reason) } |
        Group-Object fail_reason |
        Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Ascending = $true } |
        ForEach-Object { [pscustomobject]@{ fail_reason = $_.Name; count = $_.Count } })

    return [pscustomobject]@{
        since = $SinceDate
        brain = $BrainFilter
        total_rows = $rawRows.Count
        matched_rows = $filtered.Count
        overall = Get-LedgerGroupStats -Name 'overall' -Rows $filtered.ToArray()
        categories = $categories.ToArray()
        fail_reasons = $failReasons
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $targetPath = if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
        Join-Path $repoRoot 'docs\runs\ledger.csv'
    } else {
        $LedgerPath
    }
    $report = Get-LedgerReportData -Path $targetPath -SinceDate $Since -BrainFilter $Brain
    if ($Json) {
        $report | ConvertTo-Json -Depth 6
        exit 0
    }
    Write-Host ("Ledger 统计（brain={0}, since={1}, matched={2}/{3}）" -f $report.brain, $(if ($report.since) { $report.since } else { 'all' }), $report.matched_rows, $report.total_rows) -ForegroundColor Cyan
    $rowsToPrint = @($report.categories) + @($report.overall)
    $rowsToPrint | Format-Table category, runs, success, fail, timeout, preflight_fail, success_rate_pct, avg_dur_s, median_dur_s, avg_in_tok, avg_cache_hit_pct, avg_out_tok -AutoSize
    if ($report.fail_reasons.Count -gt 0) {
        Write-Host '失败原因分布：' -ForegroundColor DarkGray
        $report.fail_reasons | Format-Table fail_reason, count -AutoSize
    }
}
