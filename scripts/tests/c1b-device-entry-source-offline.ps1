#Requires -Version 7.6
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'scripts/lib/c1b-device-entry-source.ps1')
if(-not $OutputDirectory){$OutputDirectory=Join-Path $repo ('.checks/c1b-device-entry-source-offline/'+[Guid]::NewGuid().ToString('N'))}
$OutputDirectory=Get-C1bEntryCanonicalPath $OutputDirectory
Assert-C1bEntry (-not [IO.Directory]::Exists($OutputDirectory)) 'Fresh synthetic output required.'
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$fixture=Join-Path $OutputDirectory "repo's;中文fixture";$null=[IO.Directory]::CreateDirectory($fixture)
$utf8=[Text.UTF8Encoding]::new($false);$passed=0;$failed=0;$records=[Collections.Generic.List[object]]::new()
function Test-Case([string]$Name,[scriptblock]$Body){
 try{& $Body;$script:passed++;$records.Add(@{name=$Name;status='passed'});Write-Output ('PASS '+$Name)}
 catch{$script:failed++;$records.Add(@{name=$Name;status='failed';error=$_.Exception.Message});Write-Output ('FAIL '+$Name+': '+$_.Exception.Message)}
}
function Must-Fail([scriptblock]$Body,[string]$Pattern){$caught=$false;try{& $Body}catch{$caught=$true;Assert-C1bEntry ($_.Exception.Message -match $Pattern) ('Unexpected rejection: '+$_.Exception.Message)};Assert-C1bEntry $caught 'Expected rejection missing.'}
function Write-Fixture([string]$Relative,[byte[]]$Bytes){$p=Join-Path $fixture $Relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p));[IO.File]::WriteAllBytes($p,$Bytes);$p}
function Pin-Fixture([string]$Path){$b=[IO.File]::ReadAllBytes($Path);[ordered]@{path=$Path;byte_length=$b.Length;sha256=(Get-C1bEntryHash $b)}}
function Copy-Object($Value){$Value|ConvertTo-Json -Depth 70 -Compress|ConvertFrom-Json -AsHashtable -Depth 70 -DateKind String}
$libraryRaw=[IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/tablet-layout-c1b.ps1'))
$map=Get-C1bEntryImplementationPathMap $repo (Get-C1bEntryHash $libraryRaw)
$implementation=[ordered]@{}
foreach($key in $map.Keys){$p=Write-Fixture $map[$key] ([IO.File]::ReadAllBytes((Join-Path $repo $map[$key])));$implementation[$key]='sha256:'+(Pin-Fixture $p).sha256}
$lines=[string[]]@($map.Keys|ForEach-Object {$map[$_]+'='+$implementation[$_]});[Array]::Sort($lines,[StringComparer]::Ordinal)
$catalog='sha256:'+(Get-C1bEntryHash $utf8.GetBytes(($lines -join "`n")))
$deps=[ordered]@{}
foreach($row in @(@('maintenance','scripts/lib/c1b-device-entry-source.ps1'),@('host_acceptance','scripts/lib/c1b-host-acceptance.ps1'),@('terminal_discovery','scripts/lib/c1b-terminal-discovery.ps1'),@('terminal_discovery_bridge','scripts/read-c1b-terminal-discovery.ps1'),@('host_capture','scripts/lib/c1b-host-process-capture.ps1'))){
 $p=Write-Fixture $row[1] ([IO.File]::ReadAllBytes((Join-Path $repo $row[1])));$pin=Pin-Fixture $p;$pin.path=$row[1];$deps[$row[0]]=$pin
}
foreach($leaf in $script:C1bDeviceEntryLeaves){$null=Write-Fixture ('scripts/lib/c1b-device-entry-source/'+$leaf) ([IO.File]::ReadAllBytes((Join-Path $repo ('scripts/lib/c1b-device-entry-source/'+$leaf))))}
$strictPath=Write-Fixture 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1' ([IO.File]::ReadAllBytes((Join-Path $repo 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1')))
$strict=Pin-Fixture $strictPath;$strict.path='scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
$sha='1'*40;$metadata=[ordered]@{}
foreach($row in @(@('head','.git/HEAD','ref: refs/heads/codex/synthetic'),@('ref','.git/refs/heads/codex/synthetic',$sha),@('config','.git/config','[core]'),@('info_exclude','.git/info/exclude','# fixture'),@('gitattributes','.gitattributes','*.ps1 text eol=lf'),@('gitignore','.gitignore','.checks/'))){$metadata[$row[0]]=Pin-Fixture (Write-Fixture $row[1] $utf8.GetBytes($row[2]+"`n"))}
$index=Pin-Fixture (Write-Fixture '.git/index' ([byte[]]@(1,2,3,4)))
$authority=[ordered]@{repo_root=$fixture;branch='codex/synthetic';git_entry_kind='directory';git_index_sha256=$index.sha256;git_index_byte_length=$index.byte_length;tracked_path_count=500;implementation_catalog_sha256=$catalog;implementation_hashes=$implementation;git_metadata=$metadata}
$entryRoot=Join-Path $OutputDirectory '已审sources';$null=[IO.Directory]::CreateDirectory($entryRoot)
$context=[ordered]@{schema='c1b-device-entry-generation-context/v1';candidate_sha=$sha;repo_root=$fixture;entry_root=$entryRoot;pwsh_path=[Environment]::ProcessPath;runtime_sha256='362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139';strict_pin=$strict;implementation_hashes=$implementation;implementation_catalog_sha256=$catalog;authority=$authority;dependency_pins=$deps;template_pins=(Get-C1bDeviceEntryTemplatePins $fixture)}
$generated=New-C1bDeviceEntrySources $context;$outputs=[ordered]@{}
foreach($leaf in $generated.Keys){$outputs[$leaf]=[ordered]@{path=(Join-Path $entryRoot $leaf);byte_length=$generated[$leaf].Length;sha256=(Get-C1bEntryHash $generated[$leaf])}}
$manifest=[ordered]@{schema='c1b-device-entry-source-manifest/v1';context=$context;outputs=$outputs;source_pins=@($context.template_pins.Values)+@($deps.Values)+@($strict);device_execution_count=0}
$manifestPath=Join-Path $OutputDirectory 'manifest.json';[IO.File]::WriteAllBytes($manifestPath,$utf8.GetBytes(($manifest|ConvertTo-Json -Depth 70 -Compress)));[IO.File]::SetAttributes($manifestPath,[IO.FileAttributes]::ReadOnly);$manifestPin=Pin-Fixture $manifestPath
$review=[ordered]@{schema='c1b-device-entry-source-review/v1';candidate_sha=$sha;manifest_sha256=$manifestPin.sha256;review_status='reviewed';p0_findings=@();p1_findings=@();source_pins=$manifest.source_pins;output_pins=$manifest.outputs;semantic_review_basis='合成语义审查夹具；仅机械 reviewer 冷进程执行，无主机或设备验收。'}
$reviewPath=Join-Path $OutputDirectory 'review.json';[IO.File]::WriteAllBytes($reviewPath,$utf8.GetBytes(($review|ConvertTo-Json -Depth 70 -Compress)));[IO.File]::SetAttributes($reviewPath,[IO.FileAttributes]::ReadOnly);$reviewPin=Pin-Fixture $reviewPath
function New-TestNative {New-C1bEntryNativeContext $fixture $strict.sha256 $strict.byte_length}
Test-Case 'all twenty real rendered ASTs parse; no unresolved slots; LF templates' {
 foreach($leaf in $generated.Keys){$text=$utf8.GetString($generated[$leaf]);$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e);Assert-C1bEntry ($e.Count -eq 0 -and $text -cnotmatch '__[A-Z0-9_]+__') 'Rendered AST rejected.';Assert-C1bEntry (-not ([IO.File]::ReadAllText((Join-Path $fixture ('scripts/lib/c1b-device-entry-source/'+$leaf))).Contains("`r"))) 'Template must be LF.'}
 Assert-C1bEntry ($generated.Count -eq 20) 'Source count differs.'
}
Test-Case 'apostrophe and semicolon remain one real path literal' {
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($utf8.GetString($generated['invoke-next-device-once-r1.ps1']),[ref]$t,[ref]$e)
 $assignment=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$repo'})
 $literal=@($assignment[0].Right.FindAll({param($a) $a -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
 Assert-C1bEntry ($assignment.Count -eq 1 -and $literal.Count -eq 1 -and $literal[0].Value -ceq $fixture) 'Escaped literal differs.'
}
Test-Case 'catalog mismatch and extra implementation key reject' {
 $bad=Copy-Object $context;$bad.implementation_catalog_sha256='sha256:'+('0'*64);Must-Fail {New-C1bDeviceEntrySources $bad} 'catalog'
 $bad=Copy-Object $context;$bad.implementation_hashes['extra']='sha256:'+('0'*64);Must-Fail {New-C1bDeviceEntrySources $bad} '42'
}
Test-Case 'path CRLF and noncanonical path reject' {
 $bad=Copy-Object $context;$bad.entry_root=$entryRoot+"`n;throw 'injected'";Must-Fail {New-C1bDeviceEntrySources $bad} 'Canonical'
 Must-Fail {Get-C1bEntryCanonicalPath (Join-Path $entryRoot '../escape')} 'normalized'
}
Test-Case 'dependency path substitution rejects' {
 $bad=Copy-Object $context;$bad.dependency_pins.maintenance.path='../outside.ps1';Must-Fail {New-C1bDeviceEntrySources $bad} 'Exact tracked'
}
Test-Case 'template length and byte drift reject actual generation' {
 $bad=Copy-Object $context;$bad.template_pins['invoke-next-device-once-r1.ps1'].byte_length++;Must-Fail {New-C1bDeviceEntrySources $bad} 'raw pin'
 $bad=Copy-Object $context;$bad.template_pins['invoke-next-device-once-r1.ps1'].sha256='0'*64;Must-Fail {New-C1bDeviceEntrySources $bad} 'raw pin'
}
Test-Case 'duplicate nested JSON and BOM reject' {
 Must-Fail {ConvertFrom-C1bEntryJson $utf8.GetBytes('{"a":{"x":1,"x":2}}')} 'Duplicate'
 Must-Fail {ConvertFrom-C1bEntryJson $utf8.GetBytes(([string][char]0xfeff)+'{}')} 'BOM'
}
Test-Case 'actual held manifest binds current 42 files and HEAD ref' {
 $n=New-TestNative;try{$m=Assert-C1bDeviceEntryManifest $n $manifestPath $manifestPin.sha256;Assert-C1bEntry ($m.outputs.Count -eq 20) 'Wrong output count';Assert-C1bEntry ($n.Files.ContainsKey((Join-Path $fixture $map.runner_sha256)) -and $n.Files.ContainsKey($metadata.ref.path)) 'Real candidate inputs not held.'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'native deny-write and readonly input guard execute' {
 $n=New-TestNative;try{$null=Read-C1bEntryHeldFile $n $manifestPath $manifestPin.sha256 $manifestPin.byte_length;Must-Fail {$s=[IO.File]::Open($manifestPath,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$s.Dispose()} 'denied|used|access|process';$p=Join-Path $OutputDirectory 'mutable.json';[IO.File]::WriteAllText($p,'{}');$pin=Pin-Fixture $p;Must-Fail {Read-C1bEntryHeldFile $n $p $pin.sha256 $pin.byte_length} 'Readonly'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'wrong HEAD candidate refuses before publication' {
 $bad=Copy-Object $manifest;$bad.context.candidate_sha='2'*40;$p=Join-Path $OutputDirectory 'wrong-head.json';[IO.File]::WriteAllText($p,($bad|ConvertTo-Json -Depth 70 -Compress));[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly);$pin=Pin-Fixture $p
 $n=New-TestNative;try{Must-Fail {Assert-C1bDeviceEntryManifest $n $p $pin.sha256} 'HEAD/ref'}finally{Close-C1bEntryNativeContext $n}
 Assert-C1bEntry (@([IO.Directory]::EnumerateFileSystemEntries($entryRoot)).Count -eq 0) 'Rejected input wrote output.'
}
Test-Case 'current independent review identity and P0 reject' {
 $bad=Copy-Object $review;$bad.candidate_sha='2'*40;Must-Fail {Assert-C1bDeviceEntrySourceReview $bad $sha $manifestPin.sha256} 'independent'
 $bad=Copy-Object $review;$bad.p0_findings=@('block');Must-Fail {Assert-C1bDeviceEntrySourceReview $bad $sha $manifestPin.sha256} 'blocking'
}
Test-Case 'caller exit and prefix outer exit cannot be supplied as pass' {
 Must-Fail {New-C1bDeviceEntryBinding $null '' '' '' '' '' '' '' 1 0} 'independently'
 Must-Fail {New-C1bDeviceEntryReady $null '' '' '' '' '' '' 0 1} 'independently'
}
Test-Case 'formal runtime tuples have no historical PID exit defaults' {
 foreach($leaf in @('verify-next-device-terminal-r1.ps1','prepare-device-binding-r1.ps1','publish-device-ready-r1.ps1')){
  $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($utf8.GetString($generated[$leaf]),[ref]$t,[ref]$e)
  foreach($p in @($ast.ParamBlock.Parameters|Where-Object {$_.Name.VariablePath.UserPath -like 'Observed*'})){Assert-C1bEntry ($null -eq $p.DefaultValue -and $p.Extent.Text -match 'Mandatory') 'Runtime tuple has a default.'}
 }
 $text=$utf8.GetString($generated['verify-next-device-terminal-r1.ps1']);Assert-C1bEntry ($text -notmatch 'Get-ChildItem|LastWriteTimeUtc-lt|\$candidate\.FullName' -and $text -match 'C1b failure evidence reference:' -and $text -match 'Get-C1bTerminalDiscoveryIdentity') 'Failure selection or R3 identity not migrated.'
}
Test-Case 'real current source publication is CreateNew readonly and byte exact' {
 $n=New-TestNative;try{$p=Publish-C1bDeviceEntrySources $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256;Assert-C1bEntry ($p.outputs.Count -eq 20 -and -not $p.device_stage_started -and $p.device_commands -eq 0) 'Publication scope differs';foreach($leaf in $generated.Keys){$item=Get-Item -LiteralPath (Join-Path $entryRoot $leaf);Assert-C1bEntry ($item.IsReadOnly -and (Get-C1bEntryHash ([IO.File]::ReadAllBytes($item.FullName))) -ceq $outputs[$leaf].sha256) 'Published raw source differs.'}}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'publication replay rejects without overwrite' {
 $n=New-TestNative;try{Must-Fail {Publish-C1bDeviceEntrySources $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256} 'occupied'}finally{Close-C1bEntryNativeContext $n}
 Assert-C1bEntry (@([IO.Directory]::EnumerateFileSystemEntries($entryRoot)).Count -eq 20) 'Replay changed inventory.'
}
Test-Case 'cold rendered mechanical reviewer preserves Chinese paths and strict UTF8 raw stdout' {
 . (Join-Path $repo 'scripts/lib/c1b-host-process-capture.ps1')
 $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath ([Environment]::ProcessPath) -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-File',$outputs['review-entry.ps1'].path,'-ExpectedSelfSha256',$outputs['review-entry.ps1'].sha256,'-ManifestPath',$manifestPath,'-ManifestSha256',$manifestPin.sha256) -WorkingDirectory $fixture -EvidenceDirectory (Join-Path $OutputDirectory 'cold-中文-reviewer') -TimeoutMilliseconds 120000 -CaptureLimitBytes 8388608
 Assert-C1bEntry ($capture.status -ceq 'passed' -and $capture.exit_code -eq 0 -and $capture.stdout.eof -and $capture.stderr.eof -and $capture.stderr.total_byte_length -eq 0 -and $capture.cleanup.completed -and $capture.cleanup.failure_count -eq 0) 'Cold mechanical reviewer capture failed.'
 $raw=[IO.File]::ReadAllBytes((Join-Path $OutputDirectory 'cold-中文-reviewer/stdout.bin'))
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($raw);$report=ConvertFrom-C1bEntryJson $raw
 Assert-C1bEntry ($text.Contains('已审sources') -and $report.schema -ceq 'c1b-device-entry-source-audit/v1' -and $report.candidate_sha -ceq $sha -and $report.status -ceq 'verified' -and $report.deterministic_render_matches -and $report.independent_semantic_review_required -and ($report.output_raw_pins|ConvertTo-Json -Depth 20 -Compress) -ceq ($outputs|ConvertTo-Json -Depth 20 -Compress)) 'Cold reviewer UTF8 raw report differs.'
 $actualReview=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($reviewPath))
 Assert-C1bEntry ($actualReview.semantic_review_basis -ceq $review.semantic_review_basis -and $actualReview.semantic_review_basis.Contains('合成语义审查')) 'Chinese semantic basis raw fixture differs.'
}
Test-Case 'mismatched output pin cannot be admitted as published' {
 $bad=Copy-Object $manifest;$bad.outputs['invoke-next-device-once-r1.ps1'].sha256='0'*64;$p=Join-Path $OutputDirectory 'bad-output.json';[IO.File]::WriteAllText($p,($bad|ConvertTo-Json -Depth 70 -Compress));[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly);$pin=Pin-Fixture $p
 $n=New-TestNative;try{Must-Fail {Assert-C1bDeviceEntryManifest $n $p $pin.sha256 $true} 'deterministic'}finally{Close-C1bEntryNativeContext $n}
}
function Save-CaptureFixture([string]$Name,[bool]$StdoutEof=$true,[bool]$StderrEof=$true,[int]$CleanupFailures=0,[string]$Stage='Binding',$SourcePin=$outputs['prepare-device-binding-r1.ps1'],[byte[]]$StdoutBytes=$utf8.GetBytes('{}'),[byte[]]$ArgumentBytes=$utf8.GetBytes('{}'),[string]$Started='2026-09-30T00:00:00Z',[string]$Completed='2026-09-30T00:00:01Z') {
 $dir=Join-Path $OutputDirectory $Name;$null=[IO.Directory]::CreateDirectory($dir)
 function Save-Closed([string]$Leaf,[byte[]]$Bytes){$p=Join-Path $dir $Leaf;[IO.File]::WriteAllBytes($p,$Bytes);[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly);Pin-Fixture $p}
 $raw=[ordered]@{};$raw.stdout=Save-Closed 'stdout.bin' $StdoutBytes;$raw.stderr=Save-Closed 'stderr.bin' ([byte[]]@())
 $argsPath=Join-Path $OutputDirectory ($Name+'-args.json');[IO.File]::WriteAllBytes($argsPath,$ArgumentBytes);[IO.File]::SetAttributes($argsPath,[IO.FileAttributes]::ReadOnly);$args=Pin-Fixture $argsPath
 $reservation=Save-Closed 'reservation.json' $utf8.GetBytes((@{schema='tl1-c1b-host-process-capture-reservation/v1';started_at_utc=$Started;parent_pid=321;automatic_retry_count=0}|ConvertTo-Json -Compress))
 $capture=[ordered]@{schema='tl1-c1b-host-process-capture/v1';status='passed';started_at_utc=$Started;completed_at_utc=$Completed;elapsed_milliseconds=1000;start_attempt_count=1;start_count=1;automatic_retry_count=0;child_pid=123;exit_code=0;root_exit_confirmed=$true;natural_exit=$true;timed_out=$false;drain_timed_out=$false;termination_requested=$false;capture_limit_bytes_per_stream=8388608;timeout_milliseconds=1000;drain_timeout_milliseconds=1000;cleanup_timeout_milliseconds=1000;drains_completed=$true;errors=@();publication_errors=@();environment=@{mode='inherit';keys=@();sha256=('0'*64)};cleanup=@{scope='contained_job_processes_pipe_workers_owned_handles';completed=$true;job_assigned_before_resume=$true;handles_closed=$true;active_process_count=0;failure_count=$CleanupFailures;errors=@()}}
 foreach($name in @('stdout','stderr')){$p=$raw[$name];$capture[$name]=[ordered]@{eof=$(if($name -ceq 'stdout'){$StdoutEof}else{$StderrEof});aborted=$false;error=$null;overflowed=$false;observed_byte_length=$p.byte_length;observed_sha256=$p.sha256;total_byte_length=$p.byte_length;sha256=$p.sha256;captured_byte_length=$p.byte_length;captured_sha256=$p.sha256;first_byte_observed_elapsed_milliseconds=0;eof_observed_elapsed_milliseconds=1}}
 $raw.execution=Save-Closed 'execution.json' $utf8.GetBytes(($capture|ConvertTo-Json -Depth 20 -Compress));$raw.reservation=$reservation
 $captureLeaves=@{Binding='capture-r1-host-step.ps1';Prefix='capture-observer-preflight-r1.ps1';SourcePublication='capture-source-publication-r1.ps1';SourcePublicationOuter='capture-source-publication-outer-r1.ps1'}
 $named=ConvertFrom-C1bEntryJson $ArgumentBytes;$argv=[Collections.Generic.List[string]]::new();foreach($v in @('-NoLogo','-NoProfile','-NonInteractive','-File',$SourcePin.path)){$argv.Add($v)};foreach($k in $named.Keys){$argv.Add('-'+$k);$argv.Add([string]$named[$k])}
 $r=[ordered]@{schema='c1b-device-entry-host-capture/v1';candidate_sha=$sha;stage=$Stage;source=$SourcePin;arguments=$args;capture=$capture;raw_pins=$raw;capture_parent_pid=321;capture_source=$outputs[$captureLeaves[$Stage]];runtime=(Pin-Fixture ([Environment]::ProcessPath));argument_list=$argv.ToArray();device_commands=0;automatic_retry_count=0}
 Save-Closed 'entry-capture.json' $utf8.GetBytes(($r|ConvertTo-Json -Depth 30 -Compress))
}
Test-Case 'real capture consumer reads both raw stream pins and execution' {
 $pin=Save-CaptureFixture 'capture-valid';$n=New-TestNative
 try{$r=Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath;Assert-C1bEntry ($n.Files.ContainsKey($r.raw_pins.stderr.path) -and $n.Files.ContainsKey($r.raw_pins.execution.path)) 'Independent stream/execution readback missing.'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'independent stdout and stderr EOF absence each reject' {
 foreach($row in @(@('capture-out-no-eof',$false,$true),@('capture-err-no-eof',$true,$false))){$pin=Save-CaptureFixture $row[0] $row[1] $row[2];$n=New-TestNative;try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} 'EOF/hash'}finally{Close-C1bEntryNativeContext $n}}
}
Test-Case 'capture cleanup failure remains a rejection' {
 $pin=Save-CaptureFixture 'capture-bad-cleanup' $true $true 1;$n=New-TestNative;try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} 'cleanup|integer'}finally{Close-C1bEntryNativeContext $n}
}
function Change-CaptureFixture([string]$Name,[scriptblock]$Change,[scriptblock]$ChangeReservation) {
 $pin=Save-CaptureFixture $Name;$r=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($pin.path));& $Change $r
 if($ChangeReservation){$p=$r.raw_pins.reservation.path;$v=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($p));& $ChangeReservation $v;[IO.File]::SetAttributes($p,[IO.FileAttributes]::Normal);[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Compress),$utf8);[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly);$r.raw_pins.reservation=Pin-Fixture $p}
 $p=$r.raw_pins.execution.path;[IO.File]::SetAttributes($p,[IO.FileAttributes]::Normal);[IO.File]::WriteAllText($p,($r.capture|ConvertTo-Json -Depth 30 -Compress),$utf8);[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly);$r.raw_pins.execution=Pin-Fixture $p
 [IO.File]::SetAttributes($pin.path,[IO.FileAttributes]::Normal);[IO.File]::WriteAllText($pin.path,($r|ConvertTo-Json -Depth 40 -Compress),$utf8);[IO.File]::SetAttributes($pin.path,[IO.FileAttributes]::ReadOnly);Pin-Fixture $pin.path
}
Test-Case 'capture numeric boolean string counter and missing EOF reject after consistent raw repinning' {
 foreach($row in @(@('numeric-cleanup-bool',{param($r)$r.capture.cleanup.completed=1},'boolean'),@('string-cleanup-count',{param($r)$r.capture.cleanup.failure_count='0'},'integer'),@('string-device-count',{param($r)$r.device_commands='0'},'integer'),@('missing-stream-flag',{param($r)$r.capture.stdout.Remove('eof')},'key count'))){$pin=Change-CaptureFixture $row[0] $row[1];$n=New-TestNative;try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} $row[2]}finally{Close-C1bEntryNativeContext $n}}
}
Test-Case 'borrowed same-byte stdout path from another capture rejects' {
 $borrow=Pin-Fixture (Join-Path $OutputDirectory 'capture-valid/stdout.bin')
 $pin=Change-CaptureFixture 'borrowed-stream' {param($r)$r.raw_pins.stdout=$borrow};$n=New-TestNative
 try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} 'directory graph'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'repinned reservation time cannot be borrowed for actual capture' {
 $pin=Change-CaptureFixture 'reservation-time' {param($r)} {param($v)$v.started_at_utc='2026-09-29T00:00:00Z'};$n=New-TestNative
 try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} 'reservation current parent/time'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'argv mutation is rejected against actual readonly input map' {
 $pin=Change-CaptureFixture 'argv-mismatch' {param($r)$r.argument_list+=@('-EncodedCommand','AA==')};$n=New-TestNative
 try{Must-Fail {Assert-C1bEntrySuccessfulCapture $n $pin $outputs['prepare-device-binding-r1.ps1'].path $outputs['prepare-device-binding-r1.ps1'].sha256 $sha $manifest $manifestPath} 'argv differs'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'actual observer Windows quoting function covers spaces quotes and trailing slash' {
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($utf8.GetString($generated['observe-next-device-launch-r1.ps1']),[ref]$t,[ref]$e)
 $f=@($ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -ceq 'ConvertTo-C1bObserverWindowsArgument'},$true));Assert-C1bEntry ($f.Count -eq 1) 'One production quoting definition required.'
 . ([scriptblock]::Create($f[0].Extent.Text))
 foreach($row in @(@('C:\entry with spaces\wrap.ps1','"C:\entry with spaces\wrap.ps1"'),@('C:\safe\wrap.ps1','C:\safe\wrap.ps1'),@('x"y\','"x\"y\\"'),@('','""'))){Assert-C1bEntry ((ConvertTo-C1bObserverWindowsArgument $row[0]) -ceq $row[1]) 'Windows argument quoting differs.'}
}
function Save-ReadonlyJson([string]$Path,$Object){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,($Object|ConvertTo-Json -Depth 70 -Compress),$utf8);[IO.File]::SetAttributes($Path,[IO.FileAttributes]::ReadOnly);Pin-Fixture $Path}
foreach($leaf in @('publish-reviewed-r1-sources.ps1','capture-source-publication-r1.ps1')){$p=Join-Path $OutputDirectory $leaf;[IO.File]::WriteAllBytes($p,$generated[$leaf]);[IO.File]::SetAttributes($p,[IO.FileAttributes]::ReadOnly)}
$publisherPin=Pin-Fixture (Join-Path $OutputDirectory 'publish-reviewed-r1-sources.ps1')
$innerArgs=[ordered]@{ExpectedSelfSha256=$publisherPin.sha256;ManifestPath=$manifestPath;ManifestSha256=$manifestPin.sha256;SourceReviewPath=$reviewPath;SourceReviewSha256=$reviewPin.sha256}
$publication=[ordered]@{schema='c1b-device-entry-source-publication/v1';candidate_sha=$sha;manifest_sha256=$manifestPin.sha256;source_review_sha256=$reviewPin.sha256;outputs=$outputs;device_stage_started=$false;device_evidence_verified=$false;device_commands=0;automatic_retry_count=0}
$innerPin=Save-CaptureFixture 'source-inner' -Stage SourcePublication -SourcePin $publisherPin -StdoutBytes $utf8.GetBytes(($publication|ConvertTo-Json -Depth 40 -Compress)+"`r`n") -ArgumentBytes $utf8.GetBytes(($innerArgs|ConvertTo-Json -Compress))
$innerRecord=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($innerPin.path))
$innerCaptureSource=Pin-Fixture (Join-Path $OutputDirectory 'capture-source-publication-r1.ps1')
$outerArgs=[ordered]@{ExpectedSelfSha256=$innerCaptureSource.sha256;ManifestPath=$manifestPath;ManifestSha256=$manifestPin.sha256;SourcePath=$publisherPin.path;ExpectedSourceSha256=$publisherPin.sha256;ArgumentsJsonPath=$innerRecord.arguments.path;ArgumentsSha256=$innerRecord.arguments.sha256;OutputDirectory=[IO.Path]::GetDirectoryName($innerPin.path)}
$outerPin=Save-CaptureFixture 'source-outer' -Stage SourcePublicationOuter -SourcePin $innerCaptureSource -StdoutBytes $utf8.GetBytes(($innerRecord|ConvertTo-Json -Depth 40 -Compress)+"`r`n") -ArgumentBytes $utf8.GetBytes(($outerArgs|ConvertTo-Json -Compress))
$supportInput=[ordered]@{schema='c1b-device-entry-support-inputs/v1';candidate_sha=$sha;source_publication_capture=$innerPin;source_publication_outer_capture=$outerPin}
$supportPin=Save-ReadonlyJson (Join-Path $OutputDirectory 'support-inputs.json') $supportInput
Test-Case 'support readback consumes inner outer raw captures and exact publisher arguments' {
 $n=New-TestNative;try{$s=Assert-C1bDeviceEntrySupport $n $manifest $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $supportPin.path $supportPin.sha256 0 0;Assert-C1bEntry ($s.status -ceq 'verified' -and -not $s.device_stage_started -and $n.Files.ContainsKey($innerRecord.arguments.path)) 'Source publication support readback differs.'}finally{Close-C1bEntryNativeContext $n}
}
Test-Case 'support rejects nonzero outer actual observation' {
 Must-Fail {Assert-C1bDeviceEntrySupport $null $manifest $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $supportPin.path $supportPin.sha256 0 1} 'independently'
}
$bindingResult=$null;$bindingPin=$null
Test-Case 'real binding native publication preserves boundaries with explicit isolated host verification stub' {
 # Only host acceptance is stubbed here; its independent complete suite tests real evidence.
 function Import-C1bEntryPinnedDependency($Native,$Pin){Assert-C1bEntry ($Pin.path -ceq 'scripts/lib/c1b-host-acceptance.ps1') 'Unexpected mocked dependency.'}
 function Assert-C1bHostAcceptanceContract {param($CandidateSha,$EvidenceRoot,$ContractPath,$ContractSha256,$SummaryVerifierContext)
  Assert-C1bEntry ($CandidateSha -ceq $sha -and $SummaryVerifierContext.source_bytes -is [byte[]] -and (Get-C1bEntryHash $SummaryVerifierContext.source_bytes) -ceq $strict.sha256) 'Explicit native verifier context handoff differs.'
  return @{observed_buildonly_caller_exit=0;observed_buildonly_reader_exit=0;authority=$authority}
 }
 $hostPin=Save-ReadonlyJson (Join-Path $OutputDirectory 'synthetic-host-contract.json') @{scope='isolated test stub only'}
 $null=[IO.Directory]::CreateDirectory((Join-Path $fixture '.checks/c1b-device-once/1111111'))
 $attemptRoot=Join-Path $fixture '.checks/c1b-device-once/1111111/r1'
 foreach($mutation in @('missing','null','integer','array','naked','short','uppercase','trailing-newline')){
  $bad=Copy-Object $manifest
  switch($mutation){
   missing {$bad.context.implementation_hashes.Remove('runner_sha256')}
   null {$bad.context.implementation_hashes.runner_sha256=$null}
   integer {$bad.context.implementation_hashes.runner_sha256=42}
   array {$bad.context.implementation_hashes.runner_sha256=@($implementation.runner_sha256)}
   naked {$bad.context.implementation_hashes.runner_sha256=$implementation.runner_sha256.Substring(7)}
   short {$bad.context.implementation_hashes.runner_sha256='sha256:'+('1'*63)}
   uppercase {$bad.context.implementation_hashes.runner_sha256=$implementation.runner_sha256.ToUpperInvariant()}
   trailing-newline {$bad.context.implementation_hashes.runner_sha256=$implementation.runner_sha256+[char]10}
  }
  $bad.context.authority.implementation_hashes=Copy-Object $bad.context.implementation_hashes
  $badPin=Save-ReadonlyJson (Join-Path $OutputDirectory ('binding-runner-'+$mutation+'-manifest.json')) $bad
  $expectedRejection='Runner raw hash|Implementation raw hash|Implementation catalog|Exact 42|Missing exact key|Closed object'
  if($mutation -ceq 'array'){$expectedRejection='Runner raw hash|Cannot process argument transformation on parameter ''Condition''\..*System\.Object\[\].*System\.Boolean'}
  $n=New-TestNative
  try{
   Must-Fail {New-C1bDeviceEntryBinding $n $badPin.path $badPin.sha256 $reviewPath $reviewPin.sha256 $hostPin.path $hostPin.sha256 $OutputDirectory 0 0 $supportPin.path $supportPin.sha256 0 0} $expectedRejection
   Assert-C1bEntry (-not [IO.Directory]::Exists($attemptRoot) -and -not [IO.File]::Exists($attemptRoot)) 'Invalid runner hash consumed the attempt root.'
  }finally{Close-C1bEntryNativeContext $n}
 }
 $n=New-TestNative
 try{
  $script:bindingResult=New-C1bDeviceEntryBinding $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $hostPin.path $hostPin.sha256 $OutputDirectory 0 0 $supportPin.path $supportPin.sha256 0 0
  $script:bindingPin=$bindingResult.binding
  $b=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($bindingPin.path))
  foreach($k in @('device_stage_started','device_stage_authorized_by_this_binding','device_evidence_verified','wrapper_enforces_binding','tablet_scene_ready_confirmed_by_user')){Assert-C1bEntry ($b[$k] -is [bool] -and -not $b[$k]) 'Binding falsely grants device stage.'}
  Assert-C1bEntry (@([IO.Directory]::EnumerateFileSystemEntries($bindingResult.receipt_root)).Count -eq 1) 'Binding consumed device attempt.'
  # Import the actual R3 decoder/guard definitions; no R3 flow, runner or device is started.
  $tdText=[IO.File]::ReadAllText((Join-Path $fixture 'scripts/lib/c1b-terminal-discovery.ps1'))
  $tdTokens=$null;$tdErrors=$null;$tdAst=[Management.Automation.Language.Parser]::ParseInput($tdText,[ref]$tdTokens,[ref]$tdErrors)
  Assert-C1bEntry ($tdErrors.Count -eq 0) 'Actual R3 source parser rejected.'
  foreach($name in @('Assert-C1bTd','ConvertFrom-C1bTdJson','Assert-C1bTdTerminalAuthority')){
   $definitions=@($tdAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name})
   Assert-C1bEntry ($definitions.Count -eq 1) 'One actual R3 decoder/guard definition required.'
   . ([scriptblock]::Create($definitions[0].Extent.Text))
  }
  $r3Binding=ConvertFrom-C1bTdJson ([IO.File]::ReadAllBytes($bindingPin.path))
  $r3Context=[pscustomobject]@{Root=$fixture;Commit=$sha}
  $r3Observation=[ordered]@{schema='c1b-device-external-process-observation/v1';expected_commit_sha=$sha;observation_status='observed';wrapper_started=$true;wrapper_launch_call_count=1;automatic_wrapper_retry_count=0;errors=@();binding_sha256=$bindingPin.sha256;expected_binding_sha256=$bindingPin.sha256;observed_runner_exit=1;observed_wrapper_exit=1;native_wrapper_exit=1;runner_pid=123;wrapper_pid=124}
  $r3Terminal=[ordered]@{schema='c1b-device-terminal-readback/v1';verification_status='verified';expected_commit_sha=$sha;cleanup_failure_count=0;readback_external_process_invocation_count=0;readback_device_invocation_count=0;observed_runner_exit=1;runner_exit=1;observed_outer_exit=1;observed_runner_pid=123;runner_pid=123;stdout_byte_length=0;stderr_byte_length=0;terminal_status='failed'}
  Assert-C1bTdTerminalAuthority $r3Context $r3Observation $r3Terminal $r3Binding $bindingPin.sha256
  $runner=Read-C1bEntryHeldFile $n (Join-Path $fixture $map.runner_sha256) $r3Binding.runner_sha256 -1 $false
  Assert-C1bEntry ($runner.Hash -ceq (Pin-Fixture $runner.Path).sha256 -and ('sha256:'+$runner.Hash) -ceq $implementation.runner_sha256) 'R3 binding does not match the actual current runner bytes.'
  foreach($mutation in @('missing','integer','prefixed','short')){
   $badBinding=Copy-Object $r3Binding
   switch($mutation){missing {$badBinding.Remove('runner_sha256')} integer {$badBinding.runner_sha256=42} prefixed {$badBinding.runner_sha256=$implementation.runner_sha256} short {$badBinding.runner_sha256='1'*63}}
   Must-Fail {Assert-C1bTdTerminalAuthority $r3Context $r3Observation $r3Terminal $badBinding $bindingPin.sha256} 'binding raw pin|runner_sha256'
  }
  $badBinding=Copy-Object $r3Binding;$badBinding.runner_sha256='0'*64
  Must-Fail {Read-C1bEntryHeldFile $n $runner.Path $badBinding.runner_sha256 -1 $false} 'Repeated pin differs|raw hash differs'
 }finally{Close-C1bEntryNativeContext $n}
}
if($null -ne $bindingPin){
 $bindingCapture=Save-CaptureFixture 'binding-native-fixture' -Stage Binding -StdoutBytes $utf8.GetBytes(($bindingResult|ConvertTo-Json -Depth 40 -Compress)+"`r`n")
 $prefix=[ordered]@{schema='c1b-observer-pre-device-preflight/v1';status='prepared_for_device_stage';expected_commit_sha=$sha;observer_sha256=$outputs['observe-next-device-launch-r1.ps1'].sha256;binding_sha256=$bindingPin.sha256;assertion_count=59;source_prefix_statement_count=8;source_prefix_completed=$true;native_definitions_compiled=$true;native_probe_scope='current preflight process only';active_process_exit_rejected=$true;guarded_file_count=3;guarded_directory_count=4;error=$null;cleanup_error_count=0;cleanup_errors=@();observer_top_level_invocations=0;wrapper_launches=0;child_process_launches=0;uac_requests=0;adb_or_device_commands=0;formal_stage_invocations=0;formal_reservation_created=$false;device_evidence_verified=$false;external_preflight_exit_zero_required=$true;scope='synthetic fixture only';recorded_at_utc='2026-09-30T00:00:02.5000000Z'}
 $prefixPin=Save-ReadonlyJson (Join-Path $fixture '.checks/c1b-host-readiness/1111111/device-r1-preflight.json') $prefix
 $prefixCapture=Save-CaptureFixture 'prefix-native-fixture' -Stage Prefix -SourcePin $outputs['preflight-device-observer-r1.ps1'] -StdoutBytes $utf8.GetBytes(($prefix|ConvertTo-Json -Depth 20 -Compress)+"`r`n") -Started '2026-09-30T00:00:02Z' -Completed '2026-09-30T00:00:03Z'
 $readyInputs=[ordered]@{schema='c1b-device-entry-ready-inputs/v1';candidate_sha=$sha;binding=$bindingPin;binding_capture=$bindingCapture;prefix_capture=$prefixCapture;prefix_result=$prefixPin}
 $readyInputsPin=Save-ReadonlyJson (Join-Path $OutputDirectory 'ready-inputs.json') $readyInputs
 Test-Case 'actual Ready consumer reads native binding and exact two-stream prefix fixture; no device grant' {
  function Import-C1bEntryPinnedDependency($Native,$Pin){Assert-C1bEntry ($Pin.path -ceq 'scripts/lib/c1b-host-acceptance.ps1') 'Unexpected mocked dependency.'}
  function Assert-C1bHostAcceptanceContract {param($CandidateSha,$EvidenceRoot,$ContractPath,$ContractSha256,$SummaryVerifierContext);return @{authority=$authority}}
  $n=New-TestNative;try{$p=New-C1bDeviceEntryReady $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $readyInputsPin.path $readyInputsPin.sha256 0 0;$r=ConvertFrom-C1bEntryJson ([IO.File]::ReadAllBytes($p.path));Assert-C1bEntry ($r.status -ceq 'host_ready_waiting_for_device_assistance' -and -not $r.device_stage_started -and -not $r.device_evidence_verified -and -not $r.current_scene_verified -and $r.fresh_device_scene_confirmation_required) 'Ready boundary differs.'}finally{Close-C1bEntryNativeContext $n}
 }
 Test-Case 'generated device capture consumes the exact native Ready publication path' {
  $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($utf8.GetString($generated['capture-device-observer-r1.ps1']),[ref]$t,[ref]$e)
  $a=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$readyPath'})
  Assert-C1bEntry ($a.Count -eq 1) 'One production Ready path required.';$repo=$fixture
  . ([scriptblock]::Create($a[0].Extent.Text));Assert-C1bEntry ($readyPath -ceq (Join-Path $fixture '.checks/c1b-host-readiness/1111111/host-ready-r1.json') -and [IO.File]::Exists($readyPath)) 'Ready producer/consumer path mismatch.'
 }
 Test-Case 'Ready string counter numeric false and missing flag reject despite coherent raw prefix pins' {
  function Import-C1bEntryPinnedDependency($Native,$Pin){}
  function Assert-C1bHostAcceptanceContract {param($CandidateSha,$EvidenceRoot,$ContractPath,$ContractSha256,$SummaryVerifierContext);return @{authority=$authority}}
  $original=[IO.File]::ReadAllBytes($prefixPin.path)
  foreach($row in @(@('prefix-string-counter',{param($v)$v.adb_or_device_commands='0'},'integer'),@('prefix-numeric-false',{param($v)$v.formal_reservation_created=0},'boolean'),@('prefix-missing-flag',{param($v)$v.Remove('device_evidence_verified')},'key count'))){
   $bad=Copy-Object $prefix;& $row[1] $bad;[IO.File]::SetAttributes($prefixPin.path,[IO.FileAttributes]::Normal);$badPrefix=Save-ReadonlyJson $prefixPin.path $bad
   $badCapture=Save-CaptureFixture $row[0] -Stage Prefix -SourcePin $outputs['preflight-device-observer-r1.ps1'] -StdoutBytes $utf8.GetBytes(($bad|ConvertTo-Json -Depth 20 -Compress)+"`r`n") -Started '2026-09-30T00:00:02Z' -Completed '2026-09-30T00:00:03Z'
   $ri=Copy-Object $readyInputs;$ri.prefix_result=$badPrefix;$ri.prefix_capture=$badCapture;$rp=Save-ReadonlyJson (Join-Path $OutputDirectory ($row[0]+'.json')) $ri
   $n=New-TestNative;try{Must-Fail {New-C1bDeviceEntryReady $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $rp.path $rp.sha256 0 0} $row[2]}finally{Close-C1bEntryNativeContext $n;[IO.File]::SetAttributes($prefixPin.path,[IO.FileAttributes]::Normal);[IO.File]::WriteAllBytes($prefixPin.path,$original);[IO.File]::SetAttributes($prefixPin.path,[IO.FileAttributes]::ReadOnly)}
  }
 }
 Test-Case 'Ready attempt replay with runner artifact rejects before publication' {
  function Import-C1bEntryPinnedDependency($Native,$Pin){}
  function Assert-C1bHostAcceptanceContract {param($CandidateSha,$EvidenceRoot,$ContractPath,$ContractSha256,$SummaryVerifierContext);return @{authority=$authority}}
  $p=Join-Path $bindingResult.receipt_root 'reservation.json';[IO.File]::WriteAllText($p,'{}')
  $n=New-TestNative;try{Must-Fail {New-C1bDeviceEntryReady $n $manifestPath $manifestPin.sha256 $reviewPath $reviewPin.sha256 $readyInputsPin.path $readyInputsPin.sha256 0 0} 'already consumed'}finally{Close-C1bEntryNativeContext $n}
 }
}
$summary=[ordered]@{schema='c1b-device-entry-source-offline/v1';passed=$passed;failed=$failed;cases=$records.ToArray();output_directory=$OutputDirectory;source_execution_count=1;source_execution_scope='One cold rendered mechanical review-entry only; synthetic repository and evidence';helper_launcher_build_adb_provider_invocations=0;host_acceptance_stub_scope='Only binding/Ready composition fixture; independent host acceptance suite required';device_evidence_verified=$false}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($summary|ConvertTo-Json -Depth 12),$utf8)
Write-Output ("cases=$($passed+$failed) passed=$passed failed=$failed source_execution_count=1 helper_launcher_build_adb_provider_invocations=0")
if($failed -gt 0){exit 1};exit 0
