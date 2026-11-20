#Requires -Version 7

function Get-ExecutorProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('gateway')][string]$Executor,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScriptsRoot
    )

    [pscustomobject]@{
        Name = 'gateway'
        McpConfigPath = Join-Path $RepoRoot 'configs\gateway-mcp.json'
        PreamblePath = Join-Path $ScriptsRoot 'prompts\gateway-executor-preamble.md'
        AllowedTools = 'mcp__gateway'
        RequiresGatewayConfig = $true
        RequiresPortForward = $true
    }
}

function Get-GatewayPreflightPort {
    return 8848
}

function Get-GatewayConfigProblem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return 'gateway MCP 私密配置不存在。请从 example 复制后填写手机生成的 token。'
    }

    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return 'gateway MCP 私密配置不是有效 JSON。'
    }

    $gateway = $config.mcpServers.gateway
    if ($null -eq $gateway) {
        return 'gateway MCP 私密配置缺少 mcpServers.gateway。'
    }
    if ([string]$gateway.type -cne 'http') {
        return 'gateway MCP 私密配置的 type 必须为 http。'
    }
    if ([string]$gateway.url -cne 'http://127.0.0.1:8848/mcp') {
        return 'gateway MCP 私密配置的 URL 必须为本机 127.0.0.1:8848/mcp。'
    }

    $authorization = [string]$gateway.headers.Authorization
    if ([string]::IsNullOrWhiteSpace($authorization) -or
        $authorization -notmatch '(?i)^Bearer\s+([^\s]+)$') {
        return 'gateway MCP 私密配置缺少有效的 Bearer token。'
    }
    $token = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($token) -or $token -ieq '<GATEWAY_TOKEN>') {
        return 'gateway MCP 私密配置仍是 token 占位符。'
    }

    return $null
}

function Get-GatewayConfigToken {
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (Get-GatewayConfigProblem -ConfigPath $ConfigPath) { return $null }
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        $authorization = [string]$config.mcpServers.gateway.headers.Authorization
        if ($authorization -match '(?i)^Bearer\s+([^\s]+)$') { return $Matches[1] }
    }
    catch {}
    return $null
}

function Set-GatewayConfigTokenFile {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Token) -or $Token -notmatch '^[A-Za-z0-9._-]{8,256}$') {
        return $false
    }
    $directory = Split-Path -Parent $ConfigPath
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temporary = Join-Path $directory ('.gateway-mcp.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $payload = [ordered]@{
        mcpServers = [ordered]@{
            gateway = [ordered]@{
                type = 'http'
                url = 'http://127.0.0.1:8848/mcp'
                timeout = 420000
                headers = [ordered]@{ Authorization = "Bearer $Token" }
            }
        }
    } | ConvertTo-Json -Depth 5
    try {
        Set-Content -LiteralPath $temporary -Value $payload -Encoding utf8 -ErrorAction Stop
        Move-Item -LiteralPath $temporary -Destination $ConfigPath -Force -ErrorAction Stop
        return $true
    }
    catch { return $false }
    finally {
        $payload = $null
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-GatewayDeviceTokenViaRunAs {
    param([Parameter(Mandatory)][string]$AdbCommand)

    $raw = @(& $AdbCommand exec-out run-as dev.magina.gateway cat shared_prefs/gateway.xml 2>$null)
    if ($LASTEXITCODE -ne 0 -or $raw.Count -eq 0) { return $null }
    $text = $raw -join "`n"
    try {
        $match = [regex]::Match($text, '<string\s+name=["'']token["'']\s*>([^<\s]+)</string>')
        if (-not $match.Success) { return $null }
        $candidate = [string]$match.Groups[1].Value
        if ($candidate -notmatch '^[A-Za-z0-9._-]{8,256}$') { return $null }
        return $candidate
    }
    finally { $text = $null }
}

function Get-GatewayForegroundServiceState {
    param([Parameter(Mandatory)][string]$AdbCommand)

    $out = @(& $AdbCommand shell dumpsys activity services dev.magina.gateway/.GatewayService 2>&1)
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    $text = $out -join "`n"
    if ($text -match 'ServiceRecord\{[^\r\n]*dev\.magina\.gateway/\.GatewayService(?:\s+[^\r\n}]*)?\}' -and
        $text -match '(?i)\b(?:isForeground|foreground)\s*[=:]\s*true\b') {
        return 'foreground'
    }
    if ($text -notmatch 'ServiceRecord\{' -and $text -match '(?m)^\s*\(nothing\)\s*$') { return 'absent' }
    return 'unknown'
}

function New-GatewayLocalHttpClient {
    param([int]$TimeoutSec = 3)

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    return $client
}

function Wait-GatewayHealthEndpoint {
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 5
    )

    $client = New-GatewayLocalHttpClient -TimeoutSec 2
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ($true) {
            $response = $null
            try {
                $response = $client.GetAsync("http://127.0.0.1:$Port/health").GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode) {
                    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim()
                    if ($body -ceq 'ok') { return $true }
                }
            }
            catch {}
            finally {
                if ($null -ne $response) { $response.Dispose() }
            }
            if ([DateTime]::UtcNow -ge $deadline) { return $false }
            Start-Sleep -Milliseconds 250
        }
    }
    finally { $client.Dispose() }
}

function Invoke-GatewayDeviceInfoCall {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Token
    )

    $client = New-GatewayLocalHttpClient -TimeoutSec 5
    $request = $null
    $response = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::Post,
            "http://127.0.0.1:$Port/mcp"
        )
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        [void]$request.Headers.TryAddWithoutValidation('MCP-Protocol-Version', '2025-03-26')
        $body = '{"jsonrpc":"2.0","id":"dispatch-preflight","method":"tools/call","params":{"name":"device_info","arguments":{}}}'
        $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')

        $response = $client.Send($request)
        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 401) {
            return [pscustomobject]@{ Ok = $false; Unauthorized = $true; Problem = 'gateway Bearer token 鉴权失败（HTTP 401）。'; Caps = @() }
        }
        if (-not $response.IsSuccessStatusCode) {
            return [pscustomobject]@{ Ok = $false; Unauthorized = $false; Problem = "gateway MCP /mcp 返回 HTTP $statusCode。"; Caps = @() }
        }
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $rpc = ConvertFrom-Json -InputObject $raw -Depth 20 -ErrorAction Stop
        $content = @($rpc.result.content)
        if ($content.Count -lt 1 -or [string]::IsNullOrWhiteSpace([string]$content[0].text)) {
            return [pscustomobject]@{ Ok = $false; Unauthorized = $false; Problem = 'gateway device_info 响应缺少结构化正文。'; Caps = @() }
        }
        $envelope = ConvertFrom-Json -InputObject ([string]$content[0].text) -Depth 20 -ErrorAction Stop
        if ($envelope.ok -ne $true) {
            return [pscustomobject]@{ Ok = $false; Unauthorized = $false; Problem = 'gateway device_info 返回 ok=false。'; Caps = @() }
        }
        $caps = @($envelope.data.caps | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ Ok = $true; Unauthorized = $false; Problem = $null; Caps = $caps }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Unauthorized = $false; Problem = 'gateway MCP device_info 调用失败。'; Caps = @() }
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $client.Dispose()
    }
}

function Invoke-GatewayBoundedAccessibilityRebind {
    param([Parameter(Mandatory)][string]$AdbCommand)

    $actOut = @(& $AdbCommand shell dumpsys activity activities 2>&1)
    $actExit = $LASTEXITCODE
    $actText = $actOut -join "`n"
    if ($actExit -eq 0 -and
        $actText -match '(?m)(?:topResumedActivity|mResumedActivity)\s*[:=][^\r\n]*\bcom\.android\.settings/') {
        return 'gateway_a11y_not_ready：当前前台为系统设置（com.android.settings），为避开安全中心监控不自动重绑，请先退回桌面或目标 App 后重试。'
    }
    if ($actExit -ne 0 -or
        $actText -notmatch '(?:topResumedActivity|mResumedActivity)\s*[:=]\s*ActivityRecord\{[^}\r\n]*\bu\d+\s+[\w.]+/') {
        return 'gateway_a11y_not_ready：无法确认当前前台应用，已停止预检。'
    }

    $fullComp = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
    $shortComp = 'dev.magina.gateway/.a11y.GatewayA11yService'
    $curOut = @(& $AdbCommand shell settings get secure enabled_accessibility_services 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return 'gateway_a11y_not_ready：无法读取 enabled_accessibility_services 进行无障碍重绑。'
    }
    $curRaw = ($curOut -join "`n").Trim()
    if ($curRaw -ceq 'null') { $curRaw = '' }
    $existing = @($curRaw -split ':' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $without = @($existing | Where-Object { $_ -cne $fullComp -and $_ -cne $shortComp })
    $withGateway = @($without + @($fullComp))

    if ($without.Count -gt 0) {
        & $AdbCommand shell settings put secure enabled_accessibility_services ($without -join ':') *> $null
    }
    else {
        & $AdbCommand shell settings delete secure enabled_accessibility_services *> $null
    }
    if ($LASTEXITCODE -ne 0) {
        return 'gateway_a11y_not_ready：重置 enabled_accessibility_services 失败。'
    }
    Start-Sleep -Milliseconds 300
    & $AdbCommand shell settings put secure enabled_accessibility_services ($withGateway -join ':') *> $null
    if ($LASTEXITCODE -ne 0) {
        return 'gateway_a11y_not_ready：重新写入 enabled_accessibility_services 失败。'
    }
    & $AdbCommand shell settings put secure accessibility_enabled 1 *> $null
    if ($LASTEXITCODE -ne 0) {
        return 'gateway_a11y_not_ready：启用 accessibility_enabled 失败。'
    }
    return $null
}

function Stop-GatewayPreflightOwnedResources {
    [CmdletBinding()]
    param(
        [AllowNull()]$State,
        [string]$AdbCommand = 'adb'
    )

    if ($null -eq $State) { return }
    if ($State.StartedService) {
        $stopOut = @(& $AdbCommand shell am stopservice -n dev.magina.gateway/.GatewayService 2>&1)
        $stopExit = $LASTEXITCODE
        $stopText = $stopOut -join "`n"
        # Android 16 上 am stopservice 会把 Service stopped 打到 stderr 并返回 255，属正常停止。
        if ($stopExit -ne 0 -and $stopText -notmatch '(?i)Service stopped') {
            Write-Warning '收尾停止自启 GatewayService 返回非零，请按需在设备确认。'
        }
        $State.StartedService = $false
    }
    if ($State.PortForwarded) {
        & $AdbCommand forward --remove "tcp:$($State.Port)" *> $null
        $State.PortForwarded = $false
    }
}

function Ensure-GatewayPreflightReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$AdbCommand = 'adb',
        [int]$Port = (Get-GatewayPreflightPort),
        [int]$HealthTimeoutSec = 5,
        [int]$A11yRebindTimeoutSec = 8,
        [switch]$SkipAccessibilityRebind
    )

    $state = [pscustomobject]@{
        Problem = $null
        StartedService = $false
        PortForwarded = $false
        Port = $Port
    }

    if (-not (Get-Command $AdbCommand -ErrorAction SilentlyContinue)) {
        $state.Problem = 'adb 不在 PATH'
        return $state
    }
    $stateOutput = @(& $AdbCommand get-state 2>&1)
    $stateExitCode = $LASTEXITCODE
    $deviceState = "$($stateOutput | Select-Object -Last 1)".Trim()
    if ($stateExitCode -ne 0 -or $deviceState -cne 'device') {
        $state.Problem = "无已授权设备（adb get-state → $deviceState）"
        return $state
    }
    & $AdbCommand shell input keyevent KEYCODE_WAKEUP *> $null
    if ($LASTEXITCODE -ne 0) {
        $state.Problem = '设备唤醒失败（adb shell input keyevent）。'
        return $state
    }

    $serviceState = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
    if ($serviceState -eq 'unknown') {
        $state.Problem = '无法确认 GatewayService 正在前台运行或尚未启动，已停止预检。'
        return $state
    }
    if ($serviceState -eq 'absent') {
        & $AdbCommand shell am start-foreground-service -n dev.magina.gateway/.GatewayService *> $null
        $startExit = $LASTEXITCODE
        if ($startExit -ne 0) {
            & $AdbCommand shell run-as dev.magina.gateway am start-foreground-service --user 0 -n dev.magina.gateway/.GatewayService *> $null
            $startExit = $LASTEXITCODE
        }
        if ($startExit -ne 0) {
            $state.Problem = 'gateway 前台服务未运行且自动拉起失败。'
            return $state
        }
        $state.StartedService = $true
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        $running = $false
        while ($true) {
            if ((Get-GatewayForegroundServiceState -AdbCommand $AdbCommand) -eq 'foreground') { $running = $true; break }
            if ([DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $running) {
            $state.Problem = 'gateway 前台服务启动后未进入前台运行状态。'
            Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
            return $state
        }
    }

    $endpoint = "tcp:$Port"
    & $AdbCommand forward --no-rebind $endpoint $endpoint *> $null
    if ($LASTEXITCODE -eq 0) {
        $state.PortForwarded = $true
    }
    else {
        # ADB 的转发列表跨设备；只有当前设备的同一映射可以借用。
        $serial = [string](& $AdbCommand get-serialno 2>$null)
        $hasSerial = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($serial) -and $serial -cne 'unknown'
        $forwards = @(& $AdbCommand forward --list 2>$null)
        $listed = @($forwards | ForEach-Object { $_.Trim() -replace '\s+', ' ' })
        if (-not $hasSerial -or $LASTEXITCODE -ne 0 -or
            "$serial $endpoint $endpoint" -cnotin $listed) {
            $state.Problem = "gateway 端口转发失败，未确认 $endpoint 属于当前设备的同一映射。"
            Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
            return $state
        }
    }

    $configProblem = Get-GatewayConfigProblem -ConfigPath $ConfigPath
    if ($configProblem -and ($configProblem -like '*不存在*' -or $configProblem -like '*占位符*')) {
        $deviceToken = Read-GatewayDeviceTokenViaRunAs -AdbCommand $AdbCommand
        try {
            if ($deviceToken) {
                [void](Set-GatewayConfigTokenFile -ConfigPath $ConfigPath -Token $deviceToken)
            }
        }
        finally { $deviceToken = $null }
        $configProblem = Get-GatewayConfigProblem -ConfigPath $ConfigPath
    }
    if ($configProblem) {
        $state.Problem = $configProblem
        Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
        return $state
    }

    if (-not (Wait-GatewayHealthEndpoint -Port $Port -TimeoutSec $HealthTimeoutSec)) {
        $state.Problem = "gateway 本地 /health 探测超时（127.0.0.1:$Port）。"
        Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
        return $state
    }

    $token = Get-GatewayConfigToken -ConfigPath $ConfigPath
    try {
        $probe = Invoke-GatewayDeviceInfoCall -Port $Port -Token $token
        if ($probe.Unauthorized) {
            $deviceToken = Read-GatewayDeviceTokenViaRunAs -AdbCommand $AdbCommand
            try {
                if ($deviceToken -and $deviceToken -cne $token -and
                    (Set-GatewayConfigTokenFile -ConfigPath $ConfigPath -Token $deviceToken)) {
                    $token = $deviceToken
                    $probe = Invoke-GatewayDeviceInfoCall -Port $Port -Token $token
                }
            }
            finally { $deviceToken = $null }
        }
        if (-not $probe.Ok) {
            $state.Problem = $probe.Problem
            Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
            return $state
        }
        if ('a11y' -in $probe.Caps) { return $state }
        if ($SkipAccessibilityRebind) {
            $state.Problem = 'gateway_a11y_not_ready：准备任务未获准修改无障碍设置。'
            Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
            return $state
        }

        $rebindError = Invoke-GatewayBoundedAccessibilityRebind -AdbCommand $AdbCommand
        if ($rebindError) {
            $state.Problem = $rebindError
            Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
            return $state
        }

        $rebindDeadline = [DateTime]::UtcNow.AddSeconds($A11yRebindTimeoutSec)
        while ($true) {
            Start-Sleep -Milliseconds 400
            $recheck = Invoke-GatewayDeviceInfoCall -Port $Port -Token $token
            if ($recheck.Ok -and 'a11y' -in $recheck.Caps) { return $state }
            if ([DateTime]::UtcNow -ge $rebindDeadline) { break }
        }
        $state.Problem = 'gateway_a11y_not_ready：单次无障碍重绑后 a11y 仍未就绪，请人工在系统无障碍设置中重开网关服务。'
        Stop-GatewayPreflightOwnedResources -State $state -AdbCommand $AdbCommand
        return $state
    }
    finally { $token = $null }
}
