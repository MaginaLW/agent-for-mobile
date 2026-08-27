#Requires -Version 7
<#
主机级设备租约（执行 harness spec §4.2）。

不同 git worktree 可能同时指向同一台手机，所以锁不得放在仓库里。生产调用统一使用
Windows LocalApplicationData Known Folder 下的 agent-for-mobile\locks\device-v1.lock；生产路径
不读取可注入的 LOCALAPPDATA 环境变量。显式替代根目录仅供离线测试，生产调用必须无参。

租约文件与短时 gate 分工：
* gate 只串行化“新建 / join / 最后一人清理”这几个很短的临界区；
* 同一租约的父子进程各持一个 FileShare.ReadWrite（但不共享 Delete）的句柄；
* 外来 owner 在 gate 内用 FileShare.None 探测，任一父/子仍持句柄都必须拒绝；
* 文件仍在但已无句柄就是残锁，可自动接管。

AGENT_MOBILE_DEVICE_LOCK_LEASE 只是父子间的合作租约标识，不是权限或安全凭据。
它只经 ProcessStartInfo.Environment 传给直属子进程，不写日志、不进入命令行；盘上只存哈希。
#>

$script:DispatchLockLeaseEnvironmentVariable = 'AGENT_MOBILE_DEVICE_LOCK_LEASE'
$script:DispatchLockSchemaVersion = 1

if ($null -eq ('AgentMobileDispatchLockFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class AgentMobileDispatchLockFile {
    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string path, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    public static bool IsOrdinarySingleLink(SafeFileHandle handle) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        return (information.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0 &&
            information.NumberOfLinks == 1;
    }

    public static SafeFileHandle OpenOrdinaryDirectoryGuard(string path) {
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
            IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(handle, out information)) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
            (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            handle.Dispose();
            throw new InvalidOperationException("dispatch lock directory is not ordinary");
        }
        return handle;
    }
}
'@
}

function Assert-DispatchOrdinarySingleLinkStream {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not [AgentMobileDispatchLockFile]::IsOrdinarySingleLink($Stream.SafeFileHandle)) {
        throw "设备锁必须是单链接普通文件：$Path"
    }
}

function Get-DispatchSha256 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally {
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Initialize-DispatchLockParent {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw '设备锁路径必须是绝对路径。'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) { throw '设备锁路径缺少父目录。' }

    $root = [IO.Path]::GetPathRoot($parent)
    $current = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::IsNullOrEmpty($current)) { $current = $root }
    $relative = $parent.Substring($root.Length)
    foreach ($segment in $relative.Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        try {
            if (-not (Test-Path -LiteralPath $current)) {
                [void][IO.Directory]::CreateDirectory($current)
            }
            $directoryInfo = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        }
        catch { throw '无法创建或验证主机级设备锁目录。' }
        if (-not $directoryInfo.PSIsContainer -or
            ($directoryInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$directoryInfo.LinkType)) {
            throw "主机级设备锁路径含非普通目录：$current"
        }
    }
    if ((Test-Path -LiteralPath $fullPath) -and
        (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw '设备锁路径被目录占用。'
    }
    return $fullPath
}

function Open-DispatchLockDirectoryGuards {
    param([Parameter(Mandatory)][string]$Path)

    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    $directories = [Collections.Generic.List[string]]::new()
    $agentDirectory = [IO.Path]::GetDirectoryName($parent)
    $baseDirectory = if ([string]::IsNullOrWhiteSpace($agentDirectory)) {
        ''
    } else { [IO.Path]::GetDirectoryName($agentDirectory) }
    if ([IO.Path]::GetFileName($Path) -ceq 'device-v1.lock' -and
        [IO.Path]::GetFileName($parent) -ceq 'locks' -and
        [IO.Path]::GetFileName($agentDirectory) -ceq 'agent-for-mobile' -and
        -not [string]::IsNullOrWhiteSpace($baseDirectory)) {
        $directories.Add($baseDirectory)
        $directories.Add($agentDirectory)
    }
    $directories.Add($parent)

    $guards = [Collections.Generic.List[object]]::new()
    try {
        foreach ($directory in $directories) {
            $guards.Add([AgentMobileDispatchLockFile]::OpenOrdinaryDirectoryGuard($directory))
        }
        return [object[]]$guards.ToArray()
    }
    catch {
        foreach ($guard in $guards) { $guard.Dispose() }
        throw '主机级设备锁目录链不可固定；拒绝触碰设备。'
    }
}

function Close-DispatchLockDirectoryGuards {
    param([AllowNull()]$Guards)
    foreach ($guard in @($Guards)) {
        if ($null -ne $guard) { $guard.Dispose() }
    }
}

function Get-DispatchGlobalLockPath {
    param([AllowEmptyString()][string]$TestOnlyLocalAppDataPath)

    if ($PSBoundParameters.ContainsKey('TestOnlyLocalAppDataPath')) {
        $localAppDataPath = $TestOnlyLocalAppDataPath
    } else {
        $localAppDataPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($localAppDataPath)) {
        throw '找不到稳定的 LocalApplicationData；拒绝退回 worktree 创建设备锁。'
    }
    if (-not [IO.Path]::IsPathFullyQualified($localAppDataPath)) {
        throw 'LocalApplicationData 必须是绝对路径；拒绝在 worktree 创建设备锁。'
    }

    $base = [IO.Path]::GetFullPath($localAppDataPath)
    $lockDir = Join-Path (Join-Path $base 'agent-for-mobile') 'locks'
    return Initialize-DispatchLockParent -Path (Join-Path $lockDir 'device-v1.lock')
}

function Read-DispatchLockMetadata {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    if ($Stream.Length -le 0 -or $Stream.Length -gt 4096) { return $null }
    $position = $Stream.Position
    try {
        $Stream.Position = 0
        $bytes = [byte[]]::new([int]$Stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { return $null }
            $offset += $read
        }
        try { return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json) }
        catch { return $null }
        finally {
            if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
    }
    finally { $Stream.Position = $position }
}

function Write-DispatchLockMetadata {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][string]$LeaseHash,
        [Parameter(Mandatory)][string]$Owner
    )

    $process = Get-Process -Id $PID -ErrorAction Stop
    $metadata = [ordered]@{
        schema_version = $script:DispatchLockSchemaVersion
        lease_hash = $LeaseHash
        owner_fingerprint = (Get-DispatchSha256 -Text $Owner).Substring(0, 16)
        pid = $PID
        process_start_ticks = $process.StartTime.ToUniversalTime().Ticks
        created_at = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($metadata)
    try {
        $Stream.Position = 0
        $Stream.SetLength(0)
        $Stream.Write($bytes, 0, $bytes.Length)
        $Stream.Flush($true)
        $Stream.Position = 0
    }
    finally {
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Open-DispatchLockGate {
    param([Parameter(Mandatory)][string]$Path)

    $gatePath = "$Path.gate"
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        try {
            return [IO.File]::Open($gatePath, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if (Test-Path -LiteralPath $gatePath -PathType Container) {
                throw '设备锁 gate 路径被目录占用。'
            }

            # gate 只活在毫秒级临界区。能独占打开说明创建者已经退出，是可清的残留文件；
            # 不能独占则让当前持有者先完成，直到有界截止时间。
            $probe = $null
            try {
                $probe = [IO.File]::Open($gatePath, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $probe.Dispose()
                $probe = $null
                Remove-Item -LiteralPath $gatePath -Force -ErrorAction Stop
                continue
            }
            catch [IO.FileNotFoundException] { continue }
            catch {
                if ($null -ne $probe) { $probe.Dispose() }
                if ([DateTime]::UtcNow -ge $deadline) {
                    throw '设备锁 gate 持续被占用；为避免并发操作手机，本次拒绝继续。'
                }
                Start-Sleep -Milliseconds 50
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw '设备锁 gate 获取超时；为避免并发操作手机，本次拒绝继续。'
}

function Close-DispatchLockGate {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][string]$Path
    )

    $Stream.Dispose()
    Remove-Item -LiteralPath "$Path.gate" -Force -ErrorAction SilentlyContinue
}

function New-DispatchLockLeaseObject {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LeaseToken,
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][bool]$Joined,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DirectoryGuards
    )

    $lease = [pscustomobject]@{
        Path = $Path
        LeaseToken = $LeaseToken
        LeaseHash = Get-DispatchSha256 -Text $LeaseToken
        Stream = $Stream
        Joined = $Joined
        DirectoryGuards = $DirectoryGuards
    }
    # 兼容旧调用方的 $lock.Close()；完整清理应调用 Close-DispatchLockLease，后者有
    # token/ABA 校验，只有最后一个 holder 才会删租约文件。
    $lease | Add-Member -MemberType ScriptMethod -Name Close -Value {
        if ($null -ne $this.Stream) {
            $this.Stream.Dispose()
            $this.Stream = $null
        }
        Close-DispatchLockDirectoryGuards -Guards $this.DirectoryGuards
        $this.DirectoryGuards = @()
    }
    $lease | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        if ($null -ne $this.Stream) {
            $this.Stream.Dispose()
            $this.Stream = $null
        }
        Close-DispatchLockDirectoryGuards -Guards $this.DirectoryGuards
        $this.DirectoryGuards = @()
    }
    return $lease
}

function Get-DispatchLockHolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }

    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.FileNotFoundException] {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }
    catch {
        return [pscustomobject]@{ Present = $true; Active = $true; Detail = '另一个进程树仍持有设备租约' }
    }

    try {
        $metadata = Read-DispatchLockMetadata -Stream $stream
        $detail = if ($null -eq $metadata) { '无法解析的残锁' } else { '已无进程持有的残锁' }
        return [pscustomobject]@{ Present = $true; Active = $false; Detail = $detail }
    }
    finally { $stream.Dispose() }
}

function Join-DispatchLockLease {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$LeaseToken
    )

    $Path = Initialize-DispatchLockParent -Path $Path
    if ([string]::IsNullOrWhiteSpace($LeaseToken)) { throw '子进程缺少设备租约标识。' }
    $expectedHash = Get-DispatchSha256 -Text $LeaseToken
    $directoryGuards = @()
    $gate = $null
    try {
        $directoryGuards = @(Open-DispatchLockDirectoryGuards -Path $Path)
        $gate = Open-DispatchLockGate -Path $Path
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw '父进程设备租约已不存在；子进程拒绝触碰设备。'
        }
        try {
            # 这个句柄本身就是 join：读取校验期间已经以兼容共享模式持有，校验成功后直接返回，
            # 不留下“读完再打开”窗口。
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        }
        catch { throw '父进程设备租约不可加入；子进程拒绝触碰设备。' }

        try {
            Assert-DispatchOrdinarySingleLinkStream -Stream $stream -Path $Path
            $metadata = Read-DispatchLockMetadata -Stream $stream
            if ($null -eq $metadata -or
                [int]$metadata.schema_version -ne $script:DispatchLockSchemaVersion -or
                [string]$metadata.lease_hash -cne $expectedHash) {
                throw '设备租约已更换或损坏；子进程拒绝触碰设备。'
            }
            $lease = New-DispatchLockLeaseObject -Path $Path -LeaseToken $LeaseToken `
                -Stream $stream -Joined $true -DirectoryGuards $directoryGuards
            $directoryGuards = @()
            return $lease
        }
        catch {
            $stream.Dispose()
            throw
        }
    }
    finally {
        if ($null -ne $gate) { Close-DispatchLockGate -Stream $gate -Path $Path }
        Close-DispatchLockDirectoryGuards -Guards $directoryGuards
    }
}

function Open-DispatchLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner,
        [AllowEmptyString()][string]$LeaseToken
    )

    if (-not $PSBoundParameters.ContainsKey('LeaseToken')) {
        $LeaseToken = [Environment]::GetEnvironmentVariable(
            $script:DispatchLockLeaseEnvironmentVariable,
            [EnvironmentVariableTarget]::Process
        )
        # runner 只把 token 给直属 dispatch；dispatch 一取得局部副本就必须从进程环境消费掉，
        # 后续 wrapper/brain 即使使用默认继承也拿不到设备租约标识。
        [Environment]::SetEnvironmentVariable(
            $script:DispatchLockLeaseEnvironmentVariable,
            $null,
            [EnvironmentVariableTarget]::Process
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($LeaseToken)) {
        return Join-DispatchLockLease -Path $Path -Owner $Owner -LeaseToken $LeaseToken
    }

    $Path = Initialize-DispatchLockParent -Path $Path
    $directoryGuards = @()
    $gate = $null
    try {
        $directoryGuards = @(Open-DispatchLockDirectoryGuards -Path $Path)
        $gate = Open-DispatchLockGate -Path $Path
        if (Test-Path -LiteralPath $Path) {
            if (Test-Path -LiteralPath $Path -PathType Container) {
                throw '设备锁路径被目录占用；为避免并发操作手机，本次拒绝继续。'
            }
            $probe = $null
            try {
                $probe = [IO.File]::Open($Path, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                Assert-DispatchOrdinarySingleLinkStream -Stream $probe -Path $Path
            }
            catch {
                throw '疑似另一次设备任务进行中；任一 worktree 都必须等待当前任务结束。'
            }
            finally { if ($null -ne $probe) { $probe.Dispose() } }
            # 不复用既有文件，也不以 FileMode.Create 截断它：先删除已验证的单链接残锁，
            # 再用 CreateNew 建立新 inode。竞争者若抢先放入 hardlink/reparse，CreateNew 只会失败。
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            Write-Host '清理上次进程树退出后留下的设备残锁。'
        }

        $token = [guid]::NewGuid().ToString('N')
        $stream = $null
        try {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
            Assert-DispatchOrdinarySingleLinkStream -Stream $stream -Path $Path
            Write-DispatchLockMetadata -Stream $stream -LeaseHash (Get-DispatchSha256 -Text $token) -Owner $Owner
            $lease = New-DispatchLockLeaseObject -Path $Path -LeaseToken $token -Stream $stream `
                -Joined $false -DirectoryGuards $directoryGuards
            $directoryGuards = @()
            return $lease
        }
        catch {
            if ($null -ne $stream) { $stream.Dispose() }
            throw '无法建立主机级设备租约；为避免并发操作手机，本次拒绝继续。'
        }
    }
    finally {
        if ($null -ne $gate) { Close-DispatchLockGate -Stream $gate -Path $Path }
        Close-DispatchLockDirectoryGuards -Guards $directoryGuards
    }
}

function Set-DispatchLockLeaseEnvironment {
    param(
        [Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory)]$Lease
    )

    if ($null -eq $Lease.Stream -or [string]::IsNullOrWhiteSpace([string]$Lease.LeaseToken)) {
        throw '不能把已释放或无效的设备租约传给子进程。'
    }
    $StartInfo.Environment[$script:DispatchLockLeaseEnvironmentVariable] = [string]$Lease.LeaseToken
}

function Close-DispatchLockLease {
    param([Parameter(Mandatory)]$Lease)

    if ($null -ne $Lease.Stream) {
        $Lease.Stream.Dispose()
        $Lease.Stream = $null
    }

    try {
        $path = [string]$Lease.Path
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $true
        }

        $gate = Open-DispatchLockGate -Path $path
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $true }
            $probe = $null
            try {
                $probe = [IO.File]::Open($path, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            catch {
                # 同租约的父/子仍持共享句柄；最后退出的 holder 会负责清理。
                return $false
            }

            try {
                $metadata = Read-DispatchLockMetadata -Stream $probe
                if ($null -eq $metadata -or [string]$metadata.lease_hash -cne [string]$Lease.LeaseHash) {
                    return $false
                }
            }
            finally { $probe.Dispose() }

            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return $true
        }
        finally { Close-DispatchLockGate -Stream $gate -Path $path }
    }
    finally {
        Close-DispatchLockDirectoryGuards -Guards $Lease.DirectoryGuards
        $Lease.DirectoryGuards = @()
    }
}
