#Requires -Version 7
<#
零 token 只读预检：P0 盲点候选区（微信输入栏带）当前是否视觉为空。

存在的理由是省钱与省人力：上一轮失败的 `type_text` 会把 marker 留在微信输入框，
而盲点探针**按设计**要求候选区为空（`P0FocusProbeValidator`，"空白输入框才允许盲点"
是刻意的安全属性，不该为了省事放宽）。不预检就会在 `focus_probe_validation` 白烧
一整轮派单，而且失败信息埋在 trace 里，人得翻半天才知道"去把输入框清一下"。

退出码：0=候选区为空可以开跑；2=有残留文字或探针不放行，需人工处理；1=探针本身不可用
（例如装的是不含该工具的旧 APK）——调用方应当只警告并继续，不要因此阻断跑测。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [int]$Port = 8848,
    [int]$TimeoutSec = 20,
    # -Provision 刚重装完 APK 时无障碍服务还在重启，工具会回错误信封。
    # 2026-07-31 实测：三轮里两轮预检因此报"不可用"，而它是省钱的闸门，静默失效等于没有。
    [int]$ReadyRetries = 6,
    [int]$ReadyRetryDelayMs = 1000,
    # 上面那道重试**只在拿到错误信封时**才重试，覆盖不到"答得成功但内容还没稳"：
    # 服务重启后视觉/窗口状态要再过一段才稳定，此时 ok=true、empty=true，只有 probe_ready=false，
    # 于是一次就落进硬失败。2026-07-31 实测：provision 后那次报「标题命中但不可信 stage=CONTENT」，
    # 两分半后同一台设备、没人碰过手机、微信一直停在会话页，同一个预检直接通过。
    # 因此这一种也给有界重试，并把 attempts 如实带进输出——**重试第 2 次才过就坐实了是稳定性竞态，
    # 一直不过就说明页面真有问题**，下一次不用再靠猜。
    [int]$NotReadyRetries = 10,
    [int]$NotReadyRetryDelayMs = 2000
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# 旧 APK 不报新字段；Set-StrictMode 下读不存在的属性是硬错误，必须先探再读。
function Get-P0ProbeProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# 一次调用 = 一个全新的 HttpRequestMessage（HttpClient 不允许复用已发送的请求对象）。
function Invoke-P0ProbeCall {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][int]$Port
    )
    $request = $null
    $response = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::Post,
            "http://127.0.0.1:$Port/mcp"
        )
        # **显式声明要整包 JSON，不靠"我恰好没发 Accept"这种巧合。**
        # 网关的 tools/call 会按 Accept 协商：带 text/event-stream 才回 SSE。
        # 2026-08-08 网关改流式时这里被打死过一次——`data: {...}` 的第一个字符 `d`
        # 直接顶翻 ConvertFrom-Json，连锁成"marker 不在合法消息区"，Allow 腿在第 1 腿判死，
        # 而消息其实已经发出去了。这一行就是那次的补丁，别删。
        $request.Headers.Accept.ParseAdd('application/json')
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        $request.Content = [Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
        $response = $Client.Send($request)
        if (-not $response.IsSuccessStatusCode) { throw 'http status' }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ([string]$json.id -cne 'p0-probe-region' -or $null -eq $json.result) { throw 'protocol mismatch' }
        $text = [string]$json.result.content[0].text
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty tool payload' }
        $envelope = $text | ConvertFrom-Json
        if ($envelope.ok -ne $true -or $null -eq $envelope.data) { throw 'tool returned error envelope' }
        $candidate = $envelope.data
        if ($null -eq $candidate.PSObject.Properties['empty']) { throw 'tool payload missing empty' }
        return $candidate
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
    }
}

$token = $null
$authorization = $null
$config = $null
$client = $null
$data = $null
$attempts = 0
$waitedMs = 0
try {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
    $authorization = [string]$config.mcpServers.gateway.headers.Authorization
    if ($authorization -notmatch '^Bearer\s+([^\s]+)$') { throw 'invalid config' }
    $token = $Matches[1]

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $body = '{"jsonrpc":"2.0","id":"p0-probe-region","method":"tools/call",' +
        '"params":{"name":"p0_probe_region_state","arguments":{}}}'

    $lastProblem = 'unknown'
    $readyRounds = [Math]::Max(1, $ReadyRetries)
    $notReadyRounds = [Math]::Max(1, $NotReadyRetries)
    for ($round = 1; $round -le $notReadyRounds; $round++) {
        # 就绪重试：错误信封基本都是"服务刚重启还没绑好"，等一等就好；
        # 协议不符/HTTP 失败这类结构性问题重试也没用，但一并等一轮代价极小。
        $data = $null
        for ($attempt = 1; $attempt -le $readyRounds; $attempt++) {
            $attempts++
            try {
                $data = Invoke-P0ProbeCall -Client $client -Token $token -Body $body -Port $Port
                break
            }
            catch {
                $lastProblem = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
                if ($attempt -lt $readyRounds) { Start-Sleep -Milliseconds $ReadyRetryDelayMs }
            }
        }
        if ($null -eq $data) { throw "重试 $readyRounds 次仍不可用（$lastProblem）" }

        # 只有"答得成功、候选区也是空的、但探针不放行"这一种才继续等。
        # 候选区有残留文字（empty=false）是**只有人能解决**的，等下去只是白等。
        $probeReady = Get-P0ProbeProperty -Object $data -Name 'probe_ready'
        if (-not ($data.empty -eq $true -and $probeReady -eq $false)) { break }
        if ($round -lt $notReadyRounds) {
            Start-Sleep -Milliseconds $NotReadyRetryDelayMs
            $waitedMs += $NotReadyRetryDelayMs
        }
    }
}
catch {
    # **必须说出是哪一步坏的。** 这道闸门的全部价值是省掉一轮真机，而它静默失效时
    # 只会打印一句"不可用"，于是 2026-07-31 连着两轮跑测都在没有预检的情况下开跑，
    # 事后连"为什么不可用"都无从查起（脚本单独跑却是好的）。
    # 脱敏：token 只出现在请求头里，不会进异常消息；仍按 32 位裸 hex 兜底擦一遍。
    $reason = "$($_.Exception.GetType().Name): $($_.Exception.Message)" -replace '[0-9a-f]{32}', '<redacted>'
    # 原因走 **stdout**：调用方 Invoke-P0ExternalText 只回 ExitCode 与 Stdout，stderr 会被丢掉，
    # 只写 stderr 等于白写（这正是它静默失效两轮的原因）。
    [pscustomobject]@{ ok = $false; available = $false; reason = $reason; attempts = $attempts } |
        ConvertTo-Json -Compress
    [Console]::Error.WriteLine("候选区只读预检不可用（$reason），跳过预检。")
    exit 1
}
finally {
    $token = $null
    $authorization = $null
    $config = $null
    if ($null -ne $client) { $client.Dispose() }
}

$probeReady = Get-P0ProbeProperty -Object $data -Name 'probe_ready'
# region 一并带出：runner 的"marker 必须在消息区"判据在微信上拿不到 a11y 焦点几何，
# 需要用设备自报的输入栏候选区来划线（见 run-p0-safety-smoke.ps1 的 Test-P0MessageRegionMatch）。
$region = Get-P0ProbeProperty -Object $data -Name 'region'
if ($data.empty -eq $true -and $probeReady -ne $false) {
    [pscustomobject]@{ ok = $true; empty = $true; region = $region; attempts = $attempts } |
        ConvertTo-Json -Compress -Depth 4
    exit 0
}

if ($data.empty -ne $true) {
    # 残留文字原样回显给现场人——他要照着这个去手机上清框，不能只说"非空"。
    $leftovers = @($data.texts | ForEach-Object { "「$($_.text)」@$([string]::Join(',', $_.bounds))" })
    if ($data.visible_send_control -eq $true) { $leftovers += '底部出现可见「发送」控件' }
    [pscustomobject]@{
        ok = $false
        empty = $false
        region = $region
        attempts = $attempts
        remedy = '请在手机上清空微信输入框后重跑'
        leftovers = $leftovers
    } | ConvertTo-Json -Compress -Depth 4
    exit 2
}

# 输入框是空的但盲点探针仍不会放行：多半是微信没停在「文件传输助手」会话页
# （2026-07-26 实测烧掉一轮 $0.32 就是这个）。原因用宏自己的逐条说明，不另写一份。
# attempts/waited_ms 一并回显：等了整整 $waitedMs 毫秒还是这个结论，就不是"没稳住"能解释的了。
[pscustomobject]@{
    ok = $false
    empty = $true
    probe_ready = $false
    region = $region
    attempts = $attempts
    waited_ms = $waitedMs
    remedy = '请把微信停在「文件传输助手」会话页后重跑'
    reason = [string]$data.reason
} | ConvertTo-Json -Compress -Depth 4
exit 2
