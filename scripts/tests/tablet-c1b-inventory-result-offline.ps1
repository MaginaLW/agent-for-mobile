#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot '..\lib\tablet-c1b-inventory-result.ps1')
$script:Passed = 0
$script:Failed = 0
$schemaPath = Join-Path $PSScriptRoot '..\..\docs\contracts\tablet-c1b-inventory-result-v3.schema.json'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function New-TestEnvelope {
    $observed = @(); $diagnostics = @()
    foreach ($token in @('c1','c2')) {
        $observed += [ordered]@{ capture_id="capture-$token"; capture=[ordered]@{token=$token};
            a11y_windows=@([ordered]@{type='unknown'}); windows_truncated=$false }
        $stops = [ordered]@{}
        foreach ($key in $script:C1bInventoryStopKeys) { $stops[$key] = 0 }
        $diagnostics += [ordered]@{ capture_id="capture-$token"; capture_token=$token;
            enumeration_status='complete'; count_status='exact'; maximum_windows=16;
            input_count=1; unattempted_count=0; attempted_count=1; saved_count=1; dropped_count=0;
            first_stop_counts=$stops; rejected_type_code_counts=@() }
    }
    # Intentionally synthetic: this suite validates the envelope, never runtime provenance.
    $observation = [ordered]@{ schema='tablet-layout-observation/c1b-v2'; frames=$observed }
    return [ordered]@{ schema='tablet-c1b-inventory-result/v3';
        observation_json=($observation | ConvertTo-Json -Depth 30); inventory_frames=$diagnostics }
}
function Set-TestObservation($Envelope, [scriptblock]$Change) {
    $observation = $Envelope.observation_json | ConvertFrom-Json -Depth 100 -DateKind String
    & $Change $observation
    $Envelope.observation_json = $observation | ConvertTo-Json -Depth 100
}
function Convert-TestEnvelope($Envelope) {
    return [Text.UTF8Encoding]::new($false,$true).GetBytes(($Envelope | ConvertTo-Json -Depth 100 -Compress))
}
function Assert-ParseFailure([byte[]]$Bytes, [string]$Reason) {
    $result = ConvertFrom-C1bInventoryResult -Bytes $Bytes
    Assert-True (-not $result.Valid -and $result.ReasonCode -ceq $Reason) "parse expected $Reason; got $($result.ReasonCode)"
    foreach ($key in @('ObservationRaw','ObservationBytes','Observation','InventoryFrames')) {
        Assert-True ($null -eq $result.$key) "failed parse leaked $key"
    }
}
function Assert-Counts($Envelope, [AllowNull()][string]$Reason) {
    $parsed = ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $Envelope)
    Assert-True $parsed.Valid "parse failed: $($parsed.ReasonCode)"
    $counts = Test-C1bInventoryCounts -Result $parsed
    if ($Reason) { Assert-True (-not $counts.Valid -and $counts.ReasonCode -ceq $Reason) "counts expected $Reason; got $($counts.ReasonCode)" }
    else { Assert-True $counts.Valid "counts failed: $($counts.ReasonCode)" }
}

Test-Case 'exact and unknown type accepted without granting topology' { Assert-Counts (New-TestEnvelope) $null }
Test-Case 'original observation whitespace unicode and bytes retained' {
    $e = New-TestEnvelope
    $e.observation_json = "`r`n" + $e.observation_json.Replace('unknown','未知') + "`r`n"
    $r = ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e)
    Assert-True $r.Valid 'parse'
    Assert-True ($r.ObservationRaw -ceq $e.observation_json) 'raw changed'
    Assert-True ([Convert]::ToBase64String($r.ObservationBytes) -ceq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($e.observation_json))) 'bytes changed'
}
Test-Case 'complete empty distinct from failed enumeration' {
    $e = New-TestEnvelope
    Set-TestObservation $e { param($o) $o.frames[0].a11y_windows=@() }
    $f=$e.inventory_frames[0]; $f.input_count=0; $f.attempted_count=0; $f.saved_count=0
    Assert-Counts $e $null
    $f.enumeration_status='failed'; $f.count_status='unavailable'; $f.input_count=$null; $f.unattempted_count=$null
    Set-TestObservation $e { param($o) $o.frames[0].windows_truncated=$true }
    Assert-Counts $e $null
}
Test-Case 'budget plus dropped counts conserve 17 inputs 4 saved' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]
    $f.input_count=17; $f.attempted_count=16; $f.saved_count=4; $f.dropped_count=12; $f.unattempted_count=1
    foreach($key in $script:C1bInventoryStopKeys){$f.first_stop_counts[$key]=1}
    $f.first_stop_counts.window_type_invalid=0; $f.first_stop_counts.window_id_invalid=2
    Set-TestObservation $e {param($o) $o.frames[0].a11y_windows=@(@{},@{},@{},@{}); $o.frames[0].windows_truncated=$true }
    Assert-Counts $e $null
}
Test-Case 'maximum input uses int64 arithmetic' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]
    $f.input_count=2147483647; $f.attempted_count=16; $f.saved_count=1; $f.dropped_count=15; $f.unattempted_count=2147483631
    $f.first_stop_counts.window_id_invalid=15
    Set-TestObservation $e {param($o) $o.frames[0].windows_truncated=$true}
    Assert-Counts $e $null
}
foreach($field in @('input_count','unattempted_count','attempted_count','saved_count','dropped_count')) {
    Test-Case "count mismatch $field" {
        $e=New-TestEnvelope; $e.inventory_frames[0][$field]++
        Assert-Counts $e 'count_mismatch'
    }
}
Test-Case 'first stop sum mismatch' {
    $e=New-TestEnvelope; $e.inventory_frames[0].first_stop_counts.window_id_invalid=1
    Assert-Counts $e 'count_mismatch'
}
Test-Case 'truncation mismatch' {
    $e=New-TestEnvelope; Set-TestObservation $e {param($o) $o.frames[0].windows_truncated=$true}
    Assert-Counts $e 'count_mismatch'
}
Test-Case 'unavailable with zero instead of null rejected' {
    $e=New-TestEnvelope; $e.inventory_frames[0].enumeration_status='failed'; $e.inventory_frames[0].count_status='unavailable'
    Assert-Counts $e 'shape_invalid'
}
Test-Case 'exact with null rejected' { $e=New-TestEnvelope; $e.inventory_frames[0].input_count=$null; Assert-Counts $e 'shape_invalid' }
Test-Case 'illegal status combination rejected' { $e=New-TestEnvelope; $e.inventory_frames[0].count_status='unavailable'; Assert-Counts $e 'shape_invalid' }
Test-Case 'overflow never succeeds' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]; $f.count_status='overflow'; $f.input_count=$null; $f.unattempted_count=$null
    Assert-Counts $e 'count_overflow'
    $f.dropped_count=1; Assert-Counts $e 'count_mismatch'
}
Test-Case 'swapped diagnostics rejected' { $e=New-TestEnvelope; $e.inventory_frames=@($e.inventory_frames[1],$e.inventory_frames[0]); Assert-Counts $e 'capture_binding_mismatch' }
Test-Case 'duplicate token rejected' { $e=New-TestEnvelope; $e.inventory_frames[1].capture_token='c1'; Assert-Counts $e 'capture_binding_mismatch' }
Test-Case 'wrong capture id rejected' { $e=New-TestEnvelope; $e.inventory_frames[0].capture_id='old-capture'; Assert-Counts $e 'capture_binding_mismatch' }
Test-Case 'inner token mismatch rejected' { $e=New-TestEnvelope; Set-TestObservation $e {param($o) $o.frames[0].capture.token='c2'}; Assert-Counts $e 'capture_binding_mismatch' }
Test-Case 'missing inner frames rejected by counts' { $e=New-TestEnvelope; $e.observation_json='{}'; Assert-Counts $e 'observation_invalid' }
Test-Case 'bad inner schema left to original binding consumer' {
    $e=New-TestEnvelope; Set-TestObservation $e {param($o) $o.schema='wrong'}
    $r=ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e); Assert-True $r.Valid 'must preserve original schema binding classification'
}
foreach($mutation in @('extra','missing','case','bucket-extra','bucket-missing','null-frame')) {
    Test-Case "closed shape $mutation" {
        $e=New-TestEnvelope
        switch($mutation){
            extra {$e['extra']='sensitive-canary'}
            missing {$e.Remove('observation_json')}
            case {$e['Schema']=$e.schema; $e.Remove('schema')}
            bucket-extra {$e.inventory_frames[0].first_stop_counts['extra']=0}
            bucket-missing {$e.inventory_frames[0].first_stop_counts.Remove('window_id_invalid')}
            null-frame {$e.inventory_frames[0]=$null}
        }
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($value in @(-1,17,1.5,'1',$true,$null)) {
    Test-Case "invalid budget value [$value]" {
        $e=New-TestEnvelope; $e.inventory_frames[0].maximum_windows=$value
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
Test-Case 'bucket bounded by actual budget' { $e=New-TestEnvelope; $e.inventory_frames[0].maximum_windows=1; $e.inventory_frames[0].first_stop_counts.window_id_invalid=2; Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid' }
Test-Case 'wrong version rejected' { $e=New-TestEnvelope; $e.schema='tablet-c1b-inventory-result/v4'; Assert-ParseFailure (Convert-TestEnvelope $e) 'version_mismatch' }
Test-Case 'historical inventory v1 is explicitly rejected' {
    $e=New-TestEnvelope; $e.schema='tablet-c1b-inventory-result/v1'
    foreach($frame in $e.inventory_frames){$frame.Remove('rejected_type_code_counts')}
    Assert-ParseFailure (Convert-TestEnvelope $e) 'version_mismatch'
}
Test-Case 'bare observation rejected' { Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes((New-TestEnvelope).observation_json)) 'version_mismatch' }
Test-Case 'outer duplicate key rejected' {
    $raw=[Text.Encoding]::UTF8.GetString((Convert-TestEnvelope (New-TestEnvelope)))
    $raw=$raw.Replace('{"schema":','{"schema":"other","schema":')
    Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes($raw)) 'duplicate_key'
}
Test-Case 'inner duplicate key rejected' { $e=New-TestEnvelope; $e.observation_json='{"frames":[],"frames":[]}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'duplicate_key' }
Test-Case 'inner case collision rejected' { $e=New-TestEnvelope; $e.observation_json='{"frames":[],"Frames":[]}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'duplicate_key' }
foreach($rawValue in @('1e0','1.0','9223372036854775808')) {
    Test-Case "non integer token $rawValue" {
        $raw=[Text.Encoding]::UTF8.GetString((Convert-TestEnvelope (New-TestEnvelope))).Replace('"input_count":1',('"input_count":'+$rawValue))
        Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes($raw)) 'shape_invalid'
    }
}
Test-Case 'inner fractional number rejected' { $e=New-TestEnvelope; $e.observation_json='{"number":1.5}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid' }
Test-Case 'outer malformed unicode escape rejected' {
    $raw=[Text.Encoding]::UTF8.GetString((Convert-TestEnvelope (New-TestEnvelope))).Replace('"capture_id":"capture-c1"','"capture_id":"\uD800"')
    Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes($raw)) 'encoding_invalid'
}
Test-Case 'inner malformed unicode escape rejected' { $e=New-TestEnvelope; $e.observation_json='{"value":"\uD800"}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'inner malformed unicode property rejected' { $e=New-TestEnvelope; $e.observation_json='{"\uDC00":1}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'valid surrogate pair retained' { $e=New-TestEnvelope; $e.observation_json='{"value":"\uD83D\uDE00"}'; $r=ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e); Assert-True $r.Valid 'valid supplementary scalar rejected' }
Test-Case 'escaped backslash before unicode is literal text' { $e=New-TestEnvelope; $e.observation_json='{"value":"\\uD800"}'; $r=ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e); Assert-True $r.Valid 'literal escape rejected' }
Test-Case 'high surrogate followed by ordinary escaped code rejected' { $e=New-TestEnvelope; $e.observation_json='{"value":"\uD800\u0041"}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'escaped duplicate property name rejected' { $e=New-TestEnvelope; $e.observation_json='{"name":1,"\u006Eame":2}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'duplicate_key' }
Test-Case 'malformed JSON rejected' { Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes('{')) 'encoding_invalid' }
Test-Case 'control object is never a diagnostic result' { Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes('{"schema":"tablet-c1b-control/v1"}')) 'version_mismatch' }
Test-Case 'invalid UTF8 rejected' { Assert-ParseFailure ([byte[]]@(0xC3,0x28)) 'encoding_invalid' }
Test-Case 'outer BOM rejected' { Assert-ParseFailure ([byte[]](@(0xEF,0xBB,0xBF)+(Convert-TestEnvelope (New-TestEnvelope)))) 'encoding_invalid' }
Test-Case 'inner BOM rejected' { $e=New-TestEnvelope; $e.observation_json=([char]0xFEFF)+$e.observation_json; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'trailing JSON rejected' { $b=Convert-TestEnvelope (New-TestEnvelope); Assert-ParseFailure ([byte[]]($b+[Text.Encoding]::UTF8.GetBytes('{}'))) 'encoding_invalid' }
Test-Case 'inner trailing JSON rejected' { $e=New-TestEnvelope; $e.observation_json+='{}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'depth limit rejected' { $e=New-TestEnvelope; $e.observation_json='{"v":'+('['*101)+'0'+(']'*101)+'}'; Assert-ParseFailure (Convert-TestEnvelope $e) 'encoding_invalid' }
Test-Case 'empty output rejected' { Assert-ParseFailure ([byte[]]@()) 'output_size_exceeded' }
Test-Case 'oversize output rejected before decode' { Assert-ParseFailure ([byte[]]::new(1048577)) 'output_size_exceeded' }
Test-Case 'schema agrees for valid complete frame' {
    $json=(New-TestEnvelope)|ConvertTo-Json -Depth 100
    Assert-True (Test-Json -Json $json -SchemaFile $schemaPath) 'schema rejected exact'
}
Test-Case 'schema rejects unknown and invalid state combination' {
    $e=New-TestEnvelope; $e['unknown']=0
    Assert-True (-not (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'unknown accepted'
    $e=New-TestEnvelope; $e.inventory_frames[0].enumeration_status='failed'
    Assert-True (-not (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'combination accepted'
}
Test-Case 'schema accepts unavailable shape while counts remain independent' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]
    $f.enumeration_status='failed'; $f.count_status='unavailable'; $f.input_count=$null; $f.unattempted_count=$null
    $f.attempted_count=0; $f.saved_count=0; $f.dropped_count=0
    Set-TestObservation $e {param($o) $o.frames[0].a11y_windows=@(); $o.frames[0].windows_truncated=$true}
    Assert-True (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath) 'unavailable schema'
    Assert-Counts $e $null
}
Test-Case 'schema accepts overflow shape but consumer rejects success' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]; $f.count_status='overflow'; $f.input_count=$null; $f.unattempted_count=$null
    Assert-True (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath) 'overflow schema'
    Assert-Counts $e 'count_overflow'
}
Test-Case 'historical inventory v2 is explicitly rejected' {
    $e=New-TestEnvelope; $e.schema='tablet-c1b-inventory-result/v2'
    Assert-ParseFailure (Convert-TestEnvelope $e) 'version_mismatch'
}
Test-Case 'type read failure still conserves a dropped window' {
    $e=New-TestEnvelope; $f=$e.inventory_frames[0]
    $f.input_count=2; $f.attempted_count=2; $f.dropped_count=1; $f.first_stop_counts.window_type_read_failed=1
    Set-TestObservation $e {param($o) $o.frames[0].windows_truncated=$true}
    Assert-Counts $e $null
}
foreach($value in @(0,-1,256,[int]::MinValue,[int]::MaxValue)) {
    Test-Case "unknown inner type integer stays raw for observation consumer [$value]" {
        $e=New-TestEnvelope
        Set-TestObservation $e {param($o) $o.frames[0].a11y_windows[0]|Add-Member -NotePropertyName platform_type_code -NotePropertyValue $value}
        Assert-Counts $e $null
        $r=ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e)
        Assert-True ($r.Observation.frames[0].a11y_windows[0].platform_type_code -eq $value) 'inner type changed'
    }
}
foreach($mutation in @('missing','null','object')) {
    Test-Case "empty rejected type field shape $mutation" {
        $e=New-TestEnvelope; $f=$e.inventory_frames[0]
        switch($mutation){
            missing {$f.Remove('rejected_type_code_counts')}
            null {$f.rejected_type_code_counts=$null}
            object {$f.rejected_type_code_counts=[ordered]@{}}
        }
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($mutation in @('string','chat-object','raw-id-object','extra-chat','extra-window-id','null-item','array-item','missing-code','missing-count','empty-object')) {
    Test-Case "rejected table blocks arbitrary payload $mutation before returning observation" {
        $e=New-TestEnvelope
        $entry=[ordered]@{platform_type_code=-1;count=1}
        switch($mutation){
            string {$entry='synthetic-chat-text-canary'}
            chat-object {$entry=[ordered]@{chat_text='synthetic-chat-text-canary';window_id=42}}
            raw-id-object {$entry=[ordered]@{window_id=42}}
            extra-chat {$entry['chat_text']='synthetic-chat-text-canary'}
            extra-window-id {$entry['window_id']=42}
            null-item {$entry=$null}
            array-item {$entry=@('synthetic-chat-text-canary')}
            missing-code {$entry.Remove('platform_type_code')}
            missing-count {$entry.Remove('count')}
            empty-object {$entry=[ordered]@{}}
        }
        $e.inventory_frames[0].rejected_type_code_counts=,$entry
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($value in @(0,7,255,-2147483649L,2147483648L,'-1',$true,$null,-1.5,[ordered]@{chat_text='synthetic-chat-text-canary'},@(-1))) {
    Test-Case "rejected table code remains a closed rejected Int32 [$value]" {
        $e=New-TestEnvelope
        $e.inventory_frames[0].rejected_type_code_counts=@([ordered]@{platform_type_code=$value;count=1})
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($value in @(0,-1,17,'1',$true,$null,1.5,[ordered]@{chat_text='synthetic-chat-text-canary'},@(1))) {
    Test-Case "rejected table count remains a positive bounded integer [$value]" {
        $e=New-TestEnvelope
        $e.inventory_frames[0].rejected_type_code_counts=@([ordered]@{platform_type_code=-1;count=$value})
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($rawCode in @('-1.0','1e0')) {
    Test-Case "rejected table code rejects numeric token $rawCode" {
        $e=New-TestEnvelope
        $e.inventory_frames[0].rejected_type_code_counts=@([ordered]@{platform_type_code=-1;count=1})
        $raw=[Text.Encoding]::UTF8.GetString((Convert-TestEnvelope $e)).Replace('"platform_type_code":-1',('"platform_type_code":'+$rawCode))
        Assert-ParseFailure ([Text.Encoding]::UTF8.GetBytes($raw)) 'shape_invalid'
    }
}
foreach($codes in @(@(-1,-1),@(256,-1))) {
    Test-Case "rejected table remains strictly ordered and unique [$($codes -join ',')]" {
        $e=New-TestEnvelope
        $e.inventory_frames[0].rejected_type_code_counts=@($codes|ForEach-Object{[ordered]@{platform_type_code=$_;count=1}})
        Assert-ParseFailure (Convert-TestEnvelope $e) 'shape_invalid'
    }
}
foreach($code in @([int]::MinValue,-1,256,[int]::MaxValue)) {
    Test-Case "well-formed numeric rejected table is never accepted v3 evidence [$code]" {
        $e=New-TestEnvelope
        $e.inventory_frames[0].rejected_type_code_counts=@([ordered]@{platform_type_code=$code;count=1})
        Assert-Counts $e 'count_mismatch'
        $e.inventory_frames[0].capture_id='old-capture'
        Assert-Counts $e 'capture_binding_mismatch'
    }
}
Test-Case 'nonempty rejected type field never becomes accepted v3 evidence' {
    $e=New-TestEnvelope
    $e.inventory_frames[0].rejected_type_code_counts=@([ordered]@{platform_type_code=-1;count=1})
    Assert-Counts $e 'count_mismatch'
    Assert-True (-not (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'schema accepted obsolete rejected code'
    $e.inventory_frames[0].capture_id='old-capture'
    Assert-Counts $e 'capture_binding_mismatch'
}
Test-Case 'nonzero type-invalid first stop is forbidden after binding' {
    $e=New-TestEnvelope; $e.inventory_frames[0].first_stop_counts.window_type_invalid=1
    Assert-Counts $e 'count_mismatch'
    Assert-True (-not (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'schema accepted range-based first stop'
    $e.inventory_frames[0].capture_id='old-capture'
    Assert-Counts $e 'capture_binding_mismatch'
}
Test-Case 'schema requires the always-empty rejected type field' {
    $e=New-TestEnvelope; $e.inventory_frames[0].Remove('rejected_type_code_counts')
    Assert-True (-not (Test-Json -Json ($e|ConvertTo-Json -Depth 100) -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) 'schema accepted missing empty field'
}
Test-Case 'inner version remains an original runner binding decision' {
    $e=New-TestEnvelope; Set-TestObservation $e {param($o) $o.schema='tablet-layout-observation/c1b-v1'}
    $r=ConvertFrom-C1bInventoryResult -Bytes (Convert-TestEnvelope $e)
    Assert-True $r.Valid 'parser bypassed original privacy and binding decision'
    Assert-True ($r.Observation.schema -ceq 'tablet-layout-observation/c1b-v1') 'parser rewrote inner version'
}
Write-Host "tablet-c1b inventory result offline: $script:Passed passed, $script:Failed failed"
if($script:Failed){exit 1}
