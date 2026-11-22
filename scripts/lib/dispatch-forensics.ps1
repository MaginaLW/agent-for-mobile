#Requires -Version 7

# 注意：本文件不声明 Set-StrictMode（遵循 dispatch.ps1 dot-source 约定），但内部代码必须兼容 StrictMode 3.0。

function Get-GatewayBoundAccessibilitySection {
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

function Test-GatewayAccessibilityComponentBound {
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
    foreach ($section in @(Get-GatewayBoundAccessibilitySection -DumpsysText $DumpsysText)) {
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

function Get-GatewayTransportHealthSnapshot {
    [CmdletBinding()]
    param(
        [string]$AdbCommand = 'adb',
        [int]$Port = 0,
        [ValidateRange(1, 30)][int]$HealthTimeoutSec = 2,
        [AllowNull()]$PreflightState = $null,
        [string]$Slug = '',
        [int]$Leg = 1,
        [string]$Executor = 'gateway',
        [string]$Brain = 'codex',
        [string]$TraceFile = '',
        [bool]$LandscapePrepare = $false
    )

    if ($Port -le 0) {
        if (Get-Command Get-GatewayPreflightPort -ErrorAction SilentlyContinue) {
            $Port = [int](Get-GatewayPreflightPort)
        }
        else {
            $Port = 8848
        }
    }

    $fullComp = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
    $shortComp = 'dev.magina.gateway/.a11y.GatewayA11yService'
    $label = '执行网关'

    $preflightStarted = $null
    $preflightForwarded = $null
    if ($null -ne $PreflightState) {
        $startedProp = $PreflightState.PSObject.Properties['StartedService']
        if ($null -ne $startedProp) { $preflightStarted = [bool]$startedProp.Value }
        $fwdProp = $PreflightState.PSObject.Properties['PortForwarded']
        if ($null -ne $fwdProp) { $preflightForwarded = [bool]$fwdProp.Value }
    }

    # 1. adb_forward 探针
    $adbForward = [ordered]@{
        probe_ok = $false
        exit_code = $null
        total_count = 0
        port_mappings = @()
        port_mapped = $null
        error = $null
    }
    try {
        $fwdOut = @(& $AdbCommand forward --list 2>&1 | ForEach-Object { "$_" })
        $fwdExit = $LASTEXITCODE
        $adbForward.exit_code = $fwdExit
        if ($fwdExit -eq 0) {
            $fwdLines = @($fwdOut | ForEach-Object { $_.Trim() -replace '\s+', ' ' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $portMappings = @($fwdLines | Where-Object { $_ -match "(?:^|\s)tcp:$Port(?:\s|$)" })
            $adbForward.probe_ok = $true
            $adbForward.total_count = $fwdLines.Count
            $adbForward.port_mappings = @($portMappings)
            $adbForward.port_mapped = ($portMappings.Count -gt 0)
        }
        else {
            $errLine = @($fwdOut | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            $adbForward.error = if ($errLine) { $errLine } else { "adb forward --list exited with $fwdExit" }
        }
    }
    catch {
        $adbForward.probe_ok = $false
        $adbForward.error = $_.Exception.Message
    }

    # 2. /health 探针（不带 Authorization 头）
    $healthUrl = "http://127.0.0.1:$Port/health"
    $health = [ordered]@{
        url = $healthUrl
        reachable = $false
        http_status = $null
        body_ok = $false
        error_type = $null
        error = $null
    }
    $client = $null
    $response = $null
    try {
        if (Get-Command New-GatewayLocalHttpClient -ErrorAction SilentlyContinue) {
            $client = New-GatewayLocalHttpClient -TimeoutSec $HealthTimeoutSec
        }
        else {
            $handler = [Net.Http.HttpClientHandler]::new()
            $handler.UseProxy = $false
            $client = [Net.Http.HttpClient]::new($handler)
            $client.Timeout = [TimeSpan]::FromSeconds($HealthTimeoutSec)
        }
        $response = $client.GetAsync($healthUrl).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $health.reachable = $true
        $health.http_status = [int]$response.StatusCode
        $health.body_ok = ($response.IsSuccessStatusCode -and ([string]$body).Trim() -ceq 'ok')
    }
    catch {
        $health.reachable = $false
        $health.http_status = $null
        $health.body_ok = $false
        $health.error_type = $_.Exception.GetType().FullName
        $health.error = $_.Exception.Message
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
    }

    # 3. gateway_service 探针
    $gatewayService = [ordered]@{
        probe_ok = $false
        state = 'unknown'
        preflight_started_service = $preflightStarted
        preflight_port_forwarded = $preflightForwarded
        error = $null
    }
    try {
        $svcState = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
        $gatewayService.state = $svcState
        $gatewayService.probe_ok = ($svcState -in @('foreground', 'absent'))
        if ($svcState -eq 'unknown') {
            $gatewayService.error = 'dumpsys activity services returned unknown'
        }
    }
    catch {
        $gatewayService.probe_ok = $false
        $gatewayService.state = 'unknown'
        $gatewayService.error = $_.Exception.Message
    }

    # 4. accessibility 探针（settings + dumpsys bound section 摘要，不记录窗口节点文本）
    $accessibility = [ordered]@{
        enabled_query_ok = $false
        enabled_exit_code = $null
        gateway_enabled = $null
        enabled_count = $null
        enabled_services = @()
        enabled_error = $null
        dumpsys_ok = $false
        dumpsys_exit_code = $null
        gateway_bound = $null
        bound_section_count = 0
        bound_sections = @()
        dumpsys_error = $null
    }
    try {
        $enabledOut = @(& $AdbCommand shell settings get secure enabled_accessibility_services 2>&1 | ForEach-Object { "$_" })
        $enabledExit = $LASTEXITCODE
        $accessibility.enabled_exit_code = $enabledExit
        if ($enabledExit -eq 0) {
            $rawEnabled = ($enabledOut -join "`n").Trim()
            if ($rawEnabled -ceq 'null') { $rawEnabled = '' }
            $enabledList = @($rawEnabled -split ':' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $accessibility.enabled_query_ok = $true
            $accessibility.gateway_enabled = [bool](@($enabledList | Where-Object { $_ -ceq $fullComp -or $_ -ceq $shortComp }).Count -gt 0)
            $accessibility.enabled_count = $enabledList.Count
            $accessibility.enabled_services = @($enabledList)
        }
        else {
            $errMsg = @($enabledOut | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            $accessibility.enabled_error = if ($errMsg) { $errMsg } else { "settings get secure enabled_accessibility_services exited with $enabledExit" }
        }
    }
    catch {
        $accessibility.enabled_query_ok = $false
        $accessibility.enabled_error = $_.Exception.Message
    }

    try {
        $dumpsysOut = @(& $AdbCommand shell dumpsys accessibility 2>&1 | ForEach-Object { "$_" })
        $dumpsysExit = $LASTEXITCODE
        $accessibility.dumpsys_exit_code = $dumpsysExit
        if ($dumpsysExit -eq 0) {
            $dumpsysText = $dumpsysOut -join "`n"
            $sections = @(Get-GatewayBoundAccessibilitySection -DumpsysText $dumpsysText)
            $boundedSections = [Collections.Generic.List[string]]::new()
            $maxSections = [Math]::Min($sections.Count, 16)
            for ($i = 0; $i -lt $maxSections; $i++) {
                $sec = [string]$sections[$i]
                if ($sec.Length -gt 512) { $sec = $sec.Substring(0, 512) + '...(truncated)' }
                $boundedSections.Add($sec)
            }
            $bound = Test-GatewayAccessibilityComponentBound -DumpsysText $dumpsysText -Component $fullComp -Label $label
            $accessibility.dumpsys_ok = $true
            $accessibility.gateway_bound = [bool]$bound
            $accessibility.bound_section_count = $sections.Count
            $accessibility.bound_sections = @($boundedSections.ToArray())
        }
        else {
            $errMsg = @($dumpsysOut | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
            $accessibility.dumpsys_error = if ($errMsg) { $errMsg } else { "dumpsys accessibility exited with $dumpsysExit" }
        }
    }
    catch {
        $accessibility.dumpsys_ok = $false
        $accessibility.dumpsys_error = $_.Exception.Message
    }

    return [ordered]@{
        schema = 'dispatch-transport-health-snapshot/v1'
        captured_at_utc = [DateTime]::UtcNow.ToString('o')
        slug = $Slug
        leg = $Leg
        executor = $Executor
        brain = $Brain
        trace_file = $TraceFile
        port = $Port
        landscape_prepare = $LandscapePrepare
        adb_forward = $adbForward
        health = $health
        gateway_service = $gatewayService
        accessibility = $accessibility
    }
}
