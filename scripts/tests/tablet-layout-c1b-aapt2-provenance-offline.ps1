#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1')
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-aapt2.ps1')

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('tablet-layout-c1b-aapt2-provenance-' + [guid]::NewGuid().ToString('N'))
$Sentinel = Join-Path $TestRoot 'fake-aapt2-executed.txt'
$script:Passed = 0
$script:Failed = 0
$script:OfficialCheck = 'skipped'
$script:Aapt2Executions = 0
$Aapt2ExecutionLog = Join-Path $TestRoot 'fake-aapt2-dump-executions.txt'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    if ($null -eq $failure) { throw $Message }
    return $failure
}

function Assert-ThrowsLike([scriptblock]$Action, [string]$Pattern, [string]$Message) {
    $failure = Assert-Throws $Action $Message
    if ($failure.Exception.ToString() -notmatch $Pattern) {
        throw "$Message`n实际异常：$($failure.Exception.ToString())"
    }
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:Passed++
        Write-Output "PASS  $Name"
    } catch {
        $script:Failed++
        Write-Output "FAIL  $Name :: $($_.Exception.Message)"
    }
}

function New-AxmlTestApk {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateRange(1, 2)][int]$ResourceCount = 1,
        [switch]$DuplicateResource
    )
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream, [IO.Compression.ZipArchiveMode]::Create, $true
        )
        try {
            $entryNames = [Collections.Generic.List[string]]::new()
            $entryNames.Add('AndroidManifest.xml')
            $entryNames.Add('res/xml/a11y_config.xml')
            if ($ResourceCount -eq 2) { $entryNames.Add('res/xml/extra.xml') }
            if ($DuplicateResource) { $entryNames.Add('res/xml/a11y_config.xml') }
            foreach ($entryName in $entryNames) {
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::NoCompression)
                $entryStream = $entry.Open()
                try {
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes("fixture:$entryName")
                    try { $entryStream.Write($bytes) } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
                } finally { $entryStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function Open-AxmlTestArtifactGuard([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $sha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
        $stream.Position = 0
        return [pscustomobject][ordered]@{ Guard = $stream; Path = $Path; Sha256 = $sha256 }
    } catch {
        $stream.Dispose()
        throw
    }
}

function New-SdkRoot([string]$Name) {
    $sdk = Join-Path $TestRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $sdk 'build-tools\35.0.0') -Force |
        Out-Null
    return $sdk
}

function Assert-FakeNeverExecuted([string]$Context) {
    Assert-True (-not (Test-Path -LiteralPath $Sentinel -PathType Leaf)) `
        "$Context 执行了只应被读取的 fake/self-claim aapt2。"
}

function Find-OfficialAapt2 {
    $roots = @(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique
    foreach ($candidate in $roots) {
        $root = [IO.Path]::GetFullPath([string]$candidate)
        $path = Join-Path $root 'build-tools\35.0.0\aapt2.exe'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ([string]$signature.Status -cne 'Valid' -or
            $null -eq $signature.SignerCertificate -or
            -not (Test-TL1C1bAapt2SignerSubject ([string]$signature.SignerCertificate.Subject))) {
            continue
        }
        $certificateBytes = [byte[]]$signature.SignerCertificate.RawData
        try {
            $certificateSha256 = Get-TL1C1bAapt2Sha256Bytes $certificateBytes
        } finally {
            if ($certificateBytes.Length -ne 0) {
                [Array]::Clear($certificateBytes, 0, $certificateBytes.Length)
            }
        }
        $fileSha256 = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($certificateSha256 -ceq $script:TL1C1bAapt2ExpectedCertificateSha256 -and
            $fileSha256 -ceq $script:TL1C1bAapt2ExpectedExecutableSha256) {
            return [pscustomobject]@{ Root = $root; Path = $path }
        }
    }
    return $null
}

New-Item -ItemType Directory -Path $TestRoot | Out-Null
$savedSdkRoot = $env:ANDROID_SDK_ROOT
$savedAndroidHome = $env:ANDROID_HOME
try {
    $sourceDirectory = Join-Path $TestRoot 'source'
    New-Item -ItemType Directory -Path $sourceDirectory | Out-Null
    $fakeSource = Join-Path $sourceDirectory 'fake-aapt2.cs'
    $fakeExecutable = Join-Path $sourceDirectory 'fake-aapt2.exe'
    $sentinelLiteral = $Sentinel.Replace('\', '\\').Replace('"', '\"')
    $source = @"
using System;
using System.IO;
using System.Text;

public static class Program {
    public static int Main(string[] args) {
        File.WriteAllText("$sentinelLiteral", "executed", new UTF8Encoding(false));
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.Write("Android Asset Packaging Tool (aapt) 2.19-14311550\r\n" +
            "Signer: CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US\r\n" +
            "SHA256: cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564\r\n");
        return 0;
    }
}
"@
    [IO.File]::WriteAllText($fakeSource, $source, [Text.UTF8Encoding]::new($false))
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) {
        $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    Assert-True (Test-Path -LiteralPath $csc -PathType Leaf) `
        '离线测试缺少 Windows csc.exe。'
    & $csc /nologo /target:exe "/out:$fakeExecutable" $fakeSource
    Assert-True ($LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $fakeExecutable -PathType Leaf)) `
        '无法编译 unsigned fake/self-claim aapt2。'

    $dumpFakeSource = Join-Path $sourceDirectory 'fake-aapt2-dump.cs'
    $dumpFakeExecutable = Join-Path $sourceDirectory 'fake-aapt2-dump.exe'
    $dumpSource = @'
using System;
using System.IO;
using System.Text;

public static class FakeAapt2Dump {
    public static int Main(string[] args) {
        if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("TL1_C1B_FAKE_AAPT2_POISON"))) return 29;
        var log = Environment.GetEnvironmentVariable("TL1_C1B_FAKE_AAPT2_LOG");
        if (!String.IsNullOrEmpty(log)) File.AppendAllText(log, "1\n", new UTF8Encoding(false));
        var mode = Environment.GetEnvironmentVariable("TL1_C1B_FAKE_AAPT2_MODE") ?? "success";
        if (mode == "nonzero") return 23;
        if (mode == "stderr") { Console.Error.Write("synthetic stderr\n"); return 0; }
        if (mode == "invalid_utf8") {
            var output = Console.OpenStandardOutput();
            output.WriteByte(0xff);
            return 0;
        }
        if (args.Length != 5 || args[0] != "dump" || args[1] != "xmltree" ||
            args[3] != "--file") return 24;
        var text = args[4] == "AndroidManifest.xml"
            ? "N: android=http://schemas.android.com/apk/res/android\r\nE: manifest (line=2)\r\n"
            : "N: android=http://schemas.android.com/apk/res/android\r\nE: accessibility-service (line=2)\r\n";
        var bytes = new UTF8Encoding(false).GetBytes(text);
        Console.OpenStandardOutput().Write(bytes, 0, bytes.Length);
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($dumpFakeSource, $dumpSource, [Text.UTF8Encoding]::new($false))
    & $csc /nologo /target:exe "/out:$dumpFakeExecutable" $dumpFakeSource
    Assert-True ($LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $dumpFakeExecutable -PathType Leaf)) `
        '无法编译 fake aapt2 dump process。'

    $official = Find-OfficialAapt2

    Test-Case '冻结的 aapt2 path/hash/signer/certificate 常量必须 exact' {
        Assert-True ($script:TL1C1bAapt2RelativePath -ceq `
            'build-tools/35.0.0/aapt2.exe') 'aapt2 relative path 漂移。'
        Assert-True ($script:TL1C1bAapt2ExpectedExecutableSha256 -ceq `
            'sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564') `
            'aapt2 executable SHA-256 漂移。'
        Assert-True ($script:TL1C1bAapt2ExpectedCertificateSha256 -ceq `
            'sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c') `
            'aapt2 certificate SHA-256 漂移。'
        Assert-True (Test-TL1C1bAapt2SignerSubject `
            'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US') `
            '精确 Google LLC signer subject 被拒绝。'
        foreach ($spoof in @(
            'CN=Evil LLC, OU=Google LLC, O=Evil LLC, C=US',
            'CN=Google LLC Evil, O=Google LLC, L=Mountain View, S=California, C=US',
            'Google LLC'
        )) {
            Assert-True (-not (Test-TL1C1bAapt2SignerSubject $spoof)) `
                "signer subject substring 欺骗被接受：$spoof"
        }
    }

    Test-Case 'canonical SDK 中 fake/self-claim aapt2 在任何执行前 fail closed' {
        $sdk = New-SdkRoot 'unsigned-sdk'
        Copy-Item -LiteralPath $fakeExecutable -Destination `
            (Join-Path $sdk 'build-tools\35.0.0\aapt2.exe')
        Assert-ThrowsLike {
            $unexpected = Open-TL1C1bAapt2TrustGuard $RepoRoot $sdk $sdk
            try { $unexpected | Out-Null } finally { $unexpected.Guard.Dispose() }
        } 'SHA-256|Authenticode/OS trust' 'unsigned self-claim aapt2 未 fail closed。'
        Assert-FakeNeverExecuted 'unsigned canonical fake'
    }

    Test-Case 'canonical SDK roots 不相等时在文件检查和执行前拒绝' {
        $sdk = New-SdkRoot 'sdk-root-a'
        $otherSdkRoot = New-SdkRoot 'sdk-root-b'
        Copy-Item -LiteralPath $fakeExecutable -Destination `
            (Join-Path $sdk 'build-tools\35.0.0\aapt2.exe')
        Copy-Item -LiteralPath $fakeExecutable -Destination `
            (Join-Path $otherSdkRoot 'build-tools\35.0.0\aapt2.exe')
        Assert-ThrowsLike {
            Open-TL1C1bAapt2TrustGuard $RepoRoot $sdk $otherSdkRoot | Out-Null
        } 'canonical ANDROID_SDK_ROOT/ANDROID_HOME.*相等' `
            '不一致的 Android SDK roots 未 fail closed。'
        Assert-FakeNeverExecuted 'mismatched SDK roots'
    }

    Test-Case 'SDK 或 build-tools reparse path 在签名和执行前拒绝' {
        $realSdk = New-SdkRoot 'real-sdk'
        Copy-Item -LiteralPath $fakeExecutable -Destination `
            (Join-Path $realSdk 'build-tools\35.0.0\aapt2.exe')
        $sdkJunction = Join-Path $TestRoot 'sdk-junction'
        New-Item -ItemType Junction -Path $sdkJunction -Target $realSdk | Out-Null
        Assert-ThrowsLike {
            Open-TL1C1bAapt2TrustGuard $RepoRoot $sdkJunction $sdkJunction | Out-Null
        } 'reparse/link directory' 'SDK root junction 未 fail closed。'

        $nestedSdk = Join-Path $TestRoot 'nested-junction-sdk'
        New-Item -ItemType Directory -Path $nestedSdk | Out-Null
        $buildToolsTarget = Join-Path $TestRoot 'build-tools-target'
        New-Item -ItemType Directory -Path (Join-Path $buildToolsTarget '35.0.0') -Force |
            Out-Null
        Copy-Item -LiteralPath $fakeExecutable -Destination `
            (Join-Path $buildToolsTarget '35.0.0\aapt2.exe')
        New-Item -ItemType Junction -Path (Join-Path $nestedSdk 'build-tools') `
            -Target $buildToolsTarget | Out-Null
        Assert-ThrowsLike {
            Open-TL1C1bAapt2TrustGuard $RepoRoot $nestedSdk $nestedSdk | Out-Null
        } 'reparse/link directory' 'build-tools junction 未 fail closed。'
        Assert-FakeNeverExecuted 'reparse paths'
    }

    Test-Case 'canonical aapt2 hardlink count 非 1 时 fail closed' {
        $sdk = New-SdkRoot 'hardlink-sdk'
        $aapt2 = Join-Path $sdk 'build-tools\35.0.0\aapt2.exe'
        Copy-Item -LiteralPath $fakeExecutable -Destination $aapt2
        New-Item -ItemType HardLink -Path (Join-Path $TestRoot 'aapt2-alias.exe') `
            -Target $aapt2 | Out-Null
        Assert-ThrowsLike {
            Open-TL1C1bAapt2TrustGuard $RepoRoot $sdk $sdk | Out-Null
        } 'hardlink count.*1' 'aapt2 hardlink 未 fail closed。'
        Assert-FakeNeverExecuted 'hardlink aapt2'
    }

    Test-Case 'aapt2 内容篡改时 exact hash 或 Authenticode fail closed' {
        $sdk = New-SdkRoot 'tamper-sdk'
        $aapt2 = Join-Path $sdk 'build-tools\35.0.0\aapt2.exe'
        if ($null -ne $official) {
            Copy-Item -LiteralPath $official.Path -Destination $aapt2
        } else {
            Copy-Item -LiteralPath $fakeExecutable -Destination $aapt2
        }
        $bytes = [IO.File]::ReadAllBytes($aapt2)
        try {
            $offset = [Math]::Min(4096, $bytes.Length - 1)
            $bytes[$offset] = $bytes[$offset] -bxor 0x01
            [IO.File]::WriteAllBytes($aapt2, $bytes)
        } finally {
            if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        Assert-ThrowsLike {
            $unexpected = Open-TL1C1bAapt2TrustGuard $RepoRoot $sdk $sdk
            try { $unexpected | Out-Null } finally { $unexpected.Guard.Dispose() }
        } 'SHA-256|Authenticode/OS trust' '篡改后的 aapt2 未 fail closed。'
        Assert-FakeNeverExecuted 'tampered aapt2'
    }

    Test-Case '官方 aapt2 仅做只读 provenance 检查且绑定可重复' {
        if ($null -eq $official) {
            Write-Output 'INFO  official_aapt2_check=skipped (exact pinned SDK tool not present)'
            Assert-FakeNeverExecuted 'official check skip'
            return
        }
        $trust = Open-TL1C1bAapt2TrustGuard $RepoRoot $official.Root $official.Root
        try {
            Assert-True ($trust.CanonicalPath -ceq $official.Path) `
                '官方 aapt2 canonical path 未绑定。'
            Assert-True ($trust.Binding.executable_sha256 -ceq `
                $script:TL1C1bAapt2ExpectedExecutableSha256) '官方 aapt2 hash 不符。'
            Assert-True ($trust.Binding.signature_status -ceq 'Valid') `
                '官方 aapt2 Authenticode 非 Valid。'
            Assert-True ($trust.Binding.signature_subject -ceq `
                $script:TL1C1bAapt2ExpectedSignerSubject) '官方 aapt2 subject 不符。'
            Assert-True ($trust.Binding.signature_certificate_sha256 -ceq `
                $script:TL1C1bAapt2ExpectedCertificateSha256) '官方 aapt2 certificate hash 不符。'
            $after = Assert-TL1C1bAapt2TrustGuardUnchanged $trust
            Assert-True ($after.executable_sha256 -ceq $trust.Binding.executable_sha256) `
                '官方 aapt2 held-handle 前后绑定不稳定。'
        } finally {
            $trust.Guard.Dispose()
        }
        $script:OfficialCheck = 'passed'
        Assert-FakeNeverExecuted 'official aapt2 read-only trust check'
    }

    Test-Case 'held guard 对安全临时副本持续 deny-write/delete 并可复核' {
        if ($null -eq $official) {
            Write-Output 'INFO  held_guard_share_check=skipped (exact pinned SDK tool not present)'
            Assert-FakeNeverExecuted 'held guard check skip'
            return
        }
        $sdk = New-SdkRoot 'guard-sdk'
        $aapt2 = Join-Path $sdk 'build-tools\35.0.0\aapt2.exe'
        Copy-Item -LiteralPath $official.Path -Destination $aapt2
        $trust = Open-TL1C1bAapt2TrustGuard $RepoRoot $sdk $sdk
        try {
            Assert-Throws {
                $writer = [IO.File]::Open(
                    $aapt2,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite
                )
                try { $writer | Out-Null } finally { $writer.Dispose() }
            } 'held aapt2 guard 未 deny write。' | Out-Null
            Assert-Throws {
                [IO.File]::Delete($aapt2)
            } 'held aapt2 guard 未 deny delete。' | Out-Null
            Assert-True (Test-Path -LiteralPath $aapt2 -PathType Leaf) `
                'deny-delete 测试意外删除了临时 aapt2。'
            $after = Assert-TL1C1bAapt2TrustGuardUnchanged $trust
            Assert-True ($after.signature_certificate_sha256 -ceq `
                $trust.Binding.signature_certificate_sha256) 'held guard 复核绑定漂移。'
        } finally {
            $trust.Guard.Dispose()
        }
        Assert-FakeNeverExecuted 'held guard share check'
    }

    # The provenance tests above exercise the real trust gate without ever executing an
    # untrusted binary. The following block replaces only the trust *recheck* so the production
    # packaged-AXML dump function can be exercised against an isolated fake process.
    $originalTrustRecheck = (Get-Item Function:Assert-TL1C1bAapt2TrustGuardUnchanged).ScriptBlock
    $savedFakeDumpLog = $env:TL1_C1B_FAKE_AAPT2_LOG
    $savedFakeDumpMode = $env:TL1_C1B_FAKE_AAPT2_MODE
    $savedFakeDumpPoison = $env:TL1_C1B_FAKE_AAPT2_POISON
    $fakeTrustStream = [IO.File]::Open(
        $dumpFakeExecutable, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read
    )
    $fakeTrust = [pscustomobject][ordered]@{
        Guard = $fakeTrustStream
        CanonicalPath = $dumpFakeExecutable
        Binding = [pscustomobject][ordered]@{ schema = 'synthetic-test-only' }
    }
    Set-Item Function:Assert-TL1C1bAapt2TrustGuardUnchanged -Value {
        param([Parameter(Mandatory)]$TrustGuard)
        if ($TrustGuard.Binding.schema -cne 'synthetic-test-only') {
            throw 'unexpected synthetic trust binding'
        }
        return $TrustGuard.Binding
    }
    $aapt2ProcessEnvironment = @{
        SystemRoot = [string]$env:SystemRoot
        WINDIR = [string]$env:WINDIR
        TEMP = $TestRoot
        TMP = $TestRoot
        TL1_C1B_FAKE_AAPT2_LOG = $Aapt2ExecutionLog
        TL1_C1B_FAKE_AAPT2_MODE = 'success'
    }
    $env:TL1_C1B_FAKE_AAPT2_LOG = $Aapt2ExecutionLog
    $env:TL1_C1B_FAKE_AAPT2_POISON = 'must-not-reach-cleared-aapt2'
    try {
        Test-Case 'production dump helper 在执行前强制显式环境与 ClearEnvironment' {
            $apk = Join-Path $TestRoot 'environment-required.apk'; New-AxmlTestApk $apk
            $guard = Open-AxmlTestArtifactGuard $apk
            $before = if(Test-Path -LiteralPath $Aapt2ExecutionLog){@(Get-Content -LiteralPath $Aapt2ExecutionLog).Count}else{0}
            try {
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ProcessEnvironment $aapt2ProcessEnvironment | Out-Null
                } '清空继承环境' 'aapt2 缺少 ClearEnvironment 时未 fail closed。'
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ClearEnvironment | Out-Null
                } '显式受控 ProcessEnvironment' 'aapt2 缺少 ProcessEnvironment 时未 fail closed。'
            } finally { $guard.Guard.Dispose() }
            $after = if(Test-Path -LiteralPath $Aapt2ExecutionLog){@(Get-Content -LiteralPath $Aapt2ExecutionLog).Count}else{0}
            Assert-True ($after -eq $before) 'aapt2 环境闭包失败时仍执行了外部进程。'
        }

        Test-Case 'production dump helper 执行四次并按 CRLF→LF 规范化 hash' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'success'
            foreach ($variant in @('debug', 'release')) {
                $apk = Join-Path $TestRoot "$variant-success.apk"
                New-AxmlTestApk $apk
                $guard = Open-AxmlTestArtifactGuard $apk
                try {
                    $binding = Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard $variant `
                        -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment
                    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                        "N: android=http://schemas.android.com/apk/res/android`r`nE: manifest (line=2)`r`n"
                    )
                    $a11yBytes = [Text.UTF8Encoding]::new($false).GetBytes(
                        "N: android=http://schemas.android.com/apk/res/android`r`nE: accessibility-service (line=2)`r`n"
                    )
                    try {
                        Assert-True ($binding.PackagedManifestAxmlDumpSha256 -ceq
                            (Get-TL1C1bNormalizedAapt2DumpSha256 $manifestBytes 'expected manifest')) `
                            "$variant manifest normalized dump hash 漂移。"
                        Assert-True ($binding.PackagedA11yAxmlDumpSha256 -ceq
                            (Get-TL1C1bNormalizedAapt2DumpSha256 $a11yBytes 'expected a11y')) `
                            "$variant a11y normalized dump hash 漂移。"
                        Assert-True ($binding.A11yEntryRelativePath -ceq 'res/xml/a11y_config.xml') `
                            "$variant unique a11y entry 未绑定。"
                    } finally {
                        [Array]::Clear($manifestBytes, 0, $manifestBytes.Length)
                        [Array]::Clear($a11yBytes, 0, $a11yBytes.Length)
                    }
                } finally { $guard.Guard.Dispose() }
            }
            Assert-True (@(Get-Content -LiteralPath $Aapt2ExecutionLog).Count -eq 4) `
                'success dump 外部调用数不是 exact 4。'
        }

        Test-Case 'production dump helper 拒绝非空 stderr' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'stderr'
            $apk = Join-Path $TestRoot 'stderr.apk'; New-AxmlTestApk $apk
            $guard = Open-AxmlTestArtifactGuard $apk
            try {
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment | Out-Null
                } '产生 stderr' 'aapt2 stderr 未 fail closed。'
            } finally { $guard.Guard.Dispose() }
        }

        Test-Case 'production dump helper 拒绝 nonzero exit' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'nonzero'
            $apk = Join-Path $TestRoot 'nonzero.apk'; New-AxmlTestApk $apk
            $guard = Open-AxmlTestArtifactGuard $apk
            try {
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment | Out-Null
                } '失败.*exit=23' 'aapt2 nonzero exit 未 fail closed。'
            } finally { $guard.Guard.Dispose() }
        }

        Test-Case 'production dump helper 拒绝非 strict UTF-8 stdout' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'invalid_utf8'
            $apk = Join-Path $TestRoot 'invalid-utf8.apk'; New-AxmlTestApk $apk
            $guard = Open-AxmlTestArtifactGuard $apk
            try {
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment | Out-Null
                } 'strict UTF-8' 'aapt2 invalid UTF-8 未 fail closed。'
            } finally { $guard.Guard.Dispose() }
        }

        Test-Case 'production dump helper 在执行前拒绝重复或多 compiled XML' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'success'
            $before = @(Get-Content -LiteralPath $Aapt2ExecutionLog).Count
            foreach ($fixture in @(
                [pscustomobject]@{ Name = 'duplicate'; ResourceCount = 1; Duplicate = $true },
                [pscustomobject]@{ Name = 'multiple'; ResourceCount = 2; Duplicate = $false }
            )) {
                $apk = Join-Path $TestRoot "$($fixture.Name).apk"
                New-AxmlTestApk $apk -ResourceCount $fixture.ResourceCount `
                    -DuplicateResource:$fixture.Duplicate
                $guard = Open-AxmlTestArtifactGuard $apk
                try {
                    Assert-Throws {
                        Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                            -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment | Out-Null
                    } "$($fixture.Name) compiled XML 未 fail closed。" | Out-Null
                } finally { $guard.Guard.Dispose() }
            }
            Assert-True (@(Get-Content -LiteralPath $Aapt2ExecutionLog).Count -eq $before) `
                '畸形 ZIP 在 fail-closed 前执行了 aapt2。'
        }

        Test-Case 'production dump helper 在执行前拒绝 APK guard hash 漂移' {
            $aapt2ProcessEnvironment.TL1_C1B_FAKE_AAPT2_MODE = 'success'
            $before = @(Get-Content -LiteralPath $Aapt2ExecutionLog).Count
            $apk = Join-Path $TestRoot 'guard-drift.apk'; New-AxmlTestApk $apk
            $guard = Open-AxmlTestArtifactGuard $apk
            try {
                $guard.Sha256 = 'sha256:' + ('0' * 64)
                Assert-ThrowsLike {
                    Get-TL1C1bPackagedAxmlDumpBinding $fakeTrust $guard debug `
                        -ProcessEnvironment $aapt2ProcessEnvironment -ClearEnvironment | Out-Null
                } 'held handle hash 漂移' 'APK guard hash 漂移未 fail closed。'
            } finally { $guard.Guard.Dispose() }
            Assert-True (@(Get-Content -LiteralPath $Aapt2ExecutionLog).Count -eq $before) `
                'APK guard 漂移时仍执行了 aapt2。'
        }
    } finally {
        $script:Aapt2Executions = if (Test-Path -LiteralPath $Aapt2ExecutionLog -PathType Leaf) {
            @(Get-Content -LiteralPath $Aapt2ExecutionLog).Count
        } else { 0 }
        Set-Item Function:Assert-TL1C1bAapt2TrustGuardUnchanged -Value $originalTrustRecheck
        $fakeTrustStream.Dispose()
        $env:TL1_C1B_FAKE_AAPT2_LOG = $savedFakeDumpLog
        $env:TL1_C1B_FAKE_AAPT2_MODE = $savedFakeDumpMode
        $env:TL1_C1B_FAKE_AAPT2_POISON = $savedFakeDumpPoison
    }
} finally {
    $env:ANDROID_SDK_ROOT = $savedSdkRoot
    $env:ANDROID_HOME = $savedAndroidHome
    $safeRoot = [IO.Path]::GetFullPath($TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ([IO.Path]::GetDirectoryName($safeRoot) -cne $tempRoot) {
        throw 'aapt2 离线测试清理目标越界。'
    }
    if (Test-Path -LiteralPath $safeRoot) {
        Remove-Item -LiteralPath $safeRoot -Recurse -Force
    }
}

Write-Output "INFO  official_aapt2_check=$script:OfficialCheck"
Write-Output "tablet-layout-c1b aapt2 provenance offline: $script:Passed passed, $script:Failed failed, $script:Aapt2Executions aapt2 executions"
if ($script:Failed -ne 0) { exit 1 }
