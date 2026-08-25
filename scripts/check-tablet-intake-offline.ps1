#Requires -Version 7
<#
T0-L 平板 intake 的无设备离线门。

本入口不接受 AdbPath，只运行 PowerShell AST 检查和 fake-adb 套件；
不会发现、连接或查询任何真实设备。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$ChecksDirectory = Join-Path $RepoRoot '.checks'
$ReportPath = Join-Path $ChecksDirectory 'tablet-intake-offline-summary.json'
$SuiteSummaryPath = Join-Path $ChecksDirectory 'tablet-intake-offline-suite-summary.json'
$LogPath = Join-Path $ChecksDirectory 'tablet-intake-offline.log'
$SuitePath = Join-Path $PSScriptRoot 'tests\tablet-intake-offline.ps1'
$PwshPath = (Get-Process -Id $PID).Path
$RequiredCoverage = @(
    'adb_path_missing', 'zero_devices', 'unauthorized_device', 'offline_device', 'multiple_devices',
    'query_failure', 'parse_unknown', 'parse_ambiguous', 'landscape_positive', 'portrait_blocked',
    'multi_window_blocked', 'pip_blocked', 'letterbox_blocked', 'exact_read_only_argv',
    'schema_v5', 'p0_always_unsupported', 'rotation_space_drift',
    'wm_size_override_blocked', 'wm_density_override_blocked', 'no_permissions_device',
    'mixed_device_offline', 'mixed_device_unauthorized', 'relative_adb_path', 'adb_path_directory',
    'devices_query_failure', 'adb_query_timeout', 'adb_path_with_spaces', 'devices_daemon_banner_crlf',
    'foreground_source_priority', 'foreground_malformed_blocked', 'focus_relationships',
    'window_identity_diagnostics', 'window_visibility_diagnostics', 'rotation_scope_diagnostics',
    'strict_window_fallback', 'capture_identity_consistency', 'window_identity_privacy',
    'numeric_overflow_fail_closed', 'unsafe_window_types', 'state_capture_consistency',
    'run_wide_window_labels'
)

function Assert-TabletOfflineReportDirectorySafe {
    if (Test-Path -LiteralPath $ChecksDirectory) {
        $item = Get-Item -LiteralPath $ChecksDirectory -Force
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '.checks 不是可信普通目录，拒绝写入离线报告。'
        }
    }
    else {
        New-Item -ItemType Directory -Path $ChecksDirectory | Out-Null
    }
}

function Write-TabletOfflineGateReport {
    param([Parameter(Mandatory)]$Payload)
    $temporary = Join-Path $ChecksDirectory ('.tablet-intake-offline-summary.json.tmp-' +
        [guid]::NewGuid().ToString('N'))
    try {
        $Payload | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $ReportPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-TabletCoverageStatus {
    param([Parameter(Mandatory)]$SuiteSummary, [Parameter(Mandatory)][string]$Id)
    $cases = @($SuiteSummary.cases | Where-Object { @($_.covers) -contains $Id })
    if ($cases.Count -eq 0) { return 'missing' }
    if (@($cases | Where-Object { [string]$_.status -cne 'passed' }).Count -gt 0) { return 'failed' }
    return 'passed'
}

$started = [DateTime]::UtcNow
$checks = [Collections.Generic.List[object]]::new()
$suiteSummary = $null
$failure = $null
$status = 'failed'
$exitCode = 1
$reportDirectorySafe = $false

try {
    Assert-TabletOfflineReportDirectorySafe
    $reportDirectorySafe = $true

    $astFiles = @(
        (Join-Path $PSScriptRoot 'lib\tablet-intake.ps1'),
        (Join-Path $PSScriptRoot 'run-tablet-intake.ps1'),
        $SuitePath,
        (Join-Path $PSScriptRoot 'check.ps1'),
        $PSCommandPath
    )
    $astFailures = [Collections.Generic.List[string]]::new()
    foreach ($file in $astFiles) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
        foreach ($error in @($errors)) {
            $astFailures.Add("$(Split-Path $file -Leaf):$($error.Extent.StartLineNumber):$($error.Message)")
        }
    }
    $checks.Add([ordered]@{
        id = 'powershell_ast'
        status = if ($astFailures.Count -eq 0) { 'passed' } else { 'failed' }
        files = @($astFiles | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_) -replace '\\','/' })
        errors = @($astFailures)
    })
    if ($astFailures.Count -gt 0) { throw 'PowerShell AST 检查失败。' }

    foreach ($stale in @($SuiteSummaryPath, $LogPath)) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PwshPath
    $start.WorkingDirectory = $RepoRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile','-File',$SuitePath,'-SummaryPath',$SuiteSummaryPath)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw '无法启动 tablet intake 离线套件。' }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(180000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'tablet intake 离线套件超时。'
        }
        $suiteExitCode = $process.ExitCode
        $suiteOutput = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
    }
    finally { $process.Dispose() }
    Set-Content -LiteralPath $LogPath -Value $suiteOutput -Encoding utf8

    if (-not (Test-Path -LiteralPath $SuiteSummaryPath -PathType Leaf)) {
        throw 'tablet intake 离线套件未生成机器可读摘要。'
    }
    $suiteSummary = Get-Content -LiteralPath $SuiteSummaryPath -Raw -Encoding utf8 | ConvertFrom-Json
    $suiteSummaryFields = 'schema_version,suite,generated_at_utc,status,filter,device_access,selected,passed,failed,required_coverage,cases'
    if (($suiteSummary.PSObject.Properties.Name -join ',') -cne $suiteSummaryFields) {
        throw 'tablet intake 离线套件摘要 schema 字段漂移。'
    }
    if ([int]$suiteSummary.schema_version -ne 1 -or
        [string]$suiteSummary.suite -cne 'tablet_intake_offline' -or
        [string]$suiteSummary.device_access -cne 'fake_adb_only' -or
        [string]$suiteSummary.filter -cne '*') {
        throw 'tablet intake 离线套件摘要契约错误。'
    }
    $reportedSelected = [int]$suiteSummary.selected
    $reportedPassed = [int]$suiteSummary.passed
    $reportedFailed = [int]$suiteSummary.failed
    $actualCases = @($suiteSummary.cases)
    $actualPassed = @($actualCases | Where-Object { [string]$_.status -ceq 'passed' }).Count
    $actualFailed = @($actualCases | Where-Object { [string]$_.status -ceq 'failed' }).Count
    if ($reportedSelected -ne $actualCases.Count -or $reportedPassed -ne $actualPassed -or
        $reportedFailed -ne $actualFailed -or $reportedSelected -ne ($reportedPassed + $reportedFailed)) {
        throw 'tablet intake 离线套件摘要计数与用例明细不一致。'
    }
    $coverageFailures = [Collections.Generic.List[string]]::new()
    foreach ($id in $RequiredCoverage) {
        $coverageStatus = Get-TabletCoverageStatus -SuiteSummary $suiteSummary -Id $id
        if ($coverageStatus -cne 'passed') { $coverageFailures.Add("$id=$coverageStatus") }
    }
    $checks.Add([ordered]@{
        id = 'required_matrix'
        status = if ($coverageFailures.Count -eq 0) { 'passed' } else { 'failed' }
        required = @($RequiredCoverage)
        failures = @($coverageFailures)
    })
    $suitePassed = $suiteExitCode -eq 0 -and [string]$suiteSummary.status -ceq 'passed' -and
        $reportedSelected -gt 0 -and $reportedFailed -eq 0
    $checks.Add([ordered]@{
        id = 'suite'
        status = if ($suitePassed) { 'passed' } else { 'failed' }
        exit_code = $suiteExitCode
        selected = [int]$suiteSummary.selected
        passed = [int]$suiteSummary.passed
        failed = [int]$suiteSummary.failed
        log_path = '.checks/tablet-intake-offline.log'
        summary_path = '.checks/tablet-intake-offline-suite-summary.json'
    })
    if (-not $suitePassed -or $coverageFailures.Count -gt 0) {
        throw 'tablet intake 无设备离线矩阵未全部通过。'
    }

    $status = 'passed'
    $exitCode = 0
}
catch {
    $failure = [string]$_.Exception.Message
}
finally {
    if ($reportDirectorySafe) {
        $assurances = [ordered]@{}
        foreach ($id in @('exact_read_only_argv','schema_v5','p0_always_unsupported')) {
            $assurances[$id] = if ($null -eq $suiteSummary) { 'unknown' }
                else { Get-TabletCoverageStatus -SuiteSummary $suiteSummary -Id $id }
        }
        $report = [ordered]@{
            schema_version = 1
            gate = 'tablet_intake_offline'
            generated_at_utc = [DateTime]::UtcNow.ToString('o')
            duration_ms = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
            status = $status
            exit_code = $exitCode
            device_access = 'no_real_device_fake_adb_only'
            failure = $failure
            assurances = $assurances
            checks = @($checks)
            suite = $suiteSummary
        }
        Write-TabletOfflineGateReport -Payload $report
    }
}

if ($status -ceq 'passed') {
    Write-Host "tablet intake offline gate：passed，report=$ReportPath" -ForegroundColor Green
}
else {
    $reportLabel = if ($reportDirectorySafe) { $ReportPath } else { 'not_written_unsafe_report_directory' }
    [Console]::Error.WriteLine("tablet intake offline gate：failed，report=$reportLabel，reason=$failure")
}
exit $exitCode
