#Requires -Version 7.5
[CmdletBinding()]param()
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0;[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$OutputEncoding=[Text.UTF8Encoding]::new($false)
$RepoRoot=[IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent));$Pwsh=(Get-Process -Id $PID).Path
$C1aLibrary=Join-Path $PSScriptRoot 'lib\tablet-layout-c1a.ps1';$Validator=Join-Path $PSScriptRoot 'lib\tablet-layout-observation-c1b-v1-validator.ps1';$Library=Join-Path $PSScriptRoot 'lib\tablet-layout-c1b.ps1';$Tests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-host-offline.ps1'
. $C1aLibrary;. $Validator;. $Library
$gateRunId='c1b-host-gate-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$result=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$Tests,'-GateRunId',$gateRunId) -Operation 'C1b host fake-ADB offline tests' -TimeoutSec 180
if($result.Text-cnotmatch'^([^\r\n]+)\r?\n$'){throw 'C1b host tests 必须只输出一行 summary。'};$summaryRaw=$Matches[1]
$summary=ConvertFrom-TL1C1bOfflineSummary $summaryRaw $gateRunId
$checks=Join-Path $RepoRoot '.checks';if(-not(Test-Path -LiteralPath $checks -PathType Container)){[void](New-Item -ItemType Directory -Path $checks)}
$destination=Join-Path $checks 'tablet-tl1-c1b-host-v1-offline-gate.summary.json';$temporary=Join-Path $checks ('.c1b-host-'+[guid]::NewGuid().ToString('N')+'.tmp')
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($summaryRaw)
try{
    $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    [IO.File]::Move($temporary,$destination,$true)
    $readback=[IO.File]::ReadAllBytes($destination);try{$raw=ConvertFrom-TL1C1aStrictUtf8 $readback 'C1b host gate summary readback';[void](ConvertFrom-TL1C1bOfflineSummary $raw $gateRunId);if((Get-TL1C1aSha256Bytes $readback)-cne(Get-TL1C1aSha256Bytes $bytes)){throw 'C1b host gate summary 写后 hash 漂移。'}}finally{[Array]::Clear($readback,0,$readback.Length)}
}finally{[Array]::Clear($bytes,0,$bytes.Length);if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
Write-Host "C1b host fake-ADB offline gate passed: $($summary.test_case_count) cases; $destination"
