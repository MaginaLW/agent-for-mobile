#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$sourceRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$checker = Join-Path $sourceRoot 'scripts/check-contract-coverage.ps1'
$pwsh = (Get-Process -Id $PID).Path
$scratch = Join-Path $sourceRoot ('.checks/reduce-manual-20261111/contract-gate/run-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $scratch -Force)
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$env:TEMP = $scratch
$env:TMP = $scratch
$script:CaseCount = 0
$script:Passed = 0
$script:Failed = 0
$contract = 'docs/contracts/tablet-c1b-inventory-result-v3.schema.json'
$test = 'scripts/tests/tablet-c1b-inventory-result-offline.ps1'
$otherTest = 'scripts/tests/unrelated-offline.ps1'

function Invoke-CaseProcess([string]$Executable, [string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'fixture process start failed' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
    } finally { $process.Dispose() }
}
function Invoke-CaseGit([string[]]$Arguments) {
    $result = Invoke-CaseProcess 'git' (@('-C', $script:Repo) + $Arguments)
    if ($result.ExitCode -ne 0) { throw "fixture git failed: $($Arguments[0])" }
}
function Set-CaseFile([string]$RelativePath, [string]$Text) {
    $path = Join-Path $script:Repo $RelativePath
    [void](New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force)
    [IO.File]::WriteAllText($path, $Text + "`n", [Text.UTF8Encoding]::new($false))
}
function New-CaseRepo {
    $script:CaseCount++
    $script:Repo = Join-Path $scratch ('case-' + $script:CaseCount)
    [void](New-Item -ItemType Directory -Path $script:Repo)
    Invoke-CaseGit @('init', '--quiet')
    Invoke-CaseGit @('config', 'user.name', 'Offline Fixture')
    Invoke-CaseGit @('config', 'user.email', 'fixture@example.invalid')
    Invoke-CaseGit @('config', 'core.autocrlf', 'false')
    Set-CaseFile $contract '{"version":1}'
    Set-CaseFile $test '# baseline inventory tests'
    Set-CaseFile $otherTest '# baseline unrelated tests'
    Invoke-CaseGit @('add', '--', '.')
    Invoke-CaseGit @('commit', '--quiet', '-m', 'fixture baseline')
}
function Invoke-Coverage([string[]]$Extra = @()) {
    $result = Invoke-CaseProcess $pwsh (@('-NoProfile', '-File', $checker, '-RepoRoot', $script:Repo) + $Extra)
    if ([string]::IsNullOrWhiteSpace($result.Stdout)) { throw 'checker did not emit summary' }
    $summary = $result.Stdout | ConvertFrom-Json -Depth 20
    if ($summary.schema -cne 'contract-coverage/v1') { throw 'wrong summary schema' }
    if ($summary.test_execution_verified -or $summary.device_run_authorized) { throw 'coverage gate granted execution' }
    if (($result.ExitCode -eq 0) -ne ($summary.status -ceq 'passed')) { throw 'exit and summary disagree' }
    return $summary
}
function Assert-Case([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { New-CaseRepo; & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}

try {
    Test-Case 'no changes is empty passing input' {
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed' -and $r.contract_view_count -eq 0) 'empty input failed'
    }
    Test-Case 'working tree contract without tests fails' {
        Set-CaseFile $contract '{"version":2}'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks.Count -eq 1 -and $r.checks[0].scope -ceq 'working_tree' -and $r.checks[0].status -ceq 'missing_test_change') 'working tree did not fail'
    }
    Test-Case 'staged contract checked in both views' {
        Set-CaseFile $contract '{"version":2}'
        Invoke-CaseGit @('add', '--', $contract)
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.failed_count -eq 2) 'index missing'
    }
    Test-Case 'corresponding working tree tests cover contract' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile $test '# changed inventory behavior test'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed' -and $r.checks[0].status -ceq 'covered' -and $r.checks[0].changed_tests[0] -ceq $test) 'matching tests not used'
    }
    Test-Case 'corresponding staged tests cover both views' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile $test '# changed inventory behavior test'
        Invoke-CaseGit @('add', '--', $contract, $test)
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed' -and $r.checks.Count -eq 2) 'staged match failed'
    }
    Test-Case 'unrelated tests cannot cover contract' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile $otherTest '# unrelated change'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks[0].changed_tests.Count -eq 0) 'unrelated tests covered'
    }
    Test-Case 'real corpus replay covers inventory contract' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile 'scripts/tests/c1b-corpus-replay-offline.ps1' '# changed inventory replay assertion'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed' -and $r.checks[0].changed_tests[0] -ceq 'scripts/tests/c1b-corpus-replay-offline.ps1') 'inventory replay mapping missing'
    }
    Test-Case 'real corpus replay covers c1b observation contract' {
        Set-CaseFile 'docs/contracts/tablet-layout-observation-c1b-v2.schema.json' '{"version":2}'
        Set-CaseFile 'scripts/tests/c1b-corpus-replay-offline.ps1' '# changed unknown window replay assertion'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed') 'observation replay mapping missing'
    }
    Test-Case 'real corpus replay cannot cover unrelated layout contract' {
        Set-CaseFile 'docs/contracts/tablet-layout-observation-v2.schema.json' '{"version":2}'
        Set-CaseFile 'scripts/tests/c1b-corpus-replay-offline.ps1' '# c1b only replay assertion'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks[0].status -ceq 'missing_test_change') 'c1b replay widened unrelated contract'
    }
    Test-Case 'unstaged tests cannot cover staged contract' {
        Set-CaseFile $contract '{"version":2}'
        Invoke-CaseGit @('add', '--', $contract)
        Set-CaseFile $test '# working tree only'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and @($r.checks | Where-Object { $_.scope -ceq 'index' -and $_.status -ceq 'missing_test_change' }).Count -eq 1) 'unstaged test covered index'
    }
    Test-Case 'reverted working tree test cannot borrow index coverage' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile $test '# index only change'
        Invoke-CaseGit @('add', '--', $contract, $test)
        Set-CaseFile $test '# baseline inventory tests'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and @($r.checks | Where-Object { $_.scope -ceq 'working_tree' -and $_.status -ceq 'missing_test_change' }).Count -eq 1) 'index test covered reverted working tree'
    }
    Test-Case 'deleting a test does not count as coverage' {
        Set-CaseFile $contract '{"version":2}'
        Remove-Item -LiteralPath (Join-Path $script:Repo $test)
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks[0].changed_tests.Count -eq 0) 'deleted test covered contract'
    }
    Test-Case 'new known contract requires mapped tests' {
        Set-CaseFile 'docs/contracts/tablet-c1b-inventory-result-v2.schema.json' '{"version":2}'
        Set-CaseFile $test '# new version rejection case'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed' -and $r.contract_view_count -eq 1) 'untracked known contract ignored'
    }
    Test-Case 'unknown contract fails despite test changes and unicode path is preserved' {
        $path = 'docs/contracts/新 合同.md'
        Set-CaseFile $path '# new contract'
        Set-CaseFile $test '# arbitrary test change'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks[0].status -ceq 'unmapped_contract' -and $r.checks[0].contract -ceq $path) 'unknown contract silently passed or path changed'
    }
    Test-Case 'removed contract still needs a corresponding test change' {
        Remove-Item -LiteralPath (Join-Path $script:Repo $contract)
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.checks[0].contract -ceq $contract) 'deleted contract ignored'
    }
    Test-Case 'removed contract with corresponding test change passes' {
        Remove-Item -LiteralPath (Join-Path $script:Repo $contract)
        Set-CaseFile $test '# removed version is now rejected'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'passed') 'removal tests ignored'
    }
    Test-Case 'rename is checked as old and new contract' {
        Move-Item -LiteralPath (Join-Path $script:Repo $contract) -Destination (Join-Path $script:Repo 'docs/contracts/unmapped.schema.json')
        Set-CaseFile $test '# old contract removed'
        $r = Invoke-Coverage
        Assert-Case ($r.status -ceq 'failed' -and $r.contract_view_count -eq 2 -and @($r.checks | Where-Object { $_.status -ceq 'unmapped_contract' }).Count -eq 1) 'renamed unknown contract escaped'
    }
    Test-Case 'explicit exemption retains reason for each uncovered contract' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile 'docs/contracts/unmapped.md' '# explanatory contract'
        $r = Invoke-Coverage @('-ExemptionReason', '说明文字修正；已核原用例')
        Assert-Case ($r.status -ceq 'passed' -and $r.checks.Count -eq 2 -and @($r.checks | Where-Object { $_.status -ceq 'exempted' -and $_.exemption_reason -ceq '说明文字修正；已核原用例' }).Count -eq 2) 'exemption not recorded'
    }
    Test-Case 'empty exemption is rejected' {
        $r = Invoke-Coverage @('-ExemptionReason', '   ')
        Assert-Case ($r.status -ceq 'failed' -and $r.reason -ceq 'exemption_reason_empty') 'empty exemption passed'
    }
    Test-Case 'base ref includes committed contract changes' {
        Set-CaseFile $contract '{"version":2}'
        Invoke-CaseGit @('add', '--', $contract)
        Invoke-CaseGit @('commit', '--quiet', '-m', 'contract without tests')
        $r = Invoke-Coverage @('-BaseRef', 'HEAD~1')
        Assert-Case ($r.status -ceq 'failed' -and $r.failed_count -eq 2) 'committed contract diff ignored'
    }
    Test-Case 'base ref accepts corresponding committed tests' {
        Set-CaseFile $contract '{"version":2}'
        Set-CaseFile $test '# committed corresponding test'
        Invoke-CaseGit @('add', '--', $contract, $test)
        Invoke-CaseGit @('commit', '--quiet', '-m', 'contract with tests')
        $r = Invoke-Coverage @('-BaseRef', 'HEAD~1')
        Assert-Case ($r.status -ceq 'passed' -and $r.checks.Count -eq 2) 'committed tests ignored'
    }
    Test-Case 'invalid ref fails even with exemption' {
        $r = Invoke-Coverage @('-BaseRef', 'missing-fixture-ref', '-ExemptionReason', 'not permission to ignore git failure')
        Assert-Case ($r.status -ceq 'failed' -and $r.reason -ceq 'base_ref_invalid') 'git ref failure passed'
    }
    Test-Case 'empty base ref fails' {
        $r = Invoke-Coverage @('-BaseRef', '')
        Assert-Case ($r.status -ceq 'failed' -and $r.reason -ceq 'base_ref_invalid') 'empty ref passed'
    }
} finally {
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
}
Write-Host "contract coverage offline: $script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
