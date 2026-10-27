#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\lib\dev-env.ps1')
$passed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++ }
    catch { throw "用例 $Name 失败：$($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Reason) {
    if (-not $Condition) { throw $Reason }
}
# 不读取实际机器的 CIM；模拟正常、无数据和受限宿主。
function Get-DevEnvStaleFixture { }
function Get-CimInstance {
    param($ClassName, $Filter, $ErrorAction)
    if ($script:cimMode -eq 'denied') { throw 'CIM unavailable' }
    if ($script:cimMode -eq 'empty') { return }
    if ($ClassName -eq 'Win32_OperatingSystem') {
        [pscustomobject]@{ FreePhysicalMemory = $script:freeKb }
    } else {
        [pscustomobject]@{ CommandLine = 'GradleDaemon'; ProcessId = 123 }
        [pscustomobject]@{ CommandLine = 'unrelated JVM'; ProcessId = 456 }
    }
}
$script:cimMode = 'available'
$script:freeKb = 8 * 1024 * 1024
Test-Case 'healthy snapshot keeps measured values' {
    $snapshot = Get-DevEnvSnapshot
    Assert-True ($snapshot.FreeMemoryMb -eq 8192 -and $snapshot.BuildDaemons -eq 1 -and $snapshot.Healthy) '正常环境测量丢失。'
}
$script:freeKb = 1024 * 1024
Test-Case 'low memory stays unhealthy' {
    $snapshot = Get-DevEnvSnapshot
    Assert-True ($snapshot.FreeMemoryMb -eq 1024 -and -not $snapshot.Healthy) '低内存被误报健康。'
}
foreach ($mode in @('denied', 'empty')) {
    $script:cimMode = $mode
    Test-Case "$mode memory remains unknown" {
        $snapshot = Get-DevEnvSnapshot
        Assert-True ($null -eq $snapshot.FreeMemoryMb -and -not $snapshot.Healthy) '未知内存不能当作实测值或健康状态。'
        Assert-True ($snapshot.Text.Contains('可用内存 未知')) '未知内存缺少可读说明。'
        if ($script:cimMode -eq 'denied') {
            Assert-True ($null -eq $snapshot.BuildDaemons -and $snapshot.Text.Contains('构建 daemon 未知')) '失败查询不能伪装为零 daemon。'
        } else {
            Assert-True ($snapshot.BuildDaemons -eq 0) '成功查询无进程应为零 daemon。'
        }
    }
}

# 执行 check.ps1 的实际检查块，拦截外部命令；不启动 Gradle 或 runner。
$parseErrors = $null
$tokens = $null
$checkPath = Join-Path $PSScriptRoot '..\check.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($checkPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'check.ps1 语法解析失败。' }
function Get-CheckBody([string]$Name) {
    $commands = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-Check'
    }, $true) | Where-Object { $_.CommandElements[1].Value -ceq $Name })
    if ($commands.Count -ne 1) { throw "检查块缺失或重复：$Name" }
    $source = $commands[0].CommandElements[2].Extent.Text
    return [scriptblock]::Create($source.Substring(1, $source.Length - 2))
}
function Invoke-Logged {
    param($LogName, $FilePath, $Arguments)
    $script:loggedArguments = $Arguments
}
function Test-Path { param($LiteralPath, $PathType) return $true }
function Stop-DevEnvGradleDaemon { throw '常规检查不得停止共享构建 daemon。' }
function Get-LastMeaningfulLine { '离线监督式 runner：1 passed, 0 failed' }
. (Join-Path $PSScriptRoot '..\lib\check-summary.ps1')
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$LogDir = Join-Path $RepoRoot '.checks'
$PwshPath = 'unused-pwsh'
$SkipGradle = $false
$Shards = 0
$script:cimMode = 'denied'
Test-Case 'runner uses one shard when memory unavailable and leaves shared daemons alone' {
    $result = & (Get-CheckBody '监督式 runner 离线测试')
    Assert-True ($result -eq '顺序，合计 1 passed') '未知内存未保守串行运行。'
    Assert-True ($script:loggedArguments -notcontains '-ShardCount') '串行模式不应启动分片。'
}
Test-Case 'Gradle checks use offline one-shot build without compiler daemon' {
    $null = & (Get-CheckBody 'Android JVM/Lint/构建')
    foreach ($argument in @('--offline', '--no-daemon', '-Pkotlin.compiler.execution.strategy=in-process', '--dependency-verification=strict')) {
        Assert-True ($script:loggedArguments -contains $argument) "缺少构建参数：$argument"
    }
}
Write-Host "dev env offline: $passed passed, 0 failed"
