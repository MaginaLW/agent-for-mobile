#Requires -Version 7

function Get-ExecutorProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('mobile', 'gateway')][string]$Executor,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ScriptsRoot
    )

    switch ($Executor) {
        'mobile' {
            [pscustomobject]@{
                Name = 'mobile'
                McpConfigPath = Join-Path $RepoRoot 'configs\mobile-mcp.json'
                PreamblePath = Join-Path $ScriptsRoot 'prompts\executor-preamble.md'
                AllowedTools = 'mcp__mobile'
                RequiresNpx = $true
                RequiresGatewayConfig = $false
                RequiresPortForward = $false
            }
        }
        'gateway' {
            [pscustomobject]@{
                Name = 'gateway'
                McpConfigPath = Join-Path $RepoRoot 'configs\gateway-mcp.json'
                PreamblePath = Join-Path $ScriptsRoot 'prompts\gateway-executor-preamble.md'
                AllowedTools = 'mcp__gateway'
                RequiresNpx = $false
                RequiresGatewayConfig = $true
                RequiresPortForward = $true
            }
        }
    }
}

# gateway MCP 客户端配置里 per-server `timeout` 的下限（毫秒）。
# 取 420000 的算式：决定期 90s + 等前台预算 300s + 宏与输入开销 ~30s ≈ 420s。
# **这只解决第 1 层（60s 首字节计时器）**；第 2 层（300s 空闲看门狗）靠网关在阻塞期间
# 发 `notifications/progress` 心跳解决，两层缺一都会在真机上表现为同一个"客户端超时"。
# 三层天花板的实测见 docs/knowledge/brain/harness.md。
$GatewayMcpMinTimeoutMs = 420000

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

    # per-server `timeout` 缺席 = 客户端对 HTTP MCP 的**首字节计时器停在 60 秒**
    # （stdio/WebSocket 没有这一层，只有 HTTP/SSE 有）。语义意图那条链的 press_key
    # 会阻塞到 400s 量级，缺了这个字段一定被砍——2026-08-08 真机上已经烧过一轮，
    # 现场看到的是"客户端超时、无响应体、无错误码"，与"功能坏了"分不开。
    #
    # **配置是 gitignored 的私密文件，不随 checkout 过来**，所以这条只能在开跑前查。
    # 字段缺席按失败处理，不按"大概没事"处理。
    $timeout = $gateway.PSObject.Properties['timeout']
    if ($null -eq $timeout) {
        return ('gateway MCP 私密配置缺少 timeout 字段：HTTP 传输的首字节计时器默认 60s，' +
            "危险动作会阻塞更久。请照 example 加 `"timeout`": $GatewayMcpMinTimeoutMs。")
    }
    if ([int64]$timeout.Value -lt $GatewayMcpMinTimeoutMs) {
        return ("gateway MCP 私密配置的 timeout=$($timeout.Value) 小于下限 $GatewayMcpMinTimeoutMs，" +
            '不足以覆盖「决定 90s + 等前台 300s + 开销」。')
    }

    return $null
}
