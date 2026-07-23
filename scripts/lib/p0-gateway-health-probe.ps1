#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$Port = 8848,
    [int]$TimeoutSec = 5
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$token = $null
$authorization = $null
$config = $null
$client = $null
$request = $null
$response = $null
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $authorization = [string]$config.mcpServers.gateway.headers.Authorization
    if ($authorization -notmatch '^Bearer\s+([^\s]+)$') { throw 'invalid config' }
    $token = $Matches[1]

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $request = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Post,
        "http://127.0.0.1:$Port/mcp"
    )
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $body = '{"jsonrpc":"2.0","id":"p0-health","method":"ping","params":{}}'
    $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    $response = $client.Send($request)
    if (-not $response.IsSuccessStatusCode) { throw 'http status' }
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    if ([string]$json.jsonrpc -cne '2.0' -or [string]$json.id -cne 'p0-health' -or $null -eq $json.result) {
        throw 'protocol mismatch'
    }
    [pscustomobject]@{ ok = $true; protocol = 'mcp-ping' } | ConvertTo-Json -Compress
    exit 0
}
catch {
    [Console]::Error.WriteLine('gateway 本地 TCP/MCP 协议健康探测失败。')
    exit 1
}
finally {
    $token = $null
    $authorization = $null
    $config = $null
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
}
