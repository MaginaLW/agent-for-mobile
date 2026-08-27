#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HelperPath,
    [Parameter(Mandatory)][string]$ChildScriptPath,
    [Parameter(Mandatory)][string]$LocalAppDataPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReleasePath,
    [Parameter(Mandatory)][string]$ChildPidPath
)

$ErrorActionPreference = 'Stop'
. $HelperPath

$path = Get-DispatchGlobalLockPath -TestOnlyLocalAppDataPath $LocalAppDataPath
$lease = Open-DispatchLock -Path $path -Owner 'offline-parent'

$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = (Get-Process -Id $PID).Path
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($argument in @(
    '-NoProfile', '-File', $ChildScriptPath,
    '-HelperPath', $HelperPath,
    '-LocalAppDataPath', $LocalAppDataPath,
    '-ReadyPath', $ReadyPath,
    '-ReleasePath', $ReleasePath
)) {
    $start.ArgumentList.Add($argument)
}
Set-DispatchLockLeaseEnvironment -StartInfo $start -Lease $lease
$child = [Diagnostics.Process]::new()
$child.StartInfo = $start
if (-not $child.Start()) { throw '无法启动租约子进程。' }
Set-Content -LiteralPath $ChildPidPath -Value $child.Id -Encoding ascii

$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $ReadyPath -PathType Leaf)) {
    if ($child.HasExited) { throw "租约子进程提前退出：$($child.ExitCode)" }
    if ([DateTime]::UtcNow -ge $deadline) { throw '租约子进程 join 超时。' }
    Start-Sleep -Milliseconds 25
}

# 故意不 Close：模拟持初始 lease 的父进程突然退出。OS 会回收父句柄；子进程已 join，
# 它的共享句柄必须继续让外来 worktree 失败。
exit 0
