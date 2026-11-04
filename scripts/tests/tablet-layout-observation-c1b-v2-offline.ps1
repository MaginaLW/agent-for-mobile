#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $repoRoot 'scripts/lib/tablet-layout-observation-c1b-v2-validator.ps1')
$baseRaw = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/tablet-layout-observation/c1b-v1/real-shape-topology-only.json'))
$tempRoot = [IO.Directory]::CreateTempSubdirectory('tl1c1bv2-offline-')
$script:Passed = 0
$script:Failed = 0
$now = [DateTimeOffset]::UtcNow

function Assert-V2([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-V2Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Copy-V2Value($Value) { return $Value | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100 -DateKind String }
function New-V2Document([switch]$Legacy) {
    $doc = $baseRaw | ConvertFrom-Json -Depth 100 -DateKind String
    if (-not $Legacy) { $doc.schema='tablet-layout-observation/c1b-v2'; $doc.provenance.version='c1b-v2' }
    $format="yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
    $doc.upstream_t0.captured_at=$now.AddSeconds(-4).UtcDateTime.ToString($format)
    $doc.frames[0].captured_at=$now.AddSeconds(-2).UtcDateTime.ToString($format)
    $doc.frames[1].captured_at=$now.AddSeconds(-1).UtcDateTime.ToString($format)
    $doc.captured_at=$doc.frames[1].captured_at
    return $doc
}
function Write-V2Document($Document) {
    $path=Join-Path $tempRoot.FullName (([Guid]::NewGuid().ToString('N'))+'.json')
    [IO.File]::WriteAllText($path,($Document|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
    return $path
}
function Read-V2Document($Document) {
    return Test-TabletLayoutObservationC1BV2File -Path (Write-V2Document $Document) -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $now
}
function Set-V2UnknownType($Document, [long]$Code) {
    foreach($frame in $Document.frames) {
        $frame.a11y_windows[4].platform_type_code=$Code
        $frame.a11y_windows[4].type='unknown'
        $frame.focus.status='unknown'; $frame.focus.window_label=$null; $frame.focus.node_label=$null
        $frame.ime.mode='unknown'; $frame.ime.binding='unknown'
    }
    $Document.reason_codes=@(@($Document.reason_codes)+@('window_type_invalid','ime_inventory_invalid')|Sort-Object -Unique)
}
function Assert-V2Blocked($Result) {
    Assert-V2 ($Result.reason_codes -ccontains 'window_type_invalid') 'unknown code lost semantic type blocker'
    Assert-V2 ($Result.reason_codes -ccontains 'ime_inventory_invalid') 'unknown type proved IME hidden'
    foreach($key in @('window_inventory_observed','window_root_projection_observed','application_window_topology_observed','ime_hidden_observed','runtime_origin_verified','runtime_evidence','layout_accepted','editor_action_ready','execution_grant')) {
        Assert-V2 (-not $Result.$key) ('unexpected grant '+$key)
    }
}

try {
    Test-V2Case 'known v2 schema and result identity' {
        $r=Read-V2Document (New-V2Document)
        Assert-V2 $r.fixture_contract_valid 'known baseline not contract-valid'
        Assert-V2 ($r.schema -ceq 'tablet-layout-observation-validation/c1b-v2' -and $r.contract_schema -ceq 'tablet-layout-observation/c1b-v2') 'result version mislabeled'
        Assert-V2 $r.application_window_topology_observed 'known baseline topology changed'
        Assert-V2 (-not $r.semantic_tree_usable -and -not $r.execution_grant) 'opaque roots gained capability'
    }
    foreach($code in @([int]::MinValue,-1,0,256,[int]::MaxValue)) {
        Test-V2Case "signed unknown type remains valid and blocked [$code]" {
            $d=New-V2Document; Set-V2UnknownType $d $code
            $r=Read-V2Document $d
            Assert-V2 $r.fixture_contract_valid 'signed unknown type rejected by contract'
            Assert-V2Blocked $r
            Assert-V2 ($d.frames[0].a11y_windows[4].platform_type_code -eq $code) 'source integer changed'
        }
    }
    Test-V2Case 'duplicate unknown raw code is not window identity' {
        $d=New-V2Document; Set-V2UnknownType $d -1
        foreach($frame in $d.frames) {
            $extra=Copy-V2Value $frame.a11y_windows[4]; $extra.window_label='aw6'
            $frame.a11y_windows=@($frame.a11y_windows)+@($extra)
        }
        $r=Read-V2Document $d
        Assert-V2 $r.fixture_contract_valid 'duplicate type treated as duplicate identity'
        Assert-V2Blocked $r
        Assert-V2 ($d.frames[0].a11y_windows[4].platform_type_code -eq -1 -and $d.frames[0].a11y_windows[5].platform_type_code -eq -1) 'duplicate original code lost'
    }
    foreach($code in @(-2147483649L,2147483648L)) {
        Test-V2Case "outside Int32 rejected [$code]" {
            $d=New-V2Document; Set-V2UnknownType $d $code
            $r=Read-V2Document $d
            Assert-V2 (-not $r.fixture_contract_valid -and $r.reason_codes -ccontains 'json_schema_validation_failed') 'out-of-Int32 type accepted'
        }
    }
    foreach($rawCode in @('-1.0','1e0','1.5','9223372036854775808')) {
        Test-V2Case "fraction exponent or oversized integer rejected [$rawCode]" {
            $d=New-V2Document; Set-V2UnknownType $d -1
            $raw=($d|ConvertTo-Json -Depth 100 -Compress).Replace('"platform_type_code":-1',('"platform_type_code":'+$rawCode))
            $path=Join-Path $tempRoot.FullName (([Guid]::NewGuid().ToString('N'))+'.json')
            [IO.File]::WriteAllText($path,$raw,[Text.UTF8Encoding]::new($false))
            $r=Test-TabletLayoutObservationC1BV2File -Path $path -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $now
            Assert-V2 (-not $r.fixture_contract_valid -and $r.reason_codes -ccontains 'json_number_not_int64') 'non-integer token accepted'
        }
    }
    foreach($mapping in @(@(-1,'system'),@(7,'system'),@(3,'window_control'))) {
        Test-V2Case "false known mapping stays diagnostic [$($mapping -join ',')]" {
            $d=New-V2Document; Set-V2UnknownType $d ([long]$mapping[0])
            foreach($frame in $d.frames){$frame.a11y_windows[4].type=$mapping[1]}
            $r=Read-V2Document $d
            Assert-V2 $r.fixture_contract_valid 'mapping mismatch changed diagnostic/fatal classification'
            Assert-V2Blocked $r
        }
    }
    Test-V2Case 'unknown cannot retain window-only focus' {
        $d=New-V2Document; Set-V2UnknownType $d -1
        foreach($frame in $d.frames){$frame.focus.status='window_only';$frame.focus.window_label='aw2'}
        $d.reason_codes=@(@($d.reason_codes)+'focus_inventory_invalid'|Sort-Object -Unique)
        $r=Read-V2Document $d
        Assert-V2 ($r.reason_codes -ccontains 'focus_inventory_invalid') 'unknown gained known focus'
        Assert-V2Blocked $r
    }
    Test-V2Case 'hidden-looking IME cannot override unknown type inventory' {
        $d=New-V2Document; Set-V2UnknownType $d -1
        foreach($frame in $d.frames){$frame.ime.mode='none';$frame.ime.binding='not_active'}
        $r=Read-V2Document $d
        Assert-V2 $r.fixture_contract_valid 'honest unknown blocker cannot be encoded'
        Assert-V2Blocked $r
    }
    foreach($flag in @('execution_grant','layout_accepted','editor_action_ready')) {
        Test-V2Case "unknown cannot elevate $flag" {
            $d=New-V2Document; Set-V2UnknownType $d -1; $d.$flag=$true
            $r=Read-V2Document $d
            Assert-V2 (-not $r.fixture_contract_valid) 'capability constant accepted'
            Assert-V2 (-not $r.execution_grant -and -not $r.layout_accepted) 'invalid document produced grant'
        }
    }
    Test-V2Case 'v2 rejects old observation and provenance versions' {
        $r=Read-V2Document (New-V2Document -Legacy)
        Assert-V2 (-not $r.fixture_contract_valid -and $r.contract_schema -ceq 'tablet-layout-observation/c1b-v2') 'v2 accepted legacy version'
        $d=New-V2Document; $d.provenance.version='c1b-v1'; $r=Read-V2Document $d
        Assert-V2 (-not $r.fixture_contract_valid) 'v2 accepted old provenance version'
    }
    Test-V2Case 'v1 and v2 public APIs coexist without widening old contract' {
        $old=New-V2Document -Legacy
        $r=Test-TabletLayoutObservationC1BV1File -Path (Write-V2Document $old) -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $now
        Assert-V2 ($r.fixture_contract_valid -and $r.contract_schema -ceq 'tablet-layout-observation/c1b-v1') 'old public API changed'
        Set-V2UnknownType $old -1
        $r=Test-TabletLayoutObservationC1BV1File -Path (Write-V2Document $old) -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $now
        Assert-V2 (-not $r.fixture_contract_valid) 'co-loaded v2 widened old signed domain'
        $r=Test-TabletLayoutObservationC1BV1File -Path (Write-V2Document (New-V2Document)) -EvidenceRoot $tempRoot.FullName -FixtureMode -ValidationNowUtc $now
        Assert-V2 (-not $r.fixture_contract_valid) 'old public API accepted new version'
        . (Join-Path $repoRoot 'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1')
        $r=Read-V2Document (New-V2Document)
        Assert-V2 ($r.fixture_contract_valid -and $r.contract_schema -ceq 'tablet-layout-observation/c1b-v2') 'reverse load order contaminated v2'
    }
    Test-V2Case 'v2 trusted runtime remains binding facts only' {
        $d=New-V2Document; Set-V2UnknownType $d -1
        $d.provenance.kind='gateway_runtime_probe'; $d.upstream_t0.source_kind='trusted_runtime'
        $d.expected_title_hash=$script:TL1C1BV1TrustedRuntimeTitleHash
        $path=Write-V2Document $d
        $r=Test-TabletLayoutObservationC1BV2TrustedRuntimeFile -Path $path -EvidenceRoot $tempRoot.FullName `
            -ExpectedRunId $d.run_id -ExpectedProducerCommitSha $d.provenance.producer_commit_sha `
            -ExpectedProducerArtifactSha256 $d.provenance.producer_artifact_sha256 -ValidationNowUtc $now
        Assert-V2 ($r.fixture_contract_valid -and $r.runtime_binding_inputs_match) 'trusted v2 binding did not match'
        Assert-V2Blocked $r
        $r=Test-TabletLayoutObservationC1BV2TrustedRuntimeFile -Path $path -EvidenceRoot $tempRoot.FullName `
            -ExpectedRunId 'wrong-run' -ExpectedProducerCommitSha $d.provenance.producer_commit_sha `
            -ExpectedProducerArtifactSha256 $d.provenance.producer_artifact_sha256 -ValidationNowUtc $now
        Assert-V2 (-not $r.runtime_binding_inputs_match -and -not $r.runtime_origin_verified) 'mismatched runtime granted provenance'
    }
    Test-V2Case 'v2 public non-fixture entry refuses before reading' {
        $r=Test-TabletLayoutObservationC1BV2File -Path (Join-Path $tempRoot.FullName 'not-present.json') -EvidenceRoot $tempRoot.FullName
        Assert-V2 (-not $r.fixture_contract_valid -and $r.contract_schema -ceq 'tablet-layout-observation/c1b-v2') 'public entry mislabeled or granted runtime'
        Assert-V2 ($r.reason_codes -ccontains 'runtime_producer_unavailable') 'public entry did not stop before reading'
    }
} finally {
    $actual=[IO.Path]::GetFullPath($tempRoot.FullName)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if (-not $actual.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { throw 'test_cleanup_path_outside_temp' }
    Remove-Item -LiteralPath $actual -Recurse -Force
}
Write-Host "tablet-c1b observation v2 offline: $script:Passed passed, $script:Failed failed"
if($script:Failed){exit 1}
