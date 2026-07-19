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
