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
function Assert-FixtureNewline {
    param([string]$Source,[ValidateSet('LF','CRLF')][string]$Style)
    $lf = $Source.Replace("`r`n", "`n")
    Assert-Test ($lf.Contains("`n") -and -not $lf.Contains("`r")) 'Fixture must contain lines without standalone CR.'
    $expected = if ($Style -ceq 'CRLF') { $lf.Replace("`n", "`r`n") } else { $lf }
    Assert-Test ($Source -ceq $expected) "Fixture does not use only $Style newlines."
}
function New-FixtureLibraryHashes {
    param([string]$Digit='a')
    return [ordered]@{
        c1a=('sha256:'+$Digit*64); validator=('sha256:'+$Digit*64)
        c1b=('sha256:'+$Digit*64); artifact=('sha256:'+$Digit*64)
        aapt2=('sha256:'+$Digit*64); build=('sha256:'+$Digit*64)
        runner=('sha256:'+$Digit*64)
    }
}
function New-FixtureLibraryMapSource {
    param([Collections.IDictionary]$Hashes)
    $entries=@($Hashes.GetEnumerator() | ForEach-Object { "    $($_.Key) = '$($_.Value)'" })
    return '$expectedLibraryHashes = [ordered]@{' + "`n" + ($entries -join "`n") + "`n}"
}
function Read-FixtureLibraryMap {
    param([string]$Source)
    $ast=Get-C1bCandidateSourceAst $Source
    $assignment=@($ast.EndBlock.Statements | Where-Object {
        $_-is[Management.Automation.Language.AssignmentStatementAst]-and
        $_.Left.Extent.Text-ceq'$expectedLibraryHashes'
    })
    Assert-Test ($assignment.Count-eq1) 'Generated helper map must appear once.'
    $result=[ordered]@{}
    foreach($pair in $assignment[0].Right.Expression.Child.KeyValuePairs){
        $result[$pair.Item1.Value]=$pair.Item2.PipelineElements[0].Expression.SafeGetValue()
    }
    return $result
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
    $template = $template.Replace("`r`n", "`n")
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
Test-Case 'new helper diagnostics reach underlying process and renderer matches candidate bytes' {
    # wrapper 签名与唯一 Gradle 调用取自维护模板；仅底层进程使用内存 stub，不启动构建。
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
    $hashes=New-FixtureLibraryHashes 'b'
    $template=((New-FixtureLibraryMapSource (New-FixtureLibraryHashes)) + "`n" + $template).Replace("`r`n", "`n")
    function Assert-Renderer([bool]$Condition,[string]$Message) { Assert-Test $Condition $Message }
    $updated = $null
    foreach ($style in @('LF','CRLF')) {
        $inputTemplate = if ($style -ceq 'CRLF') { $template.Replace("`n", "`r`n") } else { $template }
        Assert-FixtureNewline $inputTemplate $style
        $transformed = Update-C1bHelperCandidateTemplate $inputTemplate $hashes
        Assert-FixtureNewline $transformed $style
        $helperText = $inputTemplate
        . ([scriptblock]::Create((New-C1bHelperRendererTransformSource $inputTemplate $hashes)))
        Assert-Test ($helperText -ceq $transformed) "Helper renderer differs from candidate transformation for $style."
        Assert-Rejected { Update-C1bHelperCandidateTemplate $transformed $hashes } 'cardinality'
        Assert-Rejected { Update-C1bHelperCandidateTemplate ($inputTemplate.Replace('-TimeoutSec 300)', '-TimeoutSec 299)')) $hashes } 'cardinality'
        $separator = if ($style -ceq 'CRLF') { "`r`n" } else { "`n" }
        Assert-Rejected { Update-C1bHelperCandidateTemplate ($inputTemplate + $separator + $inputTemplate) $hashes } 'one top-level'
        if ($style -ceq 'LF') { $updated = $transformed }
        else { Assert-Test ($transformed.Replace("`r`n", "`n") -ceq $updated) 'Helper LF/CRLF transformations differ.' }
    }
    $actualHashes=Read-FixtureLibraryMap $updated
    Assert-Test ($actualHashes.Count-eq7-and
        ($actualHashes.Keys-join',')-ceq($hashes.Keys-join',')-and
        @($actualHashes.Values | Where-Object {$_-cne('sha256:'+'b'*64)}).Count-eq0) 'New helper retained a frozen loader hash.'
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
}
Test-Case 'library map replacement leaves equal historical hashes and other maps intact' {
    $oldMap=New-FixtureLibraryMapSource (New-FixtureLibraryHashes)
    $historical='$historicalHash = ''sha256:' + 'a'*64 + "'"
    $otherMap=$oldMap.Replace('expectedLibraryHashes','unrelatedHashes')
    $source=$historical+"`n"+$oldMap+"`n"+$otherMap
    $hashes=New-FixtureLibraryHashes 'c'
    $hashes.runner='sha256:'+'d'*64
    $change=Get-C1bHelperLibraryHashTransformation $source $hashes
    $actual=Replace-C1bCandidateExactText $source $change.Old $change.New $change.Count
    Assert-Test ($actual-ceq($historical+"`n"+(New-FixtureLibraryMapSource $hashes)+"`n"+$otherMap)) 'Library map replacement changed unrelated history.'
    Assert-Test ((Read-FixtureLibraryMap $actual).runner-ceq$hashes.runner) 'Per-file loader hash was lost.'
}
Test-Case 'missing ambiguous dynamic and malformed helper library maps are rejected' {
    $map=New-FixtureLibraryMapSource (New-FixtureLibraryHashes)
    $hashes=New-FixtureLibraryHashes 'b'
    $line="    c1a = 'sha256:"+'a'*64+"'`n"
    foreach($source in @(
        '$other = 1',
        ($map+"`n"+$map),
        ($map+"`n"+'$EXPECTEDLIBRARYHASHES = @{}'),
        ($map+"`n"+'$script:expectedLibraryHashes = @{}'),
        ('function nested {'+"`n"+$map+"`n}"),
        $map.Replace('$expectedLibraryHashes','$script:expectedLibraryHashes'),
        $map.Replace('[ordered]@{','@{'),
        $map.Replace($line,''),
        $map.Replace($line,$line+$line.Replace('c1a','extra')),
        $map.Replace($line,$line+$line),
        $map.Replace($line,$line.Replace('c1a','temporary')).Replace('validator','c1a').Replace('temporary','validator'),
        $map.Replace("'sha256:"+'a'*64+"'",'$env:UNTRUSTED_HASH'),
        $map.Replace('sha256:','SHA256:'),
        $map.Replace('a'*64,'a'*63),
        $map.Replace("'sha256:"+'a'*64+"'",'(''sha256:'' + ''a'' * 64)')
    )) {
        Assert-Rejected { Get-C1bHelperLibraryHashTransformation $source $hashes } 'top-level|ordered literal|keys/order|literal|parser errors'
    }
}
Test-Case 'new repository hash authority rejects missing extra reordered and nonliteral values' {
    $map=New-FixtureLibraryMapSource (New-FixtureLibraryHashes)
    $missing=New-FixtureLibraryHashes;$missing.Remove('runner')
    $extra=New-FixtureLibraryHashes;$extra.extra='sha256:'+'a'*64
    $reordered=[ordered]@{runner=('sha256:'+'a'*64)}
    foreach($key in @('c1a','validator','c1b','artifact','aapt2','build')){$reordered[$key]='sha256:'+'a'*64}
    $uppercase=New-FixtureLibraryHashes;$uppercase.c1a='sha256:'+'A'*64
    $short=New-FixtureLibraryHashes;$short.c1a='sha256:'+'a'*63
    $nullHash=New-FixtureLibraryHashes;$nullHash.c1a=$null
    $scriptHash=New-FixtureLibraryHashes;$scriptHash.c1a={'sha256:'+'a'*64}
    $newline=New-FixtureLibraryHashes;$newline.c1a=('sha256:'+'a'*64+"`n")
    foreach($hashes in @($missing,$extra,$reordered,$uppercase,$short,$nullHash,$scriptHash,$newline)){
        Assert-Rejected { Get-C1bHelperLibraryHashTransformation $map $hashes } 'keys/order|lowercase SHA-256 literal'
    }
}
Test-Case 'preparation binds all seven final repository file bytes without newline normalization' {
    # 只载入三个生产读取函数；prepare 入口、冻结工件和外部进程均不执行。
    $prepare=Get-C1bCandidateSourceAst ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../prepare-tablet-layout-c1b-candidate-source.ps1')))
    foreach($name in @('Read-CandidateInput','Get-CandidateFileHash','Get-CandidateRepositoryLibraryHashes')){
        $functions=@($prepare.EndBlock.Statements | Where-Object {
            $_-is[Management.Automation.Language.FunctionDefinitionAst]-and$_.Name-ceq$name
        })
        Assert-Test ($functions.Count-eq1) 'Preparation byte reader is not uniquely defined.'
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
    $parent=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../.checks'))
    $null=[IO.Directory]::CreateDirectory($parent)
    $root=Join-Path $parent ('c1b-source-byte-fixture-'+[guid]::NewGuid().ToString('N'))
    $null=[IO.Directory]::CreateDirectory($root)
    try {
        $paths=[ordered]@{
            c1a='scripts/lib/tablet-layout-c1a.ps1';validator='scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1'
            c1b='scripts/lib/tablet-layout-c1b.ps1';artifact='scripts/lib/tablet-layout-c1b-artifact-proof.ps1'
            aapt2='scripts/lib/tablet-layout-c1b-aapt2.ps1';build='scripts/lib/tablet-layout-c1b-build-env.ps1'
            runner='scripts/run-tablet-layout-c1b.ps1'
        }
        $expected=[ordered]@{}
        foreach($entry in $paths.GetEnumerator()){
            $path=Join-Path $root $entry.Value
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes("# $($entry.Key)`n# 原始字节`n")
            [IO.File]::WriteAllBytes($path,$bytes)
            $expected[$entry.Key]='sha256:'+ [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
        $actual=Get-CandidateRepositoryLibraryHashes $root
        Assert-Test (($actual.Keys-join',')-ceq($paths.Keys-join',')) 'Preparation changed loader key order.'
        foreach($key in $paths.Keys){Assert-Test ($actual[$key]-ceq$expected[$key]) "Preparation did not bind raw bytes: $key"}
        # 执行实际入口的 raw-input 记录及输出前 revalidation AST，不运行 prepare 入口。
        $inputBuilders=@($prepare.EndBlock.Statements | Where-Object {
            $_-is[Management.Automation.Language.ForEachStatementAst]-and
            $_.Body.Extent.Text.Contains('$sourceInputs += [pscustomobject]@{')
        })
        $inputRechecks=@($prepare.EndBlock.Statements | Where-Object {
            $_-is[Management.Automation.Language.ForEachStatementAst]-and
            $_.Body.Extent.Text.Contains('Maintained source changed during preparation:')
        })
        Assert-Test ($inputBuilders.Count-eq1-and$inputRechecks.Count-eq1) 'Preparation input/revalidation blocks are not unique.'
        $RepoRoot=$root;$repositoryLibraryHashes=$actual;$sourceInputs=@()
        . ([scriptblock]::Create($inputBuilders[0].Extent.Text))
        Assert-Test ($sourceInputs.Count-eq7-and
            ($sourceInputs.path-join',')-ceq($paths.Values-join',')) 'Preparation review omitted a final repository loader input.'
        foreach($inputRecord in $sourceInputs){
            Assert-Test ($inputRecord.full-ceq(Join-Path $root $inputRecord.path)-and
                $inputRecord.sha256-cmatch'\A[0-9a-f]{64}\z') 'Preparation review recorded the wrong root or nonraw SHA-256.'
        }
        . ([scriptblock]::Create($inputRechecks[0].Extent.Text))
        $runnerPath=Join-Path $root $paths.runner
        [IO.File]::WriteAllBytes($runnerPath,[Text.UTF8Encoding]::new($false).GetBytes("# runner`r`n# 原始字节`r`n"))
        Assert-Rejected { . ([scriptblock]::Create($inputRechecks[0].Extent.Text)) } 'Maintained source changed during preparation'
        $crlf=Get-CandidateRepositoryLibraryHashes $root
        Assert-Test ($crlf.runner-cne$actual.runner) 'Preparation normalized LF/CRLF before hashing.'
        foreach($key in @('c1a','validator','c1b','artifact','aapt2','build')){
            Assert-Test ($crlf[$key]-ceq$actual[$key]) 'One changed file rewrote another loader binding.'
        }
        [IO.File]::Delete($runnerPath)
        Assert-Rejected { Get-CandidateRepositoryLibraryHashes $root } 'Could not find|cannot find|not find'
    }
    finally {
        $full=[IO.Path]::GetFullPath($root)
        if([IO.Path]::GetDirectoryName($full)-cne$parent-or
            [IO.Path]::GetFileName($full)-cnotmatch'^c1b-source-byte-fixture-[0-9a-f]{32}$'){
            throw 'Fixture cleanup escaped its exact generated root.'
        }
        Remove-Item -LiteralPath $full -Recurse -Force
    }
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
        RepositoryLibraryHashes=(New-FixtureLibraryHashes 'b')
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
Test-Case 'actual pair renderer derives the final repository helper and rejects drift before publication' {
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $sources = Join-Path $repository 'scripts/lib/c1b-candidate-source'
    $libraryHashes = [ordered]@{}
    foreach ($entry in (Get-C1bHelperLibraryPaths).GetEnumerator()) {
        $libraryHashes[$entry.Key] = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                [IO.File]::ReadAllBytes((Join-Path $repository $entry.Value)))).ToLowerInvariant()
    }
    $helperTemplate = [IO.File]::ReadAllText((Join-Path $sources 'helper-template.ps1'))
    $arguments = @{
        BaselineRendererSource=[IO.File]::ReadAllText((Join-Path $sources 'renderer-template.ps1'))
        HelperTemplateSource=$helperTemplate
        LauncherTemplateSource=[IO.File]::ReadAllText((Join-Path $sources 'launcher-template.ps1'))
        CommitSha=('a'*40); RepoRoot='C:\Fixture\CandidateRepo'
        StagingRoot='C:\Fixture\CandidateStage'; PwshPath='C:\Fixture\PowerShell\pwsh.exe'
        RepositoryLibraryHashes=$libraryHashes; VerifierSha256=('b'*64)
        UtilityAssemblySha256='2f6201bb3caf4c08158be733e786dd85b11537694f7e6ab40356fc0727a3596f'
        UtilityAssemblyLength=1652504L
    }
    $pair = New-C1bExactPairCandidateSource @arguments
    $pairAst = Get-C1bCandidateSourceAst $pair.RendererSource
    foreach ($name in @('Assert-Renderer','Replace-RendererExact')) {
        $definitions = @($pairAst.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name
        })
        Assert-Test ($definitions.Count -eq 1) 'Actual pair renderer assertion/replacement function drifted.'
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $publication = @($pairAst.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.TryStatementAst] -and
        $_.Body.Extent.Text.Contains('$helperText = [string]$inputByLabel[''helper_template''].Text')
    })
    Assert-Test ($publication.Count -eq 1) 'Actual pair renderer publication body is not unique.'
    $statements = @($publication[0].Body.Statements)
    $first = @($statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Extent.Text -ceq '$helperText = [string]$inputByLabel[''helper_template''].Text'
    })
    $last = @($statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Extent.Text -ceq '$launcherText = [string]$inputByLabel[''launcher_template_r11''].Text'
    })
    Assert-Test ($first.Count -eq 1 -and $last.Count -eq 1 -and
        $first[0].Extent.StartOffset -lt $last[0].Extent.StartOffset) 'Actual helper derivation boundaries drifted.'
    $helperStatements = @($statements | Where-Object {
        $_.Extent.StartOffset -ge $first[0].Extent.StartOffset -and
        $_.Extent.StartOffset -lt $last[0].Extent.StartOffset
    })
    $helperCode = [string]::Join("`n", @($helperStatements | ForEach-Object { $_.Extent.Text }))
    function New-RendererCandidate {
        param($TemporaryPath,$FinalPath,[string]$Text,[string]$ExpectedSha256,
            [long]$ExpectedLength,$ParentDirectoryEntry,$Label)
        Assert-Test ((Get-C1bCandidateSourceHash $Text) -ceq $ExpectedSha256 -and
            [Text.UTF8Encoding]::new($false,$true).GetByteCount($Text) -eq $ExpectedLength) 'Fixture final helper binding failed.'
        [void](Get-C1bCandidateSourceAst $Text)
        $script:actualHelperCandidateCount++
        return [pscustomobject]@{Sha256=$ExpectedSha256;Length=$ExpectedLength;Text=$Text}
    }
    function Invoke-ActualHelperFixture {
        param([string]$InputSource,[switch]$WrongExpectedHash)
        $inputByLabel = @{helper_template=[pscustomobject]@{Text=$InputSource}}
        $commitSha = $arguments.CommitSha; $commitShort = $commitSha.Substring(0,7)
        $helperTemporaryPath = Join-Path $arguments.StagingRoot 'helper-aaaaaaa-r11.rendering.tmp'
        $helperPath = Join-Path $arguments.StagingRoot 'helper-aaaaaaa-r11.ps1'
        $expectedHelperSha256 = if ($WrongExpectedHash) {'c'*64} else {$pair.HelperSha256}
        $expectedHelperLength = $pair.HelperByteLength
        $stagingDirectoryEntry = [pscustomobject]@{Path=$arguments.StagingRoot}
        $candidates = [Collections.Generic.List[object]]::new()
        $script:actualHelperCandidateCount = 0
        . ([scriptblock]::Create($helperCode))
        return [pscustomobject]@{Text=$helperText;Count=$candidates.Count;Candidate=$candidates[0]}
    }
    $result = Invoke-ActualHelperFixture $helperTemplate
    Assert-Test ($result.Text -ceq $pair.HelperSource -and $result.Count -eq 1 -and
        $script:actualHelperCandidateCount -eq 1 -and
        $result.Candidate.Sha256 -ceq $pair.HelperSha256 -and
        $result.Candidate.Length -eq $pair.HelperByteLength) 'Actual renderer bytes differ from in-memory helper derivation.'
    $renderedHashes = Read-FixtureLibraryMap $result.Text
    foreach ($key in $libraryHashes.Keys) {
        Assert-Test ($renderedHashes[$key] -ceq $libraryHashes[$key]) "Actual helper did not bind final repository bytes: $key"
    }
    Assert-Test ($result.Text.Contains('[switch]$FailureDiagnostics') -and
        $result.Text.Contains('-TimeoutSec 300 -FailureDiagnostics)')) 'Actual renderer lost Gradle failure diagnostics.'
    foreach ($source in @(
        $helperTemplate.Replace('[switch]$AllowFailure','[switch]$DifferentFailure'),
        $helperTemplate.Replace('-TimeoutSec 300)','-TimeoutSec 299)'),
        $helperTemplate.Replace('$expectedLibraryHashes = [ordered]@{','$otherLibraryHashes = [ordered]@{'))) {
        Assert-Rejected { Invoke-ActualHelperFixture $source } 'Helper source transform cardinality'
        Assert-Test ($script:actualHelperCandidateCount -eq 0) 'Drifted helper reached the publication boundary.'
    }
    Assert-Rejected { Invoke-ActualHelperFixture $helperTemplate -WrongExpectedHash } 'final helper binding'
    Assert-Test ($script:actualHelperCandidateCount -eq 0) 'Wrong expected hash reached the publication boundary.'
}
Write-Output "candidate source offline: $passed passed, 0 skipped"
