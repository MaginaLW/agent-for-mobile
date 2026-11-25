#Requires -Version 7.5
<#
PA2553 / Android 16 显式冷态起服助手。

仅在用户或运维显式调用时拉起 `MainActivity` 获取前台状态再由 `run-as ... am start-foreground-service`
启动 `GatewayService`，并只读检查无障碍绑定状态。
不替代 `scripts/dispatch.ps1` 预检，默认不会在日常派单中抢占已有前景 App 焦点，
且绝不修改 `enabled_accessibility_services`、`default_input_method` 或任何系统权限。

用法：
  scripts/bootstrap-gateway.ps1
  scripts/bootstrap-gateway.ps1 -ReturnHome
  scripts/bootstrap-gateway.ps1 -Json
#>
[CmdletBinding()]
param(
    [string]$AdbCommand = 'adb',
    [ValidateRange(1, 30)][int]$TimeoutSec = 8,
    [ValidateRange(0, 5000)][int]$SettleDelayMs = 500,
    [switch]$ReturnHome,
    [switch]$SkipA11yCheck,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot 'lib\dispatch-profile.ps1')
. (Join-Path $PSScriptRoot 'lib\dispatch-forensics.ps1')

function Read-GatewayAccessibilityStatusReadOnly {
    param([Parameter(Mandatory)][string]$AdbCommand)

    $fullComp = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
    $shortComp = 'dev.magina.gateway/.a11y.GatewayA11yService'
    $label = '执行网关'

    $enabledRaw = $null
    $enabledQueryOk = $false
    $gatewayEnabled = $false
    $leadingColon = $false
    $svcRead = Invoke-GatewaySettingsCommand -AdbCommand $AdbCommand `
        -SettingsArgs @('get', 'secure', 'enabled_accessibility_services')
    if ($svcRead.ExitCode -eq 0) {
        $enabledQueryOk = $true
        $parsed = ConvertFrom-AccessibilityServiceList -Raw $svcRead.Stdout
        $enabledRaw = $parsed.Raw
        $leadingColon = $parsed.LeadingColon
        $gatewayEnabled = [bool](@($parsed.Members | Where-Object {
            $_ -ceq $fullComp -or $_ -ceq $shortComp
        }).Count -gt 0)
    }

    $dumpsysOk = $false
    $gatewayBound = $false
    $gatewayCrashed = $false
    $global:LASTEXITCODE = 0
    $dumpsysOut = @(& $AdbCommand shell dumpsys accessibility 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 0) {
        $dumpsysOk = $true
        $dumpsysText = $dumpsysOut -join "`n"
        $gatewayBound = Test-GatewayAccessibilityComponentBound `
            -DumpsysText $dumpsysText -Component $fullComp -Label $label
        if ($dumpsysText -match '(?is)Crashed\s+services\s*[:=]\s*\{([^}]*)\}') {
            $crashedBody = [string]$Matches[1]
            $gatewayCrashed = $crashedBody.Contains('dev.magina.gateway', [StringComparison]::Ordinal)
        }
    }

    return [pscustomobject]@{
        enabled_query_ok = $enabledQueryOk
        enabled_raw = $enabledRaw
        leading_colon = $leadingColon
        gateway_enabled = $gatewayEnabled
        dumpsys_ok = $dumpsysOk
        gateway_bound = $gatewayBound
        gateway_crashed = $gatewayCrashed
    }
}

function Invoke-GatewayColdStartBootstrap {
    [CmdletBinding()]
    param(
        [string]$AdbCommand = 'adb',
        [ValidateRange(1, 30)][int]$TimeoutSec = 8,
        [ValidateRange(0, 5000)][int]$SettleDelayMs = 500,
        [switch]$ReturnHome,
        [switch]$SkipA11yCheck
    )

    if (-not (Get-Command $AdbCommand -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{
            Ok = $false
            Status = 'adb_missing'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = 'unknown'
            Message = "adb 不在 PATH 或不可执行：$AdbCommand"
            Accessibility = $null
        }
    }

    $global:LASTEXITCODE = 0
    $stateOutput = @(& $AdbCommand get-state 2>&1)
    $stateExit = $LASTEXITCODE
    $deviceState = "$($stateOutput | Select-Object -Last 1)".Trim()
    if ($stateExit -ne 0 -or $deviceState -cne 'device') {
        return [pscustomobject]@{
            Ok = $false
            Status = 'device_unavailable'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = 'unknown'
            Message = "无已授权设备（adb get-state -> $deviceState）"
            Accessibility = $null
        }
    }

    $global:LASTEXITCODE = 0
    & $AdbCommand shell input keyevent KEYCODE_WAKEUP *> $null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Ok = $false
            Status = 'wakeup_failed'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = 'unknown'
            Message = '设备唤醒失败（adb shell input keyevent KEYCODE_WAKEUP）'
            Accessibility = $null
        }
    }

    $initialState = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
    if ($initialState -ceq 'foreground') {
        $a11y = if ($SkipA11yCheck) { $null } else { Read-GatewayAccessibilityStatusReadOnly -AdbCommand $AdbCommand }
        return [pscustomobject]@{
            Ok = $true
            Status = 'already_running'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = 'foreground'
            Message = 'GatewayService 已在前台运行，无需冷态拉起。'
            Accessibility = $a11y
        }
    }

    if ($initialState -cne 'absent') {
        return [pscustomobject]@{
            Ok = $false
            Status = 'unknown_service_state'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = $initialState
            Message = "无法确认 GatewayService 处于 absent 或 foreground（当前：$initialState），已安全中止。"
            Accessibility = $null
        }
    }

    $global:LASTEXITCODE = 0
    & $AdbCommand shell am start -n dev.magina.gateway/.MainActivity *> $null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Ok = $false
            Status = 'main_activity_start_failed'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = 'absent'
            Message = '拉起 dev.magina.gateway/.MainActivity 失败，无法建立冷态前台窗口。'
            Accessibility = $null
        }
    }

    if ($SettleDelayMs -gt 0) {
        Start-Sleep -Milliseconds $SettleDelayMs
    }

    $global:LASTEXITCODE = 0
    & $AdbCommand shell run-as dev.magina.gateway am start-foreground-service --user 0 -n dev.magina.gateway/.GatewayService *> $null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Ok = $false
            Status = 'fgs_start_failed'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = (Get-GatewayForegroundServiceState -AdbCommand $AdbCommand)
            Message = 'run-as 启动 GatewayService 前台服务失败。'
            Accessibility = $null
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    $finalState = 'absent'
    while ($true) {
        $finalState = Get-GatewayForegroundServiceState -AdbCommand $AdbCommand
        if ($finalState -ceq 'foreground') { break }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    }

    if ($finalState -cne 'foreground') {
        return [pscustomobject]@{
            Ok = $false
            Status = 'start_timeout'
            ColdStarted = $false
            ReturnedHome = $false
            ServiceState = $finalState
            Message = "GatewayService 在 ${TimeoutSec}s 内未进入前台运行状态（当前：$finalState）。"
            Accessibility = $null
        }
    }

    $returnedHome = $false
    if ($ReturnHome) {
        $global:LASTEXITCODE = 0
        & $AdbCommand shell input keyevent KEYCODE_HOME *> $null
        $returnedHome = ($LASTEXITCODE -eq 0)
    }

    $a11yAfter = if ($SkipA11yCheck) { $null } else { Read-GatewayAccessibilityStatusReadOnly -AdbCommand $AdbCommand }
    return [pscustomobject]@{
        Ok = $true
        Status = 'cold_started'
        ColdStarted = $true
        ReturnedHome = $returnedHome
        ServiceState = 'foreground'
        Message = '已通过 MainActivity + run-as 拉起 GatewayService（foreground）。'
        Accessibility = $a11yAfter
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-GatewayColdStartBootstrap `
        -AdbCommand $AdbCommand `
        -TimeoutSec $TimeoutSec `
        -SettleDelayMs $SettleDelayMs `
        -ReturnHome:$ReturnHome `
        -SkipA11yCheck:$SkipA11yCheck
    if ($Json) {
        $result | ConvertTo-Json -Depth 6
    }
    else {
        $color = if ($result.Ok) { 'Green' } else { 'Red' }
        Write-Host "[$($result.Status)] $($result.Message)" -ForegroundColor $color
        if ($null -ne $result.Accessibility) {
            $a = $result.Accessibility
            Write-Host ("  无障碍只读状态: enabled={0}, bound={1}, crashed={2}, raw={3}" -f `
                $a.gateway_enabled, $a.gateway_bound, $a.gateway_crashed, $a.enabled_raw) -ForegroundColor DarkGray
        }
    }
    if ($result.Ok) { exit 0 } else { exit 1 }
}
