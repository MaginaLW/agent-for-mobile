#Requires -Version 7.5
# 只给固定 T0 producer 使用：devices 返回已绑定设备缓存，其余 exact 只读 argv 才转发到真实 adb。
[CmdletBinding(PositionalBinding=$false)]
param([Parameter(ValueFromRemainingArguments)][string[]]$AdbArgs)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)

$deviceLease = $null
$exitCode = 97
$failure = $null
try {
    $realAdb = $env:TL1_C1A_REAL_ADB_PATH
    $serial = $env:TL1_C1A_BOUND_SERIAL
    $intakeLibrary = $env:TL1_C1A_T0_LIBRARY_PATH
    $dispatchLibrary = $env:TL1_C1A_DISPATCH_LOCK_LIBRARY
    foreach($library in @($intakeLibrary,$dispatchLibrary)){
        if([string]::IsNullOrWhiteSpace($library)-or-not[IO.Path]::IsPathFullyQualified($library)-or
           -not(Test-Path -LiteralPath $library -PathType Leaf)){throw 'T0 adb sidecar library 环境绑定无效。'}
        $item=Get-Item -LiteralPath $library -Force
        if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or
           -not[string]::IsNullOrWhiteSpace([string]$item.LinkType)){throw 'T0 adb sidecar library 必须是普通文件。'}
    }
    if ([string]::IsNullOrWhiteSpace($realAdb) -or -not [IO.Path]::IsPathFullyQualified($realAdb) -or
        -not (Test-Path -LiteralPath $realAdb -PathType Leaf) -or
        [string]::IsNullOrWhiteSpace($serial) -or $serial -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$') {
        throw 'T0 adb sidecar 环境绑定无效。'
    }
    $adbServerSocket = [Environment]::GetEnvironmentVariable(
        'ADB_SERVER_SOCKET', [EnvironmentVariableTarget]::Process)
    if ($null -ne $adbServerSocket) {
        throw 'C1b 私有 ADB 端点已退役；T0 adb sidecar 不接受 ADB_SERVER_SOCKET。'
    }
    . $intakeLibrary
    . $dispatchLibrary
    $deviceLease=Open-DispatchLock -Path (Get-DispatchGlobalLockPath) -Owner "tablet-intake-sidecar:$serial"

    if ($AdbArgs.Count -eq 1 -and $AdbArgs[0] -ceq 'devices') {
        [Console]::Out.Write("List of devices attached`r`n$serial`tdevice`r`n")
        $exitCode=0
    } else {
        $matched = $false
        foreach ($name in @(
            'prop_brand','prop_manufacturer','prop_model','prop_product','prop_device',
            'prop_android_release','prop_api','prop_abi','prop_fingerprint','wm_size','wm_density',
            'activity','window','display','power','policy','zen','default_ime','input_method','am_config'
        )) {
            $expected = [string[]](Get-TabletAdbArguments -Name $name -Serial $serial)
            if ($expected.Count -ne $AdbArgs.Count) { continue }
            $same = $true
            for ($index = 0; $index -lt $expected.Count; $index++) {
                if ($expected[$index] -cne $AdbArgs[$index]) { $same = $false; break }
            }
            if ($same) { $matched = $true; break }
        }
        if (-not $matched) { throw 'T0 adb sidecar 拒绝非固定只读 argv。' }

        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = $realAdb
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $adbEnvironment=[ordered]@{}
        foreach($name in @(
            'SYSTEMROOT','WINDIR','COMSPEC','PATHEXT','PATH','TEMP','TMP',
            'USERPROFILE','HOME','ANDROID_SDK_ROOT','ANDROID_HOME',
            'TABLET_C1A_FAKE_STATE','TABLET_C1A_FAKE_PWSH','TABLET_C1A_FAKE_QUERY_STDERR'
        )){
            $value=[Environment]::GetEnvironmentVariable($name,[EnvironmentVariableTarget]::Process)
            if(-not[string]::IsNullOrWhiteSpace($value)){$adbEnvironment[$name]=$value}
        }
        $start.Environment.Clear()
        foreach($entry in $adbEnvironment.GetEnumerator()){$start.Environment[$entry.Key]=$entry.Value}
        foreach ($argument in $AdbArgs) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $stdout = [IO.MemoryStream]::new()
        $stderr = [IO.MemoryStream]::new()
        $started = $false
        try {
            if (-not $process.Start()) { throw 'T0 adb sidecar 无法启动真实 adb。' }
            $started = $true
            $process.StandardInput.Close()
            $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
            $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not $process.HasExited) {
                if ($stdout.Length -gt 4MB -or $stderr.Length -gt 1MB) { throw 'T0 adb sidecar 输出超过固定上限。' }
                if ($watch.Elapsed.TotalSeconds -ge 30) { throw 'T0 adb sidecar 查询超时。' }
                Start-Sleep -Milliseconds 10
            }
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            if ($stdout.Length -gt 4MB -or $stderr.Length -gt 1MB) { throw 'T0 adb sidecar 输出超过固定上限。' }
            if ($process.ExitCode -ne 0) { throw 'T0 adb sidecar 真实 adb 查询失败。' }
            if ($stderr.Length -ne 0) { throw 'T0 adb sidecar 真实 adb stderr 必须 exact empty。' }
            $bytes = $stdout.ToArray()
            try{[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)}
            finally{if($bytes.Length){[Array]::Clear($bytes,0,$bytes.Length)}}
            $exitCode=0
        }
        catch {
            if ($started -and -not $process.HasExited) {
                try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
            }
            throw
        }
        finally {
            $stdout.Dispose()
            $stderr.Dispose()
            $process.Dispose()
        }
    }
}
catch {$failure=$_.Exception.Message;$exitCode=97}
finally {
    if($null-ne$deviceLease){
        try{[void](Close-DispatchLockLease -Lease $deviceLease)}
        catch{$failure='T0 adb sidecar device lease cleanup 失败。';$exitCode=97}
    }
}
if($exitCode-ne0){[Console]::Error.WriteLine("T0 adb sidecar 失败：$failure")}
exit $exitCode
