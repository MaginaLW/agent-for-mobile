#Requires -Version 7.5
<#
Self-contained API 36 testbench. The default only checks inputs; -Run creates a fresh AVD.
No default adb server, physical-device selection, approval injection, or overlay click is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SdkRoot,
    [Parameter(Mandatory)][string]$AvdManagerPath,
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$ApkSignerPath,
    [Parameter(Mandatory)][string]$GatewayApk,
    [Parameter(Mandatory)][string]$TargetApk,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedGatewaySha256,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedTargetSha256,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(1024,65535)][int]$AdbServerPort=5039,
    [ValidateRange(5554,5682)][int]$ConsolePort=5580,
    [ValidateRange(1024,65535)][int]$HttpPort=18848,
    [ValidateRange(60,900)][int]$BootTimeoutSeconds=300,
    [ValidateRange(240,3600)][int]$RuntimeSeconds=900,
    [switch]$PrepareOnly,
    [switch]$Run
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$encoding=[Text.UTF8Encoding]::new($false,$true)
$clock=[Diagnostics.Stopwatch]::StartNew()
$server=$null; $emulator=$null; $client=$null; $token=$null
$forwardAdded=$false; $emulatorVerified=$false
$script:commandIndex=0; $script:rpcId=0; $script:auditIds=[Collections.Generic.List[string]]::new()
$script:phase='preflight'
$summary=[ordered]@{
    schema='local-testbench/v1'; status='failed'; mode=$(if($Run){'run'}else{'preflight'})
    source_sha='UNKNOWN'; source_clean=$false; fixed_source_verified=$false
    gateway_apk_sha256='UNKNOWN'; target_apk_sha256='UNKNOWN'
    gateway_certificate_sha256='UNKNOWN'; target_certificate_sha256='UNKNOWN'
    expected_api=36; actual_api='UNKNOWN'; serial=('emulator-'+$ConsolePort); avd_name='UNKNOWN'
    acceleration_verified=$false; available_memory_mb='UNKNOWN'
    isolated_adb_server_port=$AdbServerPort; server_pid='UNKNOWN'; emulator_pid='UNKNOWN'
    physical_device_commands=0; approval_injected=$false; token_logged=$false
    routes_verified=@(); ordinary_actions_verified=@(); confirmation_result='UNKNOWN'
    callback_count_before='UNKNOWN'; callback_count_after='UNKNOWN'; audit_verified=$false
    emulator_process_stopped='UNKNOWN'; adb_server_process_stopped='UNKNOWN'
    declared_ports_released='UNKNOWN'; remaining_listener_owners=@()
    cleanup_proven=$false; failure_phase='UNKNOWN'; failure_reason='UNKNOWN'
    runtime_acceptance=$false; production_execution_grant=$false
}

function Assert-Bench([bool]$Condition,[string]$Reason){if(-not $Condition){throw $Reason}}
function Write-BenchJson([string]$Name,$Value){
    [IO.File]::WriteAllText((Join-Path $script:output $Name),($Value|ConvertTo-Json -Depth 60)+"`n",$encoding)
}
function Set-BenchPhase([string]$Phase){
    $script:phase=$Phase
    Write-BenchJson 'state.json' ([ordered]@{phase=$Phase;elapsed_seconds=[int]$clock.Elapsed.TotalSeconds;serial=$summary.serial;server_pid=$summary.server_pid;emulator_pid=$summary.emulator_pid})
}
function Assert-BenchRemaining([int]$Reserve=0){Assert-Bench (($RuntimeSeconds-$clock.Elapsed.TotalSeconds) -gt $Reserve) 'runtime_budget_exhausted'}
function Assert-BenchLocalPath([string]$Path,[string]$Root){
    $full=[IO.Path]::GetFullPath($Path)
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    Assert-Bench ($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) 'path_outside_declared_root'
    $cursor=$full
    while($cursor.Length -ge $prefix.TrimEnd([IO.Path]::DirectorySeparatorChar).Length){
        if(Test-Path -LiteralPath $cursor){Assert-Bench (-not((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'path_reparse_point'}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Start-BenchProcess([string]$File,[string[]]$Arguments,[string]$InputText=''){
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$File; $start.WorkingDirectory=$repoRoot
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.RedirectStandardInput=$true
    $start.StandardOutputEncoding=$encoding; $start.StandardErrorEncoding=$encoding
    if([IO.Path]::GetExtension($File) -ieq '.bat'){
        # Only official, explicit batch tools use cmd; their arguments are not shell fragments.
        foreach($value in @($File)+$Arguments){Assert-Bench ($value -notmatch '["&|<>^%!\r\n]') 'batch_argument_has_shell_metacharacter'}
        $start.FileName=Join-Path $env:SystemRoot 'System32/cmd.exe'
        $parts=@($File)+$Arguments
        $quoted=@($parts|ForEach-Object {'"'+$_+'"'})
        $command='"'+($quoted -join ' ')+'"'
        # cmd /s /c consumes its own quoting; ArgumentList would backslash-escape embedded quotes.
        $start.Arguments='/d /s /c '+$command
    }else{foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}}
    foreach($pair in $script:childEnvironment.GetEnumerator()){$start.Environment[$pair.Key]=$pair.Value}
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    Assert-Bench ($process.Start()) 'native_start_failed'
    if($InputText){$process.StandardInput.Write($InputText)}
    $process.StandardInput.Close()
    return [pscustomobject]@{Process=$process;Stdout=$process.StandardOutput.ReadToEndAsync();Stderr=$process.StandardError.ReadToEndAsync()}
}
function Save-BenchProcess($Handle,[string]$Name,[switch]$Sensitive){
    $stdout=$Handle.Stdout.GetAwaiter().GetResult(); $stderr=$Handle.Stderr.GetAwaiter().GetResult()
    if(-not $Sensitive){
        [IO.File]::WriteAllText((Join-Path $script:output ($Name+'.stdout.txt')),$stdout,$encoding)
        [IO.File]::WriteAllText((Join-Path $script:output ($Name+'.stderr.txt')),$stderr,$encoding)
    }
    return [pscustomobject]@{Output=$stdout;Error=$stderr;ExitCode=$Handle.Process.ExitCode}
}
function Invoke-BenchNative([string]$File,[string[]]$Arguments,[string]$Name,[int]$TimeoutSeconds=30,[string]$InputText='',[switch]$Sensitive,[int[]]$AllowedExitCodes=@(0)){
    Assert-BenchRemaining
    $script:commandIndex++
    $logName=('{0:d3}-{1}' -f $script:commandIndex,$Name)
    $handle=Start-BenchProcess $File $Arguments $InputText
    try{
        $timeout=[Math]::Min($TimeoutSeconds,[Math]::Max(1,[int]($RuntimeSeconds-$clock.Elapsed.TotalSeconds)))
        if(-not $handle.Process.WaitForExit($timeout*1000)){$handle.Process.Kill($true);$handle.Process.WaitForExit();[void](Save-BenchProcess $handle $logName -Sensitive:$Sensitive);throw ('native_timeout_'+$Name)}
        $result=Save-BenchProcess $handle $logName -Sensitive:$Sensitive
        Assert-Bench ($result.ExitCode -in $AllowedExitCodes) ('native_exit_'+$Name)
        return $result.Output.Trim()
    }finally{$handle.Process.Dispose()}
}
function Get-BenchPortListeners([int[]]$Ports){
    $conditions=@($Ports|ForEach-Object {'LocalPort = '+$_})
    # MSFT_NetTCPConnection State=2 is LISTEN; an empty query is distinct from probe failure.
    try{return @(Get-CimInstance -Namespace 'root/StandardCimv2' -ClassName MSFT_NetTCPConnection -Filter ('State = 2 AND ('+($conditions -join ' OR ')+')') -ErrorAction Stop)}
    catch{throw 'listener_ownership_probe_unavailable'}
}
function Assert-BenchOwnedServer {
    Assert-Bench ($null -ne $server -and -not $server.Process.HasExited) 'isolated_adb_server_exited'
    $listeners=@(Get-BenchPortListeners @($AdbServerPort))
    Assert-Bench ($listeners.Count -gt 0) 'isolated_adb_server_not_listening'
    Assert-Bench (@($listeners|Where-Object {$_.OwningProcess -ne $server.Process.Id -or $_.LocalAddress -cnotin @('127.0.0.1','::1')}).Count -eq 0) 'isolated_adb_listener_owner_mismatch'
}
function Invoke-BenchAdb([string[]]$Arguments,[string]$Name,[int]$TimeoutSeconds=30,[switch]$Sensitive){
    Assert-BenchOwnedServer
    # Official adb treats numeric 127.0.0.1 as a remote server spec: connection failure cannot launch a daemon.
    return Invoke-BenchNative $script:adb (@('-H','127.0.0.1','-P',"$AdbServerPort",'-s',$summary.serial)+$Arguments) $Name $TimeoutSeconds -Sensitive:$Sensitive
}
function Get-BenchCertificate([string]$Apk,[string]$Name){
    $raw=Invoke-BenchNative $script:signer @('verify','--print-certs',$Apk) $Name 30
    $matches=@([regex]::Matches($raw,'(?m)^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})\s*$'))
    Assert-Bench ($matches.Count -eq 1) 'apk_public_signer_ambiguous'
    return $matches[0].Groups[1].Value.ToLowerInvariant()
}
function Invoke-BenchRpc([string]$Method,$Parameters,[string]$Name,[int]$TimeoutSeconds=25){
    Assert-BenchRemaining 10
    $script:rpcId++
    $request=[ordered]@{jsonrpc='2.0';id=$script:rpcId;method=$Method;params=$Parameters}
    Write-BenchJson ($Name+'.request.json') $request
    $message=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$script:mcpUri)
    $message.Headers.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$token)
    $message.Headers.Add('MCP-Protocol-Version','2025-03-26')
    $message.Content=[Net.Http.StringContent]::new(($request|ConvertTo-Json -Depth 40 -Compress),[Text.Encoding]::UTF8,'application/json')
    $cancel=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try{
        $response=$client.SendAsync($message,$cancel.Token).GetAwaiter().GetResult()
        try{
            $raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Assert-Bench $response.IsSuccessStatusCode ('mcp_http_'+[int]$response.StatusCode)
            # Only response bodies are recorded, never Authorization or request headers.
            [IO.File]::WriteAllText((Join-Path $script:output ($Name+'.response.json')),$raw,$encoding)
            $rpc=$raw|ConvertFrom-Json -Depth 100 -DateKind String
            Assert-Bench ($null -eq $rpc.PSObject.Properties['error'] -and $rpc.id -eq $script:rpcId) 'mcp_rpc_error_or_id_mismatch'
            return $rpc.result
        }finally{$response.Dispose()}
    }finally{$cancel.Dispose();$message.Dispose()}
}
function Invoke-BenchTool([string]$Tool,$Arguments,[string]$Name,[int]$TimeoutSeconds=25){
    $result=Invoke-BenchRpc 'tools/call' @{name=$Tool;arguments=$Arguments} $Name $TimeoutSeconds
    $texts=@($result.content|Where-Object type -CEQ 'text')
    Assert-Bench ($texts.Count -eq 1) 'mcp_tool_envelope_ambiguous'
    $envelope=$texts[0].text|ConvertFrom-Json -Depth 100 -DateKind String
    Assert-Bench ($envelope.ok -is [bool] -and $envelope.audit_id -match '^a-[0-9]{6}$') 'gateway_envelope_invalid'
    $script:auditIds.Add($envelope.audit_id)
    return $envelope
}
function Assert-BenchToolOk($Envelope){Assert-Bench ($Envelope.ok -ceq $true) ('tool_failed_'+$(if($Envelope.PSObject.Properties['error']){$Envelope.error.code}else{'unknown'}))}
function Assert-BenchForeground([string]$Name){
    $fg=Invoke-BenchTool 'foreground_app' @{} $Name
    Assert-BenchToolOk $fg
    Assert-Bench ($fg.ctx.app -ceq 'dev.magina.testtarget' -and $fg.ctx.foreground_known -eq $true) 'target_not_current_foreground'
}
function Get-BenchSnapshot([string]$Name){
    Assert-BenchForeground ($Name+'-foreground')
    $snapshot=Invoke-BenchTool 'ui_snapshot' @{scope='full'} $Name
    Assert-BenchToolOk $snapshot
    Assert-Bench ($snapshot.ctx.app -ceq 'dev.magina.testtarget') 'snapshot_foreground_changed'
    return $snapshot.data
}
function Find-BenchInput($Snapshot){
    $matches=@($Snapshot.elements|Where-Object {$_.role -ceq 'input' -and $_.source -ceq 'a11y'})
    Assert-Bench ($matches.Count -eq 1) 'target_input_not_unique'
    return $matches[0]
}
function Get-BenchCount($Snapshot){
    $matches=@($Snapshot.elements|Where-Object {$_.text -cmatch '^本地发送回调次数：[0-9]+$' -and $_.source -ceq 'a11y'})
    Assert-Bench ($matches.Count -eq 1) 'target_callback_count_unavailable'
    return [int]($matches[0].text -replace '^本地发送回调次数：','')
}
function Open-BenchRoute([string]$Route){
    $opened=Invoke-BenchTool 'intent_send' @{action='android.intent.action.VIEW';uri=('agent-testbench://target/'+$Route);package='dev.magina.testtarget'} ('route-'+$Route)
    Assert-BenchToolOk $opened
    Assert-BenchForeground ('route-'+$Route+'-foreground')
    $summary.routes_verified+=,$Route
}

$output=[IO.Path]::GetFullPath($OutputDirectory)
Assert-BenchLocalPath $output (Join-Path $repoRoot '.checks')|Out-Null
Assert-Bench (-not(Test-Path -LiteralPath $output)) 'output_directory_already_exists'
New-Item -ItemType Directory -Path $output -Force|Out-Null
try{
    Assert-Bench (-not($Run -and $PrepareOnly)) 'run_and_prepare_only_conflict'
    Assert-Bench ($ConsolePort%2 -eq 0 -and $RuntimeSeconds -ge $BootTimeoutSeconds+180) 'invalid_ports_or_runtime_budget'
    $ports=@($AdbServerPort,$ConsolePort,($ConsolePort+1),$HttpPort)
    Assert-Bench (@($ports|Select-Object -Unique).Count -eq 4) 'ports_not_distinct'
    $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners())
    Assert-Bench (@($listeners|Where-Object {$_.Port -in $ports}).Count -eq 0) 'declared_port_already_in_use'
    $sdk=Assert-BenchLocalPath $SdkRoot $repoRoot
    $script:adb=Join-Path $sdk 'platform-tools/adb.exe'
    $emulatorExe=Join-Path $sdk 'emulator/emulator.exe'
    $script:signer=(Resolve-Path -LiteralPath $ApkSignerPath).Path
    $manager=(Resolve-Path -LiteralPath $AvdManagerPath).Path
    $gateway=(Resolve-Path -LiteralPath $GatewayApk).Path; $target=(Resolve-Path -LiteralPath $TargetApk).Path
    foreach($path in @($script:adb,$emulatorExe,(Join-Path $JavaHome 'bin/java.exe'),(Join-Path $sdk 'system-images/android-36/google_apis/x86_64/package.xml'))){Assert-Bench (Test-Path -LiteralPath $path -PathType Leaf) 'required_dependency_missing'}
    $summary.gateway_apk_sha256=(Get-FileHash -LiteralPath $gateway -Algorithm SHA256).Hash.ToLowerInvariant()
    $summary.target_apk_sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Bench ($summary.gateway_apk_sha256 -ceq $ExpectedGatewaySha256.ToLowerInvariant() -and $summary.target_apk_sha256 -ceq $ExpectedTargetSha256.ToLowerInvariant()) 'apk_hash_mismatch'
    foreach($dir in @('home','tmp','avd-home','home/AppData/Local','home/AppData/Roaming')){New-Item -ItemType Directory -Path (Join-Path $output $dir) -Force|Out-Null}
    $childHome=Join-Path $output 'home'
    $homeDrive=[IO.Path]::GetPathRoot($childHome).TrimEnd('\','/')
    $script:childEnvironment=@{
        JAVA_HOME=[IO.Path]::GetFullPath($JavaHome);ANDROID_HOME=$sdk;ANDROID_SDK_ROOT=$sdk
        ANDROID_USER_HOME=$childHome;ANDROID_EMULATOR_HOME=$childHome;ANDROID_AVD_HOME=(Join-Path $output 'avd-home')
        HOME=$childHome;USERPROFILE=$childHome;HOMEDRIVE=$homeDrive;HOMEPATH=$childHome.Substring($homeDrive.Length)
        LOCALAPPDATA=(Join-Path $childHome 'AppData/Local');APPDATA=(Join-Path $childHome 'AppData/Roaming')
        TEMP=(Join-Path $output 'tmp');TMP=(Join-Path $output 'tmp')
        JAVA_TOOL_OPTIONS=('-Duser.home="'+(Join-Path $output 'home')+'" -Djava.io.tmpdir="'+(Join-Path $output 'tmp')+'"')
        ANDROID_ADB_SERVER_PORT="$AdbServerPort";ADB_SERVER_SOCKET="tcp:127.0.0.1:$AdbServerPort"
    }
    $summary.source_sha=Invoke-BenchNative 'git' @('rev-parse','HEAD') 'source-head'
    $dirty=Invoke-BenchNative 'git' @('status','--porcelain=v1','--untracked-files=normal') 'source-status'
    $summary.source_clean=[string]::IsNullOrWhiteSpace($dirty)
    Assert-Bench ($summary.source_sha -ceq $ExpectedSourceSha) 'source_sha_mismatch'
    Assert-Bench $summary.source_clean 'source_tree_dirty_not_a_fixed_candidate'
    $summary.fixed_source_verified=$true
    $summary.gateway_certificate_sha256=Get-BenchCertificate $gateway 'gateway-public-certificate'
    $summary.target_certificate_sha256=Get-BenchCertificate $target 'target-public-certificate'
    Set-BenchPhase 'inputs_verified'
    if(-not $Run){$summary.status='prepared_not_run';return}

    Set-BenchPhase 'host_admission'
    $acceleration=Invoke-BenchNative $emulatorExe @('-accel-check') 'acceleration-check' 20
    Assert-Bench ($acceleration -match '(?m)^0\s*$') 'emulator_acceleration_unavailable'
    $summary.acceleration_verified=$true
    try{$summary.available_memory_mb=[int]((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory/1024)}catch{throw 'host_memory_probe_unavailable'}
    Assert-Bench ($summary.available_memory_mb -ge 4096) 'insufficient_available_memory'
    $nonce=[guid]::NewGuid().ToString('N').Substring(0,12)
    $summary.avd_name='agent-testbench-'+$nonce
    Set-BenchPhase 'create_avd'
    [void](Invoke-BenchNative $manager @('create','avd','--name',$summary.avd_name,'--package','system-images;android-36;google_apis;x86_64','--device','pixel_5','--path',(Join-Path $output 'avd')) 'create-avd' 120 "no`n")
    Assert-Bench (Test-Path -LiteralPath (Join-Path $output 'avd/config.ini')) 'avd_not_created_in_declared_directory'
    Set-BenchPhase 'start_isolated_adb'
    # --one-device restricts USB discovery to a per-run nonexistent USB identifier; TCP emulators remain available.
    # tcp:<port> with no -a binds the supported loopback listener; numeric-host -L is unsupported by adb.
    $server=Start-BenchProcess $script:adb @('-L',"tcp:$AdbServerPort",'--one-device',('local-testbench-no-usb-'+$nonce),'server','nodaemon')
    $summary.server_pid=$server.Process.Id
    $serverReady=$false
    foreach($attempt in 1..20){
        Assert-Bench (-not $server.Process.HasExited) 'isolated_adb_server_start_failed'
        $listeners=@(Get-BenchPortListeners @($AdbServerPort))
        if($listeners.Count -gt 0){Assert-BenchOwnedServer;$serverReady=$true;break}
        Start-Sleep -Milliseconds 100
    }
    Assert-Bench $serverReady 'isolated_adb_server_listen_timeout'
    Set-BenchPhase 'start_emulator'
    $emulator=Start-BenchProcess $emulatorExe @('-avd',$summary.avd_name,'-ports',"$ConsolePort,$($ConsolePort+1)",'-no-window','-no-audio','-no-boot-anim','-no-snapshot','-memory','2048','-gpu','software','-no-metrics')
    $summary.emulator_pid=$emulator.Process.Id
    $bootLimit=$clock.Elapsed.TotalSeconds+$BootTimeoutSeconds
    $online=$false
    while($clock.Elapsed.TotalSeconds -lt $bootLimit){
        Assert-BenchRemaining 180
        Assert-Bench (-not $emulator.Process.HasExited) 'emulator_exited_before_boot'
        $devices=Invoke-BenchAdb @('devices') 'isolated-devices' 10
        $rows=@($devices -split '\r?\n'|Where-Object {$_ -match '^\S+\s+(device|offline|unauthorized)\b'})
        Assert-Bench (@($rows|Where-Object {($_ -split '\s+')[0] -cne $summary.serial}).Count -eq 0) 'foreign_device_on_isolated_server'
        if(@($rows|Where-Object {$_ -cmatch ('^'+[regex]::Escape($summary.serial)+'\s+device\b')}).Count -eq 1){
            $boot=Invoke-BenchAdb @('shell','getprop','sys.boot_completed') 'boot-complete' 10
            if($boot -ceq '1'){$online=$true;break}
        }
        Start-Sleep -Seconds 2
    }
    Assert-Bench $online 'emulator_boot_timeout'
    $actualAvd=Invoke-BenchAdb @('emu','avd','name') 'avd-identity' 10
    $actualApi=Invoke-BenchAdb @('shell','getprop','ro.build.version.sdk') 'api-identity' 10
    $qemu=Invoke-BenchAdb @('shell','getprop','ro.kernel.qemu') 'qemu-identity' 10
    Assert-Bench (($actualAvd -split '\r?\n')[0] -ceq $summary.avd_name -and $actualApi -ceq '36' -and $qemu -ceq '1') 'emulator_identity_mismatch'
    $summary.actual_api=$actualApi; $emulatorVerified=$true
    Set-BenchPhase 'install_and_bind'
    foreach($app in @(@{Path=$gateway;Package='dev.magina.gateway';Hash=$summary.gateway_apk_sha256},@{Path=$target;Package='dev.magina.testtarget';Hash=$summary.target_apk_sha256})){
        [void](Invoke-BenchAdb @('install','-g',$app.Path) ('install-'+$app.Package) 90)
        $installed=Invoke-BenchAdb @('shell','pm','path',$app.Package) ('package-'+$app.Package) 15
        Assert-Bench ($installed -cmatch '^package:/[^\r\n]+/base\.apk$') 'installed_package_path_ambiguous'
        $deviceHash=Invoke-BenchAdb @('shell','sha256sum',$installed.Substring(8)) ('package-hash-'+$app.Package) 20
        Assert-Bench (($deviceHash -split '\s+')[0] -ceq $app.Hash) 'installed_apk_hash_mismatch'
    }
    [void](Invoke-BenchAdb @('shell','settings','put','secure','enabled_accessibility_services','dev.magina.gateway/.a11y.GatewayA11yService') 'enable-owned-accessibility')
    [void](Invoke-BenchAdb @('shell','settings','put','secure','accessibility_enabled','1') 'accessibility-enabled')
    [void](Invoke-BenchAdb @('shell','cmd','appops','set','dev.magina.gateway','SYSTEM_ALERT_WINDOW','allow') 'owned-overlay-permission')
    [void](Invoke-BenchAdb @('shell','am','start','-n','dev.magina.gateway/.MainActivity') 'initialize-owned-gateway')
    [void](Invoke-BenchAdb @('shell','run-as','dev.magina.gateway','am','start-foreground-service','--user','0','-n','dev.magina.gateway/.GatewayService') 'start-owned-gateway-service')
    $prefs=Invoke-BenchAdb @('shell','run-as','dev.magina.gateway','cat','shared_prefs/gateway.xml') 'owned-credential-in-memory' 20 -Sensitive
    $prefsXml=[xml]$prefs
    $token=[string]$prefsXml.SelectSingleNode('/map/string[@name="token"]').InnerText
    Assert-Bench ($token -cmatch '^[0-9a-f]{32}$') 'owned_gateway_credential_unavailable'
    $prefs=$null; $prefsXml=$null
    [void](Invoke-BenchAdb @('forward','--no-rebind',"tcp:$HttpPort",'tcp:8848') 'owned-forward')
    $forwardAdded=$true
    $client=[Net.Http.HttpClient]::new();$client.Timeout=[Threading.Timeout]::InfiniteTimeSpan
    $script:mcpUri=[uri]("http://127.0.0.1:$HttpPort/mcp")
    $healthy=$false
    foreach($attempt in 1..15){
        Assert-BenchRemaining 150
        try{$response=Invoke-WebRequest -Uri "http://127.0.0.1:$HttpPort/health" -TimeoutSec 2;if($response.Content.Trim() -ceq 'ok'){$healthy=$true;break}}catch{}
        Start-Sleep -Seconds 1
    }
    Assert-Bench $healthy 'gateway_http_not_ready'
    Set-BenchPhase 'real_mcp_chain'
    $initialized=Invoke-BenchRpc 'initialize' @{protocolVersion='2025-03-26';capabilities=@{};clientInfo=@{name='local-testbench';version='1'}} 'initialize'
    Assert-Bench ($initialized.protocolVersion -ceq '2025-03-26') 'mcp_protocol_mismatch'
    $tools=Invoke-BenchRpc 'tools/list' @{} 'tools-list'
    foreach($required in @('foreground_app','intent_send','ui_snapshot','ui_action')){Assert-Bench ($tools.tools.name -ccontains $required) 'required_gateway_tool_missing'}
    Open-BenchRoute 'list'
    [void](Get-BenchSnapshot 'list-snapshot')
    Open-BenchRoute 'search'
    $snapshot=Get-BenchSnapshot 'search-before-focus'
    $inputNode=Find-BenchInput $snapshot
    $focused=Invoke-BenchTool 'ui_action' @{ref=$inputNode.ref;action='focus'} 'focus-search'
    Assert-BenchToolOk $focused
    $summary.ordinary_actions_verified+=,'focus'
    $snapshot=Get-BenchSnapshot 'search-before-set-text'
    $inputNode=Find-BenchInput $snapshot
    $typed=Invoke-BenchTool 'ui_action' @{ref=$inputNode.ref;action='set_text';text='TESTBENCH_SEARCH'} 'set-search-text'
    Assert-BenchToolOk $typed
    $readback=Find-BenchInput (Get-BenchSnapshot 'search-readback')
    Assert-Bench ($readback.text -ceq 'TESTBENCH_SEARCH') 'set_text_readback_mismatch'
    $summary.ordinary_actions_verified+=,'set_text_readback'
    Open-BenchRoute 'conversation'
    $before=Get-BenchSnapshot 'conversation-before-confirmation'
    $summary.callback_count_before=Get-BenchCount $before
    Assert-Bench ($summary.callback_count_before -eq 0) 'callback_not_zero_before_confirmation'
    $buttons=@($before.elements|Where-Object {$_.text -ceq '发送（仅本地计数）' -and $_.role -ceq 'button' -and $_.source -ceq 'a11y'})
    Assert-Bench ($buttons.Count -eq 1) 'send_counter_button_not_unique'
    Assert-BenchRemaining 120
    Set-BenchPhase 'await_real_confirmation_timeout_no_injection'
    $denied=Invoke-BenchTool 'ui_action' @{ref=$buttons[0].ref;action='click'} 'unconfirmed-click' 100
    Assert-Bench (-not $denied.ok -and $denied.error.code -ceq 'E_CONFIRM_TIMEOUT') 'unexpected_confirmation_terminal'
    $summary.confirmation_result=$denied.error.code
    $after=Get-BenchSnapshot 'conversation-after-timeout'
    $summary.callback_count_after=Get-BenchCount $after
    Assert-Bench ($summary.callback_count_after -eq 0) 'unconfirmed_click_executed'
    Set-BenchPhase 'collect_audit'
    $auditFiles=Invoke-BenchAdb @('shell','run-as','dev.magina.gateway','ls','files/audit') 'audit-file-list'
    $lines=[Collections.Generic.List[string]]::new()
    foreach($file in ($auditFiles -split '\r?\n')){
        Assert-Bench ($file -cmatch '^[0-9]{8}\.jsonl$') 'unexpected_audit_filename'
        $raw=Invoke-BenchAdb @('shell','run-as','dev.magina.gateway','cat',('files/audit/'+$file)) 'audit-lines'
        foreach($line in ($raw -split '\r?\n'|Where-Object {-not [string]::IsNullOrWhiteSpace($_)})){$lines.Add($line)}
    }
    [IO.File]::WriteAllText((Join-Path $output 'audit.jsonl'),($lines -join "`n")+"`n",$encoding)
    $audit=@($lines|ForEach-Object {$_|ConvertFrom-Json -Depth 30 -DateKind String})
    foreach($id in $script:auditIds){Assert-Bench (@($audit|Where-Object id -CEQ $id).Count -eq 1) 'audit_id_missing_or_duplicate'}
    $blocked=@($audit|Where-Object id -CEQ $denied.audit_id)
    Assert-Bench ($blocked[0].tool -ceq 'ui_action' -and $blocked[0].result -ceq 'E_CONFIRM_TIMEOUT') 'timeout_audit_mismatch'
    foreach($id in @($focused.audit_id,$typed.audit_id)){
        $entry=@($audit|Where-Object id -CEQ $id)[0]
        Assert-Bench ($entry.result -ceq 'OK' -and $entry.channel -ceq 'a11y') 'ordinary_action_audit_mismatch'
    }
    $summary.audit_verified=$true; $summary.status='passed'
}catch{
    $summary.failure_phase=$script:phase
    # Exception dumps can carry request headers or native context; persist only the named failure.
    $reason=$_.Exception.Message
    $summary.failure_reason=if($reason -cmatch '^[a-z][a-z0-9_-]+$'){$reason}else{'testbench_exception_'+$_.Exception.GetType().Name}
}finally{
    $token=$null
    if($null -ne $client){$client.Dispose()}
    if($forwardAdded -and $null -ne $server -and -not $server.Process.HasExited){try{[void](Invoke-BenchAdb @('forward','--remove',"tcp:$HttpPort") 'remove-owned-forward' 10)}catch{}}
    if($null -ne $emulator){
        try{
            if($emulatorVerified -and -not $emulator.Process.HasExited){try{[void](Invoke-BenchAdb @('emu','kill') 'stop-owned-emulator' 10)}catch{}}
            if(-not $emulator.Process.WaitForExit(15000)){$emulator.Process.Kill($true);$emulator.Process.WaitForExit()}
            $summary.emulator_process_stopped=$emulator.Process.HasExited
            [void](Save-BenchProcess $emulator 'emulator')
        }catch{$summary.emulator_process_stopped=$false}finally{$emulator.Process.Dispose()}
    }
    if($null -ne $server){
        try{
            if(-not $server.Process.HasExited){$server.Process.Kill($true);$server.Process.WaitForExit()}
            $summary.adb_server_process_stopped=$server.Process.HasExited
            [void](Save-BenchProcess $server 'adb-server')
        }catch{$summary.adb_server_process_stopped=$false}finally{$server.Process.Dispose()}
        try{
            $remaining=@(Get-BenchPortListeners @($AdbServerPort,$ConsolePort,($ConsolePort+1),$HttpPort))
            $summary.remaining_listener_owners=@($remaining|Select-Object LocalAddress,LocalPort,OwningProcess)
            $summary.declared_ports_released=$remaining.Count -eq 0
            if(@($remaining|Where-Object LocalPort -EQ $AdbServerPort).Count -gt 0){$summary.adb_server_process_stopped=$false}
            if(@($remaining|Where-Object {$_.LocalPort -in @($ConsolePort,($ConsolePort+1))}).Count -gt 0){$summary.emulator_process_stopped=$false}
        }catch{$summary.declared_ports_released='UNKNOWN';$summary.adb_server_process_stopped=$false}
    }
    if($summary.status -ceq 'passed' -and ($summary.emulator_process_stopped -cne $true -or $summary.adb_server_process_stopped -cne $true -or $summary.declared_ports_released -cne $true)){
        $summary.status='failed';$summary.failure_phase='cleanup';$summary.failure_reason='owned_process_shutdown_unproven'
    }
    $summary.elapsed_seconds=[int]$clock.Elapsed.TotalSeconds
    Write-BenchJson 'summary.json' $summary
    Write-Host ('local testbench: '+$summary.status+'; phase='+$script:phase+'; production_execution_grant=false')
}
if($summary.status -cnotin @('passed','prepared_not_run')){exit 1}
