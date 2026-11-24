#Requires -Version 7.5
<#
为当前仓库本地启用或卸载 .githooks（只改当前仓库 local git config，不动全局配置）。
启用后，每次 git commit 前将自动运行 scripts/check.ps1 -FastContentOnly（秒级空白/冲突标记/凭据扫描）。
#>
[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$repoRoot = Split-Path $PSScriptRoot -Parent
if ($Uninstall) {
    & git -C $repoRoot config --local --unset core.hooksPath 2>$null
    if ($LASTEXITCODE -notin @(0, 5)) {
        throw "卸载本地 core.hooksPath 失败（exit=$LASTEXITCODE）。"
    }
    Write-Host '已卸载本仓库本地 core.hooksPath。' -ForegroundColor Yellow
    exit 0
}

$hookFile = Join-Path $repoRoot '.githooks\pre-commit'
if (-not (Test-Path -LiteralPath $hookFile -PathType Leaf)) {
    throw "缺少钩子文件：$hookFile"
}
& git -C $repoRoot config --local core.hooksPath '.githooks'
if ($LASTEXITCODE -ne 0) {
    throw "配置本地 core.hooksPath 失败（exit=$LASTEXITCODE）。"
}
Write-Host '已启用本仓库本地 pre-commit 钩子（.githooks -> scripts/check.ps1 -FastContentOnly）。' -ForegroundColor Green
