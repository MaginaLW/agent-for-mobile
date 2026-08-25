#Requires -Version 7.5
# T-L1 v2 diagnostic-only offline gate 的 exact coverage 与原子 machine summary。

Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'tablet-layout-observation-v2-validator.ps1')

$script:TL1V2OfflineSummarySchema = 'tablet-layout-observation-offline-summary/v2'
$script:TL1V2OfflineSummaryFileName = 'tablet-tl1-v2-offline-gate.summary.json'
$script:TL1V2OfflineRequiredCoverageIds = [string[]]@(
    'upstream_t0_block_preserved',
    'probe_only_route',
    'native_multi_landscape_two_window',
    'window_identity_namespace',
    'window_label_bijection',
    'window_identity_replacement',
    'window_root_owner_conflict',
    'window_pane_bijection',
    'cross_window_region',
    'target_title_global_uniqueness',
    'same_y_wrong_window',
    'target_window_pane_drift',
    'focus_absent_perception',
    'focus_target_conflict',
    'focus_fallback_insufficient',
    'hidden_ime_layout_only',
    'ime_target_editor_binding',
    'overlay_target_occlusion',
    'multi_display_blocked',
    'atomic_capture_revision',
    'run_local_window_privacy',
    'native_setting_unchanged',
    'phone_p0_unchanged',
    'p0_exec_false'
)
$script:TL1V2OfflineRequiredCaseIds = [string[]]@(
    $script:TL1V2OfflineRequiredCoverageIds | ForEach-Object { $_ -replace '_','-' }
)
$script:TL1V2OfflineCoverageByCase = [Collections.Generic.Dictionary[string,string[]]]::new(
    [StringComparer]::Ordinal
)
for ($index = 0; $index -lt $script:TL1V2OfflineRequiredCoverageIds.Count; $index++) {
    $script:TL1V2OfflineCoverageByCase.Add(
        $script:TL1V2OfflineRequiredCaseIds[$index],
        [string[]]@($script:TL1V2OfflineRequiredCoverageIds[$index])
    )
}

function Get-TL1V2OfflineRequiredCoverageIds {
    return [string[]]@($script:TL1V2OfflineRequiredCoverageIds)
}

function Get-TL1V2OfflineRequiredCaseIds {
    return [string[]]@($script:TL1V2OfflineRequiredCaseIds)
}

function Get-TL1V2OfflineCoverageForCaseId {
    param([Parameter(Mandatory)][string]$CaseId)
    if ($script:TL1V2OfflineCoverageByCase.ContainsKey($CaseId)) {
        return [string[]]@($script:TL1V2OfflineCoverageByCase[$CaseId])
    }
    return [string[]]@()
}

function Get-TL1V2OrdinalUniqueStrings {
    param([AllowEmptyCollection()][string[]]$Values = @())
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in @($Values)) { [void]$set.Add([string]$value) }
    $result = [string[]]@($set)
    [Array]::Sort($result, [StringComparer]::Ordinal)
    return [string[]]$result
}

function Get-TL1V2OfflineSummarySchemaPath {
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    return Join-Path $repoRoot 'docs\contracts\tablet-layout-observation-offline-summary-v2.schema.json'
}

function Get-TL1V2OfflineChecksPaths {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [switch]$CreateChecksRoot
    )
    try {
        if (-not [IO.Path]::IsPathFullyQualified($RepoRoot) -or
            $RepoRoot.StartsWith('\\', [StringComparison]::Ordinal)) {
            Add-TL1V2Issue $Issues 'summary_repo_root_not_local' '/repo_root'
            return $null
        }
        $repo = [IO.Path]::GetFullPath($RepoRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        $anchor = [IO.Path]::GetPathRoot($repo).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        if ($repo.Equals($anchor, [StringComparison]::OrdinalIgnoreCase)) {
            Add-TL1V2Issue $Issues 'summary_repo_root_too_broad' '/repo_root'
            return $null
        }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($repo))
        if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
            Add-TL1V2Issue $Issues 'summary_repo_root_not_fixed_local' '/repo_root'
            return $null
        }
        $repoItem = Get-Item -LiteralPath $repo -Force -ErrorAction Stop
        if (-not $repoItem.PSIsContainer -or -not (Test-TL1V2ReparseChain $repoItem $Issues '/repo_root')) {
            return $null
        }
        $checks = [IO.Path]::GetFullPath((Join-Path $repo '.checks'))
        if (-not $checks.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
            Add-TL1V2Issue $Issues 'summary_checks_root_outside_repo' '/checks_root'
            return $null
        }
        if (-not (Test-Path -LiteralPath $checks)) {
            if (-not $CreateChecksRoot) {
                Add-TL1V2Issue $Issues 'summary_checks_root_missing' '/checks_root'
                return $null
            }
            New-Item -ItemType Directory -Path $checks -ErrorAction Stop | Out-Null
        }
        $checksItem = Get-Item -LiteralPath $checks -Force -ErrorAction Stop
        if (-not $checksItem.PSIsContainer -or $checksItem.Name -cne '.checks' -or
            -not (Test-TL1V2ReparseChain $checksItem $Issues '/checks_root')) { return $null }
        $summary = Join-Path $checks $script:TL1V2OfflineSummaryFileName
        return [pscustomobject]@{ RepoRoot=$repo; ChecksRoot=$checks; SummaryPath=$summary }
    }
    catch {
        Add-TL1V2Issue $Issues 'summary_path_validation_exception' '/summary_path'
        return $null
    }
}

function New-TL1V2OfflineSummaryValidationResult {
    param(
        [bool]$Accepted,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [long]$TotalCases = 0,
        [long]$PassedCases = 0,
        [long]$FailedCases = 0,
        [long]$CoveredRequired = 0
    )
    return [pscustomobject][ordered]@{
        schema = 'tablet-layout-observation-offline-gate-validation/v2'
        accepted = $Accepted
        reason_codes = @(Get-TL1V2ReasonCodes $Issues)
        issues = @($Issues.ToArray())
        total_cases = $TotalCases
        passed_cases = $PassedCases
        failed_cases = $FailedCases
        required_case_count = [long]$script:TL1V2OfflineRequiredCaseIds.Count
        required_coverage_count = [long]$script:TL1V2OfflineRequiredCoverageIds.Count
        covered_required_count = $CoveredRequired
        runtime_evidence = $false
        layout_accepted = $false
        p0_capability = 'unsupported'
        execution_grant = $false
    }
}

function Test-TL1V2OfflineSummaryObject {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$ExpectedGateRunId
    )
    $issues = [Collections.Generic.List[object]]::new()
    $total = 0L; $passed = 0L; $failed = 0L; $covered = 0L
    try {
        $schemaPath = Get-TL1V2OfflineSummarySchemaPath
        $json = $Summary | ConvertTo-Json -Depth 30 -Compress -ErrorAction Stop
        if (-not ($json | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            Add-TL1V2Issue $issues 'summary_schema_invalid' '/'
            return New-TL1V2OfflineSummaryValidationResult $false $issues
        }
        $snapshot = $json | ConvertFrom-Json -Depth 30 -DateKind String -ErrorAction Stop
        $total = [long]$snapshot.total_cases
        $passed = [long]$snapshot.passed_cases
        $failed = [long]$snapshot.failed_cases
        if ($snapshot.gate_run_id -cne $ExpectedGateRunId) {
            Add-TL1V2Issue $issues 'summary_gate_run_id_mismatch' '/gate_run_id'
        }
        $started = ConvertFrom-TL1V2Timestamp $snapshot.started_at
        $finished = ConvertFrom-TL1V2Timestamp $snapshot.finished_at
        if ($null -eq $started -or $null -eq $finished -or $finished -lt $started) {
            Add-TL1V2Issue $issues 'summary_time_invalid' '/finished_at'
        }
        $cases = @($snapshot.cases)
        $actualPassed = @($cases | Where-Object { $_.status -ceq 'passed' }).Count
        $actualFailed = @($cases | Where-Object { $_.status -ceq 'failed' }).Count
        if ($cases.Count -eq 0 -or $total -eq 0) { Add-TL1V2Issue $issues 'summary_zero_cases' '/cases' }
        if ($total -ne $cases.Count -or $passed -ne $actualPassed -or $failed -ne $actualFailed -or
            $passed + $failed -ne $total) {
            Add-TL1V2Issue $issues 'summary_count_mismatch' '/total_cases'
        }
        if ($failed -ne 0 -or $snapshot.status -cne 'passed' -or [long]$snapshot.test_exit_code -ne 0) {
            Add-TL1V2Issue $issues 'summary_failures_present' '/failed_cases'
        }
        $caseIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $coverageSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($case in $cases) {
            $caseId = [string]$case.case_id
            if (-not $caseIds.Add($caseId)) { Add-TL1V2Issue $issues 'summary_duplicate_case_id' '/cases' }
            $declared = [string[]]@(Get-TL1V2OrdinalUniqueStrings ([string[]]@($case.coverage_ids)))
            $expected = [string[]]@(Get-TL1V2OfflineCoverageForCaseId $caseId)
            if (($declared -join "`n") -cne ($expected -join "`n")) {
                Add-TL1V2Issue $issues 'summary_case_coverage_mismatch' "/cases/$caseId/coverage_ids"
            }
            if ($case.status -ceq 'passed') {
                foreach ($coverageId in @($case.coverage_ids)) { [void]$coverageSet.Add([string]$coverageId) }
            }
        }
        foreach ($requiredCase in $script:TL1V2OfflineRequiredCaseIds) {
            if (-not $caseIds.Contains($requiredCase)) {
                Add-TL1V2Issue $issues 'summary_required_case_missing' "/cases/$requiredCase"
            }
        }
        foreach ($caseId in $caseIds) {
            if ($script:TL1V2OfflineRequiredCaseIds -cnotcontains $caseId) {
                Add-TL1V2Issue $issues 'summary_unexpected_case' "/cases/$caseId"
            }
        }
        foreach ($coverageId in $script:TL1V2OfflineRequiredCoverageIds) {
            if ($coverageSet.Contains($coverageId)) { $covered++ }
            else { Add-TL1V2Issue $issues 'summary_required_coverage_missing' "/coverage_ids/$coverageId" }
        }
        foreach ($coverageId in $coverageSet) {
            if ($script:TL1V2OfflineRequiredCoverageIds -cnotcontains $coverageId) {
                Add-TL1V2Issue $issues 'summary_unexpected_coverage' "/coverage_ids/$coverageId"
            }
        }
        $computedCoverage = [string[]]@(Get-TL1V2OrdinalUniqueStrings ([string[]]@($coverageSet)))
        $declaredCoverage = [string[]]@($snapshot.coverage_ids)
        if (($computedCoverage -join "`n") -cne ($declaredCoverage -join "`n")) {
            Add-TL1V2Issue $issues 'summary_coverage_mismatch' '/coverage_ids'
        }
        if ($total -ne $script:TL1V2OfflineRequiredCaseIds.Count -or
            [long]$snapshot.required_coverage_count -ne $script:TL1V2OfflineRequiredCoverageIds.Count -or
            [long]$snapshot.covered_required_count -ne $covered) {
            Add-TL1V2Issue $issues 'summary_required_count_mismatch' '/required_coverage_count'
        }
    }
    catch { Add-TL1V2Issue $issues 'summary_validation_exception' '/' }
    return New-TL1V2OfflineSummaryValidationResult ($issues.Count -eq 0) $issues $total $passed $failed $covered
}

function Write-TL1V2OfflineSummaryAtomic {
    param(
        [Parameter(Mandatory)]$Summary,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$GateRunId
    )
    $issues = [Collections.Generic.List[object]]::new()
    $paths = Get-TL1V2OfflineChecksPaths $RepoRoot $issues -CreateChecksRoot
    if ($null -eq $paths -or $issues.Count -ne 0 -or
        -not ([IO.Path]::GetFullPath($SummaryPath)).Equals($paths.SummaryPath, [StringComparison]::Ordinal)) {
        throw "unsafe fixed summary destination: $(@(Get-TL1V2ReasonCodes $issues) -join ',')"
    }
    if (Test-Path -LiteralPath $paths.SummaryPath) {
        $existing = Resolve-TL1V2ControlledPath $paths.SummaryPath $paths.ChecksRoot $issues
        if ($null -eq $existing) { throw "unsafe existing summary: $(@(Get-TL1V2ReasonCodes $issues) -join ',')" }
        Read-TL1V2ControlledUtf8 $existing $issues | Out-Null
        if ($issues.Count -ne 0) { throw "unsafe existing summary: $(@(Get-TL1V2ReasonCodes $issues) -join ',')" }
    }
    if ($Summary.gate_run_id -cne $GateRunId) { throw 'summary gate_run_id mismatch before write' }
    $raw = $Summary | ConvertTo-Json -Depth 30 -ErrorAction Stop
    if (-not ($raw | Test-Json -SchemaFile (Get-TL1V2OfflineSummarySchemaPath) -ErrorAction SilentlyContinue)) {
        throw 'summary schema invalid before write'
    }
    $temp = Join-Path $paths.ChecksRoot (
        ".tablet-tl1-v2-summary.$GateRunId.$([guid]::NewGuid().ToString('N')).tmp"
    )
    $stream = $null; $writer = $null
    try {
        $stream = [IO.FileStream]::new(
            $temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None,
            4096, [IO.FileOptions]::WriteThrough
        )
        $handleIssues = [Collections.Generic.List[object]]::new()
        if (-not (Test-TL1V2OpenedFileIdentity $stream.SafeFileHandle $temp $handleIssues)) {
            throw "summary temp identity invalid: $(@(Get-TL1V2ReasonCodes $handleIssues) -join ',')"
        }
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false, $true), 4096, $true)
        $writer.Write($raw); $writer.Flush(); $stream.Flush($true)
        $writer.Dispose(); $writer = $null; $stream.Dispose(); $stream = $null
        [IO.File]::Move($temp, $paths.SummaryPath, $true)
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temp) -and
            [IO.Path]::GetDirectoryName($temp).Equals($paths.ChecksRoot, [StringComparison]::Ordinal) -and
            [IO.Path]::GetFileName($temp).StartsWith('.tablet-tl1-v2-summary.gate-', [StringComparison]::Ordinal)) {
            [IO.File]::Delete($temp)
        }
    }
}

function Read-TL1V2OfflineSummary {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ExpectedGateRunId
    )
    $issues = [Collections.Generic.List[object]]::new()
    try {
        $paths = Get-TL1V2OfflineChecksPaths $RepoRoot $issues
        if ($null -eq $paths -or -not ([IO.Path]::GetFullPath($SummaryPath)).Equals(
                $paths.SummaryPath, [StringComparison]::Ordinal
            )) {
            Add-TL1V2Issue $issues 'summary_path_not_fixed' '/summary_path'
            return New-TL1V2OfflineSummaryValidationResult $false $issues
        }
        $controlled = Resolve-TL1V2ControlledPath $paths.SummaryPath $paths.ChecksRoot $issues
        if ($null -eq $controlled) { return New-TL1V2OfflineSummaryValidationResult $false $issues }
        $raw = Read-TL1V2ControlledUtf8 $controlled $issues
        if ($null -eq $raw) { return New-TL1V2OfflineSummaryValidationResult $false $issues }
        $summary = ConvertFrom-TL1V2StrictJson $raw $issues
        if ($null -eq $summary) { return New-TL1V2OfflineSummaryValidationResult $false $issues }
        return Test-TL1V2OfflineSummaryObject $summary $ExpectedGateRunId
    }
    catch {
        Add-TL1V2Issue $issues 'summary_validation_exception' '/'
        return New-TL1V2OfflineSummaryValidationResult $false $issues
    }
}
