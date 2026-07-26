#Requires -Version 7
<#
开发机跑测环境的体检与清场。

为什么需要它：监督式 runner 离线套件 39 条用例每条都要起 pwsh 子进程、造一个临时仓库副本，
单条 8–9 秒，整轮 9–17 分钟。**它的失败率是机器状态的函数，不是代码的函数**——2026-07-26
同一个提交当天先跑出 38/38，几小时后（3–4 个常驻 gradle daemon、81 个被 kill 的跑测残留目录、
可用内存降到 ~3GB）跑出 11/38，失败全是进程启动超时，没有一条断言失败。

所以：跑之前先看一眼机器，跑完顺手清干净，别让下一轮替这一轮还债。
#>

$DevEnvFixturePatterns = @(
    'agent-mobile-p0-runner-*',
    'agent-mobile-p0-tmpl-*',
    'agent-mobile-dispatch-offline-*',
    'agent-mobile-failreason-*'
)

<#
自动清扫的默认年龄下限。

不能是 0：那样"1 毫秒前刚建好的目录"也算残留，两个套件并行跑（或人手跑一个、check.ps1 跑
另一个）会互删对方正在用的工作目录。真机 runner 用的是别的前缀，不受影响，但没必要留这个坑。
人显式 -Clean 时才用 0——那是他自己要求的全清。
#>
$DevEnvDefaultStaleMinutes = 30

<# 被 kill 的跑测不会执行 finally，残留目录只能靠外部扫。 #>
function Get-DevEnvStaleFixture {
    param([int]$OlderThanMinutes = 0)
    $cutoff = [DateTime]::Now.AddMinutes(-$OlderThanMinutes)
    $temp = [IO.Path]::GetTempPath()
    foreach ($pattern in $DevEnvFixturePatterns) {
        Get-ChildItem -LiteralPath $temp -Directory -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff }
    }
}

<#
删除残留跑测目录。返回 @{ Removed; Failed }。

**不静默吞失败**：删不掉通常意味着有进程还攥着句柄（被 kill 的 runner 正在退出），
悄悄跳过就会攒成几十个目录，最后以"莫名其妙的超时"形式还回来。
#>
function Clear-DevEnvStaleFixture {
    param(
        [int]$OlderThanMinutes = 0,
        [int]$RetryCount = 3,
        [int]$RetryDelayMs = 400
    )
    $removed = 0
    $failed = [Collections.Generic.List[string]]::new()
    foreach ($dir in @(Get-DevEnvStaleFixture -OlderThanMinutes $OlderThanMinutes)) {
        $ok = $false
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                $ok = $true
                break
            }
            catch {
                if ($attempt -lt $RetryCount) { Start-Sleep -Milliseconds $RetryDelayMs }
            }
        }
        if ($ok) { $removed++ } else { [void]$failed.Add($dir.Name) }
    }
    return [pscustomobject]@{ Removed = $removed; Failed = [string[]]$failed }
}

<#
只认构建 daemon，不按 java 进程数瞎算——这台机器上还跑着与本项目无关的 JVM。
Gradle daemon 与 **Kotlin 编译 daemon** 是两个进程，`gradlew --stop` 只管前者，
后者照样常驻吃内存，得单独点名。
#>
function Get-DevEnvBuildDaemon {
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'GradleDaemon|KotlinCompileDaemon|kotlin-daemon-embeddable' }
}

<#
停掉常驻构建 daemon：每个占 1GB 上下，正是把这台机器压过阈值的那部分。

**默认只动本仓库的 daemon**。`gradlew --stop` 本身就是按 gradle 用户目录/项目定向的；
而按命令行匹配去 `Stop-Process -Force` 是全机行为——`GradleDaemon` 出现在这台机器上
**每一个** Gradle daemon 的命令行里，`kotlin-daemon-embeddable` 更宽（任何 Kotlin 构建的
classpath 上都有）。若此时 Android Studio 正在给别的项目跑构建，就会被连坐杀掉。

所以强杀改为显式 opt-in（`-Aggressive`），且只有 check.ps1 的 -Clean 会用。
#>
function Stop-DevEnvGradleDaemon {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Aggressive
    )
    $before = @(Get-DevEnvBuildDaemon).Count
    $gradlew = Join-Path $RepoRoot 'app\gradlew.bat'
    if (Test-Path -LiteralPath $gradlew -PathType Leaf) { & $gradlew --stop *>&1 | Out-Null }
    # --stop 是异步请求，daemon 要一会儿才真退。
    Start-Sleep -Seconds 2
    if ($Aggressive) {
        # Kotlin 编译 daemon 不归 gradlew --stop 管，只能点名——但这一步是全机的，
        # 会波及本机其它项目的构建，所以必须由调用方显式要求。
        foreach ($proc in @(Get-DevEnvBuildDaemon)) {
            try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch {}
        }
        Start-Sleep -Milliseconds 500
    }
    $after = @(Get-DevEnvBuildDaemon).Count
    $scope = if ($Aggressive) { '本机全部构建 daemon' } else { '本仓库 gradle daemon' }
    return "$scope $before → $after"
}

<# 一行机器快照，跑长套件前打一眼；数字异常时人能立刻知道该先清场。 #>
function Get-DevEnvSnapshot {
    $free = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
    $stale = @(Get-DevEnvStaleFixture).Count
    $daemons = @(Get-DevEnvBuildDaemon).Count
    return [pscustomobject]@{
        FreeMemoryMb = $free
        StaleFixtures = $stale
        BuildDaemons = $daemons
        Text = "可用内存 ${free}MB · 残留跑测目录 $stale · 构建 daemon $daemons"
        # 阈值凭 2026-07-26 那轮实测定：3GB 可用内存 + 大量残留时整轮成片假超时。
        Healthy = ($free -ge 4096 -and $stale -le 5)
    }
}
