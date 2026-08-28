#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$SidecarPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a-t0-adb-sidecar.ps1'
$IntakeLibraryPath = Join-Path $RepoRoot 'scripts\lib\tablet-intake.ps1'
$DispatchLibraryPath = Join-Path $RepoRoot 'scripts\lib\dispatch-lock.ps1'
$PrivateAdbLibraryPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-adb-server.ps1'
$PwshPath = (Get-Process -Id $PID).Path
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('tablet-layout-c1a-t0-adb-sidecar-' + [guid]::NewGuid().ToString('N'))
$FakeAdbPath = Join-Path $TestRoot 'fake-adb.exe'
$TestDispatchLibraryPath = Join-Path $TestRoot 'dispatch-lock-test-double.ps1'
$script:Passed = 0
$script:Failed = 0
$script:Invocation = 0
$deviceLease = $null

. $PrivateAdbLibraryPath

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (actual=$Actual expected=$Expected)" }
}

function Assert-Sequence([object[]]$Actual, [object[]]$Expected, [string]$Message) {
    if ($Actual.Count -ne $Expected.Count) {
        throw "$Message (actual_count=$($Actual.Count) expected_count=$($Expected.Count))"
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$Actual[$index] -cne [string]$Expected[$index]) {
            throw "$Message (index=$index actual=$($Actual[$index]) expected=$($Expected[$index]))"
        }
    }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Output "PASS  $Name"
    }
    catch {
        $script:Failed++
        Write-Output "FAIL  $Name :: $($_.Exception.Message)"
    }
}

function Read-FakeEnvironment([string]$CallRoot) {
    $path = Join-Path $CallRoot 'environment.txt'
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) 'fake adb 未记录子进程环境。'
    $result = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($path, [Text.UTF8Encoding]::new($false, $true))) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) { throw 'fake adb 环境记录格式错误。' }
        $name = $line.Substring(0, $separator).ToUpperInvariant()
        if ($result.Contains($name)) { throw "fake adb 环境键重复：$name。" }
        $bytes = [Convert]::FromBase64String($line.Substring($separator + 1))
        try { $result[$name] = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
        finally { if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
    }
    return $result
}

function Assert-FakeEnvironment {
    param(
        [Parameter(Mandatory)]$Result,
        [AllowNull()][string]$ExpectedSocket
    )

    $actual = Read-FakeEnvironment $Result.CallRoot
    $expectedNames = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
        'SYSTEMROOT','WINDIR','COMSPEC','PATHEXT','PATH','TEMP','TMP',
        'USERPROFILE','HOME','ANDROID_SDK_ROOT','ANDROID_HOME','TABLET_C1A_FAKE_STATE'
    )) { $expectedNames.Add($name) }
    if ($PSBoundParameters.ContainsKey('ExpectedSocket')) { $expectedNames.Add('ADB_SERVER_SOCKET') }
    Assert-Equal $actual.Count $expectedNames.Count 'fake adb 子进程环境键集合漂移'
    foreach ($name in $expectedNames) {
        Assert-True $actual.Contains($name) "fake adb 子进程缺少环境键：$name。"
        Assert-Equal ([string]$actual[$name]) ([string]$Result.ParentEnvironment[$name]) `
            "fake adb 子进程环境值漂移：$name"
    }
    foreach ($forbidden in @(
        'SHOULD_NOT_PASS','AGENT_MOBILE_DEVICE_LOCK_LEASE','TL1_C1A_REAL_ADB_PATH',
        'TL1_C1A_BOUND_SERIAL','TL1_C1A_T0_LIBRARY_PATH','TL1_C1A_DISPATCH_LOCK_LIBRARY',
        'TL1_C1B_CLIENT_JOB_NAME'
    )) {
        Assert-True (-not $actual.Contains($forbidden)) "fake adb 子进程泄漏控制环境：$forbidden。"
    }
}

function Invoke-TestSidecar {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$IncludeSocket,
        [switch]$DisablePrivateJob,
        [AllowNull()][AllowEmptyString()][string]$Socket
    )

    $script:Invocation++
    $callRoot = Join-Path $TestRoot ('call-' + $script:Invocation.ToString('D3'))
    foreach ($path in @(
        $callRoot,
        (Join-Path $callRoot 'temp'),
        (Join-Path $callRoot 'profile'),
        (Join-Path $callRoot 'sdk')
    )) { [void](New-Item -ItemType Directory -Path $path) }

    $systemRoot = [IO.Path]::GetFullPath([string]$env:SystemRoot)
    $environment = [ordered]@{
        SYSTEMROOT = $systemRoot
        WINDIR = $systemRoot
        COMSPEC = Join-Path $systemRoot 'System32\cmd.exe'
        PATHEXT = '.COM;.EXE;.BAT;.CMD;.CPL'
        PATH = (Split-Path $PwshPath -Parent) + ';' + (Join-Path $systemRoot 'System32')
        TEMP = Join-Path $callRoot 'temp'
        TMP = Join-Path $callRoot 'temp'
        USERPROFILE = Join-Path $callRoot 'profile'
        HOME = Join-Path $callRoot 'profile'
        ANDROID_SDK_ROOT = Join-Path $callRoot 'sdk'
        ANDROID_HOME = Join-Path $callRoot 'sdk'
        TABLET_C1A_FAKE_STATE = $callRoot
        TL1_C1A_REAL_ADB_PATH = $FakeAdbPath
        TL1_C1A_BOUND_SERIAL = 'FAKE123'
        TL1_C1A_T0_LIBRARY_PATH = $IntakeLibraryPath
        TL1_C1A_DISPATCH_LOCK_LIBRARY = $TestDispatchLibraryPath
        AGENT_MOBILE_DEVICE_LOCK_LEASE = [string]$deviceLease.LeaseToken
        SHOULD_NOT_PASS = 'forbidden-environment-value'
    }
    $clientJobName = $null
    if ($IncludeSocket) {
        $environment['ADB_SERVER_SOCKET'] = $Socket
        $clientJobName = 'Local\TL1C1bClient-' + [guid]::NewGuid().ToString('N')
        $environment['TL1_C1B_CLIENT_JOB_NAME'] = $clientJobName
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PwshPath
    $start.WorkingDirectory = $RepoRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',$SidecarPath)) {
        $start.ArgumentList.Add($argument)
    }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.Environment.Clear()
    foreach ($entry in $environment.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }

    if ($IncludeSocket -and -not $DisablePrivateJob) {
        $job = $null
        $startedProcess = $null
        $stdout = [IO.MemoryStream]::new()
        $stderr = [IO.MemoryStream]::new()
        try {
            $job = [TL1C1bPrivateAdbNative]::CreateKillOnCloseJob(2, $clientJobName)
            $startedProcess = [TL1C1bPrivateAdbNative]::StartInJob(
                $PwshPath,
                [string[]]@($start.ArgumentList),
                (ConvertTo-TL1C1bPrivateAdbEnvironmentEntries $environment),
                $job)
            Assert-True ([TL1C1bPrivateAdbNative]::IsProcessAssigned(
                $job, $startedProcess.Process.Handle)) `
                'synthetic sidecar root 未 creation-time 加入 client Job。'
            $startedProcess.StandardInput.Dispose()
            $stdoutTask = $startedProcess.StandardOutput.CopyToAsync($stdout)
            $stderrTask = $startedProcess.StandardError.CopyToAsync($stderr)
            if (-not $startedProcess.Process.WaitForExit(20000)) {
                throw 'synthetic T0 adb sidecar 超时。'
            }
            if (-not $stdoutTask.Wait(2000) -or -not $stderrTask.Wait(2000)) {
                throw 'synthetic T0 adb sidecar 输出 drain 超时。'
            }
            $stdoutBytes = $stdout.ToArray()
            $stderrBytes = $stderr.ToArray()
            try {
                return [pscustomobject][ordered]@{
                    ExitCode = $startedProcess.Process.ExitCode
                    Stdout = [Text.UTF8Encoding]::new($false, $true).GetString($stdoutBytes)
                    Stderr = [Text.UTF8Encoding]::new($false, $true).GetString($stderrBytes)
                    CallRoot = $callRoot
                    ParentEnvironment = $environment
                    Executed = Test-Path -LiteralPath (Join-Path $callRoot 'invocation.txt') -PathType Leaf
                }
            } finally {
                if ($stdoutBytes.Length) { [Array]::Clear($stdoutBytes,0,$stdoutBytes.Length) }
                if ($stderrBytes.Length) { [Array]::Clear($stderrBytes,0,$stderrBytes.Length) }
            }
        } finally {
            if ($null -ne $job) { $job.Dispose() }
            if ($null -ne $startedProcess) { $startedProcess.Dispose() }
            $stdout.Dispose()
            $stderr.Dispose()
        }
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw '无法启动 synthetic T0 adb sidecar。' }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
            throw 'synthetic T0 adb sidecar 超时。'
        }
        $process.WaitForExit()
        return [pscustomobject][ordered]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
            CallRoot = $callRoot
            ParentEnvironment = $environment
            Executed = Test-Path -LiteralPath (Join-Path $callRoot 'invocation.txt') -PathType Leaf
        }
    }
    finally { $process.Dispose() }
}

[void](New-Item -ItemType Directory -Path $TestRoot)
try {
    $fakeSourcePath = Join-Path $TestRoot 'fake-adb.cs'
    $fakeSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class Program {
    public static int Main(string[] args) {
        string state = Environment.GetEnvironmentVariable("TABLET_C1A_FAKE_STATE");
        if (String.IsNullOrEmpty(state)) return 90;
        Directory.CreateDirectory(state);
        File.WriteAllLines(Path.Combine(state, "argv.txt"), args, new UTF8Encoding(false));
        var rows = new List<string>();
        foreach (DictionaryEntry entry in Environment.GetEnvironmentVariables()) {
            string value = entry.Value == null ? "" : entry.Value.ToString();
            rows.Add(entry.Key.ToString() + "=" +
                Convert.ToBase64String(Encoding.UTF8.GetBytes(value)));
        }
        rows.Sort(StringComparer.Ordinal);
        File.WriteAllLines(Path.Combine(state, "environment.txt"), rows.ToArray(),
            new UTF8Encoding(false));
        File.WriteAllText(Path.Combine(state, "invocation.txt"), "executed",
            new UTF8Encoding(false));
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.Write("fixture-output");
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($fakeSourcePath, $fakeSource, [Text.UTF8Encoding]::new($false))
    $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $cscPath -PathType Leaf)) {
        $cscPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    Assert-True (Test-Path -LiteralPath $cscPath -PathType Leaf) '离线测试缺少 Windows csc.exe。'
    & $cscPath /nologo /target:exe "/out:$FakeAdbPath" $fakeSourcePath
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $FakeAdbPath -PathType Leaf)) `
        '无法编译 synthetic fake adb。'

    $testLockPath = Join-Path $TestRoot 'locks\device-v1.lock'
    $escapedLockPath = $testLockPath.Replace("'", "''")
    $testDispatchSource = (Get-Content -LiteralPath $DispatchLibraryPath -Raw) + @"

function Get-DispatchGlobalLockPath {
    return Initialize-DispatchLockParent -Path '$escapedLockPath'
}
"@
    [IO.File]::WriteAllText(
        $TestDispatchLibraryPath, $testDispatchSource, [Text.UTF8Encoding]::new($false))
    . $IntakeLibraryPath
    . $TestDispatchLibraryPath
    $deviceLease = Open-DispatchLock -Path (Get-DispatchGlobalLockPath) `
        -Owner 'tablet-layout-c1a-t0-adb-sidecar-offline' -LeaseToken ''
    $readOnlyArguments = [string[]](Get-TabletAdbArguments -Name prop_brand -Serial 'FAKE123')

    Test-Case '合法 loopback 高端口同时绑定 argv 与 child environment' {
        $socket = 'tcp:127.0.0.1:55001'
        $result = Invoke-TestSidecar -Arguments $readOnlyArguments -IncludeSocket -Socket $socket
        Assert-Equal $result.ExitCode 0 '合法 ADB_SERVER_SOCKET 调用失败'
        Assert-Equal $result.Stdout 'fixture-output' 'fake adb stdout 漂移'
        Assert-Equal $result.Stderr '' '合法 ADB_SERVER_SOCKET 产生 stderr'
        Assert-True $result.Executed '合法 ADB_SERVER_SOCKET 未执行 synthetic fake adb'
        $actualArguments = [string[]][IO.File]::ReadAllLines(
            (Join-Path $result.CallRoot 'argv.txt'), [Text.UTF8Encoding]::new($false, $true))
        Assert-Sequence $actualArguments (@('-H','127.0.0.1','-P','55001') + $readOnlyArguments) `
            'ADB server selector 未精确前置于原只读 argv'
        Assert-FakeEnvironment -Result $result -ExpectedSocket $socket
    }

    Test-Case 'private socket 未 creation-time 加入命名 client Job 时 fail closed' {
        $result = Invoke-TestSidecar -Arguments $readOnlyArguments -IncludeSocket `
            -Socket 'tcp:127.0.0.1:55003' -DisablePrivateJob
        Assert-Equal $result.ExitCode 97 '未加入 private client Job 的 sidecar 未失败'
        Assert-True (-not $result.Executed) 'Job proof 失败后仍启动 synthetic fake adb'
        Assert-True ($result.Stderr -match 'private client Job') 'Job proof 拒绝原因不明确'
    }

    Test-Case '动态端口闭区间两端均保持 canonical 十进制' {
        foreach ($port in @(49152,65535)) {
            $socket = "tcp:127.0.0.1:$port"
            $result = Invoke-TestSidecar -Arguments $readOnlyArguments -IncludeSocket -Socket $socket
            Assert-Equal $result.ExitCode 0 "边界端口 $port 被拒绝"
            $actualArguments = [string[]][IO.File]::ReadAllLines(
                (Join-Path $result.CallRoot 'argv.txt'), [Text.UTF8Encoding]::new($false, $true))
            Assert-Sequence $actualArguments (@('-H','127.0.0.1','-P',[string]$port) + $readOnlyArguments) `
                "边界端口 $port argv 漂移"
            Assert-FakeEnvironment -Result $result -ExpectedSocket $socket
        }
    }

    Test-Case '未设置 socket 保持 C1a 原 argv 与无 socket 环境' {
        $result = Invoke-TestSidecar -Arguments $readOnlyArguments
        Assert-Equal $result.ExitCode 0 '无 ADB_SERVER_SOCKET 兼容调用失败'
        $actualArguments = [string[]][IO.File]::ReadAllLines(
            (Join-Path $result.CallRoot 'argv.txt'), [Text.UTF8Encoding]::new($false, $true))
        Assert-Sequence $actualArguments $readOnlyArguments '无 socket 时擅自添加 adb server selector'
        Assert-FakeEnvironment -Result $result
    }

    Test-Case '缓存 devices 接受合法 socket 但绝不启动 adb' {
        $result = Invoke-TestSidecar -Arguments @('devices') -IncludeSocket `
            -Socket 'tcp:127.0.0.1:55002'
        Assert-Equal $result.ExitCode 0 '缓存 devices 调用失败'
        Assert-Equal $result.Stdout "List of devices attached`r`nFAKE123`tdevice`r`n" `
            '缓存 devices 输出漂移'
        Assert-Equal $result.Stderr '' '缓存 devices 产生 stderr'
        Assert-True (-not $result.Executed) '缓存 devices 启动了 synthetic fake adb'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $result.CallRoot 'argv.txt'))) `
            '缓存 devices 留下了 fake adb argv'
    }

    Test-Case '格式、host 与默认 5037 全部在 adb 前拒绝' {
        foreach ($socket in @(
            '', ' ', 'TCP:127.0.0.1:55001', 'tcp:localhost:55001',
            'tcp:0.0.0.0:55001', 'tcp:127.0.0.2:55001', 'tcp:[::1]:55001',
            'tcp:127.0.0.1:5037', 'tcp:127.0.0.1:+55001',
            'tcp:127.0.0.1:055001', 'tcp:127.0.0.1:55001 ',
            ' tcp:127.0.0.1:55001', 'tcp:127.0.0.1:55001:extra'
        )) {
            $result = Invoke-TestSidecar -Arguments $readOnlyArguments -IncludeSocket -Socket $socket
            Assert-Equal $result.ExitCode 97 "非法 socket 未 fail closed：<$socket>"
            Assert-True (-not $result.Executed) "非法 socket 执行了 fake adb：<$socket>"
        }
    }

    Test-Case '49152..65535 之外端口全部在 adb 前拒绝' {
        foreach ($socket in @(
            'tcp:127.0.0.1:49151','tcp:127.0.0.1:65536',
            'tcp:127.0.0.1:00000','tcp:127.0.0.1:99999'
        )) {
            $result = Invoke-TestSidecar -Arguments $readOnlyArguments -IncludeSocket -Socket $socket
            Assert-Equal $result.ExitCode 97 "越界端口未 fail closed：$socket"
            Assert-True (-not $result.Executed) "越界端口执行了 fake adb：$socket"
        }
    }
}
finally {
    if ($null -ne $deviceLease) {
        Assert-True (Close-DispatchLockLease -Lease $deviceLease) '测试设备租约未完整释放。'
    }
    $safeRoot = [IO.Path]::GetFullPath($TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([IO.Path]::GetDirectoryName($safeRoot) -cne $tempRoot) {
        throw '离线测试清理目标越出 temp。'
    }
    if (Test-Path -LiteralPath $safeRoot) { [IO.Directory]::Delete($safeRoot, $true) }
}

Write-Output "tablet-layout-c1a T0 adb sidecar offline: $script:Passed passed, $script:Failed failed, real adb/JDK/Gradle executions=0"
if ($script:Failed -ne 0) { exit 1 }
