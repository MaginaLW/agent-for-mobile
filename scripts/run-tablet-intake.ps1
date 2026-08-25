#Requires -Version 7
<#
T0 Android 平板只读 intake。

本入口只建立脱敏设备画像，不安装 APK、不启动 App、不输入、不修改 settings，也不连接 gateway。
所有 adb 子命令由 scripts/lib/tablet-intake.ps1 内的固定查询表生成，调用者不能注入任意命令。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AdbPath,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$')][string]$RunId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$LibraryPath = Join-Path $PSScriptRoot 'lib\tablet-intake.ps1'

try {
    if (-not [IO.Path]::IsPathFullyQualified($AdbPath)) { throw '-AdbPath 必须是绝对路径。' }
    $AdbPath = [IO.Path]::GetFullPath($AdbPath)
    if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { throw '-AdbPath 指向的文件不存在。' }
    if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) { throw '缺少 tablet intake 只读库。' }
    . $LibraryPath

    function ConvertTo-TabletForegroundProfile {
        param([Parameter(Mandatory)]$Observation)
        return [ordered]@{
            status = $Observation.Status
            source = $Observation.Source
            package = $Observation.Package
            activity = $Observation.Activity
            top_resumed = [ordered]@{
                assignment_count = $Observation.TopResumed.AssignmentCount
                valid_count = $Observation.TopResumed.ValidCount
                absent_count = $Observation.TopResumed.AbsentCount
                malformed_count = $Observation.TopResumed.MalformedCount
                conflict_count = $Observation.TopResumed.ConflictCount
            }
            resumed_fallback = [ordered]@{
                assignment_count = $Observation.ResumedFallback.AssignmentCount
                valid_count = $Observation.ResumedFallback.ValidCount
                absent_count = $Observation.ResumedFallback.AbsentCount
                malformed_count = $Observation.ResumedFallback.MalformedCount
                conflict_count = $Observation.ResumedFallback.ConflictCount
            }
        }
    }

    function ConvertTo-TabletRotationProfile {
        param([Parameter(Mandatory)]$Observation)
        return [ordered]@{
            status = $Observation.Status
            source = $Observation.Source
            value = $Observation.Value
            assignment_count = $Observation.AssignmentCount
            valid_count = $Observation.ValidCount
            malformed_count = $Observation.MalformedCount
            conflict_count = $Observation.ConflictCount
            default_scoped_count = $Observation.DefaultScopedCount
            unscoped_count = $Observation.UnscopedCount
            non_default_count = $Observation.NonDefaultCount
        }
    }

    function New-TabletWindowLabelMap {
        param([Parameter(Mandatory)]$InitialInventory, [Parameter(Mandatory)]$FinalInventory)
        $identitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($inventory in @($InitialInventory,$FinalInventory)) {
            $allWindowsProperty = $inventory.PSObject.Properties['AllWindows']
            $allWindows = if ($null -eq $allWindowsProperty) { @($inventory.Windows) } else { @($allWindowsProperty.Value) }
            foreach ($window in $allWindows) {
                if ($window.IdentityStatus -ceq 'known' -and
                    -not [string]::IsNullOrWhiteSpace([string]$window.Identity)) {
                    [void]$identitySet.Add([string]$window.Identity)
                }
            }
        }
        [string[]]$identities = @($identitySet)
        [Array]::Sort($identities, [StringComparer]::Ordinal)
        $labels = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($identity in $identities) { $labels.Add($identity, "w$($labels.Count)") }
        return $labels
    }

    function ConvertTo-TabletWindowProfile {
        param(
            [Parameter(Mandatory)]$Inventory,
            [Parameter(Mandatory)]$Foreground,
            [Parameter(Mandatory)]$LabelMap,
            [Parameter(Mandatory)][ValidateSet('initial','final')][string]$FrameName
        )
        $allWindowsProperty = $Inventory.PSObject.Properties['AllWindows']
        $allWindows = if ($null -eq $allWindowsProperty) { @($Inventory.Windows) } else { @($allWindowsProperty.Value) }
        $profiles = [Collections.Generic.List[object]]::new()
        foreach ($window in $allWindows) {
            $hasReliableIdentity = $window.IdentityStatus -ceq 'known' -and
                -not [string]::IsNullOrWhiteSpace([string]$window.Identity) -and
                $LabelMap.ContainsKey([string]$window.Identity)
            $windowLabel = if ($hasReliableIdentity) { $LabelMap[[string]$window.Identity] }
                else { "m_${FrameName}_$($window.index)" }
            $ownerMatches = if ([string]::IsNullOrWhiteSpace([string]$window.owner_package) -or
                $Foreground.Status -cne 'known') { $null }
                else { [string]$window.owner_package -ceq [string]$Foreground.Package }
            $focused = if ($Inventory.FocusStatus -cne 'bound' -or
                [string]::IsNullOrWhiteSpace([string]$window.Identity)) { $false }
                else { [string]$window.Identity -ceq [string]$Inventory.FocusIdentity }
            $profiles.Add([ordered]@{
                window_label = $windowLabel
                identity_status = $window.IdentityStatus
                display_status = $window.DisplayStatus
                display_id = $window.DisplayId
                type = $window.WindowType
                visibility = $window.Visibility
                bounds = $window.bounds
                windowing_mode = $window.windowing_mode
                owner_matches_foreground = $ownerMatches
                focused = $focused
            })
        }
        $focusLabel = $null
        if ($Inventory.FocusStatus -ceq 'bound' -and $null -ne $Inventory.FocusWindow) {
            $focusKey = [string]$Inventory.FocusWindow.Identity
            if ($LabelMap.ContainsKey($focusKey)) { $focusLabel = $LabelMap[$focusKey] }
        }
        return [ordered]@{
            parse_status = $Inventory.ParseStatus
            block_count = $Inventory.BlockCount
            application_window_count = $Inventory.Count
            strong_visible_count = $Inventory.StrongVisibleCount
            weak_visibility_count = $Inventory.WeakVisibilityCount
            visible_overlay_count = $Inventory.VisibleOverlayCount
            visible_other_application_count = $Inventory.VisibleOtherApplicationCount
            visible_unknown_type_count = $Inventory.VisibleUnknownTypeCount
            visible_ime_count = $Inventory.VisibleImeCount
            visible_system_window_count = $Inventory.VisibleSystemWindowCount
            visible_unsafe_other_count = $Inventory.VisibleUnsafeOtherCount
            identity_missing_count = $Inventory.IdentityMissingCount
            identity_conflict_count = $Inventory.IdentityConflictCount
            duplicate_identity_count = $Inventory.DuplicateIdentityCount
            display_unknown_count = $Inventory.DisplayUnknownCount
            non_default_display_count = $Inventory.NonDefaultDisplayCount
            visibility_ambiguous_count = $Inventory.VisibilityAmbiguousCount
            malformed_field_count = $Inventory.MalformedFieldCount
            focus = [ordered]@{
                status = $Inventory.FocusStatus
                assignment_count = $Inventory.FocusAssignmentCount
                distinct_count = $Inventory.FocusDistinctCount
                mapped_count = $Inventory.FocusMappedCount
                malformed_count = $Inventory.FocusMalformedCount
                conflict_count = $Inventory.FocusConflictCount
                window_label = $focusLabel
                type = if ($null -eq $Inventory.FocusWindow) { 'unknown' } else { $Inventory.FocusWindow.WindowType }
                owner_matches_foreground = if ($null -eq $Inventory.FocusWindow -or
                    $Foreground.Status -cne 'known' -or
                    [string]::IsNullOrWhiteSpace([string]$Inventory.FocusWindow.owner_package)) { $null }
                    else { [string]$Inventory.FocusWindow.owner_package -ceq [string]$Foreground.Package }
            }
            windows = @($profiles)
        }
    }

    function ConvertTo-TabletCaptureFrameProfile {
        param(
            [Parameter(Mandatory)]$Foreground,
            [Parameter(Mandatory)]$Rotation,
            [Parameter(Mandatory)]$CurrentSize,
            [Parameter(Mandatory)]$Windows,
            [Parameter(Mandatory)]$StateObservation,
            [Parameter(Mandatory)]$LabelMap,
            [Parameter(Mandatory)][ValidateSet('initial','final')][string]$FrameName
        )
        return [ordered]@{
            foreground = ConvertTo-TabletForegroundProfile $Foreground
            rotation = ConvertTo-TabletRotationProfile $Rotation
            current_size = [ordered]@{
                status = $CurrentSize.Status
                source = $CurrentSize.Source
                wm_size_source = $CurrentSize.WmSizeSource
                value = $CurrentSize.Value
                reason_codes = @($CurrentSize.ReasonCodes)
            }
            windows = ConvertTo-TabletWindowProfile -Inventory $Windows -Foreground $Foreground `
                -LabelMap $LabelMap -FrameName $FrameName
            state = [ordered]@{
                screen_awake = $StateObservation.Awake
                keyguard_locked = $StateObservation.KeyguardLocked
                zen_mode = $StateObservation.ZenMode
                input_method = [ordered]@{
                    session_active = $StateObservation.ImeState.SessionShown
                    visible = $StateObservation.ImeState.Visible
                    floating = $StateObservation.ImeState.Floating
                    bounds = $StateObservation.ImeState.Bounds
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    }

    $devicesText = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name devices -Serial $null
    $serial = Get-TabletSingleDevice -DevicesText $devicesText
    $serialHash = Get-TabletSha256Text $serial

    $raw = @{}
    foreach ($name in @(
        'prop_brand', 'prop_manufacturer', 'prop_model', 'prop_product', 'prop_device',
        'prop_android_release', 'prop_api', 'prop_abi', 'prop_fingerprint',
        'wm_size', 'wm_density', 'activity', 'window', 'display', 'power', 'policy',
        'zen', 'default_ime', 'input_method', 'am_config'
    )) {
        $raw[$name] = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name $name -Serial $serial
    }

    $size = ConvertFrom-TabletWmSize $raw.wm_size
    $density = ConvertFrom-TabletWmDensity $raw.wm_density
    $windows = ConvertFrom-TabletWindowInventory $raw.window
    $top = Get-TabletForegroundObservation -ActivityText $raw.activity
    $rotationObservation = Get-TabletRotationObservation -DisplayText $raw.display -WindowText $raw.window
    $rotation = $rotationObservation.Value
    $currentSizeObservation = Get-TabletCurrentSizeObservation -PhysicalSize $size.Physical `
        -OverrideSize $size.Override -RotationStatus $rotationObservation.Status -Rotation $rotation `
        -WindowInventory $windows -TopPackage $top.Package -ForegroundObservation $top `
        -PhysicalSizeStatus $size.PhysicalStatus `
        -OverrideSizeStatus $size.OverrideStatus
    $currentSize = $currentSizeObservation.Value
    $orientation = Get-TabletOrientation $currentSize
    $activitySmallestWidthObservation = Get-TabletSmallestWidthDpObservation $raw.activity
    $amSmallestWidthObservation = Get-TabletAmConfigSmallestWidthDpObservation $raw.am_config
    $smallestWidthObservation = Resolve-TabletSmallestWidthDpObservation `
        -AmConfigObservation $amSmallestWidthObservation -ActivityObservation $activitySmallestWidthObservation
    $smallestWidthDp = $smallestWidthObservation.Value
    $smallestWidthSource = $smallestWidthObservation.Source
    $awake = ConvertFrom-TabletAwake $raw.power
    $keyguard = ConvertFrom-TabletKeyguardLocked $raw.policy
    $zen = ConvertFrom-TabletZenMode $raw.zen
    $ime = ConvertFrom-TabletImeState $raw.input_method
    $fourThree = Test-TabletAspectFourThree $currentSize

    # 采集末端重读 wm/display/top/windows；期间发生几何或前台变化时 readiness fail-closed。
    $finalActivity = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name activity -Serial $serial
    $finalWindow = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name window -Serial $serial
    $finalDisplay = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name display -Serial $serial
    $finalWmSize = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name wm_size -Serial $serial
    $finalWmDensity = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name wm_density -Serial $serial
    $finalAmConfig = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name am_config -Serial $serial
    $finalPower = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name power -Serial $serial
    $finalPolicy = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name policy -Serial $serial
    $finalZen = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name zen -Serial $serial
    $finalInputMethod = Invoke-TabletAdbQuery -AdbPath $AdbPath -Name input_method -Serial $serial
    $finalSize = ConvertFrom-TabletWmSize $finalWmSize
    $finalDensity = ConvertFrom-TabletWmDensity $finalWmDensity
    $finalRotationObservation = Get-TabletRotationObservation -DisplayText $finalDisplay -WindowText $finalWindow
    $finalRotation = $finalRotationObservation.Value
    $finalTop = Get-TabletForegroundObservation -ActivityText $finalActivity
    $finalWindows = ConvertFrom-TabletWindowInventory $finalWindow
    $finalCurrentSizeObservation = Get-TabletCurrentSizeObservation -PhysicalSize $finalSize.Physical `
        -OverrideSize $finalSize.Override -RotationStatus $finalRotationObservation.Status `
        -Rotation $finalRotation -WindowInventory $finalWindows -TopPackage $finalTop.Package `
        -ForegroundObservation $finalTop `
        -PhysicalSizeStatus $finalSize.PhysicalStatus -OverrideSizeStatus $finalSize.OverrideStatus
    $finalCurrentSize = $finalCurrentSizeObservation.Value
    $finalActivitySmallestWidthObservation = Get-TabletSmallestWidthDpObservation $finalActivity
    $finalAmSmallestWidthObservation = Get-TabletAmConfigSmallestWidthDpObservation $finalAmConfig
    $finalSmallestWidthObservation = Resolve-TabletSmallestWidthDpObservation `
        -AmConfigObservation $finalAmSmallestWidthObservation `
        -ActivityObservation $finalActivitySmallestWidthObservation
    $finalSmallestWidthDp = $finalSmallestWidthObservation.Value
    $finalSmallestWidthSource = $finalSmallestWidthObservation.Source
    $effectiveDensityObservation = Get-TabletEffectiveWmDensityObservation $density
    $finalEffectiveDensityObservation = Get-TabletEffectiveWmDensityObservation $finalDensity
    $initialStateObservation = [pscustomobject]@{
        Awake=$awake; KeyguardLocked=$keyguard; ZenMode=$zen; ImeState=$ime
    }
    $finalStateObservation = [pscustomobject]@{
        Awake=(ConvertFrom-TabletAwake $finalPower)
        KeyguardLocked=(ConvertFrom-TabletKeyguardLocked $finalPolicy)
        ZenMode=(ConvertFrom-TabletZenMode $finalZen)
        ImeState=(ConvertFrom-TabletImeState $finalInputMethod)
    }
    $captureObservation = Get-TabletCaptureConsistencyObservation `
        -InitialRotationObservation $rotationObservation -FinalRotationObservation $finalRotationObservation `
        -InitialForegroundObservation $top -FinalForegroundObservation $finalTop `
        -InitialWindows $windows -FinalWindows $finalWindows `
        -InitialCurrentSizeObservation $currentSizeObservation `
        -FinalCurrentSizeObservation $finalCurrentSizeObservation `
        -InitialSmallestWidthObservation $smallestWidthObservation `
        -FinalSmallestWidthObservation $finalSmallestWidthObservation `
        -InitialDensityObservation $effectiveDensityObservation `
        -FinalDensityObservation $finalEffectiveDensityObservation `
        -InitialStateObservation $initialStateObservation -FinalStateObservation $finalStateObservation
    $captureConsistent = $captureObservation.Value
    $assessment = Get-TabletP0Assessment -SmallestWidthDp $smallestWidthDp `
        -Orientation $orientation -IsFourThree $fourThree -Awake $awake `
        -KeyguardLocked $keyguard -ZenMode $zen -TopPackage $top.Package -ForegroundObservation $top `
        -WindowInventory $windows -ImeState $ime -CurrentSize $currentSize `
        -CaptureConsistent $captureConsistent -CaptureConsistencyObservation $captureObservation `
        -WmSizeOverridePresent ($size.OverrideStatus -cne 'absent' -or $finalSize.OverrideStatus -cne 'absent') `
        -WmDensityOverridePresent ($density.OverrideStatus -cne 'absent' -or $finalDensity.OverrideStatus -cne 'absent')

    $windowLabelMap = New-TabletWindowLabelMap -InitialInventory $windows -FinalInventory $finalWindows

    $fingerprint = Get-TabletSingleLineValue $raw.prop_fingerprint 500
    $profile = [ordered]@{
        schema_version = 5
        run_id = $RunId
        captured_at_utc = [DateTime]::UtcNow.ToString('o')
        device = [ordered]@{
            serial_hash = $serialHash
            brand = Get-TabletSingleLineValue $raw.prop_brand
            manufacturer = Get-TabletSingleLineValue $raw.prop_manufacturer
            model = Get-TabletSingleLineValue $raw.prop_model
            product = Get-TabletSingleLineValue $raw.prop_product
            device = Get-TabletSingleLineValue $raw.prop_device
            android_release = Get-TabletSingleLineValue $raw.prop_android_release
            api_level = ConvertFrom-TabletApiLevel $raw.prop_api
            abi = @((Get-TabletSingleLineValue $raw.prop_abi) -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            fingerprint_hash = if ($null -eq $fingerprint) { $null } else { Get-TabletSha256Text $fingerprint }
        }
        display = [ordered]@{
            physical_size = $size.Physical
            override_size = $size.Override
            current_size = $currentSize
            physical_density_dpi = $density.Physical
            override_density_dpi = $density.Override
            smallest_width_dp = $smallestWidthDp
            smallest_width_dp_status = $smallestWidthObservation.Status
            smallest_width_dp_source = $smallestWidthSource
            rotation = $rotation
            rotation_status = $rotationObservation.Status
            rotation_source = $rotationObservation.Source
            orientation = $orientation
            current_size_source = $currentSizeObservation.Source
            aspect_4_3 = $fourThree
        }
        state = [ordered]@{
            screen_awake = $awake
            keyguard_locked = $keyguard
            zen_mode = $zen
            default_ime = Get-TabletSingleLineValue $raw.default_ime
        }
        observations = [ordered]@{
            initial = ConvertTo-TabletCaptureFrameProfile -Foreground $top -Rotation $rotationObservation `
                -CurrentSize $currentSizeObservation -Windows $windows -StateObservation $initialStateObservation `
                -LabelMap $windowLabelMap -FrameName initial
            final = ConvertTo-TabletCaptureFrameProfile -Foreground $finalTop -Rotation $finalRotationObservation `
                -CurrentSize $finalCurrentSizeObservation -Windows $finalWindows -StateObservation $finalStateObservation `
                -LabelMap $windowLabelMap -FrameName final
        }
        input_method = [ordered]@{
            session_active = $ime.SessionShown
            visible = $ime.Visible
            floating = $ime.Floating
            bounds = $ime.Bounds
        }
        assessment = [ordered]@{
            tablet_threshold_dp = 600
            readiness_orientation_baseline = 'landscape'
            device_class = $assessment.DeviceClass
            intake_status = $assessment.IntakeStatus
            capture_consistent = $captureConsistent
            capture_consistency_status = $captureObservation.Status
            capture_consistency_reasons = @($captureObservation.ReasonCodes)
            readiness_status = $assessment.ReadinessStatus
            readiness_block_reasons = @($assessment.ReadinessReasons)
            p0_capability = $assessment.P0Status
            p0_unsupported_reasons = @($assessment.P0Reasons)
        }
    }

    $profilePath = Write-TabletProfileAtomic -Profile $profile -RepoRoot $RepoRoot -RunId $RunId
    Write-Host "tablet intake 已落盘：$profilePath"
    Write-Host "device_class=$($assessment.DeviceClass) p0_capability=$($assessment.P0Status)"
    if ($assessment.P0Reasons.Count -gt 0) {
        Write-Host "p0_unsupported_reasons=$($assessment.P0Reasons -join ',')"
    }
    if ($assessment.DeviceClass -eq 'phone') { exit 2 }
    if ($assessment.DeviceClass -eq 'unknown') { exit 3 }
    exit 0
}
catch {
    [Console]::Error.WriteLine("tablet intake 失败：$($_.Exception.Message)")
    exit 1
}
