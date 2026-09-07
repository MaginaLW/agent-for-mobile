#Requires -Version 7
<#
无设备 Kotlin 函数指标报告。首次联网下载 SHA256 钉定 detekt，之后可完全离线复跑。
使用项目钉定 PowerShell 运行：./scripts/measure-kotlin.ps1 [-Offline] [-JavaPath <jdk-java>]
入口与依赖不接入 Gradle；结果、JAR 缓存和日志仅写入已忽略的 .checks/kotlin-metrics/。
#>
[CmdletBinding()]
param(
    [switch]$Offline,
    [string]$JavaPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$RepoRoot = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$ToolDirectory = Join-Path $PSScriptRoot 'lib/kotlin-metrics'
$OutputDirectory = Join-Path $RepoRoot '.checks/kotlin-metrics'
$ReportPath = Join-Path $OutputDirectory 'summary.json'
$LogPath = Join-Path $OutputDirectory 'analysis.log'
$Lock = Get-Content -LiteralPath (Join-Path $ToolDirectory 'tool-lock.json') -Raw | ConvertFrom-Json

function Assert-MetricsDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "指标输出路径不是普通目录：$Path"
        }
    } else {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Assert-MetricsFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "指标输出路径不是普通文件：$Path"
        }
    }
}

function Get-MetricsInputs {
    $gitOutput = & git -C $RepoRoot -c core.quotepath=false ls-files -z --cached --others --exclude-standard -- '*.kt'
    if ($LASTEXITCODE -ne 0) { throw 'git ls-files 失败，无法界定测量范围。' }
    return @((($gitOutput -join "`n").Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) |
        Sort-Object -Unique)
}

# 逐级确认输出树，避免 .checks 的目录联接把缓存或报告写到仓库外。
Assert-MetricsDirectory (Join-Path $RepoRoot '.checks')
Assert-MetricsDirectory $OutputDirectory
Assert-MetricsDirectory (Join-Path $OutputDirectory 'tools')
foreach ($name in @('summary.json', 'analysis.log', 'inputs.txt', 'input-hashes.csv', 'functions.csv', 'run.lock')) {
    Assert-MetricsFile (Join-Path $OutputDirectory $name)
}

# 同一输出目录只允许一个写者；锁获取失败时不覆盖正在运行者的 summary。
$runLock = [IO.File]::Open((Join-Path $OutputDirectory 'run.lock'), [IO.FileMode]::OpenOrCreate,
    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $jar = Join-Path $OutputDirectory "tools/detekt-cli-$($Lock.version)-all.jar"
    Assert-MetricsFile $jar
    if (-not (Test-Path -LiteralPath $jar -PathType Leaf)) {
        if ($Offline) { throw '未缓存 detekt；首次运行请省略 -Offline 下载钉定版本。' }
        $download = $jar + '.download-' + [guid]::NewGuid().ToString('N')
        try {
            Invoke-WebRequest -Uri $Lock.url -OutFile $download
            if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ine $Lock.sha256) {
                throw 'detekt 下载 SHA256 不匹配，拒绝执行。'
            }
            Move-Item -LiteralPath $download -Destination $jar
        } finally {
            if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download -Force }
        }
    }
    if ((Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash -ine $Lock.sha256) {
        throw 'detekt 缓存 SHA256 不匹配，拒绝执行；检查缓存来源后再移除这一个 JAR。'
    }
    if ([string]::IsNullOrWhiteSpace($JavaPath)) {
        $JavaPath = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin/java.exe' }
                    else { (Get-Command java -CommandType Application -ErrorAction Stop).Source }
    }
    if (-not (Test-Path -LiteralPath $JavaPath -PathType Leaf)) { throw 'JavaPath 必须指向 JDK 的 java 可执行文件。' }

    # 测量当前工作树：包含新增且未忽略的源码，排除 build/cache 等忽略生成物。
    $files = @(Get-MetricsInputs)
    if ($files.Count -eq 0) { throw '工作树中没有 Kotlin 源文件。' }
    $manifest = Join-Path $OutputDirectory 'inputs.txt'
    $hashManifest = Join-Path $OutputDirectory 'input-hashes.csv'
    $hashes = foreach ($relative in $files) {
        if ($relative.Contains("`n") -or $relative.Contains("`r")) { throw '输入清单不支持文件名内的换行符。' }
        $source = Join-Path $RepoRoot $relative
        [pscustomobject]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [IO.File]::WriteAllLines($manifest, [string[]]$files, [Text.UTF8Encoding]::new($false))
    $hashes | Export-Csv -LiteralPath $hashManifest -NoTypeInformation -Encoding utf8

    $csv = Join-Path $OutputDirectory 'functions.csv'
    $extractorPath = Join-Path $ToolDirectory 'FunctionMetrics.java'
    $extractorHash = (Get-FileHash -LiteralPath $extractorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    & $JavaPath '--source' '17' '--class-path' $jar $extractorPath `
        $RepoRoot $manifest $csv *>&1 | Set-Content -LiteralPath $LogPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "Kotlin PSI 测量或内置回归检查失败，见 .checks/kotlin-metrics/analysis.log（退出码 $LASTEXITCODE）。" }
    if ((Get-FileHash -LiteralPath $extractorPath -Algorithm SHA256).Hash -ine $extractorHash) {
        throw '分析期间分析器源码变化，请重跑。'
    }
    # 分析期间源码若变化则拒绝发布成功，避免旧哈希给新结果背书。
    foreach ($entry in $hashes) {
        if ((Get-FileHash -LiteralPath (Join-Path $RepoRoot $entry.path) -Algorithm SHA256).Hash -ine $entry.sha256) {
            throw "分析期间源码变化，请重跑：$($entry.path)"
        }
    }
    if (Compare-Object $files @(Get-MetricsInputs) -CaseSensitive) {
        throw '分析期间 Kotlin 输入清单变化，请重跑。'
    }
    $rows = @(Import-Csv -LiteralPath $csv | ForEach-Object {
        [pscustomobject]@{
            path = $_.path; sourceSet = $_.sourceSet; name = $_.name
            startLine = [int]$_.startLine; endLine = [int]$_.endLine
            physicalLines = [int]$_.physicalLines; codeLines = [int]$_.codeLines
            cyclomatic = [int]$_.cyclomatic; cognitive = [int]$_.cognitive
        }
    })
    $main = @($rows | Where-Object { $_.sourceSet -eq 'main' })
    $summary = [ordered]@{
        schemaVersion = 1; status = 'passed'; detektVersion = $Lock.version; kotlinPsiVersion = $Lock.kotlinVersion
        detektSha256 = $Lock.sha256; inputSha256 = (Get-FileHash -LiteralPath $hashManifest -Algorithm SHA256).Hash.ToLowerInvariant()
        extractorSha256 = $extractorHash
        fileCount = $files.Count; functionCount = $rows.Count; mainFunctionCount = $main.Count
        regressionChecks = 'passed'; scope = 'Git tracked and unignored untracked .kt files in the current working tree'
        longestAll = @($rows | Select-Object -First 20)
        longestMain = @($main | Select-Object -First 20)
        highestCyclomaticMain = @($main | Sort-Object -Property @{Expression = 'cyclomatic'; Descending = $true}, path, startLine | Select-Object -First 20)
        highestCognitiveMain = @($main | Sort-Object -Property @{Expression = 'cognitive'; Descending = $true}, path, startLine | Select-Object -First 20)
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ReportPath -Encoding utf8
    Write-Host "PASS: $($files.Count) 个 Kotlin 文件 / $($rows.Count) 个函数；main $($main.Count) 个。"
    $main | Select-Object -First 5 name, physicalLines, codeLines, cyclomatic, cognitive | Format-Table | Out-Host
    Write-Host '报告：.checks/kotlin-metrics/summary.json；完整明细：functions.csv；源码指纹：input-hashes.csv。'
} catch {
    [ordered]@{ schemaVersion = 1; status = 'failed'; error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding utf8
    Write-Error $_
    exit 1
} finally {
    $runLock.Dispose()
}
