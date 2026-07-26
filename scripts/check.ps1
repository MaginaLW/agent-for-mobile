#Requires -Version 7
<#
提交前一键校验。

此前"跑了哪些验证"只存在于人的记忆和提交说明里：JVM 单测、两套 PowerShell 离线测试、
diff-check、凭据扫描各跑各的，漏掉哪一项没人拦得住。本脚本把它们收成一条命令、一张汇总表，
任一项失败即非零退出。

用法：
  scripts/check.ps1              # 全量（含 gradle，首次冷跑几分钟）
  scripts/check.ps1 -SkipGradle  # 只跑脚本与仓库侧（改文档/PowerShell 时够用）
  scripts/check.ps1 -Clean       # 只清场：停 gradle daemon、删残留跑测目录与旧日志，不跑校验

执行顺序有意为之：先跑秒级的便宜检查（快失败），再 gradle，最慢的监督式 runner 套件放最后，
并在它开跑前停掉 gradle daemon 释放内存——那套件对进程启动延迟极敏感，daemon 常驻会把它压出
成片的假超时（2026-07-26 实测，详见 docs/knowledge/android/common.md）。

长输出一律先落盘再尾读（会话纪律 3）：完整日志在 .checks/（已 gitignore），失败时只把关键行打到屏幕。
#>
[CmdletBinding()]
param(
    [switch]$SkipGradle,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path $PSScriptRoot -Parent
$LogDir = Join-Path $RepoRoot '.checks'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$PwshPath = (Get-Process -Id $PID).Path
. (Join-Path $PSScriptRoot 'lib\dev-env.ps1')

if ($Clean) {
    Write-Host '清场：' -ForegroundColor Cyan
    # -Clean 是人显式要求的清场，可以动全机构建 daemon；但要说清楚它的波及范围。
    Write-Host '  注意：这一步会停掉本机**所有** Gradle/Kotlin 构建 daemon，其它项目正在跑的构建会被中断。' -ForegroundColor Yellow
    Write-Host "  构建 daemon → $(Stop-DevEnvGradleDaemon -RepoRoot $RepoRoot -Aggressive)"
    $sweep = Clear-DevEnvStaleFixture
    Write-Host "  残留跑测目录 → 删除 $($sweep.Removed) 个" -NoNewline
    if ($sweep.Failed.Count -gt 0) { Write-Host "，$($sweep.Failed.Count) 个删不掉（仍被占用）" -ForegroundColor Yellow }
    else { Write-Host '' }
    Get-ChildItem -LiteralPath $LogDir -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "  .checks/ 日志 → 已清空"
    Write-Host "`n清场后：$((Get-DevEnvSnapshot).Text)"
    exit 0
}

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
Write-Host "日志：$LogDir" -ForegroundColor DarkGray
$startSnapshot = Get-DevEnvSnapshot
Write-Host "机器：$($startSnapshot.Text)`n" -ForegroundColor DarkGray
if (-not $startSnapshot.Healthy) {
    Write-Host '提示：本机负载偏高。监督式 runner 套件对进程启动延迟极敏感，可能出现与代码无关的成片超时；' -ForegroundColor Yellow
    Write-Host '      先跑 scripts/check.ps1 -Clean 清场更稳。' -ForegroundColor Yellow
    Write-Host ''
}

# —— 秒级检查放最前：改错了要在等 10 分钟之前就知道 ——

Invoke-Check '空白字符与冲突标记（git diff --check）' {
    $output = & git -C $RepoRoot diff --check 2>&1
    # autocrlf 的换行提醒不是错误，只有真正的空白问题才让 git 非零退出。
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    'clean'
}

Invoke-Check '派单离线测试' {
    Invoke-Logged -LogName 'dispatch-offline.log' -FilePath $PwshPath -Arguments @(
        '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts\tests\dispatch-offline.ps1')
    ) | Out-Null
    Get-LastMeaningfulLine (Join-Path $LogDir 'dispatch-offline.log')
}

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

# —— 最慢的一项放最后，且先把 gradle daemon 占的内存还回来 ——

Invoke-Check '监督式 runner 离线测试' {
    # daemon 每个占 1GB 上下；这套件几十条各起一个子进程，内存紧张时会更容易出问题。
    # 这里**不加 -Aggressive**：常规校验不该去动其它项目的构建 daemon。
    if (-not $SkipGradle) { Stop-DevEnvGradleDaemon -RepoRoot $RepoRoot | Out-Null }
    Invoke-Logged -LogName 'runner-offline.log' -FilePath $PwshPath -Arguments @(
        '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts\tests\p0-supervised-runner-offline.ps1')
    ) | Out-Null
    Get-LastMeaningfulLine (Join-Path $LogDir 'runner-offline.log')
}

Invoke-Check '凭据扫描' {
    $issues = [Collections.Generic.List[string]]::new()

    # 含真实 token 的网关配置永远不入库（2026-07-18 曾误提交并 push，token 已作废）。
    & git -C $RepoRoot ls-files --error-unmatch 'configs/gateway-mcp.json' *>$null
    if ($LASTEXITCODE -eq 0) { $issues.Add('configs/gateway-mcp.json 被 git 跟踪。') }
    & git -C $RepoRoot check-ignore -q -- 'configs/gateway-mcp.json'
    if ($LASTEXITCODE -ne 0) { $issues.Add('configs/gateway-mcp.json 未被 gitignore 覆盖。') }

    # 网关 token 是 32 位裸 hex。当前仓库零命中，任何新命中都要人看一眼。
    #
    # --untracked 不能省：git grep 默认只搜已跟踪文件，于是新写的文件要等**提交之后**才被扫到。
    # 2026-07-27 实锤：BearerAuthGuardTest 里的假 token 恰好是 32 位十六进制，批次 D 跑 check
    # 时它还没入库、报了全绿，提交完才被抓出来。
    #
    # 注意这仍然只是**提交前跑一下**的人工闸门，不是强制拦截——仓库没有装 git hook，
    # 谁不跑 check.ps1 就绕过了。真要拦住提交得配 pre-commit hook（未做）。
    $hits = @(& git -C $RepoRoot grep -nIE --untracked '\b[0-9a-f]{32}\b' -- . 2>$null)
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
