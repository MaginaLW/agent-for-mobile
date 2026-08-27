#Requires -Version 7.5
# T-L1 C1b v1 pure-a11y topology diagnostic consumer。没有设备、动作、截图或 OCR 能力。

Set-StrictMode -Version 3.0

$script:TL1C1BV1Schema = 'tablet-layout-observation/c1b-v1'
$script:TL1C1BV1ValidationSchema = 'tablet-layout-observation-validation/c1b-v1'
$script:TL1C1BV1TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
$script:TL1C1BV1MinimumIntervalTicks = [TimeSpan]::FromMilliseconds(900).Ticks
$script:TL1C1BV1MaximumIntervalTicks = [TimeSpan]::FromSeconds(60).Ticks
$script:TL1C1BV1MaximumSpanTicks = [TimeSpan]::FromSeconds(15).Ticks
$script:TL1C1BV1MaximumAgeTicks = [TimeSpan]::FromMinutes(2).Ticks
$script:TL1C1BV1MaximumT0AgeTicks = [TimeSpan]::FromMinutes(10).Ticks
$script:TL1C1BV1TrustedT0ProducerSha = '4ca32b131007df58f7752c5ee9b2d049cb1cd54e'
$script:TL1C1BV1TrustedRuntimeTitleHash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
$script:TL1C1BV1SyntheticPrivacyCanary = 'tl1c1bv1.synthetic-privacy-canary.fixture-only.20260826'
$script:TL1C1BV1RequiredBlockers = [string[]]@(
    'tablet_c1b_diagnostic_only', 'upstream_t0_readiness_blocked',
    'tablet_landscape_p0_unimplemented', 'tablet_tl2_unverified'
)
$script:TL1C1BV1BaseDiagnosticReasons = [string[]]@(
    'pane_semantic_roles_unverified', 'tablet_layout_diagnostic_only',
    'target_conversation_unverified', 'target_regions_unverified'
)
$script:TL1C1BV1ConsumerTimeReasons = [string[]]@('capture_in_future', 'capture_stale')
$script:TL1C1BV1ContractFailureCodes = [string[]]@(
    'runtime_producer_unavailable', 'fixture_origin_required', 'route_contract_violation',
    'safety_constants_invalid', 'privacy_contract_violation', 'raw_identity_persisted',
    'chat_plaintext_persisted', 'chat_content_digest_persisted', 'duplicate_json_property',
    'json_number_not_int64', 'json_schema_validation_failed', 'consistency_declared_mismatch',
    'declared_status_mismatch', 'declared_reasons_incomplete', 'validation_exception'
)
function Add-TL1C1BV1Issue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    foreach ($issue in $Issues) {
        if ($issue.code -ceq $Code -and $issue.path -ceq $Path) { return }
    }
    $Issues.Add([pscustomobject]@{ code = $Code; path = $Path })
}

function Get-TL1C1BV1ReasonCodes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues)
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $out = [Collections.Generic.List[string]]::new()
    foreach ($issue in $Issues) {
        if ($set.Add([string]$issue.code)) { $out.Add([string]$issue.code) }
    }
    return [string[]]$out.ToArray()
}

function ConvertFrom-TL1C1BV1Timestamp {
    param($Value)
    if ($Value -isnot [string] -or $Value.Length -ne 28) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
            $Value, $script:TL1C1BV1TimestampFormat, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$parsed
        ) -or $parsed.Offset -ne [TimeSpan]::Zero) { return $null }
    return $parsed
}

function Test-TL1C1BV1RectSchema {
    param($Rect)
    if ($null -eq $Rect) { return $false }
    foreach ($name in @('left','top','right','bottom')) {
        if ($null -eq $Rect.PSObject.Properties[$name]) { return $false }
        $value = [long]$Rect.$name
        if ($value -lt -32768 -or $value -gt 32768) { return $false }
    }
    return $true
}

function Test-TL1C1BV1RectPositive {
    param($Rect)
    return (Test-TL1C1BV1RectSchema $Rect) -and [long]$Rect.right -gt [long]$Rect.left -and
        [long]$Rect.bottom -gt [long]$Rect.top
}

function Test-TL1C1BV1RectDegenerate {
    param($Rect)
    return (Test-TL1C1BV1RectSchema $Rect) -and
        ([long]$Rect.right -le [long]$Rect.left -or [long]$Rect.bottom -le [long]$Rect.top)
}

function Test-TL1C1BV1RectContained {
    param($Inner, $Outer)
    return (Test-TL1C1BV1RectPositive $Inner) -and (Test-TL1C1BV1RectPositive $Outer) -and
        [long]$Inner.left -ge [long]$Outer.left -and [long]$Inner.top -ge [long]$Outer.top -and
        [long]$Inner.right -le [long]$Outer.right -and [long]$Inner.bottom -le [long]$Outer.bottom
}

function Test-TL1C1BV1RectEqual {
    param($Left, $Right)
    return $null -ne $Left -and $null -ne $Right -and
        [long]$Left.left -eq [long]$Right.left -and [long]$Left.top -eq [long]$Right.top -and
        [long]$Left.right -eq [long]$Right.right -and [long]$Left.bottom -eq [long]$Right.bottom
}

function Get-TL1C1BV1RectSignature {
    param($Rect)
    if ($null -eq $Rect) { return '<null>' }
    return "$([long]$Rect.left),$([long]$Rect.top),$([long]$Rect.right),$([long]$Rect.bottom)"
}

function Find-TL1C1BV1DuplicateJsonProperty {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Duplicates
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = "$Path/$($property.Name)"
            if (-not $names.Add($property.Name)) { $Duplicates.Add($childPath) }
            Find-TL1C1BV1DuplicateJsonProperty $property.Value $childPath $Duplicates
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1C1BV1DuplicateJsonProperty $child "$Path/$index" $Duplicates
            $index++
        }
    }
}

function Find-TL1C1BV1InvalidNumber {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$InvalidPaths
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Number) {
        $raw = $Element.GetRawText()
        $parsed = 0L
        if ($raw -cnotmatch '\A-?(0|[1-9][0-9]*)\z' -or -not [long]::TryParse(
                $raw, [Globalization.NumberStyles]::AllowLeadingSign,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed
            )) { $InvalidPaths.Add($Path) }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            Find-TL1C1BV1InvalidNumber $property.Value "$Path/$($property.Name)" $InvalidPaths
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1C1BV1InvalidNumber $child "$Path/$index" $InvalidPaths
            $index++
        }
    }
}

function Get-TL1C1BV1CanaryHash {
    $bytes = [Text.Encoding]::UTF8.GetBytes($script:TL1C1BV1SyntheticPrivacyCanary)
    try {
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)
        ).ToLowerInvariant()
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Get-TL1C1BV1SyntheticPrivacyCanary { return $script:TL1C1BV1SyntheticPrivacyCanary }
function Get-TL1C1BV1SyntheticPrivacyCanaryHash { return Get-TL1C1BV1CanaryHash }

function Find-TL1C1BV1PrivacyFinding {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Findings
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        if ($null -ne $value -and $value.Contains($script:TL1C1BV1SyntheticPrivacyCanary, [StringComparison]::Ordinal)) {
            $Findings.Add([pscustomobject]@{ code='chat_plaintext_persisted'; path=$Path })
        }
        $hash = Get-TL1C1BV1CanaryHash
        if ($null -ne $value -and $value.Contains($hash, [StringComparison]::Ordinal)) {
            $Findings.Add([pscustomobject]@{ code='chat_content_digest_persisted'; path=$Path })
        }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = "$Path/$($property.Name)"
            $lower = $property.Name.ToLowerInvariant()
            if ($lower -in @(
                    'window_id','raw_window_id','root_id','raw_root_id','node_id','raw_node_id','unique_id',
                    'view_id','view_id_resource_name','window_tostring','root_tostring','node_tostring'
                )) {
                $Findings.Add([pscustomobject]@{ code='raw_identity_persisted'; path=$childPath })
            }
            elseif ($lower -in @(
                    'title','window_title','text','chat_text','chat_plaintext','content_description',
                    'message_text','class_name','raw_dump','screenshot_base64'
                )) {
                $Findings.Add([pscustomobject]@{ code='chat_plaintext_persisted'; path=$childPath })
            }
            elseif ($lower -ne 'expected_title_hash' -and $lower -ne 'chat_content_digest_persisted' -and
                ($lower -in @('content_hash','content_hashes','text_hash','title_hash','description_hash','stable_content_sha256') -or
                    $lower -match '(content|text|title|description).*(hash|digest|sha)')) {
                $Findings.Add([pscustomobject]@{ code='chat_content_digest_persisted'; path=$childPath })
            }
            Find-TL1C1BV1PrivacyFinding $property.Value $childPath $Findings
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1C1BV1PrivacyFinding $child "$Path/$index" $Findings
            $index++
        }
    }
}

function ConvertFrom-TL1C1BV1StrictJson {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Raw)
        $duplicates = [Collections.Generic.List[string]]::new()
        Find-TL1C1BV1DuplicateJsonProperty $document.RootElement '' $duplicates
        foreach ($path in $duplicates) { Add-TL1C1BV1Issue $Issues 'duplicate_json_property' $path }
        $invalidNumbers = [Collections.Generic.List[string]]::new()
        Find-TL1C1BV1InvalidNumber $document.RootElement '' $invalidNumbers
        foreach ($path in $invalidNumbers) { Add-TL1C1BV1Issue $Issues 'json_number_not_int64' $path }
        $privacy = [Collections.Generic.List[object]]::new()
        Find-TL1C1BV1PrivacyFinding $document.RootElement '' $privacy
        foreach ($finding in $privacy) { Add-TL1C1BV1Issue $Issues $finding.code $finding.path }
        if ($Issues.Count -gt 0) { return $null }
        return $Raw | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    }
    catch {
        Add-TL1C1BV1Issue $Issues 'validation_exception' '/'
        return $null
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Test-TL1C1BV1ReparseChain {
    param(
        [Parameter(Mandatory)][IO.FileSystemInfo]$Item,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $current = $Item
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/path'
            return $false
        }
        if ($current.FullName.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = if ($current -is [IO.DirectoryInfo]) { $current.Parent } else { $current.Directory }
    }
    return $true
}

function Resolve-TL1C1BV1ControlledPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    try {
        if (-not [IO.Path]::IsPathFullyQualified($EvidenceRoot) -or $EvidenceRoot.StartsWith('\\') -or
            $Path.StartsWith('\\')) {
            Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/path'
            return $null
        }
        $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        $driveRoot = [IO.Path]::GetPathRoot($root).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        if ($root.Equals($driveRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root)).DriveType -ne [IO.DriveType]::Fixed) {
            Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/evidence_root'
            return $null
        }
        $candidate = if ([IO.Path]::IsPathFullyQualified($Path)) {
            [IO.Path]::GetFullPath($Path)
        } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($candidate) -cne '.json') {
            Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/path'
            return $null
        }
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        $file = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or $file.PSIsContainer -or
            -not (Test-TL1C1BV1ReparseChain $file $root $Issues)) { return $null }
        return [string]$file.FullName
    }
    catch {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/path'
        return $null
    }
}

function Read-TL1C1BV1ControlledUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read,
            4096, [IO.FileOptions]::SequentialScan
        )
        if ($stream.Length -le 0 -or $stream.Length -gt 1048576) {
            Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/'
            return $null
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'unexpected EOF' }
            $offset += $read
        }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
            Add-TL1C1BV1Issue $Issues 'validation_exception' '/'
            return $null
        }
        return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/'
        return $null
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-TL1C1BV1WindowTypeForCode {
    param([int]$Code)
    return $(switch ($Code) {
        1 { 'application' }
        2 { 'input_method' }
        3 { 'system' }
        4 { 'accessibility_overlay' }
        5 { 'split_screen_divider' }
        6 { 'magnification_overlay' }
        7 { 'window_control' }
        default { 'unknown' }
    })
}

function Get-TL1C1BV1FrameSignature {
    param($Frame)
    $displayWidth = if ($null -ne $Frame.display.effective_size) {
        $Frame.display.effective_size.width
    } else { $null }
    $displayHeight = if ($null -ne $Frame.display.effective_size) {
        $Frame.display.effective_size.height
    } else { $null }
    $windows = [string[]]@($Frame.a11y_windows | ForEach-Object {
        "$($_.window_label)|$($_.display_id)|$($_.platform_type_code)|$($_.type)|$($_.root_handle_status)|" +
        "$($_.root_package)|$($_.root_window_binding)|$($_.subtree_capture.status)|" +
        "$($_.subtree_capture.root_child_count)|$($_.subtree_capture.visited_node_count)|" +
        "$($_.subtree_capture.positive_visible_geometry_node_count)|$($_.subtree_capture.focused_editable_node_count)|" +
        "$($_.subtree_capture.read_error_count)|$($_.subtree_capture.budget_exhausted)|" +
        "$($_.expected_window_title_match)|$($_.layer)|$(Get-TL1C1BV1RectSignature $_.bounds)|" +
        "$(Get-TL1C1BV1RectSignature $_.touchable_bounds)|$($_.active)|$($_.focused)"
    })
    [Array]::Sort($windows, [StringComparer]::Ordinal)
    $panes = [string[]]@($Frame.panes | ForEach-Object {
        "$($_.pane_label)|$($_.window_label)|$(Get-TL1C1BV1RectSignature $_.bounds)|" +
        "$($_.projection_binding)|$($_.semantic_role)|$(@($_.semantic_evidence).Count)"
    })
    [Array]::Sort($panes, [StringComparer]::Ordinal)
    $nodes = [string[]]@($Frame.node_observations | ForEach-Object {
        "$($_.node_label)|$($_.window_label)|$($_.pane_label)|$($_.source)|$($_.is_root)|" +
        "$($_.window_id_binding)|$($_.semantic_role)|$($_.geometry_status)|" +
        "$(Get-TL1C1BV1RectSignature $_.bounds)|$($_.visible)|$($_.enabled)|$($_.editable)|$($_.scrollable)|$($_.focused)"
    })
    [Array]::Sort($nodes, [StringComparer]::Ordinal)
    return @(
        $Frame.display.display_id_status, $Frame.display.display_id, $displayWidth, $displayHeight,
        $Frame.display.orientation,
        $Frame.windows_truncated, ($windows -join ';'), $Frame.panes_truncated, ($panes -join ';'),
        $Frame.nodes_truncated, ($nodes -join ';'), $Frame.focus.status, $Frame.focus.window_label,
        $Frame.focus.node_label, $Frame.ime.visible, $Frame.ime.mode, (Get-TL1C1BV1RectSignature $Frame.ime.bounds),
        $Frame.ime.binding, $Frame.ime.editor_node_label
    ) -join '|'
}

function Test-TL1C1BV1Frame {
    param(
        [Parameter(Mandatory)]$Frame,
        [Parameter(Mandatory)][int]$FrameIndex,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $path = "/frames/$FrameIndex"
    $windowInventory = $true
    $wechatOwnership = $true
    $rootProjection = $true
    $semanticTreeUsable = $true
    $imeHidden = $true
    $windowTypeInventoryComplete = $true

    if ([string]$Frame.capture.token -cne "c$($FrameIndex + 1)") {
        Add-TL1C1BV1Issue $Issues 'capture_order_invalid' "$path/capture/token"
    }
    if ([long]$Frame.capture.revision_before -ne [long]$Frame.capture.revision_after -or
        [long]$Frame.capture.revision_before -ne [long]$Frame.capture.layout_revision -or
        [long]$Frame.capture.revision_before -ne [long]$Frame.capture.ime_revision) {
        Add-TL1C1BV1Issue $Issues 'atomic_capture_revision_invalid' "$path/capture"
    }
    $displayKnown = $Frame.display.display_id_status -ceq 'known' -and
        $null -ne $Frame.display.display_id -and $null -ne $Frame.display.effective_size -and
        $Frame.display.orientation -cne 'unknown'
    if (-not $displayKnown) {
        Add-TL1C1BV1Issue $Issues 'display_unknown' "$path/display"
        $windowInventory = $false
    }
    elseif ($Frame.display.orientation -cne 'landscape' -or
        [long]$Frame.display.effective_size.width -le [long]$Frame.display.effective_size.height) {
        Add-TL1C1BV1Issue $Issues 'not_landscape' "$path/display"
        $windowInventory = $false
    }

    $windows = @($Frame.a11y_windows)
    if ($Frame.windows_truncated) {
        Add-TL1C1BV1Issue $Issues 'window_inventory_truncated' "$path/windows_truncated"
        $windowInventory = $false
    }
    $windowMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($window in $windows) {
        $label = [string]$window.window_label
        if ($label -cnotmatch '^aw[1-9][0-9]{0,2}$') {
            Add-TL1C1BV1Issue $Issues 'window_label_invalid' "$path/a11y_windows"
            $windowInventory = $false
        }
        if ($windowMap.ContainsKey($label)) {
            Add-TL1C1BV1Issue $Issues 'window_label_duplicate' "$path/a11y_windows"
            $windowInventory = $false
        } else { $windowMap.Add($label, $window) }
        if (-not (Test-TL1C1BV1RectPositive $window.bounds) -or
            ($null -ne $window.touchable_bounds -and -not (Test-TL1C1BV1RectPositive $window.touchable_bounds))) {
            Add-TL1C1BV1Issue $Issues 'window_geometry_invalid' "$path/a11y_windows/$label"
            $windowInventory = $false
        }
        if ($displayKnown -and [long]$window.display_id -ne [long]$Frame.display.display_id) {
            Add-TL1C1BV1Issue $Issues 'multi_display_blocked' "$path/a11y_windows/$label/display_id"
            $windowInventory = $false
        }
        $expectedType = Get-TL1C1BV1WindowTypeForCode ([int]$window.platform_type_code)
        if ($expectedType -ceq 'unknown' -or [string]$window.type -cne $expectedType) {
            Add-TL1C1BV1Issue $Issues 'window_type_invalid' "$path/a11y_windows/$label/type"
            $windowInventory = $false
            $windowTypeInventoryComplete = $false
        }
    }
    $applicationWindows = @($windows | Where-Object { $_.type -ceq 'application' })
    if ($applicationWindows.Count -ne 2) {
        Add-TL1C1BV1Issue $Issues 'window_count_not_two' "$path/a11y_windows"
        $windowInventory = $false
        $wechatOwnership = $false
    }
    foreach ($window in $applicationWindows) {
        if ($window.root_package -cne 'com.tencent.mm') { $wechatOwnership = $false }
        if ($window.root_handle_status -cne 'readable' -or $window.root_package -cne 'com.tencent.mm') {
            Add-TL1C1BV1Issue $Issues 'window_root_owner_conflict' "$path/a11y_windows/$($window.window_label)"
            $rootProjection = $false
        }
        if ($window.root_window_binding -cne 'exact') {
            Add-TL1C1BV1Issue $Issues 'root_window_binding_invalid' "$path/a11y_windows/$($window.window_label)"
            $rootProjection = $false
        }
        if ($window.expected_window_title_match -ceq 'not_attempted' -or
            $window.expected_window_title_match -in @('over_budget','read_error')) {
            Add-TL1C1BV1Issue $Issues 'window_title_probe_invalid' "$path/a11y_windows/$($window.window_label)"
        }
    }
    foreach ($window in @($windows | Where-Object { $_.type -cne 'application' })) {
        if ($window.expected_window_title_match -cne 'not_attempted') {
            Add-TL1C1BV1Issue $Issues 'window_title_probe_invalid' "$path/a11y_windows/$($window.window_label)"
        }
    }

    $panes = @($Frame.panes)
    if ($Frame.panes_truncated) {
        Add-TL1C1BV1Issue $Issues 'pane_projection_invalid' "$path/panes_truncated"
        $rootProjection = $false
    }
    $paneMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $paneCountByWindow = @{}
    foreach ($pane in $panes) {
        $paneLabel = [string]$pane.pane_label
        if ($paneMap.ContainsKey($paneLabel)) {
            Add-TL1C1BV1Issue $Issues 'pane_projection_invalid' "$path/panes"
            $rootProjection = $false
        } else { $paneMap.Add($paneLabel, $pane) }
        $windowLabel = [string]$pane.window_label
        if (-not $windowMap.ContainsKey($windowLabel) -or $windowMap[$windowLabel].type -cne 'application' -or
            $pane.projection_binding -cne 'root_subtree' -or
            -not (Test-TL1C1BV1RectEqual $pane.bounds $windowMap[$windowLabel].bounds) -or
            $pane.semantic_role -cne 'unknown' -or @($pane.semantic_evidence).Count -ne 0) {
            Add-TL1C1BV1Issue $Issues 'pane_projection_invalid' "$path/panes/$paneLabel"
            $rootProjection = $false
        }
        if (-not $paneCountByWindow.ContainsKey($windowLabel)) { $paneCountByWindow[$windowLabel] = 0 }
        $paneCountByWindow[$windowLabel]++
    }
    if ($panes.Count -ne 2) {
        Add-TL1C1BV1Issue $Issues 'window_root_projection_invalid' "$path/panes"
        $rootProjection = $false
    }
    foreach ($window in $applicationWindows) {
        if (-not $paneCountByWindow.ContainsKey([string]$window.window_label) -or
            [int]$paneCountByWindow[[string]$window.window_label] -ne 1) {
            Add-TL1C1BV1Issue $Issues 'window_root_projection_invalid' "$path/panes"
            $rootProjection = $false
        }
    }

    $nodes = @($Frame.node_observations)
    $nodeMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($node in $nodes) {
        $label = [string]$node.node_label
        if ($nodeMap.ContainsKey($label)) {
            Add-TL1C1BV1Issue $Issues 'node_binding_invalid' "$path/node_observations"
        } else { $nodeMap.Add($label, $node) }
        $windowLabel = [string]$node.window_label
        $paneLabel = [string]$node.pane_label
        $ownerWindow = if ($windowMap.ContainsKey($windowLabel)) { $windowMap[$windowLabel] } else { $null }
        $ownerPane = if ($paneMap.ContainsKey($paneLabel)) { $paneMap[$paneLabel] } else { $null }
        $bindingValid = $null -ne $ownerWindow -and $null -ne $ownerPane -and
            $ownerPane.window_label -ceq $windowLabel -and $node.window_id_binding -ceq 'exact' -and
            $node.semantic_role -ceq 'unknown'
        $geometryValid = switch ([string]$node.geometry_status) {
            'positive' { $null -ne $ownerWindow -and (Test-TL1C1BV1RectContained $node.bounds $ownerWindow.bounds) }
            'degenerate' { Test-TL1C1BV1RectDegenerate $node.bounds }
            'unavailable' { $null -eq $node.bounds }
            default { $false }
        }
        if (-not $bindingValid -or -not $geometryValid) {
            Add-TL1C1BV1Issue $Issues 'node_binding_invalid' "$path/node_observations/$label"
        }
    }
    if ($Frame.nodes_truncated) {
        Add-TL1C1BV1Issue $Issues 'subtree_capture_incomplete' "$path/nodes_truncated"
        $semanticTreeUsable = $false
    }

    foreach ($window in $windows) {
        $label = [string]$window.window_label
        $windowNodes = @($nodes | Where-Object { $_.window_label -ceq $label })
        $positiveVisible = @($windowNodes | Where-Object {
                $_.geometry_status -ceq 'positive' -and $_.visible
            }).Count
        $focusedEditable = @($windowNodes | Where-Object { $_.focused -and $_.editable }).Count
        $rootCount = @($windowNodes | Where-Object { $_.is_root }).Count
        $subtree = $window.subtree_capture
        if ([long]$subtree.visited_node_count -ne $windowNodes.Count -or
            [long]$subtree.positive_visible_geometry_node_count -ne $positiveVisible -or
            [long]$subtree.focused_editable_node_count -ne $focusedEditable -or
            (($windowNodes.Count -gt 0) -and $rootCount -ne 1)) {
            Add-TL1C1BV1Issue $Issues 'subtree_counts_invalid' "$path/a11y_windows/$label/subtree_capture"
            $semanticTreeUsable = $false
        }
        if ($window.type -ceq 'application') {
            $completeValid = $subtree.status -ceq 'complete' -and $null -ne $subtree.root_child_count -and
                [long]$subtree.visited_node_count -ge 1 -and [long]$subtree.read_error_count -eq 0 -and
                -not $subtree.budget_exhausted -and
                ([long]$subtree.root_child_count -ne 0 -or [long]$subtree.visited_node_count -eq 1)
            if (-not $completeValid) {
                Add-TL1C1BV1Issue $Issues 'subtree_capture_incomplete' "$path/a11y_windows/$label/subtree_capture"
                $semanticTreeUsable = $false
            }
            if ([long]$subtree.positive_visible_geometry_node_count -eq 0) { $semanticTreeUsable = $false }
        }
        elseif ($subtree.status -cne 'not_attempted' -or $null -ne $subtree.root_child_count -or
            [long]$subtree.visited_node_count -ne 0 -or [long]$subtree.positive_visible_geometry_node_count -ne 0 -or
            [long]$subtree.focused_editable_node_count -ne 0 -or [long]$subtree.read_error_count -ne 0 -or
            $subtree.budget_exhausted) {
            Add-TL1C1BV1Issue $Issues 'subtree_counts_invalid' "$path/a11y_windows/$label/subtree_capture"
        }
    }
    if (-not $semanticTreeUsable) {
        Add-TL1C1BV1Issue $Issues 'semantic_subtree_opaque' "$path/node_observations"
    }

    $focusedApplicationWindows = @($applicationWindows | Where-Object { $_.focused })
    $eligibleFocusedEditors = @($nodes | Where-Object {
            $_.focused -and $_.editable -and $_.visible -and $_.enabled -and
            $_.geometry_status -ceq 'positive' -and $_.window_id_binding -ceq 'exact'
        })
    $focusTopologyComplete = @($applicationWindows | Where-Object {
            $applicationWindow = $_
            $windowLabel = [string]$applicationWindow.window_label
            $windowNodes = @($nodes | Where-Object { $_.window_label -ceq $windowLabel })
            $rootNodes = @($windowNodes | Where-Object { $_.is_root })
            $projectionPanes = @($panes | Where-Object { $_.window_label -ceq $windowLabel })
            $projectionValid = $projectionPanes.Count -eq 1 -and
                $projectionPanes[0].projection_binding -ceq 'root_subtree' -and
                (Test-TL1C1BV1RectEqual $projectionPanes[0].bounds $applicationWindow.bounds) -and
                $projectionPanes[0].semantic_role -ceq 'unknown' -and
                @($projectionPanes[0].semantic_evidence).Count -eq 0
            $rootGeometryValid = if ($rootNodes.Count -eq 1) {
                switch ([string]$rootNodes[0].geometry_status) {
                    'positive' { Test-TL1C1BV1RectContained $rootNodes[0].bounds $applicationWindow.bounds }
                    'degenerate' { Test-TL1C1BV1RectDegenerate $rootNodes[0].bounds }
                    'unavailable' { $null -eq $rootNodes[0].bounds }
                    default { $false }
                }
            } else { $false }
            -not (Test-TL1C1BV1RectPositive $applicationWindow.bounds) -or
                $applicationWindow.root_handle_status -cne 'readable' -or
                $applicationWindow.root_package -cne 'com.tencent.mm' -or
                $applicationWindow.root_window_binding -cne 'exact' -or
                $applicationWindow.subtree_capture.status -cne 'complete' -or
                $null -eq $applicationWindow.subtree_capture.root_child_count -or
                [long]$applicationWindow.subtree_capture.visited_node_count -lt 1 -or
                $windowNodes.Count -ne [long]$applicationWindow.subtree_capture.visited_node_count -or
                [long]$applicationWindow.subtree_capture.read_error_count -ne 0 -or
                $applicationWindow.subtree_capture.budget_exhausted -or -not $projectionValid -or
                $rootNodes.Count -ne 1 -or $rootNodes[0].window_id_binding -cne 'exact' -or
                $rootNodes[0].pane_label -cne $projectionPanes[0].pane_label -or -not $rootGeometryValid
        }).Count -eq 0
    $expectedFocus = if ($Frame.windows_truncated -or $Frame.nodes_truncated -or
        -not $windowTypeInventoryComplete -or -not $focusTopologyComplete) { 'unknown' }
        elseif ($focusedApplicationWindows.Count -gt 1 -or $eligibleFocusedEditors.Count -gt 1) { 'conflict' }
        elseif ($focusedApplicationWindows.Count -eq 1 -and $eligibleFocusedEditors.Count -eq 1 -and
            $focusedApplicationWindows[0].window_label -ceq $eligibleFocusedEditors[0].window_label) { 'editor_known' }
        elseif ($focusedApplicationWindows.Count -eq 1 -and $eligibleFocusedEditors.Count -eq 0) { 'window_only' }
        elseif ($focusedApplicationWindows.Count -eq 0 -and $eligibleFocusedEditors.Count -eq 0) { 'absent' }
        else { 'conflict' }
    $focusValid = [string]$Frame.focus.status -ceq $expectedFocus
    if ($expectedFocus -ceq 'window_only') {
        $focusValid = $focusValid -and $Frame.focus.window_label -ceq $focusedApplicationWindows[0].window_label -and
            $null -eq $Frame.focus.node_label
    }
    elseif ($expectedFocus -ceq 'editor_known') {
        $focusValid = $focusValid -and $Frame.focus.window_label -ceq $focusedApplicationWindows[0].window_label -and
            $Frame.focus.node_label -ceq $eligibleFocusedEditors[0].node_label
    }
    elseif ($expectedFocus -in @('absent','conflict','unknown')) {
        $focusValid = $focusValid -and $null -eq $Frame.focus.window_label -and $null -eq $Frame.focus.node_label
    }
    if (-not $focusValid) { Add-TL1C1BV1Issue $Issues 'focus_inventory_invalid' "$path/focus" }

    $imeWindows = @($windows | Where-Object { $_.type -ceq 'input_method' })
    if ([string]$Frame.ime.capture_token -cne [string]$Frame.capture.token) {
        Add-TL1C1BV1Issue $Issues 'ime_inventory_invalid' "$path/ime/capture_token"
        $imeHidden = $false
    }
    if ($Frame.windows_truncated -or -not $windowTypeInventoryComplete) {
        Add-TL1C1BV1Issue $Issues 'ime_inventory_invalid' "$path/ime"
        $imeHidden = $false
    }
    if (-not $Frame.ime.visible) {
        if ($imeWindows.Count -ne 0 -or $Frame.ime.mode -cne 'none' -or $null -ne $Frame.ime.bounds -or
            $Frame.ime.binding -cne 'not_active' -or $null -ne $Frame.ime.editor_node_label) {
            Add-TL1C1BV1Issue $Issues 'ime_inventory_invalid' "$path/ime"
            $imeHidden = $false
        }
    } else {
        $imeHidden = $false
        Add-TL1C1BV1Issue $Issues 'ime_hidden_unverified' "$path/ime"
        if ($imeWindows.Count -ne 1 -or $null -eq $Frame.ime.bounds -or
            -not (Test-TL1C1BV1RectEqual $Frame.ime.bounds $imeWindows[0].bounds)) {
            Add-TL1C1BV1Issue $Issues 'ime_inventory_invalid' "$path/ime"
        }
    }

    return [pscustomobject]@{
        window_inventory_observed = $windowInventory
        wechat_window_ownership_observed = $windowInventory -and $wechatOwnership
        root_projection_observed = $windowInventory -and $rootProjection
        semantic_tree_usable = $semanticTreeUsable
        ime_hidden_observed = $imeHidden
        signature = Get-TL1C1BV1FrameSignature $Frame
        window_labels = [string[]]@($windows | ForEach-Object { $_.window_label } | Sort-Object -CaseSensitive)
    }
}

function Test-TL1C1BV1Semantics {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][ValidateSet('fixture','trusted_runtime')][string]$OriginMode,
        [Parameter(Mandatory)][DateTimeOffset]$ValidationNowUtc,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    foreach ($reason in $script:TL1C1BV1BaseDiagnosticReasons) {
        Add-TL1C1BV1Issue $Issues $reason '/'
    }
    if ($Evidence.schema -cne $script:TL1C1BV1Schema -or $Evidence.mode -cne 'c1b_pure_a11y_diagnostic') {
        Add-TL1C1BV1Issue $Issues 'safety_constants_invalid' '/schema'
    }
    if ($OriginMode -ceq 'fixture') {
        if ($Evidence.provenance.kind -cne 'offline_fixture' -or $Evidence.upstream_t0.source_kind -cne 'offline_fixture') {
            Add-TL1C1BV1Issue $Issues 'fixture_origin_required' '/provenance'
        }
    }
    elseif ($Evidence.provenance.kind -cne 'gateway_runtime_probe' -or
        $Evidence.upstream_t0.source_kind -cne 'trusted_runtime') {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/provenance'
    }
    if ($Evidence.provenance.runtime_attested -or $Evidence.route.kind -cne 'probe_only' -or
        $Evidence.route.settings_mutation_allowed -or $Evidence.route.device_action_allowed -or
        $Evidence.route.screenshot_allowed -or $Evidence.route.ocr_allowed) {
        Add-TL1C1BV1Issue $Issues 'route_contract_violation' '/route'
    }
    if ($Evidence.layout_accepted -or $Evidence.wechat_layout_verified -or $Evidence.editor_action_ready -or
        $Evidence.p0_capability -cne 'unsupported' -or $Evidence.execution_grant) {
        Add-TL1C1BV1Issue $Issues 'safety_constants_invalid' '/'
    }
    $blockers = [string[]]@($Evidence.p0_blockers)
    if ($blockers.Count -ne $script:TL1C1BV1RequiredBlockers.Count -or
        @($blockers | Select-Object -Unique).Count -ne $blockers.Count) {
        Add-TL1C1BV1Issue $Issues 'safety_constants_invalid' '/p0_blockers'
    }
    foreach ($blocker in $script:TL1C1BV1RequiredBlockers) {
        if ($blockers -cnotcontains $blocker) { Add-TL1C1BV1Issue $Issues 'safety_constants_invalid' '/p0_blockers' }
    }
    if ($Evidence.upstream_t0.producer_commit_sha -cne $script:TL1C1BV1TrustedT0ProducerSha -or
        $Evidence.upstream_t0.schema_version -ne 5 -or $Evidence.upstream_t0.intake_status -cne 'accepted' -or
        $Evidence.upstream_t0.readiness_status -cne 'blocked' -or $Evidence.upstream_t0.p0_capability -cne 'unsupported') {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/upstream_t0'
    }
    $t0ReadinessReasons = [string[]]@($Evidence.upstream_t0.readiness_reasons)
    $t0P0Reasons = [string[]]@($Evidence.upstream_t0.p0_unsupported_reasons)
    if ($t0ReadinessReasons.Count -lt 1 -or
        $t0P0Reasons -cnotcontains 'wechat_layout_unverified' -or
        $t0P0Reasons -cnotcontains 'tablet_landscape_p0_unimplemented') {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/upstream_t0'
    }

    $frames = @($Evidence.frames)
    $facts = [Collections.Generic.List[object]]::new()
    $previousAt = [DateTimeOffset]::MinValue
    $firstAt = [DateTimeOffset]::MinValue
    $minimumTicks = [long]::MaxValue
    $previousRevision = 0L
    for ($index = 0; $index -lt $frames.Count; $index++) {
        $frame = $frames[$index]
        $at = ConvertFrom-TL1C1BV1Timestamp $frame.captured_at
        if ($null -eq $at) {
            Add-TL1C1BV1Issue $Issues 'capture_order_invalid' "/frames/$index/captured_at"
            continue
        }
        if ($index -eq 0) { $firstAt = $at }
        if ($at -gt $ValidationNowUtc) { Add-TL1C1BV1Issue $Issues 'capture_in_future' "/frames/$index/captured_at" }
        if ($index -gt 0) {
            $ticks = ($at - $previousAt).Ticks
            if ($at -le $previousAt -or $ticks -lt $script:TL1C1BV1MinimumIntervalTicks -or
                $ticks -gt $script:TL1C1BV1MaximumIntervalTicks -or
                [long]$frame.capture.revision_before -le $previousRevision) {
                Add-TL1C1BV1Issue $Issues 'capture_order_invalid' "/frames/$index"
            }
            if ($ticks -gt 0 -and $ticks -lt $minimumTicks) { $minimumTicks = $ticks }
        }
        $facts.Add((Test-TL1C1BV1Frame $frame $index $Issues))
        $previousAt = $at
        $previousRevision = [long]$frame.capture.revision_before
    }
    if ($firstAt -ne [DateTimeOffset]::MinValue -and $previousAt -ne [DateTimeOffset]::MinValue -and
        ($previousAt - $firstAt).Ticks -gt $script:TL1C1BV1MaximumSpanTicks) {
        Add-TL1C1BV1Issue $Issues 'capture_span_exceeded' '/frames'
    }
    if ($previousAt -ne [DateTimeOffset]::MinValue -and
        ($ValidationNowUtc - $previousAt).Ticks -gt $script:TL1C1BV1MaximumAgeTicks) {
        Add-TL1C1BV1Issue $Issues 'capture_stale' '/captured_at'
    }
    $topCapturedAt = ConvertFrom-TL1C1BV1Timestamp $Evidence.captured_at
    if ($null -eq $topCapturedAt -or $topCapturedAt -ne $previousAt) {
        Add-TL1C1BV1Issue $Issues 'capture_order_invalid' '/captured_at'
    }
    $t0At = ConvertFrom-TL1C1BV1Timestamp $Evidence.upstream_t0.captured_at
    if ($null -eq $t0At -or $firstAt -eq [DateTimeOffset]::MinValue -or $t0At -gt $firstAt -or
        ($firstAt - $t0At).Ticks -gt $script:TL1C1BV1MaximumT0AgeTicks) {
        Add-TL1C1BV1Issue $Issues 'runtime_producer_unavailable' '/upstream_t0/captured_at'
    }

    if ($facts.Count -eq 2) {
        if (($facts[0].window_labels -join "`n") -cne ($facts[1].window_labels -join "`n")) {
            Add-TL1C1BV1Issue $Issues 'window_identity_replacement' '/frames/1/a11y_windows'
        }
        if ($facts[0].signature -cne $facts[1].signature) {
            Add-TL1C1BV1Issue $Issues 'capture_semantics_drift' '/frames/1'
        }
    }

    $consistencyCodes = [string[]]@(Get-TL1C1BV1ReasonCodes $Issues | Where-Object {
            $_ -cin @(
                'atomic_capture_revision_invalid','capture_order_invalid','capture_span_exceeded',
                'window_identity_replacement','capture_semantics_drift'
            )
        } | Sort-Object -Unique)
    $minimumMs = if ($minimumTicks -eq [long]::MaxValue) { -1L } else {
        [long][Math]::Floor($minimumTicks / [double][TimeSpan]::TicksPerMillisecond)
    }
    if ([long]$Evidence.consistency.sample_count -ne $frames.Count -or
        [long]$Evidence.consistency.minimum_interval_ms -ne $minimumMs -or
        [bool]$Evidence.consistency.stable -ne ($consistencyCodes.Count -eq 0) -or
        (([string[]]@($Evidence.consistency.reason_codes | Sort-Object -Unique)) -join "`n") -cne
            ($consistencyCodes -join "`n")) {
        Add-TL1C1BV1Issue $Issues 'consistency_declared_mismatch' '/consistency'
    }

    $intrinsicCodes = [string[]]@(Get-TL1C1BV1ReasonCodes $Issues | Where-Object {
            $script:TL1C1BV1ConsumerTimeReasons -cnotcontains $_ -and
            $_ -cnotin @('declared_status_mismatch','declared_reasons_incomplete')
        } | Sort-Object -Unique)
    $declaredCodes = [string[]]@($Evidence.reason_codes | Sort-Object -Unique)
    if ($Evidence.diagnostic_status -cne 'blocked') {
        Add-TL1C1BV1Issue $Issues 'declared_status_mismatch' '/diagnostic_status'
    }
    if (@($intrinsicCodes | Where-Object { $declaredCodes -cnotcontains $_ }).Count -gt 0) {
        Add-TL1C1BV1Issue $Issues 'declared_reasons_incomplete' '/reason_codes'
    }
    if (@($declaredCodes | Where-Object { $intrinsicCodes -cnotcontains $_ }).Count -gt 0) {
        Add-TL1C1BV1Issue $Issues 'declared_status_mismatch' '/reason_codes'
    }

    $allWindowInventory = $facts.Count -eq 2 -and @($facts | Where-Object { -not $_.window_inventory_observed }).Count -eq 0
    $allWechatOwnership = $facts.Count -eq 2 -and @($facts | Where-Object {
            -not $_.wechat_window_ownership_observed
        }).Count -eq 0
    $allRootProjection = $allWindowInventory -and @($facts | Where-Object { -not $_.root_projection_observed }).Count -eq 0
    $stable = $consistencyCodes.Count -eq 0
    $consumerTimeValid = @((Get-TL1C1BV1ReasonCodes $Issues) | Where-Object {
            $script:TL1C1BV1ConsumerTimeReasons -ccontains $_
        }).Count -eq 0
    return [pscustomobject]@{
        consumer_time_valid = $consumerTimeValid
        window_inventory_observed = $allWindowInventory
        wechat_window_ownership_observed = $allWechatOwnership
        window_root_projection_observed = $allRootProjection
        application_window_topology_observed = $allRootProjection -and $stable -and $consumerTimeValid
        ime_hidden_observed = $facts.Count -eq 2 -and @($facts | Where-Object { -not $_.ime_hidden_observed }).Count -eq 0
        semantic_tree_usable = $facts.Count -eq 2 -and @($facts | Where-Object { -not $_.semantic_tree_usable }).Count -eq 0
    }
}

function New-TL1C1BV1ValidationResult {
    param(
        [bool]$ContractValid,
        [bool]$RuntimeBindingInputsMatch,
        $Facts,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    if ($null -eq $Facts) {
        $Facts = [pscustomobject]@{
            consumer_time_valid = $false
            window_inventory_observed = $false
            wechat_window_ownership_observed = $false
            window_root_projection_observed = $false
            application_window_topology_observed = $false
            ime_hidden_observed = $false
            semantic_tree_usable = $false
        }
    }
    $observationUsable = $ContractValid -and [bool]$Facts.consumer_time_valid
    $topologyObserved = $observationUsable -and [bool]$Facts.application_window_topology_observed
    return [pscustomobject][ordered]@{
        schema = $script:TL1C1BV1ValidationSchema
        contract_schema = $script:TL1C1BV1Schema
        fixture_contract_valid = $ContractValid
        diagnostic_status = 'blocked'
        reason_codes = @(Get-TL1C1BV1ReasonCodes $Issues)
        issues = @($Issues.ToArray())
        runtime_binding_inputs_match = $RuntimeBindingInputsMatch
        runtime_origin_verified = $false
        runtime_evidence = $false
        window_inventory_observed = $observationUsable -and [bool]$Facts.window_inventory_observed
        wechat_window_ownership_observed = $observationUsable -and [bool]$Facts.wechat_window_ownership_observed
        wechat_window_ownership_verified = $false
        window_root_projection_observed = $observationUsable -and [bool]$Facts.window_root_projection_observed
        window_root_projection_verified = $false
        application_window_topology_observed = $topologyObserved
        application_window_topology_verified = $false
        ime_hidden_observed = $observationUsable -and [bool]$Facts.ime_hidden_observed
        ime_hidden_verified = $false
        semantic_tree_usable = $observationUsable -and [bool]$Facts.semantic_tree_usable
        navigation_pane_verified = $false
        conversation_pane_verified = $false
        target_conversation_verified = $false
        target_regions_verified = $false
        layout_accepted = $false
        wechat_layout_verified = $false
        editor_action_ready = $false
        settings_mutation_allowed = $false
        device_action_allowed = $false
        screenshot_allowed = $false
        ocr_allowed = $false
        p0_capability = 'unsupported'
        execution_grant = $false
    }
}

function Test-TL1C1BV1Core {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][ValidateSet('fixture','trusted_runtime')][string]$OriginMode,
        [Parameter(Mandatory)][DateTimeOffset]$ValidationNowUtc,
        [string]$ExpectedRunId,
        [string]$ExpectedProducerCommitSha,
        [string]$ExpectedProducerArtifactSha256
    )
    $issues = [Collections.Generic.List[object]]::new()
    $facts = $null
    try {
        $controlledPath = Resolve-TL1C1BV1ControlledPath $Path $EvidenceRoot $issues
        if ($null -eq $controlledPath) { return New-TL1C1BV1ValidationResult $false $false $facts $issues }
        $raw = Read-TL1C1BV1ControlledUtf8 $controlledPath $issues
        if ($null -eq $raw) { return New-TL1C1BV1ValidationResult $false $false $facts $issues }
        $evidence = ConvertFrom-TL1C1BV1StrictJson $raw $issues
        if ($null -eq $evidence) { return New-TL1C1BV1ValidationResult $false $false $facts $issues }
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $schemaPath = Join-Path $repoRoot 'docs\contracts\tablet-layout-observation-c1b-v1.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or
            -not ($raw | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            Add-TL1C1BV1Issue $issues 'json_schema_validation_failed' '/'
            return New-TL1C1BV1ValidationResult $false $false $facts $issues
        }
        $snapshotRaw = $evidence | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
        $snapshot = $snapshotRaw | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
        $facts = Test-TL1C1BV1Semantics $snapshot $OriginMode $ValidationNowUtc $issues

        if ($OriginMode -ceq 'trusted_runtime') {
            if ($ExpectedRunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -or
                $ExpectedProducerCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
                $ExpectedProducerArtifactSha256 -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                $snapshot.run_id -cne $ExpectedRunId -or
                $snapshot.expected_title_hash -cne $script:TL1C1BV1TrustedRuntimeTitleHash -or
                $snapshot.provenance.producer_commit_sha -cne $ExpectedProducerCommitSha -or
                $snapshot.provenance.producer_artifact_sha256 -cne $ExpectedProducerArtifactSha256) {
                Add-TL1C1BV1Issue $issues 'runtime_producer_unavailable' '/provenance'
            }
        }

        $codes = [string[]]@(Get-TL1C1BV1ReasonCodes $issues)
        $contractValid = @($codes | Where-Object { $script:TL1C1BV1ContractFailureCodes -ccontains $_ }).Count -eq 0
        $runtimeBindingInputsMatch = $OriginMode -ceq 'trusted_runtime' -and $contractValid -and
            @($codes | Where-Object { $_ -ceq 'runtime_producer_unavailable' }).Count -eq 0
        return New-TL1C1BV1ValidationResult $contractValid $runtimeBindingInputsMatch $facts $issues
    }
    catch {
        Add-TL1C1BV1Issue $issues 'validation_exception' '/'
        return New-TL1C1BV1ValidationResult $false $false $facts $issues
    }
}

function Test-TabletLayoutObservationC1BV1File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$FixtureMode,
        [DateTimeOffset]$ValidationNowUtc = [DateTimeOffset]::UtcNow
    )
    if (-not $FixtureMode) {
        $issues = [Collections.Generic.List[object]]::new()
        Add-TL1C1BV1Issue $issues 'runtime_producer_unavailable' '/provenance'
        return New-TL1C1BV1ValidationResult $false $false $null $issues
    }
    return Test-TL1C1BV1Core $Path $EvidenceRoot fixture $ValidationNowUtc
}

function Test-TabletLayoutObservationC1BV1TrustedRuntimeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedProducerCommitSha,
        [Parameter(Mandatory)][string]$ExpectedProducerArtifactSha256,
        [DateTimeOffset]$ValidationNowUtc = [DateTimeOffset]::UtcNow
    )
    return Test-TL1C1BV1Core $Path $EvidenceRoot trusted_runtime $ValidationNowUtc `
        $ExpectedRunId $ExpectedProducerCommitSha $ExpectedProducerArtifactSha256
}
