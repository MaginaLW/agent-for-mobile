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
$AttemptFailureTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-attempt-failure-offline.ps1'
$RealBuildSmokeVerifierTests=Join-Path $PSScriptRoot 'tests\tablet-layout-c1b-real-build-smoke-verifier-offline.ps1'
. $C1aLibrary;. $Validator;. $Library
function Invoke-C1bAuxiliaryOfflineTest([string]$Path,[string]$Operation,[string]$SuccessPattern){
    $test=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$Path) -Operation $Operation -TimeoutSec 180
    $last=@($test.Text-split'\r?\n'|Where-Object{$_-cne''})|Select-Object -Last 1
    if($last-cnotmatch$SuccessPattern){throw "$Operation summary 欺骗：$last"}
}
function Assert-C1bRealBuildSmokeVerifierSummaryRawElement([Text.Json.JsonElement]$Element,[string]$Path){
    if($Element.ValueKind-eq[Text.Json.JsonValueKind]::Object){
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $Element.EnumerateObject()){
            $childPath="$Path/$($property.Name)"
            if(-not$names.Add($property.Name)){throw "C1b real build smoke verifier summary duplicate JSON property：$childPath"}
            Assert-C1bRealBuildSmokeVerifierSummaryRawElement $property.Value $childPath
        }
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Array){
        $index=0;foreach($child in $Element.EnumerateArray()){Assert-C1bRealBuildSmokeVerifierSummaryRawElement $child "$Path/$index";$index++}
    }elseif($Element.ValueKind-eq[Text.Json.JsonValueKind]::Number){
        $number=$Element.GetRawText();$parsed=0L
        if($number-cnotmatch'\A(?:0|-?[1-9][0-9]*)\z'-or-not[long]::TryParse($number,[Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){throw "C1b real build smoke verifier summary noncanonical Int64：$Path"}
    }
}
function Invoke-C1bRealBuildSmokeVerifierOfflineTest([string]$Path){
    $operation='C1b real build smoke verifier offline tests'
    $test=Invoke-TL1C1aProcess -FilePath $Pwsh -Arguments @('-NoProfile','-File',$Path) -Operation $operation -TimeoutSec 180
    if($test.Stderr-cne''){throw "$operation stderr 必须 exact empty。"}
    if($test.Text-cnotmatch'\A([^\r\n]+)\r?\n\z'){throw "$operation stdout 必须 exact 单行 JSON。"};$raw=$Matches[1]
    $document=$null;try{$document=[Text.Json.JsonDocument]::Parse($raw);if($document.RootElement.ValueKind-ne[Text.Json.JsonValueKind]::Object){throw "$operation raw summary root 必须是 object。"};Assert-C1bRealBuildSmokeVerifierSummaryRawElement $document.RootElement ''}finally{if($null-ne$document){$document.Dispose()}}
    $summary=$raw|ConvertFrom-Json -Depth 20 -DateKind String -ErrorAction Stop
    if($summary-isnot[pscustomobject]){throw "$operation summary root 必须是 object。"}
    $actual=[string[]]@($summary.PSObject.Properties.Name);$expected=[string[]]@('schema','passed','failed','skipped','mutation_assertion_count','process_api_reference_count','path_capability_skip_count','captured_public_file_invocation_count','captured_public_file_rejection_count','direct_value_rejection_count','pwsh_version','failure_messages','skip_messages');[Array]::Sort($actual,[StringComparer]::Ordinal);[Array]::Sort($expected,[StringComparer]::Ordinal)
    if(($actual-join"`n")-cne($expected-join"`n")){throw "$operation summary keys 不 exact。"}
    foreach($name in @('passed','failed','skipped','mutation_assertion_count','process_api_reference_count','path_capability_skip_count','captured_public_file_invocation_count','captured_public_file_rejection_count','direct_value_rejection_count')){if($summary.PSObject.Properties[$name].Value-isnot[long]){throw "$operation $name 必须是 Int64。"}}
    if($summary.schema-isnot[string]-or$summary.pwsh_version-isnot[string]){throw "$operation schema/pwsh_version 必须是 strings。"}
    if($summary.failure_messages-isnot[Array]-or$summary.skip_messages-isnot[Array]){throw "$operation message fields 必须是 arrays。"}
    if($summary.schema-cne'tablet-layout-c1b-real-build-smoke-verifier-offline/v2'-or[long]$summary.failed-ne0-or([long]$summary.passed+[long]$summary.skipped)-ne19-or([long]$summary.mutation_assertion_count+[long]$summary.skipped)-ne217-or([long]$summary.captured_public_file_invocation_count+[long]$summary.skipped)-ne209-or([long]$summary.captured_public_file_rejection_count+[long]$summary.skipped)-ne208-or[long]$summary.direct_value_rejection_count-ne9-or[long]$summary.mutation_assertion_count-ne([long]$summary.captured_public_file_rejection_count+[long]$summary.direct_value_rejection_count)-or[long]$summary.captured_public_file_invocation_count-ne([long]$summary.captured_public_file_rejection_count+1)-or[long]$summary.process_api_reference_count-ne0-or[long]$summary.path_capability_skip_count-ne[long]$summary.skipped-or[long]$summary.skipped-lt0-or[long]$summary.skipped-gt2-or$summary.pwsh_version-cne'7.6.4'-or@($summary.failure_messages).Count-ne0-or@($summary.skip_messages).Count-ne[long]$summary.skipped){throw "$operation summary 值不 exact：$raw"}
    foreach($message in @($summary.failure_messages)+@($summary.skip_messages)){if($message-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$message)){throw "$operation message element 非法。"}}
}
Invoke-C1bAuxiliaryOfflineTest $AdbProvenanceTests 'C1b adb provenance offline tests' '^tablet-layout-c1b adb provenance offline: 6 passed, 0 failed$'
Invoke-C1bAuxiliaryOfflineTest $Aapt2ProvenanceTests 'C1b aapt2 provenance offline tests' '^tablet-layout-c1b aapt2 provenance offline: 15 passed, 0 failed, 7 aapt2 executions$'
Invoke-C1bAuxiliaryOfflineTest $ReadOnlyTests 'C1b host mechanical read-only offline tests' '^RESULT passed=74 failed=0$'
Invoke-C1bAuxiliaryOfflineTest $ArtifactProofTests 'C1b artifact proof offline tests' '^tablet-layout-c1b artifact proof offline: 32 passed, 0 failed$'
Invoke-C1bAuxiliaryOfflineTest $BuildEnvironmentTests 'C1b build environment offline tests' '^tablet-layout-c1b build environment offline: 27 passed, 0 failed, 0 JDK/Gradle executions$'
Invoke-C1bAuxiliaryOfflineTest $AdbServerTests 'C1b private adb server offline tests' '^\{"schema":"tablet-layout-c1b-adb-server-offline/v1","passed":22,"failed":0,"real_adb_executed":false,"real_jdk_or_gradle_executed":false\}$'
Invoke-C1bAuxiliaryOfflineTest $AttemptFailureTests 'C1b attempt failure schema offline tests' '^tablet-layout-c1b attempt failure schema offline: 51 passed, 0 failed$'
Invoke-C1bRealBuildSmokeVerifierOfflineTest $RealBuildSmokeVerifierTests
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
