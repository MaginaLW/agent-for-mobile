#Requires -Version 7.5
# T-L1 C1b dedicated read-only artifact: fixed Android SDK aapt2 provenance and freeze guard.

Set-StrictMode -Version 3.0

$script:TL1C1bAapt2TrustSchema = 'tablet-layout-c1b-aapt2-trust/v1'
$script:TL1C1bAapt2BuildToolsVersion = '35.0.0'
$script:TL1C1bAapt2RelativePath = 'build-tools/35.0.0/aapt2.exe'
$script:TL1C1bAapt2ExpectedExecutableSha256 =
    'sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'
$script:TL1C1bAapt2ExpectedSignerSubject =
    'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'
$script:TL1C1bAapt2ExpectedCertificateSha256 =
    'sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'

if ($null -eq ('TL1C1bAapt2FileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bAapt2FileIdentityResult {
    public uint LinkCount { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bAapt2FileIdentity {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public FILETIME CreationTime;
        public FILETIME LastAccessTime;
        public FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

    public static TL1C1bAapt2FileIdentityResult Read(SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return new TL1C1bAapt2FileIdentityResult {
            LinkCount = information.NumberOfLinks,
            StableId = information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") +
                information.FileIndexLow.ToString("X8")
        };
    }
}
'@
}

function Test-TL1C1bAapt2SignerSubject {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Subject)

    return $Subject -ceq $script:TL1C1bAapt2ExpectedSignerSubject
}

function Get-TL1C1bAapt2Sha256Bytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    return 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Test-TL1C1bAapt2PathEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return [StringComparer]::OrdinalIgnoreCase.Equals($Left, $Right)
}

function Get-TL1C1bAapt2LinkType {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    $property = $Item.PSObject.Properties['LinkType']
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Resolve-TL1C1bAapt2OrdinaryDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "C1b aapt2 $Name 必须是绝对路径。"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "C1b aapt2 $Name 必须是 ordinary directory。"
    }

    # Validate every existing directory component, rather than only the leaf. This prevents a
    # lexically canonical path from reaching the SDK through an ancestor junction/symlink.
    $cursor = [IO.DirectoryInfo]$item
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace((Get-TL1C1bAapt2LinkType $cursor))) {
            throw "C1b aapt2 $Name path chain 必须无 reparse/link directory。"
        }
        $cursor = $cursor.Parent
    }
    return [IO.Path]::GetFullPath($item.FullName)
}

function Get-TL1C1bAapt2CanonicalState {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome
    )

    if (-not [OperatingSystem]::IsWindows()) {
        throw 'C1b aapt2 trust gate 只接受 Windows Authenticode 工具链。'
    }
    $repo = Resolve-TL1C1bAapt2OrdinaryDirectory $RepoRoot 'RepoRoot'
    $sdk = Resolve-TL1C1bAapt2OrdinaryDirectory $AndroidSdkRoot 'ANDROID_SDK_ROOT'
    $androidHomeCanonical = Resolve-TL1C1bAapt2OrdinaryDirectory `
        $AndroidHome 'ANDROID_HOME'
    if (-not (Test-TL1C1bAapt2PathEqual $sdk $androidHomeCanonical)) {
        throw 'C1b aapt2 canonical ANDROID_SDK_ROOT/ANDROID_HOME 必须相等。'
    }

    $buildTools = Resolve-TL1C1bAapt2OrdinaryDirectory `
        (Join-Path $sdk 'build-tools') 'build-tools'
    $versionDirectory = Resolve-TL1C1bAapt2OrdinaryDirectory `
        (Join-Path $buildTools $script:TL1C1bAapt2BuildToolsVersion) 'build-tools/35.0.0'
    $canonicalPath = [IO.Path]::GetFullPath((Join-Path $versionDirectory 'aapt2.exe'))
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $sdk `
        ($script:TL1C1bAapt2RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    if (-not (Test-TL1C1bAapt2PathEqual $canonicalPath $expectedPath)) {
        throw 'C1b aapt2 必须固定为 build-tools/35.0.0/aapt2.exe。'
    }

    $item = Get-Item -LiteralPath $canonicalPath -Force -ErrorAction Stop
    $linkType = Get-TL1C1bAapt2LinkType $item
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (-not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -cne 'HardLink') -or
        -not (Test-TL1C1bAapt2PathEqual ([IO.Path]::GetFullPath($item.FullName)) $expectedPath)) {
        throw 'C1b aapt2 必须是 canonical ordinary file，且不得经过 reparse。'
    }

    return [pscustomobject][ordered]@{
        RepoRoot = $repo
        AndroidSdkRoot = $sdk
        AndroidHome = $androidHomeCanonical
        CanonicalPath = $expectedPath
    }
}

function Get-TL1C1bAapt2TrustBinding {
    param([Parameter(Mandatory)]$TrustGuard)

    foreach ($name in @(
        'Guard', 'RepoRoot', 'AndroidSdkRoot', 'AndroidHome', 'CanonicalPath', 'FileIdentity'
    )) {
        if ($null -eq $TrustGuard.PSObject.Properties[$name]) {
            throw "C1b aapt2 trust guard 缺少 $name。"
        }
    }
    if ($TrustGuard.Guard -isnot [IO.FileStream] -or
        $TrustGuard.Guard.SafeFileHandle.IsClosed -or
        $TrustGuard.Guard.SafeFileHandle.IsInvalid -or
        -not $TrustGuard.Guard.CanRead) {
        throw 'C1b aapt2 trust guard 已关闭或不可读。'
    }

    $state = Get-TL1C1bAapt2CanonicalState `
        $TrustGuard.RepoRoot $TrustGuard.AndroidSdkRoot $TrustGuard.AndroidHome
    if (-not (Test-TL1C1bAapt2PathEqual $state.CanonicalPath $TrustGuard.CanonicalPath)) {
        throw 'C1b aapt2 trust guard canonical path 漂移。'
    }

    $identity = [TL1C1bAapt2FileIdentity]::Read($TrustGuard.Guard.SafeFileHandle)
    if ($identity.LinkCount -ne 1) {
        throw 'C1b aapt2 hardlink count 必须 exact 1。'
    }
    if ([string]$identity.StableId -cne [string]$TrustGuard.FileIdentity) {
        throw 'C1b aapt2 held handle identity 漂移。'
    }

    $savedPosition = $TrustGuard.Guard.Position
    try {
        $TrustGuard.Guard.Position = 0
        $executableSha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($TrustGuard.Guard)
        ).ToLowerInvariant()
    } finally {
        $TrustGuard.Guard.Position = $savedPosition
    }
    if ($executableSha256 -cne $script:TL1C1bAapt2ExpectedExecutableSha256) {
        throw 'C1b aapt2 executable SHA-256 与冻结值不一致。'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $state.CanonicalPath
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'C1b aapt2 Authenticode/OS trust 必须是 Valid。'
    }
    $certificate = $signature.SignerCertificate
    $subject = [string]$certificate.Subject
    if (-not (Test-TL1C1bAapt2SignerSubject $subject)) {
        throw 'C1b aapt2 Authenticode signer subject 必须精确是 Google LLC。'
    }
    $certificateBytes = [byte[]]$certificate.RawData
    try {
        $certificateSha256 = Get-TL1C1bAapt2Sha256Bytes $certificateBytes
    } finally {
        if ($certificateBytes.Length -ne 0) {
            [Array]::Clear($certificateBytes, 0, $certificateBytes.Length)
        }
    }
    if ($certificateSha256 -cne $script:TL1C1bAapt2ExpectedCertificateSha256) {
        throw 'C1b aapt2 signer certificate RawData SHA-256 与冻结值不一致。'
    }

    return [pscustomobject][ordered]@{
        schema = $script:TL1C1bAapt2TrustSchema
        trust_root = 'android_sdk_build_tools'
        build_tools_version = $script:TL1C1bAapt2BuildToolsVersion
        canonical_relative_path = $script:TL1C1bAapt2RelativePath
        sdk_roots_equal = $true
        executable_sha256 = $executableSha256
        signature_status = 'Valid'
        signature_subject = $subject
        signature_certificate_sha256 = $certificateSha256
    }
}

function Open-TL1C1bAapt2TrustGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$AndroidHome
    )

    $state = Get-TL1C1bAapt2CanonicalState $RepoRoot $AndroidSdkRoot $AndroidHome
    # FileShare.Read deliberately omits Write/Delete. The caller owns this guard and must hold it
    # across Gradle plus every artifact-proof recomputation, then dispose it in finally.
    $guard = [IO.File]::Open(
        $state.CanonicalPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $identity = [TL1C1bAapt2FileIdentity]::Read($guard.SafeFileHandle)
        if ($identity.LinkCount -ne 1) {
            throw 'C1b aapt2 hardlink count 必须 exact 1。'
        }
        $trustGuard = [pscustomobject][ordered]@{
            Guard = $guard
            RepoRoot = $state.RepoRoot
            AndroidSdkRoot = $state.AndroidSdkRoot
            AndroidHome = $state.AndroidHome
            CanonicalPath = $state.CanonicalPath
            FileIdentity = $identity.StableId
            Binding = $null
        }
        $trustGuard.Binding = Get-TL1C1bAapt2TrustBinding $trustGuard
        return $trustGuard
    } catch {
        $guard.Dispose()
        throw
    }
}

function Assert-TL1C1bAapt2TrustGuardUnchanged {
    param([Parameter(Mandatory)]$TrustGuard)

    if ($null -eq $TrustGuard.PSObject.Properties['Binding'] -or
        $null -eq $TrustGuard.Binding) {
        throw 'C1b aapt2 trust guard 缺少初始 binding。'
    }
    $current = Get-TL1C1bAapt2TrustBinding $TrustGuard
    $expectedNames = @(
        'schema', 'trust_root', 'build_tools_version', 'canonical_relative_path',
        'sdk_roots_equal', 'executable_sha256', 'signature_status', 'signature_subject',
        'signature_certificate_sha256'
    )
    $actualNames = @($TrustGuard.Binding.PSObject.Properties.Name)
    if (($actualNames -join "`n") -cne ($expectedNames -join "`n")) {
        throw 'C1b aapt2 初始 trust binding 字段集合漂移。'
    }
    foreach ($name in $expectedNames) {
        if ($current.$name -is [bool]) {
            if ([bool]$current.$name -ne [bool]$TrustGuard.Binding.$name) {
                throw "C1b aapt2 trust binding/$name 前后漂移。"
            }
        } elseif ([string]$current.$name -cne [string]$TrustGuard.Binding.$name) {
            throw "C1b aapt2 trust binding/$name 前后漂移。"
        }
    }
    return $current
}

function Get-TL1C1bNormalizedAapt2DumpSha256 {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Operation
    )

    $text = ConvertFrom-TL1C1aStrictUtf8 -Bytes $Bytes -Operation $Operation
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "$Operation 输出为空。"
    }
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $normalizedBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalized)
    try {
        return Get-TL1C1bAapt2Sha256Bytes $normalizedBytes
    } finally {
        if ($normalizedBytes.Length -ne 0) {
            [Array]::Clear($normalizedBytes, 0, $normalizedBytes.Length)
        }
    }
}

function Get-TL1C1bPackagedAxmlDumpBinding {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [Parameter(Mandatory)]$ArtifactGuard,
        [Parameter(Mandatory)][ValidateSet('debug', 'release')][string]$Variant,
        [AllowNull()][hashtable]$ProcessEnvironment,
        [switch]$ClearEnvironment
    )

    if ($null -eq $ProcessEnvironment -or -not $ClearEnvironment.IsPresent) {
        throw 'C1b aapt2 必须清空继承环境并使用显式受控 ProcessEnvironment。'
    }
    [void](Assert-TL1C1bAapt2TrustGuardUnchanged $TrustGuard)
    if ($ArtifactGuard.Guard -isnot [IO.FileStream] -or
        $ArtifactGuard.Guard.SafeFileHandle.IsClosed -or
        $ArtifactGuard.Guard.SafeFileHandle.IsInvalid -or
        -not $ArtifactGuard.Guard.CanRead -or
        [string]::IsNullOrWhiteSpace([string]$ArtifactGuard.Path) -or
        [string]$ArtifactGuard.Sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "C1b $Variant APK guard 已关闭或绑定无效。"
    }

    $savedPosition = $ArtifactGuard.Guard.Position
    try {
        $ArtifactGuard.Guard.Position = 0
        $heldSha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($ArtifactGuard.Guard)
        ).ToLowerInvariant()
    } finally {
        $ArtifactGuard.Guard.Position = $savedPosition
    }
    if ($heldSha256 -cne [string]$ArtifactGuard.Sha256) {
        throw "C1b $Variant APK held handle hash 漂移。"
    }

    $archive = [IO.Compression.ZipFile]::OpenRead([string]$ArtifactGuard.Path)
    try {
        $duplicateEntries = @($archive.Entries | Group-Object -Property FullName | Where-Object { $_.Count -ne 1 })
        if ($duplicateEntries.Count -ne 0) {
            throw "C1b $Variant APK 含重复 ZIP entry。"
        }
        $resourceEntries = @($archive.Entries | Where-Object {
            $_.FullName -cmatch '^res/(?:[^/]+/)?[^/]+\.xml$'
        })
        if ($resourceEntries.Count -ne 1) {
            throw "C1b $Variant APK compiled XML resource 必须 exact 1。"
        }
        $a11yEntry = [string]$resourceEntries[0].FullName
    } finally {
        $archive.Dispose()
    }

    $hashes = [ordered]@{}
    foreach ($entry in @(
        [pscustomobject]@{ Name = 'manifest'; RelativePath = 'AndroidManifest.xml' },
        [pscustomobject]@{ Name = 'a11y'; RelativePath = $a11yEntry }
    )) {
        $result = Invoke-TL1C1aProcess -FilePath ([string]$TrustGuard.CanonicalPath) -Arguments @(
            'dump', 'xmltree', [string]$ArtifactGuard.Path, '--file', [string]$entry.RelativePath
        ) -Operation "C1b $Variant packaged $($entry.Name) AXML dump" -TimeoutSec 30 `
            -Environment $ProcessEnvironment -ClearEnvironment
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Stderr)) {
                throw "C1b $Variant packaged $($entry.Name) AXML dump 产生 stderr。"
            }
            $hashes[$entry.Name] = Get-TL1C1bNormalizedAapt2DumpSha256 `
                -Bytes $result.Bytes -Operation "C1b $Variant packaged $($entry.Name) AXML dump"
        } finally {
            if ($result.Bytes.Length -ne 0) {
                [Array]::Clear($result.Bytes, 0, $result.Bytes.Length)
            }
        }
    }

    [void](Assert-TL1C1bAapt2TrustGuardUnchanged $TrustGuard)
    return [pscustomobject][ordered]@{
        Variant = $Variant
        ApkSha256 = $heldSha256
        A11yEntryRelativePath = $a11yEntry
        PackagedManifestAxmlDumpSha256 = $hashes.manifest
        PackagedA11yAxmlDumpSha256 = $hashes.a11y
    }
}
