#Requires -Version 7
<#
单机单派锁（执行 harness spec §4.2）。

派单进程在整个跑测期间独占持有锁文件句柄，所以"能否独占打开"就是"上一次派单
是否还活着"的真值：wrapper 或监督式 runner 被 Ctrl-C / 崩溃 / 被 kill 之后，
文件会留在盘上但句柄已由 OS 回收——这种残锁必须自动清，不该每次都让人手删
（2026-07-26 前的行为是直接报"手动删除锁文件重试"，每次 runner 崩溃都要人工介入）。
反过来，只要还有进程持着句柄，就一定拒绝，绝不靠超时或时间戳猜。
#>

function Get-DispatchLockHolder {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }
    try { $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None') }
    catch [IO.FileNotFoundException] {
        return [pscustomobject]@{ Present = $false; Active = $false; Detail = '锁文件已不存在' }
    }
    catch {
        return [pscustomobject]@{ Present = $true; Active = $true; Detail = '另一个进程仍持有锁句柄' }
    }

    try {
        $reader = [IO.StreamReader]::new($stream)
        $detail = $reader.ReadToEnd().Trim()
    }
    finally { $stream.Dispose() }

    [pscustomobject]@{
        Present = $true
        Active = $false
        Detail = if ($detail) { "残锁内容：$detail" } else { '空残锁' }
    }
}

<#
拿到锁则返回仍处于打开状态的 FileStream（调用方负责 Close 并删除锁文件）；
判定另一次派单确实在跑则抛错。残锁只自动清理一次，避免与并发者互删死循环。
#>
function Open-DispatchLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Owner
    )

    foreach ($attempt in 1, 2) {
        $stream = $null
        try { $stream = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None') }
        catch {
            $holder = Get-DispatchLockHolder -Path $Path
            if ($holder.Active) {
                throw "疑似另一次派单进行中（锁 $Path：$($holder.Detail)）。确认无并发后手动删除锁文件重试。"
            }
            if ($attempt -eq 2) {
                throw "派单锁 $Path 清理后仍拿不到（$($holder.Detail)）。确认无并发后手动删除锁文件重试。"
            }
            Write-Host "清理上次派单崩溃残留的锁（$($holder.Detail)）。"
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            continue
        }

        # 内容只用于人读诊断；判活靠句柄，不靠这里的 pid。
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.WriteLine("pid=$PID owner=$Owner at=$(Get-Date -Format 's')")
        $writer.Flush()
        return $stream
    }
}
