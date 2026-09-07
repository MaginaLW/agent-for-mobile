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
Test-Case 'exact replacement and frozen r13 source authority reject drift' {
    Assert-Rejected { Replace-C1bCandidateExactText 'same same' 'same' 'next' } 'cardinality'
    Assert-Rejected { New-C1bPreflightR14CandidateSource -BaselineLeafSource '$x=1' -ChecksSource 'function x {}' -Constants @{} } 'Frozen r13'

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
foreach ($name in @('repoRoot','stagingRoot','expectedCommitSha','expectedCommitShort',
    'helperPath','expectedHelperSha256','expectedHelperByteLength',
    'launcherPath','expectedLauncherSha256','expectedLauncherByteLength',
    'expectedLauncherTemplateSha256','failureSidecarPath','pwshPath','expectedPwshSha256',
    'expectedGitIndexSha256','expectedGitTrackedPathCount','expectedGitConfigSha256',
    'expectedGitAttributesSha256','expectedGitIgnoreSha256','expectedGitInfoExcludeSha256',
    'expectedVerifierSha256','summaryLeaf','logLeaf','launcherResultLeaf','receiptLeaf')) {
    $constants[$name] = 'fixture'
}
$constants.expectedCommitSha = 'a'*40
$constants.expectedCommitShort = 'a'*7
$constants.expectedPwshSha256 = '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
$declarations = [string]::Join("`n", @($constants.Keys | ForEach-Object { '$' + $_ + " = 'old'" }))
$body = @'
$failures = [Collections.Generic.List[string]]::new()
$gitPath = 'C:\Fixture\Git\mingw64\bin\git.exe'
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
Test-Case 'new helper diagnostics reach underlying process and renderer matches candidate bytes' {
    # wrapper 签名与唯一 Gradle 调用取自冻结模板；仅底层进程使用内存 stub，不启动构建。
    $template = @'
function Invoke-TL1C1aProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [byte[]]$InputBytes,
        [hashtable]$Environment,
        [switch]$ClearEnvironment,
        [ValidateRange(1, 300)][int]$TimeoutSec = 30,
        [switch]$AllowFailure
    )
    return Invoke-TL1C1aProcessSmokeUnderlying @PSBoundParameters
}
    [void](Invoke-TL1C1aProcess -FilePath ([string]$gradleInvocation.FilePath) `
        -Arguments $gradleArguments `
        -Operation 'C1b 42-input real isolated direct GradleMain smoke' `
        -Environment $environment -ClearEnvironment -TimeoutSec 300)
'@
    $updated = Update-C1bHelperCandidateTemplate $template
    $helperText = $template
    function Assert-Renderer([bool]$Condition,[string]$Message) { Assert-Test $Condition $Message }
    . ([scriptblock]::Create((New-C1bHelperRendererTransformSource $template)))
    Assert-Test ($helperText -ceq $updated) 'Helper renderer differs from candidate transformation.'
    $crlf = $template.Replace("`r`n","`n").Replace("`n","`r`n")
    Assert-Test ((Update-C1bHelperCandidateTemplate $crlf).Replace("`r`n","`n") -ceq $updated.Replace("`r`n","`n")) 'Helper CRLF transformation differs.'
    $script:helperForwarded = $null
    function Invoke-TL1C1aProcessSmokeUnderlying {
        param($FilePath,$Arguments,$Operation,$InputBytes,$Environment,[switch]$ClearEnvironment,
            [int]$TimeoutSec,[switch]$AllowFailure,[switch]$FailureDiagnostics)
        $script:helperForwarded = @{} + $PSBoundParameters
    }
    $gradleInvocation = @{FilePath='fixture-java.exe'}
    $gradleArguments = [string[]]@('fixture-gradle-main')
    $environment = @{FIXTURE='value'}
    . ([scriptblock]::Create($updated))
    Assert-Test ($null -ne $script:helperForwarded -and $script:helperForwarded.FailureDiagnostics.IsPresent -and
        $script:helperForwarded.ClearEnvironment.IsPresent -and $script:helperForwarded.TimeoutSec -eq 300 -and
        $script:helperForwarded.FilePath -ceq 'fixture-java.exe') 'Helper wrapper did not forward diagnostics unchanged.'
    Assert-Rejected { Update-C1bHelperCandidateTemplate $updated } 'cardinality'
    Assert-Rejected { Update-C1bHelperCandidateTemplate ($template.Replace('-TimeoutSec 300)', '-TimeoutSec 299)')) } 'cardinality'
    Assert-Rejected { Update-C1bHelperCandidateTemplate ($template + "`n" + $template) } 'cardinality'
}
Test-Case 'missing or duplicate injection anchors cannot silently produce a candidate' {
    Assert-Rejected { Add-C1bPreflightR14ChecksToSource ($fixture.Replace('function Invoke-ReadOnlyGit {','function Other {')) $checks $constants } 'cardinality'
    Assert-Rejected { Add-C1bPreflightR14ChecksToSource $fixture ($checks + '; Write-Output bad') $constants } 'functions only'
}
Write-Output "candidate source offline: $passed passed, 0 skipped"
