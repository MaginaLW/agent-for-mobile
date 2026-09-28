#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('\A[0-9a-f]{64}\z')]
    [string]$ExpectedLauncherSha256
)

$sharedFailurePipelineReady = $false
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$expectedCommitSha = '__FINAL_COMMIT_SHA__'
$expectedCommitShort = '__FINAL_COMMIT_SHORT__'
$repoRoot = '__REPO_ROOT__'
$failureSidecarPath = '__FAILURE_SIDECAR_ABSOLUTE_PATH__'
$startedAtUtc = [DateTimeOffset]::UtcNow
$observedLauncherPath = [string]$PSCommandPath
$launcherPhase = 'native_type_load'
$currentFileSystemLocation = $null
$environmentCurrentDirectory = $null
$failureSidecarPublishAttempted = $false
$failureSidecarPublished = $false
$primaryFailureErrorRecord = $null
$primaryFailurePhase = $null
$automaticRetryCount = 0L
$helperStartAttemptCount = 0L
$helperStartCount = 0L
$failureSidecarPreexisting = $null
$outputTargetsAbsent = $false
$outputChainHeld = $false
$elevatedToken = $false
$resultPublished = $false
$failure = $null
$summaryStatus = $null
$helperFailureSummaryVerified = $false
$helperFailureReasons = [string[]]@()

function Get-LauncherBoundedFailureText {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][int]$MaximumLength
    )
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ($text.Length -gt $MaximumLength) {
        return $text.Substring(0, $MaximumLength)
    }
    return $text
}

function Capture-LauncherPrimaryFailure {
    param(
        [AllowNull()][Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()][Exception]$Exception,
        [Parameter(Mandatory)][string]$Phase
    )
    if ($null -ne $script:primaryFailureErrorRecord) { return }
    if ($null -eq $ErrorRecord) {
        if ($null -eq $Exception) {
            throw 'Primary failure capture requires an ErrorRecord or Exception.'
        }
        $ErrorRecord = [Management.Automation.ErrorRecord]::new(
            $Exception,
            'TL1C1bLauncherFailure',
            [Management.Automation.ErrorCategory]::OperationStopped,
            $null)
    }
    $script:primaryFailureErrorRecord = $ErrorRecord
    $script:primaryFailurePhase = [string]$Phase
}

function Merge-LauncherFailure {
    param(
        [AllowNull()][Exception]$Existing,
        [Parameter(Mandatory)][Exception]$Additional,
        [Parameter(Mandatory)][string]$Message
    )
    if ($null -eq $Existing) { return $Additional }
    return [AggregateException]::new(
        $Message, [Exception[]]@($Existing, $Additional))
}

function Publish-LauncherFailureSidecarCreateNew {
    param(
        [AllowNull()][Management.Automation.ErrorRecord]$PrimaryErrorRecord,
        [Parameter(Mandatory)][Exception]$PrimaryException
    )
    $fullSidecarPath = [IO.Path]::GetFullPath($script:failureSidecarPath)
    $fullLauncherPath = [IO.Path]::GetFullPath($script:observedLauncherPath)
    if ($fullSidecarPath -cnotmatch '\A[A-Za-z]:\\' -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            $fullSidecarPath, [string]$script:failureSidecarPath) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($fullSidecarPath),
            [IO.Path]::GetDirectoryName($fullLauncherPath)) -or
        -not $fullSidecarPath.EndsWith(
            '.failure.json', [StringComparison]::Ordinal)) {
        throw 'Launcher failure sidecar is not the fixed absolute staging sibling.'
    }

    $exceptionQueue = [Collections.Generic.Queue[Exception]]::new()
    if ($null -ne $PrimaryErrorRecord -and
        $null -ne $PrimaryErrorRecord.Exception) {
        $exceptionQueue.Enqueue($PrimaryErrorRecord.Exception)
    }
    if ($null -eq $PrimaryErrorRecord -or
        $null -eq $PrimaryErrorRecord.Exception -or
        -not [object]::ReferenceEquals(
            $PrimaryErrorRecord.Exception, $PrimaryException)) {
        $exceptionQueue.Enqueue($PrimaryException)
    }
    $exceptionRecords = [Collections.Generic.List[object]]::new()
    $observedExceptions = [Collections.Generic.List[Exception]]::new()
    $maximumStoredExceptionCount = 8L
    $maximumObservedExceptionCount = 256L
    $exceptionMessageTruncatedCount = 0L
    while ($exceptionQueue.Count -ne 0 -and
        $observedExceptions.Count -lt $maximumObservedExceptionCount) {
        $currentException = $exceptionQueue.Dequeue()
        $alreadyObserved = $false
        foreach ($observedException in $observedExceptions) {
            if ([object]::ReferenceEquals(
                    $observedException, $currentException)) {
                $alreadyObserved = $true
                break
            }
        }
        if ($alreadyObserved) { continue }
        $observedExceptions.Add($currentException)
        if ($exceptionRecords.Count -lt $maximumStoredExceptionCount) {
            $nativeErrorCode = if ($currentException -is
                    [ComponentModel.Win32Exception]) {
                [int]$currentException.NativeErrorCode
            } else { $null }
            $originalExceptionMessage = if ($null -eq
                    $currentException.Message) {
                $null
            } else { [string]$currentException.Message }
            $storedExceptionMessage = Get-LauncherBoundedFailureText `
                -Value $originalExceptionMessage -MaximumLength 4096
            $originalExceptionMessageLength = if ($null -eq
                    $originalExceptionMessage) {
                $null
            } else { [long]$originalExceptionMessage.Length }
            $storedExceptionMessageLength = if ($null -eq
                    $storedExceptionMessage) {
                $null
            } else { [long]$storedExceptionMessage.Length }
            $exceptionMessageTruncated = [bool](
                $null -ne $originalExceptionMessageLength -and
                $null -ne $storedExceptionMessageLength -and
                $originalExceptionMessageLength -gt
                    $storedExceptionMessageLength)
            if ($exceptionMessageTruncated) {
                $exceptionMessageTruncatedCount++
            }
            $exceptionRecords.Add([pscustomobject][ordered]@{
                type = [string]$currentException.GetType().FullName
                message = $storedExceptionMessage
                message_original_length = $originalExceptionMessageLength
                message_stored_length = $storedExceptionMessageLength
                message_truncated = [bool]$exceptionMessageTruncated
                hresult = [int]$currentException.HResult
                native_error_code = $nativeErrorCode
            })
        }
        if ($currentException -is [AggregateException]) {
            foreach ($innerException in $currentException.InnerExceptions) {
                if ($null -ne $innerException) {
                    $exceptionQueue.Enqueue($innerException)
                }
            }
        }
        elseif ($null -ne $currentException.InnerException) {
            $exceptionQueue.Enqueue($currentException.InnerException)
        }
    }
    $exceptionObservationLimitReached = [bool]($exceptionQueue.Count -ne 0)
    $exceptionChainTruncated = [bool](
        $exceptionRecords.Count -lt $observedExceptions.Count -or
        $exceptionObservationLimitReached)

    $invocation = if ($null -eq $PrimaryErrorRecord) {
        $null
    } else { $PrimaryErrorRecord.InvocationInfo }
    $fullyQualifiedErrorIdOriginal = if ($null -eq $PrimaryErrorRecord) {
        $null
    } else { [string]$PrimaryErrorRecord.FullyQualifiedErrorId }
    $categoryOriginal = if ($null -eq $PrimaryErrorRecord) {
        $null
    } else { [string]$PrimaryErrorRecord.CategoryInfo }
    $positionMessageOriginal = if ($null -eq $invocation) {
        $null
    } else { [string]$invocation.PositionMessage }
    $scriptStackTraceOriginal = if ($null -eq $PrimaryErrorRecord) {
        $null
    } else { [string]$PrimaryErrorRecord.ScriptStackTrace }
    $fullyQualifiedErrorIdStored = Get-LauncherBoundedFailureText `
        -Value $fullyQualifiedErrorIdOriginal -MaximumLength 4096
    $categoryStored = Get-LauncherBoundedFailureText `
        -Value $categoryOriginal -MaximumLength 4096
    $positionMessageStored = Get-LauncherBoundedFailureText `
        -Value $positionMessageOriginal -MaximumLength 4096
    $scriptStackTraceStored = Get-LauncherBoundedFailureText `
        -Value $scriptStackTraceOriginal -MaximumLength 4096
    $fullyQualifiedErrorIdTruncated = [bool](
        $null -ne $fullyQualifiedErrorIdOriginal -and
        $fullyQualifiedErrorIdOriginal.Length -gt
            $fullyQualifiedErrorIdStored.Length)
    $categoryTruncated = [bool](
        $null -ne $categoryOriginal -and
        $categoryOriginal.Length -gt $categoryStored.Length)
    $positionMessageTruncated = [bool](
        $null -ne $positionMessageOriginal -and
        $positionMessageOriginal.Length -gt $positionMessageStored.Length)
    $scriptStackTraceTruncated = [bool](
        $null -ne $scriptStackTraceOriginal -and
        $scriptStackTraceOriginal.Length -gt $scriptStackTraceStored.Length)
    $boundedTextTruncatedCount = [long]$exceptionMessageTruncatedCount
    foreach ($fieldWasTruncated in @(
            $fullyQualifiedErrorIdTruncated,
            $categoryTruncated,
            $positionMessageTruncated,
            $scriptStackTraceTruncated)) {
        if ($fieldWasTruncated) { $boundedTextTruncatedCount++ }
    }
    $value = [pscustomobject][ordered]@{
        schema = 'tablet-layout-c1b-real-build-smoke-launcher-failure/v2'
        status = 'failed'
        success_eligible = $false
        pass_closure = $false
        evidence_role = 'diagnostic_failure_only'
        started_at_utc = $script:startedAtUtc.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture)
        failed_at_utc = [DateTimeOffset]::UtcNow.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [Globalization.CultureInfo]::InvariantCulture)
        phase = if ($null -eq $script:primaryFailurePhase) {
            [string]$script:launcherPhase
        } else { [string]$script:primaryFailurePhase }
        expected_commit_sha = [string]$script:expectedCommitSha
        expected_launcher_sha256 = [string]$ExpectedLauncherSha256
        launcher_path = $fullLauncherPath
        repo_root = [string]$script:repoRoot
        context = [pscustomobject][ordered]@{
            current_filesystem_location = $script:currentFileSystemLocation
            environment_current_directory = $script:environmentCurrentDirectory
            process_path = [string][Environment]::ProcessPath
            ps_version = $PSVersionTable.PSVersion.ToString()
            elevated_token = [bool]$script:elevatedToken
        }
        progress = [pscustomobject][ordered]@{
            output_targets_absence_confirmed =
                [bool]$script:outputTargetsAbsent
            failure_sidecar_preexisting = $script:failureSidecarPreexisting
            output_chain_held = [bool]$script:outputChainHeld
            helper_start_attempt_count = [long]$script:helperStartAttemptCount
            helper_start_count = [long]$script:helperStartCount
            automatic_retry_count = [long]$script:automaticRetryCount
            result_published = [bool]$script:resultPublished
        }
        helper_summary = [pscustomobject][ordered]@{
            verified = [bool]$script:helperFailureSummaryVerified
            status = $script:summaryStatus
            failure_count = [long]$script:helperFailureReasons.Count
            failure_reasons = [string[]]$script:helperFailureReasons
        }
        error = [pscustomobject][ordered]@{
            exception_chain = [object[]]$exceptionRecords.ToArray()
            exception_chain_stored_count = [long]$exceptionRecords.Count
            exception_chain_observed_count = [long]$observedExceptions.Count
            exception_chain_truncated = [bool]$exceptionChainTruncated
            exception_chain_storage_limit = [long]$maximumStoredExceptionCount
            exception_observation_limit = [long]$maximumObservedExceptionCount
            exception_observation_limit_reached =
                [bool]$exceptionObservationLimitReached
            bounded_text_truncated_count = [long]$boundedTextTruncatedCount
            fully_qualified_error_id = $fullyQualifiedErrorIdStored
            fully_qualified_error_id_original_length = if ($null -eq
                    $fullyQualifiedErrorIdOriginal) {
                $null
            } else { [long]$fullyQualifiedErrorIdOriginal.Length }
            fully_qualified_error_id_stored_length = if ($null -eq
                    $fullyQualifiedErrorIdStored) {
                $null
            } else { [long]$fullyQualifiedErrorIdStored.Length }
            fully_qualified_error_id_truncated =
                [bool]$fullyQualifiedErrorIdTruncated
            category = $categoryStored
            category_original_length = if ($null -eq $categoryOriginal) {
                $null
            } else { [long]$categoryOriginal.Length }
            category_stored_length = if ($null -eq $categoryStored) {
                $null
            } else { [long]$categoryStored.Length }
            category_truncated = [bool]$categoryTruncated
            script_line_number = if ($null -eq $invocation) { $null } else {
                [long]$invocation.ScriptLineNumber
            }
            offset_in_line = if ($null -eq $invocation) { $null } else {
                [long]$invocation.OffsetInLine
            }
            position_message = $positionMessageStored
            position_message_original_length = if ($null -eq
                    $positionMessageOriginal) {
                $null
            } else { [long]$positionMessageOriginal.Length }
            position_message_stored_length = if ($null -eq
                    $positionMessageStored) {
                $null
            } else { [long]$positionMessageStored.Length }
            position_message_truncated = [bool]$positionMessageTruncated
            script_stack_trace = $scriptStackTraceStored
            script_stack_trace_original_length = if ($null -eq
                    $scriptStackTraceOriginal) {
                $null
            } else { [long]$scriptStackTraceOriginal.Length }
            script_stack_trace_stored_length = if ($null -eq
                    $scriptStackTraceStored) {
                $null
            } else { [long]$scriptStackTraceStored.Length }
            script_stack_trace_truncated = [bool]$scriptStackTraceTruncated
        }
        publication = [pscustomobject][ordered]@{
            path = $fullSidecarPath
            mode = 'CreateNew'
            attempt_count = 1L
        }
    }

    $raw = Microsoft.PowerShell.Utility\ConvertTo-Json `
        -InputObject $value -Depth 12 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($raw)
    $stream = $null
    try {
        $stream = [IO.FileStream]::new(
            $fullSidecarPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            65536,
            [IO.FileOptions]::WriteThrough)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    $script:failureSidecarPublished = $true
}

function Exit-LauncherFailed {
    param(
        [AllowNull()][Management.Automation.ErrorRecord]$PrimaryErrorRecord,
        [Parameter(Mandatory)][Exception]$PrimaryException
    )
    $sidecarPublicationFailure = $null
    if (-not $script:failureSidecarPublishAttempted) {
        $script:failureSidecarPublishAttempted = $true
        try {
            Publish-LauncherFailureSidecarCreateNew `
                -PrimaryErrorRecord $PrimaryErrorRecord `
                -PrimaryException $PrimaryException
        }
        catch {
            # Secondary diagnostics only; never replace or recapture the
            # authoritative primary failure.
            $sidecarPublicationFailure = $_.Exception
        }
    }
    [Console]::Error.WriteLine($PrimaryException.ToString())
    if ($null -ne $sidecarPublicationFailure) {
        [Console]::Error.WriteLine(
            'Launcher failure sidecar publication also failed: ' +
            $sidecarPublicationFailure.ToString())
    }
    exit 1
}

trap {
    if (-not $script:sharedFailurePipelineReady) {
        break
    }
    $trappedErrorRecord = $_
    Capture-LauncherPrimaryFailure `
        -ErrorRecord $trappedErrorRecord -Exception $null `
        -Phase ([string]$launcherPhase)
    $failure = Merge-LauncherFailure `
        -Existing $failure -Additional $trappedErrorRecord.Exception `
        -Message 'Launcher aggregate and top-level trap failure both occurred.'
    Exit-LauncherFailed `
        -PrimaryErrorRecord $primaryFailureErrorRecord `
        -PrimaryException $failure
}
$sharedFailurePipelineReady = $true

if (-not [OperatingSystem]::IsWindows()) {
    throw 'The C1b real-build smoke launcher only accepts Windows.'
}
if ($null -ne ('TL1C1bNextLauncherNativeV1' -as [type])) {
    throw 'The launcher native authority type is already loaded; launcher retry is forbidden.'
}

$null = Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bNextLauncherIdentityV1 {
    public uint LinkCount { get; set; }
    public uint FileAttributes { get; set; }
    public ulong FileSize { get; set; }
    public long LastWriteTimeUtcFileTime { get; set; }
    public string StableId { get; set; }
}

public sealed class TL1C1bNextLauncherDrainResultV1 {
    public byte[] CapturedBytes { get; set; }
    public long TotalByteLength { get; set; }
    public bool Overflowed { get; set; }
    public string Sha256 { get; set; }
}

public static class TL1C1bNextLauncherNativeV1 {
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeInformationByHandleW(
        SafeFileHandle file, StringBuilder volumeName, uint volumeNameSize,
        out uint volumeSerialNumber, out uint maximumComponentLength,
        out uint fileSystemFlags, StringBuilder fileSystemName,
        uint fileSystemNameSize);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(
        IntPtr process, uint flags, StringBuilder executablePath,
        ref uint size);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObjectW(
        IntPtr jobAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        SafeFileHandle job, int informationClass, IntPtr information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(
        SafeFileHandle job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(
        SafeFileHandle job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
        SafeFileHandle job, int informationClass, IntPtr information,
        uint informationLength, out uint returnLength);

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    public static SafeFileHandle OpenDirectoryNoFollowDenyDelete(string path) {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
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
                FILE_FLAG_SEQUENTIAL_SCAN, IntPtr.Zero);
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
        const int MaximumPathCharacters = 32768;
        StringBuilder path = new StringBuilder(MaximumPathCharacters);
        uint result = GetFinalPathNameByHandleW(
            file, path, (uint)path.Capacity, 0);
        if (result == 0) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (result >= path.Capacity) {
            throw new InvalidOperationException("Final path exceeds the fixed Windows path bound.");
        }
        return path.ToString();
    }

    public static string GetFileSystemName(SafeFileHandle file) {
        StringBuilder volumeName = new StringBuilder(261);
        StringBuilder fileSystemName = new StringBuilder(261);
        uint serial;
        uint maximumComponentLength;
        uint flags;
        if (!GetVolumeInformationByHandleW(
                file, volumeName, (uint)volumeName.Capacity,
                out serial, out maximumComponentLength, out flags,
                fileSystemName, (uint)fileSystemName.Capacity)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return fileSystemName.ToString();
    }

    public static string QueryProcessImagePath(IntPtr processHandle) {
        StringBuilder path = new StringBuilder(32768);
        uint size = (uint)path.Capacity;
        if (!QueryFullProcessImageNameW(
                processHandle, 0, path, ref size)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return path.ToString();
    }

    public static string QueryCurrentProcessImagePath() {
        return QueryProcessImagePath(GetCurrentProcess());
    }

    public static TL1C1bNextLauncherIdentityV1 ReadIdentity(SafeFileHandle file) {
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
        ulong lastWrite = ((ulong)information.LastWriteTime.High << 32) |
            information.LastWriteTime.Low;
        return new TL1C1bNextLauncherIdentityV1 {
            LinkCount = information.NumberOfLinks,
            FileAttributes = information.FileAttributes,
            FileSize = size,
            LastWriteTimeUtcFileTime = unchecked((long)lastWrite),
            StableId = fileIdInformation.VolumeSerialNumber.ToString("X16") + ":" +
                fileIdInformation.FileId.HighPart.ToString("X16") +
                fileIdInformation.FileId.LowPart.ToString("X16")
        };
    }

    public static SafeFileHandle CreateKillOnCloseJob() {
        const int JobObjectExtendedLimitInformation = 9;
        const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        SafeFileHandle job = CreateJobObjectW(IntPtr.Zero, null);
        if (job.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            job.Dispose();
            throw new Win32Exception(error);
        }
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION value =
            new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        value.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        IntPtr memory = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(value, memory, false);
            if (!SetInformationJobObject(
                    job, JobObjectExtendedLimitInformation, memory, (uint)size)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return job;
        }
        catch {
            job.Dispose();
            throw;
        }
        finally {
            Marshal.FreeHGlobal(memory);
        }
    }

    public static void AssignProcess(SafeFileHandle job, IntPtr processHandle) {
        if (!AssignProcessToJobObject(job, processHandle)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void TerminateJob(SafeFileHandle job, uint exitCode) {
        if (!TerminateJobObject(job, exitCode)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static uint GetActiveProcessCount(SafeFileHandle job) {
        const int JobObjectBasicAccountingInformation = 1;
        int size = Marshal.SizeOf<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>();
        IntPtr memory = Marshal.AllocHGlobal(size);
        try {
            uint returned;
            if (!QueryInformationJobObject(
                    job, JobObjectBasicAccountingInformation, memory,
                    (uint)size, out returned)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION value =
                Marshal.PtrToStructure<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(memory);
            return value.ActiveProcesses;
        }
        finally {
            Marshal.FreeHGlobal(memory);
        }
    }

    public static async Task<TL1C1bNextLauncherDrainResultV1> DrainAsync(
        Stream input, int captureLimitBytes) {
        if (input == null) throw new ArgumentNullException(nameof(input));
        if (captureLimitBytes < 0) throw new ArgumentOutOfRangeException(nameof(captureLimitBytes));
        byte[] buffer = new byte[65536];
        try {
            using (IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            using (MemoryStream captured = new MemoryStream(
                Math.Min(captureLimitBytes, 65536))) {
                long total = 0;
                bool overflowed = false;
                while (true) {
                    int read = await input.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                    if (read == 0) break;
                    total = checked(total + read);
                    hash.AppendData(buffer, 0, read);
                    int remaining = captureLimitBytes - checked((int)captured.Length);
                    if (remaining > 0) {
                        int keep = Math.Min(remaining, read);
                        captured.Write(buffer, 0, keep);
                    }
                    if (total > captureLimitBytes) overflowed = true;
                    Array.Clear(buffer, 0, read);
                }
                byte[] digest = hash.GetHashAndReset();
                try {
                    return new TL1C1bNextLauncherDrainResultV1 {
                        CapturedBytes = captured.ToArray(),
                        TotalByteLength = total,
                        Overflowed = overflowed,
                        Sha256 = Convert.ToHexString(digest).ToLowerInvariant()
                    };
                }
                finally {
                    Array.Clear(digest, 0, digest.Length);
                }
            }
        }
        finally {
            Array.Clear(buffer, 0, buffer.Length);
        }
    }
}
'@

$launcherPhase = 'working_directory_validation'
$helperPath = '__HELPER_ABSOLUTE_PATH__'
$expectedHelperSha256 = '__HELPER_SHA256__'
$expectedVerifierSha256 = '__VERIFIER_SHA256__'
$pwshPath = '__PWSH_ABSOLUTE_PATH__'
$expectedPwshSha256 = '__PWSH_SHA256__'

$verifierRelativePath = 'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1'
$canonicalRepoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar)
if ($repoRoot -cnotmatch '\A[A-Za-z]:\\' -or
    -not [StringComparer]::Ordinal.Equals($canonicalRepoRoot, $repoRoot)) {
    throw 'The rendered repository root is not one canonical absolute local path.'
}
$currentFileSystemLocation = [IO.Path]::GetFullPath(
    $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
$environmentCurrentDirectory = [IO.Path]::GetFullPath(
    [Environment]::CurrentDirectory).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
        $currentFileSystemLocation, $repoRoot) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals(
        $environmentCurrentDirectory, $repoRoot)) {
    throw 'Both PowerShell and process working directories must match the fixed repository root.'
}
$launcherPhase = 'path_derivation'
$outputRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '.checks'))
$verifierPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $verifierRelativePath))
$summaryPath = [IO.Path]::GetFullPath((Join-Path $outputRoot (
    'tablet-c1b-real-build-smoke-' + $expectedCommitShort + '.summary.json')))
$logPath = [IO.Path]::GetFullPath((Join-Path $outputRoot (
    'tablet-c1b-real-build-smoke-' + $expectedCommitShort + '.log')))
$launcherResultPath = [IO.Path]::GetFullPath((Join-Path $outputRoot (
    'tablet-c1b-real-build-smoke-' + $expectedCommitShort + '.launcher.json')))

$programFiles = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::ProgramFiles)
$userProfileRoot = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::UserProfile)
$localApplicationData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::LocalApplicationData)
$javaHome = [IO.Path]::GetFullPath((Join-Path $programFiles 'Java\jdk-21'))
$gradleHome = [IO.Path]::GetFullPath((Join-Path $userProfileRoot (
    '.gradle\wrapper\dists\gradle-8.9-bin\90cnw93cvbtalezasaz0blq0a\gradle-8.9')))
$androidSdkRoot = [IO.Path]::GetFullPath((Join-Path $localApplicationData 'Android\Sdk'))
$gitPath = [IO.Path]::GetFullPath((Join-Path $programFiles 'Git\cmd\git.exe'))

$helperDeadlineMilliseconds = 2700000L
$helperKillWaitMilliseconds = 30000L
$helperDrainWaitMilliseconds = 30000L
$captureCapBytes = 1048576L
$maximumObserverTailSeconds = 5.0

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

function ConvertFrom-LauncherFinalDosPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return [IO.Path]::GetFullPath('\\' + $Path.Substring(8))
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        return [IO.Path]::GetFullPath($Path.Substring(4))
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-LauncherLocalNtfsPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -cnotmatch '\A[A-Za-z]:\\' -or
        $full.Substring(2).Contains(':')) {
        throw "Launcher trust paths reject device, UNC, relative, and alternate-data-stream forms: $full"
    }
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
        throw "Launcher trust paths must be fully qualified local DOS-volume paths: $full"
    }
    $drive = [IO.DriveInfo]::new($root)
    if (-not $drive.IsReady -or
        $drive.DriveType -ne [IO.DriveType]::Fixed -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals($drive.DriveFormat, 'NTFS')) {
        throw "Launcher trust paths only accept a ready fixed NTFS volume: $full"
    }
}

function Get-LauncherOrdinaryDirectoryChain {
    param([Parameter(Mandatory)][string]$Path)
    $item = Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { throw "Launcher path is not a directory: $Path" }
    $reversed = [Collections.Generic.List[string]]::new()
    $cursor = [IO.DirectoryInfo]$item
    while ($null -ne $cursor) {
        $reversed.Add([IO.Path]::GetFullPath($cursor.FullName))
        $cursor = $cursor.Parent
    }
    $result = [string[]]::new($reversed.Count)
    for ($index = 0; $index -lt $reversed.Count; $index++) {
        $result[$index] = $reversed[$reversed.Count - $index - 1]
    }
    return $result
}

function Assert-LauncherHandleFinalPath {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][string]$ExpectedPath
    )
    $actual = ConvertFrom-LauncherFinalDosPath `
        -Path ([TL1C1bNextLauncherNativeV1]::GetFinalDosPath($Handle))
    $fileSystemName = [TL1C1bNextLauncherNativeV1]::GetFileSystemName($Handle)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $fileSystemName, 'NTFS')) {
        throw 'Held launcher handle is not on exact NTFS.'
    }
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $actual.TrimEnd([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar),
            $expected.TrimEnd([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar))) {
        throw "Held launcher handle final path drifted: $ExpectedPath"
    }
}

function Assert-LauncherDirectoryIdentity {
    param([Parameter(Mandatory)][object]$Identity)
    $directoryFlag = [uint32][IO.FileAttributes]::Directory
    $reparseFlag = [uint32][IO.FileAttributes]::ReparsePoint
    if (([uint32]$Identity.FileAttributes -band $directoryFlag) -eq 0 -or
        ([uint32]$Identity.FileAttributes -band $reparseFlag) -ne 0) {
        throw 'Held launcher directory is not ordinary and reparse-free.'
    }
}

function Assert-LauncherFileIdentity {
    param(
        [Parameter(Mandatory)][object]$Identity,
        [Parameter(Mandatory)][long]$ExpectedLength
    )
    $directoryFlag = [uint32][IO.FileAttributes]::Directory
    $reparseFlag = [uint32][IO.FileAttributes]::ReparsePoint
    if ([uint32]$Identity.LinkCount -ne 1 -or
        ([uint32]$Identity.FileAttributes -band $directoryFlag) -ne 0 -or
        ([uint32]$Identity.FileAttributes -band $reparseFlag) -ne 0 -or
        [uint64]$Identity.FileSize -ne [uint64]$ExpectedLength) {
        throw 'Held launcher file is not ordinary, single-link, stable-size, and reparse-free.'
    }
}

function Add-LauncherHeldDirectoryChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string,object]]$Bindings,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[object]]$Order
    )
    foreach ($directory in @(Get-LauncherOrdinaryDirectoryChain -Path $Path)) {
        Assert-LauncherLocalNtfsPath -Path $directory
        if ($Bindings.ContainsKey($directory)) { continue }
        $handle = $null
        try {
            $handle = [TL1C1bNextLauncherNativeV1]::OpenDirectoryNoFollowDenyDelete(
                $directory)
            $identity = [TL1C1bNextLauncherNativeV1]::ReadIdentity($handle)
            Assert-LauncherDirectoryIdentity -Identity $identity
            Assert-LauncherHandleFinalPath -Handle $handle -ExpectedPath $directory
            $binding = [pscustomobject][ordered]@{
                Path = [string]$directory
                Handle = $handle
                Identity = $identity
            }
            $Bindings.Add($directory, $binding)
            $Order.Add($binding)
            $handle = $null
        }
        finally {
            if ($null -ne $handle) { $handle.Dispose() }
        }
    }
}

function Assert-LauncherHeldDirectoryBinding {
    param([Parameter(Mandatory)][object]$Binding)
    $current = $null
    try {
        $current = [TL1C1bNextLauncherNativeV1]::OpenDirectoryNoFollowDenyDelete(
            [string]$Binding.Path)
        $identity = [TL1C1bNextLauncherNativeV1]::ReadIdentity($current)
        Assert-LauncherDirectoryIdentity -Identity $identity
        Assert-LauncherHandleFinalPath -Handle $current -ExpectedPath ([string]$Binding.Path)
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$identity.StableId,
                [string]$Binding.Identity.StableId)) {
            throw "Launcher directory path no longer resolves to its held identity: $($Binding.Path)"
        }
    }
    finally { if ($null -ne $current) { $current.Dispose() } }
}

function Open-LauncherHeldExactFile {
    param(
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$ExpectedSha256,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string,object]]$DirectoryBindings,
        [Parameter(Mandatory)][Collections.Generic.List[object]]$DirectoryOrder
    )
    $full = [IO.Path]::GetFullPath($Path)
    Assert-LauncherLocalNtfsPath -Path $full
    Add-LauncherHeldDirectoryChain `
        -Path ([IO.Path]::GetDirectoryName($full)) `
        -Bindings $DirectoryBindings -Order $DirectoryOrder
    if (-not [string]::IsNullOrEmpty($ExpectedSha256) -and
        $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z') {
        throw "Pinned $Role SHA-256 is not canonical lowercase hex."
    }
    $safeHandle = $null
    $stream = $null
    try {
        $safeHandle = [TL1C1bNextLauncherNativeV1]::OpenFileReadNoFollowDenyWriteDelete(
            $full)
        Assert-LauncherHandleFinalPath -Handle $safeHandle -ExpectedPath $full
        $stream = [IO.FileStream]::new(
            $safeHandle, [IO.FileAccess]::Read, 65536, $false)
        $safeHandle = $null
        $length = [long]$stream.Length
        $initialIdentity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $stream.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $initialIdentity -ExpectedLength $length
        $actualSha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        $stream.Position = 0L
        $finalIdentity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $stream.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $finalIdentity -ExpectedLength $length
        Assert-LauncherHandleFinalPath -Handle $stream.SafeFileHandle -ExpectedPath $full
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$initialIdentity.StableId, [string]$finalIdentity.StableId) -or
            [long]$initialIdentity.LastWriteTimeUtcFileTime -ne
                [long]$finalIdentity.LastWriteTimeUtcFileTime) {
            throw "Pinned $Role identity changed during held-stream hashing."
        }
        if (-not [string]::IsNullOrEmpty($ExpectedSha256) -and
            $actualSha256 -cne $ExpectedSha256) {
            throw "Pinned $Role SHA-256 binding failed."
        }
        $binding = [pscustomobject][ordered]@{
            Role = [string]$Role
            Path = [string]$full
            ExpectedSha256 = $ExpectedSha256
            ActualSha256 = [string]$actualSha256
            ByteLength = [long]$length
            Identity = $finalIdentity
            Guard = $stream
        }
        $stream = $null
        return $binding
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $safeHandle) { $safeHandle.Dispose() }
    }
}

function Assert-LauncherHeldFileBinding {
    param([Parameter(Mandatory)][object]$Binding)
    $currentHandle = $null
    $currentStream = $null
    try {
        $currentHandle = [TL1C1bNextLauncherNativeV1]::OpenFileReadNoFollowDenyWriteDelete(
            [string]$Binding.Path)
        Assert-LauncherHandleFinalPath -Handle $currentHandle `
            -ExpectedPath ([string]$Binding.Path)
        $currentStream = [IO.FileStream]::new(
            $currentHandle, [IO.FileAccess]::Read, 65536, $false)
        $currentHandle = $null
        $identity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $currentStream.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $identity `
            -ExpectedLength ([long]$Binding.ByteLength)
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$identity.StableId, [string]$Binding.Identity.StableId) -or
            [long]$identity.LastWriteTimeUtcFileTime -ne
                [long]$Binding.Identity.LastWriteTimeUtcFileTime) {
            throw "Pinned $($Binding.Role) path no longer resolves to the held identity."
        }
        $sha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($currentStream)).ToLowerInvariant()
        if ($sha256 -cne [string]$Binding.ActualSha256) {
            throw "Pinned $($Binding.Role) bytes changed while held."
        }
        $heldIdentity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $Binding.Guard.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $heldIdentity `
            -ExpectedLength ([long]$Binding.ByteLength)
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$heldIdentity.StableId, [string]$Binding.Identity.StableId) -or
            [long]$heldIdentity.LastWriteTimeUtcFileTime -ne
                [long]$Binding.Identity.LastWriteTimeUtcFileTime) {
            throw "Pinned $($Binding.Role) held handle identity changed."
        }
    }
    finally {
        if ($null -ne $currentStream) { $currentStream.Dispose() }
        if ($null -ne $currentHandle) { $currentHandle.Dispose() }
    }
}

function Assert-LauncherRuntimePwshMatchesPinned {
    param([Parameter(Mandatory)][object]$PinnedPwshBinding)
    $runtimePath = [IO.Path]::GetFullPath([Environment]::ProcessPath)
    $queriedRuntimePath = [IO.Path]::GetFullPath(
        [TL1C1bNextLauncherNativeV1]::QueryCurrentProcessImagePath())
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $runtimePath, [string]$PinnedPwshBinding.Path) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            $queriedRuntimePath, [string]$PinnedPwshBinding.Path)) {
        throw 'The current PowerShell process image path is not the pinned pwsh path.'
    }
    Assert-LauncherLocalNtfsPath -Path $runtimePath
    $handle = $null
    $stream = $null
    try {
        $handle = [TL1C1bNextLauncherNativeV1]::OpenFileReadNoFollowDenyWriteDelete(
            $runtimePath)
        Assert-LauncherHandleFinalPath -Handle $handle -ExpectedPath $runtimePath
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read, 65536, $false)
        $handle = $null
        $identity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $stream.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $identity `
            -ExpectedLength ([long]$PinnedPwshBinding.ByteLength)
        $sha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$identity.StableId,
                [string]$PinnedPwshBinding.Identity.StableId) -or
            $sha256 -cne [string]$PinnedPwshBinding.ActualSha256) {
            throw 'The current PowerShell process image does not match the pinned pwsh identity and bytes.'
        }
        return [pscustomobject][ordered]@{
            Path = [string]$runtimePath
            QueriedPath = [string]$queriedRuntimePath
            StableId = [string]$identity.StableId
            Sha256 = [string]$sha256
            Matched = $true
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Read-LauncherHeldFileBytes {
    param(
        [Parameter(Mandatory)][object]$Binding,
        [Parameter(Mandatory)][long]$MinimumLength,
        [Parameter(Mandatory)][long]$MaximumLength
    )
    $length = [long]$Binding.ByteLength
    if ($length -lt $MinimumLength -or $length -gt $MaximumLength -or
        $length -gt [int]::MaxValue) {
        throw "Held $($Binding.Role) byte length is outside the closed bound."
    }
    $bytes = [byte[]]::new([int]$length)
    try {
        $Binding.Guard.Position = 0L
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $Binding.Guard.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "Held $($Binding.Role) read ended early." }
            $offset += $read
        }
        if ($Binding.Guard.ReadByte() -ne -1 -or
            [long]$Binding.Guard.Length -ne $length) {
            throw "Held $($Binding.Role) length changed during the read."
        }
        $Binding.Guard.Position = 0L
        $sha256 = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($sha256 -cne [string]$Binding.ActualSha256) {
            throw "Held $($Binding.Role) bytes do not match its held-stream hash."
        }
        return ,$bytes
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null -Phase 'summary_held_file_read'
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        throw
    }
}

function Assert-LauncherExactPSCustomObject {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string[]]$ExpectedProperties
    )
    if ($Value.GetType() -ne [Management.Automation.PSCustomObject]) {
        throw 'Verifier returned a value that is not an exact PSCustomObject.'
    }
    $actual = [string[]]@($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $ExpectedProperties.Count) {
        throw 'Verifier returned an unexpected property count.'
    }
    for ($index = 0; $index -lt $ExpectedProperties.Count; $index++) {
        if ($actual[$index] -cne $ExpectedProperties[$index]) {
            throw 'Verifier returned an unexpected ordered property set.'
        }
    }
}

function Assert-LauncherCapturedVerifierBindings {
    param(
        [Parameter(Mandatory)][string[]]$FunctionNames,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string,object]]$CapturedFunctions,
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string,object]]$CapturedScriptBlocks,
        [Parameter(Mandatory)][string]$ExpectedVerifierPath
    )
    foreach ($name in $FunctionNames) {
        $commands = @(Microsoft.PowerShell.Core\Get-Command `
            -Name $name -All -ErrorAction Stop)
        if ($commands.Count -ne 1 -or
            $commands[0].GetType() -ne [Management.Automation.FunctionInfo] -or
            $commands[0].CommandType -ne
                [Management.Automation.CommandTypes]::Function -or
            -not [object]::ReferenceEquals(
                $commands[0],
                $CapturedFunctions[$name]) -or
            -not [object]::ReferenceEquals(
                $commands[0].ScriptBlock,
                $CapturedScriptBlocks[$name]) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath($commands[0].ScriptBlock.File),
                [IO.Path]::GetFullPath($ExpectedVerifierPath))) {
            throw "Verifier function binding changed after exact capture: $name"
        }
    }
}

function Assert-LauncherFailureSummaryValue {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{40}\z')]
        [string]$ExpectedCommitSha,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')]
        [string]$ExpectedHelperSha256,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessStartedNotBeforeUtc,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessExitedNotAfterUtc
    )
    if ($Value.GetType() -ne [Management.Automation.PSCustomObject]) {
        throw 'Failure summary root is not one exact PSCustomObject.'
    }
    if ($Value.schema -isnot [string] -or
        [string]$Value.schema -cne
            'tablet-layout-c1b-real-build-smoke-summary/v1') {
        throw 'Failure summary schema is not exact.'
    }
    if ($Value.status -isnot [string] -or
        [string]$Value.status -cne 'failed') {
        throw 'Failure summary status is not exact failed.'
    }
    if ($Value.expected_commit_sha -isnot [string] -or
        [string]$Value.expected_commit_sha -cne $ExpectedCommitSha) {
        throw 'Failure summary commit binding is not exact.'
    }
    if ($Value.helper_sha256 -isnot [string] -or
        [string]$Value.helper_sha256 -cne
            ('sha256:' + $ExpectedHelperSha256)) {
        throw 'Failure summary helper binding is not exact.'
    }

    $nonnegativeIntegerProperties = [string[]]@(
        'bootstrap_git_execution_count',
        'real_jdk_gradlemain_execution_count',
        'real_apksigner_execution_count',
        'held_aapt2_verification_execution_count',
        'held_git_execution_count',
        'unexpected_direct_process_count',
        'direct_adb_attempt_count',
        'observed_adb_process_start_count',
        'real_adb_call_count',
        'observed_direct_child_java_process_start_count',
        'observed_other_java_process_start_count',
        'pre_adb_process_count',
        'post_adb_process_count',
        'pre_default_adb_listener_count',
        'post_default_adb_listener_count',
        'device_enumeration_call_count',
        'install_attempt_count',
        't0_call_count',
        'capture_call_count',
        'c1b_java_residual_count',
        'failure_count'
    )
    foreach ($name in $nonnegativeIntegerProperties) {
        $propertyValue = $Value.PSObject.Properties[$name].Value
        if ($propertyValue -isnot [long] -or [long]$propertyValue -lt 0L) {
            throw "Failure summary property is not a nonnegative Int64: $name"
        }
    }
    foreach ($name in @(
            'bootstrap_git_provenance_verified',
            'pre_git_provenance_verified',
            'post_git_provenance_verified',
            'workspace_residual',
            'recovery_journal_residual',
            'module_build_residual',
            'module_gradle_residual',
            'local_properties_residual')) {
        if ($Value.PSObject.Properties[$name].Value -isnot [bool]) {
            throw "Failure summary property is not boolean: $name"
        }
    }

    if ($Value.failure_reasons -isnot [Array]) {
        throw 'Failure summary failure_reasons is not an array.'
    }
    $reasonValues = @($Value.failure_reasons)
    if ([long]$Value.failure_count -lt 1L -or
        $reasonValues.Count -ne [long]$Value.failure_count -or
        $reasonValues.Count -gt 38) {
        throw 'Failure summary failure count and reason cardinality are not exact.'
    }
    $validatedReasons = [Collections.Generic.List[string]]::new()
    $primaryReasonCount = 0L
    $cleanupReasonCount = 0L
    $observerReasonCount = 0L
    $adbBoundaryReasonCount = 0L
    $coreMissingReasonCount = 0L
    $residueReasonCount = 0L
    $canonicalCanaryReasonCount = 0L
    $observerOmissionReasonCount = 0L
    $cleanupOmissionReasonCount = 0L
    foreach ($reason in $reasonValues) {
        if ($reason -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$reason) -or
            [long]([string]$reason).Length -gt 128L) {
            throw 'Failure summary contains an invalid bounded failure reason.'
        }
        if (-not (
                [string]$reason -cmatch '\A(observer|primary|cleanup): ' -or
                [string]$reason -ceq
                    'ADB-zero boundary failed: direct attempt, process-start event, process snapshot, or TCP/5037 listener was nonzero.' -or
                [string]$reason -ceq
                    'core: real build smoke result is missing.' -or
                [string]$reason -ceq
                    'residue: workspace, journal, module output, local.properties, or C1b Java process remained.')) {
            throw 'Failure summary contains a reason outside the helper closed categories.'
        }
        $validatedReasons.Add([string]$reason)
        if ([string]$reason -cmatch '\Aprimary: ') {
            $primaryReasonCount++
        }
        elseif ([string]$reason -cmatch '\Acleanup: ') {
            $cleanupReasonCount++
            if ([string]$reason -cmatch
                    '\Acleanup: closed-bound omitted_count=[1-9][0-9]*\.\z') {
                $cleanupOmissionReasonCount++
            }
        }
        elseif ([string]$reason -cmatch '\Aobserver: ') {
            $observerReasonCount++
            if ([string]$reason -cmatch
                    '\Aobserver: direct-child Java event canary expected 2, observed [0-9]+\.\z') {
                $canonicalCanaryReasonCount++
            }
            elseif ([string]$reason -cmatch
                    '\Aobserver: closed-bound omitted_count=[1-9][0-9]*\.\z') {
                $observerOmissionReasonCount++
            }
        }
        elseif ([string]$reason -ceq
                'ADB-zero boundary failed: direct attempt, process-start event, process snapshot, or TCP/5037 listener was nonzero.') {
            $adbBoundaryReasonCount++
        }
        elseif ([string]$reason -ceq
                'core: real build smoke result is missing.') {
            $coreMissingReasonCount++
        }
        elseif ([string]$reason -ceq
                'residue: workspace, journal, module output, local.properties, or C1b Java process remained.') {
            $residueReasonCount++
        }
    }

    if ([long]$Value.real_adb_call_count -ne
            ([long]$Value.direct_adb_attempt_count +
             [long]$Value.observed_adb_process_start_count)) {
        throw 'Failure summary ADB count relation is not exact.'
    }
    foreach ($name in @(
            'device_enumeration_call_count','install_attempt_count',
            't0_call_count','capture_call_count')) {
        if ([long]$Value.PSObject.Properties[$name].Value -ne 0L) {
            throw "Failure summary crossed the no-device boundary: $name"
        }
    }
    if ([long]$Value.bootstrap_git_execution_count -ne 2L -or
        -not [bool]$Value.bootstrap_git_provenance_verified) {
        throw 'Failure summary bootstrap Git binding is not exact.'
    }
    if ($Value.process_start_observer_scope -isnot [string] -or
        [string]$Value.process_start_observer_scope -cne
            'host_wide_best_effort_wmi' -or
        $Value.process_start_observer_limitation -isnot [string] -or
        [string]$Value.process_start_observer_limitation -cne
            'Win32_ProcessStartTrace is operational observation, not a persistent kernel or syscall audit.' -or
        $Value.default_adb_listener_observation -isnot [string] -or
        [string]$Value.default_adb_listener_observation -cne
            'boundary_snapshots_only') {
        throw 'Failure summary observer contract constants are not exact.'
    }

    $coreProperties = [string[]]@(
        'build_environment_schema','repository_input_count',
        'repository_input_catalog_sha256','repository_input_directory_root_count',
        'jdk_version','jdk_catalog_sha256','gradle_version',
        'gradle_catalog_sha256','gradle_entrypoint','wrapper_not_executed',
        'apksigner_jar_sha256','artifact_proof_sha256','debug_apk_sha256',
        'release_apk_sha256','signer_certificate_sha256','forbidden_match_count',
        'manifest_mutating_capability_count','manifest_extra_component_count',
        'dependency_allowlist_verified','packaged_axml_verified',
        'post_gradle_lock_sealed'
    )
    $nullCorePropertyCount = 0L
    foreach ($name in $coreProperties) {
        if ($null -eq $Value.PSObject.Properties[$name].Value) {
            $nullCorePropertyCount++
        }
    }
    if ($nullCorePropertyCount -ne 0L -and
        $nullCorePropertyCount -ne [long]$coreProperties.Count) {
        throw 'Failure summary core fields are not an all-null or all-present snapshot.'
    }
    $corePresent = [bool]($nullCorePropertyCount -eq 0L)
    $maximumObserverReasonCount = if ($corePresent) { 18L } else { 17L }
    if ($cleanupReasonCount -gt 17L -or
        $observerReasonCount -gt $maximumObserverReasonCount) {
        throw 'Failure summary reason category count exceeds the exact helper bound.'
    }
    if (-not $corePresent) {
        if ($primaryReasonCount -ne 1L -or $coreMissingReasonCount -ne 1L) {
            throw 'Failure summary missing-core state lacks one primary and one core reason.'
        }
    }
    else {
        if ($primaryReasonCount -ne 0L -or $coreMissingReasonCount -ne 0L) {
            throw 'Failure summary present-core state contains a primary or missing-core reason.'
        }
        foreach ($name in @(
                'repository_input_count','repository_input_directory_root_count',
                'forbidden_match_count','manifest_mutating_capability_count',
                'manifest_extra_component_count')) {
            $propertyValue = $Value.PSObject.Properties[$name].Value
            if ($propertyValue -isnot [long] -or [long]$propertyValue -lt 0L) {
                throw "Failure summary core property is not a nonnegative Int64: $name"
            }
        }
        foreach ($name in @(
                'wrapper_not_executed','dependency_allowlist_verified',
                'packaged_axml_verified','post_gradle_lock_sealed')) {
            if ($Value.PSObject.Properties[$name].Value -isnot [bool]) {
                throw "Failure summary core property is not boolean: $name"
            }
        }
        foreach ($name in @(
                'build_environment_schema','repository_input_catalog_sha256',
                'jdk_version','jdk_catalog_sha256','gradle_version',
                'gradle_catalog_sha256','gradle_entrypoint','apksigner_jar_sha256',
                'artifact_proof_sha256','debug_apk_sha256','release_apk_sha256',
                'signer_certificate_sha256')) {
            $propertyValue = $Value.PSObject.Properties[$name].Value
            if ($propertyValue -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$propertyValue)) {
                throw "Failure summary core property is not a nonempty string: $name"
            }
        }
        foreach ($name in @(
                'repository_input_catalog_sha256','jdk_catalog_sha256',
                'gradle_catalog_sha256','apksigner_jar_sha256',
                'artifact_proof_sha256','debug_apk_sha256','release_apk_sha256',
                'signer_certificate_sha256')) {
            if ([string]$Value.PSObject.Properties[$name].Value -cnotmatch
                    '\Asha256:[0-9a-f]{64}\z') {
                throw "Failure summary core hash is not canonical: $name"
            }
        }
        if (-not [bool]$Value.pre_git_provenance_verified -or
            -not [bool]$Value.post_git_provenance_verified -or
            [long]$Value.real_jdk_gradlemain_execution_count -ne 1L -or
            [long]$Value.real_apksigner_execution_count -ne 1L -or
            [long]$Value.held_aapt2_verification_execution_count -ne 4L -or
            [long]$Value.held_git_execution_count -ne 32L -or
            [long]$Value.unexpected_direct_process_count -ne 0L -or
            [long]$Value.direct_adb_attempt_count -ne 0L -or
            [long]$Value.pre_adb_process_count -ne 0L -or
            [long]$Value.pre_default_adb_listener_count -ne 0L) {
            throw 'Failure summary present-core execution/provenance counts are not exact.'
        }
        if ([string]$Value.build_environment_schema -cne
                'tablet-layout-c1b-build-environment-trust/v1' -or
            [long]$Value.repository_input_count -ne 42L -or
            [long]$Value.repository_input_directory_root_count -ne 3L -or
            [string]$Value.jdk_version -cne '21.0.5' -or
            [string]$Value.jdk_catalog_sha256 -cne
                'sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9' -or
            [string]$Value.gradle_version -cne '8.9' -or
            [string]$Value.gradle_catalog_sha256 -cne
                'sha256:d0974b974d9471723cccf083f59e8772448b5bb6672f479bddd63897ba665189' -or
            [string]$Value.gradle_entrypoint -cne
                'org.gradle.launcher.GradleMain' -or
            -not [bool]$Value.wrapper_not_executed -or
            [string]$Value.apksigner_jar_sha256 -cne
                'sha256:00ef9948f843fe395d2440ae3ef41405b8040a6d5d46493bd1902ac0ee6deae7' -or
            [long]$Value.forbidden_match_count -ne 0L -or
            [long]$Value.manifest_mutating_capability_count -ne 0L -or
            [long]$Value.manifest_extra_component_count -ne 0L -or
            -not [bool]$Value.dependency_allowlist_verified -or
            -not [bool]$Value.packaged_axml_verified -or
            -not [bool]$Value.post_gradle_lock_sealed) {
            throw 'Failure summary present-core trust values are not exact.'
        }
    }

    $cleanupStates = [ordered]@{
        artifact_guards_cleanup = [string[]]@('not_acquired','completed','failed')
        build_environment_cleanup = [string[]]@('not_acquired','completed','failed')
        repository_library_guards_cleanup = [string[]]@('completed','failed')
    }
    foreach ($entry in $cleanupStates.GetEnumerator()) {
        $propertyValue = $Value.PSObject.Properties[[string]$entry.Key].Value
        if ($propertyValue -isnot [string] -or
            -not ([string[]]$entry.Value).Contains([string]$propertyValue)) {
            throw "Failure summary cleanup state is outside the closed set: $($entry.Key)"
        }
    }
    if ($corePresent -and (
            [string]$Value.artifact_guards_cleanup -ceq 'not_acquired' -or
            [string]$Value.build_environment_cleanup -ceq 'not_acquired')) {
        throw 'Failure summary present-core cleanup state is unreachable.'
    }
    if (-not $corePresent -and
        [string]$Value.artifact_guards_cleanup -cne 'not_acquired' -and
        [string]$Value.build_environment_cleanup -ceq 'not_acquired') {
        throw 'Failure summary missing-core cleanup acquisition order is unreachable.'
    }
    if (-not $corePresent -and
        -not [bool]$Value.pre_git_provenance_verified -and
        [bool]$Value.post_git_provenance_verified) {
        throw 'Failure summary missing-core Git provenance state is unreachable.'
    }

    $adbBoundaryFailed = [bool](
        [long]$Value.direct_adb_attempt_count -ne 0L -or
        [long]$Value.observed_adb_process_start_count -ne 0L -or
        [long]$Value.pre_adb_process_count -ne 0L -or
        [long]$Value.post_adb_process_count -ne 0L -or
        [long]$Value.pre_default_adb_listener_count -ne 0L -or
        [long]$Value.post_default_adb_listener_count -ne 0L)
    $expectedAdbBoundaryReasonCount = if ($adbBoundaryFailed) { 1L } else { 0L }
    if ($adbBoundaryReasonCount -ne $expectedAdbBoundaryReasonCount) {
        throw 'Failure summary ADB boundary reason is not iff-bound to its counters.'
    }
    $residueFailed = [bool](
        [bool]$Value.workspace_residual -or
        [bool]$Value.recovery_journal_residual -or
        [bool]$Value.module_build_residual -or
        [bool]$Value.module_gradle_residual -or
        [bool]$Value.local_properties_residual -or
        [long]$Value.c1b_java_residual_count -ne 0L)
    $expectedResidueReasonCount = if ($residueFailed) { 1L } else { 0L }
    if ($residueReasonCount -ne $expectedResidueReasonCount) {
        throw 'Failure summary residue reason is not iff-bound to residue fields.'
    }
    $cleanupFailed = [bool](
        [string]$Value.artifact_guards_cleanup -ceq 'failed' -or
        [string]$Value.build_environment_cleanup -ceq 'failed' -or
        [string]$Value.repository_library_guards_cleanup -ceq 'failed')
    if (($cleanupReasonCount -gt 0L) -ne $cleanupFailed) {
        throw 'Failure summary cleanup reasons are not iff-bound to cleanup state.'
    }
    if ($corePresent) {
        $canaryReason = 'observer: direct-child Java event canary expected 2, observed ' +
            [string][long]$Value.observed_direct_child_java_process_start_count + '.'
        $canaryFailed = [bool](
            [long]$Value.observed_direct_child_java_process_start_count -ne 2L)
        $expectedCanaryReasonCount = if ($canaryFailed) { 1L } else { 0L }
        if ($canonicalCanaryReasonCount -ne $expectedCanaryReasonCount -or
            $validatedReasons.Contains($canaryReason) -ne $canaryFailed) {
            throw 'Failure summary Java canary reason is not iff-bound to its count.'
        }
    }
    elseif ($canonicalCanaryReasonCount -ne 0L) {
        throw 'Failure summary missing-core state contains an unreachable Java canary reason.'
    }
    $nonCanaryObserverReasonCount = [long](
        $observerReasonCount - $canonicalCanaryReasonCount)
    if ($nonCanaryObserverReasonCount -gt 17L -or
        (($nonCanaryObserverReasonCount -eq 17L) -ne
         ($observerOmissionReasonCount -eq 1L)) -or
        ($nonCanaryObserverReasonCount -lt 17L -and
         $observerOmissionReasonCount -ne 0L) -or
        (($cleanupReasonCount -eq 17L) -ne
         ($cleanupOmissionReasonCount -eq 1L)) -or
        ($cleanupReasonCount -lt 17L -and
         $cleanupOmissionReasonCount -ne 0L)) {
        throw 'Failure summary closed-bound omission markers are not exact.'
    }

    $timestampPattern =
        '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z\z'
    foreach ($name in @('started_at_utc','completed_at_utc')) {
        $propertyValue = $Value.PSObject.Properties[$name].Value
        if ($propertyValue -isnot [string] -or
            [string]$propertyValue -cnotmatch $timestampPattern) {
            throw "Failure summary timestamp is not exact UTC: $name"
        }
    }
    $timestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
    $timestampStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        $startedAt = [DateTimeOffset]::ParseExact(
            [string]$Value.started_at_utc,
            $timestampFormat,
            [Globalization.CultureInfo]::InvariantCulture,
            $timestampStyles)
        $completedAt = [DateTimeOffset]::ParseExact(
            [string]$Value.completed_at_utc,
            $timestampFormat,
            [Globalization.CultureInfo]::InvariantCulture,
            $timestampStyles)
    }
    catch {
        throw 'Failure summary contains an invalid UTC timestamp.'
    }
    if ($completedAt -lt $startedAt -or
        $startedAt -lt $HelperProcessStartedNotBeforeUtc -or
        $completedAt -gt $HelperProcessExitedNotAfterUtc) {
        throw 'Failure summary timestamps are outside the helper process envelope.'
    }
    $observerEndedRaw = $Value.process_start_observation_ended_at_utc
    if ($null -eq $observerEndedRaw) {
        if (($observerReasonCount - $canonicalCanaryReasonCount) -eq 0L) {
            throw 'Failure summary lacks an observer reason for a null observer timestamp.'
        }
    }
    else {
        if ($observerEndedRaw -isnot [string] -or
            [string]$observerEndedRaw -cnotmatch $timestampPattern) {
            throw 'Failure summary observer timestamp is not exact UTC.'
        }
        try {
            $observerEndedAt = [DateTimeOffset]::ParseExact(
                [string]$observerEndedRaw,
                $timestampFormat,
                [Globalization.CultureInfo]::InvariantCulture,
                $timestampStyles)
        }
        catch {
            throw 'Failure summary contains an invalid observer UTC timestamp.'
        }
        if ($observerEndedAt -le $startedAt -or
            $observerEndedAt -gt $completedAt) {
            throw 'Failure summary observer timestamp ordering is invalid.'
        }
    }

    return [pscustomobject][ordered]@{
        FailureCount = [long]$Value.failure_count
        Reasons = [string[]]$validatedReasons.ToArray()
    }
}

function Write-LauncherAtomicNewUtf8Json {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)]
        [ValidateSet('log_publication','result_publication')]
        [string]$FailurePhase
    )
    $full = [IO.Path]::GetFullPath($Path)
    Assert-LauncherLocalNtfsPath -Path $full
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $full) {
        throw "Atomic no-overwrite output already exists: $full"
    }
    $raw = $Value | Microsoft.PowerShell.Utility\ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($raw)
    $parent = [IO.Path]::GetDirectoryName($full)
    $temp = [IO.Path]::GetFullPath((Join-Path $parent (
        '.' + [IO.Path]::GetFileName($full) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp')))
    $stream = $null
    $handle = $null
    $readStream = $null
    $published = $false
    $writeFailure = $null
    $binding = $null
    try {
        $stream = [IO.FileStream]::new(
            $temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [IO.File]::Move($temp, $full, $false)
        $published = $true

        $handle = [TL1C1bNextLauncherNativeV1]::OpenFileReadNoFollowDenyWriteDelete(
            $full)
        Assert-LauncherHandleFinalPath -Handle $handle -ExpectedPath $full
        $readStream = [IO.FileStream]::new(
            $handle, [IO.FileAccess]::Read, 65536, $false)
        $handle = $null
        $identity = [TL1C1bNextLauncherNativeV1]::ReadIdentity(
            $readStream.SafeFileHandle)
        Assert-LauncherFileIdentity -Identity $identity `
            -ExpectedLength ([long]$bytes.Length)
        $actual = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($readStream)).ToLowerInvariant()
        $expected = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($actual -cne $expected) {
            throw 'Atomic JSON output readback hash drifted.'
        }
        $binding = [pscustomobject][ordered]@{
            Path = [string]$full
            ByteLength = [long]$bytes.Length
            ActualSha256 = [string]$expected
            Sha256 = 'sha256:' + $expected
            Identity = $identity
        }
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null `
            -Phase ($FailurePhase + '_atomic_write_readback')
        $writeFailure = $_.Exception
    }
    finally {
        foreach ($resource in @($readStream, $handle, $stream)) {
            if ($null -eq $resource) { continue }
            try { $resource.Dispose() }
            catch {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $_ -Exception $null `
                    -Phase ($FailurePhase + '_resource_cleanup')
                $writeFailure = Merge-LauncherFailure `
                    -Existing $writeFailure -Additional $_.Exception `
                    -Message 'Atomic JSON write and handle cleanup both failed.'
            }
        }
        try {
            if (-not $published -and
                (Microsoft.PowerShell.Management\Test-Path -LiteralPath $temp)) {
                Microsoft.PowerShell.Management\Remove-Item `
                    -LiteralPath $temp -Force -ErrorAction Stop
                if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $temp) {
                    throw 'Atomic JSON temporary output cleanup failed.'
                }
            }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase ($FailurePhase + '_temporary_cleanup')
            $writeFailure = Merge-LauncherFailure `
                -Existing $writeFailure -Additional $_.Exception `
                -Message 'Atomic JSON write and temporary cleanup both failed.'
        }
        try {
            if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase ($FailurePhase + '_buffer_cleanup')
            $writeFailure = Merge-LauncherFailure `
                -Existing $writeFailure -Additional $_.Exception `
                -Message 'Atomic JSON write and buffer cleanup both failed.'
        }
    }
    if ($null -ne $writeFailure) { throw $writeFailure }
    return $binding
}

function Wait-LauncherJobEmptyBounded {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Job,
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][long]$DeadlineMilliseconds
    )
    while ($true) {
        $remaining = $DeadlineMilliseconds - [long]$Stopwatch.ElapsedMilliseconds
        if ($remaining -lt 0) { return $false }
        $active = [uint32][TL1C1bNextLauncherNativeV1]::GetActiveProcessCount($Job)
        if ($active -eq 0) { return $true }
        if ($remaining -le 0) { return $false }
        [Threading.Thread]::Sleep([int][Math]::Min(100L, $remaining))
    }
}

function Stop-LauncherHelperJobBounded {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Job,
        [Parameter(Mandatory)][long]$WaitMilliseconds
    )
    $failures = [Collections.Generic.List[Exception]]::new()
    $killTreeRequested = $false
    $jobTerminationRequested = $false
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $killTreeRequested = $true
        }
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null `
            -Phase 'helper_process_termination_request'
        $failures.Add($_.Exception)
    }
    try {
        [TL1C1bNextLauncherNativeV1]::TerminateJob($Job, 1)
        $jobTerminationRequested = $true
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null `
            -Phase 'helper_job_termination_request'
        $failures.Add($_.Exception)
    }

    $wait = [Diagnostics.Stopwatch]::StartNew()
    $rootExited = $false
    try {
        if ($Process.HasExited) { $rootExited = $true }
        else {
            $remaining = $WaitMilliseconds - [long]$wait.ElapsedMilliseconds
            if ($remaining -gt 0) {
                $rootExited = [bool]$Process.WaitForExit([int]$remaining)
            }
        }
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null `
            -Phase 'helper_root_exit_confirmation'
        $failures.Add($_.Exception)
    }
    $jobEmpty = $false
    try {
        $jobEmpty = Wait-LauncherJobEmptyBounded `
            -Job $Job -Stopwatch $wait -DeadlineMilliseconds $WaitMilliseconds
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null `
            -Phase 'helper_job_empty_confirmation'
        $failures.Add($_.Exception)
    }
    if (-not $rootExited) {
        $failures.Add([InvalidOperationException]::new(
            'Helper root process did not exit inside the kill window.'))
    }
    if (-not $jobEmpty) {
        $failures.Add([InvalidOperationException]::new(
            'Helper Job Object did not reach zero active processes inside the kill window.'))
    }
    return [pscustomobject][ordered]@{
        KillTreeRequested = [bool]$killTreeRequested
        JobTerminationRequested = [bool]$jobTerminationRequested
        RootExitConfirmed = [bool]$rootExited
        JobEmptyConfirmed = [bool]$jobEmpty
        Failures = $failures.ToArray()
    }
}

function Wait-LauncherDrainsBounded {
    param(
        [Parameter(Mandatory)][Threading.Tasks.Task]$StdoutTask,
        [Parameter(Mandatory)][Threading.Tasks.Task]$StderrTask,
        [Parameter(Mandatory)][long]$WaitMilliseconds
    )
    $combined = [Threading.Tasks.Task]::WhenAll(
        [Threading.Tasks.Task[]]@($StdoutTask, $StderrTask))
    if (-not $combined.Wait([int]$WaitMilliseconds)) {
        throw 'Helper stdout/stderr drains did not both reach EOF inside the shared drain window.'
    }
    if (-not $StdoutTask.IsCompletedSuccessfully -or
        -not $StderrTask.IsCompletedSuccessfully) {
        throw 'Helper stdout/stderr drain task faulted or was canceled.'
    }
    return [pscustomobject][ordered]@{
        Stdout = $StdoutTask.Result
        Stderr = $StderrTask.Result
    }
}

$completedAtUtc = $null
$cleanupFailures = [Collections.Generic.List[Exception]]::new()
$directoryBindings = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::OrdinalIgnoreCase)
$directoryOrder = [Collections.Generic.List[object]]::new()
$fileBindings = [Collections.Generic.List[object]]::new()
$launcherBinding = $null
$helperBinding = $null
$verifierBinding = $null
$pwshBinding = $null
$summaryBinding = $null
$runtimePwshBinding = $null
$logBinding = $null
$resultBinding = $null
$summaryBytes = $null
$summaryRaw = $null
$summaryValue = $null
$expectedStdoutBytes = $null
$stdoutResult = $null
$stderrResult = $null
$capturedVerifierFunction = $null
$capturedVerifierFunctions = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal)
$capturedVerifierScriptBlocks = [Collections.Generic.Dictionary[string,object]]::new(
    [StringComparer]::Ordinal)
$verifierLoadOutput = $null
$verifierResult = $null
$process = $null
$processGate = $null
$helperJob = $null
$stdoutDrainTask = $null
$stderrDrainTask = $null
$helperDeadlineStopwatch = $null
$helperProcessStartedNotBeforeUtc = $null
$helperProcessExitedNotAfterUtc = $null
$helperProcessId = $null
$helperExitCode = $null
$helperTermination = 'not_started'
$helperReleaseCount = 0L
$helperGateSignalCount = 0L
$jobAssignmentCompleted = $false
$helperJobValidationActiveProcessCount = $null
$helperJobCleanupActiveProcessCount = $null
$helperChildTerminationValidationVerified = $false
$helperChildTerminationCleanupVerified = $false
$helperKillAttemptCount = 0L
$helperKillSucceeded = $false
$helperJobTerminationAttemptCount = 0L
$helperJobTerminationSucceeded = $false
$helperRootExitConfirmed = $false
$helperJobEmptyConfirmed = $false
$helperTimedOut = $false
$helperTimeoutReason = $null
$helperDrainWaitAttemptCount = 0L
$helperDrainCompleted = $false
$stdoutForcedClosed = $false
$stderrForcedClosed = $false
$helperProcessDisposed = $false
$helperJobDisposed = $false
$helperGateDisposed = $false
$verifierLoadAttemptCount = 0L
$verifierLoadCount = 0L
$verifierSummaryParseAttemptCount = 0L
$verifierSummaryParseCount = 0L
$verifierInvokeAttemptCount = 0L
$verifierInvokeCount = 0L
$helperSummaryVerified = $false
$stdoutExactSummaryPlusCrLf = $false
$summaryPreexisting = $null
$logPreexisting = $null
$resultPreexisting = $null
$runtimePwshReopenMatchesHeld = $false
$childPwshQueryImagePathMatchesHeld = $false
$fixedFileGuardsCleanup = 'not_started'
$directoryGuardsCleanup = 'not_started'
$sensitiveBuffersCleanup = 'not_started'
$processCleanup = 'not_started'
$logPublished = $false

$launcherPhase = 'closed_constants'
try {
    if ($expectedCommitSha -cnotmatch '\A[0-9a-f]{40}\z' -or
        $expectedCommitShort -cnotmatch '\A[0-9a-f]{7}\z' -or
        -not $expectedCommitSha.StartsWith(
            $expectedCommitShort, [StringComparison]::Ordinal)) {
        throw 'Final candidate commit placeholders were not replaced canonically.'
    }
    foreach ($hash in @(
            $expectedHelperSha256, $expectedVerifierSha256,
            $expectedPwshSha256, $ExpectedLauncherSha256)) {
        if ([string]$hash -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'One or more launcher SHA-256 bindings are not canonical lowercase hex.'
        }
    }
    if ($verifierFunctionNames.Count -ne 16 -or
        $automaticRetryCount -ne 0L -or
        $helperDeadlineMilliseconds -ne 2700000L -or
        $helperKillWaitMilliseconds -ne 30000L -or
        $helperDrainWaitMilliseconds -ne 30000L -or
        $captureCapBytes -ne 1048576L -or
        $maximumObserverTailSeconds -ne 5.0) {
        throw 'Launcher closed constants drifted.'
    }
    $launcherPhase = 'elevation_check'
    $elevatedToken = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevatedToken) {
        throw 'The build-only helper requires an elevated launcher token.'
    }

    $launcherPhase = 'trust_path_validation'
    $launcherPath = [IO.Path]::GetFullPath($PSCommandPath)
    $fullHelperPath = [IO.Path]::GetFullPath($helperPath)
    $fullPwshPath = [IO.Path]::GetFullPath($pwshPath)
    $fullFailureSidecarPath = [IO.Path]::GetFullPath($failureSidecarPath)
    $repoPrefix = $repoRoot + [IO.Path]::DirectorySeparatorChar
    if ($launcherPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $fullHelperPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Launcher and helper must both remain outside the repository.'
    }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $fullFailureSidecarPath, $failureSidecarPath) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($fullFailureSidecarPath),
            [IO.Path]::GetDirectoryName($launcherPath)) -or
        -not $fullFailureSidecarPath.EndsWith(
            '.failure.json', [StringComparison]::Ordinal)) {
        throw 'Failure sidecar is not the fixed absolute launcher sibling.'
    }
    if (-not $verifierPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetRelativePath($repoRoot, $verifierPath),
            $verifierRelativePath)) {
        throw 'Verifier is not at the fixed repository-relative path.'
    }
    foreach ($target in @($summaryPath, $logPath, $launcherResultPath)) {
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($target), $outputRoot)) {
            throw 'Launcher output escaped the exact .checks parent.'
        }
    }

    $launcherPhase = 'held_repo_chain'
    Add-LauncherHeldDirectoryChain -Path $repoRoot `
        -Bindings $directoryBindings -Order $directoryOrder
    $launcherPhase = 'held_output_chain'
    Add-LauncherHeldDirectoryChain -Path $outputRoot `
        -Bindings $directoryBindings -Order $directoryOrder
    $outputChainHeld = $true

    $launcherPhase = 'held_self'
    $launcherBinding = Open-LauncherHeldExactFile `
        -Role 'self' -Path $launcherPath `
        -ExpectedSha256 $ExpectedLauncherSha256 `
        -DirectoryBindings $directoryBindings -DirectoryOrder $directoryOrder
    $fileBindings.Add($launcherBinding)
    $launcherPhase = 'held_helper'
    $helperBinding = Open-LauncherHeldExactFile `
        -Role 'helper' -Path $fullHelperPath `
        -ExpectedSha256 $expectedHelperSha256 `
        -DirectoryBindings $directoryBindings -DirectoryOrder $directoryOrder
    $fileBindings.Add($helperBinding)
    $launcherPhase = 'held_verifier'
    $verifierBinding = Open-LauncherHeldExactFile `
        -Role 'verifier' -Path $verifierPath `
        -ExpectedSha256 $expectedVerifierSha256 `
        -DirectoryBindings $directoryBindings -DirectoryOrder $directoryOrder
    $fileBindings.Add($verifierBinding)
    $launcherPhase = 'held_pwsh'
    $pwshBinding = Open-LauncherHeldExactFile `
        -Role 'pwsh' -Path $fullPwshPath `
        -ExpectedSha256 $expectedPwshSha256 `
        -DirectoryBindings $directoryBindings -DirectoryOrder $directoryOrder
    $fileBindings.Add($pwshBinding)
    $launcherPhase = 'runtime_pwsh'
    $runtimePwshBinding = Assert-LauncherRuntimePwshMatchesPinned `
        -PinnedPwshBinding $pwshBinding
    $runtimePwshReopenMatchesHeld = [bool]$runtimePwshBinding.Matched
    if ($PSVersionTable.PSEdition -cne 'Core' -or
        $PSVersionTable.PSVersion.ToString() -cne '7.6.5') {
        throw 'The current runtime is not exact PowerShell Core 7.6.5.'
    }

    foreach ($binding in $fileBindings) {
        Assert-LauncherHeldFileBinding -Binding $binding
    }
    foreach ($binding in $directoryOrder) {
        Assert-LauncherHeldDirectoryBinding -Binding $binding
    }

    $launcherPhase = 'output_absence'
    $summaryPreexisting = [bool](
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $summaryPath)
    $logPreexisting = [bool](
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $logPath)
    $resultPreexisting = [bool](
        Microsoft.PowerShell.Management\Test-Path -LiteralPath $launcherResultPath)
    $failureSidecarPreexisting = [TL1C1bNextLauncherNativeV1]::
        EntryExistsNoFollow($fullFailureSidecarPath)
    if ($summaryPreexisting -or $logPreexisting -or $resultPreexisting -or
        $failureSidecarPreexisting) {
        throw 'One or more one-shot output paths already exist.'
    }
    $outputTargetsAbsent = $true

    $launcherPhase = 'verifier_load'
    foreach ($name in $verifierFunctionNames) {
        $existing = @(Microsoft.PowerShell.Core\Get-Command `
            -Name $name -All -ErrorAction SilentlyContinue)
        if ($existing.Count -ne 0) {
            throw "Verifier command name existed before exact load: $name"
        }
    }
    if ($null -ne ('TL1C1bRealBuildSmokeFileIdentityV1' -as [type])) {
        throw 'Verifier native authority type existed before exact load.'
    }
    $verifierLoadAttemptCount++
    $verifierLoadOutput = @(
        . $verifierBinding.Path 2>&1 3>&1 4>&1 5>&1 6>&1
    )
    $verifierLoadCount++
    if ($verifierLoadAttemptCount -ne 1L -or
        $verifierLoadCount -ne 1L -or
        $verifierLoadOutput.Count -ne 0) {
        throw 'Verifier exact load was not one silent load.'
    }
    foreach ($name in $verifierFunctionNames) {
        $commands = @(Microsoft.PowerShell.Core\Get-Command `
            -Name $name -All -ErrorAction Stop)
        if ($commands.Count -ne 1 -or
            $commands[0].GetType() -ne [Management.Automation.FunctionInfo] -or
            $commands[0].CommandType -ne [Management.Automation.CommandTypes]::Function -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetFullPath($commands[0].ScriptBlock.File),
                [string]$verifierBinding.Path)) {
            throw "Verifier function binding is not one exact FunctionInfo from the held file: $name"
        }
        if ($name -ceq 'Assert-TL1C1bRealBuildSmokeSummaryFile') {
            $capturedVerifierFunction = $commands[0]
        }
        $capturedVerifierFunctions.Add($name, $commands[0])
        $capturedVerifierScriptBlocks.Add($name, $commands[0].ScriptBlock)
    }
    if ($null -eq $capturedVerifierFunction) {
        throw 'Public verifier FunctionInfo was not captured.'
    }

    $gateCreatedNew = $false
    $gateName = 'Local\TL1C1bBuildSmokeGate-' + [guid]::NewGuid().ToString('N')
    $processGate = [Threading.EventWaitHandle]::new(
        $false, [Threading.EventResetMode]::ManualReset,
        $gateName, [ref]$gateCreatedNew)
    if (-not $gateCreatedNew) {
        throw 'The unique helper release gate was not created new.'
    }
    $helperJob = [TL1C1bNextLauncherNativeV1]::CreateKillOnCloseJob()

    $childBootstrapSource = @'
#Requires -Version 7.5
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$gate = [Threading.EventWaitHandle]::OpenExisting($env:TL1C1B_LAUNCH_GATE)
try {
    if (-not $gate.WaitOne(120000)) {
        throw 'The held launcher did not release the helper bootstrap gate in time.'
    }
}
finally { $gate.Dispose() }
try {
    & ([IO.Path]::GetFullPath($env:TL1C1B_HELPER_PATH)) `
        -RepoRoot ([IO.Path]::GetFullPath($env:TL1C1B_REPO_ROOT)) `
        -ExpectedCommitSha $env:TL1C1B_EXPECTED_COMMIT `
        -JavaHome ([IO.Path]::GetFullPath($env:TL1C1B_JAVA_HOME)) `
        -GradleHome ([IO.Path]::GetFullPath($env:TL1C1B_GRADLE_HOME)) `
        -AndroidSdkRoot ([IO.Path]::GetFullPath($env:TL1C1B_ANDROID_SDK_ROOT)) `
        -SummaryPath ([IO.Path]::GetFullPath($env:TL1C1B_SUMMARY_PATH)) `
        -GitPath ([IO.Path]::GetFullPath($env:TL1C1B_GIT_PATH))
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
    $childBootstrapBytes = [Text.Encoding]::Unicode.GetBytes($childBootstrapSource)
    try {
        $childEncodedCommand = [Convert]::ToBase64String($childBootstrapBytes)
    }
    finally {
        if ($childBootstrapBytes.Length -ne 0) {
            [Array]::Clear($childBootstrapBytes, 0, $childBootstrapBytes.Length)
        }
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$pwshBinding.Path
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in @($startInfo.Environment.Keys)) {
        if ([string]$key -like 'GIT_*' -or [string]$key -like 'TL1C1B_*') {
            $null = $startInfo.Environment.Remove([string]$key)
        }
    }
    $startInfo.Environment['TL1C1B_LAUNCH_GATE'] = $gateName
    $startInfo.Environment['TL1C1B_HELPER_PATH'] = [string]$helperBinding.Path
    $startInfo.Environment['TL1C1B_REPO_ROOT'] = $repoRoot
    $startInfo.Environment['TL1C1B_EXPECTED_COMMIT'] = $expectedCommitSha
    $startInfo.Environment['TL1C1B_JAVA_HOME'] = $javaHome
    $startInfo.Environment['TL1C1B_GRADLE_HOME'] = $gradleHome
    $startInfo.Environment['TL1C1B_ANDROID_SDK_ROOT'] = $androidSdkRoot
    $startInfo.Environment['TL1C1B_SUMMARY_PATH'] = $summaryPath
    $startInfo.Environment['TL1C1B_GIT_PATH'] = $gitPath
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-EncodedCommand', $childEncodedCommand)) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    foreach ($binding in $fileBindings) {
        Assert-LauncherHeldFileBinding -Binding $binding
    }
    foreach ($binding in $directoryOrder) {
        Assert-LauncherHeldDirectoryBinding -Binding $binding
    }

    $launcherPhase = 'failure_sidecar_absence_before_helper'
    $failureSidecarPreexisting = [TL1C1bNextLauncherNativeV1]::
        EntryExistsNoFollow($fullFailureSidecarPath)
    if ($failureSidecarPreexisting) {
        throw 'Failure sidecar appeared before the one-shot helper start.'
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $launcherPhase = 'helper_start'
    $helperStartAttemptCount = 1L
    $helperDeadlineStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $helperProcessStartedNotBeforeUtc = [DateTimeOffset]::UtcNow
    if (-not $process.Start()) {
        throw 'The one-shot helper bootstrap process could not start.'
    }
    $helperStartCount = 1L
    $launcherPhase = 'helper_process_binding'
    $helperProcessId = [int]$process.Id
    $stdoutDrainTask = [TL1C1bNextLauncherNativeV1]::DrainAsync(
        $process.StandardOutput.BaseStream, [int]$captureCapBytes)
    $stderrDrainTask = [TL1C1bNextLauncherNativeV1]::DrainAsync(
        $process.StandardError.BaseStream, [int]$captureCapBytes)
    $childPwshImagePath = [IO.Path]::GetFullPath(
        [TL1C1bNextLauncherNativeV1]::QueryProcessImagePath($process.Handle))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $childPwshImagePath, [string]$pwshBinding.Path)) {
        throw 'The helper bootstrap process image path is not the held pinned pwsh path.'
    }
    $childPwshQueryImagePathMatchesHeld = $true
    [TL1C1bNextLauncherNativeV1]::AssignProcess(
        $helperJob, $process.Handle)
    $jobAssignmentCompleted = $true
    if (-not $processGate.Set()) {
        throw 'The Job-assigned helper bootstrap release gate could not be signaled.'
    }
    $helperReleaseCount = 1L
    $helperGateSignalCount = 1L
    $launcherPhase = 'helper_supervision'

    $remainingDeadline = $helperDeadlineMilliseconds -
        [long]$helperDeadlineStopwatch.ElapsedMilliseconds
    $rootExitedInsideDeadline = $false
    if ($remainingDeadline -gt 0) {
        $rootExitedInsideDeadline = [bool]$process.WaitForExit([int]$remainingDeadline)
    }
    if (-not $rootExitedInsideDeadline) {
        $helperTimedOut = $true
        $helperTimeoutReason =
            'The one-shot helper crossed the exact 45-minute monotonic hard deadline.'
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $null `
            -Exception ([TimeoutException]::new($helperTimeoutReason)) `
            -Phase 'helper_root_deadline'
        $helperKillAttemptCount++
        $helperJobTerminationAttemptCount++
        $termination = Stop-LauncherHelperJobBounded `
            -Process $process -Job $helperJob `
            -WaitMilliseconds $helperKillWaitMilliseconds
        $helperKillSucceeded = [bool](
            $helperKillSucceeded -or $termination.KillTreeRequested)
        $helperJobTerminationSucceeded = [bool](
            $helperJobTerminationSucceeded -or $termination.JobTerminationRequested)
        $helperRootExitConfirmed = [bool]$termination.RootExitConfirmed
        $helperJobEmptyConfirmed = [bool]$termination.JobEmptyConfirmed
        foreach ($terminationFailure in $termination.Failures) {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $null -Exception $terminationFailure `
                -Phase 'helper_deadline_termination'
            $cleanupFailures.Add($terminationFailure)
        }
        if ($helperRootExitConfirmed) {
            $helperProcessExitedNotAfterUtc = [DateTimeOffset]::UtcNow
        }
        $helperTermination = 'deadline_job_terminated'
    }
    else {
        $helperRootExitConfirmed = $true
        $helperProcessExitedNotAfterUtc = [DateTimeOffset]::UtcNow
        $helperTermination = 'natural_root_exit'
    }

    if (-not $helperTimedOut) {
        $helperJobEmptyConfirmed = Wait-LauncherJobEmptyBounded `
            -Job $helperJob -Stopwatch $helperDeadlineStopwatch `
            -DeadlineMilliseconds $helperDeadlineMilliseconds
        if (-not $helperJobEmptyConfirmed) {
            $helperTimedOut = $true
            $helperTimeoutReason =
                'The helper Job remained nonempty at the exact 45-minute monotonic hard deadline.'
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $null `
                -Exception ([TimeoutException]::new($helperTimeoutReason)) `
                -Phase 'helper_job_deadline'
            $helperKillAttemptCount++
            $helperJobTerminationAttemptCount++
            $termination = Stop-LauncherHelperJobBounded `
                -Process $process -Job $helperJob `
                -WaitMilliseconds $helperKillWaitMilliseconds
            $helperKillSucceeded = [bool](
                $helperKillSucceeded -or $termination.KillTreeRequested)
            $helperJobTerminationSucceeded = [bool](
                $helperJobTerminationSucceeded -or $termination.JobTerminationRequested)
            $helperJobEmptyConfirmed = [bool]$termination.JobEmptyConfirmed
            foreach ($terminationFailure in $termination.Failures) {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $null -Exception $terminationFailure `
                    -Phase 'helper_job_deadline_termination'
                $cleanupFailures.Add($terminationFailure)
            }
            $helperTermination = 'post_root_job_deadline_terminated'
        }
    }
    if ($helperRootExitConfirmed -and $helperJobEmptyConfirmed) {
        $helperDrainWaitAttemptCount++
        $drains = Wait-LauncherDrainsBounded `
            -StdoutTask $stdoutDrainTask -StderrTask $stderrDrainTask `
            -WaitMilliseconds $helperDrainWaitMilliseconds
        $stdoutResult = $drains.Stdout
        $stderrResult = $drains.Stderr
        $helperDrainCompleted = $true
    }
    if ($helperRootExitConfirmed) {
        $helperExitCode = [int]$process.ExitCode
    }
    if ($null -ne $helperJob) {
        $helperJobValidationActiveProcessCount = [long](
            [TL1C1bNextLauncherNativeV1]::GetActiveProcessCount($helperJob))
    }
    $helperChildTerminationValidationVerified = (
        $helperRootExitConfirmed -and
        $helperJobValidationActiveProcessCount -eq 0L)
    $launcherPhase = 'helper_result_validation'
    if ($helperTimedOut) {
        throw [TimeoutException]::new($helperTimeoutReason)
    }
    if (-not $helperRootExitConfirmed -or -not $helperJobEmptyConfirmed -or
        -not $helperChildTerminationValidationVerified -or
        -not $helperDrainCompleted) {
        throw 'Helper root exit, Job Object zero-active closure, or stream EOF drain was not confirmed.'
    }
    if ($stdoutResult.Overflowed) {
        throw 'Helper stdout crossed the fixed one-MiB capture bound.'
    }
    if ($helperStartAttemptCount -ne 1L -or $helperStartCount -ne 1L -or
        $helperReleaseCount -ne 1L -or $helperGateSignalCount -ne 1L -or
        -not $jobAssignmentCompleted -or $automaticRetryCount -ne 0L) {
        throw 'Helper start/release/retry cardinality drifted.'
    }

    $launcherPhase = 'summary_verification'
    if (-not (Microsoft.PowerShell.Management\Test-Path `
            -LiteralPath $summaryPath -PathType Leaf)) {
        throw "Helper did not publish the exact summary leaf (exit=$helperExitCode; stderr_bytes=$([long]$stderrResult.TotalByteLength); stderr_sha256=$([string]$stderrResult.Sha256))."
    }
    $summaryBinding = Open-LauncherHeldExactFile `
        -Role 'summary' -Path $summaryPath -ExpectedSha256 $null `
        -DirectoryBindings $directoryBindings -DirectoryOrder $directoryOrder
    $fileBindings.Add($summaryBinding)
    $summaryBytes = Read-LauncherHeldFileBytes `
        -Binding $summaryBinding -MinimumLength 1L `
        -MaximumLength 65536L
    $expectedStdoutBytes = [byte[]]::new($summaryBytes.Length + 2)
    [Buffer]::BlockCopy($summaryBytes, 0, $expectedStdoutBytes, 0, $summaryBytes.Length)
    $expectedStdoutBytes[$expectedStdoutBytes.Length - 2] = 13
    $expectedStdoutBytes[$expectedStdoutBytes.Length - 1] = 10
    if ([long]$stdoutResult.TotalByteLength -ne [long]$expectedStdoutBytes.Length -or
        $stdoutResult.CapturedBytes.Length -ne $expectedStdoutBytes.Length -or
        -not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
            $stdoutResult.CapturedBytes, $expectedStdoutBytes)) {
        throw 'Helper stdout is not exact held summary bytes followed by one CRLF.'
    }
    $expectedStdoutSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($expectedStdoutBytes)).ToLowerInvariant()
    if ([string]$stdoutResult.Sha256 -cne $expectedStdoutSha256) {
        throw 'Helper stdout full-stream SHA-256 does not match the exact summary-plus-CRLF bytes.'
    }
    $stdoutExactSummaryPlusCrLf = $true

    if ($summaryBytes.Length -ge 3 -and $summaryBytes[0] -eq 0xEF -and
        $summaryBytes[1] -eq 0xBB -and $summaryBytes[2] -eq 0xBF) {
        throw 'Helper summary must not contain a UTF-8 BOM.'
    }
    $summaryRaw = [Text.UTF8Encoding]::new($false, $true).GetString($summaryBytes)

    foreach ($binding in $fileBindings) {
        Assert-LauncherHeldFileBinding -Binding $binding
    }
    foreach ($binding in $directoryOrder) {
        Assert-LauncherHeldDirectoryBinding -Binding $binding
    }
    Assert-LauncherCapturedVerifierBindings `
        -FunctionNames $verifierFunctionNames `
        -CapturedFunctions $capturedVerifierFunctions `
        -CapturedScriptBlocks $capturedVerifierScriptBlocks `
        -ExpectedVerifierPath ([string]$verifierBinding.Path)

    $launcherPhase = 'summary_strict_parse'
    $verifierSummaryParseAttemptCount++
    $summaryParseOutput = @(
        & $capturedVerifierFunctions[
            'ConvertFrom-TL1C1bRealBuildSmokeSummaryJson'
        ] -Raw $summaryRaw 2>&1 3>&1 4>&1 5>&1 6>&1
    )
    if ($summaryParseOutput.Count -ne 1 -or
        $summaryParseOutput[0].GetType() -ne
            [Management.Automation.PSCustomObject]) {
        throw 'Captured strict summary parser did not return one exact PSCustomObject.'
    }
    $summaryValue = $summaryParseOutput[0]
    $summaryPropertyAssertionOutput = @(
        & $capturedVerifierFunctions[
            'Assert-TL1C1bRealBuildSmokeSummaryExactProperties'
        ] -Value $summaryValue 2>&1 3>&1 4>&1 5>&1 6>&1
    )
    if ($summaryPropertyAssertionOutput.Count -ne 0) {
        throw 'Captured exact-property assertion was not silent.'
    }
    $verifierSummaryParseCount++
    if ($summaryValue.status -isnot [string]) {
        throw 'Helper summary status is not a string.'
    }
    $summaryStatus = [string]$summaryValue.status

    Assert-LauncherCapturedVerifierBindings `
        -FunctionNames $verifierFunctionNames `
        -CapturedFunctions $capturedVerifierFunctions `
        -CapturedScriptBlocks $capturedVerifierScriptBlocks `
        -ExpectedVerifierPath ([string]$verifierBinding.Path)
    foreach ($binding in $fileBindings) {
        Assert-LauncherHeldFileBinding -Binding $binding
    }
    foreach ($binding in $directoryOrder) {
        Assert-LauncherHeldDirectoryBinding -Binding $binding
    }

    if ($summaryStatus -ceq 'failed') {
        $launcherPhase = 'failure_summary_verification'
        $failureSummaryOutput = @(
            Assert-LauncherFailureSummaryValue `
                -Value $summaryValue `
                -ExpectedCommitSha $expectedCommitSha `
                -ExpectedHelperSha256 $expectedHelperSha256 `
                -HelperProcessStartedNotBeforeUtc $helperProcessStartedNotBeforeUtc `
                -HelperProcessExitedNotAfterUtc $helperProcessExitedNotAfterUtc
        )
        if ($failureSummaryOutput.Count -ne 1) {
            throw 'Failure summary validator did not return exactly one value.'
        }
        Assert-LauncherExactPSCustomObject `
            -Value $failureSummaryOutput[0] `
            -ExpectedProperties ([string[]]@('FailureCount','Reasons'))
        if ($failureSummaryOutput[0].FailureCount -isnot [long] -or
            $failureSummaryOutput[0].Reasons -isnot [Array] -or
            [long]$failureSummaryOutput[0].FailureCount -ne
                @($failureSummaryOutput[0].Reasons).Count) {
            throw 'Failure summary validator result binding is not exact.'
        }
        $helperFailureReasons = [string[]]@($failureSummaryOutput[0].Reasons)
        $helperFailureSummaryVerified = $true

        Assert-LauncherCapturedVerifierBindings `
            -FunctionNames $verifierFunctionNames `
            -CapturedFunctions $capturedVerifierFunctions `
            -CapturedScriptBlocks $capturedVerifierScriptBlocks `
            -ExpectedVerifierPath ([string]$verifierBinding.Path)
        foreach ($binding in $fileBindings) {
            Assert-LauncherHeldFileBinding -Binding $binding
        }
        foreach ($binding in $directoryOrder) {
            Assert-LauncherHeldDirectoryBinding -Binding $binding
        }

        $displayReasons = [Collections.Generic.List[string]]::new()
        foreach ($reason in $helperFailureReasons) {
            $displayReasons.Add(
                [Text.RegularExpressions.Regex]::Replace(
                    [string]$reason, '[\p{Cc}\p{Cf}]', ' '))
        }
        $boundedReasonText = Get-LauncherBoundedFailureText `
            -Value ([string[]]$displayReasons.ToArray() -join ' | ') `
            -MaximumLength 4096
        $launcherPhase = 'helper_reported_failure'
        throw "The exact held helper summary reported failure (exit=$helperExitCode; stderr_bytes=$([long]$stderrResult.TotalByteLength); stderr_sha256=$([string]$stderrResult.Sha256); stderr_overflowed=$([bool]$stderrResult.Overflowed)): $boundedReasonText"
    }
    if ($summaryStatus -cne 'passed') {
        throw 'Helper summary status is neither exact passed nor exact failed.'
    }
    if ($helperExitCode -ne 0) {
        throw "The one-shot helper exited nonzero ($helperExitCode) with a passed summary; automatic retry is forbidden."
    }
    if ($stderrResult.Overflowed -or
        [long]$stderrResult.TotalByteLength -ne 0L -or
        $stderrResult.CapturedBytes.Length -ne 0) {
        throw 'Helper stderr was not byte-empty for a passed summary.'
    }

    $launcherPhase = 'verifier_invoke'
    $verifierInvokeAttemptCount++
    $verifierOutput = @(
        & $capturedVerifierFunction `
            -Path $summaryPath `
            -ExpectedParentDirectory $outputRoot `
            -ExpectedCommitSha $expectedCommitSha `
            -ExpectedHelperSha256 $expectedHelperSha256 `
            -HelperProcessStartedNotBeforeUtc $helperProcessStartedNotBeforeUtc `
            -HelperProcessExitedNotAfterUtc $helperProcessExitedNotAfterUtc `
            -MaximumObserverTailSeconds $maximumObserverTailSeconds `
            2>&1 3>&1 4>&1 5>&1 6>&1
    )
    $verifierInvokeCount++
    if ($verifierOutput.Count -ne 1) {
        throw 'Captured verifier did not return exactly one value.'
    }
    $verifierResult = $verifierOutput[0]
    Assert-LauncherExactPSCustomObject -Value $verifierResult `
        -ExpectedProperties ([string[]]@('ByteLength','Sha256'))
    if ($verifierResult.ByteLength -isnot [long] -or
        $verifierResult.Sha256 -isnot [string] -or
        [long]$verifierResult.ByteLength -ne [long]$summaryBinding.ByteLength -or
        [string]$verifierResult.Sha256 -cne
            ('sha256:' + [string]$summaryBinding.ActualSha256)) {
        throw 'Captured verifier result did not exact-match the held summary bytes.'
    }
    $helperSummaryVerified = $true

    Assert-LauncherCapturedVerifierBindings `
        -FunctionNames $verifierFunctionNames `
        -CapturedFunctions $capturedVerifierFunctions `
        -CapturedScriptBlocks $capturedVerifierScriptBlocks `
        -ExpectedVerifierPath ([string]$verifierBinding.Path)
    foreach ($binding in $fileBindings) {
        Assert-LauncherHeldFileBinding -Binding $binding
    }
    foreach ($binding in $directoryOrder) {
        Assert-LauncherHeldDirectoryBinding -Binding $binding
    }
    if ($verifierLoadAttemptCount -ne 1L -or $verifierLoadCount -ne 1L -or
        $verifierSummaryParseAttemptCount -ne 1L -or
        $verifierSummaryParseCount -ne 1L -or
        $verifierInvokeAttemptCount -ne 1L -or $verifierInvokeCount -ne 1L -or
        -not $helperSummaryVerified) {
        throw 'Verifier load/invoke/accept cardinality drifted.'
    }
}
catch {
    Capture-LauncherPrimaryFailure `
        -ErrorRecord $_ -Exception $null -Phase ([string]$launcherPhase)
    $failure = Merge-LauncherFailure -Existing $failure `
        -Additional $_.Exception `
        -Message 'C1b build-only launcher execution failed.'
}
finally {
    if ($null -ne $process -and $helperStartCount -eq 1L -and
        (-not $helperRootExitConfirmed -or -not $helperJobEmptyConfirmed)) {
        try {
            $helperKillAttemptCount++
            $helperJobTerminationAttemptCount++
            $termination = Stop-LauncherHelperJobBounded `
                -Process $process -Job $helperJob `
                -WaitMilliseconds $helperKillWaitMilliseconds
            $helperKillSucceeded = [bool](
                $helperKillSucceeded -or $termination.KillTreeRequested)
            $helperJobTerminationSucceeded = [bool](
                $helperJobTerminationSucceeded -or $termination.JobTerminationRequested)
            $helperRootExitConfirmed = [bool]$termination.RootExitConfirmed
            $helperJobEmptyConfirmed = [bool]$termination.JobEmptyConfirmed
            foreach ($terminationFailure in $termination.Failures) {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $null -Exception $terminationFailure `
                    -Phase 'helper_termination_cleanup'
                $cleanupFailures.Add($terminationFailure)
            }
            if ($helperRootExitConfirmed -and
                $null -eq $helperProcessExitedNotAfterUtc) {
                $helperProcessExitedNotAfterUtc = [DateTimeOffset]::UtcNow
            }
            if ($helperTermination -ceq 'not_started') {
                $helperTermination = 'failure_job_terminated'
            }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_termination_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($helperStartCount -eq 1L -and
        $helperDrainWaitAttemptCount -eq 0L -and
        $null -ne $stdoutDrainTask -and $null -ne $stderrDrainTask -and
        $helperRootExitConfirmed) {
        try {
            $helperDrainWaitAttemptCount++
            $drains = Wait-LauncherDrainsBounded `
                -StdoutTask $stdoutDrainTask -StderrTask $stderrDrainTask `
                -WaitMilliseconds $helperDrainWaitMilliseconds
            $stdoutResult = $drains.Stdout
            $stderrResult = $drains.Stderr
            $helperDrainCompleted = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_stream_drain_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($null -ne $processGate) {
        try {
            $processGate.Dispose()
            $helperGateDisposed = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null -Phase 'helper_gate_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($null -ne $helperJob) {
        try {
            $helperJobCleanupActiveProcessCount = [long](
                [TL1C1bNextLauncherNativeV1]::GetActiveProcessCount($helperJob))
            if ($helperJobCleanupActiveProcessCount -ne 0L) {
                throw 'Helper Job Object was nonempty at cleanup.'
            }
            $helperChildTerminationCleanupVerified = [bool](
                $helperRootExitConfirmed -and
                $helperJobCleanupActiveProcessCount -eq 0L)
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_job_state_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
        try {
            $helperJob.Dispose()
            $helperJobDisposed = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_job_dispose_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($null -ne $process -and -not $helperDrainCompleted) {
        try {
            $process.StandardOutput.BaseStream.Dispose()
            $stdoutForcedClosed = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_stdout_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
        try {
            $process.StandardError.BaseStream.Dispose()
            $stderrForcedClosed = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_stderr_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if ($null -ne $process) {
        try {
            if ($helperStartCount -eq 1L -and -not $process.HasExited) {
                throw 'Helper process was still alive at cleanup.'
            }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_process_state_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
        try {
            $process.Dispose()
            $helperProcessDisposed = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'helper_process_dispose_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    if (($null -eq $process -or $helperProcessDisposed) -and
        ($null -eq $helperJob -or $helperJobDisposed) -and
        ($null -eq $processGate -or $helperGateDisposed) -and
        ($helperStartCount -eq 0L -or
         ($helperRootExitConfirmed -and
          $helperJobCleanupActiveProcessCount -eq 0L -and
          $helperChildTerminationCleanupVerified))) {
        $processCleanup = 'completed'
    }

    if ($outputTargetsAbsent -and -not $logPreexisting) {
        try {
            $logValue = [pscustomobject][ordered]@{
                schema = 'tablet-layout-c1b-real-build-smoke-launcher-log/v2'
                expected_commit_sha = $expectedCommitSha
                bindings = [pscustomobject][ordered]@{
                    self_expected_sha256 = 'sha256:' + $ExpectedLauncherSha256
                    self_actual_sha256 = if ($null -eq $launcherBinding) { $null } else {
                        'sha256:' + [string]$launcherBinding.ActualSha256
                    }
                    helper_expected_sha256 = 'sha256:' + $expectedHelperSha256
                    helper_actual_sha256 = if ($null -eq $helperBinding) { $null } else {
                        'sha256:' + [string]$helperBinding.ActualSha256
                    }
                    verifier_expected_sha256 = 'sha256:' + $expectedVerifierSha256
                    verifier_actual_sha256 = if ($null -eq $verifierBinding) { $null } else {
                        'sha256:' + [string]$verifierBinding.ActualSha256
                    }
                    pwsh_expected_sha256 = 'sha256:' + $expectedPwshSha256
                    pwsh_actual_sha256 = if ($null -eq $pwshBinding) { $null } else {
                        'sha256:' + [string]$pwshBinding.ActualSha256
                    }
                }
                verifier = [pscustomobject][ordered]@{
                    load_attempt_count = [long]$verifierLoadAttemptCount
                    load_count = [long]$verifierLoadCount
                    summary_parse_attempt_count =
                        [long]$verifierSummaryParseAttemptCount
                    summary_parse_count = [long]$verifierSummaryParseCount
                    invoke_attempt_count = [long]$verifierInvokeAttemptCount
                    invoke_count = [long]$verifierInvokeCount
                    accepted = [bool]$helperSummaryVerified
                    summary_status = $summaryStatus
                    failure_summary_accepted =
                        [bool]$helperFailureSummaryVerified
                    failure_count = [long]$helperFailureReasons.Count
                    failure_reasons = [string[]]$helperFailureReasons
                }
                helper = [pscustomobject][ordered]@{
                    start_attempt_count = [long]$helperStartAttemptCount
                    start_count = [long]$helperStartCount
                    release_count = [long]$helperReleaseCount
                    helper_gate_signal_count = [long]$helperGateSignalCount
                    job_assignment_completed = [bool]$jobAssignmentCompleted
                    automatic_retry_count = [long]$automaticRetryCount
                    exit_code = $helperExitCode
                    deadline_milliseconds = [long]$helperDeadlineMilliseconds
                    kill_wait_milliseconds = [long]$helperKillWaitMilliseconds
                    drain_wait_milliseconds = [long]$helperDrainWaitMilliseconds
                    timed_out = [bool]$helperTimedOut
                    termination = [string]$helperTermination
                    root_exit_confirmed = [bool]$helperRootExitConfirmed
                    job_empty_confirmed = [bool]$helperJobEmptyConfirmed
                    job_validation_active_process_count =
                        $helperJobValidationActiveProcessCount
                    job_cleanup_active_process_count =
                        $helperJobCleanupActiveProcessCount
                    child_termination_validation_verified =
                        [bool]$helperChildTerminationValidationVerified
                    child_termination_cleanup_verified =
                        [bool]$helperChildTerminationCleanupVerified
                    process_started_not_before_utc = if ($null -eq $helperProcessStartedNotBeforeUtc) {
                        $null
                    } else { $helperProcessStartedNotBeforeUtc.UtcDateTime.ToString(
                        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                        [Globalization.CultureInfo]::InvariantCulture) }
                    process_exited_not_after_utc = if ($null -eq $helperProcessExitedNotAfterUtc) {
                        $null
                    } else { $helperProcessExitedNotAfterUtc.UtcDateTime.ToString(
                        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
                        [Globalization.CultureInfo]::InvariantCulture) }
                }
                stdout = if ($null -eq $stdoutResult) { $null } else {
                    [pscustomobject][ordered]@{
                        total_byte_length = [long]$stdoutResult.TotalByteLength
                        captured_byte_length = [long]$stdoutResult.CapturedBytes.Length
                        sha256 = 'sha256:' + [string]$stdoutResult.Sha256
                        overflowed = [bool]$stdoutResult.Overflowed
                        forced_closed = [bool]$stdoutForcedClosed
                    }
                }
                stderr = if ($null -eq $stderrResult) { $null } else {
                    [pscustomobject][ordered]@{
                        total_byte_length = [long]$stderrResult.TotalByteLength
                        captured_byte_length = [long]$stderrResult.CapturedBytes.Length
                        captured_prefix_base64 = [Convert]::ToBase64String($stderrResult.CapturedBytes)
                        captured_prefix_sha256 = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrResult.CapturedBytes)).ToLowerInvariant()
                        captured_prefix_byte_length = [long]$stderrResult.CapturedBytes.Length
                        capture_is_prefix = $true
                        uncaptured_byte_length = [long]$stderrResult.TotalByteLength - [long]$stderrResult.CapturedBytes.Length
                        sha256 = 'sha256:' + [string]$stderrResult.Sha256
                        overflowed = [bool]$stderrResult.Overflowed
                        forced_closed = [bool]$stderrForcedClosed
                    }
                }
                summary = if ($null -eq $summaryBinding) { $null } else {
                    [pscustomobject][ordered]@{
                        byte_length = [long]$summaryBinding.ByteLength
                        sha256 = 'sha256:' + [string]$summaryBinding.ActualSha256
                        stdout_exact_summary_plus_crlf = [bool]$stdoutExactSummaryPlusCrLf
                    }
                }
            }
            $logBinding = Write-LauncherAtomicNewUtf8Json `
                -Path $logPath -Value $logValue `
                -FailurePhase 'log_publication'
            $logPublished = $true
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null -Phase 'log_publication'
            $failure = Merge-LauncherFailure -Existing $failure `
                -Additional $_.Exception `
                -Message 'Launcher execution and log publication both failed.'
        }
    }

    $bufferCleanupBefore = $cleanupFailures.Count
    foreach ($buffer in @(
            $summaryBytes, $expectedStdoutBytes,
            $(if ($null -eq $stdoutResult) { $null } else { ,$stdoutResult.CapturedBytes }),
            $(if ($null -eq $stderrResult) { $null } else { ,$stderrResult.CapturedBytes }))) {
        if ($null -ne $buffer -and $buffer.Length -ne 0) {
            try { [Array]::Clear($buffer, 0, $buffer.Length) }
            catch {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $_ -Exception $null `
                    -Phase 'sensitive_buffer_cleanup'
                $cleanupFailures.Add($_.Exception)
            }
        }
    }
    $sensitiveBuffersCleanup = if ($cleanupFailures.Count -eq $bufferCleanupBefore) {
        'completed'
    } else { 'failed' }

    $fileCleanupBefore = $cleanupFailures.Count
    for ($index = $fileBindings.Count - 1; $index -ge 0; $index--) {
        try {
            $guard = $fileBindings[$index].Guard
            $safeHandle = $guard.SafeFileHandle
            $guard.Dispose()
            if (-not $safeHandle.IsClosed) {
                throw "Held file guard did not close: $($fileBindings[$index].Role)"
            }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'fixed_file_guard_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    $fixedFileGuardsCleanup = if ($cleanupFailures.Count -eq $fileCleanupBefore) {
        'completed'
    } else { 'failed' }

    $directoryCleanupBefore = $cleanupFailures.Count
    for ($index = $directoryOrder.Count - 1; $index -ge 0; $index--) {
        try {
            $directoryOrder[$index].Handle.Dispose()
            if (-not $directoryOrder[$index].Handle.IsClosed) {
                throw "Held directory guard did not close: $($directoryOrder[$index].Path)"
            }
        }
        catch {
            Capture-LauncherPrimaryFailure `
                -ErrorRecord $_ -Exception $null `
                -Phase 'directory_guard_cleanup'
            $cleanupFailures.Add($_.Exception)
        }
    }
    $directoryGuardsCleanup = if ($cleanupFailures.Count -eq $directoryCleanupBefore) {
        'completed'
    } else { 'failed' }

    foreach ($cleanupFailure in $cleanupFailures) {
        $failure = Merge-LauncherFailure -Existing $failure `
            -Additional $cleanupFailure `
            -Message 'Launcher execution and bounded cleanup both failed.'
    }
}

$launcherPhase = 'pass_closure'
$completedAtUtc = [DateTimeOffset]::UtcNow
$passClosure = (
    $null -eq $failure -and
    $outputTargetsAbsent -and
    $runtimePwshReopenMatchesHeld -and
    $childPwshQueryImagePathMatchesHeld -and
    $verifierLoadAttemptCount -eq 1L -and $verifierLoadCount -eq 1L -and
    $verifierSummaryParseAttemptCount -eq 1L -and
    $verifierSummaryParseCount -eq 1L -and
    $verifierInvokeAttemptCount -eq 1L -and $verifierInvokeCount -eq 1L -and
    $helperStartAttemptCount -eq 1L -and $helperStartCount -eq 1L -and
    $helperReleaseCount -eq 1L -and $automaticRetryCount -eq 0L -and
    $helperGateSignalCount -eq 1L -and $jobAssignmentCompleted -and
    -not $helperTimedOut -and $helperExitCode -eq 0 -and
    $helperRootExitConfirmed -and $helperJobEmptyConfirmed -and
    $helperChildTerminationValidationVerified -and
    $helperChildTerminationCleanupVerified -and
    $helperDrainCompleted -and $helperSummaryVerified -and
    -not $helperFailureSummaryVerified -and
    $helperFailureReasons.Count -eq 0 -and
    $summaryStatus -ceq 'passed' -and
    $stdoutExactSummaryPlusCrLf -and
    $processCleanup -ceq 'completed' -and
    $fixedFileGuardsCleanup -ceq 'completed' -and
    $directoryGuardsCleanup -ceq 'completed' -and
    $sensitiveBuffersCleanup -ceq 'completed' -and
    $logPublished)
if (-not $passClosure -and $null -eq $failure) {
    $failure = [InvalidOperationException]::new(
        'Launcher pass closure was incomplete after bounded cleanup.')
    Capture-LauncherPrimaryFailure `
        -ErrorRecord $null -Exception $failure -Phase 'pass_closure'
}

$bindingResult = [ordered]@{}
foreach ($name in @('self','helper','verifier','pwsh')) {
    $binding = switch ($name) {
        'self' { $launcherBinding }
        'helper' { $helperBinding }
        'verifier' { $verifierBinding }
        'pwsh' { $pwshBinding }
    }
    $expected = switch ($name) {
        'self' { $ExpectedLauncherSha256 }
        'helper' { $expectedHelperSha256 }
        'verifier' { $expectedVerifierSha256 }
        'pwsh' { $expectedPwshSha256 }
    }
    $bindingResult[$name] = [pscustomobject][ordered]@{
        expected_sha256 = 'sha256:' + $expected
        actual_sha256 = if ($null -eq $binding) { $null } else {
            'sha256:' + [string]$binding.ActualSha256
        }
        path = if ($null -eq $binding) { $null } else { [string]$binding.Path }
        stable_id = if ($null -eq $binding) { $null } else {
            [string]$binding.Identity.StableId
        }
        link_count = if ($null -eq $binding) { $null } else {
            [long]$binding.Identity.LinkCount
        }
        byte_length = if ($null -eq $binding) { $null } else {
            [long]$binding.ByteLength
        }
    }
}

$failureMessages = [string[]]@()
if ($null -ne $failure) {
    $message = [string]$failure.Message
    if ($message.Length -gt 4096) { $message = $message.Substring(0, 4096) }
    $failureMessages = [string[]]@($message)
}
$resultValue = [pscustomobject][ordered]@{
    schema = 'tablet-layout-c1b-real-build-smoke-launcher/v3'
    started_at_utc = $startedAtUtc.UtcDateTime.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    completed_at_utc = $completedAtUtc.UtcDateTime.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    status = if ($null -eq $failure) {
        'candidate_pass_requires_external_exit'
    } else { 'failed' }
    success_eligible_without_external_exit = $false
    external_exit_zero_required = $true
    failure_sidecar_absent_after_exit_required = $true
    pre_publication_pass_closure = [bool]$passClosure
    final_status_authority =
        'external_exit_zero_and_failure_sidecar_absent_after_process_exit'
    expected_commit_sha = $expectedCommitSha
    bindings = [pscustomobject]$bindingResult
    runtime_pwsh = [pscustomobject][ordered]@{
        expected_version = '7.6.5'
        actual_version = $PSVersionTable.PSVersion.ToString()
        query_image_path_matches_held_path = [bool]$runtimePwshReopenMatchesHeld
        queried_path_reopen_matches_held_file = [bool]$runtimePwshReopenMatchesHeld
        child_query_image_path_matches_held_path = [bool]$childPwshQueryImagePathMatchesHeld
    }
    filesystem = [pscustomobject][ordered]@{
        ntfs_only = [bool]$outputChainHeld
        held_ancestor_directory_count = [long]$directoryOrder.Count
        repo_root = $repoRoot
        output_root = $outputRoot
    }
    verifier = [pscustomobject][ordered]@{
        fixed_repo_relative_path = $verifierRelativePath
        load_attempt_count = [long]$verifierLoadAttemptCount
        load_count = [long]$verifierLoadCount
        summary_parse_attempt_count =
            [long]$verifierSummaryParseAttemptCount
        summary_parse_count = [long]$verifierSummaryParseCount
        invoke_attempt_count = [long]$verifierInvokeAttemptCount
        invoke_count = [long]$verifierInvokeCount
        captured_function_name = if ($null -eq $capturedVerifierFunction) {
            $null
        } else { [string]$capturedVerifierFunction.Name }
        accepted = [bool]$helperSummaryVerified
        summary_status = $summaryStatus
        failure_summary_accepted = [bool]$helperFailureSummaryVerified
        failure_count = [long]$helperFailureReasons.Count
        failure_reasons = [string[]]$helperFailureReasons
    }
    helper = [pscustomobject][ordered]@{
        process_id = $helperProcessId
        start_attempt_count = [long]$helperStartAttemptCount
        start_count = [long]$helperStartCount
        release_after_job_assignment_count = [long]$helperReleaseCount
        helper_gate_signal_count = [long]$helperGateSignalCount
        job_assignment_completed = [bool]$jobAssignmentCompleted
        automatic_retry_count = [long]$automaticRetryCount
        exit_code = $helperExitCode
        deadline_milliseconds = [long]$helperDeadlineMilliseconds
        kill_wait_milliseconds = [long]$helperKillWaitMilliseconds
        drain_wait_milliseconds = [long]$helperDrainWaitMilliseconds
        timed_out = [bool]$helperTimedOut
        kill_attempt_count = [long]$helperKillAttemptCount
        kill_request_succeeded = [bool]$helperKillSucceeded
        job_termination_attempt_count = [long]$helperJobTerminationAttemptCount
        job_termination_request_succeeded = [bool]$helperJobTerminationSucceeded
        root_exit_confirmed = [bool]$helperRootExitConfirmed
        job_active_processes_zero = [bool]$helperJobEmptyConfirmed
        job_validation_active_process_count =
            $helperJobValidationActiveProcessCount
        job_cleanup_active_process_count =
            $helperJobCleanupActiveProcessCount
        helper_child_termination_validation_verified =
            [bool]$helperChildTerminationValidationVerified
        helper_child_termination_cleanup_verified =
            [bool]$helperChildTerminationCleanupVerified
        termination = [string]$helperTermination
        process_started_not_before_utc = if ($null -eq $helperProcessStartedNotBeforeUtc) {
            $null
        } else { $helperProcessStartedNotBeforeUtc.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
        process_exited_not_after_utc = if ($null -eq $helperProcessExitedNotAfterUtc) {
            $null
        } else { $helperProcessExitedNotAfterUtc.UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    }
    streams = [pscustomobject][ordered]@{
        capture_cap_bytes_per_stream = [long]$captureCapBytes
        drain_completed = [bool]$helperDrainCompleted
        stdout = if ($null -eq $stdoutResult) { $null } else {
            [pscustomobject][ordered]@{
                total_byte_length = [long]$stdoutResult.TotalByteLength
                captured_byte_length = [long]$stdoutResult.CapturedBytes.Length
                sha256 = 'sha256:' + [string]$stdoutResult.Sha256
                overflowed = [bool]$stdoutResult.Overflowed
                forced_closed = [bool]$stdoutForcedClosed
            }
        }
        stderr = if ($null -eq $stderrResult) { $null } else {
            [pscustomobject][ordered]@{
                total_byte_length = [long]$stderrResult.TotalByteLength
                captured_byte_length = [long]$stderrResult.CapturedBytes.Length
                sha256 = 'sha256:' + [string]$stderrResult.Sha256
                overflowed = [bool]$stderrResult.Overflowed
                forced_closed = [bool]$stderrForcedClosed
            }
        }
    }
    outputs = [pscustomobject][ordered]@{
        summary = [pscustomobject][ordered]@{
            path = $summaryPath
            preexisting = $summaryPreexisting
            create_new_and_stdout_bound = [bool]$stdoutExactSummaryPlusCrLf
            byte_length = if ($null -eq $summaryBinding) { $null } else {
                [long]$summaryBinding.ByteLength
            }
            sha256 = if ($null -eq $summaryBinding) { $null } else {
                'sha256:' + [string]$summaryBinding.ActualSha256
            }
        }
        log = [pscustomobject][ordered]@{
            path = $logPath
            preexisting = $logPreexisting
            atomic_no_overwrite_published = [bool]$logPublished
            byte_length = if ($null -eq $logBinding) { $null } else {
                [long]$logBinding.ByteLength
            }
            sha256 = if ($null -eq $logBinding) { $null } else {
                [string]$logBinding.Sha256
            }
        }
        result = [pscustomobject][ordered]@{
            path = $launcherResultPath
            preexisting = $resultPreexisting
            atomic_no_overwrite_requested = $true
        }
    }
    cleanup = [pscustomobject][ordered]@{
        process_job_gate = $processCleanup
        fixed_file_guards = $fixedFileGuardsCleanup
        ancestor_directory_guards = $directoryGuardsCleanup
        sensitive_buffers = $sensitiveBuffersCleanup
        cleanup_failure_count = [long]$cleanupFailures.Count
    }
    residual = [pscustomobject][ordered]@{
        helper_root_process_alive = [bool](-not $helperRootExitConfirmed -and $helperStartCount -eq 1L)
        helper_job_active_processes_nonzero = [bool](-not $helperJobEmptyConfirmed -and $helperStartCount -eq 1L)
        expected_summary_present = [bool](
            Microsoft.PowerShell.Management\Test-Path -LiteralPath $summaryPath -PathType Leaf)
        expected_log_present = [bool](
            Microsoft.PowerShell.Management\Test-Path -LiteralPath $logPath -PathType Leaf)
    }
    failure_count = [long]$failureMessages.Count
    failure_reasons = $failureMessages
}

$launcherPhase = 'result_publication'
if ($outputTargetsAbsent -and -not $resultPreexisting) {
    $publishDirectoryBindings = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $publishDirectoryOrder = [Collections.Generic.List[object]]::new()
    $publishFileBindings = [Collections.Generic.List[object]]::new()
    try {
        Add-LauncherHeldDirectoryChain -Path $outputRoot `
            -Bindings $publishDirectoryBindings -Order $publishDirectoryOrder
        foreach ($binding in $publishDirectoryOrder) {
            Assert-LauncherHeldDirectoryBinding -Binding $binding
            if (-not $directoryBindings.ContainsKey([string]$binding.Path) -or
                -not [StringComparer]::Ordinal.Equals(
                    [string]$binding.Identity.StableId,
                    [string]$directoryBindings[[string]$binding.Path].Identity.StableId)) {
                throw "Result-publication ancestor identity does not match the original held chain: $($binding.Path)"
            }
        }
        if ($null -eq $failure) {
            if ($null -eq $summaryBinding -or $null -eq $logBinding) {
                throw 'Candidate-pass result publication lacks original summary or log binding.'
            }
            $publishSummaryBinding = Open-LauncherHeldExactFile `
                -Role 'result-publication-summary' -Path $summaryPath `
                -ExpectedSha256 ([string]$summaryBinding.ActualSha256) `
                -DirectoryBindings $publishDirectoryBindings `
                -DirectoryOrder $publishDirectoryOrder
            $publishFileBindings.Add($publishSummaryBinding)
            if (-not [StringComparer]::Ordinal.Equals(
                    [string]$publishSummaryBinding.Identity.StableId,
                    [string]$summaryBinding.Identity.StableId) -or
                [long]$publishSummaryBinding.ByteLength -ne [long]$summaryBinding.ByteLength -or
                [long]$publishSummaryBinding.Identity.LastWriteTimeUtcFileTime -ne
                    [long]$summaryBinding.Identity.LastWriteTimeUtcFileTime) {
                throw 'Result-publication summary identity does not match the verified held summary.'
            }
            $publishLogBinding = Open-LauncherHeldExactFile `
                -Role 'result-publication-log' -Path $logPath `
                -ExpectedSha256 ([string]$logBinding.ActualSha256) `
                -DirectoryBindings $publishDirectoryBindings `
                -DirectoryOrder $publishDirectoryOrder
            $publishFileBindings.Add($publishLogBinding)
            if (-not [StringComparer]::Ordinal.Equals(
                    [string]$publishLogBinding.Identity.StableId,
                    [string]$logBinding.Identity.StableId) -or
                [long]$publishLogBinding.ByteLength -ne [long]$logBinding.ByteLength -or
                [long]$publishLogBinding.Identity.LastWriteTimeUtcFileTime -ne
                    [long]$logBinding.Identity.LastWriteTimeUtcFileTime) {
                throw 'Result-publication log identity does not match the atomically published log.'
            }
        }
        $resultBinding = Write-LauncherAtomicNewUtf8Json `
            -Path $launcherResultPath -Value $resultValue `
            -FailurePhase 'result_publication'
        $resultPublished = $true
    }
    catch {
        Capture-LauncherPrimaryFailure `
            -ErrorRecord $_ -Exception $null -Phase 'result_publication'
        $failure = Merge-LauncherFailure -Existing $failure `
            -Additional $_.Exception `
            -Message 'Launcher result publication failed.'
    }
    finally {
        for ($index = $publishFileBindings.Count - 1; $index -ge 0; $index--) {
            try { $publishFileBindings[$index].Guard.Dispose() }
            catch {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $_ -Exception $null `
                    -Phase 'result_publication_file_guard_cleanup'
                $failure = Merge-LauncherFailure -Existing $failure `
                    -Additional $_.Exception `
                    -Message 'Launcher result publication file-guard cleanup failed.'
            }
        }
        for ($index = $publishDirectoryOrder.Count - 1; $index -ge 0; $index--) {
            try { $publishDirectoryOrder[$index].Handle.Dispose() }
            catch {
                Capture-LauncherPrimaryFailure `
                    -ErrorRecord $_ -Exception $null `
                    -Phase 'result_publication_directory_guard_cleanup'
                $failure = Merge-LauncherFailure -Existing $failure `
                    -Additional $_.Exception `
                    -Message 'Launcher result publication guard cleanup failed.'
            }
        }
    }
}
if (-not $resultPublished -and $null -eq $failure) {
    $failure = [InvalidOperationException]::new(
        'Launcher result was not atomically published.')
    Capture-LauncherPrimaryFailure `
        -ErrorRecord $null -Exception $failure -Phase 'result_publication'
}

if ($null -ne $failure) {
    Exit-LauncherFailed `
        -PrimaryErrorRecord $primaryFailureErrorRecord `
        -PrimaryException $failure
}
exit 0
