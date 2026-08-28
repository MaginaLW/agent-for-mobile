#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0;[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Text.UTF8Encoding]::new($false)
$RepoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));$Pwsh=(Get-Process -Id $PID).Path
$C1aLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1';$Validator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-validator.ps1';$Library=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b.ps1';$Tests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-host-offline.ps1'
$AdbProvenanceTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-adb-provenance-offline.ps1'
$Aapt2ProvenanceTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-aapt2-provenance-offline.ps1'
$ReadOnlyTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-readonly-offline.ps1'
$ArtifactProofTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-artifact-proof-offline.ps1'
$BuildEnvironmentTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-build-env-offline.ps1'
$AdbServerTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-adb-server-offline.ps1'
. $C1aLibrary;. $Validator;. $Library
function Invoke-C1bAuxiliaryOfflineTest([string]$Path,[string]$Operation,[string]$SuccessPattern){
    $test=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$Path) -Operation $Operation -TimeoutSec 180
    $last=@($test.Text-split'\r?\n'|Where-Object{$_-cne''})|Select-Object -Last 1
    if($last-cnotmatch$SuccessPattern){throw "$Operation summary 欺骗：$last"}
}
Invoke-C1bAuxiliaryOfflineTest $AdbProvenanceTests 'C1b adb provenance offline tests' '^tablet-layout-c1b adb provenance offline: 6 passed, 0 failed$'
Invoke-C1bAuxiliaryOfflineTest $Aapt2ProvenanceTests 'C1b aapt2 provenance offline tests' '^tablet-layout-c1b aapt2 provenance offline: 15 passed, 0 failed, 7 aapt2 executions$'
Invoke-C1bAuxiliaryOfflineTest $ReadOnlyTests 'C1b host mechanical read-only offline tests' '^RESULT passed=70 failed=0$'
Invoke-C1bAuxiliaryOfflineTest $ArtifactProofTests 'C1b artifact proof offline tests' '^tablet-layout-c1b artifact proof offline: 32 passed, 0 failed$'
Invoke-C1bAuxiliaryOfflineTest $BuildEnvironmentTests 'C1b build environment offline tests' '^tablet-layout-c1b build environment offline: 26 passed, 0 failed, 0 JDK/Gradle executions$'
Invoke-C1bAuxiliaryOfflineTest $AdbServerTests 'C1b private adb server offline tests' '^\{"schema":"tablet-layout-c1b-adb-server-offline/v1","passed":16,"failed":0,"real_adb_executed":false,"real_jdk_or_gradle_executed":false\}$'
$gateRunId='c1b-host-gate-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$gateStartedAtUtc=[DateTimeOffset]::UtcNow;$gateStopwatch=[Diagnostics.Stopwatch]::StartNew()
try{$result=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$Tests,'-GateRunId',$gateRunId) -Operation 'C1b host fake-ADB offline tests' -TimeoutSec 300}
finally{$gateStopwatch.Stop();$gateCompletedAtUtc=[DateTimeOffset]::UtcNow}
if($result.Text-cnotmatch'^([^\r\n]+)\r?\n$'){throw 'C1b host tests 必须只输出一行 summary。'};$summaryRaw=$Matches[1]
$gateElapsedMilliseconds=[long]$gateStopwatch.ElapsedMilliseconds
$summary=ConvertFrom-TL1C1bOfflineSummary $summaryRaw $gateRunId $gateStartedAtUtc $gateCompletedAtUtc $gateElapsedMilliseconds
$checks=Join-Path $RepoRoot '.checks';if(-not(Test-Path -LiteralPath $checks -PathType Container)){[void](New-Item -ItemType Directory -Path $checks)}
$destination=Join-Path $checks 'tablet-tl1-c1b-host-v1-offline-gate.summary.json';$temporary=Join-Path $checks ('.c1b-host-'+[guid]::NewGuid().ToString('N')+'.tmp')
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($summaryRaw)
try{
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($temporary,$destination,$true)
    $readback=[IO.File]::ReadAllBytes($destination);try{$raw=ConvertFrom-TL1C1aStrictUtf8 $readback 'C1b host gate summary readback';[void](ConvertFrom-TL1C1bOfflineSummary $raw $gateRunId $gateStartedAtUtc $gateCompletedAtUtc $gateElapsedMilliseconds);if((Get-TL1C1aSha256Bytes $readback)-cne(Get-TL1C1aSha256Bytes $bytes)){throw 'C1b host gate summary 写后 hash 漂移。'}}finally{[Array]::Clear($readback,0,$readback.Length)}
}finally{[Array]::Clear($bytes,0,$bytes.Length);if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
Write-Host "C1b host fake-ADB offline gate passed: $($summary.test_case_count) cases; $destination"
