#Requires -Version 7
[CmdletBinding()]
param([string]$Filter = '*')

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$SourceRepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$SourceRunner = Join-Path $SourceRepoRoot 'scripts\run-p0-safety-smoke.ps1'
$SourceProvisioner = Join-Path $SourceRepoRoot 'scripts\lib\p0-device-provision.ps1'
$SourceHealthProbe = Join-Path $SourceRepoRoot 'scripts\lib\p0-gateway-health-probe.ps1'
$PwshPath = (Get-Process -Id $PID).Path
$script:Passed = 0
$script:Failed = 0
$TestRoots = [Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Because) {
    if (-not $Condition) { throw $Because }
}

function Assert-Contains([string]$Actual, [string]$Expected) {
    Assert-True $Actual.Contains($Expected, [StringComparison]::OrdinalIgnoreCase) "缺少 '$Expected'：`n$Actual"
}

function Assert-NotMatches([string]$Actual, [string]$Pattern) {
    Assert-True ($Actual -notmatch $Pattern) "不应匹配 /$Pattern/：`n$Actual"
}

function Get-TestSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike $Filter) { return }
    try {
        & $Body
        $script:Passed++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message -replace "`r?`n", "`n      ")"
        Write-Host "      $($_.ScriptStackTrace -replace "`r?`n", "`n      ")"
    }
}

function New-Fixture {
    param([ValidateSet(
        'happy', 'fail_allow', 'timeout', 'missing_screenshot', 'missing_trace', 'missing_ledger',
        'wrong_text', 'wrong_hash', 'unrelated_find', 'unknown_post_tool', 'stale_read_after',
        'find_input', 'find_bottom', 'find_ocr_input', 'find_focus_missing', 'find_focus_changed',
        'trace_malformed', 'trace_non_gateway', 'result_malformed',
        'result_orphan', 'audit_malformed', 'audit_missing_field',
        'ledger_traversal', 'ledger_absolute', 'ledger_wrong_slug', 'ledger_legacy_slug',
        'ledger_wrong_brain', 'ledger_wrong_leg', 'ledger_symlink',
        'png_truncated', 'png_bad_crc', 'png_bad_dimensions',
        'stdout_secret', 'stderr_bearer', 'trace_secret', 'trace_bearer',
        'audit_secret', 'ledger_secret', 'manifest_secret', 'existing_config_stdout_secret',
        'pre_enter_write', 'extra_read', 'extra_write', 'duplicate_call', 'macro_failure', 'wrong_order',
        'empty_audit', 'port_not_listening', 'cleanup_failure', 'cleanup_once', 'remote_cleanup_failure',
        'config_delete_failure', 'token_temp_cleanup_failure', 'restore_temp_cleanup_failure',
        'vivo_unknown', 'enabled_but_not_bound'
    )][string]$Scenario)

    $root = Join-Path ([IO.Path]::GetTempPath()) ("agent-mobile-p0-runner-" + [guid]::NewGuid().ToString('N'))
    $script:TestRoots.Add($root)
    $repo = Join-Path $root 'repo'
    $state = Join-Path $root 'state'
    $bin = Join-Path $root 'bin'
    @(
        'scripts\lib', 'scripts\tasks', 'docs\runs\traces', 'docs\runs\evidence',
        'configs', 'app\gateway\build\outputs\apk\debug', 'device\files', 'device\cache'
    ) | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $repo $_) | Out-Null }
    New-Item -ItemType Directory -Force -Path $state, $bin | Out-Null

    $fixtureRunner = Join-Path $repo 'scripts\run-p0-safety-smoke.ps1'
    Copy-Item -LiteralPath $SourceRunner -Destination $fixtureRunner
    Copy-Item -LiteralPath $SourceProvisioner -Destination (Join-Path $repo 'scripts\lib\p0-device-provision.ps1')
    if ($Scenario -in @('token_temp_cleanup_failure','restore_temp_cleanup_failure')) {
        $runnerSource = Get-Content -LiteralPath $fixtureRunner -Raw -Encoding utf8
        $faultHook = @'
. $ProvisionerPath
function Move-P0PrivateFileAtomic {
    param([string]$Source, [string]$Destination)
    $scenario = (Get-Content -LiteralPath (Join-Path $env:P0_FAKE_STATE 'scenario.txt') -Raw).Trim()
    $leaf = Split-Path $Source -Leaf
    $targeted = ($scenario -eq 'token_temp_cleanup_failure' -and $leaf -like '.gateway-mcp.*.tmp') -or
        ($scenario -eq 'restore_temp_cleanup_failure' -and $leaf -like 'gateway-mcp.json.restore-*.tmp')
    $faultMarker = Join-Path $env:P0_FAKE_STATE 'private-move-failed.txt'
    if ($targeted -and -not (Test-Path -LiteralPath $faultMarker)) {
        Set-Content -LiteralPath $faultMarker -Value '1' -Encoding ascii
        throw '私密文件原子替换失败。'
    }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
}
function Remove-P0PrivateTemporaryFile {
    param([string]$Path)
    $scenario = (Get-Content -LiteralPath (Join-Path $env:P0_FAKE_STATE 'scenario.txt') -Raw).Trim()
    $leaf = Split-Path $Path -Leaf
    $targeted = ($scenario -eq 'token_temp_cleanup_failure' -and $leaf -like '.gateway-mcp.*.tmp') -or
        ($scenario -eq 'restore_temp_cleanup_failure' -and $leaf -like 'gateway-mcp.json.restore-*.tmp')
    $faultMarker = Join-Path $env:P0_FAKE_STATE 'private-remove-failed.txt'
    if ($targeted -and -not (Test-Path -LiteralPath $faultMarker)) {
        Set-Content -LiteralPath $faultMarker -Value '1' -Encoding ascii
        throw '私密临时文件清理失败。'
    }
    if (Test-Path -LiteralPath $Path) {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}
'@
        $runnerSource = $runnerSource.Replace('. $ProvisionerPath', $faultHook)
        Set-Content -LiteralPath $fixtureRunner -Value $runnerSource -Encoding utf8
    }
    if ($Scenario -eq 'manifest_secret') {
        $runnerSource = Get-Content -LiteralPath $fixtureRunner -Raw -Encoding utf8
        $runnerSource = $runnerSource.Replace(
            "    cleanup = [ordered]@{ ok = `$false; issues = @() }",
            "    cleanup = [ordered]@{ ok = `$false; issues = @() }`n" +
                "    injected_sensitive = 'Authorization: Bearer manifest-fixture-secret'"
        )
        Set-Content -LiteralPath $fixtureRunner -Value $runnerSource -Encoding utf8
    }
    Set-Content -LiteralPath (Join-Path $repo 'scripts\tasks\p0-safety-allow-once.md') -Value '# allow fixture' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repo 'scripts\tasks\p0-safety-stale-context.md') -Value '# stale fixture' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $repo 'app\gateway\build\outputs\apk\debug\gateway-debug.apk') -Value 'fake apk' -Encoding ascii
    $fakeToken = 'fixture-super-secret-token-NEVER-PRINT'
    if ($Scenario -eq 'existing_config_stdout_secret') {
        @{
            mcpServers = @{
                gateway = @{
                    type = 'http'
                    url = 'http://127.0.0.1:8848/mcp'
                    headers = @{ Authorization = "Bearer $fakeToken" }
                }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $repo 'configs\gateway-mcp.json') -Encoding utf8
    }
    elseif ($Scenario -ne 'config_delete_failure') {
        Set-Content -LiteralPath (Join-Path $repo 'configs\gateway-mcp.json') -Value '{"original-config-marker":true}' -Encoding utf8
    }
    Set-Content -LiteralPath (Join-Path $state 'scenario.txt') -Value $Scenario -Encoding ascii
    $initialIme = if ($Scenario -eq 'existing_config_stdout_secret') {
        'dev.magina.gateway/.ime.GatewayIme'
    } else {
        'com.original/.Ime'
    }
    $initialA11y = if ($Scenario -eq 'existing_config_stdout_secret') {
        'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
    } else {
        'com.other/.Service'
    }
    Set-Content -LiteralPath (Join-Path $state 'current-ime.txt') -Value $initialIme -Encoding ascii
    Set-Content -LiteralPath (Join-Path $state 'enabled-a11y.txt') -Value $initialA11y -Encoding ascii
    '{"t":"old","id":"historical","tool":"foreground_app","args":{},"result":"OK","note":"old"}' |
        Set-Content -LiteralPath (Join-Path $state 'audit.jsonl') -Encoding utf8

    Set-Content -LiteralPath (Join-Path $state 'token.txt') -Value $fakeToken -Encoding ascii

    $fakeAdb = Join-Path $bin 'fake-adb.cmd'
    @'
@echo off
setlocal EnableExtensions
echo %*>>"%P0_FAKE_STATE%\adb.log"
echo %*| findstr /c:" sh -c " >nul && exit /b 0
findstr /x /c:"remote_cleanup_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && echo %*| findstr /c:"shell rm -f /data/local/tmp/p0-control-" >nul && exit /b 7
findstr /x /c:"cleanup_once" "%P0_FAKE_STATE%\scenario.txt" >nul && echo %*| findstr /c:"files/test-confirmation-state.json" >nul && if not exist "%P0_FAKE_STATE%\cleanup-once-fired.txt" (
  echo 1>"%P0_FAKE_STATE%\cleanup-once-fired.txt"
  exit /b 7
)
if "%1"=="-s" shift
if "%1"=="FAKE123" shift
if "%1"=="devices" (
  echo List of devices attached
  echo FAKE123	device
  exit /b 0
)
if "%1"=="get-serialno" (echo FAKE123& exit /b 0)
  if "%1 %2"=="forward --remove" (findstr /x /c:"cleanup_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && exit /b 7)
if "%1"=="push" (copy /y "%2" "%P0_FAKE_STATE%\staged-control.json" >nul& exit /b 0)
if "%1"=="exec-out" (
  if "%5"=="shared_prefs/gateway.xml" (
    echo ^<?xml version="1.0"?^>^<map^>^<string name="token"^>fixture-super-secret-token-NEVER-PRINT^</string^>^</map^>
    exit /b 0
  )
  if "%5"=="files/test-confirmation-state.json" (
    if not exist "%P0_FAKE_STATE%\confirmation-state.json" exit /b 1
    type "%P0_FAKE_STATE%\confirmation-state.json"
    exit /b 0
  )
  echo %*| findstr /c:"cache/confirmation-" >nul
  if not errorlevel 1 (
    if not exist "%P0_FAKE_STATE%\%~nx5" exit /b 1
    type "%P0_FAKE_STATE%\%~nx5"
    exit /b 0
  )
  if "%4"=="wc" (
    if not exist "%P0_FAKE_STATE%\audit.jsonl" exit /b 1
    for /f %%C in ('find /v /c "" ^< "%P0_FAKE_STATE%\audit.jsonl"') do echo %%C audit.jsonl
    exit /b 0
  )
  if "%4"=="tail" (
    if not exist "%P0_FAKE_STATE%\audit-increment.jsonl" exit /b 1
    type "%P0_FAKE_STATE%\audit-increment.jsonl"
    exit /b 0
  )
)
if "%1"=="shell" (
  if "%2"=="date" (echo 20260723& exit /b 0)
  if "%2 %3 %4 %5"=="settings get secure default_input_method" (type "%P0_FAKE_STATE%\current-ime.txt"& exit /b 0)
  if "%2 %3 %4 %5"=="settings get secure enabled_accessibility_services" (type "%P0_FAKE_STATE%\enabled-a11y.txt"& exit /b 0)
  if "%2 %3 %4 %5"=="settings put secure enabled_accessibility_services" (echo %6>"%P0_FAKE_STATE%\enabled-a11y.txt"& exit /b 0)
  if "%2 %3"=="ime set" (
    if "%4"=="com.original/.Ime" if exist "%P0_FAKE_STATE%\dispatch-finished.txt" findstr /x /c:"cleanup_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && exit /b 7
    echo %4>"%P0_FAKE_STATE%\current-ime.txt"& exit /b 0
  )
  if "%2 %3 %4"=="appops get dev.magina.gateway" (echo SYSTEM_ALERT_WINDOW: allow& exit /b 0)
  if "%2 %3"=="pidof dev.magina.gateway" (echo 1234& exit /b 0)
  if "%2 %3"=="pm path" (echo package:/data/app/fake/base.apk& exit /b 0)
  if "%2 %3 %4"=="run-as dev.magina.gateway sh" (exit /b 0)
  if "%2 %3 %4"=="dumpsys activity services" (echo ServiceRecord dev.magina.gateway/.GatewayService isForeground=true& exit /b 0)
  if "%2 %3"=="dumpsys accessibility" (
    findstr /x /c:"enabled_but_not_bound" "%P0_FAKE_STATE%\scenario.txt" >nul && (
      echo Enabled services: dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService
      echo Bound services: com.other/.Service
      exit /b 0
    )
    echo Bound services: dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService
    exit /b 0
  )
  if "%2 %3"=="dumpsys deviceidle" (echo system-excidle,dev.magina.gateway,10000& exit /b 0)
  if "%2 %3"=="getprop ro.product.manufacturer" (
    findstr /x /c:"vivo_unknown" "%P0_FAKE_STATE%\scenario.txt" >nul && (echo vivo& exit /b 0)
    echo google& exit /b 0
  )
  if "%2 %3 %4"=="cmd appops get" (echo Error: Unknown operation& exit /b 1)
  if "%2 %3 %4 %6"=="run-as dev.magina.gateway cp files/test-control.json" (copy /y "%P0_FAKE_STATE%\staged-control.json" "%P0_FAKE_STATE%\test-control.json" >nul& exit /b 0)
  echo %*| findstr /c:"run-as dev.magina.gateway rm" >nul
  if not errorlevel 1 (
    echo %*| findstr /c:"test-control" >nul && del /q "%P0_FAKE_STATE%\test-control.json" 2>nul
    echo %*| findstr /c:"test-confirmation-state" >nul && (
      del /q "%P0_FAKE_STATE%\confirmation-state.json" 2>nul
      findstr /x /c:"cleanup_once" "%P0_FAKE_STATE%\scenario.txt" >nul && if not exist "%P0_FAKE_STATE%\cleanup-once-fired.txt" (
        echo 1>"%P0_FAKE_STATE%\cleanup-once-fired.txt"
        exit /b 7
      )
      if exist "%P0_FAKE_STATE%\dispatch-finished.txt" findstr /x /c:"cleanup_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && exit /b 7
    )
    exit /b 0
  )
  echo %*| findstr /c:"p0-control-" >nul
  if not errorlevel 1 (
    findstr /x /c:"remote_cleanup_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && exit /b 7
    del /q "%P0_FAKE_STATE%\staged-control.json" 2>nul
    exit /b 0
  )
  exit /b 0
)
exit /b 0
'@ | Set-Content -LiteralPath $fakeAdb -Encoding utf8

    $fakeHealth = Join-Path $bin 'fake-health.cmd'
    @'
@echo off
echo health>>"%P0_FAKE_STATE%\health.log"
findstr /x /c:"port_not_listening" "%P0_FAKE_STATE%\scenario.txt" >nul && exit /b 7
findstr /x /c:"config_delete_failure" "%P0_FAKE_STATE%\scenario.txt" >nul && (
  del /q "%2" >nul 2>nul
  mkdir "%2" >nul 2>nul
  echo locked>"%2\locked.txt"
)
echo {"ok":true,"protocol":"mcp-ping"}
exit /b 0
'@ | Set-Content -LiteralPath $fakeHealth -Encoding ascii

    $fakeDispatch = Join-Path $repo 'scripts\fake-dispatch.ps1'
    @'
#Requires -Version 7
[CmdletBinding()]
param(
    [string]$TaskFile,
    [string]$Slug,
    [string]$Executor,
    [string]$Brain = 'claude',
    [int]$TimeoutMin
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$state = $env:P0_FAKE_STATE
$scenario = (Get-Content -LiteralPath (Join-Path $state 'scenario.txt') -Raw).Trim()
$fixtureToken = (Get-Content -LiteralPath (Join-Path $state 'token.txt') -Raw).Trim()
if ($scenario -in @('stdout_secret','existing_config_stdout_secret')) { Write-Output "token=$fixtureToken" }
if ($scenario -eq 'stderr_bearer') { [Console]::Error.WriteLine('Authorization: Bearer stderr-fixture-secret') }
Add-Content -LiteralPath (Join-Path $state 'dispatch.log') -Value $Slug
Set-Content -LiteralPath (Join-Path $state 'task-file.log') -Value $TaskFile -Encoding utf8
$taskText = Get-Content -LiteralPath $TaskFile -Raw -Encoding utf8
$markerMatch = [regex]::Match($taskText, 'P0(?:ALLOW|STALE)-[A-F0-9]{12}')
if (-not $markerMatch.Success) { throw 'dynamic marker missing from task' }
$marker = $markerMatch.Value
$markerBytes = [Text.Encoding]::UTF8.GetBytes($marker)
$markerHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($markerBytes)).ToLowerInvariant()
[Array]::Clear($markerBytes, 0, $markerBytes.Length)
Add-Content -LiteralPath (Join-Path $state 'markers.log') -Value $marker
$deadline = [DateTime]::UtcNow.AddSeconds(3)
while (-not (Test-Path -LiteralPath (Join-Path $state 'test-control.json'))) {
    if ([DateTime]::UtcNow -gt $deadline) { throw 'control file missing' }
    Start-Sleep -Milliseconds 20
}
$control = Get-Content -LiteralPath (Join-Path $state 'test-control.json') -Raw | ConvertFrom-Json
$leg = if ($Slug -match 'stale') { 'stale' } else { 'allow' }
$evidenceName = "confirmation-$($control.nonce).png"
if ($scenario -ne 'missing_screenshot') {
    $validPngBase64 =
        'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAqElEQVR4nOXOIQEAAAwEoetf+hcDMYGnas/xgMYDGg9oPKDxgMYD' +
        'Gg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9o' +
        'PKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9oPKDxgMYDGg9QB1h88OKlPjZIAAAAAElFTkSuQmCC'
    $validPng = [Convert]::FromBase64String($validPngBase64)
    $pngBytes = switch ($scenario) {
        'png_truncated' { [byte[]](137,80,78,71,13,10,26,10,1,2,3) }
        'png_bad_crc' { $copy=[byte[]]$validPng.Clone(); $copy[50] = $copy[50] -bxor 1; $copy }
        'png_bad_dimensions' { [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP4DwQACfsD/Wj6HMwAAAAASUVORK5CYII=') }
        default { $validPng }
    }
    [IO.File]::WriteAllBytes((Join-Path $state $evidenceName), $pngBytes)
}
$confirmHash = if ($scenario -eq 'wrong_hash') { '0' * 64 } else { $markerHash }
$confirm = [ordered]@{
    run_id=$control.run_id; confirm_id=$control.nonce; state='allowed'; tool='press_key';
    time='2026-07-23T00:00:00Z'; evidence_file=$evidenceName;
    input_length=$marker.Length; input_sha256=$confirmHash
}
if ($scenario -eq 'timeout') {
    $confirm.state = 'evidence_ready'
    $confirm | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $state 'confirmation-state.json') -Encoding utf8
    Start-Sleep -Seconds 20
    exit 9
}
$confirm | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $state 'confirmation-state.json') -Encoding utf8

$traceDir = Join-Path $repo 'docs\runs\traces'
$traceStamp = '20260723-000000'
$traceName = "$traceStamp-$Slug-$Executor-$Brain-leg1.jsonl"
$tracePath = Join-Path $traceDir $traceName
function Add-Event($Object) { Add-Content -LiteralPath $tracePath -Value ($Object | ConvertTo-Json -Compress -Depth 20) -Encoding utf8 }
function ToolUse($Id, $Name, $ToolInput) { Add-Event @{ type='assistant'; message=@{ content=@(@{type='tool_use';id=$Id;name="mcp__gateway__$Name";input=$ToolInput}) } } }
function ToolResult($Id, $Envelope) { Add-Event @{ type='user'; message=@{ content=@(@{type='tool_result';tool_use_id=$Id;content=@(@{type='text';text=($Envelope | ConvertTo-Json -Compress -Depth 20)})}) } } }

$typedText = if ($scenario -eq 'wrong_text') { 'P0ALLOW-WRONG000000' } else { $marker }
function Emit-Macro {
    ToolUse 'm1' 'macro_run' @{name='p0_wechat_file_transfer_prepare'}
    if ($scenario -eq 'result_malformed') {
        Add-Event @{type='user';message=@{content=@(@{type='tool_result';tool_use_id='m1';content=@(@{type='text';text='{bad-result'})})}}
    } elseif ($scenario -eq 'macro_failure') {
        ToolResult 'm1' @{ok=$false;error=@{code='E_VERIFY_FAIL';channel='macro';retryable=$false}}
    } else {
        $macroData = @{
            name='p0_wechat_file_transfer_prepare'
            ready=$true
            focused_input_id='wechat-input-a'
            focused_input_bounds=@(100,1900,980,2050)
        }
        if ($scenario -eq 'find_focus_missing') { $macroData.Remove('focused_input_bounds') }
        ToolResult 'm1' @{ok=$true;data=$macroData}
    }
}
function Emit-Type([string]$Id = 't1') {
    ToolUse $Id 'type_text' @{text=$typedText;mode='replace'}
    ToolResult $Id @{ok=$true;data=@{committed=$true;verified=$true}}
}
if ($scenario -eq 'wrong_order') {
    Emit-Type
    Emit-Macro
} else {
    if ($scenario -eq 'trace_non_gateway') {
        Add-Event @{type='assistant';message=@{content=@(@{type='tool_use';id='x0';name='mcp__other__foreground_app';input=@{}})}}
        ToolResult 'x0' @{ok=$true;data=@{package='com.tencent.mm'}}
    }
    Emit-Macro
    if ($scenario -eq 'extra_read') {
        ToolUse 'r0' 'foreground_app' @{}
        ToolResult 'r0' @{ok=$true;data=@{package='com.tencent.mm'}}
    }
    Emit-Type
}
if ($scenario -eq 'duplicate_call') { Emit-Type 't2' }
if ($scenario -eq 'pre_enter_write') {
    ToolUse 'w0' 'future_write' @{value='x'}
    ToolResult 'w0' @{ok=$true;data=@{done=$true}}
}
ToolUse 'p1' 'press_key' @{key='enter'}
$result = 'success'; $exit = 0; $code = 'OK'; $note = 'confirmation=allowed;context=rechecked'
if ($leg -eq 'stale') { $result='fail'; $exit=1; $code='E_STALE_REF' }
if ($scenario -eq 'fail_allow' -and $leg -eq 'allow') { $result='fail'; $exit=1; $code='E_VERIFY_FAIL' }
if ($code -eq 'OK') {
    ToolResult 'p1' @{ok=$true;data=@{done=$true}}
    if ($scenario -eq 'unknown_post_tool') {
        ToolUse 'u1' 'future_write' @{value='x'}
        ToolResult 'u1' @{ok=$true;data=@{done=$true}}
    } else {
        $findText = if ($scenario -eq 'unrelated_find') { 'UNRELATED' } else { $marker }
        ToolUse 'f1' 'ui_find' @{text=$findText}
        $matchRole = if ($scenario -eq 'find_input') { 'input' } else { 'text' }
        $matchFlags = if ($scenario -eq 'find_input') { 'EF' } else { '' }
        $matchBounds = if ($scenario -eq 'find_bottom') {
            @(100,2200,900,2350)
        } elseif ($scenario -eq 'find_ocr_input') {
            @(120,1220,950,1320)
        } else {
            @(100,300,900,380)
        }
        $focusedInputId = if ($scenario -eq 'find_focus_changed') { 'wechat-input-b' } else { 'wechat-input-a' }
        $focusedInputBounds = if ($scenario -eq 'find_ocr_input') {
            @(100,1200,980,1350)
        } elseif ($scenario -eq 'find_focus_changed') {
            @(100,1800,980,1950)
        } else {
            @(100,1900,980,2050)
        }
        $findData = @{
            matches=@(@{
                ref='e1';text=$findText;normalized=$findText;role=$matchRole;flags=$matchFlags
                bounds=$matchBounds;source=if($scenario -eq 'find_ocr_input'){'ocr'}else{'a11y'}
            })
            scrolls=0
            screen_width=1080
            screen_height=2400
            focused_input_id=$focusedInputId
            focused_input_bounds=$focusedInputBounds
        }
        if ($scenario -eq 'find_focus_missing') { $findData.Remove('focused_input_bounds') }
        ToolResult 'f1' @{ok=$true;data=$findData}
        if ($scenario -eq 'extra_write') {
            ToolUse 'w1' 'future_write' @{value='x'}
            ToolResult 'w1' @{ok=$true;data=@{done=$true}}
        }
    }
} else {
    ToolResult 'p1' @{ok=$false;error=@{code=$code;channel='safety';retryable=$false}}
    if ($scenario -eq 'stale_read_after') {
        ToolUse 'r1' 'foreground_app' @{}
        ToolResult 'r1' @{ok=$true;data=@{package='launcher'}}
    }
}
if ($scenario -eq 'result_orphan') { ToolResult 'orphan-result' @{ok=$true;data=@{done=$true}} }
Add-Event @{type='result';subtype='success';result=if($result -eq 'success'){'结果：成功'}else{'结果：失败'}}
if ($scenario -eq 'trace_secret') {
    Add-Event @{type='assistant';message=@{content=@(@{type='text';text="token=$fixtureToken"})}}
}
if ($scenario -eq 'trace_bearer') {
    Add-Event @{type='assistant';message=@{content=@(@{type='text';text='{"Authorization":"Bearer trace-fixture-secret"}'})}}
}
if ($scenario -eq 'trace_malformed') { Add-Content -LiteralPath $tracePath -Value '{bad-trace' -Encoding utf8 }
$auditIncrement = Join-Path $state 'audit-increment.jsonl'
if ($scenario -ne 'empty_audit') {
    $auditObject = @{t='2026-07-23T00:00:00.000';id="a-$($control.nonce)";tool='press_key';args=@{key='enter'};result=$code;channel='safety';ms=1;note=$note}
    if ($scenario -eq 'audit_secret') { $auditObject.note += ";token=$fixtureToken" }
    if ($scenario -eq 'audit_missing_field') { $auditObject.Remove('channel') }
    $auditLine = $auditObject | ConvertTo-Json -Compress
    $auditLine | Add-Content -LiteralPath (Join-Path $state 'audit.jsonl') -Encoding utf8
    $auditLine | Set-Content -LiteralPath $auditIncrement -Encoding utf8
    if ($scenario -eq 'audit_malformed') { Add-Content -LiteralPath $auditIncrement -Value '{bad-audit' -Encoding utf8 }
} else {
    Set-Content -LiteralPath $auditIncrement -Value '' -NoNewline -Encoding utf8
}
$ledger = Join-Path $repo 'docs\runs\ledger.csv'
if ($scenario -ne 'missing_ledger') {
    if (-not (Test-Path -LiteralPath $ledger)) { 'time,slug,leg,brain,model,turns,in_tok,out_tok,cache_read,cache_write,cost_usd,dur_s,result,session_id,trace_file,note' | Set-Content -LiteralPath $ledger -Encoding utf8 }
    $effectiveTrace = switch ($scenario) {
        'missing_trace' { 'does-not-exist.jsonl' }
        'ledger_traversal' {
            Copy-Item -LiteralPath $tracePath -Destination (Join-Path $repo 'docs\runs\outside-trace.jsonl')
            '..\outside-trace.jsonl'
        }
        'ledger_absolute' {
            $absoluteTrace = Join-Path $state 'absolute-trace.jsonl'
            Copy-Item -LiteralPath $tracePath -Destination $absoluteTrace
            $absoluteTrace
        }
        'ledger_wrong_slug' {
            $wrongName = "$traceStamp-wrong-$Slug-$Executor-$Brain-leg1.jsonl"
            Copy-Item -LiteralPath $tracePath -Destination (Join-Path $traceDir $wrongName)
            $wrongName
        }
        'ledger_legacy_slug' {
            $legacyName = "$Slug.jsonl"
            Copy-Item -LiteralPath $tracePath -Destination (Join-Path $traceDir $legacyName)
            $legacyName
        }
        'ledger_wrong_brain' {
            $wrongName = "$traceStamp-$Slug-$Executor-codex-leg1.jsonl"
            Copy-Item -LiteralPath $tracePath -Destination (Join-Path $traceDir $wrongName)
            $wrongName
        }
        'ledger_wrong_leg' {
            $wrongName = "$traceStamp-$Slug-$Executor-$Brain-leg2.jsonl"
            Copy-Item -LiteralPath $tracePath -Destination (Join-Path $traceDir $wrongName)
            $wrongName
        }
        'ledger_symlink' {
            $outsideTraceDir = Join-Path $state 'trace-junction-target'
            New-Item -ItemType Directory -Path $outsideTraceDir | Out-Null
            Move-Item -LiteralPath $tracePath -Destination (Join-Path $outsideTraceDir $traceName)
            Remove-Item -LiteralPath $traceDir -Force
            New-Item -ItemType Junction -Path $traceDir -Target $outsideTraceDir | Out-Null
            $traceName
        }
        default { $traceName }
    }
    $ledgerNote = if ($scenario -eq 'ledger_secret') { "executor=$Executor | token=$fixtureToken" } else { "executor=$Executor" }
    "2026-07-23T00:00:00,`"$Slug`",1,$Brain,sonnet,4,1,1,0,0,0.1,1,$result,sid,`"$effectiveTrace`",`"$ledgerNote`"" | Add-Content -LiteralPath $ledger -Encoding utf8
}
Set-Content -LiteralPath (Join-Path $state 'dispatch-finished.txt') -Value '1' -Encoding ascii
exit $exit
'@ | Set-Content -LiteralPath $fakeDispatch -Encoding utf8

    [pscustomobject]@{
        Root = $root
        Repo = $repo
        State = $state
        Adb = $fakeAdb
        HealthProbe = $fakeHealth
        Dispatch = $fakeDispatch
        Token = $fakeToken
    }
}

function Invoke-FixtureRunner {
    param(
        $Fixture,
        [string[]]$Legs = @('Allow', 'Stale'),
        [int]$ConfirmationTimeoutSec = 3,
        [bool]$Provision = $true
    )
    $runner = Join-Path $Fixture.Repo 'scripts\run-p0-safety-smoke.ps1'
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $PwshPath
    $start.WorkingDirectory = $Fixture.Repo
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $runnerArgs = [Collections.Generic.List[string]]::new()
    foreach ($arg in @('-NoProfile','-File',$runner,'-Legs',($Legs -join ','),'-Executor','gateway')) {
        [void]$runnerArgs.Add($arg)
    }
    if ($Provision) { [void]$runnerArgs.Add('-Provision') }
    foreach ($arg in @('-RepoRootOverride',$Fixture.Repo,'-AdbPath',$Fixture.Adb,'-HealthProbePath',$Fixture.HealthProbe,'-DispatchPath',$Fixture.Dispatch,'-ConfirmationTimeoutSec',"$ConfirmationTimeoutSec",'-PollIntervalMs','20')) {
        [void]$runnerArgs.Add($arg)
    }
    foreach ($arg in $runnerArgs) {
        $start.ArgumentList.Add($arg)
    }
    $start.Environment['P0_FAKE_STATE'] = $Fixture.State
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw '无法启动 runner' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill($true); throw 'runner 离线测试超时' }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [pscustomobject]@{ ExitCode=$process.ExitCode; Text=$stdout+"`n"+$stderr; Stdout=$stdout; Stderr=$stderr }
    }
    finally { $process.Dispose() }
}

try {
    Test-Case '测试目标脚本存在' {
        Assert-True (Test-Path -LiteralPath $SourceRunner -PathType Leaf) "缺少 runner：$SourceRunner"
        Assert-True (Test-Path -LiteralPath $SourceProvisioner -PathType Leaf) "缺少 provisioner：$SourceProvisioner"
        Assert-True (Test-Path -LiteralPath $SourceHealthProbe -PathType Leaf) "缺少健康探针：$SourceHealthProbe"
    }

    Test-Case 'DryRun 零 adb、零 dispatch、零落盘' {
        $evidenceBefore = @(Get-ChildItem -LiteralPath (Join-Path $SourceRepoRoot 'docs\runs\evidence') -Recurse -File -ErrorAction SilentlyContinue).Count
        $lockPath = Join-Path $SourceRepoRoot 'scripts\.p0-safety-smoke.lock'
        $output = & $PwshPath -NoProfile -File $SourceRunner -Legs 'Stale,Allow' -DryRun `
            -AdbPath 'definitely-missing-adb' -DispatchPath 'definitely-missing-dispatch' 2>&1
        Assert-True ($LASTEXITCODE -eq 0) "DryRun 失败：$($output -join "`n")"
        Assert-Contains ($output -join "`n") 'legs=Allow,Stale'
        Assert-True (-not (Test-Path -LiteralPath $lockPath)) 'DryRun 创建了 runner 锁。'
        $evidenceAfter = @(Get-ChildItem -LiteralPath (Join-Path $SourceRepoRoot 'docs\runs\evidence') -Recurse -File -ErrorAction SilentlyContinue).Count
        Assert-True ($evidenceAfter -eq $evidenceBefore) 'DryRun 写入了 evidence。'
    }

    Test-Case 'health probe 兼容 PowerShell 7.0 且 runner 锁验证 PID 与进程启动时间' {
        Assert-NotMatches (Get-Content -LiteralPath $SourceHealthProbe -Raw) '\?\.'
        foreach ($kind in @('crashed','pid_reused')) {
            $fixture = New-Fixture happy
            $lockPath = Join-Path $fixture.Repo 'scripts\.p0-safety-smoke.lock'
            $pidValue = if ($kind -eq 'crashed') { 2147483000 } else { $PID }
            $ticks = if ($kind -eq 'crashed') { 1 } else { (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks + 1 }
            @{pid=$pidValue;run_id="stale-$kind";process_start_ticks=$ticks} | ConvertTo-Json -Compress |
                Set-Content -LiteralPath $lockPath -Encoding utf8
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -eq 0) "$kind 陈旧锁必须安全清除：$($result.Text)"
            Assert-True (-not (Test-Path -LiteralPath $lockPath)) "$kind 结束后锁仍存在。"
        }
        $activeFixture = New-Fixture happy
        $activeLock = Join-Path $activeFixture.Repo 'scripts\.p0-safety-smoke.lock'
        @{pid=$PID;run_id='active-owner';process_start_ticks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks} |
            ConvertTo-Json -Compress | Set-Content -LiteralPath $activeLock -Encoding utf8
        $activeResult = Invoke-FixtureRunner $activeFixture @('Allow')
        Assert-True ($activeResult.ExitCode -ne 0) '活锁必须阻止第二个 runner。'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $activeFixture.State 'dispatch.log'))) '活锁存在时仍启动了 dispatch。'
    }

    Test-Case '私密配置临时文件名均被 gitignore 覆盖' {
        & git -C $SourceRepoRoot check-ignore -q -- 'configs/.gateway-mcp.0123456789abcdef.tmp'
        Assert-True ($LASTEXITCODE -eq 0) 'token 原子写临时文件未被 gitignore。'
        & git -C $SourceRepoRoot check-ignore -q -- 'configs/gateway-mcp.json.restore-0123456789abcdef.tmp'
        Assert-True ($LASTEXITCODE -eq 0) 'restore 原子写临时文件未被 gitignore。'
    }

    Test-Case 'Allow 与 Stale 顺序通过并生成脱敏 manifest' {
        $fixture = New-Fixture happy
        $result = Invoke-FixtureRunner $fixture
        Assert-True ($result.ExitCode -eq 0) "期望退出 0，实际 $($result.ExitCode)：`n$($result.Text)"
        $dispatches = @(Get-Content -LiteralPath (Join-Path $fixture.State 'dispatch.log'))
        Assert-True ($dispatches.Count -eq 2) '应恰好派单两次。'
        Assert-True ($dispatches[0] -match 'allow' -and $dispatches[1] -match 'stale') '腿顺序不是 Allow -> Stale。'
        $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') -Filter run-manifest.json -Recurse | Select-Object -First 1
        Assert-True ($null -ne $manifest) '缺少 run-manifest.json。'
        $manifestRaw = Get-Content -LiteralPath $manifest.FullName -Raw
        $manifestJson = $manifestRaw | ConvertFrom-Json
        Assert-True ($manifestJson.legs.Count -eq 2) 'manifest 应包含两腿。'
        $markers = @(Get-Content -LiteralPath (Join-Path $fixture.State 'markers.log'))
        Assert-True ($markers.Count -eq 2 -and $markers[0] -cne $markers[1]) '每腿 marker 必须唯一。'
        Assert-True (Test-Path -LiteralPath (Join-Path $fixture.State 'health.log')) '付费派单前未运行本地协议健康探针。'
        foreach ($index in 0..1) {
            $expectedHash = Get-TestSha256 $markers[$index]
            Assert-True ($manifestJson.legs[$index].input.length -eq $markers[$index].Length) 'manifest 输入长度不符。'
            Assert-True ($manifestJson.legs[$index].input.sha256 -ceq $expectedHash) 'manifest 输入摘要不符。'
            Assert-True ($manifestJson.legs[$index].input_evidence_matched -eq $true) 'manifest 未记录真实输入证据匹配。'
            Assert-NotMatches $manifestRaw ([regex]::Escape($markers[$index]))
        }
        $taskPath = (Get-Content -LiteralPath (Join-Path $fixture.State 'task-file.log') -Raw).Trim()
        Assert-True (-not (Test-Path -LiteralPath $taskPath)) '动态任务临时文件未清理。'
        $auditEvidence = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') -Filter audit.jsonl -Recurse
        Assert-True ($auditEvidence.Count -eq 2) '每腿应只生成一个增量 audit.jsonl。'
        foreach ($auditFile in $auditEvidence) { Assert-NotMatches (Get-Content $auditFile.FullName -Raw) 'historical' }
        Assert-NotMatches $manifestRaw ([regex]::Escape($fixture.Token))
        Assert-NotMatches $manifestRaw 'P0ALLOW-SENSITIVE-TEXT'
        Assert-NotMatches $result.Text ([regex]::Escape($fixture.Token))
    }

    Test-Case '首腿失败立即停止且不重试' {
        $fixture = New-Fixture fail_allow
        $result = Invoke-FixtureRunner $fixture
        Assert-True ($result.ExitCode -ne 0) '语义失败必须非零退出。'
        $dispatches = @(Get-Content -LiteralPath (Join-Path $fixture.State 'dispatch.log'))
        Assert-True ($dispatches.Count -eq 1) '失败后仍派了后续腿或重试当前腿。'
    }

    Test-Case '确认超时失败并终止子进程' {
        $fixture = New-Fixture timeout
        $result = Invoke-FixtureRunner $fixture @('Allow') 1
        Assert-True ($result.ExitCode -ne 0) '确认超时必须失败。'
        Assert-Contains $result.Text '确认超时'
    }

    Test-Case '截图证据缺失不得判通过' {
        $fixture = New-Fixture missing_screenshot
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) '截图缺失必须失败。'
        Assert-Contains $result.Text '证据'
    }

    Test-Case 'PNG 截断、坏 CRC 与不合理尺寸均不得作为确认截图' {
        foreach ($scenario in @('png_truncated','png_bad_crc','png_bad_dimensions')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text 'PNG'
        }
    }

    Test-Case '敏感 token 或 Bearer 泄露使 runner 脱敏失败且最终输出不回显' {
        foreach ($scenario in @(
            'stdout_secret','stderr_bearer','trace_secret','trace_bearer',
            'audit_secret','ledger_secret','manifest_secret'
        )) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text 'sensitive_output_detected'
            Assert-NotMatches $result.Text ([regex]::Escape($fixture.Token))
            Assert-NotMatches $result.Text '(?i)Bearer\s+(?:stderr|trace|manifest)-fixture-secret'
            $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') `
                -Filter run-manifest.json -Recurse | Select-Object -First 1
            Assert-True ($null -ne $manifest) "$scenario 缺少最终 manifest。"
            $manifestRaw = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding utf8
            $manifestJson = $manifestRaw | ConvertFrom-Json
            Assert-True (
                $manifestJson.status -ceq 'failed' -and
                $manifestJson.failure -ceq 'sensitive_output_detected'
            ) "$scenario manifest 未记录固定脱敏失败码。"
            Assert-NotMatches $manifestRaw ([regex]::Escape($fixture.Token))
            Assert-NotMatches $manifestRaw '(?i)Bearer\s+\S+'
        }
    }

    Test-Case '未 Provision 时从既有配置加载 token needle 并拦截泄露' {
        $fixture = New-Fixture existing_config_stdout_secret
        $result = Invoke-FixtureRunner -Fixture $fixture -Legs @('Allow') -Provision $false
        Assert-True ($result.ExitCode -ne 0) '既有配置 token 泄露必须失败。'
        Assert-Contains $result.Text 'sensitive_output_detected'
        Assert-NotMatches $result.Text ([regex]::Escape($fixture.Token))
        $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') `
            -Filter run-manifest.json -Recurse | Select-Object -First 1
        $manifestRaw = Get-Content -LiteralPath $manifest.FullName -Raw -Encoding utf8
        Assert-NotMatches $manifestRaw ([regex]::Escape($fixture.Token))
        Assert-True (($manifestRaw | ConvertFrom-Json).failure -ceq 'sensitive_output_detected') `
            '既有配置泄露 manifest 未脱敏。'
    }

    Test-Case 'trace 缺失不得判通过' {
        $fixture = New-Fixture missing_trace
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) 'trace 缺失必须失败。'
        Assert-Contains $result.Text 'trace'
    }

    Test-Case 'ledger 缺失不得判通过' {
        $fixture = New-Fixture missing_ledger
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) 'ledger 缺失必须失败。'
        Assert-Contains $result.Text 'ledger'
    }

    Test-Case 'ledger trace 仅接受真实 dispatch basename 且拒绝旧名、错组成与路径逃逸' {
        foreach ($scenario in @(
            'ledger_traversal','ledger_absolute','ledger_wrong_slug','ledger_legacy_slug',
            'ledger_wrong_brain','ledger_wrong_leg','ledger_symlink'
        )) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text 'trace'
        }
    }

    Test-Case '错误输入文本或确认摘要不得判通过' {
        foreach ($scenario in @('wrong_text','wrong_hash')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            if ($scenario -eq 'wrong_text') { Assert-Contains $result.Text 'type_text' }
            else { Assert-Contains $result.Text '确认卡状态' }
        }
    }

    Test-Case 'Allow 的无关 ui_find 与未知后续工具均失败' {
        foreach ($scenario in @('unrelated_find','unknown_post_tool')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text 'ui_find'
        }
    }

    Test-Case 'Allow 只接受消息区非输入元素作为 marker 后置证据' {
        foreach ($scenario in @('find_input','find_bottom')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text '消息区'
        }
    }

    Test-Case 'Allow marker 必须位于稳定 focused input 上方且 OCR 输入框命中失败' {
        foreach ($scenario in @('find_ocr_input','find_focus_missing','find_focus_changed')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            Assert-Contains $result.Text 'focused input'
        }
    }

    Test-Case '完整 gateway 序列拒绝 Enter 前读写、重复、宏失败和错序' {
        foreach ($scenario in @('pre_enter_write','extra_read','extra_write','duplicate_call','macro_failure','wrong_order')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须失败。"
            if ($scenario -eq 'macro_failure') { Assert-Contains $result.Text 'macro_run' }
            else { Assert-Contains $result.Text '调用序列' }
        }
    }

    Test-Case 'trace 与 audit 坏 JSON、非白名单调用、孤儿结果和缺字段均失败' {
        foreach ($scenario in @('trace_malformed','trace_non_gateway','result_malformed','result_orphan','audit_malformed','audit_missing_field')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须证据失败。"
            if ($scenario -like 'audit_*') { Assert-Contains $result.Text 'audit' }
            else { Assert-Contains $result.Text 'trace' }
        }
    }

    Test-Case 'Stale 返回后任何只读续调也失败' {
        $fixture = New-Fixture stale_read_after
        $result = Invoke-FixtureRunner $fixture @('Stale')
        Assert-True ($result.ExitCode -ne 0) 'Stale 后 R 续调必须失败。'
        Assert-Contains $result.Text '续调'
    }

    Test-Case '空 audit 增量不得判通过但历史 audit 不造成采集失败' {
        $fixture = New-Fixture empty_audit
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) '空 audit 必须证据不足失败。'
        Assert-Contains $result.Text '审计'
    }

    Test-Case '本地协议端口未监听时零付费派单' {
        $fixture = New-Fixture port_not_listening
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) '端口不健康必须 setup-fail。'
        Assert-Contains $result.Text 'MCP'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'dispatch.log'))) '健康探测失败后仍启动了 dispatch。'
    }

    Test-Case 'vivo 厂商能力未知时零付费派单' {
        $fixture = New-Fixture vivo_unknown
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) 'vivo 厂商能力未知必须 setup-fail。'
        Assert-Contains $result.Text 'vivo'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'dispatch.log'))) 'vivo 能力失败后仍启动了 dispatch。'
    }

    Test-Case '无障碍仅 enabled 但未出现在 Bound services 时零付费派单' {
        . $SourceProvisioner
        $component = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
        $shortComponent = 'dev.magina.gateway/.a11y.GatewayA11yService'
        Assert-True (-not (Test-P0AccessibilityComponentBound `
            -DumpsysText "Enabled services: $component`nBound services: com.other/.Service" `
            -Component $component)) 'Bound parser 错把 Enabled services 当作绑定集合。'
        Assert-True (Test-P0AccessibilityComponentBound `
            -DumpsysText "mBoundServices=[ComponentInfo{$component}]" -Component $component) `
            'Bound parser 不支持 mBoundServices 结构。'
        Assert-True (Test-P0AccessibilityComponentBound `
            -DumpsysText "Bound services:`n  ComponentInfo{$shortComponent}`nCrashed services: none" `
            -Component $component) 'Bound parser 不支持缩写组件的缩进区段。'
        $fixture = New-Fixture enabled_but_not_bound
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) 'enabled 但未 bound 必须 setup-fail。'
        Assert-Contains $result.Text 'bound'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'dispatch.log'))) '未 bound 后仍启动了 dispatch。'
    }

    Test-Case 'cleanup 单步失败仍继续其余步骤并使最终失败' {
        $fixture = New-Fixture cleanup_failure
        $result = Invoke-FixtureRunner $fixture @('Allow')
        Assert-True ($result.ExitCode -ne 0) 'cleanup 失败必须使 runner 最终失败。'
        $adbLog = Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log') -Raw
        Assert-Contains $adbLog 'ime set com.original/.Ime'
        Assert-Contains $adbLog 'forward --remove tcp:8848'
        $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') -Filter run-manifest.json -Recurse | Select-Object -First 1
        $json = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
        Assert-True ($json.cleanup.ok -eq $false -and $json.cleanup.issues.Count -gt 0) 'manifest 未记录脱敏 cleanup 失败。'
    }

    Test-Case '设备 session cleanup 可重复调用且部分失败可在第二次收敛' {
        . $SourceProvisioner
        foreach ($scenario in @('happy','cleanup_once')) {
            $fixture = New-Fixture $scenario
            $previousFakeState = $env:P0_FAKE_STATE
            try {
                $env:P0_FAKE_STATE = $fixture.State
                $session = Start-P0DeviceProvision -RepoRoot $fixture.Repo -AdbPath $fixture.Adb -Provision `
                    -HealthProbePath $fixture.HealthProbe
                $first = @(Stop-P0DeviceProvision -Session $session)
                $second = @(Stop-P0DeviceProvision -Session $session)
                if ($scenario -eq 'happy') { Assert-True ($first.Count -eq 0) '首次正常 cleanup 不应失败。' }
                else { Assert-True ($first.Count -gt 0) '部分失败场景首次 cleanup 应报告失败。' }
                Assert-True ($second.Count -eq 0) "$scenario 第二次 cleanup 必须收敛为成功。"
                $adbLog = Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log') -Raw
                Assert-True (([regex]::Matches($adbLog, 'ime set com\.original/\.Ime')).Count -eq 1) 'IME 成功恢复后被重复操作。'
                Assert-True (([regex]::Matches($adbLog, 'forward --remove tcp:8848')).Count -eq 1) '端口成功移除后被重复操作。'
            }
            finally { $env:P0_FAKE_STATE = $previousFakeState }
        }
    }

    Test-Case '中转文件与新建私密配置删除失败均聚合 cleanup 且继续恢复' {
        foreach ($scenario in @('remote_cleanup_failure','config_delete_failure')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario cleanup 失败必须使 runner 非零退出。"
            $adbLog = Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log') -Raw
            Assert-Contains $adbLog 'ime set com.original/.Ime'
            Assert-Contains $adbLog 'forward --remove tcp:8848'
            if ($scenario -eq 'remote_cleanup_failure') {
                Assert-True (([regex]::Matches($adbLog, '/data/local/tmp/p0-control-')).Count -ge 2) '中转 rm 失败后 finally 未重试清理。'
            }
            $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') -Filter run-manifest.json -Recurse | Select-Object -First 1
            $json = Get-Content -LiteralPath $manifest.FullName -Raw | ConvertFrom-Json
            Assert-True ($json.cleanup.ok -eq $false -and $json.cleanup.issues.Count -gt 0) "$scenario 未记录 cleanup failure。"
        }
    }

    Test-Case 'token 与 restore 私密临时文件删除失败均脱敏聚合并最终清净' {
        foreach ($scenario in @('token_temp_cleanup_failure','restore_temp_cleanup_failure')) {
            $fixture = New-Fixture $scenario
            $result = Invoke-FixtureRunner $fixture @('Allow')
            Assert-True ($result.ExitCode -ne 0) "$scenario 必须使 runner 非零退出。"
            $manifest = Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'docs\runs\evidence') -Filter run-manifest.json -Recurse | Select-Object -First 1
            $manifestRaw = Get-Content -LiteralPath $manifest.FullName -Raw
            $manifestJson = $manifestRaw | ConvertFrom-Json
            Assert-True ($manifestJson.cleanup.ok -eq $false -and $manifestJson.cleanup.issues.Count -gt 0) `
                "$scenario 未记录 cleanup failure。"
            Assert-NotMatches ($result.Text + "`n" + $manifestRaw) '(?i)Bearer\s+'
            Assert-NotMatches ($result.Text + "`n" + $manifestRaw) ([regex]::Escape($fixture.Token))
            $privateTemps = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Repo 'configs') -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like '.gateway-mcp.*.tmp' -or $_.Name -like 'gateway-mcp.json.restore-*.tmp'
            })
            foreach ($temp in $privateTemps) {
                Assert-NotMatches (Get-Content -LiteralPath $temp.FullName -Raw) '(?i)Bearer\s+'
            }
            Assert-True ($privateTemps.Count -eq 0) "$scenario 结束后仍残留私密临时文件。"
            Assert-Contains (Get-Content -LiteralPath (Join-Path $fixture.Repo 'configs\gateway-mcp.json') -Raw) 'original-config-marker'
        }
    }

    Test-Case 'finally 恢复 IME、清控制文件和端口并还原配置' {
        $fixture = New-Fixture fail_allow
        $null = Invoke-FixtureRunner $fixture @('Allow')
        $adbLog = Get-Content -LiteralPath (Join-Path $fixture.State 'adb.log') -Raw
        Assert-Contains $adbLog 'ime set com.original/.Ime'
        Assert-Contains $adbLog 'forward --remove tcp:8848'
        Assert-Contains $adbLog 'test-control.json'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.State 'test-control.json'))) '设备侧控制文件未清理。'
        Assert-Contains (Get-Content -LiteralPath (Join-Path $fixture.Repo 'configs\gateway-mcp.json') -Raw) 'original-config-marker'
    }

    Test-Case 'runner/provisioner 禁止 ADB UI 输入和确认决定字段' {
        $source = (Get-Content -LiteralPath $SourceRunner -Raw) + "`n" +
            (Get-Content -LiteralPath $SourceProvisioner -Raw) + "`n" +
            (Get-Content -LiteralPath $SourceHealthProbe -Raw)
        Assert-NotMatches $source '(?i)(input\s+(tap|text)|keyevent\s+(enter|home|keycode_home))'
        Assert-NotMatches $source '(?i)["'']decision["'']\s*:'
    }

    Test-Case '新增 PowerShell 脚本 AST 可解析' {
        foreach ($path in @($SourceRunner, $SourceProvisioner, $SourceHealthProbe, $PSCommandPath)) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            Assert-True ($errors.Count -eq 0) "$path 解析失败：$($errors | ForEach-Object Message -join '; ')"
        }
    }
}
finally {
    foreach ($root in $TestRoots) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n离线监督式 runner：$script:Passed passed, $script:Failed failed"
if ($script:Failed -gt 0) { exit 1 }
