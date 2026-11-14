#Requires -Version 7.5
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/run-local-testbench.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Driver parse failed'}
foreach($name in @('Assert-Bench','Assert-BenchRemaining','Assert-BenchToolOk','Assert-BenchForeground','Get-BenchSnapshot','Get-BenchCount','Open-BenchRoute','Wait-BenchHumanReady','Invoke-BenchHumanAllow','Assert-BenchHumanAllowAudit')){
    $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing production function: $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
# Reuse the existing synthetic target/tool fixtures without editing or executing their test suite.
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'scripts/tests/local-testbench-human-allow-offline.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Fixture parse failed'}
foreach($name in @('New-Snapshot','Reset-Fixture','Invoke-BenchTool','Set-BenchPhase')){
    $nodes=@($fixtureAst.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing fixture function: $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$main=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($main.Count -ne 1){throw 'Main try missing or ambiguous'}
$barrier=@($main[0].Body.Statements|Where-Object {$_.Extent.Text -ceq 'if($HumanAllowProbe){Wait-BenchHumanReady}'})
$admission=@($main[0].Body.Statements|Where-Object {$_.Extent.Text.Contains("'required_gateway_tool_missing'")})
$routes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains("'r5-process-before'")},$true))
$audits=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Assert-BenchR5Observations $audit')},$true))
if($barrier.Count -ne 1 -or $admission.Count -ne 1 -or $routes.Count -ne 1 -or $audits.Count -ne 1){throw 'Production control flow missing or ambiguous'}
$barrierBody=[scriptblock]::Create($barrier[0].Extent.Text)
$humanBody=[scriptblock]::Create($routes[0].Clauses[1].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$auditBody=[scriptblock]::Create($audits[0].Clauses[1].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$script:passed=0; $script:caseIndex=0
function Check([string]$Name,[scriptblock]$Body){& $Body; $script:passed++; Write-Host "PASS $Name"}
function Expect-Rejected([scriptblock]$Body,[string]$Reason){
    $failure=$null
    try{& $Body}catch{$failure=$_.Exception.Message}
    if($failure -cne $Reason){throw "Expected $Reason, got $failure"}
}
function Reset-ReadyFixture {
    Reset-Fixture
    $script:caseIndex++
    $script:output=Join-Path $repoRoot ('.checks/human-allow-20261113/human-ready-case-'+$script:caseIndex)
    $script:readyPath=Join-Path $script:output 'human-ready'
    $script:cancelPath=Join-Path $script:output 'human-cancel'
    $script:signals=@{}; $script:checkedPaths=[Collections.Generic.List[string]]::new()
    $script:clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=0.0}}
    $script:sleeps=0; $script:readyAfter=0; $script:cancelAfter=0
}
# Only marker filesystem and local sleep I/O are replaced; waiting cannot issue gateway requests.
function Test-Path([string]$LiteralPath,[string]$PathType='Any'){
    $script:checkedPaths.Add($LiteralPath)
    if(-not $script:signals.ContainsKey($LiteralPath)){return $false}
    if($PathType -ceq 'Leaf'){return $script:signals[$LiteralPath] -cin @('leaf','reparse')}
    return $true
}
function Get-Item([string]$LiteralPath,[switch]$Force){
    if(-not $script:signals.ContainsKey($LiteralPath)){throw 'fixture_signal_missing'}
    $attributes=if($script:signals[$LiteralPath] -ceq 'reparse'){[IO.FileAttributes]::ReparsePoint}else{[IO.FileAttributes]::Normal}
    return [pscustomobject]@{Attributes=$attributes}
}
function Start-Sleep([int]$Milliseconds){
    if($Milliseconds -ne 250 -or $script:calls.Count -ne 0){throw 'Nonlocal operation while waiting for readiness'}
    $script:sleeps++; $script:clock.Elapsed.TotalSeconds++
    if($script:readyAfter -gt 0 -and $script:sleeps -eq $script:readyAfter){$script:signals[$script:readyPath]='leaf'}
    if($script:cancelAfter -gt 0 -and $script:sleeps -eq $script:cancelAfter){$script:signals[$script:cancelPath]='leaf'}
}
function Run-ReadyHumanPipeline {
    . $barrierBody
    . $humanBody
    $audit=$script:fixture.Audit
    . $auditBody
}
function Assert-NoGatewayCalls {
    if($script:calls.Count -ne 0 -or $summary.human_allow_verified -cne $false){throw 'Readiness failure reached gateway flow'}
}
Check 'barrier is after tool admission and before route or ref preparation' {
    if($admission[0].Extent.EndOffset -ge $barrier[0].Extent.StartOffset -or $barrier[0].Extent.EndOffset -ge $routes[0].Extent.StartOffset){throw 'Barrier placement invalid'}
}
Check 'no signal waits locally and consumes original remaining-budget clock without a gateway call' {
    Reset-ReadyFixture; $script:RuntimeSeconds=152
    Expect-Rejected {Run-ReadyHumanPipeline} 'runtime_budget_exhausted'
    Assert-NoGatewayCalls
    if($script:sleeps -ne 2 -or $script:clock.Elapsed.TotalSeconds -ne 2 -or ($script:phases -join ',') -cne 'await_human_ready'){throw 'Readiness wait reset or bypassed budget'}
}
Check 'current leaf ready releases exactly one original human flow with Android audit still required' {
    Reset-ReadyFixture; $script:signals[$script:readyPath]='leaf'
    Run-ReadyHumanPipeline
    if(@($script:calls|Where-Object Tool -CEQ 'ui_action').Count -ne 1 -or
        @($script:calls|Where-Object Tool -CEQ 'intent_send').Count -ne 1 -or
        ($script:phases -join ',') -cne 'await_human_ready,human_ready_received,await_human_allow' -or
        $summary.human_allow_verified -cne $true -or $script:sleeps -ne 0){throw 'Ready signal repeated or replaced original human flow'}
}
Check 'delayed ready waits with no gateway traffic and does not reset elapsed time' {
    Reset-ReadyFixture; $script:readyAfter=2; $script:clock.Elapsed.TotalSeconds=5
    Run-ReadyHumanPipeline
    if($script:sleeps -ne 2 -or $script:clock.Elapsed.TotalSeconds -ne 7 -or
        @($script:calls|Where-Object Tool -CEQ 'ui_action').Count -ne 1){throw 'Delayed ready reset budget or repeated click'}
}
Check 'cancel stops before any conversation or dangerous call' {
    Reset-ReadyFixture; $script:signals[$script:cancelPath]='leaf'
    Expect-Rejected {Run-ReadyHumanPipeline} 'human_ready_cancelled'; Assert-NoGatewayCalls
}
Check 'cancel wins when both markers exist' {
    Reset-ReadyFixture; $script:signals[$script:readyPath]='leaf'; $script:signals[$script:cancelPath]='leaf'
    Expect-Rejected {Run-ReadyHumanPipeline} 'human_ready_cancelled'; Assert-NoGatewayCalls
    if($script:checkedPaths -ccontains $script:readyPath){throw 'Ready evaluated before existing cancel'}
}
Check 'delayed cancellation remains local and stops before click' {
    Reset-ReadyFixture; $script:cancelAfter=1
    Expect-Rejected {Run-ReadyHumanPipeline} 'human_ready_cancelled'; Assert-NoGatewayCalls
    if($script:sleeps -ne 1){throw 'Cancellation was not observed on next local iteration'}
}
Check 'already exhausted reserve rejects even a present ready signal' {
    Reset-ReadyFixture; $script:RuntimeSeconds=150; $script:signals[$script:readyPath]='leaf'
    Expect-Rejected {Run-ReadyHumanPipeline} 'runtime_budget_exhausted'; Assert-NoGatewayCalls
    if($script:sleeps -ne 0){throw 'Exhausted reserve slept'}
}
Check 'previous output marker cannot release this output' {
    Reset-ReadyFixture; $script:RuntimeSeconds=152
    $old=Join-Path (Join-Path $repoRoot '.checks/human-allow-20261113/old-output') 'human-ready'
    $script:signals[$old]='leaf'
    Expect-Rejected {Run-ReadyHumanPipeline} 'runtime_budget_exhausted'; Assert-NoGatewayCalls
    if($script:checkedPaths -ccontains $old){throw 'Previous round marker was consulted'}
}
foreach($signal in @('ready','cancel')){
    foreach($kind in @('container','reparse')){
        Check "$signal $kind cannot release a gateway call" {
            Reset-ReadyFixture
            $path=if($signal -ceq 'ready'){$script:readyPath}else{$script:cancelPath}
            $script:signals[$path]=$kind
            $reason=if($kind -ceq 'container'){'human_ready_signal_not_leaf'}else{'human_ready_signal_reparse_point'}
            Expect-Rejected {Run-ReadyHumanPipeline} $reason; Assert-NoGatewayCalls
        }
    }
}
foreach($mode in @('default','R5','Ime')){
    Check "$mode does not enter readiness barrier" {
        Reset-ReadyFixture; $HumanAllowProbe=$false; $R5ObservationOnly=($mode -ceq 'R5'); $ImeProbe=($mode -ceq 'Ime')
        . $barrierBody
        if($script:sleeps -ne 0 -or $script:checkedPaths.Count -ne 0 -or $script:phases.Count -ne 0){throw 'Nonhuman mode waited'}
        Assert-NoGatewayCalls
    }
}
foreach($code in @('E_CONFIRM_TIMEOUT','E_BLOCKED')){
    Check "ready cannot replace Android card decision $code" {
        Reset-ReadyFixture; $script:signals[$script:readyPath]='leaf'
        $script:fixture.Response=[pscustomobject]@{ok=$false;error=[pscustomobject]@{code=$code}}
        Expect-Rejected {Run-ReadyHumanPipeline} ('tool_failed_'+$code.ToLowerInvariant())
        if(@($script:calls|Where-Object Tool -CEQ 'ui_action').Count -ne 1 -or
            $summary.human_allow_verified -cne $false -or $summary.callback_count_after -cne 'UNKNOWN'){throw 'Readiness became Android approval or caused retry'}
    }
}
Check 'ready does not weaken overlay-only audit requirement' {
    Reset-ReadyFixture; $script:signals[$script:readyPath]='leaf'
    $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace('decided_via=overlay','decided_via=notification')
    Expect-Rejected {Run-ReadyHumanPipeline} 'human_allow_decision_not_proven'
    if($summary.human_allow_verified -cne $false){throw 'Readiness bypassed real approval-channel check'}
}
Write-Host "local-testbench-human-ready-offline: $script:passed passed; no SDK/ADB/network/runtime executed"
