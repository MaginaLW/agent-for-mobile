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
