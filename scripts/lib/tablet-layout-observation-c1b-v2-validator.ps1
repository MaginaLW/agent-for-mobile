#Requires -Version 7.5
# C1b v2 has a signed Int32 type domain; all diagnostic and safety semantics reuse the fixed-version core.
. (Join-Path $PSScriptRoot 'tablet-layout-observation-c1b-v1-validator.ps1')

function Test-TabletLayoutObservationC1BV2File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$FixtureMode,
        [DateTimeOffset]$ValidationNowUtc = [DateTimeOffset]::UtcNow
    )
    if (-not $FixtureMode) {
        $issues = [Collections.Generic.List[object]]::new()
        Add-TL1C1BV1Issue $issues 'runtime_producer_unavailable' '/provenance'
        return New-TL1C1BV1ValidationResult $false $false $null $issues -ContractVersion 'c1b-v2'
    }
    return Test-TL1C1BV1Core -Path $Path -EvidenceRoot $EvidenceRoot -OriginMode fixture `
        -ValidationNowUtc $ValidationNowUtc -ContractVersion 'c1b-v2'
}

function Test-TabletLayoutObservationC1BV2TrustedRuntimeFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedProducerCommitSha,
        [Parameter(Mandatory)][string]$ExpectedProducerArtifactSha256,
        [DateTimeOffset]$ValidationNowUtc = [DateTimeOffset]::UtcNow
    )
    return Test-TL1C1BV1Core -Path $Path -EvidenceRoot $EvidenceRoot -OriginMode trusted_runtime `
        -ValidationNowUtc $ValidationNowUtc -ExpectedRunId $ExpectedRunId `
        -ExpectedProducerCommitSha $ExpectedProducerCommitSha `
        -ExpectedProducerArtifactSha256 $ExpectedProducerArtifactSha256 -ContractVersion 'c1b-v2'
}
