#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-v2-offline-gate.ps1')

$script:Passed = 0
$script:Failed = 0
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-mobile-tl1-v2-gate-' + [guid]::NewGuid().ToString('N'))

function Assert-True { param([bool]$Condition,[string]$Because); if (-not $Condition) { throw $Because } }
function Assert-Equal { param($Actual,$Expected,[string]$Because); if ($Actual -cne $Expected) { throw "$Because（期望=$Expected，实际=$Actual）" } }
function Assert-Contains {
    param([object[]]$Values,[string]$Expected,[string]$Because)
    if (@($Values) -cnotcontains $Expected) { throw "$Because（缺少=$Expected）" }
}
function Test-GateCase {
    param([string]$Name,[scriptblock]$Body)
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $script:Failed++; Write-Host "FAIL $Name：$($_.Exception.Message)" -ForegroundColor Red }
}

function New-CompleteSummary {
    param([string]$GateRunId)
    $cases = [Collections.Generic.List[object]]::new()
    foreach ($caseId in @(Get-TL1V2OfflineRequiredCaseIds)) {
        $cases.Add([pscustomobject][ordered]@{
            case_id=$caseId
            status='passed'
            coverage_ids=[string[]]@(Get-TL1V2OfflineCoverageForCaseId $caseId)
        })
    }
    $finished = [DateTimeOffset]::UtcNow
    return [pscustomobject][ordered]@{
        schema=$script:TL1V2OfflineSummarySchema
        gate_run_id=$GateRunId
        started_at=$finished.AddSeconds(-1).ToString($script:TL1V2TimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
        finished_at=$finished.ToString($script:TL1V2TimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
        suite=$script:TL1V2Schema
        status='passed'; test_exit_code=0L
        total_cases=[long]$cases.Count; passed_cases=[long]$cases.Count; failed_cases=0L
        required_coverage_count=[long]$script:TL1V2OfflineRequiredCoverageIds.Count
        covered_required_count=[long]$script:TL1V2OfflineRequiredCoverageIds.Count
        coverage_ids=[string[]]@(Get-TL1V2OrdinalUniqueStrings $script:TL1V2OfflineRequiredCoverageIds)
        cases=@($cases.ToArray())
        fixture_contract_only=$true; runtime_evidence=$false; layout_accepted=$false
        wechat_layout_verified=$false; editor_action_ready=$false
        settings_mutation_allowed=$false; device_action_allowed=$false
        p0_capability='unsupported'; execution_grant=$false
    }
}

try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null

    Test-GateCase '完整 exact 24 case/coverage summary 通过' {
        $id='gate-'+[guid]::NewGuid().ToString('N')
        $result=Test-TL1V2OfflineSummaryObject (New-CompleteSummary $id) $id
        Assert-True $result.accepted '完整 summary 应通过。'
        Assert-Equal $result.total_cases 24L 'case 数错误。'
        Assert-Equal $result.covered_required_count 24L 'coverage 数错误。'
        Assert-Equal $result.layout_accepted $false 'gate 不得 layout accepted。'
        Assert-Equal $result.execution_grant $false 'gate 不得 execution grant。'
    }

    Test-GateCase '0 case/count 欺骗 fail closed' {
        $id='gate-'+[guid]::NewGuid().ToString('N'); $summary=New-CompleteSummary $id
        $summary.cases=@();$summary.coverage_ids=@();$summary.total_cases=0L;$summary.passed_cases=0L;$summary.covered_required_count=0L
        $result=Test-TL1V2OfflineSummaryObject $summary $id
        Assert-Contains $result.reason_codes 'summary_zero_cases' '0 case 未阻断。'
        Assert-Contains $result.reason_codes 'summary_required_case_missing' 'required case 缺失未检出。'
    }

    Test-GateCase '缺/未知 coverage 与重复 case 均阻断' {
        $id='gate-'+[guid]::NewGuid().ToString('N'); $summary=New-CompleteSummary $id
        $summary.cases[1].case_id=$summary.cases[0].case_id
        $summary.cases[0].coverage_ids=@('unknown_coverage')
        $summary.coverage_ids=[string[]]@($summary.coverage_ids | Where-Object { $_ -cne 'upstream_t0_block_preserved' }) + 'unknown_coverage'
        $summary.coverage_ids=[string[]]@(Get-TL1V2OrdinalUniqueStrings $summary.coverage_ids)
        $result=Test-TL1V2OfflineSummaryObject $summary $id
        Assert-Contains $result.reason_codes 'summary_duplicate_case_id' '重复 case 未检出。'
        Assert-Contains $result.reason_codes 'summary_unexpected_coverage' '未知 coverage 未检出。'
        Assert-Contains $result.reason_codes 'summary_required_coverage_missing' '缺 required coverage 未检出。'
    }

    Test-GateCase 'summary 安全常量不能自提升' {
        $id='gate-'+[guid]::NewGuid().ToString('N');$summary=New-CompleteSummary $id
        $summary.execution_grant=$true
        $result=Test-TL1V2OfflineSummaryObject $summary $id
        Assert-Contains $result.reason_codes 'summary_schema_invalid' 'exec 自提升必须由 schema 拒绝。'
        Assert-Equal $result.execution_grant $false 'validation envelope exec 必须 false。'
    }

    Test-GateCase '固定 .checks leaf 原子写入并按本次 run ID 读回' {
        $repo=Join-Path $TestRoot 'repo';New-Item -ItemType Directory -Path $repo|Out-Null
        $issues=[Collections.Generic.List[object]]::new();$paths=Get-TL1V2OfflineChecksPaths $repo $issues -CreateChecksRoot
        Assert-True ($null -ne $paths -and $issues.Count -eq 0) '.checks 初始化失败。'
        $id='gate-'+[guid]::NewGuid().ToString('N')
        Write-TL1V2OfflineSummaryAtomic (New-CompleteSummary $id) $repo $paths.SummaryPath $id
        $read=Read-TL1V2OfflineSummary $repo $paths.SummaryPath $id
        Assert-True $read.accepted '原子 summary 读回失败。'
        $stale=Read-TL1V2OfflineSummary $repo $paths.SummaryPath ('gate-'+[guid]::NewGuid().ToString('N'))
        Assert-Contains $stale.reason_codes 'summary_gate_run_id_mismatch' '旧 run ID 未阻断。'
    }
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        $full=[IO.Path]::GetFullPath($TestRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full).StartsWith('agent-mobile-tl1-v2-gate-',[StringComparison]::Ordinal)) {
            [IO.Directory]::Delete($full,$true)
        }
    }
}

Write-Host "`nT-L1 v2 gate self-test：$script:Passed passed，$script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
