#Requires -Version 7.6
# Definition-only maintenance source. Calling generation does not execute an entry.
Set-StrictMode -Version Latest
$script:C1bDeviceEntryLeaves = @(
 'invoke-next-device-once-r1.ps1','observe-next-device-launch-r1.ps1','verify-next-device-terminal-r1.ps1',
 'preflight-device-observer-r1.ps1','capture-device-observer-r1.ps1','capture-observer-preflight-r1.ps1',
 'capture-r1-host-step.ps1','prepare-device-binding-r1.ps1','publish-device-ready-r1.ps1',
 'publish-reviewed-r1-sources.ps1','capture-source-publication-r1.ps1','capture-ready-publication-r1.ps1',
 'capture-support.ps1','capture-source-publication-outer-r1.ps1','review-support.ps1',
 'review-entry.ps1','review-auxiliary.ps1','capture-review.ps1','review-support-source.ps1','capture-support-review.ps1'
)
function Assert-C1bEntry([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
function Get-C1bEntryHash([AllowEmptyCollection()][byte[]]$Bytes) {
 [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Assert-C1bEntryKeys($Object,[string[]]$Keys) {
 Assert-C1bEntry ($Object -is [Collections.IDictionary]) 'Expected closed object.'
 Assert-C1bEntry ($Object.Count -eq $Keys.Count) 'Closed object key count differs.'
 foreach($key in $Keys){Assert-C1bEntry (@($Object.Keys|Where-Object {$_ -ceq $key}).Count -eq 1) ('Missing exact key: '+$key)}
}
function Assert-C1bEntryInteger($Value,[long]$Minimum=0,[long]$Maximum=2147483647) {
 Assert-C1bEntry (($Value -is [int] -or $Value -is [long]) -and $Value -ge $Minimum -and $Value -le $Maximum) 'Actual integer required; coercion rejected.'
}
function Assert-C1bEntryBoolean($Value,[bool]$Expected) {
 Assert-C1bEntry ($Value -is [bool] -and $Value -eq $Expected) 'Actual boolean required; coercion rejected.'
}
function Assert-C1bEntryRawPin($Pin) {
 Assert-C1bEntryKeys $Pin @('path','byte_length','sha256')
 $null=Get-C1bEntryCanonicalPath $Pin.path
 Assert-C1bEntryInteger $Pin.byte_length 0 8388608
 Assert-C1bEntry ($Pin.sha256 -is [string] -and $Pin.sha256 -cmatch '^[0-9a-f]{64}$') 'Canonical raw hash required.'
}
function ConvertFrom-C1bEntryJson([byte[]]$Bytes) {
 Assert-C1bEntry ($Bytes.Length -gt 0 -and $Bytes.Length -le 8388608) 'JSON size bound.'
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
 Assert-C1bEntry (-not $text.StartsWith([char]0xfeff)) 'JSON BOM rejected.'
 $doc=[Text.Json.JsonDocument]::Parse($text)
 function Inspect-C1bEntryJson($Element){
  if($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object){
   $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
   foreach($p in $Element.EnumerateObject()){Assert-C1bEntry ($seen.Add($p.Name)) 'Duplicate JSON key.';Inspect-C1bEntryJson $p.Value}
  }elseif($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array){foreach($v in $Element.EnumerateArray()){Inspect-C1bEntryJson $v}}
 }
 try{Assert-C1bEntry ($doc.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) 'JSON root object required.';Inspect-C1bEntryJson $doc.RootElement}finally{$doc.Dispose()}
 $text|ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}
function Get-C1bEntryCanonicalPath([string]$Path) {
 Assert-C1bEntry ([IO.Path]::IsPathFullyQualified($Path) -and $Path -cnotmatch "[\r\n\x00]") 'Canonical absolute path required.'
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
 Assert-C1bEntry ([IO.Path]::IsPathFullyQualified($full)) 'Drive root is not an entry or repository path.'
 Assert-C1bEntry ([StringComparer]::OrdinalIgnoreCase.Equals($Path.TrimEnd('\','/'),$full)) 'Path must already be normalized.'
 $full
}
function Assert-C1bEntryOrdinaryChain([string]$Path) {
 $item=Get-Item -LiteralPath $Path -Force
 Assert-C1bEntry ($item -is [IO.FileInfo] -or $item -is [IO.DirectoryInfo]) 'Filesystem entry required.'
 for($p=$item;$null -ne $p;$p=$(if($p -is [IO.FileInfo]){$p.Directory}else{$p.Parent})){
  Assert-C1bEntry (($p.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Reparse chain rejected.'
 }
}
function New-C1bEntryNativeContext([string]$RepoRoot,[string]$StrictSha256,[long]$StrictLength) {
 $repo=Get-C1bEntryCanonicalPath $RepoRoot
 Assert-C1bEntry ($StrictSha256 -cmatch '^[0-9a-f]{64}$' -and $StrictLength -gt 0 -and $StrictLength -le 1048576) 'Strict source pin invalid.'
 $path=Join-Path $repo 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
 Assert-C1bEntryOrdinaryChain $path
 $bootstrap=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read);$ctx=$null
 try{
  Assert-C1bEntry ($bootstrap.Length -eq $StrictLength) 'Strict source length drift.'
  $bytes=[byte[]]::new([int]$StrictLength);$bootstrap.ReadExactly($bytes)
  Assert-C1bEntry ((Get-C1bEntryHash $bytes) -ceq $StrictSha256) 'Strict source raw hash drift.'
  if($null -eq ('TL1C1bRealBuildSmokeFileIdentityV1' -as [type])){
   $nativeText=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
   . ([scriptblock]::Create($nativeText))
   # Definition import must survive this function's scope; no verifier entry is called.
   $nativeTokens=$null;$nativeErrors=$null;$nativeAst=[Management.Automation.Language.Parser]::ParseInput($nativeText,[ref]$nativeTokens,[ref]$nativeErrors)
   foreach($definition in @($nativeAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})){
    Set-Item -LiteralPath ('Function:script:'+$definition.Name) -Value (Get-Item -LiteralPath ('Function:'+$definition.Name)).ScriptBlock
   }
   $script:C1bEntryNativeHash=$StrictSha256
  }else{
   Assert-C1bEntry ((Get-Variable C1bEntryNativeHash -Scope Script -ErrorAction SilentlyContinue) -and $script:C1bEntryNativeHash -ceq $StrictSha256) 'Native authority was loaded outside this pinned maintenance context.'
  }
  $ctx=[pscustomobject]@{RepoRoot=$repo;Bootstrap=$bootstrap;Files=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);Directories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase);Cleanup=[Collections.Generic.List[string]]::new()}
  $null=Read-C1bEntryHeldFile $ctx $path $StrictSha256 $StrictLength $false
  return $ctx
 }catch{
  $primary=$_.Exception
  if($null -ne $ctx){try{Close-C1bEntryNativeContext $ctx}catch{throw [AggregateException]::new('Native setup and cleanup failed.',[Exception[]]@($primary,$_.Exception))}}else{$bootstrap.Dispose()}
  throw $primary
 }
}
function Add-C1bEntryHeldDirectories($Context,[string]$Path) {
 foreach($dir in (Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain $Path)){
  if($Context.Directories.ContainsKey($dir)){continue}
  $h=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete($dir)
  $b=[pscustomobject]@{Path=$dir;Handle=$h;Identity=$null};$Context.Directories.Add($dir,$b)
  $b.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($h)
  Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity $b.Identity
  Assert-TL1C1bRealBuildSmokeHandleFinalPath $h $dir
 }
}
function Read-C1bEntryHeldFile($Context,[string]$Path,[string]$Sha256,[long]$Length=-1,[bool]$ReadOnly=$true) {
 $full=Get-C1bEntryCanonicalPath $Path
 Assert-C1bEntry ($Sha256 -cmatch '^[0-9a-f]{64}$') 'Expected raw pin required.'
 if($Context.Files.ContainsKey($full)){
  $old=$Context.Files[$full]
  Assert-C1bEntry ($old.Hash -ceq $Sha256 -and ($Length -lt 0 -or $old.Length -eq $Length)) 'Repeated pin differs.'
  if($ReadOnly){Assert-C1bEntry (($old.Identity.FileAttributes -band 1) -ne 0) 'Readonly source required.'}
  return $old
 }
 Add-C1bEntryHeldDirectories $Context ([IO.Path]::GetDirectoryName($full))
 $h=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete($full)
 $b=[pscustomobject]@{Path=$full;Handle=$h;Stream=$null;Identity=$null;Length=0L;Hash=$null;Bytes=$null;ReadOnly=$ReadOnly};$Context.Files.Add($full,$b)
 $b.Stream=[IO.FileStream]::new($h,[IO.FileAccess]::Read);$b.Length=$b.Stream.Length
 Assert-C1bEntry ($b.Length -le 8388608 -and ($Length -lt 0 -or $Length -eq $b.Length)) 'Input length bound or pin differs.'
 $b.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($h)
 Assert-TL1C1bRealBuildSmokeHeldFileIdentity $b.Identity $b.Length
 Assert-TL1C1bRealBuildSmokeHandleFinalPath $h $full
 if($ReadOnly){Assert-C1bEntry (($b.Identity.FileAttributes -band 1) -ne 0) 'Readonly input required.'}
 $b.Bytes=[byte[]]::new([int]$b.Length);$b.Stream.ReadExactly($b.Bytes)
 Assert-C1bEntry ($b.Stream.ReadByte() -eq -1) 'Held source grew.'
 $b.Hash=Get-C1bEntryHash $b.Bytes;Assert-C1bEntry ($b.Hash -ceq $Sha256) 'Held source raw hash differs.'
 Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $full $b.Identity $b.Length
 $b
}
function Assert-C1bEntryHeld($Context) {
 foreach($b in $Context.Files.Values){
  $now=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($b.Handle)
  Assert-TL1C1bRealBuildSmokeHeldFileIdentity $now $b.Length
  Assert-C1bEntry ($now.StableId -ceq $b.Identity.StableId -and $now.LastWriteTimeUtcFileTime -eq $b.Identity.LastWriteTimeUtcFileTime) 'Held identity/time drift.'
  if($b.ReadOnly){Assert-C1bEntry (($now.FileAttributes -band 1) -ne 0) 'Readonly attribute drift.'}
  Assert-TL1C1bRealBuildSmokeHandleFinalPath $b.Handle $b.Path
  Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $b.Path $now $b.Length
  $b.Stream.Position=0
  Assert-C1bEntry ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($b.Stream)).ToLowerInvariant() -ceq $b.Hash) 'Held raw bytes drift.'
 }
 foreach($b in $Context.Directories.Values){Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld $b;Assert-TL1C1bRealBuildSmokeHandleFinalPath $b.Handle $b.Path}
}
function Close-C1bEntryNativeContext($Context) {
 if($null -eq $Context){return}
 foreach($b in $Context.Files.Values){try{if($null -ne $b.Stream){$b.Stream.Dispose()}else{$b.Handle.Dispose()}}catch{$Context.Cleanup.Add($_.Exception.Message)}}
 foreach($b in $Context.Directories.Values){try{$b.Handle.Dispose()}catch{$Context.Cleanup.Add($_.Exception.Message)}}
 try{$Context.Bootstrap.Dispose()}catch{$Context.Cleanup.Add($_.Exception.Message)}
 Assert-C1bEntry ($Context.Cleanup.Count -eq 0) 'Native context cleanup failed.'
}
function Get-C1bEntryPin($Held){[ordered]@{path=$Held.Path;byte_length=$Held.Length;sha256=$Held.Hash}}
function Write-C1bEntryNewReadonly($Context,[string]$Path,[byte[]]$Bytes) {
 $full=Get-C1bEntryCanonicalPath $Path
 Add-C1bEntryHeldDirectories $Context ([IO.Path]::GetDirectoryName($full))
 Assert-C1bEntryHeld $Context
 $s=[IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
 try{
  $before=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($s.SafeFileHandle)
  Assert-TL1C1bRealBuildSmokeHeldFileIdentity $before 0
  Assert-TL1C1bRealBuildSmokeHandleFinalPath $s.SafeFileHandle $full
  $s.Write($Bytes);$s.Flush($true)
  [IO.File]::SetAttributes($full,[IO.File]::GetAttributes($full) -bor [IO.FileAttributes]::ReadOnly)
  $after=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($s.SafeFileHandle)
  Assert-TL1C1bRealBuildSmokeHeldFileIdentity $after $Bytes.Length
  Assert-C1bEntry ($before.StableId -ceq $after.StableId -and ($after.FileAttributes -band 1) -ne 0) 'Published identity/readonly differs.'
  $s.Position=0;Assert-C1bEntry ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant() -ceq (Get-C1bEntryHash $Bytes)) 'Published raw readback differs.'
 }finally{$s.Dispose()}
 $held=Read-C1bEntryHeldFile $Context $full (Get-C1bEntryHash $Bytes) $Bytes.Length
 Assert-C1bEntry ($held.Identity.StableId -ceq $before.StableId) 'Published identity changed on close.'
 Assert-C1bEntryHeld $Context
 Get-C1bEntryPin $held
}
function Get-C1bDeviceEntryTemplatePins([string]$RepoRoot) {
 $root=Join-Path $RepoRoot 'scripts/lib/c1b-device-entry-source';$pins=[ordered]@{}
 foreach($leaf in $script:C1bDeviceEntryLeaves){
  $path=Join-Path $root $leaf;Assert-C1bEntryOrdinaryChain $path
  $bytes=[IO.File]::ReadAllBytes($path)
  $pins[$leaf]=[ordered]@{path=('scripts/lib/c1b-device-entry-source/'+$leaf);byte_length=$bytes.Length;sha256=(Get-C1bEntryHash $bytes)}
 }
 $pins
}
function Assert-C1bDeviceEntryGenerationContext($Context) {
 Assert-C1bEntryKeys $Context @('schema','candidate_sha','repo_root','entry_root','pwsh_path','runtime_sha256','strict_pin','implementation_hashes','implementation_catalog_sha256','authority','dependency_pins','template_pins')
 Assert-C1bEntry ($Context.schema -ceq 'c1b-device-entry-generation-context/v1' -and $Context.candidate_sha -cmatch '^[0-9a-f]{40}$') 'Generation identity invalid.'
 foreach($k in @('repo_root','entry_root','pwsh_path')){$null=Get-C1bEntryCanonicalPath $Context[$k]}
 Assert-C1bEntry ($Context.runtime_sha256 -ceq '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139') 'Pinned runtime required.'
 Assert-C1bEntry ($Context.implementation_hashes -is [Collections.IDictionary] -and $Context.implementation_hashes.Count -eq 42) 'Exact 42 input catalog required.'
 foreach($h in $Context.implementation_hashes.Values){Assert-C1bEntry ($h -cmatch '^sha256:[0-9a-f]{64}$') 'Implementation raw hash invalid.'}
 $map=Get-C1bEntryImplementationPathMap $Context.repo_root $Context.implementation_hashes.c1b_library_sha256.Substring(7)
 Assert-C1bEntryKeys $Context.implementation_hashes @($map.Keys)
 $lines=[string[]]@($map.Keys|ForEach-Object {$map[$_]+'='+$Context.implementation_hashes[$_]})
 [Array]::Sort($lines,[StringComparer]::Ordinal)
 Assert-C1bEntry ($Context.implementation_catalog_sha256 -ceq ('sha256:'+(Get-C1bEntryHash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))))) 'Implementation catalog raw pins differ.'
 Assert-C1bEntryKeys $Context.template_pins $script:C1bDeviceEntryLeaves
 foreach($pin in @($Context.strict_pin)+@($Context.dependency_pins.Values)+@($Context.template_pins.Values)){
  Assert-C1bEntryKeys $pin @('path','byte_length','sha256')
  Assert-C1bEntry ($pin.sha256 -cmatch '^[0-9a-f]{64}$' -and ($pin.byte_length -is [int] -or $pin.byte_length -is [long]) -and $pin.byte_length -gt 0 -and $pin.byte_length -le 8388608) 'Maintenance source raw pin invalid.'
 }
 Assert-C1bEntryKeys $Context.dependency_pins @('maintenance','host_acceptance','terminal_discovery','terminal_discovery_bridge','host_capture')
 $expectedDependencies=@{maintenance='scripts/lib/c1b-device-entry-source.ps1';host_acceptance='scripts/lib/c1b-host-acceptance.ps1';terminal_discovery='scripts/lib/c1b-terminal-discovery.ps1';terminal_discovery_bridge='scripts/read-c1b-terminal-discovery.ps1';host_capture='scripts/lib/c1b-host-process-capture.ps1'}
 foreach($k in $expectedDependencies.Keys){Assert-C1bEntry ($Context.dependency_pins[$k].path -ceq $expectedDependencies[$k]) 'Exact tracked dependency path required.'}
 Assert-C1bEntry ($Context.strict_pin.path -ceq 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1') 'Exact strict source required.'
 Assert-C1bEntryKeys $Context.authority @('repo_root','branch','git_entry_kind','git_index_sha256','git_index_byte_length','tracked_path_count','implementation_catalog_sha256','implementation_hashes','git_metadata')
 Assert-C1bEntry ($Context.authority.repo_root -ceq $Context.repo_root -and $Context.authority.implementation_catalog_sha256 -ceq $Context.implementation_catalog_sha256 -and ($Context.authority.implementation_hashes|ConvertTo-Json -Compress) -ceq ($Context.implementation_hashes|ConvertTo-Json -Compress)) 'Context and authority raw input map differ.'
 Assert-C1bEntry ($Context.authority.git_entry_kind -ceq 'directory' -and $Context.authority.branch -cmatch '^codex/[A-Za-z0-9._/-]+$' -and $Context.authority.branch -cnotmatch '\.\.|//' -and $Context.authority.git_index_sha256 -cmatch '^[0-9a-f]{64}$' -and $Context.authority.git_index_byte_length -gt 0 -and $Context.authority.tracked_path_count -gt 0) 'Ordinary candidate Git authority invalid.'
 Assert-C1bEntryKeys $Context.authority.git_metadata @('head','ref','config','info_exclude','gitattributes','gitignore')
}
function Assert-C1bEntryCandidateAuthority($Native,$Context) {
 $a=$Context.authority;$repo=$Context.repo_root
 $null=Read-C1bEntryHeldFile $Native (Join-Path $repo '.git/index') $a.git_index_sha256 $a.git_index_byte_length $false
 $paths=@{head='.git/HEAD';ref=('.git/refs/heads/'+$a.branch);config='.git/config';info_exclude='.git/info/exclude';gitattributes='.gitattributes';gitignore='.gitignore'}
 foreach($key in $paths.Keys){
  $pin=$a.git_metadata[$key];Assert-C1bEntryKeys $pin @('path','byte_length','sha256')
  Assert-C1bEntry ($pin.path -ceq (Join-Path $repo $paths[$key])) 'Git metadata exact path differs.'
  $null=Read-C1bEntryHeldFile $Native $pin.path $pin.sha256 $pin.byte_length $false
 }
 $head=[Text.UTF8Encoding]::new($false,$true).GetString($Native.Files[$a.git_metadata.head.path].Bytes).TrimEnd("`r","`n")
 $ref=[Text.UTF8Encoding]::new($false,$true).GetString($Native.Files[$a.git_metadata.ref.path].Bytes).TrimEnd("`r","`n")
 Assert-C1bEntry ($head -ceq ('ref: refs/heads/'+$a.branch) -and $ref -ceq $Context.candidate_sha) 'Current held HEAD/ref does not bind candidate SHA.'
}
function Get-C1bEntryImplementationPathMap([string]$RepoRoot,[string]$LibrarySha256) {
 $path=Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b.ps1';Assert-C1bEntryOrdinaryChain $path
 $bytes=[IO.File]::ReadAllBytes($path);Assert-C1bEntry ((Get-C1bEntryHash $bytes) -ceq $LibrarySha256) 'Implementation map source pin differs.'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput([Text.UTF8Encoding]::new($false,$true).GetString($bytes),[ref]$tokens,[ref]$errors)
 Assert-C1bEntry ($errors.Count -eq 0) 'Implementation map parser rejected.'
 $assign=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$script:TL1C1bImplementationPathMap'})
 Assert-C1bEntry ($assign.Count -eq 1) 'One literal implementation map required.'
 $table=@($assign[0].Right.FindAll({param($a) $a -is [Management.Automation.Language.HashtableAst]},$true))
 Assert-C1bEntry ($table.Count -eq 1 -and $table[0].KeyValuePairs.Count -eq 42) 'Exact literal map required.'
 $map=[ordered]@{}
 foreach($pair in $table[0].KeyValuePairs){$key=$pair.Item1.SafeGetValue();$value=$pair.Item2.SafeGetValue();Assert-C1bEntry ($key -is [string] -and $value -is [string] -and $value -cmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -and -not $map.Contains($key)) 'Unsafe implementation literal.';$map[$key]=$value}
 $map
}
function New-C1bDeviceEntrySources($Context) {
 Assert-C1bDeviceEntryGenerationContext $Context
 $values=[ordered]@{ENTRY_ROOT=$Context.entry_root;REPO_ROOT=$Context.repo_root;PWSH_PATH=$Context.pwsh_path;CANDIDATE_SHA=$Context.candidate_sha;CANDIDATE_SHORT=$Context.candidate_sha.Substring(0,7);IMPLEMENTATION_CATALOG_HASH=$Context.implementation_catalog_sha256.Substring(7);STRICT_VERIFIER_HASH=$Context.strict_pin.sha256;STRICT_VERIFIER_LENGTH=$Context.strict_pin.byte_length}
 foreach($k in $Context.implementation_hashes.Keys){$values['INPUT_'+$k.ToUpperInvariant()]=$Context.implementation_hashes[$k].Substring(7)}
 foreach($k in $Context.dependency_pins.Keys){$values['DEPENDENCY_'+$k.ToUpperInvariant()+'_PATH']=Join-Path $Context.repo_root $Context.dependency_pins[$k].path;$values['DEPENDENCY_'+$k.ToUpperInvariant()+'_HASH']=$Context.dependency_pins[$k].sha256;$values['DEPENDENCY_'+$k.ToUpperInvariant()+'_LENGTH']=$Context.dependency_pins[$k].byte_length}
 $output=[ordered]@{}
 foreach($leaf in $script:C1bDeviceEntryLeaves){
  $pin=$Context.template_pins[$leaf];Assert-C1bEntry ($pin.path -ceq ('scripts/lib/c1b-device-entry-source/'+$leaf)) 'Template path must be exact.'
  $path=Join-Path $Context.repo_root $pin.path;Assert-C1bEntryOrdinaryChain $path
  $raw=[IO.File]::ReadAllBytes($path);Assert-C1bEntry ($raw.Length -eq $pin.byte_length -and (Get-C1bEntryHash $raw) -ceq $pin.sha256) 'Template raw pin drift.'
  $source=[Text.UTF8Encoding]::new($false,$true).GetString($raw)
  $tokens=@([regex]::Matches($source,'__[A-Z0-9_]+__')|ForEach-Object Value|Sort-Object -Unique)
  foreach($token in $tokens){
   $key=$token.Substring(2,$token.Length-4);Assert-C1bEntry ($values.Contains($key)) ('Unresolved source slot: '+$key)
   $v=$values[$key]
   if($v -is [int] -or $v -is [long]){$source=$source.Replace("'"+$token+"'",[string]$v).Replace($token,[string]$v)}
   else{$source=$source.Replace($token,([string]$v).Replace("'","''"))}
  }
  $t=$null;$e=$null;$null=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$t,[ref]$e)
  Assert-C1bEntry ($e.Count -eq 0 -and $source -cnotmatch '__[A-Z0-9_]+__') 'Rendered source parser or slots rejected.'
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes($source.Replace("`r`n","`n"))
  $output[$leaf]=$bytes
  $tag=([IO.Path]::GetFileNameWithoutExtension($leaf)-replace '[^A-Za-z0-9]','_').ToUpperInvariant()
  $values['SOURCE_'+$tag+'_HASH']=Get-C1bEntryHash $bytes;$values['SOURCE_'+$tag+'_LENGTH']=$bytes.Length
 }
 return ,$output
}
function Assert-C1bDeviceEntrySourceReview($Review,[string]$CandidateSha,[string]$ManifestSha256) {
 Assert-C1bEntryKeys $Review @('schema','candidate_sha','manifest_sha256','review_status','p0_findings','p1_findings','source_pins','output_pins','semantic_review_basis')
 Assert-C1bEntry ($Review.schema -ceq 'c1b-device-entry-source-review/v1' -and $Review.candidate_sha -ceq $CandidateSha -and $Review.manifest_sha256 -ceq $ManifestSha256 -and $Review.review_status -ceq 'reviewed') 'Current independent source review required.'
 foreach($k in @('p0_findings','p1_findings')){Assert-C1bEntry ($Review[$k] -is [array] -and $Review[$k].Count -eq 0) 'Source review has blocking findings.'}
 Assert-C1bEntry ($Review.semantic_review_basis -is [string] -and -not [string]::IsNullOrWhiteSpace($Review.semantic_review_basis)) 'Independent semantic review basis missing.'
}
function Assert-C1bDeviceEntryManifest($Native,[string]$ManifestPath,[string]$ManifestSha256,[bool]$RequirePublished=$false) {
 $held=Read-C1bEntryHeldFile $Native $ManifestPath $ManifestSha256
 $m=ConvertFrom-C1bEntryJson $held.Bytes
 Assert-C1bEntryKeys $m @('schema','context','outputs','source_pins','device_execution_count')
 Assert-C1bEntryInteger $m.device_execution_count 0 0
 Assert-C1bEntry ($m.schema -ceq 'c1b-device-entry-source-manifest/v1' -and $m.device_execution_count -eq 0) 'Source manifest scope differs.'
 Assert-C1bDeviceEntryGenerationContext $m.context
 Assert-C1bEntryCandidateAuthority $Native $m.context
 foreach($pin in $m.source_pins){$null=Read-C1bEntryHeldFile $Native (Join-Path $m.context.repo_root $pin.path) $pin.sha256 $pin.byte_length $false}
 $map=Get-C1bEntryImplementationPathMap $m.context.repo_root $m.context.implementation_hashes.c1b_library_sha256.Substring(7)
 foreach($key in $map.Keys){$null=Read-C1bEntryHeldFile $Native (Join-Path $m.context.repo_root $map[$key]) $m.context.implementation_hashes[$key].Substring(7) -1 $false}
 $expected=New-C1bDeviceEntrySources $m.context
 Assert-C1bEntryKeys $m.outputs $script:C1bDeviceEntryLeaves
 foreach($leaf in $expected.Keys){
  $pin=$m.outputs[$leaf];Assert-C1bEntryRawPin $pin
  Assert-C1bEntry ($pin.path -ceq (Join-Path $m.context.entry_root $leaf) -and $pin.byte_length -eq $expected[$leaf].Length -and $pin.sha256 -ceq (Get-C1bEntryHash $expected[$leaf])) 'Output must equal current deterministic generation.'
  if($RequirePublished){$null=Read-C1bEntryHeldFile $Native $pin.path $pin.sha256 $pin.byte_length}
 }
 Assert-C1bEntry ($m.source_pins.Count -eq 26) 'Twenty templates, five dependencies and strict source required.'
 $expectedPins=@($m.context.template_pins.Values)+@($m.context.dependency_pins.Values)+@($m.context.strict_pin)
 Assert-C1bEntry (($m.source_pins|ConvertTo-Json -Depth 10 -Compress) -ceq ($expectedPins|ConvertTo-Json -Depth 10 -Compress)) 'Maintenance source pin map differs.'
 Assert-C1bEntryHeld $Native
 $m
}
function Publish-C1bDeviceEntrySources($Native,[string]$ManifestPath,[string]$ManifestSha256,[string]$SourceReviewPath,[string]$SourceReviewSha256) {
 $m=Assert-C1bDeviceEntryManifest $Native $ManifestPath $ManifestSha256
 $r=ConvertFrom-C1bEntryJson (Read-C1bEntryHeldFile $Native $SourceReviewPath $SourceReviewSha256).Bytes
 Assert-C1bDeviceEntrySourceReview $r $m.context.candidate_sha $ManifestSha256
 Assert-C1bEntry (($r.source_pins|ConvertTo-Json -Depth 15 -Compress) -ceq ($m.source_pins|ConvertTo-Json -Depth 15 -Compress) -and ($r.output_pins|ConvertTo-Json -Depth 15 -Compress) -ceq ($m.outputs|ConvertTo-Json -Depth 15 -Compress)) 'Review must cover exact maintenance and emitted source pins.'
 $expected=New-C1bDeviceEntrySources $m.context
 Assert-C1bEntryOrdinaryChain $m.context.entry_root
 # All targets are prechecked before the first write; CreateNew remains the race guard.
 foreach($leaf in $expected.Keys){Assert-C1bEntry (-not [IO.File]::Exists($m.outputs[$leaf].path) -and -not [IO.Directory]::Exists($m.outputs[$leaf].path)) 'Publication target occupied.'}
 $pins=[ordered]@{}
 foreach($leaf in $expected.Keys){$pins[$leaf]=Write-C1bEntryNewReadonly $Native $m.outputs[$leaf].path $expected[$leaf]}
 [ordered]@{schema='c1b-device-entry-source-publication/v1';candidate_sha=$m.context.candidate_sha;manifest_sha256=$ManifestSha256;source_review_sha256=$SourceReviewSha256;outputs=$pins;device_stage_started=$false;device_evidence_verified=$false;device_commands=0;automatic_retry_count=0}
}
function Import-C1bEntryPinnedDependency($Native,$Pin) {
 $held=Read-C1bEntryHeldFile $Native (Join-Path $Native.RepoRoot $Pin.path) $Pin.sha256 $Pin.byte_length $false
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($held.Bytes)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
 Assert-C1bEntry ($errors.Count -eq 0) 'Pinned dependency parser rejected.'
 . ([scriptblock]::Create($text))
 foreach($definition in @($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})){
  Set-Item -LiteralPath ('Function:script:'+$definition.Name) -Value (Get-Item -LiteralPath ('Function:'+$definition.Name)).ScriptBlock
 }
 Assert-C1bEntryHeld $Native
}
function Get-C1bEntrySummaryVerifierContext($Native,$Pin) {
 Assert-C1bEntry ((Get-Variable C1bEntryNativeHash -Scope Script -ErrorAction SilentlyContinue) -and $script:C1bEntryNativeHash -ceq $Pin.sha256) 'Pinned maintenance native owner required.'
 $held=Read-C1bEntryHeldFile $Native (Join-Path $Native.RepoRoot $Pin.path) $Pin.sha256 $Pin.byte_length $false
 [ordered]@{source_pin=(Get-C1bEntryPin $held);native_authority_owner='c1b-device-entry-source';source_bytes=$held.Bytes}
}
function Assert-C1bEntryReviewForManifest($Native,$Manifest,[string]$ManifestSha256,[string]$Path,[string]$Hash) {
 $held=Read-C1bEntryHeldFile $Native $Path $Hash
 $r=ConvertFrom-C1bEntryJson $held.Bytes
 Assert-C1bDeviceEntrySourceReview $r $Manifest.context.candidate_sha $ManifestSha256
 Assert-C1bEntry (($r.source_pins|ConvertTo-Json -Depth 15 -Compress) -ceq ($Manifest.source_pins|ConvertTo-Json -Depth 15 -Compress) -and ($r.output_pins|ConvertTo-Json -Depth 15 -Compress) -ceq ($Manifest.outputs|ConvertTo-Json -Depth 15 -Compress)) 'Review raw pin set differs.'
 Get-C1bEntryPin $held
}
function New-C1bDeviceEntryBinding($Native,[string]$ManifestPath,[string]$ManifestSha256,[string]$SourceReviewPath,[string]$SourceReviewSha256,[string]$HostAcceptanceContractPath,[string]$HostAcceptanceContractSha256,[string]$EvidenceRoot,[int]$ObservedBuildOnlyCallerExit,[int]$ObservedBuildOnlyReaderExit,[string]$SupportInputsPath,[string]$SupportInputsSha256,[int]$ObservedSourcePublicationCaptureExit,[int]$ObservedSourcePublicationOuterCaptureExit) {
 Assert-C1bEntry ($ObservedBuildOnlyCallerExit -eq 0 -and $ObservedBuildOnlyReaderExit -eq 0) 'Both independently observed BuildOnly exits required.'
 $m=Assert-C1bDeviceEntryManifest $Native $ManifestPath $ManifestSha256 $true
 $review=Assert-C1bEntryReviewForManifest $Native $m $ManifestSha256 $SourceReviewPath $SourceReviewSha256
 $support=Assert-C1bDeviceEntrySupport $Native $m $ManifestPath $ManifestSha256 $SourceReviewPath $SourceReviewSha256 $SupportInputsPath $SupportInputsSha256 $ObservedSourcePublicationCaptureExit $ObservedSourcePublicationOuterCaptureExit
 Import-C1bEntryPinnedDependency $Native $m.context.dependency_pins.host_acceptance
 $summaryContext=Get-C1bEntrySummaryVerifierContext $Native $m.context.strict_pin
 $contract=Assert-C1bHostAcceptanceContract -CandidateSha $m.context.candidate_sha -EvidenceRoot $EvidenceRoot -ContractPath $HostAcceptanceContractPath -ContractSha256 $HostAcceptanceContractSha256 -SummaryVerifierContext $summaryContext
 Assert-C1bEntry ($contract.observed_buildonly_caller_exit -eq $ObservedBuildOnlyCallerExit -and $contract.observed_buildonly_reader_exit -eq $ObservedBuildOnlyReaderExit) 'Independent BuildOnly tuple differs from accepted raw evidence.'
 Assert-C1bEntry (($contract.authority|ConvertTo-Json -Depth 25 -Compress) -ceq ($m.context.authority|ConvertTo-Json -Depth 25 -Compress)) 'Manifest authority differs from current host acceptance.'
 $hostContractHeld=Read-C1bEntryHeldFile $Native $HostAcceptanceContractPath $HostAcceptanceContractSha256
 $repo=$m.context.repo_root;$short=$m.context.candidate_sha.Substring(0,7)
 $parent=Join-Path $repo ('.checks/c1b-device-once/'+$short)
 Assert-C1bEntryOrdinaryChain $parent;Add-C1bEntryHeldDirectories $Native $parent
 $root=Join-Path $parent 'r1'
 Assert-C1bEntry (-not [IO.Directory]::Exists($root) -and -not [IO.File]::Exists($root)) 'Device attempt exists; no replay.'
 Assert-C1bEntryHeld $Native
 # The directory may survive a publication failure; it is never removed/reused.
 $null=New-Item -ItemType Directory -Path $root -ErrorAction Stop
 Add-C1bEntryHeldDirectories $Native $root
 $binding=[ordered]@{
  schema='c1b-device-root-preparation-binding/v1';status='prepared_binding_pending_prefix';commit_sha=$m.context.candidate_sha;repo_root=$repo;attempt='r1'
  branch=$contract.authority.branch;git_entry_kind=$contract.authority.git_entry_kind;git_index_sha256=$contract.authority.git_index_sha256;git_index_byte_length=$contract.authority.git_index_byte_length;tracked_path_count=$contract.authority.tracked_path_count
  implementation_catalog_sha256=$m.context.implementation_catalog_sha256;implementation_hashes=$m.context.implementation_hashes
  tools=$m.outputs;host_evidence_root=$EvidenceRoot;source_publication_support_inputs=[ordered]@{path=$SupportInputsPath;sha256=$SupportInputsSha256};root_observed_source_publication_capture_exit=$ObservedSourcePublicationCaptureExit;root_observed_source_publication_outer_capture_exit=$ObservedSourcePublicationOuterCaptureExit;authorities=[ordered]@{host_terminal=(Get-C1bEntryPin $hostContractHeld);device_source_review=$review;manifest=[ordered]@{path=$ManifestPath;sha256=$ManifestSha256}}
  root_observed_buildonly_caller_exit=$ObservedBuildOnlyCallerExit;root_observed_buildonly_reader_exit=$ObservedBuildOnlyReaderExit
  tablet_scene_ready_confirmed_by_user=$false;tablet_scene_reconfirmation_required_before_device_stage=$true;device_stage_started=$false;device_stage_authorized_by_this_binding=$false;device_evidence_verified=$false;wrapper_enforces_binding=$false
  observer_prefix_verification_still_required=$true;fresh_device_scene_confirmation_required=$true;automatic_retry_count=0;old_attempts_preserved=$true;created_utc=[DateTimeOffset]::UtcNow.ToString('O')
 }
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($binding|ConvertTo-Json -Depth 40 -Compress))
 $pin=Write-C1bEntryNewReadonly $Native (Join-Path $root 'binding.json') $bytes
 [ordered]@{schema='c1b-device-root-binding-publication/v1';candidate_sha=$m.context.candidate_sha;binding=$pin;receipt_root=$root;device_stage_started=$false;device_evidence_verified=$false;automatic_retry_count=0}
}
function Assert-C1bEntrySuccessfulCapture($Native,$Pin,[string]$ExpectedSourcePath,[string]$ExpectedSourceHash,[string]$CandidateSha,$Manifest,[string]$ManifestPath) {
 Assert-C1bEntryRawPin $Pin
 Assert-C1bEntry ([IO.Path]::GetFileName($Pin.path) -ceq 'entry-capture.json') 'Capture wrapper exact leaf required.'
 $captureDirectory=[IO.Path]::GetDirectoryName($Pin.path)
 $held=Read-C1bEntryHeldFile $Native $Pin.path $Pin.sha256 $Pin.byte_length
 $record=ConvertFrom-C1bEntryJson $held.Bytes
 Assert-C1bEntryKeys $record @('schema','candidate_sha','stage','source','arguments','capture','raw_pins','capture_parent_pid','capture_source','runtime','argument_list','device_commands','automatic_retry_count')
 Assert-C1bEntryInteger $record.device_commands 0 0;Assert-C1bEntryInteger $record.automatic_retry_count 0 0;Assert-C1bEntryInteger $record.capture_parent_pid 1
 foreach($p in @($record.source,$record.arguments,$record.capture_source,$record.runtime)){Assert-C1bEntryRawPin $p}
 Assert-C1bEntryKeys $record.raw_pins @('execution','reservation','stdout','stderr')
 $captureEntries=@([IO.Directory]::EnumerateFileSystemEntries($captureDirectory))
 $expectedEntries=@('entry-capture.json','execution.json','reservation.json','stdout.bin','stderr.bin')
 Assert-C1bEntry ($captureEntries.Count -eq $expectedEntries.Count) 'Capture directory exact inventory differs.'
 foreach($entry in $captureEntries){Assert-C1bEntry ([IO.Path]::GetFileName($entry) -cin $expectedEntries) 'Unexpected capture directory entry.'}
 foreach($name in $record.raw_pins.Keys){$p=$record.raw_pins[$name];Assert-C1bEntryRawPin $p;Assert-C1bEntry ($p.path -ceq (Join-Path $captureDirectory ($name+$(if($name -cin @('stdout','stderr')){'.bin'}else{'.json'})))) 'Capture raw path escaped exact capture directory graph.'}
 $captureLeaves=@{Binding='capture-r1-host-step.ps1';Terminal='capture-r1-host-step.ps1';Prefix='capture-observer-preflight-r1.ps1';Ready='capture-ready-publication-r1.ps1';SourcePublication='capture-source-publication-r1.ps1';SourcePublicationOuter='capture-source-publication-outer-r1.ps1';Support='capture-support.ps1';ReviewEntry='capture-review.ps1';ReviewAuxiliary='capture-review.ps1';ReviewSupport='capture-support-review.ps1'}
 Assert-C1bEntry ($captureLeaves.ContainsKey($record.stage)) 'Unknown host capture stage.'
 $captureExpected=$Manifest.outputs[$captureLeaves[$record.stage]];$capturePreview=Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) $captureLeaves[$record.stage]
 Assert-C1bEntry ($record.capture_source.sha256 -ceq $captureExpected.sha256 -and $record.capture_source.byte_length -eq $captureExpected.byte_length -and ($record.capture_source.path -ceq $captureExpected.path -or $record.capture_source.path -ceq $capturePreview)) 'Current capture source pin differs.'
 Assert-C1bEntry ($record.runtime.path -ceq $Manifest.context.pwsh_path -and $record.runtime.sha256 -ceq $Manifest.context.runtime_sha256 -and $record.runtime.byte_length -eq 301368) 'Capture runtime actual pin differs.'
 Assert-C1bEntry ($record.schema -ceq 'c1b-device-entry-host-capture/v1' -and $record.candidate_sha -ceq $CandidateSha -and $record.source.path -ceq $ExpectedSourcePath -and $record.source.sha256 -ceq $ExpectedSourceHash -and $record.device_commands -eq 0 -and $record.automatic_retry_count -eq 0) 'Capture source/current identity differs.'
 $c=$record.capture
 Assert-C1bEntryKeys $c @('schema','status','started_at_utc','completed_at_utc','elapsed_milliseconds','start_attempt_count','start_count','automatic_retry_count','child_pid','exit_code','root_exit_confirmed','natural_exit','timed_out','drain_timed_out','termination_requested','capture_limit_bytes_per_stream','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds','drains_completed','errors','publication_errors','environment','cleanup','stdout','stderr')
 foreach($key in @('root_exit_confirmed','natural_exit','drains_completed')){Assert-C1bEntry ($c[$key] -is [bool] -and $c[$key]) 'Actual capture boolean proof invalid.'}
 foreach($key in @('timed_out','drain_timed_out','termination_requested')){Assert-C1bEntry ($c[$key] -is [bool] -and -not $c[$key]) 'Actual capture refusal boolean invalid.'}
 foreach($key in @('child_pid','exit_code','start_attempt_count','start_count','automatic_retry_count')){Assert-C1bEntry ($c[$key] -is [int] -or $c[$key] -is [long]) 'Actual capture integer proof invalid.'}
 foreach($key in @('elapsed_milliseconds','capture_limit_bytes_per_stream','timeout_milliseconds','drain_timeout_milliseconds','cleanup_timeout_milliseconds')){Assert-C1bEntryInteger $c[$key]}
 foreach($key in @('started_at_utc','completed_at_utc')){Assert-C1bEntry ($c[$key] -is [string]) 'Actual capture timestamp string required.'}
 Assert-C1bEntry ($c.schema -ceq 'tl1-c1b-host-process-capture/v1' -and $c.status -ceq 'passed' -and $c.start_attempt_count -eq 1 -and $c.start_count -eq 1 -and $c.child_pid -gt 0 -and $c.exit_code -eq 0 -and $c.automatic_retry_count -eq 0 -and $c.root_exit_confirmed -and $c.natural_exit -and $c.drains_completed -and -not $c.timed_out -and -not $c.drain_timed_out -and -not $c.termination_requested -and $c.errors.Count -eq 0 -and $c.publication_errors.Count -eq 0) 'Actual capture did not pass.'
 Assert-C1bEntry ($c.errors -is [array] -and $c.publication_errors -is [array]) 'Actual capture error arrays required.'
 Assert-C1bEntryKeys $c.cleanup @('scope','job_assigned_before_resume','active_process_count','handles_closed','failure_count','errors','completed')
 Assert-C1bEntry ($c.cleanup.scope -ceq 'contained_job_processes_pipe_workers_owned_handles') 'Capture cleanup scope differs.'
 foreach($key in @('completed','job_assigned_before_resume','handles_closed')){Assert-C1bEntryBoolean $c.cleanup[$key] $true}
 Assert-C1bEntryInteger $c.cleanup.active_process_count 0 0;Assert-C1bEntryInteger $c.cleanup.failure_count 0 0
 Assert-C1bEntry ($c.cleanup.errors -is [array]) 'Actual cleanup error array required.'
 Assert-C1bEntry ($c.cleanup.completed -and $c.cleanup.job_assigned_before_resume -and $c.cleanup.handles_closed -and $c.cleanup.active_process_count -eq 0 -and $c.cleanup.failure_count -eq 0 -and $c.cleanup.errors.Count -eq 0) 'Capture cleanup incomplete.'
 Assert-C1bEntryKeys $c.environment @('mode','keys','sha256')
 Assert-C1bEntry ($c.environment.mode -ceq 'inherit' -and $c.environment.keys -is [array] -and $c.environment.sha256 -cmatch '^[0-9a-f]{64}$') 'Capture environment closed pin invalid.'
 $envNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($key in $c.environment.keys){Assert-C1bEntry ($key -is [string] -and $key.Length -gt 0 -and $key -cnotmatch '[=\x00\r\n]' -and $envNames.Add($key)) 'Environment keys invalid/duplicate.'}
 foreach($name in @('stdout','stderr')){
  $s=$c[$name]
  Assert-C1bEntryKeys $s @('eof','aborted','error','overflowed','observed_byte_length','observed_sha256','total_byte_length','sha256','captured_byte_length','captured_sha256','first_byte_observed_elapsed_milliseconds','eof_observed_elapsed_milliseconds')
  foreach($key in @('eof','aborted','overflowed')){Assert-C1bEntry ($s[$key] -is [bool]) 'Stream EOF/refusal must be actual boolean.'}
  Assert-C1bEntry ($s.eof -and -not $s.aborted -and -not $s.overflowed -and $null -eq $s.error -and ($s.total_byte_length -is [int] -or $s.total_byte_length -is [long]) -and $s.total_byte_length -ge 0 -and $s.total_byte_length -eq $s.captured_byte_length -and $s.sha256 -cmatch '^[0-9a-f]{64}$' -and $s.sha256 -ceq $s.captured_sha256) 'Independent raw stream EOF/hash required.'
  Assert-C1bEntryInteger $s.observed_byte_length 0 8388608;Assert-C1bEntryInteger $s.captured_byte_length 0 8388608
  Assert-C1bEntryInteger $s.eof_observed_elapsed_milliseconds
  if($null -ne $s.first_byte_observed_elapsed_milliseconds){Assert-C1bEntryInteger $s.first_byte_observed_elapsed_milliseconds}else{Assert-C1bEntry ($s.observed_byte_length -eq 0) 'Nonempty stream lacks actual first byte observation.'}
  Assert-C1bEntry ($s.observed_byte_length -eq $s.total_byte_length -and $s.observed_sha256 -ceq $s.sha256) 'Observed/raw stream full hash differs.'
  $p=$record.raw_pins[$name];$raw=Read-C1bEntryHeldFile $Native $p.path $p.sha256 $p.byte_length
  Assert-C1bEntry ($raw.Length -eq $s.total_byte_length -and $raw.Hash -ceq $s.sha256) 'Capture raw stream pin differs.'
 }
 foreach($p in @($record.raw_pins.execution,$record.raw_pins.reservation,$record.source,$record.arguments,$record.capture_source)){$null=Read-C1bEntryHeldFile $Native $p.path $p.sha256 $p.byte_length}
 $null=Read-C1bEntryHeldFile $Native $record.runtime.path $record.runtime.sha256 $record.runtime.byte_length $false
 $reservation=ConvertFrom-C1bEntryJson $Native.Files[$record.raw_pins.reservation.path].Bytes
 Assert-C1bEntryKeys $reservation @('schema','started_at_utc','parent_pid','automatic_retry_count')
 Assert-C1bEntryInteger $reservation.parent_pid 1;Assert-C1bEntryInteger $reservation.automatic_retry_count 0 0
 Assert-C1bEntry ($reservation.schema -ceq 'tl1-c1b-host-process-capture-reservation/v1' -and $reservation.started_at_utc -ceq $c.started_at_utc -and $reservation.parent_pid -eq $record.capture_parent_pid) 'Capture reservation current parent/time binding differs.'
 Assert-C1bEntry ([DateTimeOffset]::Parse($c.completed_at_utc) -ge [DateTimeOffset]::Parse($c.started_at_utc)) 'Capture time order invalid.'
 $named=ConvertFrom-C1bEntryJson $Native.Files[$record.arguments.path].Bytes
 $expectedArguments=[Collections.Generic.List[string]]::new();foreach($value in @('-NoLogo','-NoProfile','-NonInteractive','-File',$ExpectedSourcePath)){$expectedArguments.Add($value)}
 foreach($key in $named.Keys){Assert-C1bEntry ($key -is [string] -and $key -cmatch '^[A-Za-z][A-Za-z0-9]*$' -and ($named[$key] -is [string] -or $named[$key] -is [int] -or $named[$key] -is [long])) 'Actual capture named argument invalid.';$expectedArguments.Add('-'+$key);$expectedArguments.Add([string]$named[$key])}
 Assert-C1bEntry ($record.argument_list -is [array] -and ($record.argument_list|ConvertTo-Json -Compress) -ceq ($expectedArguments.ToArray()|ConvertTo-Json -Compress)) 'Actual capture argv differs from source and raw named inputs.'
 $actualExecution=ConvertFrom-C1bEntryJson $Native.Files[$record.raw_pins.execution.path].Bytes
 Assert-C1bEntry (($actualExecution|ConvertTo-Json -Depth 20 -Compress) -ceq ($c|ConvertTo-Json -Depth 20 -Compress)) 'Capture execution readback differs.'
 $record
}
function Assert-C1bDeviceEntrySupport($Native,$Manifest,[string]$ManifestPath,[string]$ManifestSha256,[string]$SourceReviewPath,[string]$SourceReviewSha256,[string]$SupportInputsPath,[string]$SupportInputsSha256,[int]$ObservedSourcePublicationCaptureExit,[int]$ObservedSourcePublicationOuterCaptureExit) {
 Assert-C1bEntry ($ObservedSourcePublicationCaptureExit -eq 0 -and $ObservedSourcePublicationOuterCaptureExit -eq 0) 'Both independently observed source publication capture exits required.'
 $i=ConvertFrom-C1bEntryJson (Read-C1bEntryHeldFile $Native $SupportInputsPath $SupportInputsSha256).Bytes
 Assert-C1bEntryKeys $i @('schema','candidate_sha','source_publication_capture','source_publication_outer_capture')
 Assert-C1bEntry ($i.schema -ceq 'c1b-device-entry-support-inputs/v1' -and $i.candidate_sha -ceq $Manifest.context.candidate_sha) 'Current support inputs required.'
 $preview=[IO.Path]::GetDirectoryName($ManifestPath)
 $publisher=Join-Path $preview 'publish-reviewed-r1-sources.ps1';$captureSource=Join-Path $preview 'capture-source-publication-r1.ps1'
 $inner=Assert-C1bEntrySuccessfulCapture $Native $i.source_publication_capture $publisher $Manifest.outputs['publish-reviewed-r1-sources.ps1'].sha256 $Manifest.context.candidate_sha $Manifest $ManifestPath
 $outer=Assert-C1bEntrySuccessfulCapture $Native $i.source_publication_outer_capture $captureSource $Manifest.outputs['capture-source-publication-r1.ps1'].sha256 $Manifest.context.candidate_sha $Manifest $ManifestPath
 Assert-C1bEntry ($inner.stage -ceq 'SourcePublication' -and $outer.stage -ceq 'SourcePublicationOuter') 'Publication support stages differ.'
 $published=ConvertFrom-C1bEntryJson $Native.Files[$inner.raw_pins.stdout.path].Bytes
 Assert-C1bEntryKeys $published @('schema','candidate_sha','manifest_sha256','source_review_sha256','outputs','device_stage_started','device_evidence_verified','device_commands','automatic_retry_count')
 Assert-C1bEntry ($published.schema -ceq 'c1b-device-entry-source-publication/v1' -and $published.candidate_sha -ceq $Manifest.context.candidate_sha -and $published.manifest_sha256 -ceq $ManifestSha256 -and $published.source_review_sha256 -ceq $SourceReviewSha256 -and ($published.outputs|ConvertTo-Json -Depth 20 -Compress) -ceq ($Manifest.outputs|ConvertTo-Json -Depth 20 -Compress)) 'Actual publication stdout differs from admitted current outputs.'
 foreach($k in @('device_stage_started','device_evidence_verified')){Assert-C1bEntry ($published[$k] -is [bool] -and -not $published[$k]) 'Publication crossed device boundary.'}
 Assert-C1bEntryInteger $published.device_commands 0 0;Assert-C1bEntryInteger $published.automatic_retry_count 0 0
 Assert-C1bEntry ($published.device_commands -eq 0 -and $published.automatic_retry_count -eq 0) 'Publication device/retry boundary differs.'
 $printedInner=ConvertFrom-C1bEntryJson $Native.Files[$outer.raw_pins.stdout.path].Bytes
 Assert-C1bEntry (($printedInner|ConvertTo-Json -Depth 40 -Compress) -ceq ($inner|ConvertTo-Json -Depth 40 -Compress)) 'Outer actual stdout differs from inner raw capture readback.'
 $args=ConvertFrom-C1bEntryJson $Native.Files[$inner.arguments.path].Bytes
 Assert-C1bEntryKeys $args @('ExpectedSelfSha256','ManifestPath','ManifestSha256','SourceReviewPath','SourceReviewSha256')
 Assert-C1bEntry ($args.ExpectedSelfSha256 -ceq $Manifest.outputs['publish-reviewed-r1-sources.ps1'].sha256 -and $args.ManifestPath -ceq $ManifestPath -and $args.ManifestSha256 -ceq $ManifestSha256 -and $args.SourceReviewPath -ceq $SourceReviewPath -and $args.SourceReviewSha256 -ceq $SourceReviewSha256) 'Actual publisher arguments differ from current admitted pins.'
 $outerArgs=ConvertFrom-C1bEntryJson $Native.Files[$outer.arguments.path].Bytes
 Assert-C1bEntryKeys $outerArgs @('ExpectedSelfSha256','ManifestPath','ManifestSha256','SourcePath','ExpectedSourceSha256','ArgumentsJsonPath','ArgumentsSha256','OutputDirectory')
 Assert-C1bEntry ($outerArgs.ExpectedSelfSha256 -ceq $Manifest.outputs['capture-source-publication-r1.ps1'].sha256 -and $outerArgs.ManifestPath -ceq $ManifestPath -and $outerArgs.ManifestSha256 -ceq $ManifestSha256 -and $outerArgs.SourcePath -ceq $publisher -and $outerArgs.ExpectedSourceSha256 -ceq $Manifest.outputs['publish-reviewed-r1-sources.ps1'].sha256 -and $outerArgs.ArgumentsJsonPath -ceq $inner.arguments.path -and $outerArgs.ArgumentsSha256 -ceq $inner.arguments.sha256 -and $outerArgs.OutputDirectory -ceq [IO.Path]::GetDirectoryName($i.source_publication_capture.path)) 'Outer actual capture arguments differ from inner raw capture.'
 [ordered]@{schema='c1b-device-entry-support-readback/v1';candidate_sha=$Manifest.context.candidate_sha;status='verified';source_publication_capture=$i.source_publication_capture;source_publication_outer_capture=$i.source_publication_outer_capture;root_observed_source_publication_capture_exit=$ObservedSourcePublicationCaptureExit;root_observed_source_publication_outer_capture_exit=$ObservedSourcePublicationOuterCaptureExit;device_stage_started=$false;device_evidence_verified=$false;device_invocations=0;producer_invocations=0}
}
function New-C1bDeviceEntryReady($Native,[string]$ManifestPath,[string]$ManifestSha256,[string]$SourceReviewPath,[string]$SourceReviewSha256,[string]$ReadyInputsPath,[string]$ReadyInputsSha256,[int]$ObservedBindingCaptureExit,[int]$ObservedPrefixCaptureExit) {
 Assert-C1bEntry ($ObservedBindingCaptureExit -eq 0 -and $ObservedPrefixCaptureExit -eq 0) 'Both independently observed host capture exits required.'
 $m=Assert-C1bDeviceEntryManifest $Native $ManifestPath $ManifestSha256 $true
 $review=Assert-C1bEntryReviewForManifest $Native $m $ManifestSha256 $SourceReviewPath $SourceReviewSha256
 $input=ConvertFrom-C1bEntryJson (Read-C1bEntryHeldFile $Native $ReadyInputsPath $ReadyInputsSha256).Bytes
 Assert-C1bEntryKeys $input @('schema','candidate_sha','binding','binding_capture','prefix_capture','prefix_result')
 Assert-C1bEntry ($input.schema -ceq 'c1b-device-entry-ready-inputs/v1' -and $input.candidate_sha -ceq $m.context.candidate_sha) 'Ready input identity differs.'
 $bindingFile=Read-C1bEntryHeldFile $Native $input.binding.path $input.binding.sha256 $input.binding.byte_length
 $b=ConvertFrom-C1bEntryJson $bindingFile.Bytes
 $expectedRoot=Join-Path $m.context.repo_root ('.checks/c1b-device-once/'+$m.context.candidate_sha.Substring(0,7)+'/r1')
 Assert-C1bEntry ($bindingFile.Path -ceq (Join-Path $expectedRoot 'binding.json') -and $b.schema -ceq 'c1b-device-root-preparation-binding/v1' -and $b.commit_sha -ceq $m.context.candidate_sha -and $b.status -ceq 'prepared_binding_pending_prefix' -and $b.attempt -ceq 'r1') 'Preparation binding differs.'
 foreach($key in @('tablet_scene_ready_confirmed_by_user','device_stage_started','device_stage_authorized_by_this_binding','device_evidence_verified','wrapper_enforces_binding')){Assert-C1bEntry ($b[$key] -is [bool] -and -not $b[$key]) 'Binding scope boundary differs.'}
 Assert-C1bEntry ($b.tablet_scene_reconfirmation_required_before_device_stage -is [bool] -and $b.tablet_scene_reconfirmation_required_before_device_stage) 'Scene reconfirmation required.'
 $null=Assert-C1bDeviceEntrySupport $Native $m $ManifestPath $ManifestSha256 $SourceReviewPath $SourceReviewSha256 $b.source_publication_support_inputs.path $b.source_publication_support_inputs.sha256 $b.root_observed_source_publication_capture_exit $b.root_observed_source_publication_outer_capture_exit
 Import-C1bEntryPinnedDependency $Native $m.context.dependency_pins.host_acceptance
 $hostPin=$b.authorities.host_terminal
 $null=Read-C1bEntryHeldFile $Native $hostPin.path $hostPin.sha256 $hostPin.byte_length
 $summaryContext=Get-C1bEntrySummaryVerifierContext $Native $m.context.strict_pin
 $hostAcceptanceVerified=Assert-C1bHostAcceptanceContract -CandidateSha $m.context.candidate_sha -EvidenceRoot $b.host_evidence_root -ContractPath $hostPin.path -ContractSha256 $hostPin.sha256 -SummaryVerifierContext $summaryContext
 Assert-C1bEntry (($hostAcceptanceVerified.authority|ConvertTo-Json -Depth 25 -Compress) -ceq ($m.context.authority|ConvertTo-Json -Depth 25 -Compress)) 'Ready current host authority differs.'
 $bc=Assert-C1bEntrySuccessfulCapture $Native $input.binding_capture $m.outputs['prepare-device-binding-r1.ps1'].path $m.outputs['prepare-device-binding-r1.ps1'].sha256 $m.context.candidate_sha $m $ManifestPath
 $pc=Assert-C1bEntrySuccessfulCapture $Native $input.prefix_capture $m.outputs['preflight-device-observer-r1.ps1'].path $m.outputs['preflight-device-observer-r1.ps1'].sha256 $m.context.candidate_sha $m $ManifestPath
 Assert-C1bEntry ($bc.stage -ceq 'Binding' -and $pc.stage -ceq 'Prefix') 'Ready stages differ.'
 $bindingPublication=ConvertFrom-C1bEntryJson $Native.Files[$bc.raw_pins.stdout.path].Bytes
 Assert-C1bEntry ($bindingPublication.schema -ceq 'c1b-device-root-binding-publication/v1' -and $bindingPublication.candidate_sha -ceq $m.context.candidate_sha -and ($bindingPublication.binding|ConvertTo-Json -Compress) -ceq ($input.binding|ConvertTo-Json -Compress)) 'Binding publisher stdout differs from actual raw binding.'
 $prefixHeld=Read-C1bEntryHeldFile $Native $input.prefix_result.path $input.prefix_result.sha256 $input.prefix_result.byte_length
 Assert-C1bEntry ($prefixHeld.Path -ceq (Join-Path $m.context.repo_root ('.checks/c1b-host-readiness/'+$m.context.candidate_sha.Substring(0,7)+'/device-r1-preflight.json'))) 'Prefix result exact path differs.'
 $prefix=ConvertFrom-C1bEntryJson $prefixHeld.Bytes
 Assert-C1bEntryKeys $prefix @('schema','status','expected_commit_sha','observer_sha256','binding_sha256','assertion_count','source_prefix_statement_count','source_prefix_completed','native_definitions_compiled','native_probe_scope','active_process_exit_rejected','guarded_file_count','guarded_directory_count','error','cleanup_error_count','cleanup_errors','observer_top_level_invocations','wrapper_launches','child_process_launches','uac_requests','adb_or_device_commands','formal_stage_invocations','formal_reservation_created','device_evidence_verified','external_preflight_exit_zero_required','scope','recorded_at_utc')
 $prefixOut=ConvertFrom-C1bEntryJson $Native.Files[$pc.raw_pins.stdout.path].Bytes
 $expectedPrefixOut=[byte[]]::new($prefixHeld.Bytes.Length+2);[Array]::Copy($prefixHeld.Bytes,$expectedPrefixOut,$prefixHeld.Bytes.Length);$expectedPrefixOut[-2]=13;$expectedPrefixOut[-1]=10
 Assert-C1bEntry ((Get-C1bEntryHash $expectedPrefixOut) -ceq $Native.Files[$pc.raw_pins.stdout.path].Hash) 'Prefix stdout must be exact result raw bytes plus CRLF.'
 Assert-C1bEntry (($prefixOut|ConvertTo-Json -Depth 20 -Compress) -ceq ($prefix|ConvertTo-Json -Depth 20 -Compress)) 'Prefix stdout/result differs.'
 foreach($key in @('source_prefix_completed','native_definitions_compiled','active_process_exit_rejected')){Assert-C1bEntry ($prefix[$key] -is [bool] -and $prefix[$key]) 'Prefix native proof must be actual boolean.'}
 foreach($key in @('formal_reservation_created','device_evidence_verified')){Assert-C1bEntryBoolean $prefix[$key] $false}
 Assert-C1bEntryBoolean $prefix.external_preflight_exit_zero_required $true
 Assert-C1bEntryInteger $prefix.cleanup_error_count 0 0;Assert-C1bEntryInteger $prefix.source_prefix_statement_count 8 8
 Assert-C1bEntryInteger $prefix.assertion_count 1;Assert-C1bEntryInteger $prefix.guarded_file_count 3 3;Assert-C1bEntryInteger $prefix.guarded_directory_count 1
 Assert-C1bEntry ($prefix.cleanup_errors -is [array] -and $prefix.cleanup_errors.Count -eq 0 -and $prefix.recorded_at_utc -is [string]) 'Actual prefix cleanup/timestamp fields required.'
 Assert-C1bEntry ($prefix.schema -ceq 'c1b-observer-pre-device-preflight/v1' -and $prefix.status -ceq 'prepared_for_device_stage' -and $prefix.expected_commit_sha -ceq $m.context.candidate_sha -and $prefix.observer_sha256 -ceq $m.outputs['observe-next-device-launch-r1.ps1'].sha256 -and $prefix.binding_sha256 -ceq $bindingFile.Hash -and $prefix.source_prefix_completed -and $prefix.source_prefix_statement_count -eq 8 -and $prefix.native_definitions_compiled -and $prefix.active_process_exit_rejected -and $null -eq $prefix.error -and $prefix.cleanup_error_count -eq 0 -and $prefix.cleanup_errors.Count -eq 0 -and -not $prefix.formal_reservation_created -and -not $prefix.device_evidence_verified) 'Actual observer prefix did not pass.'
 foreach($key in @('observer_top_level_invocations','wrapper_launches','child_process_launches','uac_requests','adb_or_device_commands','formal_stage_invocations')){Assert-C1bEntryInteger $prefix[$key] 0 0}
 Add-C1bEntryHeldDirectories $Native $expectedRoot
 $leaves=@([IO.Directory]::EnumerateFileSystemEntries($expectedRoot))
 Assert-C1bEntry ($leaves.Count -eq 1 -and $leaves[0] -ceq $bindingFile.Path) 'Attempt already consumed.'
 Assert-C1bEntry ([DateTimeOffset]::Parse($bc.capture.completed_at_utc) -le [DateTimeOffset]::Parse($pc.capture.started_at_utc)) 'Prefix must follow binding publication.'
 Assert-C1bEntry ([DateTimeOffset]::Parse($prefix.recorded_at_utc) -ge [DateTimeOffset]::Parse($pc.capture.started_at_utc) -and [DateTimeOffset]::Parse($prefix.recorded_at_utc) -le [DateTimeOffset]::Parse($pc.capture.completed_at_utc)) 'Prefix result is outside actual capture envelope.'
 $ready=[ordered]@{schema='c1b-pre-device-ready-freeze/v1';status='host_ready_waiting_for_device_assistance';candidate_sha=$m.context.candidate_sha;attempt='r1';binding=(Get-C1bEntryPin $bindingFile);tools=[ordered]@{external_observer=$m.outputs['observe-next-device-launch-r1.ps1'];device_capture=$m.outputs['capture-device-observer-r1.ps1'];terminal_reader=$m.outputs['verify-next-device-terminal-r1.ps1']};source_review=$review;prefix_result=$input.prefix_result;binding_capture=$input.binding_capture;prefix_capture=$input.prefix_capture;root_observed_binding_capture_exit=$ObservedBindingCaptureExit;root_observed_prefix_capture_exit=$ObservedPrefixCaptureExit;current_scene_verified=$false;device_stage_started=$false;device_evidence_verified=$false;fresh_device_scene_confirmation_required=$true;automatic_retry_authorized=$false;created_utc=[DateTimeOffset]::UtcNow.ToString('O')}
 $root=Join-Path $m.context.repo_root ('.checks/c1b-host-readiness/'+$m.context.candidate_sha.Substring(0,7));Assert-C1bEntryOrdinaryChain $root
 Write-C1bEntryNewReadonly $Native (Join-Path $root 'host-ready-r1.json') ([Text.UTF8Encoding]::new($false).GetBytes(($ready|ConvertTo-Json -Depth 40 -Compress)))
}
function Invoke-C1bDeviceEntryHostCapture($Native,[string]$Stage,[string]$SourcePath,[string]$SourceSha256,[string]$ArgumentsJsonPath,[string]$ArgumentsSha256,[string]$OutputDirectory,[string]$RuntimePath,[string]$CandidateSha,$CaptureLibraryPin,[string]$ManifestPath,[string]$ManifestSha256,[string]$CaptureSourcePath,[string]$CaptureSourceSha256) {
 $allowed=@{Binding='prepare-device-binding-r1.ps1';Prefix='preflight-device-observer-r1.ps1';Terminal='verify-next-device-terminal-r1.ps1';Ready='publish-device-ready-r1.ps1';SourcePublication='publish-reviewed-r1-sources.ps1';SourcePublicationOuter='capture-source-publication-r1.ps1';Support='review-support.ps1';ReviewEntry='review-entry.ps1';ReviewAuxiliary='review-auxiliary.ps1';ReviewSupport='review-support-source.ps1'}
 Assert-C1bEntry ($allowed.ContainsKey($Stage) -and [IO.Path]::GetFileName($SourcePath) -ceq $allowed[$Stage]) 'Host capture stage/source differs.'
 $manifest=Assert-C1bDeviceEntryManifest $Native $ManifestPath $ManifestSha256
 $sourcePin=$manifest.outputs[$allowed[$Stage]]
 $previewPath=Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) $allowed[$Stage]
 Assert-C1bEntry ($manifest.context.candidate_sha -ceq $CandidateSha -and $sourcePin.sha256 -ceq $SourceSha256 -and ($SourcePath -ceq $sourcePin.path -or $SourcePath -ceq $previewPath)) 'Capture must use exact current rendered source at published or review path.'
 Assert-C1bEntry (($CaptureLibraryPin|ConvertTo-Json -Compress) -ceq ($manifest.context.dependency_pins.host_capture|ConvertTo-Json -Compress)) 'Capture library differs from admitted maintenance source.'
 Assert-C1bEntry ([Environment]::ProcessPath -ceq $RuntimePath -and $PSVersionTable.PSVersion.ToString() -ceq '7.6.5') 'Pinned runtime required.'
 $source=Read-C1bEntryHeldFile $Native $SourcePath $SourceSha256
 $captureSourceHeld=Read-C1bEntryHeldFile $Native $CaptureSourcePath $CaptureSourceSha256
 $argsFile=Read-C1bEntryHeldFile $Native $ArgumentsJsonPath $ArgumentsSha256
 $runtimeHeld=Read-C1bEntryHeldFile $Native $RuntimePath '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139' 301368 $false
 $named=ConvertFrom-C1bEntryJson $argsFile.Bytes
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput([Text.UTF8Encoding]::new($false,$true).GetString($source.Bytes),[ref]$tokens,[ref]$errors)
 Assert-C1bEntry ($errors.Count -eq 0 -and $null -ne $ast.ParamBlock) 'Parameterized admitted host source required.'
 $parameters=@($ast.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
 foreach($key in $named.Keys){Assert-C1bEntry ($key -is [string] -and $key -cin $parameters -and ($named[$key] -is [string] -or $named[$key] -is [int] -or $named[$key] -is [long])) 'Named host argument rejected.'}
 Import-C1bEntryPinnedDependency $Native $CaptureLibraryPin
 Add-C1bEntryHeldDirectories $Native ([IO.Path]::GetDirectoryName($OutputDirectory));Assert-C1bEntryHeld $Native
 $argv=[Collections.Generic.List[string]]::new();foreach($v in @('-NoLogo','-NoProfile','-NonInteractive','-File',$SourcePath)){$argv.Add($v)}
 foreach($k in $named.Keys){$argv.Add('-'+$k);$argv.Add([string]$named[$k])}
 $capture=Invoke-TL1C1bHostProcessCapture -ExecutablePath $RuntimePath -ArgumentList $argv.ToArray() -WorkingDirectory $Native.RepoRoot -EvidenceDirectory $OutputDirectory -CaptureLimitBytes 8388608
 $pins=[ordered]@{}
 foreach($name in @('execution','reservation','stdout','stderr')){
  $path=Join-Path $OutputDirectory ($name+$(if($name -in @('stdout','stderr')){'.bin'}else{'.json'}))
  Assert-C1bEntryOrdinaryChain $path;[IO.File]::SetAttributes($path,[IO.File]::GetAttributes($path) -bor [IO.FileAttributes]::ReadOnly)
  $bytes=[IO.File]::ReadAllBytes($path);$pins[$name]=Get-C1bEntryPin (Read-C1bEntryHeldFile $Native $path (Get-C1bEntryHash $bytes) $bytes.Length)
 }
 $record=[ordered]@{schema='c1b-device-entry-host-capture/v1';candidate_sha=$CandidateSha;stage=$Stage;source=(Get-C1bEntryPin $source);arguments=(Get-C1bEntryPin $argsFile);capture=$capture;raw_pins=$pins;capture_parent_pid=$PID;capture_source=(Get-C1bEntryPin $captureSourceHeld);runtime=(Get-C1bEntryPin $runtimeHeld);argument_list=$argv.ToArray();device_commands=0;automatic_retry_count=0}
 $null=Write-C1bEntryNewReadonly $Native (Join-Path $OutputDirectory 'entry-capture.json') ([Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 30 -Compress)))
 Assert-C1bEntryHeld $Native
 return $record
}
