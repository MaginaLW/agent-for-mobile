#Requires -Version 7.6
# Maintenance template: execute only after this exact candidate full gate, exact host/preflight,
# and BuildOnly have passed and root has created/frozen this clone's binding.json.
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$repo='__REPO_ROOT__'
$expectedCommit='__CANDIDATE_SHA__'
$pwsh='__PWSH_PATH__'
$runner=Join-Path $repo 'scripts\run-tablet-layout-c1b.ps1'
$expectedRunnerHash='__INPUT_RUNNER_SHA256__'
$root=Join-Path $repo '.checks\c1b-device-once\__CANDIDATE_SHORT__\r1'
if($PSVersionTable.PSVersion.ToString()-cne'7.6.5'-or[Environment]::ProcessPath-cne$pwsh){throw 'Pinned runtime required.'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevated token required for the ACL guard.'}
$runnerGuard=[IO.File]::Open($runner,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$child=$null;$outFile=$null;$errFile=$null;$primary=$null;$childStarted=$false;$childExit=$null
$started=[DateTimeOffset]::UtcNow
function Write-NewRecord([string]$Path,$Value){
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 5 -Compress))
    $file=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
}
try{
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($runnerGuard)).ToLowerInvariant()
    if($actual-cne$expectedRunnerHash){throw 'Runner bytes changed.'}
    Write-NewRecord (Join-Path $root 'reservation.json') ([ordered]@{schema='c1b-device-cli-once/v1';commit_sha=$expectedCommit;runner_sha256=$actual;started_at_utc=$started.ToString('O');automatic_retry_count=0})
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$pwsh;$start.WorkingDirectory=$repo;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.Environment.Clear()
    $windows=[Environment]::GetFolderPath('Windows')
    $system=[Environment]::GetFolderPath('System')
    $profile=[Environment]::GetFolderPath('UserProfile')
    $local=[Environment]::GetFolderPath('LocalApplicationData')
    $cleanEnvironment=[ordered]@{
        SYSTEMROOT=$windows;WINDIR=$windows;SystemDrive=[IO.Path]::GetPathRoot($windows).TrimEnd('\')
        COMSPEC=(Join-Path $system 'cmd.exe');PATH=$system;PATHEXT='.COM;.EXE;.BAT;.CMD'
        TEMP=(Join-Path $local 'Temp');TMP=(Join-Path $local 'Temp')
        USERPROFILE=$profile;HOME=$profile;LOCALAPPDATA=$local
        APPDATA=[Environment]::GetFolderPath('ApplicationData')
        ProgramFiles=[Environment]::GetFolderPath('ProgramFiles')
        'ProgramFiles(x86)'=[Environment]::GetFolderPath('ProgramFilesX86')
        ProgramW6432=[Environment]::GetFolderPath('ProgramFiles')
        PSModulePath=((Join-Path ([IO.Path]::GetDirectoryName($pwsh)) 'Modules')+';'+(Join-Path $system 'WindowsPowerShell\v1.0\Modules'))
        OS='Windows_NT';PROCESSOR_ARCHITECTURE='AMD64'
    }
    foreach($key in $cleanEnvironment.Keys){$start.Environment[$key]=[string]$cleanEnvironment[$key]}
    $start.Environment['JAVA_HOME']=Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Java\jdk-21'
    $start.Environment['TL1_C1B_GRADLE_HOME']=Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gradle\wrapper\dists\gradle-8.9-bin\90cnw93cvbtalezasaz0blq0a\gradle-8.9'
    $sdk=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Android\Sdk'
    $start.Environment['ANDROID_SDK_ROOT']=$sdk;$start.Environment['ANDROID_HOME']=$sdk
    foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$runner,'-AdbPath',(Join-Path $sdk 'platform-tools\adb.exe'),'-ExpectedCommitSha',$expectedCommit,'-Provision')){$start.ArgumentList.Add($argument)}
    $outFile=[IO.File]::Open((Join-Path $root 'runner.stdout.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $errFile=[IO.File]::Open((Join-Path $root 'runner.stderr.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $child=[Diagnostics.Process]::new();$child.StartInfo=$start
    if(-not$child.Start()){throw 'Runner process did not start.'};$childStarted=$true
    $outTask=$child.StandardOutput.BaseStream.CopyToAsync($outFile)
    $errTask=$child.StandardError.BaseStream.CopyToAsync($errFile)
    $child.WaitForExit();$childExit=$child.ExitCode
    if(-not[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),30000)){throw 'Runner output drains did not close.'}
    $outFile.Flush($true);$errFile.Flush($true)
}catch{$primary=$_.Exception.Message}
finally{
    if($null-ne$outFile){$outFile.Dispose()};if($null-ne$errFile){$errFile.Dispose()}
    $runnerGuard.Dispose()
}
$record=[ordered]@{schema='c1b-device-cli-exit/v1';commit_sha=$expectedCommit;runner_sha256=$expectedRunnerHash;runner_started=$childStarted;runner_pid=if($childStarted){$child.Id}else{$null};runner_exit_code=$childExit;wrapper_failure=$primary;started_at_utc=$started.ToString('O');completed_at_utc=[DateTimeOffset]::UtcNow.ToString('O');automatic_retry_count=0;success_requires_runner_evidence_validation=$true}
Write-NewRecord (Join-Path $root 'exit.json') $record
if($null-ne$child){$child.Dispose()}
$record|ConvertTo-Json -Depth 5 -Compress
if($null-ne$primary){exit 1};if($null-eq$childExit){exit 1};exit $childExit