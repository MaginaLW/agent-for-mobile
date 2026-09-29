#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
Microsoft.PowerShell.Core\Set-StrictMode -Version 3.0

$stagingRoot = '__BINDING__'
$repoRoot = '__BINDING__'
$commitSha = '__BINDING__'
$commitShort = '__BINDING__'
$helperTemplatePath = [IO.Path]::Combine($repoRoot, 'scripts/lib/c1b-candidate-source/helper-template.ps1')
$launcherTemplatePath = [IO.Path]::Combine($repoRoot, 'scripts/lib/c1b-candidate-source/launcher-template.ps1')
$helperPath = '__BINDING__'
$launcherPath = '__BINDING__'
$helperTemporaryPath = '__BINDING__'
$launcherTemporaryPath = '__BINDING__'
$failureSidecarPath = '__BINDING__'
$outputRoot = [IO.Path]::Combine($repoRoot, '.checks')
$summaryPath = '__BINDING__'
$logPath = '__BINDING__'
$launcherResultPath = '__BINDING__'
$verifierPath = [IO.Path]::Combine(
    $repoRoot, 'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1')
$pwshPath = '__BINDING__'
$utilityAssemblyPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($pwshPath), 'Microsoft.PowerShell.Commands.Utility.dll')

$expectedHelperTemplateSha256 =
    '__BINDING__'
$expectedLauncherTemplateSha256 =
    '__BINDING__'
$expectedVerifierSha256 =
    '__BINDING__'
$expectedPwshSha256 =
    '__BINDING__'
$expectedUtilityAssemblySha256 =
    '__BINDING__'
$expectedUtilityAssemblyLength = 0L
$expectedPwshVersion = '__BINDING__'
$expectedHelperSha256 =
    '__BINDING__'
$expectedLauncherSha256 =
    '__BINDING__'
$expectedHelperLength = 0L
$expectedLauncherLength = 0L

function Assert-Renderer {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Complete-RendererLocalFailure {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowNull()][Management.Automation.ErrorRecord]$Primary,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Exception[]]$Cleanup
    )
    if ($Cleanup.Count -ne 0) {
        $all = [Collections.Generic.List[System.Exception]]::new()
        if ($null -ne $Primary) { $all.Add($Primary.Exception) }
        foreach ($failure in $Cleanup) {
            if ($null -eq $failure) {
                $all.Add([InvalidOperationException]::new(
                    'Renderer cleanup reported a null exception.'))
            }
            else { $all.Add($failure) }
        }
        throw [AggregateException]::new(
            "$Label failed and cleanup did not close cleanly.",
            [System.Exception[]]$all.ToArray())
    }
    if ($null -ne $Primary) { throw $Primary }
}

function Invoke-RendererPinnedCmdlet {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][type]$CmdletType,
        [Parameter(Mandatory)][hashtable]$Parameters
    )
    $instance = $null
    $output = $null
    $primary = $null
    $cleanup = [Collections.Generic.List[System.Exception]]::new()
    try {
        Assert-Renderer (
            $CmdletType.IsSubclassOf([Management.Automation.PSCmdlet])
        ) "Pinned cmdlet type is not a PSCmdlet: $Name"
        $command = [Management.Automation.CmdletInfo]::new($Name, $CmdletType)
        Assert-Renderer ($command.ImplementingType -eq $CmdletType) (
            "Pinned cmdlet implementing type drifted: $Name")
        $instance = [Management.Automation.PowerShell]::Create()
        [void]$instance.AddCommand($command)
        foreach ($key in $Parameters.Keys) {
            [void]$instance.AddParameter(
                [string]$key, $Parameters[$key])
        }
        $output = @($instance.Invoke())
        if ($instance.HadErrors -or $instance.Streams.Error.Count -ne 0) {
            if ($instance.Streams.Error.Count -ne 0) {
                throw $instance.Streams.Error[0]
            }
            throw "Pinned cmdlet reported an unmaterialized error: $Name"
        }
    }
    catch { $primary = $_ }
    if ($null -ne $instance) {
        try { $instance.Dispose() }
        catch { $cleanup.Add($_.Exception) }
    }
    Complete-RendererLocalFailure `
        -Label "pinned cmdlet '$Name'" -Primary $primary `
        -Cleanup ([System.Exception[]]$cleanup.ToArray())
    return $output
}

if (-not [OperatingSystem]::IsWindows()) {
    throw 'Exact-pair renderer only supports Windows.'
}
if ($null -ne ('TL1C1bExactPairRendererFileAuthorityV1' -as [type])) {
    throw 'Exact-pair renderer native authority type is already loaded.'
}

$utilityBootstrapStream = $null
$utilityBootstrapBytes = $null
$utilityBootstrapPrimary = $null
$utilityBootstrapCleanup =
    [Collections.Generic.List[System.Exception]]::new()
try {
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            [Environment]::ProcessPath, $pwshPath)
    ) 'Renderer is not running under the pinned PowerShell executable.'
    Assert-Renderer ($PSVersionTable.PSVersion.ToString() -ceq
        $expectedPwshVersion) 'Renderer PowerShell version drifted.'
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            $PSHOME, [IO.Path]::GetDirectoryName($pwshPath))
    ) 'Renderer PSHOME drifted from the pinned PowerShell directory.'
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            $utilityAssemblyPath,
            [IO.Path]::Combine(
                $PSHOME, 'Microsoft.PowerShell.Commands.Utility.dll'))
    ) 'Pinned Utility assembly path drifted from PSHOME.'
    $utilityBootstrapAttributes =
        [IO.File]::GetAttributes($utilityAssemblyPath)
    Assert-Renderer ((
        $utilityBootstrapAttributes -band
        [IO.FileAttributes]::ReparsePoint) -eq 0) (
        'Pinned Utility assembly is a reparse point.')
    $utilityBootstrapStream = [IO.FileStream]::new(
        $utilityAssemblyPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::Read, 4096, [IO.FileOptions]::SequentialScan)
    Assert-Renderer (
        $utilityBootstrapStream.Length -eq $expectedUtilityAssemblyLength
    ) 'Pinned Utility assembly length drifted.'
    $utilityBootstrapBytes =
        [byte[]]::new([int]$utilityBootstrapStream.Length)
    $utilityBootstrapOffset = 0
    while ($utilityBootstrapOffset -lt $utilityBootstrapBytes.Length) {
        $utilityBootstrapRead = $utilityBootstrapStream.Read(
            $utilityBootstrapBytes, $utilityBootstrapOffset,
            $utilityBootstrapBytes.Length - $utilityBootstrapOffset)
        if ($utilityBootstrapRead -le 0) {
            throw 'Pinned Utility assembly held read ended early.'
        }
        $utilityBootstrapOffset += $utilityBootstrapRead
    }
    Assert-Renderer ($utilityBootstrapStream.ReadByte() -eq -1) (
        'Pinned Utility assembly grew during its held read.')
    $utilityBootstrapSha256 = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData(
            $utilityBootstrapBytes)).ToLowerInvariant()
    Assert-Renderer (
        $utilityBootstrapSha256 -ceq $expectedUtilityAssemblySha256
    ) 'Pinned Utility assembly SHA-256 drifted.'
    $utilityAssembly =
        [Reflection.Assembly]::Load($utilityBootstrapBytes)
    Assert-Renderer (
        $utilityAssembly.GetName().Name -ceq
            'Microsoft.PowerShell.Commands.Utility'
    ) 'Pinned Utility assembly identity drifted.'
    $pinnedAddTypeCmdletType = $utilityAssembly.GetType(
        'Microsoft.PowerShell.Commands.AddTypeCommand', $true, $false)
    $pinnedConvertToJsonCmdletType = $utilityAssembly.GetType(
        'Microsoft.PowerShell.Commands.ConvertToJsonCommand', $true, $false)
}
catch { $utilityBootstrapPrimary = $_ }
if ($null -ne $utilityBootstrapStream) {
    try { $utilityBootstrapStream.Dispose() }
    catch { $utilityBootstrapCleanup.Add($_.Exception) }
}
if ($null -ne $utilityBootstrapBytes -and
    $utilityBootstrapBytes.Length -ne 0) {
    try {
        [Array]::Clear(
            $utilityBootstrapBytes, 0, $utilityBootstrapBytes.Length)
    }
    catch { $utilityBootstrapCleanup.Add($_.Exception) }
}
Complete-RendererLocalFailure `
    -Label 'pinned Utility bootstrap' -Primary $utilityBootstrapPrimary `
    -Cleanup ([System.Exception[]]$utilityBootstrapCleanup.ToArray())

$nativeTypeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bExactPairRendererFileIdentityV1 {
    public uint LinkCount { get; set; }
    public uint FileAttributes { get; set; }
    public ulong FileSize { get; set; }
    public long LastWriteTimeUtcFileTime { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bExactPairRendererFileAuthorityV1 {
    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint DELETE = 0x00010000;
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint FILE_TRAVERSE = 0x00000020;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint CREATE_NEW = 1;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_ATTRIBUTE_READONLY = 0x00000001;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
    private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
    private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    private const int FileBasicInfo = 0;
    private const int FileRenameInformation = 10;
    private const int FileIdInfo = 18;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_BASIC_INFO {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_STATUS_BLOCK {
        public IntPtr Status;
        public UIntPtr Information;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        SetLastError = true, ExactSpelling = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint desiredAccess, uint shareMode,
        IntPtr securityAttributes, uint creationDisposition,
        uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file, int informationClass,
        out FILE_ID_INFO information, uint bufferSize);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        SetLastError = true, ExactSpelling = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file, StringBuilder path, uint characterCount, uint flags);

    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle",
        SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetBasicInformation(
        SafeFileHandle file, int informationClass,
        ref FILE_BASIC_INFO information, uint bufferSize);

    [DllImport("ntdll.dll", ExactSpelling = true)]
    private static extern int NtSetInformationFile(
        IntPtr file, out IO_STATUS_BLOCK ioStatusBlock,
        IntPtr information, uint bufferSize, int informationClass);

    [DllImport("ntdll.dll", ExactSpelling = true)]
    private static extern uint RtlNtStatusToDosError(int status);

    private static SafeFileHandle Open(
        string path, uint desiredAccess, uint shareMode,
        uint creationDisposition, uint flagsAndAttributes,
        string operation) {
        SafeFileHandle handle = CreateFileW(
            path, desiredAccess, shareMode, IntPtr.Zero,
            creationDisposition, flagsAndAttributes, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, operation + " failed.");
        }
        return handle;
    }

    public static SafeFileHandle OpenDirectoryDenyDelete(string path) {
        return Open(
            path, FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            "OpenDirectoryDenyDelete");
    }

    public static SafeFileHandle OpenFileReadNoFollowDenyDataWriteDelete(
        string path) {
        return Open(
            path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
                FILE_FLAG_SEQUENTIAL_SCAN,
            "OpenFileReadNoFollowDenyDataWriteDelete");
    }

    public static SafeFileHandle CreateNewExclusive(string path) {
        return Open(
            path, GENERIC_READ | GENERIC_WRITE | DELETE, 0, CREATE_NEW,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
                FILE_FLAG_WRITE_THROUGH,
            "CreateNewExclusive");
    }

    public static bool EntryExistsNoFollow(string path) {
        SafeFileHandle handle = CreateFileW(
            path, FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            if (error == 2 || error == 3) return false;
            throw new Win32Exception(error, "EntryExistsNoFollow failed.");
        }
        handle.Dispose();
        return true;
    }

    public static string GetFinalDosPath(SafeFileHandle file) {
        const int MaximumPathCharacters = 32768;
        StringBuilder path = new StringBuilder(MaximumPathCharacters);
        uint result = GetFinalPathNameByHandleW(
            file, path, checked((uint)path.Capacity), 0);
        if (result == 0) {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetFinalPathNameByHandleW failed.");
        }
        if (result >= path.Capacity) {
            throw new InvalidOperationException("Final path exceeds its bound.");
        }
        return path.ToString();
    }

    public static TL1C1bExactPairRendererFileIdentityV1 Read(
        SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetFileInformationByHandle failed.");
        }
        FILE_ID_INFO fileIdInformation;
        if (!GetFileInformationByHandleEx(
                file, FileIdInfo, out fileIdInformation,
                checked((uint)Marshal.SizeOf<FILE_ID_INFO>()))) {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "GetFileInformationByHandleEx(FileIdInfo) failed.");
        }
        ulong size = ((ulong)information.FileSizeHigh << 32) |
            information.FileSizeLow;
        ulong write = ((ulong)information.LastWriteTime.High << 32) |
            information.LastWriteTime.Low;
        return new TL1C1bExactPairRendererFileIdentityV1 {
            LinkCount = information.NumberOfLinks,
            FileAttributes = information.FileAttributes,
            FileSize = size,
            LastWriteTimeUtcFileTime = unchecked((long)write),
            StableId = fileIdInformation.VolumeSerialNumber.ToString("X16") + ":" +
                fileIdInformation.FileId.HighPart.ToString("X16") +
                fileIdInformation.FileId.LowPart.ToString("X16")
        };
    }

    public static void SetReadOnly(
        SafeFileHandle file, uint currentAttributes) {
        FILE_BASIC_INFO information = default;
        information.FileAttributes =
            (currentAttributes & ~FILE_ATTRIBUTE_NORMAL) |
            FILE_ATTRIBUTE_READONLY;
        if (!SetBasicInformation(
                file, FileBasicInfo, ref information,
                checked((uint)Marshal.SizeOf<FILE_BASIC_INFO>()))) {
            throw new Win32Exception(Marshal.GetLastWin32Error(),
                "SetFileInformationByHandle(FileBasicInfo) failed.");
        }
    }

    public static void RenameRelativeToHeldDirectoryNoReplace(
        SafeFileHandle file, SafeFileHandle heldDirectory,
        string simpleFinalName) {
        if (string.IsNullOrEmpty(simpleFinalName) ||
            simpleFinalName == "." || simpleFinalName == ".." ||
            simpleFinalName.IndexOf('\\') >= 0 ||
            simpleFinalName.IndexOf('/') >= 0 ||
            simpleFinalName.IndexOf(':') >= 0 ||
            simpleFinalName.IndexOf('\0') >= 0) {
            throw new ArgumentException("Final name is not a simple leaf.");
        }
        byte[] name = Encoding.Unicode.GetBytes(simpleFinalName);
        if (name.Length == 0 || (name.Length & 1) != 0) {
            throw new ArgumentException("Final path is not valid UTF-16.");
        }
        int rootOffset = IntPtr.Size == 8 ? 8 :
            IntPtr.Size == 4 ? 4 :
            throw new PlatformNotSupportedException();
        int lengthOffset = checked(rootOffset + IntPtr.Size);
        int nameOffset = checked(lengthOffset + sizeof(uint));
        int structureSize = IntPtr.Size == 8 ? 24 : 16;
        byte[] information = new byte[
            checked(structureSize + name.Length)];
        Buffer.BlockCopy(name, 0, information, nameOffset, name.Length);
        GCHandle pin = GCHandle.Alloc(information, GCHandleType.Pinned);
        bool directoryReferenceAdded = false;
        bool fileReferenceAdded = false;
        try {
            heldDirectory.DangerousAddRef(ref directoryReferenceAdded);
            file.DangerousAddRef(ref fileReferenceAdded);
            IntPtr pointer = pin.AddrOfPinnedObject();
            Marshal.WriteInt32(pointer, 0, 0);
            Marshal.WriteIntPtr(
                pointer, rootOffset, heldDirectory.DangerousGetHandle());
            Marshal.WriteInt32(pointer, lengthOffset, name.Length);
            IO_STATUS_BLOCK ioStatusBlock;
            int status = NtSetInformationFile(
                file.DangerousGetHandle(), out ioStatusBlock, pointer,
                checked((uint)information.Length), FileRenameInformation);
            if (status < 0) {
                uint mapped = RtlNtStatusToDosError(status);
                throw new Win32Exception(
                    unchecked((int)mapped),
                    "NtSetInformationFile(FileRenameInformation) failed " +
                    "with NTSTATUS 0x" + status.ToString("X8") +
                    " and Win32 error " + mapped + ".");
            }
        }
        finally {
            if (fileReferenceAdded) file.DangerousRelease();
            if (directoryReferenceAdded) heldDirectory.DangerousRelease();
            pin.Free();
            Array.Clear(information, 0, information.Length);
            Array.Clear(name, 0, name.Length);
        }
    }
}
'@
$addTypeOutput = @(Invoke-RendererPinnedCmdlet `
    -Name 'Add-Type' -CmdletType $pinnedAddTypeCmdletType `
    -Parameters @{ TypeDefinition = $nativeTypeSource })
Assert-Renderer ($addTypeOutput.Count -eq 0) (
    'Pinned Add-Type unexpectedly emitted success output.')
$nativeTypeSource = $null

function ConvertFrom-RendererFinalDosPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return '\\' + $Path.Substring(8)
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        return $Path.Substring(4)
    }
    throw "Native final path has an unsupported prefix: $Path"
}

function Assert-RendererIdentity {
    param(
        [Parameter(Mandatory)]
        [TL1C1bExactPairRendererFileIdentityV1]$Identity,
        [Parameter(Mandatory)][bool]$ExpectedDirectory,
        [Parameter(Mandatory)][bool]$RequireSingleLink,
        [Parameter(Mandatory)][string]$Label
    )
    $reparse = (
        [uint32]$Identity.FileAttributes -band
        [uint32][IO.FileAttributes]::ReparsePoint) -ne 0
    $directory = (
        [uint32]$Identity.FileAttributes -band
        [uint32][IO.FileAttributes]::Directory) -ne 0
    Assert-Renderer (-not $reparse) "$Label is a reparse point."
    Assert-Renderer ($directory -eq $ExpectedDirectory) (
        "$Label directory/file type drifted.")
    Assert-Renderer ([uint32]$Identity.LinkCount -ge 1) (
        "$Label link count is zero.")
    if ($RequireSingleLink) {
        Assert-Renderer ([uint32]$Identity.LinkCount -eq 1) (
            "$Label link count is not exactly one.")
    }
    Assert-Renderer (
        [string]$Identity.StableId -cmatch '\A[0-9A-F]{16}:[0-9A-F]{32}\z'
    ) "$Label stable identity is not canonical."
}

function Assert-RendererFinalPath {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$Label
    )
    $actual = [IO.Path]::GetFullPath((ConvertFrom-RendererFinalDosPath (
        [TL1C1bExactPairRendererFileAuthorityV1]::GetFinalDosPath($Handle))))
    $expected = [IO.Path]::GetFullPath($ExpectedPath)
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals($actual, $expected)
    ) "$Label handle-derived final path drifted."
}

function Get-RendererPathChain {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    Assert-Renderer (-not [string]::IsNullOrWhiteSpace($root)) (
        "Renderer directory has no rooted volume: $full")
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($full, $root)) {
        $full = $full.TrimEnd(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar)
    }
    $result = [Collections.Generic.List[string]]::new()
    $result.Add($root)
    $relative = $full.Substring($root.Length).Trim(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $current = $root
    if (-not [string]::IsNullOrEmpty($relative)) {
        foreach ($part in $relative.Split(
                [char[]]@(
                    [IO.Path]::DirectorySeparatorChar,
                    [IO.Path]::AltDirectorySeparatorChar),
                [StringSplitOptions]::RemoveEmptyEntries)) {
            Assert-Renderer (
                $part -cne '.' -and $part -cne '..' -and
                -not $part.Contains(':')
            ) "Renderer directory chain contains a non-ordinary component: $full"
            $current = [IO.Path]::Combine($current, $part)
            $result.Add([IO.Path]::GetFullPath($current))
        }
    }
    return [string[]]$result.ToArray()
}

function Get-RendererSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-RendererStreamExact {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][long]$MaximumLength,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-Renderer ($Stream.CanRead -and $Stream.CanSeek) (
        "$Label stream is not readable and seekable.")
    $length = [long]$Stream.Length
    Assert-Renderer (
        $length -gt 0L -and $length -le $MaximumLength -and
        $length -le [int]::MaxValue
    ) "$Label length is outside its closed bound."
    $bytes = [byte[]]::new([int]$length)
    try {
        $Stream.Position = 0L
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw "$Label held read ended early." }
            $offset += $read
        }
        Assert-Renderer ($Stream.ReadByte() -eq -1) (
            "$Label grew during its held read.")
        Assert-Renderer ([long]$Stream.Length -eq $length) (
            "$Label length drifted during its held read.")
        return ,$bytes
    }
    catch {
        if ($bytes.Length -ne 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        throw
    }
}

function Assert-RendererPowerShellText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput(
        $Text, [ref]$tokens, [ref]$errors)
    Assert-Renderer ($errors.Count -eq 0) (
        "$Label contains PowerShell parser errors.")
}

function Open-RendererDirectoryChain {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    $entries = [Collections.Generic.List[object]]::new()
    $primary = $null
    $cleanup = [Collections.Generic.List[System.Exception]]::new()
    try {
        $ordinal = 0
        foreach ($component in @(Get-RendererPathChain $Path)) {
            $handle = $null
            $componentPrimary = $null
            $componentCleanup =
                [Collections.Generic.List[System.Exception]]::new()
            try {
                $handle = [TL1C1bExactPairRendererFileAuthorityV1]::
                    OpenDirectoryDenyDelete($component)
                $identity = [TL1C1bExactPairRendererFileAuthorityV1]::
                    Read($handle)
                $componentLabel = "$Label directory[$ordinal]"
                Assert-RendererIdentity $identity $true $false $componentLabel
                Assert-RendererFinalPath $handle $component $componentLabel
                $entries.Add([pscustomobject][ordered]@{
                    Label = $componentLabel
                    Path = [IO.Path]::GetFullPath($component)
                    Handle = $handle
                    InitialIdentity = $identity
                })
                $handle = $null
                $ordinal++
            }
            catch { $componentPrimary = $_ }
            if ($null -ne $handle) {
                try { $handle.Dispose() }
                catch { $componentCleanup.Add($_.Exception) }
            }
            if ($null -ne $componentPrimary) {
                Complete-RendererLocalFailure `
                    -Label "$Label directory component '$component'" `
                    -Primary $componentPrimary `
                    -Cleanup (
                        [System.Exception[]]$componentCleanup.ToArray())
            }
        }
    }
    catch { $primary = $_ }

    if ($null -ne $primary) {
        for ($index = $entries.Count - 1; $index -ge 0; $index--) {
            try { $entries[$index].Handle.Dispose() }
            catch { $cleanup.Add($_.Exception) }
        }
        Complete-RendererLocalFailure `
            -Label "$Label directory-chain acquisition" `
            -Primary $primary -Cleanup ([System.Exception[]]$cleanup.ToArray())
    }

    return [pscustomobject][ordered]@{
        Label = $Label
        Path = [IO.Path]::GetFullPath($Path)
        Entries = $entries
    }
}

function Assert-RendererDirectoryChainStillBound {
    param([Parameter(Mandatory)][object]$Chain)
    foreach ($entry in $Chain.Entries) {
        $current = [TL1C1bExactPairRendererFileAuthorityV1]::
            Read($entry.Handle)
        Assert-RendererIdentity $current $true $false $entry.Label
        Assert-Renderer (
            [StringComparer]::Ordinal.Equals(
                [string]$current.StableId,
                [string]$entry.InitialIdentity.StableId)
        ) "$($entry.Label) stable identity drifted."
        Assert-RendererFinalPath $entry.Handle $entry.Path $entry.Label
    }
}

function Open-RendererInput {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][long]$MaximumLength,
        [Parameter(Mandatory)][bool]$RequireReadOnly,
        [Parameter(Mandatory)][bool]$DecodeUtf8,
        [Parameter(Mandatory)][bool]$ParsePowerShell,
        [Parameter(Mandatory)][string]$Label
    )
    $nativeHandle = $null
    $stream = $null
    $bytes = $null
    $result = $null
    $primary = $null
    $cleanup = [Collections.Generic.List[System.Exception]]::new()
    try {
        $nativeHandle = [TL1C1bExactPairRendererFileAuthorityV1]::
            OpenFileReadNoFollowDenyDataWriteDelete($Path)
        $stream = [IO.FileStream]::new(
            $nativeHandle, [IO.FileAccess]::Read, 4096, $false)
        $nativeHandle = $null
        $identity = [TL1C1bExactPairRendererFileAuthorityV1]::
            Read($stream.SafeFileHandle)
        Assert-RendererIdentity $identity $false $true $Label
        Assert-RendererFinalPath $stream.SafeFileHandle $Path $Label
        $readOnly = (
            [uint32]$identity.FileAttributes -band
            [uint32][IO.FileAttributes]::ReadOnly) -ne 0
        if ($RequireReadOnly) {
            Assert-Renderer $readOnly "$Label is not frozen read-only."
        }
        $bytes = Read-RendererStreamExact $stream $MaximumLength $Label
        $sha256 = Get-RendererSha256 $bytes
        Assert-Renderer ($sha256 -ceq $ExpectedSha256) (
            "$Label SHA-256 drifted.")
        Assert-Renderer ([ulong]$identity.FileSize -eq [ulong]$bytes.Length) (
            "$Label identity length drifted.")

        $text = $null
        if ($DecodeUtf8) {
            Assert-Renderer (-not (
                $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
                $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            )) "$Label unexpectedly has a UTF-8 BOM."
            Assert-Renderer (-not ($bytes -contains 0)) (
                "$Label unexpectedly contains NUL bytes.")
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        }
        if ($ParsePowerShell) {
            Assert-Renderer $DecodeUtf8 (
                "$Label cannot be parsed without strict UTF-8 decoding.")
            Assert-RendererPowerShellText $text $Label
        }

        $result = [pscustomobject][ordered]@{
            Label = $Label
            Path = [IO.Path]::GetFullPath($Path)
            Stream = $stream
            InitialIdentity = $identity
            Bytes = $bytes
            Text = $text
            Sha256 = $sha256
            RequireReadOnly = $RequireReadOnly
            MaximumLength = $MaximumLength
        }
        $stream = $null
        $bytes = $null
    }
    catch { $primary = $_ }

    if ($null -ne $primary) {
        if ($null -ne $bytes -and $bytes.Length -ne 0) {
            try { [Array]::Clear($bytes, 0, $bytes.Length) }
            catch { $cleanup.Add($_.Exception) }
        }
        if ($null -ne $stream) {
            try { $stream.Dispose() }
            catch { $cleanup.Add($_.Exception) }
        }
        if ($null -ne $nativeHandle) {
            try { $nativeHandle.Dispose() }
            catch { $cleanup.Add($_.Exception) }
        }
        Complete-RendererLocalFailure `
            -Label "$Label input acquisition" -Primary $primary `
            -Cleanup ([System.Exception[]]$cleanup.ToArray())
    }

    return $result
}

function Assert-RendererInputStillBound {
    param([Parameter(Mandatory)][object]$InputObject)
    $identity = [TL1C1bExactPairRendererFileAuthorityV1]::
        Read($InputObject.Stream.SafeFileHandle)
    Assert-RendererIdentity $identity $false $true $InputObject.Label
    Assert-Renderer (
        [StringComparer]::Ordinal.Equals(
            [string]$identity.StableId,
            [string]$InputObject.InitialIdentity.StableId)
    ) "$($InputObject.Label) stable identity drifted."
    Assert-Renderer (
        [ulong]$identity.FileSize -eq [ulong]$InputObject.Bytes.Length
    ) "$($InputObject.Label) identity length drifted."
    if ($InputObject.RequireReadOnly) {
        Assert-Renderer ((
            [uint32]$identity.FileAttributes -band
            [uint32][IO.FileAttributes]::ReadOnly) -ne 0) (
            "$($InputObject.Label) lost its read-only attribute.")
    }
    Assert-RendererFinalPath `
        $InputObject.Stream.SafeFileHandle $InputObject.Path $InputObject.Label
    $repeat = Read-RendererStreamExact `
        $InputObject.Stream ([long]$InputObject.MaximumLength) `
        ($InputObject.Label + ' final revalidation')
    try {
        Assert-Renderer (
            [Security.Cryptography.CryptographicOperations]::
                FixedTimeEquals($InputObject.Bytes, $repeat)
        ) "$($InputObject.Label) bytes drifted while held."
        Assert-Renderer ((Get-RendererSha256 $repeat) -ceq $InputObject.Sha256) (
            "$($InputObject.Label) SHA-256 drifted while held.")
    }
    finally {
        if ($repeat.Length -ne 0) {
            [Array]::Clear($repeat, 0, $repeat.Length)
        }
    }
}

function Replace-RendererExact {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Placeholder,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][long]$ExpectedCount
    )
    Assert-Renderer (
        $Value.IndexOf("'", [StringComparison]::Ordinal) -lt 0 -and
        $Value.IndexOf("`r", [StringComparison]::Ordinal) -lt 0 -and
        $Value.IndexOf("`n", [StringComparison]::Ordinal) -lt 0 -and
        $Value.IndexOf([char]0) -lt 0
    ) "Renderer replacement is unsafe: $Placeholder"
    $actualCount = [regex]::Matches(
        $Text, [regex]::Escape($Placeholder),
        [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    Assert-Renderer ($actualCount -eq $ExpectedCount) (
        "Renderer placeholder cardinality drifted: $Placeholder ($actualCount)")
    return $Text.Replace($Placeholder, $Value, [StringComparison]::Ordinal)
}

function Assert-RendererCandidateStillBound {
    param(
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][bool]$RequireReadOnly
    )
    $identity = [TL1C1bExactPairRendererFileAuthorityV1]::
        Read($Candidate.Stream.SafeFileHandle)
    Assert-RendererIdentity $identity $false $true $Candidate.Label
    Assert-Renderer (
        [StringComparer]::Ordinal.Equals(
            [string]$identity.StableId,
            [string]$Candidate.InitialIdentity.StableId)
    ) "$($Candidate.Label) stable identity drifted."
    $readOnly = (
        [uint32]$identity.FileAttributes -band
        [uint32][IO.FileAttributes]::ReadOnly) -ne 0
    Assert-Renderer ($readOnly -eq $RequireReadOnly) (
        "$($Candidate.Label) read-only state drifted.")
    Assert-Renderer (
        [ulong]$identity.FileSize -eq [ulong]$Candidate.Bytes.Length
    ) "$($Candidate.Label) identity length drifted."
    Assert-RendererFinalPath `
        $Candidate.Stream.SafeFileHandle $ExpectedPath $Candidate.Label
    $repeat = Read-RendererStreamExact `
        $Candidate.Stream ([long]$Candidate.Bytes.Length) `
        ($Candidate.Label + ' held revalidation')
    try {
        Assert-Renderer (
            [Security.Cryptography.CryptographicOperations]::
                FixedTimeEquals($Candidate.Bytes, $repeat)
        ) "$($Candidate.Label) held bytes drifted."
        Assert-Renderer ((Get-RendererSha256 $repeat) -ceq $Candidate.Sha256) (
            "$($Candidate.Label) held SHA-256 drifted.")
    }
    finally {
        if ($repeat.Length -ne 0) {
            [Array]::Clear($repeat, 0, $repeat.Length)
        }
    }
}

function New-RendererCandidate {
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][long]$ExpectedLength,
        [Parameter(Mandatory)][object]$ParentDirectoryEntry,
        [Parameter(Mandatory)][string]$Label
    )
    $nativeHandle = $null
    $stream = $null
    $bytes = $null
    $candidate = $null
    $primary = $null
    $cleanup = [Collections.Generic.List[System.Exception]]::new()
    try {
        Assert-Renderer (-not [regex]::IsMatch($Text, '__[A-Z0-9_]+__')) (
            "$Label still contains an unresolved placeholder.")
        Assert-RendererPowerShellText $Text $Label
        Assert-Renderer (
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($TemporaryPath),
                $ParentDirectoryEntry.Path) -and
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($FinalPath),
                $ParentDirectoryEntry.Path)
        ) "$Label temp/final paths escaped the held parent directory."
        Assert-RendererFinalPath `
            $ParentDirectoryEntry.Handle $ParentDirectoryEntry.Path `
            ($Label + ' held parent')
        $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($Text)
        Assert-Renderer ([long]$bytes.Length -eq $ExpectedLength) (
            "$Label rendered byte length drifted.")
        $sha256 = Get-RendererSha256 $bytes
        Assert-Renderer ($sha256 -ceq $ExpectedSha256) (
            "$Label rendered SHA-256 drifted.")
        Assert-Renderer (
            -not [TL1C1bExactPairRendererFileAuthorityV1]::
                EntryExistsNoFollow($TemporaryPath)
        ) "$Label temporary path unexpectedly exists."
        Assert-Renderer (
            -not [TL1C1bExactPairRendererFileAuthorityV1]::
                EntryExistsNoFollow($FinalPath)
        ) "$Label final path unexpectedly exists."

        $nativeHandle = [TL1C1bExactPairRendererFileAuthorityV1]::
            CreateNewExclusive($TemporaryPath)
        $stream = [IO.FileStream]::new(
            $nativeHandle, [IO.FileAccess]::ReadWrite, 4096, $false)
        $nativeHandle = $null
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)

        $identity = [TL1C1bExactPairRendererFileAuthorityV1]::
            Read($stream.SafeFileHandle)
        Assert-RendererIdentity $identity $false $true $Label
        Assert-Renderer (
            [ulong]$identity.FileSize -eq [ulong]$bytes.Length
        ) "$Label temporary identity length drifted."
        Assert-RendererFinalPath `
            $stream.SafeFileHandle $TemporaryPath ($Label + ' temporary')

        $readback = Read-RendererStreamExact `
            $stream $ExpectedLength ($Label + ' temporary readback')
        try {
            Assert-Renderer (
                [Security.Cryptography.CryptographicOperations]::
                    FixedTimeEquals($bytes, $readback)
            ) "$Label temporary held readback drifted."
        }
        finally {
            if ($readback.Length -ne 0) {
                [Array]::Clear($readback, 0, $readback.Length)
            }
        }

        $candidate = [pscustomobject][ordered]@{
            Label = $Label
            TemporaryPath = [IO.Path]::GetFullPath($TemporaryPath)
            FinalPath = [IO.Path]::GetFullPath($FinalPath)
            Stream = $stream
            InitialIdentity = $identity
            Bytes = $bytes
            Sha256 = $sha256
            ByteLength = [long]$bytes.Length
            ParentDirectoryEntry = $ParentDirectoryEntry
            Published = $false
        }
        $stream = $null
        $bytes = $null
    }
    catch { $primary = $_ }

    if ($null -ne $primary) {
        if ($null -ne $stream) {
            try { $stream.Dispose() }
            catch { $cleanup.Add($_.Exception) }
        }
        elseif ($null -ne $nativeHandle) {
            try { $nativeHandle.Dispose() }
            catch { $cleanup.Add($_.Exception) }
        }
        if ($null -ne $bytes -and $bytes.Length -ne 0) {
            try { [Array]::Clear($bytes, 0, $bytes.Length) }
            catch { $cleanup.Add($_.Exception) }
        }
        Complete-RendererLocalFailure `
            -Label "$Label staging" -Primary $primary `
            -Cleanup ([System.Exception[]]$cleanup.ToArray())
    }

    return $candidate
}

function Publish-RendererCandidate {
    param([Parameter(Mandatory)][object]$Candidate)
    Assert-Renderer (-not [bool]$Candidate.Published) (
        "$($Candidate.Label) was already published.")
    Assert-Renderer (
        -not [TL1C1bExactPairRendererFileAuthorityV1]::
            EntryExistsNoFollow($Candidate.FinalPath)
    ) "$($Candidate.Label) final path appeared before publication."
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($Candidate.TemporaryPath),
            [IO.Path]::GetDirectoryName($Candidate.FinalPath))
    ) "$($Candidate.Label) temp/final parents drifted."
    Assert-RendererCandidateStillBound `
        $Candidate $Candidate.TemporaryPath $false
    [TL1C1bExactPairRendererFileAuthorityV1]::
        RenameRelativeToHeldDirectoryNoReplace(
            $Candidate.Stream.SafeFileHandle,
            $Candidate.ParentDirectoryEntry.Handle,
            [IO.Path]::GetFileName($Candidate.FinalPath))
    $Candidate.Published = $true
    $publishedIdentity = [TL1C1bExactPairRendererFileAuthorityV1]::
        Read($Candidate.Stream.SafeFileHandle)
    Assert-Renderer (
        [StringComparer]::Ordinal.Equals(
            [string]$publishedIdentity.StableId,
            [string]$Candidate.InitialIdentity.StableId)
    ) "$($Candidate.Label) stable identity drifted during publication."
    [TL1C1bExactPairRendererFileAuthorityV1]::SetReadOnly(
        $Candidate.Stream.SafeFileHandle,
        [uint32]$publishedIdentity.FileAttributes)
    Assert-RendererCandidateStillBound `
        $Candidate $Candidate.FinalPath $true
    Assert-Renderer (
        -not [TL1C1bExactPairRendererFileAuthorityV1]::
            EntryExistsNoFollow($Candidate.TemporaryPath)
    ) "$($Candidate.Label) temporary name survived held publication."
}

function Assert-RendererCanonicalPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )
    Assert-Renderer ([IO.Path]::IsPathFullyQualified($Path)) (
        "$Label is not fully qualified.")
    Assert-Renderer (
        [StringComparer]::Ordinal.Equals([IO.Path]::GetFullPath($Path), $Path)
    ) "$Label is not lexically canonical."
    Assert-Renderer ($Path.IndexOf([char]0) -lt 0) (
        "$Label contains a NUL character.")
    Assert-Renderer ($Path -cmatch '\A[A-Za-z]:\\') (
        "$Label is not a fixed local DOS path.")
    Assert-Renderer ($Path.IndexOf(':', 2) -lt 0) (
        "$Label contains an alternate data stream delimiter.")
    Assert-Renderer ($Path.Length -lt 260) (
        "$Label exceeds the renderer's closed Win32 path bound.")
}

function Assert-RendererEntriesAbsent {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($path in $Paths) {
        Assert-Renderer (
            -not [TL1C1bExactPairRendererFileAuthorityV1]::
                EntryExistsNoFollow($path)
        ) "$Label unexpectedly exists: $path"
    }
}

$directoryChains = [Collections.Generic.List[object]]::new()
$inputs = [Collections.Generic.List[object]]::new()
$inputByLabel = [Collections.Generic.Dictionary[string, object]]::new(
    [StringComparer]::Ordinal)
$candidates = [Collections.Generic.List[object]]::new()
$mainPrimary = $null
$mainCleanup = [Collections.Generic.List[System.Exception]]::new()
$successJson = $null
$helperText = $null
$launcherText = $null

try {
    $allPaths = @(
        $stagingRoot, $repoRoot, $outputRoot,
        $helperTemplatePath, $launcherTemplatePath,
        $helperPath, $launcherPath,
        $helperTemporaryPath, $launcherTemporaryPath,
        $failureSidecarPath, $summaryPath, $logPath, $launcherResultPath,
        $verifierPath, $pwshPath, $utilityAssemblyPath)
    foreach ($path in $allPaths) {
        Assert-RendererCanonicalPath $path "renderer path '$path'"
    }

    foreach ($path in @(
            $helperPath, $launcherPath,
            $helperTemporaryPath, $launcherTemporaryPath,
            $failureSidecarPath)) {
        Assert-Renderer (
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($path), $stagingRoot)
        ) "Staging child escaped its fixed parent: $path"
    }
    foreach ($path in @($summaryPath, $logPath, $launcherResultPath)) {
        Assert-Renderer (
            [StringComparer]::OrdinalIgnoreCase.Equals(
                [IO.Path]::GetDirectoryName($path), $outputRoot)
        ) "Output child escaped its fixed parent: $path"
    }

    $driveRoots = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($stagingRoot, $repoRoot, $pwshPath)) {
        [void]$driveRoots.Add([IO.Path]::GetPathRoot($path))
    }
    foreach ($driveRoot in $driveRoots) {
        $drive = [IO.DriveInfo]::new($driveRoot)
        Assert-Renderer ($drive.IsReady -and $drive.DriveFormat -ceq 'NTFS') (
            "Renderer authority requires a ready NTFS volume: $driveRoot")
    }

    $directoryChains.Add((Open-RendererDirectoryChain `
        -Path $stagingRoot -Label 'staging root'))
    $directoryChains.Add((Open-RendererDirectoryChain `
        -Path $outputRoot -Label 'output root'))
    $directoryChains.Add((Open-RendererDirectoryChain `
        -Path ([IO.Path]::GetDirectoryName($pwshPath)) `
        -Label 'pinned pwsh parent'))
    $directoryChains.Add((Open-RendererDirectoryChain `
        -Path ([IO.Path]::GetDirectoryName($verifierPath)) `
        -Label 'smoke verifier parent'))
    $stagingDirectoryEntry =
        $directoryChains[0].Entries[$directoryChains[0].Entries.Count - 1]
    Assert-Renderer (
        [StringComparer]::OrdinalIgnoreCase.Equals(
            $stagingDirectoryEntry.Path, $stagingRoot)
    ) 'Terminal held staging directory entry drifted.'

    $initialAbsentPaths = [string[]]@(
        $helperPath, $launcherPath,
        $helperTemporaryPath, $launcherTemporaryPath,
        $failureSidecarPath,
        $summaryPath, $logPath, $launcherResultPath)
    Assert-RendererEntriesAbsent $initialAbsentPaths 'renderer target'

    $inputSpecifications = @(
        [pscustomobject]@{
            Label = 'helper_template'
            Path = $helperTemplatePath
            Sha256 = $expectedHelperTemplateSha256
            MaximumLength = 1048576L
            RequireReadOnly = $false
            DecodeUtf8 = $true
            ParsePowerShell = $true
        },
        [pscustomobject]@{
            Label = 'launcher_template_r11'
            Path = $launcherTemplatePath
            Sha256 = $expectedLauncherTemplateSha256
            MaximumLength = 1048576L
            RequireReadOnly = $false
            DecodeUtf8 = $true
            ParsePowerShell = $true
        },
        [pscustomobject]@{
            Label = 'smoke_verifier'
            Path = $verifierPath
            Sha256 = $expectedVerifierSha256
            MaximumLength = 1048576L
            RequireReadOnly = $false
            DecodeUtf8 = $true
            ParsePowerShell = $true
        },
        [pscustomobject]@{
            Label = 'pinned_pwsh'
            Path = $pwshPath
            Sha256 = $expectedPwshSha256
            MaximumLength = 1048576L
            RequireReadOnly = $false
            DecodeUtf8 = $false
            ParsePowerShell = $false
        },
        [pscustomobject]@{
            Label = 'pinned_utility_assembly'
            Path = $utilityAssemblyPath
            Sha256 = $expectedUtilityAssemblySha256
            MaximumLength = 4194304L
            RequireReadOnly = $false
            DecodeUtf8 = $false
            ParsePowerShell = $false
        })
    foreach ($specification in $inputSpecifications) {
        $inputObject = Open-RendererInput `
            -Path ([string]$specification.Path) `
            -ExpectedSha256 ([string]$specification.Sha256) `
            -MaximumLength ([long]$specification.MaximumLength) `
            -RequireReadOnly ([bool]$specification.RequireReadOnly) `
            -DecodeUtf8 ([bool]$specification.DecodeUtf8) `
            -ParsePowerShell ([bool]$specification.ParsePowerShell) `
            -Label ([string]$specification.Label)
        $inputs.Add($inputObject)
        $inputByLabel.Add([string]$specification.Label, $inputObject)
    }

    $helperText = [string]$inputByLabel['helper_template'].Text
    $helperText = Replace-RendererExact `
        $helperText '__FINAL_COMMIT_SHA__' $commitSha 1L
    $helperText = Replace-RendererExact `
        $helperText '__FINAL_COMMIT_SHORT__' $commitShort 1L
    $helperCandidate = New-RendererCandidate `
        -TemporaryPath $helperTemporaryPath -FinalPath $helperPath `
        -Text $helperText -ExpectedSha256 $expectedHelperSha256 `
        -ExpectedLength $expectedHelperLength `
        -ParentDirectoryEntry $stagingDirectoryEntry `
        -Label 'exact helper r11'
    $candidates.Add($helperCandidate)

    $launcherText = [string]$inputByLabel['launcher_template_r11'].Text
    foreach ($slot in @(
            [pscustomobject]@{
                Placeholder = '__FINAL_COMMIT_SHA__'; Value = $commitSha },
            [pscustomobject]@{
                Placeholder = '__FINAL_COMMIT_SHORT__'; Value = $commitShort },
            [pscustomobject]@{
                Placeholder = '__REPO_ROOT__'; Value = $repoRoot },
            [pscustomobject]@{
                Placeholder = '__FAILURE_SIDECAR_ABSOLUTE_PATH__'
                Value = $failureSidecarPath },
            [pscustomobject]@{
                Placeholder = '__HELPER_ABSOLUTE_PATH__'; Value = $helperPath },
            [pscustomobject]@{
                Placeholder = '__HELPER_SHA256__'
                Value = $helperCandidate.Sha256 },
            [pscustomobject]@{
                Placeholder = '__VERIFIER_SHA256__'
                Value = $expectedVerifierSha256 },
            [pscustomobject]@{
                Placeholder = '__PWSH_ABSOLUTE_PATH__'; Value = $pwshPath },
            [pscustomobject]@{
                Placeholder = '__PWSH_SHA256__'; Value = $expectedPwshSha256 })) {
        $launcherText = Replace-RendererExact `
            $launcherText ([string]$slot.Placeholder) ([string]$slot.Value) 1L
    }
    $launcherCandidate = New-RendererCandidate `
        -TemporaryPath $launcherTemporaryPath -FinalPath $launcherPath `
        -Text $launcherText -ExpectedSha256 $expectedLauncherSha256 `
        -ExpectedLength $expectedLauncherLength `
        -ParentDirectoryEntry $stagingDirectoryEntry `
        -Label 'exact launcher r11'
    $candidates.Add($launcherCandidate)

    foreach ($chain in $directoryChains) {
        Assert-RendererDirectoryChainStillBound $chain
    }
    foreach ($inputObject in $inputs) {
        Assert-RendererInputStillBound $inputObject
    }

    Publish-RendererCandidate $launcherCandidate
    Publish-RendererCandidate $helperCandidate

    foreach ($chain in $directoryChains) {
        Assert-RendererDirectoryChainStillBound $chain
    }
    foreach ($inputObject in $inputs) {
        Assert-RendererInputStillBound $inputObject
    }
    Assert-RendererCandidateStillBound $launcherCandidate $launcherPath $true
    Assert-RendererCandidateStillBound $helperCandidate $helperPath $true
    Assert-RendererEntriesAbsent `
        ([string[]]@($helperTemporaryPath, $launcherTemporaryPath)) `
        'published temporary path'
    Assert-RendererEntriesAbsent `
        ([string[]]@(
            $failureSidecarPath, $summaryPath, $logPath, $launcherResultPath)) `
        'unauthorized target output'

    $success = [pscustomobject][ordered]@{
        schema = 'tablet-layout-c1b-exact-launcher-r11-render/v1'
        commit_sha = $commitSha
        commit_short = $commitShort
        renderer_execution_scope = 'artifact_generation_only'
        helper_path = $helperPath
        helper_sha256 = $helperCandidate.Sha256
        helper_byte_length = $helperCandidate.ByteLength
        helper_read_only = $true
        launcher_path = $launcherPath
        launcher_sha256 = $launcherCandidate.Sha256
        launcher_byte_length = $launcherCandidate.ByteLength
        launcher_read_only = $true
        inputs_held_deny_data_write_delete_sharing = $true
        input_stable_ids_revalidated = $true
        directory_chains_held_deny_delete_sharing = $true
        directory_stable_ids_revalidated = $true
        directory_timestamp_equality_required = $false
        directory_data_write_or_reparse_lease_claimed = $false
        temporary_files_created_exclusive_data_delete_sharing = $true
        final_files_frozen_read_only_before_data_delete_guard_release = $true
        final_name_data_or_delete_accessible_before_read_only = $false
        attribute_or_ea_lease_claimed = $false
        publication_same_handle_rename_no_replace = $true
        final_paths_verified_from_held_handles = $true
        final_stable_ids_revalidated = $true
        final_bytes_revalidated_from_held_handles = $true
        continuous_namespace_lease_claimed = $false
        success_json_assembled_while_all_guards_held = $true
        utility_assembly_loaded_from_exact_pinned_bytes = $true
        launcher_executed = $false
        helper_executed = $false
        preflight_executed = $false
        git_executed = $false
        build_executed = $false
        adb_or_device_operation_executed = $false
        failure_sidecar_created = $false
        smoke_outputs_created = $false
    }
    $jsonOutput = @(Invoke-RendererPinnedCmdlet `
        -Name 'ConvertTo-Json' `
        -CmdletType $pinnedConvertToJsonCmdletType `
        -Parameters @{
            InputObject = $success
            Depth = 5
            Compress = $true
        })
    Assert-Renderer ($jsonOutput.Count -eq 1) (
        'Pinned ConvertTo-Json did not emit exactly one record.')
    $successJson = [string]$jsonOutput[0]
    Assert-Renderer (-not [string]::IsNullOrWhiteSpace($successJson)) (
        'Renderer success JSON could not be assembled.')
}
catch { $mainPrimary = $_ }
finally {
    for ($index = 0; $index -lt $candidates.Count; $index++) {
        $candidate = $candidates[$index]
        try { $candidate.Stream.Dispose() }
        catch { $mainCleanup.Add($_.Exception) }
        if ($null -ne $candidate.Bytes -and $candidate.Bytes.Length -ne 0) {
            try {
                [Array]::Clear(
                    $candidate.Bytes, 0, $candidate.Bytes.Length)
            }
            catch { $mainCleanup.Add($_.Exception) }
        }
    }
    for ($index = $inputs.Count - 1; $index -ge 0; $index--) {
        $inputObject = $inputs[$index]
        try { $inputObject.Stream.Dispose() }
        catch { $mainCleanup.Add($_.Exception) }
        if ($null -ne $inputObject.Bytes -and
            $inputObject.Bytes.Length -ne 0) {
            try {
                [Array]::Clear(
                    $inputObject.Bytes, 0, $inputObject.Bytes.Length)
            }
            catch { $mainCleanup.Add($_.Exception) }
        }
    }
    for ($chainIndex = $directoryChains.Count - 1;
         $chainIndex -ge 0; $chainIndex--) {
        $chain = $directoryChains[$chainIndex]
        for ($entryIndex = $chain.Entries.Count - 1;
             $entryIndex -ge 0; $entryIndex--) {
            try { $chain.Entries[$entryIndex].Handle.Dispose() }
            catch { $mainCleanup.Add($_.Exception) }
        }
    }
    $helperText = $null
    $launcherText = $null
}

Complete-RendererLocalFailure `
    -Label 'exact-pair renderer' -Primary $mainPrimary `
    -Cleanup ([System.Exception[]]$mainCleanup.ToArray())
Assert-Renderer (-not [string]::IsNullOrWhiteSpace($successJson)) (
    'Renderer completed without a success record.')
[Console]::Out.WriteLine($successJson)
