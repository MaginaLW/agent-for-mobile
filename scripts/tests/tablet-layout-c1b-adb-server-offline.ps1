#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1')
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-adb-server.ps1')

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('tablet-layout-c1b-adb-server-' + [guid]::NewGuid().ToString('N'))
$FakeRoot = Join-Path $TestRoot 'fake-sdk\platform-tools'
$FakeAdb = Join-Path $FakeRoot 'adb.exe'
$script:Passed = 0
$script:Failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    if ($null -eq $failure) { throw $Message }
    return $failure
}

function Get-StartupDiagnostic($Failure) {
    $diagnostic = $Failure.Exception.Data['TL1C1bPrivateAdbStartupDiagnostic']
    Assert-True ($null -ne $diagnostic) `
        ("private adb startup failure 缺少结构化 Exception.Data：" +
            $Failure.Exception.GetType().FullName + ' / ' + $Failure.Exception.Message +
            ' / inner=' + $(if($null-eq$Failure.Exception.InnerException){'<null>'}else{
                $Failure.Exception.InnerException.GetType().FullName + ' / ' +
                    $Failure.Exception.InnerException.Message}))
    Assert-True ((@($diagnostic.PSObject.Properties.Name) -join ',') -ceq
        'schema,outcome,final_substage,server_attempt_count,attempts') `
        'private adb startup diagnostic 顶层字段不闭合。'
    Assert-True ($diagnostic.schema -ceq
        'tablet-layout-c1b-private-adb-startup-diagnostic/v1' -and
        $diagnostic.outcome -ceq 'failed' -and
        [int]$diagnostic.server_attempt_count -eq @($diagnostic.attempts).Count) `
        'private adb startup diagnostic 顶层语义无效。'
    return $diagnostic
}

function Assert-StartupAttemptDiagnostic($Attempt) {
    Assert-True ((@($Attempt.PSObject.Properties.Name) -join ',') -ceq
        'ordinal,terminal_substage,listener_observed,server_process,status_clients,cleanup') `
        'private adb startup attempt 字段不闭合。'
    Assert-True ((@($Attempt.cleanup.PSObject.Properties.Name) -join ',') -ceq
        'status,process_exit_observed,streams_drained,port_rebind_verified') `
        'private adb startup attempt cleanup 字段不闭合。'
    Assert-True ($Attempt.cleanup.status -ceq 'completed' -and
        [bool]$Attempt.cleanup.process_exit_observed -and
        [bool]$Attempt.cleanup.streams_drained -and
        [bool]$Attempt.cleanup.port_rebind_verified) `
        'private adb startup attempt cleanup proof 不完整。'
}

function Assert-ProcessDiagnostic($ProcessDiagnostic) {
    Assert-True ((@($ProcessDiagnostic.PSObject.Properties.Name) -join ',') -ceq
        'started,exit_observed,exit_code,stdout,stderr') `
        'private adb process diagnostic 字段不闭合。'
    foreach ($stream in @($ProcessDiagnostic.stdout, $ProcessDiagnostic.stderr)) {
        Assert-True ((@($stream.PSObject.Properties.Name) -join ',') -ceq
            'observed_bytes,captured_bytes,overflowed,captured_sha256,strict_utf8,classification') `
            'private adb stream diagnostic 字段不闭合。'
        Assert-True ([long]$stream.observed_bytes -ge [long]$stream.captured_bytes -and
            [int]$stream.captured_bytes -ge 0 -and
            [string]$stream.captured_sha256 -cmatch '^sha256:[0-9a-f]{64}$') `
            'private adb stream diagnostic byte/hash 语义无效。'
    }
}

function Get-GuardedClientDiagnostic(
    $Failure, [string]$OperationClass, [string]$Substage, [string[]]$ForbiddenText) {
    $diagnostic = $Failure.Exception.Data['TL1C1bPrivateAdbClientDiagnostic']
    Assert-True ($null -ne $diagnostic) 'guarded client failure 缺少结构化诊断。'
    Assert-True ((@($diagnostic.PSObject.Properties.Name) -join ',') -ceq
        'schema,client_kind,operation_class,failure_substage,diagnostic_complete,install_failure_code,process,cleanup') `
        'guarded client diagnostic 字段不闭合。'
    Assert-True ($diagnostic.schema -ceq
        'tablet-layout-c1b-private-adb-guarded-client-diagnostic/v1' -and
        $diagnostic.client_kind -ceq 'Adb' -and
        $diagnostic.operation_class -ceq $OperationClass -and
        $diagnostic.failure_substage -ceq $Substage -and
        $diagnostic.diagnostic_complete -is [bool] -and $diagnostic.diagnostic_complete) `
        'guarded client 类型/操作分类/失败子阶段诊断漂移。'
    $process = $diagnostic.process
    Assert-True ((@($process.PSObject.Properties.Name | Sort-Object) -join ',') -ceq
        'exit_code,exit_observed,started,stderr,stdout' -and
        $process.started -is [bool] -and $process.exit_observed -is [bool]) `
        'guarded client process 字段或观测类型不闭合。'
    if (-not $process.exit_observed) {
        Assert-True ($null -eq $process.exit_code) '未观测退出时 exit_code 必须为 null。'
    }
    foreach ($stream in @($process.stdout, $process.stderr)) {
        Assert-True ((@($stream.PSObject.Properties.Name | Sort-Object) -join ',') -ceq
            'maximum_bytes,observed_bytes,overflowed' -and
            [long]$stream.observed_bytes -ge 0 -and [long]$stream.maximum_bytes -ge 4096 -and
            $stream.overflowed -is [bool]) 'guarded client stream 有界统计字段无效。'
    }
    Assert-True ($diagnostic.cleanup.status -cin @('completed','failed')) `
        'guarded client cleanup 状态无效。'
    $message = [string]$Failure.Exception.Message
    foreach ($safeLabel in @('Adb',$OperationClass,$Substage,'exit_observed','exit_code',
            'stdout','stderr','observed_bytes','overflowed')) {
        Assert-True ($message.Contains($safeLabel, [StringComparison]::OrdinalIgnoreCase)) `
            'guarded client message 缺少安全操作或数值诊断字段。'
    }
    $serialized = $diagnostic | ConvertTo-Json -Depth 8 -Compress
    $exceptionText = $Failure.Exception.ToString()
    foreach ($canary in $ForbiddenText) {
        Assert-True (-not $message.Contains($canary) -and
            -not $serialized.Contains($canary) -and -not $exceptionText.Contains($canary)) `
            'guarded client message/Data/exception 泄露输入、原始输出或内部异常哨兵。'
    }
    return $diagnostic
}

function Get-FailureCanaryObservation($State, [string]$Stage) {
    $text = "$Stage|$($State.Root)|$($State.Secret)|诊断|$('Z' * 512)"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    try {
        return [pscustomobject]@{
            Bytes = $bytes.Length
            Sha256 = 'sha256:' + [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
    } finally { if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Output "PASS  $Name"
    } catch {
        $script:Failed++
        Write-Output "FAIL  $Name :: $($_.Exception.Message)"
    }
}

function New-FakeState([string]$Name, [string]$Mode = 'normal') {
    $root = Join-Path $TestRoot $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return [pscustomobject][ordered]@{
        Root = $root
        Mode = $Mode
        Secret = 'SERIAL-SECRET-' + $Name
        Environment = @{
            SYSTEMROOT = [string]$env:SystemRoot
            WINDIR = [string]$env:SystemRoot
            COMSPEC = Join-Path $env:SystemRoot 'System32\cmd.exe'
            PATH = Join-Path $env:SystemRoot 'System32'
            PATHEXT = '.COM;.EXE;.BAT;.CMD'
            TEMP = $root
            TMP = $root
            TL1_C1B_FAKE_ADB_STATE = $root
            TL1_C1B_FAKE_ADB_MODE = $Mode
            ANDROID_SERIAL = 'SERIAL-SECRET-' + $Name
            ADB_SERVER_SOCKET = 'tcp:127.0.0.1:5037'
            ADB_TRACE = 'all'
        }
    }
}

function Get-FakeInvocationLines($State) {
    $path = Join-Path $State.Root 'invocations.log'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [string[]]@() }
    return [string[]]@(Get-Content -LiteralPath $path)
}

function Get-FakeInvocationPorts($State) {
    $ports = [Collections.Generic.HashSet[int]]::new()
    foreach ($line in Get-FakeInvocationLines $State) {
        foreach ($match in [regex]::Matches(
                $line, '(?:tcp:(?:127\.0\.0\.1|localhost):|-P,)([0-9]{5})')) {
            [void]$ports.Add([int]$match.Groups[1].Value)
        }
    }
    return [int[]]@($ports)
}

function Assert-StateHasNoLivePort($State) {
    foreach ($port in Get-FakeInvocationPorts $State) {
        $deadline = [DateTime]::UtcNow.AddSeconds(3)
        do {
            if (Test-TL1C1bPrivateAdbPortAvailable $port) { break }
            Start-Sleep -Milliseconds 50
        } while ([DateTime]::UtcNow -lt $deadline)
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            "fake adb 失败路径遗留 listener：$port"
    }
}

function Get-PrivateGuardPort($Guard) {
    $arguments = Get-TL1C1bPrivateAdbClientArguments $Guard
    Assert-True ($arguments.Count -eq 4 -and
        [string]$arguments[0] -ceq '-H' -and
        [string]$arguments[1] -ceq '127.0.0.1' -and
        [string]$arguments[2] -ceq '-P') 'opaque guard client argument shape 无效。'
    return [int][string]$arguments[3]
}

function New-FakeAdbExecutable {
    New-Item -ItemType Directory -Path $FakeRoot -Force | Out-Null
    $sourcePath = Join-Path $FakeRoot 'fake-adb.cs'
    $source = @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class Program {
    private static string StateRoot {
        get { return Environment.GetEnvironmentVariable("TL1_C1B_FAKE_ADB_STATE") ?? ""; }
    }

    private static string Mode {
        get { return Environment.GetEnvironmentVariable("TL1_C1B_FAKE_ADB_MODE") ?? "normal"; }
    }

    private static string SelfPath {
        get { return Process.GetCurrentProcess().MainModule.FileName; }
    }

    private static string ProtoQuote(string value) {
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    private static void Log(string[] args) {
        if (StateRoot.Length == 0) return;
        Directory.CreateDirectory(StateRoot);
        string line = Process.GetCurrentProcess().Id + "|" +
            (Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET") ?? "<missing>") + "|" +
            String.Join(",", args) + Environment.NewLine;
        for (int attempt = 0; attempt < 20; attempt++) {
            try {
                File.AppendAllText(Path.Combine(StateRoot, "invocations.log"), line,
                    new UTF8Encoding(false));
                return;
            } catch (IOException) { Thread.Sleep(10); }
        }
    }

    private static int ParsePort(string socket, string prefix) {
        if (!socket.StartsWith(prefix, StringComparison.Ordinal)) return -1;
        int port;
        return Int32.TryParse(socket.Substring(prefix.Length), out port) ? port : -1;
    }

    private static byte[] ReadExact(NetworkStream stream, int count) {
        byte[] bytes = new byte[count];
        int offset = 0;
        while (offset < bytes.Length) {
            int read = stream.Read(bytes, offset, bytes.Length - offset);
            if (read <= 0) throw new EndOfStreamException();
            offset += read;
        }
        return bytes;
    }

    private static void WriteFrame(NetworkStream stream, string payload) {
        byte[] bytes = new UTF8Encoding(false, true).GetBytes(payload);
        byte[] length = Encoding.ASCII.GetBytes(bytes.Length.ToString("X4", CultureInfo.InvariantCulture));
        stream.Write(length, 0, length.Length);
        stream.Write(bytes, 0, bytes.Length);
    }

    private static string ServerStatusText() {
        string executable = Mode == "wrong_status_path"
            ? Path.Combine(StateRoot, "other-adb.exe") : SelfPath;
        return "usb_backend: LIBADBUSB\n" +
            "usb_backend_forced: false\n" +
            "mdns_backend: LIBADBMDNS\n" +
            "mdns_backend_forced: false\n" +
            "version: \"37.0.1\"\n" +
            "build: \"fake-platform-tools-37.0.1\"\n" +
            "executable_absolute_path: " + ProtoQuote(executable) + "\n" +
            "log_absolute_path: " + ProtoQuote(Path.Combine(StateRoot, "adb.log")) + "\n" +
            "os: \"fake-windows\"\n" +
            "burst_mode: false\n" +
            "mdns_enabled: false\n" +
            "keystore_path: " + ProtoQuote(Path.Combine(StateRoot, "adbkey")) + "\n" +
            "known_hosts_path: " + ProtoQuote(Path.Combine(StateRoot, "adb_known_hosts.pb")) + "\n";
    }

    private static void WriteFailureCanary(string stage) {
        string secret = "SERIAL-SECRET-" + new DirectoryInfo(StateRoot).Name;
        Console.Error.Write(stage + "|" + StateRoot + "|" + secret +
            "|\u8BCA\u65AD|" + new String('Z', 512));
        Console.Error.Flush();
    }

    private static bool HandleSmartSocketClient(TcpClient client) {
        using (client) using (NetworkStream stream = client.GetStream()) {
            stream.ReadTimeout = 1500;
            stream.WriteTimeout = 1500;
            string lengthText = Encoding.ASCII.GetString(ReadExact(stream, 4));
            int length;
            if (!Int32.TryParse(lengthText, NumberStyles.HexNumber,
                    CultureInfo.InvariantCulture, out length) || length < 1 || length > 1024) {
                return false;
            }
            string service = new UTF8Encoding(false, true).GetString(ReadExact(stream, length));
            byte[] okay = Encoding.ASCII.GetBytes("OKAY");
            if (service == "host:server-status") {
                stream.Write(okay, 0, okay.Length);
                WriteFrame(stream, ServerStatusText());
                return false;
            }
            if (service == "host:kill") {
                stream.Write(okay, 0, okay.Length);
                return Mode != "ignore_kill";
            }
            byte[] fail = Encoding.ASCII.GetBytes("FAIL");
            stream.Write(fail, 0, fail.Length);
            WriteFrame(stream, "unsupported fake service");
            return false;
        }
    }

    private static int RunListener(int port, bool stoppable) {
        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Server.ExclusiveAddressUse = true;
        listener.Start(8);
        try {
            while (true) {
                if (listener.Pending()) {
                    TcpClient client = listener.AcceptTcpClient();
                    if (HandleSmartSocketClient(client) && stoppable) return 0;
                }
                Thread.Sleep(20);
            }
        } finally { listener.Stop(); }
    }

    private static int RunServer(string[] args) {
        if (args.Length != 4 || args[0] != "-L" || args[2] != "server" ||
            args[3] != "nodaemon") return 81;
        int port = ParsePort(args[1], "tcp:localhost:");
        if (port < 49152 || port > 65535) return 82;
        string clientSocket = "tcp:127.0.0.1:" +
            port.ToString(CultureInfo.InvariantCulture);
        if (Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET") != clientSocket) return 83;
        if (Mode == "server_exit_before_listener") {
            WriteFailureCanary("server-fast-exit");
            return 93;
        }
        if (Mode == "output_overflow") {
            Console.Out.Write(new String('X', 131072));
            Console.Out.Flush();
        }
        if (Mode == "hang_without_listener") {
            while (true) Thread.Sleep(1000);
        }
        if (Mode == "child_listener") {
            Thread.Sleep(500);
            ProcessStartInfo child = new ProcessStartInfo();
            child.FileName = SelfPath;
            child.Arguments = "--listener-child " + port;
            child.UseShellExecute = false;
            Process.Start(child);
            while (true) Thread.Sleep(1000);
        }
        return RunListener(port, true);
    }

    private static string SendService(int port, string service, bool readPayload) {
        using (TcpClient client = new TcpClient()) {
            IAsyncResult pending = client.BeginConnect(IPAddress.Loopback, port, null, null);
            try {
                if (!pending.AsyncWaitHandle.WaitOne(1000)) throw new IOException("connect timeout");
                client.EndConnect(pending);
            } finally { pending.AsyncWaitHandle.Close(); }
            using (NetworkStream stream = client.GetStream()) {
                stream.ReadTimeout = 1500;
                stream.WriteTimeout = 1500;
                byte[] serviceBytes = new UTF8Encoding(false, true).GetBytes(service);
                byte[] length = Encoding.ASCII.GetBytes(
                    serviceBytes.Length.ToString("X4", CultureInfo.InvariantCulture));
                stream.Write(length, 0, length.Length);
                stream.Write(serviceBytes, 0, serviceBytes.Length);
                string status = Encoding.ASCII.GetString(ReadExact(stream, 4));
                if (status != "OKAY") throw new IOException("fake smart socket rejected service");
                if (!readPayload) return "";
                string payloadLengthText = Encoding.ASCII.GetString(ReadExact(stream, 4));
                int payloadLength;
                if (!Int32.TryParse(payloadLengthText, NumberStyles.HexNumber,
                        CultureInfo.InvariantCulture, out payloadLength) ||
                    payloadLength < 1 || payloadLength > 65536) {
                    throw new IOException("invalid fake smart socket payload length");
                }
                return new UTF8Encoding(false, true).GetString(ReadExact(stream, payloadLength));
            }
        }
    }

    private static int RunClient(string[] args) {
        if (args.Length < 5 || args[0] != "-H" || args[1] != "127.0.0.1" ||
            args[2] != "-P") return 84;
        int port;
        if (!Int32.TryParse(args[3], out port)) return 85;
        string socket = "tcp:127.0.0.1:" + port;
        if (Environment.GetEnvironmentVariable("ADB_SERVER_SOCKET") != socket) return 86;
        if (args[4] == "server-status") {
            if (Mode == "server_status_client_exit") {
                WriteFailureCanary("status-client-exit");
                return 94;
            }
            if (Mode == "auto_start") {
                try { SendService(port, "host:kill", false); } catch { }
                for (int attempt = 0; attempt < 100; attempt++) {
                    try {
                        using (TcpClient probe = new TcpClient()) {
                            probe.Connect(IPAddress.Loopback, port);
                        }
                        Thread.Sleep(10);
                    } catch { break; }
                }
                ProcessStartInfo child = new ProcessStartInfo();
                child.FileName = SelfPath;
                child.Arguments = "--listener-child " + port;
                child.UseShellExecute = false;
                Process.Start(child);
                Thread.Sleep(1500);
                return 91;
            }
            Console.Write(SendService(port, "host:server-status", true));
            return 0;
        }
        if (args[4] == "kill-server") {
            SendService(port, "host:kill", false);
            return 0;
        }
        if (args[4] == "devices") {
            if (Mode == "guarded_timeout") {
                Console.Write("guarded-timeout-stdout-canary");
                Console.Out.Flush();
                WriteFailureCanary("guarded-timeout-stderr");
                while (true) Thread.Sleep(1000);
            }
            if (Mode == "business_auto_start") {
                try { SendService(port, "host:kill", false); } catch { }
                for (int attempt = 0; attempt < 100; attempt++) {
                    try {
                        using (TcpClient probe = new TcpClient()) {
                            probe.Connect(IPAddress.Loopback, port);
                        }
                        Thread.Sleep(10);
                    } catch { break; }
                }
                ProcessStartInfo child = new ProcessStartInfo();
                child.FileName = SelfPath;
                child.Arguments = "--listener-child " + port;
                child.UseShellExecute = false;
                Process.Start(child);
                File.WriteAllText(Path.Combine(StateRoot, "business-side-effect.txt"), "executed");
                return 92;
            }
            Console.Write("List of devices attached\r\nFAKE123\tdevice\r\n");
            return 0;
        }
        if (Mode == "buffered_semantics" && args.Length == 11 &&
            args[4] == "-s" && args[5] == "FAKE123" && args[6] == "exec-in" &&
            args[7] == "content" && args[8] == "write" && args[9] == "--uri") {
            using (Stream input = Console.OpenStandardInput())
            using (Stream output = Console.OpenStandardOutput()) input.CopyTo(output);
            return 0;
        }
        if (Mode == "buffered_semantics" && args.Length == 9 &&
            args[4] == "-s" && args[5] == "FAKE123" && args[6] == "shell" &&
            args[7] == "getprop" && args[8] == "ro.build.fingerprint") {
            Console.Write("failure-output");
            Console.Error.Write("fixture-error");
            return 23;
        }
        if (Mode.StartsWith("install_diag_", StringComparison.Ordinal)) {
            string detail = "INSTALL-BODY-CANARY|" + StateRoot + "|敏感-token";
            string frame = "Failure [INSTALL_FAILED_USER_RESTRICTED: " + detail + "]";
            if (Mode == "install_diag_no_status") {
                Console.Write("install-no-status-stdout|" + detail);
                Console.Error.Write("install-no-status-stderr|" + detail);
                return 1;
            } else if (Mode == "install_diag_stderr" || Mode == "install_diag_stderr_windows" ||
                Mode == "install_diag_stderr_windows_bad_dot" ||
                Mode == "install_diag_stderr_windows_suffix") {
                string program = "adb";
                if (Mode == "install_diag_stderr_windows") program = "adb.exe";
                else if (Mode == "install_diag_stderr_windows_bad_dot") program = "adbxexe";
                else if (Mode == "install_diag_stderr_windows_suffix") program = "adb.exe.bad";
                Console.WriteLine("Performing Streamed Install");
                Console.Error.WriteLine(program + ": failed to install " + SelfPath + ": " + frame);
            } else if (Mode == "install_diag_unknown") {
                Console.Error.WriteLine("Failure [INSTALL_FAILED_UNREVIEWED_VENDOR_CODE: " + detail + "]");
            } else if (Mode == "install_diag_truncated") {
                Console.Write(frame.Substring(0, frame.Length - 1));
            } else {
                Console.WriteLine(frame);
                Console.Out.Flush();
                if (Mode == "install_diag_conflict")
                    Console.Error.WriteLine("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]");
                else if (Mode == "install_diag_stdout_utf8")
                    Console.OpenStandardOutput().WriteByte(255);
                else if (Mode == "install_diag_stderr_utf8")
                    Console.OpenStandardError().WriteByte(255);
                else if (Mode == "install_diag_stdout_overflow")
                    Console.Write(new string('X', 8192));
                else if (Mode == "install_diag_stderr_overflow")
                    Console.Error.Write(new string('X', 1048577));
                else if (Mode == "install_diag_timeout")
                    while (true) Thread.Sleep(1000);
                else Console.Error.Write(detail);
            }
            return 23;
        }
        if (args.Length == 9 && args[4] == "-s" && args[6] == "exec-out" &&
            args[7] == "cat" && args[8].EndsWith("/base.apk", StringComparison.Ordinal)) {
            byte[] block = new byte[65536];
            for (int index = 0; index < block.Length; index++) block[index] = (byte)(index % 251);
            Stream output = Console.OpenStandardOutput();
            for (int index = 0; index < 32; index++) output.Write(block, 0, block.Length);
            for (int index = 0; index < 37; index++) output.WriteByte((byte)(index % 251));
            output.Flush();
            return 0;
        }
        return 88;
    }

    public static int Main(string[] args) {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        Log(args);
        if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("ANDROID_SERIAL")) ||
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("ADB_TRACE"))) {
            if (StateRoot.Length != 0) {
                File.WriteAllText(Path.Combine(StateRoot, "serial-or-trace-leak.txt"), "leak");
            }
            return 90;
        }
        if (args.Length == 2 && args[0] == "--listener-child") {
            int childPort;
            return Int32.TryParse(args[1], out childPort)
                ? RunListener(childPort, false) : 89;
        }
        if (args.Length > 0 && args[0] == "-L") return RunServer(args);
        return RunClient(args);
    }
}
'@
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    Assert-True (Test-Path -LiteralPath $csc -PathType Leaf) `
        '离线 fake adb 测试缺少 Windows csc.exe。'
    & $csc /nologo /target:exe "/out:$FakeAdb" $sourcePath
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $FakeAdb -PathType Leaf)) `
        '无法编译离线 fake adb.exe。'
}

New-Item -ItemType Directory -Path $TestRoot | Out-Null
try {
    New-FakeAdbExecutable

    Test-Case 'random high port 与 exclusive loopback probe' {
        $candidates = [int[]]@(1..32 | ForEach-Object {
            Get-TL1C1bPrivateAdbRandomHighPortCandidate
        })
        Assert-True (@($candidates | Where-Object { $_ -lt 49152 -or $_ -gt 65535 }).Count -eq 0) `
            '随机端口越出 IANA dynamic/private 高位范围。'
        Assert-True (@($candidates | Select-Object -Unique).Count -gt 1) `
            '随机端口候选未体现随机性。'
        $listener = $null
        $occupiedPort = 0
        for ($attempt = 0; $attempt -lt 64 -and $null -eq $listener; $attempt++) {
            $candidate = Get-TL1C1bPrivateAdbRandomHighPortCandidate
            $candidateListener = [Net.Sockets.TcpListener]::new(
                [Net.IPAddress]::Loopback, $candidate)
            try {
                $candidateListener.Server.ExclusiveAddressUse = $true
                $candidateListener.Start()
                $listener = $candidateListener
                $occupiedPort = $candidate
            } catch [Net.Sockets.SocketException] {
                $candidateListener.Stop()
            }
        }
        Assert-True ($null -ne $listener) '无法为 exclusive probe 占用随机高位端口。'
        try {
            Assert-True ($occupiedPort -ge 49152 -and $occupiedPort -le 65535) `
                'exclusive probe 未使用高位端口。'
            Assert-True (-not (Test-TL1C1bPrivateAdbPortAvailable $occupiedPort)) `
                'exclusive probe 未拒绝已占用端口。'
        } finally { $listener.Stop() }
        foreach ($invalidSocket in @(
            'tcp:127.0.0.1:49100', 'tcp:127.0.0.1:49151',
            'tcp:127.0.0.1:65536', 'tcp:127.0.0.1:05037')) {
            [void](Assert-Throws {
                New-TL1C1bPrivateAdbEnvironment @{} $invalidSocket | Out-Null
            } "越界/非 canonical private socket 未被拒绝：$invalidSocket")
        }
        foreach ($validSocket in @('tcp:127.0.0.1:49152','tcp:127.0.0.1:65535')) {
            $environment = New-TL1C1bPrivateAdbEnvironment @{} $validSocket
            Assert-True ($environment.ADB_SERVER_SOCKET -ceq $validSocket) `
                "合法边界 private socket 被改写：$validSocket"
        }
    }

    Test-Case 'fake server 明确拒绝旧 numeric/literal-IP -L listen spec' {
        $state = New-FakeState 'legacy-listen-spec'
        $port = 0
        for ($attempt = 0; $attempt -lt 64 -and $port -eq 0; $attempt++) {
            $candidate = Get-TL1C1bPrivateAdbRandomHighPortCandidate
            if (Test-TL1C1bPrivateAdbPortAvailable $candidate) { $port = $candidate }
        }
        Assert-True ($port -ge 49152 -and $port -le 65535) `
            '无法为 legacy -L 拒绝测试选取空闲高位端口。'
        $socket = "tcp:127.0.0.1:$port"
        $environment = New-TL1C1bPrivateAdbEnvironment $state.Environment $socket
        foreach ($legacySpec in @([string]$port, $socket)) {
            $result = Invoke-TL1C1aProcess -FilePath $FakeAdb `
                -Arguments @('-L', $legacySpec, 'server', 'nodaemon') `
                -Operation 'fake legacy listen spec rejection' `
                -Environment $environment -ClearEnvironment -TimeoutSec 2 -AllowFailure
            Assert-True ($result.ExitCode -eq 82 -and $result.Bytes.Length -eq 0 -and
                $result.Stderr.Length -eq 0) `
                "fake adb 未明确拒绝 legacy -L listen spec：$legacySpec"
        }
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            'legacy -L 拒绝路径意外创建 listener。'
        $legacyLines = Get-FakeInvocationLines $state
        Assert-True ($legacyLines.Count -eq 2 -and
            @($legacyLines | Where-Object {
                $_ -match '\|-L,(?:[0-9]{5}|tcp:127\.0\.0\.1:[0-9]{5}),server,nodaemon$'
            }).Count -eq 2) 'legacy -L 拒绝 fixture 未记录两个精确输入。'
    }

    Test-Case '37.0.1 server-status closed grammar/enums/path 严格绑定' {
        $quoted = $FakeAdb.Replace('\','\\').Replace('"','\"')
        $quotedKeystore = (Join-Path $TestRoot 'fake-adbkey').Replace('\','\\').Replace('"','\"')
        $quotedKnownHosts = (Join-Path $TestRoot 'fake-known-hosts.pb').Replace('\','\\').Replace('"','\"')
        $valid = "usb_backend: LIBADBUSB`n" +
            "usb_backend_forced: false`n" +
            "mdns_backend: LIBADBMDNS`n" +
            "mdns_backend_forced: false`n" +
            "version: `"37.0.1`"`n" +
            "build: `"fake-platform-tools-37.0.1`"`n" +
            "executable_absolute_path: `"$quoted`"`n" +
            "keystore_path: `"$quotedKeystore`"`n" +
            "known_hosts_path: `"$quotedKnownHosts`"`n"
        $held = [IO.File]::Open(
            $FakeAdb, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $identity = [TL1C1bPrivateAdbNative]::GetFileIdentity($held.SafeFileHandle) }
        finally { $held.Dispose() }
        Assert-True (Assert-TL1C1bPrivateAdbServerStatus $valid $FakeAdb $identity) `
            '37.0.1 LIBADBUSB/LIBADBMDNS 与 optional path fields 被拒绝。'
        $mdnsDisabled = "usb_backend: LIBADBUSB`n" +
            "mdns_backend: MDNS_DISABLED`n" +
            "executable_absolute_path: `"$quoted`"`n"
        Assert-True (Assert-TL1C1bPrivateAdbServerStatus $mdnsDisabled $FakeAdb $identity) `
            '37.0.1 MDNS_DISABLED enum grammar 被拒绝。'
        $usbDisabled = "usb_backend: USB_DISABLED`n" +
            "mdns_backend: LIBADBMDNS`n" +
            "executable_absolute_path: `"$quoted`"`n"
        $disabledFailure = Assert-Throws {
            Assert-TL1C1bPrivateAdbServerStatus $usbDisabled $FakeAdb $identity
        } '37.0.1 USB_DISABLED 未在 ready proof fail closed。'
        Assert-True ($disabledFailure.Exception.Message -match '可用 USB backend') `
            'USB_DISABLED 被当成未知 enum，而非明确拒绝不可用 backend。'
        [void](Assert-Throws {
            Assert-TL1C1bPrivateAdbServerStatus `
                ($valid + "unknown_field: `"x`"`n") $FakeAdb $identity
        } '未知 server-status 字段未被拒绝。')
        [void](Assert-Throws {
            Assert-TL1C1bPrivateAdbServerStatus `
                ($valid + "executable_absolute_path: `"$quoted`"`n") $FakeAdb $identity
        } '重复 executable_absolute_path 未被拒绝。')

        $caseVariant = [IO.Path]::Combine(
            [IO.Path]::GetDirectoryName($FakeAdb), 'ADB.exe')
        $caseQuoted = $caseVariant.Replace('\','\\').Replace('"','\"')
        [void](Assert-Throws {
            Assert-TL1C1bPrivateAdbServerStatus `
                "executable_absolute_path: `"$caseQuoted`"`n" $FakeAdb $identity
        } '大小写别名 executable path 未被拒绝。')

        $aliasRoot = Join-Path $TestRoot 'status-hardlink-alias'
        New-Item -ItemType Directory -Path $aliasRoot | Out-Null
        $aliasAdb = Join-Path $aliasRoot 'adb.exe'
        New-Item -ItemType HardLink -Path $aliasAdb -Target $FakeAdb | Out-Null
        try {
            $aliasQuoted = $aliasAdb.Replace('\','\\').Replace('"','\"')
            [void](Assert-Throws {
                Assert-TL1C1bPrivateAdbServerStatus `
                    "executable_absolute_path: `"$aliasQuoted`"`n" $FakeAdb $identity
            } '同 file identity 的别名 executable path 未被拒绝。')
        } finally { Remove-Item -LiteralPath $aliasAdb -Force }
    }

    Test-Case 'private nodaemon ready/env/owner/status 与 graceful cleanup 全链路' {
        $state = New-FakeState 'success'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        try {
            $binding = Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard
            $bindingAgain = Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard
            Assert-True (-not [object]::ReferenceEquals($binding, $bindingAgain)) `
                'Assert 未每次重建独立只读 Binding。'
            $port = Get-PrivateGuardPort $guard
            $guardState = Get-TL1C1bPrivateAdbGuardState $guard
            $owners = @(Get-TL1C1bPrivateAdbListenerOwners $port)
            Assert-True ($port -ge 49152 -and $port -le 65535) 'guard 端口不在高位范围。'
            Assert-True ($owners.Count -eq 1 -and
                [string]$owners[0].Address -ceq '127.0.0.1' -and
                [int]$owners[0].ProcessId -eq [int]$guardState.ProcessId) `
                'listener owner 未精确绑定 127.0.0.1 与 held server PID。'
            Assert-True ($binding.server_mode -ceq 'private_nodaemon' -and
                $binding.listener_pid_verified -and
                $binding.server_status_executable_path_verified -and
                -not $binding.default_server_used) 'private server binding 不完整。'
            $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
            Assert-True ($environment.ADB_SERVER_SOCKET -ceq "tcp:127.0.0.1:$port") `
                'client environment 未绑定精确 ADB_SERVER_SOCKET。'
            Assert-True (-not $environment.ContainsKey('ANDROID_SERIAL') -and
                -not $environment.ContainsKey('ADB_TRACE')) 'client environment 泄露 serial/trace。'
            $arguments = Get-TL1C1bPrivateAdbClientArguments $guard
            Assert-True (($arguments -join '|') -ceq "-H|127.0.0.1|-P|$port") `
                'client -H/-P prefix 不精确。'
            $cleanup = Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 3
            Assert-True ($cleanup.server_cleanup_verified -and
                $cleanup.private_kill_server_requested -and
                $cleanup.graceful_exit_verified -and
                -not $cleanup.job_fallback_used -and
                $cleanup.port_rebind_verified) 'graceful cleanup proof 不完整。'
            $again = Close-TL1C1bPrivateAdbServerGuard $guard
            Assert-True ($again.server_cleanup_verified -and
                -not [object]::ReferenceEquals($cleanup, $again)) `
                'cleanup 未保持幂等深拷贝。'
            Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) 'graceful close 后端口不可重绑定。'
        } finally {
            if (-not $guard.Disposed) { [void](Close-TL1C1bPrivateAdbServerGuard $guard) }
        }
        $lines = Get-FakeInvocationLines $state
        Assert-True (@($lines | Where-Object { $_ -match '\|tcp:127\.0\.0\.1:5037\|' }).Count -eq 0) `
            'fake adb 观察到 default 5037。'
        $serverLines = @($lines | Where-Object { $_ -match '\|-L,' })
        Assert-True ($serverLines.Count -eq 1 -and
            $serverLines[0] -match
                '\|tcp:127\.0\.0\.1:([0-9]{5})\|-L,tcp:localhost:\1,server,nodaemon$') `
            'server -L 未精确使用 tcp:localhost:<port>，或环境未保持 tcp:127.0.0.1:<port>。'
        $clientLines = @($lines | Where-Object { $_ -match '\|-H,' })
        Assert-True ($clientLines.Count -ge 2 -and @($clientLines | Where-Object {
            $_ -cnotmatch
                '\|tcp:127\.0\.0\.1:([0-9]{5})\|-H,127\.0\.0\.1,-P,\1,(?:server-status|kill-server)$'
        }).Count -eq 0) 'client ADB_SERVER_SOCKET/-H/-P 未精确绑定 literal loopback。'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $state.Root 'serial-or-trace-leak.txt'))) `
            'fake adb 子进程环境泄露 serial/trace。'
        Assert-True (($lines -join "`n") -notmatch [regex]::Escape($state.Secret)) `
            'fake adb invocation log 泄露 serial。'
    }

    Test-Case 'guarded diagnostic 仅将实际整数 ExitCode 记录为已观测退出' {
        $stdout = [TL1C1bBoundedWriteStream]::new(4096)
        $stderr = [TL1C1bBoundedWriteStream]::new(1048576)
        try {
            foreach ($case in @(
                [pscustomobject]@{ Name = 'null'; Value = $null; Observed = $false },
                [pscustomobject]@{ Name = 'nonnumeric-string'; Value = 'not-an-exit'; Observed = $false },
                [pscustomobject]@{ Name = 'numeric-string'; Value = '0'; Observed = $false },
                [pscustomobject]@{ Name = 'integer-zero'; Value = 0; Observed = $true },
                [pscustomobject]@{ Name = 'integer-nonzero'; Value = 23; Observed = $true })) {
                $fakeProcess = [pscustomobject]@{
                    HasExited = $true
                    ExitCodeValue = $case.Value
                    ExitCodeGetterCalls = 0
                }
                $fakeProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Value {
                    $this.ExitCodeGetterCalls++
                    return $this.ExitCodeValue
                }
                $diagnostic = New-TL1C1bPrivateAdbGuardedProcessDiagnostic `
                    -Started ([pscustomobject]@{ Process = $fakeProcess }) `
                    -Stdout $stdout -Stderr $stderr -MaximumOutputBytes 4096
                Assert-True ($fakeProcess.ExitCodeGetterCalls -eq 1 -and $diagnostic.started -and
                    $diagnostic.exit_observed -eq $case.Observed -and
                    $diagnostic.stdout.observed_bytes -eq 0 -and
                    $diagnostic.stderr.observed_bytes -eq 0) `
                    "ExitCode getter 未读取或观测状态错误：$($case.Name)"
                if ($case.Observed) {
                    Assert-True ($diagnostic.exit_code -is [int] -and
                        $diagnostic.exit_code -eq $case.Value) `
                        "有效整数 ExitCode 未原样保留：$($case.Name)"
                } else {
                    Assert-True ($null -eq $diagnostic.exit_code) `
                        "未观测 ExitCode 被强转成有效退出码：$($case.Name)"
                }
            }
        } finally {
            $stdout.Dispose()
            $stderr.Dispose()
        }
    }

    Test-Case 'install failure 固定分类拒绝未知、多码、装饰、控制字符及不完整 frame' {
        $code = 'INSTALL_FAILED_USER_RESTRICTED'
        $cases = @(
            @{ Out = "Failure [$code]"; Err = ''; Expected = $code; Extraction = 'recognized' }
            @{ Out = ''; Err = "adb: failed to install C:\private\app.apk: Failure [${code}: secret-body]`r`n"; Expected = $code; Extraction = 'recognized' }
            @{ Out = "Performing Streamed Install`r`n"; Err = "adb.exe: failed to install C:\private\app.apk: Failure [${code}: secret-body]`r`n"; Expected = $code; Extraction = 'recognized' }
            @{ Out = ''; Err = "adbxexe: failed to install C:\private\app.apk: Failure [$code]"; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = ''; Err = "adb.exe.bad: failed to install C:\private\app.apk: Failure [$code]"; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = ''; Err = "prefixadb.exe: failed to install C:\private\app.apk: Failure [$code]"; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = "Failure [$code]"; Err = 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]'; Expected = $null; Extraction = 'ambiguous_status_tokens' }
            @{ Out = "Failure [${code}: INSTALL_PARSE_FAILED_NOT_APK]"; Err = ''; Expected = $null; Extraction = 'ambiguous_status_tokens' }
            @{ Out = 'Failure [INSTALL_FAILED_UNREVIEWED_VENDOR_CODE]'; Err = ''; Expected = $null; Extraction = 'unsupported_code' }
            @{ Out = "Failure [${code}_SECRET]"; Err = ''; Expected = $null; Extraction = 'unsupported_code' }
            @{ Out = "Failure [${code}: secret-body"; Err = ''; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = "prefix Failure [$code]"; Err = ''; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = "Failure [$code] suffix"; Err = ''; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = "Failure [${code}: nested[secret]]"; Err = ''; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = "Failure [$code]"; Err = "`e[31msecret"; Expected = $null; Extraction = 'unsafe_control' }
            @{ Out = 'Failure [install_failed_user_restricted]'; Err = ''; Expected = $null; Extraction = 'frame_rejected' }
            @{ Out = ''; Err = ''; Expected = $null; Extraction = 'no_status_token' }
            @{ Out = 'synthetic-stdout-canary'; Err = 'synthetic-stderr-canary'; Expected = $null; Extraction = 'no_status_token' }
            @{ Out = 'Failure [synthetic-unknown-message]'; Err = ''; Expected = $null; Extraction = 'no_status_token' }
            @{ Out = ''; Err = "`e[31msynthetic-control-canary"; Expected = $null; Extraction = 'unsafe_control' }
            @{ Out = "Failure [$code]"; Err = "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]`e"; Expected = $null; Extraction = 'unsafe_control' }
            @{ Out = ''; Err = "adb.exe: failed to install C:\install_cache\app.apk: Failure [$code]"; Expected = $null; Extraction = 'ambiguous_status_tokens' }
            @{ Out = "Failure [${code}: line1`nline2]"; Err = ''; Expected = $null; Extraction = 'frame_rejected' })
        foreach ($case in $cases) {
            $actual = Get-TL1C1bPrivateAdbInstallFailureCode $case.Out $case.Err
            Assert-True ($actual -ceq $case.Expected) 'install failure 分类误接受或泄露非固定值。'
            $extraction = 'EXTRACTION-INPUT-CANARY'
            $withStatus = Get-TL1C1bPrivateAdbInstallFailureCode `
                $case.Out $case.Err ([ref]$extraction)
            Assert-True ($withStatus -ceq $case.Expected -and $extraction -ceq $case.Extraction) `
                'install failure 可选诊断改变原code/null结果或未返回固定提取分类。'
        }
    }

    foreach ($case in @(
        @{ Name = 'stdout'; Substage = 'process_exit'; Code = 'INSTALL_FAILED_USER_RESTRICTED'; Extraction = 'recognized' }
        @{ Name = 'stderr'; Substage = 'process_exit'; Code = 'INSTALL_FAILED_USER_RESTRICTED'; Extraction = 'recognized' }
        @{ Name = 'stderr_windows'; Substage = 'process_exit'; Code = 'INSTALL_FAILED_USER_RESTRICTED'; Extraction = 'recognized' }
        @{ Name = 'stderr_windows_bad_dot'; Substage = 'process_exit'; Code = $null; Extraction = 'frame_rejected' }
        @{ Name = 'stderr_windows_suffix'; Substage = 'process_exit'; Code = $null; Extraction = 'frame_rejected' }
        @{ Name = 'conflict'; Substage = 'process_exit'; Code = $null; Extraction = 'ambiguous_status_tokens' }
        @{ Name = 'unknown'; Substage = 'process_exit'; Code = $null; Extraction = 'unsupported_code' }
        @{ Name = 'truncated'; Substage = 'process_exit'; Code = $null; Extraction = 'frame_rejected' }
        @{ Name = 'no_status'; Substage = 'process_exit'; Code = $null; Extraction = 'no_status_token' }
        @{ Name = 'stdout_utf8'; Substage = 'stdout_utf8'; Code = $null; Extraction = 'not_attempted' }
        @{ Name = 'stderr_utf8'; Substage = 'stderr_utf8'; Code = $null; Extraction = 'not_attempted' }
        @{ Name = 'stdout_overflow'; Substage = 'output_overflow'; Code = $null; Extraction = 'not_attempted' }
        @{ Name = 'stderr_overflow'; Substage = 'output_overflow'; Code = $null; Extraction = 'not_attempted' }
        @{ Name = 'timeout'; Substage = 'timeout'; Code = $null; Extraction = 'not_attempted' }
        @{ Name = 'noninstall'; Substage = 'process_exit'; Code = $null; Extraction = $null })) {
        Test-Case "guarded install failure 安全诊断 $($case.Name)" {
            $state = New-FakeState ('install-diagnostic-' + $case.Name) ('install_diag_' + $case.Name)
            $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
            try {
                $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
                $prefix = Get-TL1C1bPrivateAdbClientArguments $guard
                $tail = if ($case.Name -ceq 'noninstall') {
                    @('-s','FAKE123','shell','getprop','ro.build.fingerprint')
                } else { @('-s','FAKE123','install','-r','-t',$FakeAdb) }
                $operationClass = if ($case.Name -ceq 'noninstall') {
                    'device_fingerprint'
                } else { 'package_install' }
                $failure = Assert-Throws {
                    Invoke-TL1C1bPrivateAdbGuardedProcess -Guard $guard -FilePath $FakeAdb `
                        -Arguments ($prefix + $tail) -Operation 'install-operation-canary' `
                        -ProcessEnvironment $environment -ClearEnvironment -TimeoutSec 2 `
                        -MaximumOutputBytes 4096 -ClientKind Adb | Out-Null
                } 'fake install failure 未 fail closed。'
                $forbidden = @($state.Root,$state.Secret,$FakeAdb,'FAKE123','敏感-token',
                    'INSTALL-BODY-CANARY','install-operation-canary','Failure [',
                    'INSTALL_FAILED_UNREVIEWED_VENDOR_CODE',
                    'install-no-status-stdout|','install-no-status-stderr|')
                if ($null -eq $case.Code) { $forbidden += 'INSTALL_FAILED_USER_RESTRICTED' }
                $diagnostic = Get-GuardedClientDiagnostic $failure $operationClass `
                    $case.Substage $forbidden
                Assert-True ($diagnostic.install_failure_code -ceq $case.Code) `
                    'guarded install failure 提取门或固定码漂移。'
                $message = [string]$failure.Exception.Message
                $extractionLabelCount = [regex]::Matches($message, 'install_failure_extraction=').Count
                if ($null -eq $case.Extraction) {
                    Assert-True ($extractionLabelCount -eq 0) '非install命令导出安装提取分类。'
                } else {
                    Assert-True ($extractionLabelCount -eq 1 -and
                        $message.Contains('; install_failure_extraction=' + $case.Extraction + '; cleanup=')) `
                        '安全Message未保留唯一固定提取分类。'
                }
                if ($null -ne $case.Code) {
                    Assert-True ($message.Contains('install_failure_code=' + $case.Code)) `
                        '有效 install failure 未保留安全码。'
                }
                if ($case.Substage -ceq 'process_exit') {
                    $detail = 'INSTALL-BODY-CANARY|' + $state.Root + '|敏感-token'
                    $frame = 'Failure [INSTALL_FAILED_USER_RESTRICTED: ' + $detail + ']'
                    $newline = [Environment]::NewLine
                    $expectedOut = $frame + $newline
                    $expectedErr = $detail
                    $expectedExit = 23
                    switch -CaseSensitive ($case.Name) {
                        { $_ -cin @('stderr','stderr_windows','stderr_windows_bad_dot','stderr_windows_suffix') } {
                            $program = switch -CaseSensitive ($case.Name) {
                                'stderr' { 'adb' }
                                'stderr_windows' { 'adb.exe' }
                                'stderr_windows_bad_dot' { 'adbxexe' }
                                'stderr_windows_suffix' { 'adb.exe.bad' }
                            }
                            $expectedOut = 'Performing Streamed Install' + $newline
                            $expectedErr = $program + ': failed to install ' + $FakeAdb + ': ' + $frame + $newline
                        }
                        'conflict' { $expectedErr = 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]' + $newline }
                        'unknown' {
                            $expectedOut = ''
                            $expectedErr = 'Failure [INSTALL_FAILED_UNREVIEWED_VENDOR_CODE: ' + $detail + ']' + $newline
                        }
                        'truncated' { $expectedOut = $frame.Substring(0, $frame.Length - 1); $expectedErr = '' }
                        'no_status' {
                            $expectedOut = 'install-no-status-stdout|' + $detail
                            $expectedErr = 'install-no-status-stderr|' + $detail
                            $expectedExit = 1
                        }
                    }
                    Assert-True ($diagnostic.process.started -and $diagnostic.process.exit_observed -and
                        $diagnostic.process.exit_code -is [int] -and
                        $diagnostic.process.exit_code -eq $expectedExit -and
                        $diagnostic.process.stdout.observed_bytes -eq [Text.Encoding]::UTF8.GetByteCount($expectedOut) -and
                        $diagnostic.process.stderr.observed_bytes -eq [Text.Encoding]::UTF8.GetByteCount($expectedErr) -and
                        $diagnostic.process.stdout.maximum_bytes -eq 4096 -and
                        $diagnostic.process.stderr.maximum_bytes -eq 1048576 -and
                        -not $diagnostic.process.stdout.overflowed -and
                        -not $diagnostic.process.stderr.overflowed -and
                        $diagnostic.cleanup.status -ceq 'completed') `
                        '含null-code的原生失败未保留精确退出、双流字节、上限与清理诊断。'
                }
            } finally { [void](Close-TL1C1bPrivateAdbServerGuard $guard) }
        }
    }

    Test-Case 'guarded buffered client 保留 binary stdin 与 AllowFailure 语义' {
        $state = New-FakeState 'guarded-buffered' 'buffered_semantics'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        try {
            $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
            $prefix = Get-TL1C1bPrivateAdbClientArguments $guard
            $t0Uri = 'content://dev.magina.gateway.tablet.c1b/t0/tl1-c1b-test?' +
                'nonce=n-' + ('a' * 32) +
                '&title_hash=sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c' +
                '&producer_commit_sha=' + ('b' * 40) +
                '&producer_artifact_sha256=sha256:' + ('c' * 64)
            $failureArguments = $prefix + @(
                '-s','FAKE123','shell','getprop','ro.build.fingerprint')
            $input = [Text.UTF8Encoding]::new($false).GetBytes("binary-input`r`n第二行")
            try {
                $echo = Invoke-TL1C1bPrivateAdbGuardedProcess `
                    -Guard $guard -FilePath $FakeAdb `
                    -Arguments ($prefix + @('-s','FAKE123','exec-in','content','write','--uri',$t0Uri)) `
                    -Operation 'fake guarded input' -InputBytes $input `
                    -ProcessEnvironment $environment -ClearEnvironment -TimeoutSec 5 `
                    -ClientKind Adb
                Assert-True ([Convert]::ToHexString($echo.Bytes) -ceq
                    [Convert]::ToHexString($input)) 'guarded client 未原样转发 binary stdin。'
            } finally { if ($input.Length) { [Array]::Clear($input,0,$input.Length) } }
            $allowed = Invoke-TL1C1bPrivateAdbGuardedProcess `
                -Guard $guard -FilePath $FakeAdb -Arguments $failureArguments `
                -Operation 'fake guarded allow failure' -ProcessEnvironment $environment `
                -ClearEnvironment -TimeoutSec 5 -AllowFailure -ClientKind Adb
            Assert-True ($allowed.ExitCode -eq 23 -and $allowed.Text -ceq 'failure-output' -and
                $allowed.Stderr -ceq 'fixture-error') 'AllowFailure 返回语义漂移。'
            $operationCanary = 'OPERATION-CANARY-' + $state.Secret + '-TOKEN'
            $failure = Assert-Throws {
                Invoke-TL1C1bPrivateAdbGuardedProcess `
                    -Guard $guard -FilePath $FakeAdb -Arguments $failureArguments `
                    -Operation $operationCanary -ProcessEnvironment $environment `
                    -ClearEnvironment -TimeoutSec 5 -ClientKind Adb | Out-Null
            } '非零 exit 未 fail closed。'
            $diagnostic = Get-GuardedClientDiagnostic $failure 'device_fingerprint' 'process_exit' `
                @($operationCanary,$state.Root,$state.Secret,'FAKE123','ro.build.fingerprint',
                    'failure-output','fixture-error')
            Assert-True ($diagnostic.process.started -and $diagnostic.process.exit_observed -and
                [int]$diagnostic.process.exit_code -eq 23 -and
                [long]$diagnostic.process.stdout.observed_bytes -eq 14 -and
                [long]$diagnostic.process.stderr.observed_bytes -eq 13 -and
                [long]$diagnostic.process.stdout.maximum_bytes -eq 1048576 -and
                [long]$diagnostic.process.stderr.maximum_bytes -eq 1048576 -and
                -not $diagnostic.process.stdout.overflowed -and
                -not $diagnostic.process.stderr.overflowed -and
                $diagnostic.cleanup.status -ceq 'completed') `
                'guarded nonzero 退出码/双流统计/cleanup 诊断未保留。'

            $guardState = Get-TL1C1bPrivateAdbGuardState $guard
            $readUriC1a = "'content://dev.magina.gateway.tablet.c1a/status/tl1-c1b-test?nonce=n-$('d' * 32)'"
            $readUriC1b = "'content://dev.magina.gateway.tablet.c1b/capture/c2/tl1-c1b-test?nonce=n-$('e' * 32)'"
            $validTails = @(
                ,([string[]]@('devices'))
                ,([string[]]@('-s','FAKE123','shell','getprop','ro.build.fingerprint'))
                ,([string[]]@('-s','FAKE123','shell','cat','/proc/sys/kernel/random/boot_id'))
                ,([string[]]@('-s','FAKE123','shell','settings','get','secure','enabled_accessibility_services'))
                ,([string[]]@('-s','FAKE123','shell','dumpsys','accessibility'))
                ,([string[]]@('-s','FAKE123','shell','pm','path','dev.magina.gateway'))
                ,([string[]]@('-s','FAKE123','shell','dumpsys','package','dev.magina.gateway'))
                ,([string[]]@('-s','FAKE123','install','-r','-t',$FakeAdb))
                ,([string[]]@('-s','FAKE123','exec-out','cat','/data/app/fake/base.apk'))
                ,([string[]]@('-s','FAKE123','exec-in','content','write','--uri',$t0Uri))
                ,([string[]]@('-s','FAKE123','shell','content','read','--uri',$readUriC1a))
                ,([string[]]@('-s','FAKE123','shell','content','read','--uri',$readUriC1b)))
            foreach ($tail in $validTails) {
                Assert-True ((Assert-TL1C1bPrivateAdbGuardedSpecification `
                    $guardState $FakeAdb ($prefix + $tail) Adb $environment) -eq 1) `
                    "合法 business argv 被拒绝：$($tail -join ',')"
            }

            $beforeRejected = @(Get-FakeInvocationLines $state).Count
            $forbiddenTails = @(
                ,([string[]]@('-Hlocalhost','devices'))
                ,([string[]]@('-P5037','devices'))
                ,([string[]]@('-s123','shell','getprop','ro.build.fingerprint'))
                ,([string[]]@('-t7','devices'))
                ,([string[]]@('-d','devices'))
                ,([string[]]@('-e','devices'))
                ,([string[]]@('-a','devices'))
                ,([string[]]@('--one-device','FAKE123','devices'))
                ,([string[]]@('--reply-fd','7','devices'))
                ,([string[]]@('--exit-on-write-error','devices'))
                ,([string[]]@('fork-server','server'))
                ,([string[]]@('-s','FAKE123','shell','getprop','ro.build.fingerprint','-Hlocalhost'))
                ,([string[]]@('-s','FAKE123','install','-r','-t','relative.apk'))
                ,([string[]]@('-s','FAKE123','exec-out','cat','/sdcard/base.apk'))
                ,([string[]]@('-s','FAKE123','shell','content','read','--uri',$t0Uri)))
            foreach ($tail in $forbiddenTails) {
                [void](Assert-Throws {
                    Invoke-TL1C1bPrivateAdbGuardedProcess -Guard $guard `
                        -FilePath $FakeAdb -Arguments ($prefix + $tail) `
                        -Operation 'fake guarded argv rejection' `
                        -ProcessEnvironment $environment -ClearEnvironment `
                        -TimeoutSec 5 -ClientKind Adb | Out-Null
                } "危险/漂移 adb argv 未被拒绝：$($tail -join ',')")
            }
            Assert-True (@(Get-FakeInvocationLines $state).Count -eq $beforeRejected) `
                'argv allowlist 拒绝发生在 fake adb 启动之后。'
            [void](Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard)
        } finally { [void](Close-TL1C1bPrivateAdbServerGuard $guard) }
    }

    Test-Case 'C1a private devices 与超过 1 MiB exec-out 使用 guarded streaming SHA' {
        $state = New-FakeState 'guarded-c1a-stream'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        try {
            $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
            Assert-True ((Get-TL1C1aSingleDevice $FakeAdb -ProcessEnvironment $environment `
                -ClearEnvironment -PrivateAdbServerGuard $guard) -ceq 'FAKE123') `
                'C1a devices 未走 guarded client。'
            $prefix = Get-TL1C1bPrivateAdbClientArguments $guard
            $operationCanary = 'OPERATION-CANARY-' + $state.Secret + '-TOKEN'
            $failure = Assert-Throws {
                Invoke-TL1C1bPrivateAdbGuardedProcess -Guard $guard -FilePath $FakeAdb `
                    -Arguments ($prefix + @('-s','FAKE123','exec-out','cat','/data/app/fake/base.apk')) `
                    -Operation $operationCanary -ProcessEnvironment $environment `
                    -ClearEnvironment -TimeoutSec 5 -OutputMode Sha256 `
                    -MaximumOutputBytes 1048576 -ClientKind Adb | Out-Null
            } '超过 guarded streaming 上限未失败。'
            $diagnostic = Get-GuardedClientDiagnostic $failure 'installed_apk_read' 'output_overflow' `
                @($operationCanary,$state.Root,$state.Secret,'FAKE123','/data/app/fake/base.apk')
            Assert-True ($diagnostic.process.started -and
                $diagnostic.process.stdout.overflowed -and
                [long]$diagnostic.process.stdout.observed_bytes -gt 1048576 -and
                [long]$diagnostic.process.stdout.maximum_bytes -eq 1048576 -and
                [long]$diagnostic.process.stderr.observed_bytes -eq 0 -and
                -not $diagnostic.process.stderr.overflowed -and
                $diagnostic.cleanup.status -ceq 'completed') `
                'guarded streaming overflow 分类或有界统计诊断漂移。'
            [void](Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard)
            $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
                [Security.Cryptography.HashAlgorithmName]::SHA256)
            $block = [byte[]]::new(65536)
            for ($index=0;$index-lt$block.Length;$index++){$block[$index]=[byte]($index%251)}
            try {
                for($index=0;$index-lt32;$index++){$hasher.AppendData($block)}
                $tail = [byte[]]::new(37)
                for($index=0;$index-lt$tail.Length;$index++){$tail[$index]=[byte]($index%251)}
                $hasher.AppendData($tail)
                $expected = 'sha256:' + [Convert]::ToHexString(
                    $hasher.GetHashAndReset()).ToLowerInvariant()
            } finally {
                [Array]::Clear($block,0,$block.Length)
                if ($null -ne $tail) { [Array]::Clear($tail,0,$tail.Length) }
                $hasher.Dispose()
            }
            $actual = Get-TL1C1aInstalledApkHostSha256 $FakeAdb 'FAKE123' `
                '/data/app/fake/base.apk' 10 -ProcessEnvironment $environment `
                -ClearEnvironment -PrivateAdbServerGuard $guard
            Assert-True ($actual -ceq $expected) 'guarded streaming SHA 与 >1 MiB fixture 不一致。'
            [void](Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard)
        } finally { [void](Close-TL1C1bPrivateAdbServerGuard $guard) }
    }

    foreach ($cleanupFails in @($false,$true)) {
        $caseName = if ($cleanupFails) { 'guarded-timeout-cleanup-failure' } else { 'guarded-timeout' }
        Test-Case "$caseName 保留 cleanup 前未退出快照且不泄露哨兵" {
            $state = New-FakeState $caseName 'guarded_timeout'
            $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
            $originalContained =
                (Get-Item -LiteralPath Function:\Wait-TL1C1bPrivateAdbEndpointContained).ScriptBlock
            $script:GuardedCleanupMockCalls = 0
            try {
                $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
                $prefix = Get-TL1C1bPrivateAdbClientArguments $guard
                $operationCanary = 'OPERATION-CANARY-' + $state.Secret + '-TOKEN'
                try {
                    if ($cleanupFails) {
                        Set-Item -LiteralPath Function:\Wait-TL1C1bPrivateAdbEndpointContained `
                            -Value {
                                param([int]$Port, [int]$ExpectedProcessId, [int]$TimeoutMs)
                                $script:GuardedCleanupMockCalls++
                                throw 'GUARDED-CLEANUP-EXCEPTION-CANARY'
                            }
                    }
                    $watch = [Diagnostics.Stopwatch]::StartNew()
                    $failure = Assert-Throws {
                        Invoke-TL1C1bPrivateAdbGuardedProcess -Guard $guard -FilePath $FakeAdb `
                            -Arguments ($prefix + @('devices')) -Operation $operationCanary `
                            -ProcessEnvironment $environment -ClearEnvironment -TimeoutSec 1 `
                            -ClientKind Adb | Out-Null
                    } 'guarded devices timeout 未 fail closed。'
                    $watch.Stop()
                } finally {
                    Set-Item -LiteralPath Function:\Wait-TL1C1bPrivateAdbEndpointContained `
                        -Value $originalContained
                }
                Assert-True ($watch.Elapsed.TotalSeconds -lt 8) 'guarded timeout cleanup 未保持有界。'
                $diagnostic = Get-GuardedClientDiagnostic $failure 'device_discovery' 'timeout' `
                    @($operationCanary,$state.Root,$state.Secret,'guarded-timeout-stdout-canary',
                        'guarded-timeout-stderr','GUARDED-CLEANUP-EXCEPTION-CANARY')
                $expectedStderr = Get-FailureCanaryObservation $state 'guarded-timeout-stderr'
                Assert-True ($diagnostic.process.started -and
                    -not $diagnostic.process.exit_observed -and $null -eq $diagnostic.process.exit_code -and
                    [long]$diagnostic.process.stdout.observed_bytes -eq
                        [Text.Encoding]::UTF8.GetByteCount('guarded-timeout-stdout-canary') -and
                    [long]$diagnostic.process.stderr.observed_bytes -eq $expectedStderr.Bytes -and
                    [long]$diagnostic.process.stdout.maximum_bytes -eq 1048576 -and
                    [long]$diagnostic.process.stderr.maximum_bytes -eq 1048576 -and
                    -not $diagnostic.process.stdout.overflowed -and
                    -not $diagnostic.process.stderr.overflowed) `
                    'timeout 主失败快照丢失或被 cleanup 的进程退出观测覆盖。'
                $expectedCleanup = if ($cleanupFails) { 'failed' } else { 'completed' }
                Assert-True ($diagnostic.cleanup.status -ceq $expectedCleanup -and
                    $script:GuardedCleanupMockCalls -eq [int]$cleanupFails) `
                    'cleanup 故障未独立记录或未命中受控 mock。'
                [void](Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard)
            } finally { [void](Close-TL1C1bPrivateAdbServerGuard $guard) }
            Assert-StateHasNoLivePort $state
        }
    }

    Test-Case '实际 C1a devices 路径在 auto-start child 进入前 fail closed' {
        $state = New-FakeState 'guarded-c1a-auto-start' 'business_auto_start'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        try {
            $environment = Get-TL1C1bPrivateAdbClientEnvironment $guard
            [void](Assert-Throws {
                Get-TL1C1aSingleDevice $FakeAdb -ProcessEnvironment $environment `
                    -ClearEnvironment -PrivateAdbServerGuard $guard | Out-Null
            } 'C1a devices auto-start escape 未失败。')
        } finally {
            if (-not $guard.Disposed) {
                try { [void](Close-TL1C1bPrivateAdbServerGuard $guard) } catch { }
            }
        }
        $lines = Get-FakeInvocationLines $state
        Assert-True (@($lines | Where-Object { $_ -match '--listener-child' }).Count -eq 0) `
            'C1a auto-start child 已进入 fake Main。'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $state.Root 'business-side-effect.txt'))) `
            'C1a auto-start child 拒绝前已产生业务副作用。'
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            'C1a auto-start 失败路径端口不可重绑定。'
    }

    Test-Case 'issued Binding 被 ETS 覆写后 fail closed 但仍回收 server/port' {
        $state = New-FakeState 'binding-mutation'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        $binding = Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard
        $binding | Add-Member -Force -NotePropertyName server_socket `
            -NotePropertyValue 'tcp:127.0.0.1:49152'
        [void](Assert-Throws {
            Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard | Out-Null
        } '被覆写的 Binding 未被拒绝。')
        [void](Assert-Throws {
            Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 2 | Out-Null
        } '被覆写的 Binding 在 Close 未 fail closed。')
        Assert-True $guard.Disposed '被覆写 Binding 失败路径未将已回收 guard 标记为 disposed。'
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            '被覆写 Binding 失败路径遗留端口。'
    }

    Test-Case 'issued CleanupBinding 被 ETS 覆写后幂等 Close fail closed' {
        $state = New-FakeState 'cleanup-mutation'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        $cleanup = Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 2
        $cleanup | Add-Member -Force -NotePropertyName port_rebind_verified `
            -NotePropertyValue $false
        [void](Assert-Throws {
            Close-TL1C1bPrivateAdbServerGuard $guard | Out-Null
        } '被覆写的 CleanupBinding 在幂等 Close 未 fail closed。')
        Assert-True ($guard.Disposed -and (Test-TL1C1bPrivateAdbPortAvailable $port)) `
            'CleanupBinding 篡改影响了已完成的回收事实。'
    }

    Test-Case 'opaque Guard field 覆写 fail closed 且 Close 仍必定回收' {
        $state = New-FakeState 'guard-mutation'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        $guard | Add-Member -Force -NotePropertyName Disposed -NotePropertyValue $false
        [void](Assert-Throws {
            Assert-TL1C1bPrivateAdbServerGuardUnchanged $guard | Out-Null
        } '被覆写的 Guard field 未被拒绝。')
        [void](Assert-Throws {
            Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 2 | Out-Null
        } '被覆写的 Guard field 在 Close 未 fail closed。')
        Assert-True $guard.Disposed 'Close 未清除 shadow field/反映设置真实 Disposed。'
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            'Guard field 篡改失败路径遗留端口。'
    }

    Test-Case 'Close listener proof 异常注入仍 finally 回收 Job/process/port' {
        $state = New-FakeState 'close-fault'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        $originalListenerProof =
            (Get-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbListenerOwned).ScriptBlock
        try {
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbListenerOwned `
                -Value { throw 'synthetic listener proof fault' }
            [void](Assert-Throws {
                Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 1 | Out-Null
            } 'Close 故障注入未 fail closed。')
        } finally {
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbListenerOwned `
                -Value $originalListenerProof
        }
        Assert-True $guard.Disposed '故障注入 Close 未在回收后标记 disposed。'
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) `
            '故障注入 Close 遗留端口。'
    }

    Test-Case 'client ACTIVE_PROCESS_LIMIT 在替代 listener 进入前拒绝 auto-start' {
        $state = New-FakeState 'client-auto-start' 'auto_start'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        [void](Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 6 -ClientTimeoutSec 3 -PortAttemptCount 1 | Out-Null
        } 'client auto-start 替代 server 未 fail closed。')
        $watch.Stop()
        Assert-True ($watch.Elapsed.TotalSeconds -lt 11) 'client auto-start 失败回收未保持有界。'
        $autoLines = Get-FakeInvocationLines $state
        Assert-True (@($autoLines | Where-Object {
                    $_ -match '--listener-child,[0-9]{5}'
                }).Count -eq 0) "fake auto-start child 已越过 active process limit：$($autoLines -join ';')"
        Assert-StateHasNoLivePort $state
    }

    Test-Case 'private kill-server 无效时 Job KILL_ON_CLOSE 兜底并释放端口' {
        $state = New-FakeState 'job-fallback' 'ignore_kill'
        $guard = Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
            -StartupTimeoutSec 5 -ClientTimeoutSec 2 -PortAttemptCount 4
        $port = Get-PrivateGuardPort $guard
        $cleanup = Close-TL1C1bPrivateAdbServerGuard $guard -ShutdownTimeoutSec 1
        Assert-True ($cleanup.server_cleanup_verified -and $cleanup.job_fallback_used -and
            $cleanup.port_rebind_verified) 'Job KILL_ON_CLOSE fallback proof 不完整。'
        Assert-True (Test-TL1C1bPrivateAdbPortAvailable $port) 'Job fallback 后端口不可重绑定。'
    }

    Test-Case 'held nodaemon Job 拒绝 child-owned listener 且清理端口' {
        $state = New-FakeState 'wrong-owner' 'child_listener'
        $failure = Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 4 -ClientTimeoutSec 1 -PortAttemptCount 1 | Out-Null
        } 'child-owned listener 未被拒绝。'
        $diagnostic = Get-StartupDiagnostic $failure
        $closedSubstages = @(
            'server_job_create','server_process_start','server_stream_drain',
            'server_job_membership','server_process_exit_before_ready',
            'server_process_exit_during_status','server_output_overflow','listener_ownership',
            'server_status_client','server_status_contract','server_ready_recheck',
            'startup_timeout','server_attempt_cleanup','port_selection_timeout','unexpected_failure')
        $safeFinalSubstage = if ($diagnostic.final_substage -is [string] -and
            $diagnostic.final_substage -cin $closedSubstages) { $diagnostic.final_substage } else { 'invalid' }
        $safeAttemptCount = if (($diagnostic.server_attempt_count -is [int] -or
            $diagnostic.server_attempt_count -is [long]) -and $diagnostic.server_attempt_count -in 0..32) {
            $diagnostic.server_attempt_count.ToString([Globalization.CultureInfo]::InvariantCulture)
        } else { 'invalid' }
        Assert-True ($diagnostic.final_substage -ceq 'server_process_exit_before_ready' -and
            $diagnostic.server_attempt_count -eq 1) `
            "child listener 的 active-limit failure substage 不明确。actual_final_substage=$safeFinalSubstage; actual_server_attempt_count=$safeAttemptCount"
        $attempt = @($diagnostic.attempts)[0]
        Assert-StartupAttemptDiagnostic $attempt
        $safeAttemptSubstage = if ($attempt.terminal_substage -is [string] -and
            $attempt.terminal_substage -cin $closedSubstages) { $attempt.terminal_substage } else { 'invalid' }
        $safeListenerObserved = if ($attempt.listener_observed -is [bool]) {
            $attempt.listener_observed.ToString().ToLowerInvariant()
        } else { 'invalid' }
        Assert-True ($attempt.terminal_substage -ceq 'server_process_exit_before_ready' -and
            -not [bool]$attempt.listener_observed) `
            "child listener attempt 未证明在 listener ready 前退出。actual_terminal_substage=$safeAttemptSubstage; actual_listener_observed=$safeListenerObserved"
        Assert-True (@(Get-FakeInvocationLines $state | Where-Object {
                    $_ -match '--listener-child,[0-9]{5}'
                }).Count -eq 0) 'child-owned listener 已越过 server Job active process limit。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case 'server 快速非零退出保留 bounded/hash 诊断并完成 cleanup' {
        $state = New-FakeState 'server-fast-exit' 'server_exit_before_listener'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $failure = Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 3 -ClientTimeoutSec 1 -PortAttemptCount 1 `
                -MaximumOutputBytes 4096 | Out-Null
        } 'server 快速非零退出未 fail closed。'
        $watch.Stop()
        Assert-True ($watch.Elapsed.TotalSeconds -lt 8) 'server 快速退出诊断/cleanup 未保持有界。'
        $diagnostic = Get-StartupDiagnostic $failure
        Assert-True ($diagnostic.final_substage -ceq 'server_process_exit_before_ready' -and
            $diagnostic.server_attempt_count -eq 1) `
            'server 快速退出未保留精确 final_substage。'
        $attempt = @($diagnostic.attempts)[0]
        Assert-StartupAttemptDiagnostic $attempt
        Assert-True ($attempt.terminal_substage -ceq 'server_process_exit_before_ready' -and
            -not [bool]$attempt.listener_observed -and @($attempt.status_clients).Count -eq 0) `
            'server 快速退出 attempt 阶段/owner 语义无效。'
        Assert-ProcessDiagnostic $attempt.server_process
        $expected = Get-FailureCanaryObservation $state 'server-fast-exit'
        Assert-True ([bool]$attempt.server_process.started -and
            [bool]$attempt.server_process.exit_observed -and
            [int]$attempt.server_process.exit_code -eq 93 -and
            [int]$attempt.server_process.stdout.captured_bytes -eq 0 -and
            $attempt.server_process.stdout.classification -ceq 'empty' -and
            [int]$attempt.server_process.stderr.captured_bytes -eq $expected.Bytes -and
            [long]$attempt.server_process.stderr.observed_bytes -eq $expected.Bytes -and
            $attempt.server_process.stderr.captured_sha256 -ceq $expected.Sha256 -and
            [bool]$attempt.server_process.stderr.strict_utf8 -and
            -not [bool]$attempt.server_process.stderr.overflowed -and
            $attempt.server_process.stderr.classification -ceq 'other_text') `
            'server 快速退出 exit/stderr bounded/hash 诊断不精确。'
        $serialized = $diagnostic | ConvertTo-Json -Depth 12 -Compress
        Assert-True ($serialized -notmatch [regex]::Escape($state.Root) -and
            $serialized -notmatch [regex]::Escape($state.Secret) -and
            $serialized -notmatch 'server-fast-exit') `
            'server 快速退出结构化诊断泄露原始 stderr/path/serial。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case 'server-status client 非零退出与 server attempt 分层诊断' {
        $state = New-FakeState 'status-client-exit' 'server_status_client_exit'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $failure = Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 3 -ClientTimeoutSec 1 -PortAttemptCount 1 `
                -MaximumOutputBytes 4096 | Out-Null
        } 'server-status client 非零退出未 fail closed。'
        $watch.Stop()
        Assert-True ($watch.Elapsed.TotalSeconds -lt 8) `
            'server-status client 退出诊断/cleanup 未保持有界。'
        $diagnostic = Get-StartupDiagnostic $failure
        Assert-True ($diagnostic.final_substage -ceq 'server_status_client' -and
            $diagnostic.server_attempt_count -eq 1) `
            'status client failure 未与 server exit 分层。'
        $attempt = @($diagnostic.attempts)[0]
        Assert-StartupAttemptDiagnostic $attempt
        Assert-True ($attempt.terminal_substage -ceq 'server_status_client' -and
            [bool]$attempt.listener_observed -and @($attempt.status_clients).Count -eq 1) `
            'status client attempt 阶段/listener 语义无效。'
        Assert-ProcessDiagnostic $attempt.server_process
        $client = @($attempt.status_clients)[0]
        Assert-True ((@($client.PSObject.Properties.Name) -join ',') -ceq
            'ordinal,terminal_substage,process,cleanup' -and
            [int]$client.ordinal -eq 1 -and
            $client.terminal_substage -ceq 'server-status_process-exit') `
            "status client diagnostic 字段/阶段不闭合：keys=$(@($client.PSObject.Properties.Name) -join ','); ordinal=$($client.ordinal); substage=$($client.terminal_substage)"
        Assert-ProcessDiagnostic $client.process
        $expected = Get-FailureCanaryObservation $state 'status-client-exit'
        Assert-True ([bool]$client.process.started -and [bool]$client.process.exit_observed -and
            [int]$client.process.exit_code -eq 94 -and
            [int]$client.process.stdout.captured_bytes -eq 0 -and
            [int]$client.process.stderr.captured_bytes -eq $expected.Bytes -and
            [long]$client.process.stderr.observed_bytes -eq $expected.Bytes -and
            $client.process.stderr.captured_sha256 -ceq $expected.Sha256 -and
            [bool]$client.process.stderr.strict_utf8 -and
            -not [bool]$client.process.stderr.overflowed -and
            $client.process.stderr.classification -ceq 'other_text') `
            'status client exit/stderr bounded/hash 诊断不精确。'
        Assert-True ((@($client.cleanup.PSObject.Properties.Name) -join ',') -ceq
            'status,endpoint_contained' -and $client.cleanup.status -ceq 'completed' -and
            $client.cleanup.endpoint_contained -ceq 'held') `
            'status client cleanup/endpoint containment proof 不完整。'
        $serialized = $diagnostic | ConvertTo-Json -Depth 12 -Compress
        Assert-True ($serialized -notmatch [regex]::Escape($state.Root) -and
            $serialized -notmatch [regex]::Escape($state.Secret) -and
            $serialized -notmatch 'status-client-exit') `
            'status client 结构化诊断泄露原始 stderr/path/serial。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case 'server-status 自报其他 executable path 时 fail closed 且不泄露 serial' {
        $state = New-FakeState 'wrong-status' 'wrong_status_path'
        $failure = Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 4 -ClientTimeoutSec 1 -PortAttemptCount 1 | Out-Null
        } 'wrong executable_absolute_path 未被拒绝。'
        Assert-True ($failure.Exception.ToString() -notmatch [regex]::Escape($state.Secret)) `
            'status 失败异常泄露 serial。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case 'nodaemon stdout 超限时有界 fail closed 且无 listener 遗留' {
        $state = New-FakeState 'overflow' 'output_overflow'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $failure = Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 3 -ClientTimeoutSec 1 -PortAttemptCount 1 `
                -MaximumOutputBytes 4096 | Out-Null
        } 'server stdout 超限未 fail closed。'
        $watch.Stop()
        Assert-True ($watch.Elapsed.TotalSeconds -lt 8) 'stdout 超限失败未保持有界。'
        Assert-True ($failure.Exception.ToString() -notmatch [regex]::Escape($state.Secret)) `
            'stdout 超限异常泄露 serial。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case '已启动 server 缺任一 drain task 时 cleanup 必须失败' {
        $state = New-FakeState 'partial-stream-drain'
        $port = 0
        for ($candidateAttempt = 0; $candidateAttempt -lt 64; $candidateAttempt++) {
            $candidate = Get-TL1C1bPrivateAdbRandomHighPortCandidate
            if (Test-TL1C1bPrivateAdbPortAvailable $candidate) { $port = $candidate; break }
        }
        Assert-True ($port -ge 49152) 'partial stream drain 测试未取得可用端口。'
        $socket = "tcp:127.0.0.1:$port"
        $environment = New-TL1C1bPrivateAdbEnvironment $state.Environment $socket
        $job = $null
        $started = $null
        $stdout = [TL1C1bBoundedWriteStream]::new(4096)
        $stderr = [TL1C1bBoundedWriteStream]::new(4096)
        try {
            $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob(1)
            $started = [TL1C1bPrivateAdbNative]::StartInJob(
                $FakeAdb,
                [string[]]@('-H','127.0.0.1','-P',$port.ToString(),'unsupported'),
                (ConvertTo-TL1C1bPrivateAdbEnvironmentEntries $environment),
                $job)
            $started.StandardInput.Dispose()
            $stdoutTask = $started.StandardOutput.CopyToAsync($stdout)
            $attempt = [pscustomobject][ordered]@{
                Ordinal = 1; StartedProcess = $started; Process = $started.Process
                ProcessId = [int]$started.Process.Id; Job = $job; Stdout = $stdout; Stderr = $stderr
                StdoutTask = $stdoutTask; StderrTask = $null; Port = $port; Socket = $socket
                ListenerObserved = $false; StatusClients = [Collections.Generic.List[object]]::new()
            }
            $failure = Assert-Throws {
                Stop-TL1C1bPrivateAdbServerAttempt $attempt `
                    -TerminalSubstage 'server_stream_drain' | Out-Null
            } 'partial stream drain cleanup 被误报为成功。'
            $diagnostic = $failure.Exception.Data['TL1C1bPrivateAdbServerAttemptDiagnostic']
            Assert-True ($null -ne $diagnostic -and
                $diagnostic.terminal_substage -ceq 'server_stream_drain' -and
                $diagnostic.cleanup.status -ceq 'failed' -and
                -not [bool]$diagnostic.cleanup.streams_drained -and
                [bool]$diagnostic.cleanup.process_exit_observed -and
                [bool]$diagnostic.cleanup.port_rebind_verified) `
                'partial stream drain cleanup 诊断未向失败方向收敛。'
        } finally {
            if ($null -ne $job) { try { $job.Dispose() } catch { } }
            if ($null -ne $started) { try { $started.Dispose() } catch { } }
            try { $stdout.Dispose() } catch { }
            try { $stderr.Dispose() } catch { }
        }
        Assert-StateHasNoLivePort $state
    }

    Test-Case '端口选择失败产生 zero-attempt closed diagnostic 且不启动 adb' {
        $state = New-FakeState 'port-selection-timeout'
        $originalCandidate =
            (Get-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate).ScriptBlock
        $originalPortAvailable =
            (Get-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable).ScriptBlock
        try {
            Set-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate `
                -Value { return 50001 }
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable `
                -Value { param([int]$Port) return $false }
            $failure = Assert-Throws {
                Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                    -StartupTimeoutSec 2 -ClientTimeoutSec 1 -PortAttemptCount 2 | Out-Null
            } 'port selection timeout 未 fail closed。'
        } finally {
            Set-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate `
                -Value $originalCandidate
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable `
                -Value $originalPortAvailable
        }
        $diagnostic = Get-StartupDiagnostic $failure
        Assert-True ($diagnostic.final_substage -ceq 'port_selection_timeout' -and
            [int]$diagnostic.server_attempt_count -eq 0 -and
            @($diagnostic.attempts).Count -eq 0) `
            'port selection timeout zero-attempt diagnostic 漂移。'
        Assert-True (@(Get-FakeInvocationLines $state).Count -eq 0) `
            'port selection timeout 前不应启动 fake adb。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case '跳过 unavailable port 后首个实际 server attempt ordinal 仍从一开始' {
        $state = New-FakeState 'skipped-port-ordinal' 'server_exit_before_listener'
        $candidates = [Collections.Generic.List[int]]::new()
        for ($candidateAttempt = 0; $candidateAttempt -lt 128 -and $candidates.Count -lt 2;
             $candidateAttempt++) {
            $candidate = Get-TL1C1bPrivateAdbRandomHighPortCandidate
            if (-not $candidates.Contains($candidate) -and
                (Test-TL1C1bPrivateAdbPortAvailable $candidate)) {
                $candidates.Add($candidate)
            }
        }
        Assert-True ($candidates.Count -eq 2) 'skipped port ordinal 测试未取得两个可用端口。'
        $originalCandidate =
            (Get-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate).ScriptBlock
        $originalPortAvailable =
            (Get-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable).ScriptBlock
        $script:TL1C1bSkippedPortCandidates = [int[]]$candidates.ToArray()
        $script:TL1C1bSkippedPortCandidateIndex = 0
        $script:TL1C1bOriginalPortAvailable = $originalPortAvailable
        try {
            Set-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate -Value {
                $index = [Math]::Min($script:TL1C1bSkippedPortCandidateIndex,
                    $script:TL1C1bSkippedPortCandidates.Count - 1)
                $script:TL1C1bSkippedPortCandidateIndex++
                return $script:TL1C1bSkippedPortCandidates[$index]
            }
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable -Value {
                param([int]$Port)
                if ($Port -eq $script:TL1C1bSkippedPortCandidates[0]) { return $false }
                return & $script:TL1C1bOriginalPortAvailable $Port
            }
            $failure = Assert-Throws {
                Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                    -StartupTimeoutSec 3 -ClientTimeoutSec 1 -PortAttemptCount 2 | Out-Null
            } 'skipped port 后 server early failure 未 fail closed。'
        } finally {
            Set-Item -LiteralPath Function:\Get-TL1C1bPrivateAdbRandomHighPortCandidate `
                -Value $originalCandidate
            Set-Item -LiteralPath Function:\Test-TL1C1bPrivateAdbPortAvailable `
                -Value $originalPortAvailable
            Remove-Variable -Scope Script -Name TL1C1bSkippedPortCandidates,
                TL1C1bSkippedPortCandidateIndex,TL1C1bOriginalPortAvailable -ErrorAction SilentlyContinue
        }
        $diagnostic = Get-StartupDiagnostic $failure
        Assert-True ($diagnostic.server_attempt_count -eq 1 -and
            @($diagnostic.attempts).Count -eq 1 -and
            [int]$diagnostic.attempts[0].ordinal -eq 1 -and
            $diagnostic.final_substage -ceq 'server_process_exit_before_ready') `
            'skipped unavailable port 污染了实际 server attempt ordinal。'
        Assert-True (@(Get-FakeInvocationLines $state).Count -eq 1) `
            'skipped unavailable port 不应产生 fake adb invocation。'
        Assert-StateHasNoLivePort $state
    }

    Test-Case '无 listener 的 held server 在总 startup deadline 内失败并由 Job 回收' {
        $state = New-FakeState 'no-listener' 'hang_without_listener'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        [void](Assert-Throws {
            Open-TL1C1bPrivateAdbServerGuard $FakeAdb $state.Environment `
                -StartupTimeoutSec 1 -ClientTimeoutSec 1 -PortAttemptCount 1 | Out-Null
        } '无 listener server 未失败。')
        $watch.Stop()
        Assert-True ($watch.Elapsed.TotalSeconds -lt 6) 'startup deadline 未保持有界。'
        Assert-StateHasNoLivePort $state
    }
} finally {
    if (Test-Path -LiteralPath $TestRoot -PathType Container) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force
    }
}

$result = [ordered]@{
    schema = 'tablet-layout-c1b-adb-server-offline/v1'
    passed = $script:Passed
    failed = $script:Failed
    real_adb_executed = $false
    real_jdk_or_gradle_executed = $false
}
$result | ConvertTo-Json -Compress
if ($script:Failed -ne 0) { exit 1 }
