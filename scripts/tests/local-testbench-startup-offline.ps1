#Requires -Version 7.5
[CmdletBinding()]
param([switch]$BaselineProof)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$driver=Join-Path $repoRoot 'scripts/run-local-testbench.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($driver,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Driver parse failed'}
foreach($name in @('Assert-Bench','Assert-BenchRemaining','Save-BenchProcess','Invoke-BenchNative','Assert-BenchOwnedServer','Invoke-BenchAdb')){
    $nodes=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if($nodes.Count -ne 1){throw "Missing function: $name"}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$main=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
if($main.Count -ne 1){throw 'Main try missing or ambiguous'}
$statements=@($main[0].Body.Statements)
$start=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text.Contains("'initialize-owned-gateway'")})
$end=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text.Contains("'touch-exploration-setting'")})
if($start.Count -ne 1 -or $end.Count -ne 1 -or $end[0] -le $start[0]){throw 'Startup boundary missing or ambiguous'}
$startupBody=[scriptblock]::Create(($statements[$start[0]..($end[0]-1)].Extent.Text -join "`n"))
$forwardCleanup=@($main[0].Finally.Statements|Where-Object {$_.Extent.Text.Contains("'remove-owned-forward'")})
if($forwardCleanup.Count -ne 1){throw 'Forward cleanup missing or ambiguous'}
$forwardCleanupBody=[scriptblock]::Create($forwardCleanup[0].Extent.Text)
$script:root=Join-Path $repoRoot ('.checks/human-allow-20261113/startup-fixtures-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:root -Force|Out-Null
$script:passed=0; $script:caseIndex=0
function Check([string]$Name,[scriptblock]$Body){& $Body; $script:passed++; Write-Host "PASS $Name"}
function Get-BenchPortListeners([int[]]$Ports){return [pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=5039;OwningProcess=123}}
# Native process and HTTP I/O only are replaced. Production timeout, redaction, ownership and cleanup code runs.
function Start-BenchProcess([string]$File,[string[]]$Arguments,[string]$InputText=''){
    if($File -cne 'fixture-adb' -or ($Arguments[0..5] -join '|') -cne '-H|127.0.0.1|-P|5039|-s|emulator-5580'){throw 'Unexpected native target'}
    $command=$Arguments[6..($Arguments.Count-1)] -join ' '
    $exitCode=0; $stdout=''; $stderr=''
    switch -Regex ($command){
        '^shell am start -n dev\.magina\.gateway/\.MainActivity$' {$operation='activity-start';$stdout='Starting: fixture Activity';break}
        '^shell run-as dev\.magina\.gateway am start-foreground-service ' {$operation='service-start';$stdout='Starting service: fixture Service';break}
        '^shell run-as dev\.magina\.gateway cat shared_prefs/gateway\.xml$' {
            $operation='credential';$script:fixture.Reads++
            if(-not $script:fixture.Ready -or $script:fixture.ReadFailure){
                $exitCode=7;$stdout=$script:fixture.FakeToken;$stderr='synthetic private detail '+$script:fixture.FakeToken
            }else{$stdout='<map><string name="token">'+$script:fixture.FakeToken+'</string></map>'}
            break
        }
        '^forward --no-rebind tcp:18848 tcp:8848$' {$operation='forward';break}
        '^forward --remove tcp:18848$' {$operation='remove-forward';$script:fixture.Removals++;break}
        default {throw 'Unexpected native command'}
    }
    $script:fixture.Calls.Add($operation)
    $process=[pscustomobject]@{Id=123;HasExited=$false;ExitCode=$exitCode;Operation=$operation}
    $process|Add-Member ScriptMethod WaitForExit {
        param([int]$Milliseconds)
        $script:fixture.Waits.Add([pscustomobject]@{Operation=$this.Operation;Milliseconds=$Milliseconds})
        return $true
    }
    $process|Add-Member ScriptMethod Dispose {$script:fixture.Disposals++}
    return [pscustomobject]@{Process=$process;Stdout=[Threading.Tasks.Task]::FromResult[string]($stdout);Stderr=[Threading.Tasks.Task]::FromResult[string]($stderr)}
}
function Invoke-WebRequest([string]$Uri,[int]$TimeoutSec){
    if($Uri -cne 'http://127.0.0.1:18848/health' -or $TimeoutSec -ne 2){throw 'Unexpected health request'}
    $script:fixture.HealthRequests++;$script:fixture.Calls.Add('health')
    if($script:fixture.HealthNever -or $script:fixture.HealthRequests -lt $script:fixture.ReadyAfter){throw 'synthetic health not ready'}
    if($script:fixture.HealthBody.Trim() -ceq 'ok'){$script:fixture.Ready=$true}
    return [pscustomobject]@{Content=$script:fixture.HealthBody}
}
function Start-Sleep([int]$Seconds){
    if($Seconds -ne 1){throw 'Health interval changed'}
    $script:fixture.Sleeps++
}
function Invoke-StartupFixture([hashtable]$Options=@{}){
    $script:caseIndex++
    $script:output=Join-Path $script:root ('case-'+$script:caseIndex)
    New-Item -ItemType Directory -Path $script:output -Force|Out-Null
    $script:encoding=[Text.UTF8Encoding]::new($false,$true)
    $script:RuntimeSeconds=900; $script:clock=[Diagnostics.Stopwatch]::StartNew()
    $script:commandIndex=0; $script:adb='fixture-adb'
    $script:server=[pscustomobject]@{Process=[pscustomobject]@{Id=123;HasExited=$false}}
    $script:AdbServerPort=5039; $script:HttpPort=18848
    $script:summary=@{serial='emulator-5580'}
    $script:fixture=@{Ready=$false;ReadyAfter=1;HealthNever=$false;HealthBody='ok';ReadFailure=$false;Reads=0;HealthRequests=0;Sleeps=0;Removals=0;Disposals=0;FakeToken=('d'*32);Calls=[Collections.Generic.List[string]]::new();Waits=[Collections.Generic.List[object]]::new()}
    foreach($key in $Options.Keys){if($key -ceq 'RuntimeSeconds'){$script:RuntimeSeconds=$Options[$key]}else{$script:fixture[$key]=$Options[$key]}}
    $forwardAdded=$false; $client=$null; $token=$null; $failure=$null; $tokenRead=$false; $forwardBeforeCleanup=$false
    try{
        . $startupBody
        $tokenRead=$token -ceq $script:fixture.FakeToken
    }catch{$failure=$_.Exception.Message}finally{
        $forwardBeforeCleanup=$forwardAdded
        $token=$null;$prefs=$null;$prefsXml=$null
        if($null -ne $client){$client.Dispose()}
        . $forwardCleanupBody
    }
    $credentialFiles=@(Get-ChildItem -LiteralPath $script:output -File|Where-Object Name -Match 'credential')
    $leaked=$failure -like ('*'+$script:fixture.FakeToken+'*')
    foreach($file in Get-ChildItem -LiteralPath $script:output -File){if([IO.File]::ReadAllText($file.FullName).Contains($script:fixture.FakeToken)){$leaked=$true}}
    return [pscustomobject]@{Failure=$failure;Reads=$script:fixture.Reads;HealthRequests=$script:fixture.HealthRequests;Sleeps=$script:fixture.Sleeps;Removals=$script:fixture.Removals;ForwardBeforeCleanup=$forwardBeforeCleanup;TokenRead=$tokenRead;Calls=@($script:fixture.Calls);Waits=@($script:fixture.Waits);CredentialFiles=$credentialFiles.Count;SensitiveLeak=$leaked}
}
if($BaselineProof){
    $result=Invoke-StartupFixture @{ReadyAfter=2}
    if($result.Failure -cne 'native_exit_owned-credential-in-memory' -or $result.Reads -ne 1 -or $result.HealthRequests -ne 0 -or
        $result.ForwardBeforeCleanup -or $result.SensitiveLeak){throw 'Old premature read not reproduced'}
    $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $repoRoot '.checks/human-allow-20261113/startup-old-order-proof.json') -Encoding utf8
    Write-Host 'BASELINE_PROOF old startup reads once before any health readiness; synthetic failure preserved, no SDK/ADB/network'
    exit 0
}
Check 'health readiness precedes exactly one sensitive read and owned forward cleanup' {
    $r=Invoke-StartupFixture
    if($null -ne $r.Failure -or $r.Reads -ne 1 -or $r.HealthRequests -ne 1 -or -not $r.TokenRead -or
        -not $r.ForwardBeforeCleanup -or $r.Removals -ne 1 -or $r.SensitiveLeak -or $r.CredentialFiles -ne 0 -or
        ($r.Calls -join '|') -cne 'activity-start|service-start|forward|health|credential|remove-forward'){throw 'Startup ordering invalid'}
    $readWait=@($r.Waits|Where-Object Operation -CEQ 'credential')
    if($readWait.Count -ne 1 -or $readWait[0].Milliseconds -ne 20000){throw 'Sensitive read timeout changed'}
}
Check 'initial health failure uses original interval then reads only after positive health' {
    $r=Invoke-StartupFixture @{ReadyAfter=2}
    if($null -ne $r.Failure -or $r.HealthRequests -ne 2 -or $r.Sleeps -ne 1 -or $r.Reads -ne 1 -or
        ($r.Calls -join '|') -cne 'activity-start|service-start|forward|health|health|credential|remove-forward'){throw 'Read occurred before health readiness'}
}
Check 'unready health preserves 15 attempts and performs zero sensitive reads' {
    $r=Invoke-StartupFixture @{HealthNever=$true}
    if($r.Failure -cne 'gateway_http_not_ready' -or $r.HealthRequests -ne 15 -or $r.Sleeps -ne 15 -or
        $r.Reads -ne 0 -or -not $r.ForwardBeforeCleanup -or $r.Removals -ne 1 -or $r.SensitiveLeak){throw 'Unready health did not stop before credentials'}
}
Check 'original exact health body rejects uppercase without reading credentials' {
    $r=Invoke-StartupFixture @{HealthBody='OK'}
    if($r.Failure -cne 'gateway_http_not_ready' -or $r.HealthRequests -ne 15 -or $r.Reads -ne 0 -or $r.Removals -ne 1){throw 'Health body predicate weakened'}
}
Check 'read failure after ready is one attempt, redacted and still removes owned forward' {
    $r=Invoke-StartupFixture @{ReadFailure=$true}
    if($r.Failure -cne 'native_exit_owned-credential-in-memory' -or $r.HealthRequests -ne 1 -or $r.Reads -ne 1 -or
        $r.Removals -ne 1 -or $r.SensitiveLeak -or $r.CredentialFiles -ne 0){throw 'Read failure leaked or retried'}
}
Check 'original remaining-budget reserve stops before health and sensitive read' {
    $r=Invoke-StartupFixture @{RuntimeSeconds=149}
    if($r.Failure -cne 'runtime_budget_exhausted' -or $r.HealthRequests -ne 0 -or $r.Reads -ne 0 -or
        -not $r.ForwardBeforeCleanup -or $r.Removals -ne 1){throw 'Remaining budget or forward teardown changed'}
}
Write-Host "local-testbench-startup-offline: $script:passed passed; no SDK/ADB/network/runtime executed"
