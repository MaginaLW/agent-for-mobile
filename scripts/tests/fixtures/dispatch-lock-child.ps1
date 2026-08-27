#Requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HelperPath,
    [Parameter(Mandatory)][string]$LocalAppDataPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReleasePath
)

$ErrorActionPreference = 'Stop'
. $HelperPath

$lease = $null
try {
    $path = Get-DispatchGlobalLockPath -LocalAppDataPath $LocalAppDataPath
    # token 不在命令行；Open-DispatchLock 从直属父进程传来的进程环境自动 join。
    $lease = Open-DispatchLock -Path $path -Owner 'offline-child'
    Set-Content -LiteralPath $ReadyPath -Value $PID -Encoding ascii
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw '等待测试释放信号超时。' }
        Start-Sleep -Milliseconds 25
    }
}
finally {
    if ($null -ne $lease) { [void](Close-DispatchLockLease -Lease $lease) }
}
