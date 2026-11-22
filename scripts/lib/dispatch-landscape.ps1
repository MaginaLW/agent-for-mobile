#Requires -Version 7

# 设备选择、APK 与设置只在持有 dispatch 租约时读取。设置、序列号、窗口内容仅留在内存。
function Read-LandscapeBaseline {
    param($Device, [string]$AdbCommand)

    $baseline = [ordered]@{}
    foreach ($key in @('default_input_method', 'enabled_input_methods', 'enabled_accessibility_services', 'accessibility_enabled')) {
        $value = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','settings','--user','0','get','secure',$key) -Operation "读取 $key").Stdout.Trim()
        if ([string]::IsNullOrEmpty($value) -or $value -match '[\r\n]') { throw "无法核对 $key。" }
        $baseline[$key] = $value
    }
    $baseline.Service = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
    $forwards = (Invoke-P0DeviceCommand -Session $Device -Arguments @('forward','--list') -Operation '读取网关端口映射').Stdout
    $port = Get-GatewayPreflightPort
    $baseline.Forward = @($forwards -split '\r?\n' | Where-Object { $_ -match "^\S+\s+tcp:$port\s+" }) -join "`n"
    return $baseline
}

function Get-LandscapeStartBaseline {
    param($Device, [string]$AdbCommand, [string]$ExpectedGatewaySha256)
    . (Join-Path $PSScriptRoot 'p0-device-provision.ps1')

    if ((Get-P0SingleDevice -AdbPath $Device.AdbPath) -cne $Device.Serial) { throw '已连接设备与本轮授权序列号不符。' }
    $model = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','getprop','ro.product.model') -Operation '读取设备型号').Stdout.Trim()
    if ($model -cne 'PA2553') { throw '设备型号不匹配 PA2553。' }
    $user = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','am','get-current-user') -Operation '核对活动用户').Stdout.Trim()
    if ($user -cne '0') { throw '无法核实当前活动用户为测试用户 0。' }
    $policy = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','dumpsys','window','policy') -Operation '读取锁屏状态').Stdout
    foreach ($field in @('showing','inputRestricted')) {
        $values = [regex]::Matches($policy, "(?m)^[ \t]*${field}=([^\s]+)[ \t]*\r?$")
        if ($values.Count -ne 1 -or $values[0].Groups[1].Value -cne 'false') { throw '设备已锁屏或无法核实解锁状态。' }
    }
    $package = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','pm','path','dev.magina.gateway') -Operation '读取在机网关路径').Stdout.Trim()
    if ($package -cnotmatch '\Apackage:(/data/app/[a-zA-Z0-9_/=+~.-]+/base\.apk)\z') { throw '无法核实唯一的在机网关 base APK。' }
    $apk = $Matches[1]
    $digest = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','sha256sum',$apk) -Operation '核对在机网关摘要').Stdout.Trim()
    if ($digest -notmatch '\A([0-9a-f]{64})\s+' -or $Matches[1] -ine $ExpectedGatewaySha256) { throw '在机网关 APK SHA-256 与本轮候选不符。' }
    $baseline = Read-LandscapeBaseline -Device $Device -AdbCommand $AdbCommand
    if ($baseline.Service -notin @('absent', 'foreground')) { throw '网关服务基线不确定。' }
    return $baseline
}

function Test-LandscapeChatFocus {
    param([string]$Windows)
    # 同一个 dumpsys 的两行必须唯一。标题在右窗、包名相同或可见键盘均不能单独证明编辑目标。
    $focus = [regex]::Matches($Windows, '(?m)^[ \t]*mCurrentFocus=([^\r\n]*)')
    $ime = [regex]::Matches($Windows, '(?m)^[ \t]*imeInputTarget in display#\s*0\s+([^\r\n]*)')
    if ($focus.Count -ne 1 -or $ime.Count -ne 1) { return $false }
    $target = '^Window\{([\da-fA-F]+) u0 com\.tencent\.mm/(?:com\.tencent\.mm)?\.(?:[\w]+\.)*ChattingUI(?=[ }])'
    $focused = [regex]::Match($focus[0].Groups[1].Value, $target)
    $input = [regex]::Match($ime[0].Groups[1].Value, $target)
    return $focused.Success -and $input.Success -and $focused.Groups[1].Value -ceq $input.Groups[1].Value
}

function Get-LandscapeProperty {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-LandscapeJsonObject {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [Collections.IDictionary]) { return $true }
    return ($Value -is [psobject]) -and ($Value -isnot [array]) -and
        ($Value -isnot [string]) -and (-not $Value.GetType().IsValueType)
}

function Test-LandscapeInt {
    param([AllowNull()]$Value)
    return ($Value -is [int]) -or ($Value -is [long])
}

function Test-LandscapeFiniteNumber {
    param([AllowNull()]$Value)
    if ($Value -isnot [int] -and $Value -isnot [long] -and $Value -isnot [double] -and
        $Value -isnot [float] -and $Value -isnot [decimal]) { return $false }
    $num = [double]$Value
    return -not [double]::IsNaN($num) -and -not [double]::IsInfinity($num)
}

function Test-LandscapeRectangle {
    param($Box, $Within)
    if ($Box -isnot [array] -or $Box.Count -ne 4) { return $false }
    foreach ($v in $Box) {
        if (-not (Test-LandscapeInt $v) -or $v -lt 0 -or $v -gt [int]::MaxValue) { return $false }
    }
    if ($Box[2] -le $Box[0] -or $Box[3] -le $Box[1]) { return $false }
    return $null -eq $Within -or ($Box[0] -ge $Within[0] -and $Box[1] -ge $Within[1] -and
        $Box[2] -le $Within[2] -and $Box[3] -le $Within[3])
}

function ConvertTo-LandscapeAnchorBounds {
    param([AllowNull()]$BoundsObj, $RightBounds, $Screen)
    if (-not (Test-LandscapeJsonObject $BoundsObj)) { return $null }
    $l = Get-LandscapeProperty $BoundsObj 'left'
    $t = Get-LandscapeProperty $BoundsObj 'top'
    $r = Get-LandscapeProperty $BoundsObj 'right'
    $b = Get-LandscapeProperty $BoundsObj 'bottom'
    foreach ($v in @($l, $t, $r, $b)) {
        if (-not (Test-LandscapeFiniteNumber $v)) { return $null }
        $d = [double]$v
        if ($d -lt 0 -or $d -gt [int]::MaxValue) { return $null }
    }
    $dl = [double]$l; $dt = [double]$t; $dr = [double]$r; $db = [double]$b
    if ($dr -le $dl -or $db -le $dt) { return $null }
    if ($dl -lt $RightBounds[0] -or $dt -lt $RightBounds[1] -or
        $dr -gt $RightBounds[2] -or $db -gt $RightBounds[3] -or
        $dl -lt $Screen[0] -or $dt -lt $Screen[1] -or
        $dr -gt $Screen[2] -or $db -gt $Screen[3]) { return $null }
    # 与 Kotlin Float.roundToInt()（非负数 floor(x + 0.5)）保持一致。
    $box = @(
        [long][Math]::Floor($dl + 0.5),
        [long][Math]::Floor($dt + 0.5),
        [long][Math]::Floor($dr + 0.5),
        [long][Math]::Floor($db + 0.5)
    )
    if (-not (Test-LandscapeRectangle $box $RightBounds) -or -not (Test-LandscapeRectangle $box $Screen)) {
        return $null
    }
    return ,$box
}

function Test-LandscapePointInBox {
    param([AllowNull()]$X, [AllowNull()]$Y, $Box)
    if (-not (Test-LandscapeFiniteNumber $X) -or -not (Test-LandscapeFiniteNumber $Y)) { return $false }
    $dx = [double]$X; $dy = [double]$Y
    return $dx -ge $Box[0] -and $dx -le $Box[2] -and $dy -ge $Box[1] -and $dy -le $Box[3]
}

function Test-LandscapeInsertionMarker {
    param([AllowNull()]$Marker, $Box)
    if (-not (Test-LandscapeJsonObject $Marker)) { return $false }
    if ((Get-LandscapeProperty $Marker 'visibility') -cne 'visible') { return $false }
    $topX = Get-LandscapeProperty $Marker 'top_x'
    $topY = Get-LandscapeProperty $Marker 'top_y'
    $bottomX = Get-LandscapeProperty $Marker 'bottom_x'
    $bottomY = Get-LandscapeProperty $Marker 'bottom_y'
    if (-not (Test-LandscapePointInBox -X $topX -Y $topY -Box $Box) -or
        -not (Test-LandscapePointInBox -X $bottomX -Y $bottomY -Box $Box) -or
        [double]$topY -gt [double]$bottomY) { return $false }
    $baseX = Get-LandscapeProperty $Marker 'baseline_x'
    $baseY = Get-LandscapeProperty $Marker 'baseline_y'
    if (($null -eq $baseX) -xor ($null -eq $baseY)) { return $false }
    if ($null -ne $baseX -and -not (Test-LandscapePointInBox -X $baseX -Y $baseY -Box $Box)) {
        return $false
    }
    return $true
}

function Test-LandscapeEditorNotFoundEnvelope {
    param([AllowNull()]$Envelope)
    if (-not (Test-LandscapeJsonObject $Envelope)) { return $false }
    $ok = Get-LandscapeProperty $Envelope 'ok'
    if ($ok -isnot [bool] -or $ok) { return $false }
    if ($null -ne (Get-LandscapeProperty $Envelope 'data')) { return $false }
    $err = Get-LandscapeProperty $Envelope 'error'
    return (Test-LandscapeJsonObject $err) -and ((Get-LandscapeProperty $err 'code') -ceq 'E_NOT_FOUND')
}

function Test-LandscapeAnchorFocusMetadata {
    param($Data, $RightWindow, $Box)
    $source = Get-LandscapeProperty $Data 'focused_identity_source'
    $inputId = Get-LandscapeProperty $Data 'focused_input_id'
    $winId = Get-LandscapeProperty $Data 'focused_input_window_id'
    $pane = Get-LandscapeProperty $Data 'focused_input_pane'
    $bounds = Get-LandscapeProperty $Data 'focused_input_bounds'
    return $source -ceq 'ime_cursor_anchor' -and $null -eq $inputId -and
        (Test-LandscapeInt $winId) -and $winId -eq $RightWindow.id -and
        $pane -ceq 'right' -and (Test-LandscapeRectangle $bounds $RightWindow.bounds) -and
        ($bounds -join ',') -ceq ($Box -join ',')
}

function Test-LandscapeEditorReceipt {
    param([AllowEmptyCollection()][object[]]$Calls)

    # 动作会改变窗口或键盘。只采用最后一次动作之后的读数，拒绝复用点击前的焦点。
    $reads = @{}
    $keyboardCall = $null
    $editorNotFoundEnvelope = $null
    foreach ($call in $Calls) {
        if ($call.Server -cne 'gateway') { return $false }
        switch -CaseSensitive ($call.Name) {
            'foreground_app' {
                if ($call.Outcome -cne 'success') { return $false }
                $reads.foreground = $call.ResultEnvelope
            }
            'keyboard_state' {
                if ($call.Outcome -cne 'success') { return $false }
                $reads.keyboard = $call.ResultEnvelope
                $keyboardCall = $call
            }
            'ui_find' {
                if (Get-LandscapeProperty $call.Input 'scroll_search') { return $false }
                $inputText = Get-LandscapeProperty $call.Input 'text'
                $inputRole = Get-LandscapeProperty $call.Input 'role'
                $inputDesc = Get-LandscapeProperty $call.Input 'desc'
                if ($inputText -ceq '文件传输助手' -and -not $inputRole -and -not $inputDesc) {
                    if ($call.Outcome -cne 'success') { return $false }
                    $reads.title = $call.ResultEnvelope
                }
                elseif ($inputText -ceq '可按住转文字' -and -not $inputRole -and -not $inputDesc) {
                    if ($call.Outcome -cne 'success') { return $false }
                    $reads.hint = $call.ResultEnvelope
                }
                elseif ($inputRole -ceq 'input' -and -not $inputText -and -not $inputDesc) {
                    if ($call.Outcome -ceq 'success') {
                        $reads.editor = $call.ResultEnvelope
                        $editorNotFoundEnvelope = $null
                    }
                    elseif ($call.Outcome -ceq 'gateway-tool-failure' -and
                        (Test-LandscapeEditorNotFoundEnvelope $call.ResultEnvelope)) {
                        [void]$reads.Remove('editor')
                        $editorNotFoundEnvelope = $call.ResultEnvelope
                    }
                    else { return $false }
                }
                else { return $false }
            }
            { $_ -cin @('app_launch', 'ui_action') } {
                if ($call.Outcome -cne 'success' -or
                    ($call.Name -ceq 'app_launch' -and (Get-LandscapeProperty $call.Input 'name') -cne 'com.tencent.mm') -or
                    ($call.Name -ceq 'ui_action' -and (Get-LandscapeProperty $call.Input 'action') -cne 'click')) { return $false }
                $reads.Clear()
                $keyboardCall = $null
                $editorNotFoundEnvelope = $null
            }
            default { return $false }
        }
    }
    if (-not $reads.ContainsKey('foreground') -or -not $reads.ContainsKey('title') -or
        -not $reads.ContainsKey('keyboard')) { return $false }
    $hasEditorRead = $reads.ContainsKey('editor')
    $foreground = $reads.foreground.data
    $title = $reads.title.data
    $editor = if ($hasEditorRead) { $reads.editor.data } else { $null }
    $keyboard = $reads.keyboard.data
    $revision = $foreground.revision
    if (-not (Test-LandscapeInt $revision) -or $revision -lt 0 -or
        $foreground.package -cne 'com.tencent.mm' -or $foreground.window_topology -cne 'same_app_multi' -or
        $foreground.foreground_known -isnot [bool] -or -not $foreground.foreground_known -or
        $keyboard.visible -isnot [bool] -or -not (Test-LandscapeInt $keyboard.height)) { return $false }
    $envelopes = [Collections.Generic.List[object]]::new()
    foreach ($read in $reads.Values) { $envelopes.Add($read) }
    if ($null -ne $editorNotFoundEnvelope) { $envelopes.Add($editorNotFoundEnvelope) }
    $auditIds = [Collections.Generic.HashSet[string]]::new()
    foreach ($read in $envelopes) {
        $ctx = Get-LandscapeProperty $read 'ctx'
        $ctxRevision = Get-LandscapeProperty $ctx 'revision'
        $ctxKeyboard = Get-LandscapeProperty $ctx 'keyboard'
        $auditId = Get-LandscapeProperty $read 'audit_id'
        if (-not (Test-LandscapeInt $ctxRevision) -or $ctxRevision -ne $revision -or
            (Get-LandscapeProperty $ctx 'app') -cne 'com.tencent.mm' -or
            (Get-LandscapeProperty $ctx 'window_topology') -cne 'same_app_multi' -or
            (Get-LandscapeProperty $ctx 'foreground_known') -isnot [bool] -or
            -not (Get-LandscapeProperty $ctx 'foreground_known') -or
            (Get-LandscapeProperty $ctxKeyboard 'visible') -isnot [bool] -or
            (Get-LandscapeProperty $ctxKeyboard 'visible') -ne $keyboard.visible -or
            $null -eq (Get-LandscapeProperty $ctxKeyboard 'height') -or
            (Get-LandscapeProperty $ctxKeyboard 'height') -ne $keyboard.height -or
            [string]::IsNullOrWhiteSpace($auditId) -or -not $auditIds.Add($auditId)) { return $false }
    }
    $screen = @(0, 0, $title.screen_width, $title.screen_height)
    if (-not (Test-LandscapeRectangle $screen) -or $screen[2] -le $screen[3]) { return $false }
    if ($hasEditorRead -and ($editor.screen_width -ne $screen[2] -or $editor.screen_height -ne $screen[3])) {
        return $false
    }
    $apps = @($foreground.windows | Where-Object type -CEQ 'application')
    if ($apps.Count -ne 2) { return $false }
    foreach ($app in $apps) {
        if ($app.root_package -cne 'com.tencent.mm' -or -not (Test-LandscapeInt $app.id) -or
            $app.id -lt 0 -or $app.active -isnot [bool] -or $app.focused -isnot [bool] -or
            -not (Test-LandscapeRectangle $app.bounds)) { return $false }
    }
    $left, $right = $apps | Sort-Object { $_.bounds[0] }
    $id = $foreground.selected_window_id
    if ($null -eq $id -or $right.id -ne $id -or $left.id -eq $id -or $left.active -or $left.focused -or
        -not $right.active -or -not $right.focused -or $left.bounds[2] -gt $right.bounds[0] -or
        [Math]::Max($left.bounds[1],$right.bounds[1]) -ge [Math]::Min($left.bounds[3],$right.bounds[3])) { return $false }
    $usableBottom = [Math]::Min($right.bounds[3], $screen[3])
    $ime = @($foreground.windows | Where-Object type -CEQ 'input_method')
    if ($keyboard.visible) {
        if ($ime.Count -ne 1 -or -not (Test-LandscapeRectangle $ime[0].bounds)) { return $false }
        $k = $ime[0].bounds
        if ($k[3] - $k[1] -ne $keyboard.height -or $k[0] -gt $right.bounds[0] -or
            $k[2] -lt $right.bounds[2] -or $k[3] -lt $usableBottom -or $k[1] -ge $screen[3]) { return $false }
        $usableBottom = [Math]::Min($usableBottom, $k[1])
    }
    elseif ($ime.Count -ne 0 -or $keyboard.height -ne 0) { return $false }

    # 同名的左侧列表行可以存在。先独立核对匹配的窗格 ID 与完整矩形，再从右窗取唯一候选。
    $allMatches = @($title.matches)
    if ($hasEditorRead) { $allMatches += @($editor.matches) }
    foreach ($match in $allMatches) {
        if ($match.pane -ceq 'left') { $pane = $left }
        elseif ($match.pane -ceq 'right') { $pane = $right }
        else { return $false }
        if ($null -eq $match.window_id -or $match.window_id -ne $pane.id -or
            -not (Test-LandscapeRectangle $match.bounds $pane.bounds)) { return $false }
    }
    $titles = @($title.matches | Where-Object { $_.pane -ceq 'right' -and $_.text -ceq '文件传输助手' })
    if ($titles.Count -ne 1) { return $false }
    $heading = $titles[0].bounds
    $height = $usableBottom - $right.bounds[1]
    if (-not (Test-LandscapeRectangle $heading $screen) -or
        $heading[3] -gt $right.bounds[1] + $height / 5) { return $false }

    $inputs = @(if ($hasEditorRead) { $editor.matches | Where-Object { $_.pane -ceq 'right' } })
    if ($inputs.Count -gt 1) { return $false }

    # 分支 1：原生 a11y/fused 右窗唯一编辑框（保持原严格判据不变）。
    if ($inputs.Count -eq 1) {
        $inputNode = $inputs[0]
        $box = $inputNode.bounds
        # 编辑栏须完整落在可用右窗底部五分之一，且距底边至多一行。
        if (-not (Test-LandscapeRectangle $box $screen) -or
            $box[1] -lt $usableBottom - $height / 5 -or
            $box[3] -gt $usableBottom -or $usableBottom - $box[3] -gt $box[3] - $box[1] -or
            $inputNode.role -cne 'input' -or $inputNode.source -cnotin @('a11y','fused') -or
            $inputNode.flags -cnotmatch 'E' -or $inputNode.flags -cnotmatch 'F' -or $inputNode.flags -cmatch 'x' -or
            -not (Test-LandscapeRectangle $editor.focused_input_bounds) -or
            ($editor.focused_input_bounds -join ',') -cne ($box -join ',')) { return $false }
        $identity = $editor.focused_input_id -split '\|'
        return $identity.Count -eq 5 -and $identity[0] -ceq [string]$id -and
            $identity[3] -ceq 'com.tencent.mm' -and $identity[4] -ceq ($box -join ',')
    }

    # 分支 2：无原生右窗输入节点时，仅接纳 IME CursorAnchorInfo 经严格归属与交叉核验的右窗编辑栏。
    $probeArg = Get-LandscapeProperty $keyboardCall.Input 'probe_cursor_anchor'
    if ($probeArg -isnot [bool] -or -not $probeArg) { return $false }
    $anchor = Get-LandscapeProperty $keyboard 'ime_cursor_anchor'
    $anchorReason = Get-LandscapeProperty $keyboard 'ime_cursor_anchor_reason'
    if (-not (Test-LandscapeJsonObject $anchor) -or -not [string]::IsNullOrEmpty([string]$anchorReason)) {
        return $false
    }
    $contractDiag = Get-LandscapeProperty $keyboard 'ime_editor_contract_diag'
    if (-not (Test-LandscapeJsonObject $contractDiag)) { return $false }
    $contractPresent = Get-LandscapeProperty $contractDiag 'contract_present'
    $inputTypeIsNull = Get-LandscapeProperty $contractDiag 'input_type_is_null'
    if ($contractPresent -isnot [bool] -or -not $contractPresent -or
        $inputTypeIsNull -isnot [bool] -or $inputTypeIsNull) { return $false }

    $anchorPane = Get-LandscapeProperty $anchor 'pane'
    $anchorWindowId = Get-LandscapeProperty $anchor 'window_id'
    $anchorWindowBounds = Get-LandscapeProperty $anchor 'window_bounds'
    $samePkgCount = Get-LandscapeProperty $anchor 'same_package_window_count'
    $totalAppCount = Get-LandscapeProperty $anchor 'total_app_window_count'
    $matrixIsIdentity = Get-LandscapeProperty $anchor 'matrix_is_identity'
    $sessionId = Get-LandscapeProperty $anchor 'session_id'
    $sessionGen = Get-LandscapeProperty $anchor 'session_generation'
    $requestMode = Get-LandscapeProperty $anchor 'request_mode'
    if ($anchorPane -cne 'right' -or -not (Test-LandscapeInt $anchorWindowId) -or $anchorWindowId -ne $right.id -or
        -not (Test-LandscapeRectangle $anchorWindowBounds) -or
        ($anchorWindowBounds -join ',') -cne ($right.bounds -join ',') -or
        -not (Test-LandscapeInt $samePkgCount) -or $samePkgCount -ne 2 -or
        -not (Test-LandscapeInt $totalAppCount) -or $totalAppCount -ne 2 -or
        $matrixIsIdentity -isnot [bool] -or $matrixIsIdentity -or
        $sessionId -isnot [string] -or [string]::IsNullOrWhiteSpace($sessionId) -or
        -not (Test-LandscapeInt $sessionGen) -or $sessionGen -lt 1 -or
        $requestMode -isnot [string] -or [string]::IsNullOrWhiteSpace($requestMode)) { return $false }

    $box = ConvertTo-LandscapeAnchorBounds -BoundsObj (Get-LandscapeProperty $anchor 'editor_bounds') `
        -RightBounds $right.bounds -Screen $screen
    if ($null -eq $box) { return $false }
    if ($box[1] -lt $usableBottom - $height / 5 -or $box[3] -gt $usableBottom -or
        $usableBottom - $box[3] -gt $box[3] - $box[1]) { return $false }

    $marker = Get-LandscapeProperty $anchor 'insertion_marker'
    if ($null -ne $marker -and -not (Test-LandscapeInsertionMarker -Marker $marker -Box $box)) {
        return $false
    }
    if (-not (Test-LandscapeAnchorFocusMetadata -Data $title -RightWindow $right -Box $box)) {
        return $false
    }
    if ($hasEditorRead -and -not (Test-LandscapeAnchorFocusMetadata -Data $editor -RightWindow $right -Box $box)) {
        return $false
    }
    return $true
}

function Complete-LandscapePreparation {
    param($Device, [string]$AdbCommand, $Baseline, $PreflightState, [switch]$RequireChatFocus)
    . (Join-Path $PSScriptRoot 'p0-device-provision.ps1')
    $problems = @()
    try { Stop-GatewayPreflightOwnedResources -State $PreflightState -AdbCommand $AdbCommand }
    catch { $problems += '网关预检资源清理失败' }
    try {
        $current = Read-LandscapeBaseline -Device $Device -AdbCommand $AdbCommand
        # Android 的停止回执可能先于 ServiceRecord 消失。只重读状态，不再发停止命令。
        if ($Baseline.Service -eq 'absent' -and $current.Service -ne 'absent') {
            foreach ($sample in 1..3) {
                Start-Sleep -Milliseconds 350
                $previous = $current.Service
                $current.Service = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
                if ($current.Service -eq 'absent' -or ($previous -eq 'unknown' -and $current.Service -eq 'unknown')) { break }
            }
        }
        foreach ($key in $Baseline.Keys) {
            if ($Baseline[$key] -cne $current[$key]) { $problems += "基线变化 $key" }
        }
    }
    catch { $problems += $_.Exception.Message }
    if ($RequireChatFocus) {
        try {
            $windows = (Invoke-P0DeviceCommand -Session $Device -Arguments @('shell','dumpsys','window') -Operation '复核会话输入目标').Stdout
            if (-not (Test-LandscapeChatFocus $windows)) { $problems += '系统焦点与输入法目标未同时绑定同一微信 ChattingUI 窗口' }
        }
        catch { $problems += $_.Exception.Message }
    }
    return ($problems -join ' / ')
}
