#Requires -Version 7.5
<#
合同改动必须带对应离线用例改动，或由调用者明确给出豁免理由。
只读 Git；不会运行测试、写审批记录或授予设备运行许可。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$BaseRef = 'HEAD',
    [AllowEmptyString()][string]$ExemptionReason
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

function Read-CoverageGit([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add($RepoRoot)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'git_failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $raw = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'git_failed' }
        return $raw
    } finally { $process.Dispose() }
}

function Split-CoveragePaths([AllowEmptyString()][string]$Raw) {
    return @($Raw.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
}

# 映射的是实际消费相应合同的既有套件，不把任意 tests/ 改动算作覆盖。
$contractTests = @{
    'tablet-layout-observation-v2.schema.json' = @('scripts/tests/tablet-layout-observation-v2-offline.ps1')
    'tablet-layout-observation-v2.md' = @('scripts/tests/tablet-layout-observation-v2-offline.ps1')
    'tablet-layout-observation-offline-summary-v2.schema.json' = @('scripts/tests/tablet-layout-observation-v2-offline-gate.ps1')
    'tablet-layout-observation-c1b-v1.schema.json' = @('scripts/tests/tablet-layout-observation-c1b-v1-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-layout-observation-c1b-v1.md' = @('scripts/tests/tablet-layout-observation-c1b-v1-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-layout-observation-c1b-v1-offline-summary.schema.json' = @('scripts/tests/tablet-layout-observation-c1b-v1-offline-gate.ps1')
    'tablet-layout-observation-c1b-v2.schema.json' = @('scripts/tests/tablet-layout-observation-c1b-v2-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-layout-observation-c1b-v2.md' = @('scripts/tests/tablet-layout-observation-c1b-v2-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-layout-c1a-v1.md' = @('scripts/tests/tablet-layout-c1a-offline.ps1')
    'tablet-layout-c1a-sidecar-v1.schema.json' = @('scripts/tests/tablet-layout-c1a-t0-adb-sidecar-offline.ps1')
    'tablet-c1b-inventory-result-v1.schema.json' = @('scripts/tests/tablet-c1b-inventory-result-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-c1b-inventory-result-v2.schema.json' = @('scripts/tests/tablet-c1b-inventory-result-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
    'tablet-c1b-inventory-result-v3.schema.json' = @('scripts/tests/tablet-c1b-inventory-result-offline.ps1', 'scripts/tests/c1b-corpus-replay-offline.ps1')
}

try {
    if ($PSBoundParameters.ContainsKey('ExemptionReason') -and [string]::IsNullOrWhiteSpace($ExemptionReason)) {
        throw 'exemption_reason_empty'
    }
    if ([string]::IsNullOrWhiteSpace($BaseRef)) { throw 'base_ref_invalid' }
    try { $baseCommit = (Read-CoverageGit @('rev-parse', '--verify', '--end-of-options', "$BaseRef^{commit}")).Trim() }
    catch { throw 'base_ref_invalid' }

    $views = @(
        @{ name = 'working_tree'; diff = @('diff', '--no-renames', '--name-only', '-z', $baseCommit, '--'); include_untracked = $true },
        @{ name = 'index'; diff = @('diff', '--cached', '--no-renames', '--name-only', '-z', $baseCommit, '--'); include_untracked = $false }
    )
    $checks = [Collections.Generic.List[object]]::new()
    foreach ($view in $views) {
        $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in (Split-CoveragePaths (Read-CoverageGit $view.diff))) { [void]$paths.Add($path) }
        if ($view.include_untracked) {
            foreach ($path in (Split-CoveragePaths (Read-CoverageGit @('ls-files', '--others', '--exclude-standard', '-z', '--')))) {
                [void]$paths.Add($path)
            }
        }

        # 删除用例不是新增覆盖；分别核工作树与 index，避免未暂存测试替 staged 合同过门。
        $testDiff = @('diff')
        if ($view.name -ceq 'index') { $testDiff += '--cached' }
        $testDiff += @('--no-renames', '--diff-filter=ACMT', '--name-only', '-z', $baseCommit, '--')
        $liveChanges = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in (Split-CoveragePaths (Read-CoverageGit $testDiff))) { [void]$liveChanges.Add($path) }
        if ($view.include_untracked) {
            foreach ($path in (Split-CoveragePaths (Read-CoverageGit @('ls-files', '--others', '--exclude-standard', '-z', '--')))) {
                [void]$liveChanges.Add($path)
            }
        }

        foreach ($path in @($paths | Where-Object { $_.StartsWith('docs/contracts/', [StringComparison]::Ordinal) } | Sort-Object)) {
            $key = $path.Substring('docs/contracts/'.Length)
            $expected = @(if ($contractTests.ContainsKey($key)) { $contractTests[$key] })
            $matching = @($expected | Where-Object { $liveChanges.Contains($_) })
            $status = if ($matching.Count -gt 0) { 'covered' }
                elseif ($PSBoundParameters.ContainsKey('ExemptionReason')) { 'exempted' }
                elseif ($expected.Count -eq 0) { 'unmapped_contract' }
                else { 'missing_test_change' }
            $checks.Add([pscustomobject][ordered]@{
                scope = $view.name
                contract = $path
                status = $status
                corresponding_tests = $expected
                changed_tests = $matching
                exemption_reason = if ($status -ceq 'exempted') { $ExemptionReason.Trim() } else { $null }
            })
        }
    }
    $failed = @($checks | Where-Object { $_.status -cin @('unmapped_contract', 'missing_test_change') })
    [pscustomobject][ordered]@{
        schema = 'contract-coverage/v1'
        status = if ($failed.Count -eq 0) { 'passed' } else { 'failed' }
        base_commit = $baseCommit
        contract_view_count = $checks.Count
        failed_count = $failed.Count
        checks = @($checks.ToArray())
        test_execution_verified = $false
        device_run_authorized = $false
    } | ConvertTo-Json -Depth 8 -Compress
    if ($failed.Count -gt 0) { exit 1 }
} catch {
    $reason = $_.Exception.Message
    if ($reason -cnotin @('base_ref_invalid', 'exemption_reason_empty', 'git_failed')) { $reason = 'check_failed' }
    [pscustomobject][ordered]@{
        schema = 'contract-coverage/v1'; status = 'failed'; reason = $reason
        test_execution_verified = $false; device_run_authorized = $false
    } | ConvertTo-Json -Compress
    exit 1
}
