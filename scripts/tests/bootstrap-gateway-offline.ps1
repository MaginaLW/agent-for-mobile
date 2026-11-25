#Requires -Version 7.5
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$scriptPath = Join-Path $repoRoot 'scripts\bootstrap-gateway.ps1'
$pwshPath = (Get-Process -Id $PID).Path
. $scriptPath

$passed = 0
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
}

$scratch = Join-Path $repoRoot ('.checks\bootstrap-gateway-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null

$savedEnv = @{
    BG_ADB_LOG            = $env:BG_ADB_LOG
    BG_ADB_STATE          = $env:BG_ADB_STATE
    BG_SVC_STATE_FILE     = $env:BG_SVC_STATE_FILE
    BG_MAIN_FLAG          = $env:BG_MAIN_FLAG
    BG_MAIN_EXIT          = $env:BG_MAIN_EXIT
    BG_FGS_EXIT           = $env:BG_FGS_EXIT
    BG_KEEP_ABSENT        = $env:BG_KEEP_ABSENT
    BG_REQUIRE_MAIN_FIRST = $env:BG_REQUIRE_MAIN_FIRST
    BG_A11Y_LIST          = $env:BG_A11Y_LIST
    BG_A11Y_BOUND         = $env:BG_A11Y_BOUND
    BG_A11Y_CRASHED       = $env:BG_A11Y_CRASHED
}

try {
    $adbCmd = Join-Path $scratch 'adb.cmd'
    $adbLog = Join-Path $scratch 'adb.log'
    $svcFile = Join-Path $scratch 'svc.state'
    $mainFlag = Join-Path $scratch 'main.started'

    $fakeAdbCmd = @'
@echo off
setlocal EnableExtensions
>>"%BG_ADB_LOG%" echo %*

if "%~1"=="get-state" goto :do_get_state
if "%~1"=="shell" goto :do_shell
goto :unsupported

:do_get_state
if "%BG_ADB_STATE%"=="" (
  echo device
  exit /b 0
)
echo %BG_ADB_STATE%
if "%BG_ADB_STATE%"=="device" exit /b 0
exit /b 1

:do_shell
if "%~2"=="input" exit /b 0
if "%~2"=="dumpsys" if "%~3"=="activity" if "%~4"=="services" goto :do_dumpsys_svc
if "%~2"=="am" if "%~3"=="start" goto :do_am_start
if "%~2"=="run-as" if "%~3"=="dev.magina.gateway" if "%~4"=="am" if "%~5"=="start-foreground-service" goto :do_fgs_start
if "%~2"=="settings" if "%~3"=="get" if "%~4"=="secure" if "%~5"=="enabled_accessibility_services" goto :do_get_a11y
if "%~2"=="dumpsys" if "%~3"=="accessibility" goto :do_dumpsys_a11y
goto :unsupported

:do_dumpsys_svc
set "CUR_SVC=absent"
if exist "%BG_SVC_STATE_FILE%" set /p CUR_SVC=<"%BG_SVC_STATE_FILE%"
if /I "%CUR_SVC%"=="foreground" goto :svc_fg
if /I "%CUR_SVC%"=="unknown" goto :svc_unk
echo (nothing)
exit /b 0

:svc_fg
echo   * ServiceRecord{1234 u0 dev.magina.gateway/.GatewayService}
echo     isForeground=true foregroundId=1
exit /b 0

:svc_unk
echo   * ServiceRecord{1234 u0 dev.magina.gateway/.GatewayService}
echo     app=null isForeground=false
exit /b 0

:do_am_start
if not "%BG_MAIN_EXIT%"=="" if not "%BG_MAIN_EXIT%"=="0" exit /b %BG_MAIN_EXIT%
if not "%BG_MAIN_FLAG%"=="" >"%BG_MAIN_FLAG%" echo started
exit /b 0

:do_fgs_start
if "%BG_REQUIRE_MAIN_FIRST%"=="1" if not exist "%BG_MAIN_FLAG%" exit /b 2
if not "%BG_FGS_EXIT%"=="" if not "%BG_FGS_EXIT%"=="0" exit /b %BG_FGS_EXIT%
if not "%BG_KEEP_ABSENT%"=="1" >"%BG_SVC_STATE_FILE%" echo foreground
exit /b 0

:do_get_a11y
if "%BG_A11Y_LIST%"=="" (
  echo :com.baidu.input_vivo/.AutoSendImageService:dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService
  exit /b 0
)
echo %BG_A11Y_LIST%
exit /b 0

:do_dumpsys_a11y
if "%BG_A11Y_BOUND%"=="0" (
  echo Bound services:{}
) else (
  echo Bound services:{dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService}
)
if "%BG_A11Y_CRASHED%"=="1" (
  echo Crashed services:{dev.magina.gateway/.a11y.GatewayA11yService}
) else (
  echo Crashed services:{}
)
exit /b 0

:unsupported
echo unsupported command: %* 1>&2
exit /b 9
'@
    Set-Content -LiteralPath $adbCmd -Value $fakeAdbCmd -Encoding ascii

    $env:BG_ADB_LOG = $adbLog
    $env:BG_SVC_STATE_FILE = $svcFile
    $env:BG_MAIN_FLAG = $mainFlag

    function Reset-FakeAdbState([string]$SvcState) {
        $env:BG_ADB_STATE = 'device'
        $env:BG_MAIN_EXIT = '0'
        $env:BG_FGS_EXIT = '0'
        $env:BG_KEEP_ABSENT = '0'
        $env:BG_REQUIRE_MAIN_FIRST = '1'
        $env:BG_A11Y_LIST = ''
        $env:BG_A11Y_BOUND = '1'
        $env:BG_A11Y_CRASHED = '0'
        Set-Content -LiteralPath $svcFile -Value $SvcState -NoNewline -Encoding ascii
        Remove-Item -LiteralPath $adbLog, $mainFlag -Force -ErrorAction SilentlyContinue
    }

    Test-Case 'already_running_is_idempotent_without_starting_main_activity' {
        Reset-FakeAdbState 'foreground'
        $res = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0
        Assert-True ($res.Ok -and $res.Status -ceq 'already_running') "预期 already_running，实际 $($res.Status)"
        Assert-True (-not $res.ColdStarted) '已有前台服务时 ColdStarted 应为 false'
        Assert-True ($res.Accessibility.leading_colon -and $res.Accessibility.gateway_enabled -and $res.Accessibility.gateway_bound) '应只读回传保留前导冒号的无障碍状态'
        $logText = Get-Content -LiteralPath $adbLog -Raw
        Assert-True ($logText -notmatch 'MainActivity|start-foreground-service|settings\s+put') '不应触碰 MainActivity、FGS 启动或写无障碍设置'
    }

    Test-Case 'cold_start_launches_main_activity_then_run_as_fgs' {
        Reset-FakeAdbState 'absent'
        $res = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0 -TimeoutSec 3
        Assert-True ($res.Ok -and $res.Status -ceq 'cold_started') "预期 cold_started，实际 $($res.Status) / $($res.Message)"
        Assert-True ($res.ColdStarted -and -not $res.ReturnedHome) '冷启动状态字段不符'
        Assert-True ($res.ServiceState -ceq 'foreground') '启动后应进入 foreground'
        Assert-True ($res.Accessibility.gateway_enabled -and $res.Accessibility.gateway_bound -and -not $res.Accessibility.gateway_crashed) '应读回已绑定无障碍状态'
        $logText = Get-Content -LiteralPath $adbLog -Raw
        $mainIdx = $logText.IndexOf('am start -n dev.magina.gateway/.MainActivity', [StringComparison]::Ordinal)
        $fgsIdx = $logText.IndexOf('run-as dev.magina.gateway am start-foreground-service --user 0 -n dev.magina.gateway/.GatewayService', [StringComparison]::Ordinal)
        Assert-True ($mainIdx -ge 0 -and $fgsIdx -gt $mainIdx) '必须先起 MainActivity 再 run-as 起 FGS'
        Assert-True ($logText -notmatch 'settings\s+put|settings\s+delete') '冷态起服不得改写无障碍设置'
    }

    Test-Case 'return_home_sends_keyevent_home_after_cold_start' {
        Reset-FakeAdbState 'absent'
        $res = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0 -TimeoutSec 3 -ReturnHome
        Assert-True ($res.Ok -and $res.ColdStarted -and $res.ReturnedHome) '带 -ReturnHome 时应成功切回桌面'
        $logText = Get-Content -LiteralPath $adbLog -Raw
        Assert-True ($logText -match 'KEYCODE_HOME') '应发出 KEYCODE_HOME'
    }

    Test-Case 'unknown_service_state_fails_closed_without_launching' {
        Reset-FakeAdbState 'unknown'
        $res = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0
        Assert-True (-not $res.Ok -and $res.Status -ceq 'unknown_service_state') 'unknown 状态必须 fail-closed'
        $logText = Get-Content -LiteralPath $adbLog -Raw
        Assert-True ($logText -notmatch 'MainActivity|start-foreground-service') 'unknown 状态不得盲拉 Activity 或服务'
    }

    Test-Case 'unauthorized_device_fails_closed' {
        Reset-FakeAdbState 'absent'
        $env:BG_ADB_STATE = 'unauthorized'
        $res = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0
        Assert-True (-not $res.Ok -and $res.Status -ceq 'device_unavailable') '未授权设备必须立即失败'
    }

    Test-Case 'fgs_failure_or_timeout_returns_nonzero_cli_exit' {
        Reset-FakeAdbState 'absent'
        $env:BG_FGS_EXIT = '1'
        $outFail = & $pwshPath -NoProfile -File $scriptPath -AdbCommand $adbCmd -SettleDelayMs 0 -Json 2>&1
        Assert-True ($LASTEXITCODE -ne 0) 'FGS 启动失败应返回非零退出码'
        $parsedFail = ($outFail | Out-String) | ConvertFrom-Json -Depth 6
        Assert-True (-not $parsedFail.Ok -and $parsedFail.Status -ceq 'fgs_start_failed') 'JSON 应报告 fgs_start_failed'

        Reset-FakeAdbState 'absent'
        $env:BG_KEEP_ABSENT = '1'
        $resTimeout = Invoke-GatewayColdStartBootstrap -AdbCommand $adbCmd -SettleDelayMs 0 -TimeoutSec 1
        Assert-True (-not $resTimeout.Ok -and $resTimeout.Status -ceq 'start_timeout') '服务未进入 foreground 应报 start_timeout'
    }

    Write-Host "bootstrap gateway offline: $passed passed, 0 failed"
}
finally {
    foreach ($key in $savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process')
    }
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}
