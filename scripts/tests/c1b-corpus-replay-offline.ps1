#Requires -Version 7.5
[CmdletBinding()]
param([switch]$RequireOriginals)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'scripts/lib/tablet-layout-observation-c1b-v2-validator.ps1')
. (Join-Path $repoRoot 'scripts/lib/tablet-c1b-inventory-result.ps1')
$corpusRoot = Join-Path $PSScriptRoot 'fixtures/c1b-corpus/v1'
$manifest = Get-Content -LiteralPath (Join-Path $corpusRoot 'manifest.json') -Raw | ConvertFrom-Json -Depth 100 -DateKind String
$workRoot = Join-Path $repoRoot ('.checks/reduce-manual-20261111/corpus/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$script:passed = 0
$script:failed = 0
$script:originals = 0

function Assert-Corpus([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-Corpus([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name : $($_.Exception.Message)" }
}
function Copy-Corpus($Value) { return $Value | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100 -DateKind String }
function Get-CorpusHash([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() }

# This is the full, deterministic redaction transform, not a claim of byte equality with the source.
function ConvertTo-CorpusFixture($Observation, [string]$Name) {
    $doc = Copy-Corpus $Observation
    $origin = [DateTimeOffset]::Parse($doc.upstream_t0.captured_at)
    $anchor = [DateTimeOffset]::Parse('2026-01-01T00:00:00.0000000Z')
    $format = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
    $doc.run_id = "tl1-c1b-replay-$Name"
    $doc.expected_title_hash = 'sha256:' + ('a' * 64)
    $doc.provenance.kind = 'offline_fixture'
    $doc.provenance.name = 'tablet-c1b-replay-fixture'
    $doc.provenance.producer_commit_sha = '0' * 40
    $doc.provenance.producer_artifact_sha256 = 'sha256:' + ('b' * 64)
    $doc.upstream_t0.source_kind = 'offline_fixture'
    $doc.upstream_t0.run_id = $doc.run_id
    $doc.upstream_t0.artifact_sha256 = 'sha256:' + ('c' * 64)
    $doc.upstream_t0.device_profile_hash = 'sha256:' + ('d' * 64)
    $doc.upstream_t0.captured_at = $anchor.UtcDateTime.ToString($format)
    foreach ($frame in $doc.frames) {
        $frame.capture_id = 'capture-' + $frame.capture.token
        $frame.captured_at = $anchor.Add([DateTimeOffset]::Parse($frame.captured_at) - $origin).UtcDateTime.ToString($format)
    }
    $doc.captured_at = $doc.frames[-1].captured_at
    return $doc | ConvertTo-Json -Depth 100 -Compress
}
function Read-Corpus($Document, [string]$Version, [switch]$Original, [string]$OriginalPath) {
    $path = $OriginalPath
    $evidenceRoot = $workRoot
    if ($Original) {
        Assert-Corpus (-not [string]::IsNullOrWhiteSpace($OriginalPath)) 'original path required'
        $evidenceRoot = Split-Path $OriginalPath -Parent
    } else {
        $path = Join-Path $workRoot ([guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, ($Document | ConvertTo-Json -Depth 100 -Compress), [Text.UTF8Encoding]::new($false))
    }
    $clock = [DateTimeOffset]::Parse($Document.captured_at).AddSeconds(1)
    $arguments = @{ Path=$path; EvidenceRoot=$evidenceRoot; ValidationNowUtc=$clock }
    if ($Original) {
        $arguments.ExpectedRunId = $Document.run_id
        $arguments.ExpectedProducerCommitSha = $Document.provenance.producer_commit_sha
        $arguments.ExpectedProducerArtifactSha256 = $Document.provenance.producer_artifact_sha256
        if ($Version -ceq 'c1b-v2') { return Test-TabletLayoutObservationC1BV2TrustedRuntimeFile @arguments }
        return Test-TabletLayoutObservationC1BV1TrustedRuntimeFile @arguments
    }
    if ($Version -ceq 'c1b-v2') { return Test-TabletLayoutObservationC1BV2File @arguments -FixtureMode }
    return Test-TabletLayoutObservationC1BV1File @arguments -FixtureMode
}
function Assert-CorpusNoGrant($Result) {
    foreach ($key in @('runtime_origin_verified','runtime_evidence','navigation_pane_verified','conversation_pane_verified',
        'target_conversation_verified','target_regions_verified','layout_accepted','editor_action_ready','device_action_allowed','execution_grant')) {
        Assert-Corpus (-not $Result.$key) "unexpected capability: $key"
    }
    Assert-Corpus ($Result.p0_capability -ceq 'unsupported') 'P0 capability changed'
}
function Assert-CorpusExpected($Result, $Case) {
    Assert-Corpus $Result.fixture_contract_valid 'historical contract classification changed'
    Assert-Corpus ((($Result.reason_codes | Sort-Object) -join ',') -ceq (($Case.expected_reasons | Sort-Object) -join ',')) 'historical diagnostic reasons changed'
    foreach ($key in @('application_window_topology_observed','semantic_tree_usable','ime_hidden_observed')) {
        Assert-Corpus ($Result.$key -eq $Case.expected_facts.$key) "historical fact changed: $key"
    }
    Assert-CorpusNoGrant $Result
}

Assert-Corpus ($manifest.schema -ceq 'c1b-replay-corpus/v1' -and $manifest.cases.Count -eq 2) 'corpus identity or size changed'
foreach ($case in $manifest.cases) {
    $fixturePath = Join-Path $corpusRoot $case.fixture
    $fixtureBytes = [IO.File]::ReadAllBytes($fixturePath)
    $fixtureRaw = [Text.UTF8Encoding]::new($false,$true).GetString($fixtureBytes)
    $fixture = $fixtureRaw | ConvertFrom-Json -Depth 100 -DateKind String
    Test-Corpus "$($case.name) derived bytes and historical classification" {
        Assert-Corpus ((Get-CorpusHash $fixtureBytes) -ceq $case.fixture_sha256) 'derived bytes changed without corpus review'
        Assert-CorpusExpected (Read-Corpus $fixture $case.version) $case
    }
    if ($RequireOriginals) {
        Test-Corpus "$($case.name) original bytes reader validator and redaction derivation" {
            $observationPath = Join-Path $repoRoot $case.source_observation
            $envelopePath = Join-Path $repoRoot $case.source_envelope
            $observationBytes = [IO.File]::ReadAllBytes($observationPath)
            $envelopeBytes = [IO.File]::ReadAllBytes($envelopePath)
            Assert-Corpus ((Get-CorpusHash $observationBytes) -ceq $case.source_observation_sha256) 'source observation hash mismatch'
            Assert-Corpus ((Get-CorpusHash $envelopeBytes) -ceq $case.source_envelope_sha256) 'source envelope hash mismatch'
            $observationRaw = [Text.UTF8Encoding]::new($false,$true).GetString($observationBytes)
            $original = $observationRaw | ConvertFrom-Json -Depth 100 -DateKind String
            $envelope = [Text.UTF8Encoding]::new($false,$true).GetString($envelopeBytes) | ConvertFrom-Json -Depth 100 -DateKind String
            Assert-Corpus ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($envelope.observation_json)) -ceq [Convert]::ToBase64String($observationBytes)) 'original observation string bytes differ'
            $parsed = ConvertFrom-C1bInventoryResult -Bytes $envelopeBytes
            if ($case.version -ceq 'c1b-v2') {
                Assert-Corpus $parsed.Valid 'current v3 reader rejected original envelope'
                Assert-Corpus (Test-C1bInventoryCounts -Result $parsed).Valid 'original inventory counts changed'
                Assert-Corpus ([Convert]::ToBase64String($parsed.ObservationBytes) -ceq [Convert]::ToBase64String($observationBytes)) 'current reader changed original bytes'
            } else {
                Assert-Corpus (-not $parsed.Valid -and $parsed.ReasonCode -ceq 'version_mismatch') 'current reader must not silently accept historical v1 envelope'
            }
            Assert-CorpusExpected (Read-Corpus $original $case.version -Original -OriginalPath $observationPath) $case
            Assert-Corpus ((ConvertTo-CorpusFixture $original $case.name) -ceq $fixtureRaw) 'redaction derivation changed'
            $script:originals++
        }
    }
}

# Deterministic bounded mutations use the v2 real-derived case, never a device or random unbounded loop.
$seed = Get-Content -LiteralPath (Join-Path $corpusRoot $manifest.cases[1].fixture) -Raw | ConvertFrom-Json -Depth 100 -DateKind String
foreach ($code in @([int]::MinValue,-1,0,256,[int]::MaxValue)) {
    Test-Corpus "unknown type $code remains diagnostic" {
        $doc = Copy-Corpus $seed
        foreach ($frame in $doc.frames) { ($frame.a11y_windows | Where-Object type -CEQ 'unknown').platform_type_code = $code }
        $result = Read-Corpus $doc 'c1b-v2'
        Assert-Corpus ($result.fixture_contract_valid -and $result.reason_codes -ccontains 'window_type_invalid' -and -not $result.ime_hidden_observed) 'unknown type gained inventory or hidden-IME proof'
        Assert-CorpusNoGrant $result
    }
}
foreach ($code in @(-2147483649L,2147483648L)) {
    Test-Corpus "outside Int32 $code rejected" {
        $doc = Copy-Corpus $seed
        foreach ($frame in $doc.frames) { ($frame.a11y_windows | Where-Object type -CEQ 'unknown').platform_type_code = $code }
        $result = Read-Corpus $doc 'c1b-v2'
        Assert-Corpus (-not $result.fixture_contract_valid -and $result.reason_codes -ccontains 'json_schema_validation_failed') 'out-of-domain integer accepted'
        Assert-CorpusNoGrant $result
    }
}
foreach ($mode in @('none','floating','unknown')) {
    foreach ($binding in @('not_active','unknown')) {
        Test-Corpus "conservative false IME $mode/$binding is not hidden proof" {
            $doc = Copy-Corpus $seed
            foreach ($frame in $doc.frames) { $frame.ime.visible=$false; $frame.ime.mode=$mode; $frame.ime.binding=$binding }
            $result = Read-Corpus $doc 'c1b-v2'
            Assert-Corpus (-not $result.ime_hidden_observed) 'conservative false became hidden proof'
            Assert-CorpusNoGrant $result
        }
    }
}
Test-Corpus 'opaque child_count zero cannot become usable semantics' {
    $result = Read-Corpus $seed 'c1b-v2'
    Assert-Corpus ($result.reason_codes -ccontains 'semantic_subtree_opaque' -and -not $result.semantic_tree_usable) 'opaque root promoted'
    Assert-CorpusNoGrant $result
}
Test-Corpus 'truncated inventory requires an honest blocker' {
    $doc = Copy-Corpus $seed
    foreach ($frame in $doc.frames) { $frame.windows_truncated=$true }
    $result = Read-Corpus $doc 'c1b-v2'
    Assert-Corpus (-not $result.fixture_contract_valid -and $result.reason_codes -ccontains 'declared_reasons_incomplete') 'undeclared truncation accepted'
    $doc.reason_codes = @($doc.reason_codes) + 'window_inventory_truncated'
    $result = Read-Corpus $doc 'c1b-v2'
    Assert-Corpus ($result.fixture_contract_valid -and -not $result.window_inventory_observed) 'honest truncation classification changed'
    Assert-CorpusNoGrant $result
}
foreach ($edge in @(-32769,32769)) {
    Test-Corpus "out-of-schema geometry $edge rejected" {
        $doc = Copy-Corpus $seed
        $doc.frames[0].a11y_windows[0].bounds.left=$edge
        $result = Read-Corpus $doc 'c1b-v2'
        Assert-Corpus (-not $result.fixture_contract_valid -and $result.reason_codes -ccontains 'json_schema_validation_failed') 'out-of-domain geometry accepted'
        Assert-CorpusNoGrant $result
    }
}
Test-Corpus 'invalid positive rectangle cannot gain topology' {
    $doc = Copy-Corpus $seed
    $doc.frames[0].a11y_windows[0].bounds.right=$doc.frames[0].a11y_windows[0].bounds.left
    $result = Read-Corpus $doc 'c1b-v2'
    Assert-Corpus ($result.reason_codes -ccontains 'window_geometry_invalid' -and -not $result.application_window_topology_observed) 'invalid rectangle promoted'
    Assert-CorpusNoGrant $result
}
Test-Corpus 'v3 count mutation rejected by the actual inventory reader' {
    # A public, derived envelope preserves original count shape while using no original identity.
    $counts = foreach ($frame in $seed.frames) {
        $stops = [ordered]@{}; foreach ($key in $script:C1bInventoryStopKeys) { $stops[$key]=0 }
        [ordered]@{capture_id=$frame.capture_id;capture_token=$frame.capture.token;enumeration_status='complete';count_status='exact';maximum_windows=16;
            input_count=5;unattempted_count=0;attempted_count=5;saved_count=5;dropped_count=0;first_stop_counts=$stops;rejected_type_code_counts=@()}
    }
    $envelope = [ordered]@{schema='tablet-c1b-inventory-result/v3';observation_json=($seed | ConvertTo-Json -Depth 100 -Compress);inventory_frames=@($counts)}
    $parsed = ConvertFrom-C1bInventoryResult -Bytes ([Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 100 -Compress)))
    Assert-Corpus ($parsed.Valid -and (Test-C1bInventoryCounts -Result $parsed).Valid) 'derived count baseline failed'
    $envelope.inventory_frames[0].saved_count=4
    $parsed = ConvertFrom-C1bInventoryResult -Bytes ([Text.Encoding]::UTF8.GetBytes(($envelope | ConvertTo-Json -Depth 100 -Compress)))
    $countsResult = Test-C1bInventoryCounts -Result $parsed
    Assert-Corpus (-not $countsResult.Valid -and $countsResult.ReasonCode -ceq 'count_mismatch') 'count mismatch accepted'
}

$summary = [ordered]@{schema='c1b-corpus-replay-summary/v1';passed=$script:passed;failed=$script:failed;derived_cases=$manifest.cases.Count;
    original_cases_replayed=$script:originals;originals_required=[bool]$RequireOriginals;mutations_bounded=$true;device_calls=0;runtime_acceptance=$false;execution_grant=$false}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $workRoot 'summary.json') -Encoding utf8
Write-Host "c1b corpus replay offline: $script:passed passed, $script:failed failed; originals=$script:originals"
if ($script:failed -ne 0) { exit 1 }
