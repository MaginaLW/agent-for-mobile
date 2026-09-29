#Requires -Version 7.6
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedBindingSha256)
# Executes only hash-pinned initializers, eight read-only startup statements and
# native definitions extracted from the observer. Never invokes its entrypoint.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$auditObserver='__ENTRY_ROOT__\observe-next-device-launch-r1.ps1'
$auditObserverHash='__SOURCE_OBSERVE_NEXT_DEVICE_LAUNCH_R1_HASH__'
$auditOutput='__REPO_ROOT__\.checks\c1b-host-readiness\__CANDIDATE_SHORT__\device-r1-preflight.json'
$auditSourceStream=$null;$auditSelfHandle=[IntPtr]::Zero;$auditOutputStream=$null
$auditFailure=$null;$auditCleanup=[Collections.Generic.List[string]]::new();$auditChecks=0
$auditInitialized=$false;$auditPrefixCompleted=$false;$auditNativeReady=$false
$auditFileCount=0;$auditDirectoryCount=0;$auditSelfIdentity=$null;$auditActiveExitRejected=$false
function Assert-Audit([bool]$Condition,[string]$Reason){$script:auditChecks++;if(-not$Condition){throw $Reason}}
try{
    Assert-Audit (-not(Test-Path -LiteralPath $auditOutput)) 'Preflight output already exists; no overwrite.'
    $auditSourceStream=[IO.File]::Open($auditObserver,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    Assert-Audit ($auditSourceStream.Length-eq'__SOURCE_OBSERVE_NEXT_DEVICE_LAUNCH_R1_LENGTH__') 'Observer length differs.'
    $auditBytes=[byte[]]::new([int]$auditSourceStream.Length);$auditSourceStream.ReadExactly($auditBytes)
    Assert-Audit ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($auditBytes)).ToLowerInvariant()-ceq$auditObserverHash) 'Observer hash differs.'
    $auditText=[Text.UTF8Encoding]::new($false,$true).GetString($auditBytes)
    $auditTokens=$null;$auditParseErrors=$null
    $auditAst=[Management.Automation.Language.Parser]::ParseInput($auditText,[ref]$auditTokens,[ref]$auditParseErrors)
    Assert-Audit ($auditParseErrors.Count-eq0) 'Observer Parser errors.'
    $auditStatements=@($auditAst.EndBlock.Statements)
    $auditTryIndex=-1
    for($auditI=0;$auditI-lt$auditStatements.Count;$auditI++){
        if($auditStatements[$auditI]-is[Management.Automation.Language.TryStatementAst]){$auditTryIndex=$auditI;break}
    }
    Assert-Audit ($auditTryIndex-gt0) 'Primary observer try is missing.'
    $auditInitializers=@($auditStatements[0..($auditTryIndex-1)])
    foreach($auditStatement in $auditInitializers){
        Assert-Audit ($auditStatement-is[Management.Automation.Language.AssignmentStatementAst]-or$auditStatement-is[Management.Automation.Language.FunctionDefinitionAst]-or
            ($auditStatement-is[Management.Automation.Language.PipelineAst]-and$auditStatement.Extent.Text-ceq'Set-StrictMode -Version Latest')) 'Unexpected top-level initializer.'
    }
    $auditBody=@($auditStatements[$auditTryIndex].Body.Statements)
    Assert-Audit ($auditBody[8]-is[Management.Automation.Language.AssignmentStatementAst]-and
        $auditBody[8].Extent.Text-ceq'$observationFile=[IO.File]::Open($observationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)') 'CreateNew boundary differs.'
    $auditPrefix=@($auditBody[0..7])
    Assert-Audit ($auditPrefix[7]-is[Management.Automation.Language.ForEachStatementAst]) 'Artifact absence guard is missing.'
    $auditStartupSource=($auditInitializers.Extent.Text-join"`n")+"`n"+($auditPrefix.Extent.Text-join"`n")
    $auditStartupAst=[Management.Automation.Language.Parser]::ParseInput($auditStartupSource,[ref]$auditTokens,[ref]$auditParseErrors)
    Assert-Audit ($auditParseErrors.Count-eq0) 'Extracted startup Parser errors.'
    $auditForbidden=@($auditStartupAst.FindAll({param($node)
        ($node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-in@('Start-Process','Get-CimInstance','Invoke-Expression','git','adb','gradle'))-or
        ($node-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$node.Member.Value-eq'Start')-or
        ($node-is[Management.Automation.Language.MemberExpressionAst]-and$node.Member.Value-eq'CreateNew')
    },$true))
    Assert-Audit ($auditForbidden.Count-eq0) 'Extracted startup contains a launch or reservation operation.'
    # Set first so a partially evaluated initializer still reaches guarded cleanup.
    $auditInitialized=$true
    . ([scriptblock]::Create($auditStartupSource))
    $auditPrefixCompleted=$true
    Assert-Audit ($record.wrapper_launch_call_count-eq0-and-not$record.wrapper_started-and$null-eq$outer-and$null-eq$observationFile) 'Startup crossed its read-only boundary.'
    Assert-Audit ($record.binding_sha256-ceq$ExpectedBindingSha256) 'Startup did not bind the externally pinned binding.'
    Assert-Audit ($heldFiles.Count-eq3) 'Expected runtime, wrapper and binding file guards.'
    Recheck-FileGuards
    # Compile the exact native declaration, not the observer's reservation/launch.
    $auditAddType=@($auditBody[9].FindAll({param($node)$node-is[Management.Automation.Language.CommandAst]-and$node.GetCommandName()-ceq'Add-Type'},$true))
    Assert-Audit ($auditAddType.Count-eq1) 'Native declaration extraction differs.'
    . ([scriptblock]::Create($auditBody[9].Extent.Text))
    foreach($auditName in @('Native-Error','Open-ObservedProcess','Read-ProcessIdentity','Wait-State','Read-EndedProcessExit')){
        $auditMatches=@($auditAst.FindAll({param($node)$node-is[Management.Automation.Language.FunctionDefinitionAst]-and$node.Name-ceq$auditName},$true))
        Assert-Audit ($auditMatches.Count-eq1) 'Native function extraction is not unique.'
        . ([scriptblock]::Create($auditMatches[0].Extent.Text))
    }
    $auditNativeReady=$true
    $auditSelfHandle=Open-ObservedProcess $PID
    $auditSelfIdentity=Read-ProcessIdentity $auditSelfHandle
    Assert-Audit ($auditSelfIdentity.ProcessId-eq$PID) 'Native self PID differs.'
    Assert-Audit ((Wait-State $auditSelfHandle)-eq258) 'Self process is not active.'
    try{[void](Read-EndedProcessExit $auditSelfHandle)}catch{
        $auditActiveExitRejected=$_.Exception.Message-ceq'Exit requested before actual process termination.'
    }
    Assert-Audit $auditActiveExitRejected 'Active self was accepted as an ended process.'
    Assert-Audit ($auditSelfIdentity.CreatedUtc-le[DateTime]::UtcNow) 'Native creation time is invalid.'
    foreach($auditLeaf in @('external-process-observation.json','reservation.json','exit.json','runner.stdout.bin','runner.stderr.bin','observer.stdout.log','observer.stderr.log')){
        Assert-Audit (-not(Test-Path -LiteralPath (Join-Path $receiptRoot $auditLeaf))) 'A formal execution artifact exists.'
    }
    Assert-Audit (@(Get-ChildItem -LiteralPath $receiptRoot -Force).Count-eq1) 'Device directory must contain only binding.json.'
    Recheck-FileGuards
    $auditFileCount=$heldFiles.Count;$auditDirectoryCount=$heldDirectories.Count
}catch{$auditFailure=$_.Exception.Message}
finally{
    if($auditSelfHandle-ne[IntPtr]::Zero){
        if(-not[C1bExternalProcessObserverV1]::CloseHandle($auditSelfHandle)){$auditCleanup.Add('Native self handle close failed.')}
    }
    if($auditInitialized){
        if(Get-Variable -Name heldFiles -ErrorAction SilentlyContinue){
            foreach($auditFile in $heldFiles){
                try{if($null-ne$auditFile.Stream){$auditFile.Stream.Dispose()}else{$auditFile.Handle.Dispose()}
                    if(-not$auditFile.Handle.IsClosed){$auditCleanup.Add('Source file handle remains open.')}}catch{$auditCleanup.Add($_.Exception.Message)}
            }
        }
        if(Get-Variable -Name heldDirectories -ErrorAction SilentlyContinue){
            foreach($auditDir in $heldDirectories.Values){
                try{$auditDir.Handle.Dispose();if(-not$auditDir.Handle.IsClosed){$auditCleanup.Add('Ancestor handle remains open.')}}catch{$auditCleanup.Add($_.Exception.Message)}
            }
        }
    }
    if($null-ne$auditSourceStream){$auditSourceStream.Dispose()}
}
$auditPassed=$null-eq$auditFailure-and$auditCleanup.Count-eq0-and$auditPrefixCompleted-and$auditNativeReady
$auditResult=[ordered]@{
    schema='c1b-observer-pre-device-preflight/v1';status=$(if($auditPassed){'prepared_for_device_stage'}else{'failed'})
    expected_commit_sha='__CANDIDATE_SHA__';observer_sha256=$auditObserverHash;binding_sha256=$ExpectedBindingSha256
    assertion_count=$auditChecks;source_prefix_statement_count=8;source_prefix_completed=$auditPrefixCompleted
    native_definitions_compiled=$auditNativeReady;native_probe_scope='current preflight process only';active_process_exit_rejected=$auditActiveExitRejected
    guarded_file_count=$auditFileCount;guarded_directory_count=$auditDirectoryCount
    error=$auditFailure;cleanup_error_count=$auditCleanup.Count;cleanup_errors=$auditCleanup.ToArray()
    observer_top_level_invocations=0;wrapper_launches=0;child_process_launches=0;uac_requests=0;adb_or_device_commands=0;formal_stage_invocations=0
    formal_reservation_created=$false;device_evidence_verified=$false;external_preflight_exit_zero_required=$true
    scope='Exact startup prefix and self-only native API verification; UAC, runner, device and terminal evidence remain untested.'
    recorded_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
}
$auditResultBytes=[Text.UTF8Encoding]::new($false).GetBytes(($auditResult|ConvertTo-Json -Depth 8 -Compress))
$auditOutputStream=[IO.File]::Open($auditOutput,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$auditOutputStream.Write($auditResultBytes);$auditOutputStream.Flush($true)
    [IO.File]::SetAttributes($auditOutput,([IO.File]::GetAttributes($auditOutput)-bor[IO.FileAttributes]::ReadOnly))}finally{$auditOutputStream.Dispose()}
$auditResult|ConvertTo-Json -Depth 8 -Compress
if(-not$auditPassed){exit 1};exit 0
