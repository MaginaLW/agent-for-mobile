#Requires -Version 7.5
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SummaryPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = [IO.Path]::GetFullPath((Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
$LibraryPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1'
$T0SidecarPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a-t0-adb-sidecar.ps1'
$T0SidecarCmdPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a-t0-adb-sidecar.cmd'
$RunnerPath = Join-Path $RepoRoot 'scripts\run-tablet-layout-c1a.ps1'
$ValidatorPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-v2-validator.ps1'
$PublicValidatorPath = Join-Path $RepoRoot 'scripts\validate-tablet-layout-observation-v2.ps1'
$SidecarSchemaPath = Join-Path $RepoRoot 'docs\contracts\tablet-layout-c1a-sidecar-v1.schema.json'
$FixtureObservationPath = Join-Path $RepoRoot 'scripts\tests\fixtures\tablet-layout-observation\v2\native-multi-landscape.json'
$FixtureT0Path = Join-Path $RepoRoot 'scripts\tests\fixtures\tablet-layout-observation\v2\upstream-t0-v5.json'
$PwshPath = (Get-Process -Id $PID).Path
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('tablet-c1a-offline-' + [guid]::NewGuid().ToString('N'))
$script:Results = [Collections.Generic.List[object]]::new()
$script:Failed = 0
$script:RequiredCoverage = [string[]]@(
    'entry_absolute_adb', 'entry_full_sha', 'entry_explicit_provision', 'head_clean_exact',
    'clean_port_blob_attest', 'fresh_build_challenge', 'gradle_kotlin_cache_ignored', 'single_device', 'post_discovery_serial',
    'install_once_no_retry', 'apk_hash_binding', 'apksigner_certificate', 'package_version_binding',
    'embedded_head_challenge', 'a11y_needs_user_no_mutation', 'content_protocol_exact',
    'content_nonce_constant', 'title_hash_exact', 't0_raw_bytes_unchanged', 'capture_exact_c1_c2',
    'capture_host_wait_900', 'capture_span_15s', 'no_recapture', 'result_single_consume',
    'abort_cleanup', 'device_binding_pre_post', 'safe_atomic_evidence', 'trusted_runtime_validator',
    'public_runtime_unavailable', 'claim_scope_false', 'privacy_no_raw_secret', 'argv_allowlist',
    'content_remote_shell_literal', 'content_t0_binary_stdin', 'content_stderr_empty', 'stdin_overall_deadline',
    'installed_host_stream_pre_post', 'installed_stderr_cap_after_eof', 'installed_path_closed', 'post_apk_binding',
    'control_json_types_exact', 'a11y_bound_wait_vivo', 'implementation_hash_postcheck',
    'published_evidence_postcheck', 't0_sidecar_stderr_empty', 'release_absence_gate'
)

function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Assert-Equal { param($Actual,$Expected,[string]$Message) if ($Actual -cne $Expected) { throw "$Message (actual=$Actual expected=$Expected)" } }
function Test-Case {
    param([Parameter(Mandatory)][string]$Name,[string[]]$Covers=@(),[Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body
        $script:Results.Add([ordered]@{ name=$Name; status='passed'; covers=@($Covers); error=$null })
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        $script:Results.Add([ordered]@{ name=$Name; status='failed'; covers=@($Covers); error=$_.Exception.Message })
        Write-Host "FAIL $Name：$($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-ControlJson {
    param(
        [string]$RunId='tl1-c1a-test', [string]$State='awaiting_c1', [string]$Next='capture_c1',
        $CaptureToken=$null, [string]$Commit=('a' * 40), [string]$Artifact=('sha256:' + ('b' * 64)),
        [string]$Challenge='c1a-test-challenge-20260826'
    )
    return [ordered]@{
        schema='tablet-c1a-control/v1'; ok=$true; run_id=$RunId; state=$State; next=$Next
        reason_code=$null; capture_token=$CaptureToken; producer_commit_sha=$Commit
        producer_artifact_sha256=$Artifact
        provider=[ordered]@{
            authority='dev.magina.gateway.tablet.c1a'; protocol_version='1'; package_name='dev.magina.gateway'
            version_name='0.1.0-m1a'; version_code=1; embedded_git_head=$Commit
            build_challenge=$Challenge; a11y_service_ready=$true
        }
    } | ConvertTo-Json -Depth 8 -Compress
}

function Set-FixtureFile {
    param([string]$Path,[string]$Value)
    $directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    Set-Content -LiteralPath $Path -Value $Value -Encoding utf8NoBOM -NoNewline
}

function New-FakeTools {
    $root = Join-Path $TestRoot ([guid]::NewGuid().ToString('N'))
    $state = Join-Path $root 'state'
    $bin = Join-Path $root 'bin'
    $sdk = Join-Path $root 'sdk'
    New-Item -ItemType Directory -Force -Path $state,$bin,(Join-Path $sdk 'build-tools\99.0.0') | Out-Null
    $fakeAdbPs1 = Join-Path $bin 'fake-adb.ps1'
    Set-FixtureFile $fakeAdbPs1 @'
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
trap{[Console]::Error.Write('fake-adb-script-error');exit 95}
$state=$env:TABLET_C1A_FAKE_STATE
$actualArgs = @($args)
$line=($actualArgs | ConvertTo-Json -Compress)
Add-Content -LiteralPath (Join-Path $state 'adb-argv.jsonl') -Value $line -Encoding utf8
$joined=$actualArgs -join [char]31
if($joined -ceq 'devices'){
 $override=Join-Path $state 'devices.txt'
 if(Test-Path -LiteralPath $override){[Console]::Out.Write((Get-Content -LiteralPath $override -Raw));exit 0}
 [Console]::Out.Write("List of devices attached`r`nFAKE123`tdevice`r`n");exit 0
}
if($actualArgs.Count -lt 3 -or $actualArgs[0] -cne '-s' -or $actualArgs[1] -cne 'FAKE123'){exit 97}
$tail=@($actualArgs[2..($actualArgs.Count-1)])
$key=$tail -join ' '
switch -Exact ($key) {
 'shell getprop ro.build.fingerprint' {
  [Console]::Out.Write('vivo/fixture/pa2553:16/BUILD/1:user/release-keys')
  if(-not[string]::IsNullOrEmpty($env:TABLET_C1A_FAKE_QUERY_STDERR)){[Console]::Error.Write($env:TABLET_C1A_FAKE_QUERY_STDERR)}
  exit 0
 }
 'shell cat /proc/sys/kernel/random/boot_id' {[Console]::Out.Write('01234567-89ab-cdef-0123-456789abcdef');exit 0}
 'shell settings get secure enabled_accessibility_services' {[Console]::Out.Write('dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService');exit 0}
 'shell dumpsys accessibility' {
  if($env:TABLET_C1A_FAKE_A11Y_ERROR-ceq'1'){[Console]::Error.Write('fixture-error');exit 96}
  $countPath=Join-Path $state 'a11y-count.txt';$count=if(Test-Path -LiteralPath $countPath){[int](Get-Content -LiteralPath $countPath -Raw)}else{0}
  $count++;Set-Content -LiteralPath $countPath -Value $count -NoNewline
  $boundAfter=if([string]::IsNullOrWhiteSpace($env:TABLET_C1A_FAKE_BOUND_AFTER)){1}else{[int]$env:TABLET_C1A_FAKE_BOUND_AFTER}
  if($count-ge$boundAfter){[Console]::Out.Write('Bound services:{Service[label=执行网关, feedbackType[FEEDBACK_GENERIC]]}')}
  else{[Console]::Out.Write("Enabled services: dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService`nBound services: com.other/.Service")}
  exit 0
 }
 'shell pm path dev.magina.gateway' {[Console]::Out.Write('package:/data/app/~~fixture/dev.magina.gateway-fixture/base.apk');exit 0}
 'shell dumpsys package dev.magina.gateway' {[Console]::Out.Write("  versionCode=1 minSdk=30 targetSdk=35`n  versionName=0.1.0-m1a");exit 0}
}
if($tail.Count -ge 1 -and $tail[0] -ceq 'install'){
 Add-Content -LiteralPath (Join-Path $state 'install-count.txt') -Value '1';[Console]::Out.Write('Success');exit 0
}
if($tail.Count -eq 3 -and $tail[0] -ceq 'exec-out' -and $tail[1] -ceq 'cat'){
 Add-Content -LiteralPath (Join-Path $state 'installed-stream-count.txt') -Value '1'
 if($env:TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF-ceq'1'){
  [Console]::Out.Close();$chunk='x'*65536
  while($true){[Console]::Error.Write($chunk);[Console]::Error.Flush()}
 }
 $stream=[IO.File]::OpenRead($env:TABLET_C1A_FAKE_APK)
 try{$stream.CopyTo([Console]::OpenStandardOutput())}finally{$stream.Dispose()}
 exit 0
}
if($tail.Count -eq 5 -and $tail[1] -ceq 'content' -and
   (($tail[0] -ceq 'exec-in' -and $tail[2] -ceq 'write') -or
    ($tail[0] -ceq 'shell' -and $tail[2] -ceq 'read'))){
 $operation=$tail[2];$uriLiteral=$tail[4];$remoteCommand=@($tail[1..($tail.Count-1)]) -join ' '
 if($tail[3] -cne '--uri'){exit 97}
 if($operation -ceq 'write'){
  if($uriLiteral-cnotmatch '^content://[^''\x00-\x20\x7f%+]+$'){exit 97};$uri=$uriLiteral
 }else{
  if($uriLiteral-cnotmatch "^'([^']+)'$"){exit 97};$uri=$Matches[1]
 }
 Add-Content -LiteralPath (Join-Path $state 'content-remote-command.txt') -Value $remoteCommand -Encoding utf8
 Add-Content -LiteralPath (Join-Path $state 'content-uri.txt') -Value "$operation $uri" -Encoding utf8
 if(-not[string]::IsNullOrEmpty($env:TABLET_C1A_FAKE_CONTENT_STDERR)){[Console]::Error.Write($env:TABLET_C1A_FAKE_CONTENT_STDERR)}
 if($operation -ceq 'write'){
  if($env:TABLET_C1A_FAKE_NO_STDIN_READ-ceq'1'){Start-Sleep -Seconds 5;exit 0}
  $memory=[IO.MemoryStream]::new();[Console]::OpenStandardInput().CopyTo($memory)
  [IO.File]::WriteAllBytes((Join-Path $state 'content-stdin.bin'),$memory.ToArray());$memory.Dispose();exit 0
 }
 [Console]::Out.Write($env:TABLET_C1A_FAKE_CONTROL);exit 0
}
exit 97
'@
    $fakeAdb = $script:FakeAdbShimPath
    $fakeSigner = Join-Path $sdk 'build-tools\99.0.0\apksigner.bat'
    Set-FixtureFile $fakeSigner "@echo off`r`necho Signer #1 certificate SHA-256 digest: $('c' * 64)`r`n"
    $fakeGradlePs1 = Join-Path $bin 'fake-gradle.ps1'
    Set-FixtureFile $fakeGradlePs1 @'
Add-Content -LiteralPath (Join-Path $env:TABLET_C1A_FAKE_STATE 'gradle-argv.txt') -Value ($args -join ' ')
Set-Content -LiteralPath (Join-Path $env:TABLET_C1A_FAKE_STATE 'gradle-env.txt') -Value ($env:TABLET_C1A_BUILD_CHALLENGE+'|'+$env:TL1_C1A_EXPECTED_COMMIT_SHA) -NoNewline
'@
    $fakeGradle = Join-Path $bin 'fake-gradle.cmd'
    Set-FixtureFile $fakeGradle "@echo off`r`n`"$PwshPath`" -NoProfile -File `"$fakeGradlePs1`" %*`r`n"
    return [pscustomobject]@{ Root=$root;State=$state;Bin=$bin;Sdk=$sdk;Adb=$fakeAdb;Signer=$fakeSigner;Gradle=$fakeGradle }
}

New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$script:FakeAdbShimPath = Join-Path $TestRoot 'fake-adb-shim.exe'
$fakeAdbShimSourcePath = Join-Path $TestRoot 'fake-adb-shim.cs'
$priorFakePwsh = $env:TABLET_C1A_FAKE_PWSH
$env:TABLET_C1A_FAKE_PWSH = $PwshPath
$shimSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
public static class TabletC1aFakeAdbShim {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    private static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new [] { ' ', '\t', '"' }) < 0) return value;
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var character in value) {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') {
                result.Append('\\', slashes * 2 + 1).Append('"'); slashes = 0; continue;
            }
            result.Append('\\', slashes).Append(character); slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }
    public static int Main(string[] args) {
        if (Environment.GetEnvironmentVariable("TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF") == "1" &&
            args.Length >= 4 && args[2] == "exec-out" && args[3] == "cat") {
            CloseHandle(GetStdHandle(-11));
            var chunk = new byte[65536];
            for (var index = 0; index < chunk.Length; index++) chunk[index] = (byte)'x';
            var error = Console.OpenStandardError();
            while (true) { error.Write(chunk, 0, chunk.Length); error.Flush(); }
        }
        var state = Environment.GetEnvironmentVariable("TABLET_C1A_FAKE_STATE");
        var pwsh = Environment.GetEnvironmentVariable("TABLET_C1A_FAKE_PWSH");
        if (String.IsNullOrWhiteSpace(state) || String.IsNullOrWhiteSpace(pwsh)) return 98;
        var parent = Directory.GetParent(state);
        var root = parent == null ? null : parent.FullName;
        if (root == null) return 98;
        var script = Path.Combine(root, "bin", "fake-adb.ps1");
        var start = new ProcessStartInfo {
            FileName = pwsh, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        var all = new string[args.Length + 3];
        all[0] = "-NoProfile"; all[1] = "-File"; all[2] = script;
        Array.Copy(args, 0, all, 3, args.Length);
        start.Arguments = String.Join(" ", Array.ConvertAll(all, Quote));
        using (var process = new Process { StartInfo = start }) {
            if (!process.Start()) return 98;
            var stdin = Console.OpenStandardInput().CopyToAsync(process.StandardInput.BaseStream)
                .ContinueWith(_ => { try { process.StandardInput.Close(); } catch { } });
            var stdout = process.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
            var stderr = process.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
            process.WaitForExit();
            try { Task.WaitAll(new Task[] { stdin, stdout, stderr }, 5000); } catch { }
            return process.ExitCode;
        }
    }
}
'@
Set-FixtureFile $fakeAdbShimSourcePath $shimSource
$frameworkRoot=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $frameworkRoot -PathType Leaf)){$frameworkRoot=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
if(-not(Test-Path -LiteralPath $frameworkRoot -PathType Leaf)){throw '离线 fake adb 缺少 Windows csc.exe。'}
& $frameworkRoot /nologo /target:exe "/out:$($script:FakeAdbShimPath)" $fakeAdbShimSourcePath
if($LASTEXITCODE-ne0-or-not(Test-Path -LiteralPath $script:FakeAdbShimPath -PathType Leaf)){throw '离线 fake adb shim 编译失败。'}
. $LibraryPath
. $ValidatorPath

try {
    Test-Case '入口参数在任何设备访问前 fail closed' @(
        'entry_absolute_adb','entry_full_sha','entry_explicit_provision'
    ) {
        $source = Get-Content -LiteralPath $RunnerPath -Raw
        Assert-True ($source -match 'if \(-not \$Provision\)') '缺少显式 Provision 门'
        Assert-True ($source -match 'IsPathFullyQualified\(\$AdbPath\)') '缺少 absolute adb 门'
        Assert-True ($source -match "\^\[0-9a-f\]\{40\}\$") '缺少完整 SHA 门'
        $result = & $PwshPath -NoProfile -File $RunnerPath -AdbPath '.\adb.exe' `
            -ExpectedCommitSha ('a' * 40) -Provision 2>&1
        Assert-True ($LASTEXITCODE -ne 0) 'relative adb 不得成功'
    }

    Test-Case 'clean-port provenance 精确钉六个 blob' @('head_clean_exact','clean_port_blob_attest') {
        Assert-Equal $script:TL1C1aTrustedBlobs.Count 6 '受信 blob 数漂移'
        foreach ($entry in $script:TL1C1aTrustedBlobs.GetEnumerator()) {
            $working = (& git -C $RepoRoot hash-object -- (Join-Path $RepoRoot ($entry.Key -replace '/','\'))).Trim()
            Assert-Equal $working $entry.Value "working blob 漂移 $($entry.Key)"
        }
        $source = Get-Content -LiteralPath $LibraryPath -Raw
        Assert-True ($source -notmatch 'merge-base') 'clean-port 不得伪称 ancestor'
        Assert-True ($source -match 'cat-file.*\^\{commit\}') '未证明 baseline commit object'
    }

    Test-Case 'fresh build challenge 只经子进程环境传递' @(
        'fresh_build_challenge','gradle_kotlin_cache_ignored','release_absence_gate'
    ) {
        $fake = New-FakeTools
        $challenge = 'c1a-test-challenge-20260826'
        $priorState=$env:TABLET_C1A_FAKE_STATE
        try {
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            [void](Invoke-TL1C1aProcess -FilePath $fake.Gradle -Arguments @(':gateway:clean',':gateway:assembleDebug') `
                -Operation fake-gradle -Environment @{ TABLET_C1A_BUILD_CHALLENGE=$challenge; TL1_C1A_EXPECTED_COMMIT_SHA=('d'*40) })
        }
        finally { $env:TABLET_C1A_FAKE_STATE=$priorState }
        Assert-Equal (Get-Content -LiteralPath (Join-Path $fake.State 'gradle-env.txt') -Raw) "$challenge|$('d'*40)" '构建 env 未绑定'
        $argv = Get-Content -LiteralPath (Join-Path $fake.State 'gradle-argv.txt') -Raw
        Assert-True ($argv -notmatch [regex]::Escape($challenge)) 'challenge 泄漏到 gradle argv'
        Assert-True ((Get-Content -LiteralPath (Join-Path $RepoRoot 'scripts\check.ps1') -Raw) -match
            ':gateway:verifyTabletC1aReleaseAbsence') '标准 Gradle gate 未接 release absence 强门'
        $ignored = & git -C $RepoRoot check-ignore --no-index -- 'app/.kotlin/sessions/c1a-probe' 2>$null
        Assert-True ($LASTEXITCODE -eq 0 -and $ignored.Trim() -ceq 'app/.kotlin/sessions/c1a-probe') `
            'Gradle .kotlin cache 未由正式 ignore policy 收口'
    }

    Test-Case 'fake adb 精确 content 协议、stdin 与统一 nonce' @(
        'single_device','post_discovery_serial','install_once_no_retry','content_protocol_exact',
        'content_nonce_constant','title_hash_exact','t0_raw_bytes_unchanged','capture_exact_c1_c2',
        'result_single_consume','abort_cleanup','argv_allowlist','content_remote_shell_literal',
        'content_t0_binary_stdin'
    ) {
        $fake = New-FakeTools
        $priorState=$env:TABLET_C1A_FAKE_STATE;$priorControl=$env:TABLET_C1A_FAKE_CONTROL;$priorApk=$env:TABLET_C1A_FAKE_APK
        try {
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            $env:TABLET_C1A_FAKE_CONTROL=New-ControlJson
            $apk=Join-Path $fake.Root 'gateway-debug.apk';[IO.File]::WriteAllBytes($apk,[byte[]](1,2,3,4))
            $env:TABLET_C1A_FAKE_APK=$apk
            $serial=Get-TL1C1aSingleDevice $fake.Adb
            Assert-Equal $serial 'FAKE123' '唯一设备错误'
            [void](Invoke-TL1C1aAdb $fake.Adb $serial fingerprint)
            [void](Invoke-TL1C1aAdb -AdbPath $fake.Adb -Serial $serial -Name install -Value $apk)
            $nonce='n-'+('01'*16);$commit='a'*40;$artifact='sha256:'+('b'*64)
            $t0Uri=New-TL1C1aUri t0 'tl1-c1a-test' $nonce $commit $artifact
            Assert-True ($t0Uri -match 'title_hash=sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c') 'title hash 漂移'
            Assert-True ($t0Uri -notmatch '[%+]') 'URI 不得使用 percent/+ 别名'
            # 真实 T0 producer 在 Windows 留下 CRLF；这个样本能抓住 adb shell 的 text-mode 归一化。
            $raw=[Text.UTF8Encoding]::new($false).GetBytes("{`r`n  `"raw`": `"unchanged`"`r`n}`r`n")
            $writeResult=Invoke-TL1C1aAdb -AdbPath $fake.Adb -Serial $serial -Name content_t0 -Value $t0Uri -InputBytes $raw -AllowFailure
            Assert-Equal $writeResult.ExitCode 0 ("fake content write 失败："+$writeResult.Stderr)
            foreach($endpoint in @('status','c1','c2','result','abort')){
                $uri=New-TL1C1aUri $endpoint 'tl1-c1a-test' $nonce
                [void](Invoke-TL1C1aAdb -AdbPath $fake.Adb -Serial $serial -Name ("content_$endpoint") -Value $uri)
            }
            $forwardedHash=Get-TL1C1aSha256Bytes ([IO.File]::ReadAllBytes((Join-Path $fake.State 'content-stdin.bin')))
            Assert-Equal $forwardedHash (Get-TL1C1aSha256Bytes $raw) 'T0 stdin bytes 改写'
            Assert-Equal @((Get-Content -LiteralPath (Join-Path $fake.State 'install-count.txt'))).Count 1 'install 被重试'
            $argv=@(Get-Content -LiteralPath (Join-Path $fake.State 'adb-argv.jsonl') | ForEach-Object { ,($_|ConvertFrom-Json) })
            Assert-True ($argv.Count -ge 9) 'fake adb 调用不足'
            for($i=1;$i -lt $argv.Count;$i++){
                Assert-True ($argv[$i][0] -ceq '-s' -and $argv[$i][1] -ceq 'FAKE123') "发现后第 $i 条未固定 -s"
            }
            $joined=($argv | ForEach-Object { $_ -join ' ' }) -join "`n"
            Assert-True ($joined -notmatch '(?i)\b(forward|reverse|input|screencap|uiautomator|logcat|uninstall|force-stop|am\s+start|settings\s+(put|delete)|ime\s+(set|enable|disable)|pm\s+clear)\b') '出现禁止 adb argv'
            $t0Calls=@($argv | Where-Object { @($_).Count -eq 7 -and $_[2] -ceq 'exec-in' -and $_[3] -ceq 'content' -and $_[4] -ceq 'write' })
            Assert-Equal $t0Calls.Count 1 'T0 必须且只能使用一次 adb exec-in content write'
            Assert-Equal $t0Calls[0][6] $t0Uri 'exec-in 必须接收 raw canonical URI，不得夹带字面单引号'
            $readCalls=@($argv | Where-Object { @($_).Count -eq 7 -and $_[2] -ceq 'shell' -and $_[3] -ceq 'content' -and $_[4] -ceq 'read' })
            Assert-Equal $readCalls.Count 5 '只读 content endpoint 必须继续使用 adb shell content read'
            Assert-True (@($readCalls | Where-Object { $_[6] -cnotmatch "^'content://[^']+'$" }).Count -eq 0) `
                'adb shell content read 必须保留远端 POSIX 单引号'
            $uris=@(Get-Content -LiteralPath (Join-Path $fake.State 'content-uri.txt'))
            Assert-Equal $uris.Count 6 'content endpoint 数漂移'
            Assert-True (@($uris | Where-Object { $_ -notmatch [regex]::Escape("nonce=$nonce") }).Count -eq 0) 'nonce 未统一'
            Assert-True (@($uris | Where-Object { $_ -match "['\^]" }).Count -eq 0) 'provider canonical URI 夹带 quote/caret'
            $remote=@(Get-Content -LiteralPath (Join-Path $fake.State 'content-remote-command.txt'))
            Assert-Equal $remote.Count 6 'remote content command 数漂移'
            Assert-True ($remote[0] -ceq "content write --uri $t0Uri") "T0 exec-in 外部 argv 不是 raw canonical URI：$($remote[0])"
            Assert-Equal @([regex]::Matches($remote[0],'&')).Count 3 'T0 exec-in query 被截断'
        }
        finally{$env:TABLET_C1A_FAKE_STATE=$priorState;$env:TABLET_C1A_FAKE_CONTROL=$priorControl;$env:TABLET_C1A_FAKE_APK=$priorApk}
    }

    Test-Case 'Content remote-shell quoting、stderr 与 stdin deadline fail closed' @(
        'content_protocol_exact','content_nonce_constant','result_single_consume','abort_cleanup','argv_allowlist',
        'content_stderr_empty','stdin_overall_deadline'
    ) {
        $fake=New-FakeTools
        $priorState=$env:TABLET_C1A_FAKE_STATE;$priorControl=$env:TABLET_C1A_FAKE_CONTROL
        $priorStderr=$env:TABLET_C1A_FAKE_CONTENT_STDERR;$priorNoRead=$env:TABLET_C1A_FAKE_NO_STDIN_READ
        try{
            $env:TABLET_C1A_FAKE_STATE=$fake.State;$env:TABLET_C1A_FAKE_CONTROL=New-ControlJson
            $nonce='n-'+('02'*16);$statusUri=New-TL1C1aUri status 'tl1-c1a-test' $nonce
            $env:TABLET_C1A_FAKE_CONTENT_STDERR='fixture-stderr'
            $blocked=$false;try{[void](Invoke-TL1C1aAdb $fake.Adb 'FAKE123' content_status $statusUri)}catch{$blocked=$true}
            Assert-True $blocked 'valid stdout + stderr 未阻断'
            $env:TABLET_C1A_FAKE_CONTENT_STDERR=$null
            foreach($bad in @($statusUri+"'",$statusUri+'%27',$statusUri+'+alias')){
                $blocked=$false;try{[void](Invoke-TL1C1aAdb $fake.Adb 'FAKE123' content_status $bad)}catch{$blocked=$true}
                Assert-True $blocked 'Content URI quote/alias 注入未阻断'
            }
            $blocked=$false;try{[void](Invoke-TL1C1aAdb $fake.Adb 'FAKE123' content_c1 $statusUri)}catch{$blocked=$true}
            Assert-True $blocked 'endpoint/name mismatch 未阻断'
            $env:TABLET_C1A_FAKE_NO_STDIN_READ='1'
            $t0Uri=New-TL1C1aUri t0 'tl1-c1a-test' $nonce ('a'*40) ('sha256:'+('b'*64))
            $payload=[byte[]]::new(65536);$watch=[Diagnostics.Stopwatch]::StartNew()
            $blocked=$false;try{[void](Invoke-TL1C1aAdb -AdbPath $fake.Adb -Serial 'FAKE123' -Name content_t0 -Value $t0Uri -InputBytes $payload -TimeoutSec 1)}catch{$blocked=$true}
            $watch.Stop();Assert-True ($blocked-and$watch.Elapsed.TotalSeconds-lt4) 'stdin 不读时未按 overall deadline 终止'
            $runnerSource=Get-Content -LiteralPath $RunnerPath -Raw
            Assert-Equal @([regex]::Matches($runnerSource,'-Name install\b')).Count 1 'runner install 调用数漂移'
            Assert-Equal @([regex]::Matches($runnerSource,'-Name content_result\b')).Count 1 'runner result 消费数漂移'
            Assert-Equal @([regex]::Matches($runnerSource,'-Name content_abort\b')).Count 1 'runner abort 调用数漂移'
            Assert-True ($runnerSource.IndexOf('$sessionConsumed = $true',[StringComparison]::Ordinal) -gt
                $runnerSource.IndexOf("schema -cne `$script:TL1C1aObservationSchema",[StringComparison]::Ordinal)) 'invalid result 可能跳过 abort'
            Assert-True ($runnerSource.IndexOf('$sessionStarted = $true',[StringComparison]::Ordinal) -gt
                $runnerSource.IndexOf("status = 'needs-user'",[StringComparison]::Ordinal)) 'needs-user 分支可能触发 content cleanup'
        }finally{
            $env:TABLET_C1A_FAKE_STATE=$priorState;$env:TABLET_C1A_FAKE_CONTROL=$priorControl
            $env:TABLET_C1A_FAKE_CONTENT_STDERR=$priorStderr;$env:TABLET_C1A_FAKE_NO_STDIN_READ=$priorNoRead
        }
    }

    Test-Case 'control ACK exact 10/8 key 且绑定 embedded provenance' @(
        'embedded_head_challenge','package_version_binding','abort_cleanup','control_json_types_exact'
    ) {
        $commit='a'*40;$artifact='sha256:'+('b'*64);$challenge='c1a-test-challenge-20260826'
        $value=ConvertFrom-TL1C1aControl (New-ControlJson -Commit $commit -Artifact $artifact -Challenge $challenge) `
            'tl1-c1a-test' $commit $artifact $challenge awaiting_c1 capture_c1 $null
        Assert-Equal $value.provider.package_name 'dev.magina.gateway' 'package 漂移'
        $bad=(New-ControlJson -Commit $commit -Artifact $artifact -Challenge $challenge)|ConvertFrom-Json
        $bad.provider.embedded_git_head='d'*40
        $blocked=$false;try{[void](ConvertFrom-TL1C1aControl ($bad|ConvertTo-Json -Depth 8 -Compress) `
            'tl1-c1a-test' $commit $artifact $challenge awaiting_c1 capture_c1 $null)}catch{$blocked=$true}
        Assert-True $blocked 'embedded head mismatch 未阻断'
        $duplicate=(New-ControlJson -Commit $commit -Artifact $artifact -Challenge $challenge).Replace(
            '"schema":"tablet-c1a-control/v1"','"schema":"tablet-c1a-control/v1","schema":"tablet-c1a-control/v1"')
        $blocked=$false;try{[void](ConvertFrom-TL1C1aControl $duplicate 'tl1-c1a-test' $commit $artifact $challenge awaiting_c1 capture_c1 $null)}catch{$blocked=$true}
        Assert-True $blocked 'duplicate control key 未阻断'
        $abort=(New-ControlJson -Commit $commit -Artifact $artifact -Challenge $challenge)|ConvertFrom-Json
        $abort.ok=$false;$abort.state='aborted';$abort.next='none';$abort.reason_code='session_aborted'
        $cleanup=ConvertFrom-TL1C1aCleanupControl ($abort|ConvertTo-Json -Depth 8 -Compress) `
            'tl1-c1a-test' $commit $artifact $challenge
        Assert-Equal $cleanup.CleanupStatus 'passed' 'aborted cleanup 未通过'
        $abort.provider.a11y_service_ready=$false
        $cleanup=ConvertFrom-TL1C1aCleanupControl ($abort|ConvertTo-Json -Depth 8 -Compress) `
            'tl1-c1a-test' $commit $artifact $challenge
        Assert-Equal $cleanup.CleanupStatus 'passed' 'cleanup 将实时 a11y=false 误判为绑定失败'
        $abort.provider.a11y_service_ready=$true
        foreach($reason in @('start_replayed','a11y_service_replaced','output_too_large','session_expiry_unavailable')){
            $abort.state='failed';$abort.reason_code=$reason
            $cleanup=ConvertFrom-TL1C1aCleanupControl ($abort|ConvertTo-Json -Depth 8 -Compress) `
                'tl1-c1a-test' $commit $artifact $challenge
            Assert-Equal $cleanup.CleanupStatus 'passed' "failed cleanup reason 未通过：$reason"
        }
        $abort.state='absent';$abort.reason_code='session_not_found';$abort.producer_commit_sha=$null;$abort.producer_artifact_sha256=$null
        $cleanup=ConvertFrom-TL1C1aCleanupControl ($abort|ConvertTo-Json -Depth 8 -Compress) `
            'tl1-c1a-test' $commit $artifact $challenge
        Assert-Equal $cleanup.CleanupStatus 'not_required' 'absent cleanup 映射错误'
        foreach($field in @(
            'schema_array','ok_string','run_array','state_array','next_array','reason_number','token_number',
            'commit_array','artifact_array','authority_array','protocol_number','package_array','version_name_array',
            'version_code_string','head_array','challenge_array','a11y_number'
        )){
            $spoof=(New-ControlJson -Commit $commit -Artifact $artifact -Challenge $challenge)|ConvertFrom-Json
            switch($field){
                'schema_array'{$spoof.schema=[object[]]@($spoof.schema)}
                'ok_string'{$spoof.ok='true'}
                'run_array'{$spoof.run_id=[object[]]@($spoof.run_id)}
                'state_array'{$spoof.state=[object[]]@($spoof.state)}
                'next_array'{$spoof.next=[object[]]@($spoof.next)}
                'reason_number'{$spoof.reason_code=1}
                'token_number'{$spoof.capture_token=1}
                'commit_array'{$spoof.producer_commit_sha=[object[]]@($spoof.producer_commit_sha)}
                'artifact_array'{$spoof.producer_artifact_sha256=[object[]]@($spoof.producer_artifact_sha256)}
                'authority_array'{$spoof.provider.authority=[object[]]@($spoof.provider.authority)}
                'protocol_number'{$spoof.provider.protocol_version=1}
                'package_array'{$spoof.provider.package_name=[object[]]@($spoof.provider.package_name)}
                'version_name_array'{$spoof.provider.version_name=[object[]]@($spoof.provider.version_name)}
                'version_code_string'{$spoof.provider.version_code='1'}
                'head_array'{$spoof.provider.embedded_git_head=[object[]]@($spoof.provider.embedded_git_head)}
                'challenge_array'{$spoof.provider.build_challenge=[object[]]@($spoof.provider.build_challenge)}
                'a11y_number'{$spoof.provider.a11y_service_ready=1}
            }
            $blocked=$false;try{[void](ConvertFrom-TL1C1aControl ($spoof|ConvertTo-Json -Depth 8 -Compress) `
                'tl1-c1a-test' $commit $artifact $challenge awaiting_c1 capture_c1 $null)}catch{$blocked=$true}
            Assert-True $blocked "control $field 类型欺骗未阻断"
        }
    }

    Test-Case 'APK hash、证书与 installed package parser fail closed' @(
        'apk_hash_binding','apksigner_certificate','package_version_binding','installed_host_stream_pre_post',
        'installed_stderr_cap_after_eof','installed_path_closed','post_apk_binding'
    ) {
        $fake=New-FakeTools;$priorState=$env:TABLET_C1A_FAKE_STATE;$priorApk=$env:TABLET_C1A_FAKE_APK
        $priorStreamStderr=$env:TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF
        try{
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            $largeApk=Join-Path $fake.Root 'large.apk'
            $largeStream=[IO.File]::Open($largeApk,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try{$largeStream.SetLength(1MB+4097)}finally{$largeStream.Dispose()}
            $env:TABLET_C1A_FAKE_APK=$largeApk
            $digest=Get-TL1C1aSignerDigest $fake.Signer (Join-Path $fake.Root 'x.apk')
            Assert-Equal $digest ('sha256:'+('c'*64)) 'apksigner digest 错误'
            $remote=Get-TL1C1aInstalledApkPath 'package:/data/app/~~x/dev.magina.gateway-x/base.apk'
            Assert-Equal $remote '/data/app/~~x/dev.magina.gateway-x/base.apk' 'base.apk path 错误'
            $expected=Get-TL1C1aFileSha256 $largeApk
            $pre=Get-TL1C1aInstalledApkHostSha256 $fake.Adb 'FAKE123' $remote 10
            $post=Get-TL1C1aInstalledApkHostSha256 $fake.Adb 'FAKE123' $remote 10
            Assert-Equal $pre $expected 'host 流式 installed hash 错误'
            Assert-Equal $post $pre 'pre/post installed hash 漂移'
            Assert-Equal @((Get-Content -LiteralPath (Join-Path $fake.State 'installed-stream-count.txt'))).Count 2 'installed APK 不是 pre/post 各一次'
            $env:TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF='1'
            $watch=[Diagnostics.Stopwatch]::StartNew();$blocked=$false
            try{[void](Get-TL1C1aInstalledApkHostSha256 $fake.Adb 'FAKE123' $remote 10)}catch{$blocked=$true}
            $watch.Stop()
            Assert-True ($blocked-and$watch.Elapsed.TotalSeconds-lt5) `
                "stdout EOF 后 stderr 洪泛未快速 fail closed（blocked=$blocked elapsed_ms=$($watch.ElapsedMilliseconds)）"
            $env:TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF=$null
            foreach($bad in @(
                'package:/data/app/ok;input/base.apk','package:/data/app/ok$(id)/base.apk',
                'package:/data/app/../base.apk','package:/data/app//base.apk','package:/data/app/has space/base.apk'
            )){
                $blocked=$false;try{[void](Get-TL1C1aInstalledApkPath $bad)}catch{$blocked=$true}
                Assert-True $blocked "installed path 注入未阻断：$bad"
            }
            $runnerSource=Get-Content -LiteralPath $RunnerPath -Raw
            Assert-Equal @([regex]::Matches($runnerSource,'Get-TL1C1aInstalledApkHostSha256')).Count 2 'runner installed host hash 调用数漂移'
            Assert-True ($runnerSource -match 'installedShaAfter -cne \$installedShaBefore') 'runner 未阻断 installed hash mismatch'
            $pkg=Get-TL1C1aPackageBinding " versionCode=7 minSdk=30`n versionName=0.1.0-m1a"
            Assert-Equal $pkg.VersionCode 7L 'version code 错误'
        }finally{$env:TABLET_C1A_FAKE_STATE=$priorState;$env:TABLET_C1A_FAKE_APK=$priorApk;$env:TABLET_C1A_FAKE_STREAM_STDERR_AFTER_EOF=$priorStreamStderr}
    }

    Test-Case 'a11y 缺失只返回 needs-user 且源码无自动修改' @('a11y_needs_user_no_mutation','a11y_bound_wait_vivo') {
        $component='dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
        $short='dev.magina.gateway/.a11y.GatewayA11yService'
        Assert-True (-not(Test-TL1C1aA11yReady '' 'no bound service').Ready) '缺失 a11y 被判 ready'
        Assert-True (-not(Test-TL1C1aA11yReady $component "Enabled services: $component`nBound services: com.other/.Service").Ready) 'Enabled section 冒充 bound'
        Assert-True (Test-TL1C1aA11yReady $component "Bound services:`n  ComponentInfo{$short}`nCrashed services: none").Ready 'short component bound 未识别'
        Assert-True (Test-TL1C1aA11yReady $component 'Bound services:{Service[label=执行网关, feedbackType[FEEDBACK_GENERIC]]}').Ready 'vivo label-only bound 未识别'
        Assert-True (-not(Test-TL1C1aA11yReady $component 'Bound services:{Service[label=执行网关X, feedbackType[FEEDBACK_GENERIC]]}').Ready) '相似 label 冒充 bound'
        Assert-True (-not(Test-TL1C1aA11yReady $component 'Bound services:{Service[notlabel=执行网关, feedbackType[FEEDBACK_GENERIC]]}').Ready) 'label 字段后缀冒充 bound'
        Assert-True (-not(Test-TL1C1aA11yReady $component "Bound services:`n  ComponentInfo{x$short}").Ready) 'component 子串冒充 bound'
        $fake=New-FakeTools;$priorState=$env:TABLET_C1A_FAKE_STATE;$priorAfter=$env:TABLET_C1A_FAKE_BOUND_AFTER;$priorError=$env:TABLET_C1A_FAKE_A11Y_ERROR
        try{
            $env:TABLET_C1A_FAKE_STATE=$fake.State;$env:TABLET_C1A_FAKE_BOUND_AFTER='3';$env:TABLET_C1A_FAKE_A11Y_ERROR=$null
            $waited=Wait-TL1C1aA11yReady $fake.Adb 'FAKE123' 2 50
            Assert-True ($waited.Ready-and$waited.Attempts-eq3) '延迟 bound 未在有界等待内识别'
            Remove-Item -LiteralPath (Join-Path $fake.State 'a11y-count.txt') -Force
            $env:TABLET_C1A_FAKE_BOUND_AFTER='999'
            $timed=Wait-TL1C1aA11yReady $fake.Adb 'FAKE123' 1 50
            Assert-True (-not$timed.Ready) 'bound 超时被判 ready'
            $env:TABLET_C1A_FAKE_A11Y_ERROR='1'
            $blocked=$false;try{[void](Wait-TL1C1aA11yReady $fake.Adb 'FAKE123' 1 50)}catch{$blocked=$true}
            Assert-True $blocked 'dumpsys accessibility 错误未 fail closed'
        }finally{$env:TABLET_C1A_FAKE_STATE=$priorState;$env:TABLET_C1A_FAKE_BOUND_AFTER=$priorAfter;$env:TABLET_C1A_FAKE_A11Y_ERROR=$priorError}
        $source=(Get-Content -LiteralPath $RunnerPath -Raw)+(Get-Content -LiteralPath $LibraryPath -Raw)
        Assert-True ($source -notmatch '(?i)settings[\x27\x22, ]+(put|delete)|ime[\x27\x22, ]+(enable|disable|set)') 'runner 含设置修改'
    }

    Test-Case '两帧源码只有 c1→等待900→c2 且总15秒门' @(
        'capture_host_wait_900','capture_span_15s','no_recapture','device_binding_pre_post'
    ) {
        $source=Get-Content -LiteralPath $RunnerPath -Raw
        Assert-Equal @([regex]::Matches($source,'-Name content_c1\b')).Count 1 'c1 调用数漂移'
        Assert-Equal @([regex]::Matches($source,'-Name content_c2\b')).Count 1 'c2 调用数漂移'
        Assert-True ($source -match 'ElapsedMilliseconds -lt 900') '缺少 >=900ms host wait'
        Assert-True ($source -match 'Elapsed\.TotalSeconds -gt 15') '缺少 <=15s 总门'
        Assert-True ($source -match 'recapture_count = 0') '未固定 no recapture'
        Assert-True (@([regex]::Matches($source,'Test-TL1C1aDeviceBinding')).Count -eq 2) '设备绑定不是前后两次'
    }

    Test-Case 'T0 sidecar 缓存 devices 且只转发固定 -s 查询' @('post_discovery_serial','argv_allowlist','t0_sidecar_stderr_empty') {
        $fake=New-FakeTools
        $prior=@(
            $env:TL1_C1A_REAL_ADB_PATH,$env:TL1_C1A_BOUND_SERIAL,$env:TL1_C1A_T0_LIBRARY_PATH,
            $env:TABLET_C1A_FAKE_STATE,$env:TL1_C1A_PWSH_PATH,$env:TL1_C1A_T0_SIDECAR_SCRIPT,
            $env:TABLET_C1A_FAKE_QUERY_STDERR
        )
        try{
            $env:TL1_C1A_REAL_ADB_PATH=$fake.Adb;$env:TL1_C1A_BOUND_SERIAL='FAKE123'
            $env:TL1_C1A_T0_LIBRARY_PATH=Join-Path $RepoRoot 'scripts\lib\tablet-intake.ps1'
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            $env:TL1_C1A_PWSH_PATH=$PwshPath;$env:TL1_C1A_T0_SIDECAR_SCRIPT=$T0SidecarPath
            $devices=(Invoke-TL1C1aProcess -FilePath $T0SidecarCmdPath -Arguments @('devices') -Operation fake-t0-sidecar).Text
            Assert-True ($devices -match 'FAKE123') 'sidecar cached devices 错误'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $fake.State 'adb-argv.jsonl'))) 'cached devices 误触真实 adb'
            [void](& $PwshPath -NoProfile -File $T0SidecarPath -s FAKE123 shell getprop ro.build.fingerprint)
            Assert-Equal $LASTEXITCODE 0 '固定只读查询未转发'
            $env:TABLET_C1A_FAKE_QUERY_STDERR='fixture-stderr'
            & $PwshPath -NoProfile -File $T0SidecarPath -s FAKE123 shell getprop ro.build.fingerprint 2>$null | Out-Null
            Assert-True ($LASTEXITCODE -ne 0) 'T0 sidecar 放过 valid stdout + stderr'
            $env:TABLET_C1A_FAKE_QUERY_STDERR=$null
            & $PwshPath -NoProfile -File $T0SidecarPath -s FAKE123 shell input tap 1 1 2>$null | Out-Null
            Assert-True ($LASTEXITCODE -ne 0) 'sidecar 放过 input'
        }finally{
            $env:TL1_C1A_REAL_ADB_PATH=$prior[0];$env:TL1_C1A_BOUND_SERIAL=$prior[1]
            $env:TL1_C1A_T0_LIBRARY_PATH=$prior[2];$env:TABLET_C1A_FAKE_STATE=$prior[3]
            $env:TL1_C1A_PWSH_PATH=$prior[4];$env:TL1_C1A_T0_SIDECAR_SCRIPT=$prior[5]
            $env:TABLET_C1A_FAKE_QUERY_STDERR=$prior[6]
        }
    }

    Test-Case 'fresh T0 identity 必须与外层 serial/fingerprint 同链' @(
        't0_raw_bytes_unchanged','device_binding_pre_post','privacy_no_raw_secret'
    ) {
        $run='tl1-c1a-bind-test';$serialHash='sha256:'+('1'*64);$fingerprintHash='sha256:'+('2'*64)
        $t0=[pscustomobject]@{run_id=$run;device=[pscustomobject]@{serial_hash=$serialHash;fingerprint_hash=$fingerprintHash}}
        Assert-TL1C1aT0DeviceBinding $t0 $run $serialHash $fingerprintHash
        foreach($mutation in @('run','serial','fingerprint')){
            $copy=$t0|ConvertTo-Json -Depth 5|ConvertFrom-Json
            if($mutation-ceq'run'){$copy.run_id='other'}elseif($mutation-ceq'serial'){$copy.device.serial_hash='sha256:'+('3'*64)}else{$copy.device.fingerprint_hash=$null}
            $blocked=$false;try{Assert-TL1C1aT0DeviceBinding $copy $run $serialHash $fingerprintHash}catch{$blocked=$true}
            Assert-True $blocked "T0 $mutation mismatch 未阻断"
        }
        $secret='RAW-IDENTITY-SECRET'
        $blocked=$false;try{Assert-TL1C1aNoRawSecret "safe-$secret" @($secret)}catch{$blocked=$_.Exception.Message-ceq'privacy_leak'}
        Assert-True $blocked 'runtime privacy canary 未阻断'
        $titlePlaintext='文件传输助手'
        $blocked=$false;try{Assert-TL1C1aNoRawSecret "safe-$titlePlaintext" @($titlePlaintext)}catch{$blocked=$_.Exception.Message-ceq'privacy_leak'}
        Assert-True $blocked '标题明文 privacy canary 未阻断'
        $rawBoot='ABCDEF12-3456-7890-ABCD-EF1234567890'
        $normalizedBoot=$rawBoot.ToLowerInvariant()
        $blocked=$false;try{Assert-TL1C1aNoRawSecret "safe-$normalizedBoot" @($rawBoot,$normalizedBoot)}catch{$blocked=$_.Exception.Message-ceq'privacy_leak'}
        Assert-True $blocked 'normalized boot_id privacy canary 未阻断'
    }

    Test-Case '后置 discovery 多设备或换机必须阻断' @('single_device','device_binding_pre_post') {
        $fake=New-FakeTools;$prior=$env:TABLET_C1A_FAKE_STATE
        try{
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            Assert-Equal (Get-TL1C1aSingleDevice $fake.Adb) 'FAKE123' '前置唯一设备错误'
            Set-FixtureFile (Join-Path $fake.State 'devices.txt') "List of devices attached`r`nFAKE123`tdevice`r`nOTHER456`tdevice`r`n"
            $blocked=$false;try{[void](Get-TL1C1aSingleDevice $fake.Adb)}catch{$blocked=$true}
            Assert-True $blocked '后置多设备未阻断'
            Set-FixtureFile (Join-Path $fake.State 'devices.txt') "List of devices attached`r`nOTHER456`tdevice`r`n"
            $post=Get-TL1C1aSingleDevice $fake.Adb
            Assert-True ($post-cne'FAKE123') '换机 fixture 未生效'
        }finally{$env:TABLET_C1A_FAKE_STATE=$prior}
    }

    Test-Case 'devices 0/未授权/离线/未知 transport 全部 fail closed' @('single_device','post_discovery_serial') {
        $fake=New-FakeTools;$prior=$env:TABLET_C1A_FAKE_STATE
        try{
            $env:TABLET_C1A_FAKE_STATE=$fake.State
            foreach($body in @(
                "List of devices attached`r`n",
                "List of devices attached`r`nFAKE123`tunauthorized`r`n",
                "List of devices attached`r`nFAKE123`toffline`r`n",
                "List of devices attached`r`nFAKE123`tdevice`r`nRECOVERY9`trecovery`r`n"
            )){
                Set-FixtureFile (Join-Path $fake.State 'devices.txt') $body
                $blocked=$false;try{[void](Get-TL1C1aSingleDevice $fake.Adb)}catch{$blocked=$true}
                Assert-True $blocked '非唯一可用 devices fixture 未阻断'
            }
        }finally{$env:TABLET_C1A_FAKE_STATE=$prior}
    }

    Test-Case 'trusted runtime validator 独立路径而公共 runtime 仍不可用' @(
        'trusted_runtime_validator','public_runtime_unavailable'
    ) {
        $root=Join-Path $TestRoot 'trusted-runtime';New-Item -ItemType Directory -Force -Path $root|Out-Null
        $t0Raw=Get-Content -LiteralPath $FixtureT0Path -Raw -Encoding utf8
        Set-Content -LiteralPath (Join-Path $root 'upstream-t0-v5.json') -Value $t0Raw -Encoding utf8NoBOM -NoNewline
        $t0=$t0Raw|ConvertFrom-Json -Depth 30 -DateKind String
        $obs=Get-Content -LiteralPath $FixtureObservationPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 100 -DateKind String
        $commit='a'*40;$artifact='sha256:'+('b'*64)
        $obs.run_id=$t0.run_id;$obs.provenance.kind='gateway_runtime_probe';$obs.provenance.producer_commit_sha=$commit
        $obs.provenance.producer_artifact_sha256=$artifact;$obs.upstream_t0.source_kind='trusted_runtime'
        $obs.upstream_t0.artifact_sha256=Get-TL1V2Sha256Text $t0Raw
        $obs.upstream_t0.device_profile_hash=Get-TL1V2DeviceProfileHash $t0.device
        $obsPath=Join-Path $root 'observation.json'
        $obs|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $obsPath -Encoding utf8NoBOM
        $schemaErrors=@()
        $schemaOk=(Get-Content -LiteralPath $obsPath -Raw)|Test-Json `
            -SchemaFile (Join-Path $RepoRoot 'docs\contracts\tablet-layout-observation-v2.schema.json') `
            -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
        Assert-True $schemaOk ("trusted fixture schema 失败：" + (@($schemaErrors|ForEach-Object{$_.Exception.Message}) -join ';'))
        $trusted=Test-TabletLayoutObservationV2TrustedRuntimeFile $obsPath $root $t0.run_id $commit $artifact
        Assert-True $trusted.fixture_contract_valid ("trusted runtime origin 未通过：" + (@($trusted.reason_codes) -join ','))
        Assert-True (-not $trusted.runtime_evidence) 'C1a 不得提升 runtime evidence'

        # 真实诊断 blocker 与 runtime origin 是两条轴：producer 如实声明 blocker 时，origin 仍可成立，
        # 但 diagnostic/runtime/layout/P0/execution 绝不能因此提升。
        $blockedObs=$obs|ConvertTo-Json -Depth 100|ConvertFrom-Json -Depth 100 -DateKind String
        foreach($frame in @($blockedObs.frames)){$frame.windows_truncated=$true}
        $blockedObs.diagnostic_status='blocked'
        $blockedObs.reason_codes=@('ime_target_editor_unbound','window_inventory_truncated')
        $blockedPath=Join-Path $root 'observation-blocked.json'
        $blockedObs|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $blockedPath -Encoding utf8NoBOM
        $blockedTrusted=Test-TabletLayoutObservationV2TrustedRuntimeFile $blockedPath $root $t0.run_id $commit $artifact
        Assert-True $blockedTrusted.fixture_contract_valid `
            ("diagnostic blocker 错误撤回 trusted runtime origin：" + (@($blockedTrusted.reason_codes) -join ','))
        Assert-True (-not $blockedTrusted.diagnostic_observed) 'diagnostic blocker 被错误判 observed'
        Assert-True (@($blockedTrusted.reason_codes) -contains 'window_inventory_truncated') `
            '真实 diagnostic blocker 未保留'
        Assert-True (@($blockedTrusted.reason_codes) -contains 'ime_target_editor_unbound') `
            '截断窗口导致的 IME/editor blocker 未保留'
        Assert-True (@($blockedTrusted.reason_codes) -notcontains 'declared_reasons_incomplete') `
            'producer 已完整声明 blocker 却被判 reasons incomplete'
        Assert-True (-not $blockedTrusted.runtime_evidence -and -not $blockedTrusted.layout_accepted -and
            $blockedTrusted.p0_capability -ceq 'unsupported' -and -not $blockedTrusted.execution_grant) `
            'diagnostic blocked trusted origin 错误提升 claim scope'
        $public=Test-TabletLayoutObservationV2File (Join-Path $root 'missing.json') $root
        Assert-True (@($public.reason_codes) -contains 'runtime_producer_unavailable') '公共 runtime 未固定 unavailable'
    }

    Test-Case 'sidecar schema 固定 claim scope 且安全原子路径拒绝覆盖' @(
        'safe_atomic_evidence','claim_scope_false','privacy_no_raw_secret','implementation_hash_postcheck',
        'published_evidence_postcheck'
    ) {
        $destination=Join-Path $TestRoot 'atomic.json';$bytes=[Text.Encoding]::UTF8.GetBytes('{}')
        # 使用 TestRoot 自身作为受控 root，避免把测试产物写入仓库。
        [void](Write-TL1C1aBytesAtomic -RepoRoot $TestRoot -Destination $destination -Bytes $bytes)
        $blocked=$false;try{[void](Write-TL1C1aBytesAtomic -RepoRoot $TestRoot -Destination $destination -Bytes $bytes)}catch{$blocked=$true}
        Assert-True $blocked '原子文件被覆盖'
        $postGuard=Join-Path $TestRoot 'post-guard.json'
        $blocked=$false;try{[void](Write-TL1C1aBytesAtomic -RepoRoot $TestRoot -Destination $postGuard -Bytes $bytes -PostWriteValidation {throw 'fixture-drift'})}catch{$blocked=$true}
        Assert-True ($blocked-and-not(Test-Path -LiteralPath $postGuard)) '落盘后 drift 未撤回 success sidecar'
        $evidenceFiles=@{}
        foreach($name in @('t0','observation','validation')){
            $path=Join-Path $TestRoot "$name.json"
            [IO.File]::WriteAllText($path,"{`"name`":`"$name`"}",[Text.UTF8Encoding]::new($false))
            $evidenceFiles[$name]=[pscustomobject]@{Path=$path;Hash=Get-TL1C1aFileSha256 $path}
        }
        [void](Assert-TL1C1aPublishedEvidenceBinding -RepoRoot $TestRoot `
            -T0Path $evidenceFiles.t0.Path -T0Sha256 $evidenceFiles.t0.Hash `
            -ObservationPath $evidenceFiles.observation.Path -ObservationSha256 $evidenceFiles.observation.Hash `
            -ValidationPath $evidenceFiles.validation.Path -ValidationSha256 $evidenceFiles.validation.Hash)
        [IO.File]::AppendAllText($evidenceFiles.validation.Path,' ',[Text.UTF8Encoding]::new($false))
        $blocked=$false
        try{[void](Assert-TL1C1aPublishedEvidenceBinding -RepoRoot $TestRoot `
            -T0Path $evidenceFiles.t0.Path -T0Sha256 $evidenceFiles.t0.Hash `
            -ObservationPath $evidenceFiles.observation.Path -ObservationSha256 $evidenceFiles.observation.Hash `
            -ValidationPath $evidenceFiles.validation.Path -ValidationSha256 $evidenceFiles.validation.Hash)}catch{$blocked=$true}
        Assert-True $blocked 'validation evidence 漂移未 fail closed'
        $schema=Get-Content -LiteralPath $SidecarSchemaPath -Raw
        Assert-True ($schema -match '"runtime_evidence"\s*:\s*\{\s*"const"\s*:\s*false') 'runtime_evidence 非 const false'
        Assert-True ($schema -match '"c1a_origin_binding_verified"\s*:\s*\{\s*"const"\s*:\s*true') 'origin flag 非 const true'
        foreach($field in @('mcp_used','dispatch_used','screen_capture_used','settings_mutation_used','target_app_started')){
            Assert-True ($schema -match ('"'+$field+'"\s*:\s*\{\s*"const"\s*:\s*false')) "$field 非 const false"
        }
        $hash='sha256:'+('a'*64);$git='a'*40
        $sample=[ordered]@{
            schema='tablet-layout-c1a-sidecar/v1';run_id='tl1-c1a-sample';completed_at_utc='2026-08-26T00:00:00.0000000Z'
            expected_commit_sha=$git;provenance_strategy='clean_port_content_attested'
            static_read_only_policy_version='tl1-c1a-read-only/v1'
            trusted_blobs=@($script:TL1C1aTrustedBlobs.GetEnumerator()|ForEach-Object{[ordered]@{path=$_.Key;blob_oid=$_.Value}})
            implementation_hashes=[ordered]@{
                runner_sha256=$hash;c1a_library_sha256=$hash;t0_adb_sidecar_cmd_sha256=$hash
                t0_adb_sidecar_script_sha256=$hash;validator_sha256=$hash;sidecar_schema_sha256=$hash
            }
            producer_baseline_sha=$script:TL1C1aProducerBaseline;t0_baseline_sha=$script:TL1C1aT0Baseline
            title_hash=$script:TL1C1aExpectedTitleHash
            apk=[ordered]@{
                local_sha256_before=$hash;local_sha256_after=$hash
                installed_base_apk_path_hash_before=$hash;installed_base_apk_path_hash_after=$hash
                installed_base_apk_sha256_before=$hash;installed_base_apk_sha256_after=$hash
                signer_certificate_sha256=$hash;package_name_before='dev.magina.gateway';package_name_after='dev.magina.gateway'
                version_name_before='0.1.0-m1a';version_name_after='0.1.0-m1a';version_code_before=1;version_code_after=1
                embedded_git_head=$git;build_challenge_hash=$hash
            }
            device=[ordered]@{serial_hash_before=$hash;serial_hash_after=$hash;fingerprint_hash_before=$hash;fingerprint_hash_after=$hash;boot_id_hash_before=$hash;boot_id_hash_after=$hash;unique_device_before_after=$true}
            upstream_t0=[ordered]@{producer_commit_sha=$script:TL1C1aT0Baseline;artifact_sha256=$hash;original_bytes_forwarded=$true}
            capture=[ordered]@{tokens=@('c1','c2');host_wait_ms=900;total_span_ms=1000;recapture_count=0}
            observation=[ordered]@{artifact_sha256=$hash;relative_path='tablet-layout-observation-v2.json'}
            validation=[ordered]@{artifact_sha256=$hash;relative_path='tablet-layout-observation-validation-v2.json'}
            c1a_origin_binding_verified=$true;c1a_probe_entrypoint_read_only=$true;observation_schema_valid=$true
            mcp_used=$false;dispatch_used=$false;screen_capture_used=$false;settings_mutation_used=$false;target_app_started=$false;cleanup_status='not_required'
            runtime_evidence=$false;layout_accepted=$false;wechat_layout_verified=$false;editor_action_ready=$false;p0_capability='unsupported';execution_grant=$false
        }
        $sampleRaw=$sample|ConvertTo-Json -Depth 20 -Compress
        Assert-True ($sampleRaw|Test-Json -SchemaFile $SidecarSchemaPath -ErrorAction SilentlyContinue) 'happy sidecar 不符合 schema'
        $sample.runtime_evidence=$true
        Assert-True (-not (($sample|ConvertTo-Json -Depth 20 -Compress)|Test-Json -SchemaFile $SidecarSchemaPath -ErrorAction SilentlyContinue)) 'runtime_evidence 提升未被 schema 拒绝'
        $sample.runtime_evidence=$false
        $sample.cleanup_status='passed'
        Assert-True (-not (($sample|ConvertTo-Json -Depth 20 -Compress)|Test-Json -SchemaFile $SidecarSchemaPath -ErrorAction SilentlyContinue)) 'happy sidecar 伪造 abort cleanup 未被 schema 拒绝'
        $runner=Get-Content -LiteralPath $RunnerPath -Raw
        Assert-True ($runner -notmatch '文件传输助手') 'runner 落了标题明文'
        Assert-True ($schema -notmatch '"nonce"|"build_challenge"\s*:') 'sidecar schema 允许原始 nonce/challenge'
        foreach($field in @('runner_sha256','c1a_library_sha256','t0_adb_sidecar_cmd_sha256','t0_adb_sidecar_script_sha256','validator_sha256','sidecar_schema_sha256')){
            Assert-True ($schema -match [regex]::Escape('"'+$field+'"')) "sidecar 缺 implementation hash：$field"
        }
        Assert-True ($runner -match '-PostWriteValidation') 'sidecar 落盘后未重验 implementation/APK'
        Assert-True (@([regex]::Matches($runner,'Assert-TL1C1aPublishedEvidenceBinding')).Count -eq 2) '已发布三证据不是 sidecar 前后各复核一次'
    }
}
finally {
    $env:TABLET_C1A_FAKE_PWSH = $priorFakePwsh
    if (Test-Path -LiteralPath $TestRoot) {
        $resolved=[IO.Path]::GetFullPath($TestRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)) { throw '测试清理越出 temp。' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

$coverage=[Collections.Generic.List[object]]::new()
foreach($id in $script:RequiredCoverage){
    $matching=@($script:Results|Where-Object{@($_.covers)-contains $id})
    $coverage.Add([ordered]@{id=$id;status=if($matching.Count-eq 0){'missing'}elseif(@($matching|Where-Object{$_.status-cne'passed'}).Count-gt 0){'failed'}else{'passed'};cases=@($matching|ForEach-Object{$_.name})})
}
$complete=@($coverage|Where-Object{$_.status-cne'passed'}).Count-eq 0
$status=if($script:Results.Count-gt 0 -and $script:Failed-eq 0 -and $complete){'passed'}else{'failed'}
$summary=[ordered]@{
    schema_version=1;suite='tablet_layout_c1a_offline';generated_at_utc=[DateTime]::UtcNow.ToString('o')
    status=$status;device_access='fake_tools_only';selected=$script:Results.Count
    passed=@($script:Results|Where-Object{$_.status-ceq'passed'}).Count;failed=$script:Failed
    required_coverage=@($coverage);cases=@($script:Results)
}
if(-not [IO.Path]::IsPathFullyQualified($SummaryPath)){throw '-SummaryPath 必须绝对。'}
$summaryDir=Split-Path $SummaryPath -Parent
if(-not(Test-Path -LiteralPath $summaryDir)){New-Item -ItemType Directory -Force -Path $summaryDir|Out-Null}
$summary|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $SummaryPath -Encoding utf8NoBOM
Write-Host "tablet T-L1 C1a offline：$($summary.passed)/$($summary.selected) cases，$(@($coverage|Where-Object{$_.status-ceq'passed'}).Count)/$($coverage.Count) coverage"
if($status-cne'passed'){exit 1}
