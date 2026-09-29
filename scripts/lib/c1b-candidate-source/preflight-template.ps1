#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Microsoft.PowerShell.Core\Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

# This inspector never dot-sources or invokes the launcher, helper, or verifier.
# It holds and hashes their bytes, then supplies those bytes only to ParseInput.
$repoRoot = '__BINDING__'
$expectedBranch = '__BINDING__'
$expectedCommitSha = '__BINDING__'
$expectedCommitShort = '__BINDING__'
$helperPath = '__BINDING__'
$expectedHelperSha256 = '__BINDING__'
$launcherPath = '__BINDING__'
$expectedLauncherSha256 = '__BINDING__'
$expectedLauncherTemplateSha256 =
    '__BINDING__'
$expectedHelperByteLength = 0L
$expectedLauncherByteLength = 0L
$failureSidecarPath = '__BINDING__'
$verifierRelativePath = 'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1'
$verifierPath = [IO.Path]::Combine($repoRoot, $verifierRelativePath)
$expectedVerifierSha256 = '__BINDING__'
$pwshPath = '__BINDING__'
$expectedPwshSha256 = '__BINDING__'
$stagingRoot = '__BINDING__'
$outputRoot = [IO.Path]::Combine($repoRoot, '.checks')
$moduleBuildParentPath = [IO.Path]::Combine(
    $repoRoot, 'app\tablet-c1b-probe')
$moduleBuildPath = [IO.Path]::Combine($moduleBuildParentPath, 'build')
$summaryLeaf = '__BINDING__'
$logLeaf = '__BINDING__'
$launcherResultLeaf = '__BINDING__'
$summaryPath = [IO.Path]::Combine($outputRoot, $summaryLeaf)
$logPath = [IO.Path]::Combine($outputRoot, $logLeaf)
$launcherResultPath = [IO.Path]::Combine($outputRoot, $launcherResultLeaf)
$gitDirectory = [IO.Path]::Combine($repoRoot, '.git')
$gitConfigPath = [IO.Path]::Combine($gitDirectory, 'config')
$gitHeadPath = [IO.Path]::Combine($gitDirectory, 'HEAD')
$gitIndexPath = [IO.Path]::Combine($gitDirectory, 'index')
$gitRefPath = [IO.Path]::Combine(
    $gitDirectory, 'refs', 'heads', $expectedBranch.Replace('/', [IO.Path]::DirectorySeparatorChar))
$gitInfoPath = [IO.Path]::Combine($gitDirectory, 'info')
$gitInfoAttributesPath = [IO.Path]::Combine($gitInfoPath, 'attributes')
$gitInfoExcludePath = [IO.Path]::Combine($gitInfoPath, 'exclude')
$gitAttributesPath = [IO.Path]::Combine($repoRoot, '.gitattributes')
$gitIgnorePath = [IO.Path]::Combine($repoRoot, '.gitignore')
$receiptLeaf =
    '__BINDING__'
$receiptPath = [IO.Path]::Combine($stagingRoot, $receiptLeaf)
$gitPath = '__BINDING__'
$expectedGitSha256 = '__BINDING__'
$expectedGitConfigSha256 = '__BINDING__'
$expectedGitAttributesSha256 = '__BINDING__'
$expectedGitIgnoreSha256 = '__BINDING__'
$expectedGitInfoExcludeSha256 = '__BINDING__'
$expectedGitIndexSha256 = '__BINDING__'
$expectedGitTrackedPathCount = 0L

$helperDeadlineMilliseconds = 2700000L
$helperKillWaitMilliseconds = 30000L
$helperDrainWaitMilliseconds = 30000L
$captureCapBytes = 1048576L
$verifierFunctionNames = [string[]]@(
    'Find-TL1C1bRealBuildSmokeDuplicateJsonProperty',
    'Find-TL1C1bRealBuildSmokeInvalidJsonNumber',
    'Get-TL1C1bRealBuildSmokeSummaryRequiredProperties',
    'Assert-TL1C1bRealBuildSmokeSummaryExactProperties',
    'ConvertFrom-TL1C1bRealBuildSmokeSummaryJson',
    'Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain',
    'Assert-TL1C1bRealBuildSmokeOrdinaryLeaf',
    'Get-TL1C1bRealBuildSmokeHeldFileIdentity',
    'ConvertFrom-TL1C1bRealBuildSmokeFinalDosPath',
    'Assert-TL1C1bRealBuildSmokeHandleFinalPath',
    'Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity',
    'Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld',
    'Assert-TL1C1bRealBuildSmokeHeldFileIdentity',
    'Assert-TL1C1bRealBuildSmokePathMatchesHeldFile',
    'Assert-TL1C1bRealBuildSmokeSummaryValue',
    'Assert-TL1C1bRealBuildSmokeSummaryFile'
)
$helperLibraryKeys = [string[]]@(
    'c1a', 'validator', 'c1b', 'artifact', 'aapt2', 'build', 'runner'
)
$helperDotSourceKeys = [string[]]@(
    'c1a', 'validator', 'c1b', 'artifact', 'aapt2', 'build'
)

$failures = [Collections.Generic.List[string]]::new()
$allFileBindings = [Collections.Generic.List[object]]::new()
$primaryFileBindings = [Collections.Generic.List[object]]::new()
$directoryChains = [Collections.Generic.List[object]]::new()
$receiptDirectoryChain = $null
$outputReceiptDirectoryChain = $null
$outputMutationGuard = $null
$moduleBuildReceiptDirectoryChain = $null
$moduleBuildMutationGuard = $null
$loaderBindings = [Collections.Generic.List[object]]::new()
$volumeEvidence = [Collections.Generic.List[object]]::new()
$outputAbsenceEvidence = [Collections.Generic.List[object]]::new()
$staticCheckCount = 0L
$gitInvocationCount = 0L
$gitBoundedDrainCompletedCount = 0L
$gitCleanupCompletedCount = 0L
$gitInvocationFailureRecordCount = 0L
$gitPrimaryFailureCount = 0L
$gitCleanupFailureCount = 0L
$gitRootExitNotObservedCount = 0L
$gitPendingDrainClosureNotObservedCount = 0L
$gitPendingTaskFaultObserverInstallationAttemptCount = 0L
$gitPendingTaskFaultObserverInstallationCompletedCount = 0L
$gitPrimaryFailureReasons = [Collections.Generic.List[string]]::new()
$gitCleanupFailureReasons = [Collections.Generic.List[string]]::new()
$prePublicationGuardCleanupFailureCount = 0L
$prePublicationGuardCleanupFailureReasons =
    [Collections.Generic.List[string]]::new()
$receiptPublicationCleanupFailureCount = 0L
$receiptPublicationCleanupFailureReasons =
    [Collections.Generic.List[string]]::new()
$prePublicationLocalFailureRecordCount = 0L
$prePublicationLocalPrimaryFailureCount = 0L
$prePublicationLocalCleanupFailureCount = 0L
$prePublicationLocalPrimaryFailureReasons =
    [Collections.Generic.List[string]]::new()
$prePublicationLocalCleanupFailureReasons =
    [Collections.Generic.List[string]]::new()
$gitOperationTimeoutMilliseconds = 30000
$gitCleanupRootExitTimeoutMilliseconds = 30000
$gitCleanupDrainTimeoutMilliseconds = 5000
$gitStdoutByteLimit = 1048576L
$gitReadBufferByteLength = 65536
$gitHead = $null
$gitBranch = $null
$gitStateObservedAtUtc = $null
$gitTrackedPathCount = 0L
$gitIndexFlagsVerified = $false
$gitSubmodulesAbsent = $false
$gitIsolationVerified = $false
$gitInfoAttributesAbsentVerified = $false
$gitInfoAttributesAbsentBeforeFinalGit = $false
$gitInfoAttributesAbsentAfterFinalGit = $false
$gitInfoAttributesAbsentAtStaticEnd = $false
$gitHeadBinding = $null
$gitRefBinding = $null
$gitConfigBinding = $null
$gitAttributesBinding = $null
$gitIgnoreBinding = $null
$gitInfoExcludeBinding = $null
$gitIndexBinding = $null
$worktreeClean = $false
$outputAbsenceObservedAtUtc = $null
$temporaryPrefixesAbsent = $false
$runtimePwshPathMatchesHeldPath = $false
$preflightBuiltinBindingsVerified = $false
$guardCleanupCompleted = $false
$primaryObjectsHeldThroughStaticInspection = $false
$primaryObjectGuardsReleasedBeforeReceiptPublication = $false
$receiptParentHeldDuringCreate = $false
$outputParentHeldDuringCreate = $false
$launcherEvidence = $null
$verifierEvidence = $null
$helperEvidence = $null
$childItemParameters = $null
$failureSidecarAbsentAtInitialObservation = $false
$failureSidecarAbsentAtStaticInspectionEnd = $false
$failureSidecarAbsentAtFinalPreReceiptObservation = $false
$moduleBuildAbsentAtInitialObservation = $false
$moduleBuildAbsentBeforeGuardRelease = $false
$moduleBuildAbsentAtFinalPreReceiptObservation = $false
$moduleBuildParentHeldDuringReceiptCreate = $false
$launcherTemplateReconstructionVerified = $false
$launcherOptionalExpectedShaGuardsVerified = $false
$launcherHeldFileContinuityVerified = $false
$launcherFileIdentityNoReparseGateVerified = $false
$launcherSummaryUnpinnedShaOpenVerified = $false
$passiveHostAdbStateSnapshots = [Collections.Generic.List[object]]::new()
$passiveHostAdbStateSnapshotAttemptCount = 0L
$passiveHostAdbProcessObservationAttemptCount = 0L
$passiveHostAdbProcessObservationAvailableCount = 0L
$passiveHostAdbProcessZeroCount = 0L
$passiveHostAdbProcessObjectObservedCount = 0L
$passiveHostAdbProcessObjectDisposedCount = 0L
$passiveHostTcp5037ListenerObservationAttemptCount = 0L
$passiveHostTcp5037ListenerObservationAvailableCount = 0L
$passiveHostTcp5037ListenerZeroCount = 0L
$passiveHostAdbZeroBoundaryCount = 0L
$passiveHostAdbStateStageOrderVerified = $false
$passiveHostAdbStateAllObservationsAvailable = $false
$passiveHostAdbStateAllObservationsZero = $false

function Assert-Preflight {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    $script:staticCheckCount++
    if (-not $Condition) { throw $Message }
}

function Complete-PrePublicationLocalFailure {
    param(
        [Parameter(Mandatory)][string]$Context,
        [object]$Primary,
        [System.Exception[]]$CleanupFailures = @()
    )
    if ($null -eq $Primary -and $CleanupFailures.Count -eq 0) { return }
    $script:prePublicationLocalFailureRecordCount++
    if ($null -ne $Primary) {
        $script:prePublicationLocalPrimaryFailureCount++
        $script:prePublicationLocalPrimaryFailureReasons.Add(
            [string]$Primary.Exception.ToString())
    }
    if ($CleanupFailures.Count -ne 0) {
        $script:prePublicationLocalCleanupFailureCount +=
            [long]$CleanupFailures.Count
        foreach ($cleanupFailure in $CleanupFailures) {
            $script:prePublicationLocalCleanupFailureReasons.Add(
                [string]$cleanupFailure.ToString())
        }
        $aggregate = [Collections.Generic.List[System.Exception]]::new()
        if ($null -ne $Primary) { $aggregate.Add($Primary.Exception) }
        foreach ($cleanupFailure in $CleanupFailures) {
            $aggregate.Add($cleanupFailure)
        }
        throw [AggregateException]::new(
            "$Context failed and local cleanup did not close cleanly.",
            [System.Exception[]]$aggregate.ToArray())
    }
    throw $Primary
}

function Assert-OrdinalSequence {
    param(
        [Parameter(Mandatory)][string[]]$Actual,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Message
    )
    Assert-Preflight (
        $Actual.Count -eq $Expected.Count -and
        ($Actual -join [Environment]::NewLine) -ceq
            ($Expected -join [Environment]::NewLine)
    ) $Message
}

function Assert-Text {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Needle,
        [Parameter(Mandatory)][string]$Message
    )
    Assert-Preflight (
        $Text.IndexOf($Needle, [StringComparison]::Ordinal) -ge 0
    ) $Message
}

function Get-PassiveHostAdbStateSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('initial','static_inspection_end','final_pre_receipt')]
        [string]$Stage
    )
    $script:passiveHostAdbStateSnapshotAttemptCount++
    $adbProcessObservationAvailable = $false
    $adbProcessCount = $null
    $tcp5037ListenerObservationAvailable = $false
    $tcp5037ListenerCount = $null

    $script:passiveHostAdbProcessObservationAttemptCount++
    $adbProcesses = [Diagnostics.Process[]]@()
    $adbProcessQuerySucceeded = $false
    $adbProcessDisposeSucceeded = $true
    try {
        $adbProcesses = [Diagnostics.Process]::GetProcessesByName('adb')
        if ($null -eq $adbProcesses) {
            throw 'Process.GetProcessesByName returned null.'
        }
        $adbProcessCount = [long]$adbProcesses.Length
        $script:passiveHostAdbProcessObjectObservedCount += $adbProcessCount
        $adbProcessQuerySucceeded = $true
    }
    catch {
        $script:failures.Add(
            "Passive host ADB process observation was unavailable at checkpoint '$Stage': $($_.Exception.ToString())")
    }
    finally {
        foreach ($process in $adbProcesses) {
            if ($null -eq $process) {
                $adbProcessDisposeSucceeded = $false
                $script:failures.Add(
                    "Passive host ADB process cleanup returned null at checkpoint '$Stage'.")
                continue
            }
            try {
                $process.Dispose()
                $script:passiveHostAdbProcessObjectDisposedCount++
            }
            catch {
                $adbProcessDisposeSucceeded = $false
                $script:failures.Add(
                    "Passive host ADB process cleanup was unavailable at checkpoint '$Stage': $($_.Exception.ToString())")
            }
        }
    }
    if ($adbProcessQuerySucceeded -and $adbProcessDisposeSucceeded) {
        $adbProcessObservationAvailable = $true
        $script:passiveHostAdbProcessObservationAvailableCount++
        if ($adbProcessCount -eq 0L) {
            $script:passiveHostAdbProcessZeroCount++
        }
    }

    $script:passiveHostTcp5037ListenerObservationAttemptCount++
    try {
        $ipGlobalProperties =
            [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $activeListeners = $ipGlobalProperties.GetActiveTcpListeners()
        if ($null -eq $activeListeners) {
            throw 'GetActiveTcpListeners returned null.'
        }
        $tcp5037ListenerCount = 0L
        foreach ($listener in $activeListeners) {
            if ([int]$listener.Port -eq 5037) {
                $tcp5037ListenerCount++
            }
        }
        $tcp5037ListenerObservationAvailable = $true
        $script:passiveHostTcp5037ListenerObservationAvailableCount++
        if ($tcp5037ListenerCount -eq 0L) {
            $script:passiveHostTcp5037ListenerZeroCount++
        }
    }
    catch {
        $script:failures.Add(
            "Passive host TCP/5037 listener observation was unavailable at checkpoint '$Stage': $($_.Exception.ToString())")
    }

    if ($adbProcessObservationAvailable -and $adbProcessCount -ne 0L) {
        $script:failures.Add(
            "Passive host ADB process count was nonzero at checkpoint '$Stage'.")
    }
    if ($tcp5037ListenerObservationAvailable -and
        $tcp5037ListenerCount -ne 0L) {
        $script:failures.Add(
            "Passive host TCP/5037 listener count was nonzero at checkpoint '$Stage'.")
    }
    $zeroBoundarySatisfied = [bool](
        $adbProcessObservationAvailable -and
        $tcp5037ListenerObservationAvailable -and
        $adbProcessCount -eq 0L -and
        $tcp5037ListenerCount -eq 0L)
    if ($zeroBoundarySatisfied) {
        $script:passiveHostAdbZeroBoundaryCount++
    }
    return [pscustomobject][ordered]@{
        stage = [string]$Stage
        observed_at_utc = [DateTimeOffset]::UtcNow.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture)
        adb_process_observation_available =
            [bool]$adbProcessObservationAvailable
        adb_process_query_succeeded = [bool]$adbProcessQuerySucceeded
        adb_process_cleanup_succeeded = [bool]$adbProcessDisposeSucceeded
        adb_process_count = if ($adbProcessQuerySucceeded) {
            [long]$adbProcessCount
        } else { $null }
        tcp_5037_listener_observation_available =
            [bool]$tcp5037ListenerObservationAvailable
        tcp_5037_listener_count = if ($tcp5037ListenerObservationAvailable) {
            [long]$tcp5037ListenerCount
        } else { $null }
        zero_boundary_satisfied = [bool]$zeroBoundarySatisfied
    }
}

function ConvertFrom-FinalDosPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::Ordinal)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::Ordinal)) {
        return $Path.Substring(4)
    }
    return $Path
}

if (-not [OperatingSystem]::IsWindows()) {
    throw 'Prepared-not-authorized preflight only supports Windows.'
}
if ($null -ne ('TL1C1bPreparedNotAuthorizedFileIdentityV1' -as [type])) {
    throw 'Preflight native file-identity authority type is already loaded.'
}

$null = Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bPreparedNotAuthorizedFileIdentityV1Result {
    public uint LinkCount { get; set; }
    public uint FileAttributes { get; set; }
    public ulong FileSize { get; set; }
    public long LastWriteTimeUtcFileTime { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bPreparedNotAuthorizedFileIdentityV1 {
    public static void ObserveTaskFault(Task task) {
        if (task == null) throw new ArgumentNullException(nameof(task));
        Task continuation = task.ContinueWith(
            completed => { GC.KeepAlive(completed.Exception); },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously |
                TaskContinuationOptions.OnlyOnFaulted,
            TaskScheduler.Default);
        GC.KeepAlive(continuation);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_128 {
        public ulong LowPart;
        public ulong HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_INFO {
        public ulong VolumeSerialNumber;
        public FILE_ID_128 FileId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file, int fileInformationClass,
        out FILE_ID_INFO information, uint bufferSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file, StringBuilder path, uint characterCount, uint flags);

    public static SafeFileHandle OpenDirectoryDenyDelete(string path) {
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static SafeFileHandle OpenDirectoryDenyWriteDelete(string path) {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, FILE_SHARE_READ,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static SafeFileHandle OpenFileReadNoFollowDenyWriteDelete(string path) {
        const uint GENERIC_READ = 0x80000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint OPEN_EXISTING = 3;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
        SafeFileHandle handle = CreateFileW(
            path, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
                FILE_FLAG_SEQUENTIAL_SCAN,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static bool EntryExistsNoFollow(string path) {
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint FILE_SHARE_DELETE = 0x00000004;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error == 2) return false;
            throw new Win32Exception(error);
        }
        handle.Dispose();
        return true;
    }

    public static string GetFinalDosPath(SafeFileHandle file) {
        const int MAXIMUM_PATH_CHARACTERS = 32768;
        StringBuilder path = new StringBuilder(MAXIMUM_PATH_CHARACTERS);
        uint result = GetFinalPathNameByHandleW(
            file, path, (uint)path.Capacity, 0);
        if (result == 0) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (result >= path.Capacity) {
            throw new InvalidOperationException("Final path exceeds bound.");
        }
        return path.ToString();
    }

    public static TL1C1bPreparedNotAuthorizedFileIdentityV1Result Read(
        SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        const int FileIdInfo = 18;
        FILE_ID_INFO fileIdInformation;
        if (!GetFileInformationByHandleEx(
                file, FileIdInfo, out fileIdInformation,
                (uint)Marshal.SizeOf<FILE_ID_INFO>())) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ulong size = ((ulong)information.FileSizeHigh << 32) |
            information.FileSizeLow;
        ulong write = ((ulong)information.LastWriteTime.High << 32) |
            information.LastWriteTime.Low;
        return new TL1C1bPreparedNotAuthorizedFileIdentityV1Result {
            LinkCount = information.NumberOfLinks,
            FileAttributes = information.FileAttributes,
            FileSize = size,
            LastWriteTimeUtcFileTime = unchecked((long)write),
            StableId = fileIdInformation.VolumeSerialNumber.ToString("X16") + ":" +
                fileIdInformation.FileId.HighPart.ToString("X16") +
                fileIdInformation.FileId.LowPart.ToString("X16")
        };
    }
}
'@

$preflightCommandBindings = @(
    [pscustomobject]@{ Name = 'Join-Path'; Module = 'Microsoft.PowerShell.Management' },
    [pscustomobject]@{ Name = 'Test-Path'; Module = 'Microsoft.PowerShell.Management' },
    [pscustomobject]@{ Name = 'Where-Object'; Module = 'Microsoft.PowerShell.Core' },
    [pscustomobject]@{ Name = 'ForEach-Object'; Module = 'Microsoft.PowerShell.Core' },
    [pscustomobject]@{ Name = 'Sort-Object'; Module = 'Microsoft.PowerShell.Utility' }
)
foreach ($commandBinding in $preflightCommandBindings) {
    $resolvedCommands = @(Microsoft.PowerShell.Core\Get-Command `
        -Name ([string]$commandBinding.Name) -All -ErrorAction Stop)
    Assert-Preflight (
        $resolvedCommands.Count -eq 1 -and
        $resolvedCommands[0].GetType() -eq [Management.Automation.CmdletInfo] -and
        $resolvedCommands[0].Name -ceq [string]$commandBinding.Name -and
        $resolvedCommands[0].ModuleName -ceq [string]$commandBinding.Module
    ) "Preflight builtin command binding is not exact: $($commandBinding.Name)"
}
$preflightBuiltinBindingsVerified = $true

function Get-PathChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$TargetIsDirectory
    )
    $full = [IO.Path]::GetFullPath($Path)
    $directory = if ($TargetIsDirectory) {
        $full.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)
    }
    else { [IO.Path]::GetDirectoryName($full) }
    $root = [IO.Path]::GetPathRoot($directory)
    Assert-Preflight (-not [string]::IsNullOrWhiteSpace($root)) (
        "Path has no rooted volume: $full")
    $result = [Collections.Generic.List[string]]::new()
    $result.Add($root)
    $relative = $directory.Substring($root.Length).Trim(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $current = $root
    if (-not [string]::IsNullOrEmpty($relative)) {
        foreach ($part in $relative.Split(
                [char[]]@(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar),
                [StringSplitOptions]::RemoveEmptyEntries)) {
            Assert-Preflight (
                $part -cne '.' -and $part -cne '..' -and
                -not $part.Contains(':')
            ) "Path chain contains a non-ordinary component: $full"
            $current = Join-Path $current $part
            $result.Add([IO.Path]::GetFullPath($current))
        }
    }
    return [string[]]$result.ToArray()
}

function Assert-Identity {
    param(
        [Parameter(Mandatory)][object]$Identity,
        [Parameter(Mandatory)][bool]$ExpectedDirectory,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$RequireSingleLink
    )
    $reparse = (
        [uint32]$Identity.FileAttributes -band
        [uint32][IO.FileAttributes]::ReparsePoint) -ne 0
    $directory = (
        [uint32]$Identity.FileAttributes -band
        [uint32][IO.FileAttributes]::Directory) -ne 0
    Assert-Preflight (-not $reparse) "$Label is a reparse point."
    Assert-Preflight ($directory -eq $ExpectedDirectory) (
        "$Label directory/file type drifted.")
    Assert-Preflight ([uint32]$Identity.LinkCount -ge 1) (
        "$Label link count is zero.")
    if ($RequireSingleLink) {
        Assert-Preflight ([uint32]$Identity.LinkCount -eq 1) (
            "$Label link count is not exactly one.")
    }
    Assert-Preflight (
        [string]$Identity.StableId -cmatch '\A[0-9A-F]{16}:[0-9A-F]{32}\z'
    ) "$Label stable identity is not canonical."
}

function Assert-FinalPath {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = [IO.Path]::GetFullPath((
        ConvertFrom-FinalDosPath (
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::GetFinalDosPath($Handle)
        )))
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    Assert-Preflight (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            $actual.TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar),
            $expected.TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar))
    ) "$Label final handle path does not equal its expected canonical path."
}

function Open-DirectoryChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    $entries = [Collections.Generic.List[object]]::new()
    $handle = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    try {
        foreach ($entryPath in (Get-PathChain $Path $true)) {
            $handle = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                OpenDirectoryDenyDelete($entryPath)
            $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
                $handle)
            Assert-Identity $identity $true "$Label ancestor $entryPath" $true
            Assert-FinalPath $handle $entryPath "$Label ancestor $entryPath"
            $entries.Add([pscustomobject][ordered]@{
                Path = [IO.Path]::GetFullPath($entryPath)
                Handle = $handle
                Identity = $identity
                Label = $Label
            })
            $handle = $null
        }
        return [pscustomobject][ordered]@{
            Label = $Label
            TargetPath = [IO.Path]::GetFullPath($Path)
            Entries = $entries
        }
    }
    catch {
        $primaryFailure = $_
    }
    if ($null -ne $handle) {
        try { $handle.Dispose() }
        catch {
            $cleanupFailures.Add(
                [InvalidOperationException]::new(
                    "$Label partial ancestor handle cleanup failed.",
                    $_.Exception))
        }
    }
    if ($null -ne $primaryFailure) {
        for ($index = $entries.Count - 1; $index -ge 0; $index--) {
            try { $entries[$index].Handle.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        "$Label acquired ancestor cleanup failed.",
                        $_.Exception))
            }
        }
        Complete-PrePublicationLocalFailure (
            "$Label directory-chain acquisition") $primaryFailure (
                [System.Exception[]]$cleanupFailures.ToArray())
    }
}

function Open-HeldFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')]
        [string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$ReadUtf8Text,
        [Parameter(Mandatory)][bool]$RequireSingleLink
    )
    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($Path) -and
        $Path -cmatch '\A[A-Za-z]:\\' -and
        -not $Path.Substring(2).Contains(':')
    ) (
        "$Label path is not absolute.")
    $full = [IO.Path]::GetFullPath($Path)
    $chain = Open-DirectoryChain ([IO.Path]::GetDirectoryName($full)) (
        "$Label parent")
    $handle = $null
    $stream = $null
    $bytes = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    try {
        $handle = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
            OpenFileReadNoFollowDenyWriteDelete($full)
        $identity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($handle)
        Assert-Identity $identity $false $Label $RequireSingleLink
        Assert-FinalPath $handle $full $Label
        $stream = [IO.FileStream]::new(
            $handle, [IO.FileAccess]::Read, 65536, $false)
        $handle = $null
        $length = [long]$stream.Length
        Assert-Preflight (
            $length -gt 0L -and
            [uint64]$identity.FileSize -eq [uint64]$length
        ) "$Label held length is invalid."
        $sha = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
        Assert-Preflight ($sha -ceq $ExpectedSha256) (
            "$Label SHA-256 differs from its frozen expected SHA-256.")
        $text = $null
        if ($ReadUtf8Text) {
            Assert-Preflight (
                $length -le 2097152L -and $length -le [int]::MaxValue
            ) "$Label exceeds the two-MiB static text bound."
            $stream.Position = 0L
            $bytes = [byte[]]::new([int]$length)
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
                if ($read -le 0) { throw "$Label byte read ended early." }
                $offset += $read
            }
            Assert-Preflight ($stream.ReadByte() -eq -1) (
                "$Label grew during its held-byte read.")
            Assert-Preflight (
                -not ($bytes.Length -ge 3 -and
                    $bytes[0] -eq 0xEF -and
                    $bytes[1] -eq 0xBB -and
                    $bytes[2] -eq 0xBF)
            ) "$Label contains a UTF-8 BOM."
            $utf8 = [Text.UTF8Encoding]::new($false, $true)
            $text = $utf8.GetString($bytes)
            Assert-Preflight (
                [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                    $bytes, $utf8.GetBytes($text))
            ) "$Label is not canonical strict UTF-8."
        }
        return [pscustomobject][ordered]@{
            Label = $Label
            Path = $full
            ExpectedSha256 = $ExpectedSha256
            ActualSha256 = $sha
            ByteLength = $length
            Identity = $identity
            RequireSingleLink = $RequireSingleLink
            Stream = $stream
            DirectoryChain = $chain
            Text = $text
            Bytes = $bytes
        }
    }
    catch {
        $primaryFailure = $_
    }
    if ($null -ne $primaryFailure) {
        if ($null -ne $stream) {
            try { $stream.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        "$Label partial stream cleanup failed.", $_.Exception))
            }
        }
        if ($null -ne $handle) {
            try { $handle.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        "$Label partial handle cleanup failed.", $_.Exception))
            }
        }
        if ($null -ne $chain) {
            for ($index = $chain.Entries.Count - 1; $index -ge 0; $index--) {
                try { $chain.Entries[$index].Handle.Dispose() }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "$Label partial ancestor cleanup failed.",
                            $_.Exception))
                }
            }
        }
        if ($null -ne $bytes -and $bytes.Length -ne 0) {
            try { [Array]::Clear($bytes, 0, $bytes.Length) }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        "$Label partial byte cleanup failed.", $_.Exception))
            }
        }
        Complete-PrePublicationLocalFailure (
            "$Label held-file acquisition") $primaryFailure (
                [System.Exception[]]$cleanupFailures.ToArray())
    }
}

function Assert-DirectoryChainStillBound {
    param([Parameter(Mandatory)][object]$Chain)
    foreach ($entry in $Chain.Entries) {
        $held = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
            $entry.Handle)
        Assert-Identity $held $true "$($entry.Label) held ancestor" $true
        Assert-FinalPath $entry.Handle $entry.Path (
            "$($entry.Label) held ancestor")
        Assert-Preflight (
            $held.StableId -ceq $entry.Identity.StableId
        ) "$($entry.Label) held ancestor identity changed."
        $currentHandle = $null
        $primaryFailure = $null
        $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
        try {
            $currentHandle =
                [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                    OpenDirectoryDenyDelete($entry.Path)
            $current =
                [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
                    $currentHandle)
            Assert-Identity $current $true "$($entry.Label) current ancestor" $true
            Assert-FinalPath $currentHandle $entry.Path (
                "$($entry.Label) current ancestor")
            Assert-Preflight ($current.StableId -ceq $entry.Identity.StableId) (
                "$($entry.Label) ancestor path identity changed.")
        }
        catch {
            $primaryFailure = $_
        }
        finally {
            if ($null -ne $currentHandle) {
                try { $currentHandle.Dispose() }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "$($entry.Label) current ancestor cleanup failed.",
                            $_.Exception))
                }
            }
        }
        Complete-PrePublicationLocalFailure (
            "$($entry.Label) current ancestor validation") $primaryFailure (
                [System.Exception[]]$cleanupFailures.ToArray())
    }
}

function Assert-HeldFileStillBound {
    param([Parameter(Mandatory)][object]$Binding)
    Assert-DirectoryChainStillBound $Binding.DirectoryChain
    $held = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
        $Binding.Stream.SafeFileHandle)
    Assert-Identity $held $false "$($Binding.Label) held file" (
        [bool]$Binding.RequireSingleLink)
    Assert-FinalPath $Binding.Stream.SafeFileHandle $Binding.Path (
        "$($Binding.Label) held file")
    Assert-Preflight (
        $held.StableId -ceq $Binding.Identity.StableId -and
        [uint64]$held.FileSize -eq [uint64]$Binding.ByteLength -and
        $held.LastWriteTimeUtcFileTime -eq
            $Binding.Identity.LastWriteTimeUtcFileTime
    ) "$($Binding.Label) held file identity changed."
    $Binding.Stream.Position = 0L
    $sha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Binding.Stream)
    ).ToLowerInvariant()
    Assert-Preflight ($sha -ceq $Binding.ActualSha256) (
        "$($Binding.Label) held bytes changed.")
    $currentHandle = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    try {
        $currentHandle =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                OpenFileReadNoFollowDenyWriteDelete($Binding.Path)
        $current =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($currentHandle)
        Assert-Identity $current $false "$($Binding.Label) current file" (
            [bool]$Binding.RequireSingleLink)
        Assert-FinalPath $currentHandle $Binding.Path (
            "$($Binding.Label) current file")
        Assert-Preflight ($current.StableId -ceq $Binding.Identity.StableId) (
            "$($Binding.Label) path identity changed.")
    }
    catch {
        $primaryFailure = $_
    }
    finally {
        if ($null -ne $currentHandle) {
            try { $currentHandle.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        "$($Binding.Label) current file cleanup failed.",
                        $_.Exception))
            }
        }
    }
    Complete-PrePublicationLocalFailure (
        "$($Binding.Label) current file validation") $primaryFailure (
            [System.Exception[]]$cleanupFailures.ToArray())
}

function ConvertTo-PathEvidence {
    param([Parameter(Mandatory)][object]$Binding)
    return [pscustomobject][ordered]@{
        path = [string]$Binding.Path
        expected_sha256 = [string]$Binding.ExpectedSha256
        actual_sha256 = [string]$Binding.ActualSha256
        byte_length = [long]$Binding.ByteLength
        stable_id = [string]$Binding.Identity.StableId
        link_count = [long]$Binding.Identity.LinkCount
        single_link_required = [bool]$Binding.RequireSingleLink
        ancestor_count = [long]$Binding.DirectoryChain.Entries.Count
        no_follow_verified = $true
        final_path_verified = $true
    }
}

function Parse-HeldPowerShell {
    param([Parameter(Mandatory)][object]$Binding)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        [string]$Binding.Text, [ref]$tokens, [ref]$errors)
    Assert-Preflight ($errors.Count -eq 0) (
        "$($Binding.Label) contains PowerShell parse errors.")
    return [pscustomobject][ordered]@{
        Ast = $ast
        Tokens = [Management.Automation.Language.Token[]]$tokens
        ParseErrorCount = [long]$errors.Count
    }
}

function Get-Commands {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    return @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CommandAst]
    }, $true))
}

function Get-Functions {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    return @($Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true))
}

function Get-GuardedVariableBaseName {
    param([Parameter(Mandatory)][object]$VariablePath)
    $userPath = [string]$VariablePath.UserPath
    if ($VariablePath.IsUnqualified) { return $userPath }
    if ($VariablePath.IsScript -or $VariablePath.IsLocal -or
        $VariablePath.IsPrivate -or $VariablePath.IsGlobal -or
        $userPath.StartsWith(
            'variable:', [StringComparison]::OrdinalIgnoreCase) -or
        ($VariablePath.IsDriveQualified -and
         [string]::Equals(
             [string]$VariablePath.DriveName,
             'variable',
             [StringComparison]::OrdinalIgnoreCase))) {
        $separatorOffset = $userPath.IndexOf(':')
        if ($separatorOffset -ge 0 -and
            $separatorOffset -lt ($userPath.Length - 1)) {
            return $userPath.Substring($separatorOffset + 1)
        }
    }
    return $null
}

function Get-Assignments {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [long]$AllowedScriptScopedAssignmentCount = 0L
    )
    Assert-Preflight ($AllowedScriptScopedAssignmentCount -ge 0L) (
        "Invalid allowed script-scoped assignment count: $VariableName")
    $matchingAssignments = @($Ast.FindAll({
        param($node)
        if ($node -isnot
                [Management.Automation.Language.AssignmentStatementAst] -or
            $node.Left -isnot
                [Management.Automation.Language.VariableExpressionAst]) {
            return $false
        }
        $baseName = Get-GuardedVariableBaseName $node.Left.VariablePath
        return $null -ne $baseName -and [string]::Equals(
            [string]$baseName,
            $VariableName,
            [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    $scriptScopedAssignments = @($matchingAssignments | Where-Object {
        $_.Left.VariablePath.IsScript
    })
    $unexpectedScopedAssignments = @($matchingAssignments | Where-Object {
        -not $_.Left.VariablePath.IsUnqualified -and
        -not $_.Left.VariablePath.IsScript
    })
    Assert-Preflight (
        $scriptScopedAssignments.Count -eq
            $AllowedScriptScopedAssignmentCount -and
        $unexpectedScopedAssignments.Count -eq 0 -and
        @($matchingAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0
    ) "Scoped or non-Equals assignment found for guarded variable: $VariableName"
    $assignments = @($matchingAssignments | Where-Object {
        $_.Left.VariablePath.IsUnqualified
    })
    return $assignments
}

function Get-LiteralAssignment {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$VariableName
    )
    $assignments = @(Get-Assignments $Ast $VariableName)
    Assert-Preflight ($assignments.Count -eq 1) (
        "Expected one literal assignment to $VariableName.")
    Assert-Preflight (
        $assignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals
    ) "Literal assignment to $VariableName does not use the exact equals operator."
    $constants = @($assignments[0].Right.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ConstantExpressionAst] -or
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $true))
    Assert-Preflight ($constants.Count -eq 1) (
        "Assignment to $VariableName is not one literal.")
    return $constants[0].Value
}

function Get-InitialLiteralAssignment {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$VariableName
    )
    $assignments = @(Get-Assignments $Ast $VariableName)
    Assert-Preflight ($assignments.Count -ge 1) (
        "Expected an initial literal assignment to $VariableName.")
    Assert-Preflight (
        $assignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals
    ) "Initial literal assignment to $VariableName does not use the exact equals operator."
    $constants = @($assignments[0].Right.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ConstantExpressionAst] -or
        $node -is [Management.Automation.Language.StringConstantExpressionAst]
    }, $true))
    Assert-Preflight ($constants.Count -eq 1) (
        "Initial assignment to $VariableName is not one literal.")
    return $constants[0].Value
}

function Get-VariableWriteCount {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$VariableName
    )
    $assignments = @(Get-Assignments $Ast $VariableName).Count
    $mutationNodes = @($Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.UnaryExpressionAst] -or
            $node.TokenKind -notin @(
            [Management.Automation.Language.TokenKind]::PlusPlus,
            [Management.Automation.Language.TokenKind]::PostfixPlusPlus,
            [Management.Automation.Language.TokenKind]::MinusMinus,
            [Management.Automation.Language.TokenKind]::PostfixMinusMinus) -or
            $node.Child -isnot
                [Management.Automation.Language.VariableExpressionAst]) {
            return $false
        }
        $baseName = Get-GuardedVariableBaseName $node.Child.VariablePath
        return $null -ne $baseName -and [string]::Equals(
            [string]$baseName,
            $VariableName,
            [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    Assert-Preflight (
        @($mutationNodes | Where-Object {
            -not $_.Child.VariablePath.IsUnqualified
        }).Count -eq 0
    ) "Scoped unary mutation found for guarded variable: $VariableName"
    return [long]($assignments + $mutationNodes.Count)
}

function Get-CompactAstText {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast)
    return [regex]::Replace(
        $Ast.Extent.Text,
        '\s+',
        '',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Get-HashtableMap {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory)][string]$VariableName
    )
    $assignments = @(Get-Assignments $Ast $VariableName)
    Assert-Preflight ($assignments.Count -eq 1) (
        "Expected one hashtable assignment to $VariableName.")
    Assert-Preflight (
        $assignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals
    ) "Hashtable assignment to $VariableName does not use the exact equals operator."
    $tables = @($assignments[0].Right.FindAll({
        param($node)
        $node -is [Management.Automation.Language.HashtableAst]
    }, $true))
    Assert-Preflight ($tables.Count -eq 1) (
        "Assignment to $VariableName is not one static hashtable.")
    $map = [ordered]@{}
    foreach ($pair in $tables[0].KeyValuePairs) {
        Assert-Preflight (
            $pair.Item1 -is
                [Management.Automation.Language.StringConstantExpressionAst]
        ) "Hashtable $VariableName has a nonliteral key."
        $key = [string]$pair.Item1.Value
        Assert-Preflight (-not $map.Contains($key)) (
            "Hashtable $VariableName has a duplicate key.")
        $map[$key] = [string[]]@($pair.Item2.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
    }
    return $map
}

function Invoke-ReadOnlyGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $script:gitInvocationCount++
    $start = $null
    $process = $null
    $processStarted = $false
    $stopwatch = $null
    $drainCancellation = $null
    $stdoutStream = $null
    $stderrStream = $null
    $stdoutBuffer = $null
    $stderrBuffer = $null
    $stdoutMemory = $null
    $stderrMemory = $null
    $stdoutCaptureBuffer = $null
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutBytes = $null
    $stdoutTotalBytes = 0L
    $stderrTotalBytes = 0L
    $stdoutTaskQuiescent = $true
    $stderrTaskQuiescent = $true
    $result = $null
    $primaryFailure = $null
    $cleanupFailures =
        [Collections.Generic.List[System.Exception]]::new()
    try {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $gitPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    $start.Environment.Clear()
    $systemDirectory = [Environment]::SystemDirectory
    $windowsRoot = [IO.Directory]::GetParent($systemDirectory).FullName
    foreach ($entry in ([ordered]@{
        SYSTEMROOT = $windowsRoot
        WINDIR = $windowsRoot
        PATH = $systemDirectory
        LANG = 'C'
        LC_ALL = 'C'
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_SYSTEM = 'NUL'
        GIT_CONFIG_GLOBAL = 'NUL'
        GIT_CONFIG_COUNT = '0'
        GIT_ATTR_NOSYSTEM = '1'
        GIT_ATTR_SOURCE = $expectedCommitSha
        GIT_NO_REPLACE_OBJECTS = '1'
        GIT_DIR = $gitDirectory
        GIT_COMMON_DIR = $gitDirectory
        GIT_WORK_TREE = $repoRoot
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE = 'Never'
        GIT_OPTIONAL_LOCKS = '0'
    }).GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($argument in @(
            '--no-pager',
            '--no-optional-locks',
            '--no-replace-objects',
            '-c', 'core.autocrlf=true',
            '-c', 'core.fsmonitor=false',
            '-c', 'core.untrackedCache=false',
            '-c', 'core.excludesFile=NUL',
            '-c', 'core.attributesFile=NUL',
            '-c', 'core.hooksPath=NUL',
            '-c', 'diff.external=',
            '-c', 'pager.status=false',
            '-c', 'status.submoduleSummary=false',
            '-c', 'submodule.recurse=false',
            '-C', $repoRoot
        ) + $Arguments) {
        $start.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $processStarted = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $drainCancellation = [Threading.CancellationTokenSource]::new()
    $stdoutBuffer = [byte[]]::new($gitReadBufferByteLength)
    $stderrBuffer = [byte[]]::new($gitReadBufferByteLength)
    $stdoutMemory = [Memory[byte]]::new($stdoutBuffer)
    $stderrMemory = [Memory[byte]]::new($stderrBuffer)
    $stdoutCaptureBuffer = [byte[]]::new([int]$gitStdoutByteLimit)
        Assert-Preflight ($process.Start()) 'Read-only Git could not start.'
        $processStarted = $true
        $stdoutStream = $process.StandardOutput.BaseStream
        $stderrStream = $process.StandardError.BaseStream
        $stdoutTask = $stdoutStream.ReadAsync(
            $stdoutMemory, $drainCancellation.Token).AsTask()
        $stderrTask = $stderrStream.ReadAsync(
            $stderrMemory, $drainCancellation.Token).AsTask()
        while ($null -ne $stdoutTask -or $null -ne $stderrTask) {
            $remainingMilliseconds = [int][Math]::Max(
                0.0,
                [Math]::Ceiling(
                    [double]$gitOperationTimeoutMilliseconds -
                        $stopwatch.Elapsed.TotalMilliseconds))
            Assert-Preflight ($remainingMilliseconds -gt 0) (
                'Read-only Git exceeded 30 seconds while draining output.')
            $pendingTasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
            if ($null -ne $stdoutTask) {
                $pendingTasks.Add($stdoutTask)
            }
            if ($null -ne $stderrTask) {
                $pendingTasks.Add($stderrTask)
            }
            $completedIndex = [Threading.Tasks.Task]::WaitAny(
                [Threading.Tasks.Task[]]$pendingTasks.ToArray(),
                $remainingMilliseconds)
            Assert-Preflight ($completedIndex -ge 0) (
                'Read-only Git exceeded 30 seconds while draining output.')
            $completedRole = if (
                $null -ne $stderrTask -and $stderrTask.IsCompleted) {
                'stderr'
            }
            elseif ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                'stdout'
            }
            else {
                throw 'Read-only Git drain wake did not identify a completed task.'
            }
            if ($completedRole -ceq 'stdout') {
                $completedTask = $stdoutTask
                $stdoutTask = $null
                $read = $completedTask.GetAwaiter().GetResult()
                if ($read -ne 0) {
                    Assert-Preflight (
                        $stdoutTotalBytes -le
                            ($gitStdoutByteLimit - [long]$read)) (
                        "Read-only Git stdout exceeded $gitStdoutByteLimit bytes.")
                    [Buffer]::BlockCopy(
                        $stdoutBuffer,
                        0,
                        $stdoutCaptureBuffer,
                        [int]$stdoutTotalBytes,
                        $read)
                    $stdoutTotalBytes += [long]$read
                    $stdoutTask = $stdoutStream.ReadAsync(
                        $stdoutMemory, $drainCancellation.Token).AsTask()
                }
            }
            else {
                $completedTask = $stderrTask
                $stderrTask = $null
                $read = $completedTask.GetAwaiter().GetResult()
                if ($read -ne 0) {
                    $stderrTotalBytes += [long]$read
                    throw 'Read-only Git emitted stderr.'
                }
            }
        }
        $remainingMilliseconds = [int][Math]::Max(
            0.0,
            [Math]::Ceiling(
                [double]$gitOperationTimeoutMilliseconds -
                    $stopwatch.Elapsed.TotalMilliseconds))
        Assert-Preflight (
            $remainingMilliseconds -gt 0 -and
            $process.WaitForExit($remainingMilliseconds)) (
            'Read-only Git exceeded 30 seconds before process exit.')
        Assert-Preflight ($process.ExitCode -eq 0) (
            "Read-only Git failed with exit code $($process.ExitCode).")
        Assert-Preflight ($stderrTotalBytes -eq 0L) (
            'Read-only Git emitted stderr.')
        $stdoutBytes = [byte[]]::new([int]$stdoutTotalBytes)
        if ($stdoutTotalBytes -ne 0L) {
            [Buffer]::BlockCopy(
                $stdoutCaptureBuffer,
                0,
                $stdoutBytes,
                0,
                [int]$stdoutTotalBytes)
        }
        Assert-Preflight (
            $stdoutBytes.LongLength -eq $stdoutTotalBytes) (
            'Read-only Git bounded stdout capture length drifted.')
        $result = [Text.UTF8Encoding]::new(
            $false, $true).GetString($stdoutBytes)
    }
    catch {
        $primaryFailure = $_
    }
    finally {
        if ($processStarted) {
            $hasExited = $false
            try { $hasExited = $process.HasExited }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Read-only Git HasExited cleanup check failed.',
                        $_.Exception))
            }
            if (-not $hasExited) {
                $killFailure = $null
                try { $process.Kill($true) }
                catch { $killFailure = $_.Exception }
                $exitObserved = $false
                try {
                    $exitObserved = $process.WaitForExit(
                        $gitCleanupRootExitTimeoutMilliseconds)
                }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            'Read-only Git cleanup wait failed.',
                            $_.Exception))
                }
                if ($null -ne $killFailure) {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            'Read-only Git kill request failed or raced with process exit.',
                            $killFailure))
                }
                if (-not $exitObserved) {
                    $script:gitRootExitNotObservedCount++
                    $cleanupFailures.Add(
                        [TimeoutException]::new(
                            'Read-only Git root-exit closure was not observed within the cleanup boundary.'))
                }
            }
        }
        if ($null -ne $drainCancellation) {
            try { $drainCancellation.Cancel() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Read-only Git drain cancellation failed.',
                        $_.Exception))
            }
        }
        foreach ($entry in @(
                [pscustomobject]@{ Role = 'stdout'; Stream = $stdoutStream },
                [pscustomobject]@{ Role = 'stderr'; Stream = $stderrStream })) {
            if ($null -ne $entry.Stream) {
                try { $entry.Stream.Dispose() }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "Read-only Git $($entry.Role) stream dispose failed.",
                            $_.Exception))
                }
            }
        }
        foreach ($entry in @(
                [pscustomobject]@{ Role = 'stdout'; Task = $stdoutTask },
                [pscustomobject]@{ Role = 'stderr'; Task = $stderrTask })) {
            if ($null -ne $entry.Task) {
                $taskCompleted = $false
                try {
                    $taskCompleted = [Threading.Tasks.Task]::WaitAny(
                        [Threading.Tasks.Task[]]@($entry.Task),
                        $gitCleanupDrainTimeoutMilliseconds) -eq 0
                }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "Read-only Git $($entry.Role) drain cleanup wait failed.",
                            $_.Exception))
                }
                if (-not $taskCompleted) {
                    $script:gitPendingDrainClosureNotObservedCount++
                    $cleanupFailures.Add(
                        [TimeoutException]::new(
                            "Read-only Git $($entry.Role) drain closure was not observed within the cleanup boundary."))
                    if ($entry.Role -ceq 'stdout') {
                        $stdoutTaskQuiescent = $false
                    }
                    else { $stderrTaskQuiescent = $false }
                    $script:gitPendingTaskFaultObserverInstallationAttemptCount++
                    try {
                        [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                            ObserveTaskFault($entry.Task)
                        $script:gitPendingTaskFaultObserverInstallationCompletedCount++
                    }
                    catch {
                        $cleanupFailures.Add(
                            [InvalidOperationException]::new(
                                "Read-only Git $($entry.Role) drain observer installation failed.",
                                $_.Exception))
                    }
                }
                elseif ($entry.Task.IsFaulted) {
                    foreach ($inner in $entry.Task.Exception.Flatten().InnerExceptions) {
                        $cleanupFailures.Add(
                            [InvalidOperationException]::new(
                                "Read-only Git $($entry.Role) drain faulted during cleanup.",
                                $inner))
                    }
                }
            }
        }
        if ($null -ne $process) {
            try { $process.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Read-only Git process dispose failed.',
                        $_.Exception))
            }
        }
        if ($null -ne $drainCancellation) {
            try { $drainCancellation.Dispose() }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Read-only Git cancellation source dispose failed.',
                        $_.Exception))
            }
        }
        foreach ($buffer in @($stdoutBytes, $stdoutCaptureBuffer)) {
            if ($null -ne $buffer -and $buffer.Length -ne 0) {
                try { [Array]::Clear($buffer, 0, $buffer.Length) }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            'Read-only Git buffer clearing failed.',
                            $_.Exception))
                }
            }
        }
        foreach ($entry in @(
                [pscustomobject]@{
                    Role = 'stdout'
                    Buffer = $stdoutBuffer
                    Quiescent = $stdoutTaskQuiescent
                },
                [pscustomobject]@{
                    Role = 'stderr'
                    Buffer = $stderrBuffer
                    Quiescent = $stderrTaskQuiescent
                })) {
            if ($entry.Quiescent -and $null -ne $entry.Buffer) {
                try { [Array]::Clear($entry.Buffer, 0, $entry.Buffer.Length) }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "Read-only Git $($entry.Role) read buffer clearing failed.",
                            $_.Exception))
                }
            }
        }
    }
    if ($null -ne $primaryFailure) {
        $script:gitPrimaryFailureCount++
        $script:gitPrimaryFailureReasons.Add(
            [string]$primaryFailure.Exception.ToString())
    }
    if ($cleanupFailures.Count -ne 0) {
        $script:gitCleanupFailureCount += [long]$cleanupFailures.Count
        foreach ($cleanupFailure in $cleanupFailures) {
            $script:gitCleanupFailureReasons.Add(
                [string]$cleanupFailure.ToString())
        }
    }
    if ($null -ne $primaryFailure -or $cleanupFailures.Count -ne 0) {
        $script:gitInvocationFailureRecordCount++
    }
    if ($cleanupFailures.Count -eq 0) {
        $script:gitCleanupCompletedCount++
    }
    else {
        $aggregate = [Collections.Generic.List[System.Exception]]::new()
        if ($null -ne $primaryFailure) {
            $aggregate.Add($primaryFailure.Exception)
        }
        foreach ($cleanupFailure in $cleanupFailures) {
            $aggregate.Add($cleanupFailure)
        }
        throw [AggregateException]::new(
            'Read-only Git failed and cleanup did not close cleanly.',
            [System.Exception[]]$aggregate.ToArray())
    }
    if ($null -ne $primaryFailure) { throw $primaryFailure }
    $script:gitBoundedDrainCompletedCount++
    return $result
}

function Write-ReceiptCreateNew {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    $jsonParameters = @{
        InputObject = $Value
        Depth = 20
        Compress = $true
    }
    $raw = Microsoft.PowerShell.Utility\ConvertTo-Json @jsonParameters
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($raw)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt 1048576) {
        throw 'Receipt JSON is outside the closed 1..1048576-byte publication bound.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parentPath = [IO.Path]::GetDirectoryName($fullPath)
    $temporaryLeaf = '.' + [IO.Path]::GetFileName($fullPath) +
        '.publish-' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $temporaryPath = [IO.Path]::Combine($parentPath, $temporaryLeaf)
    $writeStream = $null
    $readbackHandle = $null
    $readbackStream = $null
    $finalHandle = $null
    $finalStream = $null
    $readbackBytes = $null
    $bytesCleared = $false
    $publicationCompleted = $false
    $temporaryIdentity = $null
    $primaryFailure = $null
    $cleanupFailures = [Collections.Generic.List[System.Exception]]::new()
    try {
        if ([TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
                $fullPath) -or
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
                $temporaryPath)) {
            throw 'Receipt final or unique temporary path already exists.'
        }
        $writeStream = [IO.FileStream]::new(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough)
        $temporaryIdentity =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
                $writeStream.SafeFileHandle)
        Assert-Identity $temporaryIdentity $false (
            'receipt temporary file at creation') $true
        Assert-FinalPath $writeStream.SafeFileHandle $temporaryPath (
            'receipt temporary file at creation')
        $writeStream.Write($bytes, 0, $bytes.Length)
        $writeStream.Flush($true)
        $writtenIdentity =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
                $writeStream.SafeFileHandle)
        Assert-Identity $writtenIdentity $false (
            'receipt temporary file after durable write') $true
        Assert-FinalPath $writeStream.SafeFileHandle $temporaryPath (
            'receipt temporary file after durable write')
        Assert-Preflight (
            $writtenIdentity.StableId -ceq $temporaryIdentity.StableId -and
            [uint64]$writtenIdentity.FileSize -eq [uint64]$bytes.Length
        ) 'Receipt temporary held identity or size drifted after durable write.'
        $writeStream.Dispose()
        $writeStream = $null

        $readbackHandle =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                OpenFileReadNoFollowDenyWriteDelete($temporaryPath)
        $readbackIdentity =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($readbackHandle)
        Assert-Identity $readbackIdentity $false (
            'receipt temporary no-follow readback') $true
        Assert-FinalPath $readbackHandle $temporaryPath (
            'receipt temporary no-follow readback')
        Assert-Preflight (
            $readbackIdentity.StableId -ceq $temporaryIdentity.StableId -and
            [uint64]$readbackIdentity.FileSize -eq [uint64]$bytes.Length
        ) 'Receipt temporary path no longer identifies the created file.'
        $readbackStream = [IO.FileStream]::new(
            $readbackHandle, [IO.FileAccess]::Read, 4096, $false)
        $readbackHandle = $null
        if ($readbackStream.Length -ne $bytes.Length) {
            throw 'Receipt temporary readback length drifted.'
        }
        $readbackBytes = [byte[]]::new($bytes.Length)
        $offset = 0
        while ($offset -lt $readbackBytes.Length) {
            $read = $readbackStream.Read(
                $readbackBytes, $offset, $readbackBytes.Length - $offset)
            if ($read -le 0) {
                throw 'Receipt temporary readback ended early.'
            }
            $offset += $read
        }
        if ($readbackStream.ReadByte() -ne -1 -or
            -not [Security.Cryptography.CryptographicOperations]::
                FixedTimeEquals($bytes, $readbackBytes)) {
            throw 'Receipt temporary readback bytes drifted.'
        }
        $readbackStream.Dispose()
        $readbackStream = $null
        [Array]::Clear($readbackBytes, 0, $readbackBytes.Length)
        $readbackBytes = $null
        if ([TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
                $fullPath)) {
            throw 'Receipt final path appeared before atomic publication.'
        }
        [IO.File]::Move($temporaryPath, $fullPath, $false)

        $finalHandle =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                OpenFileReadNoFollowDenyWriteDelete($fullPath)
        $finalIdentity =
            [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read($finalHandle)
        Assert-Identity $finalIdentity $false (
            'receipt final no-follow readback') $true
        Assert-FinalPath $finalHandle $fullPath (
            'receipt final no-follow readback')
        Assert-Preflight (
            $finalIdentity.StableId -ceq $temporaryIdentity.StableId -and
            [uint64]$finalIdentity.FileSize -eq [uint64]$bytes.Length
        ) 'Receipt final path does not identify the verified temporary file.'
        $finalStream = [IO.FileStream]::new(
            $finalHandle, [IO.FileAccess]::Read, 4096, $false)
        $finalHandle = $null
        $readbackBytes = [byte[]]::new($bytes.Length)
        $offset = 0
        while ($offset -lt $readbackBytes.Length) {
            $read = $finalStream.Read(
                $readbackBytes, $offset, $readbackBytes.Length - $offset)
            if ($read -le 0) {
                throw 'Receipt final readback ended early.'
            }
            $offset += $read
        }
        if ($finalStream.ReadByte() -ne -1 -or
            -not [Security.Cryptography.CryptographicOperations]::
                FixedTimeEquals($bytes, $readbackBytes)) {
            throw 'Receipt final readback bytes drifted.'
        }
        $publicationCompleted = $true
        $finalStream.Dispose()
        $finalStream = $null
        [Array]::Clear($readbackBytes, 0, $readbackBytes.Length)
        $readbackBytes = $null
        [Array]::Clear($bytes, 0, $bytes.Length)
        $bytesCleared = $true
    }
    catch {
        $primaryFailure = $_
    }
    finally {
        foreach ($resourceState in @(
                [pscustomobject]@{ Resource = $finalStream; Label = 'final stream' },
                [pscustomobject]@{ Resource = $finalHandle; Label = 'final handle' },
                [pscustomobject]@{ Resource = $readbackStream; Label = 'temporary readback stream' },
                [pscustomobject]@{ Resource = $readbackHandle; Label = 'temporary readback handle' },
                [pscustomobject]@{ Resource = $writeStream; Label = 'temporary write stream' })) {
            if ($null -ne $resourceState.Resource) {
                try { $resourceState.Resource.Dispose() }
                catch {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            "Receipt $($resourceState.Label) dispose failed.",
                            $_.Exception))
                }
            }
        }
        if ($null -ne $readbackBytes -and $readbackBytes.Length -ne 0) {
            try { [Array]::Clear($readbackBytes, 0, $readbackBytes.Length) }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Receipt readback byte cleanup failed.', $_.Exception))
            }
        }
        if (-not $bytesCleared -and $bytes.Length -ne 0) {
            try { [Array]::Clear($bytes, 0, $bytes.Length) }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Receipt source byte cleanup failed.', $_.Exception))
            }
        }
        if (-not $publicationCompleted) {
            try {
                if ([TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                        EntryExistsNoFollow($temporaryPath)) {
                    $cleanupFailures.Add(
                        [InvalidOperationException]::new(
                            'Receipt temporary file was retained after failed publication; path deletion was intentionally withheld because same-path identity cannot be kept held across deletion.'))
                }
            }
            catch {
                $cleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Receipt temporary residue probe failed.', $_.Exception))
            }
        }
    }
    if ($cleanupFailures.Count -ne 0) {
        $script:receiptPublicationCleanupFailureCount +=
            [long]$cleanupFailures.Count
        foreach ($cleanupFailure in $cleanupFailures) {
            $script:receiptPublicationCleanupFailureReasons.Add(
                [string]$cleanupFailure.ToString())
        }
        $aggregate = [Collections.Generic.List[System.Exception]]::new()
        if ($null -ne $primaryFailure) {
            $aggregate.Add($primaryFailure.Exception)
        }
        foreach ($cleanupFailure in $cleanupFailures) {
            $aggregate.Add($cleanupFailure)
        }
        throw [AggregateException]::new(
            'Receipt publication failed and cleanup did not close cleanly.',
            [System.Exception[]]$aggregate.ToArray())
    }
    if ($null -ne $primaryFailure) { throw $primaryFailure }
}

try {
    foreach ($value in @(
            $expectedCommitSha,
            $expectedCommitShort,
            $helperPath,
            $expectedHelperSha256,
            $launcherPath,
            $expectedLauncherSha256,
            $failureSidecarPath,
            $expectedVerifierSha256,
            $pwshPath,
            $expectedPwshSha256,
            $expectedGitIndexSha256,
            $summaryLeaf,
            $logLeaf,
            $launcherResultLeaf,
            $receiptPath)) {
        Assert-Preflight (
            [string]$value -cnotmatch '__[A-Z][A-Z0-9_]*__'
        ) "Preflight contains an unexpanded staging placeholder: $value"
    }
    Assert-Preflight (
        $expectedCommitSha -cmatch '\A[0-9a-f]{40}\z'
    ) 'Final commit SHA is not canonical.'
    Assert-Preflight (
        $expectedCommitShort -cmatch '\A[0-9a-f]{7}\z' -and
        $expectedCommitSha.StartsWith(
            $expectedCommitShort, [StringComparison]::Ordinal)
    ) 'Final short commit is not bound to the full commit.'
    foreach ($hash in @(
            $expectedHelperSha256,
            $expectedLauncherSha256,
            $expectedLauncherTemplateSha256,
            $expectedVerifierSha256,
            $expectedPwshSha256,
            $expectedGitSha256,
            $expectedGitConfigSha256,
            $expectedGitAttributesSha256,
            $expectedGitIgnoreSha256,
            $expectedGitInfoExcludeSha256,
            $expectedGitIndexSha256)) {
        Assert-Preflight (
            [string]$hash -cmatch '\A[0-9a-f]{64}\z'
        ) 'A frozen expected SHA-256 is not canonical.'
    }
    $expectedVerifierPath = Join-Path $repoRoot (
        'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1')
    Assert-Preflight (
        [IO.Path]::GetFullPath($verifierPath) -ceq
            [IO.Path]::GetFullPath($expectedVerifierPath)
    ) 'Tracked verifier relative path drifted.'
    Assert-Preflight (
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($receiptPath)) -ceq
            [IO.Path]::GetFullPath($stagingRoot)
    ) 'Receipt is not a direct child of the fixed staging directory.'
    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($helperPath) -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($helperPath)) -ceq
            [IO.Path]::GetFullPath($stagingRoot) -and
        [IO.Path]::GetFileName($helperPath) -ceq
            ('helper-' + $expectedCommitShort + '-r10.ps1')
    ) 'Helper is not the exact direct staging child for this commit.'
    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($launcherPath) -and
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($launcherPath)) -ceq
            [IO.Path]::GetFullPath($stagingRoot) -and
        [IO.Path]::GetFileName($launcherPath) -ceq
            ('launcher-' + $expectedCommitShort + '-r10.ps1')
    ) 'Launcher is not the exact direct staging child for this commit.'
    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($repoRoot) -and
        [IO.Path]::GetFullPath($repoRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar) -ceq $repoRoot
    ) 'Repository root is not one fixed canonical absolute path.'
    Assert-Preflight (
        [IO.Path]::GetFullPath($moduleBuildParentPath) -ceq
            [IO.Path]::Combine($repoRoot, 'app\tablet-c1b-probe') -and
        [IO.Path]::GetFullPath($moduleBuildPath) -ceq
            [IO.Path]::Combine($repoRoot, 'app\tablet-c1b-probe\build') -and
        [IO.Path]::GetDirectoryName($moduleBuildPath) -ceq
            $moduleBuildParentPath
    ) 'Module build output path is not the exact canonical repository child.'
    Assert-Preflight (
        [IO.Path]::IsPathFullyQualified($failureSidecarPath) -and
        [IO.Path]::GetDirectoryName(
            [IO.Path]::GetFullPath($failureSidecarPath)) -ceq
                [IO.Path]::GetFullPath($stagingRoot) -and
        [IO.Path]::GetFileName($failureSidecarPath) -ceq
            ('launcher-' + $expectedCommitShort + '-r10.failure.json') -and
        [IO.Path]::GetFullPath($failureSidecarPath) -cne
            [IO.Path]::GetFullPath($launcherPath)
    ) 'Failure sidecar is not the exact .failure.json staging sibling.'

    foreach ($directorySpec in @(
            [pscustomobject]@{ Path = $repoRoot; Label = 'repository root' },
            [pscustomobject]@{ Path = $outputRoot; Label = 'output root' },
            [pscustomobject]@{
                Path = $moduleBuildParentPath
                Label = 'module build parent'
            },
            [pscustomobject]@{ Path = $gitInfoPath; Label = 'repository git info' })) {
        $directoryChains.Add((
            Open-DirectoryChain $directorySpec.Path $directorySpec.Label))
    }
    $receiptDirectoryChain = Open-DirectoryChain (
        $stagingRoot) 'receipt staging root'
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $receiptPath)
    ) 'The candidate CreateNew preflight receipt already exists.'
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $failureSidecarPath)
    ) 'The diagnostic failure sidecar already exists at initial observation.'
    $failureSidecarAbsentAtInitialObservation = $true
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $moduleBuildPath)
    ) 'The module build output already exists at initial observation.'
    $moduleBuildAbsentAtInitialObservation = $true
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $gitInfoAttributesPath)
    ) 'Repository info/attributes must remain absent for isolated Git observation.'

    $expectedGitHeadText = "ref: refs/heads/$expectedBranch`n"
    $expectedGitRefText = $expectedCommitSha + "`n"
    $expectedGitHeadSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes($expectedGitHeadText)
        )).ToLowerInvariant()
    $expectedGitRefSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            [Text.UTF8Encoding]::new($false).GetBytes($expectedGitRefText)
        )).ToLowerInvariant()

    foreach ($fileSpec in @(
            [pscustomobject]@{
                Path = $launcherPath
                Hash = $expectedLauncherSha256
                Label = 'launcher'
                Text = $true
                Primary = $true
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $helperPath
                Hash = $expectedHelperSha256
                Label = 'helper'
                Text = $true
                Primary = $true
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $verifierPath
                Hash = $expectedVerifierSha256
                Label = 'verifier'
                Text = $true
                Primary = $true
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $pwshPath
                Hash = $expectedPwshSha256
                Label = 'pinned pwsh'
                Text = $false
                Primary = $true
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitPath
                Hash = $expectedGitSha256
                Label = 'read-only git'
                Text = $false
                Primary = $false
                SingleLink = $false
            },
            [pscustomobject]@{
                Path = $gitConfigPath
                Hash = $expectedGitConfigSha256
                Label = 'repository local git config'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitAttributesPath
                Hash = $expectedGitAttributesSha256
                Label = 'repository root gitattributes'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitIgnorePath
                Hash = $expectedGitIgnoreSha256
                Label = 'repository root gitignore'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitInfoExcludePath
                Hash = $expectedGitInfoExcludeSha256
                Label = 'repository info exclude'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitHeadPath
                Hash = $expectedGitHeadSha256
                Label = 'repository HEAD'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitRefPath
                Hash = $expectedGitRefSha256
                Label = 'repository branch ref'
                Text = $true
                Primary = $false
                SingleLink = $true
            },
            [pscustomobject]@{
                Path = $gitIndexPath
                Hash = $expectedGitIndexSha256
                Label = 'repository index'
                Text = $false
                Primary = $false
                SingleLink = $true
            })) {
        $binding = Open-HeldFile (
            $fileSpec.Path) $fileSpec.Hash $fileSpec.Label $fileSpec.Text (
                [bool]$fileSpec.SingleLink)
        $allFileBindings.Add($binding)
        if ($fileSpec.Primary) { $primaryFileBindings.Add($binding) }
    }
    Assert-Preflight ($primaryFileBindings.Count -eq 4) (
        'Preflight did not hold exactly four frozen primary objects.')

    $launcherBinding = @($primaryFileBindings | Where-Object {
        $_.Label -ceq 'launcher'
    })[0]
    $helperBinding = @($primaryFileBindings | Where-Object {
        $_.Label -ceq 'helper'
    })[0]
    $verifierBinding = @($primaryFileBindings | Where-Object {
        $_.Label -ceq 'verifier'
    })[0]
    $pwshBinding = @($primaryFileBindings | Where-Object {
        $_.Label -ceq 'pinned pwsh'
    })[0]
    Assert-Preflight (
        [long]$helperBinding.ByteLength -eq $expectedHelperByteLength -and
        [long]$launcherBinding.ByteLength -eq $expectedLauncherByteLength
    ) 'Held helper or launcher byte length drifted from the frozen candidate.'

    $relevantPaths = @(
        $repoRoot, $outputRoot, $moduleBuildParentPath, $moduleBuildPath,
        $stagingRoot, $launcherPath, $helperPath,
        $verifierPath, $pwshPath, $gitPath, $summaryPath, $logPath,
        $launcherResultPath, $failureSidecarPath, $receiptPath
    )
    $roots = [string[]]@($relevantPaths | ForEach-Object {
        [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($_)).ToUpperInvariant()
    } | Sort-Object -Unique)
    Assert-Preflight ($roots.Count -gt 0) 'Relevant volume list is empty.'
    foreach ($root in $roots) {
        $drive = [IO.DriveInfo]::new($root)
        Assert-Preflight ($drive.IsReady) "Relevant volume is not ready: $root"
        Assert-Preflight ($drive.DriveType -eq [IO.DriveType]::Fixed) (
            "Relevant volume is not a fixed local drive: $root")
        Assert-Preflight ($drive.DriveFormat -ceq 'NTFS') (
            "Relevant volume is not NTFS: $root")
        $volumeEvidence.Add([pscustomobject][ordered]@{
            root = $root
            drive_type = [string]$drive.DriveType
            drive_format = [string]$drive.DriveFormat
            ready = [bool]$drive.IsReady
            fixed_drive_required = $true
            fixed_drive_verified = $true
            ntfs_required = $true
            ntfs_verified = $true
        })
    }

    $runtimePwshPath = [IO.Path]::GetFullPath(
        [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    Assert-Preflight (
        $runtimePwshPath -ceq [IO.Path]::GetFullPath($pwshPath)
    ) 'Preflight is not running under the held pinned pwsh.'
    $runtimePwshPathMatchesHeldPath = $true

    $gitHeadBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository HEAD'
    })
    $gitRefBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository branch ref'
    })
    $gitConfigBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository local git config'
    })
    $gitAttributesBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository root gitattributes'
    })
    $gitIgnoreBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository root gitignore'
    })
    $gitInfoExcludeBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository info exclude'
    })
    $gitIndexBinding = @($allFileBindings | Where-Object {
        $_.Label -ceq 'repository index'
    })
    Assert-Preflight (
        $gitHeadBinding.Count -eq 1 -and
        $gitHeadBinding[0].Text -ceq $expectedGitHeadText
    ) 'Held repository HEAD is not the exact frozen branch reference.'
    Assert-Preflight (
        $gitRefBinding.Count -eq 1 -and
        $gitRefBinding[0].Text -ceq $expectedGitRefText
    ) 'Held repository branch ref is not the exact final commit.'
    Assert-Preflight (
        $gitConfigBinding.Count -eq 1 -and
        $gitAttributesBinding.Count -eq 1 -and
        $gitIgnoreBinding.Count -eq 1 -and
        $gitInfoExcludeBinding.Count -eq 1 -and
        $gitIndexBinding.Count -eq 1
    ) 'Git config, attributes, ignore, info exclude, or index guard is not unique.'
    Assert-Preflight (
        $gitConfigBinding[0].Text -cnotmatch
            '(?im)^\s*\[(?:filter|include|includeIf|alias)(?:\s|\])' -and
        $gitConfigBinding[0].Text -cnotmatch
            '(?im)^\s*(?:fsmonitor|hooksPath|attributesFile|external|pager)\s*=' -and
        $gitAttributesBinding[0].Text -cnotmatch
            '(?im)(?:^|\s)(?:filter|diff|merge|working-tree-encoding)=' -and
        $gitAttributesBinding[0].Text -cnotmatch '(?im)^\s*\[attr\]' -and
        @($gitInfoExcludeBinding[0].Text -split '\r?\n' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.StartsWith('#', [StringComparison]::Ordinal)
        }).Count -eq 0
    ) 'Held Git config, attributes, or info exclude contains an unexpected surface.'
    $gitHead = $expectedCommitSha
    $gitBranch = $expectedBranch

    $gitRepositoryIdentity = Invoke-ReadOnlyGit @(
        'rev-parse', '--show-toplevel', '--absolute-git-dir',
        '--show-object-format')
    $gitIdentityLines = [string[]]@(
        $gitRepositoryIdentity -split '\r?\n' | Where-Object {
            -not [string]::IsNullOrEmpty($_)
        })
    Assert-Preflight (
        $gitIdentityLines.Count -eq 3 -and
        [IO.Path]::GetFullPath($gitIdentityLines[0]) -ceq
            [IO.Path]::GetFullPath($repoRoot) -and
        [IO.Path]::GetFullPath($gitIdentityLines[1]) -ceq
            [IO.Path]::GetFullPath($gitDirectory) -and
        $gitIdentityLines[2] -ceq 'sha1'
    ) 'Read-only Git repository identity or object format drifted.'

    $gitIndexFlags = Invoke-ReadOnlyGit @(
        'ls-files', '-v', '--stage', '-z')
    $gitIndexFlagRecords = [string[]]@(
        $gitIndexFlags -split "`0" | Where-Object {
            -not [string]::IsNullOrEmpty($_)
        })
    Assert-Preflight ($gitIndexFlagRecords.Count -gt 0) (
        'Read-only Git returned no tracked index records.')
    foreach ($record in $gitIndexFlagRecords) {
        Assert-Preflight (
            $record.Length -ge 3 -and $record.StartsWith(
                'H ', [StringComparison]::Ordinal)
        ) 'Git index contains assume-unchanged, skip-worktree, or noncanonical state.'
    }
    $gitIndexFlagsVerified = $true

    $gitStageRecords = [string[]]@(
        $gitIndexFlagRecords | ForEach-Object { $_.Substring(2) })
    $trackedAttributePaths = [Collections.Generic.List[string]]::new()
    $trackedIgnorePaths = [Collections.Generic.List[string]]::new()
    foreach ($record in $gitStageRecords) {
        Assert-Preflight (-not $record.StartsWith(
                '160000 ', [StringComparison]::Ordinal)) (
            'Git index contains a submodule/gitlink entry.')
        $tab = $record.IndexOf("`t", [StringComparison]::Ordinal)
        Assert-Preflight ($tab -gt 0 -and $tab -lt ($record.Length - 1)) (
            'Git staged record is not canonical.')
        $trackedPath = $record.Substring($tab + 1)
        if ([IO.Path]::GetFileName($trackedPath) -ceq '.gitattributes') {
            $trackedAttributePaths.Add($trackedPath)
        }
        if ([IO.Path]::GetFileName($trackedPath) -ceq '.gitignore') {
            $trackedIgnorePaths.Add($trackedPath)
        }
    }
    Assert-OrdinalSequence $trackedAttributePaths.ToArray() (
        [string[]]@('.gitattributes')) (
        'Expected commit has an unexpected gitattributes topology.')
    Assert-OrdinalSequence $trackedIgnorePaths.ToArray() (
        [string[]]@('.gitignore')) (
        'Expected commit has an unexpected gitignore topology.')
    $gitTrackedPathCount = [long]$gitStageRecords.Count
    Assert-Preflight (
        $gitTrackedPathCount -eq $expectedGitTrackedPathCount
    ) 'Tracked path count is not exactly the frozen candidate count.'
    $gitSubmodulesAbsent = $true

    $gitIndexVsHead = Invoke-ReadOnlyGit @(
        'diff-index', '--cached', '--name-only', '--no-renames',
        $expectedCommitSha, '--')
    Assert-Preflight ([string]::IsNullOrEmpty($gitIndexVsHead)) (
        'Read-only Git reports staged index changes relative to the expected commit.')

    foreach ($candidate in @(
            $summaryPath, $logPath, $launcherResultPath)) {
        $absent = -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
            EntryExistsNoFollow($candidate)
        $outputAbsenceEvidence.Add([pscustomobject][ordered]@{
            path = [IO.Path]::GetFullPath($candidate)
            absent = [bool]$absent
            kind = 'final_output'
        })
        Assert-Preflight $absent (
            "Candidate final output already exists: $candidate")
    }
    $childItemParameters = @{
        LiteralPath = $outputRoot
        Force = $true
        ErrorAction = 'Stop'
    }
    $outputChildren = @(
        Microsoft.PowerShell.Management\Get-ChildItem @childItemParameters)
    foreach ($prefix in @(
            ".$summaryLeaf.", ".$logLeaf.", ".$launcherResultLeaf.")) {
        $matches = @($outputChildren | Where-Object {
            $_.Name.StartsWith($prefix, [StringComparison]::Ordinal)
        })
        $outputAbsenceEvidence.Add([pscustomobject][ordered]@{
            path = [IO.Path]::GetFullPath((Join-Path $outputRoot ($prefix + '*')))
            absent = [bool]($matches.Count -eq 0)
            kind = 'candidate_temporary_prefix'
        })
        Assert-Preflight ($matches.Count -eq 0) (
            "Candidate temporary prefix is not absent: $prefix")
    }

    $passiveHostAdbStateSnapshots.Add((
        Get-PassiveHostAdbStateSnapshot -Stage 'initial'))

    $launcherParsed = Parse-HeldPowerShell $launcherBinding
    $helperParsed = Parse-HeldPowerShell $helperBinding
    $verifierParsed = Parse-HeldPowerShell $verifierBinding

    # Reconstruct the independently frozen nine-placeholder launcher template
    # by replacing only nine unique direct top-level literal RHS slots.
    Assert-Preflight (
        $launcherBinding.Text -cnotmatch '__[A-Z][A-Z0-9_]*__' -and
        $launcherBinding.Text -cnotmatch "`r|`0"
    ) 'Rendered launcher contains a placeholder, CR, or NUL byte.'
    $launcherTemplateSlots = @(
        [pscustomobject]@{
            Name = 'expectedCommitSha'
            Value = $expectedCommitSha
            Placeholder = ('_' + '_FINAL_COMMIT_SHA_' + '_')
        },
        [pscustomobject]@{
            Name = 'expectedCommitShort'
            Value = $expectedCommitShort
            Placeholder = ('_' + '_FINAL_COMMIT_SHORT_' + '_')
        },
        [pscustomobject]@{
            Name = 'repoRoot'
            Value = $repoRoot
            Placeholder = ('_' + '_REPO_ROOT_' + '_')
        },
        [pscustomobject]@{
            Name = 'failureSidecarPath'
            Value = $failureSidecarPath
            Placeholder = ('_' + '_FAILURE_SIDECAR_ABSOLUTE_PATH_' + '_')
        },
        [pscustomobject]@{
            Name = 'helperPath'
            Value = $helperPath
            Placeholder = ('_' + '_HELPER_ABSOLUTE_PATH_' + '_')
        },
        [pscustomobject]@{
            Name = 'expectedHelperSha256'
            Value = $expectedHelperSha256
            Placeholder = ('_' + '_HELPER_SHA256_' + '_')
        },
        [pscustomobject]@{
            Name = 'expectedVerifierSha256'
            Value = $expectedVerifierSha256
            Placeholder = ('_' + '_VERIFIER_SHA256_' + '_')
        },
        [pscustomobject]@{
            Name = 'pwshPath'
            Value = $pwshPath
            Placeholder = ('_' + '_PWSH_ABSOLUTE_PATH_' + '_')
        },
        [pscustomobject]@{
            Name = 'expectedPwshSha256'
            Value = $expectedPwshSha256
            Placeholder = ('_' + '_PWSH_SHA256_' + '_')
        }
    )
    $resolvedLauncherTemplateSlots = [Collections.Generic.List[object]]::new()
    foreach ($templateSlot in $launcherTemplateSlots) {
        $slotValue = [string]$templateSlot.Value
        Assert-Preflight (
            -not [string]::IsNullOrEmpty($slotValue) -and
            $slotValue.IndexOfAny([char[]]@("'", "`r", "`n", "`0")) -eq -1
        ) "Rendered launcher slot contains a forbidden character: $($templateSlot.Name)"
        $slotAssignments = @(Get-Assignments (
                $launcherParsed.Ast) ([string]$templateSlot.Name) |
                Where-Object {
                    [object]::ReferenceEquals(
                        $_.Parent, $launcherParsed.Ast.EndBlock)
                })
        Assert-Preflight (
            $slotAssignments.Count -eq 1 -and
            $slotAssignments[0].Right -is
                [Management.Automation.Language.CommandExpressionAst] -and
            $slotAssignments[0].Right.Expression -is
                [Management.Automation.Language.StringConstantExpressionAst] -and
            $slotAssignments[0].Right.Expression.StringConstantType -eq
                [Management.Automation.Language.StringConstantType]::SingleQuoted -and
            [string]$slotAssignments[0].Right.Expression.Value -ceq $slotValue -and
            $slotAssignments[0].Right.Extent.Text -ceq ("'" + $slotValue + "'")
        ) "Rendered launcher slot is not one direct exact single-quoted literal: $($templateSlot.Name)"
        $resolvedLauncherTemplateSlots.Add([pscustomobject]@{
            Name = [string]$templateSlot.Name
            Placeholder = [string]$templateSlot.Placeholder
            StartOffset = [long]$slotAssignments[0].Right.Extent.StartOffset
            EndOffset = [long]$slotAssignments[0].Right.Extent.EndOffset
        })
    }
    $reconstructedLauncherTemplate = [string]$launcherBinding.Text
    foreach ($resolvedSlot in @(
            $resolvedLauncherTemplateSlots |
                Sort-Object -Property StartOffset -Descending)) {
        $slotReplacement = "'" + [string]$resolvedSlot.Placeholder + "'"
        $reconstructedLauncherTemplate =
            $reconstructedLauncherTemplate.Substring(
                0, [int]$resolvedSlot.StartOffset) +
            $slotReplacement +
            $reconstructedLauncherTemplate.Substring(
                [int]$resolvedSlot.EndOffset)
    }
    $reconstructedTokens = $null
    $reconstructedErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput(
        $reconstructedLauncherTemplate,
        [ref]$reconstructedTokens,
        [ref]$reconstructedErrors)
    Assert-Preflight ($reconstructedErrors.Count -eq 0) (
        'Reconstructed launcher template contains parse errors.')
    $reconstructedPlaceholders = [string[]]@(
        [regex]::Matches(
            $reconstructedLauncherTemplate,
            '__[A-Z][A-Z0-9_]*__',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant) |
            ForEach-Object { [string]$_.Value })
    Assert-OrdinalSequence $reconstructedPlaceholders ([string[]]@(
        ('_' + '_FINAL_COMMIT_SHA_' + '_'),
        ('_' + '_FINAL_COMMIT_SHORT_' + '_'),
        ('_' + '_REPO_ROOT_' + '_'),
        ('_' + '_FAILURE_SIDECAR_ABSOLUTE_PATH_' + '_'),
        ('_' + '_HELPER_ABSOLUTE_PATH_' + '_'),
        ('_' + '_HELPER_SHA256_' + '_'),
        ('_' + '_VERIFIER_SHA256_' + '_'),
        ('_' + '_PWSH_ABSOLUTE_PATH_' + '_'),
        ('_' + '_PWSH_SHA256_' + '_')
    )) 'Reconstructed launcher placeholder set/order drifted.'
    $reconstructedTemplateBytes = [Text.UTF8Encoding]::new(
        $false, $true).GetBytes($reconstructedLauncherTemplate)
    $reconstructionPrimaryFailure = $null
    $reconstructionCleanupFailures =
        [Collections.Generic.List[System.Exception]]::new()
    try {
        $reconstructedTemplateSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData(
                $reconstructedTemplateBytes)).ToLowerInvariant()
        Assert-Preflight (
            $reconstructedTemplateSha256 -ceq
                $expectedLauncherTemplateSha256
        ) 'Reconstructed launcher template SHA-256 drifted.'
        $launcherTemplateReconstructionVerified = $true
    }
    catch {
        $reconstructionPrimaryFailure = $_
    }
    finally {
        if ($reconstructedTemplateBytes.Length -ne 0) {
            try {
                [Array]::Clear(
                    $reconstructedTemplateBytes,
                    0,
                    $reconstructedTemplateBytes.Length)
            }
            catch {
                $reconstructionCleanupFailures.Add(
                    [InvalidOperationException]::new(
                        'Reconstructed launcher template byte cleanup failed.',
                        $_.Exception))
            }
        }
    }
    Complete-PrePublicationLocalFailure (
        'Launcher-template reverse reconstruction') (
            $reconstructionPrimaryFailure) (
            [System.Exception[]]$reconstructionCleanupFailures.ToArray())
    # Launcher static authority.
    foreach ($literalSpec in @(
            [pscustomobject]@{
                Name = 'expectedCommitSha'; Value = $expectedCommitSha
            },
            [pscustomobject]@{
                Name = 'repoRoot'; Value = $repoRoot
            },
            [pscustomobject]@{
                Name = 'failureSidecarPath'; Value = $failureSidecarPath
            },
            [pscustomobject]@{
                Name = 'helperPath'; Value = $helperPath
            },
            [pscustomobject]@{
                Name = 'expectedHelperSha256'; Value = $expectedHelperSha256
            },
            [pscustomobject]@{
                Name = 'verifierRelativePath'; Value = $verifierRelativePath
            },
            [pscustomobject]@{
                Name = 'expectedVerifierSha256'; Value = $expectedVerifierSha256
            },
            [pscustomobject]@{
                Name = 'pwshPath'; Value = $pwshPath
            },
            [pscustomobject]@{
                Name = 'expectedPwshSha256'; Value = $expectedPwshSha256
            })) {
        Assert-Preflight (
            [string](Get-LiteralAssignment (
                $launcherParsed.Ast) $literalSpec.Name) -ceq
                [string]$literalSpec.Value
        ) "Launcher literal $($literalSpec.Name) drifted."
    }
    foreach ($numericSpec in @(
            [pscustomobject]@{
                Name = 'helperDeadlineMilliseconds'
                Value = $helperDeadlineMilliseconds
            },
            [pscustomobject]@{
                Name = 'helperKillWaitMilliseconds'
                Value = $helperKillWaitMilliseconds
            },
            [pscustomobject]@{
                Name = 'helperDrainWaitMilliseconds'
                Value = $helperDrainWaitMilliseconds
            },
            [pscustomobject]@{
                Name = 'captureCapBytes'
                Value = $captureCapBytes
            },
            [pscustomobject]@{
                Name = 'maximumObserverTailSeconds'
                Value = 5.0
            })) {
        Assert-Preflight (
            [long](Get-LiteralAssignment (
                $launcherParsed.Ast) $numericSpec.Name) -eq
                [long]$numericSpec.Value
        ) "Launcher numeric constant $($numericSpec.Name) drifted."
    }
    foreach ($outputSpec in @(
            [pscustomobject]@{
                Variable = 'summaryPath'
                Prefix = "'tablet-c1b-real-build-smoke-'"
                Suffix = "'.summary.json'"
            },
            [pscustomobject]@{
                Variable = 'logPath'
                Prefix = "'tablet-c1b-real-build-smoke-'"
                Suffix = "'.log'"
            },
            [pscustomobject]@{
                Variable = 'launcherResultPath'
                Prefix = "'tablet-c1b-real-build-smoke-'"
                Suffix = "'.launcher.json'"
            })) {
        $outputAssignments = @(Get-Assignments (
            $launcherParsed.Ast) $outputSpec.Variable)
        Assert-Preflight ($outputAssignments.Count -eq 1) (
            "Launcher output assignment is not unique: $($outputSpec.Variable)")
        $outputExpression = $outputAssignments[0].Right.Extent.Text
        foreach ($fragment in @(
                'Join-Path $outputRoot',
                [string]$outputSpec.Prefix,
                '$expectedCommitShort',
                [string]$outputSpec.Suffix)) {
            Assert-Text $outputExpression $fragment (
                "Launcher output assignment $($outputSpec.Variable) is missing $fragment.")
        }
    }

    $launcherCommands = @(Get-Commands $launcherParsed.Ast)
    $launcherRequiredModules = @(
        if ($null -ne $launcherParsed.Ast.ScriptRequirements) {
            $launcherParsed.Ast.ScriptRequirements.RequiredModules
        }
    )
    $launcherUsingModules = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.UsingStatementAst] -and
        $node.UsingStatementKind -eq
            [Management.Automation.Language.UsingStatementKind]::Module
    }, $true))
    Assert-Preflight (
        $launcherRequiredModules.Count -eq 0 -and
        $launcherUsingModules.Count -eq 0
    ) 'Launcher imports a module outside its held command surface.'
    $dotSources = @($launcherCommands | Where-Object {
        $_.InvocationOperator -eq
            [Management.Automation.Language.TokenKind]::Dot
    })
    Assert-Preflight ($dotSources.Count -eq 1) (
        'Launcher verifier dot-source count is not exactly one.')
    Assert-Text $dotSources[0].Extent.Text 'verifierBinding.Path' (
        'Launcher does not dot-source the held verifier guard path.')
    $capturedInvocations = @($launcherCommands | Where-Object {
        if ($_.InvocationOperator -ne
                [Management.Automation.Language.TokenKind]::Ampersand -or
            $_.CommandElements.Count -eq 0) {
            return $false
        }
        $first = $_.CommandElements[0]
        return (
            $first -is
                [Management.Automation.Language.VariableExpressionAst] -and
            [string]$first.VariablePath.UserPath -ceq
                'capturedVerifierFunction')
    })
    Assert-Preflight ($capturedInvocations.Count -eq 1) (
        'Captured verifier FunctionInfo invoke count is not exactly one.')
    $capturedPrivateInvocationKeys = [string[]]@(
        'ConvertFrom-TL1C1bRealBuildSmokeSummaryJson',
        'Assert-TL1C1bRealBuildSmokeSummaryExactProperties')
    $capturedPrivateInvocations = @($launcherCommands | Where-Object {
        if ($_.InvocationOperator -ne
                [Management.Automation.Language.TokenKind]::Ampersand -or
            $_.CommandElements.Count -eq 0) {
            return $false
        }
        $first = $_.CommandElements[0]
        return (
            $first -is [Management.Automation.Language.IndexExpressionAst] -and
            $first.Target -is
                [Management.Automation.Language.VariableExpressionAst] -and
            $first.Index -is
                [Management.Automation.Language.StringConstantExpressionAst] -and
            [string]$first.Target.VariablePath.UserPath -ceq
                'capturedVerifierFunctions' -and
            $capturedPrivateInvocationKeys -ccontains
                [string]$first.Index.Value)
    })
    Assert-Preflight ($capturedPrivateInvocations.Count -eq 2) (
        'Captured private verifier FunctionInfo invoke count is not exactly two.')
    $actualCapturedPrivateInvocationKeys = [string[]]@(
        $capturedPrivateInvocations | ForEach-Object {
            [string]$_.CommandElements[0].Index.Value
        })
    Assert-OrdinalSequence $actualCapturedPrivateInvocationKeys (
        $capturedPrivateInvocationKeys) (
        'Captured private verifier FunctionInfo invocation order drifted.')
    $launcherDynamicCommands = @($launcherCommands | Where-Object {
        [string]::IsNullOrEmpty($_.GetCommandName())
    })
    $expectedDynamicCommandOffsets = [long[]]@(
        [long]$dotSources[0].Extent.StartOffset,
        [long]$capturedPrivateInvocations[0].Extent.StartOffset,
        [long]$capturedPrivateInvocations[1].Extent.StartOffset,
        [long]$capturedInvocations[0].Extent.StartOffset)
    Assert-Preflight (
        $launcherDynamicCommands.Count -eq 4 -and
        @($launcherDynamicCommands | Where-Object {
            $expectedDynamicCommandOffsets -contains
                [long]$_.Extent.StartOffset
        }).Count -eq 4
    ) 'Launcher has a dynamic command outside the exact verifier load/private-parse/public-invoke set.'
    $expectedDynamicCommandElements = @(
        [pscustomobject]@{ Elements = [string[]]@(
            '$verifierBinding.Path') },
        [pscustomobject]@{ Elements = [string[]]@(
            '$capturedVerifierFunctions[''ConvertFrom-TL1C1bRealBuildSmokeSummaryJson'']',
            '-Raw', '$summaryRaw') },
        [pscustomobject]@{ Elements = [string[]]@(
            '$capturedVerifierFunctions[''Assert-TL1C1bRealBuildSmokeSummaryExactProperties'']',
            '-Value', '$summaryValue') },
        [pscustomobject]@{ Elements = [string[]]@(
            '$capturedVerifierFunction',
            '-Path', '$summaryPath',
            '-ExpectedParentDirectory', '$outputRoot',
            '-ExpectedCommitSha', '$expectedCommitSha',
            '-ExpectedHelperSha256', '$expectedHelperSha256',
            '-HelperProcessStartedNotBeforeUtc',
            '$helperProcessStartedNotBeforeUtc',
            '-HelperProcessExitedNotAfterUtc',
            '$helperProcessExitedNotAfterUtc',
            '-MaximumObserverTailSeconds', '$maximumObserverTailSeconds') }
    )
    $expectedDynamicRedirections = [string[]]@(
        '2>&1', '3>&1', '4>&1', '5>&1', '6>&1')
    $expectedDynamicAssignmentNames = [string[]]@(
        'verifierLoadOutput',
        'summaryParseOutput',
        'summaryPropertyAssertionOutput',
        'verifierOutput')
    for ($dynamicIndex = 0; $dynamicIndex -lt 4; $dynamicIndex++) {
        Assert-OrdinalSequence ([string[]]@(
                $launcherDynamicCommands[$dynamicIndex].CommandElements |
                ForEach-Object { Get-CompactAstText $_ })) (
            [string[]]$expectedDynamicCommandElements[$dynamicIndex].Elements) (
            "Launcher dynamic command elements drifted at index $dynamicIndex.")
        Assert-OrdinalSequence ([string[]]@(
                $launcherDynamicCommands[$dynamicIndex].Redirections |
                ForEach-Object { [string]$_.Extent.Text })) (
            $expectedDynamicRedirections) (
            "Launcher dynamic command redirections drifted at index $dynamicIndex.")
        $dynamicAssignments = @(Get-Assignments (
            $launcherParsed.Ast) $expectedDynamicAssignmentNames[$dynamicIndex])
        $dynamicBusinessAssignments = @($dynamicAssignments | Where-Object {
            $launcherDynamicCommands[$dynamicIndex].Extent.StartOffset -gt
                $_.Right.Extent.StartOffset -and
            $launcherDynamicCommands[$dynamicIndex].Extent.EndOffset -lt
                $_.Right.Extent.EndOffset
        })
        $dynamicInitializerCount = @($dynamicAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -ceq '$null'
        }).Count
        Assert-Preflight (
            @($dynamicAssignments | Where-Object {
                $_.Operator -ne
                    [Management.Automation.Language.TokenKind]::Equals
            }).Count -eq 0 -and
            $dynamicBusinessAssignments.Count -eq 1 -and
            (($dynamicIndex -eq 0 -and
              $dynamicAssignments.Count -eq 2 -and
              $dynamicInitializerCount -eq 1) -or
             ($dynamicIndex -ne 0 -and
              $dynamicAssignments.Count -eq 1 -and
              $dynamicInitializerCount -eq 0)) -and
            $launcherDynamicCommands[$dynamicIndex].Extent.StartOffset -gt
                $dynamicBusinessAssignments[0].Right.Extent.StartOffset -and
            $launcherDynamicCommands[$dynamicIndex].Extent.EndOffset -lt
                $dynamicBusinessAssignments[0].Right.Extent.EndOffset
        ) "Launcher dynamic command is not bound to its exact output assignment at index $dynamicIndex."
    }
    $invokeText = $capturedInvocations[0].Extent.Text
    foreach ($argument in @(
            '-Path',
            '-ExpectedParentDirectory',
            '-ExpectedCommitSha',
            '-ExpectedHelperSha256',
            '-HelperProcessStartedNotBeforeUtc',
            '-HelperProcessExitedNotAfterUtc',
            '-MaximumObserverTailSeconds',
            '$helperProcessStartedNotBeforeUtc',
            '$helperProcessExitedNotAfterUtc',
            '$maximumObserverTailSeconds')) {
        Assert-Text $invokeText $argument (
            "Captured verifier invocation is missing $argument.")
    }

    $nameAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'verifierFunctionNames')
    Assert-Preflight ($nameAssignments.Count -eq 1) (
        'Launcher verifierFunctionNames assignment is not unique.')
    $launcherVerifierNames = [string[]]@(
        $nameAssignments[0].Right.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
    Assert-OrdinalSequence $launcherVerifierNames $verifierFunctionNames (
        'Launcher exact 16 verifier names drifted.')
    $inlineVerifierFunctions = @(
        Get-Functions $launcherParsed.Ast | Where-Object {
            $verifierFunctionNames -ccontains $_.Name
        })
    Assert-Preflight ($inlineVerifierFunctions.Count -eq 0) (
        'Launcher contains an inline verifier function.')
    Assert-Preflight (
        $launcherBinding.Text -cnotmatch
            '(?i)Assert-PassedHelperSummary|verifier[_ -]?fallback'
    ) 'Launcher contains an inline or fallback verifier.'
    foreach ($needle in @(
            '$verifierLoadOutput',
            '$verifierLoadOutput.Count -ne 0',
            '.ScriptBlock.File',
            '.CommandType',
            '-All')) {
        Assert-Text $launcherBinding.Text $needle (
            "Launcher load/source proof is missing $needle.")
    }
    $getCommandAsts = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq
            'Microsoft.PowerShell.Core\Get-Command'
    })
    $dotOffset = $dotSources[0].Extent.StartOffset
    Assert-Preflight (
        @($getCommandAsts | Where-Object {
            $_.Extent.StartOffset -lt $dotOffset
        }).Count -ge 1
    ) 'Launcher lacks the pre-load verifier absence check.'
    Assert-Preflight (
        @($getCommandAsts | Where-Object {
            $_.Extent.StartOffset -gt $dotOffset
        }).Count -ge 1
    ) 'Launcher lacks the post-load verifier unique-source check.'

    foreach ($counter in @(
            'verifierLoadAttemptCount',
            'verifierLoadCount',
            'verifierSummaryParseAttemptCount',
            'verifierSummaryParseCount',
            'verifierInvokeAttemptCount',
            'verifierInvokeCount',
            'helperStartAttemptCount',
            'helperStartCount')) {
        $counterAssignments = @(Get-Assignments (
            $launcherParsed.Ast) $counter)
        Assert-Preflight (
            [long](Get-InitialLiteralAssignment (
                $launcherParsed.Ast) $counter) -eq 0L
        ) "Launcher counter $counter does not initialize to zero."
        Assert-Preflight (
            (Get-VariableWriteCount (
                $launcherParsed.Ast) $counter) -eq 2L -and
            @($counterAssignments | Where-Object {
                $_.Operator -ne
                    [Management.Automation.Language.TokenKind]::Equals
            }).Count -eq 0
        ) "Launcher counter $counter does not have exactly one mutation."
    }
    Assert-Preflight (
        [long](Get-LiteralAssignment (
            $launcherParsed.Ast) 'automaticRetryCount') -eq 0L -and
        (Get-VariableWriteCount (
            $launcherParsed.Ast) 'automaticRetryCount') -eq 1L
    ) 'Launcher automatic retry count is not immutable zero.'

    $memberCalls = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))
    $allStartCalls = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Start'
    })
    $processStarts = @($allStartCalls | Where-Object {
        $_.Expression -is
            [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Expression.VariablePath.UserPath -ceq 'process'
    })
    Assert-Preflight (
        $allStartCalls.Count -eq 1 -and $processStarts.Count -eq 1
    ) 'Launcher total Start surface is not one exact helper Process.Start.'
    $processConstructors = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'new' -and
        $_.Expression.Extent.Text -cmatch
            '\[(?:System\.)?Diagnostics\.Process\]'
    })
    Assert-Preflight ($processConstructors.Count -eq 1) (
        'Launcher Process constructor count is not exactly one.')
    $processStartOffset = $processStarts[0].Extent.StartOffset
    $lowerAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'helperProcessStartedNotBeforeUtc' | Where-Object {
            $_.Right.Extent.Text -cne '$null'
        })
    $upperAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'helperProcessExitedNotAfterUtc' | Where-Object {
            $_.Right.Extent.Text -cne '$null'
        })
    $successUpperAssignments = @($upperAssignments | Where-Object {
        $_.Extent.StartOffset -gt $processStartOffset -and
        $_.Extent.StartOffset -lt $capturedInvocations[0].Extent.StartOffset
    })
    Assert-Preflight (
        $lowerAssignments.Count -eq 1 -and
        $lowerAssignments[0].Extent.StartOffset -lt $processStartOffset -and
        $successUpperAssignments.Count -ge 1
    ) 'Launcher lower/start/upper/verifier ordering drifted.'
    $attemptMutations = @(Get-Assignments (
        $launcherParsed.Ast) 'helperStartAttemptCount' | Where-Object {
            $_.Right.Extent.Text -cne '0L'
        })
    $successMutations = @(Get-Assignments (
        $launcherParsed.Ast) 'helperStartCount' | Where-Object {
            $_.Right.Extent.Text -cne '0L'
        })
    Assert-Preflight (
        $attemptMutations.Count -eq 1 -and
        $successMutations.Count -eq 1 -and
        $attemptMutations[0].Extent.StartOffset -lt $processStartOffset -and
        $successMutations[0].Extent.StartOffset -gt $processStartOffset
    ) 'Launcher start-attempt/start-success counter ordering drifted.'

    $parameterlessWaits = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'WaitForExit' -and
        $_.Arguments.Count -eq 0
    })
    Assert-Preflight ($parameterlessWaits.Count -eq 0) (
        'Launcher contains parameterless WaitForExit.')
    Assert-Preflight (
        @($memberCalls | Where-Object {
            [string]$_.Member.Value -ceq 'WaitForExit' -and
            $_.Arguments.Count -eq 1
        }).Count -ge 1
    ) 'Launcher lacks bounded WaitForExit.'
    Assert-Preflight (
        $launcherBinding.Text -cnotmatch
            '(?i)\.ReadToEnd(?:Async)?\s*\('
    ) 'Launcher contains unbounded ReadToEnd capture.'
    foreach ($needle in @(
            '$helperDrainCompleted',
            '$captureCapBytes',
            'overflow',
            '$expectedStdoutBytes',
            '$summaryBytes',
            'FixedTimeEquals')) {
        Assert-Text $launcherBinding.Text $needle (
            "Launcher bounded capture or stdout binding is missing $needle.")
    }
    Assert-Preflight (
        $launcherBinding.Text -cmatch
            '(?s)\$expectedStdoutBytes\[\$expectedStdoutBytes\.Length\s*-\s*2\]\s*=\s*13.*?\$expectedStdoutBytes\[\$expectedStdoutBytes\.Length\s*-\s*1\]\s*=\s*10'
    ) 'Launcher stdout binding does not append exact CRLF bytes.'
    Assert-Preflight (
        $launcherBinding.Text -cmatch
            '(?i)stderr.{0,400}(?:Length|ByteLength).{0,160}-ne\s*0'
    ) 'Launcher does not require exact empty stderr.'

    # The helper is assigned to a kill-on-close Job Object before a named gate
    # is signaled. Tree completion is proven from the job active-process count.
    foreach ($jobNeedle in @(
            'CreateJobObjectW',
            'SetInformationJobObject',
            'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE',
            'AssignProcessToJobObject',
            'TerminateJobObject',
            'QueryInformationJobObject',
            'EventWaitHandle',
            'EventResetMode',
            'GetActiveProcessCount')) {
        Assert-Text $launcherBinding.Text $jobNeedle (
            "Launcher Job Object authority is missing $jobNeedle.")
    }
    $assignJobCalls = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'AssignProcess'
    })
    $gateSetCalls = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Set' -and
        $_.Expression.Extent.Text -ceq '$processGate'
    })
    Assert-Preflight (
        $assignJobCalls.Count -eq 1 -and
        $assignJobCalls[0].Arguments.Count -eq 2 -and
        $assignJobCalls[0].Arguments[0].Extent.Text -ceq '$helperJob' -and
        $assignJobCalls[0].Arguments[1].Extent.Text -ceq '$process.Handle' -and
        $assignJobCalls[0].Extent.StartOffset -gt $processStartOffset -and
        $gateSetCalls.Count -eq 1 -and
        $gateSetCalls[0].Extent.StartOffset -gt
            $assignJobCalls[0].Extent.StartOffset
    ) 'Launcher does not assign the child to the job before signaling its gate.'
    $jobCompletedAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'jobAssignmentCompleted' | Where-Object {
            $_.Right.Extent.Text -ceq '$true'
        })
    Assert-Preflight (
        $jobCompletedAssignments.Count -eq 1 -and
        $jobCompletedAssignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals -and
        $jobCompletedAssignments[0].Extent.StartOffset -gt
            $assignJobCalls[0].Extent.StartOffset -and
        $jobCompletedAssignments[0].Extent.StartOffset -lt
            $gateSetCalls[0].Extent.StartOffset
    ) 'Launcher does not record successful Job assignment before gate release.'
    $helperJobActiveCountCalls = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'GetActiveProcessCount' -and
        $_.Arguments.Count -eq 1 -and
        $_.Arguments[0].Extent.Text -ceq '$helperJob'
    })
    Assert-Preflight ($helperJobActiveCountCalls.Count -eq 2) (
        'Launcher helper Job active-process query count is not exactly two.')
    $activeCountSnapshotNames = [string[]]@(
        'helperJobValidationActiveProcessCount',
        'helperJobCleanupActiveProcessCount')
    $terminationSnapshotNames = [string[]]@(
        'helperChildTerminationValidationVerified',
        'helperChildTerminationCleanupVerified')
    for ($snapshotIndex = 0; $snapshotIndex -lt 2; $snapshotIndex++) {
        $countName = $activeCountSnapshotNames[$snapshotIndex]
        $countAssignments = @(Get-Assignments $launcherParsed.Ast $countName)
        $countBusinessAssignments = @($countAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -cne '$null'
        })
        Assert-Preflight (
            $countAssignments.Count -eq 2 -and
            @($countAssignments | Where-Object {
                $_.Operator -ne
                    [Management.Automation.Language.TokenKind]::Equals
            }).Count -eq 0 -and
            $countBusinessAssignments.Count -eq 1 -and
            (Get-CompactAstText $countBusinessAssignments[0].Right) -ceq
                '[long]([TL1C1bNextLauncherNativeV1]::GetActiveProcessCount($helperJob))' -and
            @($countBusinessAssignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ConvertExpressionAst]
            }, $true)).Count -eq 1 -and
            @($countBusinessAssignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ParenExpressionAst]
            }, $true)).Count -eq 1 -and
            @($helperJobActiveCountCalls | Where-Object {
                $_.Extent.StartOffset -gt
                    $countBusinessAssignments[0].Right.Extent.StartOffset -and
                $_.Extent.EndOffset -lt
                    $countBusinessAssignments[0].Right.Extent.EndOffset
            }).Count -eq 1
        ) "Launcher Job active-process snapshot is not one exact cast RHS: $countName"

        $terminationName = $terminationSnapshotNames[$snapshotIndex]
        $terminationAssignments = @(Get-Assignments (
            $launcherParsed.Ast) $terminationName)
        $terminationBusinessAssignments = @(
            $terminationAssignments | Where-Object {
                (Get-CompactAstText $_.Right) -cne '$false'
            })
        $expectedTerminationRhs = if ($snapshotIndex -eq 0) {
            '($helperRootExitConfirmed-and$helperJobValidationActiveProcessCount-eq0L)'
        }
        else {
            '[bool]($helperRootExitConfirmed-and$helperJobCleanupActiveProcessCount-eq0L)'
        }
        Assert-Preflight (
            $terminationAssignments.Count -eq 2 -and
            @($terminationAssignments | Where-Object {
                $_.Operator -ne
                    [Management.Automation.Language.TokenKind]::Equals
            }).Count -eq 0 -and
            $terminationBusinessAssignments.Count -eq 1 -and
            (Get-CompactAstText $terminationBusinessAssignments[0].Right) -ceq
                $expectedTerminationRhs -and
            $countBusinessAssignments[0].Extent.StartOffset -lt
                $terminationBusinessAssignments[0].Extent.StartOffset
        ) "Launcher child-termination snapshot is not bound to its own Job count: $terminationName"
    }
    $terminationValidationIfs = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        (Get-CompactAstText $node.Clauses[0].Item1) -ceq
            '-not$helperRootExitConfirmed-or-not$helperJobEmptyConfirmed-or-not$helperChildTerminationValidationVerified-or-not$helperDrainCompleted'
    }, $true))
    Assert-Preflight (
        $terminationValidationIfs.Count -eq 1 -and
        $terminationValidationIfs[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        $terminationValidationIfs[0].Clauses[0].Item2.Statements[0] -is
            [Management.Automation.Language.ThrowStatementAst]
    ) 'Launcher validation-time child termination snapshot is not an exact failure gate.'
    $processCleanupAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'processCleanup')
    $processCleanupInitialAssignments = @($processCleanupAssignments |
        Where-Object { (Get-CompactAstText $_.Right) -ceq "'not_started'" })
    $processCleanupCompletedAssignments = @($processCleanupAssignments |
        Where-Object {
            (Get-CompactAstText $_.Right) -ceq "'completed'"
        })
    Assert-Preflight (
        $processCleanupAssignments.Count -eq 2 -and
        @($processCleanupAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0 -and
        $processCleanupInitialAssignments.Count -eq 1 -and
        [object]::ReferenceEquals(
            $processCleanupInitialAssignments[0].Parent,
            $launcherParsed.Ast.EndBlock) -and
        $processCleanupCompletedAssignments.Count -eq 1 -and
        $processCleanupCompletedAssignments[0].Parent -is
            [Management.Automation.Language.StatementBlockAst] -and
        $processCleanupCompletedAssignments[0].Parent.Parent -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText (
            $processCleanupCompletedAssignments[0].Parent.Parent.
                Clauses[0].Item1)) -ceq
            '($null-eq$process-or$helperProcessDisposed)-and($null-eq$helperJob-or$helperJobDisposed)-and($null-eq$processGate-or$helperGateDisposed)-and($helperStartCount-eq0L-or($helperRootExitConfirmed-and$helperJobCleanupActiveProcessCount-eq0L-and$helperChildTerminationCleanupVerified))'
    ) 'Launcher process cleanup completion is not bound to root exit, cleanup Job zero, and cleanup child termination.'
    Assert-Preflight (
        $launcherBinding.Text -cnotmatch
            '\$helperJobActiveProcessCount(?![A-Za-z0-9_])' -and
        $launcherBinding.Text -cnotmatch
            '\$helperChildTerminationVerified(?![A-Za-z0-9_])'
    ) 'Launcher restored a shared validation/cleanup Job snapshot variable.'
    foreach ($identityNeedle in @(
            'GetFileInformationByHandleEx',
            'FILE_ID_INFO',
            'FILE_ID_128',
            'FileIdInfo = 18',
            'VolumeSerialNumber.ToString("X16")',
            'FileId.HighPart.ToString("X16")',
            'FileId.LowPart.ToString("X16")')) {
        Assert-Text $launcherBinding.Text $identityNeedle (
            "Launcher 128-bit NTFS identity authority is missing $identityNeedle.")
    }
    foreach ($publicationNeedle in @(
            '[IO.DriveType]::Fixed',
            '$directoryBindings.ContainsKey',
            "-Role 'result-publication-summary'",
            "-Role 'result-publication-log'",
            '$summaryBinding.Identity.StableId',
            '$logBinding.Identity.StableId')) {
        Assert-Text $launcherBinding.Text $publicationNeedle (
            "Launcher result-publication continuity authority is missing $publicationNeedle.")
    }

    $forbiddenLauncherCommands = [string[]]@(
        'Start-Process', 'Start-Job', 'Start-ThreadJob', 'Receive-Job',
        'Wait-Job', 'Invoke-Command', 'Enter-PSSession', 'New-PSSession',
        'Invoke-Expression', 'iex'
    )
    foreach ($command in $launcherCommands) {
        $name = [string]$command.GetCommandName()
        Assert-Preflight (
            $forbiddenLauncherCommands -cnotcontains $name
        ) "Launcher contains forbidden command surface: $name"
        if ($name -ceq 'ForEach-Object') {
            Assert-Preflight (
                $command.Extent.Text -cnotmatch '(?i)(?:^|\s)-Parallel(?:\s|$)'
            ) 'Launcher contains ForEach-Object -Parallel.'
        }
    }
    $launcherDefinedFunctionNames = [string[]]@(
        @(Get-Functions $launcherParsed.Ast) | ForEach-Object {
            [string]$_.Name
        })
    $launcherBuiltinCommands = [string[]]@(
        'Join-Path',
        'Microsoft.PowerShell.Core\Get-Command',
        'Microsoft.PowerShell.Management\Get-Item',
        'Microsoft.PowerShell.Management\Remove-Item',
        'Microsoft.PowerShell.Management\Test-Path',
        'Microsoft.PowerShell.Utility\Add-Type',
        'Microsoft.PowerShell.Utility\ConvertTo-Json',
        'Set-StrictMode'
    )
    $unexpectedLauncherCommands = [string[]]@(
        $launcherCommands | ForEach-Object {
            [string]$_.GetCommandName()
        } | Where-Object {
            -not [string]::IsNullOrEmpty($_) -and
            $launcherDefinedFunctionNames -cnotcontains $_ -and
            $launcherBuiltinCommands -cnotcontains $_
        } | Sort-Object -Unique)
    Assert-Preflight ($unexpectedLauncherCommands.Count -eq 0) (
        'Launcher has an unexpected command surface: ' +
        ($unexpectedLauncherCommands -join ', '))
    $launcherAddType = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq
            'Microsoft.PowerShell.Utility\Add-Type'
    })
    Assert-Preflight (
        $launcherAddType.Count -eq 1 -and
        $launcherAddType[0].Extent.Text -cmatch
            '(?s)(?:^|\s)-TypeDefinition\s+' -and
        $launcherAddType[0].Extent.Text -cnotmatch
            '(?i)(?:^|\s)-(?:Path|MemberDefinition)(?:\s|$)'
    ) 'Launcher Add-Type is not one literal TypeDefinition authority.'
    $launcherTypeDefinitionLiterals = @(
        $launcherAddType[0].CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.StringConstantExpressionAst] -and
            $_.StringConstantType -eq
                [Management.Automation.Language.StringConstantType]::SingleQuotedHereString
        })
    Assert-Preflight (
        $launcherAddType[0].CommandElements.Count -eq 3 -and
        $launcherAddType[0].CommandElements[1].Extent.Text -ceq '-TypeDefinition' -and
        $launcherTypeDefinitionLiterals.Count -eq 1 -and
        [object]::ReferenceEquals(
            $launcherAddType[0].CommandElements[2],
            $launcherTypeDefinitionLiterals[0])
    ) 'Launcher Add-Type TypeDefinition is not the exact literal argument.'

    # The r5 leaf keeps all r4 execution gates and statically closes the
    # early-failure diagnostics that the consumed 83121df smoke exposed.
    $launcherFunctions = @(Get-Functions $launcherParsed.Ast)
    $directoryChainFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Add-LauncherHeldDirectoryChain'
    })
    Assert-Preflight ($directoryChainFunctions.Count -eq 1) (
        'Launcher held-directory-chain function is not unique.')
    $directoryChainFunction = $directoryChainFunctions[0]
    $orderParameters = @(
        $directoryChainFunction.Body.ParamBlock.Parameters | Where-Object {
            [string]$_.Name.VariablePath.UserPath -ceq 'Order'
        })
    Assert-Preflight ($orderParameters.Count -eq 1) (
        'Launcher directory-chain Order parameter is not unique.')
    $orderAttributeNames = [string[]]@(
        $orderParameters[0].Attributes | ForEach-Object {
            [string]$_.TypeName.FullName
        })
    Assert-OrdinalSequence $orderAttributeNames (
        [string[]]@(
            'Parameter',
            'AllowEmptyCollection',
            'Collections.Generic.List[object]'
        )) (
        'Launcher Order parameter does not precisely allow the initial empty list.')
    Assert-Preflight (
        $orderParameters[0].Extent.Text -cmatch
            '(?s)\[Parameter\(Mandatory\)\]\s*\[AllowEmptyCollection\(\)\]\s*\[Collections\.Generic\.List\[object\]\]\$Order'
    ) 'Launcher AllowEmptyCollection is not bound precisely to Order.'

    $directoryIdentityFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherDirectoryIdentity'
    })
    $directoryHeldFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherHeldDirectoryBinding'
    })
    $handleFinalPathFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherHandleFinalPath'
    })
    $openHeldFileFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Open-LauncherHeldExactFile'
    })
    $assertHeldFileFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherHeldFileBinding'
    })
    Assert-Preflight (
        $directoryIdentityFunctions.Count -eq 1 -and
        $directoryHeldFunctions.Count -eq 1 -and
        $handleFinalPathFunctions.Count -eq 1 -and
        $openHeldFileFunctions.Count -eq 1 -and
        $assertHeldFileFunctions.Count -eq 1
    ) 'Launcher directory/file identity functions are not unique.'
    $directoryAuthorityText = [string]::Join(
        [Environment]::NewLine,
        [string[]]@(
            $directoryChainFunction.Extent.Text,
            $directoryIdentityFunctions[0].Extent.Text,
            $directoryHeldFunctions[0].Extent.Text,
            $handleFinalPathFunctions[0].Extent.Text
        ))
    foreach ($needle in @(
            'OpenDirectoryNoFollowDenyDelete',
            'ReparsePoint',
            'GetFinalDosPath',
            'StableId',
            '$Binding.Identity.StableId',
            'Handle = $handle',
            '$Order.Add($binding)',
            '$current.Dispose()')) {
        Assert-Text $directoryAuthorityText $needle (
            "Launcher retained directory authority is missing $needle.")
    }
    Assert-Preflight (
        $directoryAuthorityText -cnotmatch 'LastWriteTimeUtcFileTime'
    ) 'Launcher restored a directory timestamp equality gate.'
    foreach ($fileFunction in @(
            $openHeldFileFunctions[0],
            $assertHeldFileFunctions[0])) {
        Assert-Preflight (
            $fileFunction.Extent.Text -cmatch
                '(?s)LastWriteTimeUtcFileTime\s+-ne\s+.*?LastWriteTimeUtcFileTime'
        ) "Launcher file timestamp gate drifted in $($fileFunction.Name)."
    }

    $openHeldFileFunction = $openHeldFileFunctions[0]
    $expectedShaParameters = @(
        $openHeldFileFunction.Body.ParamBlock.Parameters | Where-Object {
            [string]$_.Name.VariablePath.UserPath -ceq 'ExpectedSha256'
        })
    Assert-Preflight (
        $expectedShaParameters.Count -eq 1 -and
        (Get-CompactAstText $expectedShaParameters[0]) -ceq
            '[AllowNull()][string]$ExpectedSha256'
    ) 'Launcher ExpectedSha256 is not the one optional string parameter.'
    $optionalExpectedShaGates = @($openHeldFileFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.UnaryExpressionAst] -and
        $node.TokenKind -eq [Management.Automation.Language.TokenKind]::Not -and
        $node.Child -is
            [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Child.Static -and
        $node.Child.Expression -is
            [Management.Automation.Language.TypeExpressionAst] -and
        [string]$node.Child.Expression.TypeName.FullName -ceq 'string' -and
        [string]$node.Child.Member.Value -ceq 'IsNullOrEmpty' -and
        $node.Child.Arguments.Count -eq 1 -and
        $node.Child.Arguments[0] -is
            [Management.Automation.Language.VariableExpressionAst] -and
        $node.Child.Arguments[0].VariablePath.IsUnqualified -and
        [string]$node.Child.Arguments[0].VariablePath.UserPath -ceq
            'ExpectedSha256'
    }, $true) | Sort-Object { $_.Extent.StartOffset })
    Assert-Preflight ($optionalExpectedShaGates.Count -eq 2) (
        'Launcher optional ExpectedSha256 predicate cardinality drifted.')
    foreach ($gate in $optionalExpectedShaGates) {
        Assert-Preflight (
            $gate.Parent -is
                [Management.Automation.Language.BinaryExpressionAst] -and
            [object]::ReferenceEquals($gate.Parent.Left, $gate) -and
            $gate.Parent.Operator -eq
                [Management.Automation.Language.TokenKind]::And
        ) 'Launcher optional ExpectedSha256 predicate escaped its direct -and gate.'
    }
    Assert-OrdinalSequence ([string[]]@(
            $optionalExpectedShaGates | ForEach-Object {
                Get-CompactAstText $_.Parent.Right
            })) ([string[]]@(
            '$ExpectedSha256-cnotmatch''\A[0-9a-f]{64}\z''',
            '$actualSha256-cne$ExpectedSha256'
        )) 'Launcher optional ExpectedSha256 right-hand gates drifted.'
    $legacyExpectedShaNullPredicates = @(
        $openHeldFileFunction.Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.BinaryExpressionAst] -and
            $node.Operator -eq [Management.Automation.Language.TokenKind]::Ine -and
            $node.Left -is
                [Management.Automation.Language.VariableExpressionAst] -and
            $node.Right -is
                [Management.Automation.Language.VariableExpressionAst] -and
            $node.Left.VariablePath.IsUnqualified -and
            $node.Right.VariablePath.IsUnqualified -and
            [string]$node.Left.VariablePath.UserPath -ceq 'null' -and
            [string]$node.Right.VariablePath.UserPath -ceq 'ExpectedSha256'
        }, $true))
    Assert-Preflight (
        $legacyExpectedShaNullPredicates.Count -eq 0 -and
        $launcherBinding.Text -cnotmatch
            '\$null\s+-ne\s+\$ExpectedSha256(?![A-Za-z0-9_])'
    ) 'Launcher restored the binder-broken `$null -ne $ExpectedSha256` predicate.'
    $launcherOptionalExpectedShaGuardsVerified = $true

    $openHeldAssignments = @($openHeldFileFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst]
    }, $true))
    $safeHandleAssignments = @($openHeldAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'safeHandle'
    } | Sort-Object { $_.Extent.StartOffset })
    $streamAssignments = @($openHeldAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'stream'
    } | Sort-Object { $_.Extent.StartOffset })
    Assert-OrdinalSequence ([string[]]@(
            $safeHandleAssignments | ForEach-Object {
                Get-CompactAstText $_.Right
            })) ([string[]]@(
            '$null',
            '[TL1C1bNextLauncherNativeV1]::OpenFileReadNoFollowDenyWriteDelete($full)',
            '$null'
        )) 'Launcher no-follow held SafeFileHandle transfer drifted.'
    Assert-OrdinalSequence ([string[]]@(
            $streamAssignments | ForEach-Object {
                Get-CompactAstText $_.Right
            })) ([string[]]@(
            '$null',
            '[IO.FileStream]::new($safeHandle,[IO.FileAccess]::Read,65536,$false)',
            '$null'
        )) 'Launcher held FileStream ownership transfer drifted.'
    $actualShaAssignments = @($openHeldAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'actualSha256'
    })
    Assert-Preflight (
        $actualShaAssignments.Count -eq 1 -and
        (Get-CompactAstText $actualShaAssignments[0].Right) -ceq
            '[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()'
    ) 'Launcher actual SHA-256 is no longer computed from the held stream.'
    $openHeldCommands = @(Get-Commands $openHeldFileFunction.Body)
    $heldFinalPathCommands = @($openHeldCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherHandleFinalPath'
    } | Sort-Object { $_.Extent.StartOffset })
    $heldFileIdentityCommands = @($openHeldCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherFileIdentity'
    } | Sort-Object { $_.Extent.StartOffset })
    Assert-Preflight (
        $heldFinalPathCommands.Count -eq 2 -and
        $heldFileIdentityCommands.Count -eq 2
    ) 'Launcher held-stream final-path or identity check cardinality drifted.'
    $stableIdConditions = @($openHeldFileFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst]
    }, $true) | Where-Object {
        (Get-CompactAstText $_.Clauses[0].Item1) -ceq
            '-not[StringComparer]::Ordinal.Equals([string]$initialIdentity.StableId,[string]$finalIdentity.StableId)-or[long]$initialIdentity.LastWriteTimeUtcFileTime-ne[long]$finalIdentity.LastWriteTimeUtcFileTime'
    })
    Assert-Preflight ($stableIdConditions.Count -eq 1) (
        'Launcher held-stream StableId/file-timestamp gate drifted.')
    $finalDosPathCalls = @($handleFinalPathFunctions[0].Body.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Static -and
        [string]$node.Member.Value -ceq 'GetFinalDosPath'
    }, $true))
    Assert-Preflight (
        $finalDosPathCalls.Count -eq 1 -and
        $finalDosPathCalls[0].Arguments.Count -eq 1 -and
        (Get-CompactAstText $finalDosPathCalls[0].Arguments[0]) -ceq '$Handle'
    ) 'Launcher final-path authority no longer reads the exact held handle.'
    $bindingAssignments = @($openHeldAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'binding'
    })
    Assert-Preflight (
        $bindingAssignments.Count -eq 1 -and
        $bindingAssignments[0].Extent.Text -cmatch '(?m)^\s*Guard\s*=\s*\$stream\s*$' -and
        $openHeldFileFunction.Extent.Text -cmatch
            '(?m)^\s*\$stream\s*=\s*\$null\s*$' -and
        $openHeldFileFunction.Extent.Text -cmatch
            '(?m)^\s*return\s+\$binding\s*$'
    ) 'Launcher held stream is not transferred into the returned binding guard.'
    $launcherHeldFileContinuityVerified = $true

    $fileIdentityFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherFileIdentity'
    })
    Assert-Preflight ($fileIdentityFunctions.Count -eq 1) (
        'Launcher Assert-LauncherFileIdentity is not unique.')
    $fileIdentityAssignments = @(
        $fileIdentityFunctions[0].Body.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst]
        }, $true))
    $directoryFlagAssignments = @($fileIdentityAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'directoryFlag'
    })
    $fileReparseFlagAssignments = @($fileIdentityAssignments | Where-Object {
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]$_.Left.VariablePath.UserPath -ceq 'reparseFlag'
    })
    Assert-Preflight (
        $directoryFlagAssignments.Count -eq 1 -and
        $fileReparseFlagAssignments.Count -eq 1 -and
        (Get-CompactAstText $directoryFlagAssignments[0].Right) -ceq
            '[uint32][IO.FileAttributes]::Directory' -and
        (Get-CompactAstText $fileReparseFlagAssignments[0].Right) -ceq
            '[uint32][IO.FileAttributes]::ReparsePoint'
    ) 'Launcher file identity directory/no-reparse flags drifted.'
    $heldFileIdentityCalls = @(
        Get-Commands $assertHeldFileFunctions[0].Body | Where-Object {
            [string]$_.GetCommandName() -ceq 'Assert-LauncherFileIdentity'
        })
    $heldIdentityCalls = @($heldFileIdentityCalls | Where-Object {
        @($_.CommandElements | Where-Object {
            $_ -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$_.VariablePath.UserPath -ceq 'heldIdentity'
        }).Count -eq 1
    })
    Assert-Preflight (
        $heldFileIdentityCalls.Count -eq 2 -and
        $heldIdentityCalls.Count -eq 1
    ) 'Launcher held-binding no-reparse identity call cardinality drifted.'
    $launcherFileIdentityNoReparseGateVerified = $true

    $mainExecutionTries = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
        $node.Body.Extent.StartOffset -lt $processStartOffset -and
        $node.Body.Extent.EndOffset -gt $processStarts[0].Extent.EndOffset
    }, $true))
    Assert-Preflight ($mainExecutionTries.Count -eq 1) (
        'Launcher main execution try containing Process.Start is not unique.')
    $mainExecutionTry = $mainExecutionTries[0]
    $summaryOpenCommands = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Open-LauncherHeldExactFile' -and
        $_.Extent.Text -cmatch "-Role\s+'summary'"
    })
    Assert-Preflight ($summaryOpenCommands.Count -eq 1) (
        'Launcher summary held-open command is not unique.')
    $summaryOpenElements = $summaryOpenCommands[0].CommandElements
    Assert-Preflight (
        $summaryOpenElements.Count -eq 11 -and
        [string]$summaryOpenElements[0].Value -ceq
            'Open-LauncherHeldExactFile' -and
        [string]$summaryOpenElements[1].ParameterName -ceq 'Role' -and
        [string]$summaryOpenElements[2].Value -ceq 'summary' -and
        [string]$summaryOpenElements[3].ParameterName -ceq 'Path' -and
        [string]$summaryOpenElements[4].VariablePath.UserPath -ceq
            'summaryPath' -and
        [string]$summaryOpenElements[5].ParameterName -ceq
            'ExpectedSha256' -and
        [string]$summaryOpenElements[6].VariablePath.UserPath -ceq 'null' -and
        [string]$summaryOpenElements[7].ParameterName -ceq
            'DirectoryBindings' -and
        [string]$summaryOpenElements[8].VariablePath.UserPath -ceq
            'directoryBindings' -and
        [string]$summaryOpenElements[9].ParameterName -ceq 'DirectoryOrder' -and
        [string]$summaryOpenElements[10].VariablePath.UserPath -ceq
            'directoryOrder'
    ) 'Launcher summary held-open call no longer passes exact -ExpectedSha256 $null.'
    $launcherSummaryUnpinnedShaOpenVerified = $true
    $summaryReadCommands = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Read-LauncherHeldFileBytes' -and
        $_.Extent.Text -cmatch '(?s)-MinimumLength\s+1L.*?-MaximumLength\s+65536L'
    })
    $stdoutFixedTimeEquals = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'FixedTimeEquals' -and
        $_.Extent.Text -cmatch '\$stdoutResult\.CapturedBytes'
    })
    $stdoutHashData = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'HashData' -and
        $_.Extent.Text -cmatch '\$expectedStdoutBytes'
    })
    $failureSummaryValidatorCommands = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq
            'Assert-LauncherFailureSummaryValue'
    })
    $launcherThrows = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ThrowStatementAst]
    }, $true))
    $derivedFailureThrows = @($launcherThrows | Where-Object {
        $_.Extent.Text -cmatch 'exact held helper summary reported failure'
    })
    $unknownStatusThrows = @($launcherThrows | Where-Object {
        $_.Extent.Text -cmatch 'neither exact passed nor exact failed'
    })
    $genericNonzeroThrows = @($launcherThrows | Where-Object {
        $_.Extent.Text -cmatch 'exited nonzero'
    })
    $genericStderrThrows = @($launcherThrows | Where-Object {
        $_.Extent.Text -cmatch 'stderr was not byte-empty'
    })
    Assert-Preflight (
        $summaryOpenCommands.Count -eq 1 -and
        $summaryReadCommands.Count -eq 1 -and
        $stdoutFixedTimeEquals.Count -eq 1 -and
        $stdoutHashData.Count -eq 1 -and
        $failureSummaryValidatorCommands.Count -eq 1 -and
        $derivedFailureThrows.Count -eq 1 -and
        $unknownStatusThrows.Count -eq 1 -and
        $genericNonzeroThrows.Count -eq 1 -and
        $genericStderrThrows.Count -eq 1
    ) 'Launcher failure-first summary validation nodes are not unique.'
    $failureFirstOffsets = [long[]]@(
        [long]$summaryOpenCommands[0].Extent.StartOffset,
        [long]$summaryReadCommands[0].Extent.StartOffset,
        [long]$stdoutFixedTimeEquals[0].Extent.StartOffset,
        [long]$stdoutHashData[0].Extent.StartOffset,
        [long]$capturedPrivateInvocations[0].Extent.StartOffset,
        [long]$capturedPrivateInvocations[1].Extent.StartOffset,
        [long]$failureSummaryValidatorCommands[0].Extent.StartOffset,
        [long]$derivedFailureThrows[0].Extent.StartOffset,
        [long]$unknownStatusThrows[0].Extent.StartOffset,
        [long]$genericNonzeroThrows[0].Extent.StartOffset,
        [long]$genericStderrThrows[0].Extent.StartOffset,
        [long]$capturedInvocations[0].Extent.StartOffset)
    for ($orderIndex = 1; $orderIndex -lt $failureFirstOffsets.Count;
            $orderIndex++) {
        Assert-Preflight (
            $failureFirstOffsets[$orderIndex] -gt
                $failureFirstOffsets[$orderIndex - 1]
        ) 'Launcher failure-first summary validation order drifted.'
    }
    foreach ($offset in $failureFirstOffsets) {
        Assert-Preflight (
            $offset -gt $mainExecutionTry.Body.Extent.StartOffset -and
            $offset -lt $mainExecutionTry.Body.Extent.EndOffset
        ) 'Launcher failure-first node escaped the one main execution try.'
    }
    foreach ($needle in @(
            "-Phase 'helper_root_deadline'",
            "-Phase 'helper_job_deadline'",
            '-Exception ([TimeoutException]::new($helperTimeoutReason))',
            'throw [TimeoutException]::new($helperTimeoutReason)',
            '$helperJobCleanupActiveProcessCount -eq 0L',
            '$helperChildTerminationCleanupVerified')) {
        Assert-Text $launcherBinding.Text $needle (
            "Launcher deadline-primary or cleanup-truth closure is missing $needle.")
    }
    Assert-Preflight (
        [regex]::Matches(
            $launcherBinding.Text,
            '(?s)Capture-LauncherPrimaryFailure[\s`]+-ErrorRecord\s+\$null.*?-Phase\s+''helper_(?:root|job)_deadline''.*?Stop-LauncherHelperJobBounded',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 2
    ) 'Launcher does not capture each deadline primary before bounded termination cleanup.'
    $deadlineStopOffsets = [Collections.Generic.List[long]]::new()
    foreach ($deadlinePhase in @(
            "'helper_root_deadline'", "'helper_job_deadline'")) {
        $deadlineCaptures = @($launcherCommands | Where-Object {
            [string]$_.GetCommandName() -ceq
                'Capture-LauncherPrimaryFailure' -and
            $_.CommandElements.Count -eq 7 -and
            (Get-CompactAstText $_.CommandElements[1]) -ceq '-ErrorRecord' -and
            (Get-CompactAstText $_.CommandElements[2]) -ceq '$null' -and
            (Get-CompactAstText $_.CommandElements[3]) -ceq '-Exception' -and
            (Get-CompactAstText $_.CommandElements[4]) -ceq
                '([TimeoutException]::new($helperTimeoutReason))' -and
            (Get-CompactAstText $_.CommandElements[5]) -ceq '-Phase' -and
            (Get-CompactAstText $_.CommandElements[6]) -ceq $deadlinePhase -and
            $_.Redirections.Count -eq 0
        })
        Assert-Preflight ($deadlineCaptures.Count -eq 1) (
            "Launcher deadline primary capture drifted: $deadlinePhase")
        $deadlineIf = $deadlineCaptures[0].Parent
        while ($null -ne $deadlineIf -and
            $deadlineIf -isnot [Management.Automation.Language.IfStatementAst]) {
            $deadlineIf = $deadlineIf.Parent
        }
        Assert-Preflight ($null -ne $deadlineIf) (
            "Launcher deadline capture lacks an enclosing failure branch: $deadlinePhase")
        $deadlineStops = @(Get-Commands $deadlineIf.Clauses[0].Item2 |
            Where-Object {
                [string]$_.GetCommandName() -ceq
                    'Stop-LauncherHelperJobBounded'
            })
        Assert-Preflight (
            $deadlineStops.Count -eq 1 -and
            $deadlineCaptures[0].Extent.StartOffset -lt
                $deadlineStops[0].Extent.StartOffset
        ) "Launcher deadline cleanup does not follow its exact primary capture: $deadlinePhase"
        $deadlineStopOffsets.Add([long]$deadlineStops[0].Extent.StartOffset)
    }
    $timeoutThrowIfs = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        (Get-CompactAstText $node.Clauses[0].Item1) -ceq '$helperTimedOut'
    }, $true))
    Assert-Preflight (
        $timeoutThrowIfs.Count -eq 1 -and
        $timeoutThrowIfs[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        (Get-CompactAstText (
            $timeoutThrowIfs[0].Clauses[0].Item2.Statements[0])) -ceq
            'throw[TimeoutException]::new($helperTimeoutReason)' -and
        @($deadlineStopOffsets | Where-Object {
            $_ -lt $timeoutThrowIfs[0].Extent.StartOffset
        }).Count -eq 2
    ) 'Launcher timeout throw does not preserve the earlier deadline primary through cleanup.'

    foreach ($needle in @(
            '$canonicalRepoRoot',
            '[StringComparer]::Ordinal.Equals($canonicalRepoRoot, $repoRoot)',
            '$ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path',
            '[Environment]::CurrentDirectory',
            '$currentFileSystemLocation, $repoRoot',
            '$environmentCurrentDirectory, $repoRoot',
            'Both PowerShell and process working directories must match the fixed repository root.')) {
        Assert-Text $launcherBinding.Text $needle (
            "Launcher fixed repository/CWD authority is missing $needle.")
    }
    Assert-Preflight (
        @($launcherCommands | Where-Object {
            [string]$_.GetCommandName() -ceq 'Set-Location'
        }).Count -eq 0
    ) 'Launcher mutates its working directory instead of verifying it.'

    $failurePublisherFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Publish-LauncherFailureSidecarCreateNew'
    })
    $exitFailedFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Exit-LauncherFailed'
    })
    $captureFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Capture-LauncherPrimaryFailure'
    })
    $mergeFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Merge-LauncherFailure'
    })
    $boundedTextFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Get-LauncherBoundedFailureText'
    })
    Assert-Preflight (
        $failurePublisherFunctions.Count -eq 1 -and
        $exitFailedFunctions.Count -eq 1 -and
        $captureFunctions.Count -eq 1 -and
        $mergeFunctions.Count -eq 1 -and
        $boundedTextFunctions.Count -eq 1
    ) 'Launcher failure-diagnostic functions are not unique.'
    $captureStatements = @($captureFunctions[0].Body.EndBlock.Statements)
    $mergeStatements = @($mergeFunctions[0].Body.EndBlock.Statements)
    $exitFailedStatements = @($exitFailedFunctions[0].Body.EndBlock.Statements)
    $exitFailedExitStatements = @($exitFailedFunctions[0].FindAll({
        param($node)
        $node -is [Management.Automation.Language.ExitStatementAst]
    }, $true))
    $exitFailedEarlyTerminators = @($exitFailedFunctions[0].FindAll({
        param($node)
        $node -is [Management.Automation.Language.ReturnStatementAst] -or
        $node -is [Management.Automation.Language.ThrowStatementAst] -or
        $node -is [Management.Automation.Language.BreakStatementAst] -or
        $node -is [Management.Automation.Language.ContinueStatementAst] -or
        $node -is [Management.Automation.Language.TrapStatementAst]
    }, $true))
    Assert-Preflight (
        $captureFunctions[0].Body.DynamicParamBlock -eq $null -and
        $captureFunctions[0].Body.BeginBlock -eq $null -and
        $captureFunctions[0].Body.ProcessBlock -eq $null -and
        $captureFunctions[0].Body.CleanBlock -eq $null -and
        $mergeFunctions[0].Body.DynamicParamBlock -eq $null -and
        $mergeFunctions[0].Body.BeginBlock -eq $null -and
        $mergeFunctions[0].Body.ProcessBlock -eq $null -and
        $mergeFunctions[0].Body.CleanBlock -eq $null -and
        $captureStatements.Count -eq 4 -and
        (Get-CompactAstText $captureStatements[0]) -ceq
            'if($null-ne$script:primaryFailureErrorRecord){return}' -and
        (Get-CompactAstText $captureStatements[2]) -ceq
            '$script:primaryFailureErrorRecord=$ErrorRecord' -and
        (Get-CompactAstText $captureStatements[3]) -ceq
            '$script:primaryFailurePhase=[string]$Phase' -and
        $mergeStatements.Count -eq 2 -and
        (Get-CompactAstText $mergeStatements[0]) -ceq
            'if($null-eq$Existing){return$Additional}' -and
        (Get-CompactAstText $mergeStatements[1]) -ceq
            'return[AggregateException]::new($Message,[Exception[]]@($Existing,$Additional))' -and
        $exitFailedFunctions[0].Body.DynamicParamBlock -eq $null -and
        $exitFailedFunctions[0].Body.BeginBlock -eq $null -and
        $exitFailedFunctions[0].Body.ProcessBlock -eq $null -and
        $exitFailedFunctions[0].Body.CleanBlock -eq $null -and
        $exitFailedStatements.Count -eq 5 -and
        (Get-CompactAstText $exitFailedStatements[0]) -ceq
            '$sidecarPublicationFailure=$null' -and
        $exitFailedStatements[1] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText $exitFailedStatements[1].Clauses[0].Item1) -ceq
            '-not$script:failureSidecarPublishAttempted' -and
        (Get-CompactAstText $exitFailedStatements[2]) -ceq
            '[Console]::Error.WriteLine($PrimaryException.ToString())' -and
        $exitFailedStatements[3] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText $exitFailedStatements[3].Clauses[0].Item1) -ceq
            '$null-ne$sidecarPublicationFailure' -and
        $exitFailedEarlyTerminators.Count -eq 0 -and
        $exitFailedExitStatements.Count -eq 1 -and
        [object]::ReferenceEquals(
            $exitFailedStatements[-1], $exitFailedExitStatements[0]) -and
        (Get-CompactAstText $exitFailedExitStatements[0]) -ceq 'exit1' -and
        [object]::ReferenceEquals(
            $exitFailedStatements[4], $exitFailedExitStatements[0])
    ) 'Launcher primary-first capture, merge, stderr, or exit-one contract drifted.'
    $failurePublisherText = $failurePublisherFunctions[0].Extent.Text
    foreach ($needle in @(
            "schema = 'tablet-layout-c1b-real-build-smoke-launcher-failure/v2'",
            "status = 'failed'",
            'success_eligible = $false',
            'pass_closure = $false',
            "evidence_role = 'diagnostic_failure_only'",
            "mode = 'CreateNew'",
            '[IO.FileMode]::CreateNew',
            '[IO.FileOptions]::WriteThrough',
            '$stream.Flush($true)',
            '[object]::ReferenceEquals',
            'exception_chain_stored_count',
            'exception_chain_observed_count',
            'exception_chain_truncated',
            'exception_chain_storage_limit',
            'exception_observation_limit',
            'exception_observation_limit_reached',
            'message_original_length',
            'message_stored_length',
            'message_truncated',
            'bounded_text_truncated_count',
            'helper_summary = [pscustomobject][ordered]@{',
            'verified = [bool]$script:helperFailureSummaryVerified',
            'status = $script:summaryStatus',
            'failure_count = [long]$script:helperFailureReasons.Count',
            'failure_reasons = [string[]]$script:helperFailureReasons')) {
        Assert-Text $failurePublisherText $needle (
            "Launcher failure sidecar authority is missing $needle.")
    }
    Assert-Preflight (
        [long](Get-LiteralAssignment (
            $failurePublisherFunctions[0]) 'maximumStoredExceptionCount') -eq 8L -and
        [long](Get-LiteralAssignment (
            $failurePublisherFunctions[0]) 'maximumObservedExceptionCount') -eq 256L
    ) 'Launcher exception-chain storage/observation limits drifted.'
    Assert-Preflight (
        [regex]::Matches(
            $failurePublisherText,
            '\[IO\.FileMode\]::CreateNew',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1 -and
        [regex]::Matches(
            $failurePublisherText,
            '\[IO\.FileOptions\]::WriteThrough',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1 -and
        [regex]::Matches(
            $failurePublisherText,
            '\$stream\.Flush\(\$true\)',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1
    ) 'Launcher failure sidecar durable CreateNew surface is not unique.'
    Assert-Preflight (
        $failurePublisherText -cnotmatch
            '(?is)if\s*\([^)]*resultPublished'
    ) 'Launcher suppresses a failure sidecar after result publication.'

    $sidecarEntryChecks = @($memberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'EntryExistsNoFollow' -and
        $_.Arguments.Count -eq 1 -and
        $_.Arguments[0].Extent.Text -ceq '$fullFailureSidecarPath'
    })
    Assert-Preflight (
        $sidecarEntryChecks.Count -eq 2 -and
        @($sidecarEntryChecks | Where-Object {
            $_.Extent.StartOffset -lt $processStartOffset
        }).Count -eq 2
    ) 'Launcher lacks exactly two no-follow sidecar guards before Process.Start.'

    $launcherCatchClauses = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.CatchClauseAst]
    }, $true))
    $capturingCatchCount = 0L
    $secondaryCatchClauses = [Collections.Generic.List[object]]::new()
    $primaryCaptureCommands = [Collections.Generic.List[object]]::new()
    $primaryCaptureCatchClauses = [Collections.Generic.List[object]]::new()
    foreach ($catchClause in $launcherCatchClauses) {
        $directCaptureCount = 0L
        $directCaptureCommands = [Collections.Generic.List[object]]::new()
        foreach ($captureCommand in @(
                (Get-Commands $catchClause.Body) | Where-Object {
                    [string]$_.GetCommandName() -ceq
                        'Capture-LauncherPrimaryFailure'
                })) {
            $ancestor = $captureCommand.Parent
            while ($null -ne $ancestor -and
                $ancestor -isnot
                    [Management.Automation.Language.CatchClauseAst]) {
                $ancestor = $ancestor.Parent
            }
            if ([object]::ReferenceEquals($ancestor, $catchClause)) {
                $directCaptureCount++
                $directCaptureCommands.Add($captureCommand)
            }
        }
        if ($directCaptureCount -eq 1L) {
            $capturingCatchCount++
            $primaryCaptureCommands.Add($directCaptureCommands[0])
            $primaryCaptureCatchClauses.Add($catchClause)
        }
        elseif ($directCaptureCount -eq 0L) {
            $secondaryCatchClauses.Add($catchClause)
        }
        else {
            throw 'A launcher catch captures the primary failure more than once.'
        }
    }
    $failureValidatorFunctions = @($launcherFunctions | Where-Object {
        $_.Name -ceq 'Assert-LauncherFailureSummaryValue'
    })
    Assert-Preflight ($failureValidatorFunctions.Count -eq 1) (
        'Launcher failure-summary validator function is not unique.')
    $failureValidatorText = $failureValidatorFunctions[0].Extent.Text
    foreach ($needle in @(
            '[long]([string]$reason).Length -gt 128L',
            '$reasonValues.Count -gt 38',
            '$expectedAdbBoundaryReasonCount',
            '$expectedResidueReasonCount',
            '$canonicalCanaryReasonCount',
            '$maximumObserverReasonCount',
            '$observerOmissionReasonCount',
            '$cleanupOmissionReasonCount',
            '$nonCanaryObserverReasonCount',
            'Failure summary closed-bound omission markers are not exact.',
            'Failure summary lacks an observer reason for a null observer timestamp.',
            'Failure summary missing-core cleanup acquisition order is unreachable.',
            'Failure summary missing-core Git provenance state is unreachable.')) {
        Assert-Text $failureValidatorText $needle (
            "Launcher failure-summary closed contract is missing $needle.")
    }
    Assert-Preflight (
        @($launcherCommands | Where-Object {
            [string]$_.GetCommandName() -ceq
                'Assert-LauncherFailureSummaryValue'
        }).Count -eq 1
    ) 'Launcher failure-summary validator invocation count is not exactly one.'
    $failureValidatorIfs = @($failureValidatorFunctions[0].FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst]
    }, $true))
    $omissionGateIfs = @($failureValidatorIfs | Where-Object {
        (Get-CompactAstText $_.Clauses[0].Item1) -ceq
            '$nonCanaryObserverReasonCount-gt17L-or(($nonCanaryObserverReasonCount-eq17L)-ne($observerOmissionReasonCount-eq1L))-or($nonCanaryObserverReasonCount-lt17L-and$observerOmissionReasonCount-ne0L)-or(($cleanupReasonCount-eq17L)-ne($cleanupOmissionReasonCount-eq1L))-or($cleanupReasonCount-lt17L-and$cleanupOmissionReasonCount-ne0L)'
    })
    $nullObserverOuterIfs = @($failureValidatorIfs | Where-Object {
        (Get-CompactAstText $_.Clauses[0].Item1) -ceq
            '$null-eq$observerEndedRaw'
    })
    Assert-Preflight (
        $omissionGateIfs.Count -eq 1 -and
        $omissionGateIfs[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        (Get-CompactAstText (
            $omissionGateIfs[0].Clauses[0].Item2.Statements[0])) -ceq
            "throw'Failuresummaryclosed-boundomissionmarkersarenotexact.'" -and
        $nullObserverOuterIfs.Count -eq 1 -and
        $nullObserverOuterIfs[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        (Get-CompactAstText (
            $nullObserverOuterIfs[0].Clauses[0].Item2.Statements[0])) -ceq
            "if((`$observerReasonCount-`$canonicalCanaryReasonCount)-eq0L){throw'Failuresummarylacksanobserverreasonforanullobservertimestamp.'}"
    ) 'Launcher failed-summary omission or null-observer contract is not exact AST.'
    $publisherSecondaryCatchClauses = @($secondaryCatchClauses | Where-Object {
        $_.Extent.StartOffset -gt $exitFailedFunctions[0].Extent.StartOffset -and
        $_.Extent.EndOffset -lt $exitFailedFunctions[0].Extent.EndOffset
    })
    $validatorSecondaryCatchClauses = @($secondaryCatchClauses | Where-Object {
        $_.Extent.StartOffset -gt
            $failureValidatorFunctions[0].Extent.StartOffset -and
        $_.Extent.EndOffset -lt
            $failureValidatorFunctions[0].Extent.EndOffset
    })
    Assert-Preflight (
        $launcherCatchClauses.Count -eq 29 -and
        @($launcherCatchClauses | Where-Object {
            $_.CatchTypes.Count -ne 0
        }).Count -eq 0 -and
        $capturingCatchCount -eq 26L -and
        $secondaryCatchClauses.Count -eq 3 -and
        $publisherSecondaryCatchClauses.Count -eq 1 -and
        $validatorSecondaryCatchClauses.Count -eq 2
    ) 'Launcher catch/primary/secondary cardinality is not exact 29/26/3 with one publisher and two validator catches.'
    $expectedPrimaryCapturePhases = [string[]]@(
        "'summary_held_file_read'",
        "(`$FailurePhase+'_atomic_write_readback')",
        "(`$FailurePhase+'_resource_cleanup')",
        "(`$FailurePhase+'_temporary_cleanup')",
        "(`$FailurePhase+'_buffer_cleanup')",
        "'helper_process_termination_request'",
        "'helper_job_termination_request'",
        "'helper_root_exit_confirmation'",
        "'helper_job_empty_confirmation'",
        '([string]$launcherPhase)',
        "'helper_termination_cleanup'",
        "'helper_stream_drain_cleanup'",
        "'helper_gate_cleanup'",
        "'helper_job_state_cleanup'",
        "'helper_job_dispose_cleanup'",
        "'helper_stdout_cleanup'",
        "'helper_stderr_cleanup'",
        "'helper_process_state_cleanup'",
        "'helper_process_dispose_cleanup'",
        "'log_publication'",
        "'sensitive_buffer_cleanup'",
        "'fixed_file_guard_cleanup'",
        "'directory_guard_cleanup'",
        "'result_publication'",
        "'result_publication_file_guard_cleanup'",
        "'result_publication_directory_guard_cleanup'")
    for ($captureIndex = 0;
        $captureIndex -lt $primaryCaptureCommands.Count;
        $captureIndex++) {
        $captureCommand = $primaryCaptureCommands[$captureIndex]
        Assert-OrdinalSequence ([string[]]@(
                $captureCommand.CommandElements[0..5] |
                ForEach-Object { Get-CompactAstText $_ })) ([string[]]@(
            'Capture-LauncherPrimaryFailure',
            '-ErrorRecord', '$_', '-Exception', '$null', '-Phase')) (
            "Launcher primary catch capture prefix drifted at index $captureIndex.")
        Assert-Preflight (
            $captureCommand.CommandElements.Count -eq 7 -and
            $captureCommand.Redirections.Count -eq 0 -and
            $captureCommand.InvocationOperator -eq
                [Management.Automation.Language.TokenKind]::Unknown -and
            (Get-CompactAstText $captureCommand.CommandElements[6]) -ceq
                $expectedPrimaryCapturePhases[$captureIndex] -and
            $captureCommand.Parent -is
                [Management.Automation.Language.PipelineAst] -and
            $captureCommand.Parent.PipelineElements.Count -eq 1 -and
            [object]::ReferenceEquals(
                $captureCommand.Parent.Parent,
                $primaryCaptureCatchClauses[$captureIndex].Body) -and
            [object]::ReferenceEquals(
                $captureCommand.Parent,
                $primaryCaptureCatchClauses[$captureIndex].Body.Statements[0])
        ) "Launcher catch does not preserve its original ErrorRecord as the first statement at index $captureIndex."
    }
    $secondaryCatchText = $publisherSecondaryCatchClauses[0].Extent.Text
    Assert-Preflight (
        $secondaryCatchText -cmatch
            '\$sidecarPublicationFailure\s*=\s*\$_\.Exception' -and
        $secondaryCatchText -cnotmatch
            'Capture-LauncherPrimaryFailure|Merge-LauncherFailure|primaryFailureErrorRecord|throw'
    ) 'Launcher publication catch is not secondary-only handling.'
    $validatorCatchThrowTexts = [string[]]@(
        $validatorSecondaryCatchClauses | ForEach-Object {
            Assert-Preflight (
                $_.Body.Statements.Count -eq 1 -and
                $_.Body.Statements[0] -is
                    [Management.Automation.Language.ThrowStatementAst]
            ) 'Launcher failure-summary validator catch is not one canonical throw.'
            Get-CompactAstText $_.Body.Statements[0]
        })
    Assert-OrdinalSequence $validatorCatchThrowTexts ([string[]]@(
        "throw'FailuresummarycontainsaninvalidUTCtimestamp.'",
        "throw'FailuresummarycontainsaninvalidobserverUTCtimestamp.'")) (
        'Launcher failure-summary validator catch reasons drifted.')

    $launcherTraps = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TrapStatementAst]
    }, $true))
    $launcherEndStatements = @($launcherParsed.Ast.EndBlock.Statements)
    $sharedFailureReadyAssignments = @(
        Get-Assignments $launcherParsed.Ast 'sharedFailurePipelineReady' |
            Sort-Object { $_.Extent.StartOffset })
    $sharedFailureReadyReferences = @($launcherParsed.Ast.FindAll({
        param($node)
        if ($node -isnot
                [Management.Automation.Language.VariableExpressionAst]) {
            return $false
        }
        $baseName = Get-GuardedVariableBaseName $node.VariablePath
        return $null -ne $baseName -and [string]::Equals(
            [string]$baseName,
            'sharedFailurePipelineReady',
            [StringComparison]::OrdinalIgnoreCase)
    }, $true))
    Assert-Preflight (
        $launcherTraps.Count -eq 1 -and
        [object]::ReferenceEquals(
            $launcherTraps[0].Parent, $launcherParsed.Ast.EndBlock) -and
        $null -eq $launcherTraps[0].TrapType -and
        $launcherTraps[0].Extent.StartOffset -lt
            $launcherAddType[0].Extent.StartOffset
    ) 'Launcher top-level untyped trap is not unique and defined before Add-Type.'
    $launcherTrapStatements = @($launcherTraps[0].Body.Statements)
    $bootstrapFailureGate = $launcherTrapStatements[0]
    $bootstrapFailureGateBody = if (
        $bootstrapFailureGate -is
            [Management.Automation.Language.IfStatementAst] -and
        $bootstrapFailureGate.Clauses.Count -eq 1) {
        $bootstrapFailureGate.Clauses[0].Item2
    }
    else { $null }
    $bootstrapFailureGateDisallowedAsts = @(
        if ($null -ne $bootstrapFailureGateBody) {
            $bootstrapFailureGateBody.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -or
                $node -is
                    [Management.Automation.Language.InvokeMemberExpressionAst] -or
                $node -is
                    [Management.Automation.Language.AssignmentStatementAst] -or
                $node -is [Management.Automation.Language.ExitStatementAst] -or
                $node -is [Management.Automation.Language.ThrowStatementAst] -or
                $node -is
                    [Management.Automation.Language.ContinueStatementAst] -or
                $node -is [Management.Automation.Language.ReturnStatementAst] -or
                $node -is [Management.Automation.Language.TrapStatementAst]
            }, $true)
        })
    Assert-Preflight (
        $launcherTrapStatements.Count -eq 5 -and
        $bootstrapFailureGate -is
            [Management.Automation.Language.IfStatementAst] -and
        $bootstrapFailureGate.Clauses.Count -eq 1 -and
        $null -eq $bootstrapFailureGate.ElseClause -and
        (Get-CompactAstText $bootstrapFailureGate.Clauses[0].Item1) -ceq
            '-not$script:sharedFailurePipelineReady' -and
        $bootstrapFailureGateBody.Statements.Count -eq 1 -and
        $bootstrapFailureGateBody.Statements[0] -is
            [Management.Automation.Language.BreakStatementAst] -and
        (Get-CompactAstText $bootstrapFailureGateBody.Statements[0]) -ceq
            'break' -and
        $bootstrapFailureGateDisallowedAsts.Count -eq 0 -and
        (Get-CompactAstText $launcherTrapStatements[1]) -ceq
            '$trappedErrorRecord=$_' -and
        (Get-CompactAstText $launcherTrapStatements[2]) -ceq
            'Capture-LauncherPrimaryFailure`-ErrorRecord$trappedErrorRecord-Exception$null`-Phase([string]$launcherPhase)' -and
        (Get-CompactAstText $launcherTrapStatements[3]) -ceq
            '$failure=Merge-LauncherFailure`-Existing$failure-Additional$trappedErrorRecord.Exception`-Message''Launcheraggregateandtop-leveltrapfailurebothoccurred.''' -and
        (Get-CompactAstText $launcherTrapStatements[4]) -ceq
            'Exit-LauncherFailed`-PrimaryErrorRecord$primaryFailureErrorRecord`-PrimaryException$failure'
    ) 'Launcher bootstrap trap break or ready-path failure chain is not exact.'
    Assert-Preflight (
        $sharedFailureReadyAssignments.Count -eq 2 -and
        @($sharedFailureReadyAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals -or
            -not [object]::ReferenceEquals(
                $_.Parent, $launcherParsed.Ast.EndBlock)
        }).Count -eq 0 -and
        (Get-CompactAstText $sharedFailureReadyAssignments[0]) -ceq
            '$sharedFailurePipelineReady=$false' -and
        (Get-CompactAstText $sharedFailureReadyAssignments[1]) -ceq
            '$sharedFailurePipelineReady=$true' -and
        (Get-VariableWriteCount (
                $launcherParsed.Ast) 'sharedFailurePipelineReady') -eq 2L -and
        $sharedFailureReadyReferences.Count -eq 3 -and
        [object]::ReferenceEquals(
            $launcherEndStatements[0],
            $sharedFailureReadyAssignments[0]) -and
        $launcherTraps[0].Extent.EndOffset -lt
            $sharedFailureReadyAssignments[1].Extent.StartOffset -and
        $sharedFailureReadyAssignments[1].Extent.EndOffset -lt
            $launcherAddType[0].Extent.StartOffset
    ) 'Launcher shared-failure readiness writes, references, or ordering drifted.'
    foreach ($trapFunction in @(
            $boundedTextFunctions[0],
            $captureFunctions[0],
            $mergeFunctions[0],
            $failurePublisherFunctions[0],
            $exitFailedFunctions[0])) {
        Assert-Preflight (
            $trapFunction.Extent.EndOffset -lt
                $sharedFailureReadyAssignments[1].Extent.StartOffset
        ) "Launcher trap dependency is defined after shared-failure readiness: $($trapFunction.Name)"
    }
    foreach ($needle in @(
            'Capture-LauncherPrimaryFailure',
            'Merge-LauncherFailure',
            'Exit-LauncherFailed',
            '-Existing $failure',
            '-Additional $trappedErrorRecord.Exception')) {
        Assert-Text $launcherTraps[0].Extent.Text $needle (
            "Launcher top-level trap is missing $needle.")
    }

    $passClosureAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'passClosure')
    $expectedPassClosureRhs = @'
($null-eq$failure-and$outputTargetsAbsent-and$runtimePwshReopenMatchesHeld-and$childPwshQueryImagePathMatchesHeld-and$verifierLoadAttemptCount-eq1L-and$verifierLoadCount-eq1L-and$verifierSummaryParseAttemptCount-eq1L-and$verifierSummaryParseCount-eq1L-and$verifierInvokeAttemptCount-eq1L-and$verifierInvokeCount-eq1L-and$helperStartAttemptCount-eq1L-and$helperStartCount-eq1L-and$helperReleaseCount-eq1L-and$automaticRetryCount-eq0L-and$helperGateSignalCount-eq1L-and$jobAssignmentCompleted-and-not$helperTimedOut-and$helperExitCode-eq0-and$helperRootExitConfirmed-and$helperJobEmptyConfirmed-and$helperChildTerminationValidationVerified-and$helperChildTerminationCleanupVerified-and$helperDrainCompleted-and$helperSummaryVerified-and-not$helperFailureSummaryVerified-and$helperFailureReasons.Count-eq0-and$summaryStatus-ceq'passed'-and$stdoutExactSummaryPlusCrLf-and$processCleanup-ceq'completed'-and$fixedFileGuardsCleanup-ceq'completed'-and$directoryGuardsCleanup-ceq'completed'-and$sensitiveBuffersCleanup-ceq'completed'-and$logPublished)
'@
    Assert-Preflight (
        $passClosureAssignments.Count -eq 1 -and
        $passClosureAssignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals -and
        (Get-CompactAstText $passClosureAssignments[0].Right) -ceq
            $expectedPassClosureRhs -and
        $passClosureAssignments[0].Right.Extent.Text -cnotmatch
            '(?i)failureSidecar|sidecar'
    ) 'Launcher failure sidecar is incorrectly part of pass closure.'
    foreach ($passGateVariable in @(
            'helperChildTerminationValidationVerified',
            'helperChildTerminationCleanupVerified')) {
        $passGateReferences = @($passClosureAssignments[0].Right.FindAll({
            param($node)
            $node -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$node.VariablePath.UserPath -ceq $passGateVariable
        }, $true))
        Assert-Preflight (
            $passGateReferences.Count -eq 1 -and
            $passClosureAssignments[0].Right.Extent.Text -cnotmatch
                ('(?i)-not\s+\$' + [regex]::Escape($passGateVariable))
        ) "Launcher pass closure does not consume exactly one $passGateVariable gate."
    }
    Assert-Preflight (
        [regex]::Matches(
            (Get-CompactAstText $passClosureAssignments[0].Right),
            [regex]::Escape("`$processCleanup-ceq'completed'"),
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1
    ) 'Launcher pass closure does not consume the exact completed process-cleanup gate.'
    $exitFailedText = $exitFailedFunctions[0].Extent.Text
    Assert-Preflight (
        $exitFailedText -cnotmatch '(?i)resultPublished' -and
        $launcherBinding.Text -cmatch
            '(?s)if\s*\(\s*\$null\s+-ne\s+\$failure\s*\)\s*\{\s*Exit-LauncherFailed'
    ) 'Launcher failure exit is suppressed by result publication state.'

    # Structural r6 assertions: exact top-level StrictMode, initialized trap
    # state, fail-closed sidecar guards, and direct catch-first capture.
    $launcherStrictModeCommands = @($launcherCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Set-StrictMode'
    })
    $sharedFailureReadyFinalStatementIndex = [Array]::IndexOf(
        $launcherEndStatements, $sharedFailureReadyAssignments[1])
    $sharedFailureReadyNextStatement = if (
        $sharedFailureReadyFinalStatementIndex -ge 0 -and
        $sharedFailureReadyFinalStatementIndex -lt
            ($launcherEndStatements.Count - 1)) {
        $launcherEndStatements[$sharedFailureReadyFinalStatementIndex + 1]
    }
    else { $null }
    Assert-Preflight (
        $launcherStrictModeCommands.Count -eq 1 -and
        $launcherStrictModeCommands[0].Extent.Text -ceq
            'Set-StrictMode -Version 3.0' -and
        $launcherStrictModeCommands[0].Parent -is
            [Management.Automation.Language.PipelineAst] -and
        [object]::ReferenceEquals(
            $launcherStrictModeCommands[0].Parent.Parent,
            $launcherParsed.Ast.EndBlock) -and
        $launcherEndStatements.Count -ge 3 -and
        (Get-CompactAstText $launcherEndStatements[1]) -ceq
            '$ErrorActionPreference=''Stop''' -and
        [object]::ReferenceEquals(
            $launcherEndStatements[2],
            $launcherStrictModeCommands[0].Parent) -and
        $sharedFailureReadyFinalStatementIndex -ge 3 -and
        $sharedFailureReadyFinalStatementIndex -lt
            ($launcherEndStatements.Count - 1) -and
        $sharedFailureReadyNextStatement -is
            [Management.Automation.Language.IfStatementAst] -and
        $sharedFailureReadyNextStatement.Clauses.Count -eq 1 -and
        (Get-CompactAstText (
            $sharedFailureReadyNextStatement.Clauses[0].Item1)) -ceq
            '-not[OperatingSystem]::IsWindows()' -and
        @($launcherEndStatements | Where-Object {
            $_.Extent.StartOffset -gt $launcherTraps[0].Extent.EndOffset -and
            $_.Extent.EndOffset -lt
                $sharedFailureReadyAssignments[1].Extent.StartOffset
        }).Count -eq 0 -and
        $launcherStrictModeCommands[0].Extent.EndOffset -lt
            $launcherAddType[0].Extent.StartOffset
    ) 'Launcher top-level readiness, StrictMode 3.0, or Windows-guard order drifted.'
    $launcherExitStatements = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ExitStatementAst]
    }, $true))
    $launcherTopLevelReturns = @($launcherParsed.Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.ReturnStatementAst]) {
            return $false
        }
        $ancestor = $node.Parent
        while ($null -ne $ancestor -and
            $ancestor -isnot
                [Management.Automation.Language.FunctionDefinitionAst]) {
            $ancestor = $ancestor.Parent
        }
        return $null -eq $ancestor
    }, $true))
    $terminalFailureIf = $launcherEndStatements[-2]
    $terminalExit = $launcherEndStatements[-1]
    $terminalFailureCommands = @(
        if ($terminalFailureIf -is
                [Management.Automation.Language.IfStatementAst]) {
            Get-Commands $terminalFailureIf.Clauses[0].Item2
        }
    )
    Assert-Preflight (
        $launcherExitStatements.Count -eq 2 -and
        $launcherTopLevelReturns.Count -eq 0 -and
        [object]::ReferenceEquals(
            $launcherExitStatements[0], $exitFailedExitStatements[0]) -and
        [object]::ReferenceEquals($launcherExitStatements[1], $terminalExit) -and
        $terminalExit -is [Management.Automation.Language.ExitStatementAst] -and
        (Get-CompactAstText $terminalExit) -ceq 'exit0' -and
        $terminalFailureIf -is
            [Management.Automation.Language.IfStatementAst] -and
        $terminalFailureIf.Clauses.Count -eq 1 -and
        (Get-CompactAstText $terminalFailureIf.Clauses[0].Item1) -ceq
            '$null-ne$failure' -and
        $terminalFailureIf.Clauses[0].Item2.Statements.Count -eq 1 -and
        $terminalFailureCommands.Count -eq 1 -and
        $terminalFailureCommands[0].Redirections.Count -eq 0
    ) 'Launcher terminal failure gate, top-level return absence, or final exit drifted.'
    Assert-OrdinalSequence ([string[]]@(
            $terminalFailureCommands[0].CommandElements |
            ForEach-Object { Get-CompactAstText $_ })) ([string[]]@(
        'Exit-LauncherFailed',
        '-PrimaryErrorRecord', '$primaryFailureErrorRecord',
        '-PrimaryException', '$failure')) (
        'Launcher terminal failure call arguments drifted.')

    $trapDependencyAsts = @(
        $boundedTextFunctions[0],
        $captureFunctions[0],
        $mergeFunctions[0],
        $failurePublisherFunctions[0],
        $exitFailedFunctions[0],
        $launcherTraps[0]
    )
    $trapScriptVariableCandidates = @(
        foreach ($dependencyAst in $trapDependencyAsts) {
            $dependencyAst.FindAll({
                param($node)
                $node -is
                    [Management.Automation.Language.VariableExpressionAst] -and
                $node.VariablePath.UserPath.StartsWith(
                    'script:', [StringComparison]::Ordinal)
            }, $true) | ForEach-Object {
                $_.VariablePath.UserPath.Substring(7)
            }
        })
    $trapScriptVariableNames = [string[]]@(
        $trapScriptVariableCandidates | Sort-Object -Unique)
    $expectedTrapScriptVariableNames = [string[]]@(
        @(
            'automaticRetryCount',
            'currentFileSystemLocation',
            'elevatedToken',
            'environmentCurrentDirectory',
            'expectedCommitSha',
            'failureSidecarPath',
            'failureSidecarPreexisting',
            'failureSidecarPublishAttempted',
            'failureSidecarPublished',
            'helperFailureReasons',
            'helperFailureSummaryVerified',
            'helperStartAttemptCount',
            'helperStartCount',
            'launcherPhase',
            'observedLauncherPath',
            'outputChainHeld',
            'outputTargetsAbsent',
            'primaryFailureErrorRecord',
            'primaryFailurePhase',
            'repoRoot',
            'resultPublished',
            'sharedFailurePipelineReady',
            'startedAtUtc'
            'summaryStatus'
        ) | Sort-Object)
    Assert-OrdinalSequence $trapScriptVariableNames (
        $expectedTrapScriptVariableNames) (
        'Launcher trap dependency script-variable set drifted.')
    $trapDependencyInitializerNames = [string[]]@(
        $expectedTrapScriptVariableNames | Where-Object {
            $_ -cne 'sharedFailurePipelineReady'
        })
    foreach ($initializedVariableName in [string[]]@(
            $trapDependencyInitializerNames + 'failure')) {
        $allowedScriptScopedAssignmentCount = if (
            $initializedVariableName -cin @(
                'primaryFailureErrorRecord',
                'primaryFailurePhase',
                'failureSidecarPublished',
                'failureSidecarPublishAttempted')) {
            1L
        }
        else { 0L }
        $preAddTypeInitializers = @(Get-Assignments `
                -Ast $launcherParsed.Ast `
                -VariableName $initializedVariableName `
                -AllowedScriptScopedAssignmentCount (
                    $allowedScriptScopedAssignmentCount) | Where-Object {
                [object]::ReferenceEquals(
                    $_.Parent, $launcherParsed.Ast.EndBlock) -and
                $_.Extent.EndOffset -lt
                    $sharedFailureReadyAssignments[1].Extent.StartOffset
            })
        Assert-Preflight ($preAddTypeInitializers.Count -eq 1) (
            "Launcher trap dependency lacks one top-level pre-readiness initializer: $initializedVariableName")
    }

    $sidecarGuardAssignments = @(Get-Assignments (
            $launcherParsed.Ast) 'failureSidecarPreexisting' | Where-Object {
            @($_.Right.FindAll({
                param($node)
                $node -is
                    [Management.Automation.Language.InvokeMemberExpressionAst] -and
                [string]$node.Member.Value -ceq 'EntryExistsNoFollow'
            }, $true)).Count -ne 0
        } | Sort-Object { $_.Extent.StartOffset })
    Assert-Preflight (
        $sidecarGuardAssignments.Count -eq 2 -and
        @($sidecarGuardAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0
    ) 'Launcher sidecar guard assignments are not exactly two equals assignments.'
    $expectedSidecarConditions = [string[]]@(
        '$summaryPreexisting-or$logPreexisting-or$resultPreexisting-or$failureSidecarPreexisting',
        '$failureSidecarPreexisting'
    )
    $expectedSidecarStages = [string[]]@(
        'output_absence',
        'failure_sidecar_absence_before_helper'
    )
    $sidecarGuardStatementIndexes = [Collections.Generic.List[int]]::new()
    for ($guardIndex = 0; $guardIndex -lt 2; $guardIndex++) {
        $guardAssignment = $sidecarGuardAssignments[$guardIndex]
        $guardCalls = @($guardAssignment.Right.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.InvokeMemberExpressionAst] -and
            [string]$node.Member.Value -ceq 'EntryExistsNoFollow'
        }, $true))
        Assert-Preflight (
            $guardCalls.Count -eq 1 -and
            $guardCalls[0].Arguments.Count -eq 1 -and
            $guardCalls[0].Arguments[0].Extent.Text -ceq
                '$fullFailureSidecarPath' -and
            $guardAssignment.Parent -is
                [Management.Automation.Language.StatementBlockAst]
        ) 'Launcher sidecar guard is not one assigned no-follow call.'
        $guardStatements = @($guardAssignment.Parent.Statements)
        $guardStatementIndex = [Array]::IndexOf(
            $guardStatements, $guardAssignment)
        $sidecarGuardStatementIndexes.Add($guardStatementIndex)
        Assert-Preflight (
            $guardStatementIndex -ge 1 -and
            $guardStatementIndex + 1 -lt $guardStatements.Count -and
            $guardStatements[$guardStatementIndex + 1] -is
                [Management.Automation.Language.IfStatementAst]
        ) 'Launcher sidecar guard is not followed immediately by a fail-closed if.'
        $guardIf = [Management.Automation.Language.IfStatementAst](
            $guardStatements[$guardStatementIndex + 1])
        Assert-Preflight (
            $guardIf.Clauses.Count -eq 1 -and
            $null -eq $guardIf.ElseClause -and
            (Get-CompactAstText $guardIf.Clauses[0].Item1) -ceq
                $expectedSidecarConditions[$guardIndex] -and
            $guardIf.Clauses[0].Item2.Statements.Count -eq 1 -and
            $guardIf.Clauses[0].Item2.Statements[0] -is
                [Management.Automation.Language.ThrowStatementAst]
        ) 'Launcher sidecar guard condition is not positive and fail-closed.'
        $stageAssignments = @(
            $guardStatements[0..($guardStatementIndex - 1)] |
                Where-Object {
                    $_ -is
                        [Management.Automation.Language.AssignmentStatementAst] -and
                    $_.Left -is
                        [Management.Automation.Language.VariableExpressionAst] -and
                    [string]$_.Left.VariablePath.UserPath -ceq
                        'launcherPhase'
                })
        Assert-Preflight (
            $stageAssignments.Count -ge 1 -and
            [string](Get-LiteralAssignment (
                $stageAssignments[-1]) 'launcherPhase') -ceq
                    $expectedSidecarStages[$guardIndex]
        ) 'Launcher sidecar guard phase binding drifted.'
    }
    Assert-Preflight (
        [object]::ReferenceEquals(
            $sidecarGuardAssignments[0].Parent,
            $sidecarGuardAssignments[1].Parent) -and
        $sidecarGuardAssignments[1].Extent.StartOffset -lt
            $processStartOffset
    ) 'Launcher sidecar guards are not in the one helper-start block.'
    $helperStartStatements = @($sidecarGuardAssignments[1].Parent.Statements)
    $secondGuardStatementIndex = $sidecarGuardStatementIndexes[1]
    $expectedPreStartStatementTexts = [string[]]@(
        '$failureSidecarPreexisting=[TL1C1bNextLauncherNativeV1]::EntryExistsNoFollow($fullFailureSidecarPath)',
        'if($failureSidecarPreexisting){throw''Failuresidecarappearedbeforetheone-shothelperstart.''}',
        '$process=[Diagnostics.Process]::new()',
        '$process.StartInfo=$startInfo',
        '$launcherPhase=''helper_start''',
        '$helperStartAttemptCount=1L',
        '$helperDeadlineStopwatch=[Diagnostics.Stopwatch]::StartNew()',
        '$helperProcessStartedNotBeforeUtc=[DateTimeOffset]::UtcNow',
        'if(-not$process.Start()){throw''Theone-shothelperbootstrapprocesscouldnotstart.''}'
    )
    for ($offset = 0; $offset -lt $expectedPreStartStatementTexts.Count;
            $offset++) {
        Assert-Preflight (
            (Get-CompactAstText (
                $helperStartStatements[$secondGuardStatementIndex + $offset])) -ceq
                $expectedPreStartStatementTexts[$offset]
        ) 'Launcher second sidecar guard is not immediately bound to helper start.'
    }

    foreach ($catchClause in $launcherCatchClauses) {
        $catchStatements = @($catchClause.Body.Statements)
        if ([object]::ReferenceEquals(
                $catchClause, $publisherSecondaryCatchClauses[0])) {
            Assert-Preflight (
                $catchStatements.Count -eq 1 -and
                $catchStatements[0] -is
                    [Management.Automation.Language.AssignmentStatementAst] -and
                (Get-CompactAstText $catchStatements[0]) -ceq
                    '$sidecarPublicationFailure=$_.Exception'
            ) 'Launcher secondary catch is not one exact assignment.'
            continue
        }
        if (@($validatorSecondaryCatchClauses | Where-Object {
                    [object]::ReferenceEquals($_, $catchClause)
                }).Count -eq 1) {
            Assert-Preflight (
                $catchStatements.Count -eq 1 -and
                $catchStatements[0] -is
                    [Management.Automation.Language.ThrowStatementAst]
            ) 'Launcher failure-summary validator catch is not one exact throw.'
            continue
        }
        $firstCatchCommands = @(
            Get-Commands $catchStatements[0])
        Assert-Preflight (
            $catchStatements.Count -ge 1 -and
            $catchStatements[0] -is
                [Management.Automation.Language.PipelineAst] -and
            $catchStatements[0].PipelineElements.Count -eq 1 -and
            $firstCatchCommands.Count -eq 1 -and
            [string]$firstCatchCommands[0].GetCommandName() -ceq
                'Capture-LauncherPrimaryFailure'
        ) 'A launcher primary catch does not capture as its first direct pipeline.'
    }

    $canonicalRepoAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'canonicalRepoRoot')
    $currentCwdAssignments = @(Get-Assignments (
            $launcherParsed.Ast) 'currentFileSystemLocation' | Where-Object {
            (Get-CompactAstText $_.Right) -cne '$null'
        })
    $environmentCwdAssignments = @(Get-Assignments (
            $launcherParsed.Ast) 'environmentCurrentDirectory' | Where-Object {
            (Get-CompactAstText $_.Right) -cne '$null'
        })
    Assert-Preflight (
        $canonicalRepoAssignments.Count -eq 1 -and
        $currentCwdAssignments.Count -eq 1 -and
        $environmentCwdAssignments.Count -eq 1 -and
        [object]::ReferenceEquals(
            $canonicalRepoAssignments[0].Parent,
            $launcherParsed.Ast.EndBlock) -and
        [object]::ReferenceEquals(
            $currentCwdAssignments[0].Parent,
            $launcherParsed.Ast.EndBlock) -and
        [object]::ReferenceEquals(
            $environmentCwdAssignments[0].Parent,
            $launcherParsed.Ast.EndBlock)
    ) 'Launcher repo/CWD assignments are not unique top-level statements.'
    Assert-Preflight (
        (Get-CompactAstText $canonicalRepoAssignments[0].Right) -ceq
            '[IO.Path]::GetFullPath($repoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)' -and
        (Get-CompactAstText $currentCwdAssignments[0].Right) -ceq
            '[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)' -and
        (Get-CompactAstText $environmentCwdAssignments[0].Right) -ceq
            '[IO.Path]::GetFullPath([Environment]::CurrentDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)'
    ) 'Launcher repo/CWD derivation AST drifted.'
    $canonicalStatementIndex = [Array]::IndexOf(
        $launcherEndStatements, $canonicalRepoAssignments[0])
    $currentCwdStatementIndex = [Array]::IndexOf(
        $launcherEndStatements, $currentCwdAssignments[0])
    Assert-Preflight (
        $launcherEndStatements[$canonicalStatementIndex + 1] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText (
            $launcherEndStatements[$canonicalStatementIndex + 1].
                Clauses[0].Item1)) -ceq
            '$repoRoot-cnotmatch''\A[A-Za-z]:\\''-or-not[StringComparer]::Ordinal.Equals($canonicalRepoRoot,$repoRoot)' -and
        [object]::ReferenceEquals(
            $launcherEndStatements[$currentCwdStatementIndex + 1],
            $environmentCwdAssignments[0]) -and
        $launcherEndStatements[$currentCwdStatementIndex + 2] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText (
            $launcherEndStatements[$currentCwdStatementIndex + 2].
                Clauses[0].Item1)) -ceq
            '-not[StringComparer]::OrdinalIgnoreCase.Equals($currentFileSystemLocation,$repoRoot)-or-not[StringComparer]::OrdinalIgnoreCase.Equals($environmentCurrentDirectory,$repoRoot)'
    ) 'Launcher repo/CWD fail-closed condition polarity or adjacency drifted.'

    $directoryIdentityStatements = @(
        $directoryIdentityFunctions[0].Body.EndBlock.Statements)
    Assert-Preflight (
        $directoryIdentityStatements.Count -eq 3 -and
        $directoryIdentityStatements[0] -is
            [Management.Automation.Language.AssignmentStatementAst] -and
        $directoryIdentityStatements[1] -is
            [Management.Automation.Language.AssignmentStatementAst] -and
        $directoryIdentityStatements[2] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText (
            $directoryIdentityStatements[2].Clauses[0].Item1)) -ceq
            '([uint32]$Identity.FileAttributes-band$directoryFlag)-eq0-or([uint32]$Identity.FileAttributes-band$reparseFlag)-ne0' -and
        $directoryIdentityStatements[2].Clauses[0].Item2.Statements.Count -eq
            1 -and
        $directoryIdentityStatements[2].Clauses[0].Item2.Statements[0] -is
            [Management.Automation.Language.ThrowStatementAst]
    ) 'Launcher directory no-reparse/directory-bit check is not a direct fail-closed AST.'
    $handleFinalPathStatements = @(
        $handleFinalPathFunctions[0].Body.EndBlock.Statements)
    Assert-Preflight (
        $handleFinalPathStatements.Count -eq 5 -and
        $handleFinalPathStatements[2] -is
            [Management.Automation.Language.IfStatementAst] -and
        $handleFinalPathStatements[4] -is
            [Management.Automation.Language.IfStatementAst] -and
        (Get-CompactAstText (
            $handleFinalPathStatements[2].Clauses[0].Item1)) -ceq
            '-not[StringComparer]::OrdinalIgnoreCase.Equals($fileSystemName,''NTFS'')' -and
        (Get-CompactAstText (
            $handleFinalPathStatements[4].Clauses[0].Item1)) -ceq
            '-not[StringComparer]::OrdinalIgnoreCase.Equals($actual.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),$expected.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))' -and
        $handleFinalPathStatements[2].Clauses[0].Item2.Statements[0] -is
            [Management.Automation.Language.ThrowStatementAst] -and
        $handleFinalPathStatements[4].Clauses[0].Item2.Statements[0] -is
            [Management.Automation.Language.ThrowStatementAst]
    ) 'Launcher held final-path/NTFS checks are not direct fail-closed ASTs.'

    $addDirectoryMemberCalls = @(
        $directoryChainFunction.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.InvokeMemberExpressionAst]
        }, $true))
    $addDirectoryCommands = @(Get-Commands $directoryChainFunction)
    $addOpenCalls = @($addDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'OpenDirectoryNoFollowDenyDelete'
    })
    $addReadIdentityCalls = @($addDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'ReadIdentity'
    })
    $addBindingCalls = @($addDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Add' -and
        $_.Expression.Extent.Text -ceq '$Bindings'
    })
    $addOrderCalls = @($addDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Add' -and
        $_.Expression.Extent.Text -ceq '$Order'
    })
    $addDisposeCalls = @($addDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Dispose' -and
        $_.Expression.Extent.Text -ceq '$handle'
    })
    $addAssertIdentityCommands = @($addDirectoryCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherDirectoryIdentity'
    })
    $addAssertFinalCommands = @($addDirectoryCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherHandleFinalPath'
    })
    $directoryBindingAssignments = @(Get-Assignments (
        $directoryChainFunction) 'binding')
    Assert-Preflight (
        $addOpenCalls.Count -eq 1 -and
        $addReadIdentityCalls.Count -eq 1 -and
        $addAssertIdentityCommands.Count -eq 1 -and
        $addAssertFinalCommands.Count -eq 1 -and
        $addBindingCalls.Count -eq 1 -and
        $addOrderCalls.Count -eq 1 -and
        $addDisposeCalls.Count -eq 1 -and
        $directoryBindingAssignments.Count -eq 1 -and
        (Get-CompactAstText $directoryBindingAssignments[0].Right) -ceq
            '[pscustomobject][ordered]@{Path=[string]$directoryHandle=$handleIdentity=$identity}' -and
        $addOpenCalls[0].Extent.StartOffset -lt
            $addReadIdentityCalls[0].Extent.StartOffset -and
        $addReadIdentityCalls[0].Extent.StartOffset -lt
            $addAssertIdentityCommands[0].Extent.StartOffset -and
        $addAssertIdentityCommands[0].Extent.StartOffset -lt
            $addAssertFinalCommands[0].Extent.StartOffset -and
        $addAssertFinalCommands[0].Extent.StartOffset -lt
            $addBindingCalls[0].Extent.StartOffset -and
        $addBindingCalls[0].Extent.StartOffset -lt
            $addOrderCalls[0].Extent.StartOffset
    ) 'Launcher directory held-handle acquisition/binding order drifted.'

    $heldDirectoryMemberCalls = @(
        $directoryHeldFunctions[0].FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.InvokeMemberExpressionAst]
        }, $true))
    $heldDirectoryCommands = @(Get-Commands $directoryHeldFunctions[0])
    $heldOpenCalls = @($heldDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'OpenDirectoryNoFollowDenyDelete'
    })
    $heldReadCalls = @($heldDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'ReadIdentity'
    })
    $heldDisposeCalls = @($heldDirectoryMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'Dispose' -and
        $_.Expression.Extent.Text -ceq '$current'
    })
    $heldIdentityCommands = @($heldDirectoryCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherDirectoryIdentity'
    })
    $heldFinalCommands = @($heldDirectoryCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Assert-LauncherHandleFinalPath'
    })
    $heldStableIfs = @($directoryHeldFunctions[0].FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        (Get-CompactAstText $node.Clauses[0].Item1) -ceq
            '-not[StringComparer]::Ordinal.Equals([string]$identity.StableId,[string]$Binding.Identity.StableId)'
    }, $true))
    Assert-Preflight (
        $heldOpenCalls.Count -eq 1 -and
        $heldReadCalls.Count -eq 1 -and
        $heldIdentityCommands.Count -eq 1 -and
        $heldFinalCommands.Count -eq 1 -and
        $heldStableIfs.Count -eq 1 -and
        $heldStableIfs[0].Clauses[0].Item2.Statements.Count -eq 1 -and
        $heldStableIfs[0].Clauses[0].Item2.Statements[0] -is
            [Management.Automation.Language.ThrowStatementAst] -and
        $heldDisposeCalls.Count -eq 1 -and
        $heldOpenCalls[0].Extent.StartOffset -lt
            $heldReadCalls[0].Extent.StartOffset -and
        $heldReadCalls[0].Extent.StartOffset -lt
            $heldIdentityCommands[0].Extent.StartOffset -and
        $heldIdentityCommands[0].Extent.StartOffset -lt
            $heldFinalCommands[0].Extent.StartOffset -and
        $heldFinalCommands[0].Extent.StartOffset -lt
            $heldStableIfs[0].Extent.StartOffset
    ) 'Launcher held-directory stable-ID/final-path revalidation AST drifted.'
    Assert-Preflight (
        $directoryAuthorityText -cnotmatch 'LastWriteTimeUtcFileTime'
    ) 'Launcher directory timestamp equality reappeared.'

    $fileMtimeIfs = @(
        @($openHeldFileFunctions[0], $assertHeldFileFunctions[0]) |
            ForEach-Object {
                $_.FindAll({
                    param($node)
                    $node -is
                        [Management.Automation.Language.IfStatementAst] -and
                    $node.Clauses[0].Item1.Extent.Text -cmatch
                        'LastWriteTimeUtcFileTime'
                }, $true)
            })
    $expectedFileMtimeConditions = [string[]]@(
        '-not[StringComparer]::Ordinal.Equals([string]$initialIdentity.StableId,[string]$finalIdentity.StableId)-or[long]$initialIdentity.LastWriteTimeUtcFileTime-ne[long]$finalIdentity.LastWriteTimeUtcFileTime',
        '-not[StringComparer]::Ordinal.Equals([string]$identity.StableId,[string]$Binding.Identity.StableId)-or[long]$identity.LastWriteTimeUtcFileTime-ne[long]$Binding.Identity.LastWriteTimeUtcFileTime',
        '-not[StringComparer]::Ordinal.Equals([string]$heldIdentity.StableId,[string]$Binding.Identity.StableId)-or[long]$heldIdentity.LastWriteTimeUtcFileTime-ne[long]$Binding.Identity.LastWriteTimeUtcFileTime'
    )
    Assert-Preflight ($fileMtimeIfs.Count -eq 3) (
        'Launcher held-file timestamp fail-closed check count drifted.')
    for ($mtimeIndex = 0; $mtimeIndex -lt 3; $mtimeIndex++) {
        Assert-Preflight (
            (Get-CompactAstText (
                $fileMtimeIfs[$mtimeIndex].Clauses[0].Item1)) -ceq
                $expectedFileMtimeConditions[$mtimeIndex] -and
            $fileMtimeIfs[$mtimeIndex].Clauses[0].Item2.Statements.Count -eq
                1 -and
            $fileMtimeIfs[$mtimeIndex].Clauses[0].Item2.Statements[0] -is
                [Management.Automation.Language.ThrowStatementAst]
        ) 'Launcher held-file timestamp/stable-ID condition is not direct fail-closed AST.'
    }

    Assert-Preflight (
        @($memberCalls | Where-Object {
            [string]$_.Member.Value -ceq 'Create' -and
            $_.Expression.Extent.Text -cmatch '(?i)ScriptBlock'
        }).Count -eq 0
    ) 'Launcher contains dynamic ScriptBlock.Create.'

    $childBootstrapAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'childBootstrapSource')
    Assert-Preflight ($childBootstrapAssignments.Count -eq 1) (
        'Launcher child bootstrap source assignment is not unique.')
    $childBootstrapLiterals = @(
        $childBootstrapAssignments[0].Right.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.StringConstantExpressionAst] -and
            $node.StringConstantType -eq
                [Management.Automation.Language.StringConstantType]::
                    SingleQuotedHereString
        }, $true))
    Assert-Preflight ($childBootstrapLiterals.Count -eq 1) (
        'Launcher child bootstrap is not one literal single-quoted here-string.')
    $childTokens = $null
    $childErrors = $null
    $childAst = [Management.Automation.Language.Parser]::ParseInput(
        [string]$childBootstrapLiterals[0].Value,
        [ref]$childTokens,
        [ref]$childErrors)
    Assert-Preflight ($childErrors.Count -eq 0) (
        'Launcher child bootstrap contains parse errors.')
    $childCommands = @(Get-Commands $childAst)
    $childStrictModeCommands = @($childCommands | Where-Object {
        [string]$_.GetCommandName() -ceq 'Set-StrictMode'
    })
    $childEndStatements = @($childAst.EndBlock.Statements)
    Assert-Preflight (
        $childStrictModeCommands.Count -eq 1 -and
        $childStrictModeCommands[0].Extent.Text -ceq
            'Set-StrictMode -Version 3.0' -and
        $childStrictModeCommands[0].Parent -is
            [Management.Automation.Language.PipelineAst] -and
        [object]::ReferenceEquals(
            $childStrictModeCommands[0].Parent.Parent,
            $childAst.EndBlock) -and
        $childEndStatements.Count -eq 5 -and
        (Get-CompactAstText $childEndStatements[0]) -ceq
            '$ErrorActionPreference=''Stop''' -and
        [object]::ReferenceEquals(
            $childEndStatements[1],
            $childStrictModeCommands[0].Parent) -and
        $childEndStatements[2] -is
            [Management.Automation.Language.AssignmentStatementAst] -and
        (Get-CompactAstText $childEndStatements[2]) -ceq
            '$gate=[Threading.EventWaitHandle]::OpenExisting($env:TL1C1B_LAUNCH_GATE)'
    ) 'Child bootstrap top-level StrictMode 3.0 is not unique and pre-side-effect.'
    $childRequiredModules = @(
        if ($null -ne $childAst.ScriptRequirements) {
            $childAst.ScriptRequirements.RequiredModules
        }
    )
    $childUsingModules = @($childAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.UsingStatementAst] -and
        $node.UsingStatementKind -eq
            [Management.Automation.Language.UsingStatementKind]::Module
    }, $true))
    Assert-Preflight (
        $childRequiredModules.Count -eq 0 -and $childUsingModules.Count -eq 0
    ) 'Launcher child bootstrap imports an unheld module.'
    $childHelperInvocations = @($childCommands | Where-Object {
        $_.InvocationOperator -eq
            [Management.Automation.Language.TokenKind]::Ampersand -and
        $_.Extent.Text -cmatch
            '\$env:TL1C1B_HELPER_PATH'
    })
    Assert-Preflight ($childHelperInvocations.Count -eq 1) (
        'Child bootstrap helper invocation count is not exactly one.')
    Assert-OrdinalSequence ([string[]]@(
            $childHelperInvocations[0].CommandElements |
            ForEach-Object { Get-CompactAstText $_ })) ([string[]]@(
        '([IO.Path]::GetFullPath($env:TL1C1B_HELPER_PATH))',
        '-RepoRoot', '([IO.Path]::GetFullPath($env:TL1C1B_REPO_ROOT))',
        '-ExpectedCommitSha', '$env:TL1C1B_EXPECTED_COMMIT',
        '-JavaHome', '([IO.Path]::GetFullPath($env:TL1C1B_JAVA_HOME))',
        '-GradleHome', '([IO.Path]::GetFullPath($env:TL1C1B_GRADLE_HOME))',
        '-AndroidSdkRoot',
        '([IO.Path]::GetFullPath($env:TL1C1B_ANDROID_SDK_ROOT))',
        '-SummaryPath', '([IO.Path]::GetFullPath($env:TL1C1B_SUMMARY_PATH))',
        '-GitPath', '([IO.Path]::GetFullPath($env:TL1C1B_GIT_PATH))')) (
        'Child bootstrap helper invocation arguments drifted.')
    Assert-Preflight ($childHelperInvocations[0].Redirections.Count -eq 0) (
        'Child bootstrap helper invocation unexpectedly redirects output.')
    Assert-Preflight (
        @($childCommands | Where-Object {
            [string]::IsNullOrEmpty($_.GetCommandName())
        }).Count -eq 1
    ) 'Child bootstrap has a dynamic command outside the exact helper invocation.'
    $childHelperTryStatements = @($childAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
        $node.Body.Extent.StartOffset -lt
            $childHelperInvocations[0].Extent.StartOffset -and
        $node.Body.Extent.EndOffset -gt
            $childHelperInvocations[0].Extent.EndOffset
    }, $true))
    Assert-Preflight (
        $childHelperTryStatements.Count -eq 1 -and
        $childHelperTryStatements[0].Body.Statements.Count -eq 2 -and
        $childHelperTryStatements[0].CatchClauses.Count -eq 1 -and
        $null -eq $childHelperTryStatements[0].Finally -and
        (Get-CompactAstText (
            $childHelperTryStatements[0].Body.Statements[1])) -ceq 'exit0' -and
        $childHelperTryStatements[0].CatchClauses[0].Body.Statements.Count -eq 2 -and
        (Get-CompactAstText (
            $childHelperTryStatements[0].CatchClauses[0].Body.Statements[0])) -ceq
            '[Console]::Error.WriteLine($_.Exception.ToString())' -and
        (Get-CompactAstText (
            $childHelperTryStatements[0].CatchClauses[0].Body.Statements[1])) -ceq
            'exit1' -and
        [string]$childBootstrapLiterals[0].Value -cnotmatch
            '\$LASTEXITCODE'
    ) 'Child bootstrap does not map exact helper fallthrough to exit 0 and terminating failure to exit 1.'
    $childMemberCalls = @($childAst.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))
    $childGateWaits = @($childMemberCalls | Where-Object {
        [string]$_.Member.Value -ceq 'WaitOne' -and
        $_.Expression.Extent.Text -ceq '$gate' -and
        $_.Arguments.Count -eq 1 -and
        $_.Arguments[0].Extent.Text -ceq '120000'
    })
    Assert-Preflight (
        $childGateWaits.Count -eq 1 -and
        $childGateWaits[0].Extent.StartOffset -lt
            $childHelperInvocations[0].Extent.StartOffset
    ) 'Child bootstrap does not wait on its named gate before helper invoke.'
    Assert-Preflight (
        @($childMemberCalls | Where-Object {
            [string]$_.Member.Value -cin @(
                'Start', 'Invoke', 'BeginInvoke', 'AddScript', 'CreateProcess')
        }).Count -eq 0
    ) 'Child bootstrap contains an extra managed execution surface.'
    $childUnexpectedCommands = [string[]]@(
        $childCommands | ForEach-Object {
            [string]$_.GetCommandName()
        } | Where-Object {
            -not [string]::IsNullOrEmpty($_) -and
            $_ -cnotin @('Set-StrictMode')
        } | Sort-Object -Unique)
    Assert-Preflight ($childUnexpectedCommands.Count -eq 0) (
        'Child bootstrap has an unexpected command surface: ' +
        ($childUnexpectedCommands -join ', '))
    foreach ($needle in @(
            "Environment['TL1C1B_LAUNCH_GATE']",
            "Environment['TL1C1B_HELPER_PATH']",
            '$gateName',
            '$helperBinding.Path',
            '-EncodedCommand')) {
        Assert-Text $launcherBinding.Text $needle (
            "Launcher child bootstrap binding is missing $needle.")
    }

    $beforeStartText = $launcherBinding.Text.Substring(0, $processStartOffset)
    foreach ($outputVariable in @(
            '$summaryPath', '$logPath', '$launcherResultPath')) {
        Assert-Text $beforeStartText $outputVariable (
            "Launcher does not inspect $outputVariable before start.")
    }
    Assert-Text $beforeStartText 'Test-Path' (
        'Launcher lacks a preexisting-output guard before Process.Start.')

    $requiredResultFields = [string[]]@(
        'schema',
        'status',
        'success_eligible_without_external_exit',
        'external_exit_zero_required',
        'failure_sidecar_absent_after_exit_required',
        'pre_publication_pass_closure',
        'final_status_authority',
        'bindings',
        'runtime_pwsh',
        'filesystem',
        'verifier',
        'helper',
        'streams',
        'outputs',
        'cleanup',
        'residual',
        'expected_sha256',
        'actual_sha256',
        'stable_id',
        'link_count',
        'load_attempt_count',
        'load_count',
        'summary_parse_attempt_count',
        'summary_parse_count',
        'invoke_attempt_count',
        'invoke_count',
        'captured_function_name',
        'accepted',
        'summary_status',
        'failure_summary_accepted',
        'start_attempt_count',
        'start_count',
        'release_after_job_assignment_count',
        'helper_gate_signal_count',
        'job_assignment_completed',
        'automatic_retry_count',
        'exit_code',
        'deadline_milliseconds',
        'kill_wait_milliseconds',
        'drain_wait_milliseconds',
        'timed_out',
        'kill_attempt_count',
        'kill_request_succeeded',
        'job_termination_attempt_count',
        'job_termination_request_succeeded',
        'root_exit_confirmed',
        'job_active_processes_zero',
        'job_validation_active_process_count',
        'job_cleanup_active_process_count',
        'helper_child_termination_validation_verified',
        'helper_child_termination_cleanup_verified',
        'process_started_not_before_utc',
        'process_exited_not_after_utc',
        'capture_cap_bytes_per_stream',
        'drain_completed',
        'stdout',
        'stderr',
        'total_byte_length',
        'captured_byte_length',
        'sha256',
        'overflowed',
        'forced_closed',
        'summary',
        'log',
        'result',
        'preexisting',
        'create_new_and_stdout_bound',
        'atomic_no_overwrite_published',
        'atomic_no_overwrite_requested',
        'process_job_gate',
        'fixed_file_guards',
        'ancestor_directory_guards',
        'sensitive_buffers',
        'cleanup_failure_count',
        'failure_count',
        'failure_reasons'
    )
    foreach ($field in $requiredResultFields) {
        Assert-Preflight (
            $launcherBinding.Text -cmatch (
                '(?m)^\s*' + [regex]::Escape($field) + '\s*=')
        ) "Launcher result is missing field $field."
    }
    $launcherResultAssignments = @(Get-Assignments (
        $launcherParsed.Ast) 'resultValue')
    Assert-Preflight (
        $launcherResultAssignments.Count -eq 1 -and
        $launcherResultAssignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals
    ) (
        'Launcher resultValue assignment is not unique.')
    $launcherResultAssignmentText =
        $launcherResultAssignments[0].Extent.Text
    foreach ($needle in @(
            "schema = 'tablet-layout-c1b-real-build-smoke-launcher/v3'",
            "'candidate_pass_requires_external_exit'",
            "else { 'failed' }",
            'success_eligible_without_external_exit = $false',
            'external_exit_zero_required = $true',
            'failure_sidecar_absent_after_exit_required = $true',
            "'external_exit_zero_and_failure_sidecar_absent_after_process_exit'")) {
        Assert-Text $launcherResultAssignmentText $needle (
            "Launcher result v3 external-exit authority is missing $needle.")
    }
    Assert-Preflight (
        $launcherResultAssignmentText -cnotmatch "(?m)\bstatus\s*=\s*'passed'"
    ) 'Launcher result claims passed before external exit observation.'
    $finallyBlocks = @($launcherParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TryStatementAst] -and
        $null -ne $node.Finally
    }, $true))
    $finallyText = [string]::Join(
        [Environment]::NewLine,
        [string[]]@($finallyBlocks | ForEach-Object {
            $_.Finally.Extent.Text
        }))
    foreach ($needle in @(
            'fileBindings',
            'directoryOrder',
            'helperJob',
            'processGate',
            'Dispose')) {
        Assert-Text $finallyText $needle (
            "Launcher finally cleanup is missing $needle.")
    }

    $launcherEvidence = [pscustomobject][ordered]@{
        parse_error_count = [long]$launcherParsed.ParseErrorCount
        frozen_template_sha256 = $expectedLauncherTemplateSha256
        rendered_nine_slot_template_reconstruction_verified =
            [bool]$launcherTemplateReconstructionVerified
        structural_checks_are_supplemental_to_frozen_template_hash = $true
        launcher_top_level_strict_mode_3_verified = $true
        child_top_level_strict_mode_3_verified = $true
        verifier_dot_source_count = [long]$dotSources.Count
        captured_private_function_info_invoke_count =
            [long]$capturedPrivateInvocations.Count
        captured_public_verifier_function_info_invoke_count =
            [long]$capturedInvocations.Count
        launcher_dynamic_command_count = [long]$launcherDynamicCommands.Count
        verifier_function_name_count = [long]$launcherVerifierNames.Count
        inline_verifier_function_count = [long]$inlineVerifierFunctions.Count
        verifier_fallback_count = 0L
        helper_process_start_count = [long]$processStarts.Count
        parameterless_wait_for_exit_count = [long]$parameterlessWaits.Count
        helper_deadline_milliseconds = $helperDeadlineMilliseconds
        helper_kill_wait_milliseconds = $helperKillWaitMilliseconds
        helper_drain_wait_milliseconds = $helperDrainWaitMilliseconds
        capture_cap_bytes = $captureCapBytes
        job_object_assign_before_gate_verified = $true
        job_kill_on_close_verified = $true
        job_active_process_zero_required = $true
        job_validation_and_cleanup_snapshots_are_distinct = $true
        failure_summary_held_parse_precedes_generic_exit_stderr = $true
        failure_summary_maximum_byte_length = 65536L
        result_schema_v3_candidate_requires_external_exit = $true
        forbidden_command_count = 0L
        lower_start_upper_order_verified = $true
        stdout_summary_crlf_binding_verified = $true
        stderr_empty_binding_verified = $true
        fixed_repository_root_and_cwd_verified = $true
        initial_empty_directory_order_explicitly_allowed = $true
        directory_stable_id_no_reparse_final_path_held_handle_verified = $true
        directory_timestamp_equality_count = 0L
        file_timestamp_equality_retained = $true
        optional_expected_sha256_empty_guard_count =
            [long]$optionalExpectedShaGates.Count
        legacy_expected_sha256_null_inequality_count =
            [long]$legacyExpectedShaNullPredicates.Count
        summary_open_expected_sha256_null_verified =
            [bool]$launcherSummaryUnpinnedShaOpenVerified
        held_file_hash_identity_no_reparse_final_path_and_guard_verified =
            [bool](
                $launcherHeldFileContinuityVerified -and
                $launcherFileIdentityNoReparseGateVerified)
        file_identity_directory_and_reparse_flags_unique =
            [bool]$launcherFileIdentityNoReparseGateVerified
        held_binding_held_identity_call_count =
            [long]$heldIdentityCalls.Count
        failure_sidecar_path = [IO.Path]::GetFullPath($failureSidecarPath)
        failure_sidecar_same_directory_dot_failure_json_verified = $true
        failure_sidecar_no_follow_checks_before_start =
            [long]$sidecarEntryChecks.Count
        catch_clause_count = [long]$launcherCatchClauses.Count
        primary_capturing_catch_count = [long]$capturingCatchCount
        secondary_only_publisher_catch_count =
            [long]$publisherSecondaryCatchClauses.Count
        failure_validator_canonical_catch_count =
            [long]$validatorSecondaryCatchClauses.Count
        top_level_trap_count = [long]$launcherTraps.Count
        trap_dependencies_defined_before_add_type = $true
        failure_exception_reference_deduplication_verified = $true
        failure_exception_counts_and_truncation_metadata_verified = $true
        failure_sidecar_create_new_write_through_flush_true_verified = $true
        failure_sidecar_not_suppressed_by_result_publication = $true
        failure_sidecar_excluded_from_pass_closure = $true
        bootstrap_unready_trap_break_verified = $true
        bootstrap_unready_sidecar_intentionally_unavailable = $true
        shared_failure_pipeline_false_true_transition_verified = $true
        trap_dependencies_precede_shared_failure_readiness = $true
        required_result_field_count = [long]$requiredResultFields.Count
        finally_cleanup_verified = $true
    }

    # Verifier static authority.
    $verifierFunctions = @(Get-Functions $verifierParsed.Ast)
    $actualVerifierNames = [string[]]@(
        $verifierFunctions | ForEach-Object { [string]$_.Name })
    Assert-OrdinalSequence $actualVerifierNames $verifierFunctionNames (
        'Verifier exact 16-function set or order drifted.')
    $verifierCommands = @(Get-Commands $verifierParsed.Ast)
    $verifierRequiredModules = @(
        if ($null -ne $verifierParsed.Ast.ScriptRequirements) {
            $verifierParsed.Ast.ScriptRequirements.RequiredModules
        }
    )
    $verifierUsingModules = @($verifierParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.UsingStatementAst] -and
        $node.UsingStatementKind -eq
            [Management.Automation.Language.UsingStatementKind]::Module
    }, $true))
    Assert-Preflight (
        $verifierRequiredModules.Count -eq 0 -and
        $verifierUsingModules.Count -eq 0 -and
        @($verifierCommands | Where-Object {
            [string]::IsNullOrEmpty($_.GetCommandName())
        }).Count -eq 0
    ) 'Verifier imports a module or contains a dynamic command.'
    $allowedVerifierCommands = [string[]]@(
        $verifierFunctionNames +
        @(
            'Microsoft.PowerShell.Management\Get-Item',
            'Microsoft.PowerShell.Utility\Add-Type',
            'Microsoft.PowerShell.Utility\ConvertFrom-Json'
        ))
    $unexpectedVerifierCommands = [string[]]@(
        $verifierCommands | ForEach-Object {
            [string]$_.GetCommandName()
        } | Where-Object {
            $allowedVerifierCommands -cnotcontains $_
        } | Sort-Object -Unique)
    Assert-Preflight ($unexpectedVerifierCommands.Count -eq 0) (
        'Verifier has an unexpected or unqualified command: ' +
        ($unexpectedVerifierCommands -join ', '))
    Assert-Preflight (
        @($verifierCommands | Where-Object {
            [string]$_.GetCommandName() -ceq
                'Microsoft.PowerShell.Utility\ConvertFrom-Json' -and
            $_.Extent.Text -cmatch
                '(?s)(?:^|\s)-DateKind\s+String(?:\s|$)'
        }).Count -eq 1
    ) 'Verifier lacks exactly one ConvertFrom-Json -DateKind String.'
    Assert-Preflight (
        @($verifierCommands | Where-Object {
            [string]$_.GetCommandName() -ceq 'Where-Object'
        }).Count -eq 0
    ) 'Verifier contains Where-Object.'
    $verifierAddType = @($verifierCommands | Where-Object {
        [string]$_.GetCommandName() -ceq
            'Microsoft.PowerShell.Utility\Add-Type'
    })
    Assert-Preflight (
        $verifierAddType.Count -eq 1 -and
        $verifierAddType[0].Extent.Text -cmatch
            '(?s)(?:^|\s)-TypeDefinition\s+' -and
        $verifierAddType[0].Extent.Text -cnotmatch
            '(?i)(?:^|\s)-(?:Path|MemberDefinition)(?:\s|$)'
    ) 'Verifier Add-Type is not one literal TypeDefinition authority.'
    $verifierTypeDefinitions = @(
        $verifierAddType[0].CommandElements | Where-Object {
            $_ -is
                [Management.Automation.Language.StringConstantExpressionAst] -and
            $_.StringConstantType -eq
                [Management.Automation.Language.StringConstantType]::
                    SingleQuotedHereString
        })
    Assert-Preflight ($verifierTypeDefinitions.Count -eq 1) (
        'Verifier TypeDefinition is not one literal single-quoted here-string.')
    Assert-Preflight (
        $verifierAddType[0].CommandElements.Count -eq 3 -and
        $verifierAddType[0].CommandElements[1].Extent.Text -ceq '-TypeDefinition' -and
        [object]::ReferenceEquals(
            $verifierAddType[0].CommandElements[2],
            $verifierTypeDefinitions[0])
    ) 'Verifier TypeDefinition literal is not the exact Add-Type argument.'
    Assert-Text $verifierBinding.Text (
        "'TL1C1bRealBuildSmokeFileIdentityV1' -as [type]") (
        'Verifier lacks the native-type preexistence check.')
    Assert-Text $verifierBinding.Text (
        'native authority type is already loaded') (
        'Verifier does not fail closed on a preloaded native type.')

    $dllImports = [regex]::Matches(
        $verifierBinding.Text,
        '(?s)\[DllImport\("(?<dll>[^"]+)".*?\)\]\s*private\s+static\s+extern\s+[^{;]+?\s+(?<name>[A-Za-z0-9_]+)\s*\(')
    $dllNames = [string[]]@($dllImports | ForEach-Object {
        [string]$_.Groups['name'].Value
    })
    Assert-OrdinalSequence $dllNames ([string[]]@(
        'GetFileInformationByHandle',
        'CreateFileW',
        'GetFinalPathNameByHandleW'
    )) 'Verifier native interop method set drifted.'
    foreach ($import in $dllImports) {
        Assert-Preflight (
            [string]$import.Groups['dll'].Value -ceq 'kernel32.dll'
        ) 'Verifier imports a non-kernel32 native library.'
    }
    Assert-Preflight (
        $verifierBinding.Text -cnotmatch
            '(?i)CreateProcess|ShellExecute|ProcessStartInfo|System\.Diagnostics\.Process|(?:^|[^A-Za-z0-9_])Process\s*\.\s*Start|NativeLibrary\s*\.\s*Load|Assembly\s*\.\s*Load|Start-Process|Start-Job|Start-ThreadJob|Invoke-Command|Invoke-Expression|ScriptBlock\s*::\s*Create'
    ) 'Verifier contains process, job, remoting, or dynamic-code capability.'

    $publicFunctions = @($verifierFunctions | Where-Object {
        $_.Name -ceq 'Assert-TL1C1bRealBuildSmokeSummaryFile'
    })
    Assert-Preflight ($publicFunctions.Count -eq 1) (
        'Verifier public file authority is not unique.')
    $publicParameters = [string[]]@(
        $publicFunctions[0].Body.ParamBlock.Parameters | ForEach-Object {
            [string]$_.Name.VariablePath.UserPath
        })
    Assert-OrdinalSequence $publicParameters ([string[]]@(
        'Path',
        'ExpectedParentDirectory',
        'ExpectedCommitSha',
        'ExpectedHelperSha256',
        'HelperProcessStartedNotBeforeUtc',
        'HelperProcessExitedNotAfterUtc',
        'MaximumObserverTailSeconds'
    )) 'Verifier public file parameter contract drifted.'
    foreach ($needle in @(
            '$MaximumObserverTailSeconds -gt 5.0',
            '$startedAt -lt $HelperProcessStartedNotBeforeUtc',
            '$completedAt -gt $HelperProcessExitedNotAfterUtc',
            '$observationEndedAt -le $startedAt',
            '$observationEndedAt -gt $completedAt',
            'Win32_ProcessStartTrace is operational observation, not a persistent kernel or syscall audit.')) {
        Assert-Text $verifierBinding.Text $needle (
            "Verifier parent/envelope/tail authority is missing $needle.")
    }
    Assert-Preflight (
        $verifierBinding.Text -cnotmatch
            '(?i)\[IO\.File\]::ReadAll(?:Bytes|Text)|Get-Content|StreamReader\s*\(\s*\$Path'
    ) 'Verifier contains a path reread instead of same-held-stream parsing.'
    Assert-Text $verifierBinding.Text (
        'OpenFileReadNoFollowDenyWriteDelete') (
        'Verifier lacks a no-follow deny-write/delete leaf open.')
    Assert-Text $verifierBinding.Text (
        'Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain') (
        'Verifier lacks held parent-chain verification.')

    $verifierEvidence = [pscustomobject][ordered]@{
        parse_error_count = [long]$verifierParsed.ParseErrorCount
        function_definition_count = [long]$verifierFunctions.Count
        command_ast_count = [long]$verifierCommands.Count
        unexpected_command_count = [long]$unexpectedVerifierCommands.Count
        convert_from_json_datekind_string_count = 1L
        where_object_count = 0L
        native_dllimport_count = [long]$dllImports.Count
        preloaded_native_type_fail_closed = $true
        module_qualified_cmdlets_verified = $true
        process_or_build_capability_count = 0L
        expected_parent_parameter_verified = $true
        helper_envelope_parameters_verified = $true
        maximum_observer_tail_seconds = 5.0
        exact_observer_limitation_verified = $true
        same_held_stream_verified = $true
    }

    # Helper static authority.
    Assert-Preflight (
        [string](Get-LiteralAssignment (
            $helperParsed.Ast) 'expectedSha') -ceq $expectedCommitSha
    ) 'Helper final commit literal drifted.'
    Assert-Text $helperBinding.Text $summaryLeaf (
        'Helper summary leaf literal drifted.')
    $libraryPathMap = Get-HashtableMap $helperParsed.Ast 'libraries'
    $libraryHashMap = Get-HashtableMap (
        $helperParsed.Ast) 'expectedLibraryHashes'
    $libraryMutationAssignments = @($helperParsed.Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) {
            return $false
        }
        return @($node.Left.FindAll({
            param($leftNode)
            $leftNode -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$leftNode.VariablePath.UserPath -ceq 'libraries'
        }, $true)).Count -ne 0
    }, $true))
    Assert-Preflight ($libraryMutationAssignments.Count -eq 1) (
        'Helper libraries map is reassigned or mutated after its exact literal definition.')
    $libraryHashMutationAssignments = @($helperParsed.Ast.FindAll({
        param($node)
        if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) {
            return $false
        }
        return @($node.Left.FindAll({
            param($leftNode)
            $leftNode -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]$leftNode.VariablePath.UserPath -ceq 'expectedLibraryHashes'
        }, $true)).Count -ne 0
    }, $true))
    Assert-Preflight ($libraryHashMutationAssignments.Count -eq 1) (
        'Helper library hash map is reassigned or mutated after its exact literal definition.')
    $pathKeys = [string[]]@($libraryPathMap.Keys)
    $hashKeys = [string[]]@($libraryHashMap.Keys)
    Assert-OrdinalSequence $pathKeys $helperLibraryKeys (
        'Helper seven-library path key set drifted.')
    Assert-OrdinalSequence $hashKeys $helperLibraryKeys (
        'Helper seven-library hash key set drifted.')
    $requiredKeyAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'requiredLibraryKeys')
    Assert-Preflight (
        $requiredKeyAssignments.Count -eq 1 -and
        $requiredKeyAssignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals
    ) (
        'Helper requiredLibraryKeys assignment is not unique.')
    $requiredKeys = [string[]]@(
        $requiredKeyAssignments[0].Right.FindAll({
            param($node)
            $node -is
                [Management.Automation.Language.StringConstantExpressionAst]
        }, $true) | ForEach-Object { [string]$_.Value })
    Assert-OrdinalSequence $requiredKeys $helperLibraryKeys (
        'Helper requiredLibraryKeys exact sequence drifted.')
    Assert-Text $helperBinding.Text (
        '$repositoryLibraryGuards.Count -ne 7') (
        'Helper does not require exactly seven held loader inputs.')

    $helperCommands = @(Get-Commands $helperParsed.Ast)
    $helperRequiredModules = @(
        if ($null -ne $helperParsed.Ast.ScriptRequirements) {
            $helperParsed.Ast.ScriptRequirements.RequiredModules
        }
    )
    $helperUsingModules = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.UsingStatementAst] -and
        $node.UsingStatementKind -eq
            [Management.Automation.Language.UsingStatementKind]::Module
    }, $true))
    Assert-Preflight (
        $helperRequiredModules.Count -eq 0 -and $helperUsingModules.Count -eq 0
    ) 'Helper imports an unheld module.'
    $allowedHelperCommands = [string[]]@(
        'Assert-TL1C1aGitProvenance',
        'Assert-TL1C1bAapt2TrustGuardUnchanged',
        'Assert-TL1C1bBuildEnvironmentFrozen',
        'Assert-TL1C1bReadOnlyArtifactProof',
        'Close-TL1C1bBuildEnvironmentTrustGuard',
        'ConvertFrom-Json',
        'ConvertFrom-TL1C1bClosedJson',
        'ConvertTo-Json',
        'ForEach-Object',
        'Get-CimInstance',
        'Get-Command',
        'Get-Event',
        'Get-EventSubscriber',
        'Get-Item',
        'Get-NetTCPConnection',
        'Get-SmokeAdbProcessSnapshot',
        'Get-SmokeDefaultAdbListenerSnapshot',
        'Get-SmokeFileSha256',
        'Get-TL1C1aFileSha256',
        'Get-TL1C1bBuildEnvironmentApkSignerInvocation',
        'Get-TL1C1bBuildEnvironmentBuildEnvironment',
        'Get-TL1C1bBuildEnvironmentGitEnvironment',
        'Get-TL1C1bBuildEnvironmentGradleArguments',
        'Get-TL1C1bBuildEnvironmentGradleInvocation',
        'Get-TL1C1bPackagedAxmlDumpBinding',
        'Invoke-SmokeBootstrapGit',
        'Invoke-TL1C1aProcess',
        'Invoke-TL1C1aProcessSmokeUnderlying',
        'Join-Path',
        'Open-SmokeHeldFile',
        'Open-TL1C1bAapt2TrustGuard',
        'Open-TL1C1bArtifactGuard',
        'Open-TL1C1bBuildEnvironmentTrustGuard',
        'Register-CimIndicationEvent',
        'Remove-Event',
        'Remove-Item',
        'Rename-Item',
        'Seal-TL1C1bBuildEnvironmentDebugKeystoreLock',
        'Set-StrictMode',
        'Sort-Object',
        'Start-Sleep',
        'Test-Path',
        'Test-SmokeOrdinalArgumentSequence',
        'Unregister-Event',
        'Where-Object'
    )
    $actualHelperCommands = [string[]]@(
        $helperCommands | ForEach-Object {
            [string]$_.GetCommandName()
        } | Where-Object {
            -not [string]::IsNullOrEmpty($_)
        } | Sort-Object -Unique)
    Assert-OrdinalSequence $actualHelperCommands $allowedHelperCommands (
        'Helper exact command surface drifted.')
    $helperDotSources = @($helperCommands | Where-Object {
        $_.InvocationOperator -eq
            [Management.Automation.Language.TokenKind]::Dot
    })
    Assert-Preflight ($helperDotSources.Count -eq 6) (
        'Helper library dot-source count is not exactly six.')
    Assert-Preflight (
        @($helperCommands | Where-Object {
            [string]::IsNullOrEmpty($_.GetCommandName())
        }).Count -eq 6
    ) 'Helper has a dynamic command outside its exact six held library loads.'
    $dotKeys = [string[]]@($helperDotSources | ForEach-Object {
        if ($_.Extent.Text -cmatch
                '\$libraries\.(?<key>[A-Za-z0-9_]+)') {
            [string]$Matches['key']
        }
        else { '' }
    })
    Assert-OrdinalSequence $dotKeys $helperDotSourceKeys (
        'Helper six dot-sourced library keys drifted.')
    Assert-Preflight ($dotKeys -cnotcontains 'runner') (
        'Helper dot-sources runner instead of only holding it.')

    $helperMembers = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is
            [Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))
    $summaryMoves = @($helperMembers | Where-Object {
        [string]$_.Member.Value -ceq 'Move' -and
        $_.Arguments.Count -eq 3 -and
        $_.Arguments[0].Extent.Text -ceq '$summaryTempPath' -and
        $_.Arguments[1].Extent.Text -ceq '$SummaryPath' -and
        $_.Arguments[2].Extent.Text -ceq '$false'
    })
    Assert-Preflight ($summaryMoves.Count -eq 1) (
        'Helper summary publish is not exactly one overwrite-false Move.')
    $createNewCount = [regex]::Matches(
        $helperBinding.Text,
        '\[IO\.FileMode\]::CreateNew',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    Assert-Preflight ($createNewCount -ge 1) (
        'Helper summary publication lacks CreateNew.')
    Assert-Preflight (
        $helperBinding.Text -cnotmatch
            '(?i)\bretry\b|Start-Job|Start-ThreadJob|Invoke-Command|ForEach-Object\s+-Parallel'
    ) 'Helper contains retry, job, remoting, or parallel surface.'
    foreach ($needle in @(
            '$script:SmokeGradleMainCount = 0L',
            '$script:SmokeGradleMainCount++',
            '$script:SmokeGradleMainCount -ne 1',
            '$script:SmokeDirectAdbAttemptCount = 0L',
            'install_attempt_count = 0L')) {
        Assert-Text $helperBinding.Text $needle (
            "Helper execution-count authority is missing $needle.")
    }
    Assert-Preflight (
        [regex]::Matches(
            $helperBinding.Text,
            '\$script:SmokeGradleMainCount\+\+',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 1
    ) 'Helper GradleMain increment site count is not exactly one.'
    $helperExitStatements = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.ExitStatementAst]
    }, $true))
    Assert-Preflight ($helperExitStatements.Count -eq 0) (
        'Helper contains an explicit exit that the exact bootstrap contract forbids.')
    Assert-Preflight (
        [long](Get-LiteralAssignment (
            $helperParsed.Ast) 'maximumObserverFailureReasons') -eq 16L -and
        [long](Get-LiteralAssignment (
            $helperParsed.Ast) 'maximumCleanupFailureReasons') -eq 16L
    ) 'Helper observer/cleanup failure-reason category bounds drifted.'
    $helperFinalFailureAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'finalFailures')
    $helperFinalFailureMemberCalls = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '$finalFailures'
    }, $true))
    $helperFinalFailureIndexReads = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IndexExpressionAst] -and
        $node.Target.Extent.Text -ceq '$finalFailures'
    }, $true))
    Assert-Preflight (
        $helperFinalFailureAssignments.Count -eq 1 -and
        $helperFinalFailureAssignments[0].Operator -eq
            [Management.Automation.Language.TokenKind]::Equals -and
        $helperFinalFailureMemberCalls.Count -eq 9 -and
        @($helperFinalFailureMemberCalls | Where-Object {
            [string]$_.Member.Value -ceq 'Add'
        }).Count -eq 9 -and
        $helperFinalFailureIndexReads.Count -eq 0
    ) 'Helper final failure list is reassigned, truncated, indexed, or mutated outside exact Add sites.'
    Assert-OrdinalSequence ([string[]]@(
            $helperFinalFailureMemberCalls | ForEach-Object {
                Assert-Preflight ($_.Arguments.Count -eq 1) (
                    'Helper final failure Add does not have one exact argument.')
                [string]$_.Arguments[0].Extent.Text
            })) ([string[]]@(
        '"observer: $($eventObservationFailures[[int]$failureIndex])"',
        '"observer: closed-bound omitted_count=$omittedObserverFailureCount."',
        "'ADB-zero boundary failed: direct attempt, process-start event, process snapshot, or TCP/5037 listener was nonzero.'",
        '"primary: $($primaryFailure.Message)"',
        '"cleanup: $($cleanupFailures[[int]$failureIndex])"',
        '"cleanup: closed-bound omitted_count=$omittedCleanupFailureCount."',
        "'core: real build smoke result is missing.'",
        '"observer: direct-child Java event canary expected 2, observed $($directJavaStartEvents.Count)."',
        "'residue: workspace, journal, module output, local.properties, or C1b Java process remained.'")) (
        'Helper final failure Add argument order or exact text drifted.')
    foreach ($needle in @(
            '[\u0000-\u001f\\"]',
            '$message.Length -gt 128',
            '$summaryBytes.Length -gt 65536',
            'C1b real build smoke summary exceeded the closed 1..65536-byte contract.')) {
        Assert-Text $helperBinding.Text $needle (
            "Helper closed summary byte/reason bound is missing $needle.")
    }
    $helperObservationEndAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'observationEndedAt')
    $helperObservationEndUtcAssignments = @(
        $helperObservationEndAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -ceq '[DateTime]::UtcNow'
        })
    $helperObservedEventAllAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'allObservedProcessStartEvents')
    $helperObservedEventInitialAssignments = @(
        $helperObservedEventAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -ceq '@()'
        })
    $helperObservedEventAssignments = @(
        $helperObservedEventAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -cne '@()'
        })
    $helperPostAdbAllAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'postAdbProcesses')
    $helperPostAdbInitialAssignments = @(
        $helperPostAdbAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -ceq '@()'
        })
    $helperPostAdbAssignments = @(
        $helperPostAdbAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -cne '@()'
        })
    $helperPostListenerAllAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'postDefaultAdbListeners')
    $helperPostListenerInitialAssignments = @(
        $helperPostListenerAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -ceq '@()'
        })
    $helperPostListenerAssignments = @(
        $helperPostListenerAllAssignments | Where-Object {
            (Get-CompactAstText $_.Right) -cne '@()'
        })
    $helperObservationCompletedAssignments = @(Get-Assignments (
        $helperParsed.Ast) 'postBoundaryAndResidueObservationCompleted')
    Assert-Preflight (
        $helperObservationEndAssignments.Count -eq 5 -and
        @($helperObservationEndAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0 -and
        $helperObservationEndUtcAssignments.Count -eq 3 -and
        $helperObservedEventAllAssignments.Count -eq 2 -and
        $helperObservedEventInitialAssignments.Count -eq 1 -and
        $helperObservedEventAssignments.Count -eq 1 -and
        $helperPostAdbAllAssignments.Count -eq 2 -and
        $helperPostAdbInitialAssignments.Count -eq 1 -and
        $helperPostAdbAssignments.Count -eq 1 -and
        $helperPostListenerAllAssignments.Count -eq 2 -and
        $helperPostListenerInitialAssignments.Count -eq 1 -and
        $helperPostListenerAssignments.Count -eq 1 -and
        $helperObservedEventInitialAssignments[0].Extent.StartOffset -lt
            $helperObservedEventAssignments[0].Extent.StartOffset -and
        $helperPostAdbInitialAssignments[0].Extent.StartOffset -lt
            $helperPostAdbAssignments[0].Extent.StartOffset -and
        $helperPostListenerInitialAssignments[0].Extent.StartOffset -lt
            $helperPostListenerAssignments[0].Extent.StartOffset -and
        @(@($helperObservedEventAssignments) +
          @($helperPostAdbAssignments) +
          @($helperPostListenerAssignments) | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0 -and
        $helperPostAdbAssignments[0].Extent.StartOffset -lt
            $helperObservationEndUtcAssignments[0].Extent.StartOffset -and
        $helperPostListenerAssignments[0].Extent.StartOffset -lt
            $helperObservationEndUtcAssignments[0].Extent.StartOffset -and
        @($helperObservationEndUtcAssignments | Where-Object {
            $_.Extent.StartOffset -lt
                $helperObservedEventAssignments[0].Extent.StartOffset
        }).Count -eq 3 -and
        [regex]::Matches(
            $helperBinding.Text,
            '(?s)\$eventUnregistered\s*=\s*\$true\s*\r?\n\s*\$observationEndedAt\s*=\s*\[DateTime\]::UtcNow',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count -eq 3 -and
        $helperObservationCompletedAssignments.Count -eq 2 -and
        @($helperObservationCompletedAssignments | Where-Object {
            $_.Operator -ne
                [Management.Automation.Language.TokenKind]::Equals
        }).Count -eq 0 -and
        (Get-VariableWriteCount (
            $helperParsed.Ast) 'postBoundaryAndResidueObservationCompleted') -eq 2L
    ) 'Helper observer end is not captured at the exact successful unsubscribe boundary.'
    $helperObserverIncompleteIfs = @($helperParsed.Ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses.Count -eq 1 -and
        (Get-CompactAstText $node.Clauses[0].Item1) -ceq
            '-not$eventObserverEstablished-or-not$eventUnregistered'
    }, $true))
    Assert-Preflight (
        $helperObserverIncompleteIfs.Count -eq 1 -and
        $helperObserverIncompleteIfs[0].Clauses[0].Item2.Statements.Count -eq 2 -and
        (Get-CompactAstText (
            $helperObserverIncompleteIfs[0].Clauses[0].Item2.Statements[0])) -ceq
            "if(`$eventObservationFailures.Count-eq0){`$eventObservationFailures.Add('C1bprocess-startobserverdidnotreachanestablishedandsuccessfullyunregisteredstate.')}" -and
        (Get-CompactAstText (
            $helperObserverIncompleteIfs[0].Clauses[0].Item2.Statements[1])) -ceq
            '$observationEndedAt=$null'
    ) 'Helper does not emit a non-canary observer reason before a null observer timestamp.'
    foreach ($needle in @(
            'C1b process-start observer subscriber was already absent before fallback shutdown.',
            'C1b post-boundary or residue observation did not complete.',
            'observer: closed-bound omitted_count=',
            'cleanup: closed-bound omitted_count=')) {
        Assert-Text $helperBinding.Text $needle (
            "Helper fail-closed observer completion evidence is missing $needle.")
    }
    Assert-Preflight (
        $helperBinding.Text -cmatch
            '(?s)TL1C1bImplementationPathMap\.Count\s+-ne\s+42.*?repositoryInputPaths\.Count\s+-ne\s+42'
    ) 'Helper does not pin the exact 42 implementation inputs.'

    foreach ($key in $helperLibraryKeys) {
        $paths = [string[]]@($libraryPathMap[$key] | Where-Object {
            $_ -cmatch '\.ps1\z'
        })
        $hashes = [string[]]@($libraryHashMap[$key] | Where-Object {
            $_ -cmatch '\Asha256:[0-9a-f]{64}\z'
        })
        Assert-Preflight (
            $paths.Count -eq 1 -and $hashes.Count -eq 1
        ) "Helper loader input $key lacks one path/hash literal."
        $full = [IO.Path]::GetFullPath((Join-Path $repoRoot $paths[0]))
        $prefix = [IO.Path]::GetFullPath($repoRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
        Assert-Preflight (
            $full.StartsWith($prefix, [StringComparison]::Ordinal)
        ) "Helper loader input $key escapes the repository."
        $binding = Open-HeldFile (
            $full) $hashes[0].Substring(7) (
                "helper repository loader input $key") $false $true
        $loaderBindings.Add($binding)
        $allFileBindings.Add($binding)
    }
    Assert-Preflight ($loaderBindings.Count -eq 7) (
        'Preflight did not hold/hash exactly seven helper loader inputs.')

    $helperEvidence = [pscustomobject][ordered]@{
        parse_error_count = [long]$helperParsed.ParseErrorCount
        final_commit_literal_verified = $true
        summary_leaf_verified = $true
        held_library_key_count = [long]$pathKeys.Count
        pinned_library_hash_count = [long]$hashKeys.Count
        repository_loader_input_binding_count = [long]$loaderBindings.Count
        repository_library_dot_source_count = [long]$helperDotSources.Count
        runner_dot_source_count = 0L
        summary_create_new_site_count = [long]$createNewCount
        summary_publish_move_count = [long]$summaryMoves.Count
        automatic_retry_surface_count = 0L
        gradlemain_increment_site_count = 1L
        exact_gradlemain_execution_required = $true
        explicit_exit_statement_count = [long]$helperExitStatements.Count
        observer_failure_reason_limit = 16L
        cleanup_failure_reason_limit = 16L
        failure_reason_character_limit = 128L
        final_failure_add_site_count =
            [long]$helperFinalFailureMemberCalls.Count
        post_primary_or_core_failure_list_truncation_count = 0L
        summary_byte_limit = 65536L
        observer_end_captured_at_unsubscribe_boundary = $true
        post_boundary_and_residue_observation_fail_closed = $true
        direct_adb_zero_required = $true
        install_attempt_zero_required = $true
        repository_input_count_contract_literal = 42L
        repository_input_files_individually_held_by_preflight = $false
    }

    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $gitInfoAttributesPath)
    ) 'Repository info/attributes appeared before final Git observation.'
    $gitInfoAttributesAbsentBeforeFinalGit = $true
    $gitWorktreeChanges = Invoke-ReadOnlyGit @(
        'ls-files', '--modified', '--others', '-z',
        ('--exclude-from=' + $gitIgnorePath),
        ('--exclude-from=' + $gitInfoExcludePath))
    Assert-Preflight ([string]::IsNullOrEmpty($gitWorktreeChanges)) (
        'Read-only Git reports modified, deleted, or non-excluded untracked worktree paths.')
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $gitInfoAttributesPath)
    ) 'Repository info/attributes appeared during final Git observation.'
    $gitInfoAttributesAbsentAfterFinalGit = $true
    $worktreeClean = $true
    $gitStateObservedAtUtc = [DateTimeOffset]::UtcNow
    Assert-Preflight ($gitInvocationCount -eq 4L) (
        'Read-only Git invocation count is not exactly four.')

    foreach ($binding in $allFileBindings) {
        Assert-HeldFileStillBound $binding
    }
    foreach ($chain in $directoryChains) {
        Assert-DirectoryChainStillBound $chain
    }
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $moduleBuildPath)
    ) 'The module build output appeared before primary guard release.'
    $moduleBuildAbsentBeforeGuardRelease = $true
    foreach ($candidate in @(
            $summaryPath, $logPath, $launcherResultPath)) {
        Assert-Preflight (
            -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
                EntryExistsNoFollow($candidate)
        ) "Candidate output appeared during static preflight: $candidate"
    }
    $finalOutputChildren = @(
        Microsoft.PowerShell.Management\Get-ChildItem @childItemParameters)
    foreach ($prefix in @(
            ".$summaryLeaf.", ".$logLeaf.", ".$launcherResultLeaf.")) {
        Assert-Preflight (
            @($finalOutputChildren | Where-Object {
                $_.Name.StartsWith($prefix, [StringComparison]::Ordinal)
            }).Count -eq 0
        ) "Candidate temporary prefix appeared during static preflight: $prefix"
    }
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $gitInfoAttributesPath)
    ) 'Repository info/attributes appeared before static inspection completed.'
    Assert-Preflight (
        -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $failureSidecarPath)
    ) 'The diagnostic failure sidecar appeared during static inspection.'
    $failureSidecarAbsentAtStaticInspectionEnd = $true
    $gitInfoAttributesAbsentAtStaticEnd = $true
    $gitInfoAttributesAbsentVerified = [bool](
        $gitInfoAttributesAbsentBeforeFinalGit -and
        $gitInfoAttributesAbsentAfterFinalGit -and
        $gitInfoAttributesAbsentAtStaticEnd)
    $gitIsolationVerified = $true
    Assert-Preflight ($primaryFileBindings.Count -eq 4) (
        'Four primary objects were not held through static inspection.')
    $primaryObjectsHeldThroughStaticInspection = $true
    $outputAbsenceObservedAtUtc = [DateTimeOffset]::UtcNow
    $passiveHostAdbStateSnapshots.Add((
        Get-PassiveHostAdbStateSnapshot -Stage 'static_inspection_end'))
}
catch {
    $failures.Add($_.Exception.ToString())
}
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    for ($index = $allFileBindings.Count - 1; $index -ge 0; $index--) {
        $binding = $allFileBindings[$index]
        if ($null -ne $binding.Bytes -and $binding.Bytes.Length -ne 0) {
            try { [Array]::Clear($binding.Bytes, 0, $binding.Bytes.Length) }
            catch {
                $cleanupFailures.Add(
                    "$($binding.Label) byte cleanup: $($_.Exception.ToString())")
            }
        }
        try { $binding.Stream.Dispose() }
        catch {
            $cleanupFailures.Add(
                "$($binding.Label) stream cleanup: $($_.Exception.ToString())")
        }
        for ($entryIndex = $binding.DirectoryChain.Entries.Count - 1;
                $entryIndex -ge 0; $entryIndex--) {
            try {
                $binding.DirectoryChain.Entries[$entryIndex].Handle.Dispose()
            }
            catch {
                $cleanupFailures.Add(
                    "$($binding.Label) ancestor cleanup: $($_.Exception.ToString())")
            }
        }
    }
    for ($chainIndex = $directoryChains.Count - 1;
            $chainIndex -ge 0; $chainIndex--) {
        $chain = $directoryChains[$chainIndex]
        for ($entryIndex = $chain.Entries.Count - 1;
                $entryIndex -ge 0; $entryIndex--) {
            try { $chain.Entries[$entryIndex].Handle.Dispose() }
            catch {
                $cleanupFailures.Add(
                    "$($chain.Label) cleanup: $($_.Exception.ToString())")
            }
        }
    }
    if ($cleanupFailures.Count -eq 0) {
        $guardCleanupCompleted = $true
        $primaryObjectGuardsReleasedBeforeReceiptPublication =
            $primaryObjectsHeldThroughStaticInspection
    }
    else {
        $script:prePublicationGuardCleanupFailureCount +=
            [long]$cleanupFailures.Count
        foreach ($cleanupFailure in $cleanupFailures) {
            $script:prePublicationGuardCleanupFailureReasons.Add(
                [string]$cleanupFailure)
            $failures.Add($cleanupFailure)
        }
    }
}

$primaryEvidence = [ordered]@{}
foreach ($label in @('launcher', 'helper', 'verifier', 'pinned pwsh')) {
    $binding = @($primaryFileBindings | Where-Object {
        $_.Label -ceq $label
    })
    $key = $label.Replace(' ', '_')
    $primaryEvidence[$key] = if ($binding.Count -eq 1) {
        ConvertTo-PathEvidence $binding[0]
    }
    else { $null }
}
$loaderEvidence = [object[]]@($loaderBindings | ForEach-Object {
    ConvertTo-PathEvidence $_
})
$receiptParentCleanupFailure = $null
$outputGuardCleanupFailure = $null
$moduleBuildGuardCleanupFailure = $null
$outputGuardCleanupFailures = [Collections.Generic.List[string]]::new()
$moduleBuildGuardCleanupFailures = [Collections.Generic.List[string]]::new()
$receiptGuardCleanupFailures = [Collections.Generic.List[string]]::new()
$recordingFailures = [Collections.Generic.List[string]]::new()
$receiptPublished = $false
try {
try {
    $originalOutputChains = @($directoryChains | Where-Object {
        $_.Label -ceq 'output root'
    })
    if ($originalOutputChains.Count -ne 1) {
        throw 'Original output parent chain evidence is not unique.'
    }
    $outputReceiptDirectoryChain = Open-DirectoryChain (
        $outputRoot) 'receipt-time output root'
    if ($outputReceiptDirectoryChain.Entries.Count -ne
            $originalOutputChains[0].Entries.Count) {
        throw 'Receipt-time output chain length drifted.'
    }
    for ($index = 0; $index -lt $outputReceiptDirectoryChain.Entries.Count;
            $index++) {
        $currentEntry = $outputReceiptDirectoryChain.Entries[$index]
        $originalEntry = $originalOutputChains[0].Entries[$index]
        if ($currentEntry.Path -cne $originalEntry.Path -or
            $currentEntry.Identity.StableId -cne $originalEntry.Identity.StableId) {
            throw 'Receipt-time output chain does not match the original held identity.'
        }
    }
    $outputMutationGuard = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
        OpenDirectoryDenyWriteDelete($outputRoot)
    $outputMutationIdentity = [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
        $outputMutationGuard)
    Assert-Identity $outputMutationIdentity $true (
        'receipt-time output directory handle') $true
    Assert-FinalPath $outputMutationGuard $outputRoot (
        'receipt-time output directory handle')
    if ($outputMutationIdentity.StableId -cne
            $outputReceiptDirectoryChain.Entries[
                $outputReceiptDirectoryChain.Entries.Count - 1].Identity.StableId) {
        throw 'Receipt-time output directory handle identity drifted.'
    }
    $outputParentHeldDuringCreate = $true
}
catch {
    $failures.Add($_.Exception.ToString())
}
try {
    $originalModuleBuildParentChains = @($directoryChains | Where-Object {
        $_.Label -ceq 'module build parent'
    })
    if ($originalModuleBuildParentChains.Count -ne 1) {
        throw 'Original module build parent chain evidence is not unique.'
    }
    $moduleBuildReceiptDirectoryChain = Open-DirectoryChain (
        $moduleBuildParentPath) 'receipt-time module build parent'
    if ($moduleBuildReceiptDirectoryChain.Entries.Count -ne
            $originalModuleBuildParentChains[0].Entries.Count) {
        throw 'Receipt-time module build parent chain length drifted.'
    }
    for ($index = 0;
        $index -lt $moduleBuildReceiptDirectoryChain.Entries.Count;
        $index++) {
        $currentEntry = $moduleBuildReceiptDirectoryChain.Entries[$index]
        $originalEntry = $originalModuleBuildParentChains[0].Entries[$index]
        if ($currentEntry.Path -cne $originalEntry.Path -or
            $currentEntry.Identity.StableId -cne
                $originalEntry.Identity.StableId) {
            throw 'Receipt-time module build parent chain does not match the original held identity.'
        }
    }
    $moduleBuildMutationGuard =
        [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
            OpenDirectoryDenyWriteDelete($moduleBuildParentPath)
    $moduleBuildMutationIdentity =
        [TL1C1bPreparedNotAuthorizedFileIdentityV1]::Read(
            $moduleBuildMutationGuard)
    Assert-Identity $moduleBuildMutationIdentity $true (
        'receipt-time module build parent handle') $true
    Assert-FinalPath $moduleBuildMutationGuard $moduleBuildParentPath (
        'receipt-time module build parent handle')
    if ($moduleBuildMutationIdentity.StableId -cne
            $moduleBuildReceiptDirectoryChain.Entries[
                $moduleBuildReceiptDirectoryChain.Entries.Count - 1].Identity.StableId) {
        throw 'Receipt-time module build parent handle identity drifted.'
    }
    $moduleBuildParentHeldDuringReceiptCreate = $true
}
catch {
    $failures.Add($_.Exception.ToString())
}
try {
    if ($null -eq $receiptDirectoryChain) {
        throw 'Receipt staging parent chain was not acquired.'
    }
    Assert-DirectoryChainStillBound $receiptDirectoryChain
    $receiptParentHeldDuringCreate = $true
}
catch {
    $failures.Add($_.Exception.ToString())
}
try {
    if (-not $moduleBuildParentHeldDuringReceiptCreate) {
        throw 'The module build parent was not held for final absence observation.'
    }
    $moduleBuildAbsentAtFinalPreReceiptObservation = -not (
        [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $moduleBuildPath))
    if (-not $moduleBuildAbsentAtFinalPreReceiptObservation) {
        throw 'The module build output appeared before receipt publication.'
    }
}
catch {
    $moduleBuildAbsentAtFinalPreReceiptObservation = $false
    $failures.Add($_.Exception.ToString())
}
$outputAbsenceEvidence.Clear()
$summaryAbsent = $false
$logAbsent = $false
$launcherResultAbsent = $false
$outputLeavesObserved = [bool]$outputParentHeldDuringCreate
if ($outputLeavesObserved) {
    $summaryAbsent = -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
        EntryExistsNoFollow($summaryPath)
    $logAbsent = -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
        EntryExistsNoFollow($logPath)
    $launcherResultAbsent = -not [TL1C1bPreparedNotAuthorizedFileIdentityV1]::
        EntryExistsNoFollow($launcherResultPath)
}
foreach ($outputSpec in @(
        [pscustomobject]@{
            Path = $summaryPath
            Label = 'Summary'
            Absent = $summaryAbsent
        },
        [pscustomobject]@{
            Path = $logPath
            Label = 'Log'
            Absent = $logAbsent
        },
        [pscustomobject]@{
            Path = $launcherResultPath
            Label = 'Launcher result'
            Absent = $launcherResultAbsent
        })) {
    $absent = if ($outputLeavesObserved) {
        [bool]$outputSpec.Absent
    }
    else { $null }
    $outputAbsenceEvidence.Add([pscustomobject][ordered]@{
        path = [IO.Path]::GetFullPath([string]$outputSpec.Path)
        observed = $outputLeavesObserved
        absent = $absent
        kind = 'final_output'
    })
    if (-not $outputLeavesObserved) {
        $failures.Add(
            "$($outputSpec.Label) output absence could not be observed because the output parent handle was unavailable.")
    }
    elseif (-not $absent) {
        $failures.Add(
            "$($outputSpec.Label) output was present at the final pre-receipt observation.")
    }
}
$canEnumerateOutputPrefixes = [bool](
    $outputParentHeldDuringCreate -and $null -ne $childItemParameters)
$temporaryPrefixesAbsent = $canEnumerateOutputPrefixes
$receiptOutputChildren = if ($canEnumerateOutputPrefixes) {
    @(Microsoft.PowerShell.Management\Get-ChildItem @childItemParameters)
}
else { @() }
foreach ($prefix in @(
        ".$summaryLeaf.", ".$logLeaf.", ".$launcherResultLeaf.")) {
    $prefixAbsent = if ($canEnumerateOutputPrefixes) {
        [bool](@($receiptOutputChildren | Where-Object {
            $_.Name.StartsWith($prefix, [StringComparison]::Ordinal)
        }).Count -eq 0)
    }
    else { $null }
    $outputAbsenceEvidence.Add([pscustomobject][ordered]@{
        path = [IO.Path]::GetFullPath((Join-Path $outputRoot ($prefix + '*')))
        observed = $canEnumerateOutputPrefixes
        absent = $prefixAbsent
        kind = 'candidate_temporary_prefix'
    })
    if (-not $canEnumerateOutputPrefixes) {
        $temporaryPrefixesAbsent = $false
        $failures.Add(
            "Candidate temporary prefix absence could not be observed because the output directory could not be enumerated: $prefix")
    }
    elseif (-not $prefixAbsent) {
        $temporaryPrefixesAbsent = $false
        $failures.Add(
            "Candidate temporary prefix was present at the final pre-receipt observation: $prefix")
    }
}
try {
    $failureSidecarAbsentAtFinalPreReceiptObservation = -not (
        [TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $failureSidecarPath))
    if (-not $failureSidecarAbsentAtFinalPreReceiptObservation) {
        throw 'The diagnostic failure sidecar appeared before receipt publication.'
    }
}
catch {
    $failureSidecarAbsentAtFinalPreReceiptObservation = $false
    $failures.Add($_.Exception.ToString())
}
$outputAbsenceObservedAtUtc = if (
    $outputLeavesObserved -and $canEnumerateOutputPrefixes) {
    [DateTimeOffset]::UtcNow
}
else { $null }
$passiveHostAdbStateSnapshots.Add((
    Get-PassiveHostAdbStateSnapshot -Stage 'final_pre_receipt'))
$passiveHostAdbStateStageOrderVerified = [bool](
    $passiveHostAdbStateSnapshots.Count -eq 3 -and
    ([string]$passiveHostAdbStateSnapshots[0].stage) -ceq 'initial' -and
    ([string]$passiveHostAdbStateSnapshots[1].stage) -ceq
        'static_inspection_end' -and
    ([string]$passiveHostAdbStateSnapshots[2].stage) -ceq
        'final_pre_receipt')
$passiveHostAdbStateAllObservationsAvailable = [bool](
    $passiveHostAdbStateSnapshots.Count -eq 3 -and
    $passiveHostAdbProcessObservationAvailableCount -eq 3L -and
    $passiveHostTcp5037ListenerObservationAvailableCount -eq 3L)
$passiveHostAdbStateAllObservationsZero = [bool](
    $passiveHostAdbStateAllObservationsAvailable -and
    $passiveHostAdbProcessZeroCount -eq 3L -and
    $passiveHostAdbProcessObjectObservedCount -eq
        $passiveHostAdbProcessObjectDisposedCount -and
    $passiveHostTcp5037ListenerZeroCount -eq 3L -and
    $passiveHostAdbZeroBoundaryCount -eq 3L)
if ($passiveHostAdbStateSnapshotAttemptCount -ne 3L -or
    -not $passiveHostAdbStateStageOrderVerified) {
    $failures.Add(
        'Passive host ADB/TCP observation did not complete the exact three-stage sequence.')
}
$allChecksPassed = [bool](
    $failures.Count -eq 0 -and
    $guardCleanupCompleted -and
    $launcherTemplateReconstructionVerified -and
    $launcherOptionalExpectedShaGuardsVerified -and
    $launcherHeldFileContinuityVerified -and
    $launcherFileIdentityNoReparseGateVerified -and
    $launcherSummaryUnpinnedShaOpenVerified -and
    $primaryObjectsHeldThroughStaticInspection -and
    $primaryObjectGuardsReleasedBeforeReceiptPublication -and
    $receiptParentHeldDuringCreate -and
    $preflightBuiltinBindingsVerified -and
    $passiveHostAdbStateSnapshotAttemptCount -eq 3L -and
    $passiveHostAdbProcessObservationAttemptCount -eq 3L -and
    $passiveHostTcp5037ListenerObservationAttemptCount -eq 3L -and
    $passiveHostAdbStateStageOrderVerified -and
    $passiveHostAdbStateAllObservationsAvailable -and
    $passiveHostAdbStateAllObservationsZero -and
    $passiveHostAdbProcessObservationAvailableCount -eq 3L -and
    $passiveHostTcp5037ListenerObservationAvailableCount -eq 3L -and
    $passiveHostAdbProcessZeroCount -eq 3L -and
    $passiveHostAdbProcessObjectObservedCount -eq
        $passiveHostAdbProcessObjectDisposedCount -and
    $passiveHostTcp5037ListenerZeroCount -eq 3L -and
    $passiveHostAdbZeroBoundaryCount -eq 3L -and
    $gitInvocationCount -eq 4L -and
    $gitBoundedDrainCompletedCount -eq 4L -and
    $gitCleanupCompletedCount -eq 4L -and
    $gitInvocationFailureRecordCount -eq 0L -and
    $gitPrimaryFailureCount -eq 0L -and
    $gitCleanupFailureCount -eq 0L -and
    $gitRootExitNotObservedCount -eq 0L -and
    $gitPendingDrainClosureNotObservedCount -eq 0L -and
    $gitPendingTaskFaultObserverInstallationAttemptCount -eq 0L -and
    $gitPendingTaskFaultObserverInstallationCompletedCount -eq 0L -and
    $prePublicationLocalFailureRecordCount -eq 0L -and
    $prePublicationLocalPrimaryFailureCount -eq 0L -and
    $prePublicationLocalCleanupFailureCount -eq 0L -and
    $prePublicationGuardCleanupFailureCount -eq 0L -and
    $failures.Count -ge (
        $gitInvocationFailureRecordCount +
        $prePublicationLocalFailureRecordCount +
        $prePublicationGuardCleanupFailureCount) -and
    $gitIndexFlagsVerified -and
    $gitSubmodulesAbsent -and
    $gitIsolationVerified -and
    $gitInfoAttributesAbsentVerified -and
    $outputParentHeldDuringCreate -and
    $moduleBuildParentHeldDuringReceiptCreate -and
    $temporaryPrefixesAbsent -and
    $null -ne $outputAbsenceObservedAtUtc -and
    $summaryAbsent -and
    $logAbsent -and
    $launcherResultAbsent -and
    $failureSidecarAbsentAtInitialObservation -and
    $failureSidecarAbsentAtStaticInspectionEnd -and
    $failureSidecarAbsentAtFinalPreReceiptObservation -and
    $moduleBuildAbsentAtInitialObservation -and
    $moduleBuildAbsentBeforeGuardRelease -and
    $moduleBuildAbsentAtFinalPreReceiptObservation)

$receipt = [pscustomobject][ordered]@{
    schema = 'tablet-layout-c1b-prepared-not-authorized-preflight/v1'
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture)
    prepared_not_authorized = $true
    launcher_executed = $false
    helper_executed = $false
    build_executed = $false
    adb_or_device_operation_executed = $false
    adb_command_executed = $false
    device_enumeration_attempt_count = 0L
    passive_host_adb_state_observation_executed = [bool](
        $passiveHostAdbStateSnapshotAttemptCount -gt 0L)
    passive_host_adb_process_termination_attempt_count = 0L
    passive_host_tcp_5037_listener_mutation_attempt_count = 0L
    passive_host_process_mutation_attempt_count = 0L
    passive_host_process_termination_attempt_count = 0L
    passive_host_listener_mutation_attempt_count = 0L
    passive_host_adb_state_observation_required_count = 3L
    passive_host_adb_state_snapshot_count =
        [long]$passiveHostAdbStateSnapshots.Count
    passive_host_adb_process_observation_attempt_count =
        [long]$passiveHostAdbProcessObservationAttemptCount
    passive_host_tcp_5037_listener_observation_attempt_count =
        [long]$passiveHostTcp5037ListenerObservationAttemptCount
    passive_host_adb_process_observation_available_count =
        [long]$passiveHostAdbProcessObservationAvailableCount
    passive_host_tcp_5037_listener_observation_available_count =
        [long]$passiveHostTcp5037ListenerObservationAvailableCount
    passive_host_adb_process_zero_count =
        [long]$passiveHostAdbProcessZeroCount
    passive_host_adb_process_object_observed_count =
        [long]$passiveHostAdbProcessObjectObservedCount
    passive_host_adb_process_object_disposed_count =
        [long]$passiveHostAdbProcessObjectDisposedCount
    passive_host_tcp_5037_listener_zero_count =
        [long]$passiveHostTcp5037ListenerZeroCount
    passive_host_adb_zero_boundary_count =
        [long]$passiveHostAdbZeroBoundaryCount
    passive_host_adb_state_stage_order_verified =
        [bool]$passiveHostAdbStateStageOrderVerified
    passive_host_adb_state_all_observations_available =
        [bool]$passiveHostAdbStateAllObservationsAvailable
    passive_host_adb_state_all_observations_zero =
        [bool]$passiveHostAdbStateAllObservationsZero
    passive_host_adb_state_observation_fail_closed = $true
    passive_host_adb_state_observations_are_sequential = $true
    passive_host_adb_state_atomic_snapshot_claimed = $false
    passive_host_adb_state_continuous_lease_claimed = $false
    passive_host_adb_state_snapshots =
        [object[]]$passiveHostAdbStateSnapshots.ToArray()
    all_checks_passed = $allChecksPassed
    all_checks_passed_is_pre_publication_only = $true
    receipt_alone_has_pass_authority = $false
    pass_requires_process_exit_zero = $true
    pass_requires_closed_terminal = $true
    pass_requires_primary_failure_count_zero = $true
    pass_requires_cleanup_failure_count_zero = $true
    pass_requires_recording_failure_count_zero = $true
    failure_count = [long]$failures.Count
    pre_publication_failure_record_count = [long]$failures.Count
    failure_reasons = [string[]]$failures.ToArray()
    static_check_count = [long]$staticCheckCount
    expected_commit_sha = $expectedCommitSha
    expected_commit_short = $expectedCommitShort
    expected_branch = $expectedBranch
    expected_failure_sidecar_path =
        [IO.Path]::GetFullPath($failureSidecarPath)
    failure_sidecar_absent_at_initial_observation =
        [bool]$failureSidecarAbsentAtInitialObservation
    failure_sidecar_absent_at_static_inspection_end =
        [bool]$failureSidecarAbsentAtStaticInspectionEnd
    failure_sidecar_absent_at_final_pre_receipt_observation =
        [bool]$failureSidecarAbsentAtFinalPreReceiptObservation
    failure_sidecar_no_follow_absence_observation_required_count = 3L
    expected_module_build_output_path =
        [IO.Path]::GetFullPath($moduleBuildPath)
    module_build_output_absent_at_initial_observation =
        [bool]$moduleBuildAbsentAtInitialObservation
    module_build_output_absent_before_primary_guard_release =
        [bool]$moduleBuildAbsentBeforeGuardRelease
    module_build_output_absent_at_final_pre_receipt_observation =
        [bool]$moduleBuildAbsentAtFinalPreReceiptObservation
    module_build_output_no_follow_absence_observation_required_count = 3L
    module_build_parent_held_during_receipt_create =
        [bool]$moduleBuildParentHeldDuringReceiptCreate
    module_build_child_namespace_continuously_frozen = $false
    module_build_absence_at_receipt_publication_claimed = $false
    preflight_to_smoke_namespace_continuity_claimed = $false
    gradle_or_check_between_preflight_and_smoke_permitted = $false
    actual_head_sha = $gitHead
    actual_branch = $gitBranch
    clean_head_verified = [bool](
        $gitHead -ceq $expectedCommitSha -and
        $gitBranch -ceq $expectedBranch -and
        $worktreeClean)
    worktree_clean = [bool]$worktreeClean
    worktree_clean_check_uses_only_held_explicit_exclude_files = $true
    worktree_clean_check_consults_per_directory_ignore_files = $false
    read_only_git_invocation_count = [long]$gitInvocationCount
    read_only_git_core_autocrlf_cli_override = 'true'
    read_only_git_core_autocrlf_fixed_invocation_count = 4L
    read_only_git_operation_timeout_milliseconds =
        [long]$gitOperationTimeoutMilliseconds
    read_only_git_cleanup_root_exit_timeout_milliseconds =
        [long]$gitCleanupRootExitTimeoutMilliseconds
    read_only_git_cleanup_drain_timeout_per_stream_milliseconds =
        [long]$gitCleanupDrainTimeoutMilliseconds
    read_only_git_stdout_byte_limit = [long]$gitStdoutByteLimit
    read_only_git_read_buffer_byte_length =
        [long]$gitReadBufferByteLength
    read_only_git_bounded_drain_completed_count =
        [long]$gitBoundedDrainCompletedCount
    read_only_git_cleanup_completed_count =
        [long]$gitCleanupCompletedCount
    read_only_git_invocation_failure_record_count =
        [long]$gitInvocationFailureRecordCount
    read_only_git_primary_failure_count = [long]$gitPrimaryFailureCount
    read_only_git_cleanup_failure_count = [long]$gitCleanupFailureCount
    read_only_git_primary_failure_reasons =
        [string[]]$gitPrimaryFailureReasons.ToArray()
    read_only_git_cleanup_failure_reasons =
        [string[]]$gitCleanupFailureReasons.ToArray()
    read_only_git_root_exit_not_observed_count =
        [long]$gitRootExitNotObservedCount
    read_only_git_pending_drain_closure_not_observed_count =
        [long]$gitPendingDrainClosureNotObservedCount
    read_only_git_pending_task_fault_observer_installation_attempt_count =
        [long]$gitPendingTaskFaultObserverInstallationAttemptCount
    read_only_git_pending_task_fault_observer_installation_completed_count =
        [long]$gitPendingTaskFaultObserverInstallationCompletedCount
    pre_publication_guard_cleanup_failure_count =
        [long]$prePublicationGuardCleanupFailureCount
    pre_publication_guard_cleanup_failure_reasons =
        [string[]]$prePublicationGuardCleanupFailureReasons.ToArray()
    pre_publication_local_failure_record_count =
        [long]$prePublicationLocalFailureRecordCount
    pre_publication_local_primary_failure_count =
        [long]$prePublicationLocalPrimaryFailureCount
    pre_publication_local_cleanup_failure_count =
        [long]$prePublicationLocalCleanupFailureCount
    pre_publication_local_primary_failure_reasons =
        [string[]]$prePublicationLocalPrimaryFailureReasons.ToArray()
    pre_publication_local_cleanup_failure_reasons =
        [string[]]$prePublicationLocalCleanupFailureReasons.ToArray()
    read_only_git_stderr_must_be_empty = $true
    read_only_git_primary_and_cleanup_failures_are_aggregated = $true
    read_only_git_fixed_capture_buffer_zeroized_before_success = $true
    read_only_git_pending_read_buffer_zeroization_requires_task_quiescence =
        $true
    read_only_git_pending_task_fault_observer_installed_on_cleanup_timeout =
        [bool](
            $gitPendingTaskFaultObserverInstallationAttemptCount -eq
                $gitPendingDrainClosureNotObservedCount -and
            $gitPendingTaskFaultObserverInstallationCompletedCount -eq
                $gitPendingDrainClosureNotObservedCount)
    git_state_observed_at_utc = if ($null -eq $gitStateObservedAtUtc) {
        $null
    } else {
        $gitStateObservedAtUtc.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture)
    }
    git_repository_local_config_held_and_hash_verified = [bool](
        $null -ne $gitConfigBinding -and $gitConfigBinding.Count -eq 1)
    git_repository_root_gitignore_held_and_hash_verified = [bool](
        $null -ne $gitIgnoreBinding -and $gitIgnoreBinding.Count -eq 1)
    git_repository_info_exclude_held_and_hash_verified = [bool](
        $null -ne $gitInfoExcludeBinding -and
        $gitInfoExcludeBinding.Count -eq 1)
    git_attributes_source_pinned_to_expected_commit = [bool]$gitIsolationVerified
    git_replace_objects_disabled_by_environment_and_global_option = $true
    git_info_attributes_absence_verified = [bool]$gitInfoAttributesAbsentVerified
    git_info_attributes_absent_before_final_git =
        [bool]$gitInfoAttributesAbsentBeforeFinalGit
    git_info_attributes_absent_after_final_git =
        [bool]$gitInfoAttributesAbsentAfterFinalGit
    git_info_attributes_absent_at_static_inspection_end =
        [bool]$gitInfoAttributesAbsentAtStaticEnd
    git_info_attributes_continuous_namespace_freeze_claimed = $false
    git_index_special_flags_absent = [bool]$gitIndexFlagsVerified
    git_submodules_absent = [bool]$gitSubmodulesAbsent
    expected_git_tracked_path_count = [long]$expectedGitTrackedPathCount
    git_tracked_path_count = [long]$gitTrackedPathCount
    preflight_builtin_command_bindings_verified =
        [bool]$preflightBuiltinBindingsVerified
    target_static_checks_are_supplemental_to_exact_held_hashes = $true
    runtime_pwsh_query_path_matches_held_path =
        [bool]$runtimePwshPathMatchesHeldPath
    runtime_pwsh_mapped_image_identity_claimed = $false
    relevant_volume_count = [long]$volumeEvidence.Count
    relevant_volumes = [object[]]$volumeEvidence.ToArray()
    primary_object_count_held_during_static_inspection =
        [long]$primaryFileBindings.Count
    four_objects_held_and_hash_verified_during_static_inspection =
        [pscustomobject]$primaryEvidence
    primary_objects_held_through_static_inspection =
        [bool]$primaryObjectsHeldThroughStaticInspection
    primary_object_guards_released_before_receipt_publication =
        [bool]$primaryObjectGuardsReleasedBeforeReceiptPublication
    receipt_binds_a_future_launcher_path_resolution = $false
    future_execution_requires_exact_external_command_and_launcher_revalidation =
        $true
    future_launcher_revalidates_target_hashes_and_output_absence = $true
    expected_launcher_sha256 = $expectedLauncherSha256
    expected_launcher_template_sha256 = $expectedLauncherTemplateSha256
    launcher_template_reconstruction_verified =
        [bool]$launcherTemplateReconstructionVerified
    actual_launcher_sha256 = if ($null -ne $primaryEvidence.launcher) {
        [string]$primaryEvidence.launcher.actual_sha256
    }
    else { $null }
    expected_helper_sha256 = $expectedHelperSha256
    actual_helper_sha256 = if ($null -ne $primaryEvidence.helper) {
        [string]$primaryEvidence.helper.actual_sha256
    }
    else { $null }
    expected_verifier_sha256 = $expectedVerifierSha256
    actual_verifier_sha256 = if ($null -ne $primaryEvidence.verifier) {
        [string]$primaryEvidence.verifier.actual_sha256
    }
    else { $null }
    expected_pwsh_sha256 = $expectedPwshSha256
    actual_pwsh_sha256 = if ($null -ne $primaryEvidence.pinned_pwsh) {
        [string]$primaryEvidence.pinned_pwsh.actual_sha256
    }
    else { $null }
    launcher_static_evidence = $launcherEvidence
    verifier_static_evidence = $verifierEvidence
    helper_static_evidence = $helperEvidence
    helper_repository_loader_input_count = [long]$loaderEvidence.Count
    helper_repository_loader_inputs = $loaderEvidence
    output_absence = [object[]]$outputAbsenceEvidence.ToArray()
    sequential_output_absence_checks_completed_at_utc = if (
        $null -eq $outputAbsenceObservedAtUtc) {
        $null
    } else {
        $outputAbsenceObservedAtUtc.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture)
    }
    final_output_absence_count = [long]@(
        $outputAbsenceEvidence | Where-Object {
            $_.kind -ceq 'final_output' -and $_.absent
        }).Count
    temporary_prefix_absence_count = [long]@(
        $outputAbsenceEvidence | Where-Object {
            $_.kind -ceq 'candidate_temporary_prefix' -and $_.absent
        }).Count
    summary_output_absent = [bool]$summaryAbsent
    log_output_absent = [bool]$logAbsent
    launcher_result_output_absent = [bool]$launcherResultAbsent
    temporary_output_prefixes_absent = [bool]$temporaryPrefixesAbsent
    output_absence_sequential_observations_completed = [bool](
        $outputLeavesObserved -and $canEnumerateOutputPrefixes)
    output_absence_atomic_snapshot_claimed = $false
    output_absence_at_receipt_publication_claimed = $false
    output_child_namespace_continuously_frozen = $false
    held_guard_and_sensitive_buffer_cleanup_calls_completed_without_exception =
        [bool]$guardCleanupCompleted
    native_close_success_beyond_safehandle_dispose_claimed = $false
    output_parent_directory_handle_held_during_create =
        [bool]$outputParentHeldDuringCreate
    output_directory_handle_cleanup_reportable_after_publication = $false
    receipt_parent_chain_held_during_create =
        [bool]$receiptParentHeldDuringCreate
    receipt_parent_guard_cleanup_reportable_after_publication = $false
    receipt_path = [IO.Path]::GetFullPath($receiptPath)
    receipt_create_mode =
        'HeldIdentityTemporaryCreateNewThenMoveNoReplaceThenHeldFinalReadback'
    receipt_no_overwrite_at_creation = $true
    receipt_temporary_no_reparse_stable_id_and_final_path_required = $true
    receipt_final_no_reparse_same_stable_id_and_exact_bytes_required = $true
    unsafe_same_path_temporary_cleanup_intentionally_forbidden = $true
    receipt_post_close_immutability_claimed = $false
    receipt_is_execution_authority = $false
}

try {
    if (-not $receiptParentHeldDuringCreate) {
        $receiptParentFailureDetail = if ($failures.Count -eq 0) {
            'no earlier failure was captured'
        }
        else { $failures -join '; ' }
        throw (
            'Receipt publication is forbidden without its verified held parent chain. ' +
            'Earlier failures: ' + $receiptParentFailureDetail)
    }
    if ([TL1C1bPreparedNotAuthorizedFileIdentityV1]::EntryExistsNoFollow(
            $receiptPath)) {
        throw 'Receipt path appeared before CreateNew publication.'
    }
    Write-ReceiptCreateNew -Path $receiptPath -Value $receipt
    $receiptPublished = $true
}
catch {
    $recordingFailures.Add(
        'CreateNew receipt publication failed: ' + $_.Exception.ToString())
}
}
finally {
    if ($null -ne $moduleBuildMutationGuard) {
        try { $moduleBuildMutationGuard.Dispose() }
        catch {
            $moduleBuildGuardCleanupFailures.Add($_.Exception.ToString())
        }
    }
    if ($null -ne $moduleBuildReceiptDirectoryChain) {
        for ($index = $moduleBuildReceiptDirectoryChain.Entries.Count - 1;
                $index -ge 0; $index--) {
            try {
                $moduleBuildReceiptDirectoryChain.Entries[$index].Handle.Dispose()
            }
            catch {
                $moduleBuildGuardCleanupFailures.Add($_.Exception.ToString())
            }
        }
    }
    if ($null -ne $outputMutationGuard) {
        try { $outputMutationGuard.Dispose() }
        catch { $outputGuardCleanupFailures.Add($_.Exception.ToString()) }
    }
    if ($null -ne $outputReceiptDirectoryChain) {
        for ($index = $outputReceiptDirectoryChain.Entries.Count - 1;
                $index -ge 0; $index--) {
            try { $outputReceiptDirectoryChain.Entries[$index].Handle.Dispose() }
            catch { $outputGuardCleanupFailures.Add($_.Exception.ToString()) }
        }
    }
    if ($null -ne $receiptDirectoryChain) {
        for ($index = $receiptDirectoryChain.Entries.Count - 1;
                $index -ge 0; $index--) {
            try { $receiptDirectoryChain.Entries[$index].Handle.Dispose() }
            catch { $receiptGuardCleanupFailures.Add($_.Exception.ToString()) }
        }
    }
    if ($outputGuardCleanupFailures.Count -ne 0) {
        $outputGuardCleanupFailure = $outputGuardCleanupFailures -join '; '
    }
    if ($moduleBuildGuardCleanupFailures.Count -ne 0) {
        $moduleBuildGuardCleanupFailure =
            $moduleBuildGuardCleanupFailures -join '; '
    }
    if ($receiptGuardCleanupFailures.Count -ne 0) {
        $receiptParentCleanupFailure = $receiptGuardCleanupFailures -join '; '
    }
}
$prePublicationFailureRecordCount =
    [long]$receipt.pre_publication_failure_record_count
$gitInvocationFailureRecordCount =
    [long]$receipt.read_only_git_invocation_failure_record_count
$prePublicationGuardCleanupFailureCount =
    [long]$receipt.pre_publication_guard_cleanup_failure_count
$prePublicationLocalFailureRecordCount =
    [long]$receipt.pre_publication_local_failure_record_count
$recordingFailureCount = [long]$recordingFailures.Count
$failureClassificationConsistent = [bool](
    $prePublicationFailureRecordCount -ge (
        $gitInvocationFailureRecordCount +
        $prePublicationLocalFailureRecordCount +
        $prePublicationGuardCleanupFailureCount) -and
    (($recordingFailureCount -eq 0L) -eq $receiptPublished))
$otherPrimaryFailureCount = [long][Math]::Max(
    [long]0,
    [long](
        $prePublicationFailureRecordCount -
        $gitInvocationFailureRecordCount -
        $prePublicationLocalFailureRecordCount -
        $prePublicationGuardCleanupFailureCount))
$primaryFailureCount = [long](
    $otherPrimaryFailureCount +
    [long]$receipt.read_only_git_primary_failure_count +
    [long]$receipt.pre_publication_local_primary_failure_count +
    $recordingFailureCount)
$cleanupFailureCount = [long](
    [long]$receipt.read_only_git_cleanup_failure_count +
    [long]$receipt.pre_publication_local_cleanup_failure_count +
    $prePublicationGuardCleanupFailureCount +
    $receiptPublicationCleanupFailureCount +
    $outputGuardCleanupFailures.Count +
    $moduleBuildGuardCleanupFailures.Count +
    $receiptGuardCleanupFailures.Count)
$gitProcessAndDrainQuiescenceVerified = [bool](
    [long]$receipt.read_only_git_root_exit_not_observed_count -eq 0L -and
    [long]$receipt.read_only_git_pending_drain_closure_not_observed_count -eq 0L)
$terminalResourceQuiescenceVerified = [bool](
    $gitProcessAndDrainQuiescenceVerified -and
    $cleanupFailureCount -eq 0L)
$terminalState = if (-not $gitProcessAndDrainQuiescenceVerified) {
    'bounded_nonquiescent'
}
elseif ($cleanupFailureCount -ne 0L) {
    'close_unverified'
}
else { 'closed' }
$terminalPassEligible = [bool](
    $receipt.all_checks_passed -and
    $receiptPublished -and
    $failureClassificationConsistent -and
    $terminalState -ceq 'closed' -and
    $terminalResourceQuiescenceVerified -and
    $primaryFailureCount -eq 0L -and
    $cleanupFailureCount -eq 0L -and
    $recordingFailureCount -eq 0L)
$publicResult = [pscustomobject][ordered]@{
    schema = 'tablet-layout-c1b-prepared-not-authorized-preflight-result/v1'
    terminal_state = $terminalState
    git_process_and_drain_quiescence_verified =
        $gitProcessAndDrainQuiescenceVerified
    terminal_resource_quiescence_verified =
        $terminalResourceQuiescenceVerified
    prepared_not_authorized = $true
    all_checks_passed = [bool]$receipt.all_checks_passed
    pre_publication_failure_record_count =
        $prePublicationFailureRecordCount
    pre_publication_failure_reasons =
        [string[]]$receipt.failure_reasons
    failure_classification_consistent = $failureClassificationConsistent
    failure_category_counts_are_not_a_partition = $true
    primary_failure_count = $primaryFailureCount
    cleanup_failure_count = $cleanupFailureCount
    read_only_git_primary_failure_reasons =
        [string[]]$receipt.read_only_git_primary_failure_reasons
    read_only_git_cleanup_failure_reasons =
        [string[]]$receipt.read_only_git_cleanup_failure_reasons
    pre_publication_guard_cleanup_failure_reasons =
        [string[]]$receipt.pre_publication_guard_cleanup_failure_reasons
    pre_publication_local_primary_failure_reasons =
        [string[]]$receipt.pre_publication_local_primary_failure_reasons
    pre_publication_local_cleanup_failure_reasons =
        [string[]]$receipt.pre_publication_local_cleanup_failure_reasons
    post_publication_output_guard_cleanup_failure_reasons =
        [string[]]$outputGuardCleanupFailures.ToArray()
    post_publication_module_build_guard_cleanup_failure_reasons =
        [string[]]$moduleBuildGuardCleanupFailures.ToArray()
    post_publication_receipt_guard_cleanup_failure_reasons =
        [string[]]$receiptGuardCleanupFailures.ToArray()
    receipt_publication_internal_cleanup_failure_count =
        [long]$receiptPublicationCleanupFailureCount
    receipt_publication_internal_cleanup_failure_reasons =
        [string[]]$receiptPublicationCleanupFailureReasons.ToArray()
    recording_failure_count = $recordingFailureCount
    recording_failure_reasons = [string[]]$recordingFailures.ToArray()
    receipt_published = [bool]$receiptPublished
    receipt_alone_has_pass_authority = $false
    pass_requires_observed_process_exit_zero = $true
    expected_process_exit_code_for_pass = 0L
    terminal_pass_eligible = $terminalPassEligible
    receipt_parent_guard_dispose_calls_completed_without_exception =
        [bool][string]::IsNullOrEmpty($receiptParentCleanupFailure)
    output_directory_handle_dispose_calls_completed_without_exception =
        [bool][string]::IsNullOrEmpty($outputGuardCleanupFailure)
    module_build_parent_handle_dispose_calls_completed_without_exception =
        [bool][string]::IsNullOrEmpty($moduleBuildGuardCleanupFailure)
    post_publication_dispose_exception_count = [long](
        $outputGuardCleanupFailures.Count +
        $moduleBuildGuardCleanupFailures.Count +
        $receiptGuardCleanupFailures.Count)
    native_close_success_beyond_safehandle_dispose_claimed = $false
    overall_passed_requires_terminal_plus_external_exit_zero = $true
    overall_passed = $false
    overall_passed_is_not_claimed_before_external_exit_observation = $true
    receipt_path = [string]$receipt.receipt_path
}
$publicJsonParameters = @{
    InputObject = $publicResult
    Depth = 4
    Compress = $true
}
[Console]::WriteLine((
    Microsoft.PowerShell.Utility\ConvertTo-Json @publicJsonParameters))
if (-not $terminalPassEligible) {
    [Console]::Error.WriteLine(
        "Preflight terminal state is $terminalState and is not pass-eligible; require consistent failure classification, verified resource quiescence, and primary, cleanup, and recording counts all zero.")
    exit 1
}
