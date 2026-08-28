#Requires -Version 7.5
# T-L1 C1b private ADB server lifecycle and endpoint ownership guard.

Set-StrictMode -Version 3.0

$script:TL1C1bPrivateAdbServerSchema = 'tablet-layout-c1b-private-adb-server/v1'
$script:TL1C1bPrivateAdbHost = '127.0.0.1'
$script:TL1C1bPrivateAdbMinimumPort = 49152
$script:TL1C1bPrivateAdbMaximumPortExclusive = 65536

if ($null -eq ('TL1C1bPrivateAdbNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bTcpListenerOwner {
    public string Address { get; set; }
    public int Port { get; set; }
    public int ProcessId { get; set; }
}

public sealed class TL1C1bBoundedWriteStream : Stream {
    private readonly object gate = new object();
    private readonly MemoryStream stream = new MemoryStream();
    private readonly long maximumBytes;
    private long observedBytes;
    private bool disposed;

    public TL1C1bBoundedWriteStream(long maximumBytes) {
        if (maximumBytes < 1) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        this.maximumBytes = maximumBytes;
    }

    public bool Overflowed { get { lock (gate) { return observedBytes > maximumBytes; } } }
    public long ObservedBytes { get { lock (gate) { return observedBytes; } } }
    public byte[] Snapshot() { lock (gate) { return stream.ToArray(); } }

    public override void Write(byte[] buffer, int offset, int count) {
        if (buffer == null) throw new ArgumentNullException(nameof(buffer));
        if (offset < 0 || count < 0 || offset + count > buffer.Length) {
            throw new ArgumentOutOfRangeException();
        }
        lock (gate) {
            if (disposed) throw new ObjectDisposedException(nameof(TL1C1bBoundedWriteStream));
            observedBytes += count;
            long remaining = maximumBytes - stream.Length;
            if (remaining > 0) {
                int accepted = (int)Math.Min((long)count, remaining);
                stream.Write(buffer, offset, accepted);
            }
        }
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count,
                                    CancellationToken cancellationToken) {
        cancellationToken.ThrowIfCancellationRequested();
        Write(buffer, offset, count);
        return Task.CompletedTask;
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            lock (gate) {
                if (!disposed) {
                    disposed = true;
                    stream.Dispose();
                }
            }
        }
        base.Dispose(disposing);
    }

    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position {
        get { throw new NotSupportedException(); }
        set { throw new NotSupportedException(); }
    }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) {
        throw new NotSupportedException();
    }
    public override long Seek(long offset, SeekOrigin origin) {
        throw new NotSupportedException();
    }
    public override void SetLength(long value) { throw new NotSupportedException(); }
}

public sealed class TL1C1bBoundedSha256WriteStream : Stream {
    private readonly object gate = new object();
    private readonly IncrementalHash hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    private readonly long maximumBytes;
    private long observedBytes;
    private bool completed;
    private bool disposed;

    public TL1C1bBoundedSha256WriteStream(long maximumBytes) {
        if (maximumBytes < 1) throw new ArgumentOutOfRangeException(nameof(maximumBytes));
        this.maximumBytes = maximumBytes;
    }

    public bool Overflowed { get { lock (gate) { return observedBytes > maximumBytes; } } }
    public long ObservedBytes { get { lock (gate) { return observedBytes; } } }

    public string CompleteHash() {
        lock (gate) {
            if (disposed) throw new ObjectDisposedException(nameof(TL1C1bBoundedSha256WriteStream));
            if (completed) throw new InvalidOperationException("hash was already completed");
            if (observedBytes > maximumBytes) throw new InvalidDataException("stream exceeded limit");
            completed = true;
            byte[] digest = hash.GetHashAndReset();
            try { return "sha256:" + BitConverter.ToString(digest).Replace("-", "").ToLowerInvariant(); }
            finally { Array.Clear(digest, 0, digest.Length); }
        }
    }

    public override void Write(byte[] buffer, int offset, int count) {
        if (buffer == null) throw new ArgumentNullException(nameof(buffer));
        if (offset < 0 || count < 0 || offset + count > buffer.Length) {
            throw new ArgumentOutOfRangeException();
        }
        lock (gate) {
            if (disposed) throw new ObjectDisposedException(nameof(TL1C1bBoundedSha256WriteStream));
            if (completed) throw new InvalidOperationException("hash was already completed");
            observedBytes = checked(observedBytes + count);
            if (observedBytes <= maximumBytes) hash.AppendData(buffer, offset, count);
        }
    }

    public override Task WriteAsync(byte[] buffer, int offset, int count,
                                    CancellationToken cancellationToken) {
        cancellationToken.ThrowIfCancellationRequested();
        Write(buffer, offset, count);
        return Task.CompletedTask;
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            lock (gate) {
                if (!disposed) {
                    disposed = true;
                    hash.Dispose();
                }
            }
        }
        base.Dispose(disposing);
    }

    public override bool CanRead { get { return false; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return true; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position {
        get { throw new NotSupportedException(); }
        set { throw new NotSupportedException(); }
    }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
}

public sealed class TL1C1bPrivateAdbGuardHandle {
    public string Id { get; }
    public bool Disposed { get; private set; }

    public TL1C1bPrivateAdbGuardHandle(string id) {
        if (String.IsNullOrEmpty(id)) throw new ArgumentException(nameof(id));
        Id = id;
    }

    internal void MarkDisposed() { Disposed = true; }
}

public sealed class TL1C1bPrivateAdbBinding {
    public string schema { get; }
    public string server_mode { get; }
    public string server_socket { get; }
    public string server_executable_sha256 { get; }
    public bool job_kill_on_close { get; }
    public bool listener_pid_verified { get; }
    public bool server_status_executable_path_verified { get; }
    public bool server_ready_verified { get; }
    public bool default_server_used { get; }

    public TL1C1bPrivateAdbBinding(string schema, string serverSocket,
                                  string executableSha256) {
        this.schema = schema;
        server_mode = "private_nodaemon";
        server_socket = serverSocket;
        server_executable_sha256 = executableSha256;
        job_kill_on_close = true;
        listener_pid_verified = true;
        server_status_executable_path_verified = true;
        server_ready_verified = true;
        default_server_used = false;
    }
}

public sealed class TL1C1bPrivateAdbCleanupBinding {
    public bool server_cleanup_verified { get; }
    public bool private_kill_server_requested { get; }
    public bool graceful_exit_verified { get; }
    public bool job_fallback_used { get; }
    public bool port_rebind_verified { get; }

    public TL1C1bPrivateAdbCleanupBinding(bool privateKillServerRequested,
                                         bool gracefulExitVerified,
                                         bool jobFallbackUsed) {
        server_cleanup_verified = true;
        private_kill_server_requested = privateKillServerRequested;
        graceful_exit_verified = gracefulExitVerified;
        job_fallback_used = jobFallbackUsed;
        port_rebind_verified = true;
    }
}

public sealed class TL1C1bStartedProcess : IDisposable {
    public Process Process { get; }
    public Stream StandardInput { get; }
    public Stream StandardOutput { get; }
    public Stream StandardError { get; }

    public TL1C1bStartedProcess(Process process, Stream standardInput, Stream standardOutput,
                                Stream standardError) {
        Process = process;
        StandardInput = standardInput;
        StandardOutput = standardOutput;
        StandardError = standardError;
    }

    public void Dispose() {
        StandardInput.Dispose();
        StandardOutput.Dispose();
        StandardError.Dispose();
        Process.Dispose();
    }
}

public static class TL1C1bPrivateAdbNative {
    private const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008;
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;
    private const int AF_INET = 2;
    private const int TCP_TABLE_OWNER_PID_LISTENER = 3;
    private const uint NO_ERROR = 0;
    private const uint ERROR_INSUFFICIENT_BUFFER = 122;
    private const int ERROR_ALREADY_EXISTS = 183;
    private const uint MIB_TCP_STATE_LISTEN = 2;
    private const uint STARTF_USESTDHANDLES = 0x00000100;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint HANDLE_FLAG_INHERIT = 0x00000001;
    private static readonly UIntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST =
        new UIntPtr(0x00020002);
    private static readonly UIntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST =
        new UIntPtr(0x0002000D);

    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int Length;
        public IntPtr SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX {
        public STARTUPINFO StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_INFO {
        public ulong VolumeSerialNumber;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] FileId;
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
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
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
    private struct MIB_TCPROW_OWNER_PID {
        public uint State;
        public uint LocalAddress;
        public uint LocalPort;
        public uint RemoteAddress;
        public uint RemotePort;
        public uint OwningPid;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObjectW(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        SafeFileHandle job, int informationClass, IntPtr information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(
        IntPtr process, SafeFileHandle job, [MarshalAs(UnmanagedType.Bool)] out bool result);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandleEx(
        SafeFileHandle file, int informationClass, out FILE_ID_INFO information,
        uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(
        out SafeFileHandle readPipe, out SafeFileHandle writePipe,
        ref SECURITY_ATTRIBUTES attributes, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(
        SafeFileHandle handle, uint mask, uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList, int attributeCount, uint flags, ref UIntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList, uint flags, UIntPtr attribute, IntPtr value,
        UIntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string applicationName, StringBuilder commandLine, IntPtr processAttributes,
        IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(
        IntPtr table, ref int tableLength, bool order, int ipVersion,
        int tableClass, uint reserved);

    public static SafeFileHandle CreateKillOnCloseJob(int activeProcessLimit) {
        return CreateKillOnCloseJob(activeProcessLimit, null);
    }

    public static SafeFileHandle CreateKillOnCloseJob(int activeProcessLimit, string name) {
        if (activeProcessLimit < 1 || activeProcessLimit > 64 ||
            (name != null && (name.Length < 1 || name.Length > 128))) {
            throw new ArgumentOutOfRangeException(nameof(activeProcessLimit));
        }
        SafeFileHandle job = CreateJobObjectW(IntPtr.Zero, name);
        int creationError = Marshal.GetLastWin32Error();
        if (job == null || job.IsInvalid) {
            throw new Win32Exception(creationError);
        }
        if (name != null && creationError == ERROR_ALREADY_EXISTS) {
            job.Dispose();
            throw new InvalidOperationException("job name collision");
        }
        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION information =
                new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            information.BasicLimitInformation.LimitFlags =
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
            information.BasicLimitInformation.ActiveProcessLimit = checked((uint)activeProcessLimit);
            Marshal.StructureToPtr(information, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                         buffer, (uint)size)) {
                int error = Marshal.GetLastWin32Error();
                job.Dispose();
                throw new Win32Exception(error);
            }
            return job;
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static void AssignProcess(SafeFileHandle job, IntPtr process) {
        if (job == null || job.IsClosed || job.IsInvalid) {
            throw new InvalidOperationException("job handle is not available");
        }
        if (!AssignProcessToJobObject(job, process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static bool IsProcessAssigned(SafeFileHandle job, IntPtr process) {
        if (job == null || job.IsClosed || job.IsInvalid || process == IntPtr.Zero) {
            return false;
        }
        bool result;
        if (!IsProcessInJob(process, job, out result)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return result;
    }

    public static string GetFileIdentity(SafeFileHandle file) {
        if (file == null || file.IsClosed || file.IsInvalid) {
            throw new InvalidOperationException("file handle is not available");
        }
        FILE_ID_INFO information;
        uint size = checked((uint)Marshal.SizeOf(typeof(FILE_ID_INFO)));
        if (!GetFileInformationByHandleEx(file, 18, out information, size)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (information.FileId == null || information.FileId.Length != 16) {
            throw new InvalidDataException("FILE_ID_INFO returned an invalid file id");
        }
        return information.VolumeSerialNumber.ToString("x16") + ":" +
            BitConverter.ToString(information.FileId).Replace("-", "").ToLowerInvariant();
    }

    private static string QuoteArgument(string argument) {
        if (argument == null) throw new ArgumentNullException(nameof(argument));
        if (argument.Length != 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) {
            return argument;
        }
        StringBuilder quoted = new StringBuilder();
        quoted.Append('"');
        int backslashes = 0;
        foreach (char character in argument) {
            if (character == '\\') {
                backslashes++;
            } else if (character == '"') {
                quoted.Append('\\', backslashes * 2 + 1);
                quoted.Append('"');
                backslashes = 0;
            } else {
                quoted.Append('\\', backslashes);
                backslashes = 0;
                quoted.Append(character);
            }
        }
        quoted.Append('\\', backslashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    public static TL1C1bStartedProcess StartInJob(
        string filePath, string[] arguments, string[] environmentEntries,
        SafeFileHandle job) {
        if (String.IsNullOrEmpty(filePath) || !Path.IsPathFullyQualified(filePath)) {
            throw new ArgumentException(nameof(filePath));
        }
        if (arguments == null || environmentEntries == null) {
            throw new ArgumentNullException();
        }
        if (job == null || job.IsClosed || job.IsInvalid) {
            throw new InvalidOperationException("job handle is not available");
        }

        SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES {
            Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)),
            SecurityDescriptor = IntPtr.Zero,
            InheritHandle = true,
        };
        SafeFileHandle stdoutRead = null, stdoutWrite = null;
        SafeFileHandle stderrRead = null, stderrWrite = null;
        SafeFileHandle stdinRead = null, stdinWrite = null;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr handleList = IntPtr.Zero;
        IntPtr jobList = IntPtr.Zero;
        IntPtr environment = IntPtr.Zero;
        PROCESS_INFORMATION processInformation = new PROCESS_INFORMATION();
        Process managedProcess = null;
        FileStream stdinStream = null;
        FileStream stdoutStream = null;
        FileStream stderrStream = null;
        try {
            if (!CreatePipe(out stdinRead, out stdinWrite, ref attributes, 0) ||
                !SetHandleInformation(stdinWrite, HANDLE_FLAG_INHERIT, 0) ||
                !CreatePipe(out stdoutRead, out stdoutWrite, ref attributes, 0) ||
                !SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) ||
                !CreatePipe(out stderrRead, out stderrWrite, ref attributes, 0) ||
                !SetHandleInformation(stderrRead, HANDLE_FLAG_INHERIT, 0)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            UIntPtr attributeBytes = UIntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeBytes);
            if (attributeBytes == UIntPtr.Zero) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            attributeList = Marshal.AllocHGlobal(checked((int)attributeBytes.ToUInt64()));
            if (!InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeBytes)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
            Marshal.WriteIntPtr(handleList, 0, stdinRead.DangerousGetHandle());
            Marshal.WriteIntPtr(handleList, IntPtr.Size, stdoutWrite.DangerousGetHandle());
            Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderrWrite.DangerousGetHandle());
            if (!UpdateProcThreadAttribute(attributeList, 0,
                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList,
                    new UIntPtr(checked((uint)(IntPtr.Size * 3))), IntPtr.Zero, IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            jobList = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(jobList, job.DangerousGetHandle());
            if (!UpdateProcThreadAttribute(attributeList, 0,
                    PROC_THREAD_ATTRIBUTE_JOB_LIST, jobList, new UIntPtr((uint)IntPtr.Size),
                    IntPtr.Zero, IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            string[] sortedEnvironment = (string[])environmentEntries.Clone();
            Array.Sort(sortedEnvironment, StringComparer.OrdinalIgnoreCase);
            byte[] environmentBytes = Encoding.Unicode.GetBytes(
                String.Join("\0", sortedEnvironment) + "\0\0");
            try {
                environment = Marshal.AllocHGlobal(environmentBytes.Length);
                Marshal.Copy(environmentBytes, 0, environment, environmentBytes.Length);
            } finally {
                Array.Clear(environmentBytes, 0, environmentBytes.Length);
            }

            StringBuilder commandLine = new StringBuilder(QuoteArgument(filePath));
            foreach (string argument in arguments) {
                commandLine.Append(' ').Append(QuoteArgument(argument));
            }
            STARTUPINFOEX startup = new STARTUPINFOEX();
            startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
            startup.StartupInfo.dwFlags = checked((int)STARTF_USESTDHANDLES);
            startup.StartupInfo.hStdInput = stdinRead.DangerousGetHandle();
            startup.StartupInfo.hStdOutput = stdoutWrite.DangerousGetHandle();
            startup.StartupInfo.hStdError = stderrWrite.DangerousGetHandle();
            startup.AttributeList = attributeList;
            if (!CreateProcessW(filePath, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW,
                    environment, Path.GetDirectoryName(filePath), ref startup,
                    out processInformation)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            managedProcess = Process.GetProcessById(checked((int)processInformation.ProcessId));
            if (!IsProcessAssigned(job, managedProcess.Handle)) {
                throw new InvalidOperationException("created process is not in expected job");
            }
            stdoutWrite.Dispose(); stdoutWrite = null;
            stderrWrite.Dispose(); stderrWrite = null;
            stdinRead.Dispose(); stdinRead = null;
            stdinStream = new FileStream(stdinWrite, FileAccess.Write, 4096, false);
            stdinWrite = null;
            stdoutStream = new FileStream(stdoutRead, FileAccess.Read, 4096, false);
            stdoutRead = null;
            stderrStream = new FileStream(stderrRead, FileAccess.Read, 4096, false);
            stderrRead = null;
            TL1C1bStartedProcess result =
                new TL1C1bStartedProcess(managedProcess, stdinStream, stdoutStream, stderrStream);
            managedProcess = null;
            stdinStream = null;
            stdoutStream = null;
            stderrStream = null;
            return result;
        } finally {
            if (processInformation.Thread != IntPtr.Zero) CloseHandle(processInformation.Thread);
            if (processInformation.Process != IntPtr.Zero) CloseHandle(processInformation.Process);
            if (stdinStream != null) stdinStream.Dispose();
            if (stdoutStream != null) stdoutStream.Dispose();
            if (stderrStream != null) stderrStream.Dispose();
            if (managedProcess != null) managedProcess.Dispose();
            if (attributeList != IntPtr.Zero) DeleteProcThreadAttributeList(attributeList);
            if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
            if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
            if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            if (stdinRead != null) stdinRead.Dispose();
            if (stdinWrite != null) stdinWrite.Dispose();
            if (stdoutRead != null) stdoutRead.Dispose();
            if (stdoutWrite != null) stdoutWrite.Dispose();
            if (stderrRead != null) stderrRead.Dispose();
            if (stderrWrite != null) stderrWrite.Dispose();
            GC.KeepAlive(job);
        }
    }

    public static TL1C1bTcpListenerOwner[] GetTcp4Listeners(int requestedPort) {
        if (requestedPort < 1 || requestedPort > 65535) {
            throw new ArgumentOutOfRangeException(nameof(requestedPort));
        }
        int size = 0;
        IntPtr buffer = IntPtr.Zero;
        try {
            bool complete = false;
            for (int attempt = 0; attempt < 5; attempt++) {
                uint result = GetExtendedTcpTable(buffer, ref size, false, AF_INET,
                                                  TCP_TABLE_OWNER_PID_LISTENER, 0);
                if (result == NO_ERROR && buffer != IntPtr.Zero) {
                    complete = true;
                    break;
                }
                if (result != ERROR_INSUFFICIENT_BUFFER || size < sizeof(uint) ||
                    size > 64 * 1024 * 1024) {
                    throw new Win32Exception((int)result);
                }
                if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                buffer = Marshal.AllocHGlobal(size);
            }
            if (!complete) throw new Win32Exception((int)ERROR_INSUFFICIENT_BUFFER);
            int count = Marshal.ReadInt32(buffer);
            int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
            long required = sizeof(uint) + checked((long)count * rowSize);
            if (count < 0 || required > size) {
                throw new InvalidDataException("TCP owner table is truncated");
            }
            List<TL1C1bTcpListenerOwner> listeners =
                new List<TL1C1bTcpListenerOwner>();
            long offset = sizeof(uint);
            for (int index = 0; index < count; index++, offset += rowSize) {
                MIB_TCPROW_OWNER_PID row = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(
                    new IntPtr(buffer.ToInt64() + offset), typeof(MIB_TCPROW_OWNER_PID));
                byte[] portBytes = BitConverter.GetBytes(row.LocalPort);
                int port = (portBytes[0] << 8) | portBytes[1];
                if (row.State != MIB_TCP_STATE_LISTEN || port != requestedPort) continue;
                byte[] addressBytes = BitConverter.GetBytes(row.LocalAddress);
                listeners.Add(new TL1C1bTcpListenerOwner {
                    Address = new IPAddress(addressBytes).ToString(),
                    Port = port,
                    ProcessId = checked((int)row.OwningPid),
                });
            }
            return listeners.ToArray();
        } finally {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

if ($null -eq (Get-Variable -Name TL1C1bPrivateAdbGuardStates -Scope Script `
        -ErrorAction SilentlyContinue)) {
    $script:TL1C1bPrivateAdbGuardStates =
        [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
}
$script:TL1C1bPrivateAdbGuardIdProperty =
    [TL1C1bPrivateAdbGuardHandle].GetProperty('Id')
$script:TL1C1bPrivateAdbGuardMarkDisposedMethod =
    [TL1C1bPrivateAdbGuardHandle].GetMethod(
        'MarkDisposed',
        [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic)

function Test-TL1C1bPrivateAdbGuardWrapperUnchanged {
    param(
        [Parameter(Mandatory)]$Guard,
        [Parameter(Mandatory)]$State
    )

    if ($Guard -isnot [TL1C1bPrivateAdbGuardHandle] -or
        -not [object]::ReferenceEquals($Guard, $State.Handle)) {
        return $false
    }
    $properties = @($Guard.PSObject.Properties)
    return $properties.Count -eq 2 -and
        @($properties | Where-Object {
            $_.MemberType -ne [Management.Automation.PSMemberTypes]::Property -or
            $_.Name -cnotin @('Id','Disposed')
        }).Count -eq 0
}

function Get-TL1C1bPrivateAdbGuardState {
    param(
        [Parameter(Mandatory)]$Guard,
        [switch]$AllowDisposed,
        [switch]$AllowWrapperMutation
    )

    if ($Guard -isnot [TL1C1bPrivateAdbGuardHandle]) {
        throw 'C1b private adb server guard type 无效。'
    }
    $id = [string]$script:TL1C1bPrivateAdbGuardIdProperty.GetValue($Guard)
    $state = $null
    if ([string]::IsNullOrWhiteSpace($id) -or
        -not $script:TL1C1bPrivateAdbGuardStates.TryGetValue($id, [ref]$state) -or
        -not [object]::ReferenceEquals($Guard, $state.Handle)) {
        throw 'C1b private adb server guard identity 无效。'
    }
    if (-not $AllowWrapperMutation -and
        -not (Test-TL1C1bPrivateAdbGuardWrapperUnchanged $Guard $state)) {
        throw 'C1b private adb server guard wrapper 漂移。'
    }
    if (-not $AllowDisposed -and ([bool]$state.Disposed -or [bool]$Guard.Disposed)) {
        throw 'C1b private adb server guard 已关闭。'
    }
    return $state
}

function Set-TL1C1bPrivateAdbGuardDisposed {
    param(
        [Parameter(Mandatory)]$Guard,
        [Parameter(Mandatory)]$State
    )

    $State.Disposed = $true
    [void]$script:TL1C1bPrivateAdbGuardMarkDisposedMethod.Invoke($Guard, @())
}

function Test-TL1C1bPrivateAdbBindingCanonical {
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$State
    )

    $properties = @($Binding.PSObject.Properties)
    return $Binding -is [TL1C1bPrivateAdbBinding] -and
        $properties.Count -eq 9 -and
        @($properties | Where-Object {
            $_.MemberType -ne [Management.Automation.PSMemberTypes]::Property
        }).Count -eq 0 -and
        $Binding.schema -ceq $script:TL1C1bPrivateAdbServerSchema -and
        $Binding.server_mode -ceq 'private_nodaemon' -and
        $Binding.server_socket -ceq [string]$State.ServerSocket -and
        $Binding.server_executable_sha256 -ceq [string]$State.AdbExecutableSha256 -and
        [bool]$Binding.job_kill_on_close -and
        [bool]$Binding.listener_pid_verified -and
        [bool]$Binding.server_status_executable_path_verified -and
        [bool]$Binding.server_ready_verified -and
        -not [bool]$Binding.default_server_used
}

function Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged {
    param([Parameter(Mandatory)]$State)

    foreach ($binding in $State.IssuedBindings) {
        if (-not (Test-TL1C1bPrivateAdbBindingCanonical $binding $State)) {
            throw 'C1b private adb issued Binding 漂移。'
        }
    }
}

function New-TL1C1bPrivateAdbBindingCopy {
    param([Parameter(Mandatory)]$State)

    Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $State
    $binding = [TL1C1bPrivateAdbBinding]::new(
        $script:TL1C1bPrivateAdbServerSchema,
        [string]$State.ServerSocket,
        [string]$State.AdbExecutableSha256)
    $State.IssuedBindings.Add($binding)
    return $binding
}

function Test-TL1C1bPrivateAdbCleanupBindingCanonical {
    param(
        [Parameter(Mandatory)]$Binding,
        [Parameter(Mandatory)]$State
    )

    $properties = @($Binding.PSObject.Properties)
    return $Binding -is [TL1C1bPrivateAdbCleanupBinding] -and
        $properties.Count -eq 5 -and
        @($properties | Where-Object {
            $_.MemberType -ne [Management.Automation.PSMemberTypes]::Property
        }).Count -eq 0 -and
        [bool]$Binding.server_cleanup_verified -and
        [bool]$Binding.private_kill_server_requested -eq [bool]$State.PrivateKillRequested -and
        [bool]$Binding.graceful_exit_verified -eq [bool]$State.GracefulExitVerified -and
        [bool]$Binding.job_fallback_used -eq [bool]$State.JobFallbackUsed -and
        [bool]$Binding.port_rebind_verified
}

function Assert-TL1C1bPrivateAdbIssuedCleanupBindingsUnchanged {
    param([Parameter(Mandatory)]$State)

    foreach ($binding in $State.IssuedCleanupBindings) {
        if (-not (Test-TL1C1bPrivateAdbCleanupBindingCanonical $binding $State)) {
            throw 'C1b private adb issued CleanupBinding 漂移。'
        }
    }
}

function New-TL1C1bPrivateAdbCleanupBindingCopy {
    param([Parameter(Mandatory)]$State)

    Assert-TL1C1bPrivateAdbIssuedCleanupBindingsUnchanged $State
    $binding = [TL1C1bPrivateAdbCleanupBinding]::new(
        [bool]$State.PrivateKillRequested,
        [bool]$State.GracefulExitVerified,
        [bool]$State.JobFallbackUsed)
    $State.IssuedCleanupBindings.Add($binding)
    return $binding
}

function Get-TL1C1bPrivateAdbSha256Stream {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $position = $Stream.Position
    try {
        $Stream.Position = 0
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Stream)).ToLowerInvariant()
    } finally { $Stream.Position = $position }
}

function Get-TL1C1bPrivateAdbEnvironmentFingerprint {
    param([Parameter(Mandatory)][Collections.IDictionary]$Environment)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Environment.GetEnumerator()) {
        $name = [string]$entry.Key
        $value = [string]$entry.Value
        $lines.Add(('{0}:{1}{2}:{3}' -f $name.Length, $name, $value.Length, $value))
    }
    $values = [string[]]$lines.ToArray()
    [Array]::Sort($values, [StringComparer]::OrdinalIgnoreCase)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($values -join "`n")
    try {
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    } finally { if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Resolve-TL1C1bPrivateAdbExecutable {
    param([Parameter(Mandatory)][string]$AdbPath)

    if (-not [OperatingSystem]::IsWindows()) {
        throw 'C1b private adb server guard 只接受 Windows。'
    }
    if (-not [IO.Path]::IsPathFullyQualified($AdbPath)) {
        throw 'C1b private adb executable 必须是绝对路径。'
    }
    $full = [IO.Path]::GetFullPath($AdbPath)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$item.LinkType) -or
        [IO.Path]::GetFileName($full) -cne 'adb.exe' -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath($item.FullName), $full)) {
        throw 'C1b private adb executable 必须是 canonical ordinary adb.exe。'
    }
    $directory = [IO.DirectoryInfo]$item.Directory
    while ($null -ne $directory) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$directory.LinkType)) {
            throw 'C1b private adb executable path chain 不得含 reparse/link directory。'
        }
        $directory = $directory.Parent
    }
    return $full
}

function New-TL1C1bPrivateAdbEnvironment {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$ProcessEnvironment,
        [Parameter(Mandatory)][string]$ServerSocket
    )

    $match = [regex]::Match(
        $ServerSocket,
        '\Atcp:127\.0\.0\.1:([0-9]{5})\z',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    $port = 0
    if (-not $match.Success -or
        -not [int]::TryParse(
            $match.Groups[1].Value,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$port) -or
        $port -lt $script:TL1C1bPrivateAdbMinimumPort -or
        $port -ge $script:TL1C1bPrivateAdbMaximumPortExclusive -or
        $ServerSocket -cne "tcp:$($script:TL1C1bPrivateAdbHost):$port") {
        throw 'C1b private adb server socket 不在 loopback/high-port allowlist。'
    }
    $environment = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $ProcessEnvironment.GetEnumerator()) {
        $name = [string]$entry.Key
        $value = [string]$entry.Value
        if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
            $name.IndexOf([char]0) -ge 0 -or $value.IndexOf([char]0) -ge 0 -or
            $value.IndexOf("`r") -ge 0 -or $value.IndexOf("`n") -ge 0) {
            throw 'C1b private adb child environment 含非法 name/value。'
        }
        if ($name -imatch '^(?:ADB_|ANDROID_ADB_SERVER_|ANDROID_SERIAL$)') { continue }
        if ($environment.ContainsKey($name)) {
            throw 'C1b private adb child environment 含大小写重复 name。'
        }
        $environment[$name] = $value
    }
    $environment['ADB_SERVER_SOCKET'] = $ServerSocket
    return $environment
}

function Copy-TL1C1bPrivateAdbEnvironment {
    param([Parameter(Mandatory)][Collections.IDictionary]$Environment)

    $copy = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Environment.GetEnumerator()) {
        $copy[[string]$entry.Key] = [string]$entry.Value
    }
    return $copy
}

function Get-TL1C1bPrivateAdbRandomHighPortCandidate {
    return [Security.Cryptography.RandomNumberGenerator]::GetInt32(
        $script:TL1C1bPrivateAdbMinimumPort,
        $script:TL1C1bPrivateAdbMaximumPortExclusive)
}

function Test-TL1C1bPrivateAdbPortAvailable {
    param([Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port)

    $socket = [Net.Sockets.Socket]::new(
        [Net.Sockets.AddressFamily]::InterNetwork,
        [Net.Sockets.SocketType]::Stream,
        [Net.Sockets.ProtocolType]::Tcp)
    try {
        $socket.ExclusiveAddressUse = $true
        $socket.SetSocketOption(
            [Net.Sockets.SocketOptionLevel]::Socket,
            [Net.Sockets.SocketOptionName]::ReuseAddress,
            $false)
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, $Port))
        $socket.Listen(1)
        return $true
    } catch [Net.Sockets.SocketException] { return $false }
    finally { $socket.Dispose() }
}

function Get-TL1C1bPrivateAdbListenerOwners {
    param([Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port)

    return [object[]]@([TL1C1bPrivateAdbNative]::GetTcp4Listeners($Port))
}

function Test-TL1C1bPrivateAdbListenerOwned {
    param(
        [Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ProcessId
    )

    $owners = @(Get-TL1C1bPrivateAdbListenerOwners $Port)
    return $owners.Count -eq 1 -and
        [string]$owners[0].Address -ceq $script:TL1C1bPrivateAdbHost -and
        [int]$owners[0].ProcessId -eq $ProcessId
}

function ConvertFrom-TL1C1bPrivateAdbProtoString {
    param([Parameter(Mandatory)][string]$QuotedValue)

    if ($QuotedValue.Length -lt 2 -or $QuotedValue[0] -cne '"' -or
        $QuotedValue[$QuotedValue.Length - 1] -cne '"') {
        throw 'C1b private adb server-status string grammar 无效。'
    }
    $body = $QuotedValue.Substring(1, $QuotedValue.Length - 2)
    $bytes = [Collections.Generic.List[byte]]::new()
    for ($index = 0; $index -lt $body.Length; $index++) {
        $character = $body[$index]
        if ($character -cne '\') {
            if ([char]::IsControl($character)) {
                throw 'C1b private adb server-status string 含控制字符。'
            }
            $length = 1
            if ([char]::IsHighSurrogate($character) -and
                $index + 1 -lt $body.Length -and [char]::IsLowSurrogate($body[$index + 1])) {
                $length = 2
            }
            $encoded = [Text.Encoding]::UTF8.GetBytes($body.Substring($index, $length))
            try { foreach ($value in $encoded) { $bytes.Add($value) } }
            finally { if ($encoded.Length -ne 0) { [Array]::Clear($encoded, 0, $encoded.Length) } }
            $index += $length - 1
            continue
        }
        if (++$index -ge $body.Length) {
            throw 'C1b private adb server-status string escape 截断。'
        }
        $escape = $body[$index]
        $simple = switch ($escape) {
            'a' { 7 } 'b' { 8 } 'f' { 12 } 'n' { 10 } 'r' { 13 } 't' { 9 }
            'v' { 11 } '\' { 92 } '"' { 34 } "'" { 39 } '?' { 63 }
            default { $null }
        }
        if ($null -ne $simple) { $bytes.Add([byte]$simple); continue }
        if ($escape -ceq 'x') {
            $digits = ''
            while ($index + 1 -lt $body.Length -and $digits.Length -lt 2 -and
                $body[$index + 1] -cmatch '^[0-9A-Fa-f]$') {
                $index++; $digits += $body[$index]
            }
            if ($digits.Length -eq 0) { throw 'C1b private adb server-status hex escape 无效。' }
            $bytes.Add([Convert]::ToByte($digits, 16)); continue
        }
        if ($escape -cmatch '^[0-7]$') {
            $digits = [string]$escape
            while ($index + 1 -lt $body.Length -and $digits.Length -lt 3 -and
                $body[$index + 1] -cmatch '^[0-7]$') {
                $index++; $digits += $body[$index]
            }
            $number = [Convert]::ToInt32($digits, 8)
            if ($number -gt 255) { throw 'C1b private adb server-status octal escape 越界。' }
            $bytes.Add([byte]$number); continue
        }
        throw 'C1b private adb server-status string escape 不在 allowlist。'
    }
    $array = $bytes.ToArray()
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($array) }
    catch { throw 'C1b private adb server-status string 不是 strict UTF-8。' }
    finally { if ($array.Length -ne 0) { [Array]::Clear($array, 0, $array.Length) } }
}

function Assert-TL1C1bPrivateAdbServerStatus {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExpectedExecutablePath,
        [Parameter(Mandatory)][string]$ExpectedFileIdentity
    )

    if ($Text.Length -notin 1..65536) {
        throw 'C1b private adb server-status byte/text length 越界。'
    }
    $lines = @($Text -split '\r?\n')
    if ($lines.Count -gt 32) { throw 'C1b private adb server-status 行数越界。' }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Length -eq 0) {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    if ($lines.Count -eq 0 -or @($lines | Where-Object { $_.Length -eq 0 }).Count -ne 0) {
        throw 'C1b private adb server-status 不得含空记录。'
    }
    $stringFields = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('version','build','executable_absolute_path','log_absolute_path','os','trace_level'),
        [StringComparer]::Ordinal)
    $booleanFields = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('usb_backend_forced','mdns_backend_forced','burst_mode','mdns_enabled'),
        [StringComparer]::Ordinal)
    $enumFields = [Collections.Generic.HashSet[string]]::new(
        [string[]]@('usb_backend','mdns_backend'), [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $reportedExecutable = $null
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^([a-z][a-z0-9_]{0,63}): (.+)$')
        if (-not $match.Success) { throw 'C1b private adb server-status field grammar 无效。' }
        $name = $match.Groups[1].Value
        $value = $match.Groups[2].Value
        if (-not $seen.Add($name)) { throw 'C1b private adb server-status field 重复。' }
        if ($stringFields.Contains($name)) {
            if ($value -cnotmatch '^"(?:[^"\\\x00-\x1f]|\\(?:[abfnrtv\\"''?]|[0-7]{1,3}|x[0-9A-Fa-f]{1,2}))*"$') {
                throw 'C1b private adb server-status quoted field grammar 无效。'
            }
            if ($name -ceq 'executable_absolute_path') {
                $reportedExecutable = ConvertFrom-TL1C1bPrivateAdbProtoString $value
            }
        } elseif ($booleanFields.Contains($name)) {
            if ($value -cnotin @('true','false')) {
                throw 'C1b private adb server-status bool field grammar 无效。'
            }
        } elseif ($enumFields.Contains($name)) {
            if ($name -ceq 'usb_backend' -and $value -cnotin @('UNKNOWN_USB','NATIVE','LIBUSB')) {
                throw 'C1b private adb server-status usb enum 无效。'
            }
            if ($name -ceq 'mdns_backend' -and $value -cnotin @('UNKNOWN_MDNS','BONJOUR','OPENSCREEN')) {
                throw 'C1b private adb server-status mdns enum 无效。'
            }
        } else { throw 'C1b private adb server-status 出现未知字段。' }
    }
    if ([string]::IsNullOrWhiteSpace($reportedExecutable) -or
        -not [IO.Path]::IsPathFullyQualified($reportedExecutable)) {
        throw 'C1b private adb server-status 缺少绝对 executable_absolute_path。'
    }
    $reportedCanonical = Resolve-TL1C1bPrivateAdbExecutable $reportedExecutable
    $expectedCanonical = Resolve-TL1C1bPrivateAdbExecutable $ExpectedExecutablePath
    if ($reportedExecutable -cne $reportedCanonical -or
        $expectedCanonical -cne $reportedCanonical) {
        throw 'C1b private adb server-status executable_absolute_path 未绑定 held adb。'
    }
    $reportedGuard = [IO.File]::Open(
        $reportedCanonical, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ([TL1C1bPrivateAdbNative]::GetFileIdentity($reportedGuard.SafeFileHandle) -cne
            $ExpectedFileIdentity) {
            throw 'C1b private adb server-status executable file identity 未绑定 held adb。'
        }
    } finally { $reportedGuard.Dispose() }
    return $true
}

function ConvertFrom-TL1C1bPrivateAdbStrictUtf8 {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and
        $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        throw "C1b private adb $Name 含 UTF-8 BOM。"
    }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw "C1b private adb $Name 不是 strict UTF-8。" }
}

function ConvertTo-TL1C1bPrivateAdbEnvironmentEntries {
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )

    $entries = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Environment.GetEnumerator()) {
        $entries.Add("$([string]$entry.Key)=$([string]$entry.Value)")
    }
    return [string[]]$entries.ToArray()
}

function Wait-TL1C1bPrivateAdbEndpointContained {
    param(
        [Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ExpectedProcessId,
        [ValidateRange(100, 5000)][int]$TimeoutMs = 2000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        try {
            if (Test-TL1C1bPrivateAdbListenerOwned $Port $ExpectedProcessId) {
                return 'held'
            }
            $owners = @(Get-TL1C1bPrivateAdbListenerOwners $Port)
            if ($owners.Count -eq 0 -and (Test-TL1C1bPrivateAdbPortAvailable $Port)) {
                return 'reusable'
            }
        } catch { }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'C1b private adb client cleanup 后 endpoint 未受控。'
}

function Invoke-TL1C1bPrivateAdbClientCommand {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ExpectedServerProcessId,
        [Parameter(Mandatory)][ValidateSet('server-status','kill-server')][string]$Command,
        [Parameter(Mandatory)][ValidateRange(1, 10)][int]$TimeoutSec,
        [Parameter(Mandatory)][ValidateRange(4096, 1048576)][int]$MaximumOutputBytes
    )

    $arguments = [string[]]@('-H', $script:TL1C1bPrivateAdbHost, '-P',
        $Port.ToString([Globalization.CultureInfo]::InvariantCulture), $Command)
    $stdout = [TL1C1bBoundedWriteStream]::new($MaximumOutputBytes)
    $stderr = [TL1C1bBoundedWriteStream]::new($MaximumOutputBytes)
    $job = $null
    $started = $null
    $stdoutTask = $null
    $stderrTask = $null
    $resultText = $null
    $failed = $false
    $failureCategory = 'unknown'
    try {
        $failureCategory = 'create-job'
        $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob(1)
        $failureCategory = 'start'
        $started = [TL1C1bPrivateAdbNative]::StartInJob(
            $AdbPath,
            $arguments,
            (ConvertTo-TL1C1bPrivateAdbEnvironmentEntries $Environment),
            $job)
        $started.StandardInput.Dispose()
        if (-not [TL1C1bPrivateAdbNative]::IsProcessAssigned(
                $job, $started.Process.Handle)) {
            throw 'client job membership failed'
        }
        $failureCategory = 'execute'
        $stdoutTask = $started.StandardOutput.CopyToAsync($stdout)
        $stderrTask = $started.StandardError.CopyToAsync($stderr)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $started.Process.HasExited) {
            if ($stdout.Overflowed -or $stderr.Overflowed) { throw 'client output overflow' }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw 'client timeout' }
            Start-Sleep -Milliseconds 10
        }
        if (-not $stdoutTask.Wait(1000) -or -not $stderrTask.Wait(1000)) {
            throw 'client stream drain timeout'
        }
        if ($stdout.Overflowed -or $stderr.Overflowed -or $started.Process.ExitCode -ne 0) {
            throw 'client failed'
        }
        $stdoutBytes = $stdout.Snapshot()
        $stderrBytes = $stderr.Snapshot()
        try {
            if ($stderrBytes.Length -ne 0) { throw 'client stderr not empty' }
            $resultText = ConvertFrom-TL1C1bPrivateAdbStrictUtf8 `
                $stdoutBytes "$Command stdout"
        } finally {
            if ($stdoutBytes.Length -ne 0) { [Array]::Clear($stdoutBytes, 0, $stdoutBytes.Length) }
            if ($stderrBytes.Length -ne 0) { [Array]::Clear($stderrBytes, 0, $stderrBytes.Length) }
        }
        $failureCategory = 'none'
    } catch { $failed = $true }
    finally {
        if ($null -ne $job) {
            try { $job.Dispose() } catch { $failed = $true }
        }
        if ($null -ne $started) {
            try {
                if (-not $started.Process.HasExited -and
                    -not $started.Process.WaitForExit(2000)) {
                    $started.Process.Kill($true)
                    if (-not $started.Process.WaitForExit(2000)) { $failed = $true }
                }
            } catch { $failed = $true }
        }
        foreach ($task in @($stdoutTask, $stderrTask)) {
            if ($null -ne $task) {
                try { if (-not $task.Wait(1000)) { $failed = $true } }
                catch { $failed = $true }
            }
        }
        try {
            [void](Wait-TL1C1bPrivateAdbEndpointContained `
                $Port $ExpectedServerProcessId -TimeoutMs 2000)
        } catch { $failed = $true }
        if ($null -ne $started) { try { $started.Dispose() } catch { $failed = $true } }
        try { $stdout.Dispose() } catch { $failed = $true }
        try { $stderr.Dispose() } catch { $failed = $true }
    }
    if ($failed) {
        throw "C1b private adb $Command client 失败 ($failureCategory)。"
    }
    return $resultText
}

function Start-TL1C1bPrivateAdbServerAttempt {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory)][ValidateRange(49152, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(4096, 1048576)][int]$MaximumOutputBytes
    )

    $socket = "tcp:$($script:TL1C1bPrivateAdbHost):$Port"
    $arguments = [string[]]@('-L', $socket, 'server', 'nodaemon')
    $stdout = [TL1C1bBoundedWriteStream]::new($MaximumOutputBytes)
    $stderr = [TL1C1bBoundedWriteStream]::new($MaximumOutputBytes)
    $job = $null
    $started = $null
    $stdoutTask = $null
    $stderrTask = $null
    $failureCategory = 'create-job'
    try {
        $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob(1)
        $failureCategory = 'start'
        $started = [TL1C1bPrivateAdbNative]::StartInJob(
            $AdbPath,
            $arguments,
            (ConvertTo-TL1C1bPrivateAdbEnvironmentEntries $Environment),
            $job)
        $started.StandardInput.Dispose()
        if (-not [TL1C1bPrivateAdbNative]::IsProcessAssigned(
                $job, $started.Process.Handle) -or $started.Process.HasExited) {
            throw 'server atomic job membership failed'
        }
        $failureCategory = 'stream-drain'
        $stdoutTask = $started.StandardOutput.CopyToAsync($stdout)
        $stderrTask = $started.StandardError.CopyToAsync($stderr)
        return [pscustomobject][ordered]@{
            StartedProcess = $started
            Process = $started.Process
            ProcessId = [int]$started.Process.Id
            Job = $job
            Stdout = $stdout
            Stderr = $stderr
            StdoutTask = $stdoutTask
            StderrTask = $stderrTask
            Port = $Port
            Socket = $socket
        }
    } catch {
        if ($null -ne $job) { try { $job.Dispose() } catch { } }
        if ($null -ne $started) {
            try {
                if (-not $started.Process.HasExited) {
                    $started.Process.Kill($true)
                    [void]$started.Process.WaitForExit(2000)
                }
            } catch { }
        }
        foreach ($task in @($stdoutTask, $stderrTask)) {
            if ($null -ne $task) { try { [void]$task.Wait(1000) } catch { } }
        }
        if ($null -ne $started) { try { $started.Dispose() } catch { } }
        try { $stdout.Dispose() } catch { }
        try { $stderr.Dispose() } catch { }
        throw "C1b private adb server process/job 启动失败 ($failureCategory)。"
    }
}

function Stop-TL1C1bPrivateAdbServerAttempt {
    param([AllowNull()]$Attempt)

    if ($null -eq $Attempt) { return }
    $failed = $false
    if ($null -ne $Attempt.Job) {
        try { $Attempt.Job.Dispose() } catch { $failed = $true }
        $Attempt.Job = $null
    }
    try {
        if (-not $Attempt.Process.HasExited) {
            if (-not $Attempt.Process.WaitForExit(2000)) {
                $Attempt.Process.Kill($true)
                if (-not $Attempt.Process.WaitForExit(2000)) { $failed = $true }
            }
        }
    } catch { $failed = $true }
    foreach ($task in @($Attempt.StdoutTask, $Attempt.StderrTask)) {
        if ($null -ne $task) {
            try { if (-not $task.Wait(1000)) { $failed = $true } }
            catch { $failed = $true }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    $portReusable = $false
    do {
        try {
            if (Test-TL1C1bPrivateAdbPortAvailable $Attempt.Port) {
                $portReusable = $true; break
            }
        } catch { }
        Start-Sleep -Milliseconds 25
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $portReusable) { $failed = $true }
    try { $Attempt.StartedProcess.Dispose() } catch { $failed = $true }
    try { $Attempt.Stdout.Dispose() } catch { $failed = $true }
    try { $Attempt.Stderr.Dispose() } catch { $failed = $true }
    if ($failed) {
        throw 'C1b private adb failed server attempt 未完整回收。'
    }
}

function Open-TL1C1bPrivateAdbServerGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][Collections.IDictionary]$ProcessEnvironment,
        [ValidateRange(1, 30)][int]$StartupTimeoutSec = 15,
        [ValidateRange(1, 10)][int]$ClientTimeoutSec = 3,
        [ValidateRange(1, 32)][int]$PortAttemptCount = 12,
        [ValidateRange(4096, 1048576)][int]$MaximumOutputBytes = 65536
    )

    $canonicalAdb = Resolve-TL1C1bPrivateAdbExecutable $AdbPath
    $executableGuard = [IO.File]::Open(
        $canonicalAdb, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $attempt = $null
    try {
        $executableSha256 = Get-TL1C1bPrivateAdbSha256Stream $executableGuard
        $executableIdentity =
            [TL1C1bPrivateAdbNative]::GetFileIdentity($executableGuard.SafeFileHandle)
        $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSec)
        $portsTried = [Collections.Generic.HashSet[int]]::new()
        for ($portAttempt = 0; $portAttempt -lt $PortAttemptCount -and
            [DateTime]::UtcNow -lt $deadline; $portAttempt++) {
            $port = 0
            for ($candidateAttempt = 0; $candidateAttempt -lt 64 -and
                [DateTime]::UtcNow -lt $deadline; $candidateAttempt++) {
                $candidate = Get-TL1C1bPrivateAdbRandomHighPortCandidate
                if ($portsTried.Add($candidate)) { $port = $candidate; break }
            }
            if ($port -eq 0) { break }
            if (-not (Test-TL1C1bPrivateAdbPortAvailable $port)) { continue }
            $socket = "tcp:$($script:TL1C1bPrivateAdbHost):$port"
            $environment = New-TL1C1bPrivateAdbEnvironment $ProcessEnvironment $socket
            try {
                $attempt = Start-TL1C1bPrivateAdbServerAttempt `
                    $canonicalAdb $environment $port $MaximumOutputBytes
            } catch { continue }

            $terminalFailure = $false
            while ([DateTime]::UtcNow -lt $deadline) {
                if ($attempt.Process.HasExited) { break }
                if ($attempt.Stdout.Overflowed -or $attempt.Stderr.Overflowed) {
                    $terminalFailure = $true; break
                }
                $owners = @(Get-TL1C1bPrivateAdbListenerOwners $port)
                if ($owners.Count -gt 0) {
                    if ($owners.Count -ne 1 -or
                        [string]$owners[0].Address -cne $script:TL1C1bPrivateAdbHost -or
                        [int]$owners[0].ProcessId -ne [int]$attempt.ProcessId) {
                        $terminalFailure = $true; break
                    }
                    try {
                        $status = Invoke-TL1C1bPrivateAdbClientCommand `
                            $canonicalAdb $environment $port $attempt.ProcessId 'server-status' `
                            $ClientTimeoutSec $MaximumOutputBytes
                    } catch {
                        if ($attempt.Process.HasExited) { break }
                        Start-Sleep -Milliseconds 50
                        continue
                    }
                    try {
                        [void](Assert-TL1C1bPrivateAdbServerStatus `
                            $status $canonicalAdb $executableIdentity)
                    } catch { $terminalFailure = $true; break }
                    if ($attempt.Process.HasExited -or
                        -not (Test-TL1C1bPrivateAdbListenerOwned $port $attempt.ProcessId)) {
                        $terminalFailure = $true; break
                    }
                    $handle = [TL1C1bPrivateAdbGuardHandle]::new(
                        [guid]::NewGuid().ToString('N'))
                    $state = [pscustomobject][ordered]@{
                        Handle = $handle
                        Schema = $script:TL1C1bPrivateAdbServerSchema
                        AdbPath = $canonicalAdb
                        AdbExecutableGuard = $executableGuard
                        AdbExecutableSha256 = $executableSha256
                        AdbExecutableIdentity = $executableIdentity
                        Host = $script:TL1C1bPrivateAdbHost
                        Port = [int]$port
                        ServerSocket = $socket
                        ClientEnvironment = $environment
                        ClientEnvironmentFingerprint =
                            Get-TL1C1bPrivateAdbEnvironmentFingerprint $environment
                        StartedProcess = $attempt.StartedProcess
                        Process = $attempt.Process
                        ProcessId = [int]$attempt.ProcessId
                        Job = $attempt.Job
                        Stdout = $attempt.Stdout
                        Stderr = $attempt.Stderr
                        StdoutTask = $attempt.StdoutTask
                        StderrTask = $attempt.StderrTask
                        IssuedBindings = [Collections.Generic.List[object]]::new()
                        IssuedCleanupBindings = [Collections.Generic.List[object]]::new()
                        Disposed = $false
                        CloseSucceeded = $false
                        PrivateKillRequested = $false
                        GracefulExitVerified = $false
                        JobFallbackUsed = $false
                        PortRebindVerified = $false
                    }
                    $script:TL1C1bPrivateAdbGuardStates.Add($handle.Id, $state)
                    $attempt = $null
                    $executableGuard = $null
                    return $handle
                }
                Start-Sleep -Milliseconds 25
            }
            try { Stop-TL1C1bPrivateAdbServerAttempt $attempt }
            finally { $attempt = $null }
            if ($terminalFailure) { throw 'C1b private adb server ownership/status proof 失败。' }
        }
        throw 'C1b private adb server 在有界时间内未 ready。'
    } catch {
        if ($null -ne $attempt) {
            try { Stop-TL1C1bPrivateAdbServerAttempt $attempt } catch { }
        }
        if ($null -ne $executableGuard) { try { $executableGuard.Dispose() } catch { } }
        throw
    }
}

function Assert-TL1C1bPrivateAdbServerStateUnchanged {
    param([Parameter(Mandatory)]$State)

    if ([bool]$State.Disposed -or $State.Process -isnot [Diagnostics.Process] -or
        $State.Job -isnot [Microsoft.Win32.SafeHandles.SafeFileHandle] -or
        $State.Job.IsClosed -or $State.Job.IsInvalid -or
        $State.AdbExecutableGuard -isnot [IO.FileStream] -or
        $State.AdbExecutableGuard.SafeFileHandle.IsClosed -or
        $State.AdbExecutableGuard.SafeFileHandle.IsInvalid) {
        throw 'C1b private adb server guard 已关闭或结构无效。'
    }
    if ($State.Schema -cne $script:TL1C1bPrivateAdbServerSchema -or
        $State.Host -cne $script:TL1C1bPrivateAdbHost -or
        [int]$State.Port -lt $script:TL1C1bPrivateAdbMinimumPort -or
        [int]$State.Port -ge $script:TL1C1bPrivateAdbMaximumPortExclusive -or
        $State.ServerSocket -cne "tcp:$($script:TL1C1bPrivateAdbHost):$($State.Port)" -or
        [string]$State.ClientEnvironment['ADB_SERVER_SOCKET'] -cne $State.ServerSocket -or
        (Get-TL1C1bPrivateAdbEnvironmentFingerprint $State.ClientEnvironment) -cne
            [string]$State.ClientEnvironmentFingerprint) {
        throw 'C1b private adb server endpoint/environment binding 漂移。'
    }
    if ($State.Process.HasExited -or [int]$State.Process.Id -ne [int]$State.ProcessId -or
        -not [TL1C1bPrivateAdbNative]::IsProcessAssigned(
            $State.Job, $State.Process.Handle) -or
        $State.Stdout.Overflowed -or $State.Stderr.Overflowed -or
        -not (Test-TL1C1bPrivateAdbListenerOwned $State.Port $State.ProcessId)) {
        throw 'C1b private adb server process/listener binding 漂移。'
    }
    if ((Get-TL1C1bPrivateAdbSha256Stream $State.AdbExecutableGuard) -cne
            [string]$State.AdbExecutableSha256 -or
        [TL1C1bPrivateAdbNative]::GetFileIdentity(
            $State.AdbExecutableGuard.SafeFileHandle) -cne
            [string]$State.AdbExecutableIdentity) {
        throw 'C1b private adb held executable identity/hash 漂移。'
    }
    $current = [IO.File]::Open(
        [string]$State.AdbPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ((Get-TL1C1bPrivateAdbSha256Stream $current) -cne
                [string]$State.AdbExecutableSha256 -or
            [TL1C1bPrivateAdbNative]::GetFileIdentity($current.SafeFileHandle) -cne
                [string]$State.AdbExecutableIdentity) {
            throw 'C1b private adb current executable path/identity/hash 漂移。'
        }
    } finally { $current.Dispose() }
    return $true
}

function Assert-TL1C1bPrivateAdbServerGuardUnchanged {
    param([Parameter(Mandatory)]$Guard)

    $state = Get-TL1C1bPrivateAdbGuardState $Guard
    Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state
    [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
    return New-TL1C1bPrivateAdbBindingCopy $state
}

function Get-TL1C1bPrivateAdbClientEnvironment {
    param([Parameter(Mandatory)]$Guard)

    $state = Get-TL1C1bPrivateAdbGuardState $Guard
    Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state
    [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
    return Copy-TL1C1bPrivateAdbEnvironment $state.ClientEnvironment
}

function Get-TL1C1bPrivateAdbClientArguments {
    param([Parameter(Mandatory)]$Guard)

    $state = Get-TL1C1bPrivateAdbGuardState $Guard
    Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state
    [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
    return [string[]]@(
        '-H', $script:TL1C1bPrivateAdbHost,
        '-P', ([int]$state.Port).ToString([Globalization.CultureInfo]::InvariantCulture))
}

function Assert-TL1C1bPrivateAdbGuardedEnvironment {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][Collections.IDictionary]$ProcessEnvironment,
        [Parameter(Mandatory)][ValidateSet('Adb','T0Root')][string]$ClientKind,
        [Parameter(Mandatory)][string]$FilePath
    )

    $copy = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $ProcessEnvironment.GetEnumerator()) {
        $name = [string]$entry.Key
        $value = [string]$entry.Value
        if ($name -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
            $name.IndexOf([char]0) -ge 0 -or $value.IndexOf([char]0) -ge 0 -or
            $value.IndexOf("`r") -ge 0 -or $value.IndexOf("`n") -ge 0 -or
            $copy.ContainsKey($name)) {
            throw 'C1b guarded client environment 结构无效。'
        }
        $copy[$name] = $value
    }
    foreach ($entry in $State.ClientEnvironment.GetEnumerator()) {
        $name = [string]$entry.Key
        if (-not $copy.ContainsKey($name) -or
            [string]$copy[$name] -cne [string]$entry.Value) {
            throw 'C1b guarded client environment 未绑定 private server。'
        }
    }
    $extraNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $copy.Keys) {
        if (-not $State.ClientEnvironment.ContainsKey([string]$name)) {
            [void]$extraNames.Add([string]$name)
        }
    }
    if ($ClientKind -ceq 'Adb') {
        if ($extraNames.Count -ne 0 -or
            (Get-TL1C1bPrivateAdbEnvironmentFingerprint $copy) -cne
                [string]$State.ClientEnvironmentFingerprint) {
            throw 'C1b guarded adb environment 必须是 guard 的 exact copy。'
        }
        return $copy
    }

    $allowedExtras = [string[]]@(
        'TL1_C1A_PWSH_PATH',
        'TL1_C1A_T0_SIDECAR_SCRIPT',
        'TL1_C1A_REAL_ADB_PATH',
        'TL1_C1A_BOUND_SERIAL',
        'TL1_C1A_T0_LIBRARY_PATH',
        'TL1_C1A_DISPATCH_LOCK_LIBRARY',
        'AGENT_MOBILE_DEVICE_LOCK_LEASE'
    )
    if ($extraNames.Count -ne $allowedExtras.Count -or
        @($allowedExtras | Where-Object { -not $extraNames.Contains($_) }).Count -ne 0) {
        throw 'C1b guarded T0 environment 扩展字段集合漂移。'
    }
    if ([string]$copy['TL1_C1A_PWSH_PATH'] -cne $FilePath -or
        [string]$copy['TL1_C1A_REAL_ADB_PATH'] -cne [string]$State.AdbPath -or
        [string]$copy['TL1_C1A_BOUND_SERIAL'] -cnotmatch
            '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$' -or
        [string]::IsNullOrWhiteSpace([string]$copy['AGENT_MOBILE_DEVICE_LOCK_LEASE']) -or
        ([string]$copy['AGENT_MOBILE_DEVICE_LOCK_LEASE']).Length -gt 1024) {
        throw 'C1b guarded T0 environment identity binding 无效。'
    }
    foreach ($name in @(
            'TL1_C1A_PWSH_PATH','TL1_C1A_T0_SIDECAR_SCRIPT','TL1_C1A_REAL_ADB_PATH',
            'TL1_C1A_T0_LIBRARY_PATH','TL1_C1A_DISPATCH_LOCK_LIBRARY')) {
        $value = [string]$copy[$name]
        if (-not [IO.Path]::IsPathFullyQualified($value) -or
            [IO.Path]::GetFullPath($value) -cne $value -or
            -not (Test-Path -LiteralPath $value -PathType Leaf)) {
            throw 'C1b guarded T0 environment file binding 无效。'
        }
    }
    return $copy
}

function Test-TL1C1bPrivateAdbExactArgumentSequence {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) { return $false }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -cne $Expected[$index]) { return $false }
    }
    return $true
}

function Test-TL1C1bPrivateAdbBusinessContentUri {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][bool]$BinaryWrite
    )

    $uri = $Value
    if ($BinaryWrite) {
        if ($uri.IndexOf("'") -ge 0) { return $false }
    } else {
        if ($uri.Length -lt 3 -or $uri[0] -cne "'" -or
            $uri[$uri.Length - 1] -cne "'") { return $false }
        $uri = $uri.Substring(1, $uri.Length - 2)
        if ($uri.IndexOf("'") -ge 0) { return $false }
    }
    $authority = 'dev\.magina\.gateway\.tablet\.c1[ab]'
    $run = '[a-z0-9][a-z0-9._-]{0,79}'
    $nonce = 'n-[0-9a-f]{32}'
    $pattern = if ($BinaryWrite) {
        '^content://' + $authority + '/t0/' + $run + '\?nonce=' + $nonce +
        '&title_hash=sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c' +
        '&producer_commit_sha=[0-9a-f]{40}' +
        '&producer_artifact_sha256=sha256:[0-9a-f]{64}$'
    } else {
        '^content://' + $authority + '/(?:status|capture/c1|capture/c2|result|abort)/' +
        $run + '\?nonce=' + $nonce + '$'
    }
    return [regex]::IsMatch(
        $uri, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Assert-TL1C1bPrivateAdbGuardedSpecification {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][ValidateSet('Adb','T0Root')][string]$ClientKind,
        [Parameter(Mandatory)][Collections.IDictionary]$Environment
    )

    if (-not [IO.Path]::IsPathFullyQualified($FilePath) -or
        [IO.Path]::GetFullPath($FilePath) -cne $FilePath -or
        -not (Test-Path -LiteralPath $FilePath -PathType Leaf) -or
        @($Arguments | Where-Object {
            $null -eq $_ -or $_.IndexOf([char]0) -ge 0 -or
            $_.IndexOf("`r") -ge 0 -or $_.IndexOf("`n") -ge 0
        }).Count -ne 0) {
        throw 'C1b guarded client executable/argv 结构无效。'
    }
    if ($ClientKind -ceq 'Adb') {
        $expectedPort = ([int]$State.Port).ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        if ($FilePath -cne [string]$State.AdbPath -or $Arguments.Count -lt 5 -or
            $Arguments[0] -cne '-H' -or $Arguments[1] -cne $script:TL1C1bPrivateAdbHost -or
            $Arguments[2] -cne '-P' -or $Arguments[3] -cne $expectedPort) {
            throw 'C1b guarded adb executable/endpoint argv 未精确绑定。'
        }
        $tail = [string[]]@($Arguments[4..($Arguments.Count - 1)])
        $allowed = Test-TL1C1bPrivateAdbExactArgumentSequence $tail @('devices')
        if (-not $allowed -and $tail.Count -ge 3 -and $tail[0] -ceq '-s' -and
            $tail[1] -cmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$') {
            $command = [string[]]@($tail[2..($tail.Count - 1)])
            foreach ($shape in @(
                    ,([string[]]@('shell','getprop','ro.build.fingerprint'))
                    ,([string[]]@('shell','cat','/proc/sys/kernel/random/boot_id'))
                    ,([string[]]@('shell','settings','get','secure','enabled_accessibility_services'))
                    ,([string[]]@('shell','dumpsys','accessibility'))
                    ,([string[]]@('shell','pm','path','dev.magina.gateway'))
                    ,([string[]]@('shell','dumpsys','package','dev.magina.gateway')))) {
                if (Test-TL1C1bPrivateAdbExactArgumentSequence $command $shape) {
                    $allowed = $true
                    break
                }
            }
            if (-not $allowed -and $command.Count -eq 4 -and
                $command[0] -ceq 'install' -and $command[1] -ceq '-r' -and
                $command[2] -ceq '-t' -and
                [IO.Path]::IsPathFullyQualified($command[3]) -and
                [IO.Path]::GetFullPath($command[3]) -ceq $command[3] -and
                (Test-Path -LiteralPath $command[3] -PathType Leaf)) {
                $allowed = $true
            }
            if (-not $allowed -and $command.Count -eq 3 -and
                $command[0] -ceq 'exec-out' -and $command[1] -ceq 'cat' -and
                $command[2] -cmatch '^/data/app/(?:[A-Za-z0-9_~+=.-]+/)+base\.apk$' -and
                $command[2] -cnotmatch '[\x00-\x20\x7f]') {
                $segments = @($command[2].Substring('/data/app/'.Length) -split '/')
                if ($segments.Count -ge 2 -and $segments[-1] -ceq 'base.apk' -and
                    @($segments | Where-Object {
                        $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..'
                    }).Count -eq 0) { $allowed = $true }
            }
            if (-not $allowed -and $command.Count -eq 5 -and
                $command[0] -ceq 'exec-in' -and $command[1] -ceq 'content' -and
                $command[2] -ceq 'write' -and $command[3] -ceq '--uri' -and
                (Test-TL1C1bPrivateAdbBusinessContentUri $command[4] $true)) {
                $allowed = $true
            }
            if (-not $allowed -and $command.Count -eq 5 -and
                $command[0] -ceq 'shell' -and $command[1] -ceq 'content' -and
                $command[2] -ceq 'read' -and $command[3] -ceq '--uri' -and
                (Test-TL1C1bPrivateAdbBusinessContentUri $command[4] $false)) {
                $allowed = $true
            }
        }
        if (-not $allowed) {
            throw 'C1b guarded adb business argv 不在 exact allowlist。'
        }
        return 1
    }

    $currentPwsh = [IO.Path]::GetFullPath((Get-Process -Id $PID).Path)
    $sidecarScript = [string]$Environment['TL1_C1A_T0_SIDECAR_SCRIPT']
    $expectedCmd = [IO.Path]::ChangeExtension($sidecarScript, '.cmd')
    $expectedRunner = Join-Path (
        [IO.Directory]::GetParent([IO.Path]::GetDirectoryName($sidecarScript)).FullName) `
        'run-tablet-intake.ps1'
    if ($FilePath -cne $currentPwsh -or $Arguments.Count -ne 7 -or
        $Arguments[0] -cne '-NoProfile' -or $Arguments[1] -cne '-File' -or
        $Arguments[2] -cne $expectedRunner -or $Arguments[3] -cne '-AdbPath' -or
        $Arguments[4] -cne $expectedCmd -or $Arguments[5] -cne '-RunId' -or
        $Arguments[6] -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') {
        throw 'C1b guarded T0 executable/argv 未精确绑定。'
    }
    # 当前同步链为 root pwsh -> cmd -> sidecar pwsh -> adb；第 5 个 auto-start
    # server 在创建时触发 ACTIVE_PROCESS_LIMIT，不获得执行机会。
    return 4
}

function Invoke-TL1C1bPrivateAdbGuardedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Guard,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [byte[]]$InputBytes,
        [Parameter(Mandatory)][Collections.IDictionary]$ProcessEnvironment,
        [Parameter(Mandatory)][switch]$ClearEnvironment,
        [ValidateRange(1, 300)][int]$TimeoutSec = 30,
        [switch]$AllowFailure,
        [ValidateSet('Text','Sha256')][string]$OutputMode = 'Text',
        [ValidateRange(1, 268435456)][long]$MaximumOutputBytes = 1048576,
        [Parameter(Mandatory)][ValidateSet('Adb','T0Root')][string]$ClientKind
    )

    if (-not $ClearEnvironment -or [string]::IsNullOrWhiteSpace($Operation) -or
        $Operation.Length -gt 128 -or $Operation.IndexOf([char]0) -ge 0 -or
        $Operation.IndexOf("`r") -ge 0 -or $Operation.IndexOf("`n") -ge 0 -or
        ($null -ne $InputBytes -and $InputBytes.Length -gt 1048576) -or
        ($OutputMode -ceq 'Text' -and $MaximumOutputBytes -gt 1048576)) {
        throw 'C1b guarded client invocation 参数越界。'
    }
    $state = Get-TL1C1bPrivateAdbGuardState $Guard
    Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state
    [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
    $environment = Assert-TL1C1bPrivateAdbGuardedEnvironment `
        $state $ProcessEnvironment $ClientKind $FilePath
    $activeProcessLimit = Assert-TL1C1bPrivateAdbGuardedSpecification `
        $state $FilePath $Arguments $ClientKind $environment

    $stdout = if ($OutputMode -ceq 'Sha256') {
        [TL1C1bBoundedSha256WriteStream]::new($MaximumOutputBytes)
    } else { [TL1C1bBoundedWriteStream]::new($MaximumOutputBytes) }
    $stderr = [TL1C1bBoundedWriteStream]::new(1048576)
    $job = $null
    $started = $null
    $stdoutTask = $null
    $stderrTask = $null
    $inputTask = $null
    $inputClosed = $false
    $failed = $false
    $failureCategory = 'create-job'
    $result = $null
    try {
        if ($ClientKind -ceq 'T0Root') {
            $clientJobName = 'Local\TL1C1bClient-' + [guid]::NewGuid().ToString('N')
            $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob(
                $activeProcessLimit, $clientJobName)
            $environment['TL1_C1B_CLIENT_JOB_NAME'] = $clientJobName
        } else {
            $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob($activeProcessLimit)
        }
        $failureCategory = 'start'
        $started = [TL1C1bPrivateAdbNative]::StartInJob(
            $FilePath, $Arguments,
            (ConvertTo-TL1C1bPrivateAdbEnvironmentEntries $environment), $job)
        if (-not [TL1C1bPrivateAdbNative]::IsProcessAssigned(
                $job, $started.Process.Handle) -or $started.Process.HasExited) {
            throw 'created client is not in expected active-limit job'
        }
        $failureCategory = 'execute'
        $stdoutTask = $started.StandardOutput.CopyToAsync($stdout)
        $stderrTask = $started.StandardError.CopyToAsync($stderr)
        if ($null -eq $InputBytes) {
            $started.StandardInput.Dispose()
            $inputClosed = $true
            $inputTask = [Threading.Tasks.Task]::CompletedTask
        } else {
            $inputTask = $started.StandardInput.WriteAsync(
                $InputBytes, 0, $InputBytes.Length)
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $started.Process.HasExited -or -not $inputTask.IsCompleted) {
            if ($stdout.Overflowed -or $stderr.Overflowed) { throw 'output overflow' }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw 'timeout' }
            if (-not $inputClosed -and $inputTask.IsCompleted) {
                [void]$inputTask.GetAwaiter().GetResult()
                $started.StandardInput.Dispose()
                $inputClosed = $true
            }
            Start-Sleep -Milliseconds 10
        }
        if (-not $inputClosed) {
            [void]$inputTask.GetAwaiter().GetResult()
            $started.StandardInput.Dispose()
            $inputClosed = $true
        }
        if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000) -or
            $stdout.Overflowed -or $stderr.Overflowed) {
            throw 'output drain failed'
        }
        $stderrBytes = $stderr.Snapshot()
        try { $stderrText = ConvertFrom-TL1C1bPrivateAdbStrictUtf8 $stderrBytes 'client stderr' }
        finally {
            if ($stderrBytes.Length -ne 0) { [Array]::Clear($stderrBytes, 0, $stderrBytes.Length) }
        }
        if ($OutputMode -ceq 'Sha256') {
            if ($stdout.ObservedBytes -lt 1) { throw 'stream output empty' }
            $result = [pscustomobject][ordered]@{
                ExitCode = [int]$started.Process.ExitCode
                Sha256 = $stdout.CompleteHash()
                ByteCount = [long]$stdout.ObservedBytes
                Stderr = $stderrText
            }
        } else {
            $stdoutBytes = $stdout.Snapshot()
            try {
                $stdoutText = ConvertFrom-TL1C1bPrivateAdbStrictUtf8 $stdoutBytes 'client stdout'
                $result = [pscustomobject][ordered]@{
                    ExitCode = [int]$started.Process.ExitCode
                    Bytes = $stdoutBytes
                    Text = $stdoutText
                    Stderr = $stderrText
                }
                $stdoutBytes = $null
            } finally {
                if ($null -ne $stdoutBytes -and $stdoutBytes.Length -ne 0) {
                    [Array]::Clear($stdoutBytes, 0, $stdoutBytes.Length)
                }
            }
        }
        if (-not $AllowFailure -and $result.ExitCode -ne 0) { throw 'nonzero exit' }
        $failureCategory = 'postcondition'
        [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
        $failureCategory = 'none'
    } catch { $failed = $true }
    finally {
        if ($null -ne $started -and -not $inputClosed) {
            try { $started.StandardInput.Dispose(); $inputClosed = $true }
            catch { $failed = $true }
        }
        if ($null -ne $job) {
            try { $job.Dispose() } catch { $failed = $true }
        }
        if ($null -ne $started) {
            try {
                if (-not $started.Process.HasExited -and
                    -not $started.Process.WaitForExit(3000)) {
                    $started.Process.Kill($true)
                    if (-not $started.Process.WaitForExit(3000)) { $failed = $true }
                }
            } catch { $failed = $true }
        }
        foreach ($task in @($inputTask, $stdoutTask, $stderrTask)) {
            if ($null -ne $task) {
                try { if (-not $task.Wait(2000)) { $failed = $true } }
                catch { $failed = $true }
            }
        }
        try {
            if ((Wait-TL1C1bPrivateAdbEndpointContained `
                    $state.Port $state.ProcessId -TimeoutMs 2000) -cne 'held') {
                $failed = $true
            }
            [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state)
        } catch { $failed = $true }
        if ($null -ne $started) { try { $started.Dispose() } catch { $failed = $true } }
        try { $stdout.Dispose() } catch { $failed = $true }
        try { $stderr.Dispose() } catch { $failed = $true }
    }
    if ($failed) { throw "C1b guarded private client 失败 ($failureCategory)。" }
    return $result
}

function Close-TL1C1bPrivateAdbServerGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Guard,
        [ValidateRange(1, 15)][int]$ShutdownTimeoutSec = 5,
        [ValidateRange(1, 10)][int]$ClientTimeoutSec = 3,
        [ValidateRange(4096, 1048576)][int]$MaximumOutputBytes = 65536
    )

    $state = Get-TL1C1bPrivateAdbGuardState `
        $Guard -AllowDisposed -AllowWrapperMutation
    $wrapperUnchanged = Test-TL1C1bPrivateAdbGuardWrapperUnchanged $Guard $state
    if ([bool]$state.Disposed) {
        if (-not [bool]$state.CloseSucceeded -or -not $wrapperUnchanged) {
            throw 'C1b private adb server guard 已关闭但 cleanup proof 无效。'
        }
        Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state
        Assert-TL1C1bPrivateAdbIssuedCleanupBindingsUnchanged $state
        return New-TL1C1bPrivateAdbCleanupBindingCopy $state
    }
    $failures = [Collections.Generic.List[string]]::new()
    $gracefulRequested = $false
    $gracefulCompleted = $false
    $jobFallbackUsed = $false
    $processExited = $false
    $portReusable = $false
    try {
        if (-not $wrapperUnchanged) {
            $failures.Add('guard wrapper mutation detected')
        }
        try { Assert-TL1C1bPrivateAdbIssuedBindingsUnchanged $state }
        catch { $failures.Add('issued binding mutation detected') }
        try { [void](Assert-TL1C1bPrivateAdbServerStateUnchanged $state) }
        catch { $failures.Add('final server/listener frozen recheck failed') }

        $serverAlive = $false
        try { $serverAlive = -not $state.Process.HasExited }
        catch { $failures.Add('held server liveness query failed') }
        $listenerOwned = $false
        if ($serverAlive) {
            try {
                $listenerOwned = Test-TL1C1bPrivateAdbListenerOwned `
                    $state.Port $state.ProcessId
            } catch { $failures.Add('held listener ownership query failed') }
        }
        if ($serverAlive -and $listenerOwned) {
            $gracefulRequested = $true
            try {
                $killOutput = Invoke-TL1C1bPrivateAdbClientCommand `
                    $state.AdbPath $state.ClientEnvironment $state.Port `
                    $state.ProcessId 'kill-server' $ClientTimeoutSec $MaximumOutputBytes
                if ($killOutput.Length -ne 0) { throw 'kill-server stdout not empty' }
            } catch { $failures.Add('private kill-server failed') }
        }

        try {
            if ($state.Process.HasExited) { $gracefulCompleted = $true }
            else {
                $gracefulCompleted =
                    $state.Process.WaitForExit($ShutdownTimeoutSec * 1000)
            }
        } catch { $failures.Add('server graceful wait failed') }
    } catch {
        $failures.Add('unexpected cleanup body failure')
    } finally {
        $aliveBeforeJobClose = $true
        try { $aliveBeforeJobClose = -not $state.Process.HasExited }
        catch { $failures.Add('held server liveness query before job close failed') }
        if ($aliveBeforeJobClose) { $jobFallbackUsed = $true }

        $jobToClose = $state.Job
        $state.Job = $null
        if ($null -ne $jobToClose) {
            try { $jobToClose.Dispose() }
            catch { $failures.Add('close KILL_ON_CLOSE job failed') }
        }

        try {
            if (-not $state.Process.HasExited -and
                -not $state.Process.WaitForExit(3000)) {
                $state.Process.Kill($true)
                if (-not $state.Process.WaitForExit(3000)) {
                    $failures.Add('held server process did not exit')
                }
            }
            $processExited = $state.Process.HasExited
        } catch { $failures.Add('held server process force cleanup failed') }

        foreach ($task in @($state.StdoutTask, $state.StderrTask)) {
            if ($null -ne $task) {
                try {
                    if (-not $task.Wait(2000)) {
                        $failures.Add('server output drain timeout')
                    }
                } catch { $failures.Add('server output drain failed') }
            }
        }
        try {
            if ($state.Stdout.Overflowed -or $state.Stderr.Overflowed) {
                $failures.Add('server output exceeded fixed limit')
            }
        } catch { $failures.Add('server output bound query failed') }

        $rebindDeadline = [DateTime]::UtcNow.AddSeconds($ShutdownTimeoutSec)
        do {
            try {
                if (Test-TL1C1bPrivateAdbPortAvailable $state.Port) {
                    $portReusable = $true
                    break
                }
            } catch { }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $rebindDeadline)
        if (-not $portReusable) {
            $failures.Add('private server port is not reusable')
        }

        if ($null -ne $state.StartedProcess) {
            try { $state.StartedProcess.Dispose() }
            catch { $failures.Add('server process/pipe dispose failed') }
            $state.StartedProcess = $null
        }
        try { $state.Stdout.Dispose() }
        catch { $failures.Add('server stdout sink dispose failed') }
        try { $state.Stderr.Dispose() }
        catch { $failures.Add('server stderr sink dispose failed') }
        try { $state.AdbExecutableGuard.Dispose() }
        catch { $failures.Add('held adb file dispose failed') }

        foreach ($property in @($Guard.PSObject.Properties | Where-Object {
                $_.MemberType -ne [Management.Automation.PSMemberTypes]::Property -or
                $_.Name -cnotin @('Id','Disposed')
            })) {
            try { $Guard.PSObject.Properties.Remove($property.Name) }
            catch { $failures.Add('guard wrapper extension cleanup failed') }
        }

        $state.PrivateKillRequested = $gracefulRequested
        $state.GracefulExitVerified = $gracefulCompleted
        $state.JobFallbackUsed = $jobFallbackUsed
        $state.PortRebindVerified = $portReusable
        if ($processExited -and $portReusable) {
            Set-TL1C1bPrivateAdbGuardDisposed $Guard $state
        }
        $state.CloseSucceeded = [bool]$state.Disposed -and $failures.Count -eq 0
    }
    if (-not [bool]$state.CloseSucceeded) {
        throw 'C1b private adb server cleanup 未完整证明。'
    }
    return New-TL1C1bPrivateAdbCleanupBindingCopy $state
}
