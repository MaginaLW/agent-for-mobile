#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0;[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Text.UTF8Encoding]::new($false)
$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'));$Pwsh=(Get-Process -Id $PID).Path
$C1a=Join-Path $SourceRoot 'scripts\lib\tablet-layout-c1a.ps1';$Validator=Join-Path $SourceRoot 'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1';$C1b=Join-Path $SourceRoot 'scripts\lib\tablet-layout-c1b.ps1'
. $C1a;. $Validator;. $C1b
function Check([bool]$Value,[string]$Message){if(-not$Value){throw $Message}}
function Get-E2eLineCount([string]$Path){if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return 0};return [IO.File]::ReadAllLines($Path,[Text.UTF8Encoding]::new($false,$true)).Count}
function Run-Git([string]$At,[string[]]$Arguments){$all=@('-C',$At)+$Arguments;$text=& git @all 2>&1;if($LASTEXITCODE-ne0){throw "git $($Arguments-join' ') failed: $text"};return $text}
function Assert-SyntheticGitHeadClean([string]$At){
    $lastRefresh='';$lastStatus=''
    for($attempt=0;$attempt-lt10;$attempt++){
        $refresh=& git -C $At update-index --really-refresh 2>&1
        $refreshExit=$LASTEXITCODE
        $status=& git -C $At status --porcelain=v1 --untracked-files=all 2>&1
        $statusExit=$LASTEXITCODE
        $lastRefresh=[string]($refresh-join"`n");$lastStatus=[string]($status-join"`n")
        if($refreshExit-eq0-and$statusExit-eq0-and[string]::IsNullOrWhiteSpace($lastStatus)){return}
        Start-Sleep -Milliseconds 50
    }
    throw "synthetic C1b committed checkout did not stabilize clean: refresh=$lastRefresh status=$lastStatus"
}
function Get-IndependentSha256([byte[]]$Bytes){$hasher=[Security.Cryptography.SHA256]::Create();try{return 'sha256:'+([Convert]::ToHexString($hasher.ComputeHash($Bytes))).ToLowerInvariant()}finally{$hasher.Dispose()}}
function Get-IndependentFileSha256([string]$Path){$bytes=[IO.File]::ReadAllBytes($Path);try{return Get-IndependentSha256 $bytes}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}}
function Get-IndependentTextSha256([string]$Value){$bytes=[Text.UTF8Encoding]::new($false).GetBytes($Value);try{return Get-IndependentSha256 $bytes}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}}
function Read-AdbExecutableEvidence([string]$Path){
    $lines=[IO.File]::ReadAllLines($Path,[Text.UTF8Encoding]::new($false));$evidence=[Collections.Generic.List[object]]::new()
    foreach($line in $lines){
        [string[]]$fields=$line.Split([char]0x1f);Check ($fields.Count-eq2-and[IO.Path]::IsPathFullyQualified($fields[0])-and$fields[1]-cmatch'^sha256:[0-9a-f]{64}$') 'fake adb executable evidence drift'
        $evidence.Add([pscustomobject][ordered]@{Path=[IO.Path]::GetFullPath($fields[0]);Sha256=$fields[1]})
    }
    return $evidence.ToArray()
}
function Read-PrivateAdbPortLog([string]$State,[string]$Name){
    $path=Join-Path $State $Name;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [int[]]@()}
    $ports=[Collections.Generic.List[int]]::new();foreach($line in [IO.File]::ReadAllLines($path,[Text.UTF8Encoding]::new($false,$true))){$port=0;Check ([int]::TryParse($line,[ref]$port)-and$port -in 49152..65535) "private adb port log drift: $Name";$ports.Add($port)};return [int[]]$ports.ToArray()
}
function Get-PrivateAdbServerSnapshot([string]$State){
    return [pscustomobject][ordered]@{Start=[int[]]@(Read-PrivateAdbPortLog $State 'adb-server-start.log');Status=[int[]]@(Read-PrivateAdbPortLog $State 'adb-server-status.log');Kill=[int[]]@(Read-PrivateAdbPortLog $State 'adb-server-kill.log');Exit=[int[]]@(Read-PrivateAdbPortLog $State 'adb-server-exit.log')}
}
function Test-PrivateAdbPortReusable([int]$Port){
    $socket=[Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork,[Net.Sockets.SocketType]::Stream,[Net.Sockets.ProtocolType]::Tcp)
    try{$socket.ExclusiveAddressUse=$true;$socket.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket,[Net.Sockets.SocketOptionName]::ReuseAddress,$false);$socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,$Port));$socket.Listen(1);return $true}catch [Net.Sockets.SocketException]{return $false}finally{$socket.Dispose()}
}
function Read-PrivateAdbEvidenceLog([string]$State,[string]$Name){
    $path=Join-Path $State $Name;if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return [string[]]@()}
    return [string[]][IO.File]::ReadAllLines($path,[Text.UTF8Encoding]::new($false,$true))
}
function Get-PrivateAdbAutoStartSnapshot([string]$State){
    return [pscustomobject][ordered]@{
        ServerPid=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-server-pid.log')
        ServerExitPid=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-server-exit-pid.log')
        Attempt=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-auto-start-attempt.log')
        ChildEntry=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-auto-start-child-entry.log')
        Listener=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-auto-start-listener.log')
        CommandSideEffect=[string[]]@(Read-PrivateAdbEvidenceLog $State 'adb-auto-start-command-side-effect.log')
    }
}
function Assert-PrivateAdbAutoStartBlockedScenario([object]$BeforeServer,[object]$BeforeAutoStart,[string]$State,[string]$Scenario,[string]$Label){
    $afterServer=Get-PrivateAdbServerSnapshot $State;$afterAutoStart=Get-PrivateAdbAutoStartSnapshot $State
    Check ($afterServer.Start.Count-eq$BeforeServer.Start.Count+1-and$afterServer.Status.Count-eq$BeforeServer.Status.Count+1-and$afterServer.Exit.Count-eq$BeforeServer.Exit.Count+1) "$Label held private adb lifecycle count drift"
    Check ($afterServer.Kill.Count-eq$BeforeServer.Kill.Count) "$Label unexpectedly reached a replacement/private kill-server client"
    Check ($afterAutoStart.ServerPid.Count-eq$BeforeAutoStart.ServerPid.Count+1-and$afterAutoStart.ServerExitPid.Count-eq$BeforeAutoStart.ServerExitPid.Count+1) "$Label held private adb PID lifecycle count drift"
    Check ($afterAutoStart.Attempt.Count-eq$BeforeAutoStart.Attempt.Count+1) "$Label official auto-start attempt was not reached"
    foreach($name in @('ChildEntry','Listener','CommandSideEffect')){Check ($afterAutoStart.$name.Count-eq$BeforeAutoStart.$name.Count) "$Label escaped auto-start $name evidence"}
    $separator=[char]0x1f;[string[]]$attemptFields=$afterAutoStart.Attempt[-1].Split($separator);Check ($attemptFields.Count-eq3-and$attemptFields[0]-ceq$Scenario) "$Label official auto-start attempt tuple drift";$attemptPort=0;$attemptPid=0;Check ([int]::TryParse($attemptFields[1],[ref]$attemptPort)-and[int]::TryParse($attemptFields[2],[ref]$attemptPid)-and$attemptPid-gt0) "$Label official auto-start attempt numeric tuple drift"
    [string[]]$serverFields=$afterAutoStart.ServerPid[-1].Split($separator);[string[]]$exitFields=$afterAutoStart.ServerExitPid[-1].Split($separator);$serverPort=0;$serverPid=0;$exitPort=0;$exitPid=0
    Check ($serverFields.Count-eq2-and$exitFields.Count-eq2-and[int]::TryParse($serverFields[0],[ref]$serverPort)-and[int]::TryParse($serverFields[1],[ref]$serverPid)-and[int]::TryParse($exitFields[0],[ref]$exitPort)-and[int]::TryParse($exitFields[1],[ref]$exitPid)) "$Label held private adb PID tuple drift"
    Check ($attemptPort-eq$serverPort-and$exitPort-eq$serverPort-and$exitPid-eq$serverPid-and$afterServer.Start[-1]-eq$serverPort-and$afterServer.Status[-1]-eq$serverPort-and$afterServer.Exit[-1]-eq$serverPort) "$Label held private adb endpoint/PID lifecycle mismatch"
    Check ($null-eq(Get-Process -Id $serverPid -ErrorAction SilentlyContinue)) "$Label held private adb process survived"
    Check ($null-eq(Get-Process -Id $attemptPid -ErrorAction SilentlyContinue)) "$Label official auto-starting client process survived"
    Check (Test-PrivateAdbPortReusable $serverPort) "$Label escaped listener retained the private endpoint"
    Check (-not(Test-Path -LiteralPath (Join-Path $State "adb-server-stop-$serverPort.txt"))) "$Label held-server stop marker survived cleanup"
    return [pscustomobject][ordered]@{Server=$afterServer;AutoStart=$afterAutoStart;Port=$serverPort;HeldServerPid=$serverPid;AttemptClientPid=$attemptPid}
}
function Assert-PrivateAdbServerScenario([object]$Before,[string]$State,[string]$Label){
    $after=Get-PrivateAdbServerSnapshot $State
    foreach($name in @('Start','Status','Kill','Exit')){Check ($after.$name.Count-eq$Before.$name.Count+1) "$Label private adb $name count drift"}
    $port=[int]$after.Start[-1];Check ($port -in 49152..65535-and$after.Status[-1]-eq$port-and$after.Kill[-1]-eq$port-and$after.Exit[-1]-eq$port) "$Label private adb lifecycle port mismatch";Check (Test-PrivateAdbPortReusable $port) "$Label private adb port was not reusable";Check (-not(Test-Path -LiteralPath (Join-Path $State "adb-server-stop-$port.txt"))) "$Label private adb stop marker survived cleanup";return $after
}
function Assert-PrivateAdbTransportLog([string]$State,[int]$ExpectedServerCount){
    $separator=[char]0x1f;$adbLines=[IO.File]::ReadAllLines((Join-Path $State 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$transportLines=[IO.File]::ReadAllLines((Join-Path $State 'adb-transport.log'),[Text.UTF8Encoding]::new($false,$true));Check ($transportLines.Count-eq$adbLines.Count) 'private adb normalized/transport log count drift';$serverCount=0;$statusCount=0;$killCount=0;$deviceCount=0;$t0Count=0
    for($lineIndex=0;$lineIndex-lt$transportLines.Count;$lineIndex++){
        [string[]]$fields=$transportLines[$lineIndex].Split($separator);Check ($fields.Count-ge2-and$fields[0]-cmatch'^tcp:127\.0\.0\.1:([0-9]{5})$') 'private adb transport socket grammar drift';$port=[int]$Matches[1];Check ($port -in 49152..65535) 'private adb transport used non-high port';[string[]]$raw=$fields[1..($fields.Count-1)]
        if($raw[0]-ceq'-L'){$serverCount++;Check ($raw.Count-eq4-and$raw[1]-ceq("tcp:localhost:$port")-and$raw[2]-ceq'server'-and$raw[3]-ceq'nodaemon') 'private adb server argv drift';Check (($raw-join$separator)-ceq$adbLines[$lineIndex]) 'private adb server normalized log drift';continue}
        Check ($raw.Count-ge5-and$raw[0]-ceq'-H'-and$raw[1]-ceq'127.0.0.1'-and$raw[2]-ceq'-P'-and$raw[3]-ceq([string]$port)-and$fields[0]-ceq("tcp:127.0.0.1:$port")) 'private adb client endpoint prefix/env drift';[string[]]$command=$raw[4..($raw.Count-1)];Check (($command-join$separator)-ceq$adbLines[$lineIndex]) 'private adb client normalized log drift';if($command.Count-eq1-and$command[0]-ceq'server-status'){$statusCount++}elseif($command.Count-eq1-and$command[0]-ceq'kill-server'){$killCount++}else{Check (($command.Count-eq1-and$command[0]-ceq'devices')-or($command.Count-ge3-and$command[0]-ceq'-s'-and$command[1]-ceq'FAKE123')) 'private adb unexpected client command';$deviceCount++;if($command.Count-eq7-and$command[0]-ceq'-s'-and$command[1]-ceq'FAKE123'-and$command[2]-ceq'exec-in'-and$command[3]-ceq'content'-and$command[4]-ceq'write'-and$command[5]-ceq'--uri'){$t0Count++}}
    }
    Check ($serverCount-eq$ExpectedServerCount-and$statusCount-eq$ExpectedServerCount-and$killCount-eq$ExpectedServerCount-and$deviceCount-gt0-and$t0Count-eq$ExpectedServerCount) 'private adb lifecycle/device/T0 transport counts drift';Check (@($transportLines|Where-Object{$_-cmatch'(^|\x1f)(?:tcp:127\.0\.0\.1:)?5037(?:\x1f|$)'}).Count-eq0) 'private adb transport touched default 5037';return [pscustomobject][ordered]@{Total=$transportLines.Count;Server=$serverCount;Status=$statusCount;Kill=$killCount;Device=$deviceCount;T0=$t0Count}
}
function Assert-IndependentRepositoryCatalog([string]$RepoRoot,[string]$CatalogPath,[int]$ExpectedCount){
    $bytes=[IO.File]::ReadAllBytes($CatalogPath)
    try{
        Check ($bytes.Length-gt0-and-not($bytes.Length-ge3-and$bytes[0]-eq0xef-and$bytes[1]-eq0xbb-and$bytes[2]-eq0xbf)) 'build-environment catalog BOM/empty drift'
        $raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);Check (-not$raw.Contains("`r")-and-not$raw.EndsWith("`n",[StringComparison]::Ordinal)) 'build-environment catalog newline drift'
        $lines=[string[]]@($raw-split"`n");Check ($lines.Count-eq$ExpectedCount) 'build-environment catalog count drift';$previous=$null;$root=[IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)+'\'
        foreach($line in $lines){$match=[regex]::Match($line,'^([^=]+)=(sha256:[0-9a-f]{64})$');Check $match.Success 'build-environment catalog line drift';$relative=$match.Groups[1].Value
            if($null-ne$previous){Check ([StringComparer]::Ordinal.Compare($previous,$relative)-lt0) 'build-environment catalog ordinal/duplicate drift'};$previous=$relative
            $path=[IO.Path]::GetFullPath((Join-Path $RepoRoot ($relative.Replace('/','\'))));Check ($path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)-and(Test-Path -LiteralPath $path -PathType Leaf)) 'build-environment catalog path escape/missing';Check ((Get-IndependentFileSha256 $path)-ceq$match.Groups[2].Value) "build-environment catalog file hash drift: $relative"
        }
        return Get-IndependentTextSha256 $raw
    }finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function Get-IndependentApkProof([string]$Path){
    $archive=[IO.Compression.ZipFile]::OpenRead($Path)
    try{
        $manifestEntries=@($archive.Entries|Where-Object FullName -ceq 'AndroidManifest.xml');Check ($manifestEntries.Count-eq1) 'APK manifest entry count'
        $manifestStream=$manifestEntries[0].Open();try{$manifestSha='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestStream))).ToLowerInvariant()}finally{$manifestStream.Dispose()}
        $dexEntries=@($archive.Entries|Where-Object FullName -match '^classes(?:[2-9]|[1-9][0-9]+)?\.dex$'|Sort-Object @{Expression={if($_.FullName-ceq'classes.dex'){1}else{[int]([regex]::Match($_.FullName,'^classes([0-9]+)\.dex$').Groups[1].Value)}}})
        $proof=[Collections.Generic.List[object]]::new();$catalog=[Collections.Generic.List[string]]::new()
        for($index=1;$index-le$dexEntries.Count;$index++){Check ($dexEntries[$index-1].FullName-ceq$(if($index-eq1){'classes.dex'}else{"classes$index.dex"})) 'APK DEX sequence';$stream=$dexEntries[$index-1].Open();try{$sha='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))).ToLowerInvariant()}finally{$stream.Dispose()};$proof.Add([pscustomobject]@{relative_path=$dexEntries[$index-1].FullName;sha256=$sha});$catalog.Add("$($dexEntries[$index-1].FullName)=$sha")}
        return [pscustomobject]@{packaged_manifest_sha256=$manifestSha;dex_entries=$proof.ToArray();dex_catalog_sha256=Get-IndependentTextSha256 ($catalog-join"`n")}
    }finally{$archive.Dispose()}
}
function Read-FailureEvidenceStrict([string]$Path){
    $bytes=[IO.File]::ReadAllBytes($Path)
    try{$raw=ConvertFrom-TL1C1aStrictUtf8 $bytes 'C1b E2E failure evidence';$value=ConvertFrom-TL1C1bClosedJson $raw}
    finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
    Assert-TL1C1bExactObjectKeys $value @('schema','run_id','status','reason_code','cleanup','runtime_origin_verified','runtime_evidence','layout_accepted','wechat_layout_verified','editor_action_ready','p0_capability','execution_grant') 'failure evidence'
    Check ($value.schema-ceq'tablet-layout-c1b-failure/v1') 'failure evidence schema drift'
    return $value
}
function Read-AttemptFailureEvidenceStrict([string]$Path,[string]$SchemaPath){
    $bytes=[IO.File]::ReadAllBytes($Path)
    try{
        Check ($bytes.Length-in 1..65536) 'attempt failure evidence byte count drift'
        $raw=ConvertFrom-TL1C1aStrictUtf8 $bytes 'C1b E2E attempt failure evidence'
        Check ($raw|Test-Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue) 'attempt failure evidence schema drift'
        $value=ConvertFrom-TL1C1bClosedJson $raw
    }finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
    Assert-TL1C1bExactObjectKeys $value @(
        'schema','attempt_id','run_id','status','reason_code','failure_stage',
        'expected_commit_sha','commit_verified','recorded_at_utc','runner_invocation_count',
        'automatic_runner_retry_count','pre_device_operations','private_adb_startup','cleanup',
        'runtime_origin_verified','runtime_evidence','layout_accepted','wechat_layout_verified',
        'editor_action_ready','p0_capability','execution_grant') 'attempt failure evidence'
    Check ($value.schema-ceq'tablet-layout-c1b-attempt-failure/v1') 'attempt failure evidence schema name drift'
    return [pscustomobject][ordered]@{Value=$value;Raw=$raw}
}
$runnerGitCommand=@(Get-Command git.exe -CommandType Application -All|Where-Object{$parent=Split-Path $_.Source -Parent;$leaf=Split-Path $parent -Leaf;$leaf-ceq'bin'-or($leaf-ceq'cmd'-and(Test-Path -LiteralPath (Join-Path (Split-Path $parent -Parent) 'bin\git.exe') -PathType Leaf))})|Select-Object -First 1;Check ($null-ne$runnerGitCommand) 'Git for Windows bin/cmd pair missing'
$root=Join-Path ([IO.Path]::GetTempPath()) ('tl1-c1b-e2e-'+[guid]::NewGuid().ToString('N'));$repo=Join-Path $root 'repo';$state=Join-Path $root 'state';$sdk=Join-Path $root 'sdk';$javaHome=Join-Path $root 'java-home';$gradleHome=Join-Path $root 'gradle-home';$localAppData=Join-Path $root 'localappdata';[void](New-Item -ItemType Directory -Path $root,$state,$javaHome,$gradleHome,$localAppData,(Join-Path $sdk 'build-tools\35.0.0'),(Join-Path $sdk 'platforms\android-35'),(Join-Path $sdk 'platform-tools'))
try{
    $clone=& git clone --shared --quiet $SourceRoot $repo 2>&1;if($LASTEXITCODE-ne0){throw "shared clone failed: $clone"}
    # The source checkout can contain the candidate only in its index/worktree while HEAD still
    # predates C1b.  Copy the runner's complete implementation closure into the synthetic repo so
    # the E2E tests the exact candidate rather than accidentally falling back to cloned HEAD.
    $overlay=@(
      'scripts/run-tablet-layout-c1b.ps1','scripts/run-tablet-intake.ps1',
      'scripts/lib/tablet-layout-c1a.ps1','scripts/lib/tablet-layout-c1b.ps1','scripts/lib/tablet-layout-c1b-readonly.ps1','scripts/lib/tablet-layout-c1b-artifact-proof.ps1','scripts/lib/tablet-layout-c1b-aapt2.ps1','scripts/lib/tablet-layout-c1b-build-env.ps1','scripts/lib/tablet-layout-c1b-adb-server.ps1','scripts/lib/dispatch-lock.ps1',
      'scripts/lib/tablet-layout-c1a-t0-adb-sidecar.cmd','scripts/lib/tablet-layout-c1a-t0-adb-sidecar.ps1','scripts/lib/tablet-intake.ps1',
      'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1','scripts/lib/tablet-layout-observation-v2-validator.ps1',
      'docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json','docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json','docs/contracts/tablet-c1b-read-only-artifact-proof-v1.schema.json',
      'docs/contracts/tablet-layout-c1b-v1.md','docs/contracts/tablet-layout-observation-c1b-v1.schema.json','docs/contracts/tablet-layout-observation-c1b-v1.md',
      'app/build.gradle.kts','app/settings.gradle.kts','app/gradle.properties','app/gradle/verification-metadata.xml','app/gradle/wrapper/gradle-wrapper.jar','app/gradle/wrapper/gradle-wrapper.properties',
      'app/tablet-c1b-probe/build.gradle.kts','app/tablet-c1b-probe/src/main/AndroidManifest.xml',
      'app/tablet-c1b-probe/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt',
      'app/tablet-c1b-probe/src/main/res/xml/a11y_config.xml','app/tablet-c1b-probe/src/main/res/values/strings.xml',
      'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt','app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt',
      'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt','app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt','app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt',
      'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt','app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bProtocol.kt','app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator.kt','app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController.kt','app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory.kt','app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry.kt',
      'scripts/tests/fixtures/tablet-layout-c1b-build-environment.json')
    foreach($relative in $overlay){$from=Join-Path $SourceRoot ($relative-replace'/','\');$to=Join-Path $repo ($relative-replace'/','\');$parent=Split-Path $to -Parent;if(-not(Test-Path $parent)){[void](New-Item -ItemType Directory -Force $parent)};Copy-Item -LiteralPath $from -Destination $to -Force}
    # Production resolves the global device lock from the Windows KnownFolder and both production
    # callers deliberately use the no-argument API. Keep that call shape in the synthetic runner
    # and T0 sidecar, but make their copied library derive one test-only lock root from E2E state.
    [IO.File]::AppendAllText((Join-Path $repo 'scripts\lib\dispatch-lock.ps1'),@'

function Get-DispatchGlobalLockPath {
    [CmdletBinding()]param()
    $state=[string]$env:TL1_C1B_E2E_STATE
    if([string]::IsNullOrWhiteSpace($state)-or-not[IO.Path]::IsPathFullyQualified($state)){throw 'synthetic global device lock state root missing'}
    $state=[IO.Path]::GetFullPath($state);$base=Join-Path ([IO.Path]::GetDirectoryName($state)) 'localappdata'
    if(-not(Test-Path -LiteralPath $base -PathType Container)){throw 'synthetic global device lock base missing'}
    return Initialize-DispatchLockParent -Path (Join-Path $base 'agent-for-mobile\locks\device-v1.lock')
}
$script:TL1C1bE2eOriginalCloseDispatchLockLease=${function:Close-DispatchLockLease}
function Close-DispatchLockLease {
    [CmdletBinding()]param([Parameter(Mandatory)]$Lease)
    $scenario=[string]$env:TL1_C1B_E2E_SCENARIO
    $closed=& $script:TL1C1bE2eOriginalCloseDispatchLockLease -Lease $Lease
    if($scenario-cin@('early_server_fast_exit','early_status_client_exit')){
        $evidenceRoot=[IO.Path]::GetFullPath((Join-Path $env:TL1_C1B_E2E_STATE '..\repo\docs\runs\evidence'))
        $count=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json' -ErrorAction SilentlyContinue).Count
        [IO.File]::AppendAllText((Join-Path $env:TL1_C1B_E2E_STATE 'attempt-publish-order.log'),($scenario+":device_lease_after="+$count+"`n"),[Text.UTF8Encoding]::new($false))
    }
    if($scenario-ceq'early_server_fast_exit'){return $false}
    return $closed
}
'@,[Text.UTF8Encoding]::new($false))
    # The production build-environment helper binds real JDK/Gradle/SDK trees and Windows ACLs.
    # The synthetic checkout instead appends a closed, same-signature lifecycle double. It keeps
    # one immutable public binding, launches both fake tools through this pwsh, pre-creates the
    # fixed module build root, and removes that root only when the runner closes the guard.
    [IO.File]::AppendAllText((Join-Path $repo 'scripts\lib\tablet-layout-c1b-build-env.ps1'),@'

function Get-TL1C1bSyntheticBuildEnvironmentFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{return 'sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))).ToLowerInvariant()}finally{$stream.Dispose()}
}
function Get-TL1C1bSyntheticBuildEnvironmentTextSha256 {
    param([Parameter(Mandatory)][string]$Value)
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Value)
    try{return 'sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function Assert-TL1C1bSyntheticBuildEnvironmentGuard {
    param([Parameter(Mandatory)]$TrustGuard)
    if($null-eq$TrustGuard-or[bool]$TrustGuard.Disposed){throw 'synthetic C1b build-environment guard is closed'}
    if(-not(Test-Path -LiteralPath $TrustGuard.ModuleBuildOutputDirectory -PathType Container)){throw 'synthetic C1b fixed module build root drift'}
    $expectedSystemDirectory=[IO.Path]::GetFullPath([Environment]::SystemDirectory);$expectedSystemRoot=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($expectedSystemDirectory));$expectedCmdPath=[IO.Path]::GetFullPath((Join-Path $expectedSystemDirectory 'cmd.exe'))
    if(-not[bool]$TrustGuard.TestOnlySynthetic-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$TrustGuard.HostPaths.SystemRoot,$expectedSystemRoot)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$TrustGuard.HostPaths.SystemDirectory,$expectedSystemDirectory)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$TrustGuard.HostPaths.CmdPath,$expectedCmdPath)-or
       [StringComparer]::OrdinalIgnoreCase.Equals([string]$TrustGuard.AndroidSdkRoot,[string]$TrustGuard.SourceAndroidSdkRoot)-or
       (Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $TrustGuard.IsolatedAdbPath)-cne$TrustGuard.IsolatedAdbSha256-or
       (Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $TrustGuard.IsolatedAapt2Path)-cne$TrustGuard.IsolatedAapt2Sha256-or
       (Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $TrustGuard.GradleScript)-cne$TrustGuard.GradleScriptSha256-or
       (Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $TrustGuard.SignerScript)-cne$TrustGuard.SignerScriptSha256-or
       [bool]$TrustGuard.Binding.debug_keystore.post_gradle_lock_sealed_achieved-ne
           [bool]$TrustGuard.DebugKeystoreGuard.Sealed-or
       (($TrustGuard.Binding|ConvertTo-Json -Depth 20 -Compress)-cne$TrustGuard.BindingRaw)){
        throw 'synthetic C1b build-environment frozen binding drift'
    }
    return $TrustGuard.Binding
}
function Open-TL1C1bBuildEnvironmentTrustGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$JavaHome,
        [Parameter(Mandatory)][string]$GradleHome,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$GitPath,
        [Parameter(Mandatory)][string]$GradleUserHomeParent,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RepositoryInputPaths,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RepositoryInputDirectories
    )
    $repo=[IO.Path]::GetFullPath($RepoRoot);$jdk=[IO.Path]::GetFullPath($JavaHome);$gradle=[IO.Path]::GetFullPath($GradleHome);$sdk=[IO.Path]::GetFullPath($AndroidSdkRoot)
    foreach($directory in @($repo,$jdk,$gradle,$sdk,[IO.Path]::GetFullPath($GradleUserHomeParent))){if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw 'synthetic C1b explicit build directory missing'}}
    $fixturePath=Join-Path $repo 'scripts\tests\fixtures\tablet-layout-c1b-build-environment.json';$gradleScript=Join-Path $repo 'app\fake-gradle.ps1';$signerScript=Join-Path $repo 'app\fake-signer.ps1'
    foreach($file in @($fixturePath,$gradleScript,$signerScript,$GitPath)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "synthetic C1b build fixture input missing: $file"}}
    $binding=Get-Content -LiteralPath $fixturePath -Raw|ConvertFrom-Json -Depth 30 -DateKind String
    $binding.debug_keystore.post_gradle_lock_sealed_achieved=$false
    $relativePaths=[string[]]@($RepositoryInputPaths);[Array]::Sort($relativePaths,[StringComparer]::Ordinal)
    if($relativePaths.Count-ne42-or$RepositoryInputDirectories.Count-ne3-or(@($relativePaths|Select-Object -Unique)).Count-ne42){throw 'synthetic C1b repository input closure drift'}
    $catalog=[Collections.Generic.List[string]]::new()
    foreach($relative in $relativePaths){
        if([string]::IsNullOrWhiteSpace($relative)-or$relative.Contains('\')-or[IO.Path]::IsPathFullyQualified($relative)-or$relative.StartsWith('../',[StringComparison]::Ordinal)){throw 'synthetic C1b repository input path drift'}
        $path=[IO.Path]::GetFullPath((Join-Path $repo ($relative.Replace('/','\'))));if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "synthetic C1b repository input missing: $relative"}
        $catalog.Add($relative+'='+(Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $path))
    }
    $catalogText=$catalog.ToArray()-join"`n";$binding.repository_inputs.file_count=[long]$relativePaths.Count;$binding.repository_inputs.catalog_sha256=Get-TL1C1bSyntheticBuildEnvironmentTextSha256 $catalogText
    [IO.File]::WriteAllText((Join-Path $env:TL1_C1B_E2E_STATE 'build-environment-input-catalog.txt'),$catalogText,[Text.UTF8Encoding]::new($false))
    $moduleBuildOutput=Join-Path $repo 'app\tablet-c1b-probe\build';if(Test-Path -LiteralPath $moduleBuildOutput){throw 'synthetic C1b module build output was not fresh'};[void](New-Item -ItemType Directory -Path $moduleBuildOutput)
    $journal=Join-Path $repo '.git\tablet-layout-c1b-synthetic-build-environment-recovery.json';[IO.File]::WriteAllText($journal,"synthetic recovery journal`n",[Text.UTF8Encoding]::new($false))
    $workspace=Join-Path $env:TL1_C1B_E2E_STATE ('build-environment-workspace-'+$PID);$projectCache=Join-Path $workspace 'project-cache';$processTemp=Join-Path $workspace 'process-temp';$gitUserHome=Join-Path $workspace 'git-user-home';$isolatedSdk=Join-Path $workspace 'android-sdk';$isolatedAdb=Join-Path $isolatedSdk 'platform-tools\adb.exe';$isolatedAapt2=Join-Path $isolatedSdk 'build-tools\35.0.0\aapt2.exe';[void](New-Item -ItemType Directory -Path $projectCache,$processTemp,$gitUserHome,(Split-Path $isolatedAdb -Parent),(Split-Path $isolatedAapt2 -Parent),(Join-Path $isolatedSdk 'platforms\android-35'));Copy-Item -LiteralPath (Join-Path $sdk 'platform-tools\adb.exe') -Destination $isolatedAdb;Copy-Item -LiteralPath (Join-Path $sdk 'build-tools\35.0.0\aapt2.exe') -Destination $isolatedAapt2
    if([StringComparer]::OrdinalIgnoreCase.Equals($isolatedSdk,$sdk)){throw 'synthetic C1b isolated SDK reused source root'}
    $systemRoot=[IO.Path]::GetFullPath([string]$env:SYSTEMROOT);$systemDirectory=[IO.Path]::GetFullPath([Environment]::SystemDirectory);$cmdPath=Join-Path $systemDirectory 'cmd.exe';foreach($hostPath in @($systemRoot,$systemDirectory,$cmdPath)){if(-not(Test-Path -LiteralPath $hostPath)){throw 'synthetic C1b trusted host path missing'}}
    $hostPaths=[pscustomobject][ordered]@{SystemRoot=$systemRoot;SystemDirectory=$systemDirectory;CmdPath=$cmdPath}
    $child=@{SYSTEMROOT=$systemRoot;WINDIR=$systemRoot;COMSPEC=$cmdPath;TEMP=$processTemp;TMP=$processTemp;PATH=$systemDirectory;PSModulePath=$env:PSModulePath;JAVA_HOME=$jdk;TL1_C1B_GRADLE_HOME=$gradle;ANDROID_HOME=$isolatedSdk;ANDROID_SDK_ROOT=$isolatedSdk;TL1_C1B_E2E_STATE=$env:TL1_C1B_E2E_STATE;TL1_C1B_E2E_SCENARIO=$env:TL1_C1B_E2E_SCENARIO;TL1_C1B_E2E_PROJECT_CACHE=$projectCache}
    $gitPath=[IO.Path]::GetFullPath($GitPath);$gitRoot=[IO.Path]::GetFullPath((Split-Path (Split-Path $gitPath -Parent) -Parent));$gitChild=@{SYSTEMROOT=$systemRoot;WINDIR=$systemRoot;COMSPEC=$cmdPath;PATHEXT='.COM;.EXE;.BAT;.CMD';PATH=(Join-Path $gitRoot 'cmd')+[IO.Path]::PathSeparator+(Join-Path $gitRoot 'mingw64\bin')+[IO.Path]::PathSeparator+$systemDirectory;TEMP=$processTemp;TMP=$processTemp;USERPROFILE=$gitUserHome;HOME=$gitUserHome;GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL='NUL';GIT_CONFIG_COUNT='0';GIT_TERMINAL_PROMPT='0';GCM_INTERACTIVE='Never';GIT_OPTIONAL_LOCKS='0'}
    $syntheticStatusResult=Invoke-TL1C1aGit -RepoRoot $repo -Arguments @('status','--porcelain=v1','--untracked-files=all') -GitPath $gitPath -ProcessEnvironment $gitChild -ClearEnvironment
    if(-not[string]::IsNullOrWhiteSpace($syntheticStatusResult.Text)){throw "synthetic C1b guard dirtied repo: $($syntheticStatusResult.Text)"}
    $guard=[pscustomobject][ordered]@{Disposed=$false;TestOnlySynthetic=$true;RepoRoot=$repo;GitPath=$gitPath;GitRoot=$gitRoot;GitGuard=[pscustomobject]@{Path=$gitPath};GitEnvironment=$gitChild;RecoveryJournal=[pscustomobject]@{Path=$journal};ModuleBuildOutputDirectory=$moduleBuildOutput;Workspace=$workspace;ProcessTempDirectory=$processTemp;ProjectCacheDirectory=$projectCache;HostPaths=$hostPaths;SourceAndroidSdkRoot=$sdk;AndroidSdkRoot=$isolatedSdk;IsolatedAdbPath=$isolatedAdb;IsolatedAapt2Path=$isolatedAapt2;IsolatedAdbSha256=Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $isolatedAdb;IsolatedAapt2Sha256=Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $isolatedAapt2;PwshPath=(Get-Process -Id $PID).Path;GradleScript=$gradleScript;SignerScript=$signerScript;GradleScriptSha256=Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $gradleScript;SignerScriptSha256=Get-TL1C1bSyntheticBuildEnvironmentFileSha256 $signerScript;ChildEnvironment=$child;Binding=$binding;BindingRaw=($binding|ConvertTo-Json -Depth 20 -Compress)}
    $guard|Add-Member -NotePropertyName DebugKeystoreGuard -NotePropertyValue ([pscustomobject]@{Sealed=$false})
    return $guard
}
function Assert-TL1C1bBuildEnvironmentFrozen {param([Parameter(Mandatory)]$TrustGuard);return Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard}
function Get-TL1C1bBuildEnvironmentBuildEnvironment {param([Parameter(Mandatory)]$TrustGuard);[void](Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard);return $TrustGuard.ChildEnvironment}
function Get-TL1C1bBuildEnvironmentGitEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)
    [void](Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard);$environment=$TrustGuard.GitEnvironment
    $expectedKeys=[string[]]@('COMSPEC','GCM_INTERACTIVE','GIT_CONFIG_COUNT','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','GIT_OPTIONAL_LOCKS','GIT_TERMINAL_PROMPT','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','USERPROFILE','WINDIR');[Array]::Sort($expectedKeys,[StringComparer]::Ordinal);$actualKeys=[string[]]@($environment.Keys);[Array]::Sort($actualKeys,[StringComparer]::Ordinal)
    $expectedPath=(Join-Path $TrustGuard.GitRoot 'cmd')+[IO.Path]::PathSeparator+(Join-Path $TrustGuard.GitRoot 'mingw64\bin')+[IO.Path]::PathSeparator+$TrustGuard.HostPaths.SystemDirectory
    if(($expectedKeys-join"`n")-cne($actualKeys-join"`n")-or$environment.PATH-cne$expectedPath-or$environment.GIT_CONFIG_NOSYSTEM-cne'1'-or$environment.GIT_CONFIG_GLOBAL-cne'NUL'-or$environment.GIT_CONFIG_COUNT-cne'0'-or$environment.GIT_OPTIONAL_LOCKS-cne'0'-or$environment.GIT_TERMINAL_PROMPT-cne'0'-or$environment.GCM_INTERACTIVE-cne'Never'-or-not(Test-Path -LiteralPath $environment.TEMP -PathType Container)-or$environment.TEMP-cne$environment.TMP-or$environment.USERPROFILE-cne$environment.HOME){throw 'synthetic C1b Git environment closure drift'}
    return $environment
}
function Get-TL1C1bBuildEnvironmentGradleInvocation {param([Parameter(Mandatory)]$TrustGuard);[void](Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard);return [pscustomobject][ordered]@{FilePath=$TrustGuard.PwshPath;Arguments=[string[]]@('-NoProfile','-File',$TrustGuard.GradleScript)}}
function Get-TL1C1bBuildEnvironmentApkSignerInvocation {param([Parameter(Mandatory)]$TrustGuard);[void](Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard);return [pscustomobject][ordered]@{FilePath=$TrustGuard.PwshPath;Arguments=[string[]]@('-NoProfile','-File',$TrustGuard.SignerScript)}}
function Get-TL1C1bBuildEnvironmentGradleArguments {param([Parameter(Mandatory)]$TrustGuard);[void](Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard);return [string[]]@('--project-cache-dir',$TrustGuard.ProjectCacheDirectory,'-PtabletC1bIsolatedBuild=true','-Pkotlin.incremental=false','-Pkotlin.compiler.execution.strategy=in-process')}
function Seal-TL1C1bBuildEnvironmentDebugKeystoreLock {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [Parameter(Mandatory)]$ExpectedTrustGuard,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string]$ExpectedPreSealBindingRaw
    )
    if(-not[object]::ReferenceEquals($TrustGuard,$ExpectedTrustGuard)){
        throw 'synthetic C1b post-Gradle seal trust guard identity drift'
    }
    $pre=Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard
    $preRaw=$pre|ConvertTo-Json -Depth 20 -Compress
    if($preRaw-cne$ExpectedPreSealBindingRaw-or
       [regex]::Matches($preRaw,[regex]::Escape('"post_gradle_lock_sealed_achieved":false')).Count-ne1-or
       $preRaw.Contains('"post_gradle_lock_sealed_achieved":true')){
        throw 'synthetic C1b pre-seal full binding drift'
    }
    $TrustGuard.DebugKeystoreGuard.Sealed=$true
    $TrustGuard.Binding.debug_keystore.post_gradle_lock_sealed_achieved=$true
    $TrustGuard.BindingRaw=$TrustGuard.Binding|ConvertTo-Json -Depth 20 -Compress
    $post=Assert-TL1C1bSyntheticBuildEnvironmentGuard $TrustGuard
    $postRaw=$post|ConvertTo-Json -Depth 20 -Compress
    Assert-TL1C1bBuildEnvironmentSealBindingTransition $preRaw $postRaw
    return $post
}
function Close-TL1C1bBuildEnvironmentTrustGuard {
    param([Parameter(Mandatory)]$TrustGuard,[switch]$KeepGradleUserHome)
    if([bool]$TrustGuard.Disposed){return};$TrustGuard.Disposed=$true
    if(Test-Path -LiteralPath $TrustGuard.ModuleBuildOutputDirectory){Remove-Item -LiteralPath $TrustGuard.ModuleBuildOutputDirectory -Recurse -Force}
    if(Test-Path -LiteralPath $TrustGuard.RecoveryJournal.Path){Remove-Item -LiteralPath $TrustGuard.RecoveryJournal.Path -Force}
    if(Test-Path -LiteralPath $TrustGuard.Workspace){Remove-Item -LiteralPath $TrustGuard.Workspace -Recurse -Force}
    $scenario=[string]$env:TL1_C1B_E2E_SCENARIO
    if($scenario-cin@('early_server_fast_exit','early_status_client_exit')){
        $evidenceRoot=Join-Path $TrustGuard.RepoRoot 'docs\runs\evidence'
        $count=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json' -ErrorAction SilentlyContinue).Count
        [IO.File]::AppendAllText((Join-Path $env:TL1_C1B_E2E_STATE 'attempt-publish-order.log'),($scenario+":build_environment_after="+$count+"`n"),[Text.UTF8Encoding]::new($false))
    }
}
'@,[Text.UTF8Encoding]::new($false))
    # Production requires a valid OS-trusted Google Authenticode signature.  A locally compiled
    # fake cannot have that signature, so only the synthetic copy gets this closed test double.
    # It deliberately retains the canonical SDK location and ordinary-file gates, and never ships
    # back to the source checkout.
    [IO.File]::AppendAllText((Join-Path $repo 'scripts\lib\tablet-layout-c1b.ps1'),@'

function Get-TL1C1bAdbTrustBinding {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome,
        [hashtable]$ProcessEnvironment,
        [switch]$ClearEnvironment
    )
    $sdkRoot=[IO.Path]::GetFullPath($AndroidSdkRoot)
    $homeRoot=[IO.Path]::GetFullPath($AndroidHome)
    if($sdkRoot-cne$homeRoot){throw 'synthetic C1b SDK roots differ'}
    $expected=[IO.Path]::GetFullPath((Join-Path $sdkRoot 'platform-tools\adb.exe'))
    $actual=[IO.Path]::GetFullPath($AdbPath)
    if($actual-cne$expected){throw 'synthetic C1b adb is outside canonical SDK platform-tools'}
    if(-not$ClearEnvironment-or$null-eq$ProcessEnvironment){throw 'synthetic C1b adb trust binding requires a closed child environment'}
    $expectedEnvironmentKeys=[string[]]@('ANDROID_HOME','ANDROID_SDK_ROOT','COMSPEC','HOME','PATH','PATHEXT','SYSTEMROOT','TEMP','TL1_C1B_E2E_SCENARIO','TL1_C1B_E2E_STATE','TMP','USERPROFILE','WINDIR');[Array]::Sort($expectedEnvironmentKeys,[StringComparer]::Ordinal);$actualEnvironmentKeys=[string[]]@($ProcessEnvironment.Keys);[Array]::Sort($actualEnvironmentKeys,[StringComparer]::Ordinal)
    $systemDirectory=[IO.Path]::GetFullPath([Environment]::SystemDirectory);$systemRoot=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($systemDirectory));$cmdPath=[IO.Path]::GetFullPath((Join-Path $systemDirectory 'cmd.exe'))
    if(($actualEnvironmentKeys-join"`n")-cne($expectedEnvironmentKeys-join"`n")-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.SYSTEMROOT,$systemRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.WINDIR,$systemRoot)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.COMSPEC,$cmdPath)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.PATH,$systemDirectory)-or$ProcessEnvironment.PATHEXT-cne'.COM;.EXE;.BAT;.CMD'-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.ANDROID_SDK_ROOT,$sdkRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.ANDROID_HOME,$sdkRoot)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.HOME,[string]$ProcessEnvironment.USERPROFILE)-or-not(Test-Path -LiteralPath ([string]$ProcessEnvironment.USERPROFILE) -PathType Container)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.TEMP,[string]$ProcessEnvironment.TMP)-or-not(Test-Path -LiteralPath ([string]$ProcessEnvironment.TEMP) -PathType Container)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.TL1_C1B_E2E_STATE,[string]$env:TL1_C1B_E2E_STATE)-or$ProcessEnvironment.TL1_C1B_E2E_SCENARIO-cne$env:TL1_C1B_E2E_SCENARIO){
        throw 'synthetic C1b adb clear-environment binding drift'
    }
    $item=Get-Item -LiteralPath $actual -Force -ErrorAction Stop
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or-not[string]::IsNullOrWhiteSpace([string]$item.LinkType)){
        throw 'synthetic C1b adb must be an ordinary single path'
    }
    $version="Android Debug Bridge version 1.0.41`r`nVersion 36.0.0-13206524`r`nInstalled as $actual`r`n"
    return [ordered]@{
        trust_root='android_sdk_platform_tools';canonical_relative_path='platform-tools/adb.exe';sdk_roots_equal=$true
        executable_sha256=Get-TL1C1aFileSha256 $actual;version_output_sha256=Get-TL1C1aSha256Text $version
        signature_status='Valid';signature_subject=$script:TL1C1bGoogleAdbSignerSubject
        signature_certificate_sha256=('sha256:'+('d'*64));protocol_version='1.0.41'
        package_version='36.0.0-13206524';installed_as_canonical=$true
    }
}
'@,[Text.UTF8Encoding]::new($false))
    # The production helper binds the fixed Google-signed aapt2 and holds a deny-write/delete
    # handle across the run. The synthetic checkout cannot manufacture that signed binary, so its
    # copied helper gets a test-only guard with the same closed binding and handle lifetime. No
    # override is added to the source/production helper.
    [IO.File]::AppendAllText((Join-Path $repo 'scripts\lib\tablet-layout-c1b-aapt2.ps1'),@'

function Open-TL1C1bAapt2TrustGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome
    )
    $sdkRoot=[IO.Path]::GetFullPath($AndroidSdkRoot)
    $homeRoot=[IO.Path]::GetFullPath($AndroidHome)
    if($sdkRoot-cne$homeRoot){throw 'synthetic C1b aapt2 SDK roots differ'}
    $canonical=[IO.Path]::GetFullPath((Join-Path $sdkRoot 'build-tools\35.0.0\aapt2.exe'))
    $item=Get-Item -LiteralPath $canonical -Force -ErrorAction Stop
    if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or
       (-not[string]::IsNullOrWhiteSpace([string]$item.LinkType)-and[string]$item.LinkType-cne'HardLink')){
        throw 'synthetic C1b aapt2 must be an ordinary canonical file'
    }
    $guard=[IO.File]::Open($canonical,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $binding=[pscustomobject][ordered]@{
            schema='tablet-layout-c1b-aapt2-trust/v1';trust_root='android_sdk_build_tools';build_tools_version='35.0.0'
            canonical_relative_path='build-tools/35.0.0/aapt2.exe';sdk_roots_equal=$true
            executable_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'
            signature_status='Valid';signature_subject='CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'
            signature_certificate_sha256='sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'
        }
        return [pscustomobject][ordered]@{Guard=$guard;CanonicalPath=$canonical;AndroidSdkRoot=$sdkRoot;Binding=$binding}
    }catch{$guard.Dispose();throw}
}
function Assert-TL1C1bAapt2TrustGuardUnchanged {
    param([Parameter(Mandatory)]$TrustGuard)
    if($null-eq$TrustGuard-or$null-eq$TrustGuard.Guard-or$TrustGuard.Guard.SafeFileHandle.IsClosed-or
       [IO.Path]::GetFullPath([string]$TrustGuard.CanonicalPath)-cne[IO.Path]::GetFullPath((Join-Path ([string]$TrustGuard.AndroidSdkRoot) 'build-tools\35.0.0\aapt2.exe'))){
        throw 'synthetic C1b aapt2 guard drift'
    }
    return $TrustGuard.Binding
}
function Get-TL1C1bPackagedAxmlDumpBinding {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [Parameter(Mandatory)]$ArtifactGuard,
        [Parameter(Mandatory)][ValidateSet('debug','release')][string]$Variant,
        [AllowNull()][hashtable]$ProcessEnvironment,
        [switch]$ClearEnvironment
    )
    if($null-eq$ProcessEnvironment-or-not$ClearEnvironment.IsPresent){throw 'synthetic C1b aapt2 requires a closed child environment'}
    $expectedKeys=[string[]]@('ANDROID_HOME','ANDROID_SDK_ROOT','COMSPEC','JAVA_HOME','PATH','PSModulePath','SYSTEMROOT','TABLET_C1B_BUILD_CHALLENGE','TEMP','TL1_C1B_E2E_PROJECT_CACHE','TL1_C1B_E2E_SCENARIO','TL1_C1B_E2E_STATE','TL1_C1B_EXPECTED_COMMIT_SHA','TL1_C1B_GRADLE_HOME','TMP','WINDIR');[Array]::Sort($expectedKeys,[StringComparer]::Ordinal);$actualKeys=[string[]]@($ProcessEnvironment.Keys);[Array]::Sort($actualKeys,[StringComparer]::Ordinal)
    $systemDirectory=[IO.Path]::GetFullPath([Environment]::SystemDirectory);$systemRoot=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($systemDirectory));$sdkRoot=[IO.Path]::GetFullPath([string]$TrustGuard.AndroidSdkRoot)
    if(($actualKeys-join"`n")-cne($expectedKeys-join"`n")-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.SYSTEMROOT,$systemRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.WINDIR,$systemRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.PATH,$systemDirectory)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.ANDROID_SDK_ROOT,$sdkRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.ANDROID_HOME,$sdkRoot)-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.TEMP,[string]$ProcessEnvironment.TMP)-or-not(Test-Path -LiteralPath ([string]$ProcessEnvironment.TEMP) -PathType Container)-or-not(Test-Path -LiteralPath ([string]$ProcessEnvironment.TL1_C1B_E2E_PROJECT_CACHE) -PathType Container)-or
       $ProcessEnvironment.TABLET_C1B_BUILD_CHALLENGE-cnotmatch'^c1b-[0-9a-f]{32}$'-or$ProcessEnvironment.TL1_C1B_EXPECTED_COMMIT_SHA-cnotmatch'^[0-9a-f]{40}$'-or
       -not[StringComparer]::OrdinalIgnoreCase.Equals([string]$ProcessEnvironment.TL1_C1B_E2E_STATE,[string]$env:TL1_C1B_E2E_STATE)-or$ProcessEnvironment.TL1_C1B_E2E_SCENARIO-cne$env:TL1_C1B_E2E_SCENARIO){throw 'synthetic C1b aapt2 child-environment binding drift'}
    [void](Assert-TL1C1bAapt2TrustGuardUnchanged $TrustGuard)
    if($null-eq$ArtifactGuard.Guard-or$ArtifactGuard.Guard.SafeFileHandle.IsClosed){throw 'synthetic C1b APK guard drift'}
    $saved=$ArtifactGuard.Guard.Position
    try{$ArtifactGuard.Guard.Position=0;$heldSha='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ArtifactGuard.Guard))).ToLowerInvariant()}finally{$ArtifactGuard.Guard.Position=$saved}
    if($heldSha-cne[string]$ArtifactGuard.Sha256){throw 'synthetic C1b APK held hash drift'}
    $manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes("synthetic-aapt2-manifest-dump:$Variant")
    $a11yBytes=[Text.UTF8Encoding]::new($false).GetBytes("synthetic-aapt2-a11y-dump:$Variant")
    try{
        return [pscustomobject][ordered]@{
            Variant=$Variant;ApkSha256=$heldSha;A11yEntryRelativePath='res/xml/a11y_config.xml'
            PackagedManifestAxmlDumpSha256=Get-TL1C1bAapt2Sha256Bytes $manifestBytes
            PackagedA11yAxmlDumpSha256=Get-TL1C1bAapt2Sha256Bytes $a11yBytes
        }
    }finally{[Array]::Clear($manifestBytes,0,$manifestBytes.Length);[Array]::Clear($a11yBytes,0,$a11yBytes.Length)}
}
'@,[Text.UTF8Encoding]::new($false))
    $gradleScript=Join-Path $repo 'app\fake-gradle.ps1';[IO.File]::WriteAllText($gradleScript,@'
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$state=$env:TL1_C1B_E2E_STATE;$repoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));$module=Join-Path $PSScriptRoot 'tablet-c1b-probe';$build=Join-Path $module 'build'
if(@($args|Where-Object{$_-ceq'clean'-or$_-cmatch'GradleWrapperMain'}).Count-ne0){throw 'synthetic Gradle accepted clean/WrapperMain'}
$expectedArguments=[string[]]@('--project-cache-dir',[IO.Path]::GetFullPath($env:TL1_C1B_E2E_PROJECT_CACHE),'-PtabletC1bIsolatedBuild=true','-Pkotlin.incremental=false','-Pkotlin.compiler.execution.strategy=in-process','-p',[IO.Path]::GetFullPath($PSScriptRoot),':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact','--dependency-verification=strict','--no-build-cache','--no-configuration-cache','--rerun-tasks','--no-daemon','--console=plain','--quiet')
if($args.Count-ne$expectedArguments.Count){throw 'synthetic Gradle argument count drift'};for($index=0;$index-lt$expectedArguments.Count;$index++){if([string]$args[$index]-cne$expectedArguments[$index]){throw "synthetic Gradle argument drift at index $index"}}
[IO.File]::AppendAllText((Join-Path $state 'gradle.log'),"1`n",[Text.UTF8Encoding]::new($false))
function Hash-Bytes([byte[]]$Bytes){return 'sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))).ToLowerInvariant()}
function Hash-Text([string]$Value){$bytes=[Text.UTF8Encoding]::new($false).GetBytes($Value);try{return Hash-Bytes $bytes}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}}
function Hash-File([string]$Path){$bytes=[IO.File]::ReadAllBytes($Path);try{return Hash-Bytes $bytes}finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}}
function Write-Utf8([string]$Path,[string]$Value){[void](New-Item -ItemType Directory -Force (Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function New-SyntheticApk([string]$Path,[byte]$Marker,[int]$DexCount){
    if($DexCount-notin 1..32){throw 'synthetic APK DEX count out of range'}
    [void](New-Item -ItemType Directory -Force (Split-Path $Path -Parent));$stream=[IO.File]::Open($Path,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true);try{
        $manifestEntry=$archive.CreateEntry('AndroidManifest.xml',[IO.Compression.CompressionLevel]::NoCompression);$manifestStream=$manifestEntry.Open();$manifestBytes=[Text.UTF8Encoding]::new($false).GetBytes("synthetic-binary-manifest:dev.magina.gateway:dev.magina.gateway.a11y.GatewayA11yService:dev.magina.gateway.tablet.c1b.TabletC1bContentProvider:$Marker");try{$manifestStream.Write($manifestBytes)}finally{$manifestStream.Dispose();[Array]::Clear($manifestBytes,0,$manifestBytes.Length)}
        $a11yEntry=$archive.CreateEntry('res/xml/a11y_config.xml',[IO.Compression.CompressionLevel]::NoCompression);$a11yStream=$a11yEntry.Open();$a11yBytes=[Text.UTF8Encoding]::new($false).GetBytes("synthetic-binary-a11y-config:$Marker");try{$a11yStream.Write($a11yBytes)}finally{$a11yStream.Dispose();[Array]::Clear($a11yBytes,0,$a11yBytes.Length)}
        for($dexIndex=1;$dexIndex-le$DexCount;$dexIndex++){$dexName=if($dexIndex-eq1){'classes.dex'}else{"classes$dexIndex.dex"};$entry=$archive.CreateEntry($dexName,[IO.Compression.CompressionLevel]::NoCompression);$entryStream=$entry.Open();try{$entryStream.Write([byte[]](0x64,0x65,0x78,0x0a,0x30,0x33,0x35,0x00,$Marker,[byte]$dexIndex))}finally{$entryStream.Dispose()}}
    }finally{$archive.Dispose()}}finally{$stream.Dispose()}
}
[IO.File]::WriteAllText((Join-Path $state 'challenge.txt'),$env:TABLET_C1B_BUILD_CHALLENGE,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $state 'build-head.txt'),$env:TL1_C1B_EXPECTED_COMMIT_SHA,[Text.UTF8Encoding]::new($false))
$debugApk=Join-Path $build 'outputs\apk\debug\tablet-c1b-probe-debug.apk';$releaseApk=Join-Path $build 'outputs\apk\release\tablet-c1b-probe-release-unsigned.apk'
New-SyntheticApk $debugApk 0x44 6;New-SyntheticApk $releaseApk 0x52 1
$mergedManifest=@"
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="dev.magina.gateway">
  <application android:allowBackup="false">
    <service android:name="dev.magina.gateway.a11y.GatewayA11yService" android:exported="false" android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE" />
    <provider android:name="dev.magina.gateway.tablet.c1b.TabletC1bContentProvider" android:authorities="dev.magina.gateway.tablet.c1b" android:exported="true" android:permission="android.permission.DUMP" />
  </application>
</manifest>
"@
$debugManifest=Join-Path $build 'intermediates\merged_manifests\debug\processDebugManifest\AndroidManifest.xml';$releaseManifest=Join-Path $build 'intermediates\merged_manifests\release\processReleaseManifest\AndroidManifest.xml'
Write-Utf8 $debugManifest $mergedManifest;Write-Utf8 $releaseManifest $mergedManifest
$sourcePaths=[string[]]@(
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry.kt',
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt',
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bProtocol.kt',
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator.kt',
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController.kt',
 'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory.kt',
 'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt',
 'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt',
 'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt',
 'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt',
 'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt',
 'app/tablet-c1b-probe/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt'
);[Array]::Sort($sourcePaths,[StringComparer]::Ordinal)
$sourceProof=[Collections.Generic.List[object]]::new();foreach($relative in $sourcePaths){$sourceProof.Add([ordered]@{relative_path=$relative;sha256=Hash-File (Join-Path $repoRoot ($relative-replace'/','\'))})}
$buildInputPaths=[string[]]@('app/build.gradle.kts','app/gradle.properties','app/gradle/verification-metadata.xml','app/gradle/wrapper/gradle-wrapper.jar','app/gradle/wrapper/gradle-wrapper.properties','app/gradlew.bat','app/settings.gradle.kts','app/tablet-c1b-probe/build.gradle.kts','app/tablet-c1b-probe/src/main/AndroidManifest.xml','app/tablet-c1b-probe/src/main/res/values/strings.xml','app/tablet-c1b-probe/src/main/res/xml/a11y_config.xml');[Array]::Sort($buildInputPaths,[StringComparer]::Ordinal)
$buildInputProof=[Collections.Generic.List[object]]::new();foreach($relative in $buildInputPaths){$buildInputProof.Add([ordered]@{relative_path=$relative;sha256=Hash-File (Join-Path $repoRoot ($relative-replace'/','\'))})}
function New-VariantProof([string]$Name,[string]$Apk,[string]$Manifest){
    $archive=[IO.Compression.ZipFile]::OpenRead($Apk);try{$dexEntries=@($archive.Entries|Where-Object FullName -match '^classes(?:[2-9]|[1-9][0-9]+)?\.dex$'|Sort-Object @{Expression={if($_.FullName-ceq'classes.dex'){1}else{[int]([regex]::Match($_.FullName,'^classes([0-9]+)\.dex$').Groups[1].Value)}}});$manifestEntry=@($archive.Entries|Where-Object FullName -ceq 'AndroidManifest.xml');if($dexEntries.Count-notin 1..32-or$manifestEntry.Count-ne1){throw 'synthetic APK entry closure drift'};$dexProof=[Collections.Generic.List[object]]::new();foreach($dexEntry in $dexEntries){$dexStream=$dexEntry.Open();try{$dexHash='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($dexStream))).ToLowerInvariant()}finally{$dexStream.Dispose()};$dexProof.Add([ordered]@{relative_path=$dexEntry.FullName;sha256=$dexHash})};$manifestStream=$manifestEntry[0].Open();try{$packagedManifestHash='sha256:'+([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestStream))).ToLowerInvariant()}finally{$manifestStream.Dispose()}}finally{$archive.Dispose()}
    return [ordered]@{name=$Name;apk_relative_path=if($Name-ceq'debug'){'app/tablet-c1b-probe/build/outputs/apk/debug/tablet-c1b-probe-debug.apk'}else{'app/tablet-c1b-probe/build/outputs/apk/release/tablet-c1b-probe-release-unsigned.apk'};apk_sha256=Hash-File $Apk;merged_manifest_sha256=Hash-File $Manifest;packaged_manifest_sha256=$packagedManifestHash;packaged_manifest_axml_dump_sha256=Hash-Text "synthetic-aapt2-manifest-dump:$Name";packaged_a11y_axml_dump_sha256=Hash-Text "synthetic-aapt2-a11y-dump:$Name";packaged_manifest_exact_tree_verified=$true;packaged_a11y_exact_tree_verified=$true;dex_entries=$dexProof.ToArray()}
}
$proof=[ordered]@{
 schema='tablet-c1b-read-only-artifact-proof/v1';policy='tl1-c1b-read-only/v2';git_sha=$env:TL1_C1B_EXPECTED_COMMIT_SHA;build_challenge_sha256=Hash-Text $env:TABLET_C1B_BUILD_CHALLENGE
 application_id='dev.magina.gateway';accessibility_service_component='dev.magina.gateway.a11y.GatewayA11yService';provider_component='dev.magina.gateway.tablet.c1b.TabletC1bContentProvider';provider_authority='dev.magina.gateway.tablet.c1b'
 forbidden_match_count=[long]0;manifest_mutating_capability_count=[long]0;manifest_extra_component_count=[long]0
 axml_parser=[ordered]@{tool='aapt2';build_tools_version='35.0.0';aapt2_relative_path='build-tools/35.0.0/aapt2.exe';aapt2_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'}
 dependency_allowlist=[ordered]@{passed=$true;resolved_artifacts=@([ordered]@{coordinate='org.jetbrains.kotlin:kotlin-stdlib:2.0.20';artifact_sha256='sha256:fb169596659a518357c4b2c16f43dc75ab1c4980565ed4b4a317a050e5e39006'},[ordered]@{coordinate='org.jetbrains:annotations:13.0';artifact_sha256='sha256:ace2a10dc8e2d5fd34925ecac03e4988b2c0f851650c94b8cef49ba1bd111478'})}
 named_read_only_waivers=@([ordered]@{id='accessibility-node-refresh-read-freshness';relative_path='app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt';exact_invocation='node.androidNode.refresh()';count=[long]1})
 dex_dependency_string_waivers=@('FileOutputStream','forName','getMethod','java/lang/Runtime','java/lang/reflect','java/nio/file/Files')
 scanned_sources=$sourceProof.ToArray();scanned_build_inputs=$buildInputProof.ToArray();variants=@((New-VariantProof debug $debugApk $debugManifest),(New-VariantProof release $releaseApk $releaseManifest))
}
    $proofPath=Join-Path $build 'reports\tablet-c1b-read-only-artifact-proof.json';Write-Utf8 $proofPath (($proof|ConvertTo-Json -Depth 20)+"`n")
    [IO.File]::WriteAllBytes((Join-Path $state 'apk.bin'),[IO.File]::ReadAllBytes($debugApk))
'@,[Text.UTF8Encoding]::new($false))
    $gradle=Join-Path $repo 'app\gradlew.bat';[IO.File]::WriteAllText($gradle,"@echo off`r`n`"$Pwsh`" -NoProfile -File `"$gradleScript`" %*`r`n",[Text.Encoding]::ASCII)
    $fakeSignerScript=Join-Path $repo 'app\fake-signer.ps1';[IO.File]::WriteAllText($fakeSignerScript,@'
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
if($args.Count-ne3-or$args[0]-cne'verify'-or$args[1]-cne'--print-certs'-or-not(Test-Path -LiteralPath $args[2] -PathType Leaf)){throw 'synthetic apksigner invocation drift'}
$target=[IO.Path]::GetFullPath([string]$args[2]);[IO.File]::AppendAllText((Join-Path $env:TL1_C1B_E2E_STATE 'signer.log'),($target+"`n"),[Text.UTF8Encoding]::new($false))
Write-Output ('Signer #1 certificate SHA-256 digest: '+('c'*64))
'@,[Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\tests\fixtures\tablet-layout-observation\c1b-v1\real-shape-topology-only.json') -Destination (Join-Path $state 'observation-template.json')
    $fakeSource=@'
using System;using System.IO;using System.Text;using System.Text.RegularExpressions;using System.Security.Cryptography;using System.Diagnostics;using System.Globalization;using System.Net;using System.Net.Sockets;using System.Threading;using System.Runtime.InteropServices;using System.ComponentModel;
public static class C1bFakeAdb {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]struct STARTUPINFO{public int cb;public string lpReserved;public string lpDesktop;public string lpTitle;public uint dwX;public uint dwY;public uint dwXSize;public uint dwYSize;public uint dwXCountChars;public uint dwYCountChars;public uint dwFillAttribute;public uint dwFlags;public short wShowWindow;public short cbReserved2;public IntPtr lpReserved2;public IntPtr hStdInput;public IntPtr hStdOutput;public IntPtr hStdError;}
 [StructLayout(LayoutKind.Sequential)]struct PROCESS_INFORMATION{public IntPtr hProcess;public IntPtr hThread;public uint dwProcessId;public uint dwThreadId;}
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]static extern bool CreateProcessW(string applicationName,StringBuilder commandLine,IntPtr processAttributes,IntPtr threadAttributes,bool inheritHandles,uint creationFlags,IntPtr environment,string currentDirectory,ref STARTUPINFO startupInfo,out PROCESS_INFORMATION processInformation);
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool CloseHandle(IntPtr handle);
 static string S(){string configured=Environment.GetEnvironmentVariable("TL1_C1B_E2E_STATE");if(!String.IsNullOrWhiteSpace(configured))return Path.GetFullPath(configured);string current=Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);while(!String.IsNullOrEmpty(current)){if(File.Exists(Path.Combine(current,"observation-template.json")))return current;DirectoryInfo parent=Directory.GetParent(current);current=parent==null?null:parent.FullName;}throw new InvalidOperationException("synthetic C1b state root not found from isolated adb path");}
 static bool SocketPort(string socket,out int port){port=0;Match match=Regex.Match(socket??"","\\Atcp:127\\.0\\.0\\.1:([0-9]{5})\\z",RegexOptions.CultureInvariant);return match.Success&&Int32.TryParse(match.Groups[1].Value,NumberStyles.None,CultureInfo.InvariantCulture,out port)&&port>=49152&&port<=65535;}
 static bool ListenSocketPort(string socket,out int port){port=0;Match match=Regex.Match(socket??"","\\Atcp:localhost:([0-9]{5})\\z",RegexOptions.CultureInvariant);return match.Success&&Int32.TryParse(match.Groups[1].Value,NumberStyles.None,CultureInfo.InvariantCulture,out port)&&port>=49152&&port<=65535;}
 static string Socket(int port){return "tcp:127.0.0.1:"+port.ToString(CultureInfo.InvariantCulture);}
 static void Rejected(string[] raw,string reason){File.AppendAllText(Path.Combine(S(),"adb-rejected.log"),reason+"\u001f"+(Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET")??"<absent>")+"\u001f"+string.Join("\u001f",raw)+"\n",new UTF8Encoding(false));}
 static bool Client(string[] raw,out string[] command,out int port){command=null;port=0;if(raw.Length<5||raw[0]!="-H"||raw[1]!="127.0.0.1"||raw[2]!="-P"||!Int32.TryParse(raw[3],NumberStyles.None,CultureInfo.InvariantCulture,out port)||port<49152||port>65535||raw[3]!=port.ToString(CultureInfo.InvariantCulture)||Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET")!=Socket(port))return false;command=new string[raw.Length-4];Array.Copy(raw,4,command,0,command.Length);return true;}
 static string Proto(string value){StringBuilder result=new StringBuilder();foreach(char c in value){if(c=='\\')result.Append("\\\\");else if(c=='\"')result.Append("\\\"");else if(Char.IsControl(c))result.Append("\\x"+((int)c).ToString("x2",CultureInfo.InvariantCulture));else result.Append(c);}return result.ToString();}
 static void Transport(string[] raw,string socket){File.AppendAllText(Path.Combine(S(),"adb-transport.log"),socket+"\u001f"+string.Join("\u001f",raw)+"\n",new UTF8Encoding(false));}
 static void Record(string[] normalized,string[] raw,string socket){for(int attempt=0;attempt<1000;attempt++){try{using(FileStream gate=new FileStream(Path.Combine(S(),"adb-log.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None)){Log(normalized);Transport(raw,socket);return;}}catch(IOException){Thread.Sleep(5);}}throw new IOException("synthetic adb log lock timeout");}
 static void Evidence(string name,string value){File.AppendAllText(Path.Combine(S(),name),value+"\n",new UTF8Encoding(false));}
 static bool PortReusable(int port){Socket probe=new Socket(AddressFamily.InterNetwork,SocketType.Stream,ProtocolType.Tcp);try{probe.ExclusiveAddressUse=true;probe.SetSocketOption(SocketOptionLevel.Socket,SocketOptionName.ReuseAddress,false);probe.Bind(new IPEndPoint(IPAddress.Loopback,port));probe.Listen(1);return true;}catch(SocketException){return false;}finally{probe.Close();}}
 static void StopHeldServer(int port){string socket=Socket(port),marker=Path.Combine(S(),"adb-server-stop-"+port.ToString(CultureInfo.InvariantCulture)+".txt");File.WriteAllText(marker,socket,new UTF8Encoding(false));for(int attempt=0;attempt<500;attempt++){if(PortReusable(port))return;Thread.Sleep(10);}throw new IOException("held private adb server did not release endpoint before official auto-start");}
 static int ReplacementServer(string[] raw){int port;if(raw.Length!=3||raw[0]!="--official-auto-start"||!SocketPort(raw[1],out port)||(raw[2]!="direct_auto_start_escape"&&raw[2]!="t0_auto_start_escape"))return 82;string tuple=raw[2]+"\u001f"+port.ToString(CultureInfo.InvariantCulture)+"\u001f"+Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);Evidence("adb-auto-start-child-entry.log",tuple);TcpListener listener=new TcpListener(IPAddress.Loopback,port);listener.Server.ExclusiveAddressUse=true;listener.Server.SetSocketOption(SocketOptionLevel.Socket,SocketOptionName.ReuseAddress,false);try{listener.Start(1);Evidence("adb-auto-start-listener.log",tuple);while(true)Thread.Sleep(1000);}finally{listener.Stop();}}
 static bool ShouldOfficialAutoStart(string scenario,string[] command){if(scenario=="direct_auto_start_escape")return command.Length==1&&command[0]=="devices";if(scenario=="t0_auto_start_escape")return command.Length==5&&command[0]=="-s"&&command[1]=="FAKE123"&&command[2]=="shell"&&command[3]=="getprop"&&command[4]=="ro.product.brand";return false;}
 static int AttemptOfficialAutoStart(string scenario,int port){StopHeldServer(port);string tuple=scenario+"\u001f"+port.ToString(CultureInfo.InvariantCulture)+"\u001f"+Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);Evidence("adb-auto-start-attempt.log",tuple);string executable=Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);StringBuilder commandLine=new StringBuilder("\""+executable+"\" --official-auto-start \""+Socket(port)+"\" \""+scenario+"\"");STARTUPINFO startup=new STARTUPINFO();startup.cb=Marshal.SizeOf(typeof(STARTUPINFO));PROCESS_INFORMATION replacement;if(!CreateProcessW(executable,commandLine,IntPtr.Zero,IntPtr.Zero,false,0x00000008,IntPtr.Zero,Path.GetDirectoryName(executable),ref startup,out replacement))throw new Win32Exception(Marshal.GetLastWin32Error(),"official DETACHED_PROCESS auto-start was blocked");CloseHandle(replacement.hThread);CloseHandle(replacement.hProcess);Evidence("adb-auto-start-command-side-effect.log",tuple);return 98;}
 static int Server(string[] raw){int port;string listenSocket=raw.Length>1?raw[1]:null;if(raw.Length!=4||raw[0]!="-L"||raw[2]!="server"||raw[3]!="nodaemon"||!ListenSocketPort(listenSocket,out port)){Rejected(raw,"server-listen-endpoint");return 80;}string socket=Socket(port);if(Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET")!=socket){Rejected(raw,"server-environment-endpoint");return 80;}string marker=Path.Combine(S(),"adb-server-stop-"+port.ToString(CultureInfo.InvariantCulture)+".txt");if(File.Exists(marker))File.Delete(marker);int pid=Process.GetCurrentProcess().Id;Record(raw,raw,socket);File.AppendAllText(Path.Combine(S(),"adb-server-start.log"),port.ToString(CultureInfo.InvariantCulture)+"\n",new UTF8Encoding(false));Evidence("adb-server-pid.log",port.ToString(CultureInfo.InvariantCulture)+"\u001f"+pid.ToString(CultureInfo.InvariantCulture));if(Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO")=="early_server_fast_exit"){Console.Error.Write("fatal: early-server-sensitive-canary FAKE123 n-private-canary-early-adb");File.AppendAllText(Path.Combine(S(),"adb-server-exit.log"),port.ToString(CultureInfo.InvariantCulture)+"\n",new UTF8Encoding(false));Evidence("adb-server-exit-pid.log",port.ToString(CultureInfo.InvariantCulture)+"\u001f"+pid.ToString(CultureInfo.InvariantCulture));return 86;}TcpListener listener=new TcpListener(IPAddress.Loopback,port);listener.Server.ExclusiveAddressUse=true;listener.Server.SetSocketOption(SocketOptionLevel.Socket,SocketOptionName.ReuseAddress,false);try{listener.Start(1);while(true){if(File.Exists(marker)){string value=null;try{value=File.ReadAllText(marker,Encoding.UTF8);}catch(IOException){}if(value==socket){File.Delete(marker);break;}}Thread.Sleep(10);}}finally{listener.Stop();}File.AppendAllText(Path.Combine(S(),"adb-server-exit.log"),port.ToString(CultureInfo.InvariantCulture)+"\n",new UTF8Encoding(false));Evidence("adb-server-exit-pid.log",port.ToString(CultureInfo.InvariantCulture)+"\u001f"+pid.ToString(CultureInfo.InvariantCulture));return 0;}
 static void Out(string v){Console.OutputEncoding=new UTF8Encoding(false);Console.Out.Write(v);}
 static string Read(string n){return File.ReadAllText(Path.Combine(S(),n),Encoding.UTF8).Trim();}
 static void Log(string[] a){string state=S(),executable=Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName);File.AppendAllText(Path.Combine(state,"adb.log"),string.Join("\u001f",a)+"\n",new UTF8Encoding(false));File.AppendAllText(Path.Combine(state,"adb-executable.log"),executable+"\u001f"+Hash(File.ReadAllBytes(executable))+"\n",new UTF8Encoding(false));}
 static void ControlOut(string v){File.AppendAllText(Path.Combine(S(),"control-transcript.log"),v+"\n",new UTF8Encoding(false));Out(v);}
 static string Hash(byte[] b){using(var h=SHA256.Create())return "sha256:"+BitConverter.ToString(h.ComputeHash(b)).Replace("-","").ToLowerInvariant();}
 static string Control(string run,string state,long gen,int c1,int c2,string tokens,string flight,string reason){
  string commit=Read("commit.txt"),artifact=Read("artifact.txt"),challenge=Read("challenge.txt");bool ok=state=="ready_c1"||state=="capturing_c1"||state=="ready_c2"||state=="capturing_c2"||state=="complete";
  string next=state=="ready_c1"?"capture_c1":state=="ready_c2"?"capture_c2":state=="complete"?"read_result":(state.StartsWith("capturing")?"wait":"none");
  return "{\"schema\":\"tablet-c1b-control/v1\",\"ok\":"+(ok?"true":"false")+",\"run_id\":\""+run+"\",\"generation\":"+gen+",\"state\":\""+state+"\",\"next\":\""+next+"\",\"reason_code\":"+(reason==null?"null":"\""+reason+"\"")+",\"in_flight_token\":"+(flight==null?"null":"\""+flight+"\"")+",\"c1_requests_accepted\":"+c1+",\"c2_requests_accepted\":"+c2+",\"committed_tokens\":"+tokens+",\"recapture_count\":0,\"expected_title_hash\":\"sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c\",\"producer_commit_sha\":\""+commit+"\",\"producer_artifact_sha256\":\""+artifact+"\",\"provider\":{\"authority\":\"dev.magina.gateway.tablet.c1b\",\"protocol_version\":\"1\",\"package_name\":\"dev.magina.gateway\",\"version_name\":\"0.1.0-m1a\",\"version_code\":1,\"embedded_git_head\":\""+commit+"\",\"build_challenge\":\""+challenge+"\",\"a11y_service_ready\":true}}";
 }
 static string Absent(string run,string reason){string commit=Read("commit.txt"),artifact=Read("artifact.txt");return Control(run,"aborted",0,0,0,"[]",null,"session_aborted").Replace("\"state\":\"aborted\"","\"state\":\"absent\"").Replace("\"reason_code\":\"session_aborted\"","\"reason_code\":\""+reason+"\"").Replace("\"expected_title_hash\":\"sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c\"","\"expected_title_hash\":null").Replace("\"producer_commit_sha\":\""+commit+"\"","\"producer_commit_sha\":null").Replace("\"producer_artifact_sha256\":\""+artifact+"\"","\"producer_artifact_sha256\":null");}
 static string Observation(string run){byte[] t0=File.ReadAllBytes(Path.Combine(S(),"t0.bin"));string t0raw=Encoding.UTF8.GetString(t0);string t0at=Regex.Match(t0raw,"\\\"captured_at_utc\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"").Groups[1].Value;DateTime now=DateTime.UtcNow;string c2=now.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"),c1=now.AddSeconds(-1).ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'");string x=File.ReadAllText(Path.Combine(S(),"observation-template.json"),Encoding.UTF8);
  x=x.Replace("tl1-c1b-fixture-real-shape",run).Replace("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c").Replace("\"offline_fixture\"","\"gateway_runtime_probe\"").Replace("\"source_kind\": \"gateway_runtime_probe\"","\"source_kind\": \"trusted_runtime\"").Replace("0000000000000000000000000000000000000000",Read("commit.txt")).Replace("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",Read("artifact.txt")).Replace("sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",Hash(t0)).Replace("2026-08-26T00:00:00.0000000Z",t0at).Replace("2026-08-26T00:00:01.0000000Z",c1).Replace("2026-08-26T00:00:02.0000000Z",c2);return x;
 }
  public static int Main(string[] raw){Console.OutputEncoding=new UTF8Encoding(false);if(raw.Length>0&&raw[0]=="--official-auto-start")return ReplacementServer(raw);if(raw.Length>0&&raw[0]=="-L")return Server(raw);string[] a;int port;if(!Client(raw,out a,out port)){Rejected(raw,"client-endpoint");return 81;}Record(a,raw,Socket(port));if(a.Length==1&&a[0]=="server-status"){File.AppendAllText(Path.Combine(S(),"adb-server-status.log"),port.ToString(CultureInfo.InvariantCulture)+"\n",new UTF8Encoding(false));if(Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO")=="early_status_client_exit"){Console.Error.Write("fatal: early-status-sensitive-canary FAKE123 n-private-canary-early-adb C:\\status-private\\adbkey");return 87;}string executable=Path.GetFullPath(Process.GetCurrentProcess().MainModule.FileName),state=S();Out("version: \"1.0.41\"\nbuild: \"37.0.1-13795120\"\nexecutable_absolute_path: \""+Proto(executable)+"\"\nlog_absolute_path: \""+Proto(Path.Combine(state,"adb.log"))+"\"\nos: \"windows\"\nkeystore_path: \""+Proto(Path.Combine(state,"adbkey"))+"\"\nknown_hosts_path: \""+Proto(Path.Combine(state,"adb_known_hosts.pb"))+"\"\nusb_backend: LIBADBUSB\nmdns_backend: LIBADBMDNS\nusb_backend_forced: false\nmdns_backend_forced: false\nburst_mode: false\nmdns_enabled: true\n");return 0;}if(a.Length==1&&a[0]=="kill-server"){File.AppendAllText(Path.Combine(S(),"adb-server-kill.log"),port.ToString(CultureInfo.InvariantCulture)+"\n",new UTF8Encoding(false));File.WriteAllText(Path.Combine(S(),"adb-server-stop-"+port.ToString(CultureInfo.InvariantCulture)+".txt"),Socket(port),new UTF8Encoding(false));return 0;}if(a.Length==1&&a[0]=="version"){Out("Android Debug Bridge version 1.0.41\r\nVersion 36.0.0-13206524\r\nInstalled as "+Process.GetCurrentProcess().MainModule.FileName+"\r\n");return 0;}string autoStartScenario=Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO");if(ShouldOfficialAutoStart(autoStartScenario,a))return AttemptOfficialAutoStart(autoStartScenario,port);if(a.Length==1&&a[0]=="devices"){Out("List of devices attached\r\nFAKE123\tdevice\r\n");return 0;}if(a.Length<3||a[0]!="-s"||a[1]!="FAKE123")return 90;
  string k=string.Join(" ",a,2,a.Length-2);if(k=="shell getprop ro.build.fingerprint"){Out("vivo/fixture/pa2553:16/BUILD/1:user/release-keys");return 0;}if(k=="shell cat /proc/sys/kernel/random/boot_id"){Out("01234567-89ab-cdef-0123-456789abcdef");return 0;}if(k=="shell settings get secure enabled_accessibility_services"){Out("dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService");return 0;}if(k=="shell dumpsys accessibility"){Out("Bound services: dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService");return 0;}if(a[2]=="install"){File.AppendAllText(Path.Combine(S(),"install.log"),"1\n");Out("Success");return 0;}if(k=="shell pm path dev.magina.gateway"){Out("package:/data/app/~~fixture/dev.magina.gateway-fixture/base.apk");return 0;}if(k=="shell dumpsys package dev.magina.gateway"){Out("versionCode=1 minSdk=30 targetSdk=36\nversionName=0.1.0-m1a");return 0;}if(a.Length==5&&a[2]=="exec-out"&&a[3]=="cat"){using(var o=Console.OpenStandardOutput())o.Write(File.ReadAllBytes(Path.Combine(S(),"apk.bin")),0,File.ReadAllBytes(Path.Combine(S(),"apk.bin")).Length);return 0;}
  if(a.Length==7&&a[3]=="content"){string uri=a[6].Trim('\'');string run=Regex.Match(uri,"/(?:t0|status|result|abort|capture/c1|capture/c2)/([^?]+)").Groups[1].Value;if(a[2]=="exec-in"){using(var m=new MemoryStream()){Console.OpenStandardInput().CopyTo(m);File.WriteAllBytes(Path.Combine(S(),"t0.bin"),m.ToArray());}File.WriteAllText(Path.Combine(S(),"run.txt"),run);File.WriteAllText(Path.Combine(S(),"commit.txt"),Regex.Match(uri,"producer_commit_sha=([0-9a-f]{40})").Groups[1].Value);File.WriteAllText(Path.Combine(S(),"artifact.txt"),Regex.Match(uri,"producer_artifact_sha256=(sha256:[0-9a-f]{64})").Groups[1].Value);return 0;}if(uri.Contains("/status/")){if(Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO")=="tamper"&&File.Exists(Path.Combine(S(),"tamper-"+run+".txt"))){ControlOut(Control(run,"capturing_c1",7,0,0,"[]","c1",null));return 0;}ControlOut(Control(run,"ready_c1",7,0,0,"[]",null,null));return 0;}if(uri.Contains("/capture/c1/")){File.AppendAllText(Path.Combine(S(),"c1.log"),"1\n");if(Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO")=="tamper"){File.WriteAllText(Path.Combine(S(),"tamper-"+run+".txt"),"1");ControlOut(Control(run,"capturing_c1",7,1,0,"[]","c1",null));return 0;}ControlOut(Control(run,"ready_c2",7,1,0,"[\"c1\"]",null,null));return 0;}if(uri.Contains("/capture/c2/")){File.AppendAllText(Path.Combine(S(),"c2.log"),"1\n");ControlOut(Control(run,"complete",7,1,1,"[\"c1\",\"c2\"]",null,null));return 0;}if(uri.Contains("/result/")){File.AppendAllText(Path.Combine(S(),"result.log"),"1\n");string scenario=Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO");if(scenario=="result_control"||scenario=="malformed_abort"){Out(Control(run,"complete",7,1,1,"[\"c1\",\"c2\"]",null,null));return 0;}Out(Observation(run));return 0;}if(uri.Contains("/abort/")){File.AppendAllText(Path.Combine(S(),"abort.log"),"1\n");string scenario=Environment.GetEnvironmentVariable("TL1_C1B_E2E_SCENARIO");if(scenario=="result_control"){Out(Control(run,"expired",7,1,1,"[\"c1\",\"c2\"]",null,"session_expired"));return 0;}if(scenario=="malformed_abort"){Out(Absent(run,"t0_pending"));return 0;}if(scenario=="tamper"){Out(Control(run,"aborted",7,1,0,"[]",null,"session_aborted"));return 0;}Out(Control(run,"aborted",7,0,0,"[]",null,"session_aborted"));return 0;}}
  if(k=="shell getprop ro.product.brand"||k=="shell getprop ro.product.manufacturer"){Out("vivo");return 0;}if(k=="shell getprop ro.product.model"){Out("FixturePad");return 0;}if(k=="shell getprop ro.product.name"||k=="shell getprop ro.product.device"){Out("fixture_pad");return 0;}if(k=="shell getprop ro.build.version.release"){Out("16");return 0;}if(k=="shell getprop ro.build.version.sdk"){Out("36");return 0;}if(k=="shell getprop ro.product.cpu.abilist"){Out("arm64-v8a,armeabi-v7a");return 0;}if(k=="shell wm size"){Out("Physical size: 1600x2560");return 0;}if(k=="shell wm density"){Out("Physical density: 320");return 0;}if(k=="shell dumpsys activity activities"){Out("mGlobalConfiguration={1.0 zh_CN sw800dp w800dp h1200dp}\ntopResumedActivity=ActivityRecord{abc u0 com.tencent.mm/.ui.LauncherUI t10}");return 0;}if(k=="shell dumpsys window windows"){Out("WINDOW MANAGER WINDOWS\n mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}\n Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:\n mDisplayId=0\n mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}\n mFrame=[0,0][2560,1600]\n mWindowingMode=fullscreen\n isOnScreen=true");return 0;}if(k=="shell dumpsys display"){Out("Display 0: rotation=1");return 0;}if(k=="shell dumpsys power"){Out("mWakefulness=Awake");return 0;}if(k=="shell dumpsys window policy"){Out("mShowingLockscreen=false");return 0;}if(k=="shell settings get global zen_mode"){Out("0");return 0;}if(k=="shell settings get secure default_input_method"){Out("dev.magina.gateway/.ime.GatewayIme");return 0;}if(k=="shell dumpsys input_method"){Out("mInputShown=false\nmImeWindowVis=0x0");return 0;}if(k=="shell am get-config"){Out("config: zh-rCN-ldltr-sw800dp-w800dp-h1200dp-normal-long");return 0;}return 97;
 }
}
'@
    $fakeCs=Join-Path $root 'fake-adb.cs';$fakeExe=Join-Path $sdk 'platform-tools\adb.exe';[IO.File]::WriteAllText($fakeCs,$fakeSource,[Text.UTF8Encoding]::new($false));$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe';if(-not(Test-Path $csc)){$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'};&$csc /nologo /target:exe "/out:$fakeExe" $fakeCs;if($LASTEXITCODE-ne0){throw 'E2E fake adb compile failed'}
    $fakeAapt2=Join-Path $sdk 'build-tools\35.0.0\aapt2.exe';Copy-Item -LiteralPath $fakeExe -Destination $fakeAapt2
    [void](Run-Git $repo @('config','user.email','c1b-e2e@invalid.local'));[void](Run-Git $repo @('config','user.name','C1b E2E'));[void](Run-Git $repo @('config','core.autocrlf','true'));[void](Run-Git $repo @('add','-f','--','.'));[void](Run-Git $repo @('commit','-q','-m','c1b e2e synthetic clean head'));Assert-SyntheticGitHeadClean $repo;$head=(Run-Git $repo @('rev-parse','HEAD')).Trim()
    $environment=@{TL1_C1B_E2E_STATE=$state;ANDROID_HOME=$sdk;ANDROID_SDK_ROOT=$sdk;JAVA_HOME=$javaHome;TL1_C1B_GRADLE_HOME=$gradleHome;LOCALAPPDATA=$localAppData;SYSTEMDRIVE=$env:SystemDrive;SYSTEMROOT=$env:SystemRoot;WINDIR=$env:WINDIR;TEMP=$env:TEMP;TMP=$env:TMP;PATH=[Environment]::SystemDirectory;TL1_C1B_E2E_SCENARIO='success'}
    $endpointProbes=@(
        [pscustomobject]@{Label='missing prefix';Socket='tcp:127.0.0.1:55000';Arguments=@('devices')},
        [pscustomobject]@{Label='default 5037';Socket='tcp:127.0.0.1:5037';Arguments=@('-H','127.0.0.1','-P','5037','devices')},
        [pscustomobject]@{Label='non-loopback host';Socket='tcp:127.0.0.1:55000';Arguments=@('-H','localhost','-P','55000','devices')},
        [pscustomobject]@{Label='socket format drift';Socket='tcp://127.0.0.1:55000';Arguments=@('-H','127.0.0.1','-P','55000','devices')},
        [pscustomobject]@{Label='environment/argument port drift';Socket='tcp:127.0.0.1:55001';Arguments=@('-H','127.0.0.1','-P','55000','devices')},
        [pscustomobject]@{Label='missing socket environment';Socket=$null;Arguments=@('-H','127.0.0.1','-P','55000','devices')},
        [pscustomobject]@{Label='low out-of-range port';Socket='tcp:127.0.0.1:49151';Arguments=@('-H','127.0.0.1','-P','49151','devices')},
        [pscustomobject]@{Label='high out-of-range port';Socket='tcp:127.0.0.1:65536';Arguments=@('-H','127.0.0.1','-P','65536','devices')}
    )
    foreach($probe in $endpointProbes){$probeEnvironment=@{TL1_C1B_E2E_STATE=$state;SYSTEMROOT=$env:SystemRoot;WINDIR=$env:WINDIR;TEMP=$env:TEMP;TMP=$env:TMP};if($null-ne$probe.Socket){$probeEnvironment.ADB_SERVER_SOCKET=$probe.Socket};$probeResult=Invoke-TL1C1aProcess -FilePath $fakeExe -Arguments $probe.Arguments -Operation "C1b fake adb rejects $($probe.Label)" -Environment $probeEnvironment -ClearEnvironment -TimeoutSec 10 -AllowFailure;Check ($probeResult.ExitCode-ne0) "fake adb accepted $($probe.Label)"}
    $rejectedEndpointLines=[IO.File]::ReadAllLines((Join-Path $state 'adb-rejected.log'),[Text.UTF8Encoding]::new($false,$true));Check ($rejectedEndpointLines.Count-eq$endpointProbes.Count) 'fake adb rejected-endpoint evidence count drift';Check (@($rejectedEndpointLines|Where-Object{$_-cmatch'(^|\x1f)(?:tcp:127\.0\.0\.1:)?5037(?:\x1f|$)'}).Count-gt0) 'fake adb default-5037 rejection evidence missing';$serverSnapshot=Get-PrivateAdbServerSnapshot $state;foreach($name in @('Start','Status','Kill','Exit')){Check ($serverSnapshot.$name.Count-eq0) 'fake adb endpoint negatives unexpectedly started a server'}
    $runner=Join-Path $repo 'scripts\run-tablet-layout-c1b.ps1';$outsideAdb=Join-Path $root 'arbitrary-adb.exe';Copy-Item -LiteralPath $fakeExe -Destination $outsideAdb
    $outside=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$outsideAdb,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner rejects non-SDK adb E2E' -Environment $environment -ClearEnvironment -TimeoutSec 30 -AllowFailure;Check ($outside.ExitCode-ne0) 'runner accepted arbitrary executable outside SDK';Check (-not(Test-Path (Join-Path $state 'install.log'))) 'non-SDK adb rejection reached install';$outsideSnapshot=Get-PrivateAdbServerSnapshot $state;foreach($name in @('Start','Status','Kill','Exit')){Check ($outsideSnapshot.$name.Count-eq$serverSnapshot.$name.Count) 'non-SDK adb rejection unexpectedly started a private server'}
    $success=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner fake-ADB success E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure
    if($success.ExitCode-ne0){throw "success runner exit=$($success.ExitCode) stdout=$($success.Text) stderr=$($success.Stderr)"}
    $serverSnapshot=Assert-PrivateAdbServerScenario $serverSnapshot $state 'success'
    $sourceBuildRoot=Join-Path $repo 'app\tablet-c1b-probe\build';Check (-not(Test-Path -LiteralPath $sourceBuildRoot)) 'runner cleanup retained source build root after success'
    $runDirs=@(Get-ChildItem (Join-Path $repo 'docs\runs\evidence') -Directory|Where-Object Name -like 'tl1-c1b-*');Check ($runDirs.Count-eq1) 'success E2E run dir count';$successDir=Join-Path $runDirs[0].FullName 'tablet-layout-c1b';$sidecarPath=Join-Path $successDir 'tablet-layout-c1b-sidecar-v1.json';Check (Test-Path $sidecarPath) 'success sidecar missing'
    foreach($name in @('upstream-t0-v5.json','tablet-layout-observation-c1b-v1.json','tablet-layout-observation-validation-c1b-v1.json','tablet-c1b-read-only-artifact-proof-v1.json','tablet-c1b-probe-debug.apk','tablet-c1b-probe-release-unsigned.apk','tablet-c1b-probe-debug-merged-AndroidManifest.xml','tablet-c1b-probe-release-merged-AndroidManifest.xml','tablet-layout-c1b-sidecar-v1.json')){Check (Test-Path (Join-Path $successDir $name)) "success artifact missing $name"};Check (Test-Path (Join-Path $runDirs[0].FullName 'tablet-profile.json')) 'fresh T0 original missing'
    $sidecar=Get-Content $sidecarPath -Raw|ConvertFrom-Json -DateKind String;Assert-TL1C1bSidecarCrossBindings $sidecar;Check ((Get-Content $sidecarPath -Raw)|Test-Json -SchemaFile (Join-Path $repo 'docs\contracts\tablet-layout-c1b-sidecar-v1.schema.json')) 'success sidecar schema';$expectedBuildEnvironment=Get-Content -LiteralPath (Join-Path $repo 'scripts\tests\fixtures\tablet-layout-c1b-build-environment.json') -Raw|ConvertFrom-Json -Depth 30 -DateKind String;$catalogSha=Assert-IndependentRepositoryCatalog $repo (Join-Path $state 'build-environment-input-catalog.txt') 42;$expectedBuildEnvironment.repository_inputs.file_count=[long]42;$expectedBuildEnvironment.repository_inputs.catalog_sha256=$catalogSha;Check (($sidecar.build_environment|ConvertTo-Json -Depth 20 -Compress)-ceq($expectedBuildEnvironment|ConvertTo-Json -Depth 20 -Compress)) 'success build_environment binding drift'
    $implementationTamper=($sidecar|ConvertTo-Json -Depth 40 -Compress)|ConvertFrom-Json -Depth 40 -DateKind String;$implementationTamper.implementation_hashes.runner_sha256=if($sidecar.implementation_hashes.runner_sha256-ceq('sha256:'+('a'*64))){'sha256:'+('b'*64)}else{'sha256:'+('a'*64)};Check ($implementationTamper.build_environment.repository_inputs.catalog_sha256-ceq$catalogSha) 'implementation tamper changed build-environment catalog';$implementationTamperFailure=$null;try{Assert-TL1C1bSidecarCrossBindings $implementationTamper}catch{$implementationTamperFailure=$_};Check ($null-ne$implementationTamperFailure) 'validator accepted changed implementation hash with unchanged catalog';Check ($sidecar.capture.status_poll_count-eq1) 'status count'
    $adbLines=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false));$execInLines=@($adbLines|Where-Object{$_-cmatch("^-s$([char]0x1f)FAKE123$([char]0x1f)exec-in$([char]0x1f)content$([char]0x1f)write$([char]0x1f)--uri$([char]0x1f)")});Check ($execInLines.Count-eq1) 'T0 exec-in count success';Check (@($adbLines|Where-Object{$_-ceq'version'}).Count-eq0) 'synthetic Authenticode override unexpectedly executed fake adb version';$installLines=@($adbLines|Where-Object{$_-cmatch("^-s$([char]0x1f)FAKE123$([char]0x1f)install$([char]0x1f)-r$([char]0x1f)-t$([char]0x1f)")});Check ($installLines.Count-eq1-and$installLines[0]-cmatch'[\\/]app[\\/]tablet-c1b-probe[\\/]build[\\/]outputs[\\/]apk[\\/]debug[\\/]tablet-c1b-probe-debug\.apk$') 'install did not use dedicated debug APK'
    $successAdbExecutions=@(Read-AdbExecutableEvidence (Join-Path $state 'adb-executable.log'));Check ($successAdbExecutions.Count-eq$adbLines.Count-and$successAdbExecutions.Count-gt0) 'success adb executable/argv evidence count drift';$sourceAdbHash=Get-IndependentFileSha256 $fakeExe
    foreach($execution in $successAdbExecutions){$relativeExecutionPath=[IO.Path]::GetRelativePath($state,$execution.Path).Replace('\','/');Check (-not[StringComparer]::OrdinalIgnoreCase.Equals($execution.Path,$fakeExe)-and$relativeExecutionPath-cmatch'^build-environment-workspace-[0-9]+/android-sdk/platform-tools/adb\.exe$'-and$execution.Sha256-ceq$sourceAdbHash) 'success adb execution did not come from the isolated SDK copy'}
    $successAdbPaths=[string[]]@($successAdbExecutions.Path|Sort-Object -Unique);Check ($successAdbPaths.Count-eq1) 'success runner used multiple adb executable paths';$successIsolatedAdbPath=$successAdbPaths[0];Check (-not(Test-Path -LiteralPath $successIsolatedAdbPath)-and@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0) 'success build-environment Close retained isolated SDK workspace'
    $originalT0=Join-Path $runDirs[0].FullName 'tablet-profile.json';$forwardedT0=Join-Path $state 't0.bin';$originalBytes=[IO.File]::ReadAllBytes($originalT0);$forwardedBytes=[IO.File]::ReadAllBytes($forwardedT0);try{Check ([Convert]::ToHexString($originalBytes)-ceq[Convert]::ToHexString($forwardedBytes)) 'T0 exec-in stdin bytes drift'}finally{if($originalBytes.Length){[Array]::Clear($originalBytes,0,$originalBytes.Length)};if($forwardedBytes.Length){[Array]::Clear($forwardedBytes,0,$forwardedBytes.Length)}}
    $transcriptLines=[IO.File]::ReadAllLines((Join-Path $state 'control-transcript.log'),[Text.UTF8Encoding]::new($false));$transcriptBytes=[Text.UTF8Encoding]::new($false).GetBytes($transcriptLines-join"`n");try{$independentTranscriptSha=Get-IndependentSha256 $transcriptBytes}finally{if($transcriptBytes.Length){[Array]::Clear($transcriptBytes,0,$transcriptBytes.Length)}};Check ($sidecar.provider.control_transcript_sha256-ceq$independentTranscriptSha) 'control transcript independent hash mismatch'
    Assert-TL1C1bExactObjectKeys $sidecar.artifacts @('upstream_t0','observation','validation','artifact_proof','debug_apk','release_apk','debug_merged_manifest','release_merged_manifest') 'success sidecar/artifacts'
    foreach($artifactName in @('upstream_t0','observation','validation','artifact_proof','debug_apk','release_apk','debug_merged_manifest','release_merged_manifest')){$artifact=$sidecar.artifacts.$artifactName;$artifactPath=Join-Path $successDir $artifact.relative_path;Check ((Get-IndependentFileSha256 $artifactPath)-ceq$artifact.sha256) "artifact independent hash mismatch: $artifactName"}
    $isolatedExecutableSha=$successAdbExecutions[0].Sha256;Check (@($successAdbExecutions|Where-Object Sha256 -cne $isolatedExecutableSha).Count-eq0-and$sidecar.transport.executable_sha256_before-ceq$isolatedExecutableSha-and$sidecar.transport.executable_sha256_after-ceq$isolatedExecutableSha) 'sidecar adb executable hash is not bound to the executed isolated SDK copy';$isolatedVersionOutput="Android Debug Bridge version 1.0.41`r`nVersion 36.0.0-13206524`r`nInstalled as $successIsolatedAdbPath`r`n";$isolatedVersionSha=Get-IndependentTextSha256 $isolatedVersionOutput;Check ($sidecar.transport.version_output_sha256_before-ceq$isolatedVersionSha-and$sidecar.transport.version_output_sha256_after-ceq$isolatedVersionSha) 'sidecar adb version hash is not bound to the executed isolated SDK path';Check ($sidecar.transport.trust_root-ceq'android_sdk_platform_tools'-and$sidecar.transport.canonical_relative_path-ceq'platform-tools/adb.exe'-and$sidecar.transport.installed_as_canonical) 'adb canonical trust binding missing';Check ($sidecar.transport.signature_status-ceq'Valid'-and$sidecar.transport.signature_subject-ceq$script:TL1C1bGoogleAdbSignerSubject-and$sidecar.transport.signature_certificate_sha256_before-ceq('sha256:'+('d'*64))-and$sidecar.transport.signature_certificate_sha256_after-ceq$sidecar.transport.signature_certificate_sha256_before) 'adb Authenticode sidecar binding missing'
    $debugApk=Join-Path $successDir $sidecar.artifacts.debug_apk.relative_path;$releaseApk=Join-Path $successDir $sidecar.artifacts.release_apk.relative_path;$proofPath=Join-Path $successDir $sidecar.artifacts.artifact_proof.relative_path
    $debugMergedManifest=Join-Path $successDir $sidecar.artifacts.debug_merged_manifest.relative_path;$releaseMergedManifest=Join-Path $successDir $sidecar.artifacts.release_merged_manifest.relative_path
    Check (Test-Path -LiteralPath $debugApk -PathType Leaf) 'archived dedicated debug APK missing';Check (Test-Path -LiteralPath $releaseApk -PathType Leaf) 'archived dedicated release APK missing';Check (Test-Path -LiteralPath $proofPath -PathType Leaf) 'archived dedicated artifact proof missing';Check (-not(Test-Path -LiteralPath (Join-Path $repo 'app\gateway\build\outputs\apk\debug\gateway-debug.apk'))) 'runner built legacy gateway APK'
    Check ((Get-IndependentFileSha256 $debugApk)-ceq$sidecar.apk.local_sha256_before-and$sidecar.read_only_proof.debug_apk_sha256-ceq$sidecar.apk.local_sha256_before) 'dedicated debug APK sidecar binding mismatch';Check ((Get-IndependentFileSha256 $releaseApk)-ceq$sidecar.read_only_proof.release_apk_sha256) 'dedicated release APK sidecar binding mismatch';Check ((Get-IndependentFileSha256 $proofPath)-ceq$sidecar.read_only_proof.artifact_proof_sha256) 'artifact proof sidecar binding mismatch'
    $proofRaw=Get-Content -LiteralPath $proofPath -Raw;Check ($proofRaw|Test-Json -SchemaFile (Join-Path $repo 'docs\contracts\tablet-c1b-read-only-artifact-proof-v1.schema.json')) 'artifact proof schema';$proof=$proofRaw|ConvertFrom-Json -DateKind String;Check ($proof.policy-ceq'tl1-c1b-read-only/v2'-and$proof.git_sha-ceq$head-and$proof.forbidden_match_count-eq0-and$proof.manifest_mutating_capability_count-eq0-and$proof.manifest_extra_component_count-eq0-and$proof.dependency_allowlist.passed) 'artifact proof security conclusions drift'
    $expectedBuildInputs=[string[]]@('app/build.gradle.kts','app/gradle.properties','app/gradle/verification-metadata.xml','app/gradle/wrapper/gradle-wrapper.jar','app/gradle/wrapper/gradle-wrapper.properties','app/gradlew.bat','app/settings.gradle.kts','app/tablet-c1b-probe/build.gradle.kts','app/tablet-c1b-probe/src/main/AndroidManifest.xml','app/tablet-c1b-probe/src/main/res/values/strings.xml','app/tablet-c1b-probe/src/main/res/xml/a11y_config.xml');[Array]::Sort($expectedBuildInputs,[StringComparer]::Ordinal);$actualBuildInputs=[string[]]@($proof.scanned_build_inputs|ForEach-Object{[string]$_.relative_path});Check ($actualBuildInputs.Count-eq11-and($actualBuildInputs-join"`n")-ceq($expectedBuildInputs-join"`n")) 'artifact proof scanned_build_inputs is not the exact 11-file closure'
    Assert-TL1C1bExactObjectKeys $proof.axml_parser @('tool','build_tools_version','aapt2_relative_path','aapt2_sha256') 'artifact proof/axml_parser';Check ($proof.axml_parser.tool-ceq'aapt2'-and$proof.axml_parser.build_tools_version-ceq'35.0.0'-and$proof.axml_parser.aapt2_relative_path-ceq'build-tools/35.0.0/aapt2.exe'-and$proof.axml_parser.aapt2_sha256-ceq'sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564') 'artifact proof trusted aapt2 binding drift'
    $debugZip=Get-IndependentApkProof $debugApk;$releaseZip=Get-IndependentApkProof $releaseApk;$debugVariant=@($proof.variants|Where-Object name -ceq 'debug')[0];$releaseVariant=@($proof.variants|Where-Object name -ceq 'release')[0]
    Check ($debugZip.dex_entries.Count-eq6-and$releaseZip.dex_entries.Count-eq1) 'synthetic multidex fixture shape drift';for($index=0;$index-lt$debugZip.dex_entries.Count;$index++){Check ($debugVariant.dex_entries[$index].relative_path-ceq$debugZip.dex_entries[$index].relative_path-and$debugVariant.dex_entries[$index].sha256-ceq$debugZip.dex_entries[$index].sha256) "debug DEX proof mismatch $index"};Check ($releaseVariant.dex_entries[0].relative_path-ceq$releaseZip.dex_entries[0].relative_path-and$releaseVariant.dex_entries[0].sha256-ceq$releaseZip.dex_entries[0].sha256) 'release DEX proof mismatch'
    Check ($sidecar.read_only_proof.debug_dex_entry_count-eq6-and$sidecar.read_only_proof.release_dex_entry_count-eq1-and$sidecar.read_only_proof.debug_dex_sha256-ceq$debugZip.dex_entries[0].sha256-and$sidecar.read_only_proof.release_dex_sha256-ceq$releaseZip.dex_entries[0].sha256-and$sidecar.read_only_proof.debug_dex_catalog_sha256-ceq$debugZip.dex_catalog_sha256-and$sidecar.read_only_proof.release_dex_catalog_sha256-ceq$releaseZip.dex_catalog_sha256) 'sidecar multidex proof mismatch'
    Check ($debugVariant.packaged_manifest_sha256-ceq$debugZip.packaged_manifest_sha256-and$sidecar.read_only_proof.debug_packaged_manifest_sha256-ceq$debugZip.packaged_manifest_sha256-and$releaseVariant.packaged_manifest_sha256-ceq$releaseZip.packaged_manifest_sha256-and$sidecar.read_only_proof.release_packaged_manifest_sha256-ceq$releaseZip.packaged_manifest_sha256) 'packaged manifest proof mismatch';Check ($debugVariant.packaged_manifest_exact_tree_verified-and$debugVariant.packaged_a11y_exact_tree_verified-and$releaseVariant.packaged_manifest_exact_tree_verified-and$releaseVariant.packaged_a11y_exact_tree_verified-and$sidecar.read_only_proof.packaged_axml_exact_verified) 'packaged AXML exact-tree proof missing';Check ($sidecar.read_only_proof.debug_packaged_manifest_axml_dump_sha256-ceq$debugVariant.packaged_manifest_axml_dump_sha256-and$sidecar.read_only_proof.debug_packaged_a11y_axml_dump_sha256-ceq$debugVariant.packaged_a11y_axml_dump_sha256-and$sidecar.read_only_proof.release_packaged_manifest_axml_dump_sha256-ceq$releaseVariant.packaged_manifest_axml_dump_sha256-and$sidecar.read_only_proof.release_packaged_a11y_axml_dump_sha256-ceq$releaseVariant.packaged_a11y_axml_dump_sha256) 'host AXML dump hashes are not bound to artifact proof'
    Assert-TL1C1bExactObjectKeys $sidecar.read_only_proof.axml_parser @('schema','trust_root','build_tools_version','canonical_relative_path','sdk_roots_equal','executable_sha256','signature_status','signature_subject','signature_certificate_sha256') 'sidecar/read_only_proof/axml_parser';Check ($sidecar.read_only_proof.axml_parser.schema-ceq'tablet-layout-c1b-aapt2-trust/v1'-and$sidecar.read_only_proof.axml_parser.trust_root-ceq'android_sdk_build_tools'-and$sidecar.read_only_proof.axml_parser.build_tools_version-ceq$proof.axml_parser.build_tools_version-and$sidecar.read_only_proof.axml_parser.canonical_relative_path-ceq$proof.axml_parser.aapt2_relative_path-and$sidecar.read_only_proof.axml_parser.sdk_roots_equal-and$sidecar.read_only_proof.axml_parser.executable_sha256-ceq$proof.axml_parser.aapt2_sha256-and$sidecar.read_only_proof.axml_parser.signature_status-ceq'Valid'-and$sidecar.read_only_proof.axml_parser.signature_subject-ceq'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'-and$sidecar.read_only_proof.axml_parser.signature_certificate_sha256-ceq'sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c') 'sidecar trusted aapt2 binding mismatch'
    $implementationInputs=[ordered]@{c1b_aapt2_library_sha256='scripts/lib/tablet-layout-c1b-aapt2.ps1';c1b_adb_server_library_sha256='scripts/lib/tablet-layout-c1b-adb-server.ps1';c1b_build_environment_library_sha256='scripts/lib/tablet-layout-c1b-build-env.ps1';dispatch_lock_library_sha256='scripts/lib/dispatch-lock.ps1';android_layout_probe_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt';android_layout_probe_model_sha256='app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt';app_gradlew_bat_sha256='app/gradlew.bat';app_gradle_wrapper_jar_sha256='app/gradle/wrapper/gradle-wrapper.jar';app_gradle_wrapper_properties_sha256='app/gradle/wrapper/gradle-wrapper.properties';app_gradle_verification_metadata_sha256='app/gradle/verification-metadata.xml'};foreach($entry in $implementationInputs.GetEnumerator()){Check ($sidecar.implementation_hashes.$($entry.Key)-ceq(Get-IndependentFileSha256 (Join-Path $repo ($entry.Value-replace'/','\')))) "implementation hash mismatch: $($entry.Key)"}
    $archiveExpectations=[ordered]@{artifact_proof=[pscustomobject]@{relative='tablet-c1b-read-only-artifact-proof-v1.json';sha256=$sidecar.read_only_proof.artifact_proof_sha256};debug_apk=[pscustomobject]@{relative='tablet-c1b-probe-debug.apk';sha256=$sidecar.read_only_proof.debug_apk_sha256};release_apk=[pscustomobject]@{relative='tablet-c1b-probe-release-unsigned.apk';sha256=$sidecar.read_only_proof.release_apk_sha256};debug_merged_manifest=[pscustomobject]@{relative='tablet-c1b-probe-debug-merged-AndroidManifest.xml';sha256=$sidecar.read_only_proof.debug_merged_manifest_sha256};release_merged_manifest=[pscustomobject]@{relative='tablet-c1b-probe-release-merged-AndroidManifest.xml';sha256=$sidecar.read_only_proof.release_merged_manifest_sha256}};foreach($entry in $archiveExpectations.GetEnumerator()){$artifact=$sidecar.artifacts.$($entry.Key);$archived=Join-Path $successDir $artifact.relative_path;Check ($artifact.relative_path-ceq$entry.Value.relative-and$artifact.sha256-ceq$entry.Value.sha256-and(Get-IndependentFileSha256 $archived)-ceq$entry.Value.sha256) "archived evidence binding mismatch: $($entry.Key)"};Check ($sidecar.apk.signer_certificate_sha256-ceq('sha256:'+('c'*64))) 'archived debug APK signer fixture binding drift'
    $dependencyLines=@($proof.dependency_allowlist.resolved_artifacts|ForEach-Object{"$($_.coordinate)=$($_.artifact_sha256)"});Check ($sidecar.read_only_proof.dependency_artifact_catalog_sha256-ceq(Get-IndependentTextSha256 ($dependencyLines-join"`n"))) 'dependency artifact catalog mismatch'
    $zeroReadOnlyNames=@('display_screenshot_call_count','window_screenshot_call_count','ocr_invocation_count','action_call_count','gesture_call_count','input_call_count','settings_mutation_count','target_app_start_count','mcp_call_count','dispatch_call_count');Check ($sidecar.static_read_only_policy_version-ceq'tl1-c1b-read-only/v2'-and$sidecar.read_only_counts.a11y_frame_capture_count-eq2-and$sidecar.read_only_counts.recapture_count-eq0-and@($zeroReadOnlyNames|Where-Object{[long]$sidecar.read_only_counts.$_-ne0}).Count-eq0) 'derived read-only counts drift';Check ($sidecar.read_only_proof.artifact_module-ceq':tablet-c1b-probe'-and$sidecar.read_only_proof.host_forbidden_command_count-eq0-and$sidecar.read_only_proof.artifact_forbidden_match_count-eq0-and$sidecar.read_only_proof.manifest_mutating_capability_count-eq0-and$sidecar.read_only_proof.manifest_extra_component_count-eq0-and$sidecar.read_only_proof.dependency_allowlist_verified) 'read-only proof binding drift'
    Check (@(Get-Content (Join-Path $state 'install.log')).Count-eq1) 'install count success';Check (@(Get-Content (Join-Path $state 'c1.log')).Count-eq1) 'c1 count success';Check (@(Get-Content (Join-Path $state 'c2.log')).Count-eq1) 'c2 count success';Check (@(Get-Content (Join-Path $state 'result.log')).Count-eq1) 'result count success';Check (-not(Test-Path (Join-Path $state 'abort.log'))) 'abort occurred on success'

    $knownRuns=@($runDirs.FullName);$beforeResultC1=@(Get-Content (Join-Path $state 'c1.log')).Count;$beforeResultC2=@(Get-Content (Join-Path $state 'c2.log')).Count;$beforeResultReads=@(Get-Content (Join-Path $state 'result.log')).Count;$environment.TL1_C1B_E2E_SCENARIO='result_control';$resultControl=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner fake-ADB result-control E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure;Check ($resultControl.ExitCode-ne0) 'result control runner succeeded'
    $serverSnapshot=Assert-PrivateAdbServerScenario $serverSnapshot $state 'result-control'
    $afterResult=@(Get-ChildItem (Join-Path $repo 'docs\runs\evidence') -Directory|Where-Object Name -like 'tl1-c1b-*');Check ($afterResult.Count-eq$knownRuns.Count+1) 'result control run dir missing';$resultFailureRoot=($afterResult|Where-Object{$knownRuns-cnotcontains$_.FullName})[0].FullName;$resultFailureDir=Join-Path $resultFailureRoot 'tablet-layout-c1b';$resultFailurePath=Join-Path $resultFailureDir 'tablet-layout-c1b-failure.json';Check (Test-Path $resultFailurePath) 'result control failure evidence missing';$resultFailure=Read-FailureEvidenceStrict $resultFailurePath;Check ($resultFailure.status-ceq'failed'-and$resultFailure.cleanup-ceq'completed'-and-not$resultFailure.runtime_origin_verified-and-not$resultFailure.runtime_evidence) 'result control failure evidence/cleanup drift';Check (-not(Test-Path (Join-Path $resultFailureDir 'tablet-layout-c1b-sidecar-v1.json'))) 'result control forged success sidecar';Check (@(Get-Content (Join-Path $state 'c1.log')).Count-eq$beforeResultC1+1) 'result control c1 count';Check (@(Get-Content (Join-Path $state 'c2.log')).Count-eq$beforeResultC2+1) 'result control c2 count';Check (@(Get-Content (Join-Path $state 'result.log')).Count-eq$beforeResultReads+1) 'result control result count';Check (@(Get-Content (Join-Path $state 'abort.log')).Count-eq1) 'result control abort count'

    $knownRuns=@($afterResult.FullName);$beforeMalformedAborts=@(Get-Content (Join-Path $state 'abort.log')).Count;$environment.TL1_C1B_E2E_SCENARIO='malformed_abort';$malformedAbort=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner fake-ADB malformed-abort E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure;Check ($malformedAbort.ExitCode-ne0) 'malformed abort runner succeeded'
    $serverSnapshot=Assert-PrivateAdbServerScenario $serverSnapshot $state 'malformed-abort'
    $afterMalformed=@(Get-ChildItem (Join-Path $repo 'docs\runs\evidence') -Directory|Where-Object Name -like 'tl1-c1b-*');Check ($afterMalformed.Count-eq$knownRuns.Count+1) 'malformed abort run dir missing';$malformedFailureDir=Join-Path (($afterMalformed|Where-Object{$knownRuns-cnotcontains$_.FullName})[0].FullName) 'tablet-layout-c1b';$malformedFailure=Read-FailureEvidenceStrict (Join-Path $malformedFailureDir 'tablet-layout-c1b-failure.json');Check ($malformedFailure.status-ceq'failed'-and$malformedFailure.cleanup-ceq'failed'-and-not$malformedFailure.runtime_origin_verified-and-not$malformedFailure.runtime_evidence) 'malformed abort did not fail closed';Check (-not(Test-Path (Join-Path $malformedFailureDir 'tablet-layout-c1b-sidecar-v1.json'))) 'malformed abort forged success sidecar';Check (@(Get-Content (Join-Path $state 'abort.log')).Count-eq$beforeMalformedAborts+1) 'malformed abort attempt count'

    $knownRuns=@($afterMalformed.FullName);$beforeC1=@(Get-Content (Join-Path $state 'c1.log')).Count;$beforeC2=@(Get-Content (Join-Path $state 'c2.log')).Count;$beforeResults=@(Get-Content (Join-Path $state 'result.log')).Count;$beforeAborts=@(Get-Content (Join-Path $state 'abort.log')).Count;$environment.TL1_C1B_E2E_SCENARIO='tamper';$tamper=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner fake-ADB status-tuple tamper E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure;Check ($tamper.ExitCode-ne0) 'tampered intermediate status tuple runner succeeded'
    $serverSnapshot=Assert-PrivateAdbServerScenario $serverSnapshot $state 'tamper'
    $after=@(Get-ChildItem (Join-Path $repo 'docs\runs\evidence') -Directory|Where-Object Name -like 'tl1-c1b-*');Check ($after.Count-eq$knownRuns.Count+1) 'tamper run dir missing';$failureDir=Join-Path (($after|Where-Object{$knownRuns-cnotcontains$_.FullName})[0].FullName) 'tablet-layout-c1b';$failurePath=Join-Path $failureDir 'tablet-layout-c1b-failure.json';Check (Test-Path $failurePath) 'failure evidence missing';$failure=Read-FailureEvidenceStrict $failurePath;Check ($failure.status-ceq'failed'-and$failure.cleanup-ceq'completed'-and-not$failure.runtime_origin_verified-and-not$failure.runtime_evidence) 'tamper failure evidence/cleanup drift';Check (-not(Test-Path (Join-Path $failureDir 'tablet-layout-c1b-sidecar-v1.json'))) 'tamper forged success sidecar';Check (@(Get-Content (Join-Path $state 'c1.log')).Count-eq$beforeC1+1) 'tamper c1 count';Check (@(Get-Content (Join-Path $state 'c2.log')).Count-eq$beforeC2) 'tamper reached c2';Check (@(Get-Content (Join-Path $state 'result.log')).Count-eq$beforeResults) 'tamper reached result';Check (@(Get-Content (Join-Path $state 'abort.log')).Count-eq$beforeAborts+1) 'tamper abort count'
    $finalRejectedEndpointLines=[IO.File]::ReadAllLines((Join-Path $state 'adb-rejected.log'),[Text.UTF8Encoding]::new($false,$true));Check (($finalRejectedEndpointLines-join"`n")-ceq($rejectedEndpointLines-join"`n")) 'runner produced a rejected/default/drifted adb endpoint invocation';$finalAdbLines=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false));$finalAdbExecutions=@(Read-AdbExecutableEvidence (Join-Path $state 'adb-executable.log'));Check ($finalAdbExecutions.Count-eq$finalAdbLines.Count) 'final adb executable/argv evidence count drift';foreach($execution in $finalAdbExecutions){$relativeExecutionPath=[IO.Path]::GetRelativePath($state,$execution.Path).Replace('\','/');Check (-not[StringComparer]::OrdinalIgnoreCase.Equals($execution.Path,$fakeExe)-and$relativeExecutionPath-cmatch'^build-environment-workspace-[0-9]+/android-sdk/platform-tools/adb\.exe$'-and$execution.Sha256-ceq$sourceAdbHash) 'runner scenario executed adb outside its isolated SDK copy'};$privateAdbTransport=Assert-PrivateAdbTransportLog $state 4;$aapt2ExecutionCount=@($finalAdbLines|Where-Object{$_-cmatch'^dump\x1fxmltree(?:\x1f|$)'}).Count;$fakeGradleCallCount=@(Get-Content (Join-Path $state 'gradle.log')).Count;$signerLines=[IO.File]::ReadAllLines((Join-Path $state 'signer.log'),[Text.UTF8Encoding]::new($false));$fakeSignerCallCount=$signerLines.Count
    $sourceDebugTarget=[IO.Path]::GetFullPath((Join-Path $repo 'app\tablet-c1b-probe\build\outputs\apk\debug\tablet-c1b-probe-debug.apk'));$expectedArchiveTargets=[string[]]@($after|ForEach-Object{[IO.Path]::GetFullPath((Join-Path $_.FullName 'tablet-layout-c1b\tablet-c1b-probe-debug.apk'))});$observedArchiveTargets=[Collections.Generic.List[string]]::new()
    Check ($expectedArchiveTargets.Count-eq4-and$fakeSignerCallCount-eq8) 'fake signer execution/archive count drift';for($runIndex=0;$runIndex-lt4;$runIndex++){$sourceTarget=$signerLines[$runIndex*2];$archiveTarget=$signerLines[($runIndex*2)+1];Check ($sourceTarget-ceq$sourceDebugTarget) "fake signer source target/order drift: $runIndex";Check ($expectedArchiveTargets-ccontains$archiveTarget-and(Test-Path -LiteralPath $archiveTarget -PathType Leaf)) "fake signer archive target/order drift: $runIndex";$observedArchiveTargets.Add($archiveTarget)};$expectedArchiveSorted=[string[]]@($expectedArchiveTargets|Sort-Object -CaseSensitive);$observedArchiveSorted=[string[]]@($observedArchiveTargets.ToArray()|Sort-Object -CaseSensitive);Check (($expectedArchiveSorted-join"`n")-ceq($observedArchiveSorted-join"`n")) 'fake signer archive target set drift'
    $globalDeviceLock=Join-Path $localAppData 'agent-for-mobile\locks\device-v1.lock';Check ($aapt2ExecutionCount-eq0) 'synthetic aapt2 was executed';Check ($fakeGradleCallCount-eq4) 'fake Gradle execution count drift';Check ((Assert-IndependentRepositoryCatalog $repo (Join-Path $state 'build-environment-input-catalog.txt') 42)-ceq$catalogSha) 'build-environment catalog drift across scenarios';Check (-not(Test-Path -LiteralPath $sourceBuildRoot)) 'runner cleanup retained source build root';Check (@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0) 'build-environment Close retained an isolated SDK workspace';Check (-not(Test-Path -LiteralPath $globalDeviceLock)) 'global device lock survived runner cleanup'

    # The production runner has no run_id yet when its private adb server exits during startup.
    # Exercise that exact boundary through the actual entry point. The fake exits normally with a
    # deterministic nonzero code; it never crashes and therefore cannot create WER evidence.
    $evidenceRoot=Join-Path $repo 'docs\runs\evidence';$attemptFailureSchema=Join-Path $repo 'docs\contracts\tablet-layout-c1b-attempt-failure-v1.schema.json'
    $beforeAttemptFiles=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json');Check ($beforeAttemptFiles.Count-eq0) 'attempt failure evidence existed before early startup case'
    $beforeEarlyRunDirectories=[string[]]@((Get-ChildItem -LiteralPath $evidenceRoot -Directory|Where-Object Name -like 'tl1-c1b-*').FullName|Sort-Object -CaseSensitive)
    $beforeEarlySidecars=[string[]]@(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File -Filter 'tablet-layout-c1b-sidecar-v1.json'|ForEach-Object FullName|Sort-Object -CaseSensitive)
    $beforeEarlyAdb=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$beforeEarlyTransport=[IO.File]::ReadAllLines((Join-Path $state 'adb-transport.log'),[Text.UTF8Encoding]::new($false,$true))
    $beforeEarlyInstall=Get-E2eLineCount (Join-Path $state 'install.log');$beforeEarlyT0=Get-E2eLineCount (Join-Path $state 't0.bin');$beforeEarlyC1=Get-E2eLineCount (Join-Path $state 'c1.log');$beforeEarlyC2=Get-E2eLineCount (Join-Path $state 'c2.log');$beforeEarlyResult=Get-E2eLineCount (Join-Path $state 'result.log');$beforeEarlyAbort=Get-E2eLineCount (Join-Path $state 'abort.log')
    $environment.TL1_C1B_E2E_SCENARIO='early_server_fast_exit'
    $earlyServerFailure=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner early private adb server nonzero-exit E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure
    Check ($earlyServerFailure.ExitCode-eq1) 'early private adb startup case did not fail with runner exit 1'
    Check ($earlyServerFailure.Stderr.Contains('cleanup',[StringComparison]::Ordinal)) 'early private adb device-lease false result was not surfaced as cleanup failure'
    Check (-not$earlyServerFailure.Text.Contains('early-server-sensitive-canary',[StringComparison]::Ordinal)-and-not$earlyServerFailure.Stderr.Contains('early-server-sensitive-canary',[StringComparison]::Ordinal)) 'early private adb raw stderr escaped into runner output'
    $attemptFiles=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json');Check ($attemptFiles.Count-eq1) 'early private adb startup did not publish exactly one attempt record'
    $attemptRead=Read-AttemptFailureEvidenceStrict $attemptFiles[0].FullName $attemptFailureSchema;$attemptFailure=$attemptRead.Value
    Check ((Split-Path $attemptFiles[0].FullName -Leaf)-ceq("tablet-layout-c1b-attempt-$($attemptFailure.attempt_id).json")) 'attempt filename/id binding drift'
    Check ($null-eq$attemptFailure.run_id-and$attemptFailure.status-ceq'failed'-and$attemptFailure.reason_code-ceq'private_adb_startup_failed'-and$attemptFailure.failure_stage-ceq'private_adb_startup'-and$attemptFailure.expected_commit_sha-ceq$head-and$attemptFailure.commit_verified) 'attempt identity/status/provenance drift'
    Check ($attemptFailure.runner_invocation_count-eq1-and$attemptFailure.automatic_runner_retry_count-eq0) 'early private adb runner retry accounting drift'
    $preDevice=$attemptFailure.pre_device_operations;Check ($preDevice.build_completed-and$preDevice.artifact_checks_completed-and-not$preDevice.private_adb_guard_created-and$preDevice.device_discovery_count-eq0-and$preDevice.install_count-eq0-and$preDevice.t0_count-eq0-and$preDevice.c1_count-eq0-and$preDevice.c2_count-eq0-and$preDevice.result_count-eq0-and$preDevice.abort_count-eq0-and$preDevice.capture_count-eq0) 'early private adb pre-device operation accounting drift'
    $startup=$attemptFailure.private_adb_startup;Check ($startup.schema-ceq'tablet-layout-c1b-private-adb-startup-diagnostic/v1'-and$startup.outcome-ceq'failed'-and$startup.final_substage-ceq'server_process_exit_before_ready'-and$startup.server_attempt_count-eq1-and@($startup.attempts).Count-eq1) 'early private adb startup diagnostic envelope drift'
    $startupAttempt=$startup.attempts[0];Check ($startupAttempt.ordinal-eq1-and$startupAttempt.terminal_substage-ceq'server_process_exit_before_ready'-and-not$startupAttempt.listener_observed-and@($startupAttempt.status_clients).Count-eq0) 'early private adb server-attempt stage drift'
    Check ($startupAttempt.server_process.started-and$startupAttempt.server_process.exit_observed-and$startupAttempt.server_process.exit_code-eq86-and$startupAttempt.server_process.stdout.classification-ceq'empty'-and$startupAttempt.server_process.stderr.classification-ceq'fatal'-and$startupAttempt.server_process.stderr.observed_bytes-gt0-and$startupAttempt.server_process.stderr.captured_bytes-gt0) 'early private adb process diagnostic drift'
    Check ($startupAttempt.cleanup.status-ceq'completed'-and$startupAttempt.cleanup.process_exit_observed-and$startupAttempt.cleanup.streams_drained-and$startupAttempt.cleanup.port_rebind_verified) 'early private adb attempt cleanup drift'
    $earlyCleanup=$attemptFailure.cleanup;Check ($earlyCleanup.provider_session-ceq'not_required'-and$earlyCleanup.private_adb_startup-ceq'completed'-and$earlyCleanup.private_adb_guard-ceq'not_acquired'-and$earlyCleanup.artifact_guards-ceq'completed'-and$earlyCleanup.build_environment-ceq'completed'-and$earlyCleanup.device_lease-ceq'failed'-and$earlyCleanup.overall-ceq'failed') 'early private adb device-lease cleanup failure evidence drift'
    Check (-not$attemptFailure.runtime_origin_verified-and-not$attemptFailure.runtime_evidence-and-not$attemptFailure.layout_accepted-and-not$attemptFailure.wechat_layout_verified-and-not$attemptFailure.editor_action_ready-and$attemptFailure.p0_capability-ceq'unsupported'-and-not$attemptFailure.execution_grant) 'early private adb failure record overclaimed runtime evidence'
    Check (-not$attemptRead.Raw.Contains('early-server-sensitive-canary',[StringComparison]::Ordinal)-and-not$attemptRead.Raw.Contains('FAKE123',[StringComparison]::Ordinal)-and-not$attemptRead.Raw.Contains('n-private-canary-early-adb',[StringComparison]::Ordinal)) 'early private adb record persisted raw stderr secret material'
    $publishOrder=[IO.File]::ReadAllLines((Join-Path $state 'attempt-publish-order.log'),[Text.UTF8Encoding]::new($false,$true));Check (($publishOrder-join"`n")-ceq"early_server_fast_exit:build_environment_after=0`nearly_server_fast_exit:device_lease_after=0") 'attempt record was visible before build-environment/device-lease cleanup completed'
    $afterEarlyRunDirectories=[string[]]@((Get-ChildItem -LiteralPath $evidenceRoot -Directory|Where-Object Name -like 'tl1-c1b-*').FullName|Sort-Object -CaseSensitive);$afterEarlySidecars=[string[]]@(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File -Filter 'tablet-layout-c1b-sidecar-v1.json'|ForEach-Object FullName|Sort-Object -CaseSensitive)
    Check (($afterEarlyRunDirectories-join"`n")-ceq($beforeEarlyRunDirectories-join"`n")-and($afterEarlySidecars-join"`n")-ceq($beforeEarlySidecars-join"`n")) 'early private adb failure created a normal run directory or success sidecar'
    Check ((Get-E2eLineCount (Join-Path $state 'gradle.log'))-eq$fakeGradleCallCount+1-and(Get-E2eLineCount (Join-Path $state 'signer.log'))-eq$fakeSignerCallCount+1) 'early private adb failure did not perform exactly one build/signer pass'
    Check ((Get-E2eLineCount (Join-Path $state 'install.log'))-eq$beforeEarlyInstall-and(Get-E2eLineCount (Join-Path $state 't0.bin'))-eq$beforeEarlyT0-and(Get-E2eLineCount (Join-Path $state 'c1.log'))-eq$beforeEarlyC1-and(Get-E2eLineCount (Join-Path $state 'c2.log'))-eq$beforeEarlyC2-and(Get-E2eLineCount (Join-Path $state 'result.log'))-eq$beforeEarlyResult-and(Get-E2eLineCount (Join-Path $state 'abort.log'))-eq$beforeEarlyAbort) 'early private adb failure reached device/install/T0/capture/abort work'
    $afterEarlyAdb=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$afterEarlyTransport=[IO.File]::ReadAllLines((Join-Path $state 'adb-transport.log'),[Text.UTF8Encoding]::new($false,$true));Check ($afterEarlyAdb.Count-eq$beforeEarlyAdb.Count+1-and$afterEarlyTransport.Count-eq$beforeEarlyTransport.Count+1) 'early private adb fake process count drift'
    Check ($afterEarlyAdb[-1]-cmatch'^-L\x1ftcp:localhost:([0-9]{5})\x1fserver\x1fnodaemon$'-and$afterEarlyTransport[-1]-ceq("tcp:127.0.0.1:$($Matches[1])$([char]0x1f)$($afterEarlyAdb[-1])")) 'early private adb listen/client endpoint split drift'
    $earlyServerSnapshot=Get-PrivateAdbServerSnapshot $state;Check ($earlyServerSnapshot.Start.Count-eq$serverSnapshot.Start.Count+1-and$earlyServerSnapshot.Status.Count-eq$serverSnapshot.Status.Count-and$earlyServerSnapshot.Kill.Count-eq$serverSnapshot.Kill.Count-and$earlyServerSnapshot.Exit.Count-eq$serverSnapshot.Exit.Count+1-and$earlyServerSnapshot.Start[-1]-eq$earlyServerSnapshot.Exit[-1]-and(Test-PrivateAdbPortReusable $earlyServerSnapshot.Start[-1])) 'early private adb lifecycle/port cleanup drift';$serverSnapshot=$earlyServerSnapshot
    Check (-not(Test-Path -LiteralPath $sourceBuildRoot)-and@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0-and-not(Test-Path -LiteralPath $globalDeviceLock)) 'early private adb host cleanup retained guarded resources'

    # Keep the server alive and make only the first server-status client exit nonzero. This proves
    # that the actual runner preserves all three diagnostic layers (startup, server attempt, client)
    # without persisting client stderr, and publishes one run_id-null record only after cleanup.
    $beforeStatusAttemptFiles=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json');Check ($beforeStatusAttemptFiles.Count-eq1) 'status-client case did not start from exactly one prior attempt record'
    $beforeStatusAttemptPaths=[string[]]@($beforeStatusAttemptFiles.FullName);$beforeStatusRunDirectories=[string[]]@((Get-ChildItem -LiteralPath $evidenceRoot -Directory|Where-Object Name -like 'tl1-c1b-*').FullName|Sort-Object -CaseSensitive);$beforeStatusSidecars=[string[]]@(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File -Filter 'tablet-layout-c1b-sidecar-v1.json'|ForEach-Object FullName|Sort-Object -CaseSensitive)
    $beforeStatusAdb=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$beforeStatusTransport=[IO.File]::ReadAllLines((Join-Path $state 'adb-transport.log'),[Text.UTF8Encoding]::new($false,$true));$beforeStatusPidSnapshot=Get-PrivateAdbAutoStartSnapshot $state
    $beforeStatusGradle=Get-E2eLineCount (Join-Path $state 'gradle.log');$beforeStatusSigner=Get-E2eLineCount (Join-Path $state 'signer.log');$beforeStatusInstall=Get-E2eLineCount (Join-Path $state 'install.log');$beforeStatusT0=Get-E2eLineCount (Join-Path $state 't0.bin');$beforeStatusC1=Get-E2eLineCount (Join-Path $state 'c1.log');$beforeStatusC2=Get-E2eLineCount (Join-Path $state 'c2.log');$beforeStatusResult=Get-E2eLineCount (Join-Path $state 'result.log');$beforeStatusAbort=Get-E2eLineCount (Join-Path $state 'abort.log')
    $environment.TL1_C1B_E2E_SCENARIO='early_status_client_exit'
    $statusClientFailure=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b actual runner early private adb server-status client nonzero-exit E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure
    Check ($statusClientFailure.ExitCode-eq1) 'early server-status client case did not fail with runner exit 1'
    foreach($rawSecret in @('early-status-sensitive-canary','FAKE123','n-private-canary-early-adb','C:\status-private\adbkey')){Check (-not$statusClientFailure.Text.Contains($rawSecret,[StringComparison]::Ordinal)-and-not$statusClientFailure.Stderr.Contains($rawSecret,[StringComparison]::Ordinal)) "server-status client raw material escaped into runner output: $rawSecret"}
    $afterStatusAttemptFiles=@(Get-ChildItem -LiteralPath $evidenceRoot -File -Filter 'tablet-layout-c1b-attempt-*.json');$newStatusAttemptFiles=@($afterStatusAttemptFiles|Where-Object{$beforeStatusAttemptPaths-cnotcontains$_.FullName});Check ($afterStatusAttemptFiles.Count-eq2-and$newStatusAttemptFiles.Count-eq1) 'server-status client failure did not publish exactly one new attempt record'
    $statusAttemptRead=Read-AttemptFailureEvidenceStrict $newStatusAttemptFiles[0].FullName $attemptFailureSchema;$statusAttemptFailure=$statusAttemptRead.Value
    Check ((Split-Path $newStatusAttemptFiles[0].FullName -Leaf)-ceq("tablet-layout-c1b-attempt-$($statusAttemptFailure.attempt_id).json")) 'server-status attempt filename/id binding drift'
    Check ($null-eq$statusAttemptFailure.run_id-and$statusAttemptFailure.status-ceq'failed'-and$statusAttemptFailure.reason_code-ceq'private_adb_startup_failed'-and$statusAttemptFailure.failure_stage-ceq'private_adb_startup'-and$statusAttemptFailure.expected_commit_sha-ceq$head-and$statusAttemptFailure.commit_verified-and$statusAttemptFailure.runner_invocation_count-eq1-and$statusAttemptFailure.automatic_runner_retry_count-eq0) 'server-status attempt identity/status/retry accounting drift'
    $statusPreDevice=$statusAttemptFailure.pre_device_operations;Check ($statusPreDevice.build_completed-and$statusPreDevice.artifact_checks_completed-and-not$statusPreDevice.private_adb_guard_created-and$statusPreDevice.device_discovery_count-eq0-and$statusPreDevice.install_count-eq0-and$statusPreDevice.t0_count-eq0-and$statusPreDevice.c1_count-eq0-and$statusPreDevice.c2_count-eq0-and$statusPreDevice.result_count-eq0-and$statusPreDevice.abort_count-eq0-and$statusPreDevice.capture_count-eq0) 'server-status attempt pre-device accounting drift'
    $statusStartup=$statusAttemptFailure.private_adb_startup;Check ($statusStartup.schema-ceq'tablet-layout-c1b-private-adb-startup-diagnostic/v1'-and$statusStartup.outcome-ceq'failed'-and$statusStartup.final_substage-ceq'server_status_client'-and$statusStartup.server_attempt_count-eq1-and@($statusStartup.attempts).Count-eq1) 'server-status startup diagnostic envelope drift'
    $statusServerAttempt=$statusStartup.attempts[0];Check ($statusServerAttempt.ordinal-eq1-and$statusServerAttempt.terminal_substage-ceq'server_status_client'-and$statusServerAttempt.listener_observed-and@($statusServerAttempt.status_clients).Count-eq1) 'server-status server-attempt diagnostic layer drift'
    $statusClient=$statusServerAttempt.status_clients[0];Check ($statusClient.ordinal-eq1-and$statusClient.terminal_substage-ceq'server-status_process-exit'-and$statusClient.process.started-and$statusClient.process.exit_observed-and$statusClient.process.exit_code-eq87) 'server-status client process-exit diagnostic layer drift'
    Check ($statusClient.process.stdout.observed_bytes-eq0-and$statusClient.process.stdout.captured_bytes-eq0-and-not$statusClient.process.stdout.overflowed-and$statusClient.process.stdout.strict_utf8-and$statusClient.process.stdout.classification-ceq'empty'-and$statusClient.process.stderr.observed_bytes-gt0-and$statusClient.process.stderr.captured_bytes-gt0-and-not$statusClient.process.stderr.overflowed-and$statusClient.process.stderr.strict_utf8-and$statusClient.process.stderr.classification-ceq'fatal') 'server-status client bounded stream diagnostic drift'
    Check ($statusClient.cleanup.status-ceq'completed'-and$statusClient.cleanup.endpoint_contained-ceq'held') 'server-status client cleanup/endpoint containment diagnostic drift'
    Check ($statusServerAttempt.server_process.started-and$statusServerAttempt.server_process.exit_observed-and$statusServerAttempt.server_process.stdout.classification-ceq'empty'-and$statusServerAttempt.server_process.stderr.classification-ceq'empty'-and$statusServerAttempt.cleanup.status-ceq'completed'-and$statusServerAttempt.cleanup.process_exit_observed-and$statusServerAttempt.cleanup.streams_drained-and$statusServerAttempt.cleanup.port_rebind_verified) 'server-status held server cleanup diagnostic drift'
    $statusCleanup=$statusAttemptFailure.cleanup;Check ($statusCleanup.provider_session-ceq'not_required'-and$statusCleanup.private_adb_startup-ceq'completed'-and$statusCleanup.private_adb_guard-ceq'not_acquired'-and$statusCleanup.artifact_guards-ceq'completed'-and$statusCleanup.build_environment-ceq'completed'-and$statusCleanup.device_lease-ceq'completed'-and$statusCleanup.overall-ceq'completed') 'server-status host cleanup evidence drift'
    Check (-not$statusAttemptFailure.runtime_origin_verified-and-not$statusAttemptFailure.runtime_evidence-and-not$statusAttemptFailure.layout_accepted-and-not$statusAttemptFailure.wechat_layout_verified-and-not$statusAttemptFailure.editor_action_ready-and$statusAttemptFailure.p0_capability-ceq'unsupported'-and-not$statusAttemptFailure.execution_grant) 'server-status attempt overclaimed runtime evidence'
    foreach($rawSecret in @('early-status-sensitive-canary','FAKE123','n-private-canary-early-adb','C:\status-private\adbkey',$state)){Check (-not$statusAttemptRead.Raw.Contains($rawSecret,[StringComparison]::Ordinal)) "server-status attempt persisted raw canary/path/serial: $rawSecret"}
    $publishOrder=[IO.File]::ReadAllLines((Join-Path $state 'attempt-publish-order.log'),[Text.UTF8Encoding]::new($false,$true));Check (($publishOrder-join"`n")-ceq"early_server_fast_exit:build_environment_after=0`nearly_server_fast_exit:device_lease_after=0`nearly_status_client_exit:build_environment_after=1`nearly_status_client_exit:device_lease_after=1") 'server-status attempt became visible before all host cleanup completed'
    $afterStatusRunDirectories=[string[]]@((Get-ChildItem -LiteralPath $evidenceRoot -Directory|Where-Object Name -like 'tl1-c1b-*').FullName|Sort-Object -CaseSensitive);$afterStatusSidecars=[string[]]@(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File -Filter 'tablet-layout-c1b-sidecar-v1.json'|ForEach-Object FullName|Sort-Object -CaseSensitive);Check (($afterStatusRunDirectories-join"`n")-ceq($beforeStatusRunDirectories-join"`n")-and($afterStatusSidecars-join"`n")-ceq($beforeStatusSidecars-join"`n")) 'server-status failure created a normal run directory or success sidecar'
    Check ((Get-E2eLineCount (Join-Path $state 'gradle.log'))-eq$beforeStatusGradle+1-and(Get-E2eLineCount (Join-Path $state 'signer.log'))-eq$beforeStatusSigner+1) 'server-status failure did not perform exactly one build/signer pass'
    Check ((Get-E2eLineCount (Join-Path $state 'install.log'))-eq$beforeStatusInstall-and(Get-E2eLineCount (Join-Path $state 't0.bin'))-eq$beforeStatusT0-and(Get-E2eLineCount (Join-Path $state 'c1.log'))-eq$beforeStatusC1-and(Get-E2eLineCount (Join-Path $state 'c2.log'))-eq$beforeStatusC2-and(Get-E2eLineCount (Join-Path $state 'result.log'))-eq$beforeStatusResult-and(Get-E2eLineCount (Join-Path $state 'abort.log'))-eq$beforeStatusAbort) 'server-status failure reached device/install/T0/capture/abort work'
    $afterStatusAdb=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$afterStatusTransport=[IO.File]::ReadAllLines((Join-Path $state 'adb-transport.log'),[Text.UTF8Encoding]::new($false,$true));Check ($afterStatusAdb.Count-eq$beforeStatusAdb.Count+2-and$afterStatusTransport.Count-eq$beforeStatusTransport.Count+2) 'server-status failure fake process count/retry drift'
    $statusServerMatch=[regex]::Match($afterStatusAdb[-2],'^-L\x1ftcp:localhost:([0-9]{5})\x1fserver\x1fnodaemon$');Check ($statusServerMatch.Success) 'server-status failure private server argv drift';$statusPort=[int]$statusServerMatch.Groups[1].Value;Check ($afterStatusAdb[-1]-ceq'server-status'-and$afterStatusTransport[-2]-ceq("tcp:127.0.0.1:$statusPort$([char]0x1f)$($afterStatusAdb[-2])")-and$afterStatusTransport[-1]-ceq("tcp:127.0.0.1:$statusPort$([char]0x1f)-H$([char]0x1f)127.0.0.1$([char]0x1f)-P$([char]0x1f)$statusPort$([char]0x1f)server-status")) 'server-status failure listen/client endpoint split drift'
    $afterStatusSnapshot=Get-PrivateAdbServerSnapshot $state;Check ($afterStatusSnapshot.Start.Count-eq$serverSnapshot.Start.Count+1-and$afterStatusSnapshot.Status.Count-eq$serverSnapshot.Status.Count+1-and$afterStatusSnapshot.Kill.Count-eq$serverSnapshot.Kill.Count-and$afterStatusSnapshot.Exit.Count-eq$serverSnapshot.Exit.Count-and$afterStatusSnapshot.Start[-1]-eq$statusPort-and$afterStatusSnapshot.Status[-1]-eq$statusPort-and(Test-PrivateAdbPortReusable $statusPort)-and-not(Test-Path -LiteralPath (Join-Path $state "adb-server-stop-$statusPort.txt"))) 'server-status failure lifecycle/port cleanup drift'
    $afterStatusPidSnapshot=Get-PrivateAdbAutoStartSnapshot $state;Check ($afterStatusPidSnapshot.ServerPid.Count-eq$beforeStatusPidSnapshot.ServerPid.Count+1-and$afterStatusPidSnapshot.ServerExitPid.Count-eq$beforeStatusPidSnapshot.ServerExitPid.Count-and$afterStatusPidSnapshot.Attempt.Count-eq$beforeStatusPidSnapshot.Attempt.Count-and$afterStatusPidSnapshot.ChildEntry.Count-eq$beforeStatusPidSnapshot.ChildEntry.Count-and$afterStatusPidSnapshot.Listener.Count-eq$beforeStatusPidSnapshot.Listener.Count-and$afterStatusPidSnapshot.CommandSideEffect.Count-eq$beforeStatusPidSnapshot.CommandSideEffect.Count) 'server-status failure process/auto-start evidence drift';[string[]]$statusServerPidFields=$afterStatusPidSnapshot.ServerPid[-1].Split([char]0x1f);$statusServerPid=0;Check ($statusServerPidFields.Count-eq2-and$statusServerPidFields[0]-ceq([string]$statusPort)-and[int]::TryParse($statusServerPidFields[1],[ref]$statusServerPid)-and$statusServerPid-gt0-and$null-eq(Get-Process -Id $statusServerPid -ErrorAction SilentlyContinue)) 'server-status held server process survived cleanup'
    Check (-not(Test-Path -LiteralPath $sourceBuildRoot)-and@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0-and-not(Test-Path -LiteralPath $globalDeviceLock)) 'server-status failure retained guarded resources';$serverSnapshot=$afterStatusSnapshot

    # These two cases exercise the production call sites, not a direct unit-test call into the
    # launcher. The fake first makes the held private server exit, then follows adb's official
    # failure shape by attempting to create a replacement server from inside the business client.
    # The direct client is the only process allowed in its job. The T0 root job has exactly the
    # production chain (root pwsh -> cmd -> sidecar pwsh -> adb), so the replacement is process 5.
    $autoStartSnapshot=Get-PrivateAdbAutoStartSnapshot $state
    $beforeDirectInstallCount=@(Get-Content -LiteralPath (Join-Path $state 'install.log')).Count
    $environment.TL1_C1B_E2E_SCENARIO='direct_auto_start_escape'
    $directAutoStart=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b direct business adb official-auto-start containment E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure
    Check ($directAutoStart.ExitCode-ne0) 'direct business adb official auto-start scenario succeeded'
    $directBlocked=Assert-PrivateAdbAutoStartBlockedScenario $serverSnapshot $autoStartSnapshot $state 'direct_auto_start_escape' 'direct business adb ACTIVE_PROCESS_LIMIT'
    $serverSnapshot=$directBlocked.Server;$autoStartSnapshot=$directBlocked.AutoStart
    Check (@(Get-Content -LiteralPath (Join-Path $state 'install.log')).Count-eq$beforeDirectInstallCount) 'direct official auto-start scenario reached install side effect'
    Check (@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0) 'direct official auto-start cleanup retained an isolated SDK workspace'
    Check (-not(Test-Path -LiteralPath $globalDeviceLock)) 'direct official auto-start cleanup retained global device lock'

    $beforeT0InstallCount=@(Get-Content -LiteralPath (Join-Path $state 'install.log')).Count
    $environment.TL1_C1B_E2E_SCENARIO='t0_auto_start_escape'
    $t0AutoStart=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$runner,'-AdbPath',$fakeExe,'-ExpectedCommitSha',$head,'-Provision') -Operation 'C1b T0 sidecar adb official-auto-start containment E2E' -Environment $environment -ClearEnvironment -TimeoutSec 180 -AllowFailure
    Check ($t0AutoStart.ExitCode-ne0) 'T0 sidecar adb official auto-start scenario succeeded'
    $t0Blocked=Assert-PrivateAdbAutoStartBlockedScenario $serverSnapshot $autoStartSnapshot $state 't0_auto_start_escape' 'T0 root ACTIVE_PROCESS_LIMIT'
    $serverSnapshot=$t0Blocked.Server;$autoStartSnapshot=$t0Blocked.AutoStart
    Check (@(Get-Content -LiteralPath (Join-Path $state 'install.log')).Count-eq$beforeT0InstallCount+1) 'T0 official auto-start scenario did not reach the actual post-install T0 path exactly once'
    Check (@(Get-ChildItem -LiteralPath $state -Directory -Filter 'build-environment-workspace-*').Count-eq0) 'T0 official auto-start cleanup retained an isolated SDK workspace'
    Check (-not(Test-Path -LiteralPath $globalDeviceLock)) 'T0 official auto-start cleanup retained global device lock'

    $postNegativeRejected=[IO.File]::ReadAllLines((Join-Path $state 'adb-rejected.log'),[Text.UTF8Encoding]::new($false,$true));Check (($postNegativeRejected-join"`n")-ceq($finalRejectedEndpointLines-join"`n")) 'official auto-start scenarios produced a rejected/default/drifted adb endpoint invocation'
    $postNegativeAdbLines=[IO.File]::ReadAllLines((Join-Path $state 'adb.log'),[Text.UTF8Encoding]::new($false,$true));$postNegativeAdbExecutions=@(Read-AdbExecutableEvidence (Join-Path $state 'adb-executable.log'));Check ($postNegativeAdbExecutions.Count-eq$postNegativeAdbLines.Count) 'official auto-start final adb executable/argv evidence count drift'
    foreach($execution in $postNegativeAdbExecutions){$relativeExecutionPath=[IO.Path]::GetRelativePath($state,$execution.Path).Replace('\','/');Check (-not[StringComparer]::OrdinalIgnoreCase.Equals($execution.Path,$fakeExe)-and$relativeExecutionPath-cmatch'^build-environment-workspace-[0-9]+/android-sdk/platform-tools/adb\.exe$'-and$execution.Sha256-ceq$sourceAdbHash) 'official auto-start scenario executed adb outside its isolated SDK copy'}
    Check ($autoStartSnapshot.Attempt.Count-eq2-and$autoStartSnapshot.ChildEntry.Count-eq0-and$autoStartSnapshot.Listener.Count-eq0-and$autoStartSnapshot.CommandSideEffect.Count-eq0) 'official auto-start ACTIVE_PROCESS_LIMIT aggregate proof drift'
    Check ($serverSnapshot.Start.Count-eq8-and$serverSnapshot.Status.Count-eq7-and$serverSnapshot.Kill.Count-eq4-and$serverSnapshot.Exit.Count-eq7) 'early-failure/official-auto-start aggregate private-server lifecycle drift'
    $postNegativeDeviceCount=@($postNegativeAdbLines|Where-Object{$_-cne'server-status'-and$_-cne'kill-server'-and$_-cnotmatch'^-L\x1f'}).Count
    $postNegativeT0Count=@($postNegativeAdbLines|Where-Object{$_-cmatch("^-s$([char]0x1f)FAKE123$([char]0x1f)exec-in$([char]0x1f)content$([char]0x1f)write$([char]0x1f)--uri$([char]0x1f)")}).Count
    $postNegativeGradleCount=@(Get-Content -LiteralPath (Join-Path $state 'gradle.log')).Count;$postNegativeSignerLines=[IO.File]::ReadAllLines((Join-Path $state 'signer.log'),[Text.UTF8Encoding]::new($false,$true))
    Check ($postNegativeDeviceCount-eq$privateAdbTransport.Device+11-and$postNegativeT0Count-eq$privateAdbTransport.T0) 'official auto-start final business/T0 adb counts drift'
    Check ($postNegativeGradleCount-eq$fakeGradleCallCount+4-and$postNegativeSignerLines.Count-eq$fakeSignerCallCount+4-and$postNegativeSignerLines[$fakeSignerCallCount]-ceq$sourceDebugTarget-and$postNegativeSignerLines[$fakeSignerCallCount+1]-ceq$sourceDebugTarget-and$postNegativeSignerLines[$fakeSignerCallCount+2]-ceq$sourceDebugTarget-and$postNegativeSignerLines[$fakeSignerCallCount+3]-ceq$sourceDebugTarget) 'early-failure/official-auto-start pre-ADB synthetic build/signer count drift'
    Check (-not(Test-Path -LiteralPath $sourceBuildRoot)) 'official auto-start cleanup retained source build root'
    [pscustomobject]@{schema='tablet-layout-c1b-host-e2e/v1';status='passed';fake_adb=$true;real_adb_call_count=0;fake_adb_call_count=[long]($postNegativeAdbLines.Count+$postNegativeRejected.Count);fake_adb_valid_call_count=[long]$postNegativeAdbLines.Count;fake_adb_rejected_endpoint_call_count=[long]$postNegativeRejected.Count;private_adb_server_start_count=[long]$serverSnapshot.Start.Count;private_adb_server_status_count=[long]$serverSnapshot.Status.Count;private_adb_server_kill_count=[long]$serverSnapshot.Kill.Count;private_adb_server_exit_count=[long]$serverSnapshot.Exit.Count;private_adb_device_call_count=[long]$postNegativeDeviceCount;private_adb_t0_call_count=[long]$postNegativeT0Count;private_adb_endpoint_verified=$true;private_adb_port_cleanup_verified=$true;default_adb_server_used=$false;isolated_sdk_adb_verified=$true;t0_clear_environment_verified=$true;direct_business_active_process_limit_verified=$true;t0_root_active_process_limit_verified=$true;official_auto_start_attempt_count=[long]$autoStartSnapshot.Attempt.Count;escaped_auto_start_child_count=[long]$autoStartSnapshot.ChildEntry.Count;escaped_auto_start_listener_count=[long]$autoStartSnapshot.Listener.Count;auto_start_command_side_effect_count=[long]$autoStartSnapshot.CommandSideEffect.Count;aapt2_execution_count=$aapt2ExecutionCount;runner_process_call_count=9;fake_gradle_call_count=[long]$postNegativeGradleCount;fake_signer_call_count=[long]$postNegativeSignerLines.Count;signer_target_sequence_verified=$true;build_environment_input_count=42;global_device_lock_cleaned=$true;coverage=@('private_adb_endpoint_negative_matrix','private_adb_server_lifecycle','private_adb_explicit_device_and_t0_endpoint','runner_e2e_success','runner_e2e_result_control_abort','runner_e2e_malformed_abort_fail_closed','runner_e2e_tamper_abort','runner_e2e_early_private_adb_server_exit','runner_e2e_early_device_lease_cleanup_failure','runner_e2e_early_private_adb_status_client_exit','direct_business_adb_official_auto_start_blocked','t0_sidecar_adb_official_auto_start_blocked')}|ConvertTo-Json -Compress
}finally{if($env:TL1_C1B_KEEP_E2E_TEMP-ceq'1'){[Console]::Error.WriteLine("C1b E2E temp kept: $root")}else{Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
