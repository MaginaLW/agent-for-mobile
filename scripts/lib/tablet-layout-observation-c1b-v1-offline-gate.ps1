#Requires -Version 7.5
# T-L1 C1b v1 offline gate：exact case/coverage、fresh run binding 与固定原子 machine summary。

Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'tablet-layout-observation-c1b-v1-validator.ps1')

$script:TL1C1BV1OfflineSummarySchema = 'tablet-layout-observation-offline-summary/c1b-v1'
$script:TL1C1BV1OfflineSummaryFileName = 'tablet-tl1-c1b-v1-offline-gate.summary.json'
$script:TL1C1BV1OfflineCrossLayerRequirement = 'direct_focus_refresh_binding_preconditions_kotlin'
$script:TL1C1BV1OfflineSummaryMaximumAgeTicks = [TimeSpan]::FromMinutes(2).Ticks
$script:TL1C1BV1OfflineSummaryMaximumFutureTicks = [TimeSpan]::FromSeconds(5).Ticks
$script:TL1C1BV1OfflineSummaryMaximumDurationTicks = [TimeSpan]::FromMinutes(10).Ticks

$script:TL1C1BV1OfflineCaseDefinitions = @(
    [pscustomobject]@{ case_id='real_shape'; coverage_ids=[string[]]@('real_shape','topology_observed','opaque_not_semantic','capabilities_closed') },
    [pscustomobject]@{ case_id='left_right_mirror'; coverage_ids=[string[]]@('left_right_mirror','no_geometry_role_inference') },
    [pscustomobject]@{ case_id='closed_schema'; coverage_ids=[string[]]@('closed_schema','declared_target_rejected') },
    [pscustomobject]@{ case_id='window_title_source'; coverage_ids=[string[]]@('window_title_source','title_never_toolbar') },
    [pscustomobject]@{ case_id='title_global_ambiguity'; coverage_ids=[string[]]@('title_global_ambiguity','focus_not_target_selector') },
    [pscustomobject]@{ case_id='window_type_code'; coverage_ids=[string[]]@('window_type_code','android16_window_control') },
    [pscustomobject]@{ case_id='window_type_mismatch'; coverage_ids=[string[]]@('window_type_mismatch') },
    [pscustomobject]@{ case_id='root_handle_split'; coverage_ids=[string[]]@('root_handle_split','root_window_mismatch') },
    [pscustomobject]@{ case_id='subtree_complete_opaque'; coverage_ids=[string[]]@('subtree_complete_opaque') },
    [pscustomobject]@{ case_id='subtree_truncated'; coverage_ids=[string[]]@('subtree_truncated','budget_exhausted') },
    [pscustomobject]@{ case_id='subtree_counter_mismatch'; coverage_ids=[string[]]@('subtree_counter_mismatch') },
    [pscustomobject]@{ case_id='scrollable_not_navigation'; coverage_ids=[string[]]@('scrollable_not_navigation','usable_not_semantic') },
    [pscustomobject]@{ case_id='direct_focus_observation'; coverage_ids=[string[]]@('direct_focus_observation','nav_search_not_conversation') },
    [pscustomobject]@{ case_id='focus_inventory_mismatch'; coverage_ids=[string[]]@('focus_inventory_mismatch') },
    [pscustomobject]@{ case_id='cross_frame_drift'; coverage_ids=[string[]]@('cross_frame_drift','consistency_recomputed') },
    [pscustomobject]@{ case_id='atomic_revision'; coverage_ids=[string[]]@('atomic_revision') },
    [pscustomobject]@{ case_id='freshness_stale'; coverage_ids=[string[]]@('freshness_stale') },
    [pscustomobject]@{ case_id='duplicate_key'; coverage_ids=[string[]]@('duplicate_key') },
    [pscustomobject]@{ case_id='int64_lexical_gate'; coverage_ids=[string[]]@('int64_lexical_gate','int64_range_gate') },
    [pscustomobject]@{ case_id='privacy_raw_identity'; coverage_ids=[string[]]@('privacy_raw_identity','privacy_plaintext','privacy_content_digest') },
    [pscustomobject]@{ case_id='v2_frozen'; coverage_ids=[string[]]@('v2_frozen') },
    [pscustomobject]@{ case_id='public_runtime_unavailable_before_read'; coverage_ids=[string[]]@('public_runtime_unavailable_before_read') },
    [pscustomobject]@{ case_id='runtime_origin_sidecar_only'; coverage_ids=[string[]]@('runtime_origin_sidecar_only','runtime_binding_facts_only','verified_claims_closed_without_sidecar') },
    [pscustomobject]@{ case_id='runtime_origin_mismatch'; coverage_ids=[string[]]@('runtime_origin_mismatch') },
    [pscustomobject]@{ case_id='trusted_runtime_fixed_title_hash'; coverage_ids=[string[]]@('trusted_runtime_fixed_title_hash') },
    [pscustomobject]@{ case_id='orphan_node_safe_lookup'; coverage_ids=[string[]]@('orphan_node_safe_lookup') },
    [pscustomobject]@{ case_id='sidecar_closed'; coverage_ids=[string[]]@('sidecar_closed','zero_action_counts','sidecar_symmetric_claim_binding') },
    [pscustomobject]@{ case_id='extra_application'; coverage_ids=[string[]]@('extra_application','exact_two_application_required') },
    [pscustomobject]@{ case_id='extra_display'; coverage_ids=[string[]]@('extra_display') },
    [pscustomobject]@{ case_id='unknown_display'; coverage_ids=[string[]]@('unknown_display','no_default_display_inference') },
    [pscustomobject]@{ case_id='subtree_read_error'; coverage_ids=[string[]]@('subtree_read_error') },
    [pscustomobject]@{ case_id='title_over_budget'; coverage_ids=[string[]]@('title_over_budget','title_read_error','title_failure_no_fallback') },
    [pscustomobject]@{ case_id='visible_ime'; coverage_ids=[string[]]@('visible_ime','visible_ime_no_action') },
    [pscustomobject]@{ case_id='window_label_replacement'; coverage_ids=[string[]]@('window_label_replacement','identity_replacement_blocks_topology') },
    [pscustomobject]@{ case_id='wms_crosswalk_rejected'; coverage_ids=[string[]]@('wms_crosswalk_rejected') },
    [pscustomobject]@{ case_id='capture_in_future'; coverage_ids=[string[]]@('capture_in_future','future_blocks_topology') },
    [pscustomobject]@{ case_id='declared_reason_missing'; coverage_ids=[string[]]@('declared_reason_missing') },
    [pscustomobject]@{ case_id='declared_reason_extra'; coverage_ids=[string[]]@('declared_reason_extra','declared_status_mismatch') },
    [pscustomobject]@{ case_id='diagnostic_status_closed'; coverage_ids=[string[]]@('diagnostic_status_closed') },
    [pscustomobject]@{ case_id='controlled_path_traversal'; coverage_ids=[string[]]@('controlled_path_traversal') },
    [pscustomobject]@{ case_id='controlled_path_reparse'; coverage_ids=[string[]]@('controlled_path_reparse') },
    [pscustomobject]@{ case_id='upstream_t0_v5_reasons_closed'; coverage_ids=[string[]]@('upstream_t0_v5_reasons_closed','upstream_t0_required_p0_reasons') },
    [pscustomobject]@{ case_id='provenance_version_fixed'; coverage_ids=[string[]]@('provenance_version_fixed') },
    [pscustomobject]@{ case_id='v2_blob_oid_freeze'; coverage_ids=[string[]]@('v2_blob_oid_freeze') },
    [pscustomobject]@{ case_id='static_read_only_forbidden_scan'; coverage_ids=[string[]]@('static_read_only_forbidden_scan','direct_focus_cross_layer_requirement') },
    [pscustomobject]@{ case_id='unknown_window_type'; coverage_ids=[string[]]@('unknown_window_type','unknown_type_code_zero_and_unmapped','unknown_type_blocks_topology_and_hidden_ime') },
    [pscustomobject]@{ case_id='incomplete_subtree_focus_unknown'; coverage_ids=[string[]]@('incomplete_subtree_focus_unknown','root_and_subtree_completeness_required','persisted_focus_topology_complete','focus_root_count_and_declared_node_count_required','focus_root_binding_and_geometry_required') },
    [pscustomobject]@{ case_id='truncated_window_inventory'; coverage_ids=[string[]]@('truncated_window_inventory','windows_truncated_blocks_hidden_ime','truncated_inventory_blocks_sidecar_ime_verification') },
    [pscustomobject]@{ case_id='ime_capture_token_binding'; coverage_ids=[string[]]@('ime_capture_token_binding','ime_capture_token_schema_exact','ime_capture_token_mismatch_blocks_hidden_ime') }
)

$script:TL1C1BV1OfflineCoverageByCase = [Collections.Generic.Dictionary[string,string[]]]::new([StringComparer]::Ordinal)
$coverageSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($definition in $script:TL1C1BV1OfflineCaseDefinitions) {
    $script:TL1C1BV1OfflineCoverageByCase.Add([string]$definition.case_id,[string[]]@($definition.coverage_ids))
    foreach ($coverageId in @($definition.coverage_ids)) {
        if (-not $coverageSet.Add([string]$coverageId)) { throw "duplicate C1b required coverage id: $coverageId" }
    }
}
$script:TL1C1BV1OfflineRequiredCoverageIds = [string[]]@($coverageSet)
[Array]::Sort($script:TL1C1BV1OfflineRequiredCoverageIds,[StringComparer]::Ordinal)

function Get-TL1C1BV1OfflineRequiredCaseDefinitions { return @($script:TL1C1BV1OfflineCaseDefinitions) }
function Get-TL1C1BV1OfflineRequiredCaseIds {
    return [string[]]@($script:TL1C1BV1OfflineCaseDefinitions | ForEach-Object { $_.case_id })
}
function Get-TL1C1BV1OfflineRequiredCoverageIds { return [string[]]@($script:TL1C1BV1OfflineRequiredCoverageIds) }
function Get-TL1C1BV1OfflineCoverageForCaseId {
    param([Parameter(Mandatory)][string]$CaseId)
    if ($script:TL1C1BV1OfflineCoverageByCase.ContainsKey($CaseId)) {
        return [string[]]@($script:TL1C1BV1OfflineCoverageByCase[$CaseId])
    }
    return [string[]]@()
}
function Get-TL1C1BV1OfflineOrdinalUniqueStrings {
    param([AllowEmptyCollection()][string[]]$Values=@())
    $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($value in @($Values)){[void]$set.Add([string]$value)}
    $result=[string[]]@($set);[Array]::Sort($result,[StringComparer]::Ordinal);return $result
}

function Add-TL1C1BV1OfflineGateIssue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    foreach($issue in $Issues){if($issue.code -ceq $Code -and $issue.path -ceq $Path){return}}
    $Issues.Add([pscustomobject]@{code=$Code;path=$Path})
}
function Get-TL1C1BV1OfflineGateReasonCodes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues)
    $set=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$codes=[Collections.Generic.List[string]]::new()
    foreach($issue in $Issues){if($set.Add([string]$issue.code)){$codes.Add([string]$issue.code)}}
    return [string[]]$codes.ToArray()
}
function Get-TL1C1BV1OfflineSummarySchemaPath {
    $repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    return Join-Path $repoRoot 'docs\contracts\tablet-layout-observation-c1b-v1-offline-summary.schema.json'
}

function Test-TL1C1BV1OfflineGateReparseChain {
    param(
        [Parameter(Mandatory)][IO.FileSystemInfo]$Item,[Parameter(Mandatory)][string]$StopAt,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory)][string]$Path
    )
    $current=$Item
    while($null -ne $current){
        if(($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){
            Add-TL1C1BV1OfflineGateIssue $Issues 'summary_path_reparse' $Path;return $false
        }
        if($current.FullName.Equals($StopAt,[StringComparison]::OrdinalIgnoreCase)){return $true}
        $current=if($current -is [IO.DirectoryInfo]){$current.Parent}else{$current.Directory}
    }
    Add-TL1C1BV1OfflineGateIssue $Issues 'summary_path_outside_root' $Path;return $false
}

function Get-TL1C1BV1OfflineChecksPaths {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [switch]$CreateChecksRoot
    )
    try{
        if(-not [IO.Path]::IsPathFullyQualified($RepoRoot) -or $RepoRoot.StartsWith('\\',[StringComparison]::Ordinal)){
            Add-TL1C1BV1OfflineGateIssue $Issues 'summary_repo_root_not_local' '/repo_root';return $null
        }
        $repo=[IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        $anchor=[IO.Path]::GetPathRoot($repo).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        if($repo.Equals($anchor,[StringComparison]::OrdinalIgnoreCase) -or
            [IO.DriveInfo]::new([IO.Path]::GetPathRoot($repo)).DriveType -ne [IO.DriveType]::Fixed){
            Add-TL1C1BV1OfflineGateIssue $Issues 'summary_repo_root_unsafe' '/repo_root';return $null
        }
        $repoItem=Get-Item -LiteralPath $repo -Force -ErrorAction Stop
        if(-not $repoItem.PSIsContainer -or -not(Test-TL1C1BV1OfflineGateReparseChain $repoItem $repo $Issues '/repo_root')){return $null}
        $checks=[IO.Path]::GetFullPath((Join-Path $repo '.checks'))
        if(-not $checks.StartsWith($repo+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)){
            Add-TL1C1BV1OfflineGateIssue $Issues 'summary_path_outside_root' '/checks_root';return $null
        }
        if(-not(Test-Path -LiteralPath $checks)){
            if(-not $CreateChecksRoot){Add-TL1C1BV1OfflineGateIssue $Issues 'summary_checks_root_missing' '/checks_root';return $null}
            New-Item -ItemType Directory -Path $checks -ErrorAction Stop|Out-Null
        }
        $checksItem=Get-Item -LiteralPath $checks -Force -ErrorAction Stop
        if(-not $checksItem.PSIsContainer -or $checksItem.Name -cne '.checks' -or
            -not(Test-TL1C1BV1OfflineGateReparseChain $checksItem $repo $Issues '/checks_root')){return $null}
        return [pscustomobject]@{RepoRoot=$repo;ChecksRoot=$checks;SummaryPath=(Join-Path $checks $script:TL1C1BV1OfflineSummaryFileName)}
    }catch{Add-TL1C1BV1OfflineGateIssue $Issues 'summary_path_validation_exception' '/summary_path';return $null}
}

function New-TL1C1BV1OfflineSummaryValidationResult {
    param(
        [bool]$Accepted,[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [long]$TotalCases=0,[long]$PassedCases=0,[long]$FailedCases=0,[long]$CoveredRequired=0
    )
    return [pscustomobject][ordered]@{
        schema='tablet-layout-observation-offline-gate-validation/c1b-v1';accepted=$Accepted
        reason_codes=@(Get-TL1C1BV1OfflineGateReasonCodes $Issues);issues=@($Issues.ToArray())
        total_cases=$TotalCases;passed_cases=$PassedCases;failed_cases=$FailedCases
        required_case_count=[long]$script:TL1C1BV1OfflineCaseDefinitions.Count
        required_coverage_count=[long]$script:TL1C1BV1OfflineRequiredCoverageIds.Count;covered_required_count=$CoveredRequired
        cross_layer_requirements=@($script:TL1C1BV1OfflineCrossLayerRequirement)
        fixture_contract_only=$true;runtime_origin_verified=$false;runtime_evidence=$false
        wechat_window_ownership_verified=$false;window_root_projection_verified=$false
        application_window_topology_verified=$false;ime_hidden_verified=$false
        navigation_pane_verified=$false;conversation_pane_verified=$false
        target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false
        wechat_layout_verified=$false;editor_action_ready=$false;settings_mutation_allowed=$false
        device_action_allowed=$false;screenshot_allowed=$false;ocr_allowed=$false
        p0_capability='unsupported';execution_grant=$false
    }
}

function Test-TL1C1BV1OfflineSummaryObject {
    param(
        [Parameter(Mandatory)]$Summary,[Parameter(Mandatory)][string]$ExpectedGateRunId,
        [DateTimeOffset]$ValidationNowUtc=[DateTimeOffset]::UtcNow
    )
    $issues=[Collections.Generic.List[object]]::new();$total=0L;$passed=0L;$failed=0L;$covered=0L
    try{
        $json=$Summary|ConvertTo-Json -Depth 30 -Compress -ErrorAction Stop
        if(-not($json|Test-Json -SchemaFile (Get-TL1C1BV1OfflineSummarySchemaPath) -ErrorAction SilentlyContinue)){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_schema_invalid' '/';return New-TL1C1BV1OfflineSummaryValidationResult $false $issues
        }
        $snapshot=$json|ConvertFrom-Json -Depth 30 -DateKind String -ErrorAction Stop
        $total=[long]$snapshot.total_cases;$passed=[long]$snapshot.passed_cases;$failed=[long]$snapshot.failed_cases
        if($ExpectedGateRunId -cnotmatch '^gate-[0-9a-f]{32}$' -or $snapshot.gate_run_id -cne $ExpectedGateRunId){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_gate_run_id_mismatch' '/gate_run_id'
        }
        $started=ConvertFrom-TL1C1BV1Timestamp $snapshot.started_at;$finished=ConvertFrom-TL1C1BV1Timestamp $snapshot.finished_at
        if($null -eq $started -or $null -eq $finished -or $finished -lt $started -or
            ($finished-$started).Ticks -gt $script:TL1C1BV1OfflineSummaryMaximumDurationTicks){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_time_invalid' '/finished_at'
        }elseif(($finished-$ValidationNowUtc).Ticks -gt $script:TL1C1BV1OfflineSummaryMaximumFutureTicks -or
            ($ValidationNowUtc-$finished).Ticks -gt $script:TL1C1BV1OfflineSummaryMaximumAgeTicks){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_not_fresh' '/finished_at'
        }
        $cases=@($snapshot.cases);$actualPassed=@($cases|Where-Object status -CEQ 'passed').Count;$actualFailed=@($cases|Where-Object status -CEQ 'failed').Count
        if($cases.Count -eq 0 -or $total -eq 0){Add-TL1C1BV1OfflineGateIssue $issues 'summary_zero_cases' '/cases'}
        if($total -ne $cases.Count -or $passed -ne $actualPassed -or $failed -ne $actualFailed -or $passed+$failed -ne $total){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_count_mismatch' '/total_cases'
        }
        if($failed -ne 0 -or $snapshot.status -cne 'passed' -or [long]$snapshot.test_exit_code -ne 0){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_failures_present' '/failed_cases'
        }
        $caseIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $actualCoverage=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($case in $cases){
            $caseId=[string]$case.case_id
            if(-not $caseIds.Add($caseId)){Add-TL1C1BV1OfflineGateIssue $issues 'summary_duplicate_case_id' '/cases'}
            $declared=[string[]]@(Get-TL1C1BV1OfflineOrdinalUniqueStrings ([string[]]@($case.coverage_ids)))
            $expected=[string[]]@(Get-TL1C1BV1OfflineCoverageForCaseId $caseId);[Array]::Sort($expected,[StringComparer]::Ordinal)
            if(($declared -join "`n") -cne ($expected -join "`n")){
                Add-TL1C1BV1OfflineGateIssue $issues 'summary_case_coverage_mismatch' "/cases/$caseId/coverage_ids"
            }
            if($case.status -ceq 'passed'){foreach($coverageId in @($case.coverage_ids)){[void]$actualCoverage.Add([string]$coverageId)}}
        }
        foreach($requiredCase in @(Get-TL1C1BV1OfflineRequiredCaseIds)){
            if(-not $caseIds.Contains($requiredCase)){Add-TL1C1BV1OfflineGateIssue $issues 'summary_required_case_missing' "/cases/$requiredCase"}
        }
        foreach($caseId in $caseIds){
            if(-not $script:TL1C1BV1OfflineCoverageByCase.ContainsKey($caseId)){Add-TL1C1BV1OfflineGateIssue $issues 'summary_unexpected_case' "/cases/$caseId"}
        }
        foreach($coverageId in $script:TL1C1BV1OfflineRequiredCoverageIds){
            if($actualCoverage.Contains($coverageId)){$covered++}else{Add-TL1C1BV1OfflineGateIssue $issues 'summary_required_coverage_missing' "/coverage_ids/$coverageId"}
        }
        foreach($coverageId in $actualCoverage){
            if($script:TL1C1BV1OfflineRequiredCoverageIds -cnotcontains $coverageId){Add-TL1C1BV1OfflineGateIssue $issues 'summary_unexpected_coverage' "/coverage_ids/$coverageId"}
        }
        $computedCoverage=[string[]]@(Get-TL1C1BV1OfflineOrdinalUniqueStrings ([string[]]@($actualCoverage)))
        $declaredCoverage=[string[]]@($snapshot.coverage_ids)
        if(($computedCoverage -join "`n") -cne ($declaredCoverage -join "`n")){Add-TL1C1BV1OfflineGateIssue $issues 'summary_coverage_mismatch' '/coverage_ids'}
        if($total -ne $script:TL1C1BV1OfflineCaseDefinitions.Count -or
            [long]$snapshot.required_coverage_count -ne $script:TL1C1BV1OfflineRequiredCoverageIds.Count -or
            [long]$snapshot.covered_required_count -ne $covered -or $covered -ne $script:TL1C1BV1OfflineRequiredCoverageIds.Count){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_required_count_mismatch' '/required_coverage_count'
        }
    }catch{Add-TL1C1BV1OfflineGateIssue $issues 'summary_validation_exception' '/'}
    return New-TL1C1BV1OfflineSummaryValidationResult ($issues.Count -eq 0) $issues $total $passed $failed $covered
}

function New-TL1C1BV1OfflineCompleteSummary {
    param(
        [Parameter(Mandatory)][string]$GateRunId,[Parameter(Mandatory)][object[]]$CaseResults,
        [Parameter(Mandatory)][DateTimeOffset]$StartedAt,[DateTimeOffset]$FinishedAt=[DateTimeOffset]::UtcNow
    )
    $coverage=[string[]]@(Get-TL1C1BV1OfflineOrdinalUniqueStrings ([string[]]@($CaseResults|Where-Object status -CEQ 'passed'|ForEach-Object coverage_ids)))
    $failed=@($CaseResults|Where-Object status -CEQ 'failed').Count
    return [pscustomobject][ordered]@{
        schema=$script:TL1C1BV1OfflineSummarySchema;gate_run_id=$GateRunId
        started_at=$StartedAt.UtcDateTime.ToString($script:TL1C1BV1TimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
        finished_at=$FinishedAt.UtcDateTime.ToString($script:TL1C1BV1TimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
        suite=$script:TL1C1BV1Schema;status=if($failed -eq 0){'passed'}else{'failed'};test_exit_code=if($failed -eq 0){0L}else{1L}
        total_cases=[long]$CaseResults.Count;passed_cases=[long]@($CaseResults|Where-Object status -CEQ 'passed').Count;failed_cases=[long]$failed
        required_coverage_count=[long]$script:TL1C1BV1OfflineRequiredCoverageIds.Count
        covered_required_count=[long]@($script:TL1C1BV1OfflineRequiredCoverageIds|Where-Object{$coverage -ccontains $_}).Count
        coverage_ids=$coverage;cases=@($CaseResults);cross_layer_requirements=@($script:TL1C1BV1OfflineCrossLayerRequirement)
        fixture_contract_only=$true;runtime_origin_verified=$false;runtime_evidence=$false
        wechat_window_ownership_verified=$false;window_root_projection_verified=$false
        application_window_topology_verified=$false;ime_hidden_verified=$false
        navigation_pane_verified=$false;conversation_pane_verified=$false
        target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false
        wechat_layout_verified=$false;editor_action_ready=$false;settings_mutation_allowed=$false
        device_action_allowed=$false;screenshot_allowed=$false;ocr_allowed=$false;p0_capability='unsupported';execution_grant=$false
    }
}

function Write-TL1C1BV1OfflineSummaryAtomic {
    param(
        [Parameter(Mandatory)]$Summary,[Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SummaryPath,[Parameter(Mandatory)][string]$GateRunId
    )
    $validation=Test-TL1C1BV1OfflineSummaryObject $Summary $GateRunId
    if(-not $validation.accepted){throw "summary invalid before write: $($validation.reason_codes -join ',')"}
    $issues=[Collections.Generic.List[object]]::new();$paths=Get-TL1C1BV1OfflineChecksPaths $RepoRoot $issues -CreateChecksRoot
    if($null -eq $paths -or $issues.Count -ne 0 -or
        -not([IO.Path]::GetFullPath($SummaryPath)).Equals($paths.SummaryPath,[StringComparison]::Ordinal)){
        throw "unsafe fixed summary destination: $(@(Get-TL1C1BV1OfflineGateReasonCodes $issues) -join ',')"
    }
    if(Test-Path -LiteralPath $paths.SummaryPath){
        $existing=Get-Item -LiteralPath $paths.SummaryPath -Force -ErrorAction Stop
        if($existing.PSIsContainer -or -not(Test-TL1C1BV1OfflineGateReparseChain $existing $paths.ChecksRoot $issues '/summary_path')){
            throw "unsafe existing summary: $(@(Get-TL1C1BV1OfflineGateReasonCodes $issues) -join ',')"
        }
    }
    $raw=$Summary|ConvertTo-Json -Depth 30 -ErrorAction Stop
    $temp=Join-Path $paths.ChecksRoot ".tablet-tl1-c1b-v1-summary.$GateRunId.$([guid]::NewGuid().ToString('N')).tmp"
    $stream=$null;$writer=$null
    try{
        $stream=[IO.FileStream]::new($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false,$true),4096,$true)
        $writer.Write($raw);$writer.Flush();$stream.Flush($true);$writer.Dispose();$writer=$null;$stream.Dispose();$stream=$null
        [IO.File]::Move($temp,$paths.SummaryPath,$true)
    }finally{
        if($null -ne $writer){$writer.Dispose()};if($null -ne $stream){$stream.Dispose()}
        if([IO.File]::Exists($temp) -and [IO.Path]::GetDirectoryName($temp).Equals($paths.ChecksRoot,[StringComparison]::Ordinal) -and
            [IO.Path]::GetFileName($temp).StartsWith('.tablet-tl1-c1b-v1-summary.gate-',[StringComparison]::Ordinal)){[IO.File]::Delete($temp)}
    }
}

function Read-TL1C1BV1OfflineSummary {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$SummaryPath,
        [Parameter(Mandatory)][string]$ExpectedGateRunId,[DateTimeOffset]$ValidationNowUtc=[DateTimeOffset]::UtcNow
    )
    $issues=[Collections.Generic.List[object]]::new()
    try{
        $paths=Get-TL1C1BV1OfflineChecksPaths $RepoRoot $issues
        if($null -eq $paths -or -not([IO.Path]::GetFullPath($SummaryPath)).Equals($paths.SummaryPath,[StringComparison]::Ordinal)){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_path_not_fixed' '/summary_path';return New-TL1C1BV1OfflineSummaryValidationResult $false $issues
        }
        $file=Get-Item -LiteralPath $paths.SummaryPath -Force -ErrorAction Stop
        if($file.PSIsContainer -or -not(Test-TL1C1BV1OfflineGateReparseChain $file $paths.ChecksRoot $issues '/summary_path')){
            return New-TL1C1BV1OfflineSummaryValidationResult $false $issues
        }
        $bytes=[IO.File]::ReadAllBytes($file.FullName)
        if($bytes.Length -le 0 -or $bytes.Length -gt 1048576 -or
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_document_invalid' '/';return New-TL1C1BV1OfflineSummaryValidationResult $false $issues
        }
        $raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);$strictIssues=[Collections.Generic.List[object]]::new()
        $summary=ConvertFrom-TL1C1BV1StrictJson $raw $strictIssues
        if($null -eq $summary -or $strictIssues.Count -ne 0){
            Add-TL1C1BV1OfflineGateIssue $issues 'summary_json_invalid' '/';return New-TL1C1BV1OfflineSummaryValidationResult $false $issues
        }
        return Test-TL1C1BV1OfflineSummaryObject $summary $ExpectedGateRunId $ValidationNowUtc
    }catch{Add-TL1C1BV1OfflineGateIssue $issues 'summary_validation_exception' '/';return New-TL1C1BV1OfflineSummaryValidationResult $false $issues}
}

function Invoke-TabletLayoutObservationC1BV1OfflineGate {
    [CmdletBinding()]param([string]$RepoRoot=(Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    $testPath=Join-Path $RepoRoot 'scripts\tests\tablet-layout-observation-c1b-v1-offline.ps1'
    if(-not(Test-Path -LiteralPath $testPath -PathType Leaf)){return [pscustomobject]@{passed=$false;exit_code=1;output='missing C1b offline test';cases=0;coverage='0/0'}}
    $pwsh=Join-Path $PSHOME 'pwsh.exe';if(-not(Test-Path -LiteralPath $pwsh)){$pwsh='pwsh'}
    $output=& $pwsh -NoLogo -NoProfile -NonInteractive -File $testPath 2>&1|Out-String;$exitCode=$LASTEXITCODE
    $match=[regex]::Match($output,'C1B_OFFLINE_PASS cases=([0-9]+) coverage=([0-9]+/[0-9]+)')
    $requiredCases=$script:TL1C1BV1OfflineCaseDefinitions.Count
    $requiredCoverage="$($script:TL1C1BV1OfflineRequiredCoverageIds.Count)/$($script:TL1C1BV1OfflineRequiredCoverageIds.Count)"
    return [pscustomobject]@{
        passed=$exitCode -eq 0 -and $match.Success -and [int]$match.Groups[1].Value -eq $requiredCases -and $match.Groups[2].Value -ceq $requiredCoverage
        exit_code=$exitCode;output=$output.Trim();cases=if($match.Success){[int]$match.Groups[1].Value}else{0}
        coverage=if($match.Success){$match.Groups[2].Value}else{'0/0'}
        cross_layer_requirements=@($script:TL1C1BV1OfflineCrossLayerRequirement)
    }
}
