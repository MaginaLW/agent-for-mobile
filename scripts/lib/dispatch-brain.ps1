#Requires -Version 7

function ConvertTo-DispatchTomlString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return '"' + ($Value -replace '\\', '\\' -replace '"', '\"') + '"'
}

function ConvertTo-DispatchTomlStringArray {
    param([AllowEmptyCollection()][object[]]$Values = @())
    return '[' + ((@($Values) | ForEach-Object { ConvertTo-DispatchTomlString ([string]$_) }) -join ',') + ']'
}

function Get-DispatchPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    # PowerShell 函数默认会展开单元素数组；JSON `[true]` 因而可能冒充 boolean true。
    # 所有调用点必须看到 property.Value 的原始形状。
    return ,$property.Value
}

function Test-DispatchJsonObject {
    param([AllowNull()]$Value)
    return $Value -is [Management.Automation.PSCustomObject] -or
        $Value -is [Collections.IDictionary]
}

function Get-DispatchRequiredJsonObject {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ErrorMessage
    )
    $property = if ($null -eq $InputObject) { $null } else { $InputObject.PSObject.Properties[$Name] }
    # 与 required-string 相同，必须在 property.Value 上判型；否则单元素 JSON array 会被
    # PowerShell pipeline 展开成其中那个 PSCustomObject，冒充原始 JSON object。
    if ($null -eq $property -or -not (Test-DispatchJsonObject -Value $property.Value)) {
        throw $ErrorMessage
    }
    return $property.Value
}

function Test-DispatchNonEmptyJsonString {
    param([AllowNull()]$Value)
    return $Value -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$Value)
}

function Test-DispatchNonNegativeJsonInt64 {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    $integerType = $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    if (-not $integerType) { return $false }
    try {
        $number = [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
        return $number -ge 0
    }
    catch { return $false }
}

function Test-DispatchNonNegativeJsonNumber {
    param([AllowNull()]$Value)

    if ($null -eq $Value -or $Value -is [bool]) { return $false }
    $numericType = $Value -is [sbyte] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]
    if (-not $numericType) { return $false }
    try {
        $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture)
        return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number) -and $number -ge 0
    }
    catch { return $false }
}

function Get-DispatchRequiredNonEmptyJsonString {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ErrorMessage
    )
    $property = if ($null -eq $InputObject) { $null } else { $InputObject.PSObject.Properties[$Name] }
    # 必须直接检查 property.Value；复用 Get-DispatchPropertyValue 会让单元素 JSON array 经
    # PowerShell pipeline 自动展开成 string，从而再次绕过原始 JSON 类型约束。
    if ($null -eq $property -or -not (Test-DispatchNonEmptyJsonString -Value $property.Value)) {
        throw $ErrorMessage
    }
    return [string]$property.Value
}

function Get-DispatchCodexVersionContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$VersionOutput
    )

    # 这里是经证据锁定的精确 allowlist，不是 semver 范围：0.147.0 是原验证
    # 基线；0.149.0 是官方 stable，alpha.4.1 是 2026-08-22 桌面应用实际 bundled CLI。
    # 未实测的 0.148/0.150、未来 patch/alpha、其他预发标签和额外诊断行一律 fail closed。
    switch -CaseSensitive ($VersionOutput) {
        'codex-cli 0.147.0' { return '0.147' }
        'codex-cli 0.149.0' { return '0.149' }
        'codex-cli 0.149.0-alpha.4.1' { return '0.149' }
        default { return $null }
    }
}

function Select-DispatchCodexExecutableCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)

    # 优先级是已审过的 CLI 契约顺序，不能拿安装目录随机 hash、mtime 或枚举顺序代替。
    $supportedOrder = @(
        'codex-cli 0.149.0',
        'codex-cli 0.149.0-alpha.4.1',
        'codex-cli 0.147.0'
    )
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) { throw 'Codex 候选记录不能为空。' }
        $path = [string](Get-DispatchPropertyValue $candidate 'Path')
        $version = [string](Get-DispatchPropertyValue $candidate 'VersionOutput')
        $hash = [string](Get-DispatchPropertyValue $candidate 'Sha256')
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($hash)) {
            throw 'Codex 候选缺少规范化路径或 SHA-256。'
        }
        $normalized.Add([pscustomobject]@{
            Path = [IO.Path]::GetFullPath($path)
            VersionOutput = $version
            Sha256 = $hash.ToUpperInvariant()
            Contract = Get-DispatchCodexVersionContract -VersionOutput $version
        })
    }

    $unknown = @($normalized | Where-Object { $null -eq $_.Contract })
    foreach ($version in $supportedOrder) {
        $matches = @($normalized | Where-Object { $_.VersionOutput -ceq $version })
        if ($matches.Count -eq 0) { continue }
        $hashes = @($matches | Select-Object -ExpandProperty Sha256 -Unique)
        if ($hashes.Count -ne 1) {
            throw "同一最高优先级 Codex 契约存在不同二进制哈希，拒绝任意选择：$version"
        }
        $paths = [string[]]@($matches | Select-Object -ExpandProperty Path)
        [Array]::Sort($paths, [StringComparer]::OrdinalIgnoreCase)
        return [pscustomobject]@{
            SelectedPath = $paths[0]
            VersionOutput = $version
            Contract = Get-DispatchCodexVersionContract -VersionOutput $version
            Sha256 = $hashes[0]
            UnknownVersions = [string[]]@($unknown | ForEach-Object VersionOutput | Sort-Object -Unique)
        }
    }

    $diagnostic = @($unknown | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.VersionOutput)) { '<empty-or-probe-failed>' }
        else { $_.VersionOutput }
    } | Sort-Object -Unique) -join ', '
    if ([string]::IsNullOrWhiteSpace($diagnostic)) { $diagnostic = '<none>' }
    throw "找不到已验证的 Codex CLI；探测到的未知版本：$diagnostic"
}

function Test-DispatchSupportedCodexVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$VersionOutput
    )
    return $null -ne (Get-DispatchCodexVersionContract -VersionOutput $VersionOutput)
}

if ($null -eq ('AgentMobileDispatchVersionProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.IO;
using System.IO.Pipes;

public sealed class AgentMobileDispatchVersionProbeResult {
    public bool TimedOut { get; set; }
    public int ExitCode { get; set; }
}

public static class AgentMobileDispatchVersionProbe {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
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
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass,
        ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(IntPtr job, int infoClass,
        out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info, uint length, IntPtr returnLength);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share,
        ref SECURITY_ATTRIBUTES security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startup,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new [] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    private static IntPtr BuildEnvironment(string[] entries) {
        Array.Sort(entries, StringComparer.OrdinalIgnoreCase);
        string block = String.Join("\0", entries) + "\0\0";
        byte[] bytes = Encoding.Unicode.GetBytes(block);
        IntPtr pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        Array.Clear(bytes, 0, bytes.Length);
        return pointer;
    }

    private sealed class ProbePumpResult {
        public long BytesWritten;
        public bool LimitReached;
    }

    private static Task<ProbePumpResult> StartPump(Stream source, string destinationPath,
        long limitBytes, IntPtr job) {
        if (limitBytes <= 0) throw new ArgumentOutOfRangeException("limitBytes");
        return Task.Run(() => {
            byte[] buffer = new byte[16 * 1024];
            long written = 0;
            try {
                using (FileStream destination = new FileStream(destinationPath, FileMode.Create,
                    FileAccess.Write, FileShare.Read, buffer.Length, FileOptions.SequentialScan)) {
                    while (true) {
                        int read = source.Read(buffer, 0, buffer.Length);
                        if (read == 0) break;
                        long remaining = limitBytes - written;
                        int accepted = remaining <= 0 ? 0 : (int)Math.Min((long)read, remaining);
                        if (accepted > 0) {
                            destination.Write(buffer, 0, accepted);
                            written += accepted;
                        }
                        if (written >= limitBytes) {
                            destination.Flush();
                            if (!TerminateJobObject(job, 1)) {
                                throw new Win32Exception(Marshal.GetLastWin32Error());
                            }
                            return new ProbePumpResult { BytesWritten = written, LimitReached = true };
                        }
                    }
                    destination.Flush();
                }
                return new ProbePumpResult { BytesWritten = written, LimitReached = false };
            } catch {
                // 读写异常也不允许探针继续跑；Run 会再次 DrainJob 并证明归零。
                TerminateJobObject(job, 1);
                throw;
            } finally {
                Array.Clear(buffer, 0, buffer.Length);
            }
        });
    }

    private static void WaitPumps(Task<ProbePumpResult> stdoutPump,
        Task<ProbePumpResult> stderrPump) {
        Exception first = null;
        if (stdoutPump != null) {
            try { stdoutPump.GetAwaiter().GetResult(); }
            catch (Exception ex) { first = ex; }
        }
        if (stderrPump != null) {
            try { stderrPump.GetAwaiter().GetResult(); }
            catch (Exception ex) {
                first = first == null ? ex : new AggregateException(first, ex);
            }
        }
        if (first != null) throw first;
    }

    private static bool WaitJobEmpty(IntPtr job, int milliseconds) {
        long deadline = Environment.TickCount64 + milliseconds;
        while (true) {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting;
            if (!QueryInformationJobObject(job, 1, out accounting,
                (uint)Marshal.SizeOf<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(), IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (accounting.ActiveProcesses == 0) return true;
            if (Environment.TickCount64 >= deadline) return false;
            Thread.Sleep(25);
        }
    }

    private static void DrainJob(IntPtr job) {
        if (!TerminateJobObject(job, 1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (WaitJobEmpty(job, 5000)) return;
        if (!TerminateJobObject(job, 1)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (!WaitJobEmpty(job, 5000)) {
            throw new TimeoutException("Codex version probe Job did not drain");
        }
    }

    private static void TerminateUnassignedProcess(IntPtr process) {
        if (!TerminateProcess(process, 1)) {
            int terminateError = Marshal.GetLastWin32Error();
            // 失败也可能只是进程已退出；只有 handle 尚未 signaled 才把原错误视为清理失败。
            if (WaitForSingleObject(process, 0) != 0) {
                throw new Win32Exception(terminateError);
            }
        }
        uint wait = WaitForSingleObject(process, 5000);
        if (wait == 0x00000102) {
            throw new TimeoutException("Unassigned Codex version probe process did not terminate");
        }
        if (wait != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
        uint exitCode;
        if (!GetExitCodeProcess(process, out exitCode)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (exitCode == 259) { // STILL_ACTIVE
            throw new InvalidOperationException("Unassigned Codex version probe is still active");
        }
    }

    public static AgentMobileDispatchVersionProbeResult Run(string executable,
        string workingDirectory, string stdoutPath, string stderrPath,
        string[] environment, long stdoutLimitBytes, long stderrLimitBytes,
        uint timeoutMilliseconds, bool forceAssignFailureForTest) {
        IntPtr job = IntPtr.Zero;
        IntPtr input = IntPtr.Zero;
        IntPtr environmentBlock = IntPtr.Zero;
        AnonymousPipeServerStream stdoutPipe = null;
        AnonymousPipeServerStream stderrPipe = null;
        Task<ProbePumpResult> stdoutPump = null;
        Task<ProbePumpResult> stderrPump = null;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        bool assigned = false;
        bool jobDrained = false;
        try {
            job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            limits.BasicLimitInformation.LimitFlags = 0x00002000; // KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits,
                (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
            security.nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>();
            security.bInheritHandle = true;
            const uint GENERIC_READ = 0x80000000;
            const uint FILE_SHARE_READ = 0x00000001;
            const uint FILE_SHARE_WRITE = 0x00000002;
            const uint OPEN_EXISTING = 3;
            input = CreateFile("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                ref security, OPEN_EXISTING, 0, IntPtr.Zero);
            stdoutPipe = new AnonymousPipeServerStream(
                PipeDirection.In, HandleInheritability.Inheritable);
            stderrPipe = new AnonymousPipeServerStream(
                PipeDirection.In, HandleInheritability.Inheritable);
            IntPtr invalid = new IntPtr(-1);
            if (input == invalid) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf<STARTUPINFO>();
            startup.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
            startup.hStdInput = input;
            startup.hStdOutput = stdoutPipe.ClientSafePipeHandle.DangerousGetHandle();
            startup.hStdError = stderrPipe.ClientSafePipeHandle.DangerousGetHandle();
            environmentBlock = BuildEnvironment(environment);
            const uint CREATE_SUSPENDED = 0x00000004;
            const uint CREATE_NO_WINDOW = 0x08000000;
            const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
            StringBuilder commandLine = new StringBuilder(Quote(executable) + " --version");
            if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                environmentBlock, workingDirectory, ref startup, out process)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            stdoutPipe.DisposeLocalCopyOfClientHandle();
            stderrPipe.DisposeLocalCopyOfClientHandle();
            // 测试 seam 位于 CreateProcess 成功之后、真正 Assign 之前，精确复现 suspended child
            // 尚未加入 Job 的失败窗口；它只会让调用安全失败，不会扩大生产权限。
            if (forceAssignFailureForTest) {
                throw new InvalidOperationException("fixture_forced_assign_failure");
            }
            if (!AssignProcessToJobObject(job, process.hProcess)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            assigned = true;
            stdoutPump = StartPump(stdoutPipe, stdoutPath, stdoutLimitBytes, job);
            stderrPump = StartPump(stderrPipe, stderrPath, stderrLimitBytes, job);
            if (ResumeThread(process.hThread) == 0xffffffff) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            long deadline = Environment.TickCount64 + timeoutMilliseconds;
            bool timedOut = false;
            bool processExited = false;
            while (true) {
                uint wait = WaitForSingleObject(process.hProcess, 25);
                if (wait == 0) { processExited = true; break; }
                if (wait != 0x00000102) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (stdoutPump.IsFaulted || stdoutPump.IsCanceled ||
                    stderrPump.IsFaulted || stderrPump.IsCanceled) break;
                if ((stdoutPump.IsCompleted && stdoutPump.GetAwaiter().GetResult().LimitReached) ||
                    (stderrPump.IsCompleted && stderrPump.GetAwaiter().GetResult().LimitReached)) break;
                if (Environment.TickCount64 >= deadline) { timedOut = true; break; }
            }
            uint exitCode = 1;
            if (processExited && !GetExitCodeProcess(process.hProcess, out exitCode)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            // 即使根探针已成功退出，也必须杀掉并等待其所有仍存活的后代，才可把版本交回 resolver。
            DrainJob(job);
            jobDrained = true;
            ProbePumpResult stdoutResult = stdoutPump.GetAwaiter().GetResult();
            ProbePumpResult stderrResult = stderrPump.GetAwaiter().GetResult();
            if (stdoutResult.LimitReached || stderrResult.LimitReached) {
                throw new InvalidOperationException(
                    "Codex version probe stdout/stderr exceeded byte limit");
            }
            return new AgentMobileDispatchVersionProbeResult {
                TimedOut = timedOut,
                ExitCode = unchecked((int)exitCode)
            };
        } catch (Exception failure) {
            try {
                // Assign 失败时 child 不属于 Job；DrainJob 对空 Job 无法触及它。此时必须直接
                // TerminateProcess 并等待 process handle signaled，之后才能关闭最后两个句柄。
                if (process.hProcess != IntPtr.Zero && !assigned) {
                    TerminateUnassignedProcess(process.hProcess);
                } else if (assigned && job != IntPtr.Zero && !jobDrained) {
                    DrainJob(job);
                    jobDrained = true;
                }
                WaitPumps(stdoutPump, stderrPump);
            } catch (Exception cleanup) {
                throw new InvalidOperationException(
                    "Codex version probe failed and cleanup could not be completed",
                    new AggregateException(failure, cleanup));
            }
            throw;
        } finally {
            if (environmentBlock != IntPtr.Zero) Marshal.FreeHGlobal(environmentBlock);
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            IntPtr invalid = new IntPtr(-1);
            if (input != IntPtr.Zero && input != invalid) CloseHandle(input);
            if (stdoutPipe != null) stdoutPipe.Dispose();
            if (stderrPipe != null) stderrPipe.Dispose();
            if (job != IntPtr.Zero) CloseHandle(job);
        }
    }
}
'@
}

function Invoke-DispatchCodexVersionProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000,
        [switch]$ForceAssignFailureForTest
    )

    # 版本探针发生在 bearer 构造前，也不需要认证、网络或用户配置；不能让它因为
    # CreateProcess 默认继承而先拿到宿主任意 secret。
    $versionEnvironment = [Collections.Generic.List[string]]::new()
    foreach ($name in @('SystemRoot','WINDIR','ComSpec','OS','TEMP','TMP','PATH','PATHEXT')) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -ne $value) { $versionEnvironment.Add("$name=$value") }
    }

    $stdoutPath = [IO.Path]::GetTempFileName()
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $probe = [AgentMobileDispatchVersionProbe]::Run(
            [IO.Path]::GetFullPath($ExecutablePath),
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ExecutablePath)),
            $stdoutPath, $stderrPath, $versionEnvironment.ToArray(),
            4096L, 4096L, [uint32]$TimeoutMilliseconds, [bool]$ForceAssignFailureForTest)
        if ($probe.TimedOut) {
            throw 'codex.exe --version 未在 5 秒内成功返回。'
        }
        if ($probe.ExitCode -ne 0) { throw 'codex.exe --version 返回非零退出码。' }
        if ((Get-Item -LiteralPath $stdoutPath -Force).Length -gt 4096) {
            throw 'codex.exe --version 输出异常过大。'
        }
        if ((Get-Item -LiteralPath $stderrPath -Force).Length -gt 4096) {
            throw 'codex.exe --version stderr 异常过大。'
        }
        $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
        $version = [IO.File]::ReadAllText($stdoutPath, $strictUtf8).Trim()
        return $version
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-DispatchTrustedCodexExecutable {
    [CmdletBinding()]
    param(
        [ref]$VersionOutput,
        [ref]$Sha256
    )

    $localAppData = [IO.Path]::GetFullPath([Environment]::GetFolderPath('LocalApplicationData'))
    $binRoot = Join-Path $localAppData 'OpenAI\Codex\bin'
    foreach ($directory in @(
        $localAppData,
        (Join-Path $localAppData 'OpenAI'),
        (Join-Path $localAppData 'OpenAI\Codex'),
        $binRoot
    )) {
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$item.LinkType)) {
            throw 'Codex 官方 bin 路径含 reparse/link，拒绝启动。'
        }
    }

    # 子目录名是随机 hash，mtime 也不是版本。应用更新可保留多个目录，因此必须逐个
    # 验签、探测精确版本并交给显式契约优先级选择；未知新版不能靠时间戳冒充首选。
    $candidateFiles = @(Get-ChildItem -LiteralPath $binRoot -Directory -Force |
        ForEach-Object {
            if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::IsNullOrWhiteSpace([string]$_.LinkType)) { return }
            $path = Join-Path $_.FullName 'codex.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) { return (Get-Item -LiteralPath $path -Force) }
        })
    if ($candidateFiles.Count -eq 0) {
        throw '找不到官方桌面应用 bundled codex.exe。'
    }

    $probedCandidates = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidateFiles) {
        if (($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$candidate.LinkType)) {
            throw 'codex.exe 候选是 reparse/link，拒绝启动。'
        }
        # LocalAppData 可写：从签名检查到 --version 再到 hash 必须持 deny-write/delete 句柄，
        # 否则候选可在“验签后、执行前”被换成任意 exe，最终再换回以骗过 hash。
        $candidateGuard = [IO.File]::Open($candidate.FullName, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $candidate.FullName
            if ($signature.Status -ne 'Valid' -or
                [string]$signature.SignerCertificate.Subject -cne
                    'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US') {
                throw 'codex.exe 候选签名不是有效的 OpenAI OpCo 签名。'
            }
            $version = ''
            try { $version = Invoke-DispatchCodexVersionProbe -ExecutablePath $candidate.FullName }
            catch { $version = '' }
            $candidateGuard.Position = 0
            $candidateSha256 = (Get-FileHash -InputStream $candidateGuard -Algorithm SHA256).Hash
            $probedCandidates.Add([pscustomobject]@{
                Path = [IO.Path]::GetFullPath($candidate.FullName)
                VersionOutput = $version
                Sha256 = $candidateSha256
            })
        }
        finally { $candidateGuard.Dispose() }
    }

    $selection = Select-DispatchCodexExecutableCandidate -Candidates $probedCandidates.ToArray()
    if ($selection.UnknownVersions.Count -gt 0) {
        Write-Warning ('忽略未验证的 Codex CLI 候选：' + ($selection.UnknownVersions -join ', '))
    }
    if ($null -ne $VersionOutput) { $VersionOutput.Value = $selection.VersionOutput }
    if ($null -ne $Sha256) { $Sha256.Value = $selection.Sha256 }
    return $selection.SelectedPath
}

function New-DispatchCodexLaunchSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory)][bool]$ModelWasExplicit,
        [Parameter(Mandatory)][ValidateSet(1,2)][int]$Leg,
        [string]$CodexExecutableOverride = '',
        [string]$CodexVersionOverride = ''
    )

    # mobile profile 依赖宿主 PATH 中的 npx/npm，并会继续下载/执行包。当前尚未建立对
    # node+npm+npx 整条运行时及包内容的可复验证明链；精确包版本本身不足以信任执行体。
    # dispatch 顶层也会在设备 preflight 前挡一次，这里保留第二道纯函数边界，防止调用者绕过。
    if ([string]$Profile.Name -ceq 'mobile') {
        throw 'Codex mobile 尚无可信 npx runtime 契约；当前只允许 Codex + gateway。'
    }

    if ([string]::IsNullOrWhiteSpace($CodexExecutableOverride)) {
        $codexVersion = ''
        $codexSha256 = ''
        $codexExecutable = Resolve-DispatchTrustedCodexExecutable -VersionOutput ([ref]$codexVersion) `
            -Sha256 ([ref]$codexSha256)
        $requireOpenAiSignature = $true
    }
    else {
        if ([string]::IsNullOrWhiteSpace($CodexVersionOverride)) {
            throw 'Codex executable override 必须同时显式给出已验证版本。'
        }
        $codexExecutable = $CodexExecutableOverride
        $codexVersion = $CodexVersionOverride
        $codexSha256 = (Get-FileHash -LiteralPath $codexExecutable -Algorithm SHA256).Hash
        $requireOpenAiSignature = $false
    }
    $codexVersionContract = Get-DispatchCodexVersionContract -VersionOutput $codexVersion
    if ($null -eq $codexVersionContract) { throw 'Codex launch spec 版本不在已验证的精确 allowlist 中。' }

    try {
        $configText = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 -ErrorAction Stop
        $config = ConvertFrom-Json -InputObject $configText -Depth 30 -NoEnumerate -ErrorAction Stop
    }
    catch { throw '无法读取 Codex MCP 配置：文件不存在、不可读或不是有效 JSON。' }
    finally { $configText = $null }
    if (-not (Test-DispatchJsonObject -Value $config)) {
        throw 'Codex MCP 配置顶层必须是 JSON object。'
    }

    $serverName = [string]$Profile.Name
    $mcpServers = Get-DispatchRequiredJsonObject -InputObject $config -Name 'mcpServers' `
        -ErrorMessage 'Codex MCP 配置 mcpServers 必须是 JSON object。'
    $server = Get-DispatchRequiredJsonObject -InputObject $mcpServers -Name $serverName `
        -ErrorMessage "Codex MCP 配置 mcpServers.$serverName 必须是 JSON object。"

    $arguments = [Collections.Generic.List[string]]::new()
    $disabledFeatures = @(
        'apps','browser_use','browser_use_external','browser_use_full_cdp_access','computer_use','goals','hooks','image_generation',
        'code_mode','code_mode_only','in_app_browser','memories',
        'multi_agent','multi_agent_v2','plugins','remote_plugin',
        'shell_snapshot','shell_tool','skill_mcp_dependency_install','skill_search','tool_call_mcp_elicitation',
        'tool_suggest','workspace_dependencies'
    )
    if ($codexVersionContract -ceq '0.147') {
        $disabledFeatures += @('code_mode_buffered_exec','plugin_hooks')
    }
    else {
        # 0.149 已将 view_image 暴露为 stable feature；旧 0.147 residual 不再适用。
        $disabledFeatures += 'view_image'
    }
    foreach ($argument in @(
        'exec','--json','--ephemeral','--ignore-user-config','--ignore-rules','--strict-config',
        '--skip-git-repo-check','-C',$WorkspacePath,'--sandbox','read-only',
        '-c','mcp_servers={}',
        '-c','project_doc_max_bytes=0','-c','tools.web_search=false',
        '-c','web_search="disabled"','-c','agents.enabled=false','-c','forced_login_method="chatgpt"',
        '-c','shell_environment_policy.inherit="none"',
        '-c',"mcp_servers.$serverName.enabled=true",
        '-c',"mcp_servers.$serverName.required=true",
        '-c',"mcp_servers.$serverName.default_tools_approval_mode=`"approve`""
    )) { $arguments.Add($argument) }
    foreach ($feature in $disabledFeatures) {
        $arguments.Add('--disable')
        $arguments.Add($feature)
    }

    $sensitiveEnvironment = @{}
    $typeProperty = $server.PSObject.Properties['type']
    if ($null -eq $typeProperty -or $typeProperty.Value -isnot [string]) {
        throw "Codex MCP 配置 mcpServers.$serverName.type 必须是 JSON string。"
    }
    $serverType = [string]$typeProperty.Value
    if ($serverType -ceq 'http') {
        $urlProperty = $server.PSObject.Properties['url']
        if ($null -eq $urlProperty -or $urlProperty.Value -isnot [string]) {
            throw "Codex MCP 配置 mcpServers.$serverName.url 必须是 JSON string。"
        }
        $serverUrl = [string]$urlProperty.Value
        if ($serverName -cne 'gateway' -or $serverUrl -cne 'http://127.0.0.1:8848/mcp') {
            throw 'Codex HTTP MCP 只接受本机 127.0.0.1 gateway。'
        }
        $headers = Get-DispatchRequiredJsonObject -InputObject $server -Name 'headers' `
            -ErrorMessage "Codex MCP 配置 mcpServers.$serverName.headers 必须是 JSON object。"
        $authorizationProperty = $headers.PSObject.Properties['Authorization']
        if ($null -eq $authorizationProperty -or $authorizationProperty.Value -isnot [string]) {
            throw "Codex MCP 配置 mcpServers.$serverName.headers.Authorization 必须是 JSON string。"
        }
        $authorization = [string]$authorizationProperty.Value
        if ($authorization -notmatch '(?i)^Bearer\s+([^\s]+)$') {
            throw "Codex MCP 配置 mcpServers.$serverName 缺少有效 Bearer token。"
        }
        $token = [string]$Matches[1]
        if ($token -ieq '<GATEWAY_TOKEN>') {
            throw "Codex MCP 配置 mcpServers.$serverName 仍是 Bearer token 占位符。"
        }
        $timeoutProperty = $server.PSObject.Properties['timeout']
        if ($null -eq $timeoutProperty -or
            -not (Test-DispatchNonNegativeJsonNumber -Value $timeoutProperty.Value) -or
            [double]$timeoutProperty.Value -le 0) {
            throw "Codex MCP 配置 mcpServers.$serverName.timeout 必须是大于 0 的 JSON number。"
        }
        $timeoutSecondsNumber = [math]::Ceiling(([double]$timeoutProperty.Value) / 1000.0)
        if ($timeoutSecondsNumber -gt [int]::MaxValue) {
            throw "Codex MCP 配置 mcpServers.$serverName.timeout 超出可支持范围。"
        }
        $tokenEnvironmentName = 'AGENT_MOBILE_MCP_' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
        try { $sensitiveEnvironment[$tokenEnvironmentName] = $token }
        finally {
            # token 已转移到一次性 child env map；异常路径也立刻清掉 JSON 对象树重复引用。
            $headers.PSObject.Properties['Authorization'].Value = ''
        }
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.url=$(ConvertTo-DispatchTomlString $serverUrl)")
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.bearer_token_env_var=$(ConvertTo-DispatchTomlString $tokenEnvironmentName)")
        $timeoutSeconds = [int]$timeoutSecondsNumber
        $arguments.Add('-c')
        $arguments.Add("mcp_servers.$serverName.tool_timeout_sec=$timeoutSeconds")
        $token = $null
        $authorization = $null
    }
    elseif ($serverType -ceq 'stdio') {
        throw 'Codex stdio MCP 尚无可信宿主运行时契约，拒绝启动。'
    }
    else { throw "Codex MCP 配置 mcpServers.$serverName.type 不受支持。" }

    if ($ModelWasExplicit) {
        $arguments.Add('--model')
        $arguments.Add($Model)
    }
    # `-` 明确要求从已经过路径验证的 prompt 文件读取，而不是把任务正文放进 argv。
    $arguments.Add('-')

    $config = $null
    $server = $null
    return [pscustomobject]@{
        Executable = [string]$codexExecutable
        Arguments = [string[]]$arguments.ToArray()
        SensitiveEnvironment = $sensitiveEnvironment
        LedgerModel = $(if ($ModelWasExplicit) { $Model } else { '' })
        ExpectedSha256 = [string]$codexSha256
        RequireOpenAiSignature = [bool]$requireOpenAiSignature
    }
}

function ConvertFrom-DispatchResultEnvelope {
    param($Result)
    if ($null -eq $Result) { return $null }
    if ($Result -is [string]) {
        try { $parsed = ConvertFrom-Json -InputObject $Result -Depth 30 -NoEnumerate -ErrorAction Stop }
        catch { return $null }
        if (-not (Test-DispatchJsonObject $parsed)) { return $null }
        return $parsed
    }
    if (-not (Test-DispatchJsonObject $Result)) { return $null }
    $contentProperty = $Result.PSObject.Properties['content']
    if ($null -ne $contentProperty) {
        if ($contentProperty.Value -isnot [Array]) { return $null }
        $texts = @($contentProperty.Value | Where-Object {
            if (-not (Test-DispatchJsonObject $_)) { return $false }
            $typeProperty = $_.PSObject.Properties['type']
            $textProperty = $_.PSObject.Properties['text']
            return $null -ne $typeProperty -and $typeProperty.Value -is [string] -and
                $typeProperty.Value -ceq 'text' -and $null -ne $textProperty -and
                $textProperty.Value -is [string]
        })
        if ($texts.Count -eq 1) {
            try {
                $parsed = ConvertFrom-Json -InputObject $texts[0].PSObject.Properties['text'].Value `
                    -Depth 30 -NoEnumerate -ErrorAction Stop
            }
            catch { return $null }
            if (-not (Test-DispatchJsonObject $parsed)) { return $null }
            return $parsed
        }
    }
    $structuredProperty = $Result.PSObject.Properties['structured_content']
    if ($null -ne $structuredProperty -and (Test-DispatchJsonObject $structuredProperty.Value)) {
        return $structuredProperty.Value
    }
    return $null
}

function Get-DispatchGatewayResultOutcome {
    param(
        [AllowNull()]$RawResult,
        [AllowNull()]$Envelope,
        [Parameter(Mandatory)][string]$Context
    )

    $isError = Get-DispatchPropertyValue $RawResult 'isError'
    if ($null -eq $isError) { $isError = Get-DispatchPropertyValue $RawResult 'is_error' }
    if ($null -ne $isError -and $isError -isnot [bool]) {
        throw "$Context 的 isError 必须是 JSON boolean。"
    }
    if (-not (Test-DispatchJsonObject $Envelope)) {
        throw "$Context 缺少 gateway 结构化结果。"
    }
    $ok = Get-DispatchPropertyValue $Envelope 'ok'
    if ($ok -isnot [bool]) { throw "$Context 的结果缺少 JSON boolean ok。" }
    return $(if ($isError -eq $true -or $ok -ne $true) { 'failed' } else { 'success' })
}

function ConvertTo-DispatchMobileTransportMarker {
    param([Parameter(Mandatory)]$Result)

    if (-not (Test-DispatchJsonObject $Result)) {
        throw 'Codex mobile MCP result 必须是 JSON object。'
    }
    $isErrorProperty = $Result.PSObject.Properties['isError']
    if ($null -eq $isErrorProperty) { $isErrorProperty = $Result.PSObject.Properties['is_error'] }
    $isError = if ($null -eq $isErrorProperty) { $null } else { $isErrorProperty.Value }
    if ($null -ne $isError -and $isError -isnot [bool]) {
        throw 'Codex mobile MCP result 的 isError 必须是 JSON boolean。'
    }
    if ($isError -eq $true) { throw 'Codex mobile MCP result 标记为 isError。' }
    $contentProperty = $Result.PSObject.Properties['content']
    if ($null -eq $contentProperty) { throw 'Codex mobile MCP result 缺少 content。' }
    if ($contentProperty.Value -isnot [Array]) { throw 'Codex mobile MCP result content 必须是数组。' }
    $blocks = @($contentProperty.Value)
    if ($blocks.Count -lt 1) { throw 'Codex mobile MCP result content 不能为空。' }

    $contentTypes = [Collections.Generic.List[string]]::new()
    foreach ($block in $blocks) {
        if (-not (Test-DispatchJsonObject $block)) { throw 'Codex mobile MCP content block 必须是 JSON object。' }
        $typeProperty = $block.PSObject.Properties['type']
        $type = if ($null -eq $typeProperty) { $null } else { $typeProperty.Value }
        if ($type -isnot [string]) { throw 'Codex mobile MCP content block type 必须是字符串。' }
        switch ($type) {
            'text' {
                $textProperty = $block.PSObject.Properties['text']
                $text = if ($null -eq $textProperty) { $null } else { $textProperty.Value }
                if (-not ($text -is [string]) -or [string]::IsNullOrEmpty([string]$text)) {
                    throw 'Codex mobile MCP text block 缺少正文。'
                }
            }
            'image' {
                $dataProperty = $block.PSObject.Properties['data']
                $data = if ($null -eq $dataProperty) { $null } else { $dataProperty.Value }
                $mimeTypeProperty = $block.PSObject.Properties['mimeType']
                if ($null -eq $mimeTypeProperty) { $mimeTypeProperty = $block.PSObject.Properties['mime_type'] }
                $mimeType = if ($null -eq $mimeTypeProperty) { $null } else { $mimeTypeProperty.Value }
                if (-not ($data -is [string]) -or [string]::IsNullOrWhiteSpace([string]$data) -or
                    -not ($mimeType -is [string]) -or [string]$mimeType -notmatch '^image/[A-Za-z0-9.+-]+$') {
                    throw 'Codex mobile MCP image block 缺少合法 data/mimeType。'
                }
                $decoded = $null
                try { $decoded = [Convert]::FromBase64String([string]$data) }
                catch { throw 'Codex mobile MCP image block 不是合法 base64。' }
                finally {
                    if ($null -ne $decoded -and $decoded.Length -gt 0) { [Array]::Clear($decoded, 0, $decoded.Length) }
                }
            }
            default { throw "Codex mobile MCP result 含未知 content block：$type" }
        }
        $contentTypes.Add($type)
    }
    # 只返回形状证明，不保留 text/image/base64 原文。
    return [pscustomobject]@{
        Transport='mobile-content'
        ContentCount=$contentTypes.Count
        ContentTypes=[string[]]$contentTypes.ToArray()
    }
}

function Read-DispatchTraceTranscript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][ValidateSet('claude','codex')][string]$Brain,
        # 合法完整 trace 的 canonical 输出不变，默认模式仍要求完整 lifecycle；两种模式共享更严格的
        # 逐帧/JSON-object malformed 校验。此开关只额外放宽 EOF：可缺终态，最后一个调用可未完成。
        [switch]$AllowPartial
    )

    if (-not (Test-Path -LiteralPath $TracePath -PathType Leaf)) {
        throw "trace 不存在：$TracePath"
    }

    if ($Brain -eq 'claude') {
        $callsById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $calls = [Collections.Generic.List[object]]::new()
        $terminal = $null
        $terminalSeen = $false
        $eventOrdinal = 0
        foreach ($line in Get-Content -LiteralPath $TracePath -Encoding utf8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $eventOrdinal++
            if ($terminalSeen) { throw 'Claude trace 的 result 终态之后仍有事件。' }
            try {
                $event = ConvertFrom-Json -InputObject $line -Depth 40 -NoEnumerate -ErrorAction Stop
            }
            catch { throw 'Claude trace 含无法解析的非空 JSON 行。' }
            if (-not (Test-DispatchJsonObject -Value $event)) {
                throw 'Claude trace 的非空 JSON 行必须是顶层 JSON object。'
            }
            $eventType = Get-DispatchRequiredNonEmptyJsonString -InputObject $event -Name 'type' `
                -ErrorMessage 'Claude trace 事件缺少非空字符串 type。'
            switch ($eventType) {
                'assistant' {
                    $message = Get-DispatchRequiredJsonObject -InputObject $event -Name 'message' `
                        -ErrorMessage 'Claude assistant 事件缺少 JSON object message。'
                    $messageContentProperty = $message.PSObject.Properties['content']
                    $messageContent = $null
                    if ($null -ne $messageContentProperty) { $messageContent = $messageContentProperty.Value }
                    if ($null -eq $messageContent -or
                        $messageContent -isnot [Array]) {
                        throw 'Claude assistant 事件缺少 message.content 数组。'
                    }
                    foreach ($content in $messageContent) {
                        $contentType = Get-DispatchRequiredNonEmptyJsonString -InputObject $content -Name 'type' `
                            -ErrorMessage 'Claude assistant message.content 缺少非空字符串 type。'
                        if ($contentType -ine 'tool_use') { continue }
                        $id = Get-DispatchRequiredNonEmptyJsonString -InputObject $content -Name 'id' `
                            -ErrorMessage 'Claude trace 含缺失或非字符串的 tool_use id。'
                        if ($callsById.ContainsKey($id)) {
                            throw 'Claude trace 含缺失或重复的 tool_use id。'
                        }
                        $rawName = Get-DispatchRequiredNonEmptyJsonString -InputObject $content -Name 'name' `
                            -ErrorMessage 'Claude tool_use 缺少非空字符串工具名。'
                        $input = Get-DispatchRequiredJsonObject -InputObject $content -Name 'input' `
                            -ErrorMessage 'Claude tool_use.input 必须是 JSON object。'
                        $server = ''
                        $name = $rawName
                        $match = [regex]::Match($rawName, '^mcp__([^_]+)__(.+)$')
                        if ($match.Success) { $server = $match.Groups[1].Value; $name = $match.Groups[2].Value }
                        if ($calls.Count -gt 0 -and $calls[$calls.Count - 1].ResultCount -ne 1) {
                            throw 'Claude trace 在上一调用完成前启动了下一调用。'
                        }
                        $call = [pscustomobject]@{
                            Id=$id; Server=$server; Name=$name; RawName=$rawName
                            Input=$input
                            ResultEnvelope=$null; ResultCount=0; Outcome='started'
                            Ordinal=$calls.Count; StartedOrdinal=$eventOrdinal; CompletedOrdinal=$null
                            CompletedBeforeNext=$false
                        }
                        $callsById.Add($id, $call)
                        $calls.Add($call)
                    }
                }
                'user' {
                    $message = Get-DispatchRequiredJsonObject -InputObject $event -Name 'message' `
                        -ErrorMessage 'Claude user 事件缺少 JSON object message。'
                    $messageContentProperty = $message.PSObject.Properties['content']
                    $messageContent = $null
                    if ($null -ne $messageContentProperty) { $messageContent = $messageContentProperty.Value }
                    if ($null -eq $messageContent -or
                        $messageContent -isnot [Array]) {
                        throw 'Claude user 事件缺少 message.content 数组。'
                    }
                    foreach ($content in $messageContent) {
                        $contentType = Get-DispatchRequiredNonEmptyJsonString -InputObject $content -Name 'type' `
                            -ErrorMessage 'Claude user message.content 缺少非空字符串 type。'
                        if ($contentType -ine 'tool_result') { continue }
                        $id = Get-DispatchRequiredNonEmptyJsonString -InputObject $content -Name 'tool_use_id' `
                            -ErrorMessage 'Claude trace 含缺失或非字符串的 tool_result.tool_use_id。'
                        if (-not $callsById.ContainsKey($id)) {
                            throw 'Claude trace 含孤儿 tool_result。'
                        }
                        $call = $callsById[$id]
                        $call.ResultCount++
                        if ($call.ResultCount -ne 1) { throw 'Claude trace 含重复 tool_result。' }
                        $call.ResultEnvelope = ConvertFrom-DispatchResultEnvelope $content
                        $isError = Get-DispatchPropertyValue $content 'is_error'
                        if ($call.Server -ceq 'gateway') {
                            $call.Outcome = Get-DispatchGatewayResultOutcome -RawResult $content `
                                -Envelope $call.ResultEnvelope -Context "Claude gateway tool_result $id"
                        }
                        else {
                            if ($null -ne $isError -and $isError -isnot [bool]) {
                                throw "Claude tool_result $id 的 is_error 必须是 JSON boolean。"
                            }
                            $call.Outcome = $(if ($isError -eq $true) { 'failed' } else { 'success' })
                        }
                        $call.CompletedOrdinal = $eventOrdinal
                    }
                }
                'result' {
                    if ($null -ne $terminal) { throw 'Claude trace 含多个 result 终态。' }
                    $terminal = $event
                    $terminalSeen = $true
                }
                { $_ -in @('system','rate_limit_event') } { }
                default { throw "Claude trace 含未知事件类型：$eventType" }
            }
        }
        if ($eventOrdinal -eq 0) { throw 'Claude trace 为空。' }
        if ($null -eq $terminal -and -not $AllowPartial) { throw 'Claude trace 缺少唯一 result 终态。' }
        for ($index = 0; $index -lt $calls.Count; $index++) {
            $call = $calls[$index]
            $mayBeUnfinishedTail = $AllowPartial -and $null -eq $terminal -and
                $index -eq $calls.Count - 1 -and $call.ResultCount -eq 0
            if ($call.ResultCount -ne 1 -and -not $mayBeUnfinishedTail) {
                throw "Claude trace 的调用 $($call.Id) 没有唯一结果。"
            }
        }
        for ($index = 0; $index -lt $calls.Count; $index++) {
            if ($calls[$index].ResultCount -eq 0) {
                # AllowPartial 唯一容许的未完成项已在上一轮证明为最后一个调用。
                $calls[$index].CompletedBeforeNext = $false
                continue
            }
            $nextOrdinal = if ($index + 1 -lt $calls.Count) {
                [int]$calls[$index + 1].StartedOrdinal
            } elseif ($null -ne $terminal) { $eventOrdinal }
            else { $eventOrdinal + 1 }
            $calls[$index].CompletedBeforeNext = [int]$calls[$index].CompletedOrdinal -lt $nextOrdinal
            if (-not $calls[$index].CompletedBeforeNext) {
                throw "Claude trace 的调用 $($calls[$index].Id) 未在下一事件边界前完成。"
            }
        }
        $usage = Get-DispatchPropertyValue $terminal 'usage'
        $terminalSessionId = Get-DispatchPropertyValue $terminal 'session_id'
        $terminalSubtype = Get-DispatchPropertyValue $terminal 'subtype'
        $terminalResult = Get-DispatchPropertyValue $terminal 'result'
        if ($null -ne $terminal) {
            if (-not (Test-DispatchNonEmptyJsonString $terminalSubtype)) {
                throw 'Claude result 终态缺少非空字符串 subtype。'
            }
            $terminalSuccess = $terminalSubtype -ceq 'success'
            if ($null -ne $terminalSessionId -and $terminalSessionId -isnot [string]) {
                throw 'Claude result.session_id 必须是字符串。'
            }
            if ($null -ne $terminalResult -and $terminalResult -isnot [string]) {
                throw 'Claude result.result 必须是字符串。'
            }
            if ($terminalSuccess -and $null -eq $usage) {
                throw 'Claude success result 缺少 JSON object usage。'
            }
            if ($null -ne $usage -and -not (Test-DispatchJsonObject $usage)) {
                throw 'Claude result.usage 必须是 JSON object。'
            }
            if ($null -ne $usage) {
                foreach ($field in @(
                    'input_tokens','cache_read_input_tokens','output_tokens','cache_creation_input_tokens'
                )) {
                    $usageProperty = $usage.PSObject.Properties[$field]
                    if ($terminalSuccess -and $null -eq $usageProperty) {
                        throw "Claude success result.usage.$field 缺失。"
                    }
                    if ($null -ne $usageProperty -and
                        -not (Test-DispatchNonNegativeJsonInt64 -Value $usageProperty.Value)) {
                        throw "Claude result.usage.$field 非法。"
                    }
                }
            }
            $turnProperty = $terminal.PSObject.Properties['num_turns']
            if ($terminalSuccess -and $null -eq $turnProperty) {
                throw 'Claude success result.num_turns 缺失。'
            }
            if ($null -ne $turnProperty -and
                -not (Test-DispatchNonNegativeJsonInt64 -Value $turnProperty.Value)) {
                throw 'Claude result.num_turns 非法。'
            }
            $costProperty = $terminal.PSObject.Properties['total_cost_usd']
            if ($terminalSuccess -and $null -eq $costProperty) {
                throw 'Claude success result.total_cost_usd 缺失。'
            }
            if ($null -ne $costProperty -and
                -not (Test-DispatchNonNegativeJsonNumber -Value $costProperty.Value)) {
                throw 'Claude result.total_cost_usd 非法。'
            }
        }
        return [pscustomobject]@{
            Brain='claude'; Schema='claude-stream-json-v1'; SessionId=[string]$terminalSessionId
            Terminal=$(if ($null -eq $terminal) { $null } else {
                [pscustomobject]@{
                    Type='result'; Status=[string]$terminalSubtype
                    Success=([string]$terminalSubtype -ceq 'success')
                }
            })
            FinalText=$(if ($terminalResult -is [string]) { [string]$terminalResult } else { '' })
            Usage=[pscustomobject]@{
                InputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['input_tokens']) { [long]$usage.input_tokens } else { $null })
                CachedInputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_read_input_tokens']) { [long]$usage.cache_read_input_tokens } else { $null })
                OutputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['output_tokens']) { [long]$usage.output_tokens } else { $null })
                CacheWriteTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_creation_input_tokens']) { [long]$usage.cache_creation_input_tokens } else { $null })
            }
            Turns=$(if ($null -ne $terminal -and $null -ne $terminal.PSObject.Properties['num_turns']) {
                [int](Get-DispatchPropertyValue $terminal 'num_turns')
            } else { $null })
            CostUsd=$(if ($null -ne $terminal -and $null -ne $terminal.PSObject.Properties['total_cost_usd']) {
                [double](Get-DispatchPropertyValue $terminal 'total_cost_usd')
            } else { $null })
            Calls=[object[]]$calls.ToArray()
        }
    }

    $callsById = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $calls = [Collections.Generic.List[object]]::new()
    $sessionId = ''
    $threadStarted = 0
    $turnStarted = 0
    $turnTerminals = 0
    $terminal = $null
    $terminalSeen = $false
    # 仅在解析期间保留正文与 ordinal；canonical 只暴露最终正文，避免中间说明扩散到
    # console/ledger。ordinal 用来证明最终正文发生在全部 MCP completed 之后。
    $finalMessages = [Collections.Generic.List[object]]::new()
    $usage = $null
    $sawCodexError = $false
    $eventOrdinal = 0
    $terminalOrdinal = $null

    foreach ($line in Get-Content -LiteralPath $TracePath -Encoding utf8) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $eventOrdinal++
        if ($terminalSeen) { throw 'Codex trace 的 turn.completed 终态之后仍有事件。' }
        try {
            $event = ConvertFrom-Json -InputObject $line -Depth 40 -NoEnumerate -ErrorAction Stop
        }
        catch { throw 'Codex trace 含无法解析的非空 JSON 行。' }
        if (-not (Test-DispatchJsonObject -Value $event)) {
            throw 'Codex trace 的非空 JSON 行必须是顶层 JSON object。'
        }
        $eventType = Get-DispatchRequiredNonEmptyJsonString -InputObject $event -Name 'type' `
            -ErrorMessage 'Codex trace 事件缺少非空字符串 type。'
        switch ($eventType) {
            'thread.started' {
                $threadStarted++
                if ($threadStarted -ne 1 -or $turnStarted -gt 0 -or $calls.Count -gt 0) {
                    throw 'Codex trace 的 thread.started 缺失、重复或错序。'
                }
                $sessionId = Get-DispatchRequiredNonEmptyJsonString -InputObject $event -Name 'thread_id' `
                    -ErrorMessage 'Codex thread.started 缺少非空字符串 thread_id。'
            }
            'turn.started' {
                if ($threadStarted -ne 1 -or ++$turnStarted -ne 1) { throw 'Codex turn.started 重复或错序。' }
            }
            'item.started' {
                if ($threadStarted -ne 1 -or $turnStarted -ne 1) { throw 'Codex item.started 早于 turn.started。' }
                $item = Get-DispatchRequiredJsonObject -InputObject $event -Name 'item' `
                    -ErrorMessage 'Codex item.started 缺少 JSON object item。'
                $itemType = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'type' `
                    -ErrorMessage 'Codex item.started 缺少非空字符串 item.type。'
                if ($itemType -ceq 'reasoning') { continue }
                if ($itemType -cne 'mcp_tool_call') {
                    throw "Codex trace 含未授权 item.started 类型：$itemType"
                }
                $id = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'id' `
                    -ErrorMessage 'Codex trace 含缺失或非字符串的 mcp_tool_call id。'
                if ($callsById.ContainsKey($id)) {
                    throw 'Codex trace 含缺失或重复的 mcp_tool_call id。'
                }
                if ($calls.Count -gt 0 -and $calls[$calls.Count - 1].ResultCount -ne 1) {
                    throw 'Codex trace 在上一 MCP 调用 completed 前启动了下一调用。'
                }
                $server = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'server' `
                    -ErrorMessage 'Codex mcp_tool_call 缺少非空字符串 server。'
                $name = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'tool' `
                    -ErrorMessage 'Codex mcp_tool_call 缺少非空字符串 tool。'
                $arguments = Get-DispatchRequiredJsonObject -InputObject $item -Name 'arguments' `
                    -ErrorMessage 'Codex mcp_tool_call.arguments 必须是 JSON object。'
                $call = [pscustomobject]@{
                    Id=$id; Server=$server; Name=$name
                    RawName="mcp__${server}__${name}"; Input=$arguments
                    ResultEnvelope=$null; ResultCount=0; Outcome='started'
                    Ordinal=$calls.Count; StartedOrdinal=$eventOrdinal; CompletedOrdinal=$null
                    CompletedBeforeNext=$false
                    InputCanonical=($arguments | ConvertTo-Json -Compress -Depth 40)
                }
                $callsById.Add($id, $call)
                $calls.Add($call)
            }
            'item.completed' {
                if ($threadStarted -ne 1) { throw 'Codex item.completed 早于 thread.started。' }
                $item = Get-DispatchRequiredJsonObject -InputObject $event -Name 'item' `
                    -ErrorMessage 'Codex item.completed 缺少 JSON object item。'
                $itemType = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'type' `
                    -ErrorMessage 'Codex item.completed 缺少非空字符串 item.type。'
                if ($itemType -ceq 'error') {
                    $sawCodexError = $true
                    continue
                }
                if ($turnStarted -ne 1) { throw 'Codex item.completed 早于 turn.started。' }
                switch ($itemType) {
                    'reasoning' { continue }
                    'agent_message' {
                        if (-not ($item.text -is [string])) { throw 'Codex agent_message 缺少文本。' }
                        $finalMessages.Add([pscustomobject]@{
                            Text=[string]$item.text
                            Ordinal=$eventOrdinal
                        })
                    }
                    'mcp_tool_call' {
                        $id = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'id' `
                            -ErrorMessage 'Codex completed 含缺失或非字符串的 mcp_tool_call id。'
                        if (-not $callsById.ContainsKey($id)) {
                            throw 'Codex trace 含孤儿 mcp_tool_call completed。'
                        }
                        $call = $callsById[$id]
                        $completedServer = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'server' `
                            -ErrorMessage "Codex mcp_tool_call $id 的 completed 缺少非空字符串 server。"
                        $completedName = Get-DispatchRequiredNonEmptyJsonString -InputObject $item -Name 'tool' `
                            -ErrorMessage "Codex mcp_tool_call $id 的 completed 缺少非空字符串 tool。"
                        $completedArguments = Get-DispatchRequiredJsonObject -InputObject $item -Name 'arguments' `
                            -ErrorMessage "Codex mcp_tool_call $id 的 completed.arguments 必须是 JSON object。"
                        if ($call.Server -cne $completedServer -or $call.Name -cne $completedName) {
                            throw "Codex mcp_tool_call $id 的 started/completed 身份不一致。"
                        }
                        $completedInput = $completedArguments | ConvertTo-Json -Compress -Depth 40
                        if ($call.InputCanonical -cne $completedInput) {
                            throw "Codex mcp_tool_call $id 的 started/completed arguments 不一致。"
                        }
                        $call.ResultCount++
                        if ($call.ResultCount -ne 1) { throw "Codex mcp_tool_call $id 重复 completed。" }
                        $call.CompletedOrdinal = $eventOrdinal
                        $itemStatus = Get-DispatchPropertyValue $item 'status'
                        $itemError = Get-DispatchPropertyValue $item 'error'
                        if ($itemStatus -isnot [string] -or $itemStatus -cne 'completed' -or
                            $null -ne $itemError) {
                            $call.Outcome = 'failed'
                            $call.ResultEnvelope = $itemError
                            continue
                        }
                        $rawResult = Get-DispatchPropertyValue $item 'result'
                        $call.ResultEnvelope = if ($call.Server -ceq 'mobile') {
                            ConvertTo-DispatchMobileTransportMarker $rawResult
                        }
                        else { ConvertFrom-DispatchResultEnvelope $rawResult }
                        if ($null -eq $call.ResultEnvelope) { throw "Codex mcp_tool_call $id 缺少结构化结果。" }
                        if ($call.Server -ceq 'gateway') {
                            $call.Outcome = Get-DispatchGatewayResultOutcome -RawResult $rawResult `
                                -Envelope $call.ResultEnvelope -Context "Codex gateway mcp_tool_call $id"
                        }
                        else { $call.Outcome = 'success' }
                    }
                    default { throw "Codex trace 含未授权 item.completed 类型：$itemType" }
                }
            }
            'turn.completed' {
                if ($threadStarted -ne 1 -or $turnStarted -ne 1 -or ++$turnTerminals -ne 1) {
                    throw 'Codex turn.completed 重复或错序。'
                }
                $usage = Get-DispatchPropertyValue $event 'usage'
                $terminalSeen = $true
                $terminalOrdinal = $eventOrdinal
                $terminal = [pscustomobject]@{ Type='turn.completed'; Status='success'; Success=$true; Code='' }
            }
            'turn.failed' {
                if ($threadStarted -ne 1 -or $turnStarted -ne 1 -or ++$turnTerminals -ne 1) {
                    throw 'Codex turn.failed 重复或错序。'
                }
                $terminalSeen = $true
                $terminalOrdinal = $eventOrdinal
                $terminal = [pscustomobject]@{
                    Type='turn.failed'; Status='failed'; Success=$false
                    Code=$(if ($sawCodexError) { 'codex-error' } else { 'turn-failed' })
                }
            }
            'error' {
                $sawCodexError = $true
            }
            default { throw "Codex trace 含未知事件类型：$eventType" }
        }
    }
    if ($threadStarted -ne 1 -or ($null -eq $terminal -and -not $AllowPartial) -or
        ($null -ne $terminal -and $turnTerminals -ne 1)) {
        throw 'Codex trace 缺少唯一 thread/turn 终态。'
    }
    if ($null -ne $terminal -and $terminal.Success -and $sawCodexError) {
        throw 'Codex 成功终态之前出现 error diagnostics。'
    }
    if ($null -ne $terminal -and $terminal.Success -and $finalMessages.Count -lt 1) {
        throw 'Codex trace 缺少 agent_message 终态正文。'
    }
    for ($index = 0; $index -lt $calls.Count; $index++) {
        $call = $calls[$index]
        $mayBeUnfinishedTail = $AllowPartial -and $null -eq $terminal -and
            $index -eq $calls.Count - 1 -and $call.ResultCount -eq 0
        if ($call.ResultCount -ne 1 -and -not $mayBeUnfinishedTail) {
            throw "Codex mcp_tool_call $($call.Id) 缺少唯一 completed。"
        }
        if ($call.ResultCount -eq 0) {
            $call.CompletedBeforeNext = $false
            continue
        }
        $nextOrdinal = if ($index + 1 -lt $calls.Count) {
            [int]$calls[$index + 1].StartedOrdinal
        } elseif ($null -ne $terminal) { [int]$terminalOrdinal }
        else { $eventOrdinal + 1 }
        $call.CompletedBeforeNext = [int]$call.CompletedOrdinal -lt $nextOrdinal
        if (-not $call.CompletedBeforeNext) {
            throw "Codex mcp_tool_call $($call.Id) 未在下一调用/终态前 completed。"
        }
    }
    if ($null -ne $terminal -and $terminal.Success) {
        $lastMessage = $finalMessages[$finalMessages.Count - 1]
        $latestCallCompletion = -1
        foreach ($call in $calls) {
            $latestCallCompletion = [math]::Max($latestCallCompletion, [int]$call.CompletedOrdinal)
        }
        if ([int]$lastMessage.Ordinal -le $latestCallCompletion -or
            [int]$lastMessage.Ordinal -ge [int]$terminalOrdinal) {
            throw 'Codex 最后 agent_message 必须晚于全部 MCP completed 且早于 turn.completed。'
        }
    }
    if ($null -ne $terminal -and $terminal.Success) {
        if ($null -eq $usage -or -not (Test-DispatchJsonObject $usage)) {
            throw 'Codex turn.completed 缺少 JSON object usage。'
        }
        foreach ($field in @('input_tokens','cached_input_tokens','output_tokens')) {
            $property = $usage.PSObject.Properties[$field]
            if ($null -eq $property -or -not (Test-DispatchNonNegativeJsonInt64 $property.Value)) {
                throw "Codex turn.completed usage.$field 缺失或非法。"
            }
        }
        $cacheWriteProperty = $usage.PSObject.Properties['cache_write_input_tokens']
        if ($null -ne $cacheWriteProperty -and
            -not (Test-DispatchNonNegativeJsonInt64 $cacheWriteProperty.Value)) {
            throw 'Codex turn.completed usage.cache_write_input_tokens 非法。'
        }
    }
    return [pscustomobject]@{
        Brain='codex'; Schema='codex-jsonl-v1'; SessionId=$sessionId
        Terminal=$terminal
        FinalText=$(if ($finalMessages.Count -gt 0) { [string]$finalMessages[$finalMessages.Count - 1].Text } else { '' })
        Usage=[pscustomobject]@{
            InputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['input_tokens']) { [long]$usage.input_tokens } else { $null })
            CachedInputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cached_input_tokens']) { [long]$usage.cached_input_tokens } else { $null })
            OutputTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['output_tokens']) { [long]$usage.output_tokens } else { $null })
            CacheWriteTokens=$(if ($null -ne $usage -and $null -ne $usage.PSObject.Properties['cache_write_input_tokens']) { [long]$usage.cache_write_input_tokens } else { $null })
        }
        Turns=$(if ($null -ne $terminal) { 1 } else { $turnStarted })
        CostUsd=$null; Calls=[object[]]$calls.ToArray()
    }
}
