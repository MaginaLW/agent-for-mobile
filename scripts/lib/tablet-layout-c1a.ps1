#Requires -Version 7.5
# T-L1 C1a PC 侧受控 runner/sidecar 库。这里只提供固定协议原语，不导出任意 adb shell 入口。

Set-StrictMode -Version 3.0

$script:TL1C1aAuthority = 'dev.magina.gateway.tablet.c1a'
$script:TL1C1aProtocolSchema = 'tablet-c1a-control/v1'
$script:TL1C1aObservationSchema = 'tablet-layout-observation/v2'
$script:TL1C1aSidecarSchema = 'tablet-layout-c1a-sidecar/v1'
$script:TL1C1aPackageName = 'dev.magina.gateway'
$script:TL1C1aA11yComponent = 'dev.magina.gateway/dev.magina.gateway.a11y.GatewayA11yService'
$script:TL1C1aA11yLabel = '执行网关'
$script:TL1C1aProducerBaseline = 'b5769df7baba075fda47aec17f249a5caa124b92'
$script:TL1C1aT0Baseline = '4ca32b131007df58f7752c5ee9b2d049cb1cd54e'
$script:TL1C1aExpectedTitleHash = 'sha256:5d3510ec998c991305fcede15b32be9ea1c4061d82ab15a3994a38faa243311c'
$script:TL1C1aMaximumOutputBytes = 1MB
$script:TL1C1aMaximumInstalledApkBytes = 256MB
$script:TL1C1aTrustedBlobs = [ordered]@{
    'app/gateway/src/main/java/dev/magina/gateway/tablet/AndroidTabletLayoutProbeSource.kt' = 'cf5f625650d81e830da8e03b2ee8ebf5ce309b7a'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt' = 'b7b35d1d0c4c1787f1f254224c8ac13ee1668cf7'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt' = '283eb71675605444c5f829aea9b1c9fd9bd65db0'
    'app/gateway/src/test/java/dev/magina/gateway/tablet/TabletLayoutProbeTest.kt' = '70843bb488041c5e21204f973c4dbcac526a126e'
    'scripts/lib/tablet-intake.ps1' = '4d33c629b95a13a59bb97bdf1490e1edc74b17b4'
    'scripts/run-tablet-intake.ps1' = '572da0c848eefd038ea666d80d741fb73767eb48'
}

function Get-TL1C1aSha256Bytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Get-TL1C1aSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try { return Get-TL1C1aSha256Bytes $bytes }
    finally { if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Get-TL1C1aFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function Assert-TL1C1aNoRawSecret {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Secrets
    )
    foreach ($secretValue in $Secrets) {
        if ($null -eq $secretValue) { continue }
        $secret = [string]$secretValue
        if ($secret.Length -lt 4) { continue }
        if ($Content.IndexOf($secret, [StringComparison]::Ordinal) -ge 0) { throw 'privacy_leak' }
    }
}

function Assert-TL1C1aPublishedEvidenceBinding {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$T0Path,
        [Parameter(Mandatory)][string]$T0Sha256,
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$ObservationSha256,
        [Parameter(Mandatory)][string]$ValidationPath,
        [Parameter(Mandatory)][string]$ValidationSha256
    )
    $bindings = [ordered]@{
        upstream_t0 = [pscustomobject]@{ Path=$T0Path; Sha256=$T0Sha256 }
        observation = [pscustomobject]@{ Path=$ObservationPath; Sha256=$ObservationSha256 }
        validation = [pscustomobject]@{ Path=$ValidationPath; Sha256=$ValidationSha256 }
    }
    foreach ($entry in $bindings.GetEnumerator()) {
        $binding = $entry.Value
        if ([string]$binding.Sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw '已发布 C1a evidence hash 格式错误。'
        }
        [void](Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path ([string]$binding.Path))
        if ((Get-TL1C1aFileSha256 ([string]$binding.Path)) -cne [string]$binding.Sha256) {
            throw "已发布 C1a evidence 漂移：$($entry.Key)。"
        }
    }
}

function Assert-TL1C1aT0DeviceBinding {
    param(
        [Parameter(Mandatory)]$T0,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$SerialHash,
        [Parameter(Mandatory)][string]$FingerprintHash
    )
    try {
        if ($T0.run_id -cne $RunId -or $T0.device.serial_hash -cne $SerialHash -or
            $T0.device.fingerprint_hash -cne $FingerprintHash -or
            $SerialHash -cnotmatch '^sha256:[0-9a-f]{64}$' -or
            $FingerprintHash -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'fresh T0 与外层 device identity 绑定失败。'
        }
    }
    catch { throw 'fresh T0 与外层 device identity 绑定失败。' }
}

function ConvertFrom-TL1C1aStrictUtf8 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes, [Parameter(Mandatory)][string]$Operation)
    if ($Bytes.Length -gt $script:TL1C1aMaximumOutputBytes) { throw "$Operation 输出超过 1 MiB。" }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xef -and $Bytes[1] -eq 0xbb -and $Bytes[2] -eq 0xbf) {
        throw "$Operation 输出含 UTF-8 BOM。"
    }
    try { return [Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw "$Operation 输出不是 strict UTF-8。" }
}

function Invoke-TL1C1aProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [byte[]]$InputBytes,
        [hashtable]$Environment,
        [ValidateRange(1, 300)][int]$TimeoutSec = 30,
        [switch]$AllowFailure
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    if ($null -ne $Environment) {
        foreach ($name in $Environment.Keys) { $start.Environment[[string]$name] = [string]$Environment[$name] }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = [IO.MemoryStream]::new()
    $stderr = [IO.MemoryStream]::new()
    $cancellation = [Threading.CancellationTokenSource]::new()
    $inputClosed = $false
    $started = $false
    try {
        if (-not $process.Start()) { throw "$Operation 无法启动。" }
        $started = $true
        $cancellation.CancelAfter($TimeoutSec * 1000)
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout, $cancellation.Token)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr, $cancellation.Token)
        if ($null -eq $InputBytes) {
            $process.StandardInput.Close()
            $inputClosed = $true
            $inputTask = [Threading.Tasks.Task]::CompletedTask
        }
        else {
            $inputTask = $process.StandardInput.BaseStream.WriteAsync(
                $InputBytes, 0, $InputBytes.Length, $cancellation.Token
            )
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.HasExited -or -not $inputTask.IsCompleted) {
            if ($stdout.Length -gt $script:TL1C1aMaximumOutputBytes -or
                $stderr.Length -gt $script:TL1C1aMaximumOutputBytes) {
                throw "$Operation 输出超过 1 MiB。"
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "$Operation 超时。" }
            if (-not $inputClosed -and $inputTask.IsCompleted) {
                [void]$inputTask.GetAwaiter().GetResult()
                $process.StandardInput.Close()
                $inputClosed = $true
            }
            Start-Sleep -Milliseconds 10
        }
        if (-not $inputClosed) {
            [void]$inputTask.GetAwaiter().GetResult()
            $process.StandardInput.Close()
            $inputClosed = $true
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) { throw "$Operation 超时。" }
        [void]$stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $bytes = $stdout.ToArray()
        $stderrBytes = $stderr.ToArray()
        if ($bytes.Length -gt $script:TL1C1aMaximumOutputBytes -or
            $stderrBytes.Length -gt $script:TL1C1aMaximumOutputBytes) { throw "$Operation 输出超过 1 MiB。" }
        $text = ConvertFrom-TL1C1aStrictUtf8 -Bytes $bytes -Operation $Operation
        $stderrText = ConvertFrom-TL1C1aStrictUtf8 -Bytes $stderrBytes -Operation "$Operation stderr"
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Bytes = $bytes
            Text = $text
            Stderr = $stderrText
        }
        if (-not $AllowFailure -and $result.ExitCode -ne 0) {
            throw "$Operation 失败（exit=$($result.ExitCode)）。"
        }
        return $result
    }
    catch {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
        }
        throw
    }
    finally {
        $cancellation.Cancel()
        $cancellation.Dispose()
        if (-not $inputClosed) { try { $process.StandardInput.Close() } catch { } }
        $stdout.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
}

function Invoke-TL1C1aGit {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )
    $result = Invoke-TL1C1aProcess -FilePath 'git.exe' -Arguments (@('-C', $RepoRoot) + $Arguments) `
        -Operation 'Git provenance 复核' -TimeoutSec 30 -AllowFailure:$AllowFailure
    return $result
}

function Assert-TL1C1aGitProvenance {
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$ExpectedCommitSha)
    if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$') { throw '-ExpectedCommitSha 必须是完整小写 40 位 Git SHA。' }
    $head = (Invoke-TL1C1aGit $RepoRoot @('rev-parse','HEAD')).Text.Trim()
    if ($head -cne $ExpectedCommitSha) { throw "HEAD 与 -ExpectedCommitSha 不一致（HEAD=$head）。" }
    $status = (Invoke-TL1C1aGit $RepoRoot @('status','--porcelain=v1','--untracked-files=all')).Text
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw '工作树不干净，拒绝构建或连接设备。' }
    foreach ($baseline in @($script:TL1C1aProducerBaseline, $script:TL1C1aT0Baseline)) {
        $object = Invoke-TL1C1aGit $RepoRoot @('cat-file','-e',"$baseline^{commit}") -AllowFailure
        if ($object.ExitCode -ne 0) { throw "缺少受信 baseline commit object：$baseline。" }
    }
    foreach ($entry in $script:TL1C1aTrustedBlobs.GetEnumerator()) {
        $path = [string]$entry.Key
        $expectedBlob = [string]$entry.Value
        $baseline = if ($path.StartsWith('app/', [StringComparison]::Ordinal)) {
            $script:TL1C1aProducerBaseline
        } else { $script:TL1C1aT0Baseline }
        $baselineBlob = (Invoke-TL1C1aGit $RepoRoot @('rev-parse',"$baseline`:$path")).Text.Trim()
        $headBlob = (Invoke-TL1C1aGit $RepoRoot @('rev-parse',"$ExpectedCommitSha`:$path")).Text.Trim()
        $workingBlob = (Invoke-TL1C1aGit $RepoRoot @('hash-object','--',(Join-Path $RepoRoot ($path -replace '/','\')))).Text.Trim()
        if ($baselineBlob -cne $expectedBlob -or $headBlob -cne $expectedBlob -or $workingBlob -cne $expectedBlob) {
            throw "受信 blob 漂移：$path。"
        }
    }
    return $head
}

function Assert-TL1C1aOrdinaryPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf
    )
    $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw '证据路径越出仓库根目录。' }
    $cursor = if ($AllowMissingLeaf) { [IO.Path]::GetDirectoryName($full) } else { $full }
    while ($cursor -and $cursor.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw '证据路径含 reparse point。'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
    if (-not $AllowMissingLeaf -and -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw '受控证据文件不存在。'
    }
    return $full
}

function Write-TL1C1aBytesAtomic {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [scriptblock]$PostWriteValidation
    )
    if ($Bytes.Length -lt 1 -or $Bytes.Length -gt 1MB) { throw '证据文件必须在 1..1 MiB。' }
    $destinationFull = Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path $Destination -AllowMissingLeaf
    if ([IO.Path]::GetExtension($destinationFull) -cne '.json') { throw '证据文件扩展名必须是 .json。' }
    if (Test-Path -LiteralPath $destinationFull) { throw "拒绝覆盖既有证据：$(Split-Path $destinationFull -Leaf)。" }
    $directory = [IO.Path]::GetDirectoryName($destinationFull)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw '证据目标目录不存在。' }
    $temporary = Join-Path $directory ('.c1a-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $published = $false
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $destinationFull)
        $published = $true
        [void](Assert-TL1C1aOrdinaryPath -RepoRoot $RepoRoot -Path $destinationFull)
        if ($null -eq ('TabletLayoutObservationV2.NativePath' -as [type])) {
            throw '证据 final-path/hardlink guard 未加载。'
        }
        $verifyStream = [IO.File]::Open($destinationFull,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            $identityIssues = [Collections.Generic.List[object]]::new()
            if (-not (Test-TL1V2OpenedFileIdentity $verifyStream.SafeFileHandle $destinationFull $identityIssues) -or
                $identityIssues.Count -ne 0) { throw '证据 final path/hardlink 复核失败。' }
        }
        finally { $verifyStream.Dispose() }
        if ((Get-TL1C1aFileSha256 $destinationFull) -cne (Get-TL1C1aSha256Bytes $Bytes)) {
            throw '证据原子写入后 hash 漂移。'
        }
        if ($null -ne $PostWriteValidation) { & $PostWriteValidation }
    }
    catch {
        if ($published -and (Test-Path -LiteralPath $destinationFull -PathType Leaf)) {
            Remove-Item -LiteralPath $destinationFull -Force
        }
        throw
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    return $destinationFull
}

function Write-TL1C1aJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    try { return Write-TL1C1aBytesAtomic -RepoRoot $RepoRoot -Destination $Destination -Bytes $bytes }
    finally { if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Get-TL1C1aSingleDevice {
    param([Parameter(Mandatory)][string]$AdbPath)
    $result = Invoke-TL1C1aProcess -FilePath $AdbPath -Arguments @('devices') -Operation '唯一设备发现'
    $rows = [Collections.Generic.List[object]]::new()
    $headerSeen = $false
    foreach ($line in ($result.Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '') { continue }
        if ($trimmed -ceq 'List of devices attached') {
            if ($headerSeen -or $rows.Count -gt 0) { throw 'adb devices header 重复或位置错误。' }
            $headerSeen = $true
            continue
        }
        if (-not $headerSeen) { throw 'adb devices 输出含未知前导行。' }
        $match = [regex]::Match($trimmed, '^(\S+)\s+(.+)$')
        if (-not $match.Success) { throw 'adb devices 输出含不可解析设备行。' }
        $state = $match.Groups[2].Value.Trim()
        if ($state -cnotmatch '^(device|unauthorized|offline|no permissions(?:\s.*)?)$') {
            throw 'adb devices 输出含未知 transport/state。'
        }
        $rows.Add([pscustomobject]@{ Serial=$match.Groups[1].Value; State=$state })
    }
    if (-not $headerSeen) { throw 'adb devices 缺少固定 header。' }
    if ($rows.Count -ne 1) { throw "C1a 要求恰好一台设备，当前识别到 $($rows.Count) 台。" }
    if ($rows[0].State -cne 'device') { throw "唯一设备不可用（state=$($rows[0].State)）。" }
    if ([string]$rows[0].Serial -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$') { throw '设备 serial 格式不安全。' }
    return [string]$rows[0].Serial
}

function ConvertTo-TL1C1aContentUriArgument {
    param(
        [Parameter(Mandatory)][ValidateSet(
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][bool]$BinaryStdin
    )
    $runPattern = '[a-z0-9][a-z0-9._-]{0,79}'
    $noncePattern = 'n-[0-9a-f]{32}'
    $pathPattern = switch ($Name) {
        'content_t0' { "t0/$runPattern" }
        'content_status' { "status/$runPattern" }
        'content_c1' { "capture/c1/$runPattern" }
        'content_c2' { "capture/c2/$runPattern" }
        'content_result' { "result/$runPattern" }
        'content_abort' { "abort/$runPattern" }
    }
    $queryPattern = if ($Name -ceq 'content_t0') {
        'nonce=' + $noncePattern +
        '&title_hash=' + [regex]::Escape($script:TL1C1aExpectedTitleHash) +
        '&producer_commit_sha=[0-9a-f]{40}' +
        '&producer_artifact_sha256=sha256:[0-9a-f]{64}'
    }
    else { 'nonce=' + $noncePattern }
    $expected = '^content://' + [regex]::Escape($script:TL1C1aAuthority) + '/' +
        $pathPattern + '\?' + $queryPattern + '$'
    if ($Uri -cnotmatch $expected -or $Uri -match "['\x00-\x20\x7f%+]" ) {
        throw 'Content URI 不符合固定 closed grammar。'
    }
    if (($Name -ceq 'content_t0') -ne $BinaryStdin) {
        throw 'Content URI transport 与 endpoint 不一致。'
    }
    # adb exec-in 会对 command argv 自行 escape_arg，必须给它 raw canonical URI；预置单引号会变成参数内容。
    # adb shell 则把多 argv 无转义拼回远端 sh，只读 endpoint 必须显式提供 POSIX 单引号。
    if ($BinaryStdin) { return $Uri }
    return "'$Uri'"
}

function Assert-TL1C1aInstalledApkRemotePath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cnotmatch '^/data/app/(?:[A-Za-z0-9_~+=.-]+/)+base\.apk$' -or
        $Path -match '[\x00-\x20\x7f]') { throw 'installed base.apk 路径不安全。' }
    $segments = @($Path.Substring('/data/app/'.Length) -split '/')
    if ($segments.Count -lt 2 -or $segments[-1] -cne 'base.apk' -or
        @($segments | Where-Object { $_ -ceq '' -or $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) {
        throw 'installed base.apk 路径不安全。'
    }
    return $Path
}

function Invoke-TL1C1aAdb {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][ValidateSet(
            'fingerprint','boot_id','a11y_enabled','a11y_bound','install','package_path','package_dump',
            'content_t0','content_status','content_c1','content_c2','content_result','content_abort'
        )][string]$Name,
        [string]$Value,
        [byte[]]$InputBytes,
        [int]$TimeoutSec = 30,
        [switch]$AllowFailure
    )
    $contentNames = @('content_t0','content_status','content_c1','content_c2','content_result','content_abort')
    $contentUriArgument = if ($contentNames -ccontains $Name) {
        ConvertTo-TL1C1aContentUriArgument -Name $Name -Uri $Value -BinaryStdin:($Name -ceq 'content_t0')
    } else { $null }
    $tail = switch ($Name) {
        'fingerprint' { @('shell','getprop','ro.build.fingerprint') }
        'boot_id' { @('shell','cat','/proc/sys/kernel/random/boot_id') }
        'a11y_enabled' { @('shell','settings','get','secure','enabled_accessibility_services') }
        'a11y_bound' { @('shell','dumpsys','accessibility') }
        'install' { @('install','-r','-t',$Value) }
        'package_path' { @('shell','pm','path',$script:TL1C1aPackageName) }
        'package_dump' { @('shell','dumpsys','package',$script:TL1C1aPackageName) }
        # Windows adb shell 从重定向 stdin 经 CRT text mode 读取，会把 CRLF 归一为 LF。
        # exec-in 在 adb 客户端启用 binary stdin，才能把 T0 producer 的原始 bytes 原样送进 provider。
        'content_t0' { @('exec-in','content','write','--uri',$contentUriArgument) }
        'content_status' { @('shell','content','read','--uri',$contentUriArgument) }
        'content_c1' { @('shell','content','read','--uri',$contentUriArgument) }
        'content_c2' { @('shell','content','read','--uri',$contentUriArgument) }
        'content_result' { @('shell','content','read','--uri',$contentUriArgument) }
        'content_abort' { @('shell','content','read','--uri',$contentUriArgument) }
        default { throw '内部错误：未知 C1a ADB 映射。' }
    }
    if ($Name -eq 'install' -and (-not [IO.Path]::IsPathFullyQualified($Value) -or
        -not (Test-Path -LiteralPath $Value -PathType Leaf))) { throw '安装 APK 路径必须是存在的绝对文件。' }
    $result = Invoke-TL1C1aProcess -FilePath $AdbPath -Arguments (@('-s',$Serial) + $tail) `
        -Operation "C1a adb/$Name" -InputBytes $InputBytes -TimeoutSec $TimeoutSec -AllowFailure:$AllowFailure
    if ($contentNames -ccontains $Name -and $result.Stderr.Length -ne 0) {
        throw "C1a adb/$Name stderr 必须 exact empty。"
    }
    return $result
}

function New-TL1C1aUri {
    param(
        [Parameter(Mandatory)][ValidateSet('t0','status','c1','c2','result','abort')][string]$Endpoint,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Nonce,
        [string]$ExpectedCommitSha,
        [string]$ArtifactSha256
    )
    if ($RunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$') { throw 'run_id 格式错误。' }
    if ($Nonce -cnotmatch '^n-[0-9a-f]{32}$') { throw 'nonce 格式错误。' }
    $path = switch ($Endpoint) {
        't0' { "/t0/$RunId" }
        'status' { "/status/$RunId" }
        'c1' { "/capture/c1/$RunId" }
        'c2' { "/capture/c2/$RunId" }
        'result' { "/result/$RunId" }
        'abort' { "/abort/$RunId" }
    }
    $query = [Collections.Generic.List[string]]::new()
    $query.Add('nonce=' + $Nonce)
    if ($Endpoint -eq 't0') {
        if ($ExpectedCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
            $ArtifactSha256 -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'T0 URI provenance 参数错误。' }
        $query.Add('title_hash=' + $script:TL1C1aExpectedTitleHash)
        $query.Add('producer_commit_sha=' + $ExpectedCommitSha)
        $query.Add('producer_artifact_sha256=' + $ArtifactSha256)
    }
    return "content://$($script:TL1C1aAuthority)${path}?" + ($query -join '&')
}

function Assert-TL1C1aControlJsonTypes {
    param([Parameter(Mandatory)]$Value)
    foreach ($name in @('schema','run_id','state','next')) {
        if ($Value.$name -isnot [string]) { throw "control $name JSON type 错误。" }
    }
    if ($Value.ok -isnot [bool]) { throw 'control ok JSON type 错误。' }
    foreach ($name in @('reason_code','capture_token','producer_commit_sha','producer_artifact_sha256')) {
        if ($null -ne $Value.$name -and $Value.$name -isnot [string]) {
            throw "control $name JSON type 错误。"
        }
    }
    foreach ($name in @(
        'authority','protocol_version','package_name','version_name','embedded_git_head','build_challenge'
    )) {
        if ($Value.provider.$name -isnot [string]) { throw "control provider/$name JSON type 错误。" }
    }
    if ($Value.provider.version_code -isnot [long] -or
        $Value.provider.a11y_service_ready -isnot [bool]) {
        throw 'control provider scalar JSON type 错误。'
    }
}

function ConvertFrom-TL1C1aControl {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$BuildChallenge,
        [Parameter(Mandatory)][ValidateSet('awaiting_c1','awaiting_c2','complete','aborted')][string]$ExpectedState,
        [Parameter(Mandatory)][ValidateSet('capture_c1','capture_c2','read_result','none')][string]$ExpectedNext,
        [AllowNull()]$ExpectedCaptureToken
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt 65536 -or $Raw -match '[\r\n]') {
        throw 'control 响应必须是 64 KiB 内单行 JSON。'
    }
    try {
        $strictIssues = [Collections.Generic.List[object]]::new()
        $value = ConvertFrom-TL1V2StrictJson $Raw $strictIssues
        if ($null -eq $value -or $strictIssues.Count -ne 0) { throw 'strict JSON failed' }
    }
    catch { throw 'control 响应不是 strict JSON。' }
    if ($value -isnot [pscustomobject]) { throw 'control 响应顶层必须是 JSON object。' }
    $required = @(
        'schema','ok','run_id','state','next','reason_code','capture_token',
        'producer_commit_sha','producer_artifact_sha256','provider'
    )
    $actual = [string[]]@($value.PSObject.Properties.Name)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    [Array]::Sort($required, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($required -join "`n")) { throw 'control 响应字段集合漂移。' }
    if ($value.provider -isnot [pscustomobject]) { throw 'control provider 必须是 JSON object。' }
    $providerNames = [string[]]@($value.provider.PSObject.Properties.Name)
    $expectedProvider = [string[]]@(
        'authority','protocol_version','package_name','version_name','version_code',
        'embedded_git_head','build_challenge','a11y_service_ready'
    )
    [Array]::Sort($providerNames, [StringComparer]::Ordinal)
    [Array]::Sort($expectedProvider, [StringComparer]::Ordinal)
    if (($providerNames -join "`n") -cne ($expectedProvider -join "`n")) { throw 'control provider 字段集合漂移。' }
    Assert-TL1C1aControlJsonTypes $value
    if ($value.schema -cne $script:TL1C1aProtocolSchema -or
        $value.ok -ne $true -or
        $value.run_id -cne $RunId -or $value.state -cne $ExpectedState -or
        $value.next -cne $ExpectedNext -or $null -ne $value.reason_code -or
        $value.producer_commit_sha -cne $ExpectedCommitSha -or
        $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256 -or
        $value.provider.authority -cne $script:TL1C1aAuthority -or
        $value.provider.protocol_version -cne '1' -or
        $value.provider.package_name -cne $script:TL1C1aPackageName -or
        $value.provider.embedded_git_head -cne $ExpectedCommitSha -or
        $value.provider.build_challenge -cne $BuildChallenge -or
        $value.provider.a11y_service_ready -ne $true -or
        $value.provider.version_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $value.provider.version_code -lt 1) { throw 'control 响应绑定失败。' }
    if ($null -ne $ExpectedCaptureToken -and $value.capture_token -cne $ExpectedCaptureToken) {
        throw 'capture token 响应错误。'
    }
    if ($null -eq $ExpectedCaptureToken -and $null -ne $value.capture_token) { throw '非 capture 响应夹带 token。' }
    return $value
}

function ConvertFrom-TL1C1aCleanupControl {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][string]$ExpectedArtifactSha256,
        [Parameter(Mandatory)][string]$BuildChallenge
    )
    if ([Text.Encoding]::UTF8.GetByteCount($Raw) -gt 65536 -or $Raw -match '[\r\n]') {
        throw 'cleanup control 必须是 64 KiB 内单行 JSON。'
    }
    try {
        $strictIssues = [Collections.Generic.List[object]]::new()
        $value = ConvertFrom-TL1V2StrictJson $Raw $strictIssues
        if ($null -eq $value -or $strictIssues.Count -ne 0) { throw 'strict JSON failed' }
    }
    catch { throw 'cleanup control 不是 strict JSON。' }
    if ($value -isnot [pscustomobject]) { throw 'cleanup control 顶层必须是 JSON object。' }
    $top = [string[]]@($value.PSObject.Properties.Name)
    $expectedTop = [string[]]@(
        'schema','ok','run_id','state','next','reason_code','capture_token',
        'producer_commit_sha','producer_artifact_sha256','provider'
    )
    $expectedProvider = [string[]]@(
        'authority','protocol_version','package_name','version_name','version_code',
        'embedded_git_head','build_challenge','a11y_service_ready'
    )
    [Array]::Sort($top,[StringComparer]::Ordinal);[Array]::Sort($expectedTop,[StringComparer]::Ordinal)
    if (($top -join "`n") -cne ($expectedTop -join "`n")) { throw 'cleanup control 字段集合漂移。' }
    if ($value.provider -isnot [pscustomobject]) { throw 'cleanup control provider 必须是 JSON object。' }
    $provider = [string[]]@($value.provider.PSObject.Properties.Name)
    [Array]::Sort($provider,[StringComparer]::Ordinal);[Array]::Sort($expectedProvider,[StringComparer]::Ordinal)
    if (($provider -join "`n") -cne ($expectedProvider -join "`n")) { throw 'cleanup provider 字段集合漂移。' }
    Assert-TL1C1aControlJsonTypes $value
    if (
        $value.schema -cne $script:TL1C1aProtocolSchema -or
        $value.ok -ne $false -or
        $value.run_id -cne $RunId -or $value.next -cne 'none' -or $null -ne $value.capture_token -or
        $value.provider.authority -cne $script:TL1C1aAuthority -or
        $value.provider.protocol_version -cne '1' -or $value.provider.package_name -cne $script:TL1C1aPackageName -or
        $value.provider.embedded_git_head -cne $ExpectedCommitSha -or
        $value.provider.build_challenge -cne $BuildChallenge -or
        $value.provider.version_name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        $value.provider.version_code -lt 1) { throw 'cleanup control 基础绑定失败。' }
    $failedReasons = [string[]]@(
        'build_identity_mismatch','run_salt_unavailable','t0_invalid','capture_sequence_invalid',
        'a11y_service_unavailable','capture_c1_failed','capture_c2_failed','observation_assembly_failed',
        'start_replayed','a11y_service_replaced','output_too_large','session_expiry_unavailable'
    )
    $cleanupStatus = switch ([string]$value.state) {
        'aborted' {
            if ($value.reason_code -cne 'session_aborted' -or
                $value.producer_commit_sha -cne $ExpectedCommitSha -or
                $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256) { throw 'aborted cleanup 绑定失败。' }
            'passed'
        }
        'failed' {
            if ($failedReasons -cnotcontains [string]$value.reason_code -or
                $value.producer_commit_sha -cne $ExpectedCommitSha -or
                $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256) { throw 'failed cleanup 绑定失败。' }
            'passed'
        }
        'expired' {
            if ($value.reason_code -cne 'session_expired' -or
                $value.producer_commit_sha -cne $ExpectedCommitSha -or
                $value.producer_artifact_sha256 -cne $ExpectedArtifactSha256) { throw 'expired cleanup 绑定失败。' }
            'passed'
        }
        'absent' {
            if ($value.reason_code -cne 'session_not_found' -or
                $null -ne $value.producer_commit_sha -or $null -ne $value.producer_artifact_sha256) {
                throw 'absent cleanup 绑定失败。'
            }
            'not_required'
        }
        default { throw 'cleanup control state 不允许。' }
    }
    return [pscustomobject]@{ Value=$value; CleanupStatus=$cleanupStatus }
}

function Get-TL1C1aPackageBinding {
    param([Parameter(Mandatory)][string]$PackageDump)
    $versionNameMatches = @([regex]::Matches($PackageDump, '(?m)^\s*versionName=([^\r\n]+)\s*$'))
    $versionCodeMatches = @([regex]::Matches($PackageDump, '(?m)^\s*versionCode=(\d+)\b'))
    if ($versionNameMatches.Count -ne 1 -or $versionCodeMatches.Count -ne 1) { throw 'installed package/version 无法唯一解析。' }
    $versionName = $versionNameMatches[0].Groups[1].Value.Trim()
    $versionCode = 0L
    if ($versionName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
        -not [long]::TryParse($versionCodeMatches[0].Groups[1].Value, [ref]$versionCode) -or $versionCode -lt 1) {
        throw 'installed package/version 格式错误。'
    }
    return [pscustomobject]@{ PackageName=$script:TL1C1aPackageName; VersionName=$versionName; VersionCode=$versionCode }
}

function Get-TL1C1aInstalledApkPath {
    param([Parameter(Mandatory)][string]$Text)
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($lines.Count -ne 1 -or $lines[0] -cnotmatch '^package:(.+)$') {
        throw 'installed base.apk 路径无法唯一解析。'
    }
    try { return Assert-TL1C1aInstalledApkRemotePath ([string]$Matches[1]) }
    catch { throw 'installed base.apk 路径无法唯一解析。' }
}

function Get-TL1C1aInstalledApkHostSha256 {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Serial,
        [Parameter(Mandatory)][string]$RemotePath,
        [ValidateRange(1,300)][int]$TimeoutSec = 180
    )
    [void](Assert-TL1C1aInstalledApkRemotePath $RemotePath)
    if ($Serial -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$') { throw 'installed APK serial 格式不安全。' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-s',$Serial,'exec-out','cat',$RemotePath)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stderr = [IO.MemoryStream]::new()
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash(
        [Security.Cryptography.HashAlgorithmName]::SHA256
    )
    $cancellation = [Threading.CancellationTokenSource]::new()
    $buffer = [byte[]]::new(65536)
    $started = $false
    [long]$total = 0
    try {
        if (-not $process.Start()) { throw 'installed base.apk 流式读取无法启动。' }
        $started = $true
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $process.StandardInput.Close()
        $cancellation.CancelAfter($TimeoutSec * 1000)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr, $cancellation.Token)
        while ($true) {
            $readTask = $process.StandardOutput.BaseStream.ReadAsync(
                $buffer, 0, $buffer.Length, $cancellation.Token
            )
            while (-not $readTask.IsCompleted) {
                if ($stderr.Length -gt $script:TL1C1aMaximumOutputBytes) {
                    throw 'installed base.apk 流式读取超过固定上限。'
                }
                if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                    throw 'installed base.apk 流式读取超时。'
                }
                Start-Sleep -Milliseconds 10
            }
            $read = $readTask.GetAwaiter().GetResult()
            if ($read -eq 0) { break }
            $total += $read
            if ($total -gt $script:TL1C1aMaximumInstalledApkBytes -or
                $stderr.Length -gt $script:TL1C1aMaximumOutputBytes) {
                throw 'installed base.apk 流式读取超过固定上限。'
            }
            $hasher.AppendData($buffer, 0, $read)
        }
        # stdout 可能先 EOF，而异常 adb 仍持续写 stderr；直到进程退出都继续守住同一总时限和 1 MiB 上限。
        while (-not $process.HasExited) {
            if ($stderr.Length -gt $script:TL1C1aMaximumOutputBytes) {
                throw 'installed base.apk 流式读取超过固定上限。'
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                throw 'installed base.apk 流式读取超时。'
            }
            Start-Sleep -Milliseconds 10
        }
        [void]$stderrTask.GetAwaiter().GetResult()
        $stderrBytes = $stderr.ToArray()
        if ($stderrBytes.Length -gt $script:TL1C1aMaximumOutputBytes) {
            throw 'installed base.apk 流式读取超过固定上限。'
        }
        if ($process.ExitCode -ne 0 -or $total -lt 1 -or $stderrBytes.Length -ne 0) {
            throw 'installed base.apk 流式读取失败。'
        }
        return 'sha256:' + [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    catch {
        if ($started -and -not $process.HasExited) {
            try { $process.Kill($true); [void]$process.WaitForExit(5000) } catch { }
        }
        if ($_.Exception -is [OperationCanceledException]) { throw 'installed base.apk 流式读取超时。' }
        throw
    }
    finally {
        $cancellation.Cancel()
        $cancellation.Dispose()
        [Array]::Clear($buffer, 0, $buffer.Length)
        $hasher.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
}

function Find-TL1C1aApkSigner {
    $roots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    foreach ($root in $roots) {
        if (-not [IO.Path]::IsPathFullyQualified($root)) { continue }
        $buildTools = Join-Path ([IO.Path]::GetFullPath($root)) 'build-tools'
        if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $buildTools -Directory | Sort-Object Name -Descending)) {
            foreach ($name in @('apksigner.bat','apksigner.exe')) {
                $candidate = Join-Path $directory.FullName $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
        }
    }
    throw '未找到 Android SDK apksigner。'
}

function Get-TL1C1aSignerDigest {
    param([Parameter(Mandatory)][string]$ApkSignerPath, [Parameter(Mandatory)][string]$ApkPath)
    $result = Invoke-TL1C1aProcess -FilePath $ApkSignerPath `
        -Arguments @('verify','--print-certs',$ApkPath) -Operation 'apksigner 证书复核' -TimeoutSec 60
    $matches = @([regex]::Matches($result.Text, '(?im)^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$'))
    if ($matches.Count -ne 1) { throw 'APK signer SHA-256 无法唯一解析。' }
    return 'sha256:' + $matches[0].Groups[1].Value.ToLowerInvariant()
}

function Get-TL1C1aBoundAccessibilitySections {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DumpsysText)
    $lines = @($DumpsysText -split "`r?`n")
    $sections = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -notmatch '(?i)^(?<indent>\s*)(?:m)?bound\s*services?\s*[:=](?<inline>.*)$') { continue }
        $headerIndent = $Matches['indent'].Length
        $section = [Collections.Generic.List[string]]::new()
        $inline = [string]$Matches['inline']
        if (-not [string]::IsNullOrWhiteSpace($inline)) { $section.Add($inline.Trim()) }
        for ($child = $index + 1; $child -lt $lines.Count; $child++) {
            $candidate = $lines[$child]
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                if ($section.Count -gt 0) { break }
                continue
            }
            $leading = $candidate.Length - $candidate.TrimStart().Length
            if ($leading -le $headerIndent) { break }
            $section.Add($candidate.Trim())
        }
        $sections.Add(($section -join "`n"))
    }
    return @($sections)
}

function Test-TL1C1aA11yReady {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$EnabledText,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BoundText
    )
    $separator = $script:TL1C1aA11yComponent.IndexOf('/')
    $packageName = $script:TL1C1aA11yComponent.Substring(0, $separator)
    $className = $script:TL1C1aA11yComponent.Substring($separator + 1)
    $shortComponent = if ($className.StartsWith("$packageName.", [StringComparison]::Ordinal)) {
        "$packageName/.$($className.Substring($packageName.Length + 1))"
    } else { $script:TL1C1aA11yComponent }
    $enabledTokens = @($EnabledText.Trim() -split ':' | Where-Object { $_ -ne '' })
    $enabledMatches = @($enabledTokens | Where-Object {
        $_ -ceq $script:TL1C1aA11yComponent -or $_ -ceq $shortComponent
    })
    $enabled = $enabledMatches.Count -eq 1
    $bound = $false
    if ($enabled) {
        $fullPattern = '(?<![A-Za-z0-9_.])' + [regex]::Escape($script:TL1C1aA11yComponent) +
            '(?![A-Za-z0-9_.])'
        $shortPattern = '(?<![A-Za-z0-9_.])' + [regex]::Escape($shortComponent) +
            '(?![A-Za-z0-9_.])'
        $labelPattern = '(?:^|[\[,{\s])label=' + [regex]::Escape($script:TL1C1aA11yLabel) + '(?=[,\]])'
        foreach ($section in @(Get-TL1C1aBoundAccessibilitySections $BoundText)) {
            if ([regex]::IsMatch($section, $fullPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                [regex]::IsMatch($section, $shortPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant) -or
                [regex]::IsMatch($section, $labelPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                $bound = $true
                break
            }
        }
    }
    return [pscustomobject]@{ Enabled=$enabled; Bound=$bound; Ready=($enabled -and $bound) }
}

function Wait-TL1C1aA11yReady {
    param(
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$Serial,
        [ValidateRange(1,45)][int]$MaximumWaitSec = 45,
        [ValidateRange(50,1000)][int]$PollIntervalMs = 1000
    )
    $enabledText = (Invoke-TL1C1aAdb $AdbPath $Serial a11y_enabled).Text
    $enabledState = Test-TL1C1aA11yReady -EnabledText $enabledText -BoundText ''
    if (-not $enabledState.Enabled) {
        return [pscustomobject]@{ Enabled=$false; Bound=$false; Ready=$false; Attempts=0; WaitMs=0L }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    while ($true) {
        $attempts++
        $boundText = (Invoke-TL1C1aAdb $AdbPath $Serial a11y_bound).Text
        $state = Test-TL1C1aA11yReady -EnabledText $enabledText -BoundText $boundText
        if ($state.Ready -or $watch.Elapsed.TotalSeconds -ge $MaximumWaitSec) {
            return [pscustomobject]@{
                Enabled=$state.Enabled; Bound=$state.Bound; Ready=$state.Ready
                Attempts=$attempts; WaitMs=[long]$watch.ElapsedMilliseconds
            }
        }
        $remainingMs = ($MaximumWaitSec * 1000) - [long]$watch.ElapsedMilliseconds
        if ($remainingMs -le 0) { continue }
        Start-Sleep -Milliseconds ([Math]::Min($PollIntervalMs, [int]$remainingMs))
    }
}

function Test-TL1C1aDeviceBinding {
    param([Parameter(Mandatory)][string]$Fingerprint, [Parameter(Mandatory)][string]$BootId)
    $fingerprint = $Fingerprint.Trim()
    $boot = $BootId.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($fingerprint) -or $fingerprint.Length -gt 1000 -or
        $fingerprint -match '[\r\n]' -or $boot -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'device fingerprint/boot_id 格式错误。'
    }
    return [pscustomobject]@{
        FingerprintHash = Get-TL1C1aSha256Text $fingerprint
        BootIdHash = Get-TL1C1aSha256Text $boot
    }
}

function New-TL1C1aRunId {
    return ('tl1-c1a-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
        [guid]::NewGuid().ToString('N').Substring(0, 12)).ToLowerInvariant()
}
