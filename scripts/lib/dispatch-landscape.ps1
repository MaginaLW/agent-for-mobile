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

function Test-LandscapeEditorReceipt {
    param([AllowEmptyCollection()][object[]]$Calls)

    # 动作会改变窗口或键盘。只采用最后一次动作之后的读数，拒绝复用点击前的焦点。
    $foreground = $null
    $title = $null
    $editor = $null
    $keyboard = $null
    foreach ($call in $Calls) {
        if ($call.Server -cne 'gateway' -or $call.Outcome -cne 'success') { return $false }
        $data = $call.ResultEnvelope.data
        switch -CaseSensitive ($call.Name) {
            'foreground_app' { $foreground = $data }
            'keyboard_state' { $keyboard = $data }
            'ui_find' {
                if ($call.Input.scroll_search) { return $false }
                if ($call.Input.text -ceq '文件传输助手') { $title = $data }
                elseif ($call.Input.role -ceq 'input') { $editor = $data }
                else { return $false }
            }
            { $_ -cin @('app_launch', 'ui_action') } {
                if (($call.Name -ceq 'app_launch' -and $call.Input.name -cne 'com.tencent.mm') -or
                    ($call.Name -ceq 'ui_action' -and $call.Input.action -cne 'click')) { return $false }
                $foreground = $title = $editor = $keyboard = $null
            }
            default { return $false }
        }
    }
    if ($foreground.package -cne 'com.tencent.mm' -or $foreground.window_topology -cne 'same_app_multi' -or
        $foreground.foreground_known -ne $true -or $keyboard.visible -isnot [bool] -or
        [string]::IsNullOrWhiteSpace($editor.focused_input_id)) { return $false }

    $id = $foreground.selected_window_id
    $active = @($foreground.windows | Where-Object {
        $_.id -eq $id -and $_.type -ceq 'application' -and $_.active -and $_.focused
    })
    $titles = @($title.matches | Where-Object {
        $_.pane -ceq 'right' -and $_.window_id -eq $id -and $_.text -ceq '文件传输助手'
    })
    $inputs = @($editor.matches | Where-Object {
        $_.pane -ceq 'right' -and $_.window_id -eq $id -and $_.role -ceq 'input' -and
        $_.source -cin @('a11y', 'fused') -and $_.flags -cmatch 'E' -and $_.flags -cnotmatch 'x'
    })
    if ($null -eq $id -or $active.Count -ne 1 -or $titles.Count -ne 1 -or $inputs.Count -ne 1 -or
        $titles[0].bounds.Count -ne 4) { return $false }
    $box = $inputs[0].bounds
    return $inputs[0].flags -cmatch 'F' -and $box.Count -eq 4 -and
        $box[0] -lt $box[2] -and $box[1] -lt $box[3] -and
        $box[1] -ge $titles[0].bounds[3] -and ($box -join ',') -ceq ($editor.focused_input_bounds -join ',')
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
