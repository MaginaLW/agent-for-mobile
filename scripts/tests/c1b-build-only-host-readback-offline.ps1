#Requires -Version 7.6
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source=[IO.File]::ReadAllText((Join-Path $repo 'scripts/read-c1b-build-only-host.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Reader source Parser rejected.'}
# Load definitions only; never execute the reader CLI or any candidate.
foreach($definition in @($ast.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})){
    . ([scriptblock]::Create($definition.Extent.Text))
}
$privateHA=Import-C1bRBPrivateFunctions ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/c1b-host-acceptance.ps1'))) @('Assert-C1bHAKeys','Assert-C1bHAInt','Assert-C1bHABool','Assert-C1bHAString','ConvertFrom-C1bHAStrictJson','Get-C1bHAPath','New-C1bHASession','Read-C1bHAFile','Read-C1bHAJson','Close-C1bHASession','Assert-C1bHACapture','Assert-C1bHARoot','Get-C1bHAImplementationMap','Get-C1bHAObservedPin','Open-C1bHADirectories','Assert-C1bHAAbsentFile') 'C1bReadbackOfflineAuthority'
$haCommands=$privateHA.functions
$passed=0;$assertions=0;$fixtureSequence=0
function Assert-Test([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Expect-Rejected([scriptblock]$Body,[string]$Pattern){
    $caught=$null;try{& $Body}catch{$caught=$_.Exception.Message}
    Assert-Test ($null-ne$caught-and$caught-match$Pattern) "Expected closed rejection: $Pattern; actual=$caught"
}
function Test-Case([string]$Name,[scriptblock]$Body){& $Body;$script:passed++;Write-Output "PASS $Name"}
function Hash-Bytes([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
$parent=Join-Path $repo '.checks/goal-20260930/build-only-reader/fixtures'
$null=[IO.Directory]::CreateDirectory($parent)
$root=Join-Path $parent ([guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
function Write-FixtureBytes([string]$Path,[byte[]]$Bytes){
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllBytes($Path,$Bytes)
    return @{path=$Path;byte_length=[long]$Bytes.Length;sha256=(Hash-Bytes $Bytes)}
}
function Write-FixtureJson([string]$Path,$Value){
    Write-FixtureBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 30)+"`n"))
}
function New-FixtureStream {
    $hash=Hash-Bytes ([byte[]]@())
    return [ordered]@{eof=$true;aborted=$false;error=$null;overflowed=$false;observed_byte_length=0L;observed_sha256=$hash;total_byte_length=0L;sha256=$hash;captured_byte_length=0L;captured_sha256=$hash;first_byte_observed_elapsed_milliseconds=$null;eof_observed_elapsed_milliseconds=20L}
}
function New-FixtureCapture([long]$ProcessId){
    return [ordered]@{
        schema='tl1-c1b-host-process-capture/v1';status='passed';started_at_utc='2026-09-30T00:00:00.0000000Z';completed_at_utc='2026-09-30T00:00:00.0300000Z';elapsed_milliseconds=30L
        start_attempt_count=1L;start_count=1L;automatic_retry_count=0L;child_pid=$ProcessId;exit_code=0L;root_exit_confirmed=$true;natural_exit=$true
        timed_out=$false;drain_timed_out=$false;termination_requested=$false;capture_limit_bytes_per_stream=1048576L;timeout_milliseconds=2700000L;drain_timeout_milliseconds=30000L;cleanup_timeout_milliseconds=30000L;drains_completed=$true;errors=@();publication_errors=@()
        environment=[ordered]@{mode='inherit';keys=@();sha256=('a'*64)}
        cleanup=[ordered]@{scope='contained_job_processes_pipe_workers_owned_handles';job_assigned_before_resume=$true;active_process_count=0L;handles_closed=$true;failure_count=0L;errors=@();completed=$true}
        stdout=(New-FixtureStream);stderr=(New-FixtureStream)
    }
}
function New-TransportFixture([scriptblock]$Mutate={}){
    $script:fixtureSequence++
    $directory=Join-Path $root ('transport-'+$script:fixtureSequence)
    $null=[IO.Directory]::CreateDirectory($directory)
    $map=[ordered]@{candidate_sha=('a'*40);run_id='offline-run';nonce='11111111-2222-3333-4444-555555555555'}
    $launcher=New-FixtureCapture 101L;$driver=New-FixtureCapture 303L
    $launcherRoot=[ordered]@{schema='c1b-host-root-observation/v1';candidate_sha=$map.candidate_sha;phase='BuildOnly';run_id=$map.run_id;process_id=101L;native_exit_code=0L;capture_pin=$null}
    $driverRoot=[ordered]@{schema='c1b-host-root-observation/v1';candidate_sha=$map.candidate_sha;phase='BuildOnlyDriver';run_id=$map.run_id;process_id=303L;native_exit_code=0L;capture_pin=$null}
    & $Mutate $launcher $driver $launcherRoot $driverRoot
    $map.launcher_capture_pin=Write-FixtureJson (Join-Path $directory 'launcher/execution.json') $launcher
    $map.driver_capture_pin=Write-FixtureJson (Join-Path $directory 'driver/execution.json') $driver
    foreach($scope in @('launcher','driver')){foreach($stream in @('stdout','stderr')){$null=Write-FixtureBytes (Join-Path $directory "$scope/$stream.bin") ([byte[]]@())}}
    $launcherRoot.capture_pin=$map.launcher_capture_pin;$driverRoot.capture_pin=$map.driver_capture_pin
    $map.root_observation_pin=Write-FixtureJson (Join-Path $directory 'launcher-root.json') $launcherRoot
    $map.driver_root_observation_pin=Write-FixtureJson (Join-Path $directory 'driver-root.json') $driverRoot
    $map.launcher_source_pin=@{path=(Join-Path $directory 'launcher.ps1');byte_length=1L;sha256=('b'*64)}
    $map.wrapper_source_pin=@{path=(Join-Path $directory 'wrapper.ps1');byte_length=1L;sha256=('c'*64)}
    return @{map=$map;directory=$directory}
}
function Invoke-TransportFixture($Fixture){
    $session=& $haCommands['New-C1bHASession'] @($root)
    try{return Assert-C1bRBTransport $session $Fixture.map $Fixture.map.candidate_sha}
    finally{& $haCommands['Close-C1bHASession'] $session}
}
function New-ElevationFixture($Map){
    $argv=[string[]]@('-NoProfile','-File',$Map.launcher_source_pin.path,'-ExpectedLauncherSha256',$Map.launcher_source_pin.sha256)
    return [ordered]@{
        schema='c1b-build-only-elevation-result/v1';candidate_sha=$Map.candidate_sha;status='passed';run_id=$Map.run_id;nonce=$Map.nonce;invocation_count=1L;automatic_retry_count=0L;elevated_pid=202L;driver_pid=303L;token_elevated=$true
        launcher_capture_pin=$Map.launcher_capture_pin;launcher_source_pin=$Map.launcher_source_pin;wrapper_source_pin=$Map.wrapper_source_pin;expected_launcher_sha256=$Map.launcher_source_pin.sha256;argument_list=$argv
        argument_list_sha256=(Hash-Bytes ([Text.UTF8Encoding]::new($false).GetBytes(($argv|ConvertTo-Json -Compress))));native_exit_code=0L;elevated_native_exit_code=0L
    }
}
try {
    Test-Case 'separate launcher driver and elevation scopes are accepted as synthetic transport' {
        $fixture=New-TransportFixture;$transport=Invoke-TransportFixture $fixture
        Assert-C1bRBElevation $fixture.map $transport (New-ElevationFixture $fixture.map)
        Assert-Test ($transport.launcher.child_pid-eq101-and$transport.driver.child_pid-eq303) 'Synthetic root PIDs were conflated.'
    }
    Test-Case 'wrong launcher or driver root PID is rejected' {
        foreach($which in @('launcher','driver')){
            $fixture=New-TransportFixture {param($l,$d,$lr,$dr) if($which-ceq'launcher'){$lr.process_id=303L}else{$dr.process_id=101L}}
            Expect-Rejected {Invoke-TransportFixture $fixture} 'PID or native exit mismatch'
        }
    }
    Test-Case 'nonzero root or capture native exit is rejected' {
        foreach($which in @('capture','root')){
            $fixture=New-TransportFixture {param($l,$d,$lr,$dr) if($which-ceq'capture'){$l.exit_code=1L}else{$lr.native_exit_code=1L}}
            Expect-Rejected {Invoke-TransportFixture $fixture} 'out of range'
        }
    }
    Test-Case 'missing stdout or stderr EOF cannot become transport success' {
        foreach($stream in @('stdout','stderr')){
            $fixture=New-TransportFixture {param($l) $l[$stream].eof=$false}
            Expect-Rejected {Invoke-TransportFixture $fixture} 'EOF unknown or unexpected'
        }
    }
    Test-Case 'capture cleanup failures and driver scope substitutions are rejected' {
        $fixture=New-TransportFixture {param($l) $l.cleanup.active_process_count=1L}
        Expect-Rejected {Invoke-TransportFixture $fixture} 'out of range'
        $fixture=New-TransportFixture {param($l,$d,$lr,$dr) $d.child_pid=101L;$dr.process_id=101L}
        Expect-Rejected {Invoke-TransportFixture $fixture} 'Driver PID cannot substitute'
    }
    Test-Case 'missing raw pin hash and extra closed capture fields are rejected' {
        $fixture=New-TransportFixture;$fixture.map.launcher_capture_pin.Remove('sha256')
        Expect-Rejected {Invoke-TransportFixture $fixture} 'unknown or missing fields'
        $fixture=New-TransportFixture {param($l) $l.fake_success=$true}
        Expect-Rejected {Invoke-TransportFixture $fixture} 'unknown or missing fields'
    }
    Test-Case 'captured raw stream drift is rejected independently of producer claims' {
        $fixture=New-TransportFixture
        [IO.File]::WriteAllBytes((Join-Path $fixture.directory 'launcher/stdout.bin'),[byte[]]@(1))
        Expect-Rejected {Invoke-TransportFixture $fixture} 'length rejected'
    }
    Test-Case 'elevation token nonce native exit PID and raw source drift are rejected' {
        $fixture=New-TransportFixture;$transport=Invoke-TransportFixture $fixture
        foreach($mutation in @('token','nonce','launcher-exit','elevated-exit','pid','source','argv','extra')){
            $value=New-ElevationFixture $fixture.map
            switch($mutation){
                token{$value.token_elevated=$false}
                nonce{$value.nonce='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}
                launcher-exit{$value.native_exit_code=1L}
                elevated-exit{$value.elevated_native_exit_code=1L}
                pid{$value.elevated_pid=101L}
                source{$value.wrapper_source_pin=@{path=$fixture.map.wrapper_source_pin.path;byte_length=1L;sha256=('d'*64)}}
                argv{$value.argument_list[1]='-Command'}
                extra{$value.extra=$true}
            }
            Expect-Rejected {Assert-C1bRBElevation $fixture.map $transport $value} 'mismatch|missing fields'
        }
    }
    Test-Case 'private FunctionInfo invokes the exact tracked public verifier despite global shadowing' {
        $privateVerifier=Import-C1bRBPrivateFunctions ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'))) @('ConvertFrom-TL1C1bRealBuildSmokeSummaryJson','Assert-TL1C1bRealBuildSmokeSummaryExactProperties','Assert-TL1C1bRealBuildSmokeSummaryFile') 'C1bReadbackOfflineVerifier'
        function Assert-TL1C1bRealBuildSmokeSummaryFile {throw 'Global shadow must never execute.'}
        $fixturePath=Join-Path $repo 'scripts/tests/fixtures/tablet-layout-c1b-real-build-smoke-summary-v1.json'
        $verified=& $privateVerifier.functions['Assert-TL1C1bRealBuildSmokeSummaryFile'] -Path $fixturePath -ExpectedParentDirectory ([IO.Path]::GetDirectoryName($fixturePath)) -ExpectedCommitSha '8882add6116ebd3cca547d865f9d142bbbcac1a4' -ExpectedHelperSha256 'be4d2afa0e48aa1492eae870b5df6bfa9913a518a70770b0f46e64f4315014c9' -HelperProcessStartedNotBeforeUtc ([DateTimeOffset]::Parse('2026-08-29T10:54:52.0000000Z')) -HelperProcessExitedNotAfterUtc ([DateTimeOffset]::Parse('2026-08-29T11:22:56.0000000Z')) -MaximumObserverTailSeconds 5.0
        Assert-Test ($verified.ByteLength-eq2998L-and$verified.Sha256-ceq'sha256:ec4d8ed153e9ca95448084099122e3eba227dcf6e74d70a145e31d6d3f1b0715') 'Private public verifier changed the fixture raw binding.'
    }
    Test-Case 'summary raw drift is rejected by the held native pin reader' {
        $path=Join-Path $root 'summary-drift.json';$pin=Write-FixtureBytes $path ([Text.UTF8Encoding]::new($false).GetBytes('{"status":"passed"}'))
        [IO.File]::WriteAllText($path,'{"status":"failed"}',[Text.UTF8Encoding]::new($false))
        $session=& $haCommands['New-C1bHASession'] @($root)
        try{Expect-Rejected {$null=& $haCommands['Read-C1bHAFile'] $session $pin} 'SHA256 mismatch'}finally{& $haCommands['Close-C1bHASession'] $session}
    }
    Test-Case 'failure sidecar presence is rejected and held parent absence is observable' {
        $path=Join-Path $root 'launcher.failure.json';$session=& $haCommands['New-C1bHASession'] @($root)
        try{
            Assert-C1bRBFailureAbsent $session $path $root
            Assert-Test $true 'Fresh absence was not observable.'
            $null=Write-FixtureBytes $path ([byte[]]@(123,125))
            Expect-Rejected {Assert-C1bRBFailureAbsent $session $path $root} 'namespace absence'
            Expect-Rejected {& $haCommands['Close-C1bHASession'] $session} 'guard cleanup failed'
            $session=$null
        }finally{if($null-ne$session){& $haCommands['Close-C1bHASession'] $session}}
    }
    Test-Case 'candidate source literal binding rejects ambiguity and dynamic expressions' {
        Assert-Test ((Get-C1bRBLiteral '$candidate = ''literal''; function nested {$candidate=''other''}' 'candidate')-ceq'literal') 'Top-level literal binding was lost.'
        foreach($text in @('$candidate=''a'';$candidate=''b''','function nested {$candidate=''a''}','$candidate=$env:UNTRUSTED')){
            Expect-Rejected {Get-C1bRBLiteral $text 'candidate'} 'one top-level string literal'
        }
    }
    Test-Case 'helper envelope must fit the independent actual launcher capture lifetime' {
        $capture=New-FixtureCapture 101L
        $helper=@{process_started_not_before_utc='2026-09-30T00:00:00.0010000Z';process_exited_not_after_utc='2026-09-30T00:00:00.0200000Z'}
        Assert-C1bRBHelperEnvelope $capture $helper
        Assert-Test $true 'Valid nested process lifetime rejected.'
        foreach($mutation in @('stale','late','wrong-zone')){
            $bad=@{}+$helper
            switch($mutation){
                stale{$bad.process_started_not_before_utc='2026-09-29T00:00:00.0010000Z'}
                late{$bad.process_exited_not_after_utc='2026-09-30T00:00:00.0400000Z'}
                wrong-zone{$bad.process_exited_not_after_utc='2026-09-30T00:00:00.0200000+08:00'}
            }
            Expect-Rejected {Assert-C1bRBHelperEnvelope $capture $bad} 'outside the actual launcher|canonical UTC'
        }
    }
    Test-Case 'actual reader CLI publishes a failed report pointer and never overwrites it' {
        # One harmless reader subprocess; invalid synthetic input rejects before any candidate read.
        $cliRepo=Join-Path $root 'cli-repository';$cliEvidence=Join-Path $root 'cli-evidence';$cliStaging=Join-Path $root 'cli-staging'
        foreach($directory in @($cliRepo,$cliEvidence,$cliStaging)){$null=[IO.Directory]::CreateDirectory($directory)}
        $readerPath=Join-Path $cliRepo 'scripts/read-c1b-build-only-host.ps1'
        $authorityPath=Join-Path $cliRepo 'scripts/lib/c1b-host-acceptance.ps1'
        $null=Write-FixtureBytes $readerPath ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/read-c1b-build-only-host.ps1')))
        $authorityPin=Write-FixtureBytes $authorityPath ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/c1b-host-acceptance.ps1')))
        $mapPin=Write-FixtureJson (Join-Path $cliEvidence 'map.json') @{schema='c1b-build-only-readback-inputs/v1';candidate_sha=('a'*40)}
        $reportPath=Join-Path $cliEvidence 'report.json'
        function Invoke-ReaderFixtureCli {
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=[Environment]::ProcessPath
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
            foreach($argument in @('-NoLogo','-NoProfile','-NonInteractive','-File',$readerPath,'-CandidateSha',('a'*40),'-RepoRoot',$cliRepo,'-StagingRoot',$cliStaging,'-PwshPath',[Environment]::ProcessPath,'-EvidenceRoot',$cliEvidence,'-InputMapPath',$mapPin.path,'-InputMapSha256',$mapPin.sha256,'-HostAcceptanceSourceSha256',$authorityPin.sha256,'-ReportPath',$reportPath)){$start.ArgumentList.Add($argument)}
            $child=[Diagnostics.Process]::new();$child.StartInfo=$start
            $stdout=[IO.MemoryStream]::new();$stderr=[IO.MemoryStream]::new()
            try{
                Assert-Test ($child.Start()) 'Synthetic reader CLI did not start.'
                $outTask=$child.StandardOutput.BaseStream.CopyToAsync($stdout);$errTask=$child.StandardError.BaseStream.CopyToAsync($stderr)
                Assert-Test ($child.WaitForExit(30000)) 'Synthetic reader CLI timed out.'
                Assert-Test ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask,$errTask),5000)) 'Synthetic reader CLI streams did not close.'
                return @{exit_code=$child.ExitCode;stdout=[Text.UTF8Encoding]::new($false,$true).GetString($stdout.ToArray());stderr=[Text.UTF8Encoding]::new($false,$true).GetString($stderr.ToArray())}
            }finally{
                if(-not$child.HasExited){$child.Kill($true);$null=$child.WaitForExit(5000)}
                $stdout.Dispose();$stderr.Dispose();$child.Dispose()
            }
        }
        $first=Invoke-ReaderFixtureCli
        Assert-Test ($first.exit_code-eq0-and$first.stderr.Length-eq0) "Reader publication exit or stderr mismatched: $($first.stderr)"
        $pointer=& $haCommands['ConvertFrom-C1bHAStrictJson'] $first.stdout
        & $haCommands['Assert-C1bHAKeys'] $pointer @('report_path','report_sha256','acceptance_status','readback_completed') 'reader stdout pointer'
        $reportBytes=[IO.File]::ReadAllBytes($reportPath)
        Assert-Test ($pointer.report_path-ceq$reportPath-and$pointer.report_sha256-ceq(Hash-Bytes $reportBytes)-and$pointer.acceptance_status-ceq'reader_failed'-and$pointer.readback_completed-eq$false) 'Published pointer falsely accepted incomplete synthetic input.'
        $report=& $haCommands['ConvertFrom-C1bHAStrictJson'] ([Text.UTF8Encoding]::new($false,$true).GetString($reportBytes))
        Assert-Test ($report.strict_pass_summary_independently_verified-eq$false-and@($report.checks|Where-Object{$_.status-ceq'failed'}).Count-ge1-and$report.cleanup_failure_count-eq0) 'Failed reader report lost its real rejection or guard cleanup.'
        $second=Invoke-ReaderFixtureCli
        Assert-Test ($second.exit_code-ne0-and(Hash-Bytes ([IO.File]::ReadAllBytes($reportPath)))-ceq(Hash-Bytes $reportBytes)) 'Duplicate report was overwritten or silently accepted.'
    }
    Test-Case 'independent publication ancestor chains reject parent renaming until cleanup' {
        $ancestor=[IO.Path]::GetFullPath((Join-Path $root 'publication-parent'))
        $leaf=[IO.Path]::GetFullPath((Join-Path $ancestor 'leaf'))
        $destination=[IO.Path]::GetFullPath((Join-Path $root 'publication-parent-moved'))
        Assert-Test ([IO.Path]::GetDirectoryName($ancestor)-ceq$root-and[IO.Path]::GetDirectoryName($destination)-ceq$root) 'Synthetic rename targets escaped the verified fixture root.'
        $null=[IO.Directory]::CreateDirectory($leaf)
        $publicationSession=& $haCommands['New-C1bHASession'] @($leaf)
        try{
            Expect-Rejected {[IO.Directory]::Move($ancestor,$destination)} 'used by another process|access.*denied|being used'
            Assert-Test ([IO.Directory]::Exists($ancestor)-and-not[IO.Directory]::Exists($destination)) 'Held ancestor rename changed namespace.'
        }finally{& $haCommands['Close-C1bHASession'] $publicationSession}
    }
} finally {
    $full=[IO.Path]::GetFullPath($root)
    if([IO.Path]::GetDirectoryName($full)-cne$parent-or[IO.Path]::GetFileName($full)-cnotmatch'\A[0-9a-f]{32}\z'){throw 'Fixture cleanup escaped its verified root.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Output "BuildOnly host readback offline: $passed passed, 0 skipped; $assertions assertions; synthetic only; external candidate/device calls 0"
