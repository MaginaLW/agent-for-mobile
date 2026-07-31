#Requires -Version 7

Set-StrictMode -Version 3.0

$script:P0PackageName = 'dev.magina.gateway'
$script:P0AccessibilityComponent = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
# vivo 的 dumpsys accessibility 绑定区段只显示 Service[label=...]，不含组件名；label 与 manifest application label 同源。
$script:P0AccessibilityLabel = '执行网关'
$script:P0ImeComponent = 'dev.magina.gateway/.ime.GatewayIme'
$script:P0WechatPackage = 'com.tencent.mm'
$script:P0Port = 8848

function New-P0StartInfo {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($FilePath).Equals('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $start.FileName = (Get-Process -Id $PID).Path
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-File')
        $start.ArgumentList.Add($FilePath)
    }
    else {
        $start.FileName = $FilePath
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # stdin 重定向后由调用方立刻关掉，让子进程读到 EOF 而不是继承父进程的 stdin。
    # 本 harness 的常态就是非交互（dispatch 被 agent 拉起、CI、重定向），继承一个永远不给
    # EOF 的句柄，任何顺手读 stdin 的子进程都会挂到超时。这是防御性的，不针对某个已知故障。
    $start.RedirectStandardInput = $true
    return $start
}

function Invoke-P0ExternalText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$AllowFailure,
        [int]$TimeoutSec = 30
    )

    $start = New-P0StartInfo -FilePath $FilePath -Arguments $Arguments
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "$Operation 失败。" }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw "$Operation 超时。"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) { throw "$Operation 失败。" }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout }
    }
    catch {
        if ($_.Exception.Message -in @("$Operation 失败。", "$Operation 超时。")) { throw }
        throw "$Operation 失败。"
    }
    finally { $process.Dispose() }
}

function Invoke-P0ExternalToFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$AllowFailure,
        [int]$TimeoutSec = 30
    )

    $start = New-P0StartInfo -FilePath $FilePath -Arguments $Arguments
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "$Operation 失败。" }
        $process.StandardInput.Close()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::Open($Destination, 'Create', 'Write', 'None')
        try {
            $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($stream)
            if (-not $process.WaitForExit($TimeoutSec * 1000)) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
                throw "$Operation 超时。"
            }
            [void]$copyTask.GetAwaiter().GetResult()
        }
        finally { $stream.Dispose() }
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "$Operation 失败。"
        }
    }
    catch {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        if ($_.Exception.Message -in @("$Operation 失败。", "$Operation 超时。")) { throw }
        throw "$Operation 失败。"
    }
    finally { $process.Dispose() }
}

function Invoke-P0AdbText {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$AllowFailure,
        [int]$TimeoutSec = 30
    )
    Invoke-P0ExternalText -FilePath $AdbPath -Arguments $Arguments -Operation $Operation -AllowFailure:$AllowFailure -TimeoutSec $TimeoutSec
}

function Get-P0SingleDevice {
    param([Parameter(Mandatory)][string]$AdbPath)

    $result = Invoke-P0AdbText -AdbPath $AdbPath -Arguments @('devices') -Operation '设备发现'
    $devices = @($result.Stdout -split "`r?`n" | ForEach-Object {
        if ($_ -match '^([^\s]+)\s+device$') { $Matches[1] }
    })
    if ($devices.Count -ne 1) { throw "setup-fail：要求恰好一台已授权 adb 设备，实际 $($devices.Count) 台。" }
    return $devices[0]
}

function Invoke-P0DeviceCommand {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$AllowFailure,
        [int]$TimeoutSec = 30
    )
    Invoke-P0AdbText -AdbPath $Session.AdbPath -Arguments (@('-s', $Session.Serial) + $Arguments) `
        -Operation $Operation -AllowFailure:$AllowFailure -TimeoutSec $TimeoutSec
}

function Move-P0PrivateFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
}

function Remove-P0PrivateTemporaryFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}

function Add-P0SessionCleanupIssue {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Issue)
    if (-not $Session.CleanupIssues.Contains($Issue)) { $Session.CleanupIssues.Add($Issue) }
}

function Remove-P0SessionCleanupIssue {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Issue)
    [void]$Session.CleanupIssues.Remove($Issue)
}

function Set-P0GatewayConfigToken {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Token
    )

    if ($Token -notmatch '^[A-Za-z0-9._-]{8,256}$') { throw '私密配置同步失败。' }
    $configPath = [string]$Session.ConfigPath
    $config = [ordered]@{
        mcpServers = [ordered]@{
            gateway = [ordered]@{
                type = 'http'
                url = 'http://127.0.0.1:8848/mcp'
                headers = [ordered]@{ Authorization = "Bearer $Token" }
            }
        }
    }
    $directory = Split-Path $configPath -Parent
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = Join-Path $directory ('.gateway-mcp.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $operationFailed = $false
    $cleanupFailed = $false
    if (-not $Session.PrivateTemporaryFiles.Contains($temporary)) { $Session.PrivateTemporaryFiles.Add($temporary) }
    try {
        $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporary -Encoding utf8 -ErrorAction Stop
        Move-P0PrivateFileAtomic -Source $temporary -Destination $configPath
        [void]$Session.PrivateTemporaryFiles.Remove($temporary)
    }
    catch { $operationFailed = $true }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            try {
                Remove-P0PrivateTemporaryFile -Path $temporary
                [void]$Session.PrivateTemporaryFiles.Remove($temporary)
            }
            catch {
                $cleanupFailed = $true
                Add-P0SessionCleanupIssue -Session $Session -Issue 'private_config_temp'
            }
        } else {
            [void]$Session.PrivateTemporaryFiles.Remove($temporary)
        }
    }
    if ($operationFailed -or $cleanupFailed) { throw '私密配置同步失败。' }
}

function Read-P0GatewayConfigToken {
    param([Parameter(Mandatory)][string]$ConfigPath)
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $gateway = $config.mcpServers.gateway
        $authorization = [string]$gateway.headers.Authorization
        $match = [regex]::Match(
            $authorization,
            '^Bearer\s+(?<token>[A-Za-z0-9._-]{8,256})$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if ($gateway.type -cne 'http' -or $gateway.url -cne 'http://127.0.0.1:8848/mcp' -or
            -not $match.Success -or $authorization.Contains('<GATEWAY_TOKEN>', [StringComparison]::Ordinal)) {
            return $null
        }
        return $match.Groups['token'].Value
    }
    catch { return $null }
}

function Test-P0GatewayConfig {
    param([Parameter(Mandatory)][string]$ConfigPath)
    return -not [string]::IsNullOrWhiteSpace((Read-P0GatewayConfigToken -ConfigPath $ConfigPath))
}

function Get-P0BoundAccessibilitySection {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DumpsysText)

    $lines = @($DumpsysText -split "`r?`n")
    $sections = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -notmatch '(?i)^(?<indent>\s*)(?:m)?bound\s*services?\s*[:=](?<inline>.*)$') { continue }
        $headerIndent = $Matches['indent'].Length
        $section = [Collections.Generic.List[string]]::new()
        $inline = [string]$Matches['inline']
        if (-not [string]::IsNullOrWhiteSpace($inline)) { $section.Add($inline.Trim()) }
        for ($child = $index + 1; $child -lt $lines.Count; $child++) {
            $candidate = $lines[$child]
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                if ($section.Count -gt 0) { break }
                continue
            }
            $leading = $candidate.Length - $candidate.TrimStart().Length
            if ($leading -le $headerIndent) { break }
            $section.Add($candidate.Trim())
        }
        $sections.Add(($section -join "`n"))
    }
    return @($sections)
}

function Test-P0AccessibilityComponentBound {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DumpsysText,
        [Parameter(Mandatory)][string]$Component,
        [string]$Label = ''
    )

    $separator = $Component.IndexOf('/')
    if ($separator -lt 1) { return $false }
    $packageName = $Component.Substring(0, $separator)
    $className = $Component.Substring($separator + 1)
    $shortComponent = if ($className.StartsWith("$packageName.", [StringComparison]::Ordinal)) {
        "$packageName/.$($className.Substring($packageName.Length + 1))"
    } else { $Component }
    foreach ($section in @(Get-P0BoundAccessibilitySection -DumpsysText $DumpsysText)) {
        if ($section.Contains($Component, [StringComparison]::Ordinal) -or
            $section.Contains($shortComponent, [StringComparison]::Ordinal)) {
            return $true
        }
        # vivo 绑定区段为 label-only（Service[label=执行网关, ...]）；组件精确性由 Enabled services 检查另行保证。
        if (-not [string]::IsNullOrEmpty($Label) -and
            ($section.Contains("label=$Label,", [StringComparison]::Ordinal) -or
                $section.Contains("label=$Label]", [StringComparison]::Ordinal))) {
            return $true
        }
    }
    return $false
}

function Read-P0PrivateToken {
    param([Parameter(Mandatory)]$Session)

    try {
        $result = Invoke-P0DeviceCommand -Session $Session `
            -Arguments @('exec-out', 'run-as', $script:P0PackageName, 'cat', 'shared_prefs/gateway.xml') `
            -Operation '私密配置同步'
        [xml]$xml = $result.Stdout
        $node = $xml.SelectSingleNode('/map/string[@name="token"]')
        $token = [string]$node.InnerText
        if ($token -notmatch '^[A-Za-z0-9._-]{8,256}$') { throw 'invalid' }
        return $token
    }
    catch { throw '私密配置同步失败。' }
}

function Start-P0DeviceProvision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AdbPath,
        [switch]$Provision,
        [string]$ApkPath = (Join-Path $RepoRoot 'app\gateway\build\outputs\apk\debug\gateway-debug.apk'),
        [string]$HealthProbePath = (Join-Path $PSScriptRoot 'p0-gateway-health-probe.ps1'),
        [int]$A11yBindTimeoutSec = 45
    )

    $configPath = Join-Path $RepoRoot 'configs\gateway-mcp.json'
    $configExisted = Test-Path -LiteralPath $configPath -PathType Leaf
    $originalConfig = if ($configExisted) { [IO.File]::ReadAllBytes($configPath) } else { $null }
    $serial = Get-P0SingleDevice -AdbPath $AdbPath
    $debugCleanupPending = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in @('control_file','confirmation_state','claimed_control','confirmation_screenshot')) {
        [void]$debugCleanupPending.Add($name)
    }
    $session = [pscustomobject]@{
        RepoRoot = $RepoRoot
        AdbPath = $AdbPath
        Serial = $serial
        OriginalIme = ''
        ConfigPath = $configPath
        ConfigExisted = $configExisted
        OriginalConfig = $originalConfig
        ConfigRestorePending = $false
        PortForwarded = $false
        DebugCleanupPending = $debugCleanupPending
        RemoteControlStaging = [Collections.Generic.List[string]]::new()
        PrivateTemporaryFiles = [Collections.Generic.List[string]]::new()
        CleanupIssues = [Collections.Generic.List[string]]::new()
        SensitiveValues = [Collections.Generic.List[string]]::new()
    }

    try {
        $session.OriginalIme = (Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','settings','get','secure','default_input_method') -Operation '读取原输入法').Stdout.Trim()

        if ($Provision) {
            if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "setup-fail：缺少 debug APK：$ApkPath" }
            $null = Invoke-P0DeviceCommand -Session $session -Arguments @('install','-r',$ApkPath) -Operation '安装 debug APK' -TimeoutSec 120
            foreach ($permission in @(
                'android.permission.POST_NOTIFICATIONS',
                'android.permission.BLUETOOTH_CONNECT',
                'android.permission.READ_MEDIA_IMAGES'
            )) {
                $null = Invoke-P0DeviceCommand -Session $session `
                    -Arguments @('shell','pm','grant',$script:P0PackageName,$permission) `
                    -Operation '授予标准运行权限'
            }
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','appops','set',$script:P0PackageName,'SYSTEM_ALERT_WINDOW','allow') `
                -Operation '授予悬浮窗能力'

            $enabled = (Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','settings','get','secure','enabled_accessibility_services') `
                -Operation '读取无障碍配置').Stdout.Trim()
            if ($enabled -eq 'null') { $enabled = '' }
            $services = @($enabled -split ':' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($script:P0AccessibilityComponent -notin $services) { $services += $script:P0AccessibilityComponent }
            # 值不变的 settings put 不触发 AMS observer，重装后只能等慢速回补重绑（vivo 实测 60-90s）；
            # 先写一个必然不同的值（去掉本服务，空则 delete）再写全量，强制立即重绑。
            $withoutGateway = @($services | Where-Object { $_ -ne $script:P0AccessibilityComponent })
            if ($withoutGateway.Count -gt 0) {
                $null = Invoke-P0DeviceCommand -Session $session `
                    -Arguments @('shell','settings','put','secure','enabled_accessibility_services',($withoutGateway -join ':')) `
                    -Operation '重置无障碍配置以触发重绑'
            } else {
                $null = Invoke-P0DeviceCommand -Session $session `
                    -Arguments @('shell','settings','delete','secure','enabled_accessibility_services') `
                    -Operation '重置无障碍配置以触发重绑' -AllowFailure
            }
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','settings','put','secure','enabled_accessibility_services',($services -join ':')) `
                -Operation '启用 gateway 无障碍'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','settings','put','secure','accessibility_enabled','1') `
                -Operation '启用无障碍总开关'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','ime','enable',$script:P0ImeComponent) -Operation '启用 gateway 输入法'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','ime','set',$script:P0ImeComponent) -Operation '切换 gateway 输入法'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','am','start','-n',"$script:P0PackageName/.MainActivity") -Operation '启动 gateway 面板'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','run-as',$script:P0PackageName,'am','start-foreground-service','--user','0','-n',"$script:P0PackageName/.GatewayService") `
                -Operation '启动 gateway 服务'
            $null = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','dumpsys','deviceidle','whitelist',"+$script:P0PackageName") `
                -Operation '加入 deviceidle 白名单'

            $privateToken = Read-P0PrivateToken -Session $session
            try {
                [void]$session.SensitiveValues.Add($privateToken)
                $session.ConfigRestorePending = $true
                Set-P0GatewayConfigToken -Session $session -Token $privateToken
            }
            finally { $privateToken = $null }
        }
        else {
            $configuredToken = Read-P0GatewayConfigToken -ConfigPath $configPath
            if ([string]::IsNullOrWhiteSpace($configuredToken)) {
                throw 'setup-fail：gateway MCP 私密配置无效；请由 agent 使用 -Provision 同步。'
            }
            [void]$session.SensitiveValues.Add($configuredToken)
            $configuredToken = $null
        }

        $null = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('forward',"tcp:$script:P0Port","tcp:$script:P0Port") -Operation '建立 gateway 端口转发'
        $session.PortForwarded = $true

        foreach ($package in @($script:P0PackageName, $script:P0WechatPackage)) {
            $probe = Invoke-P0DeviceCommand -Session $session -Arguments @('shell','pm','path',$package) -Operation '检查测试 App' -AllowFailure
            if ($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Stdout)) { throw "setup-fail：设备缺少 $package。" }
        }
        $gatewayPidProbe = Invoke-P0DeviceCommand -Session $session -Arguments @('shell','pidof',$script:P0PackageName) -Operation '检查 gateway 进程' -AllowFailure
        if ($gatewayPidProbe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($gatewayPidProbe.Stdout)) { throw 'setup-fail：gateway 进程未运行。' }
        $serviceProbe = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','dumpsys','activity','services',$script:P0PackageName) `
            -Operation '复核 gateway 前台服务' -AllowFailure
        if ($serviceProbe.ExitCode -ne 0 -or
            $serviceProbe.Stdout -notmatch 'GatewayService' -or
            $serviceProbe.Stdout -notmatch '(?i)(isForeground|foreground)\s*[=:]\s*true') {
            throw 'setup-fail：gateway 前台服务未实际运行。'
        }
        $a11yProbe = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','settings','get','secure','enabled_accessibility_services') `
            -Operation '复核 gateway 无障碍' -AllowFailure
        $enabledAfter = @($a11yProbe.Stdout.Trim() -split ':' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($a11yProbe.ExitCode -ne 0 -or $script:P0AccessibilityComponent -notin $enabledAfter) {
            throw 'setup-fail：gateway 无障碍未就绪。'
        }
        # 重装 APK 后系统重绑无障碍服务需要数秒到数十秒（vivo 实测），单次探测必然竞态，按上限轮询。
        $a11yBound = $false
        $a11yBindDeadline = [DateTime]::UtcNow.AddSeconds($A11yBindTimeoutSec)
        while ($true) {
            $a11yBoundProbe = Invoke-P0DeviceCommand -Session $session `
                -Arguments @('shell','dumpsys','accessibility') -Operation '复核无障碍绑定状态' -AllowFailure
            if ($a11yBoundProbe.ExitCode -eq 0 -and
                (Test-P0AccessibilityComponentBound -DumpsysText $a11yBoundProbe.Stdout `
                    -Component $script:P0AccessibilityComponent -Label $script:P0AccessibilityLabel)) {
                $a11yBound = $true
                break
            }
            if ([DateTime]::UtcNow -ge $a11yBindDeadline) { break }
            Start-Sleep -Milliseconds 1000
        }
        if (-not $a11yBound) {
            throw 'setup-fail：gateway 无障碍服务未实际 bound/connected。'
        }
        $imeProbe = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','settings','get','secure','default_input_method') `
            -Operation '复核 gateway 输入法' -AllowFailure
        if ($imeProbe.ExitCode -ne 0 -or $imeProbe.Stdout.Trim() -cne $script:P0ImeComponent) {
            throw 'setup-fail：gateway 输入法未成为默认输入法。'
        }
        $overlay = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','appops','get',$script:P0PackageName,'SYSTEM_ALERT_WINDOW') -Operation '复核悬浮窗能力' -AllowFailure
        if ($overlay.ExitCode -ne 0 -or $overlay.Stdout -notmatch '(?i)allow') { throw 'setup-fail：悬浮窗能力未就绪。' }
        $idleProbe = Invoke-P0DeviceCommand -Session $session `
            -Arguments @('shell','dumpsys','deviceidle','whitelist') -Operation '复核 deviceidle 白名单' -AllowFailure
        if ($idleProbe.ExitCode -ne 0 -or $idleProbe.Stdout -notmatch [regex]::Escape($script:P0PackageName)) {
            throw 'setup-fail：gateway 不在 deviceidle 白名单。'
        }
        if (-not (Test-Path -LiteralPath $HealthProbePath -PathType Leaf)) { throw 'setup-fail：缺少本地 gateway 健康探针。' }
        $health = Invoke-P0ExternalText -FilePath $HealthProbePath `
            -Arguments @('-ConfigPath',$configPath,'-Port',"$script:P0Port") `
            -Operation 'gateway 本地 TCP/MCP 协议健康探测' -AllowFailure -TimeoutSec 10
        if ($health.ExitCode -ne 0) { throw 'setup-fail：gateway 本地端口或 MCP 协议未就绪。' }
        try { $healthJson = $health.Stdout | ConvertFrom-Json } catch { throw 'setup-fail：gateway 健康探针响应无效。' }
        if ($healthJson.ok -ne $true -or [string]$healthJson.protocol -cne 'mcp-ping') {
            throw 'setup-fail：gateway 健康探针未确认 MCP ping。'
        }
        return $session
    }
    catch {
        $setupException = $_.Exception
        $setupCleanupIssues = @()
        try { $setupCleanupIssues = @(Stop-P0DeviceProvision -Session $session) }
        catch { $setupCleanupIssues = @('device_provision_cleanup') }
        if ($setupCleanupIssues.Count -gt 0) {
            $setupException.Data['P0CleanupIssues'] = ($setupCleanupIssues -join ',')
        }
        $session.SensitiveValues.Clear()
        throw $setupException
    }
}

function Test-P0TargetAppForeground {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    # 只读探测；探测本身失败或结果不明确时返回 $false（退回原行为：调用方仍会 am start），
    # 不能因为探测失败而误判"已在前台"进而跳过启动。
    $probe = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('shell','dumpsys','activity','activities') `
        -Operation '查询当前前台 Activity' -AllowFailure
    if ($probe.ExitCode -ne 0) { return $false }
    $pkg = [regex]::Escape($script:P0WechatPackage)
    return [bool]($probe.Stdout -match "(?:mResumedActivity|topResumedActivity)\s*[:=].*\b$pkg/")
}

function Start-P0TargetApp {
    param([Parameter(Mandatory)]$Session)
    # 微信已在前台时不重新 am start：runbook §3.0 要求用户预先手动导航到「文件传输助手」
    # 会话页（必要时预聚焦输入框），盲目 relaunch 会清掉这个人工建立的状态——画面可能不变，
    # 但输入焦点/IME 连接会丢（2026-07-24 真机实锤：连续多腿在 focus_probe_validation 撞同一堵
    # 墙，与用户是否刚点过输入框无关，直到确认画面未被冲掉才定位到是这里）。只有微信确实不在
    # 前台（例如被系统清理）时才需要拉起它。
    if (Test-P0TargetAppForeground -Session $Session) { return }
    # 目标 Android 版本的 shell am start 对隐式 -a MAIN -c LAUNCHER -p <pkg> 解析失败
    # （"unable to resolve"；--include-stopped-packages 同样无效，2026-07-23 真机实锤），
    # 必须先动态解出真实 launcher 组件，再用 -n 显式启动。
    $resolveProbe = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('shell','cmd','package','resolve-activity','--brief','-c','android.intent.category.LAUNCHER',$script:P0WechatPackage) `
        -Operation '解析微信启动组件' -AllowFailure
    $component = @($resolveProbe.Stdout -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match "^$([regex]::Escape($script:P0WechatPackage))/\S+$" } |
        Select-Object -Last 1)
    if ($resolveProbe.ExitCode -ne 0 -or $component.Count -ne 1) {
        throw 'setup-fail：无法解析微信启动组件。'
    }
    $null = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('shell','am','start','-n',[string]$component[0]) `
        -Operation '启动微信测试目标'
}

# ---------- 腿末 teardown（走 runner 自己的 adb 通道，不经执行器、不进 trace） ----------

<#
为什么 runner 可以在这里碰屏幕，而腿内不行：
腿内「工具不碰微信」是为了不让**被测组件自己**制造它要证明的前置状态；teardown 跑在本腿
判定完成、证据全部落盘之后，改不了任何已成定论的结论，性质与 Deny 腿的带外截屏一致
（不经执行器、不进 trace、不消耗 token）。腿内业务动作仍然只能经 dispatch → gateway MCP。

**顺序铁律：任何带外取证都必须排在 teardown 之前。** 被拦下的腿留在输入框里的 marker
正是"消息没发出去"的正证据，先清框就等于先毁证。
#>

# KEYCODE_MOVE_END / KEYCODE_DEL / KEYCODE_BACK
$script:P0KeyMoveEnd = 123
$script:P0KeyDelete = 67
$script:P0KeyBack = 4

<#
从 `dumpsys input_method` 读输入法窗口状态。两个字段必须分开看，合并会出人命：

- `mInputShown`：输入法**会话**在不在。
- `mImeWindowVis` 的 `IME_VISIBLE`(0x2) 位：输入法窗口**可不可见**。

本仓自有 IME 是零 UI 的（`GatewayIme.onEvaluateInputViewShown()=false`），跑测期间它就是当前
输入法——**会话在、但没有可见键盘**是常态。而 `InputMethodService` 只在 `isInputViewShown()`
为真时才吃掉 BACK：此时按 BACK 不会"收键盘"，会被微信当成返回键直接退出会话页，把下一腿的
前置条件毁掉。所以按 BACK 的判据只能是 visible，绝不能是 shown。

任一字段读不出来一律回 $null（**不是 $false**）：调用方必须能区分"确定没有"与"读不出来"。
#>
function Get-P0ImeWindowState {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $shown = $null
    $visible = $null
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $shownMatch = [regex]::Match($Text, 'mInputShown\s*=\s*(true|false)')
        if ($shownMatch.Success) { $shown = ($shownMatch.Groups[1].Value -ceq 'true') }
        $visMatch = [regex]::Match($Text, 'mImeWindowVis\s*=\s*(?:0x([0-9a-fA-F]+)|(\d+))')
        if ($visMatch.Success) {
            $bits = if ($visMatch.Groups[1].Success) {
                [Convert]::ToInt32($visMatch.Groups[1].Value, 16)
            } else {
                [int]$visMatch.Groups[2].Value
            }
            $visible = (($bits -band 0x2) -ne 0)
        }
    }
    return [pscustomobject]@{ shown = $shown; visible = $visible }
}

<#
teardown 的成功判据复用零 token 只读预检，不另立一套——它本来就是下一腿的前置条件。

三态而非布尔（同发送后验 sent/not_sent/unverified）：把"验不了"记成"清干净了"是本仓踩过的
原型错误。而 `dirty` 与 `unverified` 的分界要卡在**证据方向**上，不是卡在退出码上：

- `empty=false` 是"框里还有字"的**正证据**，teardown 没做到自己那份活 → dirty（记 cleanup issue）。
- `empty=true, probe_ready=false` 意味着框已经清了，探针不放行是别的原因（停错页、OCR 抖动、
  输入法窗口）。把它也算 dirty，等于让一次 OCR 抖动把三腿全绿的跑测判成失败——那正是本仓
  最忌讳的假信号。归 unverified：喊一句，交给下一腿带完整重试的预检去当闸门。
#>
function Get-P0TeardownVerdict {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Stdout
    )
    $detail = ([string]$Stdout).Trim()
    if ($ExitCode -eq 0) { return [pscustomobject]@{ verdict = 'clean'; detail = '' } }
    if ($ExitCode -eq 2) {
        $empty = $null
        if ($detail) {
            try {
                $payload = $detail | ConvertFrom-Json
                $property = $payload.PSObject.Properties['empty']
                if ($null -ne $property) { $empty = [bool]$property.Value }
            }
            catch { $empty = $null }
        }
        if ($empty -eq $false) { return [pscustomobject]@{ verdict = 'dirty'; detail = $detail } }
        return [pscustomobject]@{ verdict = 'unverified'; detail = $detail }
    }
    return [pscustomobject]@{ verdict = 'unverified'; detail = $detail }
}

<#
腿末收尾：清空微信输入框、收起键盘，并用只读预检核对结果。

清框用「光标移到末尾 + 定量退格」而不是 Ctrl+A：`input keyevent` 不支持 metastate，
全选只能靠 `input keycombination`（版本与实现都不稳）。退格数按本腿实际提交的文本长度
加余量，并有硬上限——写死一个大数会在焦点不在输入框时把退格发到别处。

**从不抛异常**：本腿的判定已经做完，收尾失败不该把一次有效结论作废；但也绝不静默——
结果进 manifest，`dirty` 另计一条 cleanup issue。
#>
function Invoke-P0LegTeardown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$TypedLength,
        [AllowEmptyString()][string]$PrecheckPath = '',
        [int]$ExtraDeleteKeys = 8,
        [int]$MaxDeleteKeys = 64,
        [int]$MaxBackPresses = 2
    )

    $issues = [Collections.Generic.List[string]]::new()
    $deleteKeys = [Math]::Min($MaxDeleteKeys, [Math]::Max(1, $TypedLength) + $ExtraDeleteKeys)
    $keyboard = 'unknown'

    try {
        $null = Invoke-P0DeviceCommand -Session $Session `
            -Arguments @('shell','input','keyevent',"$script:P0KeyMoveEnd") `
            -Operation '腿末光标移到输入框末尾' -AllowFailure
        $deleteArgs = @('shell','input','keyevent') + @(1..$deleteKeys | ForEach-Object { "$script:P0KeyDelete" })
        $delete = Invoke-P0DeviceCommand -Session $Session -Arguments $deleteArgs `
            -Operation '腿末清空输入框' -AllowFailure -TimeoutSec 60
        if ($delete.ExitCode -ne 0) { $issues.Add('teardown_clear_keys') }

        for ($press = 0; $press -le $MaxBackPresses; $press++) {
            $probe = Invoke-P0DeviceCommand -Session $Session -Arguments @('shell','dumpsys','input_method') `
                -Operation '腿末查询输入法窗口状态' -AllowFailure
            $state = if ($probe.ExitCode -eq 0) {
                Get-P0ImeWindowState -Text $probe.Stdout
            } else {
                [pscustomobject]@{ shown = $null; visible = $null }
            }
            if ($null -eq $state.visible) {
                # 读不出可见性就**不按 BACK**：宁可把键盘留给下一腿的预检拦下，
                # 也不冒"BACK 被微信当返回键、直接退出会话页"的险。
                $keyboard = 'unknown'
                $issues.Add('teardown_ime_state_unknown')
                break
            }
            if (-not $state.visible) {
                # 会话在、窗口不可见，正是零 UI IME 的常态：没有键盘可收，也没什么可做。
                $keyboard = if ($state.shown -eq $true) { 'session_only' }
                    elseif ($press -eq 0) { 'already_hidden' }
                    else { 'hidden' }
                break
            }
            if ($press -eq $MaxBackPresses) {
                $keyboard = 'still_visible'
                $issues.Add('teardown_ime_still_visible')
                break
            }
            $null = Invoke-P0DeviceCommand -Session $Session `
                -Arguments @('shell','input','keyevent',"$script:P0KeyBack") `
                -Operation '腿末收起键盘' -AllowFailure
        }
    }
    catch {
        $issues.Add('teardown_adb_failed')
    }

    $verdict = 'unverified'
    $detail = '未提供只读预检，无法核对收尾结果'
    if (-not [string]::IsNullOrWhiteSpace($PrecheckPath) -and (Test-Path -LiteralPath $PrecheckPath -PathType Leaf)) {
        try {
            $check = Invoke-P0ExternalText -FilePath $PrecheckPath `
                -Arguments @('-ConfigPath', $Session.ConfigPath, '-NotReadyRetries', '5', '-NotReadyRetryDelayMs', '1500') `
                -Operation '腿末收尾核对' -AllowFailure -TimeoutSec 60
            $resolved = Get-P0TeardownVerdict -ExitCode $check.ExitCode -Stdout ([string]$check.Stdout)
            $verdict = $resolved.verdict
            $detail = $resolved.detail
        }
        catch {
            $verdict = 'unverified'
            $detail = '收尾核对调用失败'
        }
    }
    # 只有"框里还有字"这一条进 cleanup（会把整轮判失败）：它是 teardown 自己那份活的
    # 正证据，且不受设备差异影响。键盘与 dumpsys 字段这两类是新路径、依赖机型输出格式，
    # 让它们能把三腿全绿的跑测判失败风险太大——下一腿的预检本来就是它们的硬闸门。
    $cleanupIssues = [Collections.Generic.List[string]]::new()
    if ($verdict -eq 'dirty') {
        $issues.Add('device_leg_teardown')
        $cleanupIssues.Add('device_leg_teardown')
    }

    return [pscustomobject]@{
        verdict = $verdict
        detail = $detail
        keyboard = $keyboard
        delete_keys = $deleteKeys
        issues = @($issues | Select-Object -Unique)
        cleanup_issues = @($cleanupIssues)
    }
}

function Set-P0PrivateControlFile {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Control
    )

    $required = @('run_id','leg','nonce','expires_at_ms','tool','action','initial_package','stale_after_allow')
    $actualKeySignature = (@($Control.Keys | ForEach-Object { [string]$_ } | Sort-Object) -join ',')
    $requiredKeySignature = (@($required | Sort-Object) -join ',')
    if ($actualKeySignature -cne $requiredKeySignature) {
        throw '测试控制字段集合不匹配。'
    }
    if ($Control.ContainsKey('decision')) { throw '测试控制文件禁止包含确认决定。' }
    # deny 腿与 allow 一样不制造上下文变化（stale_after_allow=false）；
    # 它与 allow 的区别只在真人按了哪个按钮，而那个决定 runner 与 debug hook 都写不进来。
    if ($Control.leg -notin @('allow','stale','deny') -or $Control.tool -cne 'press_key' -or
        $Control.action -cne 'enter' -or $Control.initial_package -cne $script:P0WechatPackage -or
        [bool]$Control.stale_after_allow -ne ($Control.leg -ceq 'stale')) {
        throw '测试控制值不在固定白名单。'
    }

    foreach ($name in @('control_file','confirmation_state','claimed_control','confirmation_screenshot')) {
        [void]$Session.DebugCleanupPending.Add($name)
    }

    $temporary = Join-Path ([IO.Path]::GetTempPath()) ("p0-control-$($Control.nonce).json")
    $remote = "/data/local/tmp/p0-control-$($Control.nonce).json"
    $remoteCleanupFailed = $false
    if (-not $Session.RemoteControlStaging.Contains($remote)) { $Session.RemoteControlStaging.Add($remote) }
    try {
        $Control | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding utf8
        $null = Invoke-P0DeviceCommand -Session $Session -Arguments @('push',$temporary,$remote) -Operation '上传测试控制文件'
        $null = Invoke-P0DeviceCommand -Session $Session `
            -Arguments @('shell','run-as',$script:P0PackageName,'cp',$remote,'files/test-control.json') `
            -Operation '武装监督式测试'
        $null = Invoke-P0DeviceCommand -Session $Session `
            -Arguments @('shell','run-as',$script:P0PackageName,'chmod','600','files/test-control.json') `
            -Operation '收紧测试控制权限'
    }
    finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        try {
            $remoteCleanup = Invoke-P0DeviceCommand -Session $Session -Arguments @('shell','rm','-f',$remote) `
                -Operation '清理控制中转文件' -AllowFailure
            if ($remoteCleanup.ExitCode -eq 0) {
                [void]$Session.RemoteControlStaging.Remove($remote)
                if ($Session.RemoteControlStaging.Count -eq 0) {
                    Remove-P0SessionCleanupIssue -Session $Session -Issue 'device_control_staging'
                }
            } else { $remoteCleanupFailed = $true }
        }
        catch { $remoteCleanupFailed = $true }
        if ($remoteCleanupFailed -and -not $Session.CleanupIssues.Contains('device_control_staging')) {
            $Session.CleanupIssues.Add('device_control_staging')
        }
    }
    if ($remoteCleanupFailed) { throw '清理控制中转文件失败。' }
}

function Get-P0ConfirmationState {
    param([Parameter(Mandatory)]$Session)
    $result = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('exec-out','run-as',$script:P0PackageName,'cat','files/test-confirmation-state.json') `
        -Operation '读取确认状态' -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Stdout)) { return $null }
    # app 侧非原子写入；polling 可能在写入途中读到截断/半成品内容。
    # 与文件不存在同等对待（返回 null 让调用方按下一次轮询处理），
    # 真正持续损坏会自然撞上调用方既有的确认超时兜底，不会被静默放行。
    try { return $result.Stdout | ConvertFrom-Json }
    catch { return $null }
}

function Get-P0UInt32BigEndian {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset
    )
    if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) { throw 'PNG 整数越界。' }
    [uint64]$value = ([uint64]$Bytes[$Offset] -shl 24) -bor
        ([uint64]$Bytes[$Offset + 1] -shl 16) -bor
        ([uint64]$Bytes[$Offset + 2] -shl 8) -bor
        [uint64]$Bytes[$Offset + 3]
    return [uint32]$value
}

function Get-P0Crc32 {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][int]$Count
    )
    if ($Offset -lt 0 -or $Count -lt 0 -or [int64]$Offset + $Count -gt $Bytes.Length) {
        throw 'PNG CRC 范围越界。'
    }
    [uint64]$crc = 0xffffffffL
    for ($index = $Offset; $index -lt $Offset + $Count; $index++) {
        $crc = ($crc -bxor [uint64]$Bytes[$index]) -band 0xffffffffL
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($crc -band 1L) -ne 0) {
                $crc = (($crc -shr 1) -bxor 0xedb88320L) -band 0xffffffffL
            }
            else { $crc = ($crc -shr 1) -band 0xffffffffL }
        }
    }
    return [uint32](($crc -bxor 0xffffffffL) -band 0xffffffffL)
}

function Test-P0PngEvidence {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $signature = [byte[]](137,80,78,71,13,10,26,10)
    if ($Bytes.Length -lt 57) { return $false }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($Bytes[$index] -ne $signature[$index]) { return $false }
    }

    $offset = 8
    $seenHeader = $false
    $seenData = $false
    $seenEnd = $false
    $dataEnded = $false
    $width = 0
    $height = 0
    $channels = 0
    $compressed = [IO.MemoryStream]::new()
    try {
        while ($offset -lt $Bytes.Length) {
            if ($seenEnd -or $Bytes.Length - $offset -lt 12) { return $false }
            [uint32]$chunkLength = Get-P0UInt32BigEndian -Bytes $Bytes -Offset $offset
            [uint64]$chunkEnd = [uint64]$offset + 12L + [uint64]$chunkLength
            if ($chunkLength -gt [int]::MaxValue -or $chunkEnd -gt [uint64]$Bytes.Length) { return $false }
            $length = [int]$chunkLength
            $typeOffset = $offset + 4
            $dataOffset = $offset + 8
            $crcOffset = $dataOffset + $length
            $type = [Text.Encoding]::ASCII.GetString($Bytes, $typeOffset, 4)
            if ($type -notmatch '^[A-Za-z]{4}$') { return $false }
            $expectedCrc = Get-P0UInt32BigEndian -Bytes $Bytes -Offset $crcOffset
            $actualCrc = Get-P0Crc32 -Bytes $Bytes -Offset $typeOffset -Count (4 + $length)
            if ($actualCrc -ne $expectedCrc) { return $false }

            if (-not $seenHeader -and ($type -cne 'IHDR' -or $offset -ne 8)) { return $false }
            switch -CaseSensitive ($type) {
                'IHDR' {
                    if ($seenHeader -or $length -ne 13) { return $false }
                    $seenHeader = $true
                    $width = [int64](Get-P0UInt32BigEndian -Bytes $Bytes -Offset $dataOffset)
                    $height = [int64](Get-P0UInt32BigEndian -Bytes $Bytes -Offset ($dataOffset + 4))
                    $bitDepth = [int]$Bytes[$dataOffset + 8]
                    $colorType = [int]$Bytes[$dataOffset + 9]
                    if ($width -lt 64 -or $height -lt 64 -or $width -gt 8192 -or $height -gt 8192 -or
                        $width * $height -gt 20000000L -or $bitDepth -ne 8 -or
                        $colorType -notin @(2,6) -or $Bytes[$dataOffset + 10] -ne 0 -or
                        $Bytes[$dataOffset + 11] -ne 0 -or $Bytes[$dataOffset + 12] -ne 0) {
                        return $false
                    }
                    $channels = if ($colorType -eq 2) { 3 } else { 4 }
                }
                'IDAT' {
                    if (-not $seenHeader -or $seenEnd -or $dataEnded -or $length -eq 0) { return $false }
                    $seenData = $true
                    if ($compressed.Length + $length -gt 67108864L) { return $false }
                    $compressed.Write($Bytes, $dataOffset, $length)
                }
                'IEND' {
                    if (-not $seenHeader -or -not $seenData -or $seenEnd -or $length -ne 0) { return $false }
                    $seenEnd = $true
                }
                default {
                    if ($seenData) { $dataEnded = $true }
                    # Unknown critical chunks (uppercase first byte) cannot be safely interpreted.
                    if ([char]::IsUpper([char]$type[0]) -and $type -cne 'PLTE') { return $false }
                }
            }
            $offset = [int]$chunkEnd
        }
        if (-not $seenEnd -or $offset -ne $Bytes.Length) { return $false }

        [int64]$rowSize = 1L + ([int64]$width * $channels)
        [int64]$expectedLength = $rowSize * $height
        $compressed.Position = 0
        $zlib = [IO.Compression.ZLibStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress, $true)
        try {
            $buffer = [byte[]]::new(8192)
            [int64]$decoded = 0
            while (($read = $zlib.Read($buffer, 0, $buffer.Length)) -gt 0) {
                for ($index = 0; $index -lt $read; $index++) {
                    if (($decoded % $rowSize) -eq 0 -and $buffer[$index] -gt 4) { return $false }
                    $decoded++
                    if ($decoded -gt $expectedLength) { return $false }
                }
            }
            return $decoded -eq $expectedLength
        }
        catch { return $false }
        finally { $zlib.Dispose() }
    }
    catch { return $false }
    finally { $compressed.Dispose() }
}

function Save-P0PrivateEvidence {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$EvidenceFile,
        [Parameter(Mandatory)][string]$Destination
    )
    if ($EvidenceFile -notmatch '^confirmation-[A-Za-z0-9._-]+\.png$') { throw '确认截图文件名无效。' }
    Invoke-P0ExternalToFile -FilePath $Session.AdbPath `
        -Arguments @('-s',$Session.Serial,'exec-out','run-as',$script:P0PackageName,'cat',"cache/$EvidenceFile") `
        -Destination $Destination -Operation '拉取确认截图'
    $evidenceBytes = [IO.File]::ReadAllBytes($Destination)
    if (-not (Test-P0PngEvidence -Bytes $evidenceBytes)) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw '确认截图证据不是有效 PNG。'
    }
    $evidenceBytes = $null
}

function Get-P0AuditCursor {
    param([Parameter(Mandatory)]$Session)
    $dayProbe = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('shell','date','+%Y%m%d') -Operation '读取设备审计日期' -AllowFailure
    $day = $dayProbe.Stdout.Trim()
    if ($dayProbe.ExitCode -ne 0 -or $day -notmatch '^\d{8}$') { throw '无法建立 gateway 审计游标。' }
    $path = "/sdcard/Android/data/$script:P0PackageName/files/audit/$day.jsonl"
    # 审计落在 external files dir。Android 11+ 的 `run-as` 跑在 shell 的挂载命名空间里，
    # 对 /sdcard/Android/data/<pkg> 一律 Permission denied（本机 Android 16 实测）；
    # 而普通 adb shell 反而读得到。内部 filesDir 的操作仍必须走 run-as，两者不能混用。
    $probe = Invoke-P0DeviceCommand -Session $Session `
        -Arguments @('exec-out','wc','-l',$path) `
        -Operation '读取 gateway 审计游标' -AllowFailure
    $lineCount = 0
    if ($probe.ExitCode -eq 0 -and $probe.Stdout -match '^\s*(\d+)') { $lineCount = [int64]$Matches[1] }
    [pscustomobject]@{ Day = $day; Path = $path; LineCount = $lineCount }
}

function Save-P0AuditIncrement {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Cursor,
        [Parameter(Mandatory)][string]$Destination
    )
    $firstLine = [int64]$Cursor.LineCount + 1
    # 不再 -AllowFailure：exec-out 会把设备侧 stderr 一并写进目标文件，静默失败的后果是
    # 一行 `tail: ... Permission denied` 冒充审计内容，直到下游报"无法解析的 JSON 行"
    # 才暴露（2026-07-26 实锤，且这个坑一直藏在 ToolSearch 误杀后面没被发现）。
    Invoke-P0ExternalToFile -FilePath $Session.AdbPath `
        -Arguments @('-s',$Session.Serial,'exec-out','tail','-n',"+$firstLine",[string]$Cursor.Path) `
        -Destination $Destination -Operation '拉取本腿 gateway 审计增量'
}

function Clear-P0DebugArtifacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [switch]$BestEffort)
    $issues = [Collections.Generic.List[string]]::new()
    $steps = @(
        @{ Name='control_file'; Args=@('shell','run-as',$script:P0PackageName,'rm','-f','files/test-control.json') },
        @{ Name='confirmation_state'; Args=@('shell','run-as',$script:P0PackageName,'rm','-f','files/test-confirmation-state.json') },
        @{ Name='claimed_control'; Args=@('shell','run-as',$script:P0PackageName,'sh','-c',"'rm -f files/.test-control.claimed-*.json'") },
        @{ Name='confirmation_screenshot'; Args=@('shell','run-as',$script:P0PackageName,'sh','-c',"'rm -f cache/confirmation-*.png'") }
    )
    foreach ($step in $steps) {
        if (-not $Session.DebugCleanupPending.Contains([string]$step.Name)) { continue }
        try {
            $result = Invoke-P0DeviceCommand -Session $Session -Arguments $step.Args `
                -Operation '清理监督式测试临时态' -AllowFailure
            if ($result.ExitCode -eq 0) {
                [void]$Session.DebugCleanupPending.Remove([string]$step.Name)
            }
            else { $issues.Add("device_$($step.Name)") }
        }
        catch { $issues.Add("device_$($step.Name)") }
    }
    if ($issues.Count -gt 0 -and -not $BestEffort) {
        throw "监督式测试临时态清理失败：$($issues -join ',')"
    }
    return @($issues)
}

function Clear-P0RemoteControlStaging {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [switch]$BestEffort)

    $issues = [Collections.Generic.List[string]]::new()
    foreach ($remote in @($Session.RemoteControlStaging)) {
        try {
            $result = Invoke-P0DeviceCommand -Session $Session -Arguments @('shell','rm','-f',$remote) `
                -Operation '清理控制中转文件' -AllowFailure
            if ($result.ExitCode -eq 0) {
                [void]$Session.RemoteControlStaging.Remove($remote)
            } elseif (-not $issues.Contains('device_control_staging')) {
                $issues.Add('device_control_staging')
            }
        }
        catch {
            if (-not $issues.Contains('device_control_staging')) { $issues.Add('device_control_staging') }
        }
    }
    if ($Session.RemoteControlStaging.Count -eq 0) {
        Remove-P0SessionCleanupIssue -Session $Session -Issue 'device_control_staging'
    }
    if ($issues.Count -gt 0 -and -not $BestEffort) { throw '控制中转文件清理失败。' }
    return @($issues)
}

function Clear-P0PrivateTemporaryFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [switch]$BestEffort)

    $issues = [Collections.Generic.List[string]]::new()
    foreach ($temporary in @($Session.PrivateTemporaryFiles)) {
        try {
            Remove-P0PrivateTemporaryFile -Path $temporary
            if (Test-Path -LiteralPath $temporary) { throw 'private temp remains' }
            [void]$Session.PrivateTemporaryFiles.Remove($temporary)
        }
        catch {
            if (-not $issues.Contains('private_config_temp')) { $issues.Add('private_config_temp') }
        }
    }
    if ($Session.PrivateTemporaryFiles.Count -eq 0) {
        Remove-P0SessionCleanupIssue -Session $Session -Issue 'private_config_temp'
        Remove-P0SessionCleanupIssue -Session $Session -Issue 'private_restore_temp'
    }
    if ($issues.Count -gt 0 -and -not $BestEffort) { throw '私密临时文件清理失败。' }
    return @($issues)
}

function Restore-P0Config {
    param([Parameter(Mandatory)]$Session)
    if (-not $Session.ConfigRestorePending) { return }
    if ($Session.ConfigExisted) {
        $temporary = "$($Session.ConfigPath).restore-$([guid]::NewGuid().ToString('N')).tmp"
        $operationFailed = $false
        $cleanupFailed = $false
        if (-not $Session.PrivateTemporaryFiles.Contains($temporary)) { $Session.PrivateTemporaryFiles.Add($temporary) }
        try {
            [IO.File]::WriteAllBytes($temporary, $Session.OriginalConfig)
            Move-P0PrivateFileAtomic -Source $temporary -Destination $Session.ConfigPath
            [void]$Session.PrivateTemporaryFiles.Remove($temporary)
        }
        catch { $operationFailed = $true }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                try {
                    Remove-P0PrivateTemporaryFile -Path $temporary
                    [void]$Session.PrivateTemporaryFiles.Remove($temporary)
                }
                catch {
                    $cleanupFailed = $true
                    Add-P0SessionCleanupIssue -Session $Session -Issue 'private_restore_temp'
                }
            } else {
                [void]$Session.PrivateTemporaryFiles.Remove($temporary)
            }
        }
        if ($operationFailed -or $cleanupFailed) { throw '私密配置恢复失败。' }
    }
    else {
        if (Test-Path -LiteralPath $Session.ConfigPath) {
            Remove-Item -LiteralPath $Session.ConfigPath -Force -ErrorAction Stop
        }
    }
    $Session.ConfigRestorePending = $false
    $Session.OriginalConfig = $null
    Remove-P0SessionCleanupIssue -Session $Session -Issue 'private_restore_temp'
}

function Stop-P0DeviceProvision {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($issue in @($Session.CleanupIssues)) {
        if (-not $errors.Contains($issue)) { $errors.Add($issue) }
    }
    try { $errors.AddRange([string[]]@(Clear-P0DebugArtifacts -Session $Session -BestEffort)) }
    catch { $errors.Add('device_debug_artifacts') }
    try {
        foreach ($issue in @(Clear-P0RemoteControlStaging -Session $Session -BestEffort)) {
            if (-not $errors.Contains($issue)) { $errors.Add($issue) }
        }
    }
    catch { if (-not $errors.Contains('device_control_staging')) { $errors.Add('device_control_staging') } }
    if (-not [string]::IsNullOrWhiteSpace($Session.OriginalIme) -and $Session.OriginalIme -ne 'null') {
        try {
            $restoreIme = Invoke-P0DeviceCommand -Session $Session `
                -Arguments @('shell','ime','set',$Session.OriginalIme) -Operation '恢复原输入法' -AllowFailure
            if ($restoreIme.ExitCode -ne 0) { $errors.Add('restore_ime') }
            else { $Session.OriginalIme = '' }
        }
        catch { $errors.Add('restore_ime') }
    }
    if ($Session.PortForwarded) {
        try {
            $removeForward = Invoke-P0DeviceCommand -Session $Session `
                -Arguments @('forward','--remove',"tcp:$script:P0Port") -Operation '移除 gateway 端口转发' -AllowFailure
            if ($removeForward.ExitCode -ne 0) { $errors.Add('remove_port_forward') }
            else { $Session.PortForwarded = $false }
        }
        catch { $errors.Add('remove_port_forward') }
    }
    $restoreFailed = $false
    try { Restore-P0Config -Session $Session }
    catch {
        $restoreFailed = $true
        if (-not $errors.Contains('restore_private_config')) { $errors.Add('restore_private_config') }
    }
    try {
        foreach ($issue in @(Clear-P0PrivateTemporaryFiles -Session $Session -BestEffort)) {
            if (-not $errors.Contains($issue)) { $errors.Add($issue) }
        }
    }
    catch { if (-not $errors.Contains('private_config_temp')) { $errors.Add('private_config_temp') } }
    if ($restoreFailed) {
        try { Restore-P0Config -Session $Session }
        catch { if (-not $errors.Contains('restore_private_config')) { $errors.Add('restore_private_config') } }
        try {
            foreach ($issue in @(Clear-P0PrivateTemporaryFiles -Session $Session -BestEffort)) {
                if (-not $errors.Contains($issue)) { $errors.Add($issue) }
            }
        }
        catch { if (-not $errors.Contains('private_config_temp')) { $errors.Add('private_config_temp') } }
    }
    foreach ($issue in @($Session.CleanupIssues)) {
        if (-not $errors.Contains($issue)) { $errors.Add($issue) }
    }
    return @($errors | Select-Object -Unique)
}
