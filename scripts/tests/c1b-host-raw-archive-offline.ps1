#Requires -Version 7.5
[CmdletBinding()]param([string]$EvidenceRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if([string]::IsNullOrWhiteSpace($EvidenceRoot)){$EvidenceRoot=Join-Path $repo '.checks\c1b-host-raw-archive-offline'}
$run=Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) ('run-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($run)
$entry=Join-Path $repo 'scripts\seal-c1b-host-raw-evidence.ps1';$ha=Join-Path $repo 'scripts\lib\c1b-host-acceptance.ps1';$pwsh=[Environment]::ProcessPath;$utf8=[Text.UTF8Encoding]::new($false)
. (Join-Path $repo 'scripts\lib\c1b-host-process-capture.ps1')
$cases=[Collections.Generic.List[object]]::new();$script:assertions=0
function Check([bool]$Value,[string]$Message){$script:assertions++;if(-not$Value){throw $Message}}
function Pin([string]$Path){$bytes=[IO.File]::ReadAllBytes($Path);return [pscustomobject][ordered]@{path=$Path;byte_length=$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()}}
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20)+"`n",$utf8)}
function Load([string]$Path){return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path,$utf8)) -Depth 24 -DateKind String}
function New-Inputs([string]$Case){
    $root=Join-Path $run $Case;[void][IO.Directory]::CreateDirectory($root)
    $source=Join-Path $root 'source.bin';$empty=Join-Path $root 'empty.bin';[IO.File]::WriteAllBytes($source,[byte[]](0,255,13,10,128,65));[IO.File]::WriteAllBytes($empty,[byte[]]@())
    $b=[pscustomobject][ordered]@{schema='c1b-host-raw-archive-inputs/v1';candidate_sha=('a'*40);run_id=[guid]::NewGuid().ToString('N');evidence_root=$root;archive_directory=(Join-Path $root 'sealed');trusted_source_roots=@($repo);ha_module_pin=(Pin $ha);producer_source_pin=(Pin $entry);sources=@((Pin $source),(Pin $empty))}
    $path=Join-Path $root 'inputs.json';Save $path $b
    return [pscustomobject]@{Root=$root;Bindings=$b;Input=$path;Source=$source;Empty=$empty}
}
function Invoke-Sealer($InputCase,[string]$Suffix='outer'){
    Save $InputCase.Input $InputCase.Bindings
    $argv=@('-NoProfile','-File',$entry,'-BindingsPath',$InputCase.Input,'-ExpectedBindingsSha256',(Pin $InputCase.Input).sha256)
    return Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $InputCase.Root -EvidenceDirectory (Join-Path $InputCase.Root $Suffix) -TimeoutMilliseconds 15000 -DrainTimeoutMilliseconds 1500 -CleanupTimeoutMilliseconds 4000
}
function Case([string]$Name,[scriptblock]$Body){try{&$Body;$cases.Add([pscustomobject]@{name=$Name;status='passed';error=$null});Write-Output "PASS $Name"}catch{$cases.Add([pscustomobject]@{name=$Name;status='failed';error=$_.Exception.Message});Write-Output "FAIL $Name`: $($_.Exception.Message)"}}
Case 'actual_raw_copies_readonly_manifest_and_source_preservation' {
    $i=New-Inputs 'valid';$sourceBefore=Pin $i.Source;$sourceAttributes=[IO.File]::GetAttributes($i.Source)
    $outer=Invoke-Sealer $i;Check ($outer.status-ceq'passed'-and$outer.exit_code-eq0-and$outer.stdout.eof-and$outer.stderr.eof-and$outer.cleanup.completed) 'sealer actual outer transport failed'
    $report=Load (Join-Path $i.Root 'outer\stdout.bin');Check ($report.schema-ceq'c1b-host-raw-archive-write/v1'-and$report.producer_process_id-eq$outer.child_pid-and$report.run_id-ceq$i.Bindings.run_id) 'sealer report did not bind actual PID/run'
    $manifest=Load $report.archive_pin.path;Check ($manifest.status-ceq'sealed_raw_archive'-and$manifest.members.Count-eq2-and$manifest.source_mutation_count-eq0-and$manifest.cleanup_failure_count-eq0) 'manifest closure invalid'
    foreach($member in $manifest.members){$src=Pin $member.source_pin.path;$copy=Pin $member.copy_pin.path;Check ($src.sha256-ceq$copy.sha256-and$src.byte_length-eq$copy.byte_length-and$member.copy_pin.sha256-ceq$copy.sha256) 'raw bytes differ';Check (([IO.File]::GetAttributes($copy.path)-band[IO.FileAttributes]::ReadOnly)-ne0) 'copy not read-only'}
    Check (([IO.File]::GetAttributes($report.archive_pin.path)-band[IO.FileAttributes]::ReadOnly)-ne0) 'manifest not read-only'
    Check ((Pin $i.Source).sha256-ceq$sourceBefore.sha256-and[IO.File]::GetAttributes($i.Source)-eq$sourceAttributes) 'sealer changed source bytes/attributes'
    $stream=[IO.File]::Open($i.Source,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$stream.Dispose();Check ($true) 'source guards not released'
}
Case 'source_hash_drift_and_required_missing_keep_failed_namespace' {
    foreach($kind in @('hash','missing')){
        $i=New-Inputs ('bad-'+$kind)
        if($kind-ceq'hash'){[IO.File]::AppendAllText($i.Source,'changed')}else{$i.Bindings.sources[0].path=Join-Path $i.Root 'missing.bin'}
        $outer=Invoke-Sealer $i;Check ($outer.exit_code-eq1-and$outer.status-ceq'failed') "$kind source wrongly passed"
        Check ([IO.File]::Exists((Join-Path $i.Bindings.archive_directory 'reservation.json'))-and-not[IO.File]::Exists((Join-Path $i.Bindings.archive_directory 'archive.json'))-and-not[IO.File]::Exists((Join-Path $i.Bindings.archive_directory 'failure.json'))) "$kind failed namespace was not preserved without unguarded publication"
        $again=Invoke-Sealer $i 'outer-repeat';Check ($again.exit_code-eq1) "$kind namespace retried"
    }
}
Case 'duplicate_escape_and_recursive_inventory_rejected' {
    foreach($kind in @('duplicate','escape','recursive')){
        $i=New-Inputs ('inventory-'+$kind)
        if($kind-ceq'duplicate'){$i.Bindings.sources+=,$i.Bindings.sources[0]}
        elseif($kind-ceq'escape'){$outside=Join-Path $run 'outside.bin';[IO.File]::WriteAllBytes($outside,[byte[]](1));$i.Bindings.sources[0]=Pin $outside}
        else{$i.Bindings.sources[0].path=Join-Path $i.Bindings.archive_directory 'nested.bin'}
        if($kind-ceq'escape'){$i.Bindings.trusted_source_roots=@((Join-Path $repo 'scripts'))}
        $outer=Invoke-Sealer $i;Check ($outer.exit_code-eq1-and-not[IO.Directory]::Exists($i.Bindings.archive_directory)) "$kind inventory admitted/reserved"
    }
}
Case 'closed_inventory_types_unknown_and_duplicate_json_rejected' {
    foreach($kind in @('schema-array','root-array','source-path-array','source-length-string','unknown-key','duplicate-key')){
        $i=New-Inputs ('types-'+$kind)
        switch($kind){
            'schema-array'{$i.Bindings.schema=@($i.Bindings.schema)}
            'root-array'{$i.Bindings.archive_directory=@($i.Bindings.archive_directory)}
            'source-path-array'{$i.Bindings.sources[0].path=@($i.Bindings.sources[0].path)}
            'source-length-string'{$i.Bindings.sources[0].byte_length=[string]$i.Bindings.sources[0].byte_length}
            'unknown-key'{$i.Bindings|Add-Member -NotePropertyName extra -NotePropertyValue 'unknown'}
        }
        if($kind-ceq'duplicate-key'){
            Save $i.Input $i.Bindings;$raw=[IO.File]::ReadAllText($i.Input,$utf8);$raw=$raw.Replace('"schema": "c1b-host-raw-archive-inputs/v1"','"schema": "c1b-host-raw-archive-inputs/v1", "schema": "c1b-host-raw-archive-inputs/v1"');[IO.File]::WriteAllText($i.Input,$raw,$utf8)
            Check (([regex]::Matches($raw,'"schema"\s*:')).Count-eq2) 'duplicate key fixture creation failed'
            $argv=@('-NoProfile','-File',$entry,'-BindingsPath',$i.Input,'-ExpectedBindingsSha256',(Pin $i.Input).sha256)
            $outer=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $i.Root -EvidenceDirectory (Join-Path $i.Root 'outer') -TimeoutMilliseconds 15000
        }else{$outer=Invoke-Sealer $i}
        Check ($outer.exit_code-eq1-and-not[IO.Directory]::Exists((Join-Path $i.Root 'sealed'))) "$kind inventory admitted/reserved"
    }
}
Case 'collision_never_overwrites_success_namespace' {
    $i=New-Inputs 'collision';$first=Invoke-Sealer $i;Check ($first.exit_code-eq0) 'collision setup failed'
    $manifest=Pin (Join-Path $i.Bindings.archive_directory 'archive.json');$second=Invoke-Sealer $i 'outer-repeat'
    Check ($second.exit_code-eq1-and(Pin $manifest.path).sha256-ceq$manifest.sha256) 'collision overwrote successful namespace'
}
Case 'hardlink_and_junction_sources_rejected' {
    foreach($kind in @('hardlink','junction')){
        $i=New-Inputs ('link-'+$kind)
        if($kind-ceq'hardlink'){$link=Join-Path $i.Root 'hardlink.bin';[void](New-Item -ItemType HardLink -Path $link -Target $i.Source);$i.Bindings.sources[0]=Pin $link}
        else{$target=Join-Path $i.Root 'target';[void][IO.Directory]::CreateDirectory($target);$source=Join-Path $target 'source.bin';[IO.File]::WriteAllBytes($source,[byte[]](4,5));$link=Join-Path $i.Root 'junction';[void](New-Item -ItemType Junction -Path $link -Target $target);$i.Bindings.sources[0]=Pin (Join-Path $link 'source.bin')}
        $outer=Invoke-Sealer $i;Check ($outer.exit_code-eq1-and[IO.File]::Exists((Join-Path $i.Bindings.archive_directory 'reservation.json'))-and-not[IO.File]::Exists((Join-Path $i.Bindings.archive_directory 'archive.json'))) "$kind source accepted"
    }
}
Case 'canonical_git_native_alias_group_is_complete_and_required' {
    # Read the installed tool bytes and native hardlink identities; never execute it.
    . $ha
    $gitRoot=[IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),'Git')
    $gitPath=[IO.Path]::Combine($gitRoot,'cmd','git.exe');$gitPin=Pin $gitPath
    $toolSession=New-C1bHASession @($gitRoot)
    try{
        $null=Read-C1bHAGitToolPin $toolSession $gitPin
        $toolPins=@($toolSession.files.Values|ForEach-Object{[pscustomobject]$_.pin}|Sort-Object path)
        $nativeLinks=$toolSession.files[$gitPath].identity.Links
        Check ($toolPins.Count-eq$nativeLinks-and$toolPins.Count-ge1) 'canonical tool inventory differs from native link count'
    }finally{Close-C1bHASession $toolSession}
    $i=New-Inputs 'canonical-git';$i.Bindings.trusted_source_roots+=,$gitRoot;$i.Bindings.sources=$toolPins
    $outer=Invoke-Sealer $i;Check ($outer.exit_code-eq0-and$outer.stdout.eof-and$outer.stderr.eof) 'complete canonical tool group failed'
    $manifest=Load (Join-Path $i.Bindings.archive_directory 'archive.json');Check ($manifest.members.Count-eq$toolPins.Count) 'canonical tool aliases not all copied'
    foreach($member in $manifest.members){Check ((Pin $member.copy_pin.path).sha256-ceq$gitPin.sha256) 'canonical tool raw copy drift'}
    if($toolPins.Count-gt1){
        $incomplete=New-Inputs 'canonical-git-missing-alias';$incomplete.Bindings.trusted_source_roots+=,$gitRoot;$incomplete.Bindings.sources=@($gitPin)
        $rejected=Invoke-Sealer $incomplete;Check ($rejected.exit_code-eq1-and[IO.File]::Exists((Join-Path $incomplete.Bindings.archive_directory 'reservation.json'))-and-not[IO.File]::Exists((Join-Path $incomplete.Bindings.archive_directory 'archive.json'))) 'incomplete canonical alias inventory accepted'
        $aliasOnly=New-Inputs 'canonical-git-without-primary';$aliasOnly.Bindings.trusted_source_roots+=,$gitRoot;$aliasOnly.Bindings.sources=@($toolPins|Where-Object{$_.path-cne$gitPath})
        $rejected=Invoke-Sealer $aliasOnly;Check ($rejected.exit_code-eq1-and-not[IO.File]::Exists((Join-Path $aliasOnly.Bindings.archive_directory 'archive.json'))) 'tool aliases admitted without canonical primary'
    }
}
Case 'copy_hash_drift_detected_by_independent_guard_consumer' {
    $i=New-Inputs 'copy-drift';$outer=Invoke-Sealer $i;Check ($outer.exit_code-eq0) 'copy drift setup failed'
    $manifest=Load (Join-Path $i.Bindings.archive_directory 'archive.json');$pin=$manifest.members[0].copy_pin
    [IO.File]::SetAttributes($pin.path,[IO.File]::GetAttributes($pin.path)-band(-bnot[IO.FileAttributes]::ReadOnly));[IO.File]::AppendAllText($pin.path,'tampered')
    $checker=Join-Path $i.Root 'independent-copy-check.ps1'
    [IO.File]::WriteAllText($checker,@'
param([string]$Module,[string]$Root,[string]$PinPath)
$ErrorActionPreference='Stop';. $Module
$session=New-C1bHASession @($Root)
try{$pin=ConvertFrom-C1bHAStrictJson ([IO.File]::ReadAllText($PinPath));$null=Read-C1bHAFile $session $pin;exit 0}catch{exit 17}finally{Close-C1bHASession $session}
'@,$utf8)
    $pinPath=Join-Path $i.Root 'copy-pin.json';Save $pinPath $pin
    $argv=@('-NoProfile','-File',$checker,'-Module',$ha,'-Root',$i.Root,'-PinPath',$pinPath)
    $check=Invoke-TL1C1bHostProcessCapture -ExecutablePath $pwsh -ArgumentList $argv -WorkingDirectory $i.Root -EvidenceDirectory (Join-Path $i.Root 'copy-check') -TimeoutMilliseconds 15000
    Check ($check.exit_code-eq17-and$check.stdout.eof-and$check.stderr.eof) 'independent consumer failed to detect changed copy'
}
$passed=@($cases|Where-Object status -CEQ passed).Count;$failed=$cases.Count-$passed
Save (Join-Path $run 'summary.json') ([ordered]@{schema='c1b-host-raw-archive-offline/v1';status=$(if($failed-eq0){'passed'}else{'failed'});runtime=$PSVersionTable.PSVersion.ToString();passed=$passed;failed=$failed;assertions=$script:assertions;cases=$cases.ToArray();real_git_build_device_call_count=0})
Write-Output "host-raw-archive: $passed passed / $failed failed; $script:assertions assertions; evidence=$run"
if($failed-gt0){exit 1};exit 0
