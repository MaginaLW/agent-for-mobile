# T0 平板只读 intake 的纯解析与受控 ADB 查询层。
# 本文件不导出任何“执行任意 adb 参数”的入口；所有设备调用都必须先映射到固定查询名。

Set-StrictMode -Version 3.0

function Get-TabletSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try {
        $hash = [Security.Cryptography.SHA256]::HashData($bytes)
        return 'sha256:' + [Convert]::ToHexString($hash).ToLowerInvariant()
    }
    finally {
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-TabletSafeText {
    param([AllowNull()][string]$Text, [int]$MaxLength = 200)
    if ($null -eq $Text) { return $null }
    $value = ($Text -replace '[\x00-\x1f\x7f]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    if ($value.Length -gt $MaxLength) { return $value.Substring(0, $MaxLength) }
    return $value
}

function Get-TabletSingleLineValue {
    param([AllowNull()][string]$Text, [int]$MaxLength = 200)
    if ($null -eq $Text) { return $null }
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -ne 1) { return $null }
    return Get-TabletSafeText $lines[0] $MaxLength
}

function Get-TabletAdbArguments {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'devices', 'prop_brand', 'prop_manufacturer', 'prop_model', 'prop_product', 'prop_device',
            'prop_android_release', 'prop_api', 'prop_abi', 'prop_fingerprint',
            'wm_size', 'wm_density', 'activity', 'window', 'display', 'power', 'policy',
            'zen', 'default_ime', 'input_method', 'am_config'
        )][string]$Name,
        [AllowNull()][string]$Serial
    )
    if ($Name -eq 'devices') { return [string[]]@('devices') }
    if ([string]::IsNullOrWhiteSpace($Serial)) { throw '内部错误：设备查询缺少 serial。' }

    $tail = switch ($Name) {
        'prop_brand' { @('shell', 'getprop', 'ro.product.brand') }
        'prop_manufacturer' { @('shell', 'getprop', 'ro.product.manufacturer') }
        'prop_model' { @('shell', 'getprop', 'ro.product.model') }
        'prop_product' { @('shell', 'getprop', 'ro.product.name') }
        'prop_device' { @('shell', 'getprop', 'ro.product.device') }
        'prop_android_release' { @('shell', 'getprop', 'ro.build.version.release') }
        'prop_api' { @('shell', 'getprop', 'ro.build.version.sdk') }
        'prop_abi' { @('shell', 'getprop', 'ro.product.cpu.abilist') }
        'prop_fingerprint' { @('shell', 'getprop', 'ro.build.fingerprint') }
        'wm_size' { @('shell', 'wm', 'size') }
        'wm_density' { @('shell', 'wm', 'density') }
        'activity' { @('shell', 'dumpsys', 'activity', 'activities') }
        'window' { @('shell', 'dumpsys', 'window', 'windows') }
        'display' { @('shell', 'dumpsys', 'display') }
        'power' { @('shell', 'dumpsys', 'power') }
        'policy' { @('shell', 'dumpsys', 'window', 'policy') }
        'zen' { @('shell', 'settings', 'get', 'global', 'zen_mode') }
        'default_ime' { @('shell', 'settings', 'get', 'secure', 'default_input_method') }
        'input_method' { @('shell', 'dumpsys', 'input_method') }
        'am_config' { @('shell', 'am', 'get-config') }
        default { throw "内部错误：未映射的只读查询 $Name。" }
    }
    return [string[]](@('-s', $Serial) + $tail)
}

function Invoke-TabletAdbQuery {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Serial,
        [int]$TimeoutSec = 20
    )
    $arguments = Get-TabletAdbArguments -Name $Name -Serial $Serial
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "ADB 只读查询无法启动：$Name。" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw "ADB 只读查询超时：$Name。"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "ADB 只读查询失败：$Name（exit=$($process.ExitCode)）。"
        }
        return [string]$stdout
    }
    finally {
        $process.Dispose()
    }
}

function Get-TabletSingleDevice {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DevicesText)
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($line in ($DevicesText -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), '^(\S+)\s+(device|unauthorized|offline|no permissions.*)$')
        if ($match.Success) {
            $rows.Add([pscustomobject]@{ Serial = $match.Groups[1].Value; State = $match.Groups[2].Value })
        }
    }
    if ($rows.Count -ne 1) { throw "要求恰好一台已连接设备，当前识别到 $($rows.Count) 台。" }
    if ($rows[0].State -cne 'device') { throw "唯一设备未授权或不可用（state=$($rows[0].State)）。" }
    return [string]$rows[0].Serial
}

function ConvertFrom-TabletWmSize {
    param([AllowNull()][string]$Text)
    $physical = $null
    $override = $null
    $physicalLines = @([regex]::Matches(($Text ?? ''), '(?im)^\s*Physical size:\s*(.*?)\s*$'))
    $overrideLines = @([regex]::Matches(($Text ?? ''), '(?im)^\s*Override size:\s*(.*?)\s*$'))
    $physicalStatus = if ($physicalLines.Count -eq 0) { 'absent' } else { 'ambiguous' }
    $overrideStatus = if ($overrideLines.Count -eq 0) { 'absent' } else { 'ambiguous' }
    if ($physicalLines.Count -eq 1) {
        $physicalMatch = [regex]::Match($physicalLines[0].Groups[1].Value, '^(\d+)x(\d+)$')
        $width = 0
        $height = 0
        if ($physicalMatch.Success -and
            [int]::TryParse($physicalMatch.Groups[1].Value, [ref]$width) -and
            [int]::TryParse($physicalMatch.Groups[2].Value, [ref]$height) -and
            $width -gt 0 -and $height -gt 0) {
        $physical = [ordered]@{
                width = $width
                height = $height
            }
            $physicalStatus = 'known'
        }
    }
    if ($overrideLines.Count -eq 1) {
        $overrideMatch = [regex]::Match($overrideLines[0].Groups[1].Value, '^(\d+)x(\d+)$')
        $width = 0
        $height = 0
        if ($overrideMatch.Success -and
            [int]::TryParse($overrideMatch.Groups[1].Value, [ref]$width) -and
            [int]::TryParse($overrideMatch.Groups[2].Value, [ref]$height) -and
            $width -gt 0 -and $height -gt 0) {
            $override = [ordered]@{ width = $width; height = $height }
            $overrideStatus = 'known'
        }
    }
    return [pscustomobject]@{
        Physical = $physical
        Override = $override
        PhysicalStatus = $physicalStatus
        OverrideStatus = $overrideStatus
    }
}

function ConvertFrom-TabletWmDensity {
    param([AllowNull()][string]$Text)
    $physical = $null
    $override = $null
    $physicalLines = @([regex]::Matches(($Text ?? ''), '(?im)^\s*Physical density:\s*(.*?)\s*$'))
    $overrideLines = @([regex]::Matches(($Text ?? ''), '(?im)^\s*Override density:\s*(.*?)\s*$'))
    $physicalStatus = if ($physicalLines.Count -eq 0) { 'absent' } else { 'ambiguous' }
    $overrideStatus = if ($overrideLines.Count -eq 0) { 'absent' } else { 'ambiguous' }
    if ($physicalLines.Count -eq 1) {
        $value = 0
        if ([int]::TryParse($physicalLines[0].Groups[1].Value, [ref]$value) -and $value -gt 0) {
            $physical = $value
            $physicalStatus = 'known'
        }
    }
    if ($overrideLines.Count -eq 1) {
        $value = 0
        if ([int]::TryParse($overrideLines[0].Groups[1].Value, [ref]$value) -and $value -gt 0) {
            $override = $value
            $overrideStatus = 'known'
        }
    }
    return [pscustomobject]@{
        Physical = $physical
        Override = $override
        PhysicalStatus = $physicalStatus
        OverrideStatus = $overrideStatus
    }
}

function Get-TabletEffectiveWmSizeObservation {
    param([Parameter(Mandatory)]$Size)
    if ($Size.PhysicalStatus -cne 'known' -or $null -eq $Size.Physical) {
        return [pscustomobject]@{ Status='ambiguous'; Source='unknown'; Value=$null }
    }
    if ($Size.OverrideStatus -ceq 'known' -and $null -ne $Size.Override) {
        return [pscustomobject]@{ Status='known'; Source='override'; Value=$Size.Override }
    }
    if ($Size.OverrideStatus -ceq 'absent' -and $Size.PhysicalStatus -ceq 'known' -and
        $null -ne $Size.Physical) {
        return [pscustomobject]@{ Status='known'; Source='physical'; Value=$Size.Physical }
    }
    return [pscustomobject]@{ Status='ambiguous'; Source='unknown'; Value=$null }
}

function Get-TabletEffectiveWmDensityObservation {
    param([Parameter(Mandatory)]$Density)
    if ($Density.PhysicalStatus -cne 'known' -or $null -eq $Density.Physical) {
        return [pscustomobject]@{ Status='ambiguous'; Source='unknown'; Value=$null }
    }
    if ($Density.OverrideStatus -ceq 'known' -and $null -ne $Density.Override) {
        return [pscustomobject]@{ Status='known'; Source='override'; Value=$Density.Override }
    }
    if ($Density.OverrideStatus -ceq 'absent' -and $Density.PhysicalStatus -ceq 'known' -and
        $null -ne $Density.Physical) {
        return [pscustomobject]@{ Status='known'; Source='physical'; Value=$Density.Physical }
    }
    return [pscustomobject]@{ Status='ambiguous'; Source='unknown'; Value=$null }
}

function Get-TabletRotationObservation {
    param([AllowNull()][string]$DisplayText, [AllowNull()][string]$WindowText)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($input in @(
        [pscustomobject]@{ Name='display'; Text=$DisplayText },
        [pscustomobject]@{ Name='window'; Text=$WindowText }
    )) {
        $contextDisplayId = $null
        foreach ($line in (($input.Text ?? '') -split "`r?`n")) {
            if ($input.Name -ceq 'display') {
                $displayHeader = [regex]::Match($line, '(?i)^\s*Display[ \t]+(\d+)[ \t]*:')
                if ($displayHeader.Success) {
                    [int]$parsedContextDisplay = 0
                    if ([int]::TryParse($displayHeader.Groups[1].Value, [ref]$parsedContextDisplay)) {
                        $contextDisplayId = $parsedContextDisplay
                    }
                    else { $contextDisplayId = $null }
                }
            }
            $assignments = @([regex]::Matches($line,
                '(?i)\b(?:rotation|mRotation)(?:[ \t]*[=:][ \t]*|[ \t]+)([^\s,}\]]+)'))
            foreach ($assignment in $assignments) {
                $scope = if ($line -match '(?i)\b(?:Display|displayId|mDisplayId)[ \t]*(?:#|=|:)?[ \t]*0\b') {
                    'default_display'
                }
                elseif ($line -match '(?i)\b(?:Display|displayId|mDisplayId)[ \t]*(?:#|=|:)?[ \t]*[1-9]\d*\b') {
                    'non_default_display'
                }
                elseif ($input.Name -ceq 'display' -and $null -ne $contextDisplayId -and
                    [int]$contextDisplayId -eq 0) { 'default_display' }
                elseif ($input.Name -ceq 'display' -and $null -ne $contextDisplayId) { 'non_default_display' }
                else { 'unscoped' }
                $token = $assignment.Groups[1].Value
                $valueMatch = [regex]::Match($token, '^(?:ROTATION_)?([0-3])$',
                    [Text.RegularExpressions.RegexOptions]::IgnoreCase)
                $records.Add([pscustomobject]@{
                    Input = $input.Name
                    Scope = $scope
                    Valid = $valueMatch.Success
                    Value = if ($valueMatch.Success) { [int]$valueMatch.Groups[1].Value } else { $null }
                })
            }
        }
    }
    $defaultRecords = @($records | Where-Object { $_.Scope -ceq 'default_display' })
    $validDefault = @($defaultRecords | Where-Object { $_.Valid })
    $defaultValues = @($validDefault | ForEach-Object { [int]$_.Value } | Sort-Object -Unique)
    $malformedCount = @($records | Where-Object { -not $_.Valid }).Count
    $unscopedCount = @($records | Where-Object { $_.Scope -ceq 'unscoped' }).Count
    $nonDefaultCount = @($records | Where-Object { $_.Scope -ceq 'non_default_display' }).Count
    $conflictCount = if ($defaultValues.Count -gt 1) { $defaultValues.Count } else { 0 }
    $status = 'ambiguous'
    $source = 'none'
    $value = $null
    if ($records.Count -eq 0) {
        $status = 'absent'
    }
    elseif ($defaultRecords.Count -gt 0 -and $validDefault.Count -eq $defaultRecords.Count -and
        $defaultValues.Count -eq 1 -and
        $malformedCount -eq 0 -and $unscopedCount -eq 0 -and $nonDefaultCount -eq 0) {
        $status = 'known'
        $inputs = @($validDefault | ForEach-Object { $_.Input } | Sort-Object -CaseSensitive -Unique)
        $source = if ($inputs.Count -gt 1) { 'display_window_cross_checked' }
            elseif ($inputs[0] -ceq 'display') { 'display_default' } else { 'window_default' }
        $value = [int]$validDefault[0].Value
    }
    return [pscustomobject]@{
        Status = $status
        Value = $value
        Source = $source
        AssignmentCount = $records.Count
        ValidCount = @($records | Where-Object { $_.Valid }).Count
        MalformedCount = $malformedCount
        ConflictCount = $conflictCount
        DefaultScopedCount = $defaultRecords.Count
        UnscopedCount = $unscopedCount
        NonDefaultCount = $nonDefaultCount
    }
}

function ConvertFrom-TabletRotation {
    param([AllowNull()][string]$DisplayText, [AllowNull()][string]$WindowText)
    return (Get-TabletRotationObservation -DisplayText $DisplayText -WindowText $WindowText).Value
}

function Get-TabletCurrentSizeObservation {
    param(
        $PhysicalSize,
        $OverrideSize,
        [Parameter(Mandatory)][string]$RotationStatus,
        [AllowNull()]$Rotation,
        [AllowNull()]$WindowInventory,
        [AllowNull()][string]$TopPackage,
        [AllowNull()]$ForegroundObservation,
        [string]$PhysicalSizeStatus = $(if ($null -eq $PhysicalSize) { 'absent' } else { 'known' }),
        [string]$OverrideSizeStatus = $(if ($null -eq $OverrideSize) { 'absent' } else { 'known' })
    )
    $effectiveSize = Get-TabletEffectiveWmSizeObservation ([pscustomobject]@{
        Physical=$PhysicalSize
        Override=$OverrideSize
        PhysicalStatus=$PhysicalSizeStatus
        OverrideStatus=$OverrideSizeStatus
    })
    $base = $effectiveSize.Value
    if ($null -eq $base) {
        return [pscustomobject]@{
            Status='unknown'; Source='unknown'; WmSizeSource=$effectiveSize.Source; Value=$null
            ReasonCodes=@('wm_size_unreliable')
        }
    }
    if ($RotationStatus -ceq 'known' -and $null -ne $Rotation) {
        if ([int]$Rotation -in @(1, 3)) {
            return [pscustomobject]@{
                Status='known'
                Source='rotation'
                WmSizeSource=$effectiveSize.Source
                Value=[ordered]@{ width = [int]$base.height; height = [int]$base.width }
                ReasonCodes=@()
            }
        }
        return [pscustomobject]@{
            Status='known'
            Source='rotation'
            WmSizeSource=$effectiveSize.Source
            Value=[ordered]@{ width = [int]$base.width; height = [int]$base.height }
            ReasonCodes=@()
        }
    }

    # rotation 明确 absent 时才允许窗口回退；每一项均是机械 fail-closed 前提。
    $fallbackReasons = [Collections.Generic.List[string]]::new()
    if ($RotationStatus -cne 'absent') { $fallbackReasons.Add('rotation_not_absent') }
    if ($OverrideSizeStatus -cne 'absent') { $fallbackReasons.Add('wm_size_override_present') }
    if ($null -eq $ForegroundObservation) {
        $ForegroundObservation = [pscustomobject]@{
            Status = if ([string]::IsNullOrWhiteSpace($TopPackage)) { 'absent' } else { 'known' }
            Package = $TopPackage
        }
    }
    if ($ForegroundObservation.Status -cne 'known' -or
        [string]$ForegroundObservation.Package -cne 'com.tencent.mm') {
        $fallbackReasons.Add('foreground_not_known_wechat')
    }
    if ($null -eq $WindowInventory -or $WindowInventory.ParseStatus -cne 'known') {
        $fallbackReasons.Add('window_inventory_unreliable')
    }
    $baseWindows = @()
    if ($null -ne $WindowInventory -and $WindowInventory.ParseStatus -ceq 'known') {
        $baseWindows = @($WindowInventory.Windows | Where-Object {
            $_.Visibility -ceq 'strong_visible' -and $_.WindowType -ceq 'base_application'
        })
        foreach ($condition in @(
            @{ Value=$WindowInventory.VisibleOverlayCount; Code='visible_overlay_present' },
            @{ Value=$WindowInventory.VisibleOtherApplicationCount; Code='visible_other_application_present' },
            @{ Value=$WindowInventory.VisibleUnsafeOtherCount; Code='visible_unsafe_other_present' },
            @{ Value=$WindowInventory.VisibleUnknownTypeCount; Code='visible_unknown_type_present' },
            @{ Value=$WindowInventory.IdentityMissingCount; Code='window_identity_missing' },
            @{ Value=$WindowInventory.IdentityConflictCount; Code='window_identity_conflict' },
            @{ Value=$WindowInventory.DuplicateIdentityCount; Code='window_identity_duplicate' },
            @{ Value=$WindowInventory.WeakVisibilityCount; Code='window_visibility_weak_or_unknown' },
            @{ Value=$WindowInventory.VisibilityAmbiguousCount; Code='window_visibility_ambiguous' },
            @{ Value=$WindowInventory.DisplayUnknownCount; Code='window_display_unknown' },
            @{ Value=$WindowInventory.NonDefaultDisplayCount; Code='non_default_display_present' }
            @{ Value=$WindowInventory.MalformedFieldCount; Code='window_field_malformed' }
        )) {
            if ([int]$condition.Value -gt 0) { $fallbackReasons.Add($condition.Code) }
        }
    }
    if ($baseWindows.Count -ne 1) { $fallbackReasons.Add('base_window_count_not_one') }
    $candidate = if ($baseWindows.Count -eq 1) { $baseWindows[0] } else { $null }
    if ($null -ne $candidate) {
        if ($candidate.IdentityStatus -cne 'known' -or [string]::IsNullOrWhiteSpace($candidate.Identity)) {
            $fallbackReasons.Add('window_identity_unreliable')
        }
        if ($candidate.DisplayStatus -cne 'known' -or [int]$candidate.DisplayId -ne 0) {
            $fallbackReasons.Add('window_not_default_display')
        }
        if ([string]$candidate.owner_package -cne 'com.tencent.mm') { $fallbackReasons.Add('base_owner_not_wechat') }
        if ([string]$candidate.windowing_mode -cne 'fullscreen') { $fallbackReasons.Add('base_not_fullscreen') }
        if ($null -eq $WindowInventory.FocusWindow -or $WindowInventory.FocusStatus -cne 'bound' -or
            [string]$WindowInventory.FocusWindow.Identity -cne [string]$candidate.Identity) {
            $fallbackReasons.Add('focus_not_selected_base')
        }
        if ($null -eq $candidate.bounds -or @($candidate.bounds).Count -ne 4) {
            $fallbackReasons.Add('base_bounds_unknown')
        }
        else {
            [int[]]$bounds = @($candidate.bounds)
            $baseEdges = @([int]$base.width, [int]$base.height) | Sort-Object
            $candidateEdges = @($bounds[2], $bounds[3]) | Sort-Object
            if ($bounds[0] -ne 0 -or $bounds[1] -ne 0 -or $bounds[2] -le 0 -or $bounds[3] -le 0 -or
                $candidateEdges[0] -ne $baseEdges[0] -or $candidateEdges[1] -ne $baseEdges[1]) {
                $fallbackReasons.Add('base_bounds_not_effective_wm_size')
            }
        }
    }
    if ($fallbackReasons.Count -eq 0) {
        [int[]]$bounds = @($candidate.bounds)
        return [pscustomobject]@{
            Status='known'
            Source='fullscreen_window'
            WmSizeSource=$effectiveSize.Source
            Value=[ordered]@{ width=$bounds[2]; height=$bounds[3] }
            ReasonCodes=@()
        }
    }
    return [pscustomobject]@{
        Status='unknown'; Source='unknown'; WmSizeSource=$effectiveSize.Source; Value=$null
        ReasonCodes=@($fallbackReasons | Select-Object -Unique)
    }
}

function Get-TabletCurrentSize {
    param(
        $PhysicalSize,
        $OverrideSize,
        [AllowNull()]$Rotation,
        [AllowNull()]$WindowInventory,
        [AllowNull()][string]$TopPackage,
        [AllowNull()]$ForegroundObservation,
        [string]$RotationStatus = $(if ($null -eq $Rotation) { 'absent' } else { 'known' }),
        [string]$PhysicalSizeStatus = $(if ($null -eq $PhysicalSize) { 'absent' } else { 'known' }),
        [string]$OverrideSizeStatus = $(if ($null -eq $OverrideSize) { 'absent' } else { 'known' })
    )
    return (Get-TabletCurrentSizeObservation -PhysicalSize $PhysicalSize -OverrideSize $OverrideSize `
        -RotationStatus $RotationStatus -Rotation $Rotation -WindowInventory $WindowInventory `
        -TopPackage $TopPackage -ForegroundObservation $ForegroundObservation `
        -PhysicalSizeStatus $PhysicalSizeStatus `
        -OverrideSizeStatus $OverrideSizeStatus).Value
}

function Get-TabletOrientation {
    param($CurrentSize)
    if ($null -eq $CurrentSize) { return 'unknown' }
    if ([int]$CurrentSize.height -gt [int]$CurrentSize.width) { return 'portrait' }
    if ([int]$CurrentSize.width -gt [int]$CurrentSize.height) { return 'landscape' }
    return 'square'
}

function Get-TabletSmallestWidthDpObservation {
    param([AllowNull()][string]$ActivityText)
    if ([string]::IsNullOrWhiteSpace($ActivityText)) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    $globalConfigurations = @([regex]::Matches(
        $ActivityText,
        '(?im)^\s*mGlobalConfiguration\s*=.*$'
    ) | ForEach-Object { $_.Value })
    if ($globalConfigurations.Count -eq 0) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    if ($globalConfigurations.Count -ne 1) {
        return [pscustomobject]@{ Status='ambiguous'; Value=$null }
    }
    $tokens = @([regex]::Matches($globalConfigurations[0], '(?i)\bsw\S*dp\b'))
    $matches = @([regex]::Matches($globalConfigurations[0], '(?i)\bsw(\d+)dp\b'))
    if ($matches.Count -eq 1 -and $tokens.Count -eq 1) {
        $value = 0
        if ([int]::TryParse($matches[0].Groups[1].Value, [ref]$value) -and $value -gt 0) {
            return [pscustomobject]@{ Status='known'; Value=$value }
        }
        return [pscustomobject]@{ Status='ambiguous'; Value=$null }
    }
    if ($tokens.Count -eq 0) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    return [pscustomobject]@{ Status='ambiguous'; Value=$null }
}

function ConvertFrom-TabletSmallestWidthDp {
    param([AllowNull()][string]$ActivityText)
    return (Get-TabletSmallestWidthDpObservation $ActivityText).Value
}

function Get-TabletAmConfigSmallestWidthDpObservation {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    # 只认列首 current config；不接受 recentConfigs 中带缩进的历史 ` config:`。
    $configLines = @([regex]::Matches(($Text ?? ''), '(?im)^config:[ \t]+([^\r\n]*?)[ \t]*\r?$'))
    if ($configLines.Count -eq 0) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    if ($configLines.Count -ne 1) {
        return [pscustomobject]@{ Status='ambiguous'; Value=$null }
    }
    $qualifiers = $configLines[0].Groups[1].Value
    $swTokens = @($qualifiers -split '-' | Where-Object { $_ -match '(?i)^sw' })
    if ($swTokens.Count -eq 1) {
        $match = [regex]::Match($swTokens[0], '(?i)^sw([1-9][0-9]*)dp$')
        $value = 0
        if ($match.Success -and [int]::TryParse($match.Groups[1].Value, [ref]$value)) {
            return [pscustomobject]@{ Status='known'; Value=$value }
        }
        return [pscustomobject]@{ Status='ambiguous'; Value=$null }
    }
    if ($swTokens.Count -eq 0) {
        return [pscustomobject]@{ Status='absent'; Value=$null }
    }
    return [pscustomobject]@{ Status='ambiguous'; Value=$null }
}

function Resolve-TabletSmallestWidthDpObservation {
    param(
        [Parameter(Mandatory)]$AmConfigObservation,
        [Parameter(Mandatory)]$ActivityObservation
    )
    if ($AmConfigObservation.Status -cne 'known' -or $null -eq $AmConfigObservation.Value) {
        return [pscustomobject]@{ Status='unknown'; Source='unknown'; Value=$null }
    }
    if ($ActivityObservation.Status -ceq 'absent') {
        return [pscustomobject]@{
            Status='known'
            Source='am_config'
            Value=[int]$AmConfigObservation.Value
        }
    }
    if ($ActivityObservation.Status -ceq 'known' -and $null -ne $ActivityObservation.Value -and
        [int]$ActivityObservation.Value -eq [int]$AmConfigObservation.Value) {
        return [pscustomobject]@{
            Status='known'
            Source='activity_global_cross_checked'
            Value=[int]$AmConfigObservation.Value
        }
    }
    return [pscustomobject]@{ Status='unknown'; Source='unknown'; Value=$null }
}

function Get-TabletForegroundSourceObservation {
    param(
        [AllowNull()][string]$ActivityText,
        [Parameter(Mandatory)][ValidateSet('topResumedActivity','mResumedActivity')][string]$Field
    )
    $assignments = @([regex]::Matches(($ActivityText ?? ''),
        "(?im)^\s*$([regex]::Escape($Field))\s*[=:]\s*([^\r\n]*)\r?$"))
    $valid = [Collections.Generic.List[object]]::new()
    $absentCount = 0
    $malformedCount = 0
    foreach ($assignment in $assignments) {
        $payload = $assignment.Groups[1].Value.Trim()
        if ($payload -match '(?i)^(?:null|none|<none>)$') {
            $absentCount++
            continue
        }
        $components = @([regex]::Matches($payload,
            '(?i)(?:\bu\d+\s+)?([A-Za-z][A-Za-z0-9_.]*)/([A-Za-z0-9_.$]+)(?=$|[\s,;}])'))
        if ($components.Count -ne 1) {
            $malformedCount++
            continue
        }
        $component = $components[0]
        $valid.Add([pscustomobject]@{
            Package = Get-TabletSafeText $component.Groups[1].Value
            Activity = Get-TabletSafeText $component.Groups[2].Value
        })
    }
    $signatures = @($valid | ForEach-Object { "$($_.Package)/$($_.Activity)" } | Sort-Object -CaseSensitive -Unique)
    $conflictCount = if ($signatures.Count -gt 1) { $signatures.Count } else { 0 }
    $status = 'ambiguous'
    $value = $null
    if ($assignments.Count -eq 0 -or
        ($assignments.Count -eq 1 -and $absentCount -eq 1)) {
        $status = 'absent'
    }
    elseif ($assignments.Count -eq 1 -and $valid.Count -eq 1 -and
        $malformedCount -eq 0 -and $absentCount -eq 0) {
        $status = 'known'
        $value = $valid[0]
    }
    return [pscustomobject]@{
        Status = $status
        Value = $value
        AssignmentCount = $assignments.Count
        ValidCount = $valid.Count
        AbsentCount = $absentCount
        MalformedCount = $malformedCount
        ConflictCount = $conflictCount
    }
}

function Get-TabletForegroundObservation {
    param([AllowNull()][string]$ActivityText)
    $top = Get-TabletForegroundSourceObservation -ActivityText $ActivityText -Field topResumedActivity
    $resumed = Get-TabletForegroundSourceObservation -ActivityText $ActivityText -Field mResumedActivity
    $status = 'ambiguous'
    $source = 'none'
    $selected = $null
    if ($top.Status -ceq 'known') {
        $status = 'known'
        $source = 'top_resumed_activity'
        $selected = $top.Value
    }
    elseif ($top.Status -ceq 'absent' -and $resumed.Status -ceq 'known') {
        $status = 'known'
        $source = 'm_resumed_activity_fallback'
        $selected = $resumed.Value
    }
    elseif ($top.Status -ceq 'absent' -and $resumed.Status -ceq 'absent') {
        $status = 'absent'
    }
    return [pscustomobject]@{
        Status = $status
        Source = $source
        Package = if ($null -eq $selected) { $null } else { $selected.Package }
        Activity = if ($null -eq $selected) { $null } else { $selected.Activity }
        TopResumed = $top
        ResumedFallback = $resumed
    }
}

function ConvertFrom-TabletTopActivity {
    param([AllowNull()][string]$ActivityText, [AllowNull()][string]$WindowText)
    # 兼容旧调用形态；WindowText/mCurrentFocus 永不参与前台选择。
    return Get-TabletForegroundObservation -ActivityText $ActivityText
}

function Get-TabletWindowCaptureSnapshot {
    param([Parameter(Mandatory)]$Inventory)
    if ($Inventory.ParseStatus -cne 'known') {
        return [pscustomobject]@{ Status='unknown'; IdentitySignature=$null; SemanticSignature=$null }
    }
    $allWindowsProperty = $Inventory.PSObject.Properties['AllWindows']
    $allWindowsRaw = if ($null -eq $allWindowsProperty) { @($Inventory.Windows) } else { @($allWindowsProperty.Value) }
    $allWindows = @($allWindowsRaw | Where-Object {
        ($_.Visibility -ceq 'strong_visible' -and
            $_.WindowType -in @('base_application','application','application_overlay','unknown')) -or
        (-not [string]::IsNullOrWhiteSpace([string]$_.Identity) -and
            [string]$_.Identity -ceq [string]$Inventory.FocusIdentity)
    })
    foreach ($property in @('IdentityMissingCount','IdentityConflictCount','DuplicateIdentityCount',
        'VisibilityAmbiguousCount','WeakVisibilityCount','MalformedFieldCount')) {
        $candidate = $Inventory.PSObject.Properties[$property]
        if ($null -eq $candidate -or [int]$candidate.Value -gt 0) {
            return [pscustomobject]@{ Status='unknown'; IdentitySignature=$null; SemanticSignature=$null }
        }
    }
    if ($Inventory.FocusStatus -cne 'bound' -or [string]::IsNullOrWhiteSpace([string]$Inventory.FocusIdentity)) {
        return [pscustomobject]@{ Status='unknown'; IdentitySignature=$null; SemanticSignature=$null }
    }
    $identities = [Collections.Generic.List[string]]::new()
    $semantics = [Collections.Generic.List[string]]::new()
    foreach ($window in $allWindows) {
        if ($window.IdentityStatus -cne 'known' -or [string]::IsNullOrWhiteSpace([string]$window.Identity) -or
            $window.Visibility -in @('unknown','weak_unknown','ambiguous')) {
            return [pscustomobject]@{ Status='unknown'; IdentitySignature=$null; SemanticSignature=$null }
        }
        $identity = [string]$window.Identity
        $identities.Add($identity)
        $bounds = if ($null -eq $window.bounds) { 'unknown' } else { @($window.bounds) -join ',' }
        $semantics.Add(($identity, [string]$window.DisplayStatus, [string]$window.DisplayId,
            [string]$window.WindowType, [string]$window.Visibility, $bounds,
            [string]$window.windowing_mode, [string]$window.owner_package) -join '|')
    }
    [string[]]$identityArray = $identities.ToArray()
    [string[]]$semanticArray = $semantics.ToArray()
    [Array]::Sort($identityArray, [StringComparer]::Ordinal)
    [Array]::Sort($semanticArray, [StringComparer]::Ordinal)
    return [pscustomobject]@{
        Status='known'
        IdentitySignature=($identityArray -join "`n")
        SemanticSignature=(($semanticArray + @("focus|$($Inventory.FocusIdentity)")) -join "`n")
    }
}

function Get-TabletCaptureConsistencyObservation {
    param(
        [Parameter(Mandatory)]$InitialRotationObservation,
        [Parameter(Mandatory)]$FinalRotationObservation,
        [Parameter(Mandatory)]$InitialForegroundObservation,
        [Parameter(Mandatory)]$FinalForegroundObservation,
        [Parameter(Mandatory)]$InitialWindows,
        [Parameter(Mandatory)]$FinalWindows,
        [Parameter(Mandatory)]$InitialCurrentSizeObservation,
        [Parameter(Mandatory)]$FinalCurrentSizeObservation,
        [Parameter(Mandatory)]$InitialSmallestWidthObservation,
        [Parameter(Mandatory)]$FinalSmallestWidthObservation,
        [Parameter(Mandatory)]$InitialDensityObservation,
        [Parameter(Mandatory)]$FinalDensityObservation,
        [AllowNull()]$InitialStateObservation,
        [AllowNull()]$FinalStateObservation
    )
    $unknownReasons = [Collections.Generic.List[string]]::new()
    $changedReasons = [Collections.Generic.List[string]]::new()

    if ($InitialForegroundObservation.Status -cne 'known' -or $FinalForegroundObservation.Status -cne 'known') {
        $unknownReasons.Add('foreground_unreliable')
    }
    else {
        if ([string]$InitialForegroundObservation.Source -cne [string]$FinalForegroundObservation.Source) {
            $changedReasons.Add('foreground_source_changed')
        }
        if ([string]$InitialForegroundObservation.Package -cne [string]$FinalForegroundObservation.Package -or
            [string]$InitialForegroundObservation.Activity -cne [string]$FinalForegroundObservation.Activity) {
            $changedReasons.Add('foreground_changed')
        }
    }

    if (($null -eq $InitialStateObservation) -xor ($null -eq $FinalStateObservation)) {
        $unknownReasons.Add('state_observation_unreliable')
    }
    elseif ($null -ne $InitialStateObservation -and $null -ne $FinalStateObservation) {
        if ($null -eq $InitialStateObservation.Awake -or $null -eq $FinalStateObservation.Awake) {
            $unknownReasons.Add('screen_awake_unreliable')
        }
        elseif ([bool]$InitialStateObservation.Awake -ne [bool]$FinalStateObservation.Awake) {
            $changedReasons.Add('screen_awake_changed')
        }
        if ($null -eq $InitialStateObservation.KeyguardLocked -or $null -eq $FinalStateObservation.KeyguardLocked) {
            $unknownReasons.Add('keyguard_unreliable')
        }
        elseif ([bool]$InitialStateObservation.KeyguardLocked -ne [bool]$FinalStateObservation.KeyguardLocked) {
            $changedReasons.Add('keyguard_changed')
        }
        if ($null -eq $InitialStateObservation.ZenMode -or $null -eq $FinalStateObservation.ZenMode) {
            $unknownReasons.Add('zen_unreliable')
        }
        elseif ([int]$InitialStateObservation.ZenMode -ne [int]$FinalStateObservation.ZenMode) {
            $changedReasons.Add('zen_changed')
        }
        $initialIme = $InitialStateObservation.ImeState
        $finalIme = $FinalStateObservation.ImeState
        if ($null -eq $initialIme -or $null -eq $finalIme -or
            $null -eq $initialIme.SessionShown -or $null -eq $finalIme.SessionShown -or
            $null -eq $initialIme.Visible -or $null -eq $finalIme.Visible -or
            $null -eq $initialIme.Floating -or $null -eq $finalIme.Floating) {
            $unknownReasons.Add('ime_state_unreliable')
        }
        else {
            $initialImeSignature = ([ordered]@{
                session=[bool]$initialIme.SessionShown; visible=[bool]$initialIme.Visible
                floating=[bool]$initialIme.Floating
                bounds=if ([bool]$initialIme.Visible) { @($initialIme.Bounds) } else { @() }
            } | ConvertTo-Json -Compress -Depth 3)
            $finalImeSignature = ([ordered]@{
                session=[bool]$finalIme.SessionShown; visible=[bool]$finalIme.Visible
                floating=[bool]$finalIme.Floating
                bounds=if ([bool]$finalIme.Visible) { @($finalIme.Bounds) } else { @() }
            } | ConvertTo-Json -Compress -Depth 3)
            if ($initialImeSignature -cne $finalImeSignature) { $changedReasons.Add('ime_state_changed') }
        }
    }

    if ($InitialRotationObservation.Status -notin @('known','absent') -or
        $FinalRotationObservation.Status -notin @('known','absent')) {
        $unknownReasons.Add('rotation_unreliable')
    }
    else {
        if ([string]$InitialRotationObservation.Status -cne [string]$FinalRotationObservation.Status) {
            $changedReasons.Add('rotation_status_changed')
        }
        elseif ($InitialRotationObservation.Status -ceq 'known') {
            if ([int]$InitialRotationObservation.Value -ne [int]$FinalRotationObservation.Value) {
                $changedReasons.Add('rotation_value_changed')
            }
            if ([string]$InitialRotationObservation.Source -cne [string]$FinalRotationObservation.Source) {
                $changedReasons.Add('rotation_source_changed')
            }
        }
    }

    if ($InitialCurrentSizeObservation.Status -cne 'known' -or
        $FinalCurrentSizeObservation.Status -cne 'known' -or
        $null -eq $InitialCurrentSizeObservation.Value -or $null -eq $FinalCurrentSizeObservation.Value) {
        $unknownReasons.Add('current_size_unknown')
    }
    else {
        if ([int]$InitialCurrentSizeObservation.Value.width -ne [int]$FinalCurrentSizeObservation.Value.width -or
            [int]$InitialCurrentSizeObservation.Value.height -ne [int]$FinalCurrentSizeObservation.Value.height) {
            $changedReasons.Add('current_size_changed')
        }
        if ([string]$InitialCurrentSizeObservation.Source -cne [string]$FinalCurrentSizeObservation.Source) {
            $changedReasons.Add('current_size_source_changed')
        }
        if ([string]$InitialCurrentSizeObservation.WmSizeSource -cne [string]$FinalCurrentSizeObservation.WmSizeSource) {
            $changedReasons.Add('wm_size_source_changed')
        }
    }

    if ($InitialSmallestWidthObservation.Status -cne 'known' -or
        $FinalSmallestWidthObservation.Status -cne 'known' -or
        $null -eq $InitialSmallestWidthObservation.Value -or $null -eq $FinalSmallestWidthObservation.Value) {
        $unknownReasons.Add('smallest_width_unreliable')
    }
    else {
        if ([string]$InitialSmallestWidthObservation.Source -cne [string]$FinalSmallestWidthObservation.Source) {
            $changedReasons.Add('smallest_width_source_changed')
        }
        if ([int]$InitialSmallestWidthObservation.Value -ne [int]$FinalSmallestWidthObservation.Value) {
            $changedReasons.Add('smallest_width_value_changed')
        }
    }

    if ($InitialDensityObservation.Status -cne 'known' -or $FinalDensityObservation.Status -cne 'known' -or
        $null -eq $InitialDensityObservation.Value -or $null -eq $FinalDensityObservation.Value) {
        $unknownReasons.Add('density_unreliable')
    }
    else {
        if ([string]$InitialDensityObservation.Source -cne [string]$FinalDensityObservation.Source) {
            $changedReasons.Add('density_source_changed')
        }
        if ([int]$InitialDensityObservation.Value -ne [int]$FinalDensityObservation.Value) {
            $changedReasons.Add('density_value_changed')
        }
    }

    $initialWindowSnapshot = Get-TabletWindowCaptureSnapshot $InitialWindows
    $finalWindowSnapshot = Get-TabletWindowCaptureSnapshot $FinalWindows
    if ($initialWindowSnapshot.Status -cne 'known' -or $finalWindowSnapshot.Status -cne 'known') {
        $unknownReasons.Add('window_identity_unreliable')
    }
    else {
        if ($initialWindowSnapshot.IdentitySignature -cne $finalWindowSnapshot.IdentitySignature) {
            $changedReasons.Add('window_identity_changed')
        }
        elseif ($initialWindowSnapshot.SemanticSignature -cne $finalWindowSnapshot.SemanticSignature) {
            $changedReasons.Add('window_semantics_changed')
        }
    }

    if ($unknownReasons.Count -gt 0) {
        return [pscustomobject]@{
            Status='unknown'; Value=$null
            ReasonCodes=@($unknownReasons | Select-Object -Unique)
        }
    }
    if ($changedReasons.Count -gt 0) {
        return [pscustomobject]@{
            Status='changed'; Value=$false
            ReasonCodes=@($changedReasons | Select-Object -Unique)
        }
    }
    return [pscustomobject]@{ Status='consistent'; Value=$true; ReasonCodes=@() }
}

function Test-TabletCaptureConsistency {
    param(
        [AllowNull()]$InitialRotation, [AllowNull()]$FinalRotation,
        [Parameter(Mandatory)]$InitialTop, [Parameter(Mandatory)]$FinalTop,
        [Parameter(Mandatory)]$InitialWindows, [Parameter(Mandatory)]$FinalWindows,
        [AllowNull()]$InitialCurrentSize, [AllowNull()]$FinalCurrentSize,
        [string]$InitialRotationStatus = $(if ($null -eq $InitialRotation) { 'absent' } else { 'known' }),
        [string]$FinalRotationStatus = $(if ($null -eq $FinalRotation) { 'absent' } else { 'known' }),
        [AllowNull()]$InitialSmallestWidthDp, [AllowNull()]$FinalSmallestWidthDp,
        [string]$InitialSmallestWidthStatus = 'known', [string]$FinalSmallestWidthStatus = 'known',
        [string]$InitialSmallestWidthSource = 'activity_global', [string]$FinalSmallestWidthSource = 'activity_global',
        [string]$InitialSizeSource = 'physical', [string]$FinalSizeSource = 'physical',
        [string]$InitialCurrentSizeSource = 'rotation', [string]$FinalCurrentSizeSource = 'rotation',
        [AllowNull()]$InitialDensity, [AllowNull()]$FinalDensity,
        [string]$InitialDensitySource = 'physical', [string]$FinalDensitySource = 'physical'
    )
    $observation = Get-TabletCaptureConsistencyObservation `
        -InitialRotationObservation ([pscustomobject]@{Status=$InitialRotationStatus;Value=$InitialRotation;Source='legacy'}) `
        -FinalRotationObservation ([pscustomobject]@{Status=$FinalRotationStatus;Value=$FinalRotation;Source='legacy'}) `
        -InitialForegroundObservation ([pscustomobject]@{Status=$(if ([string]::IsNullOrWhiteSpace([string]$InitialTop.Package)) {'absent'} else {'known'});Source='legacy';Package=$InitialTop.Package;Activity=$InitialTop.Activity}) `
        -FinalForegroundObservation ([pscustomobject]@{Status=$(if ([string]::IsNullOrWhiteSpace([string]$FinalTop.Package)) {'absent'} else {'known'});Source='legacy';Package=$FinalTop.Package;Activity=$FinalTop.Activity}) `
        -InitialWindows $InitialWindows -FinalWindows $FinalWindows `
        -InitialCurrentSizeObservation ([pscustomobject]@{Status=$(if ($null -eq $InitialCurrentSize) {'unknown'} else {'known'});Source=$InitialCurrentSizeSource;WmSizeSource=$InitialSizeSource;Value=$InitialCurrentSize}) `
        -FinalCurrentSizeObservation ([pscustomobject]@{Status=$(if ($null -eq $FinalCurrentSize) {'unknown'} else {'known'});Source=$FinalCurrentSizeSource;WmSizeSource=$FinalSizeSource;Value=$FinalCurrentSize}) `
        -InitialSmallestWidthObservation ([pscustomobject]@{Status=$InitialSmallestWidthStatus;Source=$InitialSmallestWidthSource;Value=$InitialSmallestWidthDp}) `
        -FinalSmallestWidthObservation ([pscustomobject]@{Status=$FinalSmallestWidthStatus;Source=$FinalSmallestWidthSource;Value=$FinalSmallestWidthDp}) `
        -InitialDensityObservation ([pscustomobject]@{Status=$(if ($null -eq $InitialDensity) {'unknown'} else {'known'});Source=$InitialDensitySource;Value=$InitialDensity}) `
        -FinalDensityObservation ([pscustomobject]@{Status=$(if ($null -eq $FinalDensity) {'unknown'} else {'known'});Source=$FinalDensitySource;Value=$FinalDensity})
    return $observation.Value
}

function ConvertFrom-TabletAwake {
    param([AllowNull()][string]$PowerText)
    $on = $PowerText -match '(?im)\bmWakefulness\s*=\s*Awake\b|Display Power:\s*state\s*=\s*ON\b'
    $off = $PowerText -match '(?im)\bmWakefulness\s*=\s*(Asleep|Dozing|Dreaming)\b|Display Power:\s*state\s*=\s*OFF\b'
    if ($on -and -not $off) { return $true }
    if ($off -and -not $on) { return $false }
    return $null
}

function ConvertFrom-TabletKeyguardLocked {
    param([AllowNull()][string]$PolicyText)
    $trueHit = $PolicyText -match '(?im)\b(?:mShowingLockscreen|showing|isStatusBarKeyguard)\s*[=:]\s*true\b'
    $falseHit = $PolicyText -match '(?im)\b(?:mShowingLockscreen|showing|isStatusBarKeyguard)\s*[=:]\s*false\b'
    if ($trueHit -and -not $falseHit) { return $true }
    if ($falseHit -and -not $trueHit) { return $false }
    return $null
}

function ConvertFrom-TabletZenMode {
    param([AllowNull()][string]$Text)
    $value = 0
    if ([int]::TryParse(($Text ?? '').Trim(), [ref]$value) -and $value -ge 0 -and $value -le 3) {
        return $value
    }
    return $null
}

function ConvertFrom-TabletApiLevel {
    param([AllowNull()][string]$Text)
    $value = 0
    if ([int]::TryParse(($Text ?? '').Trim(), [ref]$value) -and $value -gt 0) { return $value }
    return $null
}

function ConvertFrom-TabletImeState {
    param([AllowNull()][string]$Text)
    $imeText = $Text ?? ''
    $sessionShown = $null
    $sessionAssignments = @([regex]::Matches($imeText,
        '(?im)\bmInputShown\s*=\s*([^\s,}\]]+)'))
    $sessionTokens = @($sessionAssignments | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    $sessionValid = @($sessionTokens | Where-Object { $_ -in @('true','false') })
    $sessionUnique = @($sessionValid | Sort-Object -CaseSensitive -Unique)
    if ($sessionAssignments.Count -gt 0 -and $sessionValid.Count -eq $sessionAssignments.Count -and
        $sessionUnique.Count -eq 1) {
        $sessionShown = $sessionUnique[0] -ceq 'true'
    }

    $visible = $null
    $visAssignments = @([regex]::Matches($imeText,
        '(?im)\bmImeWindowVis\s*=\s*([^\s,}\]]+)'))
    $parsedVisValues = [Collections.Generic.List[uint32]]::new()
    $invalidVisCount = 0
    foreach ($visAssignment in $visAssignments) {
        $token = $visAssignment.Groups[1].Value
        [uint32]$bits = 0
        $validBits = if ($token -cmatch '^0x([0-9a-fA-F]+)$') {
            [uint32]::TryParse($Matches[1], [Globalization.NumberStyles]::HexNumber,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$bits)
        }
        elseif ($token -cmatch '^\d+$') { [uint32]::TryParse($token, [ref]$bits) }
        else { $false }
        if ($validBits) { $parsedVisValues.Add($bits) } else { $invalidVisCount++ }
    }
    $uniqueVisValues = @($parsedVisValues | Sort-Object -Unique)
    if ($visAssignments.Count -gt 0 -and $invalidVisCount -eq 0 -and $uniqueVisValues.Count -eq 1) {
        $visible = (([uint32]$uniqueVisValues[0] -band 0x2) -ne 0)
    }

    $floating = $null
    $floatingAssignments = @([regex]::Matches($imeText,
        '(?im)\b(?:mIsFloating|isFloating)\s*=\s*([^\s,}\]]+)'))
    $floatingTokens = @($floatingAssignments | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
    $floatingValid = @($floatingTokens | Where-Object { $_ -in @('true','false') })
    $floatingUnique = @($floatingValid | Sort-Object -CaseSensitive -Unique)
    if ($floatingAssignments.Count -gt 0 -and $floatingValid.Count -eq $floatingAssignments.Count -and
        $floatingUnique.Count -eq 1) {
        $floating = $floatingUnique[0] -ceq 'true'
    }
    elseif ($floatingAssignments.Count -eq 0 -and $visible -eq $false) { $floating = $false }

    $bounds = $null
    $boundsAssignments = @([regex]::Matches($imeText,
        '(?im)^\s*(?:mVisibleBound|visibleBounds?)\s*[=:]\s*([^\r\n]*)\r?$'))
    $parsedBoundsValues = [Collections.Generic.List[object]]::new()
    $invalidBoundsCount = 0
    foreach ($boundsAssignment in $boundsAssignments) {
        $boundsMatch = [regex]::Match($boundsAssignment.Groups[1].Value.Trim(),
            '^(?:Rect\()?\[?(\d+)[, ]+(\d+)\]?(?:\[|\s*-\s*)(\d+)[, ]+(\d+)\]?\)?$')
        if (-not $boundsMatch.Success) {
            $invalidBoundsCount++
            continue
        }
        $parsedBounds = [Collections.Generic.List[int]]::new()
        $boundsValid = $true
        foreach ($groupIndex in 1..4) {
            [int]$parsedBound = 0
            if (-not [int]::TryParse($boundsMatch.Groups[$groupIndex].Value, [ref]$parsedBound)) {
                $boundsValid = $false
                continue
            }
            $parsedBounds.Add($parsedBound)
        }
        if ($boundsValid -and $parsedBounds.Count -eq 4) { $parsedBoundsValues.Add(@($parsedBounds)) }
        else { $invalidBoundsCount++ }
    }
    $boundsSignatures = @($parsedBoundsValues | ForEach-Object { @($_) -join ',' } |
        Sort-Object -CaseSensitive -Unique)
    if ($boundsAssignments.Count -gt 0 -and $invalidBoundsCount -eq 0 -and $boundsSignatures.Count -eq 1) {
        $bounds = @($parsedBoundsValues[0])
    }
    return [pscustomobject]@{
        SessionShown = $sessionShown
        Visible = $visible
        Floating = $floating
        Bounds = $bounds
    }
}

function ConvertFrom-TabletWindowTypeToken {
    param([AllowNull()][string]$Token)
    $value = ($Token ?? '').ToUpperInvariant()
    switch ($value) {
        'BASE_APPLICATION' { return 'base_application' }
        'TYPE_BASE_APPLICATION' { return 'base_application' }
        'APPLICATION' { return 'application' }
        'TYPE_APPLICATION' { return 'application' }
        'APPLICATION_OVERLAY' { return 'application_overlay' }
        'TYPE_APPLICATION_OVERLAY' { return 'application_overlay' }
        'INPUT_METHOD' { return 'input_method' }
        'TYPE_INPUT_METHOD' { return 'input_method' }
        'STATUS_BAR' { return 'system_bar' }
        'TYPE_STATUS_BAR' { return 'system_bar' }
        'NAVIGATION_BAR' { return 'system_bar' }
        'TYPE_NAVIGATION_BAR' { return 'system_bar' }
        'WALLPAPER' { return 'safe_background' }
        'TYPE_WALLPAPER' { return 'safe_background' }
    }
    [long]$numeric = 0
    if ($value -match '^\d+$') {
        if (-not [long]::TryParse($value, [ref]$numeric)) { return 'unknown' }
        if ($numeric -eq 1) { return 'base_application' }
        if ($numeric -ge 2 -and $numeric -le 99) { return 'application' }
        if ($numeric -eq 2000 -or $numeric -eq 2019) { return 'system_bar' }
        if ($numeric -eq 2013) { return 'safe_background' }
        if ($numeric -eq 2011) { return 'input_method' }
        if ($numeric -eq 2038) { return 'application_overlay' }
        return 'unknown'
    }
    return 'unknown'
}

function ConvertFrom-TabletWindowInventory {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{
            ParseStatus='unknown'; Count=$null; Windows=@(); AllWindows=@(); FocusStatus='absent'; FocusIdentity=$null
            FocusWindow=$null; BlockCount=0; StrongVisibleCount=0; WeakVisibilityCount=0
            VisibleOverlayCount=0; VisibleUnknownTypeCount=0; IdentityMissingCount=0
            IdentityConflictCount=0; DuplicateIdentityCount=0; DisplayUnknownCount=0
            NonDefaultDisplayCount=0; VisibilityAmbiguousCount=0; VisibleImeCount=0
            VisibleSystemWindowCount=0; VisibleUnsafeOtherCount=0; VisibleOtherApplicationCount=0; MalformedFieldCount=0
            FocusAssignmentCount=0; FocusDistinctCount=0; FocusMappedCount=0; FocusMalformedCount=0; FocusConflictCount=0
        }
    }
    $blocks = @([regex]::Split($Text, '(?m)(?=^\s*Window #\d+\s+)') |
        Where-Object { $_ -match '(?m)^\s*Window #\d+\s+' })
    if ($blocks.Count -eq 0) {
        return [pscustomobject]@{
            ParseStatus='unknown'; Count=$null; Windows=@(); AllWindows=@(); FocusStatus='absent'; FocusIdentity=$null
            FocusWindow=$null; BlockCount=0; StrongVisibleCount=0; WeakVisibilityCount=0
            VisibleOverlayCount=0; VisibleUnknownTypeCount=0; IdentityMissingCount=0
            IdentityConflictCount=0; DuplicateIdentityCount=0; DisplayUnknownCount=0
            NonDefaultDisplayCount=0; VisibilityAmbiguousCount=0; VisibleImeCount=0
            VisibleSystemWindowCount=0; VisibleUnsafeOtherCount=0; VisibleOtherApplicationCount=0; MalformedFieldCount=0
            FocusAssignmentCount=0; FocusDistinctCount=0; FocusMappedCount=0; FocusMalformedCount=0; FocusConflictCount=0
        }
    }

    $windows = [Collections.Generic.List[object]]::new()
    foreach ($block in $blocks) {
        $windowMalformedCount = 0
        $header = [regex]::Match($block,
            '(?im)^\s*Window #(?<index>\d+)\s+Window\{(?<identity>[^\s}]+)(?:\s+u\d+\s+(?<package>[A-Za-z][A-Za-z0-9_.]*)/(?<activity>[A-Za-z0-9_.$]+))?[^\r\n]*\}:')
        $rawIdentity = if ($header.Success) { $header.Groups['identity'].Value } else { $null }
        $identity = if ($null -ne $rawIdentity -and $rawIdentity.Length -le 200) {
            Get-TabletSafeText $rawIdentity 200
        } else { $null }
        if ($null -ne $rawIdentity -and $rawIdentity.Length -gt 200) { $windowMalformedCount++ }
        $identityStatus = if ([string]::IsNullOrWhiteSpace($identity)) { 'missing' } else { 'known' }
        $headerLine = @($block -split "`r?`n")[0]
        $headerIdentityValues = @([regex]::Matches($headerLine, 'Window\{([^\s}]+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -CaseSensitive -Unique)
        if ($headerIdentityValues.Count -gt 1) { $identityStatus = 'conflict' }
        # WindowState header object identity 与 mToken/WindowToken 是不同层对象，禁止交叉等值比较。

        $typeAssignments = @([regex]::Matches($block,
            '(?im)\b(?:ty|type)\s*=\s*([^\s,}\]]+)'))
        $typeTokens = @($typeAssignments |
            ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
        $typeKinds = @($typeTokens | ForEach-Object { ConvertFrom-TabletWindowTypeToken $_ } |
            Sort-Object -CaseSensitive -Unique)
        $typeInvalidCount = @($typeKinds | Where-Object { $_ -ceq 'unknown' }).Count
        if ($typeKinds.Count -eq 1 -and $typeInvalidCount -eq 0) { $windowType = $typeKinds[0] }
        else { $windowType = 'unknown' }
        if ($typeAssignments.Count -gt 0 -and ($typeInvalidCount -gt 0 -or $typeKinds.Count -ne 1)) {
            $windowMalformedCount++
        }

        $visibilityAssignments = @([regex]::Matches($block,
            '(?im)\b(?:isOnScreen|isVisible)\s*=\s*([^\s,}\]]+)'))
        $visibilityTokens = @($visibilityAssignments | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
        $trueCount = @($visibilityTokens | Where-Object { $_ -ceq 'true' }).Count
        $falseCount = @($visibilityTokens | Where-Object { $_ -ceq 'false' }).Count
        $invalidVisibilityCount = @($visibilityTokens | Where-Object { $_ -notin @('true','false') }).Count
        $weakVisible = $block -match '(?im)\bmViewVisibility\s*=\s*0x0\b'
        $visibility = if ($invalidVisibilityCount -gt 0) { 'ambiguous' }
            elseif ($trueCount -gt 0 -and $falseCount -eq 0) { 'strong_visible' }
            elseif ($trueCount -gt 0 -and $falseCount -gt 0) { 'ambiguous' }
            elseif ($falseCount -gt 0) { 'not_visible' }
            elseif ($weakVisible) { 'weak_unknown' }
            else { 'unknown' }
        if ($invalidVisibilityCount -gt 0) { $windowMalformedCount++ }

        $boundsAssignments = @([regex]::Matches($block,
            '(?im)^\s*(?:mFrame|frame)\s*=\s*([^\r\n]*)\r?$'))
        $bounds = $null
        $parsedBoundsValues = [Collections.Generic.List[object]]::new()
        $invalidBoundsCount = 0
        foreach ($boundsAssignment in $boundsAssignments) {
            $boundsMatch = [regex]::Match($boundsAssignment.Groups[1].Value.Trim(),
                '^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$')
            if (-not $boundsMatch.Success) {
                $invalidBoundsCount++
                continue
            }
            $parsedBounds = [Collections.Generic.List[int]]::new()
            $boundsValid = $true
            foreach ($groupIndex in 1..4) {
                [int]$parsedBound = 0
                if (-not [int]::TryParse($boundsMatch.Groups[$groupIndex].Value, [ref]$parsedBound)) {
                    $boundsValid = $false
                    continue
                }
                $parsedBounds.Add($parsedBound)
            }
            if ($boundsValid -and $parsedBounds.Count -eq 4) { $parsedBoundsValues.Add(@($parsedBounds)) }
            else { $invalidBoundsCount++ }
        }
        $boundsSignatures = @($parsedBoundsValues | ForEach-Object { @($_) -join ',' } |
            Sort-Object -CaseSensitive -Unique)
        if ($invalidBoundsCount -eq 0 -and $boundsSignatures.Count -eq 1) {
            $bounds = @($parsedBoundsValues[0])
        }
        elseif ($boundsAssignments.Count -gt 0) {
            $windowMalformedCount++
        }

        $modeAssignments = @([regex]::Matches($block,
            '(?im)\b(?:mWindowingMode|windowingMode)\s*=\s*([^\s,}\]]+)'))
        $invalidModeCount = @($modeAssignments | Where-Object { $_.Groups[1].Value -cnotmatch '^[A-Za-z0-9_-]+$' }).Count
        $modeValues = @($modeAssignments | Where-Object { $_.Groups[1].Value -cmatch '^[A-Za-z0-9_-]+$' } |
          ForEach-Object {
            $rawMode = $_.Groups[1].Value.ToLowerInvariant()
            switch ($rawMode) {
                '1' { 'fullscreen' }
                '2' { 'pinned' }
                '3' { 'split_screen_primary' }
                '4' { 'split_screen_secondary' }
                '5' { 'freeform' }
                '6' { 'multi_window' }
                default { $rawMode -replace '-', '_' }
            }
        } | Sort-Object -CaseSensitive -Unique)
        $mode = if ($invalidModeCount -eq 0 -and $modeValues.Count -eq 1) { $modeValues[0] } else { $null }
        if ($modeAssignments.Count -gt 0 -and ($invalidModeCount -gt 0 -or $modeValues.Count -ne 1)) {
            $windowMalformedCount++
        }

        $displayMatches = @([regex]::Matches($block,
            '(?im)\b(?:mDisplayId|displayId)\s*=\s*([^\s,}\]]+)'))
        $parsedDisplayValues = [Collections.Generic.List[int]]::new()
        $invalidDisplayCount = 0
        foreach ($displayMatch in $displayMatches) {
            [int]$parsedDisplay = 0
            if ([int]::TryParse($displayMatch.Groups[1].Value, [ref]$parsedDisplay)) {
                $parsedDisplayValues.Add($parsedDisplay)
            }
            else { $invalidDisplayCount++ }
        }
        $displayValues = @($parsedDisplayValues | Sort-Object -Unique)
        $displayStatus = if ($displayMatches.Count -eq 0) { 'missing' }
            elseif ($invalidDisplayCount -eq 0 -and $displayValues.Count -eq 1) { 'known' }
            else { 'conflict' }
        if ($displayStatus -ceq 'conflict') { $windowMalformedCount++ }
        $displayId = if ($displayStatus -ceq 'known') { $displayValues[0] } else { $null }
        [int]$parsedIndex = $windows.Count
        if ($header.Success -and -not [int]::TryParse($header.Groups['index'].Value, [ref]$parsedIndex)) {
            $parsedIndex = $windows.Count
            $windowMalformedCount++
        }
        $windows.Add([pscustomobject]@{
            index = $parsedIndex
            Identity = $identity
            IdentityStatus = $identityStatus
            DisplayStatus = $displayStatus
            DisplayId = $displayId
            WindowType = $windowType
            Visibility = $visibility
            bounds = $bounds
            windowing_mode = $mode
            owner_package = if ($header.Success -and $header.Groups['package'].Success) {
                Get-TabletSafeText $header.Groups['package'].Value
            } else { $null }
            OwnerActivity = if ($header.Success -and $header.Groups['activity'].Success) {
                Get-TabletSafeText $header.Groups['activity'].Value
            } else { $null }
            MalformedFieldCount = $windowMalformedCount
        })
    }

    $identityGroups = @($windows | Where-Object { $_.IdentityStatus -ceq 'known' } |
        Group-Object -CaseSensitive -Property Identity)
    $duplicateIdentityCount = @($identityGroups | Where-Object { $_.Count -gt 1 }).Count
    $focusAssignmentLines = @([regex]::Matches($Text,
        '(?im)^\s*mCurrentFocus\s*=\s*([^\r\n]*)\r?$'))
    $focusIdentities = [Collections.Generic.List[string]]::new()
    $focusAbsentCount = 0
    $focusMalformedCount = 0
    foreach ($focusAssignment in $focusAssignmentLines) {
        $payload = $focusAssignment.Groups[1].Value.Trim()
        if ($payload -match '(?i)^(?:null|none|<none>)$') {
            $focusAbsentCount++
            continue
        }
        $focusMatch = [regex]::Match($payload, '^Window\{([^\s}]+)(?:\s+[^{}]*)?\}$')
        if ($focusMatch.Success -and $focusMatch.Groups[1].Value.Length -le 200) {
            $focusIdentities.Add($focusMatch.Groups[1].Value)
        }
        else { $focusMalformedCount++ }
    }
    $focusDistinct = @($focusIdentities | Sort-Object -CaseSensitive -Unique)
    $focusIdentity = $null
    $focusStatus = if ($focusAssignmentLines.Count -eq 0 -or
        ($focusAssignmentLines.Count -eq 1 -and $focusAbsentCount -eq 1)) { 'absent' } else { 'ambiguous' }
    $focusWindow = $null
    if ($focusAssignmentLines.Count -eq 1 -and $focusIdentities.Count -eq 1 -and
        $focusMalformedCount -eq 0 -and $focusAbsentCount -eq 0) {
        $focusIdentity = [string]$focusIdentities[0]
        $focusMatches = @($windows | Where-Object {
            $_.IdentityStatus -ceq 'known' -and $_.Identity -ceq $focusIdentity
        })
        if ($focusMatches.Count -eq 1) {
            $focusStatus = 'bound'
            $focusWindow = $focusMatches[0]
        }
        else { $focusStatus = 'unbound' }
    }
    $strongVisible = @($windows | Where-Object { $_.Visibility -ceq 'strong_visible' })
    $baseWindows = @($strongVisible | Where-Object { $_.WindowType -ceq 'base_application' })
    return [pscustomobject]@{
        ParseStatus = 'known'
        Count = $baseWindows.Count
        Windows = @($baseWindows)
        AllWindows = @($windows)
        FocusStatus = $focusStatus
        FocusIdentity = $focusIdentity
        FocusWindow = $focusWindow
        BlockCount = $windows.Count
        StrongVisibleCount = $strongVisible.Count
        WeakVisibilityCount = @($windows | Where-Object {
            $_.WindowType -in @('base_application','application','application_overlay','unknown') -and
            $_.Visibility -in @('weak_unknown','unknown')
        }).Count
        VisibleOverlayCount = @($strongVisible | Where-Object { $_.WindowType -ceq 'application_overlay' }).Count
        VisibleUnknownTypeCount = @($strongVisible | Where-Object { $_.WindowType -ceq 'unknown' }).Count
        VisibleImeCount = @($strongVisible | Where-Object { $_.WindowType -ceq 'input_method' }).Count
        VisibleOtherApplicationCount = @($strongVisible | Where-Object { $_.WindowType -ceq 'application' }).Count
        VisibleSystemWindowCount = @($strongVisible | Where-Object {
            $_.WindowType -in @('system_bar','safe_background')
        }).Count
        VisibleUnsafeOtherCount = @($strongVisible | Where-Object { $_.WindowType -ceq 'other' }).Count
        IdentityMissingCount = @($windows | Where-Object { $_.IdentityStatus -ceq 'missing' }).Count
        IdentityConflictCount = @($windows | Where-Object { $_.IdentityStatus -ceq 'conflict' }).Count
        DuplicateIdentityCount = $duplicateIdentityCount
        DisplayUnknownCount = @($strongVisible | Where-Object {
            $_.WindowType -in @('base_application','application','application_overlay','unknown') -and
            $_.DisplayStatus -cne 'known'
        }).Count
        NonDefaultDisplayCount = @($strongVisible | Where-Object {
            $_.WindowType -in @('base_application','application','application_overlay','unknown') -and
            $_.DisplayStatus -ceq 'known' -and [int]$_.DisplayId -ne 0
        }).Count
        VisibilityAmbiguousCount = @($windows | Where-Object {
            $_.WindowType -in @('base_application','application','application_overlay','unknown') -and
            $_.Visibility -ceq 'ambiguous'
        }).Count
        MalformedFieldCount = [int](($windows | Measure-Object -Property MalformedFieldCount -Sum).Sum ?? 0)
        FocusAssignmentCount = $focusAssignmentLines.Count
        FocusDistinctCount = $focusDistinct.Count
        FocusMappedCount = if ($focusStatus -ceq 'bound') { 1 } else { 0 }
        FocusMalformedCount = $focusMalformedCount
        FocusConflictCount = if ($focusDistinct.Count -gt 1) { $focusDistinct.Count } else { 0 }
    }
}

function Test-TabletAspectFourThree {
    param($CurrentSize)
    if ($null -eq $CurrentSize) { return $null }
    $short = [Math]::Min([double]$CurrentSize.width, [double]$CurrentSize.height)
    $long = [Math]::Max([double]$CurrentSize.width, [double]$CurrentSize.height)
    if ($short -le 0) { return $null }
    return [Math]::Abs(($long / $short) - (4.0 / 3.0)) -le 0.03
}

function Get-TabletP0Assessment {
    param(
        [AllowNull()]$SmallestWidthDp,
        [Parameter(Mandatory)][string]$Orientation,
        [AllowNull()]$IsFourThree,
        [AllowNull()]$Awake,
        [AllowNull()]$KeyguardLocked,
        [AllowNull()]$ZenMode,
        [AllowNull()][string]$TopPackage,
        [AllowNull()]$ForegroundObservation,
        [Parameter(Mandatory)]$WindowInventory,
        [Parameter(Mandatory)]$ImeState,
        $CurrentSize,
        [AllowNull()]$CaptureConsistent,
        [AllowNull()]$CaptureConsistencyObservation,
        [bool]$WmSizeOverridePresent = $false,
        [bool]$WmDensityOverridePresent = $false
    )
    $deviceClass = if ($null -eq $SmallestWidthDp) { 'unknown' }
        elseif ([int]$SmallestWidthDp -ge 600) { 'tablet' }
        else { 'phone' }
    $reasons = [Collections.Generic.List[string]]::new()
    if ($deviceClass -ne 'tablet') { $reasons.Add("device_class_$deviceClass") }
    if ($Orientation -ne 'landscape') { $reasons.Add("orientation_$Orientation") }
    if ($null -eq $IsFourThree) { $reasons.Add('aspect_unknown') }
    elseif ($IsFourThree) { $reasons.Add('aspect_4_3') }
    if ($null -eq $Awake) { $reasons.Add('screen_awake_unknown') }
    elseif (-not $Awake) { $reasons.Add('screen_not_awake') }
    if ($null -eq $KeyguardLocked) { $reasons.Add('keyguard_unknown') }
    elseif ($KeyguardLocked) { $reasons.Add('keyguard_locked') }
    if ($null -eq $ZenMode) { $reasons.Add('zen_unknown') }
    elseif ([int]$ZenMode -ne 0) { $reasons.Add('zen_not_zero') }
    if ($null -ne $ForegroundObservation) {
        $TopPackage = $ForegroundObservation.Package
        if ($ForegroundObservation.Status -ceq 'absent') { $reasons.Add('foreground_absent') }
        elseif ($ForegroundObservation.Status -cne 'known') { $reasons.Add('foreground_ambiguous') }
    }
    if ([string]::IsNullOrWhiteSpace($TopPackage)) { $reasons.Add('top_package_unknown') }
    elseif ($TopPackage -cne 'com.tencent.mm') { $reasons.Add('top_package_not_wechat') }
    if ($null -ne $CaptureConsistencyObservation) { $CaptureConsistent = $CaptureConsistencyObservation.Value }
    if ($null -eq $CaptureConsistent) { $reasons.Add('capture_consistency_unknown') }
    elseif (-not $CaptureConsistent) { $reasons.Add('capture_changed_during_collection') }
    if ($WmSizeOverridePresent) { $reasons.Add('wm_size_override_present') }
    if ($WmDensityOverridePresent) { $reasons.Add('wm_density_override_present') }
    if ($WindowInventory.ParseStatus -cne 'known' -or $null -eq $WindowInventory.Count) {
        $reasons.Add('application_windows_unknown')
    }
    elseif ([int]$WindowInventory.Count -ne 1) {
        $reasons.Add('application_window_count_not_one')
    }
    else {
        $only = @($WindowInventory.Windows | Where-Object {
            $_.Visibility -ceq 'strong_visible' -and $_.WindowType -ceq 'base_application'
        })[0]
        if ([string]::IsNullOrWhiteSpace([string]$only.owner_package) -or
            [string]::IsNullOrWhiteSpace($TopPackage)) {
            $reasons.Add('application_window_owner_unknown')
        }
        elseif ([string]$only.owner_package -cne $TopPackage) {
            $reasons.Add('application_window_owner_mismatch')
        }
        if ($null -eq $only.bounds -or @($only.bounds).Count -ne 4 -or $null -eq $CurrentSize) {
            $reasons.Add('application_window_bounds_unknown')
        }
        else {
            [int[]]$b = @($only.bounds)
            if ($b[0] -ne 0 -or $b[1] -ne 0 -or
                $b[2] -ne [int]$CurrentSize.width -or $b[3] -ne [int]$CurrentSize.height) {
                $reasons.Add('application_window_bounds_invalid')
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$only.windowing_mode)) {
            $reasons.Add('windowing_mode_unknown')
        }
        elseif ([string]$only.windowing_mode -cne 'fullscreen') {
            $reasons.Add("windowing_mode_$($only.windowing_mode)")
        }
        if ($only.IdentityStatus -cne 'known' -or [string]::IsNullOrWhiteSpace([string]$only.Identity)) {
            $reasons.Add('application_window_identity_unknown')
        }
        if ($only.DisplayStatus -cne 'known') { $reasons.Add('application_window_display_unknown') }
        elseif ([int]$only.DisplayId -ne 0) { $reasons.Add('application_window_not_default_display') }
        if ($WindowInventory.FocusStatus -cne 'bound' -or $null -eq $WindowInventory.FocusWindow) {
            $reasons.Add("focus_$($WindowInventory.FocusStatus)")
        }
        elseif ([string]$WindowInventory.FocusWindow.Identity -cne [string]$only.Identity) {
            $reasons.Add('focus_not_selected_base')
        }
        elseif ($WindowInventory.FocusWindow.WindowType -cne 'base_application') {
            $reasons.Add('focus_not_base_application')
        }
    }
    foreach ($diagnostic in @(
        @{ Value=$WindowInventory.VisibleOverlayCount; Reason='visible_application_overlay' },
        @{ Value=$WindowInventory.VisibleOtherApplicationCount; Reason='visible_other_application_window' },
        @{ Value=$WindowInventory.VisibleUnsafeOtherCount; Reason='visible_unsafe_other_window' },
        @{ Value=$WindowInventory.VisibleUnknownTypeCount; Reason='visible_window_type_unknown' },
        @{ Value=$WindowInventory.IdentityMissingCount; Reason='window_identity_missing' },
        @{ Value=$WindowInventory.IdentityConflictCount; Reason='window_identity_conflict' },
        @{ Value=$WindowInventory.DuplicateIdentityCount; Reason='window_identity_duplicate' },
        @{ Value=$WindowInventory.WeakVisibilityCount; Reason='window_visibility_weak_or_unknown' },
        @{ Value=$WindowInventory.VisibilityAmbiguousCount; Reason='window_visibility_ambiguous' },
        @{ Value=$WindowInventory.DisplayUnknownCount; Reason='window_display_unknown' },
        @{ Value=$WindowInventory.NonDefaultDisplayCount; Reason='non_default_display_window' }
        @{ Value=$WindowInventory.MalformedFieldCount; Reason='window_field_malformed' }
    )) {
        if ([int]$diagnostic.Value -gt 0) { $reasons.Add($diagnostic.Reason) }
    }
    if ($WindowInventory.ParseStatus -ceq 'known') {
        if ($WindowInventory.FocusStatus -in @('absent','ambiguous','unbound')) {
            $reasons.Add("focus_$($WindowInventory.FocusStatus)")
        }
        elseif ($WindowInventory.FocusStatus -ceq 'bound' -and $null -ne $WindowInventory.FocusWindow) {
            if ($WindowInventory.FocusWindow.WindowType -cne 'base_application') {
                $reasons.Add('focus_not_base_application')
            }
            if (-not [string]::IsNullOrWhiteSpace($TopPackage) -and
                [string]$WindowInventory.FocusWindow.owner_package -cne $TopPackage) {
                $reasons.Add('focus_owner_mismatch')
            }
        }
    }
    if ($null -eq $ImeState.Visible) { $reasons.Add('ime_visibility_unknown') }
    elseif ($ImeState.Visible) {
        if ($null -eq $ImeState.Floating) { $reasons.Add('floating_ime_unknown') }
        elseif ($ImeState.Floating) { $reasons.Add('floating_ime') }
    }
    $readinessReasons = @($reasons | Select-Object -Unique)
    $p0Reasons = @($readinessReasons + @(
        'wechat_layout_unverified',
        'tablet_landscape_p0_unimplemented'
    ))
    return [pscustomobject]@{
        DeviceClass = $deviceClass
        IntakeStatus = if ($deviceClass -eq 'tablet') { 'accepted' } elseif ($deviceClass -eq 'phone') { 'rejected' } else { 'inconclusive' }
        ReadinessStatus = if ($readinessReasons.Count -eq 0) { 'accepted' } else { 'blocked' }
        ReadinessReasons = $readinessReasons
        P0Status = 'unsupported'
        P0Reasons = $p0Reasons
    }
}

function Assert-TabletEvidencePathSafe {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Destination)
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $target = [IO.Path]::GetFullPath($Destination)
    if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw '证据输出路径越出仓库根目录。'
    }
    $cursor = [IO.Path]::GetDirectoryName($target)
    while ($cursor -and $cursor.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw '证据输出路径包含 reparse point，拒绝写入。'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
}

function Write-TabletProfileAtomic {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RunId
    )
    if ($RunId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') { throw 'run_id 不符合安全字符约束。' }
    $evidenceRoot = Join-Path $RepoRoot 'docs\runs\evidence'
    $runDir = Join-Path $evidenceRoot $RunId
    $destination = Join-Path $runDir 'tablet-profile.json'
    Assert-TabletEvidencePathSafe -RepoRoot $RepoRoot -Destination $destination
    if (Test-Path -LiteralPath $runDir) { throw 'run_id 已存在，拒绝覆盖既有证据。' }
    New-Item -ItemType Directory -Path $runDir | Out-Null
    Assert-TabletEvidencePathSafe -RepoRoot $RepoRoot -Destination $destination
    $temporary = Join-Path $runDir ('.tablet-profile.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $Profile | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $destination
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
    return $destination
}
