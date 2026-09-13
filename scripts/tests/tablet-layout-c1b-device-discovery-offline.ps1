#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1')
$script:Passed = 0
$script:Failed = 0
$script:MockCalls = [Collections.Generic.List[object]]::new()
$script:MockResult = $null
$script:MockFailure = $null

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; "PASS $Name" }
    catch { $script:Failed++; "FAIL $Name :: $($_.Exception.Message)" }
}
function Set-MockResult([string]$Text, [string]$Stderr = '') {
    $script:MockCalls.Clear()
    $script:MockFailure = $null
    $script:MockResult = [pscustomobject]@{
        ExitCode = 0
        Bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
        Text = $Text
        Stderr = $Stderr
    }
}
function Invoke-MockProcess([string]$Kind, [string[]]$Arguments) {
    $script:MockCalls.Add([pscustomobject]@{ Kind = $Kind; Arguments = $Arguments })
    if ($null -ne $script:MockFailure) { throw $script:MockFailure }
    return $script:MockResult
}
# 两个实际进程入口均替换为内存 mock；本文件不创建进程、文件或真实 ADB server。
function Invoke-TL1C1aProcess {
    param($FilePath, [string[]]$Arguments, $Operation, $Environment, [switch]$ClearEnvironment)
    return Invoke-MockProcess 'ordinary' $Arguments
}
function Invoke-TL1C1bPrivateAdbGuardedProcess {
    param($Guard, $FilePath, [string[]]$Arguments, $Operation,
        $ProcessEnvironment, [switch]$ClearEnvironment, $TimeoutSec, $ClientKind)
    Assert-True ($TimeoutSec -eq 30 -and $ClientKind -ceq 'Adb' -and $ClearEnvironment) `
        'guarded invocation shape changed'
    return Invoke-MockProcess 'private' $Arguments
}
function Invoke-Discovery([switch]$Private, [switch]$WithoutDiagnostic) {
    $parameters = @{ AdbPath = 'offline-mock-only' }
    if ($Private) {
        $parameters.ProcessEnvironment = @{ ADB_SERVER_SOCKET = 'tcp:127.0.0.1:55000' }
        $parameters.ClearEnvironment = $true
        $parameters.PrivateAdbServerGuard = [pscustomobject]@{ test_guard = $true }
    }
    $diagnostic = $null
    if (-not $WithoutDiagnostic) { $parameters.DiscoveryDiagnostic = [ref]$diagnostic }
    $serial = $null
    $failure = $null
    try { $serial = Get-TL1C1aSingleDevice @parameters } catch { $failure = $_ }
    Assert-True ($script:MockCalls.Count -eq 1) 'discovery added a call or retry'
    $expectedArgs = if ($Private) { '-H|127.0.0.1|-P|55000|devices' } else { 'devices' }
    Assert-True (($script:MockCalls[0].Arguments -join '|') -ceq $expectedArgs) `
        'discovery command changed'
    return [pscustomobject]@{ Serial = $serial; Failure = $failure; Diagnostic = $diagnostic }
}
function Assert-Diagnostic($Diagnostic, [string]$Outcome, $Count, [string]$Stage) {
    Assert-True ((@($Diagnostic.PSObject.Properties.Name) -join ',') -ceq
        ('schema,started_utc,completed_utc,stdout_bytes,stdout_capture_status,' +
        'stdout_observed_byte_count,stderr_bytes,stderr_capture_status,stderr_observed_byte_count,' +
        'stderr_capture_basis,actual_exit,device_count,device_states,outcome,failure_stage,client_failure_substage')) `
        'diagnostic fields are not closed'
    Assert-True ($Diagnostic.schema -ceq 'tablet-layout-device-discovery-diagnostic/v1') 'schema mismatch'
    $start = [DateTimeOffset]::Parse($Diagnostic.started_utc)
    $end = [DateTimeOffset]::Parse($Diagnostic.completed_utc)
    Assert-True ($end -ge $start -and $start.Offset -eq [TimeSpan]::Zero -and
        $end.Offset -eq [TimeSpan]::Zero) 'UTC window missing or inverted'
    Assert-True ($Diagnostic.outcome -ceq $Outcome) 'outcome mismatch'
    Assert-True ($Diagnostic.device_count -ceq $Count) 'device count mismatch'
    Assert-True ([string]$Diagnostic.failure_stage -ceq $Stage) 'failure stage mismatch'
    if ($null -eq $Count) {
        Assert-True ($null -eq $Diagnostic.device_states) 'partial parser count/states leaked'
    }
}

foreach ($private in @($false, $true)) {
    $mode = if ($private) { 'private' } else { 'ordinary' }
    Test-Case "$mode success preserves serial and complete independent bytes" {
        Set-MockResult "List of devices attached`r`nFAKE123`tdevice`r`n" "诊断`r`n"
        $result = Invoke-Discovery -Private:$private
        Assert-True ($null -eq $result.Failure -and $result.Serial -ceq 'FAKE123') 'serial changed'
        $d = $result.Diagnostic
        Assert-Diagnostic $d 'succeeded' 1 ''
        Assert-True (($d.device_states -join ',') -ceq 'device' -and $d.actual_exit -eq 0) 'state/exit mismatch'
        Assert-True ($d.stdout_capture_status -ceq 'complete' -and
            $d.stdout_observed_byte_count -eq $script:MockResult.Bytes.Length -and
            [Convert]::ToBase64String($d.stdout_bytes) -ceq
                [Convert]::ToBase64String($script:MockResult.Bytes)) 'stdout not exact'
        Assert-True ($d.stderr_capture_status -ceq 'complete' -and
            $d.stderr_capture_basis -ceq 'strict_utf8_reencoded_from_process_result' -and
            $d.stderr_observed_byte_count -eq 8 -and
            [Text.Encoding]::UTF8.GetString($d.stderr_bytes) -ceq "诊断`r`n") 'stderr basis/bytes mismatch'
        $script:MockResult.Bytes[0] = 0
        Assert-True ($d.stdout_bytes[0] -eq [byte][char]'L') 'stdout shares result buffer'
        $d.device_states[0] = 'changed'
        Set-MockResult "List of devices attached`nFAKE123`tdevice`n"
        $next = Invoke-Discovery -Private:$private
        Assert-True ($next.Diagnostic.device_states[0] -ceq 'device' -and
            -not [object]::ReferenceEquals($d, $next.Diagnostic)) 'diagnostics share mutable state'
    }
    Test-Case "$mode optional ref remains optional" {
        Set-MockResult "List of devices attached`nFAKE123`tdevice`n"
        $result = Invoke-Discovery -Private:$private -WithoutDiagnostic
        Assert-True ($null -eq $result.Failure -and $result.Serial -ceq 'FAKE123' -and
            $null -eq $result.Diagnostic) 'legacy invocation changed'
    }
    foreach ($case in @(
        @{ Name = 'zero'; Body = "List of devices attached`n"; Count = 0; States = ''; Stage = 'device_count' }
        @{ Name = 'multi'; Body = "List of devices attached`nFAKE123`tdevice`nOTHER456`tdevice`n"; Count = 2; States = 'device,device'; Stage = 'device_count' }
        @{ Name = 'unauthorized'; Body = "List of devices attached`nFAKE123`tunauthorized`n"; Count = 1; States = 'unauthorized'; Stage = 'device_state' }
        @{ Name = 'offline'; Body = "List of devices attached`nFAKE123`toffline`n"; Count = 1; States = 'offline'; Stage = 'device_state' }
        @{ Name = 'permission'; Body = "List of devices attached`nFAKE123`tno permissions (diagnostic detail)`n"; Count = 1; States = 'no permissions'; Stage = 'device_state' }
        @{ Name = 'invalid serial'; Body = "List of devices attached`nBAD/123`tdevice`n"; Count = 1; States = 'device'; Stage = 'serial' }
        @{ Name = 'empty stdout'; Body = ''; Count = $null; States = $null; Stage = 'parser' }
        @{ Name = 'missing header'; Body = "FAKE123`tdevice`n"; Count = $null; States = $null; Stage = 'parser' }
        @{ Name = 'duplicate header'; Body = "List of devices attached`nList of devices attached`n"; Count = $null; States = $null; Stage = 'parser' }
        @{ Name = 'malformed row'; Body = "List of devices attached`nFAKE123`n"; Count = $null; States = $null; Stage = 'parser' }
        @{ Name = 'unknown transport after valid row'; Body = "List of devices attached`nFAKE123`tdevice`nOTHER456`trecovery`n"; Count = $null; States = $null; Stage = 'parser' }
    )) {
        Test-Case "$mode $($case.Name) retains evidence and original failure" {
            Set-MockResult $case.Body
            $result = Invoke-Discovery -Private:$private
            Assert-True ($null -ne $result.Failure -and $null -eq $result.Serial) 'invalid device accepted'
            Assert-Diagnostic $result.Diagnostic 'failed' $case.Count $case.Stage
            Assert-True ($result.Diagnostic.actual_exit -eq 0 -and
                $result.Diagnostic.stdout_capture_status -ceq 'complete' -and
                $result.Diagnostic.stderr_capture_status -ceq 'complete' -and
                $null -ne $result.Diagnostic.stderr_bytes -and
                $result.Diagnostic.stderr_bytes.Length -eq 0) 'empty stream was invented or lost'
            if ($null -ne $case.Count) {
                Assert-True (($result.Diagnostic.device_states -join ',') -ceq $case.States) 'state mismatch'
            }
            Set-MockResult $case.Body
            $legacy = Invoke-Discovery -Private:$private -WithoutDiagnostic
            Assert-True ($legacy.Failure.Exception.Message -ceq $result.Failure.Exception.Message) `
                'diagnostic replaced original parser exception'
        }
    }
    Test-Case "$mode transport exception leaves raw unknown and is rethrown" {
        Set-MockResult 'unused'
        $exception = [InvalidOperationException]::new('opaque transport failure')
        $script:MockFailure = $exception
        $result = Invoke-Discovery -Private:$private
        Assert-True ([object]::ReferenceEquals($exception, $result.Failure.Exception)) 'original exception replaced'
        Assert-Diagnostic $result.Diagnostic 'failed' $null 'client'
        foreach ($name in @('stdout_bytes','stderr_bytes','stdout_observed_byte_count',
                'stderr_observed_byte_count','stderr_capture_basis','actual_exit','client_failure_substage')) {
            Assert-True ($null -eq $result.Diagnostic.$name) 'unavailable evidence fabricated'
        }
        Assert-True ($result.Diagnostic.stdout_capture_status -ceq 'unavailable' -and
            $result.Diagnostic.stderr_capture_status -ceq 'unavailable') 'unknown stream status changed'
        Assert-True (($result.Diagnostic | ConvertTo-Json -Depth 8 -Compress) -cnotmatch 'opaque') `
            'exception string copied into evidence'
    }
    foreach ($length in @(65536, 65537)) {
        Test-Case "$mode diagnostic byte cap $length preserves process and parser behavior" {
            $body = "List of devices attached`nFAKE123`tdevice`n"
            $body += ' ' * ($length - [Text.Encoding]::UTF8.GetByteCount($body))
            Set-MockResult $body ('x' * $length)
            $result = Invoke-Discovery -Private:$private
            Assert-True ($null -eq $result.Failure -and $result.Serial -ceq 'FAKE123') 'cap changed execution outcome'
            foreach ($stream in @('stdout','stderr')) {
                $status = if ($length -eq 65536) { 'complete' } else { 'over_limit' }
                Assert-True ($result.Diagnostic.($stream + '_capture_status') -ceq $status -and
                    $result.Diagnostic.($stream + '_observed_byte_count') -eq $length) 'cap facts mismatch'
                if ($length -gt 65536) {
                    Assert-True ($null -eq $result.Diagnostic.($stream + '_bytes')) 'over-limit raw was truncated'
                } else {
                    Assert-True ($result.Diagnostic.($stream + '_bytes').Length -eq 65536) 'boundary raw lost'
                }
            }
        }
    }
}

foreach ($substage in @('process_exit','timeout')) {
    Test-Case "guarded $substage copies only closed client facts" {
        Set-MockResult 'unused'
        $exception = [InvalidOperationException]::new('opaque client failure')
        $exitObserved = $substage -ceq 'process_exit'
        $exception.Data['TL1C1bPrivateAdbClientDiagnostic'] = [pscustomobject]@{
            schema = 'tablet-layout-c1b-private-adb-guarded-client-diagnostic/v1'
            client_kind = 'Adb'; operation_class = 'device_discovery'; failure_substage = $substage
            untrusted_extra = 'never-copy-this'
            process = [pscustomobject]@{
                exit_observed = $exitObserved
                exit_code = if ($exitObserved) { 7 } else { $null }
                stdout = [pscustomobject]@{ observed_bytes = [long]14 }
                stderr = [pscustomobject]@{ observed_bytes = [long]23 }
            }
        }
        $script:MockFailure = $exception
        $result = Invoke-Discovery -Private
        Assert-True ([object]::ReferenceEquals($exception, $result.Failure.Exception)) 'guarded exception replaced'
        Assert-Diagnostic $result.Diagnostic 'failed' $null 'client'
        Assert-True ($result.Diagnostic.client_failure_substage -ceq $substage -and
            $result.Diagnostic.actual_exit -ceq $(if ($exitObserved) { 7 } else { $null }) -and
            $result.Diagnostic.stdout_observed_byte_count -eq 14 -and
            $result.Diagnostic.stderr_observed_byte_count -eq 23 -and
            $null -eq $result.Diagnostic.stdout_bytes -and $null -eq $result.Diagnostic.stderr_bytes) `
            'guarded facts lost or raw invented'
        Assert-True (($result.Diagnostic | ConvertTo-Json -Depth 8 -Compress) -cnotmatch 'opaque|never-copy-this') `
            'arbitrary client diagnostic content copied'
    }
}
Test-Case 'endpoint validation still precedes any client' {
    Set-MockResult 'unused'
    $diagnostic = $null
    $failure = $null
    try {
        [void](Get-TL1C1aSingleDevice -AdbPath 'offline-mock-only' `
            -ProcessEnvironment @{ ADB_SERVER_SOCKET = 'tcp:127.0.0.1:55000' } `
            -DiscoveryDiagnostic ([ref]$diagnostic))
    } catch { $failure = $_ }
    Assert-True ($null -ne $failure -and $script:MockCalls.Count -eq 0) 'endpoint guard was bypassed'
    Assert-Diagnostic $diagnostic 'failed' $null 'endpoint'
}
Test-Case 'unknown client fields cannot fabricate actual exit or replace the exception' {
    Set-MockResult 'unused'
    $exception = [InvalidOperationException]::new('opaque unknown fields')
    $exception.Data['TL1C1bPrivateAdbClientDiagnostic'] = [pscustomobject]@{
        schema = 'tablet-layout-c1b-private-adb-guarded-client-diagnostic/v1'
        client_kind = 'Adb'; operation_class = 'device_discovery'; failure_substage = 'arbitrary-text'
        process = [pscustomobject]@{
            exit_observed = 'true'; exit_code = '0'
            stdout = [pscustomobject]@{ observed_bytes = -1 }
            stderr = [pscustomobject]@{ observed_bytes = '42' }
        }
    }
    $script:MockFailure = $exception
    $result = Invoke-Discovery -Private
    Assert-True ([object]::ReferenceEquals($exception, $result.Failure.Exception) -and
        $null -eq $result.Diagnostic.actual_exit -and $null -eq $result.Diagnostic.client_failure_substage -and
        $null -eq $result.Diagnostic.stdout_observed_byte_count -and
        $null -eq $result.Diagnostic.stderr_observed_byte_count) 'untrusted client values were coerced'
}
Test-Case 'malformed client diagnostic does not replace the original exception' {
    Set-MockResult 'unused'
    $exception = [InvalidOperationException]::new('opaque malformed diagnostic')
    $exception.Data['TL1C1bPrivateAdbClientDiagnostic'] = [pscustomobject]@{ unrelated = $true }
    $script:MockFailure = $exception
    $result = Invoke-Discovery -Private
    Assert-True ([object]::ReferenceEquals($exception, $result.Failure.Exception)) `
        'diagnostic extraction replaced the original exception'
    Assert-Diagnostic $result.Diagnostic 'failed' $null 'client'
}
Test-Case 'stderr byte cap counts strict UTF8 bytes without truncating multibyte text' {
    Set-MockResult "List of devices attached`nFAKE123`tdevice`n" ('字' * 21846)
    $result = Invoke-Discovery -Private
    Assert-True ($null -eq $result.Failure -and $result.Diagnostic.stderr_capture_status -ceq 'over_limit' -and
        $result.Diagnostic.stderr_observed_byte_count -eq 65538 -and
        $null -eq $result.Diagnostic.stderr_bytes -and
        $result.Diagnostic.stderr_capture_basis -ceq 'strict_utf8_reencoded_from_process_result') `
        'stderr cap used text length or truncated a multibyte stream'
}

"device-discovery offline: $($script:Passed) passed; $($script:Failed) failed; real ADB/child processes/files=0"
if ($script:Failed -ne 0) { exit 1 }
