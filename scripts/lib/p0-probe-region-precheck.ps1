#Requires -Version 7
<#
零 token 只读预检：P0 盲点候选区（微信输入栏带）当前是否视觉为空。

存在的理由是省钱与省人力：上一轮失败的 `type_text` 会把 marker 留在微信输入框，
而盲点探针**按设计**要求候选区为空（`P0FocusProbeValidator`，"空白输入框才允许盲点"
是刻意的安全属性，不该为了省事放宽）。不预检就会在 `focus_probe_validation` 白烧
一整轮派单，而且失败信息埋在 trace 里，人得翻半天才知道"去把输入框清一下"。

退出码：0=候选区为空可以开跑；2=有残留文字，需人工清空；1=探针本身不可用
（例如装的是不含该工具的旧 APK）——调用方应当只警告并继续，不要因此阻断跑测。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$Port = 8848,
    [int]$TimeoutSec = 20
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
    $body = '{"jsonrpc":"2.0","id":"p0-probe-region","method":"tools/call",' +
        '"params":{"name":"p0_probe_region_state","arguments":{}}}'
    $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    $response = $client.Send($request)
    if (-not $response.IsSuccessStatusCode) { throw 'http status' }
    $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    if ([string]$json.id -cne 'p0-probe-region' -or $null -eq $json.result) { throw 'protocol mismatch' }
    $text = [string]$json.result.content[0].text
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty tool payload' }
    $envelope = $text | ConvertFrom-Json
    if ($envelope.ok -ne $true -or $null -eq $envelope.data) { throw 'tool returned error envelope' }
    $data = $envelope.data
    if ($null -eq $data.PSObject.Properties['empty']) { throw 'tool payload missing empty' }
}
catch {
    [Console]::Error.WriteLine('候选区只读预检不可用（工具缺失或协议不符），跳过预检。')
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

if ($data.empty -eq $true) {
    [pscustomobject]@{ ok = $true; empty = $true } | ConvertTo-Json -Compress
    exit 0
}

# 残留文字原样回显给现场人——他要照着这个去手机上清框，不能只说"非空"。
$leftovers = @($data.texts | ForEach-Object { "「$($_.text)」@$([string]::Join(',', $_.bounds))" })
if ($data.visible_send_control -eq $true) { $leftovers += '底部出现可见「发送」控件' }
[pscustomobject]@{
    ok = $false
    empty = $false
    leftovers = $leftovers
} | ConvertTo-Json -Compress -Depth 4
exit 2
