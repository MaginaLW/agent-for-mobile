#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FrozenSourceRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$PwshPath,
    [string]$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-candidate-source.ps1')

# 此入口只写 gitignored review drafts。不能据此声称 clean SHA/preflight/build 已验收。
function Read-CandidateInput {
    param([string]$Path, [switch]$Bytes)
    $full = [IO.Path]::GetFullPath($Path)
    $cursor = $full
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Candidate input contains a reparse path.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
    $stream = [IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 4194304L) { throw 'Candidate input exceeds 4 MiB.' }
        $data = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($data)
        if ($stream.ReadByte() -ne -1) { throw 'Candidate input length changed.' }
        if ($Bytes) { return ,$data }
        return [Text.UTF8Encoding]::new($false,$true).GetString($data)
    }
    finally { $stream.Dispose() }
}
function Get-CandidateFileHash {
    param([string]$Path)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        (Read-CandidateInput $Path -Bytes))).ToLowerInvariant()
}

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$FrozenSourceRoot = [IO.Path]::GetFullPath($FrozenSourceRoot)
$PwshPath = [IO.Path]::GetFullPath($PwshPath)
$short = $CommitSha.Substring(0,7)
if ((Get-CandidateFileHash $PwshPath) -cne
    '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139' -or
    [Environment]::ProcessPath -ine $PwshPath -or $PSVersionTable.PSVersion.ToString() -cne '7.6.5') {
    throw 'Preparation must run under the exact pinned PowerShell 7.6.5.'
}
$utility = [IO.Path]::Combine([IO.Path]::GetDirectoryName($PwshPath),'Microsoft.PowerShell.Commands.Utility.dll')
$utilityBytes = Read-CandidateInput $utility -Bytes
$pair = New-C1bExactPairCandidateSource `
    -BaselineRendererSource (Read-CandidateInput (Join-Path $FrozenSourceRoot 'render-final-r12-015835c.ps1')) `
    -HelperTemplateSource (Read-CandidateInput (Join-Path $FrozenSourceRoot 'helper-template.ps1')) `
    -LauncherTemplateSource (Read-CandidateInput (Join-Path $FrozenSourceRoot 'launcher-template-r11.ps1')) `
    -CommitSha $CommitSha -RepoRoot $RepoRoot -StagingRoot $FrozenSourceRoot -PwshPath $PwshPath `
    -UtilityAssemblySha256 (Get-CandidateFileHash $utility) -UtilityAssemblyLength $utilityBytes.Length
$indexPath = Join-Path $RepoRoot '.git/index'
$indexBytes = Read-CandidateInput $indexPath -Bytes
if ($indexBytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($indexBytes,0,4) -cne 'DIRC') {
    throw 'Repository index is not an ordinary Git index.'
}
$entryCount = [long]$indexBytes[8]*16777216L + [long]$indexBytes[9]*65536L +
    [long]$indexBytes[10]*256L + [long]$indexBytes[11]
$indexHash = Get-CandidateFileHash $indexPath
$constants = [ordered]@{
    repoRoot=$RepoRoot; stagingRoot=$FrozenSourceRoot
    expectedCommitSha=$CommitSha; expectedCommitShort=$short
    helperPath=(Join-Path $FrozenSourceRoot "helper-$short-r11.ps1")
    expectedHelperSha256=$pair.HelperSha256; expectedHelperByteLength=$pair.HelperByteLength
    launcherPath=(Join-Path $FrozenSourceRoot "launcher-$short-r11.ps1")
    expectedLauncherSha256=$pair.LauncherSha256; expectedLauncherByteLength=$pair.LauncherByteLength
    expectedLauncherTemplateSha256=$pair.LauncherTemplateSha256
    failureSidecarPath=(Join-Path $FrozenSourceRoot "launcher-$short-r11.failure.json")
    pwshPath=$PwshPath; expectedPwshSha256=(Get-CandidateFileHash $PwshPath)
    expectedGitIndexSha256=$indexHash; expectedGitTrackedPathCount=$entryCount
    expectedGitConfigSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.git/config'))
    expectedGitAttributesSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.gitattributes'))
    expectedGitIgnoreSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.gitignore'))
    expectedGitInfoExcludeSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.git/info/exclude'))
    expectedVerifierSha256=(Get-CandidateFileHash (Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'))
    summaryLeaf="tablet-c1b-real-build-smoke-$short.summary.json"
    logLeaf="tablet-c1b-real-build-smoke-$short.log"
    launcherResultLeaf="tablet-c1b-real-build-smoke-$short.launcher.json"
    receiptLeaf="preflight-$short-r14.prepared-not-authorized.receipt.json"
}
$baselinePath = Join-Path $FrozenSourceRoot 'preflight-a661f36-r13.ps1'
$leaf = New-C1bPreflightR14CandidateSource -BaselineLeafSource (Read-CandidateInput $baselinePath) `
    -ChecksSource (Read-CandidateInput (Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-preflight-r14-checks.ps1')) `
    -Constants $constants
$renderer = New-C1bPreflightR14RendererSource -PairRendererSource $pair.RendererSource `
    -PreflightSource $leaf -BaselineLeafPath $baselinePath -IndexSha256 $indexHash -IndexByteLength $indexBytes.Length
if ((Get-CandidateFileHash $indexPath) -cne $indexHash) { throw 'Raw index changed during preparation.' }
$outputRoot = Join-Path $RepoRoot ".checks/c1b-candidate-source/$short"
if ([IO.Directory]::Exists($outputRoot) -or [IO.File]::Exists($outputRoot)) {
    throw 'Review output already exists; never overwrite a prior preparation.'
}
$parent = [IO.Path]::GetDirectoryName($outputRoot)
while (-not [IO.Directory]::Exists($parent)) { $parent = [IO.Path]::GetDirectoryName($parent) }
$cursor = $parent
while (-not [string]::IsNullOrEmpty($cursor)) {
    if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Review output parent contains a reparse path.'
    }
    $cursor = [IO.Path]::GetDirectoryName($cursor)
}
[void][IO.Directory]::CreateDirectory($outputRoot)
$outputs = [ordered]@{
    "render-final-r12-$short.ps1"=$pair.RendererSource
    "render-preflight-r14-$short.ps1"=$renderer
    "helper-$short-r11.expected.ps1"=$pair.HelperSource
    "launcher-$short-r11.expected.ps1"=$pair.LauncherSource
    "preflight-$short-r14.expected.ps1"=$leaf
}
$records = [Collections.Generic.List[object]]::new()
foreach ($name in $outputs.Keys) {
    $bytes = [Text.UTF8Encoding]::new($false,$true).GetBytes($outputs[$name])
    $path = Join-Path $outputRoot $name
    $stream = [IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    $records.Add([pscustomobject]@{name=$name; byte_length=$bytes.Length; sha256=(Get-C1bCandidateSourceHash $outputs[$name])})
}
[pscustomobject]@{
    schema='tablet-layout-c1b-review-source/v1'; commit_sha=$CommitSha
    output_directory=$outputRoot; files=$records.ToArray(); source_derivation_only=$true
    clean_sha_verified=$false; artifacts_published=$false; preflight_executed=$false
    helper_or_launcher_executed=$false; git_or_build_or_adb_executed=$false
} | ConvertTo-Json -Depth 5
