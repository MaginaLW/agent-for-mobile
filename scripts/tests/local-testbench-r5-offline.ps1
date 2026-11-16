#Requires -Version 7.5
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$driver=Join-Path $repoRoot 'scripts/run-local-testbench.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($driver,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Driver parse failed'}
foreach($name in @('Assert-Bench','Open-BenchRoute','Assert-BenchR5Observations')){
    $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing function: $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$routeBranches=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains("'r5-process-before'")},$true))
if($routeBranches.Count -ne 1){throw 'R5 route branch missing or ambiguous'}
$routeBody=[scriptblock]::Create($routeBranches[0].Clauses[0].Item2.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
$script:passed=0
function Check([string]$Name,[scriptblock]$Body){& $Body; $script:passed++; Write-Host "PASS $Name"}
function Expect-Rejected([scriptblock]$Body,[string]$Reason){
    $message=$null
    try{& $Body}catch{$message=$_.Exception.Message}
    if($message -cne $Reason){throw "Expected $Reason, got $message"}
}
function New-Fixture {
    $routes=[ordered]@{}; $audit=@(); $index=0
    foreach($route in @('list','search','conversation')){
        $index++; $id='a-'+$index.ToString('D6')
        $response=[pscustomobject]@{ok=$true;audit_id=$id;data=[pscustomobject]@{sent=$true;target_package='dev.magina.testtarget';foreground_verified=$true;verification_scope='package';verification_status='verified'}}
        $routes[$route]=$response
        $note=[ordered]@{v=1;available=$true;pid=1234;process_instance='12345678-1234-4234-8234-123456789abc';audit_id=$id;dispatch='returned';dispatch_entered_ms=($index*100);dispatch_returned_ms=($index*100+1);poll='hit';poll_start_ms=($index*100+2);poll_end_ms=($index*100+3);checks=1}
        $audit+=,[pscustomobject]@{id=$id;tool='intent_send';result='OK';channel='intent';args=[pscustomobject]@{action='android.intent.action.VIEW';package='dev.magina.testtarget';uri=('agent-testbench://target/'+$route)};note=(';r5_observation='+($note|ConvertTo-Json -Compress))}
    }
    return @{Routes=$routes;Audit=$audit}
}
function Change-Note($Fixture,[string]$Key,$Value,[int]$Index=0){
    $note=$Fixture.Audit[$Index].note.Substring(';r5_observation='.Length)|ConvertFrom-Json -AsHashtable
    $note[$Key]=$Value
    $Fixture.Audit[$Index].note=';r5_observation='+($note|ConvertTo-Json -Compress)
}
Check 'three real-format route responses bind to matching audit notes' {
    $f=New-Fixture; Assert-BenchR5Observations $f.Audit $f.Routes 1234
}
foreach($case in @(
    @('missing third route',{param($f) $f.Routes.Remove('conversation')},'r5_route_or_process_missing'),
    @('missing audit',{param($f) $f.Audit=$f.Audit[1..2]},'r5_audit_missing_or_duplicate'),
    @('duplicate audit',{param($f) $f.Audit+=,$f.Audit[0]},'r5_audit_missing_or_duplicate'),
    @('reused response ID',{param($f) $f.Routes.search.audit_id=$f.Routes.list.audit_id},'r5_route_audit_id_invalid'),
    @('wrong route URI',{param($f) $f.Audit[0].args.uri='agent-testbench://target/search'},'r5_audit_route_mismatch'),
    @('response not verified',{param($f) $f.Routes.list.data.foreground_verified=$false},'r5_route_response_unverified'),
    @('response bool string',{param($f) $f.Routes.list.data.foreground_verified='True'},'r5_route_response_unverified'),
    @('missing note',{param($f) $f.Audit[0].note=''},'r5_note_missing_or_duplicate'),
    @('duplicate marker',{param($f) $f.Audit[0].note+=';r5_observation={}'},'r5_note_missing_or_duplicate'),
    @('unavailable sentinel',{param($f) $f.Audit[0].note=';r5_observation=unavailable'},'r5_note_invalid_json'),
    @('unavailable note',{param($f) Change-Note $f available $false},'r5_note_identity_unverified'),
    @('availability string',{param($f) Change-Note $f available 'True'},'r5_note_identity_unverified'),
    @('wrong PID',{param($f) Change-Note $f pid 4321},'r5_note_identity_unverified'),
    @('PID string',{param($f) Change-Note $f pid '1234'},'r5_note_identity_unverified'),
    @('wrong note audit ID',{param($f) Change-Note $f audit_id 'a-999999'},'r5_note_identity_unverified'),
    @('process instance changed',{param($f) Change-Note $f process_instance '12345678-1234-4234-8234-123456789abd' 1},'r5_process_instance_changed'),
    @('timeout cannot pass positive probe',{param($f) Change-Note $f poll 'timeout'},'r5_note_not_positive_landing'),
    @('zero completed checks',{param($f) Change-Note $f checks 0},'r5_note_not_positive_landing'),
    @('dispatch did not return',{param($f) Change-Note $f dispatch 'entered'},'r5_note_not_positive_landing'),
    @('reversed timestamps',{param($f) Change-Note $f poll_end_ms 0},'r5_note_time_order_invalid'),
    @('missing timestamp',{param($f) Change-Note $f poll_start_ms $null},'r5_note_time_order_invalid'),
    @('timestamp numeric string',{param($f) Change-Note $f poll_start_ms '102'},'r5_note_time_order_invalid'),
    @('cross-call time reversal',{param($f) Change-Note $f dispatch_entered_ms 100 1},'r5_note_time_order_invalid')
)){
    Check $case[0] {$f=New-Fixture; & $case[1] $f; Expect-Rejected {Assert-BenchR5Observations $f.Audit $f.Routes 1234} $case[2]}
}
# Execute the actual production R5 branch with only its I/O boundaries replaced.
function Invoke-BenchAdb($Arguments,[string]$Name){$script:calls.Add($Name); return '1234'}
function Invoke-BenchTool([string]$Tool,$Arguments,[string]$Name){
    $script:calls.Add($Tool+':'+$Name)
    if($Tool -ceq 'intent_send'){
        $route=$Name.Substring('route-'.Length)
        return $script:fixture.Routes[$route]
    }
    if($Tool -ceq 'foreground_app'){return [pscustomobject]@{ok=$true;ctx=[pscustomobject]@{app='dev.magina.testtarget';foreground_known=$true}}}
    throw 'unexpected_tool_in_r5_probe'
}
function Assert-BenchToolOk($Envelope){Assert-Bench ($Envelope.ok -ceq $true) 'tool_failed'}
function Assert-BenchForeground([string]$Name){$fg=Invoke-BenchTool 'foreground_app' @{} $Name; Assert-Bench ($fg.ctx.app -ceq 'dev.magina.testtarget' -and $fg.ctx.foreground_known) 'wrong_foreground'}
Check 'production branch performs exactly three routes, no snapshot or action' {
    $R5ObservationOnly=$true; $summary=@{routes_verified=@()}; $script:r5Routes=[ordered]@{}
    $script:fixture=New-Fixture; $script:calls=[Collections.Generic.List[string]]::new()
    . $routeBody
    $expected=@('r5-process-before','intent_send:route-list','foreground_app:route-list-foreground','intent_send:route-search','foreground_app:route-search-foreground','intent_send:route-conversation','foreground_app:route-conversation-foreground','r5-process-after')
    if(($script:calls -join '|') -cne ($expected -join '|')){throw 'Production route I/O differs'}
    if(($summary.routes_verified -join ',') -cne 'list,search,conversation'){throw 'Routes not recorded'}
    Assert-BenchR5Observations $script:fixture.Audit $script:r5Routes 1234
}
# Exercise the real CLI conflict gate; impossible paths ensure no SDK can be used.
Check 'conflicting modes fail before any native tool' {
    $scratch=Join-Path $repoRoot ('.checks/local-testbench-r5-offline-'+[guid]::NewGuid().ToString('N'))
    $missing=Join-Path $scratch 'absent'
    $arguments=@('-NoProfile','-File',$driver,'-SdkRoot',$missing,'-AvdManagerPath',$missing,'-JavaHome',$missing,'-ApkSignerPath',$missing,'-GatewayApk',$missing,'-TargetApk',$missing,'-ExpectedSourceSha',('a'*40),'-ExpectedGatewaySha256',('b'*64),'-ExpectedTargetSha256',('c'*64),'-OutputDirectory',$scratch,'-Run','-ImeProbe','-R5ObservationOnly')
    & (Get-Process -Id $PID).Path @arguments | Out-Null
    if($LASTEXITCODE -ne 1){throw 'Conflict did not exit 1'}
    $receipt=Get-Content -LiteralPath (Join-Path $scratch 'summary.json') -Raw|ConvertFrom-Json
    if($receipt.failure_reason -cne 'r5_observation_and_ime_probe_conflict' -or
        $receipt.verification_scope -cne 'r5_observation_only' -or $receipt.runtime_acceptance -cne $false -or
        $receipt.r5_observation_verified -cne $false -or @(Get-ChildItem -LiteralPath $scratch -Filter '*.stdout.txt').Count -ne 0){throw 'Conflict receipt invalid'}
}
Write-Host "local-testbench-r5-offline: $script:passed passed; no SDK/ADB/runtime executed"
