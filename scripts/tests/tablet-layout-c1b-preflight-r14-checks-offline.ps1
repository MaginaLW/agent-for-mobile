#Requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
if (-not $IsWindows) { throw 'r14 nofollow identity tests require Windows.' }
. (Join-Path $PSScriptRoot '../lib/tablet-layout-c1b-preflight-r14-checks.ps1')

# Synthetic harness only: no frozen leaf, Git, build, ADB or launcher invocation.
# Use genuine Windows handles and identities without importing a runnable leaf.
if ($null -ne ('TL1C1bPreparedNotAuthorizedFileIdentityV1' -as [type])) {
    throw 'Run this synthetic test in a fresh PowerShell process.'
}
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class TL1C1bPreparedNotAuthorizedFileIdentityV1 {
    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime { public uint Low; public uint High; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Info {
        public uint Attributes;
        public FileTime Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    public sealed class Identity {
        public uint LinkCount, FileAttributes;
        public ulong FileSize;
        public long LastWriteTimeUtcFileTime;
        public string StableId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access,
        uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,
        StringBuilder path, uint length, uint flags);
    private static SafeFileHandle Open(string path, uint access, uint share, uint flags) {
        SafeFileHandle handle = CreateFileW(path, access, share, IntPtr.Zero, 3, flags, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error(); handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }
    public static SafeFileHandle OpenDirectoryDenyDelete(string path) {
        return Open(path, 0x80, 3, 0x02200000);
    }
    public static SafeFileHandle OpenDirectoryDenyWriteDelete(string path) {
        return Open(path, 0x81, 1, 0x02200000);
    }
    public static SafeFileHandle OpenFileReadNoFollowDenyWriteDelete(string path) {
        return Open(path, 0x80000000, 1, 0x08200080);
    }
    public static Identity Read(SafeFileHandle handle) {
        Info info;
        if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return new Identity {
            LinkCount = info.Links, FileAttributes = info.Attributes,
            FileSize = ((ulong)info.SizeHigh << 32) | info.SizeLow,
            LastWriteTimeUtcFileTime = unchecked((long)(((ulong)info.Write.High << 32) | info.Write.Low)),
            StableId = ((ulong)info.Volume).ToString("X16") + ":" +
                (((ulong)info.IndexHigh << 32) | info.IndexLow).ToString("X32")
        };
    }
    public static string GetFinalDosPath(SafeFileHandle handle) {
        StringBuilder path = new StringBuilder(32768);
        uint result = GetFinalPathNameByHandleW(handle, path, (uint)path.Capacity, 0);
        if (result == 0 || result >= path.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
        return path.ToString();
    }
}
'@

$script:checks = 0
$script:cleanupFailures = 0
function Assert-Preflight {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function Assert-Identity {
    param($Identity, [bool]$ExpectedDirectory, [string]$Label, [bool]$RequireSingleLink)
    Assert-Preflight (
        ($Identity.FileAttributes -band [uint32][IO.FileAttributes]::ReparsePoint) -eq 0 -and
        (($Identity.FileAttributes -band [uint32][IO.FileAttributes]::Directory) -ne 0) -eq $ExpectedDirectory -and
        $Identity.LinkCount -ge 1 -and
        (-not $RequireSingleLink -or $Identity.LinkCount -eq 1) -and
        $Identity.StableId -cmatch '\A[0-9A-F]{16}:[0-9A-F]{32}\z'
    ) "$Label identity is not ordinary."
}
function Assert-FinalPath {
    param($Handle, [string]$ExpectedPath, [string]$Label)
    $actual = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::GetFinalDosPath($Handle)
    if ($actual.StartsWith('\\?\', [StringComparison]::Ordinal)) { $actual = $actual.Substring(4) }
    Assert-Preflight ([StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath($actual).TrimEnd('\'),
        [IO.Path]::GetFullPath($ExpectedPath).TrimEnd('\'))) "$Label final path differs."
}
function Open-DirectoryChain {
    param([string]$Path, [string]$Label)
    $paths = [Collections.Generic.List[string]]::new()
    $cursor = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $cursor) { $paths.Add($cursor.FullName); $cursor = $cursor.Parent }
    $entries = [Collections.Generic.List[object]]::new()
    $handle = $null
    try {
        for ($index = $paths.Count - 1; $index -ge 0; $index--) {
            $handle = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::OpenDirectoryDenyDelete($paths[$index])
            $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($handle)
            Assert-Identity $identity $true $Label $true
            Assert-FinalPath $handle $paths[$index] $Label
            $entries.Add([pscustomobject]@{ Handle = $handle; Identity = $identity })
            $handle = $null
        }
        return [pscustomobject]@{ Entries = $entries }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        foreach ($entry in $entries) { $entry.Handle.Dispose() }
        throw
    }
}
function Complete-PrePublicationLocalFailure {
    param([string]$Context, $Primary, [System.Exception[]]$CleanupFailures = @())
    $script:cleanupFailures += $CleanupFailures.Count
    if ($CleanupFailures.Count -ne 0) { throw [AggregateException]::new($Context, $CleanupFailures) }
    if ($null -ne $Primary) { throw $Primary }
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$ExpectedMessage)
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert-Preflight ($null -ne $failure -and $failure.Exception.Message.Contains($ExpectedMessage)) (
        "Expected rejection was not observed: $ExpectedMessage")
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scratch = Join-Path $repoRoot ('.checks/c1b-preflight-r14-' + [guid]::NewGuid().ToString('N'))
$treeRoot = Join-Path $scratch 'tree'
$subdirectory = Join-Path $treeRoot 'sub'
$emptyPath = Join-Path $treeRoot 'empty.bin'
$dataPath = Join-Path $subdirectory 'data.bin'
$aliasPath = Join-Path $treeRoot 'alias.bin'
$outsideAlias = Join-Path $scratch 'outside-alias.bin'
$extraPath = Join-Path $treeRoot 'extra.bin'
$replacement = Join-Path $scratch 'replacement.bin'
$junction = Join-Path $treeRoot 'junction'
$junctionTarget = Join-Path $scratch 'junction-target'
$payload = [byte[]]@(0, 1, 2, 128, 255)
[void][IO.Directory]::CreateDirectory($subdirectory)
[void][IO.Directory]::CreateDirectory($junctionTarget)
try {
    [IO.File]::WriteAllBytes($emptyPath, [byte[]]::new(0))
    [IO.File]::WriteAllBytes($dataPath, $payload)
    $null = New-Item -ItemType HardLink -Path $aliasPath -Target $dataPath
    $catalogLines = [Collections.Generic.List[string]]::new()
    foreach ($relative in @('alias.bin', 'empty.bin', 'sub/data.bin')) {
        $sha = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [IO.File]::ReadAllBytes((Join-Path $treeRoot $relative)))).ToLowerInvariant()
        $catalogLines.Add("$relative=$sha")
    }
    $expectedCatalog = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false).GetBytes($catalogLines -join "`n"))).ToLowerInvariant()
    $snapshotParameters = @{
        Root = $treeRoot; ExpectedFileCount = 3; ExpectedCatalogSha256 = $expectedCatalog
        ExpectedIdentityCount = 2; ExpectedInternalHardlinkGroupCount = 1
    }
    $before = Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'before'
    $after = Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'after'
    Assert-TL1C1bPreflightGitTreeContinuity $before $after
    Assert-Preflight ($before.CleanupCompleted -and $after.CleanupCompleted) 'Success cleanup was not verified.'

    $null = New-Item -ItemType HardLink -Path $outsideAlias -Target $dataPath
    Assert-Rejected { Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'outside-link' } 'hardlinks must close entirely'
    [IO.File]::Delete($outsideAlias)
    [IO.File]::WriteAllBytes($extraPath, [byte[]]@(1))
    Assert-Rejected { Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'extra-file' } 'more files than the frozen count'
    [IO.File]::Delete($extraPath)
    [IO.File]::WriteAllBytes($dataPath, [byte[]]@(255))
    Assert-Rejected { Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'changed-bytes' } 'catalog SHA-256 differs'
    [IO.File]::WriteAllBytes($dataPath, $payload)
    $snapshotParameters.ExpectedIdentityCount = 3
    Assert-Rejected { Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'wrong-topology' } 'identity or internal hardlink group count'
    $snapshotParameters.ExpectedIdentityCount = 2
    $null = New-Item -ItemType Junction -Path $junction -Target $junctionTarget
    Assert-Rejected { Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'junction' } 'reparse point'
    [IO.Directory]::Delete($junction, $false)

    $before = Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'before-replacement'
    [IO.File]::WriteAllBytes($replacement, [byte[]]::new(0))
    [IO.File]::Move($replacement, $emptyPath, $true)
    $after = Get-TL1C1bPreflightGitTreeSnapshot @snapshotParameters -Stage 'after-replacement'
    Assert-Rejected { Assert-TL1C1bPreflightGitTreeContinuity $before $after } 'continuity drifted'

    $tokens = $null; $errors = $null
    $goodAst = [Management.Automation.Language.Parser]::ParseInput(
        'function Read-LauncherHeldFileBytes { return ,$bytes }', [ref]$tokens, [ref]$errors)
    $canary = Assert-TL1C1bPreflightLauncherByteReturn $goodAst
    Assert-Preflight ($canary.case_count -eq 3 -and $canary.cleanup_completed) 'Canary coverage or cleanup drifted.'
    foreach ($badReturn in @('return $bytes', 'return ,$other', 'return @($bytes)', 'return ,$bytes; return ,$bytes')) {
        $badAst = [Management.Automation.Language.Parser]::ParseInput(
            ('function Read-LauncherHeldFileBytes { ' + $badReturn + ' }'), [ref]$tokens, [ref]$errors)
        Assert-Rejected { Assert-TL1C1bPreflightLauncherByteReturn $badAst } 'Launcher held-byte'
    }

    # Text-only launcher fixture: parsed by the stream contract, never invoked.
    $bootstrapFixture = @'
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$gate = $null
'@
    $streamFixturePattern = @'
$childBootstrapSource = '__BOOTSTRAP__'
$captureCapBytes = 1048576L
$stdoutDrainTask = [TL1C1bNextLauncherNativeV1]::DrainAsync(
    $process.StandardOutput.BaseStream, [int]$captureCapBytes)
$stderrDrainTask = [TL1C1bNextLauncherNativeV1]::DrainAsync(
    $process.StandardError.BaseStream, [int]$captureCapBytes)
if ($stderrResult.Overflowed -or
    [long]$stderrResult.TotalByteLength -ne 0L -or
    $stderrResult.CapturedBytes.Length -ne 0) {
    throw 'Helper stderr was not byte-empty for a passed summary.'
}
$logValue = [pscustomobject][ordered]@{
    stderr = if ($null -eq $stderrResult) { $null } else {
        [pscustomobject][ordered]@{
            total_byte_length = [long]$stderrResult.TotalByteLength
            captured_byte_length = [long]$stderrResult.CapturedBytes.Length
            sha256 = 'sha256:' + [string]$stderrResult.Sha256
            overflowed = [bool]$stderrResult.Overflowed
            forced_closed = [bool]$stderrForcedClosed
            captured_prefix_base64 = [Convert]::ToBase64String($stderrResult.CapturedBytes)
            captured_prefix_sha256 = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrResult.CapturedBytes)).ToLowerInvariant()
            captured_prefix_byte_length = [long]$stderrResult.CapturedBytes.Length
            capture_is_prefix = $true
            uncaptured_byte_length = [long]$stderrResult.TotalByteLength - [long]$stderrResult.CapturedBytes.Length
        }
    }
}
foreach ($buffer in @(
    $summaryBytes, $expectedStdoutBytes,
    $(if ($null -eq $stdoutResult) { $null } else { ,$stdoutResult.CapturedBytes }),
    $(if ($null -eq $stderrResult) { $null } else { ,$stderrResult.CapturedBytes }))) {
    if ($null -ne $buffer -and $buffer.Length -ne 0) {
        try { [Array]::Clear($buffer, 0, $buffer.Length) }
        catch { throw }
    }
}
'@
    $makeStreamFixture = {
        param([string]$Bootstrap)
        return $streamFixturePattern.Replace('__BOOTSTRAP__', $Bootstrap.Replace("'", "''"))
    }
    $streamFixture = & $makeStreamFixture $bootstrapFixture
    $streamAst = [Management.Automation.Language.Parser]::ParseInput(
        $streamFixture, [ref]$tokens, [ref]$errors)
    Assert-Preflight ($errors.Count -eq 0) 'Stream-contract fixture did not parse.'
    $streamEvidence = Assert-TL1C1bPreflightLauncherStreamContract $streamAst
    Assert-Preflight (
        $streamEvidence.progress_suppressed_before_bootstrap -and
        $streamEvidence.error_action_stop_preserved -and
        $streamEvidence.diagnostic_prefix_bound -and
        $streamEvidence.diagnostic_prefix_cap_bytes -eq 1048576L -and
        $streamEvidence.empty_stderr_gate_preserved -and
        $streamEvidence.captured_array_cleanup_reference_shape_verified -and
        $streamEvidence.captured_array_unary_comma_cleanup_count -eq 2L -and
        $streamEvidence.original_buffer_clear_preserved -and
        $streamEvidence.launcher_invocation_count -eq 0L -and
        $streamEvidence.bootstrap_invocation_count -eq 0L
    ) 'Stream-contract positive evidence drifted.'
    $streamMutations = [Collections.Generic.List[string]]::new()
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture.Replace(
        '$ProgressPreference = ''SilentlyContinue''', '$unused = ''SilentlyContinue'''))))
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture.Replace(
        '$ProgressPreference = ''SilentlyContinue''', '$ErrorActionPreference = ''Stop''').Replace(
        '$ErrorActionPreference = ''Stop''' + "`n" + 'Set-StrictMode',
        '$ProgressPreference = ''SilentlyContinue''' + "`n" + 'Set-StrictMode'))))
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture + "`n" + '$script:ProgressPreference = ''Continue''')))
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture.Replace("'Stop'", "'Continue'"))))
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture + "`n" + 'Write-Output 1 2>$null')))
    $streamMutations.Add((& $makeStreamFixture ($bootstrapFixture + "`n" + 'Set-Variable ProgressPreference Continue')))
    $streamMutations.Add($streamFixture.Replace(
        '[Convert]::ToBase64String($stderrResult.CapturedBytes)',
        '[Convert]::ToBase64String($stdoutResult.CapturedBytes)'))
    $streamMutations.Add($streamFixture.Replace(
        '[Security.Cryptography.SHA256]::HashData($stderrResult.CapturedBytes)',
        '[Security.Cryptography.SHA256]::HashData($stdoutResult.CapturedBytes)'))
    $streamMutations.Add($streamFixture.Replace(
        'captured_prefix_byte_length = [long]$stderrResult.CapturedBytes.Length',
        'captured_prefix_byte_length = [long]$stderrResult.TotalByteLength'))
    $streamMutations.Add($streamFixture.Replace('capture_is_prefix = $true', 'capture_is_prefix = $false'))
    $streamMutations.Add($streamFixture.Replace(
        'uncaptured_byte_length = [long]$stderrResult.TotalByteLength - [long]$stderrResult.CapturedBytes.Length',
        'uncaptured_byte_length = [long]$stderrResult.TotalByteLength + [long]$stderrResult.CapturedBytes.Length'))
    $streamMutations.Add($streamFixture.Replace('$captureCapBytes = 1048576L', '$captureCapBytes = 2097152L'))
    $streamMutations.Add($streamFixture.Replace(
        '$process.StandardError.BaseStream, [int]$captureCapBytes',
        '$process.StandardError.BaseStream, 1048576'))
    $streamMutations.Add($streamFixture.Replace(
        '$stderrResult.CapturedBytes.Length -ne 0)', '$stderrResult.CapturedBytes.Length -gt 0)'))
    $streamMutations.Add($streamFixture.Replace('captured_byte_length =', 'renamed_captured_byte_length ='))
    $streamMutations.Add($streamFixture.Replace(
        "captured_prefix_sha256 = 'sha256:'", "captured_prefix_sha256 = 'sha 256:'"))
    $streamMutations.Add($streamFixture.Replace(
        'else { ,$stdoutResult.CapturedBytes }', 'else { $stdoutResult.CapturedBytes }'))
    $streamMutations.Add($streamFixture.Replace(
        'else { ,$stderrResult.CapturedBytes }', 'else { $stderrResult.CapturedBytes }'))
    foreach ($mutatedSource in $streamMutations) {
        $mutatedAst = [Management.Automation.Language.Parser]::ParseInput(
            $mutatedSource, [ref]$tokens, [ref]$errors)
        Assert-Preflight ($errors.Count -eq 0) 'Stream-contract mutation did not parse.'
        Assert-Rejected { Assert-TL1C1bPreflightLauncherStreamContract $mutatedAst } 'Launcher stream contract'
    }
    Assert-Preflight ($script:cleanupFailures -eq 0) 'Synthetic resource cleanup failed.'
    [pscustomobject][ordered]@{
        status = 'passed'
        synthetic_only = $true
        frozen_script_invocation_count = 0
        external_process_invocation_count = 0
        snapshot_files = 3
        snapshot_identities = 2
        snapshot_internal_hardlink_groups = 1
        mutation_rejection_cases = 10 + $streamMutations.Count
        stream_contract_mutation_rejection_cases = $streamMutations.Count
        stream_contract_static_only = $true
        byte_canary_lengths = @(0, 1, 5)
        cleanup_failure_count = $script:cleanupFailures
        assertion_count = $script:checks
    } | ConvertTo-Json -Depth 5 -Compress
} finally {
    # Only this test's exact known entries are removed; unknown entries fail the
    # final non-recursive directory removal and remain available for diagnosis.
    if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) }
    foreach ($path in @($outsideAlias, $extraPath, $replacement, $aliasPath, $dataPath, $emptyPath)) {
        [IO.File]::Delete($path)
    }
    foreach ($path in @($junctionTarget, $subdirectory, $treeRoot, $scratch)) {
        if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path, $false) }
    }
}
