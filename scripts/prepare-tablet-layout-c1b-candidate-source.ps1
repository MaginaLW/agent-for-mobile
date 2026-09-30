#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StagingRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CommitSha,
    [Parameter(Mandatory)][string]$PwshPath,
    [Parameter(Mandatory)][string]$GitPath,
    [string]$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-candidate-source.ps1')

# 此入口只写 gitignored review drafts。不能据此声称 clean SHA/preflight/build 已验收。
function Read-CandidateInput {
    param([string]$Path, [switch]$Bytes,
        [ValidateRange(1,16777216)][long]$MaximumLength = 4194304L)
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
        if ($stream.Length -gt $MaximumLength) { throw 'Candidate input exceeds its bounded length.' }
        $data = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($data)
        if ($stream.ReadByte() -ne -1) { throw 'Candidate input length changed.' }
        if ($Bytes) { return ,$data }
        return [Text.UTF8Encoding]::new($false,$true).GetString($data)
    }
    finally { $stream.Dispose() }
}
function Get-CandidateFileHash {
    param([string]$Path, [ValidateRange(1,16777216)][long]$MaximumLength = 4194304L)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        (Read-CandidateInput $Path -Bytes -MaximumLength $MaximumLength))).ToLowerInvariant()
}

function Get-CandidateRepositoryLibraryHashes {
    param([Parameter(Mandatory)][string]$Root)
    $hashes=[ordered]@{}
    foreach($entry in (Get-C1bHelperLibraryPaths).GetEnumerator()){
        # 绑定最终候选 checkout 的原始字节，不通过文本读取/换行归一计算。
        $hashes[$entry.Key]='sha256:'+(Get-CandidateFileHash (Join-Path $Root $entry.Value))
    }
    Assert-C1bHelperLibraryHashes $hashes
    return $hashes
}

Assert-C1bCandidateGitPath $GitPath
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$StagingRoot = [IO.Path]::GetFullPath($StagingRoot)
$PwshPath = [IO.Path]::GetFullPath($PwshPath)
$GitPath = [IO.Path]::GetFullPath($GitPath)
$transformPath = Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-candidate-source.ps1'
$sourceRoot = Join-Path $PSScriptRoot 'lib/c1b-candidate-source'
$short = $CommitSha.Substring(0,7)
if ((Get-CandidateFileHash $PwshPath) -cne
    '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139' -or
    [Environment]::ProcessPath -ine $PwshPath -or $PSVersionTable.PSVersion.ToString() -cne '7.6.5') {
    throw 'Preparation must run under the exact pinned PowerShell 7.6.5.'
}
$utility = [IO.Path]::Combine([IO.Path]::GetDirectoryName($PwshPath),'Microsoft.PowerShell.Commands.Utility.dll')
$utilityBytes = Read-CandidateInput $utility -Bytes
$rendererTemplatePath = Join-Path $sourceRoot 'renderer-template.ps1'
$helperTemplatePath = Join-Path $sourceRoot 'helper-template.ps1'
$launcherTemplatePath = Join-Path $sourceRoot 'launcher-template.ps1'
$preflightTemplatePath = Join-Path $sourceRoot 'preflight-template.ps1'
$checksPath = Join-Path $PSScriptRoot 'lib/tablet-layout-c1b-preflight-r14-checks.ps1'
$verifierPath = Join-Path $RepoRoot 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
$rendererTemplate = Read-CandidateInput $rendererTemplatePath
$helperTemplate = Read-CandidateInput $helperTemplatePath
$launcherTemplate = Read-CandidateInput $launcherTemplatePath
$preflightTemplate = Read-CandidateInput $preflightTemplatePath
$checksSource = Read-CandidateInput $checksPath
$sourceInputs = @(
    [pscustomobject]@{path='scripts/prepare-tablet-layout-c1b-candidate-source.ps1';full=$PSCommandPath;sha256=(Get-CandidateFileHash $PSCommandPath)}
    [pscustomobject]@{path='scripts/lib/tablet-layout-c1b-candidate-source.ps1';full=$transformPath;sha256=(Get-CandidateFileHash $transformPath)}
    [pscustomobject]@{path='scripts/lib/c1b-candidate-source/renderer-template.ps1';full=$rendererTemplatePath;sha256=(Get-C1bCandidateSourceHash $rendererTemplate)}
    [pscustomobject]@{path='scripts/lib/c1b-candidate-source/helper-template.ps1';full=$helperTemplatePath;sha256=(Get-C1bCandidateSourceHash $helperTemplate)}
    [pscustomobject]@{path='scripts/lib/c1b-candidate-source/launcher-template.ps1';full=$launcherTemplatePath;sha256=(Get-C1bCandidateSourceHash $launcherTemplate)}
    [pscustomobject]@{path='scripts/lib/c1b-candidate-source/preflight-template.ps1';full=$preflightTemplatePath;sha256=(Get-C1bCandidateSourceHash $preflightTemplate)}
    [pscustomobject]@{path='scripts/lib/tablet-layout-c1b-preflight-r14-checks.ps1';full=$checksPath;sha256=(Get-C1bCandidateSourceHash $checksSource)}
)
$repositoryLibraryHashes = Get-CandidateRepositoryLibraryHashes $RepoRoot
foreach ($entry in (Get-C1bHelperLibraryPaths).GetEnumerator()) {
    $sourceInputs += [pscustomobject]@{
        path=$entry.Value; full=(Join-Path $RepoRoot $entry.Value)
        sha256=([string]$repositoryLibraryHashes[$entry.Key]).Substring(7)
    }
}
$pair = New-C1bExactPairCandidateSource `
    -BaselineRendererSource $rendererTemplate `
    -HelperTemplateSource $helperTemplate `
    -LauncherTemplateSource $launcherTemplate `
    -CommitSha $CommitSha -RepoRoot $RepoRoot -StagingRoot $StagingRoot -PwshPath $PwshPath `
    -RepositoryLibraryHashes $repositoryLibraryHashes `
    -VerifierSha256 (Get-CandidateFileHash $verifierPath) `
    -UtilityAssemblySha256 (Get-CandidateFileHash $utility) -UtilityAssemblyLength $utilityBytes.Length
$indexPath = Join-Path $RepoRoot '.git/index'
$indexBytes = Read-CandidateInput $indexPath -Bytes
if ($indexBytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($indexBytes,0,4) -cne 'DIRC') {
    throw 'Repository index is not an ordinary Git index.'
}
$entryCount = [long]$indexBytes[8]*16777216L + [long]$indexBytes[9]*65536L +
    [long]$indexBytes[10]*256L + [long]$indexBytes[11]
$indexHash = Get-CandidateFileHash $indexPath
$headPath = Join-Path $RepoRoot '.git/HEAD'
$headText = Read-CandidateInput $headPath
$headHash = Get-C1bCandidateSourceHash $headText
$headMatch = [regex]::Match($headText,
    '\Aref: refs/heads/(?<branch>[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*)\r?\n\z')
if (-not $headMatch.Success) {
    throw 'Repository HEAD is not an ordinary loose branch ref.'
}
$branch = $headMatch.Groups['branch'].Value
$constants = [ordered]@{
    repoRoot=$RepoRoot; stagingRoot=$StagingRoot; expectedBranch=$branch
    expectedCommitSha=$CommitSha; expectedCommitShort=$short
    helperPath=(Join-Path $StagingRoot "helper-$short-r11.ps1")
    expectedHelperSha256=$pair.HelperSha256; expectedHelperByteLength=$pair.HelperByteLength
    launcherPath=(Join-Path $StagingRoot "launcher-$short-r11.ps1")
    expectedLauncherSha256=$pair.LauncherSha256; expectedLauncherByteLength=$pair.LauncherByteLength
    expectedLauncherTemplateSha256=$pair.LauncherTemplateSha256
    failureSidecarPath=(Join-Path $StagingRoot "launcher-$short-r11.failure.json")
    pwshPath=$PwshPath; expectedPwshSha256=(Get-CandidateFileHash $PwshPath)
    gitPath=$GitPath; expectedGitSha256=(Get-CandidateFileHash $GitPath -MaximumLength 16777216L)
    expectedGitIndexSha256=$indexHash; expectedGitTrackedPathCount=$entryCount
    expectedGitConfigSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.git/config'))
    expectedGitAttributesSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.gitattributes'))
    expectedGitIgnoreSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.gitignore'))
    expectedGitInfoExcludeSha256=(Get-CandidateFileHash (Join-Path $RepoRoot '.git/info/exclude'))
    expectedVerifierSha256=(Get-CandidateFileHash $verifierPath)
    summaryLeaf="tablet-c1b-real-build-smoke-$short.summary.json"
    logLeaf="tablet-c1b-real-build-smoke-$short.log"
    launcherResultLeaf="tablet-c1b-real-build-smoke-$short.launcher.json"
    receiptLeaf="preflight-$short-r14.prepared-not-authorized.receipt.json"
}
$leaf = New-C1bPreflightR14CandidateSource -BaselineLeafSource $preflightTemplate `
    -ChecksSource $checksSource `
    -Constants $constants
$renderer = New-C1bPreflightR14RendererSource -PairRendererSource $pair.RendererSource `
    -PreflightSource $leaf -BaselineLeafPath $preflightTemplatePath `
    -BaselineLeafSha256 (Get-C1bCandidateSourceHash $preflightTemplate) `
    -BaselineLeafByteLength ([Text.UTF8Encoding]::new($false,$true).GetByteCount($preflightTemplate)) `
    -IndexSha256 $indexHash -IndexByteLength $indexBytes.Length
if ((Get-CandidateFileHash $indexPath) -cne $indexHash) { throw 'Raw index changed during preparation.' }
if ((Get-CandidateFileHash $headPath) -cne $headHash) { throw 'Repository HEAD changed during preparation.' }
foreach ($sourceInput in $sourceInputs) {
    if ((Get-CandidateFileHash $sourceInput.full) -cne $sourceInput.sha256) {
        throw "Maintained source changed during preparation: $($sourceInput.path)"
    }
}
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
    source_inputs=@($sourceInputs | ForEach-Object {
        [pscustomobject]@{path=$_.path;sha256=$_.sha256}
    })
    repository_library_hashes=$repositoryLibraryHashes
    clean_sha_verified=$false; artifacts_published=$false; preflight_executed=$false
    helper_or_launcher_executed=$false; git_or_build_or_adb_executed=$false
} | ConvertTo-Json -Depth 5
