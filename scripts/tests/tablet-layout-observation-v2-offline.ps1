#Requires -Version 7.5
[CmdletBinding()]
param(
    [string]$SummaryPath,
    [string]$GateRunId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$ValidatorPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-v2-validator.ps1'
$GateLibraryPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-v2-offline-gate.ps1'
$CliPath = Join-Path $RepoRoot 'scripts\validate-tablet-layout-observation-v2.ps1'
$SchemaPath = Join-Path $RepoRoot 'docs\contracts\tablet-layout-observation-v2.schema.json'
$FixtureRoot = Join-Path $PSScriptRoot 'fixtures\tablet-layout-observation\v2'
$BaseEvidencePath = Join-Path $FixtureRoot 'native-multi-landscape.json'
$BaseT0Path = Join-Path $FixtureRoot 'upstream-t0-v5.json'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-mobile-tl1-v2-' + [guid]::NewGuid().ToString('N'))
$CaseRoot = Join-Path $TestRoot 'controlled-fixtures'
$script:Passed = 0
$script:Failed = 0
$script:WriteIndex = 0
$script:CaseResults = [Collections.Generic.List[object]]::new()
$script:StartedAt = [DateTimeOffset]::UtcNow

. $GateLibraryPath

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw $Because }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Because)
    if ($Actual -cne $Expected) { throw "$Because（期望=$Expected，实际=$Actual）" }
}

function Assert-Contains {
    param([object[]]$Values, [string]$Expected, [string]$Because)
    if (@($Values) -cnotcontains $Expected) {
        throw "$Because（缺少=$Expected，实际=$(@($Values) -join ',')）"
    }
}

function Assert-NotContains {
    param([object[]]$Values, [string]$Unexpected, [string]$Because)
    if (@($Values) -ccontains $Unexpected) {
        throw "$Because（不应包含=$Unexpected，实际=$(@($Values) -join ',')）"
    }
}

function Assert-DiagnosticSafety {
    param($Result, [string]$Because)
    Assert-Equal $Result.runtime_evidence $false "$Because runtime evidence"
    Assert-Equal $Result.layout_accepted $false "$Because layout acceptance"
    Assert-Equal $Result.wechat_layout_verified $false "$Because WeChat verification"
    Assert-Equal $Result.editor_action_ready $false "$Because editor action"
    Assert-Equal $Result.settings_mutation_allowed $false "$Because settings mutation"
    Assert-Equal $Result.device_action_allowed $false "$Because device action"
    Assert-Equal $Result.p0_capability 'unsupported' "$Because P0"
    Assert-Equal $Result.execution_grant $false "$Because execution"
}

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$CoverageId,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $caseId = $CoverageId -replace '_','-'
    $status = 'passed'
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $status = 'failed'
        $script:Failed++
        Write-Host "FAIL $Name：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host ($_.ScriptStackTrace -replace "`r?`n", "`n  ")
    }
    $script:CaseResults.Add([pscustomobject][ordered]@{
        case_id = $caseId
        status = $status
        coverage_ids = [string[]]@($CoverageId)
    })
}

function Copy-TL1V2Object {
    param([Parameter(Mandatory)]$Value)
    return $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 -DateKind String
}

function Write-T0Fixture {
    param([Parameter(Mandatory)]$Pair, [switch]$SyncEnvelope)
    $t0Raw = $Pair.T0 | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText(
        (Join-Path $CaseRoot $script:TL1V2FixedT0FixtureName),
        $t0Raw,
        [Text.UTF8Encoding]::new($false, $true)
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($t0Raw)
    try { $Pair.Evidence.upstream_t0.artifact_sha256 = Get-TL1V2Sha256Bytes $bytes }
    finally { if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
    $Pair.Evidence.upstream_t0.device_profile_hash = Get-TL1V2DeviceProfileHash $Pair.T0.device
    if ($SyncEnvelope) {
        $Pair.Evidence.upstream_t0.schema_version = [long]$Pair.T0.schema_version
        $Pair.Evidence.upstream_t0.run_id = [string]$Pair.T0.run_id
        $Pair.Evidence.upstream_t0.captured_at = [string]$Pair.T0.captured_at_utc
        $Pair.Evidence.upstream_t0.intake_status = [string]$Pair.T0.assessment.intake_status
        $Pair.Evidence.upstream_t0.readiness_status = [string]$Pair.T0.assessment.readiness_status
        $Pair.Evidence.upstream_t0.readiness_reasons = @($Pair.T0.assessment.readiness_block_reasons)
        $Pair.Evidence.upstream_t0.p0_capability = [string]$Pair.T0.assessment.p0_capability
        $Pair.Evidence.upstream_t0.p0_unsupported_reasons = @($Pair.T0.assessment.p0_unsupported_reasons)
    }
}

function New-FreshPair {
    $evidence = Get-Content -LiteralPath $BaseEvidencePath -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100 -DateKind String
    $t0 = Get-Content -LiteralPath $BaseT0Path -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100 -DateKind String
    $last = [DateTimeOffset]::UtcNow.AddSeconds(-1)
    $first = $last.AddMilliseconds(-1200)
    $t0At = $first.AddSeconds(-2)
    $t0.captured_at_utc = $t0At.ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $evidence.frames[0].captured_at = $first.ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $evidence.frames[1].captured_at = $last.ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $evidence.captured_at = $evidence.frames[1].captured_at
    $pair = [pscustomobject]@{ Evidence=$evidence; T0=$t0 }
    Write-T0Fixture $pair -SyncEnvelope
    return $pair
}

function Set-PairCaptureTimes {
    param(
        [Parameter(Mandatory)]$Pair,
        [Parameter(Mandatory)][DateTimeOffset]$First,
        [Parameter(Mandatory)][DateTimeOffset]$Last
    )
    $Pair.T0.captured_at_utc = $First.AddSeconds(-2).ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $Pair.Evidence.frames[0].captured_at = $First.ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $Pair.Evidence.frames[1].captured_at = $Last.ToString(
        $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
    )
    $Pair.Evidence.captured_at = $Pair.Evidence.frames[1].captured_at
    Write-T0Fixture $Pair -SyncEnvelope
}

function Write-EvidenceRaw {
    param([Parameter(Mandatory)][string]$Raw, [string]$Stem = 'case')
    $script:WriteIndex++
    $safeStem = $Stem -replace '[^a-zA-Z0-9._-]','-'
    $path = Join-Path $CaseRoot ("{0:D3}-{1}.json" -f $script:WriteIndex, $safeStem)
    [IO.File]::WriteAllText($path, $Raw, [Text.UTF8Encoding]::new($false, $true))
    return $path
}

function Invoke-Evidence {
    param([Parameter(Mandatory)]$Evidence, [string]$Stem = 'case')
    $path = Write-EvidenceRaw ($Evidence | ConvertTo-Json -Depth 100) $Stem
    return Test-TabletLayoutObservationV2File $path $CaseRoot -FixtureMode
}

function Invoke-Pair {
    param([Parameter(Mandatory)]$Pair, [string]$Stem = 'case')
    return Invoke-Evidence $Pair.Evidence $Stem
}

function Set-FrameWindowLabel {
    param([Parameter(Mandatory)]$Frame, [string]$Old, [string]$New)
    foreach ($window in @($Frame.a11y_windows)) {
        if ($window.window_label -ceq $Old) { $window.window_label = $New }
    }
    foreach ($pane in @($Frame.panes)) {
        if ($pane.window_label -ceq $Old) { $pane.window_label = $New }
    }
    foreach ($node in @($Frame.node_observations)) {
        if ($node.window_label -ceq $Old) { $node.window_label = $New }
    }
    if ($Frame.target.conversation_window_label -ceq $Old) { $Frame.target.conversation_window_label = $New }
    foreach ($name in @('title_candidates','toolbar_candidates','message_candidates','input_candidates')) {
        foreach ($candidate in @($Frame.target.$name)) {
            if ($candidate.window_label -ceq $Old) { $candidate.window_label = $New }
        }
    }
    if ($Frame.target.focus.window_label -ceq $Old) { $Frame.target.focus.window_label = $New }
}

function Add-OverlayWindow {
    param([Parameter(Mandatory)]$Frame, [long]$DisplayId, [bool]$Occludes)
    $bounds = if ($Occludes) {
        [pscustomobject]@{ left=1200L; top=20L; right=2300L; bottom=400L }
    } else { [pscustomobject]@{ left=10L; top=10L; right=100L; bottom=100L } }
    $Frame.a11y_windows = @($Frame.a11y_windows) + @([pscustomobject][ordered]@{
        window_label='aw3'; identity_namespace='a11y_run_local'; display_id=$DisplayId
        type=if ($Occludes) { 'accessibility_overlay' } else { 'system' }
        root_status='absent'; root_package=$null; layer=20L; bounds=$bounds; touchable_bounds=$bounds
        active=$false; focused=$false
    })
}

function Add-ImeWindow {
    param(
        [Parameter(Mandatory)]$Frame,
        [Parameter(Mandatory)][AllowNull()]$Bounds,
        [long]$DisplayId = 0L,
        [string]$WindowLabel = 'aw3'
    )
    $Frame.a11y_windows = @($Frame.a11y_windows) + @([pscustomobject][ordered]@{
        window_label=$WindowLabel; identity_namespace='a11y_run_local'; display_id=$DisplayId
        type='input_method'; root_status='absent'; root_package=$null; layer=30L
        bounds=$Bounds; touchable_bounds=$Bounds; active=$false; focused=$false
    })
}

function Set-VisibleTargetIme {
    param(
        [Parameter(Mandatory)]$Frame,
        [Parameter(Mandatory)][AllowNull()]$Bounds
    )
    $Frame.a11y_windows[1].focused = $true
    ($Frame.node_observations | Where-Object role -ceq 'input_editor')[0].focused = $true
    $Frame.target.input_candidates[0].focused = $true
    $Frame.target.focus.status = 'known'
    $Frame.target.focus.window_label = 'aw2'
    $Frame.target.focus.input_candidate_label = 'in1'
    $Frame.target.ime.visible = $true
    $Frame.target.ime.mode = 'docked'
    $Frame.target.ime.bounds = $Bounds
    $Frame.target.ime.editor_fingerprint_hash = $Frame.target.input_candidates[0].editor_fingerprint_hash
    $Frame.target.ime.binding = 'target_editor'
    $Frame.target.ime.target_input_candidate_label = 'in1'
}

try {
    New-Item -ItemType Directory -Path $CaseRoot -Force | Out-Null

    Test-Case 'fresh blocked T0 envelope 原样保留且 hash 独立复核' 'upstream_t0_block_preserved' {
        $pair = New-FreshPair
        $result = Invoke-Pair $pair 't0-positive'
        Assert-True $result.fixture_contract_valid "fresh T0 fixture contract 应有效；reasons=$($result.reason_codes -join ',')；last=$script:TL1V2LastValidationException"
        Assert-True $result.diagnostic_observed "blocked readiness 只应路由 diagnostic observation；reasons=$($result.reason_codes -join ',')；last=$script:TL1V2LastValidationException"
        Assert-DiagnosticSafety $result 'fresh T0 positive'

        $pair = New-FreshPair
        $pair.T0.assessment.readiness_status = 'accepted'
        Write-T0Fixture $pair
        $blocked = Invoke-Pair $pair 't0-rewritten'
        Assert-Contains $blocked.reason_codes 'upstream_t0_invalid' '不得把 blocked T0 改写为 accepted。'

        $pair = New-FreshPair
        $pair.Evidence.upstream_t0.artifact_sha256 = 'sha256:' + ('9' * 64)
        $hashBlocked = Invoke-Pair $pair 't0-hash'
        Assert-Contains $hashBlocked.reason_codes 'upstream_t0_hash_mismatch' 'caller 自报 artifact hash 不得绕过。'

        $pair = New-FreshPair
        $pair.Evidence.provenance.kind = 'gateway_runtime_probe'
        $firstFrameAt = ConvertFrom-TL1V2Timestamp $pair.Evidence.frames[0].captured_at
        $pair.T0.captured_at_utc = $firstFrameAt.AddMinutes(-11).ToString(
            $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture
        )
        Write-T0Fixture $pair -SyncEnvelope
        $pair.Evidence.upstream_t0.artifact_sha256 = 'sha256:' + ('8' * 64)
        $pair.Evidence.upstream_t0.device_profile_hash = 'sha256:' + ('7' * 64)
        $independentIssues = Invoke-Pair $pair 't0-independent-after-provenance-issue'
        Assert-Contains $independentIssues.reason_codes 'fixture_origin_required' `
            '反例必须先形成独立的 observation provenance issue。'
        Assert-Contains $independentIssues.reason_codes 'upstream_t0_hash_mismatch' `
            '已有独立 issue 时仍必须复核并报告 T0 artifact hash。'
        Assert-Contains $independentIssues.reason_codes 'upstream_t0_device_hash_mismatch' `
            '已有独立 issue 时仍必须复核并报告 T0 device hash。'
        Assert-Contains $independentIssues.reason_codes 'upstream_t0_stale' `
            '已有独立 issue 时仍必须复核并报告 T0 freshness。'
    }

    Test-Case 'route 固定 probe_only 且不授予设置/设备动作' 'probe_only_route' {
        $pair = New-FreshPair
        $pair.Evidence.route.settings_mutation_allowed = $true
        $result = Invoke-Pair $pair 'route-promote'
        Assert-Contains $result.reason_codes 'json_schema_validation_failed' 'route 自提升必须由 closed schema 拒绝。'
        Assert-DiagnosticSafety $result 'route promotion'
        $runtime = Test-TabletLayoutObservationV2File '\\server\caller.json' $CaseRoot
        Assert-Contains $runtime.reason_codes 'runtime_producer_unavailable' 'runtime 入口必须在读取 caller 路径前阻断。'

        $missingPath = Join-Path $CaseRoot 'must-not-be-read.json'
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $cliOutput = @(& $pwsh -NoLogo -NoProfile -File $CliPath `
            -Path $missingPath -EvidenceRoot $CaseRoot 2>&1)
        $cliExit = $LASTEXITCODE
        $cliResult = ($cliOutput -join "`n") | ConvertFrom-Json -Depth 30 -DateKind String
        Assert-Equal $cliExit 1 '无 FixtureMode 的 CLI 应输出 blocked envelope 并非零退出。'
        Assert-Contains $cliResult.reason_codes 'runtime_producer_unavailable' `
            '无 FixtureMode 的 CLI 进程必须返回 runtime_producer_unavailable JSON。'
        Assert-Equal @($cliResult.reason_codes).Count 1 `
            '不存在的 caller path 不得在无 FixtureMode 时被读取或增加文件诊断。'
        Assert-DiagnosticSafety $cliResult 'CLI runtime producer unavailable envelope'
    }

    Test-Case '原生横屏两个微信 application window 可形成 observed 诊断' 'native_multi_landscape_two_window' {
        $result = Invoke-Pair (New-FreshPair) 'native-two-window'
        Assert-True $result.diagnostic_observed '双 window fixture 应完成诊断。'
        Assert-DiagnosticSafety $result 'native two-window'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { Add-OverlayWindow $frame 0 $false }
        $nonApp = Invoke-Pair $pair 'two-app-plus-system-window'
        Assert-True $nonApp.diagnostic_observed '非遮挡 system window 可被持久，但不得计入两个 application window。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-ImeWindow $frame ([pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            })
        }
        $imeWindow = Invoke-Pair $pair 'two-app-plus-ime-window'
        Assert-Contains $imeWindow.reason_codes 'ime_target_editor_unbound' `
            'hidden IME observation 中存在 interactive input_method window 必须 fail closed。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.nodes_truncated = $true }
        $truncated = Invoke-Pair $pair 'bounded-node-overflow'
        Assert-True $truncated.fixture_contract_valid '512 上限后的截断形状仍须符合 closed schema。'
        Assert-Contains $truncated.reason_codes 'node_inventory_truncated' 'node inventory 截断必须阻断 observed。'
    }

    Test-Case 'a11y awN 命名空间与 T0 wN 不互认' 'window_identity_namespace' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.a11y_windows[0].window_label = 'w1' }
        $result = Invoke-Pair $pair 'wms-label'
        Assert-Contains $result.reason_codes 'json_schema_validation_failed' 'T0 wN 不得进入 a11y awN 字段。'
        Assert-DiagnosticSafety $result 'identity namespace'
    }

    Test-Case '单帧 awN 必须一一映射不同 a11y identity' 'window_label_bijection' {
        $pair = New-FreshPair
        $pair.Evidence.frames[0].a11y_windows[1].window_label = 'aw1'
        $result = Invoke-Pair $pair 'duplicate-aw'
        Assert-Contains $result.reason_codes 'window_label_duplicate' '重复 awN 必须阻断。'
        Assert-DiagnosticSafety $result 'window label bijection'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.windows_truncated = $true }
        $truncated = Invoke-Pair $pair 'bounded-window-overflow'
        Assert-True $truncated.fixture_contract_valid '16 上限后的截断形状仍须符合 closed schema。'
        Assert-Contains $truncated.reason_codes 'window_inventory_truncated' 'window inventory 截断必须阻断 observed。'
    }

    Test-Case '同一语义 window 跨帧换 awN 必须识别 identity replacement' 'window_identity_replacement' {
        $pair = New-FreshPair
        Set-FrameWindowLabel $pair.Evidence.frames[1] 'aw2' 'aw3'
        $result = Invoke-Pair $pair 'identity-replacement'
        Assert-Contains $result.reason_codes 'window_identity_replacement' '跨帧 awN replacement 未检出。'
        Assert-DiagnosticSafety $result 'identity replacement'
    }

    Test-Case '任一 application root owner 非微信即冲突' 'window_root_owner_conflict' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.a11y_windows[1].root_package = 'com.example.other' }
        $result = Invoke-Pair $pair 'owner-conflict'
        Assert-Contains $result.reason_codes 'window_root_owner_conflict' 'root owner 冲突未检出。'
    }

    Test-Case '两个 app window 与 navigation/conversation pane 必须双射' 'window_pane_bijection' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.panes[1].window_label = 'aw1' }
        $result = Invoke-Pair $pair 'pane-bijection'
        Assert-Contains $result.reason_codes 'window_pane_bijection_invalid' 'window/pane 非双射未检出。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $false
            $frame.panes[0].window_label = 'aw3'
            $frame.panes[0].bounds = Copy-TL1V2Object $frame.a11y_windows[2].bounds
        }
        $nonAppPane = Invoke-Pair $pair 'pane-bound-to-system'
        Assert-Contains $nonAppPane.reason_codes 'window_pane_bijection_invalid' `
            'pane 只能绑定 application window，不能绑定 system/IME/overlay。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.panes_truncated = $true }
        $truncated = Invoke-Pair $pair 'bounded-pane-overflow'
        Assert-True $truncated.fixture_contract_valid '8 上限后的截断形状仍须符合 closed schema。'
        Assert-Contains $truncated.reason_codes 'pane_inventory_truncated' 'pane inventory 截断必须阻断 observed。'
    }

    Test-Case '目标 region 不能跨到 navigation window' 'cross_window_region' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.input_candidates[0].window_label = 'aw1' }
        $result = Invoke-Pair $pair 'cross-window-region'
        Assert-Contains $result.reason_codes 'cross_window_region' '跨 window input 未检出。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.input_candidates[0].bounds.top += 1L }
        $boundsMismatch = Invoke-Pair $pair 'candidate-node-bounds-mismatch'
        Assert-Contains $boundsMismatch.reason_codes 'region_binding_invalid' `
            'candidate/node 不能只按 label/window/pane 绑定，bounds 漂移必须阻断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.target.message_candidates = @($frame.target.message_candidates) + @(
                [pscustomobject][ordered]@{
                    candidate_label='msg2'; source_node_labels=@('an1')
                    bounds=Copy-TL1V2Object $frame.node_observations[0].bounds
                    window_label='aw1'; pane_label='ap1'; capture_token=$frame.capture.token
                }
            )
        }
        $navScrollable = Invoke-Pair $pair 'navigation-message-candidate'
        Assert-Contains $navScrollable.reason_codes 'region_candidate_ambiguous' `
            'navigation scrollable node 不得混入 target message candidates。'
        Assert-Contains $navScrollable.reason_codes 'cross_window_region' `
            'navigation message candidate 必须保留跨窗 ownership 诊断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $message = $frame.target.message_candidates[0]
            $message.bounds.bottom = $message.bounds.top
            $messageNode = ($frame.node_observations |
                Where-Object { $_.node_label -ceq $message.source_node_labels[0] })[0]
            $messageNode.bounds.bottom = $messageNode.bounds.top
        }
        $zeroHeightRegion = Invoke-Pair $pair 'single-region-zero-height'
        Assert-Contains $zeroHeightRegion.reason_codes 'region_geometry_invalid' `
            'toolbar/message/input 各恰一项时，其中一项零高仍必须几何阻断。'
    }

    Test-Case 'expected title 必须在全部 window 中全局唯一' 'target_title_global_uniqueness' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $duplicate = Copy-TL1V2Object $frame.target.title_candidates[0]
            $duplicate.candidate_label = 'tt2'
            $frame.target.title_candidates = @($frame.target.title_candidates) + @($duplicate)
        }
        $result = Invoke-Pair $pair 'duplicate-title'
        Assert-Contains $result.reason_codes 'target_title_not_unique' '全局同名 title 未检出。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.node_observations[1].role = 'other' }
        $spoofedRole = Invoke-Pair $pair 'self-declared-toolbar-title'
        Assert-Contains $spoofedRole.reason_codes 'title_wrong_role' `
            'candidate 自报 pane_toolbar_title 不能替代 referenced node 的 toolbar_title 结构证明。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.title_candidates[0].bounds.left += 1L }
        $spoofedBounds = Invoke-Pair $pair 'title-node-bounds-mismatch'
        Assert-Contains $spoofedBounds.reason_codes 'region_binding_invalid' `
            'title candidate 与 referenced node 的 bounds 必须逐字段一致。'
    }

    Test-Case '同 Y 但位于错误 window 的标题不能冒充 target' 'same_y_wrong_window' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $wrong = [pscustomobject][ordered]@{
                candidate_label='tt2'; node_label='an1'; label_hash=$frame.target.expected_title_hash
                semantic_role='conversation_row'; source='a11y_node'
                bounds=[pscustomobject]@{ left=80L; top=40L; right=820L; bottom=120L }
                window_label='aw1'; pane_label='ap1'; capture_token=$frame.capture.token
            }
            $frame.target.title_candidates = @($frame.target.title_candidates) + @($wrong)
        }
        $result = Invoke-Pair $pair 'same-y-wrong-window'
        Assert-Contains $result.reason_codes 'target_title_not_unique' '同 Y 错窗 title 应破坏全局唯一性。'
        Assert-Contains $result.reason_codes 'title_wrong_window' '同 Y 错窗必须保留 ownership 诊断。'
    }

    Test-Case '目标 conversation window/pane 跨帧漂移必须阻断' 'target_window_pane_drift' {
        $pair = New-FreshPair
        $pair.Evidence.frames[1].target.conversation_window_label = 'aw1'
        $pair.Evidence.frames[1].target.conversation_pane_label = 'ap1'
        $result = Invoke-Pair $pair 'target-drift'
        Assert-Contains $result.reason_codes 'target_window_pane_drift' 'target window/pane drift 未检出。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.target.conversation_window_label = $null
            $frame.target.conversation_pane_label = $null
        }
        $bothNull = Invoke-Pair $pair 'target-both-null'
        Assert-NotContains $bothNull.reason_codes 'target_window_pane_drift' '两帧 nullable target label 均为 null 时不得误报 drift。'

        $pair = New-FreshPair
        $pair.Evidence.frames[0].target.conversation_window_label = $null
        $pair.Evidence.frames[0].target.conversation_pane_label = $null
        $nullToValue = Invoke-Pair $pair 'target-null-to-value'
        Assert-Contains $nullToValue.reason_codes 'target_window_pane_drift' 'target label 从 null 变为非 null 必须报告 drift。'

        $pair = New-FreshPair
        $pair.Evidence.frames[1].target.conversation_window_label = $null
        $pair.Evidence.frames[1].target.conversation_pane_label = $null
        $valueToNull = Invoke-Pair $pair 'target-value-to-null'
        Assert-Contains $valueToNull.reason_codes 'target_window_pane_drift' 'target label 从非 null 变为 null 必须报告 drift。'
    }

    Test-Case 'focus absent 仍可完成纯布局感知' 'focus_absent_perception' {
        $pair = New-FreshPair
        $result = Invoke-Pair $pair 'focus-absent'
        Assert-True $result.diagnostic_observed 'focus absent 不应破坏纯感知诊断。'
        Assert-Equal $result.editor_action_ready $false 'focus absent 永远不能 action ready。'
    }

    Test-Case 'known focus 指向其它 window 必须冲突' 'focus_target_conflict' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.a11y_windows[0].focused = $true
            $frame.target.input_candidates[0].focused = $true
            $frame.target.focus.status = 'known'
            $frame.target.focus.window_label = 'aw1'
            $frame.target.focus.input_candidate_label = 'in1'
        }
        $result = Invoke-Pair $pair 'focus-conflict'
        Assert-Contains $result.reason_codes 'focus_target_conflict' 'known other-window focus 未检出。'
    }

    Test-Case 'unknown focus 不能靠 fallback 推断 target' 'focus_fallback_insufficient' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.focus.status = 'unknown' }
        $result = Invoke-Pair $pair 'focus-unknown'
        Assert-Contains $result.reason_codes 'focus_fallback_insufficient' 'unknown focus 不得被猜成 target。'
        Assert-NotContains $result.reason_codes 'focus_target_conflict' `
            'unknown 且 serialized focus inventory 无冲突时只应有 fallback reason。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.focus.status = 'unknown' }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('focus_fallback_insufficient')
        $intrinsicExact = Invoke-Pair $pair 'intrinsic-reason-exact'
        Assert-Contains $intrinsicExact.reason_codes 'focus_fallback_insufficient' `
            'producer 可稳定重算的 intrinsic reason 必须保留。'
        Assert-NotContains $intrinsicExact.reason_codes 'declared_status_mismatch' `
            'intrinsic status/reason exact 声明不应被误报。'
        Assert-NotContains $intrinsicExact.reason_codes 'declared_reasons_incomplete' `
            'intrinsic exact reason 不应被误报 incomplete。'
        Assert-NotContains $intrinsicExact.reason_codes 'consistency_declared_mismatch' `
            'focus intrinsic blocker 不应污染 capture consistency。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0L $false
            $frame.a11y_windows[2].focused = $true
            $frame.target.focus.status = 'unknown'
        }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('focus_target_conflict','focus_fallback_insufficient')
        $unknownNonAppConflict = Invoke-Pair $pair 'focus-unknown-nonapp-conflict-exact'
        Assert-Contains $unknownNonAppConflict.reason_codes 'focus_target_conflict' `
            'unknown focus 的 non-application focused window 必须重算 conflict。'
        Assert-Contains $unknownNonAppConflict.reason_codes 'focus_fallback_insufficient' `
            'unknown focus 即使已有 conflict 仍必须保留 fallback insufficient。'
        Assert-NotContains $unknownNonAppConflict.reason_codes 'declared_status_mismatch' `
            'unknown+conflict 两个 intrinsic reasons exact 声明不应误报。'
        Assert-NotContains $unknownNonAppConflict.reason_codes 'declared_reasons_incomplete' `
            'unknown+conflict exact 声明不应误报 incomplete。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.a11y_windows[1].focused = $true
            $frame.target.focus.status = 'unknown'
        }
        $unknownAsymmetry = Invoke-Pair $pair 'focus-unknown-window-input-asymmetry'
        Assert-Contains $unknownAsymmetry.reason_codes 'focus_target_conflict' `
            'focused app window 与 focused input 有无不对称必须重算 conflict。'
        Assert-Contains $unknownAsymmetry.reason_codes 'focus_fallback_insufficient' `
            'asymmetry 下 unknown 仍须保留 fallback。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.a11y_windows[0].focused = $true
            ($frame.node_observations | Where-Object role -ceq 'input_editor')[0].focused = $true
            $frame.target.input_candidates[0].focused = $true
            $frame.target.focus.status = 'unknown'
        }
        $unknownLabelMismatch = Invoke-Pair $pair 'focus-unknown-window-input-label-mismatch'
        Assert-Contains $unknownLabelMismatch.reason_codes 'focus_target_conflict' `
            'focused window/input label 不一致或非 target 必须重算 conflict。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.a11y_windows[0].focused = $true
            $frame.a11y_windows[1].focused = $true
            ($frame.node_observations | Where-Object role -ceq 'input_editor')[0].focused = $true
            $frame.target.input_candidates[0].focused = $true
            $frame.target.focus.status = 'unknown'
        }
        $unknownMultiple = Invoke-Pair $pair 'focus-unknown-multiple-focused-windows'
        Assert-Contains $unknownMultiple.reason_codes 'focus_target_conflict' `
            '多个 focused application windows 必须重算 conflict。'
    }

    Test-Case 'IME hidden 可做 layout-only 诊断但 action 固定 false' 'hidden_ime_layout_only' {
        $result = Invoke-Pair (New-FreshPair) 'ime-hidden'
        Assert-True $result.diagnostic_observed 'hidden IME 应允许 layout-only observation。'
        Assert-Equal $result.editor_action_ready $false 'hidden IME 不得 editor ready。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.windows_truncated = $true }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('window_inventory_truncated','ime_target_editor_unbound')
        $hiddenTruncated = Invoke-Pair $pair 'ime-hidden-window-inventory-truncated'
        Assert-Contains $hiddenTruncated.reason_codes 'window_inventory_truncated' `
            'hidden IME 也必须保留 window inventory 截断事实。'
        Assert-Contains $hiddenTruncated.reason_codes 'ime_target_editor_unbound' `
            'windows_truncated=true 时不能证明 hidden inventory 恰零，必须 fail closed。'
        Assert-NotContains $hiddenTruncated.reason_codes 'declared_status_mismatch' `
            'hidden+truncated 的 DTO 可见 intrinsic exact 声明不应误报。'
        Assert-NotContains $hiddenTruncated.reason_codes 'declared_reasons_incomplete' `
            'hidden+truncated exact 声明不应误报 incomplete。'
    }

    Test-Case 'visible IME 必须绑定 target editor fingerprint' 'ime_target_editor_binding' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds)
        }
        $valid = Invoke-Pair $pair 'ime-bound'
        Assert-True $valid.diagnostic_observed '正确 target editor binding 应可诊断 observed。'
        Assert-Equal $valid.editor_action_ready $false '即使绑定正确，第一阶段仍不放 action。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds)
            $frame.windows_truncated = $true
        }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('window_inventory_truncated','ime_target_editor_unbound')
        $truncatedImeExact = Invoke-Pair $pair 'ime-window-inventory-truncated-exact'
        Assert-Contains $truncatedImeExact.reason_codes 'window_inventory_truncated' `
            'visible IME 的 window inventory 截断事实必须保留。'
        Assert-Contains $truncatedImeExact.reason_codes 'ime_target_editor_unbound' `
            'windows_truncated=true 时不能证明 IME window 唯一，必须阻断 editor binding。'
        Assert-NotContains $truncatedImeExact.reason_codes 'declared_status_mismatch' `
            '可从 serialized DTO 重算的两个 intrinsic reasons exact 声明不应误报。'
        Assert-NotContains $truncatedImeExact.reason_codes 'declared_reasons_incomplete' `
            'visible IME truncated exact 声明不应误报 incomplete。'
        Assert-NotContains $truncatedImeExact.reason_codes 'consistency_declared_mismatch' `
            '稳定存在于两帧的 truncation blocker 不应污染 capture consistency。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds)
            $frame.windows_truncated = $true
        }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('window_inventory_truncated')
        $truncatedImeMissingReason = Invoke-Pair $pair 'ime-window-inventory-truncated-missing-reason'
        Assert-Contains $truncatedImeMissingReason.reason_codes 'declared_reasons_incomplete' `
            'windows_truncated visible IME 漏声明派生的 unbound reason 必须拒绝。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds)
        }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('ime_target_editor_unbound')
        $forgedInvisibleImeReason = Invoke-Pair $pair 'ime-raw-only-forged-reason'
        Assert-Contains $forgedInvisibleImeReason.reason_codes 'declared_status_mismatch' `
            'serialized DTO 可证明完整绑定时，不得额外声明 raw-only unbound reason。'
        Assert-NotContains $forgedInvisibleImeReason.reason_codes 'ime_target_editor_unbound' `
            '伪造的 evidence reason 不能变成 consumer 重算出的真实 issue。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Set-VisibleTargetIme $frame ([pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            })
        }
        $missingImeWindow = Invoke-Pair $pair 'ime-window-missing'
        Assert-Contains $missingImeWindow.reason_codes 'ime_target_editor_unbound' `
            'visible IME 缺少 interactive input_method window 必须阻断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds) 0L 'aw3'
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds) 0L 'aw4'
        }
        $multipleImeWindows = Invoke-Pair $pair 'ime-window-multiple'
        Assert-Contains $multipleImeWindows.reason_codes 'ime_target_editor_unbound' `
            'visible IME 存在多个 interactive input_method window 必须阻断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $imeBounds = [pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            }
            Set-VisibleTargetIme $frame $imeBounds
            Add-ImeWindow $frame (Copy-TL1V2Object $imeBounds) 1L
        }
        $wrongDisplayImeWindow = Invoke-Pair $pair 'ime-window-wrong-display'
        Assert-Contains $wrongDisplayImeWindow.reason_codes 'ime_target_editor_unbound' `
            'visible IME window 与 target window 不同 known display 必须阻断绑定。'
        Assert-Contains $wrongDisplayImeWindow.reason_codes 'multi_display_blocked' `
            'visible IME window 错 display 还必须保留通用 multi-display 诊断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Set-VisibleTargetIme $frame ([pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            })
            Add-ImeWindow $frame ([pscustomobject]@{
                left=900L; top=1500L; right=2800L; bottom=1968L
            })
        }
        $wrongBoundsImeWindow = Invoke-Pair $pair 'ime-window-wrong-bounds'
        Assert-Contains $wrongBoundsImeWindow.reason_codes 'ime_target_editor_unbound' `
            'visible IME window bounds 与 target.ime.bounds 不 exact 必须阻断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Set-VisibleTargetIme $frame ([pscustomobject]@{
                left=900L; top=1400L; right=2800L; bottom=1968L
            })
            Add-ImeWindow $frame ([pscustomobject]@{
                left=900L; top=1500L; right=900L; bottom=1968L
            })
        }
        $invalidImeWindowBounds = Invoke-Pair $pair 'ime-window-degenerate-bounds'
        Assert-Contains $invalidImeWindowBounds.reason_codes 'ime_target_editor_unbound' `
            'visible IME window 的退化 bounds 必须阻断 editor binding。'
        Assert-Contains $invalidImeWindowBounds.reason_codes 'window_geometry_invalid' `
            'visible IME window 的退化 bounds 必须保留通用 window geometry 诊断。'
        Assert-Contains $invalidImeWindowBounds.reason_codes 'region_geometry_invalid' `
            'visible IME window 的非 null 退化 bounds 还必须保留 IME region geometry 诊断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            $frame.target.ime.visible = $true
            $frame.target.ime.mode = 'docked'
            $frame.target.ime.bounds = [pscustomobject]@{ left=900L; top=1400L; right=2800L; bottom=1968L }
            $frame.target.ime.binding = 'other_editor'
            $frame.target.ime.editor_fingerprint_hash = 'sha256:' + ('f' * 64)
        }
        $blocked = Invoke-Pair $pair 'ime-other-editor'
        Assert-Contains $blocked.reason_codes 'ime_target_editor_unbound' '其它 editor IME 不得绑定 target。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { Set-VisibleTargetIme $frame $null }
        $nullBounds = Invoke-Pair $pair 'ime-target-null-bounds'
        Assert-Contains $nullBounds.reason_codes 'ime_target_editor_unbound' `
            'visible docked target IME 即使 fingerprint 齐全，bounds=null 也必须阻断。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Set-VisibleTargetIme $frame ([pscustomobject]@{
                left=900L; top=1400L; right=900L; bottom=1968L
            })
        }
        $degenerateBounds = Invoke-Pair $pair 'ime-target-degenerate-bounds'
        Assert-Contains $degenerateBounds.reason_codes 'ime_target_editor_unbound' `
            'visible docked target IME 即使 fingerprint 齐全，退化 bounds 也必须阻断。'
        Assert-Contains $degenerateBounds.reason_codes 'region_geometry_invalid' `
            'visible IME 的非 null 退化 bounds 还必须保留几何诊断。'
    }

    Test-Case '高 layer overlay 遮挡目标区域必须阻断' 'overlay_target_occlusion' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { Add-OverlayWindow $frame 0 $true }
        $result = Invoke-Pair $pair 'overlay-occlusion'
        Assert-Contains $result.reason_codes 'overlay_target_occlusion' 'target overlay occlusion 未检出。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[1].display_id = $null
            $frame.a11y_windows[2].display_id = $null
        }
        $bothDisplayUnknown = Invoke-Pair $pair 'overlay-display-both-null'
        Assert-NotContains $bothDisplayUnknown.reason_codes 'overlay_target_occlusion' `
            'target 与 overlay display id 均为 null 时不得冒充同一 display 并派生 occlusion。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[2].display_id = $null
        }
        $overlayDisplayUnknown = Invoke-Pair $pair 'overlay-display-null'
        Assert-NotContains $overlayDisplayUnknown.reason_codes 'overlay_target_occlusion' `
            'overlay display id 为 null 时不得派生 occlusion。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[1].display_id = $null
        }
        $targetDisplayUnknown = Invoke-Pair $pair 'target-display-null'
        Assert-NotContains $targetDisplayUnknown.reason_codes 'overlay_target_occlusion' `
            'target display id 为 null 时不得派生 occlusion。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { Add-OverlayWindow $frame 1 $true }
        $differentKnownDisplay = Invoke-Pair $pair 'overlay-different-known-display'
        Assert-NotContains $differentKnownDisplay.reason_codes 'overlay_target_occlusion' `
            '有效几何但 known display 不同的 overlay 不得派生 target occlusion。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[2].touchable_bounds = [pscustomobject]@{
                left=10L; top=10L; right=100L; bottom=100L
            }
        }
        $visualBounds = Invoke-Pair $pair 'overlay-window-bounds'
        Assert-Contains $visualBounds.reason_codes 'overlay_target_occlusion' `
            '视觉遮挡必须按 window.bounds 判断，不能由不相交 touchable_bounds 绕过。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[2].type = 'unknown'
        }
        $unknown = Invoke-Pair $pair 'unknown-high-layer-occlusion'
        Assert-Contains $unknown.reason_codes 'overlay_target_occlusion' `
            '未知高 layer interactive window 与 target 相交时必须按潜在 overlay fail closed。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) {
            Add-OverlayWindow $frame 0 $true
            $frame.a11y_windows[2].bounds.right = $frame.a11y_windows[2].bounds.left
            $frame.a11y_windows[2].touchable_bounds = Copy-TL1V2Object $frame.a11y_windows[2].bounds
        }
        $degenerateOverlay = Invoke-Pair $pair 'degenerate-overlay-not-occlusion'
        Assert-Contains $degenerateOverlay.reason_codes 'window_geometry_invalid' `
            '退化 overlay 必须保留 window geometry 诊断。'
        Assert-NotContains $degenerateOverlay.reason_codes 'overlay_target_occlusion' `
            '退化 overlay 不得额外冒充有效几何并产生 occlusion reason。'
    }

    Test-Case '任何额外 display window 都必须 fail closed' 'multi_display_blocked' {
        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { Add-OverlayWindow $frame 1 $false }
        $result = Invoke-Pair $pair 'multi-display'
        Assert-Contains $result.reason_codes 'multi_display_blocked' '额外 display 未检出。'
    }

    Test-Case 'window/layout/IME 必须落在同一 atomic revision bracket' 'atomic_capture_revision' {
        $pair = New-FreshPair
        $pair.Evidence.frames[1].capture.ime_revision = 999L
        $result = Invoke-Pair $pair 'revision-split'
        Assert-Contains $result.reason_codes 'atomic_capture_revision_invalid' 'revision split 未检出。'

        $pair = New-FreshPair
        $second = $pair.Evidence.frames[1]
        $second.capture.token = 'c1'
        foreach ($name in @('title_candidates','toolbar_candidates','message_candidates','input_candidates')) {
            foreach ($candidate in @($second.target.$name)) { $candidate.capture_token = 'c1' }
        }
        $second.target.ime.capture_token = 'c1'
        $duplicateToken = Invoke-Pair $pair 'duplicate-capture-token'
        Assert-Contains $duplicateToken.reason_codes 'capture_order_invalid' `
            '候选均跟随重复 c1 时，仍必须由 frame index/global uniqueness 阻断。'

        $pair = New-FreshPair
        $spanFirst = [DateTimeOffset]::UtcNow.AddSeconds(-30)
        $spanLast = $spanFirst.AddTicks([TimeSpan]::FromSeconds(15).Ticks + 1L)
        Set-PairCaptureTimes $pair $spanFirst $spanLast
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('capture_span_exceeded')
        $pair.Evidence.consistency.minimum_interval_ms = 15000L
        $pair.Evidence.consistency.stable = $false
        $pair.Evidence.consistency.reason_codes = @('capture_span_exceeded')
        $overSpan = Invoke-Pair $pair 'capture-span-15s-plus-100ns'
        Assert-Contains $overSpan.reason_codes 'capture_span_exceeded' `
            '15 秒加 100ns 必须严格越过 capture span 上限。'
        Assert-NotContains $overSpan.reason_codes 'declared_status_mismatch' `
            'capture_span_exceeded intrinsic exact 声明不应误报。'
        Assert-NotContains $overSpan.reason_codes 'consistency_declared_mismatch' `
            '15s+100ns 的 consistency exact 声明不应误报。'

        $pair = New-FreshPair
        $futureFirst = [DateTimeOffset]::UtcNow.AddMinutes(3)
        Set-PairCaptureTimes $pair $futureFirst $futureFirst.AddMilliseconds(1200)
        $future = Invoke-Pair $pair 'consumer-time-future'
        Assert-True $future.fixture_contract_valid 'future fixture 的静态 contract 仍应有效。'
        Assert-Equal $future.diagnostic_observed $false 'consumer 实际 UtcNow future 门必须阻断最终 observed。'
        Assert-Contains $future.reason_codes 'capture_in_future' 'consumer-owned future reason 未保留。'
        Assert-NotContains $future.reason_codes 'declared_status_mismatch' `
            'producer 未预声明 validation-time future 不应制造 status mismatch。'
        Assert-NotContains $future.reason_codes 'consistency_declared_mismatch' `
            'consumer-owned future 不应污染 producer intrinsic consistency。'

        $pair = New-FreshPair
        $staleFirst = [DateTimeOffset]::UtcNow.AddMinutes(-5).AddMilliseconds(-1200)
        Set-PairCaptureTimes $pair $staleFirst $staleFirst.AddMilliseconds(1200)
        $stale = Invoke-Pair $pair 'consumer-time-stale'
        Assert-True $stale.fixture_contract_valid 'stale fixture 的静态 contract 仍应有效。'
        Assert-Equal $stale.diagnostic_observed $false 'consumer 实际 UtcNow 两分钟 freshness 门必须阻断。'
        Assert-Contains $stale.reason_codes 'capture_stale' 'consumer-owned stale reason 未保留。'
        Assert-NotContains $stale.reason_codes 'declared_status_mismatch' `
            'producer 未预声明 validation-time stale 不应制造 status mismatch。'
        Assert-NotContains $stale.reason_codes 'consistency_declared_mismatch' `
            'consumer-owned stale 不应污染 producer intrinsic consistency。'

        $pair = New-FreshPair
        foreach ($frame in @($pair.Evidence.frames)) { $frame.target.focus.status = 'unknown' }
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('focus_fallback_insufficient')
        $combinedStaleFirst = [DateTimeOffset]::UtcNow.AddMinutes(-5).AddMilliseconds(-1200)
        Set-PairCaptureTimes $pair $combinedStaleFirst $combinedStaleFirst.AddMilliseconds(1200)
        $intrinsicAndDynamic = Invoke-Pair $pair 'intrinsic-plus-consumer-time-stale'
        Assert-Contains $intrinsicAndDynamic.reason_codes 'focus_fallback_insufficient' `
            '动态 freshness 不得丢失 producer exact intrinsic reason。'
        Assert-Contains $intrinsicAndDynamic.reason_codes 'capture_stale' `
            'intrinsic blocker 存在时 consumer 仍必须追加真实 stale reason。'
        Assert-NotContains $intrinsicAndDynamic.reason_codes 'declared_status_mismatch' `
            'intrinsic exact + consumer dynamic 组合不应制造 status mismatch。'
        Assert-NotContains $intrinsicAndDynamic.reason_codes 'consistency_declared_mismatch' `
            'intrinsic exact + consumer dynamic 组合不应污染 consistency。'

        $pair = New-FreshPair
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.reason_codes = @('capture_stale')
        $forgedDynamic = Invoke-Pair $pair 'forged-consumer-time-reason'
        Assert-Contains $forgedDynamic.reason_codes 'declared_status_mismatch' `
            'evidence 不得把 consumer-owned dynamic reason 伪装成 producer intrinsic 声明。'
        Assert-NotContains $forgedDynamic.reason_codes 'capture_stale' `
            'fresh evidence 自报 stale 不能让 consumer 产生真实 freshness reason。'

        $pair = New-FreshPair
        $pair.Evidence.diagnostic_status = 'blocked'
        $pair.Evidence.consistency.stable = $false
        $pair.Evidence.consistency.reason_codes = @('capture_in_future')
        $forgedDynamicConsistency = Invoke-Pair $pair 'forged-consumer-time-consistency'
        Assert-Contains $forgedDynamicConsistency.reason_codes 'consistency_declared_mismatch' `
            'evidence consistency 不得声明 consumer-owned dynamic reason。'
        Assert-NotContains $forgedDynamicConsistency.reason_codes 'capture_in_future' `
            'fresh evidence 自报 future consistency 不能产生真实 validation-time reason。'
    }

    Test-Case '只允许 run-local awN/anN，拒绝 raw identity 与聊天明文' 'run_local_window_privacy' {
        $pair = New-FreshPair
        $chatCanary = Get-TL1V2SyntheticPrivacyCanary
        $chatCanaryHash = Get-TL1V2SyntheticPrivacyCanaryHash
        $legalRaw = $pair.Evidence | ConvertTo-Json -Depth 100 -Compress
        Assert-True (-not $legalRaw.Contains($chatCanary, [StringComparison]::Ordinal)) `
            '合法 evidence 不得包含聊天 canary 明文。'
        Assert-True (-not $legalRaw.Contains($chatCanaryHash, [StringComparison]::Ordinal)) `
            '合法 evidence 不得包含聊天 canary 的稳定 SHA256。'
        $raw = $pair.Evidence | ConvertTo-Json -Depth 100
        $raw = $raw -replace '"schema"\s*:', `
            ('"raw_window_id":"Window{abc}","chat_text":"' + $chatCanary + '","schema":')
        $result = Test-TabletLayoutObservationV2File (Write-EvidenceRaw $raw 'privacy') $CaseRoot -FixtureMode
        Assert-Contains $result.reason_codes 'raw_identity_persisted' 'raw window identity 未检出。'
        Assert-Contains $result.reason_codes 'chat_plaintext_persisted' '聊天明文未检出。'
        Assert-DiagnosticSafety $result 'privacy leak'
        $digestRaw = ($pair.Evidence | ConvertTo-Json -Depth 100) -replace '"schema"\s*:', `
            ('"content_hash":"' + $chatCanaryHash + '","schema":')
        $digestResult = Test-TabletLayoutObservationV2File `
            (Write-EvidenceRaw $digestRaw 'privacy-stable-digest') $CaseRoot -FixtureMode
        Assert-Contains $digestResult.reason_codes 'chat_content_digest_persisted' `
            '聊天 canary 的稳定 SHA256 未被 privacy pre-scan 拒绝。'
        Assert-DiagnosticSafety $digestResult 'stable chat digest leak'

        $pair = New-FreshPair
        $pair.Evidence.run_id = $chatCanary
        Assert-True (($pair.Evidence | ConvertTo-Json -Depth 100 -Compress) |
                Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue) `
            'dummy canary run_id 反例本身必须先是 schema 合法字段值。'
        $legalFieldPlaintext = Invoke-Pair $pair 'privacy-canary-legal-safe-id'
        Assert-Contains $legalFieldPlaintext.reason_codes 'chat_plaintext_persisted' `
            'dummy canary 藏在 schema 合法 safeId value 中仍必须按 ordinal 拒绝。'

        $pair = New-FreshPair
        $pair.Evidence.provenance.producer_artifact_sha256 = $chatCanaryHash
        Assert-True (($pair.Evidence | ConvertTo-Json -Depth 100 -Compress) |
                Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue) `
            'dummy canary hash 反例本身必须先是 schema 合法字段值。'
        $legalFieldDigest = Invoke-Pair $pair 'privacy-canary-legal-hash'
        Assert-Contains $legalFieldDigest.reason_codes 'chat_content_digest_persisted' `
            'dummy canary 无盐 SHA 藏在 schema 合法 hash value 中仍必须拒绝。'

        $pair = New-FreshPair
        $pair.T0.device.manufacturer = $chatCanary
        Write-T0Fixture $pair
        $t0LegalPlaintext = Invoke-Pair $pair 'privacy-canary-t0-legal-string'
        Assert-Contains $t0LegalPlaintext.reason_codes 'chat_plaintext_persisted' `
            'fixed T0 raw 的合法 string value 也必须扫描 dummy canary 明文。'

        $pair = New-FreshPair
        $pair.T0.device.serial_hash = $chatCanaryHash
        Write-T0Fixture $pair
        $t0LegalDigest = Invoke-Pair $pair 'privacy-canary-t0-legal-hash'
        Assert-Contains $t0LegalDigest.reason_codes 'chat_content_digest_persisted' `
            'fixed T0 raw 的合法 hash value 也必须扫描 dummy canary 无盐 SHA。'
        $schemaSource = Get-Content -LiteralPath $SchemaPath -Raw -Encoding utf8
        Assert-True ($schemaSource -notmatch '文件传输助手') 'schema 不得落目标标题明文。'
    }

    Test-Case 'validator/gate 只读且不含设置修改或设备调用' 'native_setting_unchanged' {
        foreach ($path in @($ValidatorPath, $GateLibraryPath, $CliPath, $PSCommandPath)) {
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            Assert-Equal @($errors).Count 0 "PowerShell AST 错误：$path"
        }
        foreach ($path in @($ValidatorPath, $GateLibraryPath, $CliPath)) {
            $source = Get-Content -LiteralPath $path -Raw -Encoding utf8
            foreach ($forbidden in @('adb.exe','settings put','shell input','Start-Process','ToolRegistry','macro_run')) {
                Assert-True (-not $source.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) `
                    "离线脚本出现越界调用词：$forbidden"
            }
        }
        $pair = New-FreshPair
        Assert-Equal $pair.Evidence.route.settings_mutation_allowed $false 'fixture route 不得允许设置修改。'
        Assert-Equal $pair.Evidence.route.device_action_allowed $false 'fixture route 不得允许设备动作。'
    }

    Test-Case 'v2 合同不修改手机 P0 路径且不会输出 supported' 'phone_p0_unchanged' {
        $source = (Get-Content -LiteralPath $ValidatorPath -Raw -Encoding utf8) +
            (Get-Content -LiteralPath $CliPath -Raw -Encoding utf8)
        foreach ($phoneSymbol in @('P0WeChatPrepareMacro','p0-foreground-bootstrap','p0-oob','GatewayA11yService')) {
            Assert-True (-not $source.Contains($phoneSymbol, [StringComparison]::Ordinal)) `
                "v2 consumer 不得耦合手机 P0：$phoneSymbol"
        }
        $result = Invoke-Pair (New-FreshPair) 'phone-p0-isolated'
        Assert-DiagnosticSafety $result 'phone P0 isolation'
    }

    Test-Case '任意 fixture 的 P0/action/execution 恒 false' 'p0_exec_false' {
        $pair = New-FreshPair
        $pair.Evidence.p0_capability = 'supported'
        $pair.Evidence.execution_grant = $true
        $result = Invoke-Pair $pair 'p0-promotion'
        Assert-Contains $result.reason_codes 'json_schema_validation_failed' 'P0/exec 自提升必须拒绝。'
        Assert-DiagnosticSafety $result 'P0/exec promotion'
    }
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        $full = [IO.Path]::GetFullPath($TestRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($full).StartsWith('agent-mobile-tl1-v2-', [StringComparison]::Ordinal)) {
            [IO.Directory]::Delete($full, $true)
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($SummaryPath) -or -not [string]::IsNullOrWhiteSpace($GateRunId)) {
    try {
        if ([string]::IsNullOrWhiteSpace($SummaryPath) -or $GateRunId -cnotmatch '\Agate-[0-9a-f]{32}\z') {
            throw 'SummaryPath 与 canonical GateRunId 必须成对提供。'
        }
        $coverage = [string[]]@(
            Get-TL1V2OrdinalUniqueStrings ([string[]]@(
                $script:CaseResults | Where-Object status -ceq 'passed' | ForEach-Object coverage_ids
            ))
        )
        $required = [string[]]@(Get-TL1V2OfflineRequiredCoverageIds)
        $covered = @($required | Where-Object { $coverage -ccontains $_ }).Count
        $summary = [pscustomobject][ordered]@{
            schema = $script:TL1V2OfflineSummarySchema
            gate_run_id = $GateRunId
            started_at = $script:StartedAt.ToString($script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
            finished_at = [DateTimeOffset]::UtcNow.ToString($script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture)
            suite = $script:TL1V2Schema
            status = if ($script:Failed -eq 0) { 'passed' } else { 'failed' }
            test_exit_code = if ($script:Failed -eq 0) { 0L } else { 1L }
            total_cases = [long]$script:CaseResults.Count
            passed_cases = [long]$script:Passed
            failed_cases = [long]$script:Failed
            required_coverage_count = [long]$required.Count
            covered_required_count = [long]$covered
            coverage_ids = $coverage
            cases = @($script:CaseResults.ToArray())
            fixture_contract_only = $true
            runtime_evidence = $false
            layout_accepted = $false
            wechat_layout_verified = $false
            editor_action_ready = $false
            settings_mutation_allowed = $false
            device_action_allowed = $false
            p0_capability = 'unsupported'
            execution_grant = $false
        }
        Write-TL1V2OfflineSummaryAtomic $summary $RepoRoot $SummaryPath $GateRunId
    }
    catch {
        $script:Failed++
        Write-Host "FAIL machine summary：$($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`nT-L1 v2 diagnostic-only：$script:Passed passed，$script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
