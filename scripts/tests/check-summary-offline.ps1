#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\lib\check-summary.ps1')
$passed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
}
function Assert-Rejected([scriptblock]$Body, [string]$Pattern) {
    $failure = $null
    try { & $Body | Out-Null } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notmatch $Pattern) {
        throw "预期拒绝 /$Pattern/，实际：$failure"
    }
}
function New-VerifierSummary {
    [ordered]@{
        schema = 'tablet-layout-c1b-real-build-smoke-verifier-offline/v2'
        passed = 19L; failed = 0L; skipped = 0L; mutation_assertion_count = 217L
        process_api_reference_count = 0L; path_capability_skip_count = 0L
        captured_public_file_invocation_count = 209L; captured_public_file_rejection_count = 208L
        direct_value_rejection_count = 9L; pwsh_version = $PSVersionTable.PSVersion.ToString()
        failure_messages = @(); skip_messages = @()
    }
}
function Assert-Verifier($Summary) {
    Assert-C1bRealBuildSmokeVerifierSummary -Stdout (($Summary | ConvertTo-Json -Compress) + "`n") -Stderr '' -ExpectedPowerShellVersion $PSVersionTable.PSVersion.ToString()
}
Test-Case 'parent runtime version is accepted without stale version literal' { Assert-Verifier (New-VerifierSummary) }
Test-Case 'different child runtime rejected' {
    $summary = New-VerifierSummary
    $summary.pwsh_version = '0.0.0'
    Assert-Rejected { Assert-Verifier $summary } '不 exact'
}
Test-Case 'valid capability skip still cannot become a green gate' {
    $summary = New-VerifierSummary
    $summary.passed = 17L; $summary.skipped = 2L; $summary.path_capability_skip_count = 2L
    $summary.mutation_assertion_count = 215L; $summary.captured_public_file_invocation_count = 207L
    $summary.captured_public_file_rejection_count = 206L
    $summary.skip_messages = @('leaf unavailable', 'ancestor unavailable')
    Assert-Rejected { Assert-Verifier $summary } '符号链接反例未运行'
}
Test-Case 'failed verifier rejected' {
    $summary = New-VerifierSummary; $summary.failed = 1L
    Assert-Rejected { Assert-Verifier $summary } '不 exact'
}
Test-Case 'counter drift rejected' {
    $summary = New-VerifierSummary; $summary.mutation_assertion_count = 216L
    Assert-Rejected { Assert-Verifier $summary } '不 exact'
}
Test-Case 'duplicate JSON key rejected' {
    $raw = (New-VerifierSummary | ConvertTo-Json -Compress).Replace('"passed":19', '"passed":19,"passed":19') + "`n"
    if ($raw -notmatch '"passed":19,"passed":19') { throw '反例注入没有发生。' }
    Assert-Rejected { Assert-C1bRealBuildSmokeVerifierSummary $raw '' $PSVersionTable.PSVersion.ToString() } 'duplicate JSON property'
}
Test-Case 'stderr rejected' {
    Assert-Rejected { Assert-C1bRealBuildSmokeVerifierSummary "{}`n" 'unexpected' $PSVersionTable.PSVersion.ToString() } 'stderr'
}
Test-Case 'extra stdout rejected' {
    Assert-Rejected { Assert-C1bRealBuildSmokeVerifierSummary "{}`nextra`n" '' $PSVersionTable.PSVersion.ToString() } '单行'
}
Test-Case 'sequential producer summary accepted' {
    if ((Get-RunnerOfflinePassedCount @('离线监督式 runner：86 passed, 0 failed')) -ne 86) { throw 'count' }
}
$shards = @(
    '离线监督式 runner：29 passed, 0 failed（分片 1/3，另 57 条归其它分片）',
    '离线监督式 runner：29 passed, 0 failed（分片 2/3，另 57 条归其它分片）',
    '离线监督式 runner：28 passed, 0 failed（分片 3/3，另 58 条归其它分片）'
)
Test-Case 'all producer shards add up exactly' {
    if ((Get-RunnerOfflinePassedCount $shards) -ne 86) { throw 'count' }
}
Test-Case 'missing summary rejected' { Assert-Rejected { Get-RunnerOfflinePassedCount @('') } '汇总缺失' }
Test-Case 'zero tests rejected' { Assert-Rejected { Get-RunnerOfflinePassedCount @('离线监督式 runner：0 passed, 0 failed') } '空跑' }
Test-Case 'nonzero failed count rejected' { Assert-Rejected { Get-RunnerOfflinePassedCount @('离线监督式 runner：86 passed, 1 failed') } '失败' }
Test-Case 'duplicate shard identity rejected' { Assert-Rejected { Get-RunnerOfflinePassedCount @($shards[0], $shards[0], $shards[2]) } '分片身份' }
Test-Case 'missing shard rejected' { Assert-Rejected { Get-RunnerOfflinePassedCount @($shards[0], $shards[1]) } '分片身份' }
Test-Case 'unequal suite totals rejected' {
    Assert-Rejected { Get-RunnerOfflinePassedCount @($shards[0], $shards[1], $shards[2].Replace('58 条', '57 条')) } '用例总数'
}
Test-Case 'incomplete shard coverage rejected' {
    Assert-Rejected { Get-RunnerOfflinePassedCount @($shards[0], $shards[1], $shards[2].Replace('28 passed', '27 passed').Replace('58 条', '59 条')) } '未覆盖'
}
Write-Host "check summary offline: $passed passed, 0 failed"
