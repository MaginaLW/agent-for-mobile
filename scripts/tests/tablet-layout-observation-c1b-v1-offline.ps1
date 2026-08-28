#Requires -Version 7.5

[CmdletBinding()]
param(
    [string]$SummaryPath,
    [string]$GateRunId
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'scripts\lib\tablet-layout-observation-c1b-v1-offline-gate.ps1')
. (Join-Path $repoRoot 'scripts\lib\tablet-layout-c1a.ps1')
. (Join-Path $repoRoot 'scripts\lib\tablet-layout-c1b.ps1')

$fixturePath = Join-Path $PSScriptRoot 'fixtures\tablet-layout-observation\c1b-v1\real-shape-topology-only.json'
$buildEnvironmentFixturePath = Join-Path $PSScriptRoot 'fixtures\tablet-layout-c1b-build-environment.json'
$baseRaw = [IO.File]::ReadAllText($fixturePath, [Text.UTF8Encoding]::new($false, $true))
$tempRoot = [IO.Directory]::CreateTempSubdirectory('tl1c1bv1-offline-')
$script:CaseCount = 0
$script:Coverage = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:CaseResults = [Collections.Generic.List[object]]::new()
$script:StartedAt = [DateTimeOffset]::UtcNow

function Copy-C1BBaseDocument {
    return ($baseRaw | ConvertFrom-Json -Depth 100 -DateKind String) |
        ConvertTo-Json -Depth 100 -Compress |
        ConvertFrom-Json -Depth 100 -DateKind String
}

function Copy-C1BValue {
    param([Parameter(Mandatory)]$Value)
    return $Value | ConvertTo-Json -Depth 100 -Compress |
        ConvertFrom-Json -Depth 100 -DateKind String
}

function Set-C1BFreshTimes {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][DateTimeOffset]$Now)
    $t0 = $Now.AddSeconds(-4)
    $c1 = $Now.AddSeconds(-2)
    $c2 = $Now.AddSeconds(-1)
    $format = $script:TL1C1BV1TimestampFormat
    $Document.upstream_t0.captured_at = $t0.UtcDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $Document.frames[0].captured_at = $c1.UtcDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $Document.frames[1].captured_at = $c2.UtcDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $Document.captured_at = $Document.frames[1].captured_at
}

function Add-C1BDeclaredReason {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Code)
    $Document.reason_codes = [string[]]@(@($Document.reason_codes) + $Code | Sort-Object -Unique)
}

function Remove-C1BDeclaredReason {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Code)
    $Document.reason_codes = [string[]]@($Document.reason_codes | Where-Object { $_ -cne $Code })
}

function Set-C1BFocusUnknown {
    param([Parameter(Mandatory)]$Document)
    foreach ($frame in $Document.frames) {
        $frame.focus.status = 'unknown'
        $frame.focus.window_label = $null
        $frame.focus.node_label = $null
    }
}

function Write-C1BDocument {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path $tempRoot.FullName "$Name.json"
    $raw = $Document | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($path, $raw, [Text.UTF8Encoding]::new($false))
    return $path
}

function Write-C1BRaw {
    param([Parameter(Mandatory)][string]$Raw, [Parameter(Mandatory)][string]$Name)
    $path = Join-Path $tempRoot.FullName "$Name.json"
    [IO.File]::WriteAllText($path, $Raw, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-C1BFixture {
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)][string]$Name,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    Set-C1BFreshTimes $Document $Now
    $path = Write-C1BDocument $Document $Name
    return Test-TabletLayoutObservationC1BV1File -Path $path -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $Now
}

function Assert-C1B {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-C1BCode {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Code)
    Assert-C1B ($Result.reason_codes -ccontains $Code) "expected reason $Code; got $($Result.reason_codes -join ',')"
}

function Complete-C1BCase {
    param([Parameter(Mandatory)][string[]]$Coverage)
    $caseId = [string]$Coverage[0]
    $actual = [string[]]@(Get-TL1C1BV1OfflineOrdinalUniqueStrings $Coverage)
    $expected = [string[]]@(Get-TL1C1BV1OfflineCoverageForCaseId $caseId)
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "ASSERT: authoritative case/coverage mismatch for $caseId"
    }
    $script:CaseCount++
    foreach ($item in $Coverage) { [void]$script:Coverage.Add($item) }
    $script:CaseResults.Add([pscustomobject][ordered]@{
        case_id=$caseId; status='passed'; coverage_ids=[string[]]@($Coverage)
    })
}

try {
    # 1. 真实 C1a 形态：双 window/root projection 成立；root-only opaque 不产生任何语义或能力结论。
    $doc = Copy-C1BBaseDocument
    $result = Invoke-C1BFixture $doc 'real-shape'
    Assert-C1B $result.fixture_contract_valid 'real-shape fixture contract must be valid'
    Assert-C1B $result.application_window_topology_observed 'real-shape topology must be observed'
    Assert-C1B (-not $result.application_window_topology_verified) 'fixture must not verify runtime topology'
    Assert-C1B (-not $result.semantic_tree_usable) 'complete root-only tree must remain opaque'
    Assert-C1BCode $result 'semantic_subtree_opaque'
    Assert-C1B (-not $result.navigation_pane_verified -and -not $result.conversation_pane_verified -and
        -not $result.target_conversation_verified -and -not $result.layout_accepted -and
        $result.p0_capability -ceq 'unsupported' -and -not $result.execution_grant) 'semantic/action constants must remain closed'
    Complete-C1BCase @('real_shape','topology_observed','opaque_not_semantic','capabilities_closed')

    # 2. Metamorphic mirror：交换 application window 左右位置后 claim vector 不变。
    $mirror = Copy-C1BBaseDocument
    foreach ($frame in $mirror.frames) {
        $aw1 = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0]
        $aw2 = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw2')[0]
        $ap1 = @($frame.panes | Where-Object pane_label -CEQ 'ap1')[0]
        $ap2 = @($frame.panes | Where-Object pane_label -CEQ 'ap2')[0]
        $leftBounds = $aw1.bounds; $leftTouchable = $aw1.touchable_bounds
        $aw1.bounds = $aw2.bounds; $aw1.touchable_bounds = $aw2.touchable_bounds
        $aw2.bounds = $leftBounds; $aw2.touchable_bounds = $leftTouchable
        $ap1.bounds = $aw1.bounds; $ap2.bounds = $aw2.bounds
    }
    $mirrorResult = Invoke-C1BFixture $mirror 'left-right-mirror'
    Assert-C1B $mirrorResult.fixture_contract_valid 'mirror must remain contract-valid'
    foreach ($claim in @(
            'application_window_topology_observed','semantic_tree_usable','navigation_pane_verified',
            'conversation_pane_verified','target_conversation_verified','layout_accepted'
        )) {
        Assert-C1B ([bool]$mirrorResult.$claim -eq [bool]$result.$claim) "mirror changed claim $claim"
    }
    Complete-C1BCase @('left_right_mirror','no_geometry_role_inference')

    # 3. package/focus/title 仍不能由 caller 声明 target；closed schema 拒绝声明字段。
    $forged = Copy-C1BBaseDocument
    $forged | Add-Member -NotePropertyName declared_target_window -NotePropertyValue 'aw2'
    $forgedResult = Invoke-C1BFixture $forged 'declared-target'
    Assert-C1B (-not $forgedResult.fixture_contract_valid) 'declared target must fail closed schema'
    Assert-C1BCode $forgedResult 'json_schema_validation_failed'
    Complete-C1BCase @('closed_schema','declared_target_rejected')

    # 4. 唯一 native window-title match 只是一条 window-bound 诊断，不形成 target/toolbar。
    $title = Copy-C1BBaseDocument
    foreach ($frame in $title.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw2')[0].expected_window_title_match = 'match'
    }
    $titleResult = Invoke-C1BFixture $title 'window-title-exact-only'
    Assert-C1B $titleResult.fixture_contract_valid 'window title match-only must remain a valid diagnostic'
    Assert-C1B (-not $titleResult.target_conversation_verified -and -not $titleResult.target_regions_verified -and
        -not $titleResult.layout_accepted) 'window title alone promoted target/layout'
    Complete-C1BCase @('window_title_source','title_never_toolbar')

    # 5. 两窗都 title match 仍只保持歧义，不按 focus/side 选 aw2。
    $ambiguousTitle = Copy-C1BBaseDocument
    foreach ($frame in $ambiguousTitle.frames) {
        foreach ($window in @($frame.a11y_windows | Where-Object type -CEQ 'application')) {
            $window.expected_window_title_match = 'match'
        }
    }
    $ambiguousTitleResult = Invoke-C1BFixture $ambiguousTitle 'window-title-ambiguous'
    Assert-C1B $ambiguousTitleResult.fixture_contract_valid 'ambiguous title inventory must be representable'
    Assert-C1B (-not $ambiguousTitleResult.target_conversation_verified) 'ambiguous title selected target'
    Complete-C1BCase @('title_global_ambiguity','focus_not_target_selector')

    # 6. Android 16 type=7 可审计映射为 window_control，不能成为第三 application window。
    $windowControl = Copy-C1BBaseDocument
    foreach ($frame in $windowControl.frames) {
        $aw5 = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw5')[0]
        $aw5.platform_type_code = 7
        $aw5.type = 'window_control'
    }
    $windowControlResult = Invoke-C1BFixture $windowControl 'window-control-type7'
    Assert-C1B $windowControlResult.fixture_contract_valid 'type 7 mapping must be accepted'
    Assert-C1B $windowControlResult.application_window_topology_observed 'window control must not count as application'
    Complete-C1BCase @('window_type_code','android16_window_control')

    # 7. raw code/type 对不上必须阻断 inventory。
    $badType = Copy-C1BBaseDocument
    foreach ($frame in $badType.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw5')[0].platform_type_code = 7
    }
    Set-C1BFocusUnknown $badType
    Add-C1BDeclaredReason $badType 'window_type_invalid'
    Add-C1BDeclaredReason $badType 'ime_inventory_invalid'
    $badTypeResult = Invoke-C1BFixture $badType 'window-type-mismatch'
    Assert-C1BCode $badTypeResult 'window_type_invalid'
    Assert-C1B (-not $badTypeResult.application_window_topology_observed) 'type mismatch must block topology'
    Complete-C1BCase @('window_type_mismatch')

    # 8. root handle 与 window exact binding 分离；mismatch 不影响事实落盘，但不能形成 projection。
    $rootMismatch = Copy-C1BBaseDocument
    foreach ($frame in $rootMismatch.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].root_window_binding = 'mismatch'
    }
    Set-C1BFocusUnknown $rootMismatch
    Add-C1BDeclaredReason $rootMismatch 'root_window_binding_invalid'
    $rootMismatchResult = Invoke-C1BFixture $rootMismatch 'root-window-mismatch'
    Assert-C1B $rootMismatchResult.fixture_contract_valid 'truthfully declared root mismatch remains valid evidence'
    Assert-C1BCode $rootMismatchResult 'root_window_binding_invalid'
    Assert-C1B (-not $rootMismatchResult.window_root_projection_observed) 'root mismatch formed projection'
    Complete-C1BCase @('root_handle_split','root_window_mismatch')

    # 9. readable handle 但 child=0/visited=1/positive=0 是 opaque，不是 unreadable。
    $opaque = Copy-C1BBaseDocument
    $opaqueResult = Invoke-C1BFixture $opaque 'complete-opaque'
    Assert-C1B (-not ($opaqueResult.reason_codes -ccontains 'subtree_capture_incomplete')) 'complete opaque tree was called incomplete'
    Assert-C1BCode $opaqueResult 'semantic_subtree_opaque'
    Complete-C1BCase @('subtree_complete_opaque')

    # 10. truncated/budget 必须显式阻断 subtree completeness。
    $truncated = Copy-C1BBaseDocument
    foreach ($frame in $truncated.frames) {
        $subtree = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].subtree_capture
        $subtree.status = 'truncated'; $subtree.budget_exhausted = $true
    }
    Set-C1BFocusUnknown $truncated
    Add-C1BDeclaredReason $truncated 'subtree_capture_incomplete'
    $truncatedResult = Invoke-C1BFixture $truncated 'subtree-truncated'
    Assert-C1BCode $truncatedResult 'subtree_capture_incomplete'
    Assert-C1B (-not $truncatedResult.semantic_tree_usable) 'truncated tree became usable'
    Complete-C1BCase @('subtree_truncated','budget_exhausted')

    # 11. producer counter 必须与持久 node inventory 机械一致。
    $counter = Copy-C1BBaseDocument
    foreach ($frame in $counter.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].subtree_capture.visited_node_count = 2
    }
    Set-C1BFocusUnknown $counter
    Add-C1BDeclaredReason $counter 'subtree_counts_invalid'
    Add-C1BDeclaredReason $counter 'subtree_capture_incomplete'
    $counterResult = Invoke-C1BFixture $counter 'subtree-counter-mismatch'
    Assert-C1BCode $counterResult 'subtree_counts_invalid'
    Assert-C1B (-not ($counterResult.reason_codes -ccontains 'focus_inventory_invalid')) `
        'declared/node count mismatch rejected honest unknown focus'
    Complete-C1BCase @('subtree_counter_mismatch')

    # 12. visible scrollable 树可以成为 usable diagnostic，但不能推成 navigation/conversation。
    $scrollable = Copy-C1BBaseDocument
    foreach ($frame in $scrollable.frames) {
        foreach ($node in $frame.node_observations) {
            $window = @($frame.a11y_windows | Where-Object window_label -CEQ $node.window_label)[0]
            $node.geometry_status = 'positive'; $node.bounds = $window.bounds
            $node.visible = $true; $node.enabled = $true; $node.scrollable = $true
            $window.subtree_capture.positive_visible_geometry_node_count = 1
        }
    }
    Remove-C1BDeclaredReason $scrollable 'semantic_subtree_opaque'
    $scrollableResult = Invoke-C1BFixture $scrollable 'scrollable-not-navigation'
    Assert-C1B $scrollableResult.fixture_contract_valid 'scrollable diagnostic must validate'
    Assert-C1B $scrollableResult.semantic_tree_usable 'positive complete tree should be marked usable'
    Assert-C1B (-not $scrollableResult.navigation_pane_verified -and -not $scrollableResult.conversation_pane_verified) 'scrollable promoted role'
    Complete-C1BCase @('scrollable_not_navigation','usable_not_semantic')

    # 13. editable search node 也只是 focus inventory；不选择 conversation/target。
    $editor = Copy-C1BBaseDocument
    foreach ($frame in $editor.frames) {
        $an2 = @($frame.node_observations | Where-Object node_label -CEQ 'an2')[0]
        $aw2 = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw2')[0]
        $an2.geometry_status = 'positive'; $an2.bounds = $aw2.bounds
        $an2.visible = $true; $an2.enabled = $true; $an2.editable = $true; $an2.focused = $true
        $aw2.subtree_capture.positive_visible_geometry_node_count = 1
        $aw2.subtree_capture.focused_editable_node_count = 1
        $frame.focus.status = 'editor_known'; $frame.focus.window_label = 'aw2'; $frame.focus.node_label = 'an2'
    }
    $editorResult = Invoke-C1BFixture $editor 'editor-known-not-conversation'
    Assert-C1B $editorResult.fixture_contract_valid 'legal direct editor observation must validate'
    Assert-C1B (-not $editorResult.conversation_pane_verified -and -not $editorResult.target_conversation_verified -and
        -not $editorResult.editor_action_ready) 'editable focus promoted conversation/action'
    Complete-C1BCase @('direct_focus_observation','nav_search_not_conversation')

    # 14. focus declaration必须由 inventory 重算。
    $focusMismatch = Copy-C1BBaseDocument
    foreach ($frame in $focusMismatch.frames) {
        $frame.focus.status = 'absent'; $frame.focus.window_label = $null
    }
    Add-C1BDeclaredReason $focusMismatch 'focus_inventory_invalid'
    $focusMismatchResult = Invoke-C1BFixture $focusMismatch 'focus-inventory-mismatch'
    Assert-C1BCode $focusMismatchResult 'focus_inventory_invalid'
    Complete-C1BCase @('focus_inventory_mismatch')

    # 15. 同一字段跨帧漂移必须进入 consistency，不能靠第二帧选 target。
    $drift = Copy-C1BBaseDocument
    @($drift.frames[1].a11y_windows | Where-Object window_label -CEQ 'aw2')[0].expected_window_title_match = 'match'
    $drift.consistency.stable = $false
    $drift.consistency.reason_codes = @('capture_semantics_drift')
    Add-C1BDeclaredReason $drift 'capture_semantics_drift'
    $driftResult = Invoke-C1BFixture $drift 'cross-frame-title-drift'
    Assert-C1BCode $driftResult 'capture_semantics_drift'
    Assert-C1B (-not $driftResult.application_window_topology_observed) 'semantic drift preserved stable topology claim'
    Complete-C1BCase @('cross_frame_drift','consistency_recomputed')

    # 16. frame atomic revision 不一致。
    $atomic = Copy-C1BBaseDocument
    $atomic.frames[1].capture.ime_revision = 12
    $atomic.consistency.stable = $false
    $atomic.consistency.reason_codes = @('atomic_capture_revision_invalid')
    Add-C1BDeclaredReason $atomic 'atomic_capture_revision_invalid'
    $atomicResult = Invoke-C1BFixture $atomic 'atomic-revision-invalid'
    Assert-C1BCode $atomicResult 'atomic_capture_revision_invalid'
    Complete-C1BCase @('atomic_revision')

    # 17. freshness 是 consumer-owned；旧 evidence 不要求 producer 预写 stale reason。
    $stale = Copy-C1BBaseDocument
    $staleNow = [DateTimeOffset]::UtcNow
    Set-C1BFreshTimes $stale $staleNow.AddMinutes(-3)
    $stalePath = Write-C1BDocument $stale 'stale'
    $staleResult = Test-TabletLayoutObservationC1BV1File -Path $stalePath -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $staleNow
    Assert-C1BCode $staleResult 'capture_stale'
    Assert-C1B (-not ($staleResult.reason_codes -ccontains 'declared_reasons_incomplete')) 'consumer stale was required in producer reasons'
    Assert-C1B (-not $staleResult.application_window_topology_observed) 'stale evidence retained topology claim'
    Complete-C1BCase @('freshness_stale')

    # 18. duplicate key 在 ConvertFrom-Json 之前拒绝。
    $fresh = Copy-C1BBaseDocument
    $now = [DateTimeOffset]::UtcNow; Set-C1BFreshTimes $fresh $now
    $raw = $fresh | ConvertTo-Json -Depth 100
    $duplicateRaw = $raw -replace '^\{', '{"schema":"tablet-layout-observation/c1b-v1",'
    $duplicatePath = Write-C1BRaw $duplicateRaw 'duplicate-key'
    $duplicateResult = Test-TabletLayoutObservationC1BV1File -Path $duplicatePath -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $now
    Assert-C1BCode $duplicateResult 'duplicate_json_property'
    Assert-C1B (-not $duplicateResult.fixture_contract_valid) 'duplicate key passed contract'
    Complete-C1BCase @('duplicate_key')

    # 19. 只接受 JSON Int64 整数词法；小数/指数不能被 PowerShell 悄悄转换。
    $intDoc = Copy-C1BBaseDocument; $now = [DateTimeOffset]::UtcNow; Set-C1BFreshTimes $intDoc $now
    $intRaw = ($intDoc | ConvertTo-Json -Depth 100) -replace '"revision_before": 10', '"revision_before": 1.5'
    $intPath = Write-C1BRaw $intRaw 'non-int64-number'
    $intResult = Test-TabletLayoutObservationC1BV1File -Path $intPath -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $now
    Assert-C1BCode $intResult 'json_number_not_int64'
    $overflowRaw = ($intDoc | ConvertTo-Json -Depth 100) -replace '"revision_before": 10', '"revision_before": 9223372036854775808'
    $overflowPath = Write-C1BRaw $overflowRaw 'int64-overflow'
    $overflowResult = Test-TabletLayoutObservationC1BV1File -Path $overflowPath -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $now
    Assert-C1BCode $overflowResult 'json_number_not_int64'
    Complete-C1BCase @('int64_lexical_gate','int64_range_gate')

    # 20. raw identity、plaintext 与稳定内容 hash 分别由 pre-schema privacy scan 拒绝。
    foreach ($privacyCase in @(
            [pscustomobject]@{ Name='raw-id'; Property='raw_window_id'; Value=42; Code='raw_identity_persisted' },
            [pscustomobject]@{ Name='plaintext'; Property='window_title'; Value=(Get-TL1C1BV1SyntheticPrivacyCanary); Code='chat_plaintext_persisted' },
            [pscustomobject]@{ Name='content-hash'; Property='title_hash'; Value=(Get-TL1C1BV1SyntheticPrivacyCanaryHash); Code='chat_content_digest_persisted' }
        )) {
        $privacyDoc = Copy-C1BBaseDocument
        $privacyDoc.frames[0].a11y_windows[0] | Add-Member -NotePropertyName $privacyCase.Property -NotePropertyValue $privacyCase.Value
        $privacyResult = Invoke-C1BFixture $privacyDoc "privacy-$($privacyCase.Name)"
        Assert-C1BCode $privacyResult $privacyCase.Code
        Assert-C1B (-not $privacyResult.fixture_contract_valid) "privacy case $($privacyCase.Name) passed"
    }
    Complete-C1BCase @('privacy_raw_identity','privacy_plaintext','privacy_content_digest')

    # 21. v2 frozen artifact 不能按 C1b schema 重解释。
    $v2Root = Join-Path $PSScriptRoot 'fixtures\tablet-layout-observation\v2'
    $v2Path = Join-Path $v2Root 'native-multi-landscape.json'
    $v2Result = Test-TabletLayoutObservationC1BV1File -Path $v2Path -EvidenceRoot $v2Root `
        -FixtureMode -ValidationNowUtc ([DateTimeOffset]::UtcNow)
    Assert-C1B (-not $v2Result.fixture_contract_valid) 'v2 artifact was accepted as C1b'
    Assert-C1BCode $v2Result 'json_schema_validation_failed'
    Complete-C1BCase @('v2_frozen')

    # 22. 公共非-fixture入口在读取 caller path 之前固定 unavailable。
    $publicResult = Test-TabletLayoutObservationC1BV1File -Path 'Z:\must-not-be-read.json' `
        -EvidenceRoot $tempRoot.FullName
    Assert-C1BCode $publicResult 'runtime_producer_unavailable'
    Assert-C1B ($publicResult.issues.Count -eq 1 -and $publicResult.issues[0].path -ceq '/provenance') 'public entry read caller path'
    Complete-C1BCase @('public_runtime_unavailable_before_read')

    # 23. trusted-runtime 参数最多形成非证明性的 binding fact；observation validator 永不自证 origin。
    $runtime = Copy-C1BBaseDocument
    $runtime.provenance.kind = 'gateway_runtime_probe'
    $runtime.upstream_t0.source_kind = 'trusted_runtime'
    $runtime.expected_title_hash = $script:TL1C1BV1TrustedRuntimeTitleHash
    $now = [DateTimeOffset]::UtcNow; Set-C1BFreshTimes $runtime $now
    $runtimePath = Write-C1BDocument $runtime 'trusted-runtime'
    $runtimeResult = Test-TabletLayoutObservationC1BV1TrustedRuntimeFile -Path $runtimePath `
        -EvidenceRoot $tempRoot.FullName -ExpectedRunId $runtime.run_id `
        -ExpectedProducerCommitSha $runtime.provenance.producer_commit_sha `
        -ExpectedProducerArtifactSha256 $runtime.provenance.producer_artifact_sha256 -ValidationNowUtc $now
    Assert-C1B $runtimeResult.runtime_binding_inputs_match 'trusted binding inputs did not match'
    Assert-C1B (-not $runtimeResult.runtime_origin_verified -and -not $runtimeResult.runtime_evidence) `
        'caller strings self-attested runtime origin'
    Assert-C1B (-not $runtimeResult.application_window_topology_verified -and
        -not $runtimeResult.wechat_window_ownership_verified -and
        -not $runtimeResult.window_root_projection_verified -and -not $runtimeResult.ime_hidden_verified) `
        'observation validator promoted final verified claims without sidecar'
    Assert-C1B (-not $runtimeResult.target_conversation_verified -and -not $runtimeResult.layout_accepted -and
        -not $runtimeResult.execution_grant) 'trusted origin promoted semantics/actions'
    Complete-C1BCase @('runtime_origin_sidecar_only','runtime_binding_facts_only','verified_claims_closed_without_sidecar')

    # 24. trusted expected artifact mismatch撤销 origin 与 verified claim。
    $badRuntime = Test-TabletLayoutObservationC1BV1TrustedRuntimeFile -Path $runtimePath `
        -EvidenceRoot $tempRoot.FullName -ExpectedRunId $runtime.run_id `
        -ExpectedProducerCommitSha $runtime.provenance.producer_commit_sha `
        -ExpectedProducerArtifactSha256 ('sha256:' + ('f' * 64)) -ValidationNowUtc $now
    Assert-C1B (-not $badRuntime.runtime_origin_verified -and -not $badRuntime.application_window_topology_verified) 'mismatched origin remained verified'
    Assert-C1BCode $badRuntime 'runtime_producer_unavailable'
    Complete-C1BCase @('runtime_origin_mismatch')

    # 25. trusted runtime 不能接受任意 caller title hash；fixture 的 synthetic hash 不得越过 origin 边界。
    $runtimeTitleMismatch = Copy-C1BValue $runtime
    $runtimeTitleMismatch.expected_title_hash = 'sha256:' + ('e' * 64)
    $runtimeTitleMismatchPath = Write-C1BDocument $runtimeTitleMismatch 'trusted-runtime-title-mismatch'
    $runtimeTitleMismatchResult = Test-TabletLayoutObservationC1BV1TrustedRuntimeFile `
        -Path $runtimeTitleMismatchPath -EvidenceRoot $tempRoot.FullName -ExpectedRunId $runtimeTitleMismatch.run_id `
        -ExpectedProducerCommitSha $runtimeTitleMismatch.provenance.producer_commit_sha `
        -ExpectedProducerArtifactSha256 $runtimeTitleMismatch.provenance.producer_artifact_sha256 -ValidationNowUtc $now
    Assert-C1BCode $runtimeTitleMismatchResult 'runtime_producer_unavailable'
    Assert-C1B (-not $runtimeTitleMismatchResult.runtime_origin_verified -and
        -not $runtimeTitleMismatchResult.application_window_topology_verified) `
        'arbitrary trusted runtime title hash retained verified claims'
    Complete-C1BCase @('trusted_runtime_fixed_title_hash')

    # 26. orphan node 必须稳定报告 node_binding_invalid，不能在 owner lookup 抛 validation_exception。
    $orphan = Copy-C1BBaseDocument
    foreach ($frame in $orphan.frames) {
        $frame.node_observations = @($frame.node_observations) + [pscustomobject][ordered]@{
            node_label='an9'; window_label='aw9'; pane_label='ap1'; source='root_subtree'
            is_root=$false; window_id_binding='exact'; semantic_role='unknown'; geometry_status='positive'
            bounds=[pscustomobject][ordered]@{ left=10; top=10; right=20; bottom=20 }
            visible=$true; enabled=$true; editable=$false; scrollable=$false; focused=$false
        }
    }
    Add-C1BDeclaredReason $orphan 'node_binding_invalid'
    $orphanResult = Invoke-C1BFixture $orphan 'orphan-node'
    Assert-C1BCode $orphanResult 'node_binding_invalid'
    Assert-C1B (-not ($orphanResult.reason_codes -ccontains 'validation_exception')) 'orphan node caused validation exception'
    Complete-C1BCase @('orphan_node_safe_lookup')

    # 27. sidecar schema 也是 closed，并机械钉零 screenshot/OCR/action。
    $sidecarSchema = Join-Path $repoRoot 'docs\contracts\tablet-layout-c1b-sidecar-v1.schema.json'
    $hash = 'sha256:' + ('a' * 64)
    $implementationHashes=[ordered]@{};foreach($name in @(
        'runner_sha256','c1b_library_sha256','c1b_read_only_library_sha256','c1b_artifact_proof_library_sha256','c1b_aapt2_library_sha256','c1b_build_environment_library_sha256','c1b_adb_server_library_sha256','dispatch_lock_library_sha256','c1a_low_level_library_sha256',
        't0_runner_sha256','t0_library_sha256','t0_adb_sidecar_cmd_sha256','t0_adb_sidecar_script_sha256','validator_sha256','native_path_validator_sha256',
        'observation_schema_sha256','sidecar_schema_sha256','artifact_proof_schema_sha256','android_layout_probe_sha256','android_layout_probe_model_sha256','android_model_sha256','android_probe_sha256','android_source_sha256',
        'android_provider_sha256','android_protocol_sha256','android_coordinator_sha256','android_controller_sha256','android_context_sha256','android_pending_registry_sha256',
        'app_build_gradle_sha256','app_settings_gradle_sha256','app_gradle_properties_sha256','app_gradlew_bat_sha256','app_gradle_wrapper_jar_sha256','app_gradle_wrapper_properties_sha256','app_gradle_verification_metadata_sha256','probe_build_gradle_sha256','probe_manifest_sha256','probe_service_sha256','probe_a11y_config_sha256','probe_strings_sha256'
    )){$implementationHashes[$name]=$hash}
    $buildEnvironment=Get-Content -LiteralPath $buildEnvironmentFixturePath -Raw | ConvertFrom-Json -Depth 100 -DateKind String
    $buildEnvironment.repository_inputs.file_count=[long]$implementationHashes.Count
    $buildEnvironment.repository_inputs.catalog_sha256=Get-TL1C1bImplementationCatalogSha256 $implementationHashes
    $at=[DateTimeOffset]::UtcNow.UtcDateTime.ToString($script:TL1C1BV1TimestampFormat,[Globalization.CultureInfo]::InvariantCulture)
    $sidecar = [ordered]@{
        schema='tablet-layout-c1b-sidecar/v1'; run_id='tl1-c1b-sidecar-fixture'
        completed_at_utc=$at;expected_commit_sha=('b'*40);capture_scope='pure_a11y';provenance_strategy='clean_content_provider_independently_attested';static_read_only_policy_version='tl1-c1b-read-only/v2';implementation_hashes=$implementationHashes
        build_environment=$buildEnvironment
        transport=[ordered]@{trust_root='android_sdk_platform_tools';canonical_relative_path='platform-tools/adb.exe';sdk_roots_equal=$true;executable_sha256_before=$hash;executable_sha256_after=$hash;version_output_sha256_before=$hash;version_output_sha256_after=$hash;signature_status='Valid';signature_subject='CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US, SERIALNUMBER=3582691, OID.2.5.4.15=Private Organization, OID.1.3.6.1.4.1.311.60.2.1.2=Delaware, OID.1.3.6.1.4.1.311.60.2.1.3=US';signature_certificate_sha256_before=$hash;signature_certificate_sha256_after=$hash;protocol_version='1.0.41';package_version='36.0.0-13206524';installed_as_canonical=$true;server_schema='tablet-layout-c1b-private-adb-server/v1';server_mode='private_nodaemon';server_socket='tcp:127.0.0.1:55001';server_executable_sha256=$hash;job_kill_on_close=$true;listener_pid_verified=$true;server_status_executable_path_verified=$true;server_ready_verified=$true;server_cleanup_verified=$true;private_kill_server_requested=$true;graceful_exit_verified=$true;job_fallback_used=$false;port_rebind_verified=$true;default_server_used=$false}
        apk=[ordered]@{fresh_build=$true;install_attempt_count=1;uninstall_count=0;automatic_retry_count=0;local_sha256_before=$hash;local_sha256_after=$hash;installed_base_apk_path_hash_before=$hash;installed_base_apk_path_hash_after=$hash;installed_base_apk_sha256_before=$hash;installed_base_apk_sha256_after=$hash;signer_certificate_sha256=$hash;package_name_before='dev.magina.gateway';package_name_after='dev.magina.gateway';version_name_before='1.0';version_name_after='1.0';version_code_before=1;version_code_after=1}
        device=[ordered]@{serial_hash_before=$hash;serial_hash_after=$hash;fingerprint_hash_before=$hash;fingerprint_hash_after=$hash;boot_id_hash_before=$hash;boot_id_hash_after=$hash;unique_device_before_after=$true}
        upstream_t0=[ordered]@{producer_commit_sha='4ca32b131007df58f7752c5ee9b2d049cb1cd54e';original_relative_path='docs/runs/evidence/tl1-c1b-sidecar-fixture/tablet-profile.json';original_sha256=$hash;original_byte_count=10;original_crlf_count=1;original_bytes_forwarded=$true;exec_in_write_count=1;device_binding_verified=$true}
        provider=[ordered]@{authority='dev.magina.gateway.tablet.c1b';protocol_version='1';package_name='dev.magina.gateway';version_name='1.0';version_code=1;embedded_git_head=('b'*40);build_challenge_hash=$hash;expected_title_hash='sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c';producer_artifact_sha256=$hash;a11y_service_ready=$true;control_transcript_sha256=$hash;endpoint_set_sha256=$hash}
        capture=[ordered]@{generation=1;c1_requested_at_utc=$at;c1_committed_at_utc=$at;c2_requested_at_utc=$at;c2_committed_at_utc=$at;host_wait_ms=900;total_span_ms=1000;status_poll_count=1;c1_requests_accepted=1;c2_requests_accepted=1;result_read_count=1;recapture_count=0}
        artifacts=[ordered]@{upstream_t0=[ordered]@{relative_path='upstream-t0-v5.json';sha256=$hash};observation=[ordered]@{relative_path='tablet-layout-observation-c1b-v1.json';sha256=$hash};validation=[ordered]@{relative_path='tablet-layout-observation-validation-c1b-v1.json';sha256=$hash};artifact_proof=[ordered]@{relative_path='tablet-c1b-read-only-artifact-proof-v1.json';sha256=$hash};debug_apk=[ordered]@{relative_path='tablet-c1b-probe-debug.apk';sha256=$hash};release_apk=[ordered]@{relative_path='tablet-c1b-probe-release-unsigned.apk';sha256=$hash};debug_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-debug-merged-AndroidManifest.xml';sha256=$hash};release_merged_manifest=[ordered]@{relative_path='tablet-c1b-probe-release-merged-AndroidManifest.xml';sha256=$hash}}
        read_only_counts=[ordered]@{
            a11y_frame_capture_count=2; recapture_count=0; display_screenshot_call_count=0
            window_screenshot_call_count=0; ocr_invocation_count=0; action_call_count=0
            gesture_call_count=0; input_call_count=0; settings_mutation_count=0
            target_app_start_count=0; mcp_call_count=0; dispatch_call_count=0
        }
        read_only_proof=[ordered]@{schema='tablet-layout-c1b-read-only-proof/v1';policy_version='tl1-c1b-read-only/v2';artifact_module=':tablet-c1b-probe';artifact_proof_relative_path='app/tablet-c1b-probe/build/reports/tablet-c1b-read-only-artifact-proof.json';artifact_proof_sha256=$hash;runner_ast_sha256=$hash;t0_runner_ast_sha256=$hash;t0_library_ast_sha256=$hash;host_forbidden_command_count=0;axml_parser=[ordered]@{schema='tablet-layout-c1b-aapt2-trust/v1';trust_root='android_sdk_build_tools';build_tools_version='35.0.0';canonical_relative_path='build-tools/35.0.0/aapt2.exe';sdk_roots_equal=$true;executable_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564';signature_status='Valid';signature_subject='CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US';signature_certificate_sha256='sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'};packaged_axml_exact_verified=$true;dependency_artifact_catalog_sha256=$hash;debug_apk_sha256=$hash;debug_merged_manifest_sha256=$hash;debug_packaged_manifest_sha256=$hash;debug_packaged_manifest_axml_dump_sha256=$hash;debug_packaged_a11y_axml_dump_sha256=$hash;debug_dex_entry_count=6;debug_dex_sha256=$hash;debug_dex_catalog_sha256=$hash;release_apk_sha256=$hash;release_merged_manifest_sha256=$hash;release_packaged_manifest_sha256=$hash;release_packaged_manifest_axml_dump_sha256=$hash;release_packaged_a11y_axml_dump_sha256=$hash;release_dex_entry_count=1;release_dex_sha256=$hash;release_dex_catalog_sha256=$hash;artifact_forbidden_match_count=0;manifest_mutating_capability_count=0;manifest_extra_component_count=0;dependency_allowlist_verified=$true}
        attestations=[ordered]@{full_clean_head_verified=$true;implementation_hashes_verified=$true;origin_binding_verified=$true;probe_entrypoint_read_only=$true;dedicated_read_only_artifact_verified=$true;host_read_only_ast_verified=$true;observation_schema_valid=$true;artifact_hashes_recomputed=$true}
        claims=[ordered]@{
            runtime_origin_verified=$true; runtime_evidence=$true
            wechat_window_ownership_observed=$true; wechat_window_ownership_verified=$true
            window_root_projection_observed=$true; window_root_projection_verified=$true
            application_window_topology_observed=$true; application_window_topology_verified=$true
            ime_hidden_observed=$true; ime_hidden_verified=$true;semantic_tree_usable=$true
            navigation_pane_verified=$false;conversation_pane_verified=$false;target_conversation_verified=$false;target_regions_verified=$false;layout_accepted=$false
            wechat_layout_verified=$false; editor_action_ready=$false; p0_capability='unsupported'; execution_grant=$false
        }
        cleanup=[ordered]@{ required=$false; status='not_required';abort_attempt_count=0 }
    }
    $sidecarRaw = $sidecar | ConvertTo-Json -Depth 20
    Assert-C1B ($sidecarRaw | Test-Json -SchemaFile $sidecarSchema -ErrorAction Stop) 'valid sidecar rejected'
    $sidecar.read_only_counts.ocr_invocation_count = 1
    Assert-C1B (-not (($sidecar | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $sidecarSchema -ErrorAction SilentlyContinue)) 'sidecar allowed OCR count'
    $sidecar.read_only_counts.ocr_invocation_count = 0
    $sidecar.claims.ime_hidden_verified = $false
    Assert-C1B (-not (($sidecar | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $sidecarSchema -ErrorAction SilentlyContinue)) `
        'sidecar allowed observed/verified claim mismatch'
    Complete-C1BCase @('sidecar_closed','zero_action_counts','sidecar_symmetric_claim_binding')

    # 28. 第三个 application window 必须阻断 exact-two topology，即使它自己的 root projection 完整。
    $extraApplication = Copy-C1BBaseDocument
    foreach ($frame in $extraApplication.frames) {
        $newWindow = Copy-C1BValue (@($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0])
        $newWindow.window_label = 'aw6'; $newWindow.layer = 6; $newWindow.active = $false
        $newPane = Copy-C1BValue (@($frame.panes | Where-Object pane_label -CEQ 'ap1')[0])
        $newPane.pane_label = 'ap6'; $newPane.window_label = 'aw6'
        $newNode = Copy-C1BValue (@($frame.node_observations | Where-Object node_label -CEQ 'an1')[0])
        $newNode.node_label = 'an6'; $newNode.window_label = 'aw6'; $newNode.pane_label = 'ap6'
        $frame.a11y_windows = @($frame.a11y_windows) + $newWindow
        $frame.panes = @($frame.panes) + $newPane
        $frame.node_observations = @($frame.node_observations) + $newNode
    }
    Add-C1BDeclaredReason $extraApplication 'window_count_not_two'
    Add-C1BDeclaredReason $extraApplication 'window_root_projection_invalid'
    $extraApplicationResult = Invoke-C1BFixture $extraApplication 'extra-application'
    Assert-C1BCode $extraApplicationResult 'window_count_not_two'
    Assert-C1B (-not $extraApplicationResult.application_window_topology_observed -and
        -not $extraApplicationResult.wechat_window_ownership_observed) 'third application retained exact-two claims'
    Complete-C1BCase @('extra_application','exact_two_application_required')

    # 29. 任一额外 display id 出现在 inventory 即 fail closed。
    $extraDisplay = Copy-C1BBaseDocument
    foreach ($frame in $extraDisplay.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw5')[0].display_id = 1
    }
    Add-C1BDeclaredReason $extraDisplay 'multi_display_blocked'
    $extraDisplayResult = Invoke-C1BFixture $extraDisplay 'extra-display'
    Assert-C1BCode $extraDisplayResult 'multi_display_blocked'
    Assert-C1B (-not $extraDisplayResult.window_inventory_observed) 'extra display retained window inventory claim'
    Complete-C1BCase @('extra_display')

    # 30. producer 可诚实表达 unknown display，但不能因此猜 display 0 或 landscape。
    $unknownDisplay = Copy-C1BBaseDocument
    foreach ($frame in $unknownDisplay.frames) {
        $frame.display.display_id_status = 'unknown'; $frame.display.display_id = $null
        $frame.display.effective_size = $null; $frame.display.orientation = 'unknown'
    }
    Add-C1BDeclaredReason $unknownDisplay 'display_unknown'
    $unknownDisplayResult = Invoke-C1BFixture $unknownDisplay 'unknown-display'
    Assert-C1B $unknownDisplayResult.fixture_contract_valid 'truthful unknown display must be representable'
    Assert-C1BCode $unknownDisplayResult 'display_unknown'
    Assert-C1B (-not $unknownDisplayResult.application_window_topology_observed) 'unknown display retained topology'
    Complete-C1BCase @('unknown_display','no_default_display_inference')

    # 31. subtree read_error 与 complete opaque 必须区分。
    $readError = Copy-C1BBaseDocument
    foreach ($frame in $readError.frames) {
        $subtree = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].subtree_capture
        $subtree.status = 'read_error'; $subtree.read_error_count = 1
    }
    Set-C1BFocusUnknown $readError
    Add-C1BDeclaredReason $readError 'subtree_capture_incomplete'
    $readErrorResult = Invoke-C1BFixture $readError 'subtree-read-error'
    Assert-C1BCode $readErrorResult 'subtree_capture_incomplete'
    Assert-C1B (-not $readErrorResult.semantic_tree_usable) 'read-error subtree became usable'
    Complete-C1BCase @('subtree_read_error')

    # 32. window title over_budget/read_error 都只形成诊断阻断，不能 fallback 选 target。
    $titleFailures = Copy-C1BBaseDocument
    foreach ($frame in $titleFailures.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].expected_window_title_match = 'over_budget'
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw2')[0].expected_window_title_match = 'read_error'
    }
    Add-C1BDeclaredReason $titleFailures 'window_title_probe_invalid'
    $titleFailuresResult = Invoke-C1BFixture $titleFailures 'title-probe-failures'
    Assert-C1BCode $titleFailuresResult 'window_title_probe_invalid'
    Assert-C1B (-not $titleFailuresResult.target_conversation_verified -and
        -not $titleFailuresResult.layout_accepted) 'failed title probe selected target'
    Complete-C1BCase @('title_over_budget','title_read_error','title_failure_no_fallback')

    # 33. visible IME 可被只读 inventory 表达，但 hidden 与 action claim 均须 false。
    $visibleIme = Copy-C1BBaseDocument
    foreach ($frame in $visibleIme.frames) {
        $imeWindow = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw5')[0]
        $imeWindow.platform_type_code = 2; $imeWindow.type = 'input_method'
        $frame.ime.visible = $true; $frame.ime.mode = 'floating'; $frame.ime.bounds = $imeWindow.bounds
        $frame.ime.binding = 'unknown'; $frame.ime.editor_node_label = $null
    }
    Add-C1BDeclaredReason $visibleIme 'ime_hidden_unverified'
    $visibleImeResult = Invoke-C1BFixture $visibleIme 'visible-ime'
    Assert-C1B $visibleImeResult.fixture_contract_valid 'valid visible IME inventory was rejected'
    Assert-C1BCode $visibleImeResult 'ime_hidden_unverified'
    Assert-C1B (-not $visibleImeResult.ime_hidden_observed -and -not $visibleImeResult.ime_hidden_verified -and
        -not $visibleImeResult.editor_action_ready) 'visible IME promoted hidden/action claim'
    Complete-C1BCase @('visible_ime','visible_ime_no_action')

    # 34. frame 2 更换 run-local window label 必须同时进入 identity 与 semantic drift。
    $identityReplacement = Copy-C1BBaseDocument
    $replacementWindow = @($identityReplacement.frames[1].a11y_windows | Where-Object window_label -CEQ 'aw2')[0]
    $replacementWindow.window_label = 'aw6'
    @($identityReplacement.frames[1].panes | Where-Object pane_label -CEQ 'ap2')[0].window_label = 'aw6'
    @($identityReplacement.frames[1].node_observations | Where-Object node_label -CEQ 'an2')[0].window_label = 'aw6'
    $identityReplacement.frames[1].focus.window_label = 'aw6'
    $identityReplacement.consistency.stable = $false
    $identityReplacement.consistency.reason_codes = @('capture_semantics_drift','window_identity_replacement')
    Add-C1BDeclaredReason $identityReplacement 'capture_semantics_drift'
    Add-C1BDeclaredReason $identityReplacement 'window_identity_replacement'
    $identityReplacementResult = Invoke-C1BFixture $identityReplacement 'window-label-replacement'
    Assert-C1BCode $identityReplacementResult 'window_identity_replacement'
    Assert-C1BCode $identityReplacementResult 'capture_semantics_drift'
    Assert-C1B (-not $identityReplacementResult.application_window_topology_observed) 'identity replacement retained topology'
    Complete-C1BCase @('window_label_replacement','identity_replacement_blocks_topology')

    # 35. WMS wN→a11y awN crosswalk 不能作为 observation 字段潜入。
    $wmsCrosswalk = Copy-C1BBaseDocument
    $wmsCrosswalk.frames[0].a11y_windows[0] | Add-Member -NotePropertyName wms_window_label -NotePropertyValue 'w1'
    $wmsCrosswalkResult = Invoke-C1BFixture $wmsCrosswalk 'illegal-wms-crosswalk'
    Assert-C1BCode $wmsCrosswalkResult 'json_schema_validation_failed'
    Assert-C1B (-not $wmsCrosswalkResult.fixture_contract_valid) 'WMS crosswalk field passed closed schema'
    Complete-C1BCase @('wms_crosswalk_rejected')

    # 36. future capture 是 consumer-owned，但必须撤销本轮 topology claim。
    $future = Copy-C1BBaseDocument
    $futureNow = [DateTimeOffset]::UtcNow
    Set-C1BFreshTimes $future $futureNow
    $format = $script:TL1C1BV1TimestampFormat
    $future.frames[0].captured_at = $futureNow.AddSeconds(1).UtcDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $future.frames[1].captured_at = $futureNow.AddSeconds(2).UtcDateTime.ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    $future.captured_at = $future.frames[1].captured_at
    $futurePath = Write-C1BDocument $future 'future-capture'
    $futureResult = Test-TabletLayoutObservationC1BV1File -Path $futurePath -EvidenceRoot $tempRoot.FullName `
        -FixtureMode -ValidationNowUtc $futureNow
    Assert-C1BCode $futureResult 'capture_in_future'
    Assert-C1B (-not $futureResult.application_window_topology_observed) 'future evidence retained topology claim'
    Complete-C1BCase @('capture_in_future','future_blocks_topology')

    # 37. producer 漏报一个可重算 intrinsic reason 必须 fail closed。
    $missingReason = Copy-C1BBaseDocument
    foreach ($frame in $missingReason.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].expected_window_title_match = 'read_error'
    }
    $missingReasonResult = Invoke-C1BFixture $missingReason 'declared-reason-missing'
    Assert-C1BCode $missingReasonResult 'declared_reasons_incomplete'
    Assert-C1B (-not $missingReasonResult.fixture_contract_valid) 'missing declared reason passed contract'
    Complete-C1BCase @('declared_reason_missing')

    # 38. producer 多报不存在的 reason 同样是 status/reason mismatch。
    $extraReason = Copy-C1BBaseDocument
    Add-C1BDeclaredReason $extraReason 'window_count_not_two'
    $extraReasonResult = Invoke-C1BFixture $extraReason 'declared-reason-extra'
    Assert-C1BCode $extraReasonResult 'declared_status_mismatch'
    Assert-C1B (-not $extraReasonResult.fixture_contract_valid) 'extra declared reason passed contract'
    Complete-C1BCase @('declared_reason_extra','declared_status_mismatch')

    # 39. diagnostic_status 的非 blocked 值在 semantic consumer 前即由 closed schema 拒绝。
    $badStatus = Copy-C1BBaseDocument
    $badStatus.diagnostic_status = 'observed'
    $badStatusResult = Invoke-C1BFixture $badStatus 'diagnostic-status-observed'
    Assert-C1BCode $badStatusResult 'json_schema_validation_failed'
    Complete-C1BCase @('diagnostic_status_closed')

    # 40. 受控根外路径必须在任何读取前拒绝。
    $traversalResult = Test-TabletLayoutObservationC1BV1File -Path '..\outside.json' `
        -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc ([DateTimeOffset]::UtcNow)
    Assert-C1BCode $traversalResult 'runtime_producer_unavailable'
    Assert-C1B ($traversalResult.issues.Count -eq 1 -and $traversalResult.issues[0].path -ceq '/path') `
        'controlled-path traversal was not rejected before read'
    Complete-C1BCase @('controlled_path_traversal')

    # 41. evidence root 内的 reparse hop 也不能绕过受控路径边界。
    $realDirectory = Join-Path $tempRoot.FullName 'reparse-real'
    $linkDirectory = Join-Path $tempRoot.FullName 'reparse-link'
    [void][IO.Directory]::CreateDirectory($realDirectory)
    $reparseDoc = Copy-C1BBaseDocument; $reparseNow = [DateTimeOffset]::UtcNow
    Set-C1BFreshTimes $reparseDoc $reparseNow
    [IO.File]::WriteAllText((Join-Path $realDirectory 'inside.json'),
        ($reparseDoc | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
    try {
        if ($IsWindows) {
            [void](New-Item -ItemType Junction -Path $linkDirectory -Target $realDirectory -Force)
        } else {
            [void][IO.Directory]::CreateSymbolicLink($linkDirectory, $realDirectory)
        }
        $reparseResult = Test-TabletLayoutObservationC1BV1File -Path (Join-Path $linkDirectory 'inside.json') `
            -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $reparseNow
        Assert-C1BCode $reparseResult 'runtime_producer_unavailable'
        Assert-C1B ($reparseResult.issues[0].path -ceq '/path') 'reparse evidence path was read'
    }
    finally {
        if (Test-Path -LiteralPath $linkDirectory) { Remove-Item -LiteralPath $linkDirectory -Force }
    }
    Complete-C1BCase @('controlled_path_reparse')

    # 42. C1b 必须完整复用并 closed-validate T0 v5 readiness/P0 阻断归因。
    $missingT0Reasons = Copy-C1BBaseDocument
    $missingT0Reasons.upstream_t0.PSObject.Properties.Remove('readiness_reasons')
    $missingT0ReasonsResult = Invoke-C1BFixture $missingT0Reasons 't0-readiness-reasons-missing'
    Assert-C1BCode $missingT0ReasonsResult 'json_schema_validation_failed'
    $missingT0P0Reason = Copy-C1BBaseDocument
    $missingT0P0Reason.upstream_t0.p0_unsupported_reasons = @(
        $missingT0P0Reason.upstream_t0.p0_unsupported_reasons | Where-Object { $_ -cne 'wechat_layout_unverified' }
    )
    $missingT0P0ReasonResult = Invoke-C1BFixture $missingT0P0Reason 't0-required-p0-reason-missing'
    Assert-C1BCode $missingT0P0ReasonResult 'json_schema_validation_failed'
    Complete-C1BCase @('upstream_t0_v5_reasons_closed','upstream_t0_required_p0_reasons')

    # 43. provenance version 固定为 c1b-v1。
    $badVersion = Copy-C1BBaseDocument
    $badVersion.provenance.version = 'c1b-v2'
    $badVersionResult = Invoke-C1BFixture $badVersion 'provenance-version-mismatch'
    Assert-C1BCode $badVersionResult 'json_schema_validation_failed'
    Complete-C1BCase @('provenance_version_fixed')

    # 44. v2 冻结不仅靠 schema 拒绝，还逐文件钉住 Git blob OID。
    $v2BlobManifest = @(
        [pscustomobject]@{ Oid='12930c9e4e041773263b3ddc02fc85462f4c6168'; Path='docs/contracts/tablet-layout-observation-v2.md' },
        [pscustomobject]@{ Oid='c12062b86ba9a9a112199209618757767ec4890b'; Path='docs/contracts/tablet-layout-observation-v2.schema.json' },
        [pscustomobject]@{ Oid='5713979aa755a51417af62d338c7866c2eb74b8a'; Path='docs/runbooks/T-L1-tablet-layout-observation-v2.md' },
        [pscustomobject]@{ Oid='02fb13bcd21a5aa8282597064c19d0bab65dca0b'; Path='scripts/validate-tablet-layout-observation-v2.ps1' },
        [pscustomobject]@{ Oid='68209b06623439cc46f054827ddb6a647e3c0cd7'; Path='scripts/run-tablet-layout-observation-v2-offline-gate.ps1' },
        [pscustomobject]@{ Oid='2d023040e663f1f047980bd71f2e553882790f32'; Path='scripts/lib/tablet-layout-observation-v2-validator.ps1' },
        [pscustomobject]@{ Oid='89ab3992f7405df098f7827a639407a0c9a82277'; Path='scripts/lib/tablet-layout-observation-v2-offline-gate.ps1' },
        [pscustomobject]@{ Oid='b2cc25829a4e41ffa0225df82422f6db9f2755b9'; Path='scripts/tests/tablet-layout-observation-v2-offline.ps1' },
        [pscustomobject]@{ Oid='1c6f535d90803c0cccfc4d29fbc505507c5db83c'; Path='scripts/tests/tablet-layout-observation-v2-offline-gate.ps1' },
        [pscustomobject]@{ Oid='cd15fffd8b3d3a353f322cf8cbc4a8bd3be8224d'; Path='scripts/tests/fixtures/tablet-layout-observation/v2/native-multi-landscape.json' },
        [pscustomobject]@{ Oid='e96f7e4aadd7defc9515df37ad0161fffb3c0a72'; Path='scripts/tests/fixtures/tablet-layout-observation/v2/upstream-t0-v5.json' }
    )
    foreach ($entry in $v2BlobManifest) {
        $actualOid = (& git -C $repoRoot hash-object -- $entry.Path).Trim()
        Assert-C1B ($LASTEXITCODE -eq 0 -and $actualOid -ceq $entry.Oid) "v2 blob changed: $($entry.Path)"
    }
    Complete-C1BCase @('v2_blob_oid_freeze')

    # 45. executable C1b consumer/gate 只读；direct focus producer 前提被明确留作 Kotlin 跨层 requirement。
    $productionScripts = @(
        'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1',
        'scripts/lib/tablet-layout-observation-c1b-v1-offline-gate.ps1',
        'scripts/validate-tablet-layout-observation-c1b-v1.ps1',
        'scripts/run-tablet-layout-observation-c1b-v1-offline-gate.ps1',
        'scripts/check-tablet-layout-observation-c1b-v1.ps1'
    )
    $forbiddenExecutablePattern = '(?i)\b(?:adb(?:\.exe)?|scrcpy|uiautomator|performAction|dispatchGesture|takeScreenshot|executeShellCommand|ToolRegistry)\b'
    foreach ($relativePath in $productionScripts) {
        $source = [IO.File]::ReadAllText((Join-Path $repoRoot $relativePath), [Text.UTF8Encoding]::new($false, $true))
        Assert-C1B ($source -cnotmatch $forbiddenExecutablePattern) "forbidden executable token in $relativePath"
    }
    $contractSource = [IO.File]::ReadAllText(
        (Join-Path $repoRoot 'docs/contracts/tablet-layout-observation-c1b-v1.md'),
        [Text.UTF8Encoding]::new($false, $true)
    )
    Assert-C1B ($contractSource.Contains('direct `findFocus`', [StringComparison]::Ordinal) -and
        $contractSource.Contains('refresh 成功', [StringComparison]::Ordinal) -and
        $contractSource.Contains('Kotlin producer coordinator tests', [StringComparison]::Ordinal)) `
        'direct focus Kotlin cross-layer requirement is not explicit'
    Complete-C1BCase @('static_read_only_forbidden_scan','direct_focus_cross_layer_requirement')

    # 46. code=0 与未映射 code 都可诚实保留为 unknown，但不能保留 topology/hidden-IME/focus 结论。
    foreach ($unknownTypeCode in @(0, 42)) {
        $unknownType = Copy-C1BBaseDocument
        foreach ($frame in $unknownType.frames) {
            $window = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw5')[0]
            $window.platform_type_code = $unknownTypeCode
            $window.type = 'unknown'
        }
        Set-C1BFocusUnknown $unknownType
        Add-C1BDeclaredReason $unknownType 'window_type_invalid'
        Add-C1BDeclaredReason $unknownType 'ime_inventory_invalid'
        $unknownTypeResult = Invoke-C1BFixture $unknownType "unknown-window-type-$unknownTypeCode"
        Assert-C1B $unknownTypeResult.fixture_contract_valid "truthful unknown type $unknownTypeCode was rejected"
        Assert-C1BCode $unknownTypeResult 'window_type_invalid'
        Assert-C1BCode $unknownTypeResult 'ime_inventory_invalid'
        Assert-C1B (-not $unknownTypeResult.window_inventory_observed -and
            -not $unknownTypeResult.application_window_topology_observed -and
            -not $unknownTypeResult.ime_hidden_observed) "unknown type $unknownTypeCode retained observed claims"
        Assert-C1B (-not ($unknownTypeResult.reason_codes -ccontains 'focus_inventory_invalid')) `
            "unknown type $unknownTypeCode rejected honest unknown focus"
    }
    Complete-C1BCase @('unknown_window_type','unknown_type_code_zero_and_unmapped','unknown_type_blocks_topology_and_hidden_ime')

    # 47. application root/subtree 的任一 completeness 条件缺失时只能落 unknown focus；不得降级 absent/window_only。
    $focusCompletenessVariants = @(
        [pscustomobject]@{ Name='subtree-status'; Reasons=@('subtree_capture_incomplete'); Mutate={ param($frame,$window) $window.subtree_capture.status = 'truncated' } },
        [pscustomobject]@{ Name='root-child-null'; Reasons=@('subtree_capture_incomplete'); Mutate={ param($frame,$window) $window.subtree_capture.root_child_count = $null } },
        [pscustomobject]@{ Name='read-error'; Reasons=@('subtree_capture_incomplete'); Mutate={ param($frame,$window) $window.subtree_capture.read_error_count = 1 } },
        [pscustomobject]@{ Name='budget-exhausted'; Reasons=@('subtree_capture_incomplete'); Mutate={ param($frame,$window) $window.subtree_capture.budget_exhausted = $true } },
        [pscustomobject]@{ Name='root-handle'; Reasons=@('window_root_owner_conflict'); Mutate={ param($frame,$window) $window.root_handle_status = 'absent' } },
        [pscustomobject]@{ Name='root-owner'; Reasons=@('window_root_owner_conflict'); Mutate={ param($frame,$window) $window.root_package = $null } },
        [pscustomobject]@{ Name='root-binding'; Reasons=@('root_window_binding_invalid'); Mutate={ param($frame,$window) $window.root_window_binding = 'mismatch' } },
        [pscustomobject]@{ Name='window-bounds'; Reasons=@('window_geometry_invalid'); Mutate={
            param($frame,$window)
            $window.bounds = [pscustomobject]@{ left=0; top=0; right=0; bottom=0 }
            @($frame.panes | Where-Object window_label -CEQ 'aw1')[0].bounds = Copy-C1BValue $window.bounds
        } },
        [pscustomobject]@{ Name='visited-zero'; Reasons=@('subtree_capture_incomplete'); Mutate={
            param($frame,$window)
            $frame.node_observations = @($frame.node_observations | Where-Object window_label -CNE 'aw1')
            $window.subtree_capture.visited_node_count = 0
        } },
        [pscustomobject]@{ Name='projection-invalid'; Reasons=@('pane_projection_invalid'); Mutate={
            param($frame,$window)
            @($frame.panes | Where-Object window_label -CEQ 'aw1')[0].projection_binding = 'unknown'
        } },
        [pscustomobject]@{ Name='declared-node-count'; Reasons=@('subtree_counts_invalid','subtree_capture_incomplete'); Mutate={
            param($frame,$window) $window.subtree_capture.visited_node_count = 2
        } },
        [pscustomobject]@{ Name='root-count'; Reasons=@('subtree_counts_invalid'); Mutate={
            param($frame,$window) @($frame.node_observations | Where-Object window_label -CEQ 'aw1')[0].is_root = $false
        } },
        [pscustomobject]@{ Name='root-node-binding'; Reasons=@('node_binding_invalid'); Mutate={
            param($frame,$window) @($frame.node_observations | Where-Object window_label -CEQ 'aw1')[0].window_id_binding = 'mismatch'
        } },
        [pscustomobject]@{ Name='root-node-geometry'; Reasons=@('node_binding_invalid'); Mutate={
            param($frame,$window)
            $root = @($frame.node_observations | Where-Object window_label -CEQ 'aw1')[0]
            $root.geometry_status = 'positive'
            $root.bounds = [pscustomobject]@{ left=3000; top=0; right=3100; bottom=100 }
        } }
    )
    foreach ($variant in $focusCompletenessVariants) {
        $incompleteFocus = Copy-C1BBaseDocument
        $mutate = [scriptblock]$variant.Mutate
        foreach ($frame in $incompleteFocus.frames) {
            $applicationWindow = @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0]
            & $mutate $frame $applicationWindow
        }
        Set-C1BFocusUnknown $incompleteFocus
        foreach ($reason in @($variant.Reasons)) { Add-C1BDeclaredReason $incompleteFocus ([string]$reason) }
        $incompleteFocusResult = Invoke-C1BFixture $incompleteFocus "focus-unknown-$($variant.Name)"
        Assert-C1B $incompleteFocusResult.fixture_contract_valid "honest unknown focus rejected for $($variant.Name)"
        Assert-C1B (-not ($incompleteFocusResult.reason_codes -ccontains 'focus_inventory_invalid')) `
            "consumer did not expect unknown focus for $($variant.Name)"
    }
    $forgedIncompleteFocus = Copy-C1BBaseDocument
    foreach ($frame in $forgedIncompleteFocus.frames) {
        @($frame.a11y_windows | Where-Object window_label -CEQ 'aw1')[0].subtree_capture.root_child_count = $null
    }
    Add-C1BDeclaredReason $forgedIncompleteFocus 'subtree_capture_incomplete'
    Add-C1BDeclaredReason $forgedIncompleteFocus 'focus_inventory_invalid'
    $forgedIncompleteFocusResult = Invoke-C1BFixture $forgedIncompleteFocus 'incomplete-subtree-window-only-forged'
    Assert-C1BCode $forgedIncompleteFocusResult 'focus_inventory_invalid'
    Complete-C1BCase @(
        'incomplete_subtree_focus_unknown','root_and_subtree_completeness_required',
        'persisted_focus_topology_complete','focus_root_count_and_declared_node_count_required',
        'focus_root_binding_and_geometry_required'
    )

    # 48. 截断的 window 清单不能仅凭 hidden-shaped IME tuple 声称 hidden，sidecar 也不能单独抬高 verified。
    $truncatedWindows = Copy-C1BBaseDocument
    foreach ($frame in $truncatedWindows.frames) { $frame.windows_truncated = $true }
    Set-C1BFocusUnknown $truncatedWindows
    Add-C1BDeclaredReason $truncatedWindows 'window_inventory_truncated'
    Add-C1BDeclaredReason $truncatedWindows 'ime_inventory_invalid'
    $truncatedWindowsResult = Invoke-C1BFixture $truncatedWindows 'truncated-window-inventory-hidden-ime'
    Assert-C1B $truncatedWindowsResult.fixture_contract_valid 'truthful truncated window inventory was rejected'
    Assert-C1BCode $truncatedWindowsResult 'window_inventory_truncated'
    Assert-C1BCode $truncatedWindowsResult 'ime_inventory_invalid'
    Assert-C1B (-not $truncatedWindowsResult.window_inventory_observed -and
        -not $truncatedWindowsResult.application_window_topology_observed -and
        -not $truncatedWindowsResult.ime_hidden_observed -and
        -not $truncatedWindowsResult.ime_hidden_verified) 'truncated window inventory retained IME/topology claims'
    $forgedTruncatedSidecar = Copy-C1BValue $sidecar
    $forgedTruncatedSidecar.claims.ime_hidden_observed = $false
    $forgedTruncatedSidecar.claims.ime_hidden_verified = $true
    Assert-C1B (-not (($forgedTruncatedSidecar | ConvertTo-Json -Depth 20) |
        Test-Json -SchemaFile $sidecarSchema -ErrorAction SilentlyContinue)) `
        'sidecar allowed verified hidden IME over false observation'
    Complete-C1BCase @(
        'truncated_window_inventory','windows_truncated_blocks_hidden_ime',
        'truncated_inventory_blocks_sidecar_ime_verification'
    )

    # 49. IME sample 必须 exact 绑定同帧 capture token；schema 与 validator 各自 fail-closed。
    $mismatchedImeToken = Copy-C1BBaseDocument
    $mismatchedImeToken.frames[0].ime.capture_token = 'c2'
    $mismatchedImeTokenResult = Invoke-C1BFixture $mismatchedImeToken 'ime-capture-token-mismatch'
    Assert-C1B (-not $mismatchedImeTokenResult.fixture_contract_valid) `
        'schema accepted an IME sample bound to the wrong frame token'
    Assert-C1BCode $mismatchedImeTokenResult 'json_schema_validation_failed'
    Assert-C1B (-not $mismatchedImeTokenResult.ime_hidden_observed -and
        -not $mismatchedImeTokenResult.ime_hidden_verified) `
        'wrong-frame IME token retained hidden observed/verified claims'

    $directMismatch = Copy-C1BBaseDocument
    $directMismatch.frames[0].ime.capture_token = 'c2'
    $directIssues = [Collections.Generic.List[object]]::new()
    $directFacts = Test-TL1C1BV1Frame $directMismatch.frames[0] 0 $directIssues
    Assert-C1B ((Get-TL1C1BV1ReasonCodes $directIssues) -ccontains 'ime_inventory_invalid') `
        'validator semantic layer did not independently reject wrong-frame IME token'
    Assert-C1B (-not $directFacts.ime_hidden_observed) `
        'validator semantic layer retained hidden IME after token mismatch'
    Complete-C1BCase @(
        'ime_capture_token_binding','ime_capture_token_schema_exact',
        'ime_capture_token_mismatch_blocks_hidden_ime'
    )

    $requiredCoverage = [string[]]@(Get-TL1C1BV1OfflineRequiredCoverageIds)
    $missing = @($requiredCoverage | Where-Object { -not $script:Coverage.Contains($_) })
    Assert-C1B ($missing.Count -eq 0) "missing required coverage: $($missing -join ',')"
    Assert-C1B ($script:CaseCount -eq @(Get-TL1C1BV1OfflineRequiredCaseIds).Count) 'required case count mismatch'
    if (-not [string]::IsNullOrWhiteSpace($SummaryPath) -or -not [string]::IsNullOrWhiteSpace($GateRunId)) {
        if ([string]::IsNullOrWhiteSpace($SummaryPath) -or $GateRunId -cnotmatch '^gate-[0-9a-f]{32}$') {
            throw 'SummaryPath and canonical GateRunId must be supplied together.'
        }
        $summary = New-TL1C1BV1OfflineCompleteSummary $GateRunId @($script:CaseResults.ToArray()) $script:StartedAt
        Write-TL1C1BV1OfflineSummaryAtomic $summary $repoRoot $SummaryPath $GateRunId
    }
    "C1B_OFFLINE_PASS cases=$script:CaseCount coverage=$($script:Coverage.Count)/$($requiredCoverage.Count)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot.FullName) { [IO.Directory]::Delete($tempRoot.FullName, $true) }
}
