#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Filter = '*',
    [string]$SummaryPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$SourceRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$SourceRunner = Join-Path $SourceRepoRoot 'scripts\run-tablet-intake.ps1'
$SourceLibrary = Join-Path $SourceRepoRoot 'scripts\lib\tablet-intake.ps1'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('agent-mobile-tablet-intake-' + [guid]::NewGuid().ToString('N'))
$PwshPath = (Get-Process -Id $PID).Path
$script:Passed = 0
$script:Failed = 0
$script:Results = [Collections.Generic.List[object]]::new()
$script:RequiredCoverage = @(
    'adb_path_missing', 'zero_devices', 'unauthorized_device', 'offline_device', 'multiple_devices',
    'query_failure', 'parse_unknown', 'parse_ambiguous', 'landscape_positive', 'portrait_blocked',
    'multi_window_blocked', 'pip_blocked', 'letterbox_blocked', 'exact_read_only_argv',
    'schema_v5', 'p0_always_unsupported', 'rotation_space_drift',
    'wm_size_override_blocked', 'wm_density_override_blocked', 'no_permissions_device',
    'mixed_device_offline', 'mixed_device_unauthorized', 'relative_adb_path', 'adb_path_directory',
    'devices_query_failure', 'adb_query_timeout', 'adb_path_with_spaces', 'devices_daemon_banner_crlf',
    'foreground_source_priority', 'foreground_malformed_blocked', 'focus_relationships',
    'window_identity_diagnostics', 'window_visibility_diagnostics', 'rotation_scope_diagnostics',
    'strict_window_fallback', 'capture_identity_consistency', 'window_identity_privacy',
    'numeric_overflow_fail_closed', 'unsafe_window_types', 'state_capture_consistency',
    'run_wide_window_labels'
)

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw $Because }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Because)
    if ($Actual -cne $Expected) { throw "$Because（期望=$Expected，实际=$Actual）" }
}

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string[]]$Covers = @()
    )
    if ($Name -notlike $Filter) { return }
    $started = [DateTime]::UtcNow
    try {
        & $Body
        $script:Passed++
        $script:Results.Add([ordered]@{
            name = $Name
            status = 'passed'
            covers = @($Covers | Sort-Object -Unique)
            duration_ms = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
            error = $null
        })
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:Results.Add([ordered]@{
            name = $Name
            status = 'failed'
            covers = @($Covers | Sort-Object -Unique)
            duration_ms = [int]([DateTime]::UtcNow - $started).TotalMilliseconds
            error = [string]$_.Exception.Message
        })
        Write-Host "FAIL $Name：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host ($_.ScriptStackTrace -replace "`r?`n", "`n  ")
    }
}

function Set-FixtureText {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    Set-Content -LiteralPath (Join-Path $Directory "$Name.txt") -Value $Value -Encoding utf8
}

function New-TabletFixture {
    param(
        [ValidateSet(
            'portrait','phone','landscape','four_three','letterbox_landscape','override_size','override_density',
            'rotation_space_drift','split','multi_window','pip_landscape','freeform','pinned','floating_ime',
            'zero','multiple','unauthorized','offline','no_permissions','mixed_offline','mixed_unauthorized',
            'devices_fail','devices_delay','daemon_banner','unknown','drift','wm_drift','am_drift','sw_source_drift','sw_conflict',
            'am_empty','am_absent','am_invalid','am_fail','vivo_no_rotation','state_drift','window_reorder'
        )]
        [string]$Scenario,
        [string]$Serial = 'RAW-SERIAL-SECRET-42',
        [string]$Fingerprint = 'vendor/product/device:16/BUILD/123:user/release-keys'
    )
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    $repo = Join-Path $root 'repo'
    $state = Join-Path $root 'state'
    $bin = Join-Path $root 'bin'
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'scripts\lib'),(Join-Path $repo 'docs\runs'),$state,$bin | Out-Null
    Copy-Item -LiteralPath $SourceRunner -Destination (Join-Path $repo 'scripts\run-tablet-intake.ps1')
    Copy-Item -LiteralPath $SourceLibrary -Destination (Join-Path $repo 'scripts\lib\tablet-intake.ps1')

    $fakeAdb = @'
@echo off
setlocal EnableExtensions
>>"%TABLET_FAKE_STATE%\adb.log" echo %*
if "%1"=="devices" goto devices
if not "%1"=="-s" goto unexpected
shift
shift
if "%1 %2 %3"=="shell getprop ro.product.brand" goto prop_brand
if "%1 %2 %3"=="shell getprop ro.product.manufacturer" goto prop_manufacturer
if "%1 %2 %3"=="shell getprop ro.product.model" goto prop_model
if "%1 %2 %3"=="shell getprop ro.product.name" goto prop_product
if "%1 %2 %3"=="shell getprop ro.product.device" goto prop_device
if "%1 %2 %3"=="shell getprop ro.build.version.release" goto prop_android_release
if "%1 %2 %3"=="shell getprop ro.build.version.sdk" goto prop_api
if "%1 %2 %3"=="shell getprop ro.product.cpu.abilist" goto prop_abi
if "%1 %2 %3"=="shell getprop ro.build.fingerprint" goto prop_fingerprint
if "%1 %2"=="shell wm" if "%3"=="size" goto wm_size
if "%1 %2"=="shell wm" if "%3"=="density" goto wm_density
if "%1 %2 %3 %4"=="shell dumpsys activity activities" goto activity
if "%1 %2 %3 %4"=="shell dumpsys window windows" goto window
if "%1 %2 %3"=="shell dumpsys display" goto display
if "%1 %2 %3"=="shell dumpsys power" goto power
if "%1 %2 %3 %4"=="shell dumpsys window policy" goto policy
if "%1 %2 %3 %4 %5"=="shell settings get global zen_mode" goto zen
if "%1 %2 %3 %4 %5"=="shell settings get secure default_input_method" goto default_ime
if "%1 %2 %3"=="shell dumpsys input_method" goto input_method
if "%1 %2 %3"=="shell am get-config" goto am_config
goto unexpected
:devices
if exist "%TABLET_FAKE_STATE%\devices-exit.txt" exit /b 42
if exist "%TABLET_FAKE_STATE%\devices-delay.txt" "%TABLET_FAKE_CHILD_PWSH%" -NoProfile -Command "Set-Content -LiteralPath (Join-Path $env:TABLET_FAKE_STATE 'devices-child-started.txt') -Value started; Start-Sleep -Seconds 2; Set-Content -LiteralPath (Join-Path $env:TABLET_FAKE_STATE 'devices-completed.txt') -Value completed"
type "%TABLET_FAKE_STATE%\devices.txt"
exit /b 0
:prop_brand
type "%TABLET_FAKE_STATE%\prop_brand.txt"
exit /b 0
:prop_manufacturer
type "%TABLET_FAKE_STATE%\prop_manufacturer.txt"
exit /b 0
:prop_model
type "%TABLET_FAKE_STATE%\prop_model.txt"
exit /b 0
:prop_product
type "%TABLET_FAKE_STATE%\prop_product.txt"
exit /b 0
:prop_device
type "%TABLET_FAKE_STATE%\prop_device.txt"
exit /b 0
:prop_android_release
type "%TABLET_FAKE_STATE%\prop_android_release.txt"
exit /b 0
:prop_api
type "%TABLET_FAKE_STATE%\prop_api.txt"
exit /b 0
:prop_abi
type "%TABLET_FAKE_STATE%\prop_abi.txt"
exit /b 0
:prop_fingerprint
type "%TABLET_FAKE_STATE%\prop_fingerprint.txt"
exit /b 0
:wm_size
type "%TABLET_FAKE_STATE%\wm_size.txt"
if exist "%TABLET_FAKE_STATE%\wm_size-next.txt" move /y "%TABLET_FAKE_STATE%\wm_size-next.txt" "%TABLET_FAKE_STATE%\wm_size.txt" >nul
exit /b 0
:wm_density
type "%TABLET_FAKE_STATE%\wm_density.txt"
if exist "%TABLET_FAKE_STATE%\wm_density-next.txt" move /y "%TABLET_FAKE_STATE%\wm_density-next.txt" "%TABLET_FAKE_STATE%\wm_density.txt" >nul
exit /b 0
:activity
type "%TABLET_FAKE_STATE%\activity.txt"
if exist "%TABLET_FAKE_STATE%\activity-next.txt" move /y "%TABLET_FAKE_STATE%\activity-next.txt" "%TABLET_FAKE_STATE%\activity.txt" >nul
exit /b 0
:window
type "%TABLET_FAKE_STATE%\window.txt"
if exist "%TABLET_FAKE_STATE%\window-next.txt" move /y "%TABLET_FAKE_STATE%\window-next.txt" "%TABLET_FAKE_STATE%\window.txt" >nul
exit /b 0
:display
type "%TABLET_FAKE_STATE%\display.txt"
if exist "%TABLET_FAKE_STATE%\display-next.txt" move /y "%TABLET_FAKE_STATE%\display-next.txt" "%TABLET_FAKE_STATE%\display.txt" >nul
exit /b 0
:power
type "%TABLET_FAKE_STATE%\power.txt"
if exist "%TABLET_FAKE_STATE%\power-next.txt" move /y "%TABLET_FAKE_STATE%\power-next.txt" "%TABLET_FAKE_STATE%\power.txt" >nul
exit /b 0
:policy
type "%TABLET_FAKE_STATE%\policy.txt"
if exist "%TABLET_FAKE_STATE%\policy-next.txt" move /y "%TABLET_FAKE_STATE%\policy-next.txt" "%TABLET_FAKE_STATE%\policy.txt" >nul
exit /b 0
:zen
type "%TABLET_FAKE_STATE%\zen.txt"
if exist "%TABLET_FAKE_STATE%\zen-next.txt" move /y "%TABLET_FAKE_STATE%\zen-next.txt" "%TABLET_FAKE_STATE%\zen.txt" >nul
exit /b 0
:default_ime
type "%TABLET_FAKE_STATE%\default_ime.txt"
exit /b 0
:input_method
type "%TABLET_FAKE_STATE%\input_method.txt"
if exist "%TABLET_FAKE_STATE%\input_method-next.txt" move /y "%TABLET_FAKE_STATE%\input_method-next.txt" "%TABLET_FAKE_STATE%\input_method.txt" >nul
exit /b 0
:am_config
if exist "%TABLET_FAKE_STATE%\am_config-exit.txt" exit /b 41
type "%TABLET_FAKE_STATE%\am_config.txt"
if exist "%TABLET_FAKE_STATE%\am_config-next.txt" move /y "%TABLET_FAKE_STATE%\am_config-next.txt" "%TABLET_FAKE_STATE%\am_config.txt" >nul
exit /b 0
:unexpected
>>"%TABLET_FAKE_STATE%\unexpected.log" echo %*
exit /b 97
'@
    $adb = Join-Path $bin 'fake-adb.cmd'
    Set-Content -LiteralPath $adb -Value ($fakeAdb -replace "`r?`n", "`r`n") -Encoding ascii -NoNewline

    if ($Scenario -eq 'zero') {
        Set-FixtureText $state devices 'List of devices attached'
        return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial }
    }
    if ($Scenario -eq 'multiple') {
        Set-FixtureText $state devices "List of devices attached`n$Serial`tdevice`nSECOND-SERIAL`tdevice"
        return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial }
    }
    if ($Scenario -in @('unauthorized','offline','no_permissions')) {
        $deviceState = if ($Scenario -eq 'no_permissions') { 'no permissions' } else { $Scenario }
        Set-FixtureText $state devices "List of devices attached`n$Serial`t$deviceState"
        return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial }
    }
    if ($Scenario -in @('mixed_offline','mixed_unauthorized')) {
        $badState = if ($Scenario -eq 'mixed_offline') { 'offline' } else { 'unauthorized' }
        Set-FixtureText $state devices "List of devices attached`n$Serial`tdevice`nSECOND-SERIAL`t$badState"
        return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial }
    }
    if ($Scenario -in @('devices_fail','devices_delay')) {
        Set-FixtureText $state devices "List of devices attached`n$Serial`tdevice"
        if ($Scenario -eq 'devices_fail') { Set-FixtureText $state devices-exit '42' }
        else { Set-FixtureText $state devices-delay 'true' }
        return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial }
    }

    if ($Scenario -eq 'daemon_banner') {
        Set-FixtureText $state devices ("* daemon not running; starting now at tcp:5037`r`n" +
            "* daemon started successfully`r`nList of devices attached`r`n$Serial`tdevice")
    }
    else { Set-FixtureText $state devices "List of devices attached`n$Serial`tdevice" }
    Set-FixtureText $state prop_brand 'FixtureBrand'
    Set-FixtureText $state prop_manufacturer 'Fixture制造商'
    Set-FixtureText $state prop_model 'Fixture 平板'
    Set-FixtureText $state prop_product 'fixture_product'
    Set-FixtureText $state prop_device 'fixture_device'
    Set-FixtureText $state prop_android_release '16'
    Set-FixtureText $state prop_api '36'
    Set-FixtureText $state prop_abi 'arm64-v8a,armeabi-v7a'
    Set-FixtureText $state prop_fingerprint $Fingerprint
    Set-FixtureText $state wm_density "Physical density: 320"
    Set-FixtureText $state power 'mWakefulness=Awake'
    Set-FixtureText $state policy 'mShowingLockscreen=false'
    Set-FixtureText $state zen '0'
    Set-FixtureText $state default_ime 'dev.magina.gateway/.ime.GatewayIme'
    Set-FixtureText $state input_method "mInputShown=false`nmImeWindowVis=0x0"

    $sw = 800
    $rotation = 0
    $size = '1600x2560'
    if ($Scenario -eq 'phone') { $sw = 411; $size = '1260x2800' }
    if ($Scenario -in @(
        'landscape','four_three','letterbox_landscape','override_size','override_density',
        'rotation_space_drift','multi_window','pip_landscape','state_drift','window_reorder'
    )) { $rotation = 1 }
    if ($Scenario -eq 'four_three') { $size = '1200x1600' }
    if ($Scenario -eq 'vivo_no_rotation') { $sw = 787; $size = '1968x2800'; Set-FixtureText $state wm_density 'Physical density: 400' }
    Set-FixtureText $state am_config "config: zh-rCN-ldltr-sw${sw}dp-w${sw}dp-h1200dp-normal-long"
    if ($Scenario -eq 'unknown') {
        Set-FixtureText $state wm_size 'size unavailable'
        Set-FixtureText $state activity 'activity dump without recognized fields'
        Set-FixtureText $state window 'window dump without recognized blocks'
        Set-FixtureText $state display 'rotation=unknown'
        Set-FixtureText $state power 'wake state missing'
        Set-FixtureText $state policy 'keyguard state missing'
        Set-FixtureText $state zen 'null'
        Set-FixtureText $state input_method 'ime state missing'
        Set-FixtureText $state am_config 'config: zh-rCN-swBADdp-normal'
    }
    else {
        Set-FixtureText $state wm_size "Physical size: $size"
        $sizeParts = $size -split 'x'
        $currentWidth = if ($rotation -in @(1,3)) { $sizeParts[1] } else { $sizeParts[0] }
        $currentHeight = if ($rotation -in @(1,3)) { $sizeParts[0] } else { $sizeParts[1] }
        Set-FixtureText $state activity @"
mGlobalConfiguration={1.0 ?mcc?mnc [zh_CN] ldltr sw${sw}dp w${sw}dp h1200dp}
topResumedActivity=ActivityRecord{abc u0 com.tencent.mm/.ui.LauncherUI t10}
"@
        Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][$currentWidth,$currentHeight]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        Set-FixtureText $state display "Display 0: rotation=$rotation"
        if ($Scenario -eq 'override_size') {
            Set-FixtureText $state wm_size "Physical size: $size`nOverride size: $size"
        }
        elseif ($Scenario -eq 'override_density') {
            Set-FixtureText $state wm_density "Physical density: 320`nOverride density: 320"
        }
        if ($Scenario -in @('split','multi_window')) {
            $modeA = if ($Scenario -eq 'split') { 'split-screen-primary' } else { 'multi-window' }
            $modeB = if ($Scenario -eq 'split') { 'split-screen-secondary' } else { 'multi-window' }
            $splitEdge = [int]$currentWidth / 2
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][$splitEdge,$currentHeight]
    mWindowingMode=$modeA
    isOnScreen=true
  Window #1 Window{def u0 com.example.other/.MainActivity}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[$splitEdge,0][$currentWidth,$currentHeight]
    mWindowingMode=$modeB
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'pip_landscape') {
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{pip u0 com.example.video/.PlayerActivity}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[1800,900][2500,1500]
    mWindowingMode=pinned
    isOnScreen=true
  Window #1 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'letterbox_landscape') {
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[80,40][2480,1560]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'freeform') {
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[100,120][1500,2200]
    mWindowingMode=freeform
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'pinned') {
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[100,120][1500,2200]
    mWindowingMode=pinned
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'floating_ime') {
            Set-FixtureText $state input_method "mInputShown=true`nmImeWindowVis=0x2`nmIsFloating=true`nmVisibleBound=[400,1500][1200,2300]"
        }
        elseif ($Scenario -eq 'rotation_space_drift') {
            Set-FixtureText $state display 'Display 0: rotation 1'
            Set-FixtureText $state display-next 'Display 0: rotation 3'
            Set-FixtureText $state window-next @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][$currentWidth,$currentHeight]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'drift') {
            Set-FixtureText $state activity-next @"
mGlobalConfiguration={1.0 ?mcc?mnc [zh_CN] ldltr sw${sw}dp w${sw}dp h1200dp}
topResumedActivity=ActivityRecord{def u0 com.example.other/.MainActivity t11}
"@
            Set-FixtureText $state window-next @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{def u0 com.example.other/.MainActivity}
  Window #0 Window{def u0 com.example.other/.MainActivity}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][$currentWidth,$currentHeight]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'wm_drift') {
            Set-FixtureText $state wm_size-next 'Physical size: 1600x2600'
            Set-FixtureText $state wm_density-next 'Physical density: 401'
        }
        elseif ($Scenario -eq 'am_drift') {
            Set-FixtureText $state am_config-next 'config: zh-rCN-ldltr-sw600dp-w600dp-h900dp-normal'
            Set-FixtureText $state activity-next @"
mGlobalConfiguration={1.0 ?mcc?mnc [zh_CN] ldltr sw600dp w600dp h900dp}
topResumedActivity=ActivityRecord{abc u0 com.tencent.mm/.ui.LauncherUI t10}
"@
        }
        elseif ($Scenario -eq 'sw_source_drift') {
            Set-FixtureText $state activity-next `
                'topResumedActivity=ActivityRecord{abc u0 com.tencent.mm/.ui.LauncherUI t10}'
        }
        elseif ($Scenario -eq 'sw_conflict') {
            Set-FixtureText $state am_config 'config: zh-rCN-ldltr-sw600dp-w600dp-h900dp-normal'
        }
        elseif ($Scenario -eq 'state_drift') {
            Set-FixtureText $state power-next 'mWakefulness=Asleep'
            Set-FixtureText $state policy-next 'mShowingLockscreen=true'
            Set-FixtureText $state zen-next '1'
            Set-FixtureText $state input_method-next "mInputShown=true`nmImeWindowVis=0x2`nmIsFloating=true`nmVisibleBound=[400,900][1200,1500]"
        }
        elseif ($Scenario -eq 'window_reorder') {
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][$currentWidth,$currentHeight]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
"@
            Set-FixtureText $state window-next @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][$currentWidth,$currentHeight]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
        }
        elseif ($Scenario -eq 'am_empty') {
            Set-FixtureText $state am_config ''
        }
        elseif ($Scenario -eq 'am_absent') {
            Set-FixtureText $state am_config 'abi: arm64-v8a'
        }
        elseif ($Scenario -eq 'am_invalid') {
            Set-FixtureText $state am_config 'config: zh-rCN-swBADdp-normal'
        }
        elseif ($Scenario -eq 'am_fail') {
            Set-FixtureText $state am_config-exit '41'
        }
        elseif ($Scenario -eq 'vivo_no_rotation') {
            Set-FixtureText $state activity @"
topResumedActivity=ActivityRecord{abc u0 com.android.chrome/org.chromium.chrome.browser.customtabs.CustomTabActivity t10}
"@
            Set-FixtureText $state window @"
WINDOW MANAGER WINDOWS
  mCurrentFocus=Window{abc u0 com.android.chrome/org.chromium.chrome.browser.customtabs.CustomTabActivity}
  Window #0 Window{pip u0 com.example.video/.PlayerActivity}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[45,221][1058,791]
    mWindowingMode=pinned
    isOnScreen=true
  Window #1 Window{abc u0 com.android.chrome/org.chromium.chrome.browser.customtabs.CustomTabActivity}:
    mDisplayId=0
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
            Set-FixtureText $state display 'Display 0 without recognized orientation assignment'
        }
    }
    return [pscustomobject]@{ Root=$root; Repo=$repo; State=$state; Adb=$adb; Serial=$Serial; Fingerprint=$Fingerprint }
}

function Invoke-TabletFixture {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$RunId,
        [string]$AdbPath
    )
    if ([string]::IsNullOrWhiteSpace($AdbPath)) { $AdbPath = $Fixture.Adb }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PwshPath
    $start.WorkingDirectory = $Fixture.Repo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-File')
    $start.ArgumentList.Add((Join-Path $Fixture.Repo 'scripts\run-tablet-intake.ps1'))
    $start.ArgumentList.Add('-AdbPath')
    $start.ArgumentList.Add($AdbPath)
    $start.ArgumentList.Add('-RunId')
    $start.ArgumentList.Add($RunId)
    $start.Environment['TABLET_FAKE_STATE'] = $Fixture.State
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        Assert-True $process.Start() '无法启动 tablet intake 子进程。'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            [void]$process.WaitForExit(5000)
            throw 'tablet intake 离线用例超时。'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
            ProfilePath = Join-Path $Fixture.Repo "docs\runs\evidence\$RunId\tablet-profile.json"
        }
    }
    finally { $process.Dispose() }
}

function Read-TabletProfile {
    param([Parameter(Mandatory)]$Result)
    Assert-True (Test-Path -LiteralPath $Result.ProfilePath -PathType Leaf) '缺少 tablet-profile.json。'
    return Get-Content -LiteralPath $Result.ProfilePath -Raw -Encoding utf8 | ConvertFrom-Json
}

try {
    if (-not (Test-Path -LiteralPath $SourceRunner -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SourceLibrary -PathType Leaf)) {
        throw '测试设施错误：缺少真实 tablet intake 入口或库。'
    }
    New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
    . $SourceLibrary

    Test-Case -Name 'tablet portrait 只读画像成功但作为非基线 blocked' `
        -Covers @('portrait_blocked') -Body {
        $fixture = New-TabletFixture portrait
        $result = Invoke-TabletFixture $fixture 'portrait-ok'
        Assert-Equal $result.ExitCode 0 "竖屏平板 intake 应成功；stderr=$($result.Stderr.Trim())"
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.schema_version 5 'schema 版本错误'
        Assert-Equal $profile.display.smallest_width_dp_status 'known' 'resolved sw 状态错误'
        Assert-Equal $profile.display.smallest_width_dp_source 'activity_global_cross_checked' `
            'activity/am config 交叉确认来源错误'
        Assert-Equal $profile.assessment.device_class 'tablet' '设备分类错误'
        Assert-Equal $profile.assessment.readiness_orientation_baseline 'landscape' '横屏基线未入 schema'
        Assert-Equal $profile.assessment.readiness_status 'blocked' '竖屏不得进入 readiness 基线'
        Assert-Equal (@($profile.assessment.readiness_block_reasons).Count) 1 '干净竖屏应只被方向基线阻断'
        Assert-Equal $profile.assessment.readiness_block_reasons[0] 'orientation_portrait' '竖屏阻断原因错误'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' 'T0 不得宣称 P0 已支持'
        Assert-True (@($profile.assessment.p0_unsupported_reasons) -contains 'wechat_layout_unverified') `
            '未验证微信 pane 时必须保持 unsupported'
        Assert-True (@($profile.assessment.p0_unsupported_reasons) -contains 'tablet_landscape_p0_unimplemented') `
            '即使 readiness 被竖屏阻断，仍必须显式声明横屏 P0 未实现'
        Assert-Equal (@($profile.assessment.p0_unsupported_reasons).Count) 3 `
            '竖屏样本应包含 readiness 原因与两个固定 P0 阻断'
        Assert-Equal $profile.observations.initial.windows.application_window_count 1 '应用窗口数错误'
        Assert-Equal $profile.observations.initial.windows.windows[0].windowing_mode 'fullscreen' '窗口模式错误'
    }

    Test-Case 'phone 画像落盘但以退出码 2 拒绝' {
        $fixture = New-TabletFixture phone
        $result = Invoke-TabletFixture $fixture 'phone-rejected'
        Assert-Equal $result.ExitCode 2 '手机必须被默认 tablet 门拒绝'
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.display.physical_size.width 1260 '手机 fixture panel short edge 前置不成立'
        Assert-Equal $profile.display.physical_density_dpi 320 '手机 fixture density 前置不成立'
        Assert-Equal $profile.display.smallest_width_dp 411 'device class 必须使用 am config sw，不是 panel nominal dp'
        Assert-Equal $profile.assessment.device_class 'phone' '手机分类错误'
        Assert-Equal $profile.assessment.intake_status 'rejected' '手机 intake 状态错误'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' '手机不得成为 P0 候选'
    }

    Test-Case -Name 'landscape 满足 T0 readiness 但 P0 仍 unsupported' `
        -Covers @('landscape_positive','schema_v5') -Body {
        $fixture = New-TabletFixture landscape
        $result = Invoke-TabletFixture $fixture 'landscape-readonly'
        Assert-Equal $result.ExitCode 0 "横屏不得阻断只读 intake；stderr=$($result.Stderr.Trim())"
        $profile = Read-TabletProfile $result
        Assert-Equal (($profile.PSObject.Properties.Name) -join ',') `
            'schema_version,run_id,captured_at_utc,device,display,state,observations,input_method,assessment' `
            '画像顶层 schema 字段漂移'
        Assert-Equal (($profile.assessment.PSObject.Properties.Name) -join ',') `
            'tablet_threshold_dp,readiness_orientation_baseline,device_class,intake_status,capture_consistent,capture_consistency_status,capture_consistency_reasons,readiness_status,readiness_block_reasons,p0_capability,p0_unsupported_reasons' `
            'assessment schema 字段漂移'
        $nestedSchemas = @(
            @{ Name='device'; Value=$profile.device; Fields='serial_hash,brand,manufacturer,model,product,device,android_release,api_level,abi,fingerprint_hash' },
            @{ Name='display'; Value=$profile.display; Fields='physical_size,override_size,current_size,physical_density_dpi,override_density_dpi,smallest_width_dp,smallest_width_dp_status,smallest_width_dp_source,rotation,rotation_status,rotation_source,orientation,current_size_source,aspect_4_3' },
            @{ Name='state'; Value=$profile.state; Fields='screen_awake,keyguard_locked,zen_mode,default_ime' },
            @{ Name='observations'; Value=$profile.observations; Fields='initial,final' },
            @{ Name='frame'; Value=$profile.observations.initial; Fields='foreground,rotation,current_size,windows,state' },
            @{ Name='foreground'; Value=$profile.observations.initial.foreground; Fields='status,source,package,activity,top_resumed,resumed_fallback' },
            @{ Name='foreground_source'; Value=$profile.observations.initial.foreground.top_resumed; Fields='assignment_count,valid_count,absent_count,malformed_count,conflict_count' },
            @{ Name='rotation_observation'; Value=$profile.observations.initial.rotation; Fields='status,source,value,assignment_count,valid_count,malformed_count,conflict_count,default_scoped_count,unscoped_count,non_default_count' },
            @{ Name='current_size_observation'; Value=$profile.observations.initial.current_size; Fields='status,source,wm_size_source,value,reason_codes' },
            @{ Name='windows'; Value=$profile.observations.initial.windows; Fields='parse_status,block_count,application_window_count,strong_visible_count,weak_visibility_count,visible_overlay_count,visible_other_application_count,visible_unknown_type_count,visible_ime_count,visible_system_window_count,visible_unsafe_other_count,identity_missing_count,identity_conflict_count,duplicate_identity_count,display_unknown_count,non_default_display_count,visibility_ambiguous_count,malformed_field_count,focus,windows' },
            @{ Name='focus'; Value=$profile.observations.initial.windows.focus; Fields='status,assignment_count,distinct_count,mapped_count,malformed_count,conflict_count,window_label,type,owner_matches_foreground' },
            @{ Name='window'; Value=$profile.observations.initial.windows.windows[0]; Fields='window_label,identity_status,display_status,display_id,type,visibility,bounds,windowing_mode,owner_matches_foreground,focused' },
            @{ Name='frame_state'; Value=$profile.observations.initial.state; Fields='screen_awake,keyguard_locked,zen_mode,input_method' },
            @{ Name='input_method'; Value=$profile.input_method; Fields='session_active,visible,floating,bounds' }
        )
        foreach ($schema in $nestedSchemas) {
            Assert-Equal (($schema.Value.PSObject.Properties.Name) -join ',') $schema.Fields `
                "$($schema.Name) schema 字段漂移"
        }
        Assert-Equal $profile.schema_version 5 '横屏正向 schema 版本错误'
        Assert-Equal $profile.display.orientation 'landscape' '横屏识别错误'
        Assert-Equal $profile.assessment.readiness_status 'accepted' '干净横屏平板 readiness 应接受'
        Assert-Equal (@($profile.assessment.readiness_block_reasons).Count) 0 '横屏正向不应有 readiness blocker'
        Assert-Equal $profile.observations.initial.windows.application_window_count 1 '横屏正向必须恰好一个应用窗口'
        Assert-True ($profile.observations.initial.windows.windows[0].owner_matches_foreground -eq $true) `
            '横屏正向窗口 owner 必须匹配前台微信'
        Assert-Equal $profile.observations.initial.windows.windows[0].windowing_mode 'fullscreen' `
            '横屏正向必须为 fullscreen'
        Assert-Equal (($profile.observations.initial.windows.windows[0].bounds -join ',')) '0,0,2560,1600' `
            '横屏正向窗口必须精确覆盖当前屏幕'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' '横屏 readiness 不得放行 P0'
        Assert-True (@($profile.assessment.p0_unsupported_reasons) -contains 'wechat_layout_unverified') `
            '横屏正向仍必须阻断未验证微信布局'
        Assert-True (@($profile.assessment.p0_unsupported_reasons) -contains 'tablet_landscape_p0_unimplemented') `
            '横屏正向仍必须显式阻断尚未实现的平板横屏 P0'
        Assert-Equal (@($profile.assessment.p0_unsupported_reasons).Count) 2 `
            '无 readiness blocker 时应恰好保留两个固定 P0 阻断'
    }

    Test-Case -Name 'P0 在 readiness 正向与阻断策略矩阵中永远 unsupported' `
        -Covers @('p0_always_unsupported') -Body {
        $windows = ConvertFrom-TabletWindowInventory @'
Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
  mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
  mFrame=[0,0][2560,1600]
  mWindowingMode=fullscreen
  isOnScreen=true
'@
        $ime = ConvertFrom-TabletImeState "mInputShown=false`nmImeWindowVis=0x0"
        $matrix = @(
            @{ Name='accepted_landscape'; Sw=800; Orientation='landscape'; Four=$false; Awake=$true; Locked=$false; Zen=0; Top='com.tencent.mm'; Consistent=$true },
            @{ Name='portrait_blocked'; Sw=800; Orientation='portrait'; Four=$false; Awake=$true; Locked=$false; Zen=0; Top='com.tencent.mm'; Consistent=$true },
            @{ Name='unknown_blocked'; Sw=$null; Orientation='unknown'; Four=$null; Awake=$null; Locked=$null; Zen=$null; Top=$null; Consistent=$null }
        )
        foreach ($case in $matrix) {
            $assessment = Get-TabletP0Assessment -SmallestWidthDp $case.Sw -Orientation $case.Orientation `
                -IsFourThree $case.Four -Awake $case.Awake -KeyguardLocked $case.Locked -ZenMode $case.Zen `
                -TopPackage $case.Top -WindowInventory $windows -ImeState $ime `
                -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $case.Consistent
            Assert-Equal $assessment.P0Status 'unsupported' "$($case.Name) 不得放行 P0"
            foreach ($reason in @('wechat_layout_unverified','tablet_landscape_p0_unimplemented')) {
                Assert-True (@($assessment.P0Reasons) -contains $reason) "$($case.Name) 缺少固定 P0 阻断 $reason"
            }
        }
    }

    Test-Case -Name 'wm size 或 density override 任一存在都阻断默认缩放基线' `
        -Covers @('wm_size_override_blocked','wm_density_override_blocked') -Body {
        $cases = @(
            @{ Scenario='override_size'; Reason='wm_size_override_present' },
            @{ Scenario='override_density'; Reason='wm_density_override_present' }
        )
        foreach ($case in $cases) {
            $fixture = New-TabletFixture $case.Scenario
            $result = Invoke-TabletFixture $fixture "default-scale-$($case.Scenario)"
            Assert-Equal $result.ExitCode 0 "$($case.Scenario) 只读 intake 应成功"
            $profile = Read-TabletProfile $result
            Assert-Equal $profile.display.orientation 'landscape' "$($case.Scenario) 应保持横屏正向几何"
            Assert-True ($profile.assessment.capture_consistent -eq $true) `
                "$($case.Scenario) 样本必须证明不是靠采集漂移阻断"
            Assert-Equal $profile.assessment.readiness_status 'blocked' "$($case.Scenario) 必须阻断 readiness"
            Assert-True (@($profile.assessment.readiness_block_reasons) -contains $case.Reason) `
                "$($case.Scenario) 缺少默认缩放阻断 $($case.Reason)"
            Assert-True (@($profile.assessment.readiness_block_reasons) -notcontains 'capture_changed_during_collection') `
                "$($case.Scenario) 不得用采集漂移代替 override 机械门"
            Assert-Equal $profile.assessment.p0_capability 'unsupported' "$($case.Scenario) 不得放行 P0"
        }
    }

    Test-Case '4比3只读 intake 成功但 P0 unsupported' {
        $fixture = New-TabletFixture four_three
        $result = Invoke-TabletFixture $fixture 'four-three-readonly'
        Assert-Equal $result.ExitCode 0 '4:3 不得阻断只读 intake'
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.display.orientation 'landscape' '4:3 必须在横屏基线下验证'
        Assert-True ($profile.display.aspect_4_3 -eq $true) '4:3 比例未识别'
        Assert-Equal $profile.assessment.readiness_status 'blocked' '4:3 不得获得 readiness'
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'aspect_4_3') '4:3 缺少比例阻断'
        Assert-True (@($profile.assessment.readiness_block_reasons) -notcontains 'orientation_landscape') `
            '4:3 不得靠横屏方向假阻断'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' '4:3 不得进入 P0 候选'
    }

    Test-Case -Name '分屏多窗自由窗浮动IME全部 fail closed' `
        -Covers @('multi_window_blocked','pip_blocked') -Body {
        $cases = @(
            @{ Scenario='split'; Reason='application_window_count_not_one' },
            @{ Scenario='multi_window'; Reason='application_window_count_not_one' },
            @{ Scenario='pip_landscape'; Reason='application_window_count_not_one' },
            @{ Scenario='freeform'; Reason='windowing_mode_freeform' },
            @{ Scenario='pinned'; Reason='windowing_mode_pinned' },
            @{ Scenario='floating_ime'; Reason='floating_ime' }
        )
        foreach ($case in $cases) {
            $fixture = New-TabletFixture $case.Scenario
            $result = Invoke-TabletFixture $fixture ("unsupported-" + $case.Scenario)
            Assert-Equal $result.ExitCode 0 "$($case.Scenario) 仍应完成只读 intake"
            $profile = Read-TabletProfile $result
            Assert-Equal $profile.assessment.p0_capability 'unsupported' "$($case.Scenario) 不得进入 P0 候选"
            Assert-True (@($profile.assessment.p0_unsupported_reasons) -contains $case.Reason) `
                "$($case.Scenario) 缺少原因 $($case.Reason)"
            if ($case.Scenario -in @('multi_window','pip_landscape')) {
                Assert-Equal $profile.display.orientation 'landscape' "$($case.Scenario) 应在横屏基线下验证"
                Assert-True (@($profile.assessment.readiness_block_reasons) -notcontains 'orientation_landscape') `
                    "$($case.Scenario) 不得靠方向门假阻断"
            }
            if ($case.Scenario -eq 'pip_landscape') {
                Assert-Equal $profile.assessment.readiness_status 'blocked' 'PiP 必须阻断 readiness'
                Assert-Equal $profile.observations.initial.windows.application_window_count 2 'PiP 应保留 pinned 与微信两个 OS 应用窗口'
            }
        }
    }

    Test-Case -Name '横屏 fullscreen 字样但未精确覆盖当前屏幕必须 fail closed' `
        -Covers @('letterbox_blocked') -Body {
        $fixture = New-TabletFixture letterbox_landscape
        $result = Invoke-TabletFixture $fixture 'letterbox-landscape'
        Assert-Equal $result.ExitCode 0 'letterbox 不得阻断只读 intake'
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.display.orientation 'landscape' 'letterbox 样本必须在横屏基线下验证'
        Assert-Equal $profile.observations.initial.windows.application_window_count 1 'letterbox 样本应只有一个应用窗口'
        Assert-Equal $profile.observations.initial.windows.windows[0].windowing_mode 'fullscreen' `
            'letterbox 样本用 fullscreen 字样测试 bounds 门'
        Assert-True ($profile.observations.initial.windows.windows[0].owner_matches_foreground -eq $true) `
            'letterbox 样本 owner 应匹配微信'
        Assert-Equal $profile.assessment.readiness_status 'blocked' 'letterbox 不得获得 readiness'
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'application_window_bounds_invalid') `
            'letterbox 缺少精确 bounds 阻断'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' 'letterbox 不得放行 P0'
    }

    Test-Case 'vivo Android 16 Chrome 加 pinned 旧形态保持 current-size unknown' {
        $fixture = New-TabletFixture vivo_no_rotation
        $result = Invoke-TabletFixture $fixture 'vivo-no-rotation'
        Assert-Equal $result.ExitCode 0 'wm 画像可分类时 intake 应成功'
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.display.smallest_width_dp 787 'am get-config sw 解析错误'
        Assert-Equal $profile.display.smallest_width_dp_status 'known' 'am config sw 状态错误'
        Assert-Equal $profile.display.smallest_width_dp_source 'am_config' 'am config sw 来源未标注'
        Assert-Equal $profile.assessment.device_class 'tablet' 'vivo 平板分类错误'
        Assert-Equal $profile.display.rotation $null '不得伪造 rotation'
        Assert-True ($null -eq $profile.display.current_size) '非微信且多个 BASE 不得回填 current-size'
        Assert-Equal $profile.display.orientation 'unknown' '非严格窗口回退不得猜横屏'
        Assert-Equal $profile.display.current_size_source 'unknown' '失败回退来源必须 unknown'
        Assert-True ($null -eq $profile.assessment.capture_consistent) 'current-size 不可靠时 consistency 应 unknown'
        Assert-Equal $profile.assessment.readiness_status 'blocked' 'pinned/非微信仍必须 blocked'
        foreach ($reason in @('orientation_unknown','top_package_not_wechat','application_window_count_not_one','capture_consistency_unknown')) {
            Assert-True (@($profile.assessment.readiness_block_reasons) -contains $reason) "缺少阻断原因 $reason"
        }
        Assert-True (@($profile.observations.initial.current_size.reason_codes) -contains 'foreground_not_known_wechat') `
            '严格 fallback 应记录非微信前台阻断'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' 'vivo 回退不得放行 P0'
    }

    Test-Case -Name 'am config 缺失歧义或与 activity 冲突时 device class unknown' `
        -Covers @('parse_ambiguous') -Body {
        foreach ($scenario in @('am_empty','am_absent','am_invalid','sw_conflict')) {
            $fixture = New-TabletFixture $scenario
            $result = Invoke-TabletFixture $fixture ("sw-unknown-$scenario")
            Assert-Equal $result.ExitCode 3 "$scenario 不得产生 tablet/phone 决策"
            $profile = Read-TabletProfile $result
            Assert-Equal $profile.display.smallest_width_dp $null "$scenario 不得回填 sw"
            Assert-Equal $profile.display.smallest_width_dp_status 'unknown' "$scenario resolved status 错误"
            Assert-Equal $profile.display.smallest_width_dp_source 'unknown' "$scenario resolved source 错误"
            Assert-Equal $profile.assessment.device_class 'unknown' "$scenario device class 必须 unknown"
            Assert-Equal $profile.assessment.readiness_status 'blocked' "$scenario readiness 必须 blocked"
            Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'device_class_unknown') `
                "$scenario 缺少 device_class_unknown"
            Assert-Equal $profile.assessment.p0_capability 'unsupported' "$scenario 不得放行 P0"
        }
    }

    Test-Case -Name 'am get-config 查询失败时不落成功画像' `
        -Covers @('query_failure') -Body {
        $fixture = New-TabletFixture am_fail
        $result = Invoke-TabletFixture $fixture 'am-query-failed'
        Assert-Equal $result.ExitCode 1 'am get-config 非零必须中止 intake'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) '查询失败不得落画像'
    }

    Test-Case 'am config 值或 resolved source 初末漂移必须 blocked' {
        foreach ($case in @(
            @{Scenario='am_drift'; Expected=$false; Reason='capture_changed_during_collection'},
            @{Scenario='sw_source_drift'; Expected=$false; Reason='capture_changed_during_collection'}
        )) {
            $fixture = New-TabletFixture $case.Scenario
            $result = Invoke-TabletFixture $fixture ("sw-drift-" + $case.Scenario)
            Assert-Equal $result.ExitCode 0 "$($case.Scenario) 仍应落只读画像"
            $profile = Read-TabletProfile $result
            if ($null -eq $case.Expected) {
                Assert-True ($null -eq $profile.assessment.capture_consistent) '来源漂移应为 unknown'
            }
            else { Assert-True ($profile.assessment.capture_consistent -eq $case.Expected) '值漂移应为 false' }
            Assert-True (@($profile.assessment.readiness_block_reasons) -contains $case.Reason) `
                "$($case.Scenario) 缺少阻断原因 $($case.Reason)"
            Assert-Equal $profile.assessment.p0_capability 'unsupported' '漂移不得放行 P0'
        }
    }

    Test-Case 'wm/window 回退必须拒绝边长错配或多个 fullscreen 候选' {
        $physical = [ordered]@{width=1968;height=2800}
        $mismatch = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2799,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $mismatchSize = Get-TabletCurrentSize -PhysicalSize $physical -OverrideSize $null `
            -Rotation $null -WindowInventory $mismatch -TopPackage 'com.tencent.mm'
        Assert-True ($null -eq $mismatchSize) '边长不严格匹配 wm size 时不得猜方向'

        $duplicate = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{def u0 com.tencent.mm/.ui.LauncherUI}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $duplicateSize = Get-TabletCurrentSize -PhysicalSize $physical -OverrideSize $null `
            -Rotation $null -WindowInventory $duplicate -TopPackage 'com.tencent.mm'
        Assert-True ($null -eq $duplicateSize) '多个 fullscreen 候选时不得猜方向'
        foreach ($typeLine in @('type=TYPE_APPLICATION_OVERLAY','type=TYPE_APPLICATION')) {
            $nonBase = ConvertFrom-TabletWindowInventory @"
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    $typeLine
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
"@
            Assert-Equal $nonBase.Count 0 "$typeLine 不得算 BASE_APPLICATION"
            $nonBaseSize = Get-TabletCurrentSize -PhysicalSize $physical -OverrideSize $null `
                -Rotation $null -WindowInventory $nonBase -TopPackage 'com.tencent.mm'
            Assert-True ($null -eq $nonBaseSize) "$typeLine 不得推导方向"
        }
    }

    Test-Case '应用窗口 owner 或 bounds 错配不能获得 readiness' {
        $ownerMismatch = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.example.other/.MainActivity}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $ime = ConvertFrom-TabletImeState "mInputShown=false`nmImeWindowVis=0x0"
        $ownerAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $ownerMismatch -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600})
        Assert-True (@($ownerAssessment.ReadinessReasons) -contains 'application_window_owner_mismatch') `
            '唯一窗口 owner 不属于 top 微信时必须 blocked'

        $badBounds = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[100,100][50,50]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $boundsAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $badBounds -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600})
        Assert-True (@($boundsAssessment.ReadinessReasons) -contains 'application_window_bounds_invalid') `
            '退化窗口 bounds 必须 blocked'
    }

    Test-Case 'IME session 与窗口可见性分开解析' {
        $ime = ConvertFrom-TabletImeState "mInputShown=false`nmImeWindowVis=0x2`nmIsFloating=true"
        Assert-True ($ime.SessionShown -eq $false) 'mInputShown 只表示 session'
        Assert-True ($ime.Visible -eq $true) 'mImeWindowVis 0x2 才表示可见窗口'
        Assert-True ($ime.Floating -eq $true) '可见浮动 IME 必须识别'
    }

    Test-Case -Name 'sw 歧义与 foreground 来源优先级严格解析' `
        -Covers @('foreground_source_priority','foreground_malformed_blocked') -Body {
        $sw = ConvertFrom-TabletSmallestWidthDp @'
mGlobalConfiguration={ sw800dp w800dp h1200dp }
TaskRecord{ configuration={ sw411dp w411dp h800dp } }
'@
        Assert-Equal $sw 800 '只能从唯一全局 configuration 提取 sw'
        $ambiguousSw = ConvertFrom-TabletSmallestWidthDp @'
mGlobalConfiguration={ sw800dp w800dp h1200dp }
mGlobalConfiguration={ sw600dp w600dp h900dp }
'@
        Assert-True ($null -eq $ambiguousSw) '多个全局 configuration 不得猜 sw'
        $top = ConvertFrom-TabletTopActivity -ActivityText @'
topResumedActivity=ActivityRecord{a u0 com.tencent.mm/.ui.LauncherUI t1}
mResumedActivity=ActivityRecord{b u0 com.example.other/.MainActivity t2}
'@ -WindowText $null
        Assert-Equal $top.Status 'known' '权威 topResumed 不应被低优先级 resumed 冲突降级'
        Assert-Equal $top.Source 'top_resumed_activity' 'topResumed 来源优先级错误'
        Assert-Equal $top.Package 'com.tencent.mm' '低优先级 resumed 覆盖了 topResumed'
        $fallback = Get-TabletForegroundObservation @'
mResumedActivity=ActivityRecord{x u0 com.tencent.mm/.ui.LauncherUI t1}
'@
        Assert-Equal $fallback.Status 'known' 'topResumed absent 时唯一 resumed 应可 fallback'
        Assert-Equal $fallback.Source 'm_resumed_activity_fallback' 'resumed fallback 来源错误'
        $focusOnly = ConvertFrom-TabletTopActivity -ActivityText '' `
            -WindowText 'mCurrentFocus=Window{focus-secret u0 com.tencent.mm/.ui.LauncherUI}'
        Assert-Equal $focusOnly.Status 'absent' 'mCurrentFocus 不得建立 foreground'
        foreach ($malformedTop in @(
            "topResumedActivity=malformed`nmResumedActivity=ActivityRecord{x u0 com.tencent.mm/.ui.LauncherUI t1}",
            "topResumedActivity=ActivityRecord{a u0 com.tencent.mm/.ui.LauncherUI t1}`ntopResumedActivity=ActivityRecord{a u0 com.tencent.mm/.ui.LauncherUI t1}",
            "topResumedActivity=ActivityRecord{a u0 com.tencent.mm/.ui.LauncherUI t1}`ntopResumedActivity=ActivityRecord{b u0 com.example.other/.MainActivity t2}"
        )) {
            $ambiguousTop = Get-TabletForegroundObservation $malformedTop
            Assert-Equal $ambiguousTop.Status 'ambiguous' 'topResumed malformed/duplicate/conflict 不得降级 fallback'
            Assert-True ($null -eq $ambiguousTop.Package) 'ambiguous foreground 不得选择候选'
        }
    }

    Test-Case -Name 'sw 只从 am current config 决策且 rotation 必须有 default scope' `
        -Covers @('rotation_scope_diagnostics') -Body {
        $absentSw = Get-TabletSmallestWidthDpObservation 'topResumedActivity=x'
        Assert-Equal $absentSw.Status 'absent' '缺席 sw 状态错误'
        foreach ($text in @(
            "mGlobalConfiguration={ sw800dp }`nmGlobalConfiguration={ sw800dp }",
            "mGlobalConfiguration={ sw800dp }`nmGlobalConfiguration={ sw600dp }",
            'mGlobalConfiguration={ sw800dp swBADdp }',
            'mGlobalConfiguration={ swBADdp }',
            'mGlobalConfiguration={ sw0dp }'
        )) {
            $observation = Get-TabletSmallestWidthDpObservation $text
            Assert-Equal $observation.Status 'ambiguous' '重复/冲突/非法 sw 不得当成 absent'
            Assert-True ($null -eq $observation.Value) '重复/冲突/非法 sw 不得产生值'
        }

        $amCurrent = Get-TabletAmConfigSmallestWidthDpObservation @'
config: zh-rCN-ldltr-sw787dp-w787dp-h1200dp-normal
recentConfigs:
 config: zh-rCN-ldltr-sw600dp-w600dp-h900dp-normal
'@
        Assert-Equal $amCurrent.Status 'known' '当前 am config 应可解析'
        Assert-Equal $amCurrent.Value 787 '带缩进的历史 config 不得覆盖当前值'
        foreach ($text in @(
            "config: zh-sw800dp-normal`nconfig: zh-sw800dp-normal",
            'config: zh-sw800dp-swBADdp-normal',
            'config: zh-sw800dp-sw600dp-normal',
            'config: zh-sw0dp-normal',
            'config: zh-sw999999999999999999999dp-normal',
            'config: zh-sw800dpx-normal'
        )) {
            $observation = Get-TabletAmConfigSmallestWidthDpObservation $text
            Assert-Equal $observation.Status 'ambiguous' '重复/冲突/非法 am config sw 必须 ambiguous'
            Assert-True ($null -eq $observation.Value) '重复/冲突/非法 am config sw 不得产生值'
        }
        $amKnown = [pscustomobject]@{Status='known';Value=787}
        $activityAbsent = [pscustomobject]@{Status='absent';Value=$null}
        $resolvedAmOnly = Resolve-TabletSmallestWidthDpObservation $amKnown $activityAbsent
        Assert-Equal $resolvedAmOnly.Source 'am_config' 'activity absent 时应只用 am config'
        $activityKnown = [pscustomobject]@{Status='known';Value=787}
        $resolvedCrossCheck = Resolve-TabletSmallestWidthDpObservation $amKnown $activityKnown
        Assert-Equal $resolvedCrossCheck.Source 'activity_global_cross_checked' '两条全局配置应交叉确认'
        foreach ($activity in @(
            [pscustomobject]@{Status='known';Value=800},
            [pscustomobject]@{Status='ambiguous';Value=$null}
        )) {
            $resolved = Resolve-TabletSmallestWidthDpObservation $amKnown $activity
            Assert-Equal $resolved.Status 'unknown' 'activity 冲突/歧义时 resolved sw 必须 unknown'
        }
        foreach ($am in @(
            [pscustomobject]@{Status='absent';Value=$null},
            [pscustomobject]@{Status='ambiguous';Value=$null}
        )) {
            $resolved = Resolve-TabletSmallestWidthDpObservation $am $activityKnown
            Assert-Equal $resolved.Status 'unknown' 'am config 缺失/歧义时不得只信 activity'
        }

        $physical = [ordered]@{width=1968;height=2800}

        Assert-Equal (Get-TabletRotationObservation 'Display 0 without assignment' '').Status 'absent' `
            '无 rotation 赋值应为 absent'
        foreach ($rotationText in @('Display 0: rotation 1','Display 0: rotation 1,','Display 0: rotation 1}','Display 0: rotation 1]')) {
            $spaceRotation = Get-TabletRotationObservation $rotationText ''
            Assert-Equal $spaceRotation.Status 'known' "$rotationText 空格格式应窄解析"
            Assert-Equal $spaceRotation.Value 1 "$rotationText 值解析错误"
        }
        Assert-Equal (Get-TabletRotationObservation 'DisplayDeviceInfo{rotation 1}' '').Status 'ambiguous' `
            '无法证明 default display 的 rotation 不得 known'
        $secondaryOnly = Get-TabletRotationObservation 'Display 1: rotation=1' ''
        Assert-Equal $secondaryOnly.Status 'ambiguous' 'secondary display 不得决定当前 rotation'
        Assert-Equal $secondaryOnly.NonDefaultCount 1 'secondary display 诊断计数错误'
        $multipleDefault = Get-TabletRotationObservation "Display 0: rotation=1`nDisplay 0: rotation=3" ''
        Assert-Equal $multipleDefault.Status 'ambiguous' '多个 default rotation 不得投票选值'
        Assert-True ($multipleDefault.ConflictCount -gt 0) 'default rotation 冲突未进入摘要'
        $malformedDefault = Get-TabletRotationObservation 'Display 0: rotation=1->3' ''
        Assert-Equal $malformedDefault.Status 'ambiguous' 'default malformed rotation 不得截断'
        Assert-Equal $malformedDefault.MalformedCount 1 'malformed rotation 计数错误'
        $multilineDefault = Get-TabletRotationObservation "Display 0:`n  rotation=1" ''
        Assert-Equal $multilineDefault.Status 'known' '明确 Display 0 block 内分行 rotation 应可窄解析'
        $sameValueRepeated = Get-TabletRotationObservation "Display 0: rotation=1`nDisplay 0: rotation=1" ''
        Assert-Equal $sameValueRepeated.Status 'known' '同 scope 同值重复 rotation 不应误报 conflict'
        $crossCheckedRotation = Get-TabletRotationObservation 'Display 0: rotation=1' `
            'mDisplayId=0 mRotation=ROTATION_1'
        Assert-Equal $crossCheckedRotation.Status 'known' 'display/window 同值 default rotation 应 cross-check'
        Assert-Equal $crossCheckedRotation.Source 'display_window_cross_checked' 'rotation 双源来源摘要错误'
        Assert-Equal (Get-TabletRotationObservation "Display 0: rotation=1`nDisplay 1: rotation=1" '').Status `
            'ambiguous' '出现 secondary display 时 T0-L 必须 fail closed'
        Assert-Equal (Get-TabletRotationObservation 'DisplayDeviceInfo{rotation 1x}' '').Status 'ambiguous' `
            '`rotation 1x` 不得被宽松截断为 1'
        Assert-Equal (Get-TabletRotationObservation 'DisplayDeviceInfo{rotation 1->3}' '').Status 'ambiguous' `
            '`rotation 1->3` 不得被宽松截断为 1'
        Assert-Equal (Get-TabletRotationObservation 'DisplayDeviceInfo{mRotation 1}' '').Status 'ambiguous' `
            '未承诺的 `mRotation 1` 空格格式不得放行'
        Assert-Equal (Get-TabletRotationObservation 'rotation=0' 'mRotation=ROTATION_1').Status 'ambiguous' `
            '冲突 rotation 不得当成 absent'
        Assert-Equal (Get-TabletRotationObservation 'rotation=0' 'mRotation=unknown').Status 'ambiguous' `
            '合法+非法 rotation 不得忽略非法证据'
        Assert-Equal (Get-TabletRotationObservation 'rotation=unknown' '').Status 'ambiguous' `
            '非法 rotation 不得当成 absent'

        $window = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mAttrs={(0,0)(fillxfill) ty=BASE_APPLICATION}
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $blockedFallback = Get-TabletCurrentSizeObservation -PhysicalSize $physical -OverrideSize $null `
            -RotationStatus ambiguous -Rotation $null -WindowInventory $window -TopPackage 'com.tencent.mm'
        Assert-Equal $blockedFallback.Source 'unknown' '冲突 rotation 不得启用 window 回退'
        $ownerMismatch = Get-TabletCurrentSizeObservation -PhysicalSize $physical -OverrideSize $null `
            -RotationStatus absent -Rotation $null -WindowInventory $window -TopPackage 'com.example.other'
        Assert-Equal $ownerMismatch.Source 'unknown' '非前台 owner 窗口不得推导方向'

        $top = [pscustomobject]@{Package='com.tencent.mm';Activity='.ui.LauncherUI'}
        $current = [ordered]@{width=2800;height=1968}
        $mixedRotation = Test-TabletCaptureConsistency -InitialRotation 1 -FinalRotation $null `
            -InitialRotationStatus known -FinalRotationStatus absent -InitialTop $top -FinalTop $top `
            -InitialWindows $window -FinalWindows $window -InitialCurrentSize $current -FinalCurrentSize $current `
            -InitialSmallestWidthDp 787 -FinalSmallestWidthDp 787 -InitialDensity 400 -FinalDensity 400
        Assert-True ($null -eq $mixedRotation) '单端 rotation known 不得与 window 回退混用'
        $mixedSw = Test-TabletCaptureConsistency -InitialRotation $null -FinalRotation $null `
            -InitialRotationStatus absent -FinalRotationStatus absent -InitialTop $top -FinalTop $top `
            -InitialWindows $window -FinalWindows $window -InitialCurrentSize $current -FinalCurrentSize $current `
            -InitialSmallestWidthDp 787 -FinalSmallestWidthDp 787 `
            -InitialSmallestWidthStatus known -FinalSmallestWidthStatus absent `
            -InitialDensity 400 -FinalDensity 400
        Assert-True ($null -eq $mixedSw) '初末 resolved sw 状态不同必须 unknown'

        $sameValueDifferentSource = Test-TabletCaptureConsistency -InitialRotation 0 -FinalRotation 0 `
            -InitialRotationStatus known -FinalRotationStatus known -InitialTop $top -FinalTop $top `
            -InitialWindows $window -FinalWindows $window -InitialCurrentSize $current -FinalCurrentSize $current `
            -InitialSmallestWidthDp 787 -FinalSmallestWidthDp 787 -InitialDensity 400 -FinalDensity 400 `
            -InitialSizeSource physical -FinalSizeSource override
        Assert-True ($null -eq $sameValueDifferentSource) 'physical/override size 来源切换不得因数值相同而通过'
        $sameDensityDifferentSource = Test-TabletCaptureConsistency -InitialRotation 0 -FinalRotation 0 `
            -InitialRotationStatus known -FinalRotationStatus known -InitialTop $top -FinalTop $top `
            -InitialWindows $window -FinalWindows $window -InitialCurrentSize $current -FinalCurrentSize $current `
            -InitialSmallestWidthDp 787 -FinalSmallestWidthDp 787 -InitialDensity 400 -FinalDensity 400 `
            -InitialDensitySource physical -FinalDensitySource override
        Assert-True ($null -eq $sameDensityDifferentSource) 'physical/override density 来源切换不得因数值相同而通过'

        foreach ($wmSizeText in @(
            "Physical size: 1968x2800`nOverride size: 1200x1600`nOverride size: 1300x1600",
            "Physical size: 1968x2800`nOverride size: 1200x1600`nOverride size: invalid"
        )) {
            $wmSize = ConvertFrom-TabletWmSize $wmSizeText
            Assert-Equal $wmSize.OverrideStatus 'ambiguous' '冲突/合法+非法 override size 状态错误'
            Assert-Equal (Get-TabletEffectiveWmSizeObservation $wmSize).Status 'ambiguous' `
                '冲突 override size 不得静默退回 physical'
        }
        foreach ($wmDensityText in @(
            "Physical density: 400`nOverride density: 320`nOverride density: 360",
            "Physical density: 400`nOverride density: 320`nOverride density: invalid"
        )) {
            $wmDensity = ConvertFrom-TabletWmDensity $wmDensityText
            Assert-Equal $wmDensity.OverrideStatus 'ambiguous' '冲突/合法+非法 override density 状态错误'
            Assert-Equal (Get-TabletEffectiveWmDensityObservation $wmDensity).Status 'ambiguous' `
                '冲突 override density 不得静默退回 physical'
        }
    }

    Test-Case -Name 'window identity 强可见性与 focus 关系全部 fail closed' `
        -Covers @('window_identity_diagnostics','window_visibility_diagnostics','focus_relationships') -Body {
        $differentIdentity = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{def u0 com.example.other/.MainActivity}
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{def u0 com.example.other/.MainActivity}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $differentIdentity.Count 2 '相同 bounds 的不同 identity 必须保留为两个 BASE'
        Assert-Equal $differentIdentity.DuplicateIdentityCount 0 '不同 identity 不得误报 duplicate'

        $duplicateIdentity = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{same u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{same u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{same u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $duplicateIdentity.DuplicateIdentityCount 1 '同 identity 重复块未进入诊断'
        Assert-Equal $duplicateIdentity.FocusStatus 'unbound' '重复 identity 时 focus 不得伪绑定唯一窗口'

        $missingIdentity = ConvertFrom-TabletWindowInventory @'
  Window #0 BrokenWindowHeader:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $missingIdentity.IdentityMissingCount 1 '缺失 header identity 未进入诊断'
        $conflictingIdentity = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{abc u0 com.tencent.mm/.ui.LauncherUI} Window{def u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $conflictingIdentity.IdentityConflictCount 1 '单 block 多 header identity 未进入 conflict'

        $weakVisibility = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{weak u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    mViewVisibility=0x0
'@
        Assert-Equal $weakVisibility.Count 0 '仅 mViewVisibility 不得成为强可见 BASE'
        Assert-Equal $weakVisibility.WeakVisibilityCount 1 'weak visibility 未进入诊断'
        $ambiguousVisibility = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{ambiguous u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
    isVisible=false
'@
        Assert-Equal $ambiguousVisibility.Count 0 'true+false visibility 不得成为强可见 BASE'
        Assert-Equal $ambiguousVisibility.VisibilityAmbiguousCount 1 'true+false 未进入 ambiguous 诊断'

        $blockingWindows = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{overlay u0 com.example.overlay/.Overlay}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isVisible=true
  Window #2 Window{mystery u0 com.example.mystery/.Mystery}:
    mDisplayId=0
    type=VENDOR_UNKNOWN
    mFrame=[0,0][2560,1600]
    isOnScreen=true
  Window #3 Window{dialog u0 com.tencent.mm/.Dialog}:
    mDisplayId=0
    type=TYPE_APPLICATION
    mFrame=[100,100][1200,800]
    isVisible=true
'@
        Assert-Equal $blockingWindows.Count 1 'overlay/unknown 不得混入 BASE count'
        Assert-Equal $blockingWindows.VisibleOverlayCount 1 '可见 2038 overlay 未进入诊断'
        Assert-Equal $blockingWindows.VisibleUnknownTypeCount 1 '可见未知类型未进入诊断'
        Assert-Equal $blockingWindows.VisibleOtherApplicationCount 1 '可见 application dialog 未进入诊断'
        $ime = ConvertFrom-TabletImeState "mInputShown=false`nmImeWindowVis=0x0"
        $blockingAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $blockingWindows -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $true
        foreach ($reason in @('visible_application_overlay','visible_other_application_window','visible_window_type_unknown','focus_not_base_application')) {
            Assert-True (@($blockingAssessment.ReadinessReasons) -contains $reason) "缺少窗口/focus 阻断 $reason"
        }
        $otherBaseAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $differentIdentity -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $true
        Assert-True (@($otherBaseAssessment.ReadinessReasons) -contains 'focus_owner_mismatch') `
            'focus 到 other BASE 必须明确阻断'

        $imeFocus = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{ime u0 com.example.ime/.ImeWindow}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{ime u0 com.example.ime/.ImeWindow}:
    mDisplayId=0
    type=TYPE_INPUT_METHOD
    mFrame=[0,1000][2560,1600]
    isVisible=true
'@
        Assert-Equal $imeFocus.FocusStatus 'bound' 'IME focus 应绑定到其 window identity'
        Assert-Equal $imeFocus.FocusWindow.WindowType 'input_method' 'IME focus 类型解析错误'
        $imeFocusAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $imeFocus -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $true
        Assert-True (@($imeFocusAssessment.ReadinessReasons) -contains 'focus_not_base_application') `
            'focus 到 IME 必须阻断 readiness'

        $withWallpaper = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{wallpaper u0 com.android.systemui/.Wallpaper}:
    mDisplayId=0
    type=TYPE_WALLPAPER
    mFrame=[0,0][2560,1600]
    isOnScreen=true
'@
        Assert-Equal $withWallpaper.VisibleUnknownTypeCount 0 '明确 wallpaper 不得误报 unknown occluder'
        Assert-Equal $withWallpaper.MalformedFieldCount 0 '明确 wallpaper 不得误报 malformed'
        Assert-Equal (ConvertFrom-TabletWindowTypeToken '2013') 'safe_background' 'numeric 2013 wallpaper 分类错误'
        $wallpaperAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $withWallpaper -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $true
        Assert-Equal $wallpaperAssessment.ReadinessStatus 'accepted' `
            '唯一 BASE + 明确 background wallpaper 不应误阻断 readiness'

        $unbound = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{missing-focus u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $unbound.FocusStatus 'unbound' 'focus 不在窗口集合时必须 unbound'
        $unboundAssessment = Get-TabletP0Assessment -SmallestWidthDp 800 -Orientation landscape `
            -IsFourThree $false -Awake $true -KeyguardLocked $false -ZenMode 0 `
            -TopPackage 'com.tencent.mm' -WindowInventory $unbound -ImeState $ime `
            -CurrentSize ([ordered]@{width=2560;height=1600}) -CaptureConsistent $true
        Assert-True (@($unboundAssessment.ReadinessReasons) -contains 'focus_unbound') `
            'unbound focus 未阻断 readiness'
        $conflictingFocus = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  mCurrentFocus=Window{other u0 com.example.other/.MainActivity}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{other u0 com.example.other/.MainActivity}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $conflictingFocus.FocusStatus 'ambiguous' '多个 focus assignment 必须 ambiguous'
        Assert-Equal $conflictingFocus.FocusAssignmentCount 2 'focus assignment 计数错误'
        Assert-Equal $conflictingFocus.FocusDistinctCount 2 'focus distinct 计数错误'
        Assert-Equal $conflictingFocus.FocusMappedCount 0 'ambiguous focus 不得映射窗口'
        Assert-True ($conflictingFocus.FocusConflictCount -gt 0) 'focus conflict 未进入脱敏摘要'
    }

    Test-Case -Name '畸形超大数字与未知应用窗口类型只诊断并阻断' `
        -Covers @('numeric_overflow_fail_closed','unsafe_window_types') -Body {
        $oversized = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{huge u0 com.tencent.mm/.ui.LauncherUI}
  Window #999999999999999999999999 Window{huge u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=999999999999999999999999
    type=999999999999999999999999
    mFrame=[0,0][999999999999999999999999,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        Assert-Equal $oversized.ParseStatus 'known' '超大数字不得让 parser throw/中止 intake'
        Assert-True ($oversized.MalformedFieldCount -ge 4) '超大 index/type/frame/display 未全部进入 malformed 摘要'
        Assert-Equal $oversized.VisibleUnknownTypeCount 1 '超大 type 必须视为 visible unknown'
        Assert-Equal $oversized.DisplayUnknownCount 1 '超大 displayId 必须视为 unknown'
        foreach ($numericType in @('1000','2032')) {
            $unsafe = ConvertFrom-TabletWindowInventory @"
  Window #0 Window{unsafe u0 com.example.unsafe/.Unsafe}:
    mDisplayId=0
    type=$numericType
    mFrame=[0,0][2560,1600]
    isOnScreen=true
"@
            Assert-Equal $unsafe.VisibleUnknownTypeCount 1 "type=$numericType 不得落入 safe system window"
        }
        $sameValueDuplicates = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{same-values u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{same-values u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    displayId=0
    type=TYPE_BASE_APPLICATION
    ty=1
    mFrame=[0,0][2560,1600]
    frame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    windowingMode=1
    isOnScreen=true
    isVisible=true
'@
        Assert-Equal $sameValueDuplicates.MalformedFieldCount 0 '同值重复字段不应误报 malformed'
        Assert-Equal $sameValueDuplicates.Count 1 '同值重复字段应保留唯一 BASE 语义'
        Assert-Equal $sameValueDuplicates.FocusStatus 'bound' '同值重复字段不应破坏 focus binding'
        $conflictingValues = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{conflict-values u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    displayId=1
    type=TYPE_BASE_APPLICATION
    ty=2038
    mFrame=[0,0][2560,1600]
    frame=[1,0][2560,1600]
    mWindowingMode=fullscreen
    windowingMode=pinned
    isOnScreen=true
'@
        Assert-True ($conflictingValues.MalformedFieldCount -ge 4) '冲突 type/frame/display/mode 必须 malformed'
        Assert-Equal $conflictingValues.VisibleUnknownTypeCount 1 '冲突 type 必须变成 visible unknown'
        $validPlusInvalid = ConvertFrom-TabletWindowInventory @'
  Window #0 Window{mixed-values u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    displayId=BAD
    type=TYPE_BASE_APPLICATION
    ty=VENDOR_UNKNOWN
    mFrame=[0,0][2560,1600]
    frame=BAD
    mWindowingMode=fullscreen
    windowingMode=???
    isOnScreen=true
    isVisible=unknown
'@
        Assert-True ($validPlusInvalid.MalformedFieldCount -ge 5) '合法+非法混合字段不得忽略非法证据'
        Assert-Equal $validPlusInvalid.VisibilityAmbiguousCount 1 '合法 true + 非法 visibility 必须 ambiguous'
        Assert-Equal $validPlusInvalid.VisibleUnknownTypeCount 0 `
            'visibility ambiguous 时不应伪计 strong visible unknown；应由 malformed/ambiguous 阻断'
        $oversizedIme = ConvertFrom-TabletImeState @'
mInputShown=true
mImeWindowVis=0xffffffffffffffffffffffffffff
mVisibleBound=[0,0][999999999999999999999999,1600]
'@
        Assert-True ($null -eq $oversizedIme.Visible) '超大 IME vis 应 unknown 而非 throw'
        Assert-True ($null -eq $oversizedIme.Bounds) '超大 IME bounds 应 unknown 而非 throw'
        $oversizedImeDecimal = ConvertFrom-TabletImeState 'mImeWindowVis=999999999999999999999999'
        Assert-True ($null -eq $oversizedImeDecimal.Visible) '超大十进制 IME vis 应 unknown'
        $mixedIme = ConvertFrom-TabletImeState @'
mInputShown=true
mInputShown=false
mImeWindowVis=0x0
mImeWindowVis=BAD
mIsFloating=false
mIsFloating=unknown
mVisibleBound=[0,0][100,100]
mVisibleBound=BAD
'@
        Assert-True ($null -eq $mixedIme.SessionShown) 'IME session true+false 必须 unknown'
        Assert-True ($null -eq $mixedIme.Visible) 'IME vis valid+invalid 必须 unknown'
        Assert-True ($null -eq $mixedIme.Floating) 'IME floating valid+invalid 必须 unknown'
        Assert-True ($null -eq $mixedIme.Bounds) 'IME bounds valid+invalid 必须 unknown'
        $sameIme = ConvertFrom-TabletImeState @'
mInputShown=false
mInputShown=false
mImeWindowVis=0x0
mImeWindowVis=0
mVisibleBound=[0,0][100,100]
mVisibleBound=[0,0][100,100]
'@
        Assert-True ($sameIme.SessionShown -eq $false) 'IME session 同值重复不应误报 unknown'
        Assert-True ($sameIme.Visible -eq $false) 'IME vis canonical 同值重复不应误报 unknown'
        Assert-Equal (($sameIme.Bounds -join ',')) '0,0,100,100' 'IME bounds 同值重复 canonical 失败'
    }

    Test-Case -Name 'rotation absent 仅允许唯一微信 fullscreen identity 严格回退' `
        -Covers @('strict_window_fallback') -Body {
        $physical = [ordered]@{width=1968;height=2800}
        $foreground = Get-TabletForegroundObservation `
            'topResumedActivity=ActivityRecord{a u0 com.tencent.mm/.ui.LauncherUI t1}'
        $windowText = @'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $windows = ConvertFrom-TabletWindowInventory $windowText
        $strict = Get-TabletCurrentSizeObservation -PhysicalSize $physical -OverrideSize $null `
            -RotationStatus absent -Rotation $null -WindowInventory $windows `
            -TopPackage $foreground.Package -ForegroundObservation $foreground
        Assert-Equal $strict.Status 'known' '全部严格条件满足时 window fallback 应 known'
        Assert-Equal $strict.Source 'fullscreen_window' '严格 fallback 来源错误'
        Assert-Equal "$($strict.Value.width)x$($strict.Value.height)" '2800x1968' '严格 fallback 几何错误'

        $overlayWindows = ConvertFrom-TabletWindowInventory ($windowText + "`n" + @'
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=2038
    mFrame=[0,0][2800,1968]
    isOnScreen=true
'@)
        $focusMismatch = ConvertFrom-TabletWindowInventory ($windowText -replace 'mCurrentFocus=Window\{base', 'mCurrentFocus=Window{unbound')
        $duplicateWindows = ConvertFrom-TabletWindowInventory ($windowText + "`n" + @'
  Window #1 Window{second u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2800,1968]
    mWindowingMode=fullscreen
    isOnScreen=true
'@)
        foreach ($case in @(
            @{ Name='overlay'; Windows=$overlayWindows; RotationStatus='absent'; Foreground=$foreground },
            @{ Name='focus_mismatch'; Windows=$focusMismatch; RotationStatus='absent'; Foreground=$foreground },
            @{ Name='multiple_base'; Windows=$duplicateWindows; RotationStatus='absent'; Foreground=$foreground },
            @{ Name='rotation_ambiguous'; Windows=$windows; RotationStatus='ambiguous'; Foreground=$foreground },
            @{ Name='not_wechat'; Windows=$windows; RotationStatus='absent'; Foreground=(Get-TabletForegroundObservation 'topResumedActivity=ActivityRecord{x u0 com.example.other/.Main t1}') }
        )) {
            $blocked = Get-TabletCurrentSizeObservation -PhysicalSize $physical -OverrideSize $null `
                -RotationStatus $case.RotationStatus -Rotation $null -WindowInventory $case.Windows `
                -TopPackage $case.Foreground.Package -ForegroundObservation $case.Foreground
            Assert-Equal $blocked.Status 'unknown' "$($case.Name) 不得启用 window fallback"
            Assert-Equal $blocked.Source 'unknown' "$($case.Name) 不得伪造 current-size 来源"
        }
    }

    Test-Case -Name 'capture 以 identity canonical 比较且顺序不构成漂移' `
        -Covers @('capture_identity_consistency') -Body {
        $windowA = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
'@
        $windowReordered = ConvertFrom-TabletWindowInventory @'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $rotation = [pscustomobject]@{Status='known';Source='display_default';Value=1}
        $foreground = [pscustomobject]@{Status='known';Source='top_resumed_activity';Package='com.tencent.mm';Activity='.ui.LauncherUI'}
        $current = [pscustomobject]@{Status='known';Source='rotation';WmSizeSource='physical';Value=[ordered]@{width=2560;height=1600}}
        $sw = [pscustomobject]@{Status='known';Source='activity_global_cross_checked';Value=800}
        $density = [pscustomobject]@{Status='known';Source='physical';Value=320}
        $stable = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $windowReordered `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density
        Assert-Equal $stable.Status 'consistent' '相同 identity 集合重排不应视为漂移'
        Assert-True ($stable.Value -eq $true) '重排 consistency 值错误'

        $identityReplacement = ConvertFrom-TabletWindowInventory ((@'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
'@) -replace 'Window\{overlay', 'Window{replacement')
        $changedIdentity = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $identityReplacement `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density
        Assert-Equal $changedIdentity.Status 'changed' 'identity A→B 必须识别为 changed'
        Assert-True (@($changedIdentity.ReasonCodes) -contains 'window_identity_changed') '缺少 identity changed reason'

        $semanticChange = ConvertFrom-TabletWindowInventory ((@'
  mCurrentFocus=Window{base u0 com.tencent.mm/.ui.LauncherUI}
  Window #0 Window{base u0 com.tencent.mm/.ui.LauncherUI}:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=freeform
    isOnScreen=true
  Window #1 Window{overlay u0 com.example.overlay/.Overlay}:
    mDisplayId=0
    type=TYPE_APPLICATION_OVERLAY
    mFrame=[10,10][200,200]
    isVisible=true
'@))
        $changedSemantic = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $semanticChange `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density
        Assert-Equal $changedSemantic.Status 'changed' '同 identity 语义变化必须 changed'
        Assert-True (@($changedSemantic.ReasonCodes) -contains 'window_semantics_changed') '缺少 semantics changed reason'

        $sourceChanged = [pscustomobject]@{Status='known';Source='fullscreen_window';WmSizeSource='physical';Value=[ordered]@{width=2560;height=1600}}
        $changedSource = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $windowA `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $sourceChanged `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density
        Assert-Equal $changedSource.Status 'changed' 'current-size derivation source 漂移必须 changed'
        Assert-True (@($changedSource.ReasonCodes) -contains 'current_size_source_changed') '来源漂移 reason 错误'

        $hiddenStateA = [pscustomobject]@{
            Awake=$true; KeyguardLocked=$false; ZenMode=0
            ImeState=[pscustomobject]@{SessionShown=$false;Visible=$false;Floating=$false;Bounds=@(1,2,3,4)}
        }
        $hiddenStateB = [pscustomobject]@{
            Awake=$true; KeyguardLocked=$false; ZenMode=0
            ImeState=[pscustomobject]@{SessionShown=$false;Visible=$false;Floating=$false;Bounds=@(9,8,7,6)}
        }
        $hiddenBoundsStable = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $windowA `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density `
            -InitialStateObservation $hiddenStateA -FinalStateObservation $hiddenStateB
        Assert-Equal $hiddenBoundsStable.Status 'consistent' '隐藏 IME 的 stale bounds 漂移不应改变画面语义'
        $visibleStateA = [pscustomobject]@{
            Awake=$true; KeyguardLocked=$false; ZenMode=0
            ImeState=[pscustomobject]@{SessionShown=$true;Visible=$true;Floating=$false;Bounds=@(1,2,3,4)}
        }
        $visibleStateB = [pscustomobject]@{
            Awake=$true; KeyguardLocked=$false; ZenMode=0
            ImeState=[pscustomobject]@{SessionShown=$true;Visible=$true;Floating=$false;Bounds=@(9,8,7,6)}
        }
        $visibleBoundsChanged = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $windowA -FinalWindows $windowA `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density `
            -InitialStateObservation $visibleStateA -FinalStateObservation $visibleStateB
        Assert-Equal $visibleBoundsChanged.Status 'changed' '可见 IME bounds 漂移必须 changed'
        Assert-True (@($visibleBoundsChanged.ReasonCodes) -contains 'ime_state_changed') '可见 IME 漂移 reason 错误'

        $missingIdentity = ConvertFrom-TabletWindowInventory @'
  Window #0 BrokenHeader:
    mDisplayId=0
    type=TYPE_BASE_APPLICATION
    mFrame=[0,0][2560,1600]
    mWindowingMode=fullscreen
    isOnScreen=true
'@
        $unknownIdentity = Get-TabletCaptureConsistencyObservation -InitialRotationObservation $rotation `
            -FinalRotationObservation $rotation -InitialForegroundObservation $foreground `
            -FinalForegroundObservation $foreground -InitialWindows $missingIdentity -FinalWindows $missingIdentity `
            -InitialCurrentSizeObservation $current -FinalCurrentSizeObservation $current `
            -InitialSmallestWidthObservation $sw -FinalSmallestWidthObservation $sw `
            -InitialDensityObservation $density -FinalDensityObservation $density
        Assert-Equal $unknownIdentity.Status 'unknown' 'identity 缺失时 consistency 必须 unknown'
        Assert-True (@($unknownIdentity.ReasonCodes) -contains 'window_identity_unreliable') '缺少 identity unreliable reason'
    }

    Test-Case -Name 'schema v5 window labels 在同一 run 初末稳定且不误关联替换 identity' `
        -Covers @('run_wide_window_labels') -Body {
        $reorderFixture = New-TabletFixture window_reorder
        $reorderResult = Invoke-TabletFixture $reorderFixture 'window-label-reorder'
        Assert-Equal $reorderResult.ExitCode 0 "窗口重排画像失败；stderr=$($reorderResult.Stderr.Trim())"
        $reorderProfile = Read-TabletProfile $reorderResult
        $initialBase = @($reorderProfile.observations.initial.windows.windows | Where-Object type -eq 'base_application')[0]
        $finalBase = @($reorderProfile.observations.final.windows.windows | Where-Object type -eq 'base_application')[0]
        $initialOverlay = @($reorderProfile.observations.initial.windows.windows | Where-Object type -eq 'application_overlay')[0]
        $finalOverlay = @($reorderProfile.observations.final.windows.windows | Where-Object type -eq 'application_overlay')[0]
        Assert-Equal $initialBase.window_label $finalBase.window_label '重排后同一 BASE identity 标签漂移'
        Assert-Equal $initialOverlay.window_label $finalOverlay.window_label '重排后同一 overlay identity 标签漂移'
        Assert-True ($initialBase.window_label -cne $initialOverlay.window_label) '不同 identity 不得共享标签'
        Assert-True ($reorderProfile.assessment.capture_consistent -eq $true) '仅 block 重排不应改变 capture consistency'

        $replacementFixture = New-TabletFixture drift
        $replacementResult = Invoke-TabletFixture $replacementFixture 'window-label-replacement'
        Assert-Equal $replacementResult.ExitCode 0 'identity replacement 应仍落只读画像'
        $replacementProfile = Read-TabletProfile $replacementResult
        $initialLabel = @($replacementProfile.observations.initial.windows.windows | Where-Object type -eq 'base_application')[0].window_label
        $finalLabel = @($replacementProfile.observations.final.windows.windows | Where-Object type -eq 'base_application')[0].window_label
        Assert-True ($initialLabel -cne $finalLabel) 'identity A→B 必须分配不同 run-wide 标签'
        Assert-True (@($replacementProfile.assessment.capture_consistency_reasons) -contains 'window_identity_changed') `
            'identity replacement 缺少 changed reason'
    }

    Test-Case '采集期间前台漂移保留只读画像但 readiness fail closed' {
        $fixture = New-TabletFixture drift
        $result = Invoke-TabletFixture $fixture 'capture-drift'
        Assert-Equal $result.ExitCode 0 '前台漂移不得阻断只读 intake'
        $profile = Read-TabletProfile $result
        Assert-True ($profile.assessment.capture_consistent -eq $false) '未记录采集漂移'
        Assert-Equal $profile.assessment.readiness_status 'blocked' '采集漂移必须阻断 readiness'
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'capture_changed_during_collection') `
            '缺少采集漂移原因'
    }

    Test-Case -Name '`rotation 1` 空格格式初末 1 到 3 漂移必须 fail closed' `
        -Covers @('rotation_space_drift') -Body {
        $fixture = New-TabletFixture rotation_space_drift
        $result = Invoke-TabletFixture $fixture 'rotation-space-drift'
        Assert-Equal $result.ExitCode 0 'rotation 漂移不得阻断只读 intake 落盘'
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.display.rotation 1 '初始 `rotation 1` 未窄解析'
        Assert-Equal $profile.display.orientation 'landscape' '初始 rotation 1 应得出横屏'
        Assert-True ($profile.assessment.capture_consistent -eq $false) 'rotation 1→3 漂移未识别'
        Assert-Equal $profile.assessment.readiness_status 'blocked' 'rotation 1→3 必须阻断 readiness'
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'capture_changed_during_collection') `
            'rotation 1→3 缺少采集漂移阻断'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' 'rotation 1→3 不得放行 P0'
    }

    Test-Case '采集末端 wm size/density 漂移必须 fail closed' {
        $fixture = New-TabletFixture wm_drift
        $result = Invoke-TabletFixture $fixture 'wm-capture-drift'
        Assert-Equal $result.ExitCode 0 'wm 漂移不得阻断只读 intake 落盘'
        $profile = Read-TabletProfile $result
        Assert-True ($profile.assessment.capture_consistent -eq $false) '未识别 wm size/density 漂移'
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'capture_changed_during_collection') `
            '缺少 wm 漂移阻断原因'
    }

    Test-Case -Name 'awake keyguard zen 与 IME 初末双读漂移必须 fail closed' `
        -Covers @('state_capture_consistency') -Body {
        $fixture = New-TabletFixture state_drift
        $result = Invoke-TabletFixture $fixture 'state-capture-drift'
        Assert-Equal $result.ExitCode 0 "状态漂移仍应落只读画像；stderr=$($result.Stderr.Trim())"
        $profile = Read-TabletProfile $result
        Assert-True ($profile.observations.initial.state.screen_awake -eq $true) '初始 awake 状态错误'
        Assert-True ($profile.observations.final.state.screen_awake -eq $false) '末端 awake 漂移未记录'
        Assert-True ($profile.observations.final.state.keyguard_locked -eq $true) '末端 keyguard 漂移未记录'
        Assert-Equal $profile.observations.final.state.zen_mode 1 '末端 zen 漂移未记录'
        Assert-True ($profile.observations.final.state.input_method.floating -eq $true) '末端 floating IME 漂移未记录'
        Assert-Equal $profile.assessment.capture_consistency_status 'changed' '状态漂移必须 changed'
        Assert-True ($profile.assessment.capture_consistent -eq $false) '状态漂移 consistency 值错误'
        foreach ($reason in @('screen_awake_changed','keyguard_changed','zen_changed','ime_state_changed')) {
            Assert-True (@($profile.assessment.capture_consistency_reasons) -contains $reason) `
                "状态漂移缺少固定 reason $reason"
        }
        Assert-True (@($profile.assessment.readiness_block_reasons) -contains 'capture_changed_during_collection') `
            '状态漂移必须阻断 readiness'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' '状态漂移不得放行 P0'
    }

    Test-Case -Name 'ADB 绝对路径不存在必须在 devices 前 fail closed' `
        -Covers @('adb_path_missing') -Body {
        $fixture = New-TabletFixture portrait
        $missingAdb = Join-Path $fixture.Root 'missing-adb.exe'
        $result = Invoke-TabletFixture $fixture 'missing-adb-path' -AdbPath $missingAdb
        Assert-Equal $result.ExitCode 1 '不存在的 ADB 路径必须失败'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) 'ADB 路径不存在不得落画像'
        Assert-True ($result.Stderr -match '文件不存在') '错误必须明确指向 ADB 路径不存在'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'adb.log'))) `
            'ADB 路径预检失败后不得启动任何查询'
    }

    Test-Case -Name '相对 ADB 路径与指向目录都在 devices 前 fail closed' `
        -Covers @('relative_adb_path','adb_path_directory') -Body {
        $cases = @(
            @{ Name='relative'; Path='.\fake-adb.cmd'; Error='绝对路径' },
            @{ Name='directory'; Path=$null; Error='文件不存在' }
        )
        foreach ($case in $cases) {
            $fixture = New-TabletFixture portrait
            $adbPath = if ($case.Name -eq 'directory') { Split-Path $fixture.Adb -Parent } else { $case.Path }
            $result = Invoke-TabletFixture $fixture "invalid-adb-$($case.Name)" -AdbPath $adbPath
            Assert-Equal $result.ExitCode 1 "$($case.Name) ADB 路径必须失败"
            Assert-True ($result.Stderr -match $case.Error) "$($case.Name) ADB 路径错误不明确"
            Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) `
                "$($case.Name) ADB 路径失败不得落画像"
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'adb.log'))) `
                "$($case.Name) ADB 路径预检失败后不得启动查询"
        }
    }

    Test-Case -Name '`adb devices` 非零退出必须 fail closed' `
        -Covers @('devices_query_failure') -Body {
        $fixture = New-TabletFixture devices_fail
        $result = Invoke-TabletFixture $fixture 'devices-query-failed'
        Assert-Equal $result.ExitCode 1 'devices 查询非零退出必须失败'
        Assert-True ($result.Stderr -match 'devices.*exit=42') '错误必须标注 devices 与退出码'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) 'devices 查询失败不得落画像'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 'devices 查询失败后不得有后续查询'
        Assert-Equal $log[0] 'devices' 'devices 查询失败时只允许该调用'
    }

    Test-Case -Name 'Invoke-TabletAdbQuery 超时必须终止 fake-adb 且无画像' `
        -Covers @('adb_query_timeout') -Body {
        $fixture = New-TabletFixture devices_delay
        $priorState = $env:TABLET_FAKE_STATE
        $priorChildPwsh = $env:TABLET_FAKE_CHILD_PWSH
        $timedOut = $false
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $env:TABLET_FAKE_STATE = $fixture.State
            $env:TABLET_FAKE_CHILD_PWSH = $PwshPath
            try { [void](Invoke-TabletAdbQuery -AdbPath $fixture.Adb -Name devices -Serial $null -TimeoutSec 1) }
            catch { $timedOut = [string]$_.Exception.Message -match '超时：devices' }
        }
        finally {
            $watch.Stop()
            $env:TABLET_FAKE_STATE = $priorState
            $env:TABLET_FAKE_CHILD_PWSH = $priorChildPwsh
        }
        Assert-True $timedOut 'delayed fake-adb 未在 TimeoutSec=1 后超时失败'
        Assert-True ($watch.Elapsed.TotalSeconds -lt 5) '超时路径未及时终止查询进程树'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.State 'devices-child-started.txt')) `
            '超时前延迟子进程未实际启动，用例无法证明进程树 kill'
        $sentinel = Join-Path $fixture.State 'devices-completed.txt'
        $sentinelDeadline = [DateTime]::UtcNow.AddSeconds(3)
        while (-not (Test-Path -LiteralPath $sentinel) -and [DateTime]::UtcNow -lt $sentinelDeadline) {
            Start-Sleep -Milliseconds 100
        }
        Assert-True (-not (Test-Path -LiteralPath $sentinel)) `
            '超时 kill 后 fake-adb 仍运行到完成哨兵'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 '超时后不得有后续查询'
        Assert-Equal $log[0] 'devices' '超时用例只允许 devices'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence'))) `
            '超时单测不得产生任何画像目录'
    }

    Test-Case -Name 'zero devices fail closed 且仅允许 devices' -Covers @('zero_devices') -Body {
        $fixture = New-TabletFixture zero
        $result = Invoke-TabletFixture $fixture 'zero-devices'
        Assert-Equal $result.ExitCode 1 '0 设备必须失败'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) '0 设备不得落画像'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 '0 设备失败后不得继续查询'
        Assert-Equal $log[0] 'devices' '0 设备时只允许 devices'
    }

    Test-Case -Name 'multiple devices fail closed 且不落画像' `
        -Covers @('multiple_devices') -Body {
        $fixture = New-TabletFixture multiple
        $result = Invoke-TabletFixture $fixture 'multiple-failed'
        Assert-Equal $result.ExitCode 1 '多设备必须失败'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) '多设备失败不得落画像'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 '多设备失败后不得继续查询'
        Assert-Equal $log[0] 'devices' '多设备只允许执行 devices'
    }

    Test-Case -Name 'device 与 offline 或 unauthorized 混合时不得挑唯一 device' `
        -Covers @('mixed_device_offline','mixed_device_unauthorized') -Body {
        foreach ($scenario in @('mixed_offline','mixed_unauthorized')) {
            $fixture = New-TabletFixture $scenario
            $result = Invoke-TabletFixture $fixture "failed-$scenario"
            Assert-Equal $result.ExitCode 1 "$scenario 必须按两条设备记录失败"
            Assert-True ($result.Stderr -match '当前识别到 2 台') "$scenario 不得挑选唯一 device 行"
            Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) "$scenario 不得落画像"
            $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
            Assert-Equal $log.Count 1 "$scenario 失败后不得继续查询"
            Assert-Equal $log[0] 'devices' "$scenario 只允许 devices"
        }
    }

    Test-Case -Name 'unauthorized fail closed 且不落画像' `
        -Covers @('unauthorized_device') -Body {
        $fixture = New-TabletFixture unauthorized
        $result = Invoke-TabletFixture $fixture 'unauthorized-failed'
        Assert-Equal $result.ExitCode 1 '未授权设备必须失败'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) '未授权失败不得落画像'
        Assert-True ($result.Stderr -match 'unauthorized') '错误应明确未授权状态'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 '未授权失败后不得继续查询'
        Assert-Equal $log[0] 'devices' '未授权时只允许 devices'
    }

    Test-Case -Name 'offline device fail closed 且仅允许 devices' `
        -Covers @('offline_device') -Body {
        $fixture = New-TabletFixture offline
        $result = Invoke-TabletFixture $fixture 'offline-device'
        Assert-Equal $result.ExitCode 1 'offline 设备必须失败'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) 'offline 设备不得落画像'
        Assert-True ($result.Stderr -match 'state=offline') '错误必须明确 offline 状态'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 'offline 失败后不得继续查询'
        Assert-Equal $log[0] 'devices' 'offline 时只允许 devices'
    }

    Test-Case -Name 'no permissions device fail closed 且仅允许 devices' `
        -Covers @('no_permissions_device') -Body {
        $fixture = New-TabletFixture no_permissions
        $result = Invoke-TabletFixture $fixture 'no-permissions-device'
        Assert-Equal $result.ExitCode 1 'no permissions 设备必须失败'
        Assert-True ($result.Stderr -match 'state=no permissions') '错误必须明确 no permissions 状态'
        Assert-True (-not (Test-Path -LiteralPath $result.ProfilePath)) 'no permissions 不得落画像'
        $log = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        Assert-Equal $log.Count 1 'no permissions 失败后不得继续查询'
        Assert-Equal $log[0] 'devices' 'no permissions 时只允许 devices'
    }

    Test-Case -Name '含空格的绝对 ADB 路径与 CRLF daemon banner 可安全解析' `
        -Covers @('adb_path_with_spaces','devices_daemon_banner_crlf') -Body {
        $fixture = New-TabletFixture daemon_banner
        $spacedDirectory = Join-Path $fixture.Root 'platform tools with spaces'
        New-Item -ItemType Directory -Path $spacedDirectory | Out-Null
        $spacedAdb = Join-Path $spacedDirectory 'fake adb.cmd'
        Copy-Item -LiteralPath $fixture.Adb -Destination $spacedAdb
        $result = Invoke-TabletFixture $fixture 'spaces-and-banner' -AdbPath $spacedAdb
        Assert-Equal $result.ExitCode 0 "空格路径/daemon banner 正向应成功；stderr=$($result.Stderr.Trim())"
        $profile = Read-TabletProfile $result
        Assert-Equal $profile.assessment.device_class 'tablet' 'daemon banner 不得干扰唯一平板识别'
        Assert-True ([string]$profile.device.serial_hash -match '^sha256:[0-9a-f]{64}$') '空格路径下 serial 仍必须哈希'
    }

    Test-Case -Name 'parse unknown 原样落 null 且 fail closed' `
        -Covers @('parse_unknown') -Body {
        $fixture = New-TabletFixture unknown
        $result = Invoke-TabletFixture $fixture 'parse-unknown'
        Assert-Equal $result.ExitCode 3 '设备分类未知应返回 inconclusive'
        $profile = Read-TabletProfile $result
        Assert-True ($null -eq $profile.display.smallest_width_dp) '未知 sw 不得猜值'
        Assert-Equal $profile.display.orientation 'unknown' '未知方向不得猜值'
        Assert-Equal $profile.observations.initial.windows.parse_status 'unknown' '未知窗口不得猜值'
        Assert-Equal $profile.assessment.p0_capability 'unsupported' '解析未知必须 fail closed'
    }

    Test-Case -Name 'serial fingerprint 与 window identity 均不泄漏' `
        -Covers @('window_identity_privacy') -Body {
        $fixture = New-TabletFixture portrait -Serial 'SERIAL-DO-NOT-PERSIST-9988' `
            -Fingerprint 'SECRET-FINGERPRINT-DO-NOT-PERSIST'
        $windowIdentityCanary = 'RAW-WINDOW-IDENTITY-DO-NOT-PERSIST'
        $windowIdentityHash = Get-TabletSha256Text $windowIdentityCanary
        $unselectedForegroundCanary = 'com.secret.unselected'
        $windowFixture = Get-Content -LiteralPath (Join-Path $fixture.State 'window.txt') -Raw
        Set-FixtureText $fixture.State window ($windowFixture -replace '\babc\b', $windowIdentityCanary)
        $activityFixture = Get-Content -LiteralPath (Join-Path $fixture.State 'activity.txt') -Raw
        Set-FixtureText $fixture.State activity ($activityFixture +
            "`nmResumedActivity=ActivityRecord{x u0 $unselectedForegroundCanary/.SecretActivity t2}")
        $result = Invoke-TabletFixture $fixture 'privacy-check'
        Assert-Equal $result.ExitCode 0 '隐私正向 fixture 应成功'
        $json = Get-Content -LiteralPath $result.ProfilePath -Raw -Encoding utf8
        $observable = $json + $result.Stdout + $result.Stderr
        Assert-True ($observable -notmatch [regex]::Escape($fixture.Serial)) 'serial 明文泄漏'
        Assert-True ($observable -notmatch [regex]::Escape($fixture.Fingerprint)) 'fingerprint 明文泄漏'
        Assert-True ($observable -notmatch [regex]::Escape($windowIdentityCanary)) 'window identity 明文泄漏'
        Assert-True ($observable -notmatch [regex]::Escape($windowIdentityHash)) 'window identity 稳定 hash 泄漏'
        Assert-True ($observable -notmatch [regex]::Escape($unselectedForegroundCanary)) '未选 foreground 候选泄漏'
        $profile = $json | ConvertFrom-Json
        Assert-True ([string]$profile.device.serial_hash -match '^sha256:[0-9a-f]{64}$') 'serial hash 格式错误'
        Assert-True ([string]$profile.device.fingerprint_hash -match '^sha256:[0-9a-f]{64}$') 'fingerprint hash 格式错误'
        $persistedFiles = @(Get-ChildItem -LiteralPath (Split-Path $result.ProfilePath -Parent) -File)
        Assert-Equal $persistedFiles.Count 1 'run 目录只能持久化固定画像文件'
        Assert-Equal $persistedFiles[0].Name 'tablet-profile.json' '持久化了非画像文件'
    }

    Test-Case '既有 run_id 不得被覆盖' {
        $fixture = New-TabletFixture portrait
        $first = Invoke-TabletFixture $fixture 'collision-check'
        Assert-Equal $first.ExitCode 0 '首次画像应成功'
        $before = Get-Content -LiteralPath $first.ProfilePath -Raw -Encoding utf8
        $second = Invoke-TabletFixture $fixture 'collision-check'
        Assert-Equal $second.ExitCode 1 '重复 run_id 必须失败'
        $after = Get-Content -LiteralPath $first.ProfilePath -Raw -Encoding utf8
        Assert-Equal $after $before '重复 run_id 覆盖了既有证据'
    }

    Test-Case 'fake adb 未知命令以 97 默认拒绝' {
        $fixture = New-TabletFixture portrait
        $priorState = $env:TABLET_FAKE_STATE
        try {
            $env:TABLET_FAKE_STATE = $fixture.State
            & $fixture.Adb -s $fixture.Serial shell input tap 1 1 2>$null | Out-Null
            $exitCode = $LASTEXITCODE
        }
        finally { $env:TABLET_FAKE_STATE = $priorState }
        Assert-Equal $exitCode 97 'fake adb 未知命令没有默认拒绝'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.State 'unexpected.log')) '未知命令未进入拒绝审计'
    }

    Test-Case -Name 'ADB 命令集合精确只读且未知命令默认拒绝' `
        -Covers @('exact_read_only_argv') -Body {
        $fixture = New-TabletFixture portrait
        $result = Invoke-TabletFixture $fixture 'command-audit'
        Assert-Equal $result.ExitCode 0 '命令审计 fixture 应成功'
        $actual = @(Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log'))
        $expectedTail = @(
            'shell getprop ro.product.brand','shell getprop ro.product.manufacturer',
            'shell getprop ro.product.model','shell getprop ro.product.name','shell getprop ro.product.device',
            'shell getprop ro.build.version.release','shell getprop ro.build.version.sdk',
            'shell getprop ro.product.cpu.abilist','shell getprop ro.build.fingerprint',
            'shell wm size','shell wm density','shell dumpsys activity activities',
            'shell dumpsys window windows','shell dumpsys display','shell dumpsys power',
            'shell dumpsys window policy','shell settings get global zen_mode',
            'shell settings get secure default_input_method','shell dumpsys input_method','shell am get-config',
            'shell dumpsys activity activities','shell dumpsys window windows','shell dumpsys display',
            'shell wm size','shell wm density','shell am get-config','shell dumpsys power',
            'shell dumpsys window policy','shell settings get global zen_mode','shell dumpsys input_method'
        )
        $expected = @('devices') + @($expectedTail | ForEach-Object { "-s $($fixture.Serial) $_" })
        Assert-Equal $actual.Count $expected.Count 'ADB 调用数漂移'
        for ($i=0; $i -lt $expected.Count; $i++) {
            Assert-Equal $actual[$i] $expected[$i] "第 $i 条 ADB argv 漂移"
        }
        $joined = $actual -join "`n"
        Assert-True ($joined -notmatch '(?i)\b(input|install|uninstall|force-stop|monkey|push|pull|forward|reverse|run-as|screencap|uiautomator|logcat|reboot|remount|settings\s+(put|delete)|ime\s+(set|enable|disable))\b') `
            '出现禁止的 ADB 命令'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'unexpected.log'))) 'fake adb 收到未列入白名单的命令'
    }
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        $resolved = [IO.Path]::GetFullPath($TestRoot)
        $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) {
            throw '测试清理目标越出临时目录。'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

$coverage = [Collections.Generic.List[object]]::new()
foreach ($id in $script:RequiredCoverage) {
    $matching = @($script:Results | Where-Object { @($_.covers) -contains $id })
    $coverage.Add([ordered]@{
        id = $id
        status = if ($matching.Count -eq 0) { 'missing' }
            elseif (@($matching | Where-Object { $_.status -cne 'passed' }).Count -gt 0) { 'failed' }
            else { 'passed' }
        cases = @($matching | ForEach-Object { $_.name })
    })
}
$coverageComplete = @($coverage | Where-Object { $_.status -cne 'passed' }).Count -eq 0
$hasSelection = $script:Results.Count -gt 0
$suitePassed = $hasSelection -and $script:Failed -eq 0 -and ($Filter -cne '*' -or $coverageComplete)

if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
    if (-not [IO.Path]::IsPathFullyQualified($SummaryPath)) { throw '-SummaryPath 必须是绝对路径。' }
    $summaryFull = [IO.Path]::GetFullPath($SummaryPath)
    $summaryDirectory = Join-Path $SourceRepoRoot '.checks'
    $expectedSummaryPath = Join-Path $summaryDirectory 'tablet-intake-offline-suite-summary.json'
    if (-not $summaryFull.Equals([IO.Path]::GetFullPath($expectedSummaryPath),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw '-SummaryPath 只允许固定的 .checks/tablet-intake-offline-suite-summary.json。'
    }
    if (Test-Path -LiteralPath $summaryDirectory) {
        $summaryDirectoryItem = Get-Item -LiteralPath $summaryDirectory -Force
        if (-not $summaryDirectoryItem.PSIsContainer -or
            ($summaryDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '.checks 不是可信普通目录，拒绝写入套件摘要。'
        }
    }
    else {
        New-Item -ItemType Directory -Path $summaryDirectory | Out-Null
    }
    if (Test-Path -LiteralPath $summaryFull) {
        $summaryItem = Get-Item -LiteralPath $summaryFull -Force
        $linkTypeProperty = $summaryItem.PSObject.Properties['LinkType']
        $linkType = if ($null -eq $linkTypeProperty) { '' } else { [string]$linkTypeProperty.Value }
        if ($summaryItem.PSIsContainer -or
            ($summaryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace($linkType)) {
            throw '套件摘要目标不是可信普通文件，拒绝覆盖。'
        }
    }
    $summary = [ordered]@{
        schema_version = 1
        suite = 'tablet_intake_offline'
        generated_at_utc = [DateTime]::UtcNow.ToString('o')
        status = if ($suitePassed) { 'passed' } else { 'failed' }
        filter = $Filter
        device_access = 'fake_adb_only'
        selected = $script:Results.Count
        passed = $script:Passed
        failed = $script:Failed
        required_coverage = @($coverage)
        cases = @($script:Results)
    }
    $temporary = Join-Path $summaryDirectory ('.' + [IO.Path]::GetFileName($summaryFull) +
        '.tmp-' + [guid]::NewGuid().ToString('N'))
    try {
        $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding utf8
        Move-Item -LiteralPath $temporary -Destination $summaryFull -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

Write-Host "tablet intake offline：$($script:Passed) passed，$($script:Failed) failed。"
if (-not $hasSelection) { Write-Host '未选中任何用例，拒绝假绿。' -ForegroundColor Red }
elseif ($Filter -ceq '*' -and -not $coverageComplete) {
    $missing = @($coverage | Where-Object { $_.status -cne 'passed' } |
        ForEach-Object { "$($_.id)=$($_.status)" })
    Write-Host ("必需覆盖不完整：" + ($missing -join ',')) -ForegroundColor Red
}
if (-not $suitePassed) { exit 1 }
