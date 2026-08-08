#Requires -Version 7
<#
冷启动自举（`ForegroundWindowTracker.bootstrapFromWindow`）的真机验证。

**为什么需要一个专门的脚本，而不是塞进三腿验收**（2026-08-01 批次 1 验收回流第 3 条）：

自举只在"无障碍服务重启后、从未收到过任何窗口状态事件"时生效。而 `-Provision` 这条路
在重绑之后还要 `am start` 拉起 gateway 面板、再 `Start-P0TargetApp` 拉回微信——**每一步都
产生窗口事件**，身份被事件填上，自举永远轮不到。真机实测三次 `-Provision`，trace 里
`bootstrap` 零次出现。所以它不是 bug，是缺一个能构造那个场景的入口。

场景本身是**真实会发生的情形**，不是为测试硬凑的：用户停在微信会话页不动，无障碍服务
在底下重启（重装、系统回收、无障碍开关被动过）。此时没有任何窗口变化，也就没有事件。
本脚本只是把"服务重启"这一步显式做出来，屏幕状态与用户不动手的前提**一模一样**。

**为什么不并进三腿验收**：自举身份没有 activity，而危险动作在确认前后要求 package/activity
逐字段相等。若确认期间身份从自举升级成事件身份（overlay 收起时 App 窗口重新获焦就可能
产生事件），`activityName` 会从空串变成真实类名 → `E_STALE_REF`。那是**正确的 fail-closed**，
但会让 Allow 腿平白多一条与它要证明的东西无关的失败原因。验收要一把过，不该背这个风险。

因此本脚本：**零 token、不派单、不触发任何危险动作、不需要确认卡**。
它只经 runner 自己的通道读 `foreground_app`（R 级只读，`foreground_known=false` 时也可调）。

用法（设备上先手动把微信停在「文件传输助手」会话页，然后**不要再碰手机**）：

    pwsh -NoProfile -File scripts/p0-foreground-bootstrap-check.ps1 -Provision

退出码：0=passed；3=not_reproduced（场景没构造成功，**不是通过**）；
4=unavailable（读不出字段）；1=failed 或环境问题。
#>
[CmdletBinding()]
param(
    [switch]$Provision,
    [string]$RepoRootOverride,
    [string]$AdbPath = 'adb',
    [string]$HealthProbePath,
    [int]$A11yBindTimeoutSec = 45,
    # 重绑后等身份稳定：服务 connected 与窗口列表可读之间还有一小段。
    [int]$SettleSec = 5,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRootOverride)) { Split-Path $PSScriptRoot -Parent } else { $RepoRootOverride }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
if ([string]::IsNullOrWhiteSpace($HealthProbePath)) {
    $HealthProbePath = Join-Path $RepoRoot 'scripts\lib\p0-gateway-health-probe.ps1'
}
. (Join-Path $RepoRoot 'scripts\lib\p0-device-provision.ps1')
. (Join-Path $RepoRoot 'scripts\lib\p0-foreground-bootstrap.ps1')

if ($DryRun) {
    Write-Host "[DryRun] 冷启动自举检查：provision=$([bool]$Provision) settle=${SettleSec}s"
    Write-Host '[DryRun] 不连接设备、不重绑无障碍、不读取任何设备状态。'
    exit 0
}

<# 经 runner 自己的 HTTP 通道调 R 级 `foreground_app`；不经执行器、不进 trace、不花 token。 #>
function Read-P0ForegroundDiagnostics {
    param([Parameter(Mandatory)][string]$ConfigPath, [int]$Port = 8848, [int]$TimeoutSec = 20)

    $client = $null
    $request = $null
    $response = $null
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $authorization = [string]$config.mcpServers.gateway.headers.Authorization
        if ($authorization -notmatch '^Bearer\s+([^\s]+)$') { throw 'invalid config' }
        $token = $Matches[1]
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $request = [Net.Http.HttpRequestMessage]::new(
            [Net.Http.HttpMethod]::Post, "http://127.0.0.1:$Port/mcp"
        )
        # **显式声明要整包 JSON，不靠"我恰好没发 Accept"这种巧合。**
        # 网关的 tools/call 会按 Accept 协商：带 text/event-stream 才回 SSE。
        # 2026-08-08 网关改流式时这里被打死过一次——`data: {...}` 的第一个字符 `d`
        # 直接顶翻 ConvertFrom-Json，连锁成"marker 不在合法消息区"，Allow 腿在第 1 腿判死，
        # 而消息其实已经发出去了。这一行就是那次的补丁，别删。
        $request.Headers.Accept.ParseAdd('application/json')
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
        $body = '{"jsonrpc":"2.0","id":"p0-foreground","method":"tools/call",' +
            '"params":{"name":"foreground_app","arguments":{}}}'
        $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        $response = $client.Send($request)
        if (-not $response.IsSuccessStatusCode) { throw 'http status' }
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $envelope = ([string]$json.result.content[0].text) | ConvertFrom-Json
        if ($envelope.ok -ne $true) { throw 'tool returned error envelope' }
        return $envelope.data
    }
    catch { return $null }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        $token = $null
    }
}

$session = $null
$exitCode = 1
try {
    $session = Start-P0DeviceProvision -RepoRoot $RepoRoot -AdbPath $AdbPath -Provision:$Provision `
        -HealthProbePath $HealthProbePath -A11yBindTimeoutSec $A11yBindTimeoutSec

    # 1. 先把微信摆到前台并让它静止下来。这一步**故意**允许产生窗口事件——
    #    基线就应该是"身份由事件建立"，否则后面分不清自举有没有真的接管。
    Start-P0TargetApp -Session $session
    Start-Sleep -Seconds $SettleSec
    if (-not (Test-P0TargetAppForeground -Session $session)) {
        throw 'setup-fail：微信未停在前台，无法构造"服务重启时屏幕静止"的场景。'
    }
    $beforeData = Read-P0ForegroundDiagnostics -ConfigPath $session.ConfigPath
    $before = Get-P0ForegroundIdentityKind -Data $beforeData
    Write-Host "重绑前身份来源：$before"

    # 2. 重绑无障碍服务。**这之后一个窗口都不许动**——不 am start、不发按键、不切 App。
    #    tracker 随服务重建而归零，屏幕静止则不会有任何窗口状态事件到来。
    Write-Host '重绑无障碍服务（此后不再触碰任何窗口）...'
    Invoke-P0AccessibilityRebind -Session $session
    if (-not (Wait-P0AccessibilityBound -Session $session -TimeoutSec $A11yBindTimeoutSec)) {
        throw 'setup-fail：重绑后 gateway 无障碍服务未 bound/connected。'
    }
    Start-Sleep -Seconds $SettleSec

    # 3. 只读一次前台身份。foreground_app 是 R 级，identity 未建立时照样可调——
    #    正因如此它才能如实报出 unset，而不是被安全门挡掉后只留一个 E_BLOCKED。
    $afterData = Read-P0ForegroundDiagnostics -ConfigPath $session.ConfigPath
    $after = Get-P0ForegroundIdentityKind -Data $afterData
    $consistency = Test-P0BootstrapSelfConsistent -Data $afterData
    $verdict = Get-P0BootstrapVerdict -Before $before -After $after -AfterSelfConsistent $consistency.Ok

    Write-Host "重绑后身份来源：$after"
    Write-Host ''
    switch ($verdict.Verdict) {
        'passed' {
            Write-Host '自举分支已被真机触达并通过：重绑前 event → 重绑后 bootstrap，且为 package 级无 activity。' -ForegroundColor Green
            $exitCode = 0
        }
        'not_reproduced' {
            # 与"通过"分得清清楚楚。上一轮就是把未触达当成了没问题。
            Write-Host "场景未复现，判据**未触达**（不是通过）：$($verdict.Reason)" -ForegroundColor Yellow
            $exitCode = 3
        }
        'unavailable' {
            Write-Host "无法判定：$($verdict.Reason)" -ForegroundColor Yellow
            $exitCode = 4
        }
        default {
            Write-Host "自举分支判失败：$($verdict.Reason)" -ForegroundColor Red
            if ($consistency.Issues.Count -gt 0) { Write-Host "  自洽性问题：$($consistency.Issues -join '；')" -ForegroundColor Red }
            $exitCode = 1
        }
    }
}
catch {
    Write-Host "冷启动自举检查失败：$($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
}
finally {
    if ($null -ne $session) {
        $issues = @(try { Stop-P0DeviceProvision -Session $session } catch { @('device_provision_cleanup') })
        if ($issues.Count -gt 0) { Write-Host "清理问题：$($issues -join '；')" -ForegroundColor Yellow }
    }
}
exit $exitCode
