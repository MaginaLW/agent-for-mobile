#Requires -Version 7
<#
离线连接性用例专用的最小网关：**只负责按 `Accept` 把 `tools/call` 的响应帧发对**，
其余一概不管（不做鉴权、不做业务）。

存在的理由是 2026-08-08 那次翻车：网关把 `tools/call` 改成无条件 SSE，而仓库里还有两个
**直连 HTTP 的只读探针**把响应体当整包 JSON 解析，`data: {...}` 的第一个字符就把它们打死。
**`check.ps1` 五项全绿放它过去了**——因为离线假网关一直只回纯 JSON，
**没有任何一处把探针的 HTTP 解析器与真实传输帧接起来**。这个文件就是那根缺失的线。

⚠️ **它是仿制品，不是被测的那台网关。** 它复刻的是 `AcceptNegotiation.wantsEventStream`
那条规则；规则本身由 Kotlin 侧 `AcceptNegotiationTest` 钉住（含实测到的真实客户端 Accept）。
两边共用的是**规则**，不是代码——这一层残留风险如实写在这里，别当成已经闭合。
#>
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$LogPath,
    # 工具信封的 data 段（JSON 串）。默认是"候选区为空、探针放行"。
    [string]$EnvelopeData = '{"empty":true,"probe_ready":true,"region":[100,1900,980,2050],"texts":[]}'
)
$ErrorActionPreference = 'Stop'
function Log($m) { Add-Content -LiteralPath $LogPath -Value ("{0:o} {1}" -f [DateTime]::UtcNow, $m) }

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Log "listening $Port"
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response
        $body = ''
        if ($req.HasEntityBody) {
            $reader = [IO.StreamReader]::new($req.InputStream, $req.ContentEncoding)
            $body = $reader.ReadToEnd(); $reader.Close()
        }
        $accept = [string]$req.Headers['Accept']
        Log "REQ accept=$accept"
        if ($body -match '"id"\s*:\s*"([^"]+)"') { $id = $Matches[1] } else { $id = 'unknown' }
        if ($body -like '*"method":"shutdown"*') { $res.StatusCode = 200; $res.Close(); break }

        $envelope = '{"ok":true,"data":' + $EnvelopeData + '}'
        $payload = [ordered]@{
            jsonrpc = '2.0'
            id = $id
            result = [ordered]@{
                content = @([ordered]@{ type = 'text'; text = $envelope })
                isError = $false
            }
        } | ConvertTo-Json -Depth 10 -Compress

        # 与网关同一条规则：Accept 里逐项比出 text/event-stream 才走流式。
        $wantsStream = $false
        foreach ($part in ($accept -split ',')) {
            if (($part -split ';')[0].Trim() -ieq 'text/event-stream') { $wantsStream = $true }
        }
        $res.StatusCode = 200
        if ($wantsStream) {
            $res.ContentType = 'text/event-stream'
            $res.SendChunked = $true
            $bytes = [Text.Encoding]::UTF8.GetBytes("data: $payload`n`n")
            Log '  -> SSE frame'
        } else {
            $res.ContentType = 'application/json'
            $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
            $res.ContentLength64 = $bytes.Length
            Log '  -> plain JSON'
        }
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }
}
finally { $listener.Stop(); $listener.Close(); Log 'stopped' }
