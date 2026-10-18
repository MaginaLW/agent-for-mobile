#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# 只抽取 check.ps1 中实际执行的检查块，在隔离的 Git 仓库里测 index 和工作树。
$sourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$checkPath = Join-Path $sourceRoot 'scripts\check.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($checkPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'check.ps1 语法解析失败。' }
$functionAst = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-GitDiffCheckIssues'
}, $true))
if ($functionAst.Count -ne 1) { throw '空白检查函数缺失或重复。' }
. ([scriptblock]::Create($functionAst[0].Extent.Text))

function Get-CheckBody([string]$Name) {
    $commands = @($ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-Check'
    }, $true) | Where-Object {
        $_.CommandElements.Count -eq 3 -and
        $_.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $_.CommandElements[1].Value -ceq $Name
    })
    if ($commands.Count -ne 1) { throw "检查块缺失或重复：$Name" }
    $block = $commands[0].CommandElements[2]
    if ($block -isnot [Management.Automation.Language.ScriptBlockExpressionAst]) {
        throw "检查块类型不符：$Name"
    }
    $source = $block.Extent.Text
    return [scriptblock]::Create($source.Substring(1, $source.Length - 2))
}

$whitespaceCheck = Get-CheckBody '空白字符与冲突标记（工作树 + index）'
$credentialCheck = Get-CheckBody '凭据扫描'
$scratch = Join-Path $sourceRoot ('.checks/check-git-content-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$fixtureCount = 0
$passed = 0
$token = ('a1b2c3d4' * 4)
$gitCommand = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$reviewedPublicUrls = @(
    'https://developers.vivo.com/doc/d/7e7e3a6fe5c24a3cb175259e03ade6c9'
    'https://developers.vivo.com/doc/d/866218ac92f9437d86a7da059e6183bd'
    'https://developers.vivo.com/doc/d/a74d0ce7896bd3a9a143691aecfe2fa9'
    'https://developers.vivo.com/doc/d/b086bd7df65f408c8708d29d9500d678'
)

function Invoke-FixtureGit([string[]]$Arguments) {
    $null = & git -C $script:RepoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "fixture Git $($Arguments[0]) 失败。" }
}
function New-FixtureRepo {
    $script:fixtureCount++
    $script:RepoRoot = Join-Path $scratch "case-$script:fixtureCount"
    New-Item -ItemType Directory -Path $script:RepoRoot | Out-Null
    Invoke-FixtureGit @('init', '--quiet')
    Invoke-FixtureGit @('config', 'user.email', 'fixture@example.invalid')
    Invoke-FixtureGit @('config', 'user.name', 'Offline Fixture')
    Invoke-FixtureGit @('config', 'core.autocrlf', 'false')
    Set-Content -LiteralPath (Join-Path $script:RepoRoot '.gitignore') -Value "configs/gateway-mcp.json`n" -NoNewline -Encoding utf8
    Set-Content -LiteralPath (Join-Path $script:RepoRoot 'tracked.txt') -Value "clean`n" -NoNewline -Encoding utf8
    Invoke-FixtureGit @('add', '--', '.gitignore', 'tracked.txt')
    Invoke-FixtureGit @('commit', '--quiet', '-m', 'fixture baseline')
}
function Set-FixtureFile([string]$Path, [string]$Value) {
    Set-Content -LiteralPath (Join-Path $script:RepoRoot $Path) -Value $Value -NoNewline -Encoding utf8
}
function Assert-GitDiffClean([switch]$Cached) {
    $arguments = @('diff')
    if ($Cached) { $arguments += '--cached' }
    $arguments += '--check'
    $null = & git -C $script:RepoRoot @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw '反例前提不符：预期 git diff --check 无命中。' }
}
function Assert-GitDiffDirty([switch]$Cached) {
    $arguments = @('diff')
    if ($Cached) { $arguments += '--cached' }
    $arguments += '--check'
    $null = & git -C $script:RepoRoot @arguments 2>&1
    if ($LASTEXITCODE -eq 0) { throw '反例前提不符：预期 git diff --check 命中。' }
}
function Assert-Passes([scriptblock]$Body) {
    $null = & $Body
}
function Assert-FailsWith([scriptblock]$Body, [string]$Expected, [string]$Absent = '') {
    $message = $null
    try { $null = & $Body } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or -not $message.Contains($Expected, [StringComparison]::Ordinal)) {
        throw '预期的路径与规则未报告。'
    }
    if ($Absent.Length -gt 0 -and $message.Contains($Absent, [StringComparison]::Ordinal)) {
        throw '检查混淆了工作树与 index。'
    }
    if ($message.Contains($token, [StringComparison]::Ordinal) -or $message -match '[0-9a-f]{32}') {
        throw '检查结果回显了疑似凭据。'
    }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    New-FixtureRepo
    try { & $Body; $script:passed++ }
    catch {
        $reason = $_.Exception.Message
        if ($reason -notin @(
            '预期的路径与规则未报告。', '检查混淆了工作树与 index。', '检查结果回显了疑似凭据。',
            '反例前提不符：预期 git diff --check 无命中。', '反例前提不符：预期 git diff --check 命中。'
        )) { $reason = '未分类异常，详情已隐藏。' }
        throw "用例 $Name 失败：$reason"
    }
}

try {
    Test-Case 'clean baseline' {
        Assert-Passes $whitespaceCheck
        Assert-Passes $credentialCheck
    }
    Test-Case 'worktree whitespace' {
        # 原文既含疑似凭据又伪装为 Git 诊断；检查摘要不能把它当路径回显。
        Set-FixtureFile 'tracked.txt' "${token}:1: trailing whitespace.  `n"
        Assert-GitDiffDirty
        Assert-GitDiffClean -Cached
        Assert-FailsWith $whitespaceCheck '工作树：tracked.txt：trailing whitespace' 'index：'
    }
    Test-Case 'conflict marker remains blocked' {
        Set-FixtureFile 'tracked.txt' "<<<<<<< HEAD`none`n=======`ntwo`n>>>>>>> branch`n"
        Assert-GitDiffDirty
        Assert-FailsWith $whitespaceCheck '工作树：tracked.txt：leftover conflict marker'
    }
    Test-Case 'staged-only whitespace' {
        Set-FixtureFile 'new.txt' "bad  `n"
        Invoke-FixtureGit @('add', '--', 'new.txt')
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'new.txt')
        Assert-GitDiffClean
        Assert-GitDiffDirty -Cached
        Assert-FailsWith $whitespaceCheck 'index：new.txt：trailing whitespace' '工作树：'
    }
    Test-Case 'partially staged whitespace' {
        Set-FixtureFile 'tracked.txt' "bad  `n"
        Invoke-FixtureGit @('add', '--', 'tracked.txt')
        Set-FixtureFile 'tracked.txt' "clean`n"
        Assert-GitDiffClean
        Assert-GitDiffDirty -Cached
        Assert-FailsWith $whitespaceCheck 'index：tracked.txt：trailing whitespace' '工作树：'
    }
    Test-Case 'worktree credential shape' {
        Set-FixtureFile 'tracked.txt' "$token`n"
        Assert-FailsWith $credentialCheck '工作树：tracked.txt：32 位裸 hex' 'index：'
    }
    Test-Case 'untracked credential shape' {
        Set-FixtureFile 'new.txt' "$token`n"
        Assert-FailsWith $credentialCheck '工作树：new.txt：32 位裸 hex' 'index：'
    }
    Test-Case 'staged-only credential shape' {
        Set-FixtureFile 'new.txt' "$token`n"
        Invoke-FixtureGit @('add', '--', 'new.txt')
        Remove-Item -LiteralPath (Join-Path $script:RepoRoot 'new.txt')
        Assert-FailsWith $credentialCheck 'index：new.txt：32 位裸 hex' '工作树：'
    }
    Test-Case 'partially staged credential shape' {
        Set-FixtureFile 'tracked.txt' "$token`n"
        Invoke-FixtureGit @('add', '--', 'tracked.txt')
        Set-FixtureFile 'tracked.txt' "clean`n"
        Assert-FailsWith $credentialCheck 'index：tracked.txt：32 位裸 hex' '工作树：'
    }
    Test-Case 'gateway config remains blocked' {
        New-Item -ItemType Directory -Path (Join-Path $script:RepoRoot 'configs') | Out-Null
        Set-FixtureFile 'configs/gateway-mcp.json' "{}`n"
        Invoke-FixtureGit @('add', '-f', '--', 'configs/gateway-mcp.json')
        Assert-FailsWith $credentialCheck 'configs/gateway-mcp.json 被 git 跟踪。'
    }
    foreach ($publicUrl in $reviewedPublicUrls) {
        Test-Case 'reviewed public URL in worktree and index' {
            Set-FixtureFile 'tracked.txt' "[公开文档]($publicUrl)`n"
            Invoke-FixtureGit @('add', '--', 'tracked.txt')
            Assert-Passes $credentialCheck
        }
    }
    $publicUrl = $reviewedPublicUrls[0]
    $publicId = $publicUrl.Substring($publicUrl.LastIndexOf('/') + 1)
    Test-Case 'untracked reviewed public URL' {
        Set-FixtureFile 'new.txt' "<$publicUrl>`n"
        Assert-Passes $credentialCheck
    }
    Test-Case 'reviewed URL with ordinary full SHA' {
        Set-FixtureFile 'tracked.txt' "$publicUrl`n$('b' * 40)`n"
        Assert-Passes $credentialCheck
    }
    foreach ($scenario in @(
        @{ Name='token before URL'; Content="$token $publicUrl`n" },
        @{ Name='token after URL'; Content="$publicUrl $token`n" },
        @{ Name='token in Markdown label'; Content="[$token]($publicUrl)`n" },
        @{ Name='token in Markdown title'; Content="[文档]($publicUrl `"$token`")`n" },
        @{ Name='token on another line'; Content="$publicUrl`n$token`n" },
        @{ Name='same public ID outside URL'; Content="$publicUrl $publicId`n" },
        @{ Name='bare public ID'; Content="$publicId`n" },
        @{ Name='another document ID'; Content="https://developers.vivo.com/doc/d/$token`n" },
        @{ Name='lookalike host'; Content="$($publicUrl.Replace('developers.vivo.com', 'developers.vivo.com.evil.invalid'))`n" },
        @{ Name='HTTP URL'; Content="$($publicUrl.Replace('https:', 'http:'))`n" },
        @{ Name='different path'; Content="$($publicUrl.Replace('/doc/d/', '/doc/x/'))`n" },
        @{ Name='extra path'; Content="$publicUrl/other`n" },
        @{ Name='query'; Content="${publicUrl}?x=1`n" },
        @{ Name='fragment'; Content="$publicUrl#other`n" },
        @{ Name='token in query'; Content="${publicUrl}?token=$token`n" },
        @{ Name='embedded URL'; Content="https://example.invalid/?next=$publicUrl`n" },
        @{ Name='Chinese token adjacency'; Content="$publicUrl`n中${token}文`n" },
        @{ Name='accented token adjacency'; Content="$publicUrl`né${token}é`n" }
    )) {
        Test-Case $scenario.Name {
            Set-FixtureFile 'tracked.txt' $scenario.Content
            Assert-FailsWith $credentialCheck '工作树：tracked.txt：32 位裸 hex' 'index：'
        }
    }
    Test-Case 'underscore remains part of a word' {
        Set-FixtureFile 'tracked.txt' "$publicUrl`n_${token}_`n"
        Assert-Passes $credentialCheck
    }
    Test-Case 'reviewed URL in worktree cannot hide staged token' {
        Set-FixtureFile 'tracked.txt' "$publicUrl $token`n"
        Invoke-FixtureGit @('add', '--', 'tracked.txt')
        Set-FixtureFile 'tracked.txt' "$publicUrl`n"
        Assert-FailsWith $credentialCheck 'index：tracked.txt：32 位裸 hex' '工作树：'
    }
    Test-Case 'reviewed URL in index cannot hide worktree token' {
        Set-FixtureFile 'tracked.txt' "$publicUrl`n"
        Invoke-FixtureGit @('add', '--', 'tracked.txt')
        Set-FixtureFile 'tracked.txt' "$publicUrl $token`n"
        Assert-FailsWith $credentialCheck '工作树：tracked.txt：32 位裸 hex' 'index：'
    }
    Test-Case 'candidate read failure stays closed' {
        [byte[]]$invalidUtf8 = [Text.Encoding]::ASCII.GetBytes("$publicUrl`n") + [byte[]]@(255)
        [IO.File]::WriteAllBytes((Join-Path $script:RepoRoot 'tracked.txt'), $invalidUtf8)
        Assert-FailsWith $credentialCheck '工作树：tracked.txt：凭据候选读取失败。'
    }
    Test-Case 'index blob read failure stays closed' {
        Set-FixtureFile 'tracked.txt' "$publicUrl`n"
        Invoke-FixtureGit @('add', '--', 'tracked.txt')
        function git {
            if ($args -contains 'show') { $global:LASTEXITCODE = 1; return }
            & $gitCommand @args
        }
        Assert-FailsWith $credentialCheck 'index：tracked.txt：凭据候选读取失败。'
    }
    Test-Case 'Git candidate enumeration failure stays closed' {
        function git {
            if ($args -contains 'grep') { $global:LASTEXITCODE = 2; return }
            & $gitCommand @args
        }
        Assert-FailsWith $credentialCheck '工作树：git grep 执行失败。'
    }
    Test-Case 'candidate parse mismatch stays closed' {
        function git {
            if ($args -contains 'grep') {
                $global:LASTEXITCODE = 0
                return ('tracked.txt' + [char]0)
            }
            & $gitCommand @args
        }
        Assert-FailsWith $credentialCheck '工作树：tracked.txt：凭据候选读取失败。'
    }
    Write-Host "check git content offline: $passed passed, 0 failed"
}
finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    $allowed = [IO.Path]::GetFullPath((Join-Path $sourceRoot '.checks')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path $resolved -Leaf) -notlike 'check-git-content-offline-*') {
        throw '临时目录清理边界不符。'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
