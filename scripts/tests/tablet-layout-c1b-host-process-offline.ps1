#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1a.ps1')
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b.ps1')
$passed=0;$assertions=0
function Assert-True([bool]$Condition,[string]$Message){$script:assertions++;if(-not$Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$caught=$false;try{&$Action}catch{$caught=$true};Assert-True $caught $Message}
function Pass([string]$Name,[scriptblock]$Action){&$Action;$script:passed++}
function Get-Failure([string]$Name){
    $caught=$null
    try{[void](Invoke-TL1C1bHostOfflineTests $script:fixtureRoot ('c1b-host-gate-'+$Name.Replace('_','-')))}catch{$caught=$_.Exception}
    Assert-True ($null-ne$caught) 'fixture failure missing'
    $diagnostic=$caught.Data['TL1C1bHostOfflineProcessDiagnostic']
    if($null-eq$diagnostic){throw ('bounded diagnostic missing: '+(ConvertTo-TL1C1aFailureDiagnostic $caught.ToString() @($script:fixtureRoot)))}
    Assert-True ($null-ne$diagnostic-and$diagnostic.schema-ceq'tablet-layout-c1b-host-process/v1') 'bounded diagnostic missing'
    Assert-True ($diagnostic.cleanup_completed-and$diagnostic.exit_observed-and$diagnostic.stdout_eof-and$diagnostic.stderr_eof) 'native exit/EOF/cleanup missing'
    return [pscustomobject]@{Exception=$caught;Diagnostic=$diagnostic}
}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('tl1-c1b-host-process-'+[guid]::NewGuid().ToString('N'))
$fixtureRoot=Join-Path $tempRoot 'repo'
$fixtureTests=Join-Path $fixtureRoot 'scripts/tests'
[void][IO.Directory]::CreateDirectory($fixtureTests)
$fixture=@'
param([string]$GateRunId)
# HOST_ENTRY_CWD_INITIALIZATION
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$mode=$GateRunId.Substring('c1b-host-gate-'.Length).Replace('-','_')
switch($mode){
 compile{
  . (Join-Path $PSScriptRoot '../lib/tablet-layout-c1a.ps1')
  $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  $source=Join-Path $PSScriptRoot 'fake-adb.cs';$exe=Join-Path $PSScriptRoot 'fake-adb.exe'
  $r=Invoke-TL1C1aProcess -FilePath $compiler -Arguments @('/nologo','/utf8output','/target:exe',"/out:$exe",$source) -Operation 'E2E fake adb compile' -TimeoutSec 30 -FailureDiagnostics
  [ordered]@{compiler_exit=$r.ExitCode;source_sha256=(Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant();exe_exists=[IO.File]::Exists($exe);exe_executed=$false}|ConvertTo-Json -Compress
  exit 0
 }
 compiler_fail{
  . (Join-Path $PSScriptRoot '../lib/tablet-layout-c1a.ps1')
  $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  $source=Join-Path $PSScriptRoot 'bad.cs';[IO.File]::WriteAllText($source,'public class Bad { ??? }')
  [void](Invoke-TL1C1aProcess -FilePath $compiler -Arguments @('/nologo','/utf8output','/target:exe',('/out:'+(Join-Path $PSScriptRoot 'bad.exe')),$source) -Operation 'E2E fake adb compile' -TimeoutSec 30 -FailureDiagnostics)
  exit 91
 }
 cwd{
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path ([Environment]::SystemDirectory) 'cmd.exe'))
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true
  foreach($arg in @('/d','/c','cd')){$start.ArgumentList.Add($arg)}
  $child=[Diagnostics.Process]::Start($start);$childText=$child.StandardOutput.ReadToEnd()
  if(-not$child.WaitForExit(5000)){throw 'cwd child did not exit'}
  [ordered]@{powershell_cwd=$PWD.ProviderPath;native_cwd=[Environment]::CurrentDirectory;child_cwd=$childText.Trim();child_exit=$child.ExitCode}|ConvertTo-Json -Compress
  $child.Dispose();exit 0
 }
 normal{[Console]::Out.Write("fixture-ok`n");[Console]::Error.Write('fixture-stderr');exit 0}
 nonzero{[Console]::Out.Write("public-failure`ntoken=DO_NOT_ECHO_TEST_SECRET`n$PSScriptRoot`n");[Console]::Error.Write('safe-error');exit 7}
 exact{[Console]::Out.Write('x'*1048576);exit 0}
 overflow{[Console]::Out.Write('x'*1048577);exit 0}
 stderr_overflow{[Console]::Error.Write('x'*1048577);exit 0}
 invalid_utf8{$stream=[Console]::OpenStandardOutput();$stream.WriteByte(255);$stream.Flush();exit 0}
 default{
  if($mode-cnotin@('timeout','parent_exit')){exit 91}
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName=[Environment]::ProcessPath;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($arg in @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 90')){$start.ArgumentList.Add($arg)}
  $child=[Diagnostics.Process]::Start($start)
  [IO.File]::WriteAllText((Join-Path $PSScriptRoot ($mode+'.pid')),[string]$child.Id)
  if($mode-ceq'parent_exit'){exit 0}
  Start-Sleep -Seconds 90
 }
}
'@
$hostTokens=$null;$hostErrors=$null
$hostAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'tablet-layout-c1b-host-offline.ps1'),[ref]$hostTokens,[ref]$hostErrors)
if($hostErrors.Count-ne0){throw 'host entry AST invalid'}
$initializers=@($hostAst.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.AssignmentStatementAst]-and$_.Left.Extent.Text-cin@('$RepoRoot','[Environment]::CurrentDirectory')})
if($initializers.Count-ne2-or$initializers[0].Extent.Text-cne'$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ''..\..''))'-or$initializers[1].Extent.Text-cne'[Environment]::CurrentDirectory=$RepoRoot'){throw 'fixed host cwd initialization changed'}
$fixture=$fixture.Replace('# HOST_ENTRY_CWD_INITIALIZATION',(($initializers|ForEach-Object{$_.Extent.Text})-join"`n"))
[void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'scripts/lib'))
Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1a.ps1') -Destination (Join-Path $fixtureRoot 'scripts/lib/tablet-layout-c1a.ps1')
$e2eTokens=$null;$e2eErrors=$null
$e2eAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'tablet-layout-c1b-host-e2e.ps1'),[ref]$e2eTokens,[ref]$e2eErrors)
$fakeAssignments=@($e2eAst.FindAll({param($n)$n-is[Management.Automation.Language.AssignmentStatementAst]-and$n.Left-is[Management.Automation.Language.VariableExpressionAst]-and$n.Left.VariablePath.UserPath-ceq'fakeSource'},$true))
if($e2eErrors.Count-ne0-or$fakeAssignments.Count-ne1){throw 'E2E fake source assignment invalid'}
$fakeLiterals=@($fakeAssignments[0].Right.FindAll({param($n)$n-is[Management.Automation.Language.StringConstantExpressionAst]-and$n.StringConstantType-eq[Management.Automation.Language.StringConstantType]::SingleQuotedHereString},$true))
if($fakeLiterals.Count-ne1){throw 'E2E fake source literal invalid'}
$fakeSourcePath=Join-Path $fixtureTests 'fake-adb.cs'
[IO.File]::WriteAllText($fakeSourcePath,$fakeLiterals[0].Value,[Text.UTF8Encoding]::new($false))
$fakeSourceHash=(Get-FileHash -LiteralPath $fakeSourcePath).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $fixtureTests 'tablet-layout-c1b-host-offline.ps1'),$fixture,[Text.UTF8Encoding]::new($false))
try{
    Pass fixed_surface {
        $command=Get-Command Invoke-TL1C1bHostOfflineTests
        Assert-True ($script:TL1C1bHostOfflineTimeoutSeconds-eq600) 'production budget not 600'
        Assert-True (-not$command.Parameters.ContainsKey('TimeoutSec')-and-not$command.Parameters.ContainsKey('FilePath')-and-not$command.Parameters.ContainsKey('Arguments')) 'offline surface accepts arbitrary process'
        Assert-Throws {Invoke-TL1C1bHostOfflineTests ($fixtureRoot+'/../repo') 'c1b-host-gate-normal'} 'traversal accepted'
        Assert-Throws {Invoke-TL1C1bHostOfflineTests ($fixtureRoot+':alternate') 'c1b-host-gate-normal'} 'ADS accepted'
        Assert-Throws {Invoke-TL1C1bHostOfflineTests $fixtureRoot 'bad gate id'} 'gate injection accepted'
        Assert-Throws {Invoke-TL1C1bHostOfflineTests $tempRoot 'c1b-host-gate-normal'} 'missing fixed test accepted'
    }
    Pass reparse_rejection {
        $linkRoot=Join-Path $tempRoot 'linked';[void][IO.Directory]::CreateDirectory((Join-Path $linkRoot 'scripts'))
        $junction=Join-Path $linkRoot 'scripts/tests'
        [void](New-Item -ItemType Junction -Path $junction -Target $fixtureTests)
        try{Assert-Throws {Invoke-TL1C1bHostOfflineTests $linkRoot 'c1b-host-gate-normal'} 'junction escaped fixed root'}
        finally{[IO.Directory]::Delete($junction)}
    }
    Pass normal {
        $r=Invoke-TL1C1bHostOfflineTests $fixtureRoot 'c1b-host-gate-normal'
        Assert-True ($r.ExitCode-eq0-and$r.Text-ceq"fixture-ok`n"-and$r.Stderr-ceq'fixture-stderr') 'normal capture mismatch'
        Assert-True ($r.Diagnostic.terminal_substage-ceq'none'-and$r.Diagnostic.exit_code-eq0-and$r.Diagnostic.stdout_eof-and$r.Diagnostic.stderr_eof-and$r.Diagnostic.cleanup_completed) 'normal terminal proof missing'
    }
    Pass current_directory {
        $r=Invoke-TL1C1bHostOfflineTests $fixtureRoot 'c1b-host-gate-cwd';$cwd=$r.Text|ConvertFrom-Json
        Assert-True ($cwd.powershell_cwd-ceq$fixtureRoot) 'PowerShell cwd is not fixed repo'
        Assert-True ($cwd.native_cwd-ceq$fixtureRoot) 'native cwd is not fixed repo'
        Assert-True ($cwd.child_cwd-ceq$fixtureRoot-and$cwd.child_exit-eq0) 'native child did not inherit repo cwd'
    }
    Pass same_source_fake_compile {
        $r=Invoke-TL1C1bHostOfflineTests $fixtureRoot 'c1b-host-gate-compile';$compile=$r.Text|ConvertFrom-Json
        Assert-True ($compile.compiler_exit-eq0-and$compile.exe_exists-and-not$compile.exe_executed-and$compile.source_sha256-ceq$fakeSourceHash) 'same-source E2E fake compile failed or executed'
    }
    Pass compiler_failure_diagnostic {
        $r=Get-Failure compiler_fail
        Assert-True ($r.Diagnostic.terminal_substage-ceq'process_exit'-and$r.Diagnostic.exit_code-eq1) 'compiler failure native exit missing'
        Assert-True ($r.Exception.Message.Contains('error CS')-and-not$r.Exception.Message.Contains($fixtureRoot)-and-not$r.Exception.Message.Contains('不是 strict UTF-8')) 'bounded UTF-8 compiler diagnostic missing or leaked path'
    }
    Pass nonzero_sanitized {
        $r=Get-Failure nonzero
        Assert-True ($r.Diagnostic.terminal_substage-ceq'process_exit'-and$r.Diagnostic.exit_code-eq7) 'native nonzero missing'
        Assert-True ($r.Exception.Message.Contains('public-failure')-and-not$r.Exception.Message.Contains('DO_NOT_ECHO_TEST_SECRET')-and-not$r.Exception.Message.Contains($tempRoot)-and$r.Exception.InnerException-eq$null) 'failure diagnostic leaked raw content'
    }
    Pass exact_output_boundary {
        $r=Invoke-TL1C1bHostOfflineTests $fixtureRoot 'c1b-host-gate-exact'
        Assert-True ($r.Bytes.Length-eq1048576-and$r.Diagnostic.stdout_captured_bytes-eq1048576-and$r.Diagnostic.stdout_observed_bytes-eq1048576) 'exact output bound rejected or truncated'
    }
    foreach($mode in @('overflow','stderr_overflow')){
        Pass $mode {
            $r=Get-Failure $mode
            Assert-True ($r.Diagnostic.terminal_substage-ceq'output_overflow') 'output overflow classification missing'
            $stream=if($mode-ceq'overflow'){'stdout'}else{'stderr'}
            Assert-True ($r.Diagnostic."${stream}_observed_bytes"-gt1048576-and$r.Diagnostic."${stream}_captured_bytes"-eq1048576) 'hard output cap missing'
        }
    }
    Pass invalid_utf8 {
        $r=Get-Failure invalid_utf8
        Assert-True ($r.Diagnostic.terminal_substage-ceq'utf8') 'invalid UTF-8 accepted'
    }
    # 仅本测试进程的 script scope 注入短预算；公开入口没有 timeout 参数，生产常量不改写。
    $script:TL1C1bHostOfflineTimeoutSeconds=2
    foreach($mode in @('timeout','parent_exit')){
        Pass $mode {
            $timer=[Diagnostics.Stopwatch]::StartNew();$r=Get-Failure $mode;$timer.Stop()
            Assert-True ($r.Diagnostic.terminal_substage-ceq'timeout'-and$timer.Elapsed.TotalSeconds-lt10) 'timeout/EOF not bounded'
            if($mode-ceq'parent_exit'){Assert-True ($r.Diagnostic.exit_code-eq0) 'fixture parent did not exit before child'}
            $childId=[int][IO.File]::ReadAllText((Join-Path $fixtureTests ($mode+'.pid')))
            Assert-True ($null-eq(Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'owned descendant survived cleanup'
        }
    }
    $script:TL1C1bHostOfflineTimeoutSeconds=600
    Pass summary_boundaries {
        # 运行原 host suite 的纯 summary case，不编译 fake-ADB、不进入 E2E。
        $source=Join-Path $PSScriptRoot 'tablet-layout-c1b-host-offline.ps1'
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
        Assert-True ($errors.Count-eq0) 'host suite AST invalid'
        $cases=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]-and$n.GetCommandName()-ceq'Pass'-and$n.CommandElements.Count-eq3-and$n.CommandElements[1].Extent.Text-ceq'summary_deception_rejection'},$true))
        Assert-True ($cases.Count-eq1) 'summary case not unique'
        $GateRunId='c1b-host-gate-summary-boundary'
        & ([scriptblock]::Create($cases[0].CommandElements[2].ScriptBlock.Extent.Text.TrimStart('{').TrimEnd('}')))
    }
    [pscustomobject][ordered]@{schema='tablet-layout-c1b-host-process-offline/v1';passed=$passed;failed=0;assertions=$assertions;real_adb_call_count=0;host_e2e_executed=$false}|ConvertTo-Json -Compress
}finally{
    $script:TL1C1bHostOfflineTimeoutSeconds=600
    $resolved=[IO.Path]::GetFullPath($tempRoot)
    if(-not$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetFileName($resolved)-cnotmatch'^tl1-c1b-host-process-[a-f0-9]{32}$'){throw 'fixture cleanup path rejected'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
