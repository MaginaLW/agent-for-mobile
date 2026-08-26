#Requires -Version 7.5

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'scripts\lib\tablet-layout-observation-c1b-v1-offline-gate.ps1')

$script:Passed = 0
$script:Failed = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-mobile-tl1-c1b-v1-gate-' + [guid]::NewGuid().ToString('N'))

function Assert-C1BGate { param([bool]$Condition,[string]$Message); if(-not $Condition){throw $Message} }
function Assert-C1BGateCode {
    param($Result,[string]$Code)
    Assert-C1BGate ($Result.reason_codes -ccontains $Code) "missing $Code; got $($Result.reason_codes -join ',')"
}
function Test-C1BGateCase {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body;$script:Passed++;"PASS $Name"}
    catch{$script:Failed++;"FAIL $Name`: $($_.Exception.Message)"}
}
function New-C1BGateCompleteSummary {
    param([string]$GateRunId,[DateTimeOffset]$FinishedAt=[DateTimeOffset]::UtcNow)
    $cases = [Collections.Generic.List[object]]::new()
    foreach($definition in @(Get-TL1C1BV1OfflineRequiredCaseDefinitions)){
        $cases.Add([pscustomobject][ordered]@{
            case_id=[string]$definition.case_id;status='passed';coverage_ids=[string[]]@($definition.coverage_ids)
        })
    }
    return New-TL1C1BV1OfflineCompleteSummary $GateRunId @($cases.ToArray()) $FinishedAt.AddSeconds(-1) $FinishedAt
}

try{
    [void][IO.Directory]::CreateDirectory($testRoot)

    Test-C1BGateCase 'exact 49-case/89-coverage summary passes' {
        $id='gate-'+[guid]::NewGuid().ToString('N')
        $result=Test-TL1C1BV1OfflineSummaryObject (New-C1BGateCompleteSummary $id) $id
        Assert-C1BGate $result.accepted 'complete summary rejected'
        Assert-C1BGate ($result.total_cases -eq 49 -and $result.covered_required_count -eq 89) 'exact counts lost'
        Assert-C1BGate (-not $result.runtime_evidence -and -not $result.layout_accepted -and
            $result.p0_capability -ceq 'unsupported' -and -not $result.execution_grant) 'safety envelope promoted'
    }

    Test-C1BGateCase 'zero-count summary fails closed' {
        $id='gate-'+[guid]::NewGuid().ToString('N');$summary=New-C1BGateCompleteSummary $id
        $summary.cases=@();$summary.coverage_ids=@();$summary.total_cases=0L;$summary.passed_cases=0L
        $summary.covered_required_count=0L
        $result=Test-TL1C1BV1OfflineSummaryObject $summary $id
        Assert-C1BGateCode $result 'summary_schema_invalid'
    }

    Test-C1BGateCase 'case/coverage summary deception fails closed' {
        $id='gate-'+[guid]::NewGuid().ToString('N');$summary=New-C1BGateCompleteSummary $id
        $summary.cases[1].case_id=$summary.cases[0].case_id
        $summary.cases[0].coverage_ids=@('unknown_coverage')
        $summary.coverage_ids=[string[]]@(Get-TL1C1BV1OfflineOrdinalUniqueStrings (
            [string[]]@($summary.coverage_ids|Where-Object{$_ -cne 'real_shape'})+'unknown_coverage'
        ))
        $result=Test-TL1C1BV1OfflineSummaryObject $summary $id
        Assert-C1BGateCode $result 'summary_duplicate_case_id'
        Assert-C1BGateCode $result 'summary_case_coverage_mismatch'
        Assert-C1BGateCode $result 'summary_unexpected_coverage'
    }

    Test-C1BGateCase 'permanent false claims cannot self-promote' {
        $id='gate-'+[guid]::NewGuid().ToString('N');$summary=New-C1BGateCompleteSummary $id
        $summary.execution_grant=$true
        $result=Test-TL1C1BV1OfflineSummaryObject $summary $id
        Assert-C1BGateCode $result 'summary_schema_invalid'
        Assert-C1BGate (-not $result.execution_grant) 'validation envelope promoted execution'
    }

    Test-C1BGateCase 'fixed atomic summary rejects wrong run and stale time' {
        $repo=Join-Path $testRoot 'repo';[void][IO.Directory]::CreateDirectory($repo)
        $issues=[Collections.Generic.List[object]]::new();$paths=Get-TL1C1BV1OfflineChecksPaths $repo $issues -CreateChecksRoot
        Assert-C1BGate ($null -ne $paths -and $issues.Count -eq 0) 'fixed .checks path rejected'
        $id='gate-'+[guid]::NewGuid().ToString('N');$summary=New-C1BGateCompleteSummary $id
        Write-TL1C1BV1OfflineSummaryAtomic $summary $repo $paths.SummaryPath $id
        $read=Read-TL1C1BV1OfflineSummary $repo $paths.SummaryPath $id
        Assert-C1BGate $read.accepted 'atomic current-run summary read failed'
        $wrong=Read-TL1C1BV1OfflineSummary $repo $paths.SummaryPath ('gate-'+[guid]::NewGuid().ToString('N'))
        Assert-C1BGateCode $wrong 'summary_gate_run_id_mismatch'
        $stale=New-C1BGateCompleteSummary $id ([DateTimeOffset]::UtcNow.AddMinutes(-3))
        $staleResult=Test-TL1C1BV1OfflineSummaryObject $stale $id
        Assert-C1BGateCode $staleResult 'summary_not_fresh'
    }
}
finally{
    if(Test-Path -LiteralPath $testRoot){
        $full=[IO.Path]::GetFullPath($testRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if($full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full).StartsWith('agent-mobile-tl1-c1b-v1-gate-',[StringComparison]::Ordinal)){
            [IO.Directory]::Delete($full,$true)
        }
    }
}

"C1B_GATE_SELF_TEST_PASS cases=$script:Passed failed=$script:Failed"
if($script:Failed -gt 0){exit 1}
