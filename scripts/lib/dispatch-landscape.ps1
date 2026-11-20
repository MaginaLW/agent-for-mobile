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

function Test-LandscapeRectangle {
    param($Box, $Within)
    if ($Box -isnot [array] -or $Box.Count -ne 4) { return $false }
    foreach ($v in $Box) {
        if (($v -isnot [long] -and $v -isnot [int]) -or $v -lt 0 -or $v -gt [int]::MaxValue) { return $false }
    }
    if ($Box[2] -le $Box[0] -or $Box[3] -le $Box[1]) { return $false }
    return $null -eq $Within -or ($Box[0] -ge $Within[0] -and $Box[1] -ge $Within[1] -and
        $Box[2] -le $Within[2] -and $Box[3] -le $Within[3])
}

function Test-LandscapeEditorReceipt {
    param([AllowEmptyCollection()][object[]]$Calls)

    # 动作会改变窗口或键盘。只采用最后一次动作之后的读数，拒绝复用点击前的焦点。
    $reads = @{}
    foreach ($call in $Calls) {
        if ($call.Server -cne 'gateway' -or $call.Outcome -cne 'success') { return $false }
        switch -CaseSensitive ($call.Name) {
            'foreground_app' { $reads.foreground = $call.ResultEnvelope }
            'keyboard_state' { $reads.keyboard = $call.ResultEnvelope }
            'ui_find' {
                if ($call.Input.scroll_search) { return $false }
                if ($call.Input.text -ceq '文件传输助手' -and -not $call.Input.role -and -not $call.Input.desc) { $reads.title = $call.ResultEnvelope }
                elseif ($call.Input.role -ceq 'input' -and -not $call.Input.text -and -not $call.Input.desc) { $reads.editor = $call.ResultEnvelope }
                else { return $false }
            }
            { $_ -cin @('app_launch', 'ui_action') } {
                if (($call.Name -ceq 'app_launch' -and $call.Input.name -cne 'com.tencent.mm') -or
                    ($call.Name -ceq 'ui_action' -and $call.Input.action -cne 'click')) { return $false }
                $reads.Clear()
            }
            default { return $false }
        }
    }
    if ($reads.Count -ne 4) { return $false }
    $foreground = $reads.foreground.data
    $title = $reads.title.data
    $editor = $reads.editor.data
    $keyboard = $reads.keyboard.data
    $revision = $foreground.revision
    if (($revision -isnot [long] -and $revision -isnot [int]) -or $revision -lt 0 -or
        $foreground.package -cne 'com.tencent.mm' -or $foreground.window_topology -cne 'same_app_multi' -or
        $foreground.foreground_known -isnot [bool] -or -not $foreground.foreground_known -or
        $keyboard.visible -isnot [bool] -or ($keyboard.height -isnot [int] -and $keyboard.height -isnot [long])) { return $false }
    $auditIds = [Collections.Generic.HashSet[string]]::new()
    foreach ($read in $reads.Values) {
        $ctx = $read.ctx
        if (($ctx.revision -isnot [long] -and $ctx.revision -isnot [int]) -or $ctx.revision -ne $revision -or
            $ctx.app -cne 'com.tencent.mm' -or $ctx.window_topology -cne 'same_app_multi' -or
            $ctx.foreground_known -isnot [bool] -or -not $ctx.foreground_known -or
            $ctx.keyboard.visible -isnot [bool] -or $ctx.keyboard.visible -ne $keyboard.visible -or
            $null -eq $ctx.keyboard.height -or $ctx.keyboard.height -ne $keyboard.height -or
            [string]::IsNullOrWhiteSpace($read.audit_id) -or -not $auditIds.Add($read.audit_id)) { return $false }
    }
    $screen = @(0, 0, $editor.screen_width, $editor.screen_height)
    if (-not (Test-LandscapeRectangle $screen) -or $screen[2] -le $screen[3] -or
        $title.screen_width -ne $screen[2] -or $title.screen_height -ne $screen[3]) { return $false }
    $apps = @($foreground.windows | Where-Object type -CEQ 'application')
    if ($apps.Count -ne 2) { return $false }
    foreach ($app in $apps) {
        if ($app.root_package -cne 'com.tencent.mm' -or ($app.id -isnot [int] -and $app.id -isnot [long]) -or
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
    foreach ($match in @($title.matches) + @($editor.matches)) {
        if ($match.pane -ceq 'left') { $pane = $left }
        elseif ($match.pane -ceq 'right') { $pane = $right }
        else { return $false }
        if ($null -eq $match.window_id -or $match.window_id -ne $pane.id -or
            -not (Test-LandscapeRectangle $match.bounds $pane.bounds)) { return $false }
    }
    $titles = @($title.matches | Where-Object { $_.pane -ceq 'right' -and $_.text -ceq '文件传输助手' })
    $inputs = @($editor.matches | Where-Object { $_.pane -ceq 'right' })
    if ($titles.Count -ne 1 -or $inputs.Count -ne 1) { return $false }
    $heading = $titles[0].bounds
    $inputNode = $inputs[0]
    $box = $inputNode.bounds
    $height = $usableBottom - $right.bounds[1]
    # 标题、编辑栏分别须完整落在可用右窗顶部/底部五分之一，编辑栏距底边至多一行。
    if (-not (Test-LandscapeRectangle $heading $screen) -or -not (Test-LandscapeRectangle $box $screen) -or
        $heading[3] -gt $right.bounds[1] + $height / 5 -or $box[1] -lt $usableBottom - $height / 5 -or
        $box[3] -gt $usableBottom -or $usableBottom - $box[3] -gt $box[3] - $box[1] -or
        $inputNode.role -cne 'input' -or $inputNode.source -cnotin @('a11y','fused') -or
        $inputNode.flags -cnotmatch 'E' -or $inputNode.flags -cnotmatch 'F' -or $inputNode.flags -cmatch 'x' -or
        -not (Test-LandscapeRectangle $editor.focused_input_bounds) -or
        ($editor.focused_input_bounds -join ',') -cne ($box -join ',')) { return $false }
    $identity = $editor.focused_input_id -split '\|'
    return $identity.Count -eq 5 -and $identity[0] -ceq [string]$id -and
        $identity[3] -ceq 'com.tencent.mm' -and $identity[4] -ceq ($box -join ',')
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
