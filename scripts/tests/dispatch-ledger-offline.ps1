#Requires -Version 7
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$library = Join-Path $repoRoot 'scripts\lib\dispatch-ledger.ps1'
$writer = Join-Path $PSScriptRoot 'fixtures\dispatch-ledger-writer.ps1'
. $library

$tempRoot = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'agent-mobile-ledger-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempRoot)
$passed = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Pass([string]$Name, [scriptblock]$Body) {
    & $Body
    $passed.Add($Name)
}

try {
    Pass 'csv_roundtrip_and_formula_neutralization' {
        $ledger = Join-Path $tempRoot 'roundtrip.csv'
        $model = "model,`"quoted`"`nsecond line"
        $note = "line one`r`nline two"
        $unicodeFormula = "$([char]0x200B)=HIDDEN()"
        Add-P0LedgerRow -LedgerPath $ledger -Slug '=SUM(1,1)' -Leg 1 -Brain codex `
            -Model $model -Result fail -SessionId '+cmd' -TraceFile 'trace,one.jsonl' `
            -Note $note -FailReason $unicodeFormula
        $rows = @(Import-Csv -LiteralPath $ledger)
        Assert-True ($rows.Count -eq 1) 'CSV 行数漂移'
        Assert-True ($rows[0].slug -ceq "'=SUM(1,1)") 'slug 公式未中和'
        Assert-True ($rows[0].model -ceq $model) 'model CSV 往返漂移'
        Assert-True ($rows[0].session_id -ceq "'+cmd") 'session_id 公式未中和'
        Assert-True ($rows[0].trace_file -ceq 'trace,one.jsonl') 'trace_file CSV 往返漂移'
        Assert-True ($rows[0].note -ceq $note) 'note 换行往返漂移'
        Assert-True ($rows[0].fail_reason -ceq "'$unicodeFormula") 'Unicode 隐藏字符后的公式未中和'
        Assert-True (($rows[0].PSObject.Properties.Name -join ',') -ceq $P0LedgerHeader) 'CSV 列契约漂移'
    }

    Pass 'header_mismatch_fails_closed' {
        $ledger = Join-Path $tempRoot 'bad-header.csv'
        [IO.File]::WriteAllText($ledger, "wrong,header`n", [Text.UTF8Encoding]::new($false))
        $error = try {
            Add-P0LedgerRow -LedgerPath $ledger -Slug test -Leg 1 -Brain codex -Model m -Result fail
            $null
        }
        catch { $_ }
        Assert-True ($null -ne $error -and $error.Exception.Message -match '表头') '错误表头未 fail-closed'
        Assert-True ((Get-Content -LiteralPath $ledger -Raw) -ceq "wrong,header`n") '拒绝后仍改写台账'
    }

    Pass 'utf16_bom_fails_closed_without_rewrite' {
        $ledger = Join-Path $tempRoot 'utf16.csv'
        [IO.File]::WriteAllText($ledger, $P0LedgerHeader + "`r`n", [Text.UnicodeEncoding]::new($false, $true))
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($ledger))
        $error = try {
            Add-P0LedgerRow -LedgerPath $ledger -Slug test -Leg 1 -Brain codex -Model m -Result fail
            $null
        }
        catch { $_ }
        Assert-True ($null -ne $error -and $error.Exception.Message -match 'BOM') 'UTF-16 BOM 未 fail-closed'
        Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($ledger)) -ceq $before) '编码拒绝后仍改写台账'
    }

    Pass 'invalid_utf8_fails_closed_without_rewrite' {
        $ledger = Join-Path $tempRoot 'invalid-utf8.csv'
        $prefix = [Text.UTF8Encoding]::new($false).GetBytes($P0LedgerHeader + "`n")
        $bytes = [byte[]]::new($prefix.Length + 3)
        [Array]::Copy($prefix, $bytes, $prefix.Length)
        $bytes[$prefix.Length] = 0xE2
        $bytes[$prefix.Length + 1] = 0x28
        $bytes[$prefix.Length + 2] = 0xA1
        [IO.File]::WriteAllBytes($ledger, $bytes)
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($ledger))
        $error = try {
            Add-P0LedgerRow -LedgerPath $ledger -Slug test -Leg 1 -Brain codex -Model m -Result fail
            $null
        }
        catch { $_ }
        Assert-True ($null -ne $error -and $error.Exception.Message -match '严格 UTF-8') '非法 UTF-8 未 fail-closed'
        Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($ledger)) -ceq $before) '非法 UTF-8 拒绝后仍改写台账'
    }

    Pass 'truncated_tail_fails_closed_without_rewrite' {
        $ledger = Join-Path $tempRoot 'truncated.csv'
        $raw = $P0LedgerHeader + "`n2026-08-28T00:00:00,`"unterminated"
        [IO.File]::WriteAllText($ledger, $raw, [Text.UTF8Encoding]::new($false))
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($ledger))
        $error = try {
            Add-P0LedgerRow -LedgerPath $ledger -Slug test -Leg 1 -Brain codex -Model m -Result fail
            $null
        }
        catch { $_ }
        Assert-True ($null -ne $error -and $error.Exception.Message -match '尾部|尾行') '截断尾行未 fail-closed'
        Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($ledger)) -ceq $before) '截断拒绝后仍改写台账'
    }

    Pass 'legacy_columns_cannot_reappear_after_current_schema' {
        $ledger = Join-Path $tempRoot 'schema-regression.csv'
        $newRow = (@(1..17 | ForEach-Object { "v$_" }) -join ',')
        $oldRow = (@(1..16 | ForEach-Object { "v$_" }) -join ',')
        $raw = $P0LedgerHeader + "`n" + $newRow + "`n" + $oldRow + "`n"
        [IO.File]::WriteAllText($ledger, $raw, [Text.UTF8Encoding]::new($false))
        $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($ledger))
        $error = try {
            Add-P0LedgerRow -LedgerPath $ledger -Slug test -Leg 1 -Brain codex -Model m -Result fail
            $null
        }
        catch { $_ }
        Assert-True ($null -ne $error -and $error.Exception.Message -match '再次出现') 'schema 倒退未 fail-closed'
        Assert-True ([Convert]::ToHexString([IO.File]::ReadAllBytes($ledger)) -ceq $before) 'schema 拒绝后仍改写台账'
    }

    Pass 'concurrent_process_writes_are_complete' {
        $ledger = Join-Path $tempRoot 'concurrent.csv'
        $pwsh = (Get-Process -Id $PID).Path
        $processes = foreach ($index in 1..12) {
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $pwsh
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            foreach ($argument in @('-NoProfile', '-File', $writer, '-LibraryPath', $library, '-LedgerPath', $ledger, '-Index', "$index")) {
                $start.ArgumentList.Add($argument)
            }
            [Diagnostics.Process]::Start($start)
        }
        foreach ($process in $processes) {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
            $process.Dispose()
            Assert-True ($exitCode -eq 0) "并发 writer 退出码 $exitCode"
        }
        $rows = @(Import-Csv -LiteralPath $ledger)
        Assert-True ($rows.Count -eq 12) "并发台账应有 12 行，实际 $($rows.Count)"
        Assert-True ((@($rows.slug | Sort-Object -Unique).Count) -eq 12) '并发台账出现丢行或重复'
        Assert-True ((Get-Content -LiteralPath $ledger -TotalCount 1) -ceq $P0LedgerHeader) '并发表头漂移'
        Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter 'concurrent.csv.tmp.*').Count -eq 0) '成功后遗留临时台账'
    }

    [pscustomobject][ordered]@{
        schema = 'dispatch-ledger-offline-summary/v1'
        status = 'passed'
        test_case_count = $passed.Count
        coverage = $passed.ToArray()
    } | ConvertTo-Json -Compress
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $resolvedSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($resolvedSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemp).StartsWith('agent-mobile-ledger-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
