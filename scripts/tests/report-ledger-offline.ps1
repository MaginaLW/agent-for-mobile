#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$scriptPath = Join-Path $repoRoot 'scripts\report-ledger.ps1'
$pwshPath = (Get-Process -Id $PID).Path
. $scriptPath

$passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
}

$scratch = Join-Path $repoRoot ('.checks\report-ledger-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

try {
    $csvPath = Join-Path $scratch 'ledger.csv'
    @"
time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note,fail_reason
2026-11-17T10:00:00,m1-xhs-old,1,codex,,1,10000,100,5000,0,,20,success,,,,
2026-11-18T10:00:00,m1-xhs-new,1,codex,,1,20000,200,15000,0,,40,success,,,,
2026-11-18T11:00:00,m1-xhs-fail,1,codex,,1,10000,100,0,0,,30,fail,,,,verify-fail
2026-11-19T09:00:00,m1-taobao-order,1,codex,,1,,,,,,180,timeout,,,,dispatch-timeout
2026-11-19T10:00:00,skill-macro-xhs,1,codex,,1,0,50,0,0,,12,success,,,,
2026-11-19T11:00:00,legacy-claude,1,claude,sonnet,5,1000,100,0,0,0.2,10,success,,,,
"@ | Set-Content -LiteralPath $csvPath -Encoding utf8

    Test-Case 'filters_by_since_and_brain_and_handles_zero_and_empty_metrics' {
        $data = Get-LedgerReportData -Path $csvPath -SinceDate '2026-11-18' -BrainFilter 'codex'
        Assert-True ($data.total_rows -eq 6) "预期总行数 6，实际 $($data.total_rows)"
        Assert-True ($data.matched_rows -eq 4) "预期命中 4，实际 $($data.matched_rows)"
        Assert-True ($data.overall.success -eq 2) 'success 计数不符'
        Assert-True ($data.overall.fail -eq 1) 'fail 计数不符'
        Assert-True ($data.overall.timeout -eq 1) 'timeout 计数不符'
        Assert-True ($data.overall.success_rate_pct -eq 50.0) '总体成功率应为 50.0'

        $xhs = @($data.categories | Where-Object { $_.category -ceq 'xhs' })[0]
        Assert-True ($xhs.runs -eq 2) 'xhs 应有 2 条'
        Assert-True ($xhs.avg_dur_s -eq 35.0) 'xhs 平均耗时应为 35.0'
        Assert-True ($xhs.avg_in_tok -eq 15000) 'xhs 平均输入 token 应为 15000'
        Assert-True ($xhs.avg_cache_hit_pct -eq 37.5) 'xhs 平均缓存命中率应为 37.5'

        $macro = @($data.categories | Where-Object { $_.category -ceq 'macro' })[0]
        Assert-True ($macro.runs -eq 1 -and $null -eq $macro.avg_cache_hit_pct) 'in_tok=0 时缓存命中率应安全为 null'
    }

    Test-Case 'categorizes_m3_macro_runs_under_macro' {
        Assert-True ((Get-LedgerTaskCategory 'm3-taobao-readonly-prep-20261125') -ceq 'macro') 'm3-taobao-readonly-prep-20261125 应归类为 macro'
        Assert-True ((Get-LedgerTaskCategory 'm3-wechat-readonly-prep-20261125') -ceq 'macro') 'm3-wechat-readonly-prep-20261125 应归类为 macro'
        Assert-True ((Get-LedgerTaskCategory 'bili-readonly-browse') -ceq 'bili') 'bili-readonly-browse 应归类为 bili'

        $m3CsvPath = Join-Path $scratch 'ledger-m3.csv'
        @"
time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note,fail_reason
2026-11-25T10:00:00,m3-taobao-readonly-prep-20261125,1,codex,,1,1000,50,500,0,,10,success,,,,
2026-11-25T10:05:00,m3-wechat-readonly-prep-20261125,1,codex,,1,1200,60,600,0,,12,success,,,,
2026-11-25T10:10:00,m3-jd-readonly-prep-20261125,1,codex,,1,1400,70,700,0,,15,paused,,,,
2026-11-25T10:15:00,m3-bili-readonly-promote-20261125,1,codex,,1,1600,80,800,0,,18,paused,,,,
2026-11-25T10:20:00,m3-bili-readonly-promote-r2-20261125,1,codex,,1,1800,90,900,0,,20,success,,,,
2026-11-25T10:25:00,skill-macro-xhs-tokyo-20261125,1,codex,,1,2000,100,1000,0,,25,fail,,,,verify-fail
"@ | Set-Content -LiteralPath $m3CsvPath -Encoding utf8
        $m3Data = Get-LedgerReportData -Path $m3CsvPath -SinceDate '2026-11-25' -BrainFilter 'codex'
        $m3Macro = @($m3Data.categories | Where-Object { $_.category -ceq 'macro' })[0]
        Assert-True ($null -ne $m3Macro -and $m3Macro.runs -eq 6 -and $m3Macro.success -eq 3 -and $m3Macro.paused -eq 2 -and $m3Macro.fail -eq 1) 'm3-* 宏任务应聚合到 macro 类别并统计 paused'

        $bySub = @{}
        foreach ($item in $m3Data.macro_breakdown) { $bySub[$item.category] = $item }
        Assert-True ($bySub['macro:taobao'].runs -eq 1 -and $bySub['macro:wechat'].runs -eq 1) 'macro_breakdown 缺少 taobao/wechat'
        Assert-True ($bySub['macro:jd'].paused -eq 1 -and $bySub['macro:bili'].runs -eq 2 -and $bySub['macro:bili'].paused -eq 1 -and $bySub['macro:bili'].success -eq 1) 'macro_breakdown jd/bili 统计不符'
        Assert-True ($bySub['macro:xhs'].fail -eq 1) 'macro_breakdown xhs 统计不符'

        $tableOut = (& $pwshPath -NoProfile -File $scriptPath -LedgerPath $m3CsvPath -Since '2026-11-25' -ByMacro) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "report-ledger.ps1 -ByMacro 执行失败，exit=$LASTEXITCODE" }
        Assert-True ($tableOut -match '\bpaused\b') '默认报表输出应包含 paused 列'
        Assert-True ($tableOut.Contains('macro:bili', [StringComparison]::Ordinal)) '-ByMacro 应输出 macro:bili 细分行'
    }

    Test-Case 'rejects_invalid_since_format' {
        $err = $null
        try { Get-LedgerReportData -Path $csvPath -SinceDate '2026/11/18' | Out-Null } catch { $err = $_ }
        Assert-True ($null -ne $err -and $err.Exception.Message -match 'YYYY-MM-DD') '非法日期未被拒绝'
    }

    Test-Case 'json_cli_roundtrips_real_ledger' {
        $jsonOut = & $pwshPath -NoProfile -File $scriptPath -Since '2026-11-18' -Json
        if ($LASTEXITCODE -ne 0) { throw "report-ledger.ps1 执行失败，exit=$LASTEXITCODE" }
        $parsed = ($jsonOut -join "`n") | ConvertFrom-Json -Depth 8
        Assert-True ($parsed.matched_rows -ge 1) '真实 ledger.csv 2026-11-18 以来应至少有一条记录'
        Assert-True ($null -ne $parsed.overall) 'JSON 缺少 overall 节点'
    }

    Write-Host "report ledger offline: $passed passed, 0 failed"
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
