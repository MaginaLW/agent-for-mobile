#Requires -Version 7.5
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$driver=Join-Path $repoRoot 'scripts/run-local-testbench.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($driver,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Driver parse failed'}
foreach($name in @('Assert-Bench','Assert-BenchToolOk','Assert-BenchForeground','Get-BenchSnapshot','Get-BenchCount','Open-BenchRoute','Assert-BenchRemaining','Invoke-BenchHumanAllow','Assert-BenchHumanAllowAudit')){
    $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing function: $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$routeBranches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains("'r5-process-before'")},$true))
$auditBranches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Assert-BenchR5Observations $audit')},$true))
if($routeBranches.Count -ne 1 -or $auditBranches.Count -ne 1){throw 'Production branches missing or ambiguous'}
$routeBody=[scriptblock]::Create($routeBranches[0].Clauses[1].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$auditBody=[scriptblock]::Create($auditBranches[0].Clauses[1].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$emulatorStatements=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.AssignmentStatementAst] -and
        ($node.Extent.Text.StartsWith('$emulatorArguments=@(') -or $node.Extent.Text.StartsWith('$emulatorArguments+=@(') -or
        $node.Extent.Text.StartsWith('$emulator=Start-BenchProcess $emulatorExe $emulatorArguments'))) -or
    ($node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -ceq "if(-not `$HumanAllowProbe){`$emulatorArguments+=,'-no-window'}")
},$true)|Sort-Object {$_.Extent.StartOffset})
if($emulatorStatements.Count -ne 4){throw 'Emulator production arguments missing or ambiguous'}
$emulatorBody=[scriptblock]::Create(($emulatorStatements.Extent.Text -join "`n"))
$script:passed=0
function Check([string]$Name,[scriptblock]$Body){& $Body; $script:passed++; Write-Host "PASS $Name"}
function Expect-Rejected([scriptblock]$Body,[string]$Reason){
    $message=$null
    try{& $Body}catch{$message=$_.Exception.Message}
    if($message -cne $Reason){throw "Expected $Reason, got $message"}
}
function New-Snapshot([int]$Count){
    return [pscustomobject]@{ok=$true;audit_id='a-000002';ctx=[pscustomobject]@{app='dev.magina.testtarget';foreground_known=$true};data=[pscustomobject]@{
        truncated=$false;elements=@(
            [pscustomobject]@{text=('本地发送回调次数：'+$Count);role='text';source='a11y';ref='count-1'},
            [pscustomobject]@{text='发送（仅本地计数）';role='button';source='a11y';ref='node-1'}
        )
    }}
}
function Reset-Fixture {
    $script:HumanAllowProbe=$true; $script:R5ObservationOnly=$false; $script:ImeProbe=$false
    $script:RuntimeSeconds=900; $script:clock=[Diagnostics.Stopwatch]::StartNew()
    $script:summary=@{routes_verified=@();callback_count_before='UNKNOWN';callback_count_after='UNKNOWN';confirmation_result='UNKNOWN';human_allow_verified=$false}
    $script:calls=[Collections.Generic.List[object]]::new(); $script:phases=[Collections.Generic.List[string]]::new()
    $script:fixture=@{
        Before=(New-Snapshot 0);After=(New-Snapshot 1)
        Foreground=[pscustomobject]@{ok=$true;ctx=[pscustomobject]@{app='dev.magina.testtarget';foreground_known=$true}}
        Response=[pscustomobject]@{ok=$true;audit_id='a-000003';data=[pscustomobject]@{done=$true};ctx=[pscustomobject]@{app='dev.magina.testtarget';foreground_known=$true}}
        Audit=@([pscustomobject]@{id='a-000003';tool='ui_action';result='OK';channel='a11y';args=[pscustomobject]@{ref='node-1';action='click'};note='risk=confirmation_required;confirmation=requested;confirmation=allowed;decided_via=overlay;context=rechecked'})
    }
}
# Replace I/O only. The routing, snapshots, selection, action and audit checks above are production code.
function Invoke-BenchTool([string]$Tool,$Arguments,[string]$Name,[int]$TimeoutSeconds=25){
    $script:calls.Add([pscustomobject]@{Tool=$Tool;Arguments=$Arguments;Name=$Name;TimeoutSeconds=$TimeoutSeconds})
    switch -CaseSensitive ($Tool){
        'foreground_app' {return $script:fixture.Foreground}
        'intent_send' {return [pscustomobject]@{ok=$true}}
        'ui_snapshot' {
            if($Name -ceq 'human-allow-before'){return $script:fixture.Before}
            if($Name -ceq 'human-allow-after'){return $script:fixture.After}
            throw 'unexpected_snapshot'
        }
        'ui_action' {
            if($Arguments.action -cne 'click' -or $Name -cne 'human-allowed-click'){throw 'unexpected_action'}
            return $script:fixture.Response
        }
        default {throw 'unexpected_tool'}
    }
}
function Set-BenchPhase([string]$Phase){$script:phases.Add($Phase)}
function Run-HumanPipeline {
    . $routeBody
    $audit=$script:fixture.Audit
    . $auditBody
}
Check 'real production branches bind one human click and count 0 to 1 to its audit' {
    Reset-Fixture; Run-HumanPipeline
    $routes=@($script:calls|Where-Object Tool -CEQ 'intent_send')
    $actions=@($script:calls|Where-Object Tool -CEQ 'ui_action')
    if($routes.Count -ne 1 -or $routes[0].Arguments.uri -cne 'agent-testbench://target/conversation' -or
        $routes[0].Arguments.package -cne 'dev.magina.testtarget' -or $actions.Count -ne 1 -or
        $actions[0].Arguments.ref -cne 'node-1' -or $actions[0].TimeoutSeconds -le 60 -or
        ($script:phases -join ',') -cne 'await_human_allow' -or $summary.callback_count_before -ne 0 -or
        $summary.callback_count_after -ne 1 -or $summary.human_allow_verified -cne $true -or
        $summary.confirmation_result -cne 'allowed'){throw 'Human branch execution differs'}
    $expected=@('route-conversation','route-conversation-foreground','human-allow-before-foreground','human-allow-before','human-allowed-click','human-allow-after-foreground','human-allow-after')
    if(($script:calls.Name -join '|') -cne ($expected -join '|')){throw 'Unexpected extra route, input or action'}
}
foreach($case in @(
    @('missing count',{ $script:fixture.Before.data.elements=@($script:fixture.Before.data.elements[1]) },'target_callback_count_unavailable'),
    @('duplicate count',{ $script:fixture.Before.data.elements+=,$script:fixture.Before.data.elements[0] },'target_callback_count_unavailable'),
    @('before count source array',{ $script:fixture.Before.data.elements[0].source=@('a11y') },'target_callback_count_unavailable'),
    @('before count text array',{ $script:fixture.Before.data.elements[0].text=@('本地发送回调次数：0') },'target_callback_count_unavailable'),
    @('nonzero initial count',{ $script:fixture.Before=New-Snapshot 1 },'human_allow_counter_not_zero_before'),
    @('missing button',{ $script:fixture.Before.data.elements=@($script:fixture.Before.data.elements[0]) },'human_allow_button_not_unique'),
    @('duplicate button',{ $script:fixture.Before.data.elements+=,$script:fixture.Before.data.elements[1] },'human_allow_button_not_unique'),
    @('OCR button not accepted',{ $script:fixture.Before.data.elements[1].source='ocr' },'human_allow_button_not_unique'),
    @('array button text',{ $script:fixture.Before.data.elements[1].text=@('发送（仅本地计数）') },'human_allow_button_not_unique'),
    @('array button source',{ $script:fixture.Before.data.elements[1].source=@('a11y') },'human_allow_button_not_unique'),
    @('empty ref',{ $script:fixture.Before.data.elements[1].ref='' },'human_allow_button_ref_missing'),
    @('wrong snapshot package',{ $script:fixture.Before.ctx.app='other.app' },'snapshot_foreground_changed'),
    @('snapshot foreground unknown',{ $script:fixture.Before.ctx.foreground_known=$false },'human_allow_snapshot_foreground_unknown'),
    @('snapshot package array',{ $script:fixture.Before.ctx.app=@('dev.magina.testtarget') },'human_allow_snapshot_foreground_unknown'),
    @('truncated snapshot',{ $script:fixture.Before.data.truncated=$true },'human_allow_snapshot_truncated'),
    @('string truncation flag',{ $script:fixture.Before.data.truncated='False' },'human_allow_snapshot_truncated'),
    @('foreground changed before snapshot',{ $script:fixture.Foreground.ctx.app='other.app' },'target_not_current_foreground')
)){
    Check $case[0] {
        Reset-Fixture; & $case[1]; Expect-Rejected {Run-HumanPipeline} $case[2]
        if(@($script:calls|Where-Object Tool -CEQ 'ui_action').Count -ne 0 -or $summary.human_allow_verified -cne $false){throw 'Action occurred after invalid preparation'}
    }
}
foreach($case in @(
    @('no callback',{ $script:fixture.After=New-Snapshot 0 },'human_allow_callback_count_not_one'),
    @('extra callbacks',{ $script:fixture.After=New-Snapshot 2 },'human_allow_callback_count_not_one'),
    @('missing after count',{ $script:fixture.After.data.elements=@($script:fixture.After.data.elements[1]) },'target_callback_count_unavailable'),
    @('after count source array',{ $script:fixture.After.data.elements[0].source=@('a11y') },'target_callback_count_unavailable'),
    @('after count text array',{ $script:fixture.After.data.elements[0].text=@('本地发送回调次数：1') },'target_callback_count_unavailable'),
    @('after context changed',{ $script:fixture.After.ctx.app='other.app' },'snapshot_foreground_changed'),
    @('response context changed',{ $script:fixture.Response.ctx.app='other.app' },'human_allow_response_invalid'),
    @('response context array',{ $script:fixture.Response.ctx.app=@('dev.magina.testtarget') },'human_allow_response_invalid'),
    @('response foreground unknown',{ $script:fixture.Response.ctx.foreground_known=$false },'human_allow_response_invalid'),
    @('done string',{ $script:fixture.Response.data.done='True' },'human_allow_response_invalid'),
    @('response boolean string',{ $script:fixture.Response.ok='True' },'human_allow_response_invalid'),
    @('denied',{ $script:fixture.Response=[pscustomobject]@{ok=$false;error=[pscustomobject]@{code='E_BLOCKED'}} },'tool_failed_e_blocked'),
    @('timed out',{ $script:fixture.Response=[pscustomobject]@{ok=$false;error=[pscustomobject]@{code='E_CONFIRM_TIMEOUT'}} },'tool_failed_e_confirm_timeout'),
    @('stale',{ $script:fixture.Response=[pscustomobject]@{ok=$false;error=[pscustomobject]@{code='E_STALE_REF'}} },'tool_failed_e_stale_ref')
)){
    Check $case[0] {
        Reset-Fixture; & $case[1]; Expect-Rejected {Run-HumanPipeline} $case[2]
        if(@($script:calls|Where-Object Tool -CEQ 'ui_action').Count -ne 1 -or
            @($script:calls|Where-Object Tool -CEQ 'intent_send').Count -ne 1 -or $summary.human_allow_verified -cne $false){throw 'Failed action retried or callback reset'}
    }
}
foreach($case in @(
    @('missing audit',{ $script:fixture.Audit=@() },'human_allow_audit_missing_or_duplicate'),
    @('duplicate audit',{ $script:fixture.Audit+=,$script:fixture.Audit[0] },'human_allow_audit_missing_or_duplicate'),
    @('wrong audit ID',{ $script:fixture.Audit[0].id='a-000004' },'human_allow_audit_missing_or_duplicate'),
    @('invalid response ID',{ $script:fixture.Response.audit_id='invalid' },'human_allow_response_audit_id_invalid'),
    @('wrong tool',{ $script:fixture.Audit[0].tool='press_key' },'human_allow_audit_call_mismatch'),
    @('wrong ref',{ $script:fixture.Audit[0].args.ref='node-2' },'human_allow_audit_call_mismatch'),
    @('wrong action',{ $script:fixture.Audit[0].args.action='long_click' },'human_allow_audit_call_mismatch'),
    @('wrong result',{ $script:fixture.Audit[0].result='E_BLOCKED' },'human_allow_audit_call_mismatch'),
    @('wrong channel',{ $script:fixture.Audit[0].channel='gesture' },'human_allow_audit_call_mismatch'),
    @('audit ID array',{ $script:fixture.Audit[0].id=@('a-000003') },'human_allow_audit_call_mismatch'),
    @('audit ref array',{ $script:fixture.Audit[0].args.ref=@('node-1') },'human_allow_audit_call_mismatch'),
    @('audit tool array',{ $script:fixture.Audit[0].tool=@('ui_action') },'human_allow_audit_call_mismatch'),
    @('extra action audit',{ $other=$script:fixture.Audit[0]|ConvertTo-Json -Depth 8|ConvertFrom-Json; $other.id='a-000004'; $script:fixture.Audit+=,$other },'human_allow_extra_action_audit'),
    @('note array',{ $script:fixture.Audit[0].note=@($script:fixture.Audit[0].note) },'human_allow_audit_note_invalid'),
    @('wrong decision',{ $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace('confirmation=allowed','confirmation=denied') },'human_allow_decision_not_proven'),
    @('notification decision',{ $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace('decided_via=overlay','decided_via=notification') },'human_allow_decision_not_proven'),
    @('missing channel token',{ $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace(';decided_via=overlay','') },'human_allow_decision_not_proven'),
    @('missing recheck',{ $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace(';context=rechecked','') },'human_allow_decision_not_proven'),
    @('conflicting context',{ $script:fixture.Audit[0].note+=';context=changed' },'human_allow_decision_not_proven'),
    @('duplicate decision',{ $script:fixture.Audit[0].note+=';confirmation=allowed' },'human_allow_decision_not_proven'),
    @('missing requested token',{ $script:fixture.Audit[0].note=$script:fixture.Audit[0].note.Replace(';confirmation=requested','') },'human_allow_decision_not_proven')
)){
    Check $case[0] {
        Reset-Fixture; & $case[1]; Expect-Rejected {Run-HumanPipeline} $case[2]
        if($summary.human_allow_verified -cne $false){throw 'Invalid audit granted verification'}
    }
}
function Start-BenchProcess([string]$File,[string[]]$Arguments){$script:emulatorArgumentsObserved=$Arguments;return [pscustomobject]@{Process=$null}}
foreach($visible in @($false,$true)){
    Check "actual emulator arguments visible=$visible" {
        $HumanAllowProbe=$visible; $summary=@{avd_name='fixture-avd'}; $ConsolePort=5580; $emulatorExe='fixture-emulator'
        . $emulatorBody
        $hasNoWindow=$script:emulatorArgumentsObserved -ccontains '-no-window'
        if($hasNoWindow -eq $visible -or -not($script:emulatorArgumentsObserved -ccontains '-no-snapshot') -or
            -not($script:emulatorArgumentsObserved -ccontains '5580,5581')){throw 'Unexpected emulator visibility or isolation arguments'}
    }
}
foreach($conflict in @('ImeProbe','R5ObservationOnly')){
    Check "CLI human mode conflict with $conflict before native" {
        $scratch=Join-Path $repoRoot ('.checks/human-allow-20261113/cli-'+[guid]::NewGuid().ToString('N'))
        $missing=Join-Path $scratch 'absent'
        $arguments=@('-NoProfile','-File',$driver,'-SdkRoot',$missing,'-AvdManagerPath',$missing,'-JavaHome',$missing,'-ApkSignerPath',$missing,'-GatewayApk',$missing,'-TargetApk',$missing,'-ExpectedSourceSha',('a'*40),'-ExpectedGatewaySha256',('b'*64),'-ExpectedTargetSha256',('c'*64),'-OutputDirectory',$scratch,'-Run','-HumanAllowProbe',('-'+$conflict))
        & (Get-Process -Id $PID).Path @arguments | Out-Null
        if($LASTEXITCODE -ne 1){throw 'Conflict did not exit 1'}
        $receipt=Get-Content -LiteralPath (Join-Path $scratch 'summary.json') -Raw|ConvertFrom-Json
        if($receipt.failure_reason -cne 'human_allow_mode_conflict' -or $receipt.verification_scope -cne 'human_allow_only' -or
            $receipt.human_allow_verified -cne $false -or $receipt.cleanup_proven -cne $false -or
            $receipt.runtime_acceptance -cne $false -or $receipt.production_execution_grant -cne $false -or
            @(Get-ChildItem -LiteralPath $scratch -Filter '*.stdout.txt').Count -ne 0){throw 'Conflict receipt invalid'}
    }
}
Write-Host "local-testbench-human-allow-offline: $script:passed passed; no SDK/ADB/runtime executed"
