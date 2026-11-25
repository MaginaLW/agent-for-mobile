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

    $global:LASTEXITCODE = 0
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

    $global:LASTEXITCODE = 0
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

function ConvertFrom-AccessibilityServiceList {
    param([AllowNull()]$Raw = $null)

    if ($null -eq $Raw) {
        return [pscustomobject]@{
            Raw = $null
            Normalized = ''
            LeadingColon = $false
            Members = @()
        }
    }
    $trimmed = ([string]$Raw).Trim()
    if ($trimmed -ceq 'null' -or [string]::IsNullOrEmpty($trimmed)) {
        return [pscustomobject]@{
            Raw = ''
            Normalized = ''
            LeadingColon = $false
            Members = @()
        }
    }
    $leadingColon = $trimmed.StartsWith(':')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $members = [Collections.Generic.List[string]]::new()
    foreach ($part in @($trimmed -split ':')) {
        $item = $part.Trim()
        if (-not [string]::IsNullOrWhiteSpace($item) -and $seen.Add($item)) {
            $members.Add($item)
        }
    }
    $normalized = if ($members.Count -eq 0) {
        ''
    }
    elseif ($leadingColon) {
        ':' + ($members -join ':')
    }
    else {
        $members -join ':'
    }
    return [pscustomobject]@{
        Raw = $trimmed
        Normalized = $normalized
        LeadingColon = $leadingColon
        Members = @($members.ToArray())
    }
}

function Merge-AccessibilityServiceList {
    param(
        [AllowNull()]$BaselineRaw = $null,
        [AllowEmptyCollection()][string[]]$ObservedNonGateway = @(),
        [switch]$IncludeGateway,
        [string]$GatewayFullComponent = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService',
        [string]$GatewayShortComponent = 'dev.magina.gateway/.a11y.GatewayA11yService'
    )

    $baseParsed = ConvertFrom-AccessibilityServiceList -Raw $BaselineRaw
    $baseNonGateway = @($baseParsed.Members | Where-Object { $_ -cne $GatewayFullComponent -and $_ -cne $GatewayShortComponent })
    $baseHasGateway = @($baseParsed.Members | Where-Object { $_ -ceq $GatewayFullComponent -or $_ -ceq $GatewayShortComponent }).Count -gt 0

    $mergedNonGateway = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $baseNonGateway) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and $seen.Add($item)) {
            $mergedNonGateway.Add($item)
        }
    }
    foreach ($item in @($ObservedNonGateway)) {
        if (-not [string]::IsNullOrWhiteSpace($item) -and
            $item -cne $GatewayFullComponent -and
            $item -cne $GatewayShortComponent -and
            $seen.Add($item)) {
            $mergedNonGateway.Add($item)
        }
    }

    if ($IncludeGateway -and $baseHasGateway -and $mergedNonGateway.Count -eq $baseNonGateway.Count) {
        $allMatch = $true
        for ($i = 0; $i -lt $baseNonGateway.Count; $i++) {
            if ($mergedNonGateway[$i] -cne $baseNonGateway[$i]) { $allMatch = $false; break }
        }
        if ($allMatch -and -not [string]::IsNullOrEmpty($baseParsed.Raw)) {
            return $baseParsed.Raw
        }
    }

    $finalMembers = [Collections.Generic.List[string]]::new()
    foreach ($item in $mergedNonGateway) { $finalMembers.Add($item) }
    if ($IncludeGateway) { $finalMembers.Add($GatewayFullComponent) }
    if ($finalMembers.Count -eq 0) { return '' }
    if ($baseParsed.LeadingColon) { return ':' + ($finalMembers -join ':') }
    return ($finalMembers -join ':')
}

function Invoke-GatewaySettingsCommand {
    param(
        [Parameter(Mandatory)][string]$AdbCommand,
        [switch]$UserZero,
        [Parameter(Mandatory)][string[]]$SettingsArgs
    )

    $cmdArgs = [Collections.Generic.List[string]]::new()
    $cmdArgs.Add('shell')
    $cmdArgs.Add('settings')
    if ($UserZero) {
        $cmdArgs.Add('--user')
        $cmdArgs.Add('0')
    }
    foreach ($arg in $SettingsArgs) {
        $cmdArgs.Add($arg)
    }
    $global:LASTEXITCODE = 0
    $rawOut = @(& $AdbCommand @cmdArgs 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = ($rawOut -join "`n").Trim()
    }
}

function Restore-AccessibilityServicesBaseline {
    param(
        [Parameter(Mandatory)][string]$AdbCommand,
        [AllowNull()]$TargetServicesRaw = $null,
        [AllowNull()]$TargetEnabled = $null,
        [switch]$UserZero,
        [int]$SettleDelayMs = 500,
        [int]$MaxAttempts = 3
    )

    if ($null -eq $TargetServicesRaw) {
        return [pscustomobject]@{ Restored = $false; Verified = $true; Reason = 'no-baseline' }
    }
    $targetNorm = ([string]$TargetServicesRaw).Trim()
    $targetIsCleared = ($targetNorm -ceq 'null' -or [string]::IsNullOrEmpty($targetNorm))
    $targetEnabledStr = if ($null -eq $TargetEnabled) { $null } else { ([string]$TargetEnabled).Trim() }
    $validTargetEnabled = ($null -ne $targetEnabledStr -and $targetEnabledStr -cin @('0', '1'))

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    $didWrite = $false

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $readSvc = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
            -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
        if ($readSvc.ExitCode -ne 0) {
            if ($attempt -lt $MaxAttempts) {
                if ($SettleDelayMs -gt 0) { Start-Sleep -Milliseconds $SettleDelayMs }
                continue
            }
            return [pscustomobject]@{ Restored = $didWrite; Verified = $false; Reason = 'read-services-failed' }
        }

        $curNorm = $readSvc.Stdout
        $curIsCleared = ($curNorm -ceq 'null' -or [string]::IsNullOrEmpty($curNorm))
        $servicesMatch = if ($targetIsCleared) { $curIsCleared } else { $curNorm -ceq $targetNorm }

        $enabledMatch = $true
        if ($validTargetEnabled) {
            $readEnabled = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
                -SettingsArgs @('get', 'secure', 'accessibility_enabled')
            $enabledMatch = ($readEnabled.ExitCode -eq 0 -and $readEnabled.Stdout -ceq $targetEnabledStr)
        }

        if ($servicesMatch -and $enabledMatch) {
            return [pscustomobject]@{
                Restored = $didWrite
                Verified = $true
                Reason = if ($didWrite) { 'restored' } else { 'already-matched' }
            }
        }

        if (-not $servicesMatch) {
            if ($targetIsCleared) {
                $writeSvc = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
                    -SettingsArgs @('delete', 'secure', 'enabled_accessibility_services')
            }
            else {
                $writeSvc = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
                    -SettingsArgs @('put', 'secure', 'enabled_accessibility_services', $targetNorm)
            }
            if ($writeSvc.ExitCode -ne 0) {
                if ($attempt -lt $MaxAttempts) {
                    if ($SettleDelayMs -gt 0) { Start-Sleep -Milliseconds $SettleDelayMs }
                    continue
                }
                return [pscustomobject]@{ Restored = $didWrite; Verified = $false; Reason = 'write-services-failed' }
            }
            $didWrite = $true
        }

        if ($validTargetEnabled -and -not $enabledMatch) {
            $writeEnabled = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
                -SettingsArgs @('put', 'secure', 'accessibility_enabled', $targetEnabledStr)
            if ($writeEnabled.ExitCode -ne 0) {
                if ($attempt -lt $MaxAttempts) {
                    if ($SettleDelayMs -gt 0) { Start-Sleep -Milliseconds $SettleDelayMs }
                    continue
                }
                return [pscustomobject]@{ Restored = $didWrite; Verified = $false; Reason = 'write-enabled-failed' }
            }
            $didWrite = $true
        }

        if ($SettleDelayMs -gt 0) {
            Start-Sleep -Milliseconds $SettleDelayMs
        }
    }

    $finalReadSvc = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
        -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
    if ($finalReadSvc.ExitCode -eq 0) {
        $finalNorm = $finalReadSvc.Stdout
        $finalIsCleared = ($finalNorm -ceq 'null' -or [string]::IsNullOrEmpty($finalNorm))
        $finalSvcMatch = if ($targetIsCleared) { $finalIsCleared } else { $finalNorm -ceq $targetNorm }
        $finalEnabledMatch = $true
        if ($validTargetEnabled) {
            $finalReadEn = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -UserZero:$UserZero `
                -SettingsArgs @('get', 'secure', 'accessibility_enabled')
            $finalEnabledMatch = ($finalReadEn.ExitCode -eq 0 -and $finalReadEn.Stdout -ceq $targetEnabledStr)
        }
        if ($finalSvcMatch -and $finalEnabledMatch) {
            return [pscustomobject]@{ Restored = $didWrite; Verified = $true; Reason = 'restored' }
        }
    }

    return [pscustomobject]@{ Restored = $didWrite; Verified = $false; Reason = 'drift-persisted' }
}

function Invoke-GatewayBoundedAccessibilityRebind {
    param(
        [Parameter(Mandatory)][string]$AdbCommand,
        [int]$RebindPauseMs = 300
    )

    $global:LASTEXITCODE = 0
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
    $curRead = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
    if ($curRead.ExitCode -ne 0) {
        return 'gateway_a11y_not_ready：无法读取 enabled_accessibility_services 进行无障碍重绑。'
    }
    $preParsed = ConvertFrom-AccessibilityServiceList -Raw $curRead.Stdout
    $preNonGateway = @($preParsed.Members | Where-Object { $_ -cne $fullComp -and $_ -cne $shortComp })

    if ($preNonGateway.Count -gt 0) {
        $withoutValue = if ($preParsed.LeadingColon) { ':' + ($preNonGateway -join ':') } else { $preNonGateway -join ':' }
        $resetRes = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
            -SettingsArgs @('put', 'secure', 'enabled_accessibility_services', $withoutValue)
    }
    else {
        $resetRes = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
            -SettingsArgs @('delete', 'secure', 'enabled_accessibility_services')
    }
    if ($resetRes.ExitCode -ne 0) {
        return 'gateway_a11y_not_ready：重置 enabled_accessibility_services 失败。'
    }
    if ($RebindPauseMs -gt 0) {
        Start-Sleep -Milliseconds $RebindPauseMs
    }

    $observedNonGateway = @()
    $postRead = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
    if ($postRead.ExitCode -eq 0) {
        $postParsed = ConvertFrom-AccessibilityServiceList -Raw $postRead.Stdout
        $observedNonGateway = @($postParsed.Members | Where-Object { $_ -cne $fullComp -and $_ -cne $shortComp })
    }
    $targetValue = Merge-AccessibilityServiceList -BaselineRaw $preParsed.Raw `
        -ObservedNonGateway $observedNonGateway -IncludeGateway `
        -GatewayFullComponent $fullComp -GatewayShortComponent $shortComp

    $rebindPut = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
        -SettingsArgs @('put', 'secure', 'enabled_accessibility_services', $targetValue)
    if ($rebindPut.ExitCode -ne 0) {
        if ([string]::IsNullOrEmpty($preParsed.Raw)) {
            [void](Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                -SettingsArgs @('delete', 'secure', 'enabled_accessibility_services'))
        }
        else {
            [void](Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                -SettingsArgs @('put', 'secure', 'enabled_accessibility_services', $preParsed.Raw))
        }
        return 'gateway_a11y_not_ready：重新写入 enabled_accessibility_services 失败。'
    }
    $enableRes = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
        -SettingsArgs @('put', 'secure', 'accessibility_enabled', '1')
    if ($enableRes.ExitCode -ne 0) {
        if ([string]::IsNullOrEmpty($preParsed.Raw)) {
            [void](Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                -SettingsArgs @('delete', 'secure', 'enabled_accessibility_services'))
        }
        else {
            [void](Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                -SettingsArgs @('put', 'secure', 'enabled_accessibility_services', $preParsed.Raw))
        }
        return 'gateway_a11y_not_ready：启用 accessibility_enabled 失败。'
    }
    return $null
}

function Stop-GatewayPreflightOwnedResources {
    [CmdletBinding()]
    param(
        [AllowNull()]$State,
        [string]$AdbCommand = 'adb',
        [int]$A11yRestoreSettleMs = -1,
        [int]$A11yRestoreMaxAttempts = -1
    )

    if ($null -eq $State) { return }
    if ($State.StartedService) {
        $global:LASTEXITCODE = 0
        $stopOut = @(& $AdbCommand shell am stopservice -n dev.magina.gateway/.GatewayService 2>&1)
        $stopExit = $LASTEXITCODE
        $stopText = $stopOut -join "`n"
        # Android 16 上 am stopservice 会把 Service stopped 打到 stderr 并返回 255，属正常停止。
        if ($stopExit -ne 0 -and $stopText -notmatch '(?i)Service stopped') {
            $service = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
            if ($service -eq 'foreground') {
                # PA2553 上 shell 无法停止非导出服务。租约仍在，只撤销预检自己的启动。
                $global:LASTEXITCODE = 0
                $stopOut = @(& $AdbCommand shell run-as dev.magina.gateway am stopservice --user 0 -n dev.magina.gateway/.GatewayService 2>&1)
                if ($LASTEXITCODE -ne 0 -and ($stopOut -join "`n") -notmatch '(?i)Service stopped') {
                    Write-Warning '所属应用身份停止本轮 GatewayService 失败。'
                }
            }
            elseif ($service -ne 'absent') { Write-Warning '无法核实本轮 GatewayService 的停止状态。' }
        }
        $State.StartedService = $false
    }
    if ($State.PortForwarded) {
        $global:LASTEXITCODE = 0
        & $AdbCommand forward --remove "tcp:$($State.Port)" *> $null
        $State.PortForwarded = $false
    }

    $skipProp = $State.PSObject.Properties['SkipAccessibilityBaselineRestore']
    $skipRestore = ($null -ne $skipProp -and [bool]$skipProp.Value)
    $origSvcProp = $State.PSObject.Properties['OriginalAccessibilityServices']
    $origSvc = if ($null -ne $origSvcProp) { $origSvcProp.Value } else { $null }
    if (-not $skipRestore -and $null -ne $origSvc) {
        $origEnProp = $State.PSObject.Properties['OriginalAccessibilityEnabled']
        $origEn = if ($null -ne $origEnProp) { $origEnProp.Value } else { $null }
        $settleProp = $State.PSObject.Properties['AccessibilityRestoreSettleMs']
        $settleMs = if ($A11yRestoreSettleMs -ge 0) { $A11yRestoreSettleMs }
            elseif ($null -ne $settleProp -and $null -ne $settleProp.Value) { [int]$settleProp.Value }
            else { 500 }
        $attemptsProp = $State.PSObject.Properties['AccessibilityRestoreMaxAttempts']
        $maxAttempts = if ($A11yRestoreMaxAttempts -ge 1) { $A11yRestoreMaxAttempts }
            elseif ($null -ne $attemptsProp -and $null -ne $attemptsProp.Value) { [int]$attemptsProp.Value }
            else { 3 }
        try {
            $restoreRes = Restore-AccessibilityServicesBaseline -AdbCommand $AdbCommand `
                -TargetServicesRaw $origSvc -TargetEnabled $origEn `
                -SettleDelayMs $settleMs -MaxAttempts $maxAttempts
            if (-not $restoreRes.Verified) {
                Write-Warning "收尾未能还原 enabled_accessibility_services 基线（$($restoreRes.Reason)）。"
            }
        }
        catch {
            Write-Warning "收尾还原 enabled_accessibility_services 基线异常：$($_.Exception.Message)"
        }
        $State.OriginalAccessibilityServices = $null
        if ($null -ne $skipProp) { $State.SkipAccessibilityBaselineRestore = $true }
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
        [switch]$SkipAccessibilityRebind,
        [int]$A11yRestoreSettleMs = 500,
        [int]$A11yRestoreMaxAttempts = 3
    )

    $state = [pscustomobject]@{
        Problem = $null
        StartedService = $false
        PortForwarded = $false
        Port = $Port
        OriginalAccessibilityServices = $null
        OriginalAccessibilityEnabled = $null
        SkipAccessibilityBaselineRestore = [bool]$SkipAccessibilityRebind
        AccessibilityRestoreSettleMs = $A11yRestoreSettleMs
        AccessibilityRestoreMaxAttempts = $A11yRestoreMaxAttempts
    }

    if (-not (Get-Command $AdbCommand -ErrorAction SilentlyContinue)) {
        $state.Problem = 'adb 不在 PATH'
        return $state
    }
    $global:LASTEXITCODE = 0
    $stateOutput = @(& $AdbCommand get-state 2>&1)
    $stateExitCode = $LASTEXITCODE
    $deviceState = "$($stateOutput | Select-Object -Last 1)".Trim()
    if ($stateExitCode -ne 0 -or $deviceState -cne 'device') {
        $state.Problem = "无已授权设备（adb get-state → $deviceState）"
        return $state
    }
    $global:LASTEXITCODE = 0
    & $AdbCommand shell input keyevent KEYCODE_WAKEUP *> $null
    if ($LASTEXITCODE -ne 0) {
        $state.Problem = '设备唤醒失败（adb shell input keyevent）。'
        return $state
    }

    if (-not $SkipAccessibilityRebind) {
        try {
            $a11ySvcRead = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
            if ($a11ySvcRead.ExitCode -eq 0 -and $a11ySvcRead.Stdout -notmatch '[\r\n]') {
                $state.OriginalAccessibilityServices = $a11ySvcRead.Stdout
                $a11yEnRead = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
                    -SettingsArgs @('get', 'secure', 'accessibility_enabled')
                if ($a11yEnRead.ExitCode -eq 0 -and $a11yEnRead.Stdout -in @('0', '1')) {
                    $state.OriginalAccessibilityEnabled = $a11yEnRead.Stdout
                }
            }
        }
        catch {}
    }

    $serviceState = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
    if ($serviceState -eq 'unknown') {
        $state.Problem = '无法确认 GatewayService 正在前台运行或尚未启动，已停止预检。'
        return $state
    }
    if ($serviceState -eq 'absent') {
        $global:LASTEXITCODE = 0
        & $AdbCommand shell am start-foreground-service -n dev.magina.gateway/.GatewayService *> $null
        $startExit = $LASTEXITCODE
        if ($startExit -ne 0) {
            $global:LASTEXITCODE = 0
            & $AdbCommand shell run-as dev.magina.gateway am start-foreground-service --user 0 -n dev.magina.gateway/.GatewayService *> $null
            $startExit = $LASTEXITCODE
        }
        if ($startExit -ne 0) {
            $state.Problem = 'gateway 前台服务未运行且自动拉起失败。若设备处于冷态无进程，请先显式运行 scripts/bootstrap-gateway.ps1。'
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
    $global:LASTEXITCODE = 0
    & $AdbCommand forward --no-rebind $endpoint $endpoint *> $null
    if ($LASTEXITCODE -eq 0) {
        $state.PortForwarded = $true
    }
    else {
        # ADB 的转发列表跨设备；只有当前设备的同一映射可以借用。
        $global:LASTEXITCODE = 0
        $serial = [string](& $AdbCommand get-serialno 2>$null)
        $hasSerial = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($serial) -and $serial -cne 'unknown'
        $global:LASTEXITCODE = 0
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
