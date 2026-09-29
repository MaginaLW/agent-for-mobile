#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '../lib/tablet-layout-c1b-candidate-source.ps1')
$passed = 0
function Assert-Test {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function Assert-Rejected {
    param([scriptblock]$Body,[string]$Pattern)
    $caught = $null
    try { & $Body } catch { $caught = $_ }
    Assert-Test ($null -ne $caught -and $caught.Exception.Message -match $Pattern) "Expected rejection: $Pattern"
}
Test-Case 'variable-name edits preserve equal historical hashes and nested assignments' {
    $source = '$current = ''same''; $historical = ''same''; function f { $current = ''same'' }'
    $actual = Set-C1bCandidateLiteralAssignments $source @{current='next'}
    Assert-Test ($actual -ceq '$current = ''next''; $historical = ''same''; function f { $current = ''same'' }') 'Literal edit escaped top-level RHS.'
}
Test-Case 'literal escaping does not introduce executable syntax' {
    $value = 'a''; throw ''bad''; # $(whoami)'
    $actual = Set-C1bCandidateLiteralAssignments '$x = ''old''' @{x=$value}
    Assert-Test ((Get-C1bCandidateLiteralAssignment $actual 'x') -ceq $value) 'Literal escaping changed data.'
    Assert-Test ((Get-C1bCandidateSourceAst $actual).EndBlock.Statements.Count -eq 1) 'Literal introduced another statement.'
}
Test-Case 'ambiguous absent or multiline authority edits fail closed' {
    Assert-Rejected { Set-C1bCandidateLiteralAssignments '$x=1; $x=2' @{x=3} } 'one top-level'
    Assert-Rejected { Set-C1bCandidateLiteralAssignments '$x=1' @{y=3} } 'one top-level'
    Assert-Rejected { Set-C1bCandidateLiteralAssignments '$x=1' @{x="bad`nvalue"} } 'control'
    Assert-Rejected { Get-C1bCandidateLiteralAssignment '$x=[IO.File]::ReadAllText(''unknown'')' 'x' } 'dynamic'
}
Test-Case 'exact replacement and maintained preflight source reject drift' {
    Assert-Rejected { Replace-C1bCandidateExactText 'same same' 'same' 'next' } 'cardinality'
    Assert-Rejected { New-C1bPreflightR14CandidateSource -BaselineLeafSource '$x=1' -ChecksSource 'function x {}' -Constants @{} } 'Maintained preflight'

    $bootstrap = @'
#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
Write-Progress -Activity 'C1b harmless stream contract' -PercentComplete 1
if ($env:TL1_C1B_SYNTHETIC_STREAM -ceq 'native') { [Console]::Error.WriteLine('fixture native error') }
if ($env:TL1_C1B_SYNTHETIC_STREAM -ceq 'error') { Write-Error 'fixture PowerShell error' }
[Console]::WriteLine('fixture stdout')
'@
    $tail = @'
$logValue = [pscustomobject][ordered]@{
                stderr = if ($null -eq $stderrResult) { $null } else {
                    [pscustomobject][ordered]@{
                        total_byte_length = [long]$stderrResult.TotalByteLength
                        captured_byte_length = [long]$stderrResult.CapturedBytes.Length
                        sha256 = 'sha256:' + [string]$stderrResult.Sha256
                        overflowed = [bool]$stderrResult.Overflowed
                    }
                }
}
foreach ($buffer in @(
        $summaryBytes, $expectedStdoutBytes,
        $(if ($null -eq $stdoutResult) { $null } else { $stdoutResult.CapturedBytes }),
        $(if ($null -eq $stderrResult) { $null } else { $stderrResult.CapturedBytes }))) {
    if ($null -ne $buffer -and $buffer.Length -ne 0) { [Array]::Clear($buffer, 0, $buffer.Length) }
}
'@
    $template = '$versions = @(''7.6.4'', ''7.6.4'', ''7.6.4'')' + "`n" +
        '    $childBootstrapSource = @' + "'`n" + $bootstrap + "`n'@`n" + $tail
    $updated = Update-C1bLauncherCandidateTemplate $template
    $launcherText = $template
    function Assert-Renderer([bool]$Condition,[string]$Message) { Assert-Test $Condition $Message }
    . ([scriptblock]::Create((New-C1bLauncherRendererTransformSource $template)))
    Assert-Test ($launcherText -ceq $updated) 'Renderer and in-memory transformations differ.'
    Assert-Rejected { Update-C1bLauncherCandidateTemplate $updated } 'cardinality'
    Assert-Rejected { Update-C1bLauncherCandidateTemplate ($template.Replace('captured_byte_length =','other_length =')) } 'cardinality'
    $updatedCrLf = Update-C1bLauncherCandidateTemplate ($template.Replace("`r`n", "`n").Replace("`n", "`r`n"))
    Assert-Test ($updatedCrLf.Replace("`r`n", "`n") -ceq $updated.Replace("`r`n", "`n")) 'Source transformations changed newline semantics.'

    $updatedAst = Get-C1bCandidateSourceAst $updated
    $dataStatements = @($updatedAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.ForEachStatementAst] -or
        ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$logValue')
    })
    Assert-Test ($dataStatements.Count -eq 2) 'Synthetic log/clear statements are not unique.'
    $diagnosticCode = [string]::Join("`n", @($dataStatements | ForEach-Object {$_.Extent.Text}))
    foreach ($length in @(0, 1, 5, 1048576)) {
        $stderrBytes = [byte[]]::new($length)
        for ($i=0; $i -lt $length; $i++) { $stderrBytes[$i]=[byte](($i*71+129)%256) }
        $stdoutBytes = [byte[]]@(11,22,33)
        $before64 = [Convert]::ToBase64String($stderrBytes)
        $prefixHash = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrBytes)).ToLowerInvariant()
        $stderrResult = [pscustomobject]@{CapturedBytes=$stderrBytes;TotalByteLength=([long]$length+1L);Sha256=('a'*64);Overflowed=$true}
        $stdoutResult = [pscustomobject]@{CapturedBytes=$stdoutBytes}
        $summaryBytes=[byte[]]@(1,2);$expectedStdoutBytes=[byte[]]@(3,4)
        . ([scriptblock]::Create($diagnosticCode))
        Assert-Test ($logValue.stderr.captured_prefix_base64 -ceq $before64 -and $logValue.stderr.captured_prefix_sha256 -ceq $prefixHash) 'Captured prefix was not preserved before clear.'
        Assert-Test ($logValue.stderr.captured_prefix_byte_length -eq $length -and $logValue.stderr.uncaptured_byte_length -eq 1 -and $logValue.stderr.capture_is_prefix -and $logValue.stderr.overflowed) 'Bounded prefix/omission contract drifted.'
        Assert-Test (@($stderrBytes | Where-Object {$_ -ne 0}).Count -eq 0 -and @($stdoutBytes | Where-Object {$_ -ne 0}).Count -eq 0) 'Cleanup failed to clear original byte arrays.'
        Assert-Test ([object]::ReferenceEquals($stderrBytes,$stderrResult.CapturedBytes)) 'Cleanup replaced original buffer identity.'
    }

    $childLiteral = Get-C1bCandidateLiteralAssignment $updated 'childBootstrapSource'
    foreach ($case in @(
        @{Name='progress-default';Source=$bootstrap;Mode='';Exit=0;Empty=$false},
        @{Name='progress-suppressed';Source=$childLiteral;Mode='';Exit=0;Empty=$true},
        @{Name='native-error-preserved';Source=$childLiteral;Mode='native';Exit=0;Empty=$false},
        @{Name='powershell-error-preserved';Source=$childLiteral;Mode='error';Exit=1;Empty=$false}
    )) {
        $child=$null;$stdout=$null;$stderr=$null
        try {
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=[Environment]::ProcessPath
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true
            $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            $start.Environment['TL1_C1B_SYNTHETIC_STREAM']=$case.Mode
            foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($case.Source)))) { $start.ArgumentList.Add($arg) }
            $stdout=[IO.MemoryStream]::new();$stderr=[IO.MemoryStream]::new()
            $child=[Diagnostics.Process]::new();$child.StartInfo=$start
            Assert-Test ($child.Start()) 'Harmless bootstrap child did not start.'
            $outTask=$child.StandardOutput.BaseStream.CopyToAsync($stdout)
            $errTask=$child.StandardError.BaseStream.CopyToAsync($stderr)
            if (-not $child.WaitForExit(15000)) { $child.Kill($true);$null=$child.WaitForExit(5000);throw 'Harmless bootstrap child timed out.' }
            Assert-Test ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),5000)) 'Harmless bootstrap drains did not close.'
            Assert-Test ($child.ExitCode -eq $case.Exit -and ($stderr.Length -eq 0) -eq $case.Empty) "Harmless stream contract failed: $($case.Name)"
        }
        finally {
            if($null -ne $stdout){$stdout.Dispose()};if($null -ne $stderr){$stderr.Dispose()}
            if($null -ne $child){$child.Dispose()}
        }
    }
}

$constants = [ordered]@{}
foreach ($name in @('repoRoot','stagingRoot','expectedBranch','expectedCommitSha','expectedCommitShort',
    'helperPath','expectedHelperSha256','expectedHelperByteLength',
    'launcherPath','expectedLauncherSha256','expectedLauncherByteLength',
    'expectedLauncherTemplateSha256','failureSidecarPath','pwshPath','expectedPwshSha256',
    'gitPath','expectedGitSha256','expectedGitIndexSha256','expectedGitTrackedPathCount','expectedGitConfigSha256',
    'expectedGitAttributesSha256','expectedGitIgnoreSha256','expectedGitInfoExcludeSha256',
    'expectedVerifierSha256','summaryLeaf','logLeaf','launcherResultLeaf','receiptLeaf')) {
    $constants[$name] = 'fixture'
}
$constants.expectedCommitSha = 'a'*40
$constants.expectedCommitShort = 'a'*7
$constants.expectedPwshSha256 = '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
$constants.gitPath = 'C:\Fixture\Git\mingw64\bin\git.exe'
$declarations = [string]::Join("`n", @($constants.Keys | ForEach-Object { '$' + $_ + " = 'old'" }))
$body = @'
$failures = [Collections.Generic.List[string]]::new()
$gitInvocationCount = 0L
$helperName = ('helper-' + $expectedCommitShort + '-r10.ps1')
$launcherName = ('launcher-' + $expectedCommitShort + '-r10.ps1')
$failureName = ('launcher-' + $expectedCommitShort + '-r10.failure.json')
function Invoke-ReadOnlyGit {
    $script:gitInvocationCount++
    $script:order.Add('git')
    if ($script:failGit) { throw 'primary git failure' }
}
function Parse-HeldPowerShell { return @{ Ast=$null } }
try {
    $gitRepositoryIdentity = Invoke-ReadOnlyGit @(
        'rev-parse')
    $launcherBinding = $null
    $launcherParsed = Parse-HeldPowerShell $launcherBinding
}
catch { $failures.Add($_.Exception.Message) }
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    $script:order.Add('cleanup')
}
$all = (
    $gitInvocationCount -eq 4L -and
    $failures.Count -eq 0)
$receipt = [ordered]@{
    read_only_git_invocation_count = [long]$gitInvocationCount
}
[pscustomobject]@{Order=$script:order.ToArray();Failures=$failures.ToArray();Receipt=$receipt}
'@
$checks = @'
function Get-TL1C1bPreflightGitTreeSnapshot {
    param($Root,$ExpectedFileCount,$ExpectedCatalogSha256,$ExpectedIdentityCount,$ExpectedInternalHardlinkGroupCount,$Stage)
    $script:order.Add($Stage)
    if ($Stage -ceq 'before_git' -and $script:failPre) { throw 'pre drift' }
    if ($Stage -ceq 'after_git' -and $script:failPost) { throw 'post drift' }
    return @{Root=$Root;Stage=$Stage}
}
function Assert-TL1C1bPreflightGitTreeContinuity { param($Before,$After) }
function Assert-TL1C1bPreflightLauncherByteReturn { param($LauncherAst) return @{Passed=$true} }
function Assert-TL1C1bPreflightLauncherStreamContract { param($LauncherAst) return @{Passed=$true} }
'@
$fixture = $declarations + "`n" + $body
$patched = Add-C1bPreflightR14ChecksToSource -BaselineLeafSource $fixture -ChecksSource $checks -Constants $constants
function Invoke-Fixture {
    param([bool]$FailPre,[bool]$FailGit,[bool]$FailPost)
    $ps = [Management.Automation.PowerShell]::Create()
    try {
        $run = 'param($failPre,$failGit,$failPost); $ErrorActionPreference="Stop"; $script:order=[Collections.Generic.List[string]]::new();' + "`n" + $script:patched
        [void]$ps.AddScript($run).AddArgument($FailPre).AddArgument($FailGit).AddArgument($FailPost)
        $output = @($ps.Invoke())
        if ($ps.Streams.Error.Count -ne 0) { throw $ps.Streams.Error[0] }
        if ($ps.InvocationStateInfo.State -ne 'Completed') { throw $ps.InvocationStateInfo.Reason }
        Assert-Test ($output.Count -eq 1) 'Synthetic r14 emitted unexpected output.'
        return $output[0]
    }
    finally { $ps.Dispose() }
}
Test-Case 'pre-check rejects before any Git call' {
    $r = Invoke-Fixture $true $false $false
    Assert-Test (($r.Order -join ',') -ceq 'before_git,cleanup') 'Git started after failed pre-check.'
    Assert-Test ($r.Receipt.git_trust_root_post_check_attempt_count -eq 0) 'Failed pre-check incorrectly claimed post-check.'
}
Test-Case 'post-check runs after Git failure and preserves primary-first order' {
    $r = Invoke-Fixture $false $true $true
    Assert-Test (($r.Order -join ',') -ceq 'before_git,git,after_git,cleanup') 'Finally post-check or cleanup did not run.'
    Assert-Test ($r.Failures.Count -eq 2 -and $r.Failures[0] -ceq 'primary git failure' -and $r.Failures[1] -match 'post drift') 'Post-check masked primary.'
    Assert-Test ($r.Receipt.git_trust_root_post_check_failure_count -eq 1) 'Post-check failure was not recorded.'
}
Test-Case 'post-check drift rejects a successful Git call' {
    $r = Invoke-Fixture $false $false $true
    Assert-Test ($r.Failures.Count -eq 1 -and -not $r.Receipt.git_trust_root_continuity_verified) 'Terminal drift was accepted.'
}
Test-Case 'successful pre/post evidence disclaims transient continuity' {
    $r = Invoke-Fixture $false $false $false
    Assert-Test ($r.Failures.Count -eq 0 -and $r.Receipt.git_trust_root_continuity_verified) 'Stable tree was rejected.'
    Assert-Test (-not $r.Receipt.git_trust_root_transient_change_excluded) 'Discrete checks overclaimed continuity.'
}
Test-Case 'missing or duplicate injection anchors cannot silently produce a candidate' {
    Assert-Rejected { Add-C1bPreflightR14ChecksToSource ($fixture.Replace('function Invoke-ReadOnlyGit {','function Other {')) $checks $constants } 'cardinality'
    Assert-Rejected { Add-C1bPreflightR14ChecksToSource $fixture ($checks + '; Write-Output bad') $constants } 'functions only'
}
Test-Case 'tracked maintenance sources deterministically derive a candidate without historical inputs' {
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $sourceRoot = Join-Path $repoRoot 'scripts/lib/c1b-candidate-source'
    $rendererTemplate = [IO.File]::ReadAllText((Join-Path $sourceRoot 'renderer-template.ps1'))
    $helperTemplate = [IO.File]::ReadAllText((Join-Path $sourceRoot 'helper-template.ps1'))
    $launcherTemplate = [IO.File]::ReadAllText((Join-Path $sourceRoot 'launcher-template.ps1'))
    $preflightTemplate = [IO.File]::ReadAllText((Join-Path $sourceRoot 'preflight-template.ps1'))
    $checksSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'scripts/lib/tablet-layout-c1b-preflight-r14-checks.ps1'))
    $pairArgs = @{
        BaselineRendererSource=$rendererTemplate; HelperTemplateSource=$helperTemplate
        LauncherTemplateSource=$launcherTemplate; CommitSha=('a'*40)
        RepoRoot=$repoRoot; StagingRoot='C:\Fixture\CandidateStage'
        PwshPath='C:\Fixture\PowerShell\pwsh.exe'; VerifierSha256=('b'*64)
        UtilityAssemblySha256='2f6201bb3caf4c08158be733e786dd85b11537694f7e6ab40356fc0727a3596f'
        UtilityAssemblyLength=1652504L
    }
    $pair = New-C1bExactPairCandidateSource @pairArgs
    $repeat = New-C1bExactPairCandidateSource @pairArgs
    Assert-Test ($pair.RendererSource -ceq $repeat.RendererSource -and
        $pair.HelperSource -ceq $repeat.HelperSource -and
        $pair.LauncherSource -ceq $repeat.LauncherSource) 'Maintained pair derivation was not deterministic.'
    Assert-Test (-not $pair.RendererSource.Contains('historical_') -and
        -not $pair.RendererSource.Contains('__BINDING__') -and
        -not $pair.LauncherSource.Contains('__PWSH_SHA256__')) 'Candidate retained historical input or unresolved binding.'
    $driftArgs = $pairArgs.Clone()
    $driftArgs.LauncherTemplateSource = $launcherTemplate.Replace('7.6.5','7.6.4')
    Assert-Rejected { New-C1bExactPairCandidateSource @driftArgs } 'Maintained launcher source drifted'
    $leaf = New-C1bPreflightR14CandidateSource -BaselineLeafSource $preflightTemplate -ChecksSource $checksSource -Constants $constants
    Assert-Test (-not $leaf.Contains('__BINDING__') -and -not $leaf.Contains("'-r10.ps1'")) 'Preflight retained historical binding.'
    $r14 = New-C1bPreflightR14RendererSource -PairRendererSource $pair.RendererSource `
        -PreflightSource $leaf -BaselineLeafPath (Join-Path $sourceRoot 'preflight-template.ps1') `
        -BaselineLeafSha256 (Get-C1bCandidateSourceHash $preflightTemplate) `
        -BaselineLeafByteLength ([Text.UTF8Encoding]::new($false,$true).GetByteCount($preflightTemplate)) `
        -IndexSha256 ('c'*64) -IndexByteLength 128L
    Assert-Test ($r14.Contains((Get-C1bCandidateSourceHash $preflightTemplate)) -and
        -not $r14.Contains('preflight-a661f36-r13.ps1')) 'R14 renderer did not bind the maintained preflight source.'

    # 执行生成器输出的真实路径/specs/cleanup AST；native handles 仅用内存替身。
    # 不执行 bootstrap、发布或候选，不读写 synthetic 路径。
    $authorityPairArgs = $pairArgs.Clone()
    $authorityPairArgs.RepoRoot = 'C:\Fixture\CandidateRepo'
    $authorityPair = New-C1bExactPairCandidateSource @authorityPairArgs
    $authorityBaselinePath = [IO.Path]::Combine(
        $authorityPairArgs.RepoRoot,'scripts','lib','c1b-candidate-source','preflight-template.ps1')
    $authorityR14 = New-C1bPreflightR14RendererSource -PairRendererSource $authorityPair.RendererSource `
        -PreflightSource $leaf -BaselineLeafPath $authorityBaselinePath `
        -BaselineLeafSha256 (Get-C1bCandidateSourceHash $preflightTemplate) `
        -BaselineLeafByteLength ([Text.UTF8Encoding]::new($false,$true).GetByteCount($preflightTemplate)) `
        -IndexSha256 ('c'*64) -IndexByteLength 128L
    $authorityAst = Get-C1bCandidateSourceAst $authorityR14
    $authorityAssert = @($authorityAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $_.Name -ceq 'Assert-Renderer'
    })
    Assert-Test ($authorityAssert.Count -eq 1) 'R14 assertion function is not unique.'
    . ([scriptblock]::Create($authorityAssert[0].Extent.Text))
    $authorityMain = @($authorityAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst] -and
        $_.Body.Extent.Text.Contains("-Label 'r14 exact source input'")
    })
    Assert-Test ($authorityMain.Count -eq 1) 'R14 publication body is not unique.'
    $authorityStatements = @($authorityMain[0].Body.Statements | Where-Object {
        ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -cin @('r14ExpectedBaselineLeafPath','stagingDirectoryEntry','specs')) -or
        ($_ -is [Management.Automation.Language.PipelineAst] -and
            $_.Extent.Text.Contains("'R14 baseline source escaped repository maintenance path.'")) -or
        ($_ -is [Management.Automation.Language.ForEachStatementAst] -and
            ($_.Body.Extent.Text.Contains("'R14 staging child escaped parent.'") -or
             $_.Body.Extent.Text.Contains('Open-RendererDirectoryChain')))
    })
    Assert-Test ($authorityStatements.Count -eq 6) 'R14 source/output authority statements drifted.'
    $authorityCode = [string]::Join("`n", @($authorityStatements | ForEach-Object { $_.Extent.Text }))
    $authorityCleanup = [string]::Join("`n", @($authorityMain[0].Finally.Statements | ForEach-Object { $_.Extent.Text }))
    function Open-RendererDirectoryChain {
        param([string]$Path,[string]$Label)
        if ($script:failAuthorityParent -ceq $Path) { throw 'fixture source parent acquisition failed' }
        $script:openedAuthorityParents.Add($Path)
        $handle = [pscustomobject]@{Path=$Path}
        $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            $script:closedAuthorityParents.Add($this.Path)
        }
        return [pscustomobject]@{Entries=@([pscustomobject]@{Path=$Path;Handle=$handle})}
    }
    function Invoke-R14AuthorityFixture {
        param([Collections.IDictionary]$Overrides=@{},[string]$FailParent='')
        $repoRoot = $authorityPairArgs.RepoRoot
        $stagingRoot = $authorityPairArgs.StagingRoot
        $outputRoot = [IO.Path]::Combine($repoRoot,'.checks')
        $r14BaselineLeafPath = $authorityBaselinePath
        $r14LeafPath = [IO.Path]::Combine($stagingRoot,'preflight-aaaaaaa-r14.ps1')
        $r14TemporaryPath = [IO.Path]::Combine($stagingRoot,'preflight-aaaaaaa-r14.rendering.tmp')
        $r14ReceiptPath = [IO.Path]::Combine($stagingRoot,'preflight-aaaaaaa-r14.prepared-not-authorized.receipt.json')
        $r14IndexPath = [IO.Path]::Combine($repoRoot,'.git','index')
        $r14IndexSha256 = 'c'*64; $r14IndexLength = 128L
        $helperPath = [IO.Path]::Combine($stagingRoot,'helper-aaaaaaa-r11.ps1')
        $launcherPath = [IO.Path]::Combine($stagingRoot,'launcher-aaaaaaa-r11.ps1')
        $expectedHelperSha256 = $authorityPair.HelperSha256
        $expectedHelperLength = $authorityPair.HelperByteLength
        $expectedLauncherSha256 = $authorityPair.LauncherSha256
        $expectedLauncherLength = $authorityPair.LauncherByteLength
        $pwshPath = $authorityPairArgs.PwshPath
        $expectedPwshSha256 = '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
        $utilityAssemblyPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($pwshPath),'Microsoft.PowerShell.Commands.Utility.dll')
        $expectedUtilityAssemblySha256 = $authorityPairArgs.UtilityAssemblySha256
        $expectedUtilityAssemblyLength = $authorityPairArgs.UtilityAssemblyLength
        $verifierPath = [IO.Path]::Combine($repoRoot,'scripts','lib','tablet-layout-c1b-real-build-smoke-verifier.ps1')
        $expectedVerifierSha256 = $authorityPairArgs.VerifierSha256
        foreach ($name in $Overrides.Keys) { Set-Variable -Name $name -Value $Overrides[$name] -Scope Local }
        $directoryChains = [Collections.Generic.List[object]]::new()
        $inputs = [Collections.Generic.List[object]]::new()
        $candidates = [Collections.Generic.List[object]]::new()
        $decoded = $null; $specs = $null; $failure = $null
        $mainCleanup = [Collections.Generic.List[Exception]]::new()
        $script:openedAuthorityParents = [Collections.Generic.List[string]]::new()
        $script:closedAuthorityParents = [Collections.Generic.List[string]]::new()
        $script:failAuthorityParent = $FailParent
        try { . ([scriptblock]::Create($authorityCode)) }
        catch { $failure = $_.Exception.Message }
        finally { . ([scriptblock]::Create($authorityCleanup)) }
        return [pscustomobject]@{
            Failure=$failure; Specs=$specs; Opened=$script:openedAuthorityParents.ToArray()
            Closed=$script:closedAuthorityParents.ToArray(); CleanupFailures=$mainCleanup.Count
            StagingEntry=if ($directoryChains.Count -eq 0) {$null} else {$directoryChains[0].Entries[0].Path}
        }
    }
    $authorityResult = Invoke-R14AuthorityFixture
    $authoritySourceParent = [IO.Path]::GetDirectoryName($authorityBaselinePath)
    Assert-Test ($null -eq $authorityResult.Failure -and $authorityResult.CleanupFailures -eq 0) "Repository maintenance baseline was rejected: $($authorityResult.Failure)"
    Assert-Test ($authorityResult.Opened.Count -eq 6 -and
        @($authorityResult.Opened | Where-Object {$_ -ceq $authoritySourceParent}).Count -eq 1 -and
        $authorityResult.StagingEntry -ceq $authorityPairArgs.StagingRoot) 'R14 source parent was not held separately from the publication parent.'
    $authorityClosedReverse = @($authorityResult.Opened)
    [Array]::Reverse($authorityClosedReverse)
    Assert-Test (($authorityResult.Closed -join "`n") -ceq ($authorityClosedReverse -join "`n")) 'R14 directory cleanup did not close every held parent in reverse order.'
    Assert-Test ($authorityResult.Specs.Count -eq 7 -and
        $authorityResult.Specs[0].Path -ceq $authorityBaselinePath -and
        $authorityResult.Specs[0].Hash -ceq (Get-C1bCandidateSourceHash $preflightTemplate) -and
        $authorityResult.Specs[0].Length -eq [Text.UTF8Encoding]::new($false,$true).GetByteCount($preflightTemplate) -and
        -not $authorityResult.Specs[0].Frozen -and $authorityResult.Specs[0].Parse -and
        $authorityResult.Specs[2].Frozen -and $authorityResult.Specs[3].Frozen) 'R14 maintained-source hash/length/parser or frozen pair bindings drifted.'
    foreach ($invalidBaseline in @(
        [IO.Path]::Combine($authorityPairArgs.StagingRoot,'preflight-template.ps1'),
        [IO.Path]::Combine($authorityPairArgs.RepoRoot,'scripts','lib','other-source','preflight-template.ps1'))) {
        $rejected = Invoke-R14AuthorityFixture @{r14BaselineLeafPath=$invalidBaseline}
        Assert-Test ($rejected.Failure -match 'baseline source escaped' -and $rejected.Opened.Count -eq 0) 'Non-maintenance baseline started authority acquisition.'
    }
    foreach ($name in @('r14LeafPath','r14TemporaryPath','r14ReceiptPath','helperPath','launcherPath')) {
        $rejected = Invoke-R14AuthorityFixture @{$name=[IO.Path]::Combine($authorityPairArgs.RepoRoot,'escaped.ps1')}
        Assert-Test ($rejected.Failure -match 'staging child escaped' -and $rejected.Opened.Count -eq 0) "R14 accepted an escaped staging child: $name"
    }
    $rejected = Invoke-R14AuthorityFixture -FailParent $authoritySourceParent
    $partialClosedReverse = @($rejected.Opened)
    [Array]::Reverse($partialClosedReverse)
    Assert-Test ($rejected.Failure -match 'source parent acquisition failed' -and
        $null -eq $rejected.Specs -and $rejected.Opened.Count -eq 5 -and
        ($rejected.Closed -join "`n") -ceq ($partialClosedReverse -join "`n") -and
        $rejected.CleanupFailures -eq 0) 'R14 source-parent failure continued or leaked earlier held parents.'
}
Write-Output "candidate source offline: $passed passed, 0 skipped"
