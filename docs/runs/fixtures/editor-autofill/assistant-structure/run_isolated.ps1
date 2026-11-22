[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$TestbenchSdk,
    [Parameter(Mandatory)][string]$JavaHome,
    [int]$AdbServerPort = 5071,
    [int]$ConsolePort = 5604,
    [int]$RuntimeSeconds = 780,
    [int]$BootTimeoutSeconds = 240,
    [switch]$SkipControls,
    [switch]$KeepAvd
)

$ErrorActionPreference = 'Stop'
$encoding = [Text.UTF8Encoding]::new($false)

if ($AdbServerPort -eq 5037) { throw 'refusing_default_adb_port_5037' }
if ($ConsolePort -lt 5554 -or ($ConsolePort % 2) -ne 0) { throw 'invalid_console_port' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'output_directory_already_exists' }

$fixtureDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $fixtureDir '../../../../..')).Path
$buildRoot = (Resolve-Path $BuildDir).Path
$sdkRoot = (Resolve-Path $TestbenchSdk).Path
$jdkRoot = (Resolve-Path $JavaHome).Path

$verifier = Join-Path $repoRoot 'docs/runs/fixtures/editor-autofill/verify_right_first.py'
$benchScript = Join-Path $repoRoot 'scripts/run-local-testbench.ps1'
$adb = Join-Path $sdkRoot 'platform-tools/adb.exe'
$emulatorExe = Join-Path $sdkRoot 'emulator/emulator.exe'
$manager = Join-Path $sdkRoot 'cmdline-tools/latest/bin/avdmanager.bat'

foreach ($required in @($verifier, $benchScript, $adb, $emulatorExe, $manager,
        (Join-Path $buildRoot 'hashes.json'), (Join-Path $buildRoot 'target.apk'), (Join-Path $buildRoot 'observer.apk'))) {
    if (-not (Test-Path -LiteralPath $required)) { throw "missing_required_input:$required" }
}

$output = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$original = $output
$clock = [Diagnostics.Stopwatch]::StartNew()
$ports = @($AdbServerPort, $ConsolePort, ($ConsolePort + 1))
$serial = "emulator-$ConsolePort"
$nonce = [guid]::NewGuid().ToString('N').Substring(0, 12)
$avdName = "assist-a2-$nonce"
$server = $null
$emulator = $null
$verified = $false
$commandIndex = 0

$target = 'dev.magina.autofilltarget'
$observer = 'dev.magina.autofillobserver'
$ime = "$observer/.ProbeIme"
$service = "$observer/.ProbeAutofillService"
$AssistantRole = 'android.app.role.ASSISTANT'

$keys = [ordered]@{
    default_input_method        = 'secure'
    enabled_input_methods       = 'secure'
    autofill_service            = 'secure'
    immersive_mode_confirmations = 'secure'
    airplane_mode_on            = 'global'
    wifi_on                     = 'global'
    accelerometer_rotation      = 'system'
    user_rotation               = 'system'
    assistant                   = 'secure'
    voice_interaction_service   = 'secure'
    voice_recognition_service   = 'secure'
    assist_structure_enabled    = 'secure'
    assist_screenshot_enabled   = 'secure'
}

$summary = [ordered]@{
    serial                    = $serial
    avd_name                  = $avdName
    server_port               = $AdbServerPort
    console_port              = $ConsolePort
    disable_usb               = $true
    disable_mdns              = $true
    initially_empty           = $null
    api                       = $null
    hardware                  = $null
    assistant_holder_before   = $null
    assistant_role_during     = $null
    assistant_holder_after    = $null
    assistant_role_restored   = $null
    status                    = 'running'
    cleanup                   = $null
    cleanup_errors            = @()
}

function Save-State([string]$Phase) {
    $summary.phase = $Phase
    $summary.elapsed_seconds = [int]$clock.Elapsed.TotalSeconds
    [IO.File]::WriteAllText((Join-Path $output 'state.json'), ($summary | ConvertTo-Json -Depth 10) + "`n", $encoding)
    Write-Host "$Phase $($summary.elapsed_seconds)s"
}

$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($benchScript, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'runner_parse_error' }
$benchFunctions = @(
    'Assert-Bench', 'Assert-BenchRemaining', 'Start-BenchProcess', 'Save-BenchProcess',
    'Invoke-BenchNative', 'Get-BenchPortListeners', 'Assert-BenchOwnedServer',
    'Invoke-BenchAdb', 'Get-BenchDeviceRows'
)
foreach ($fnName in $benchFunctions) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $fnName }, $true)
    if (-not $node) { throw "missing_runner_function:$fnName" }
    . ([scriptblock]::Create($node.Extent.Text))
}

function Call-Guest([string[]]$Words, [string]$Label, [int]$TimeoutSeconds = 30) {
    return Invoke-BenchAdb (@('shell') + $Words) $Label $TimeoutSeconds
}

function Read-Setting([string]$Key) {
    return Call-Guest @('settings', 'get', $keys[$Key], $Key) "get-$Key"
}

function Set-Setting([string]$Key, [string]$Value) {
    if ($Value -ceq 'null') {
        [void](Call-Guest @('settings', 'delete', $keys[$Key], $Key) "delete-$Key")
    } else {
        Assert-Bench ($Value -notmatch "['\r\n]") 'unsupported_setting_characters'
        $put = "settings put $($keys[$Key]) $Key '$Value'"
        [void](Invoke-BenchAdb @('shell', $put) "put-$Key")
    }
}

function Read-AssistantHolder([string]$Label = 'assistant-holder') {
    Assert-Bench ($AssistantRole -ceq 'android.app.role.ASSISTANT') 'assistant_role_constant_corrupted'
    return Call-Guest @('cmd', 'role', 'get-role-holders', '--user', '0', $AssistantRole) $Label
}

function Read-AssistLog([string]$Label = 'assist-log') {
    return Call-Guest @(
        'logcat', '-b', 'main', '-b', 'system', '-d', '-v', 'monotonic', '-s',
        'SyntheticAssist:I', 'AssistTarget:I', 'SyntheticProbeIme:I',
        'VoiceInteractionManagerService:W', 'VoiceInteractionSession:W'
    ) $Label
}

function Get-Fixture([string]$Pkg, [string]$Name) {
    $dirs = (Call-Guest @('run-as', $Pkg, 'ls', '-1', '.') 'private-dirs') -split '\s+'
    if ($dirs -cnotcontains 'files') { return 'ABSENT' }
    $entries = (Call-Guest @('run-as', $Pkg, 'ls', '-1', 'files') "list-$Name") -split '\s+'
    if ($entries -cnotcontains $Name) { return 'ABSENT' }
    return Invoke-BenchAdb @('exec-out', 'run-as', $Pkg, 'cat', "files/$Name") "read-$Name"
}

function Wait-Fixture([string]$Pkg, [string]$Name, [int]$TimeoutSeconds = 30) {
    $limit = $clock.Elapsed.TotalSeconds + $TimeoutSeconds
    do {
        $raw = Get-Fixture $Pkg $Name
        if ($raw -cne 'ABSENT') { return $raw }
        Start-Sleep -Milliseconds 350
    } while ($clock.Elapsed.TotalSeconds -lt $limit)
    throw "no_fixture_${Pkg}_$Name"
}

function Set-Stage([int]$Stage) {
    $markerCommand = "run-as $observer sh -c 'echo $Stage > files/natural-stage'"
    [void](Invoke-BenchAdb @('shell', $markerCommand) "stage-$Stage")
    Assert-Bench ((Get-Fixture $observer 'natural-stage') -ceq "$Stage") 'stage_readback'
    $script:stageOpenedMs = $clock.ElapsedMilliseconds
}

function Select-Ime([string]$Id) {
    [void](Call-Guest @('ime', 'set', $Id) 'select-ime')
    Assert-Bench ((Read-Setting 'default_input_method') -ceq $Id) 'selected_ime_readback'
}

function Save-Text([string]$Dir, [string]$Name, [string]$Str) {
    [IO.File]::WriteAllText((Join-Path $Dir $Name), $Str, $encoding)
}

function Get-LatestImeAnchor {
    $imeLog = Call-Guest @('logcat', '-d', '-v', 'threadtime', '-s', 'SyntheticProbeIme:I') 'latest-ime-log'
    $matches = [regex]::Matches($imeLog, 'SyntheticProbeIme\s*:\s+generation=(\d+)\s+started=(\d+)')
    Assert-Bench ($matches.Count -ge 1) 'no_ime_anchor_found'
    $last = $matches[$matches.Count - 1]
    return [pscustomobject]@{
        Generation = [int]$last.Groups[1].Value
        StartedMs  = [long]$last.Groups[2].Value
        RawLog     = $imeLog
    }
}

function Invoke-AssistPhase([string]$StageName, [int]$Generation, [long]$StartedMs, [string]$DestDir, [switch]$ProfileTarget) {
    Save-State "request_$StageName"
    if ($ProfileTarget) {
        [void](Call-Guest @('am', 'profile', 'start', '--clock-type', 'wall', $target, "/data/local/tmp/$StageName.trace") "profile-$StageName")
    }
    $cmd = "$StageName $Generation $StartedMs"
    Assert-Bench ($cmd -match '^(assist|noflag|secure|ccoptout|obfuscated|multiwin|multiwin2) \d+ \d+$') 'invalid_assist_anchor'
    [void](Invoke-BenchAdb @('shell', "run-as $observer sh -c 'echo $cmd > files/assist-pending && mv files/assist-pending files/assist-command'") "arm-$StageName")
    Start-Sleep -Milliseconds 600
    try {
        $winFocus = Invoke-BenchAdb @('shell', "dumpsys window | grep -E 'mCurrentFocus=|mFocusedApp='") "window-$StageName"
    } catch {
        $winFocus = 'window_focus_read_unavailable'
    }
    Save-Text $DestDir "focus-$StageName.txt" $winFocus
    $limit = $clock.Elapsed.TotalSeconds + 25
    $raw = 'ABSENT'
    $logs = ''
    do {
        $raw = Get-Fixture $observer "assist-$StageName.json"
        $logs = Read-AssistLog "poll-log-$StageName"
        if ($raw -cne 'ABSENT' -and $logs -match "session_destroyed $StageName") { break }
        if ($logs -match "command_rejected $StageName|session_show_failed $StageName|receipt_failed $StageName") { break }
        Start-Sleep -Milliseconds 400
    } while ($clock.Elapsed.TotalSeconds -lt $limit)
    # Allow TargetActivity binder thread to finish logging post-probe (-4) before capturing final log/trace.
    Start-Sleep -Milliseconds 600
    $logs = Read-AssistLog "final-log-$StageName"
    Save-Text $DestDir "assist-$StageName.json" $raw
    Save-Text $DestDir 'assist.log' $logs
    if ($ProfileTarget) {
        [void](Call-Guest @('am', 'profile', 'stop', $target) "stop-profile-$StageName")
        Start-Sleep -Milliseconds 750
        [void](Invoke-BenchAdb @('pull', "/data/local/tmp/$StageName.trace", (Join-Path $DestDir "$StageName.trace")) "pull-$StageName")
    }
    [void](Call-Guest @('dumpsys', 'activity', $target) "focus-after-$StageName")
    if ($raw -ceq 'ABSENT' -or $logs -notmatch "session_destroyed $StageName") {
        throw "no_complete_assistant_result_$StageName"
    }
    return ($raw | ConvertFrom-Json)
}

function Capture-A2Case([string]$Dir, [int]$Stage) {
    $oracle = Wait-Fixture $target 'oracle.json' 30
    Save-Text $Dir 'oracle.json' $oracle
    $oracleReadMs = $clock.ElapsedMilliseconds
    Start-Sleep -Seconds 6
    $raw = Get-Fixture $observer "natural-$Stage.json"
    $closeMs = $clock.ElapsedMilliseconds
    Save-Text $Dir 'observation.json' (@{
        marker_readback_ms = $script:stageOpenedMs
        oracle_read_ms     = $oracleReadMs
        journal_read_ms    = $closeMs
        window_ms          = ($closeMs - $script:stageOpenedMs)
        after_oracle_ms    = ($closeMs - $oracleReadMs)
    } | ConvertTo-Json)
    Save-Text $Dir 'journal-read.txt' $raw
    if ($raw -ceq 'ABSENT') {
        $raw = @{
            stage            = $Stage
            callback_count   = 0
            terminal_count   = 0
            samples          = @()
            host_observation = 'journal_absent_at_close'
        } | ConvertTo-Json
    }
    Save-Text $Dir 'ledger.json' $raw
    $log = Call-Guest @('logcat', '-d', '-v', 'threadtime', '-s', 'SyntheticProbeIme:I', 'AutofillObserver:W') 'ime-log'
    Save-Text $Dir 'ime.txt' $log
    Assert-Bench ($log -notmatch 'NATURAL_RECEIPT_WRITE_FAILED') 'receipt_write_failure'
    Assert-Bench ((Get-Fixture $observer 'natural-stage') -ceq "$Stage") 'unstable_marker'
    $verdict = & python -B $verifier $Dir
    Assert-Bench ($LASTEXITCODE -eq 0) 'host_verification_failed'
    Save-Text $Dir 'verdict.json' ($verdict -join [Environment]::NewLine)
    return ($verdict -join '' | ConvertFrom-Json)
}

$baseline = [ordered]@{}
$restored = [ordered]@{}
$installed = @()
$baselineComplete = $false
$roleTouched = $false
$originalHolder = $null

try {
    foreach ($dir in 'home', 'tmp', 'avd-home', 'home/AppData/Local', 'home/AppData/Roaming') {
        [void](New-Item -ItemType Directory -Path (Join-Path $output $dir) -Force)
    }
    $childHome = Join-Path $original 'home'
    $childDrive = [IO.Path]::GetPathRoot($childHome).TrimEnd('\', '/')
    $childEnvironment = @{
        JAVA_HOME                = $jdkRoot
        ANDROID_HOME             = $sdkRoot
        ANDROID_SDK_ROOT         = $sdkRoot
        ANDROID_USER_HOME        = $childHome
        ANDROID_EMULATOR_HOME    = $childHome
        ANDROID_AVD_HOME         = (Join-Path $original 'avd-home')
        HOME                     = $childHome
        USERPROFILE              = $childHome
        HOMEDRIVE                = $childDrive
        HOMEPATH                 = $childHome.Substring($childDrive.Length)
        LOCALAPPDATA             = (Join-Path $childHome 'AppData/Local')
        APPDATA                  = (Join-Path $childHome 'AppData/Roaming')
        TEMP                     = (Join-Path $output 'tmp')
        TMP                      = (Join-Path $output 'tmp')
        JAVA_TOOL_OPTIONS        = ('-Duser.home="' + $childHome + '" -Djava.io.tmpdir="' + (Join-Path $output 'tmp') + '"')
        ANDROID_ADB_SERVER_PORT  = "$AdbServerPort"
        ADB_SERVER_SOCKET        = "tcp:127.0.0.1:$AdbServerPort"
        ADB_USB                  = '0'
        ADB_MDNS                 = '0'
        ADB_EMU                  = '1'
    }

    Save-State 'admission'
    Assert-Bench (@(Get-BenchPortListeners $ports).Count -eq 0) 'ports_occupied'
    $acceleration = Invoke-BenchNative $emulatorExe @('-accel-check') 'acceleration' 20
    Assert-Bench ($acceleration -match '(?m)^0\s*$') 'no_acceleration'
    $freeMb = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
    Assert-Bench ($freeMb -ge 4096) 'not_enough_memory'
    $summary.available_memory_mb = $freeMb

    Save-State 'create_fresh_avd'
    $childEnvironment.JAVA_TOOL_OPTIONS += ' -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=9 -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=9'
    [void](Invoke-BenchNative $manager @('create', 'avd', '--name', $avdName, '--package', 'system-images;android-36;google_apis;x86_64', '--device', 'pixel_5', '--path', (Join-Path $output 'avd')) 'create-avd' 120 "no`n")
    Assert-Bench (Test-Path -LiteralPath (Join-Path $original 'avd/config.ini')) 'own_avd_missing'

    Save-State 'isolated_server'
    $server = Start-BenchProcess $adb @('-L', "tcp:$AdbServerPort", '--one-device', ("synthetic-exclude-usb-$nonce"), 'server', 'nodaemon')
    $summary.server_pid = $server.Process.Id
    foreach ($i in 1..30) {
        if (@(Get-BenchPortListeners @($AdbServerPort)).Count) { break }
        Assert-Bench (-not $server.Process.HasExited) 'server_start'
        Start-Sleep -Milliseconds 200
    }
    Assert-BenchOwnedServer
    $table = Invoke-BenchAdb @('devices') 'empty-device-table' 10
    Assert-Bench (@(Get-BenchDeviceRows $table).Count -eq 0) 'not_empty'
    $summary.initially_empty = $true

    Save-State 'boot'
    $emulator = Start-BenchProcess $emulatorExe @('-avd', $avdName, '-ports', "$ConsolePort,$($ConsolePort + 1)", '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-memory', '2048', '-gpu', 'software', '-no-metrics')
    $summary.emulator_pid = $emulator.Process.Id
    $bootLimit = $clock.Elapsed.TotalSeconds + $BootTimeoutSeconds
    do {
        Assert-Bench (-not $emulator.Process.HasExited) 'emulator_exited'
        $rows = @(Get-BenchDeviceRows (Invoke-BenchAdb @('devices') 'isolated-devices' 10))
        Assert-Bench (@($rows | Where-Object { $_ -cnotmatch ('^' + $serial + '\s+(device|offline|unauthorized)\b') }).Count -eq 0) 'foreign_transport'
        if ($rows -match ('^' + $serial + '\s+device\b')) {
            if ((Invoke-BenchAdb @('shell', 'getprop', 'sys.boot_completed') 'boot-complete' 10) -ceq '1') { break }
        }
        Start-Sleep -Seconds 2
    } while ($clock.Elapsed.TotalSeconds -lt $bootLimit)
    Assert-Bench ($clock.Elapsed.TotalSeconds -lt $bootLimit) 'boot_timeout'

    $actualAvd = (Invoke-BenchAdb @('emu', 'avd', 'name') 'identity' 10) -split '[\r\n]+'
    $summary.api = Invoke-BenchAdb @('shell', 'getprop', 'ro.build.version.sdk') 'api' 10
    $summary.hardware = Invoke-BenchAdb @('shell', 'getprop', 'ro.kernel.qemu') 'qemu' 10
    Assert-Bench ($actualAvd[0] -ceq $avdName -and $summary.api -ceq '36' -and $summary.hardware -ceq '1') 'avd_identity'
    $verified = $true

    Save-State 'baseline_and_install'
    try {
        foreach ($k in $keys.Keys) { $baseline[$k] = Read-Setting $k }
        $summary.baseline = $baseline
        $originalHolder = Read-AssistantHolder 'assistant-holder-before'
        Assert-Bench ($originalHolder -ceq '' -or $originalHolder -cmatch '^[a-zA-Z][\w.]+$') 'ambiguous_assistant_holder'
        $summary.assistant_holder_before = $originalHolder
        Assert-Bench ($baseline.default_input_method -match '^[\w.]+/[\w.]+$' -and $baseline.enabled_input_methods -ne 'null') 'stock_ime_unknown'
        $baselineComplete = $true

        [void](Call-Guest @('cmd', 'connectivity', 'airplane-mode', 'enable') 'offline')
        [void](Call-Guest @('svc', 'wifi', 'disable') 'wifi-off')
        Assert-Bench ((Read-Setting 'airplane_mode_on') -ceq '1' -and (Read-Setting 'wifi_on') -ceq '0') 'not_offline'
        Set-Setting 'immersive_mode_confirmations' 'confirmed'
        Set-Setting 'accelerometer_rotation' '0'
        Set-Setting 'user_rotation' '1'

        $hashes = Get-Content -LiteralPath (Join-Path $buildRoot 'hashes.json') -Raw | ConvertFrom-Json
        $summary.uids = [ordered]@{}
        $summary.apk = [ordered]@{}
        foreach ($apkKind in @('target', 'observer')) {
            $pkg = if ($apkKind -ceq 'target') { $target } else { $observer }
            Assert-Bench ((Call-Guest @('pm', 'list', 'packages', '-u', $pkg) "absent-$apkKind") -ceq '') 'package_present'
            $apk = Join-Path $buildRoot "$apkKind.apk"
            Assert-Bench ((Get-FileHash -LiteralPath $apk).Hash -ieq $hashes.$apkKind) "host_hash_$apkKind"
            Assert-Bench ((Invoke-BenchAdb @('install', $apk) "install-$apkKind" 90) -match 'Success') "install_$apkKind"
            $installed += $pkg
            $installedPath = Call-Guest @('pm', 'path', $pkg) "installed-path-$apkKind"
            Assert-Bench ($installedPath -cmatch '^package:/[^\r\n]+/base\.apk$') 'invalid_apk_path'
            $installedHash = (Call-Guest @('sha256sum', $installedPath.Substring(8)) "installed-sha-$apkKind") -split '\s+'
            Assert-Bench ($installedHash[0] -ceq $hashes.$apkKind) "installed_hash_$apkKind"
            $summary.apk[$apkKind] = $installedHash[0]
            $summary.uids[$apkKind] = Call-Guest @('run-as', $pkg, 'id', '-u') "uid-$apkKind"
        }
        Assert-Bench ($summary.uids.target -match '^\d+$' -and $summary.uids.observer -match '^\d+$' -and $summary.uids.target -cne $summary.uids.observer) 'uid_mismatch'
        [void](Call-Guest @('run-as', $observer, 'mkdir', '-p', 'files') 'observer-files')

        Save-State 'select_assistant'
        Assert-Bench ($AssistantRole -ceq 'android.app.role.ASSISTANT' -and (Read-AssistantHolder 'assistant-holder-preselect') -ceq $originalHolder) 'role_changed_before_selection'
        $roleTouched = $true
        [void](Call-Guest @('cmd', 'role', 'add-role-holder', '--user', '0', $AssistantRole, $observer, '0') 'select-assistant')
        $duringHolder = Read-AssistantHolder 'assistant-holder-during'
        $summary.assistant_role_during = $duringHolder
        Assert-Bench ($duringHolder -ceq $observer) 'assistant_role_not_selected'

        $limit = $clock.Elapsed.TotalSeconds + 25
        $voice = ''
        $logs = ''
        do {
            $voice = Read-Setting 'voice_interaction_service'
            $logs = Read-AssistLog 'poll-service-ready'
            if ($voice -cmatch '^dev\.magina\.autofillobserver/(\.AssistService|dev\.magina\.autofillobserver\.AssistService)$' -and $logs -match 'service_ready') { break }
            Start-Sleep -Milliseconds 500
        } while ($clock.Elapsed.TotalSeconds -lt $limit)
        Assert-Bench ($voice -match 'autofillobserver/.+AssistService' -and $logs -match 'service_ready') 'assistant_not_bound'
        $summary.voice_during = $voice
        $summary.assistant_during = Read-Setting 'assistant'
        $summary.voice_recognition_during = Read-Setting 'voice_recognition_service'

        [void](Call-Guest @('ime', 'enable', $ime) 'enable-ime')
        Set-Setting 'autofill_service' $service
        Assert-Bench ((Read-Setting 'autofill_service') -ceq $service) 'autofill_readback'
        Start-Sleep -Seconds 2

        # --- Phase 1: Core A2 (already-focused anonymous EditText across IME switch) ---
        $a2 = (New-Item -ItemType Directory -Path (Join-Path $output 'A2')).FullName
        foreach ($pair in @(@($observer, 'natural-1.json'), @($observer, 'natural-2.json'), @($target, 'oracle.json'), @($target, 'right-ready.json'))) {
            Assert-Bench ((Get-Fixture $pair[0] $pair[1]) -ceq 'ABSENT') 'old_a2_receipt'
        }
        Set-Stage 1
        Save-State 'A2_right_before_switch'
        [void](Call-Guest @('am', 'start', '-n', "$target/.TargetActivity", '--es', 'scenario', 'automatic-right-switch') 'start-a2')
        Save-Text $a2 'right-ready.json' (Wait-Fixture $target 'right-ready.json' 30)
        Assert-Bench ((Read-Setting 'default_input_method') -ceq $baseline.default_input_method) 'stock_ime_before_switch'
        Start-Sleep -Seconds 2
        Save-Text $a2 'pre-switch-journal.txt' (Get-Fixture $observer 'natural-1.json')
        Set-Stage 2
        Save-State 'A2_switch'
        Select-Ime $ime
        $summary.A2 = Capture-A2Case $a2 2
        [void](Call-Guest @('dumpsys', 'activity', $target) 'focus-before-assist')
        foreach ($phase in @('assist', 'noflag')) {
            $parsed = Invoke-AssistPhase -StageName $phase -Generation ([int]$summary.A2.generation) -StartedMs ([long]$summary.A2.ime_started_ms) -DestDir $a2 -ProfileTarget
            if (-not $parsed.current_at_close) {
                $summary.assist_stop = 'connection_lost'
                break
            }
        }
        $summary.autofill_after_assist = Get-Fixture $observer 'natural-2.json'

        # Close natural-stage marker so extra controls do not pollute natural-2.json
        [void](Invoke-BenchAdb @('shell', "run-as $observer rm -f files/natural-stage") 'clear-natural-stage')

        # --- Phases 2..5: Adversarial Controls (FLAG_SECURE, IMPORTANT_FOR_CONTENT_CAPTURE, a11y obfuscation, 2-window landscape) ---
        if (-not $SkipControls) {
            $controlsRoot = (New-Item -ItemType Directory -Path (Join-Path $output 'controls')).FullName
            $summary.controls_run = @()

            # Control 2A/2B/2C: TargetActivity with extra flags
            $singleControls = @(
                @{ Name = 'secure';     Extra = @('--ez', 'secure', 'true') },
                @{ Name = 'ccoptout';   Extra = @('--ez', 'cc_optout', 'true') },
                @{ Name = 'obfuscated'; Extra = @('--ez', 'a11y_obfuscate', 'true') }
            )
            foreach ($ctrl in $singleControls) {
                $cName = $ctrl.Name
                $cDir = (New-Item -ItemType Directory -Path (Join-Path $controlsRoot $cName)).FullName
                [void](Call-Guest @('am', 'force-stop', $target) "stop-before-$cName")
                [void](Invoke-BenchAdb @('shell', "run-as $target rm -f files/oracle.json files/oracle.tmp files/right-ready.json") "clean-target-$cName")
                [void](Invoke-BenchAdb @('shell', "run-as $observer rm -f files/assist-$cName.json files/assist-$cName.tmp") "clean-obs-$cName")
                Start-Sleep -Milliseconds 400
                [void](Call-Guest (@('am', 'start', '-n', "$target/.TargetActivity", '--es', 'scenario', 'automatic-right') + $ctrl.Extra) "start-$cName")
                Save-Text $cDir 'oracle.json' (Wait-Fixture $target 'oracle.json' 25)
                Start-Sleep -Milliseconds 500
                $anchor = Get-LatestImeAnchor
                Save-Text $cDir 'ime.txt' $anchor.RawLog
                [void](Invoke-AssistPhase -StageName $cName -Generation $anchor.Generation -StartedMs $anchor.StartedMs -DestDir $cDir)
                $summary.controls_run += $cName
            }

            # Control 3A: Two OS windows in 1 Activity (SplitWindowActivity: main left + focusable dialog right)
            $mwDir = (New-Item -ItemType Directory -Path (Join-Path $controlsRoot 'multiwin')).FullName
            [void](Call-Guest @('am', 'force-stop', $target) 'stop-before-multiwin')
            [void](Invoke-BenchAdb @('shell', "run-as $target rm -f files/multiwin-dialog.json files/multiwin-dialog.tmp") 'clean-target-multiwin')
            [void](Invoke-BenchAdb @('shell', "run-as $observer rm -f files/assist-multiwin.json files/assist-multiwin.tmp") 'clean-obs-multiwin')
            Start-Sleep -Milliseconds 400
            [void](Call-Guest @('am', 'start', '-n', "$target/.SplitWindowActivity") 'start-multiwin')
            Save-Text $mwDir 'multiwin-dialog.json' (Wait-Fixture $target 'multiwin-dialog.json' 25)
            Start-Sleep -Milliseconds 500
            $anchor = Get-LatestImeAnchor
            Save-Text $mwDir 'ime.txt' $anchor.RawLog
            [void](Invoke-AssistPhase -StageName 'multiwin' -Generation $anchor.Generation -StartedMs $anchor.StartedMs -DestDir $mwDir)
            $summary.controls_run += 'multiwin'

            # Control 3B: Two separate same-package Activities in 2 tasks (LeftPaneActivity + translucent RightPaneActivity)
            $mw2Dir = (New-Item -ItemType Directory -Path (Join-Path $controlsRoot 'multiwin2')).FullName
            [void](Call-Guest @('am', 'force-stop', $target) 'stop-before-multiwin2')
            [void](Invoke-BenchAdb @('shell', "run-as $target rm -f files/pane-left.json files/pane-right.json files/pane-left.tmp files/pane-right.tmp") 'clean-target-multiwin2')
            [void](Invoke-BenchAdb @('shell', "run-as $observer rm -f files/assist-multiwin2.json files/assist-multiwin2.tmp") 'clean-obs-multiwin2')
            Start-Sleep -Milliseconds 400
            [void](Call-Guest @('am', 'start', '-n', "$target/.LeftPaneActivity") 'start-pane-left')
            Save-Text $mw2Dir 'pane-left.json' (Wait-Fixture $target 'pane-left.json' 25)
            [void](Call-Guest @('am', 'start', '-f', '0x18000000', '-n', "$target/.RightPaneActivity") 'start-pane-right')
            Save-Text $mw2Dir 'pane-right.json' (Wait-Fixture $target 'pane-right.json' 25)
            Start-Sleep -Milliseconds 500
            $anchor = Get-LatestImeAnchor
            Save-Text $mw2Dir 'ime.txt' $anchor.RawLog
            [void](Invoke-AssistPhase -StageName 'multiwin2' -Generation $anchor.Generation -StartedMs $anchor.StartedMs -DestDir $mw2Dir)
            $summary.controls_run += 'multiwin2'
        }

        $summary.status = 'observed'
    } finally {
        $cleanupErrors = @()
        if ($roleTouched) {
            try {
                [void](Call-Guest @('logcat', '-d', '-v', 'brief', '-s', 'RoleControllerServiceImpl:W', 'AssistantRoleBehavior:W', 'RoleManagerService:W', 'VoiceInteractionManagerService:W', 'SyntheticAssist:I') 'role-diagnostics')
            } catch {}
        }
        if ($baselineComplete) {
            # Step 1: Restore ASSISTANT role BEFORE uninstalling observer so VIMS transitions cleanly back to baseline.
            if ($roleTouched) {
                try {
                    Assert-Bench ($AssistantRole -ceq 'android.app.role.ASSISTANT') 'assistant_role_constant_corrupted'
                    if ($originalHolder) {
                        [void](Call-Guest @('cmd', 'role', 'add-role-holder', '--user', '0', $AssistantRole, $originalHolder, '0') 'restore-assistant-role')
                    } else {
                        [void](Call-Guest @('cmd', 'role', 'remove-role-holder', '--user', '0', $AssistantRole, $observer, '0') 'remove-assistant-role')
                    }
                    $restoreLimit = $clock.Elapsed.TotalSeconds + 10
                    do {
                        $curHolder = Read-AssistantHolder 'poll-holder-restore'
                        $curVoice = Read-Setting 'voice_interaction_service'
                        if ($curHolder -ceq $originalHolder -and $curVoice -ceq $baseline.voice_interaction_service) { break }
                        Start-Sleep -Milliseconds 400
                    } while ($clock.Elapsed.TotalSeconds -lt $restoreLimit)
                } catch {
                    $cleanupErrors += $_.Exception.Message
                }
            }

            # Step 2: Stop target, restore IME and autofill, disable experimental IME.
            foreach ($cleanupAction in @(
                { if ($installed -contains $target) { [void](Call-Guest @('am', 'force-stop', $target) 'stop-target') } },
                { Select-Ime $baseline.default_input_method },
                { Set-Setting 'autofill_service' $baseline.autofill_service },
                { if ($installed -contains $observer) { [void](Call-Guest @('ime', 'disable', $ime) 'disable-ime') } }
            )) {
                try { & $cleanupAction } catch { $cleanupErrors += $_.Exception.Message }
            }

            # Step 3: Uninstall experimental packages and verify absent.
            foreach ($pkg in $installed) {
                try {
                    Assert-Bench ((Invoke-BenchAdb @('uninstall', $pkg) "uninstall-$pkg" 35) -match 'Success') "uninstall_failure_$pkg"
                    Assert-Bench ((Call-Guest @('pm', 'list', 'packages', '-u', $pkg) "uninstall-readback-$pkg") -ceq '') "package_remains_$pkg"
                } catch {
                    $cleanupErrors += $_.Exception.Message
                }
            }

            # Step 4: Explicitly restore display/IME/voice settings that may have drifted during role switch.
            foreach ($k in @('immersive_mode_confirmations', 'accelerometer_rotation', 'user_rotation', 'enabled_input_methods',
                             'voice_recognition_service', 'assistant', 'voice_interaction_service',
                             'assist_structure_enabled', 'assist_screenshot_enabled')) {
                try {
                    if ((Read-Setting $k) -cne $baseline[$k]) {
                        Set-Setting $k $baseline[$k]
                    }
                } catch {
                    $cleanupErrors += $_.Exception.Message
                }
            }

            # Step 5: Restore airplane mode and Wi-Fi.
            try {
                $flight = if ($baseline.airplane_mode_on -ceq '1') { 'enable' } else { 'disable' }
                [void](Call-Guest @('cmd', 'connectivity', 'airplane-mode', $flight) 'restore-airplane')
                $wifi = if ($baseline.wifi_on -ceq '1') { 'enable' } else { 'disable' }
                [void](Call-Guest @('svc', 'wifi', $wifi) 'restore-wifi')
                Start-Sleep -Seconds 2
            } catch {
                $cleanupErrors += $_.Exception.Message
            }

            # Step 6: UNCONDITIONAL final readback of ASSISTANT role holder + all 13 settings (never left unknown!).
            try {
                $finalHolder = Read-AssistantHolder 'assistant-holder-after'
                $summary.assistant_holder_after = $finalHolder
                $summary.assistant_role_restored = ($finalHolder -ceq $originalHolder)
                if (-not $summary.assistant_role_restored) { $cleanupErrors += 'assistant_holder_not_restored' }
            } catch {
                $summary.assistant_holder_after = $null
                $summary.assistant_role_restored = $false
                $cleanupErrors += ('final_holder_readback_' + $_.Exception.Message)
            }

            foreach ($k in $keys.Keys) {
                try { $restored[$k] = (Read-Setting $k) -ceq $baseline[$k] } catch { $restored[$k] = $false }
                if (-not $restored[$k]) { $cleanupErrors += "restore_failed_$k" }
            }
            $summary.restored = $restored
            $summary.cleanup_errors = $cleanupErrors
            if ($cleanupErrors.Count) { throw ($cleanupErrors -join ',') }
        }
    }
} catch {
    $summary.status = 'failed'
    $summary.error = $_.Exception.Message
    Write-Host "experiment_failed $($summary.error)"
} finally {
    if ($emulator) {
        if ($verified -and -not $emulator.Process.HasExited) {
            try { [void](Invoke-BenchAdb @('emu', 'kill') 'stop-owned-avd' 10) } catch {}
        }
        if (-not $emulator.Process.WaitForExit(15000)) {
            $emulator.Process.Kill($true)
            $emulator.Process.WaitForExit()
        }
        [void](Save-BenchProcess $emulator 'emulator')
        $emulator.Process.Dispose()
    }
    if ($server) {
        if (-not $server.Process.HasExited) {
            $server.Process.Kill($true)
            $server.Process.WaitForExit()
        }
        [void](Save-BenchProcess $server 'isolated-adb-server')
        $server.Process.Dispose()
    }
    if (-not $KeepAvd) {
        foreach ($avdPath in @((Join-Path $output 'avd'), (Join-Path $output 'avd-home'))) {
            if (Test-Path -LiteralPath $avdPath) {
                try { Remove-Item -LiteralPath $avdPath -Recurse -Force -ErrorAction Stop } catch {}
            }
        }
    }
    $remaining = @(Get-BenchPortListeners $ports)
    $avdCleaned = $KeepAvd -or ((-not (Test-Path -LiteralPath (Join-Path $output 'avd'))) -and (-not (Test-Path -LiteralPath (Join-Path $output 'avd-home'))))
    $summary.cleanup = [ordered]@{
        ports_released          = ($remaining.Count -eq 0)
        emulator_stopped        = $true
        isolated_server_stopped = $true
        avd_cleaned             = $avdCleaned
    }
    Save-State 'closed'
}

if ($summary.status -cne 'observed' -or -not $summary.cleanup.ports_released) { exit 1 }
