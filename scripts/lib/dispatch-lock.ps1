#Requires -Version 7
<#
单机单派锁（执行 harness spec §4.2）。

派单进程在整个跑测期间独占持有锁文件句柄，所以"能否独占打开"就是"上一次派单
是否还活着"的真值：wrapper 或监督式 runner 被 Ctrl-C / 崩溃 / 被 kill 之后，
文件会留在盘上但句柄已由 OS 回收——这种残锁必须自动清，不该每次都让人手删
（2026-07-26 前的行为是直接报"手动删除锁文件重试"，每次 runner 崩溃都要人工介入）。
反过来，只要还有进程持着句柄，就一定拒绝，绝不靠超时或时间戳猜。
#>

function Assert-DispatchLockLeafSafe {
    param([Parameter(Mandatory)][string]$Path)

    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { return $false }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { throw 'unsafe_dispatch_lock_path' }

    $linkTypeProperty = $item.PSObject.Properties['LinkType']
    $hasLinkType = $null -ne $linkTypeProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $hasLinkType) {
        throw 'unsafe_dispatch_lock_path'
    }
    return $true
}

function Resolve-DispatchSafePersistentPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRoot,
        [Parameter(Mandatory)][string]$BoundaryRoot,
        [ValidateSet('Leaf','Container')][string]$PathKind = 'Leaf',
        [switch]$AllowMissing
    )

    try {
        $boundary = [IO.Path]::GetFullPath($BoundaryRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $expected = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $candidate = [IO.Path]::GetFullPath($Path).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    catch { throw [IO.InvalidDataException]::new('unsafe_artifact_path') }

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $boundaryPrefix = $boundary + [IO.Path]::DirectorySeparatorChar
    if (-not ($expected.Equals($boundary, $comparison) -or
        $expected.StartsWith($boundaryPrefix, $comparison))) {
        throw [IO.InvalidDataException]::new('unsafe_artifact_path')
    }
    if ($PathKind -ceq 'Leaf') {
        $parent = [IO.Path]::GetDirectoryName($candidate).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if (-not $parent.Equals($expected, $comparison)) {
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
    }
    elseif (-not $candidate.Equals($expected, $comparison)) {
        throw [IO.InvalidDataException]::new('unsafe_artifact_path')
    }

    # 从可信边界逐级检查到 expected root；任何 ancestor/容器 link 都拒绝。
    $directories = [Collections.Generic.List[string]]::new()
    [void]$directories.Add($boundary)
    $relativeRoot = [IO.Path]::GetRelativePath($boundary, $expected)
    if ($relativeRoot -cne '.') {
        $cursor = $boundary
        foreach ($segment in $relativeRoot.Split(
            [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
            [StringSplitOptions]::RemoveEmptyEntries)) {
            $cursor = Join-Path $cursor $segment
            [void]$directories.Add($cursor)
        }
    }
    foreach ($directory in $directories) {
        $item = $null
        try { $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] {
            if ($PathKind -ceq 'Container' -and $AllowMissing) { break }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch [IO.FileNotFoundException] {
            if ($PathKind -ceq 'Container' -and $AllowMissing) { break }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch [IO.DirectoryNotFoundException] {
            if ($PathKind -ceq 'Container' -and $AllowMissing) { break }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch { throw [IO.InvalidDataException]::new('unsafe_artifact_path') }
        $linkType = $item.PSObject.Properties['LinkType']
        if (-not $item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($null -ne $linkType -and -not [string]::IsNullOrWhiteSpace([string]$linkType.Value))) {
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
    }

    if ($PathKind -ceq 'Leaf') {
        $leaf = $null
        try { $leaf = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] {
            if ($AllowMissing) { return $candidate }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch [IO.FileNotFoundException] {
            if ($AllowMissing) { return $candidate }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch [IO.DirectoryNotFoundException] {
            if ($AllowMissing) { return $candidate }
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
        catch { throw [IO.InvalidDataException]::new('unsafe_artifact_path') }
        $linkType = $leaf.PSObject.Properties['LinkType']
        if ($leaf.PSIsContainer -or
            ($leaf.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($null -ne $linkType -and -not [string]::IsNullOrWhiteSpace([string]$linkType.Value))) {
            throw [IO.InvalidDataException]::new('unsafe_artifact_path')
        }
    }
    return $candidate
}

function Get-DispatchLockHolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Assert-DispatchLockLeafSafe -Path $Path)) {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }
    try { $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None') }
    catch [IO.FileNotFoundException] {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }
    catch {
        return [pscustomobject]@{ Present = $true; Active = $true; Detail = '另一个进程仍持有锁句柄' }
    }

    # 判活只需要“能否独占打开”；残锁正文完全不参与机械判断，也不得作为诊断回显。
    # 即便是普通 leaf，也可能被同机故障进程写入 token/路径，读取原文只会扩散敏感面。
    $stream.Dispose()

    [pscustomobject]@{
        Present = $true
        Active = $false
        Detail = '残锁文件可独占打开'
    }
}

function Get-DispatchLeaseTokenSha256 {
    param([Parameter(Mandatory)][string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { throw '设备 lease owner token 不能为空。' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($Token)
    $digest = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($bytes)
        return ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        if ($null -ne $digest -and $digest.Length -gt 0) { [Array]::Clear($digest, 0, $digest.Length) }
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function ConvertFrom-DispatchHex {
    param([Parameter(Mandatory)][string]$Hex)
    if (($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
        throw 'invalid_dispatch_hex'
    }
    $bytes = [byte[]]::new([int]($Hex.Length / 2))
    try {
        for ($index = 0; $index -lt $bytes.Length; $index++) {
            $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
        }
        return ,$bytes
    }
    catch {
        if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($_.Exception.Message -ceq 'invalid_dispatch_hex') { throw }
        throw 'invalid_dispatch_hex'
    }
}

<#
拿到锁则返回仍处于打开状态的 FileStream（调用方负责 Close 并删除锁文件）；
判定另一次派单确实在跑则抛错。残锁只自动清理一次，避免与并发者互删死循环。
#>
function Open-DispatchLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner,
        # runner 创建全生命周期 lease 时传入；锁文件只落 hash，原 token 只经子进程环境继承。
        [string]$LeaseOwnerToken,
        # runner 的子 dispatch 用同一个 token 只读加入现有 lease，不重新取写锁，避免自锁。
        [switch]$InheritLease
    )

    [void](Assert-DispatchLockLeafSafe -Path $Path)

    if ($InheritLease) {
        if ([string]::IsNullOrWhiteSpace($LeaseOwnerToken)) {
            throw '继承设备 lease 时缺少 owner token。'
        }
        $stream = $null
        try {
            # owner 句柄以 FileShare.Read 创建：只有拿到原 token 的子 dispatch 能读并加入；
            # 本句柄也只 Share.Read，所以 runner 异常退出后，子 dispatch 仍会挡住普通写 lease。
            $stream = [IO.File]::Open(
                $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $reader = [IO.StreamReader]::new(
                $stream, [Text.UTF8Encoding]::new($false), $true, 1024, $true)
            try { $content = $reader.ReadToEnd() }
            finally { $reader.Dispose() }

            $match = [regex]::Match($content, '(?m)^lease_token_sha256=([0-9a-f]{64})\s*$')
            if (-not $match.Success) { throw '设备 lease 不支持继承或元数据损坏。' }
            $expected = Get-DispatchLeaseTokenSha256 -Token $LeaseOwnerToken
            $actualBytes = ConvertFrom-DispatchHex -Hex $match.Groups[1].Value
            $expectedBytes = ConvertFrom-DispatchHex -Hex $expected
            try {
                if (-not [Security.Cryptography.CryptographicOperations]::FixedTimeEquals($actualBytes, $expectedBytes)) {
                    throw '设备 lease owner token 不匹配，拒绝子派单加入。'
                }
            }
            finally {
                [Array]::Clear($actualBytes, 0, $actualBytes.Length)
                [Array]::Clear($expectedBytes, 0, $expectedBytes.Length)
            }
            Add-Member -InputObject $stream -NotePropertyName DispatchLeaseInherited -NotePropertyValue $true -Force
            return $stream
        }
        catch {
            if ($null -ne $stream) { $stream.Dispose() }
            throw
        }
    }

    foreach ($attempt in 1, 2) {
        $stream = $null
        $createStream = $null
        $bridgeStream = $null
        $createdByThisAttempt = $false
        try {
            if ([string]::IsNullOrWhiteSpace($LeaseOwnerToken)) {
                $stream = [IO.File]::Open(
                    $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $createdByThisAttempt = $true
            }
            else {
                # Windows 的 share compatibility 是双向的：ReadWrite owner + Share.Read 无法让
                # Read child 加入。先用可共享 writer 建档，再用一个 permissive reader 桥接到
                # 最终的 strict Read/Share.Read keeper；全程至少一个句柄在场，不留“残锁”竞态窗。
                $createStream = [IO.File]::Open(
                    $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                $createdByThisAttempt = $true
                $writer = [IO.StreamWriter]::new(
                    $createStream, [Text.UTF8Encoding]::new($false), 1024, $true)
                try {
                    $writer.WriteLine("pid=$PID owner=$Owner at=$(Get-Date -Format 's')")
                    $writer.WriteLine("lease_token_sha256=$(Get-DispatchLeaseTokenSha256 -Token $LeaseOwnerToken)")
                    $writer.Flush()
                    $createStream.Flush($true)
                }
                finally { $writer.Dispose() }

                $bridgeStream = [IO.File]::Open(
                    $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                $createStream.Dispose()
                $createStream = $null
                $stream = [IO.File]::Open(
                    $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                $bridgeStream.Dispose()
                $bridgeStream = $null
            }
        }
        catch {
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $bridgeStream) { $bridgeStream.Dispose() }
            if ($null -ne $createStream) { $createStream.Dispose() }
            if ($createdByThisAttempt) {
                [void](Assert-DispatchLockLeafSafe -Path $Path)
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
                throw
            }
            $holder = Get-DispatchLockHolder -Path $Path
            if ($holder.Active) {
                throw "疑似另一次派单进行中（锁 $Path：$($holder.Detail)）。确认无并发后手动删除锁文件重试。"
            }
            if ($attempt -eq 2) {
                throw "派单锁 $Path 清理后仍拿不到（$($holder.Detail)）。确认无并发后手动删除锁文件重试。"
            }
            Write-Host "清理上次派单崩溃残留的锁（$($holder.Detail)）。"
            [void](Assert-DispatchLockLeafSafe -Path $Path)
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            continue
        }

        # 内容只用于人读诊断；判活靠句柄，不靠这里的 pid。
        if ([string]::IsNullOrWhiteSpace($LeaseOwnerToken)) {
            $writer = [IO.StreamWriter]::new(
                $stream, [Text.UTF8Encoding]::new($false), 1024, $true)
            try {
                $writer.WriteLine("pid=$PID owner=$Owner at=$(Get-Date -Format 's')")
                $writer.Flush()
                $stream.Flush($true)
            }
            finally { $writer.Dispose() }
        }
        Add-Member -InputObject $stream -NotePropertyName DispatchLeaseInherited -NotePropertyValue $false -Force
        return $stream
    }
}

function Close-DispatchLock {
    param(
        [AllowNull()]$Stream,
        [Parameter(Mandatory)][string]$Path
    )
    if ($null -eq $Stream) { return }
    $inheritedProperty = $Stream.PSObject.Properties['DispatchLeaseInherited']
    $inherited = $null -ne $inheritedProperty -and [bool]$inheritedProperty.Value
    $Stream.Dispose()
    if (-not $inherited) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}
