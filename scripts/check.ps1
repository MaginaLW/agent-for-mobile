#Requires -Version 7
<#
提交前一键校验。

此前"跑了哪些验证"只存在于人的记忆和提交说明里：JVM 单测、两套 PowerShell 离线测试、
diff-check、凭据扫描各跑各的，漏掉哪一项没人拦得住。本脚本把它们收成一条命令、一张汇总表，
任一项失败即非零退出。

用法：
  scripts/check.ps1              # 全量（含 gradle，首次冷跑几分钟）
  scripts/check.ps1 -SkipGradle  # 只跑脚本与仓库侧（改文档/PowerShell 时够用）

长输出一律先落盘再尾读（会话纪律 3）：完整日志在 .checks/（已 gitignore），失败时只把关键行打到屏幕。
#>
[CmdletBinding()]
param(
    [switch]$SkipGradle
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path $PSScriptRoot -Parent
$LogDir = Join-Path $RepoRoot '.checks'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$PwshPath = (Get-Process -Id $PID).Path

$results = [Collections.Generic.List[object]]::new()

function Invoke-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Write-Host "▶ $Name" -ForegroundColor Cyan
    $started = [DateTime]::UtcNow
    $detail = ''
    $ok = $false
    try {
        $detail = [string](& $Body)
        $ok = $true
    }
    catch {
        $detail = $_.Exception.Message
    }
    $elapsed = [int]([DateTime]::UtcNow - $started).TotalSeconds
    $results.Add([pscustomobject]@{ Name = $Name; Ok = $ok; Seconds = $elapsed; Detail = $detail })
    if ($ok) { Write-Host "  PASS  ${elapsed}s $detail" -ForegroundColor Green }
    else { Write-Host "  FAIL  ${elapsed}s $detail" -ForegroundColor Red }
}

function Invoke-Logged {
    <# 跑一条命令，全量输出落盘，失败时只回关键行。 #>
    param(
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string[]]$FailurePatterns = @('FAILED', 'FAILURE', 'error:', 'Exception', 'failed')
    )
    $logPath = Join-Path $LogDir $LogName
    & $FilePath @Arguments *>&1 | Set-Content -LiteralPath $logPath -Encoding utf8
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $pattern = ($FailurePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $lines = @(Select-String -LiteralPath $logPath -Pattern $pattern |
            Select-Object -Last 12 | ForEach-Object { $_.Line.Trim() })
        if ($lines.Count -eq 0) { $lines = @(Get-Content -LiteralPath $logPath -Tail 12) }
        throw ("退出码 $exitCode，完整日志 .checks/$LogName`n    " + ($lines -join "`n    "))
    }
    return $logPath
}

function Get-LastMeaningfulLine {
    param([Parameter(Mandatory)][string]$Path)
    $line = @(Get-Content -LiteralPath $Path | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) |
        Select-Object -Last 1
    if ($null -eq $line) { return '' }
    return $line.Trim()
}

Write-Host "仓库：$RepoRoot" -ForegroundColor DarkGray
Write-Host "日志：$LogDir`n" -ForegroundColor DarkGray

if ($SkipGradle) {
    Write-Host '跳过 gradle（-SkipGradle）：Kotlin 侧未验证。' -ForegroundColor Yellow
    $results.Add([pscustomobject]@{ Name = 'gateway JVM 单测与构建'; Ok = $null; Seconds = 0; Detail = '已跳过' })
}
else {
    Invoke-Check 'gateway JVM 单测与构建' {
        $gradlew = Join-Path $RepoRoot 'app\gradlew.bat'
        if (-not (Test-Path -LiteralPath $gradlew -PathType Leaf)) { throw "缺少 gradle wrapper：$gradlew" }
        Invoke-Logged -LogName 'gradle.log' -FilePath $gradlew -Arguments @(
            '-p', (Join-Path $RepoRoot 'app'),
            ':gateway:testDebugUnitTest', ':gateway:testReleaseUnitTest', ':gateway:assembleDebug',
            '--console=plain'
        ) | Out-Null
        'testDebug + testRelease + assembleDebug'
    }
}

Invoke-Check '派单离线测试' {
    Invoke-Logged -LogName 'dispatch-offline.log' -FilePath $PwshPath -Arguments @(
        '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts\tests\dispatch-offline.ps1')
    ) | Out-Null
    Get-LastMeaningfulLine (Join-Path $LogDir 'dispatch-offline.log')
}

Invoke-Check '监督式 runner 离线测试' {
    Invoke-Logged -LogName 'runner-offline.log' -FilePath $PwshPath -Arguments @(
        '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts\tests\p0-supervised-runner-offline.ps1')
    ) | Out-Null
    Get-LastMeaningfulLine (Join-Path $LogDir 'runner-offline.log')
}

Invoke-Check '空白字符与冲突标记（git diff --check）' {
    $output = & git -C $RepoRoot diff --check 2>&1
    # autocrlf 的换行提醒不是错误，只有真正的空白问题才让 git 非零退出。
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    'clean'
}

Invoke-Check '凭据扫描' {
    $issues = [Collections.Generic.List[string]]::new()

    # 含真实 token 的网关配置永远不入库（2026-07-18 曾误提交并 push，token 已作废）。
    & git -C $RepoRoot ls-files --error-unmatch 'configs/gateway-mcp.json' *>$null
    if ($LASTEXITCODE -eq 0) { $issues.Add('configs/gateway-mcp.json 被 git 跟踪。') }
    & git -C $RepoRoot check-ignore -q -- 'configs/gateway-mcp.json'
    if ($LASTEXITCODE -ne 0) { $issues.Add('configs/gateway-mcp.json 未被 gitignore 覆盖。') }

    # 网关 token 是去掉短横的 UUID：恰好 32 位裸 hex。当前仓库零命中，任何新命中都要人看一眼。
    $hits = @(& git -C $RepoRoot grep -nIE '\b[0-9a-f]{32}\b' -- . 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw 'git grep 执行失败。' }
    if ($hits.Count -gt 0) {
        $issues.Add("疑似 token 形态（32 位裸 hex）命中 $($hits.Count) 处：`n    " +
            (($hits | Select-Object -First 5) -join "`n    "))
    }

    if ($issues.Count -gt 0) { throw ($issues -join "`n  ") }
    'gateway-mcp.json 未入库且被忽略；无 32 位裸 hex 命中'
}

Write-Host "`n================ 汇总 ================"
foreach ($item in $results) {
    $tag = if ($null -eq $item.Ok) { 'SKIP' } elseif ($item.Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($null -eq $item.Ok) { 'Yellow' } elseif ($item.Ok) { 'Green' } else { 'Red' }
    Write-Host ("{0,-4}  {1,-28} {2,4}s" -f $tag, $item.Name, $item.Seconds) -ForegroundColor $color
}

$failed = @($results | Where-Object { $_.Ok -eq $false })
$skipped = @($results | Where-Object { $null -eq $_.Ok })
if ($failed.Count -gt 0) {
    Write-Host "`n$($failed.Count) 项失败，完整日志在 .checks/。" -ForegroundColor Red
    exit 1
}
if ($skipped.Count -gt 0) {
    Write-Host "`n全部通过，但有 $($skipped.Count) 项跳过——不等于全绿。" -ForegroundColor Yellow
    exit 0
}
Write-Host "`n全部通过。" -ForegroundColor Green
exit 0
