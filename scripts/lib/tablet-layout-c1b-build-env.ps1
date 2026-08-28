#Requires -Version 7.5
# T-L1 C1b dedicated read-only artifact: fixed JDK/Gradle build-environment trust guard.

Set-StrictMode -Version 3.0

$script:TL1C1bBuildEnvironmentTrustSchema = 'tablet-layout-c1b-build-environment-trust/v1'
$script:TL1C1bBuildEnvironmentRecoverySchema =
    'tablet-layout-c1b-build-environment-acl-recovery/v1'
$script:TL1C1bBuildEnvironmentThreatBoundary =
    'filesystem-and-environment integrity after guard establishment; excludes same-user process-memory injection, pre-existing writable handles/mappings, ACL/ownership takeover, and same-user concurrent mutation of all intentionally writable fresh build working state (including dependency/project/Kotlin caches, process temp, Gradle daemon/native/transform state, and module outputs) during Gradle execution and the post-exit-to-final-guard window'
$script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $null
$script:TL1C1bBuildEnvironmentActiveMutexNames =
    [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

$script:TL1C1bBuildEnvironmentJdkVendor = 'Oracle Corporation'
$script:TL1C1bBuildEnvironmentJdkVersion = '21.0.5'
$script:TL1C1bBuildEnvironmentJdkArchiveSha256 =
    'sha256:6cce98ce38b86737c63912fd1df9ecfee1fe209ab08c0e1e16500f054e67de48'
$script:TL1C1bBuildEnvironmentJdkFileCount = 418
$script:TL1C1bBuildEnvironmentJdkCatalogSha256 =
    'sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9'
$script:TL1C1bBuildEnvironmentJdkKeyFiles = [ordered]@{
    'bin/java.exe' = 'sha256:e66f719f6cfedc986d5f30012793d61ee4b26673de00cb9d28353a1b8833b496'
    'bin/server/jvm.dll' = 'sha256:d56cf961f03e1af960b390103b3f03e27faf324a1ffb801e84155b4386dc47a6'
    'release' = 'sha256:66815dfd67d03fa9f48a4268296ff18baf3bfbb287b1898f00acd17dc55a4bde'
    'lib/modules' = 'sha256:9372088036cfd572a9636e0df08960ac8d4de2aa0c772e08608c0abf50f13edd'
}
$script:TL1C1bBuildEnvironmentJdkSignerSubject =
    'CN="Oracle America, Inc.", O="Oracle America, Inc.", L=Redwood City, S=California, C=US'
$script:TL1C1bBuildEnvironmentJdkSignerCertificateSha256 =
    'sha256:4b59d847d7187ed910590d52798fd7e6fcb13396092fdbc1fe43b2311aab6eeb'

$script:TL1C1bBuildEnvironmentGradleVersion = '8.9'
$script:TL1C1bBuildEnvironmentGradleDistribution = 'gradle-8.9-bin'
$script:TL1C1bBuildEnvironmentGradleFileCount = 299
$script:TL1C1bBuildEnvironmentGradleCatalogSha256 =
    'sha256:d0974b974d9471723cccf083f59e8772448b5bb6672f479bddd63897ba665189'
$script:TL1C1bBuildEnvironmentGradleCliMainSha256 =
    'sha256:3a4ccf05dec4dda1a5bc44b6639542b4fb9100b78b6d610517db16c6bbe26137'
$script:TL1C1bBuildEnvironmentGradleInstrumentationAgentSha256 =
    'sha256:56e23876af24d37a597a820d4e6f866dceac8ab5f1c3450a8132c31c7ce0f6c0'

$script:TL1C1bBuildEnvironmentAndroidBuildToolsVersion = '35.0.0'
$script:TL1C1bBuildEnvironmentAndroidBuildToolsFileCount = 170
$script:TL1C1bBuildEnvironmentAndroidBuildToolsCatalogSha256 =
    'sha256:a832390563b10614954d13f682e2848bd4d9815480c6fe3ef8a42361a356e782'
$script:TL1C1bBuildEnvironmentAndroidBuildToolsKeyFiles = [ordered]@{
    'source.properties' = 'sha256:084847d70abc41284feee7ea717e7c92eab0d1be05f048c27445a359cfe109d8'
    'package.xml' = 'sha256:43b68163de67b4ef1816059a6934d819fa951688433bc2fac849b825eeeaaf3c'
    'lib/apksigner.jar' = 'sha256:00ef9948f843fe395d2440ae3ef41405b8040a6d5d46493bd1902ac0ee6deae7'
}
$script:TL1C1bBuildEnvironmentAndroidPlatformVersion = 'android-35'
$script:TL1C1bBuildEnvironmentAndroidPlatformFileCount = 11163
$script:TL1C1bBuildEnvironmentAndroidPlatformCatalogSha256 =
    'sha256:33a80cd529f09e178d1202351e8cf14d6ab2cb21b931b085194a5d7fe3156248'
$script:TL1C1bBuildEnvironmentAndroidPlatformKeyFiles = [ordered]@{
    'android.jar' = 'sha256:4566663c3876e022b4fa4ced8c8697c4ab1688267f090114fd92d027b32e619b'
    'source.properties' = 'sha256:2c3764446f335ad2cc44383a0360fe247620b7c774ec100d5087771ac8ed3b28'
    'package.xml' = 'sha256:d1d333d5cf7f7be677871ab043cdd10665bd1636cdb7d8d173561ea0e4554435'
    'framework.aidl' = 'sha256:732ec4d49719b7473549d2010d37380946b52bfc2600b5f7fcecf549017e88b2'
    'core-for-system-modules.jar' = 'sha256:4279b723c69c851cea46a36d75ffd294649ec041176c0b786bafe62d1d1af1a6'
}
$script:TL1C1bBuildEnvironmentAndroidPlatformToolsVersion = '37.0.1'
$script:TL1C1bBuildEnvironmentAndroidPlatformToolsFileCount = 15
$script:TL1C1bBuildEnvironmentAndroidPlatformToolsCatalogSha256 =
    'sha256:98c794076c786c9d7f921d419ae87f5c8a93601e5f149a8dbcb3be1570a3866b'
$script:TL1C1bBuildEnvironmentAndroidPlatformToolsKeyFiles = [ordered]@{
    'package.xml' = 'sha256:55d46ccebf3bba4ad4349d3747643bb0ed38aac843ce6c87782b009328f73e1e'
    'source.properties' = 'sha256:2dccd788c0234d8cf7f7457377e57f57527a86a629c6ed54feb8af0f549dac38'
}
$script:TL1C1bBuildEnvironmentIsolatedAndroidSdkFileCount = 11348
$script:TL1C1bBuildEnvironmentIsolatedAndroidSdkCatalogSha256 =
    'sha256:09a7cb46fef3c2b505330e4dfa09abbe4ba739412e8450e97b3458ddbaf473d8'

$script:TL1C1bBuildEnvironmentGitVersion = '2.55.0.windows.3'
$script:TL1C1bBuildEnvironmentGitFileCount = 9576
$script:TL1C1bBuildEnvironmentGitIdentityCount = 9489
$script:TL1C1bBuildEnvironmentGitInternalHardlinkGroupCount = 85
$script:TL1C1bBuildEnvironmentGitCatalogSha256 =
    'sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458'
$script:TL1C1bBuildEnvironmentGitKeyFiles = [ordered]@{
    'cmd/git.exe' =
        'sha256:7b7971dd13f0c3a284e538601f2f9770b3a87dfaccb5fb52d68141c67ed22364'
    'mingw64/bin/git.exe' =
        'sha256:1a0043555d254618f2d56c936c3d9a1fbfb878bc878416a133c346bc7835eda9'
    'mingw64/libexec/git-core/git.exe' =
        'sha256:1a0043555d254618f2d56c936c3d9a1fbfb878bc878416a133c346bc7835eda9'
    'mingw64/bin/libcurl-4.dll' =
        'sha256:799f7eefc3c9da9c80ec5aea221a02b3afe2c5350c6b45fd5a4865e7e2d4e574'
    'mingw64/bin/libssl-3-x64.dll' =
        'sha256:feb5b300e0b3a021fed481178f3d66896426576d4d13b85a304d2a3809b25bfd'
    'mingw64/bin/libcrypto-3-x64.dll' =
        'sha256:0330b5f558996f297d687e1a2b2fcc2cacf883b16baef74aaef35285d7c1231c'
}
$script:TL1C1bBuildEnvironmentGitSignerSubject =
    'CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE'
$script:TL1C1bBuildEnvironmentGitSignerCertificateSha256 =
    'sha256:1668941fff36fec818a596ffde6589f34daa6c6434069e60f356b7755f084e63'

$script:TL1C1bBuildEnvironmentDangerousExactNames = [string[]]@(
    'JAVA_TOOL_OPTIONS'
    '_JAVA_OPTIONS'
    'JDK_JAVA_OPTIONS'
    'JAVA_OPTS'
    'CLASSPATH'
    'MAVEN_OPTS'
    'ANT_OPTS'
    'ANDROID_SDK_HOME'
    'ANDROID_USER_HOME'
    'ANDROID_PREFS_ROOT'
    'ANDROID_AVD_HOME'
)
$script:TL1C1bBuildEnvironmentDangerousPrefixes = [string[]]@(
    'GRADLE_'
    'ORG_GRADLE_PROJECT_'
    'SYSTEM_PROP_'
    'KOTLIN_'
    'GIT_'
)

if ($null -eq ('TL1C1bBuildEnvironmentFileIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bBuildEnvironmentFileIdentityResult {
    public uint LinkCount { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bBuildEnvironmentFileIdentity {
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string path, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    public static SafeFileHandle OpenDirectoryDenyDelete(string path) {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static TL1C1bBuildEnvironmentFileIdentityResult Read(SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return new TL1C1bBuildEnvironmentFileIdentityResult {
            LinkCount = information.NumberOfLinks,
            StableId = information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") +
                information.FileIndexLow.ToString("X8")
        };
    }
}
'@
}

function Test-TL1C1bBuildEnvironmentPathEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftCanonical = [IO.Path]::GetFullPath($Left).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    $rightCanonical = [IO.Path]::GetFullPath($Right).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    return [StringComparer]::OrdinalIgnoreCase.Equals(
        $leftCanonical, $rightCanonical)
}

function ConvertTo-TL1C1bBuildEnvironmentComparableAccessSddl {
    param([Parameter(Mandatory)][string]$Sddl)

    if (-not $Sddl.StartsWith('D:', [StringComparison]::Ordinal)) {
        throw 'C1b access SDDL 缺少 DACL 前缀。'
    }
    $body = $Sddl.Substring(2)
    $aceStart = $body.IndexOf('(', [StringComparison]::Ordinal)
    if ($aceStart -lt 0) {
        $flags = $body
        $aces = ''
    } else {
        $flags = $body.Substring(0, $aceStart)
        $aces = $body.Substring($aceStart)
    }
    if ($flags -cnotmatch '^(?:(?:P|AR|AI))*$') {
        throw 'C1b access SDDL control flags 不在 closed allowlist。'
    }
    $normalizedFlags = ''
    if ($flags.Contains('P', [StringComparison]::Ordinal)) { $normalizedFlags += 'P' }
    if ($flags.Contains('AR', [StringComparison]::Ordinal)) { $normalizedFlags += 'AR' }
    # Windows may add the DACL_AUTO_INHERITED (AI) control bit when SetAccessControl writes an
    # otherwise byte-for-byte equivalent inherited DACL. AI is metadata about how the same ACEs
    # were obtained; P/AR, ACE order, identities, inheritance flags and rights remain exact.
    return 'D:' + $normalizedFlags + $aces
}

function Test-TL1C1bBuildEnvironmentAccessSddlEquivalent {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return (ConvertTo-TL1C1bBuildEnvironmentComparableAccessSddl $Left) -ceq
        (ConvertTo-TL1C1bBuildEnvironmentComparableAccessSddl $Right)
}

function Get-TL1C1bBuildEnvironmentLinkType {
    param([Parameter(Mandatory)][IO.FileSystemInfo]$Item)

    $property = $Item.PSObject.Properties['LinkType']
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

function Get-TL1C1bBuildEnvironmentSha256Bytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    return 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Get-TL1C1bBuildEnvironmentSha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    try { return Get-TL1C1bBuildEnvironmentSha256Bytes $bytes }
    finally {
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-TL1C1bBuildEnvironmentStreamSha256 {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    if ($Stream.SafeFileHandle.IsClosed -or $Stream.SafeFileHandle.IsInvalid -or
        -not $Stream.CanRead) {
        throw 'C1b build-environment file guard 已关闭或不可读。'
    }
    $savedPosition = $Stream.Position
    try {
        $Stream.Position = 0
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($Stream)
        ).ToLowerInvariant()
    } finally {
        $Stream.Position = $savedPosition
    }
}

function Get-TL1C1bBuildEnvironmentSnapshot {
    $snapshot = [ordered]@{}
    foreach ($entry in Get-ChildItem Env:) {
        $snapshot[[string]$entry.Name] = [string]$entry.Value
    }
    return $snapshot
}

function Assert-TL1C1bBuildEnvironmentVariablesClean {
    param([Collections.IDictionary]$EnvironmentSnapshot)

    if ($null -eq $EnvironmentSnapshot) {
        $EnvironmentSnapshot = Get-TL1C1bBuildEnvironmentSnapshot
    }
    foreach ($rawName in $EnvironmentSnapshot.Keys) {
        $name = [string]$rawName
        $upper = $name.ToUpperInvariant()
        if ($script:TL1C1bBuildEnvironmentDangerousExactNames -ccontains $upper) {
            throw "C1b build-environment 拒绝环境注入变量：$name。"
        }
        foreach ($prefix in $script:TL1C1bBuildEnvironmentDangerousPrefixes) {
            if ($upper.StartsWith($prefix, [StringComparison]::Ordinal)) {
                throw "C1b build-environment 拒绝环境注入变量：$name。"
            }
        }
    }
}

function Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not [OperatingSystem]::IsWindows()) {
        throw 'C1b build-environment trust gate 只接受 Windows。'
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "C1b build-environment $Name 必须是绝对路径。"
    }
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        throw "C1b build-environment $Name 必须是 ordinary directory。"
    }
    $cursor = [IO.DirectoryInfo]$item
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace(
                (Get-TL1C1bBuildEnvironmentLinkType $cursor))) {
            throw "C1b build-environment $Name path chain 必须无 reparse/link directory。"
        }
        $cursor = $cursor.Parent
    }
    return [IO.Path]::GetFullPath($item.FullName)
}

function Get-TL1C1bBuildEnvironmentTreeInventory {
    param([Parameter(Mandatory)][string]$Root)

    $canonicalRoot = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $Root 'tree root'
    $directories = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[string]]::new()
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($canonicalRoot)
    while ($pending.Count -ne 0) {
        $directory = $pending.Dequeue()
        foreach ($entryPath in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $item = Get-Item -LiteralPath $entryPath -Force -ErrorAction Stop
            $linkType = Get-TL1C1bBuildEnvironmentLinkType $item
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (-not [string]::IsNullOrWhiteSpace($linkType) -and
                    $linkType -cne 'HardLink')) {
                throw 'C1b build-environment tree 必须无 reparse/link entry。'
            }
            $relative = [IO.Path]::GetRelativePath($canonicalRoot, $item.FullName).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative) -or
                $relative.Contains("`r") -or $relative.Contains("`n") -or
                $relative.Contains('=') -or [IO.Path]::IsPathFullyQualified($relative) -or
                $relative -cmatch '(^|/)\.\.(/|$)') {
                throw 'C1b build-environment tree relative path 不可安全编目。'
            }
            if ($item.PSIsContainer) {
                $directories.Add($relative)
                $pending.Enqueue([IO.Path]::GetFullPath($item.FullName))
            } elseif ([IO.File]::Exists($item.FullName)) {
                $files.Add($relative)
            } else {
                throw 'C1b build-environment tree 只接受 ordinary file/directory。'
            }
        }
    }
    $directoryArray = $directories.ToArray()
    $fileArray = $files.ToArray()
    [Array]::Sort($directoryArray, [StringComparer]::Ordinal)
    [Array]::Sort($fileArray, [StringComparer]::Ordinal)
    return [pscustomobject][ordered]@{
        Root = $canonicalRoot
        Directories = $directoryArray
        Files = $fileArray
    }
}

function Get-TL1C1bBuildEnvironmentCatalogSha256 {
    param([Parameter(Mandatory)][object[]]$Entries)

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        if ([string]$entry.RelativePath -cmatch '[\r\n=]' -or
            [string]$entry.Sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw 'C1b build-environment tree catalog entry 无效。'
        }
        $lines.Add("$($entry.RelativePath)=$($entry.Sha256)")
    }
    return Get-TL1C1bBuildEnvironmentSha256Text ($lines -join "`n")
}

function Close-TL1C1bBuildEnvironmentTreeGuard {
    param([AllowNull()]$TreeGuard)

    if ($null -eq $TreeGuard) { return }
    foreach ($entry in @($TreeGuard.Entries)) {
        if ($entry.Stream -is [IO.FileStream]) { $entry.Stream.Dispose() }
    }
}

function Resolve-TL1C1bBuildEnvironmentRepoRelativePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        $RelativePath.Contains('\') -or $RelativePath.Contains("`r") -or
        $RelativePath.Contains("`n") -or $RelativePath.Contains('=') -or
        [IO.Path]::IsPathFullyQualified($RelativePath) -or
        $RelativePath -cmatch '(^|/)\.\.(/|$)') {
        throw "C1b $Name 必须是 canonical repo-relative forward-slash path。"
    }
    $root = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $RepoRoot 'RepoRoot'
    $full = [IO.Path]::GetFullPath((Join-Path $root `
        ($RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $roundTrip = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
    if ($roundTrip -cne $RelativePath) {
        throw "C1b $Name repo-relative path round-trip 漂移。"
    }
    if ($Directory) {
        return Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $full $Name
    }
    [void](Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($full)) "$Name parent")
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    $linkType = Get-TL1C1bBuildEnvironmentLinkType $item
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (-not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -cne 'HardLink') -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetFullPath($item.FullName)) $full)) {
        throw "C1b $Name 必须是 canonical ordinary file。"
    }
    return $full
}

function Close-TL1C1bBuildEnvironmentFileSetGuard {
    param([AllowNull()]$FileSetGuard)

    if ($null -eq $FileSetGuard) { return }
    foreach ($entry in @($FileSetGuard.Entries)) {
        if ($entry.Stream -is [IO.FileStream]) { $entry.Stream.Dispose() }
    }
}

function Open-TL1C1bBuildEnvironmentFileSetGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RelativePaths,
        [Parameter(Mandatory)][string]$Name
    )

    $paths = [string[]]@($RelativePaths)
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    for ($index = 0; $index -lt $paths.Count; $index++) {
        if ($index -gt 0 -and $paths[$index] -ceq $paths[$index - 1]) {
            throw "C1b $Name relative path 不得重复。"
        }
    }
    $entries = [Collections.Generic.List[object]]::new()
    try {
        foreach ($relative in $paths) {
            $path = Resolve-TL1C1bBuildEnvironmentRepoRelativePath `
                $RepoRoot $relative "$Name input"
            $stream = [IO.File]::Open(
                $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try {
                $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
                    $stream.SafeFileHandle)
                if ($identity.LinkCount -ne 1) {
                    throw "C1b $Name hardlink count 必须 exact 1：$relative。"
                }
                $entries.Add([pscustomobject][ordered]@{
                    RelativePath = $relative
                    Path = $path
                    Sha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $stream
                    FileIdentity = $identity.StableId
                    Stream = $stream
                })
            } catch { $stream.Dispose(); throw }
        }
        $guard = [pscustomobject][ordered]@{
            Name = $Name
            RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
            Entries = $entries.ToArray()
            CatalogSha256 = Get-TL1C1bBuildEnvironmentCatalogSha256 $entries.ToArray()
        }
        [void](Assert-TL1C1bBuildEnvironmentFileSetGuardUnchanged $guard)
        return $guard
    } catch {
        foreach ($entry in $entries) { $entry.Stream.Dispose() }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentFileSetGuardUnchanged {
    param([Parameter(Mandatory)]$FileSetGuard)

    $current = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($FileSetGuard.Entries)) {
        if ($entry.Stream -isnot [IO.FileStream] -or
            $entry.Stream.SafeFileHandle.IsClosed -or
            $entry.Stream.SafeFileHandle.IsInvalid -or -not $entry.Stream.CanRead) {
            throw "C1b $($FileSetGuard.Name) held input guard 已关闭。"
        }
        $path = Resolve-TL1C1bBuildEnvironmentRepoRelativePath `
            $FileSetGuard.RepoRoot $entry.RelativePath "$($FileSetGuard.Name) input"
        $heldIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $entry.Stream.SafeFileHandle)
        $heldSha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $entry.Stream
        $pathStream = [IO.File]::Open(
            $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $pathIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
                $pathStream.SafeFileHandle)
            $pathSha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $pathStream
        } finally { $pathStream.Dispose() }
        if ($heldIdentity.LinkCount -ne 1 -or $pathIdentity.LinkCount -ne 1 -or
            [string]$heldIdentity.StableId -cne [string]$entry.FileIdentity -or
            [string]$pathIdentity.StableId -cne [string]$entry.FileIdentity -or
            $heldSha256 -cne [string]$entry.Sha256 -or
            $pathSha256 -cne [string]$entry.Sha256) {
            throw "C1b $($FileSetGuard.Name) held/current input 绑定漂移。"
        }
        $current.Add([pscustomobject][ordered]@{
            RelativePath = [string]$entry.RelativePath
            Sha256 = $heldSha256
        })
    }
    $catalog = Get-TL1C1bBuildEnvironmentCatalogSha256 $current.ToArray()
    if ($catalog -cne [string]$FileSetGuard.CatalogSha256) {
        throw "C1b $($FileSetGuard.Name) input catalog 漂移。"
    }
    return [pscustomobject][ordered]@{
        file_count = @($FileSetGuard.Entries).Count
        catalog_sha256 = $catalog
    }
}

function Open-TL1C1bBuildEnvironmentExternalFileGuard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "C1b $Name 必须是绝对路径。"
    }
    $full = [IO.Path]::GetFullPath($Path)
    [void](Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($full)) "$Name parent")
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace((Get-TL1C1bBuildEnvironmentLinkType $item))) {
        throw "C1b $Name 必须是 ordinary non-link file。"
    }
    $stream = [IO.File]::Open(
        $full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
        if ($identity.LinkCount -ne 1) {
            throw "C1b $Name hardlink count 必须 exact 1。"
        }
        return [pscustomobject][ordered]@{
            Name = $Name
            Path = $full
            Sha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $stream
            StableId = $identity.StableId
            Stream = $stream
        }
    } catch { $stream.Dispose(); throw }
}

function Assert-TL1C1bBuildEnvironmentExternalFileGuardUnchanged {
    param([Parameter(Mandatory)]$Guard)

    if ($Guard.Stream -isnot [IO.FileStream] -or
        $Guard.Stream.SafeFileHandle.IsClosed -or $Guard.Stream.SafeFileHandle.IsInvalid) {
        throw "C1b $($Guard.Name) held guard 已关闭。"
    }
    $full = [IO.Path]::GetFullPath($Guard.Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace((Get-TL1C1bBuildEnvironmentLinkType $item))) {
        throw "C1b $($Guard.Name) current path 不是 ordinary file。"
    }
    $pathStream = [IO.File]::Open(
        $full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $heldIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $Guard.Stream.SafeFileHandle)
        $pathIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $pathStream.SafeFileHandle)
        $heldSha = Get-TL1C1bBuildEnvironmentStreamSha256 $Guard.Stream
        $pathSha = Get-TL1C1bBuildEnvironmentStreamSha256 $pathStream
        if ($heldIdentity.LinkCount -ne 1 -or $pathIdentity.LinkCount -ne 1 -or
            [string]$heldIdentity.StableId -cne [string]$Guard.StableId -or
            [string]$pathIdentity.StableId -cne [string]$Guard.StableId -or
            $heldSha -cne [string]$Guard.Sha256 -or $pathSha -cne [string]$Guard.Sha256) {
            throw "C1b $($Guard.Name) held/current binding 漂移。"
        }
    } finally { $pathStream.Dispose() }
    return [string]$Guard.Sha256
}

function Close-TL1C1bBuildEnvironmentExternalFileGuard {
    param([AllowNull()]$Guard)
    if ($null -ne $Guard -and $Guard.Stream -is [IO.FileStream]) {
        $Guard.Stream.Dispose()
    }
}

function Open-TL1C1bBuildEnvironmentMutableEmptyFileGuard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "C1b $Name 必须是绝对路径。"
    }
    $full = [IO.Path]::GetFullPath($Path)
    [void](Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($full)) "$Name parent")
    $stream = [IO.File]::Open(
        $full, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
        ([IO.FileShare]::Read -bor [IO.FileShare]::Write))
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace((Get-TL1C1bBuildEnvironmentLinkType $item))) {
            throw "C1b $Name 必须是 ordinary non-link file。"
        }
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
        $emptySha256 = Get-TL1C1bBuildEnvironmentSha256Text ''
        if ($identity.LinkCount -ne 1 -or $stream.Length -ne 0 -or
            (Get-TL1C1bBuildEnvironmentStreamSha256 $stream) -cne $emptySha256) {
            throw "C1b $Name 必须是 empty single-link file。"
        }
        return [pscustomobject][ordered]@{
            Name = $Name
            Path = $full
            EmptySha256 = $emptySha256
            StableId = $identity.StableId
            MutableStream = $stream
            SealStream = $null
            Sealed = $false
        }
    } catch { $stream.Dispose(); throw }
}

function Assert-TL1C1bBuildEnvironmentMutableEmptyFileGuardUnchanged {
    param([Parameter(Mandatory)]$Guard)

    $heldStream = if ([bool]$Guard.Sealed) {
        $Guard.SealStream
    } else {
        $Guard.MutableStream
    }
    if ($heldStream -isnot [IO.FileStream] -or
        $heldStream.SafeFileHandle.IsClosed -or
        $heldStream.SafeFileHandle.IsInvalid -or -not $heldStream.CanRead) {
        throw "C1b $($Guard.Name) held guard 已关闭。"
    }
    $full = [IO.Path]::GetFullPath($Guard.Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace((Get-TL1C1bBuildEnvironmentLinkType $item))) {
        throw "C1b $($Guard.Name) current path 不是 ordinary file。"
    }
    $share = if ([bool]$Guard.Sealed) {
        [IO.FileShare]::Read
    } else {
        [IO.FileShare]::Read -bor [IO.FileShare]::Write
    }
    $pathStream = [IO.File]::Open(
        $full, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $heldIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $heldStream.SafeFileHandle)
        $pathIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $pathStream.SafeFileHandle)
        if ($heldIdentity.LinkCount -ne 1 -or $pathIdentity.LinkCount -ne 1 -or
            [string]$heldIdentity.StableId -cne [string]$Guard.StableId -or
            [string]$pathIdentity.StableId -cne [string]$Guard.StableId -or
            $heldStream.Length -ne 0 -or $pathStream.Length -ne 0 -or
            (Get-TL1C1bBuildEnvironmentStreamSha256 $heldStream) -cne
                [string]$Guard.EmptySha256 -or
            (Get-TL1C1bBuildEnvironmentStreamSha256 $pathStream) -cne
                [string]$Guard.EmptySha256) {
            throw "C1b $($Guard.Name) held/current empty-file binding 漂移。"
        }
    } finally { $pathStream.Dispose() }
}

function Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard {
    param([Parameter(Mandatory)]$Guard)

    if ([bool]$Guard.Sealed) {
        Assert-TL1C1bBuildEnvironmentMutableEmptyFileGuardUnchanged $Guard
        return
    }
    Assert-TL1C1bBuildEnvironmentMutableEmptyFileGuardUnchanged $Guard
    $transition = [IO.File]::Open(
        [string]$Guard.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::Read -bor [IO.FileShare]::Write))
    $seal = $null
    try {
        $transitionIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $transition.SafeFileHandle)
        if ($transitionIdentity.LinkCount -ne 1 -or
            [string]$transitionIdentity.StableId -cne [string]$Guard.StableId -or
            $transition.Length -ne 0 -or
            (Get-TL1C1bBuildEnvironmentStreamSha256 $transition) -cne
                [string]$Guard.EmptySha256) {
            throw "C1b $($Guard.Name) transition binding 漂移。"
        }
        $Guard.MutableStream.Dispose()
        $Guard.MutableStream = $null
        $seal = [IO.File]::Open(
            [string]$Guard.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::Read)
        $sealIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $seal.SafeFileHandle)
        if ($sealIdentity.LinkCount -ne 1 -or
            [string]$sealIdentity.StableId -cne [string]$Guard.StableId -or
            $seal.Length -ne 0 -or
            (Get-TL1C1bBuildEnvironmentStreamSha256 $seal) -cne
                [string]$Guard.EmptySha256) {
            throw "C1b $($Guard.Name) post-Gradle seal binding 漂移。"
        }
        $Guard.SealStream = $seal
        $Guard.Sealed = $true
        $seal = $null
    } finally {
        if ($null -ne $seal) { $seal.Dispose() }
        $transition.Dispose()
    }
    Assert-TL1C1bBuildEnvironmentMutableEmptyFileGuardUnchanged $Guard
}

function Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard {
    param([AllowNull()]$Guard)
    if ($null -eq $Guard) { return }
    foreach ($stream in @($Guard.SealStream, $Guard.MutableStream)) {
        if ($stream -is [IO.FileStream]) { $stream.Dispose() }
    }
}

function Protect-TL1C1bBuildEnvironmentRepoDirectories {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RelativeDirectories,
        [Parameter(Mandatory)][string]$Name
    )

    $relativeRoots = [string[]]@($RelativeDirectories)
    [Array]::Sort($relativeRoots, [StringComparer]::Ordinal)
    for ($index = 0; $index -lt $relativeRoots.Count; $index++) {
        if ($index -gt 0 -and $relativeRoots[$index] -ceq $relativeRoots[$index - 1]) {
            throw "C1b $Name directory root 不得重复。"
        }
    }
    $pathMap = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $relativeRoots) {
        $root = Resolve-TL1C1bBuildEnvironmentRepoRelativePath `
            $RepoRoot $relative "$Name directory" -Directory
        $inventory = Get-TL1C1bBuildEnvironmentTreeInventory $root
        $pathMap[$root] = $root
        foreach ($child in $inventory.Directories) {
            $path = [IO.Path]::GetFullPath((Join-Path $root `
                ($child.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            $pathMap[$path] = $path
        }
    }
    $paths = [string[]]@($pathMap.Values)
    [Array]::Sort($paths, [Comparison[string]]{
        param($left, $right)
        $depthCompare = $left.Split([IO.Path]::DirectorySeparatorChar).Count.CompareTo(
            $right.Split([IO.Path]::DirectorySeparatorChar).Count)
        if ($depthCompare -ne 0) { return $depthCompare }
        return [StringComparer]::OrdinalIgnoreCase.Compare($left, $right)
    })
    $guards = [Collections.Generic.List[object]]::new()
    try {
        foreach ($path in $paths) {
            $guards.Add((Protect-TL1C1bBuildEnvironmentDirectory $path))
        }
        $result = [pscustomobject][ordered]@{
            Name = $Name
            Entries = $guards.ToArray()
            ProtectedDirectoryCount = $guards.Count
            RootCount = $relativeRoots.Count
        }
        Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected $result
        return $result
    } catch {
        for ($index = $guards.Count - 1; $index -ge 0; $index--) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $guards[$index] } catch { }
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentTreeHardlinkTopology {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [switch]$AllowInternalHardlinks,
        [ValidateRange(0, 20000)][int]$ExpectedIdentityCount = 0,
        [ValidateRange(0, 20000)][int]$ExpectedInternalHardlinkGroupCount = 0,
        [Parameter(Mandatory)][string]$Name
    )

    $groups = [Collections.Generic.Dictionary[string,object]]::new(
        [StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        $identity = [string]$entry.FileIdentity
        $linkCount = [uint32]$entry.LinkCount
        if ([string]::IsNullOrWhiteSpace($identity) -or $linkCount -lt 1) {
            throw "C1b $Name hardlink topology entry 无效。"
        }
        $group = $null
        if (-not $groups.TryGetValue($identity, [ref]$group)) {
            $group = [pscustomobject][ordered]@{
                LinkCount = $linkCount
                CatalogPathCount = 0
            }
            $groups.Add($identity, $group)
        } elseif ([uint32]$group.LinkCount -ne $linkCount) {
            throw "C1b $Name 同一 file identity 的 link count 不一致。"
        }
        $group.CatalogPathCount = [int]$group.CatalogPathCount + 1
    }
    $multiLinkGroupCount = 0
    foreach ($group in $groups.Values) {
        if (-not $AllowInternalHardlinks) {
            if ([uint32]$group.LinkCount -ne 1 -or
                [int]$group.CatalogPathCount -ne 1) {
                throw "C1b $Name hardlink count 必须 exact 1。"
            }
            continue
        }
        if ([int]$group.CatalogPathCount -ne [uint32]$group.LinkCount) {
            throw "C1b $Name hardlink 必须全部闭合在冻结 root/catalog 内。"
        }
        if ([uint32]$group.LinkCount -gt 1) { $multiLinkGroupCount++ }
    }
    if ($AllowInternalHardlinks) {
        if ($ExpectedIdentityCount -lt 1 -or
            $groups.Count -ne $ExpectedIdentityCount -or
            $multiLinkGroupCount -ne $ExpectedInternalHardlinkGroupCount) {
            throw "C1b $Name hardlink identity/group topology 与冻结值不一致。"
        }
    } elseif ($ExpectedIdentityCount -ne 0 -or
        $ExpectedInternalHardlinkGroupCount -ne 0) {
        throw "C1b $Name single-link tree 不接受 hardlink topology expectations。"
    }
    return [pscustomobject][ordered]@{
        identity_count = $groups.Count
        internal_hardlink_group_count = $multiLinkGroupCount
        hardlink_topology_internal = [bool]$AllowInternalHardlinks
    }
}

function Open-TL1C1bBuildEnvironmentTreeGuard {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateRange(1, 20000)][int]$ExpectedFileCount,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedCatalogSha256,
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowInternalHardlinks,
        [ValidateRange(0, 20000)][int]$ExpectedIdentityCount = 0,
        [ValidateRange(0, 20000)][int]$ExpectedInternalHardlinkGroupCount = 0
    )

    $inventory = Get-TL1C1bBuildEnvironmentTreeInventory $Root
    if ($inventory.Files.Count -ne $ExpectedFileCount) {
        throw "C1b $Name file count 必须 exact $ExpectedFileCount。"
    }
    $entries = [Collections.Generic.List[object]]::new()
    try {
        foreach ($relative in $inventory.Files) {
            $path = [IO.Path]::GetFullPath((Join-Path $inventory.Root `
                ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $linkType = Get-TL1C1bBuildEnvironmentLinkType $item
            if ($item.PSIsContainer -or
                ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                (-not [string]::IsNullOrWhiteSpace($linkType) -and
                    $linkType -cne 'HardLink') -or
                -not (Test-TL1C1bBuildEnvironmentPathEqual `
                    ([IO.Path]::GetFullPath($item.FullName)) $path)) {
                throw "C1b $Name 必须只含 canonical ordinary files。"
            }
            $stream = [IO.File]::Open(
                $path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read
            )
            try {
                $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
                    $stream.SafeFileHandle)
                $sha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $stream
                $entries.Add([pscustomobject][ordered]@{
                    RelativePath = $relative
                    Path = $path
                    Sha256 = $sha256
                    FileIdentity = $identity.StableId
                    LinkCount = [uint32]$identity.LinkCount
                    Stream = $stream
                })
            } catch {
                $stream.Dispose()
                throw
            }
        }
        $catalogSha256 = Get-TL1C1bBuildEnvironmentCatalogSha256 $entries.ToArray()
        if ($catalogSha256 -cne $ExpectedCatalogSha256) {
            throw "C1b $Name catalog SHA-256 与冻结值不一致。"
        }
        [void](Assert-TL1C1bBuildEnvironmentTreeHardlinkTopology `
            -Entries $entries.ToArray() `
            -AllowInternalHardlinks:$AllowInternalHardlinks `
            -ExpectedIdentityCount $ExpectedIdentityCount `
            -ExpectedInternalHardlinkGroupCount $ExpectedInternalHardlinkGroupCount `
            -Name $Name)
        $guard = [pscustomobject][ordered]@{
            Name = $Name
            Root = $inventory.Root
            ExpectedFileCount = $ExpectedFileCount
            ExpectedCatalogSha256 = $ExpectedCatalogSha256
            DirectoryRelativePaths = $inventory.Directories
            Entries = $entries.ToArray()
            CatalogSha256 = $catalogSha256
            AllowInternalHardlinks = [bool]$AllowInternalHardlinks
            ExpectedIdentityCount = $ExpectedIdentityCount
            ExpectedInternalHardlinkGroupCount = $ExpectedInternalHardlinkGroupCount
        }
        [void](Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard)
        return $guard
    } catch {
        foreach ($entry in $entries) { $entry.Stream.Dispose() }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged {
    param([Parameter(Mandatory)]$TreeGuard)

    if ($null -eq $TreeGuard.PSObject.Properties['Entries'] -or
        $null -eq $TreeGuard.PSObject.Properties['Root'] -or
        @($TreeGuard.Entries).Count -ne [int]$TreeGuard.ExpectedFileCount) {
        throw 'C1b build-environment tree guard 结构无效。'
    }
    $inventory = Get-TL1C1bBuildEnvironmentTreeInventory ([string]$TreeGuard.Root)
    $expectedFiles = [string[]]@($TreeGuard.Entries | ForEach-Object {
        [string]$_.RelativePath
    })
    if ($inventory.Files.Count -ne $expectedFiles.Count) {
        throw "C1b $($TreeGuard.Name) frozen tree file count 漂移。"
    }
    for ($index = 0; $index -lt $expectedFiles.Count; $index++) {
        if ($inventory.Files[$index] -cne $expectedFiles[$index]) {
            throw "C1b $($TreeGuard.Name) frozen tree path 漂移。"
        }
    }
    $initialDirectories = [string[]]@($TreeGuard.DirectoryRelativePaths)
    if ($inventory.Directories.Count -ne $initialDirectories.Count) {
        throw "C1b $($TreeGuard.Name) frozen tree directory count 漂移。"
    }
    for ($index = 0; $index -lt $initialDirectories.Count; $index++) {
        if ($inventory.Directories[$index] -cne $initialDirectories[$index]) {
            throw "C1b $($TreeGuard.Name) frozen tree directory path 漂移。"
        }
    }
    $currentEntries = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($TreeGuard.Entries)) {
        if ($entry.Stream -isnot [IO.FileStream] -or
            $entry.Stream.SafeFileHandle.IsClosed -or
            $entry.Stream.SafeFileHandle.IsInvalid -or -not $entry.Stream.CanRead) {
            throw "C1b $($TreeGuard.Name) held file guard 已关闭。"
        }
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $entry.Stream.SafeFileHandle)
        if ([string]$identity.StableId -cne [string]$entry.FileIdentity) {
            throw "C1b $($TreeGuard.Name) held file identity 漂移。"
        }
        if ([uint32]$identity.LinkCount -ne [uint32]$entry.LinkCount) {
            throw "C1b $($TreeGuard.Name) held file link count 漂移。"
        }
        $sha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $entry.Stream
        if ($sha256 -cne [string]$entry.Sha256) {
            throw "C1b $($TreeGuard.Name) held file hash 漂移。"
        }
        # A held handle alone proves the opened object, not that a later child process opening the
        # same lexical path will reach it. Re-open the current path after directory freeze and bind
        # its identity/hash back to the held handle on every pre/post/frozen check.
        $item = Get-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
        $linkType = Get-TL1C1bBuildEnvironmentLinkType $item
        if ($item.PSIsContainer -or
            ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (-not [string]::IsNullOrWhiteSpace($linkType) -and
                $linkType -cne 'HardLink') -or
            -not (Test-TL1C1bBuildEnvironmentPathEqual `
                ([IO.Path]::GetFullPath($item.FullName)) ([string]$entry.Path))) {
            throw "C1b $($TreeGuard.Name) current path 不再是 canonical ordinary file。"
        }
        $pathStream = [IO.File]::Open(
            [string]$entry.Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            $pathIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
                $pathStream.SafeFileHandle)
            $pathSha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $pathStream
            if ([uint32]$pathIdentity.LinkCount -ne [uint32]$entry.LinkCount -or
                [string]$pathIdentity.StableId -cne [string]$entry.FileIdentity -or
                $pathSha256 -cne [string]$entry.Sha256) {
                throw "C1b $($TreeGuard.Name) current path/held handle 绑定漂移。"
            }
        } finally { $pathStream.Dispose() }
        $currentEntries.Add([pscustomobject][ordered]@{
            RelativePath = [string]$entry.RelativePath
            Sha256 = $sha256
        })
    }
    $catalogSha256 = Get-TL1C1bBuildEnvironmentCatalogSha256 $currentEntries.ToArray()
    if ($catalogSha256 -cne [string]$TreeGuard.ExpectedCatalogSha256) {
        throw "C1b $($TreeGuard.Name) frozen catalog 漂移。"
    }
    $topology = Assert-TL1C1bBuildEnvironmentTreeHardlinkTopology `
        -Entries ([object[]]@($TreeGuard.Entries)) `
        -AllowInternalHardlinks:([bool]$TreeGuard.AllowInternalHardlinks) `
        -ExpectedIdentityCount ([int]$TreeGuard.ExpectedIdentityCount) `
        -ExpectedInternalHardlinkGroupCount `
            ([int]$TreeGuard.ExpectedInternalHardlinkGroupCount) `
        -Name ([string]$TreeGuard.Name)
    return [pscustomobject][ordered]@{
        root = [string]$TreeGuard.Root
        file_count = [int]$TreeGuard.ExpectedFileCount
        catalog_sha256 = $catalogSha256
        identity_count = [int]$topology.identity_count
        internal_hardlink_group_count = [int]$topology.internal_hardlink_group_count
        hardlink_topology_internal = [bool]$topology.hardlink_topology_internal
    }
}

function Get-TL1C1bBuildEnvironmentEntry {
    param(
        [Parameter(Mandatory)]$TreeGuard,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $matches = @($TreeGuard.Entries | Where-Object {
        [string]$_.RelativePath -ceq $RelativePath
    })
    if ($matches.Count -ne 1) {
        throw "C1b build-environment 缺少 exact tree entry：$RelativePath。"
    }
    return $matches[0]
}

function Test-TL1C1bBuildEnvironmentOracleSignerSubject {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Subject)

    return $Subject -ceq $script:TL1C1bBuildEnvironmentJdkSignerSubject
}

function Get-TL1C1bBuildEnvironmentAuthenticodeBinding {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'C1b JDK java.exe/jvm.dll Authenticode/OS trust 必须是 Valid。'
    }
    $certificate = $signature.SignerCertificate
    $subject = [string]$certificate.Subject
    if (-not (Test-TL1C1bBuildEnvironmentOracleSignerSubject $subject)) {
        throw 'C1b JDK Authenticode signer subject 必须精确是 Oracle America, Inc.。'
    }
    $rawData = [byte[]]$certificate.RawData
    try { $certificateSha256 = Get-TL1C1bBuildEnvironmentSha256Bytes $rawData }
    finally {
        if ($rawData.Length -ne 0) { [Array]::Clear($rawData, 0, $rawData.Length) }
    }
    if ($certificateSha256 -cne `
        $script:TL1C1bBuildEnvironmentJdkSignerCertificateSha256) {
        throw 'C1b JDK signer certificate RawData SHA-256 与冻结值不一致。'
    }
    return [pscustomobject][ordered]@{
        status = 'Valid'
        subject = $subject
        certificate_sha256 = $certificateSha256
    }
}

function Test-TL1C1bBuildEnvironmentGitSignerSubject {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Subject)

    return $Subject -ceq $script:TL1C1bBuildEnvironmentGitSignerSubject
}

function Get-TL1C1bBuildEnvironmentGitAuthenticodeBinding {
    param([Parameter(Mandatory)][string]$Path)

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$signature.Status -cne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw 'C1b Git Authenticode/OS trust 必须是 Valid。'
    }
    $certificate = $signature.SignerCertificate
    $subject = [string]$certificate.Subject
    if (-not (Test-TL1C1bBuildEnvironmentGitSignerSubject $subject)) {
        throw 'C1b Git Authenticode signer subject 必须精确匹配冻结值。'
    }
    $rawData = [byte[]]$certificate.RawData
    try { $certificateSha256 = Get-TL1C1bBuildEnvironmentSha256Bytes $rawData }
    finally {
        if ($rawData.Length -ne 0) { [Array]::Clear($rawData, 0, $rawData.Length) }
    }
    if ($certificateSha256 -cne `
        $script:TL1C1bBuildEnvironmentGitSignerCertificateSha256) {
        throw 'C1b Git signer certificate RawData SHA-256 与冻结值不一致。'
    }
    return [pscustomobject][ordered]@{
        status = 'Valid'
        subject = $subject
        certificate_sha256 = $certificateSha256
    }
}

function Resolve-TL1C1bBuildEnvironmentGitRoot {
    param(
        [Parameter(Mandatory)][string]$GitPath,
        [string]$TestOnlyExpectedGitRoot,
        [switch]$TestOnlySynthetic
    )

    if (-not [IO.Path]::IsPathFullyQualified($GitPath)) {
        throw 'C1b GitPath 必须是显式绝对路径。'
    }
    $canonicalPath = [IO.Path]::GetFullPath($GitPath)
    $root = if ($TestOnlySynthetic) {
        if ([string]::IsNullOrWhiteSpace($TestOnlyExpectedGitRoot) -or
            -not [IO.Path]::IsPathFullyQualified($TestOnlyExpectedGitRoot)) {
            throw 'C1b synthetic Git root 必须是显式绝对路径。'
        }
        Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            $TestOnlyExpectedGitRoot 'synthetic Git for Windows root'
    } else {
        if (-not [string]::IsNullOrWhiteSpace($TestOnlyExpectedGitRoot)) {
            throw 'C1b production Git root 不接受 test-only override。'
        }
        $programFiles = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) `
            'Windows Program Files trust root'
        Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            (Join-Path $programFiles 'Git') 'canonical Git for Windows root'
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $root 'cmd\git.exe'))
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $canonicalPath $expectedPath)) {
        throw 'C1b GitPath 必须 exact 指向冻结 Git root/cmd/git.exe。'
    }
    $item = Get-Item -LiteralPath $canonicalPath -Force -ErrorAction Stop
    $linkType = Get-TL1C1bBuildEnvironmentLinkType $item
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (-not [string]::IsNullOrWhiteSpace($linkType) -and $linkType -cne 'HardLink') -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetFullPath($item.FullName)) $canonicalPath)) {
        throw 'C1b GitPath 必须是 canonical ordinary file。'
    }
    return $root
}

function Get-TL1C1bBuildEnvironmentGitBinding {
    param(
        [Parameter(Mandatory)]$TreeGuard,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedKeyFiles,
        [scriptblock]$TestOnlySignatureReader
    )

    $tree = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $TreeGuard
    $expectedNames = [string[]]@($script:TL1C1bBuildEnvironmentGitKeyFiles.Keys)
    if ($ExpectedKeyFiles.Count -ne $expectedNames.Count) {
        throw 'C1b Git key-file catalog 必须覆盖 exact 冻结集合。'
    }
    $keyHashes = [ordered]@{}
    foreach ($relative in $expectedNames) {
        if (-not $ExpectedKeyFiles.Contains($relative)) {
            throw "C1b Git key-file catalog 缺少：$relative。"
        }
        $expected = [string]$ExpectedKeyFiles[$relative]
        if ($expected -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw "C1b Git key-file hash 格式无效：$relative。"
        }
        $entry = Get-TL1C1bBuildEnvironmentEntry $TreeGuard $relative
        if ([string]$entry.Sha256 -cne $expected) {
            throw "C1b Git key-file hash 漂移：$relative。"
        }
        $keyHashes[$relative] = $expected
    }
    $launcher = Get-TL1C1bBuildEnvironmentEntry $TreeGuard 'cmd/git.exe'
    $signature = if ($null -eq $TestOnlySignatureReader) {
        Get-TL1C1bBuildEnvironmentGitAuthenticodeBinding $launcher.Path
    } else {
        # Dedicated offline synthetic test only; production Open never forwards this hook.
        & $TestOnlySignatureReader $launcher.Path
    }
    if ([string]$signature.status -cne 'Valid' -or
        [string]$signature.subject -cne $script:TL1C1bBuildEnvironmentGitSignerSubject -or
        [string]$signature.certificate_sha256 -cne `
            $script:TL1C1bBuildEnvironmentGitSignerCertificateSha256) {
        throw 'C1b Git signature binding 与冻结值不一致。'
    }
    return [pscustomobject][ordered]@{
        version = $script:TL1C1bBuildEnvironmentGitVersion
        file_count = $tree.file_count
        identity_count = $tree.identity_count
        internal_hardlink_group_count = $tree.internal_hardlink_group_count
        catalog_sha256 = $tree.catalog_sha256
        cmd_git_sha256 = $keyHashes['cmd/git.exe']
        mingw64_bin_git_sha256 = $keyHashes['mingw64/bin/git.exe']
        mingw64_libexec_git_core_git_sha256 =
            $keyHashes['mingw64/libexec/git-core/git.exe']
        libcurl_sha256 = $keyHashes['mingw64/bin/libcurl-4.dll']
        libssl_sha256 = $keyHashes['mingw64/bin/libssl-3-x64.dll']
        libcrypto_sha256 = $keyHashes['mingw64/bin/libcrypto-3-x64.dll']
        signature_status = 'Valid'
        signature_subject = [string]$signature.subject
        signature_certificate_sha256 = [string]$signature.certificate_sha256
        child_environment_cleared = $true
        minimal_path = $true
        system_and_global_config_disabled = $true
        hardlink_topology_internal = $tree.hardlink_topology_internal
        tree_files_deny_write_delete = $true
        tree_directories_acl_protected = $true
    }
}

function Compare-TL1C1bBuildEnvironmentGitBinding {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($name in @(
        'version', 'file_count', 'identity_count', 'internal_hardlink_group_count',
        'catalog_sha256', 'cmd_git_sha256',
        'mingw64_bin_git_sha256', 'mingw64_libexec_git_core_git_sha256',
        'libcurl_sha256', 'libssl_sha256', 'libcrypto_sha256',
        'signature_status', 'signature_subject', 'signature_certificate_sha256',
        'child_environment_cleared', 'minimal_path',
        'system_and_global_config_disabled', 'hardlink_topology_internal',
        'tree_files_deny_write_delete',
        'tree_directories_acl_protected'
    )) {
        if ([string]$Expected.$name -cne [string]$Actual.$name) {
            throw "C1b Git trust binding/$name 前后漂移。"
        }
    }
}

function Get-TL1C1bBuildEnvironmentJdkBinding {
    param(
        [Parameter(Mandatory)]$TreeGuard,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedKeyFiles,
        [scriptblock]$TestOnlySignatureReader
    )

    $tree = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $TreeGuard
    $keyHashes = [ordered]@{}
    foreach ($relative in $ExpectedKeyFiles.Keys) {
        $entry = Get-TL1C1bBuildEnvironmentEntry $TreeGuard $relative
        $expected = [string]$ExpectedKeyFiles[$relative]
        if ([string]$entry.Sha256 -cne $expected) {
            throw "C1b JDK key file hash 漂移：$relative。"
        }
        $keyHashes[$relative] = $expected
    }
    $java = Get-TL1C1bBuildEnvironmentEntry $TreeGuard 'bin/java.exe'
    $jvm = Get-TL1C1bBuildEnvironmentEntry $TreeGuard 'bin/server/jvm.dll'
    if ($null -eq $TestOnlySignatureReader) {
        $javaSignature = Get-TL1C1bBuildEnvironmentAuthenticodeBinding $java.Path
        $jvmSignature = Get-TL1C1bBuildEnvironmentAuthenticodeBinding $jvm.Path
    } else {
        # This hook is used only by the dedicated offline test's synthetic files. The production
        # Open-TL1C1bBuildEnvironmentTrustGuard entry point never accepts or forwards it.
        $javaSignature = & $TestOnlySignatureReader $java.Path
        $jvmSignature = & $TestOnlySignatureReader $jvm.Path
    }
    foreach ($candidate in @($javaSignature, $jvmSignature)) {
        if ([string]$candidate.status -cne 'Valid' -or
            [string]$candidate.subject -cne $script:TL1C1bBuildEnvironmentJdkSignerSubject -or
            [string]$candidate.certificate_sha256 -cne `
                $script:TL1C1bBuildEnvironmentJdkSignerCertificateSha256) {
            throw 'C1b JDK synthetic/real signature binding 与冻结值不一致。'
        }
    }
    return [pscustomobject][ordered]@{
        vendor = $script:TL1C1bBuildEnvironmentJdkVendor
        version = $script:TL1C1bBuildEnvironmentJdkVersion
        archive_sha256 = $script:TL1C1bBuildEnvironmentJdkArchiveSha256
        file_count = $tree.file_count
        catalog_sha256 = $tree.catalog_sha256
        java_sha256 = $keyHashes['bin/java.exe']
        jvm_sha256 = $keyHashes['bin/server/jvm.dll']
        release_sha256 = $keyHashes['release']
        modules_sha256 = $keyHashes['lib/modules']
        signature_status = 'Valid'
        signature_subject = [string]$javaSignature.subject
        signature_certificate_sha256 = [string]$javaSignature.certificate_sha256
        tree_files_deny_write_delete = $true
        tree_directories_acl_protected = $true
    }
}

function Get-TL1C1bBuildEnvironmentKeyFileHashes {
    param(
        [Parameter(Mandatory)]$TreeGuard,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedKeyFiles,
        [Parameter(Mandatory)][string]$Name
    )

    $result = [ordered]@{}
    foreach ($relative in $ExpectedKeyFiles.Keys) {
        $entry = Get-TL1C1bBuildEnvironmentEntry $TreeGuard ([string]$relative)
        $expected = [string]$ExpectedKeyFiles[$relative]
        if ([string]$entry.Sha256 -cne $expected) {
            throw "C1b $Name key file hash 漂移：$relative。"
        }
        $result[[string]$relative] = $expected
    }
    return $result
}

function Assert-TL1C1bBuildEnvironmentAndroidRoots {
    param([Parameter(Mandatory)][string]$AndroidSdkRoot)

    $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $AndroidSdkRoot 'AndroidSdkRoot'
    foreach ($name in @('ANDROID_SDK_ROOT', 'ANDROID_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $ambient = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $value $name
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual $canonical $ambient)) {
            throw "C1b $name 与显式 AndroidSdkRoot 不一致。"
        }
    }
    return $canonical
}

function Copy-TL1C1bBuildEnvironmentTreeGuardToDirectory {
    param(
        [Parameter(Mandatory)]$TreeGuard,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$DestinationPrefix
    )

    [void](Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $TreeGuard)
    if ($DestinationPrefix -cnotmatch '^[a-z0-9][a-z0-9._/-]*$' -or
        $DestinationPrefix -cmatch '(^|/)\.\.(/|$)') {
        throw 'C1b isolated Android SDK prefix 无效。'
    }
    $prefixRoot = Join-Path $DestinationRoot `
        ($DestinationPrefix.Replace('/', [IO.Path]::DirectorySeparatorChar))
    [IO.Directory]::CreateDirectory($prefixRoot) | Out-Null
    foreach ($relativeDirectory in $TreeGuard.DirectoryRelativePaths) {
        [IO.Directory]::CreateDirectory((Join-Path $prefixRoot `
            ($relativeDirectory.Replace('/', [IO.Path]::DirectorySeparatorChar)))) |
            Out-Null
    }
    foreach ($entry in $TreeGuard.Entries) {
        $destination = Join-Path $prefixRoot `
            ($entry.RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $writer = [IO.File]::Open(
            $destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $position = $entry.Stream.Position
        try {
            $entry.Stream.Position = 0
            $entry.Stream.CopyTo($writer)
            $writer.Flush($true)
        } finally {
            $entry.Stream.Position = $position
            $writer.Dispose()
        }
    }
}

function New-TL1C1bBuildEnvironmentIsolatedAndroidSdk {
    param(
        [Parameter(Mandatory)]$Workspace,
        [Parameter(Mandatory)]$BuildToolsTreeGuard,
        [Parameter(Mandatory)]$PlatformTreeGuard,
        [Parameter(Mandatory)]$PlatformToolsTreeGuard,
        [Parameter(Mandatory)][ValidateRange(1, 20000)][int]$ExpectedFileCount,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedCatalogSha256
    )

    $root = [IO.Path]::GetFullPath((Join-Path $Workspace.Root 'isolated-android-sdk'))
    if (Test-Path -LiteralPath $root) {
        throw 'C1b isolated Android SDK root 必须预先不存在。'
    }
    $treeGuard = $null
    $aclGuards = $null
    try {
        [IO.Directory]::CreateDirectory($root) | Out-Null
        Copy-TL1C1bBuildEnvironmentTreeGuardToDirectory `
            $BuildToolsTreeGuard $root 'build-tools/35.0.0'
        Copy-TL1C1bBuildEnvironmentTreeGuardToDirectory `
            $PlatformToolsTreeGuard $root 'platform-tools'
        Copy-TL1C1bBuildEnvironmentTreeGuardToDirectory `
            $PlatformTreeGuard $root 'platforms/android-35'
        foreach ($relative in @('.knownPackages', 'tools', 'emulator')) {
            if (Test-Path -LiteralPath (Join-Path $root $relative)) {
                throw "C1b isolated Android SDK 不得含 $relative。"
            }
        }
        $treeGuard = Open-TL1C1bBuildEnvironmentTreeGuard `
            $root $ExpectedFileCount $ExpectedCatalogSha256 'isolated Android SDK'
        $aclGuards = Protect-TL1C1bBuildEnvironmentTreeDirectories $treeGuard
        return [pscustomobject][ordered]@{
            Root = $root
            TreeGuard = $treeGuard
            DirectoryAclGuards = $aclGuards
        }
    } catch {
        if ($null -ne $aclGuards) {
            try { Restore-TL1C1bBuildEnvironmentTreeDirectories $aclGuards } catch { }
        }
        Close-TL1C1bBuildEnvironmentTreeGuard $treeGuard
        if (Test-Path -LiteralPath $root -PathType Container) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        throw
    }
}

function New-TL1C1bBuildEnvironmentDebugKeystoreGuard {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)]$Workspace
    )

    $source = Open-TL1C1bBuildEnvironmentExternalFileGuard `
        $SourcePath 'canonical user-profile .android/debug.keystore'
    $copyGuard = $null
    $lockGuard = $null
    $aclEntries = [Collections.Generic.List[object]]::new()
    $aclGuards = $null
    try {
        $destination = Join-Path $Workspace.UserHomeDirectory '.android\debug.keystore'
        $lockPath = $destination + '.lock'
        if ((Test-Path -LiteralPath $destination) -or
            (Test-Path -LiteralPath $lockPath)) {
            throw 'C1b fresh user.home debug.keystore/lock destination 必须 absent。'
        }
        $writer = [IO.File]::Open(
            $destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $position = $source.Stream.Position
        try {
            $source.Stream.Position = 0
            $source.Stream.CopyTo($writer)
            $writer.Flush($true)
        } finally {
            $source.Stream.Position = $position
            $writer.Dispose()
        }
        $copyGuard = Open-TL1C1bBuildEnvironmentExternalFileGuard `
            $destination 'isolated user.home .android/debug.keystore'
        $lockGuard = Open-TL1C1bBuildEnvironmentMutableEmptyFileGuard `
            $lockPath 'isolated user.home .android/debug.keystore.lock'
        foreach ($directory in @(
            $Workspace.UserHomeDirectory,
            (Join-Path $Workspace.UserHomeDirectory '.android')
        )) {
            $aclEntries.Add((Protect-TL1C1bBuildEnvironmentDirectory $directory))
        }
        $aclGuards = [pscustomobject][ordered]@{
            Name = 'isolated debug signing user.home'
            Entries = $aclEntries.ToArray()
            ProtectedDirectoryCount = $aclEntries.Count
        }
        Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected $aclGuards
        Assert-TL1C1bBuildEnvironmentDebugKeystoreDirectoryShape `
            $Workspace.UserHomeDirectory
        if ([string]$copyGuard.Sha256 -cne [string]$source.Sha256) {
            throw 'C1b isolated debug.keystore copy hash 与 held source 不一致。'
        }
        return [pscustomobject][ordered]@{
            SourceGuard = $source
            CopyGuard = $copyGuard
            LockGuard = $lockGuard
            UserHomeDirectory = [string]$Workspace.UserHomeDirectory
            DirectoryAclGuards = $aclGuards
            Binding = [pscustomobject][ordered]@{
                sha256 = [string]$source.Sha256
                source_ordinary_single_link_guarded = $true
                isolated_copy_equal = $true
                isolated_user_home_other_config_absent = $true
                keystore_source_and_copy_deny_write_delete = $true
                directories_acl_protected = $true
                gradle_lock_precreated = $true
                gradle_lock_identity_guarded = $true
                gradle_lock_deny_delete = $true
                gradle_lock_write_allowed_during_gradle = $true
                post_gradle_lock_seal_required = $true
                post_gradle_lock_zero_length = $true
                post_gradle_lock_sealed_achieved = $false
            }
        }
    } catch {
        if ($null -ne $aclGuards) {
            try { Restore-TL1C1bBuildEnvironmentTreeDirectories $aclGuards } catch { }
        } else {
            for ($index = $aclEntries.Count - 1; $index -ge 0; $index--) {
                try { Restore-TL1C1bBuildEnvironmentDirectory $aclEntries[$index] }
                catch { }
            }
        }
        Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard $lockGuard
        Close-TL1C1bBuildEnvironmentExternalFileGuard $copyGuard
        Close-TL1C1bBuildEnvironmentExternalFileGuard $source
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentDebugKeystoreDirectoryShape {
    param([Parameter(Mandatory)][string]$UserHomeDirectory)

    $inventory = Get-TL1C1bBuildEnvironmentTreeInventory $UserHomeDirectory
    if (($inventory.Directories -join "`n") -cne '.android' -or
        ($inventory.Files -join "`n") -cne (@(
            '.android/debug.keystore',
            '.android/debug.keystore.lock'
        ) -join "`n")) {
        throw 'C1b isolated user.home 只能含 debug.keystore 与预创建 lock。'
    }
}

function Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged {
    param([Parameter(Mandatory)]$Guard)

    $userHome = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Guard.UserHomeDirectory 'isolated debug signing user.home'
    $expectedCopyPath = [IO.Path]::GetFullPath(
        (Join-Path $userHome '.android\debug.keystore'))
    $expectedLockPath = $expectedCopyPath + '.lock'
    $aclEntries = @($Guard.DirectoryAclGuards.Entries)
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
            $Guard.CopyGuard.Path $expectedCopyPath) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $Guard.LockGuard.Path $expectedLockPath) -or
        $aclEntries.Count -ne 2 -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $aclEntries[0].Directory $userHome) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $aclEntries[1].Directory (Join-Path $userHome '.android'))) {
        throw 'C1b debug.keystore copy/lock/directory canonical path binding 漂移。'
    }
    $sourceSha = Assert-TL1C1bBuildEnvironmentExternalFileGuardUnchanged `
        $Guard.SourceGuard
    $copySha = Assert-TL1C1bBuildEnvironmentExternalFileGuardUnchanged `
        $Guard.CopyGuard
    Assert-TL1C1bBuildEnvironmentMutableEmptyFileGuardUnchanged `
        $Guard.LockGuard
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $Guard.DirectoryAclGuards
    Assert-TL1C1bBuildEnvironmentDebugKeystoreDirectoryShape `
        $userHome
    if ($copySha -cne $sourceSha -or
        [string]$Guard.Binding.sha256 -cne $sourceSha -or
        [bool]$Guard.Binding.post_gradle_lock_sealed_achieved -ne
            [bool]$Guard.LockGuard.Sealed) {
        throw 'C1b debug.keystore source/copy binding 漂移。'
    }
    return $Guard.Binding
}

function Assert-TL1C1bBuildEnvironmentDebugKeystoreTrustBinding {
    param([Parameter(Mandatory)]$TrustGuard)

    $guard = $TrustGuard.DebugKeystoreGuard
    if (-not [object]::ReferenceEquals(
            $guard, $TrustGuard.DebugKeystoreGuardAnchor)) {
        throw 'C1b debug.keystore creation-time guard identity 漂移。'
    }
    $workspaceUserHome = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $TrustGuard.Workspace.UserHomeDirectory 'fresh user.home'
    $expectedUserHome = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $TrustGuard.DebugKeystoreUserHomeDirectory `
        'creation-time debug signing user.home'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
            $workspaceUserHome $TrustGuard.Workspace.UserHomeDirectory) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $expectedUserHome $TrustGuard.DebugKeystoreUserHomeDirectory) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $workspaceUserHome $expectedUserHome) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $guard.UserHomeDirectory $expectedUserHome)) {
        throw 'C1b debug.keystore 与 workspace user.home creation-time binding 漂移。'
    }
    return $guard
}

function Assert-TL1C1bBuildEnvironmentSealBindingTransition {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PreSealBindingRaw,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PostSealBindingRaw
    )

    $falseMarker = '"post_gradle_lock_sealed_achieved":false'
    $trueMarker = '"post_gradle_lock_sealed_achieved":true'
    if ([regex]::Matches($PreSealBindingRaw, [regex]::Escape($falseMarker)).Count -ne 1 -or
        $PreSealBindingRaw.Contains($trueMarker) -or
        [regex]::Matches($PostSealBindingRaw, [regex]::Escape($trueMarker)).Count -ne 1 -or
        $PostSealBindingRaw.Contains($falseMarker) -or
        $PostSealBindingRaw.Replace($trueMarker, $falseMarker) -cne
            $PreSealBindingRaw) {
        throw 'C1b pre/post seal binding 除 achieved false→true 外发生漂移。'
    }
}

function Seal-TL1C1bBuildEnvironmentDebugKeystoreLock {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [Parameter(Mandatory)]$ExpectedTrustGuard,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string]$ExpectedPreSealBindingRaw
    )

    if (-not [object]::ReferenceEquals($TrustGuard, $ExpectedTrustGuard)) {
        throw 'C1b post-Gradle seal trust guard identity 漂移。'
    }
    $guard = Assert-TL1C1bBuildEnvironmentDebugKeystoreTrustBinding `
        $TrustGuard
    $preSealBinding = Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle
    $preSealBindingRaw = $preSealBinding | ConvertTo-Json -Depth 20 -Compress
    if ($preSealBindingRaw -cne $ExpectedPreSealBindingRaw -or
        [regex]::Matches(
            $preSealBindingRaw,
            [regex]::Escape('"post_gradle_lock_sealed_achieved":false')).Count -ne 1 -or
        $preSealBindingRaw.Contains('"post_gradle_lock_sealed_achieved":true')) {
        throw 'C1b pre/post seal 初始 binding 不唯一或已漂移。'
    }
    Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard $guard.LockGuard
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $guard.DirectoryAclGuards
    Assert-TL1C1bBuildEnvironmentDebugKeystoreDirectoryShape `
        $guard.UserHomeDirectory
    $guard.Binding.post_gradle_lock_sealed_achieved = $true
    $postSealBinding = Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle
    $postSealBindingRaw = $postSealBinding | ConvertTo-Json -Depth 20 -Compress
    if (-not [bool]$postSealBinding.debug_keystore.post_gradle_lock_sealed_achieved -or
        -not [bool]$guard.LockGuard.Sealed) {
        throw 'C1b post-Gradle seal state 未达成。'
    }
    Assert-TL1C1bBuildEnvironmentSealBindingTransition `
        $preSealBindingRaw $postSealBindingRaw
    return $postSealBinding
}

function Close-TL1C1bBuildEnvironmentDebugKeystoreGuard {
    param([AllowNull()]$Guard)

    if ($null -eq $Guard) { return }
    $failures = [Collections.Generic.List[string]]::new()
    try {
        try {
            Restore-TL1C1bBuildEnvironmentTreeDirectories $Guard.DirectoryAclGuards
        } catch { $failures.Add("restore debug signing directories: $($_.Exception.Message)") }
    } finally {
        foreach ($entry in @(
            [pscustomobject]@{ Name = 'lock'; Action = {
                Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard $Guard.LockGuard
            } },
            [pscustomobject]@{ Name = 'copy'; Action = {
                Close-TL1C1bBuildEnvironmentExternalFileGuard $Guard.CopyGuard
            } },
            [pscustomobject]@{ Name = 'source'; Action = {
                Close-TL1C1bBuildEnvironmentExternalFileGuard $Guard.SourceGuard
            } }
        )) {
            try { & $entry.Action }
            catch { $failures.Add("close debug signing $($entry.Name): $($_.Exception.Message)") }
        }
    }
    if ($failures.Count -ne 0) {
        throw ('C1b debug signing guard 未完整关闭：' + ($failures -join ' | '))
    }
}

function Get-TL1C1bBuildEnvironmentAndroidSdkBinding {
    param(
        [Parameter(Mandatory)]$BuildToolsTreeGuard,
        [Parameter(Mandatory)]$PlatformTreeGuard,
        [Parameter(Mandatory)]$PlatformToolsTreeGuard,
        [Parameter(Mandatory)]$IsolatedTreeGuard,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedBuildToolsKeyFiles,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedPlatformKeyFiles,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedPlatformToolsKeyFiles
    )

    $buildTools = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged `
        $BuildToolsTreeGuard
    $platform = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $PlatformTreeGuard
    $platformTools = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged `
        $PlatformToolsTreeGuard
    $isolated = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $IsolatedTreeGuard
    $buildToolsKeys = Get-TL1C1bBuildEnvironmentKeyFileHashes `
        $BuildToolsTreeGuard $ExpectedBuildToolsKeyFiles 'Android build-tools 35.0.0'
    $platformKeys = Get-TL1C1bBuildEnvironmentKeyFileHashes `
        $PlatformTreeGuard $ExpectedPlatformKeyFiles 'Android platform android-35'
    $platformToolsKeys = Get-TL1C1bBuildEnvironmentKeyFileHashes `
        $PlatformToolsTreeGuard $ExpectedPlatformToolsKeyFiles 'Android platform-tools'
    return [pscustomobject][ordered]@{
        build_tools = [pscustomobject][ordered]@{
            version = $script:TL1C1bBuildEnvironmentAndroidBuildToolsVersion
            file_count = $buildTools.file_count
            catalog_sha256 = $buildTools.catalog_sha256
            source_properties_sha256 = $buildToolsKeys['source.properties']
            package_xml_sha256 = $buildToolsKeys['package.xml']
            apksigner_jar_sha256 = $buildToolsKeys['lib/apksigner.jar']
        }
        platform = [pscustomobject][ordered]@{
            version = $script:TL1C1bBuildEnvironmentAndroidPlatformVersion
            file_count = $platform.file_count
            catalog_sha256 = $platform.catalog_sha256
            android_jar_sha256 = $platformKeys['android.jar']
            source_properties_sha256 = $platformKeys['source.properties']
            package_xml_sha256 = $platformKeys['package.xml']
            framework_aidl_sha256 = $platformKeys['framework.aidl']
            core_for_system_modules_jar_sha256 =
                $platformKeys['core-for-system-modules.jar']
        }
        platform_tools = [pscustomobject][ordered]@{
            version = $script:TL1C1bBuildEnvironmentAndroidPlatformToolsVersion
            file_count = $platformTools.file_count
            catalog_sha256 = $platformTools.catalog_sha256
            source_properties_sha256 = $platformToolsKeys['source.properties']
            package_xml_sha256 = $platformToolsKeys['package.xml']
        }
        isolated = [pscustomobject][ordered]@{
            file_count = $isolated.file_count
            catalog_sha256 = $isolated.catalog_sha256
            package_roots = [string[]]@(
                'build-tools/35.0.0', 'platform-tools', 'platforms/android-35')
            dot_known_packages_absent = $true
            tools_package_xml_absent = $true
            emulator_package_xml_absent = $true
        }
        source_trees_files_deny_write_delete = $true
        child_uses_only_isolated_sdk = $true
        tree_files_deny_write_delete = $true
        tree_directories_acl_protected = $true
    }
}

function Compare-TL1C1bBuildEnvironmentAndroidSdkBinding {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($sectionName in @('build_tools', 'platform', 'platform_tools', 'isolated')) {
        $expectedSection = $Expected.$sectionName
        $actualSection = $Actual.$sectionName
        $expectedNames = [string[]]@($expectedSection.PSObject.Properties.Name)
        $actualNames = [string[]]@($actualSection.PSObject.Properties.Name)
        if (($expectedNames -join "`n") -cne ($actualNames -join "`n")) {
            throw "C1b Android SDK $sectionName binding 字段集合漂移。"
        }
        foreach ($name in $expectedNames) {
            if ([string]$expectedSection.$name -cne [string]$actualSection.$name) {
                throw "C1b Android SDK $sectionName/$name binding 漂移。"
            }
        }
    }
    foreach ($name in @(
        'source_trees_files_deny_write_delete', 'child_uses_only_isolated_sdk',
        'tree_files_deny_write_delete', 'tree_directories_acl_protected'
    )) {
        if ([bool]$Expected.$name -ne [bool]$Actual.$name) {
            throw "C1b Android SDK $name binding 漂移。"
        }
    }
}

function New-TL1C1bBuildEnvironmentEmptyFileGuard {
    param([Parameter(Mandatory)][string]$Path)

    $creator = [IO.File]::Open(
        $Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $creator.Flush($true) } finally { $creator.Dispose() }
    $stream = [IO.File]::Open(
        $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne 0) { throw 'C1b Gradle init sentinel 必须为空。' }
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
        if ($identity.LinkCount -ne 1) {
            throw 'C1b Gradle init sentinel hardlink count 必须 exact 1。'
        }
        return [pscustomobject][ordered]@{
            Path = [IO.Path]::GetFullPath($Path)
            FileIdentity = $identity.StableId
            Stream = $stream
        }
    } catch {
        $stream.Dispose()
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentEmptyFileGuardUnchanged {
    param(
        [Parameter(Mandatory)]$Guard,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Guard.Stream -isnot [IO.FileStream] -or
        $Guard.Stream.SafeFileHandle.IsClosed -or $Guard.Stream.SafeFileHandle.IsInvalid -or
        -not $Guard.Stream.CanRead -or $Guard.Stream.Length -ne 0) {
        throw "C1b $Name guard 已关闭或不为空。"
    }
    $item = Get-Item -LiteralPath $Guard.Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "C1b $Name 必须是 ordinary empty file。"
    }
    $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($Guard.Stream.SafeFileHandle)
    if ($identity.LinkCount -ne 1 -or
        [string]$identity.StableId -cne [string]$Guard.FileIdentity) {
        throw "C1b $Name identity/hardlink count 漂移。"
    }
}

function Open-TL1C1bBuildEnvironmentRepoInputGuard {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $repo = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $RepoRoot 'RepoRoot'
    $app = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        (Join-Path $repo 'app') 'app project root'
    foreach ($relative in @('buildSrc', 'build-logic', 'local.properties')) {
        $candidate = Join-Path $app $relative
        if (Test-Path -LiteralPath $candidate) {
            throw "C1b build-environment 拒绝 ignored/implicit app/$relative。"
        }
    }
    $guards = [Collections.Generic.List[object]]::new()
    $rootAclGuard = $null
    $appAclGuard = $null
    try {
        $guards.Add((New-TL1C1bBuildEnvironmentEmptyFileGuard `
            (Join-Path $app 'local.properties')))
        $rootAclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $repo `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        $appAclGuard = Protect-TL1C1bBuildEnvironmentDirectory -Directory $app
        return [pscustomobject][ordered]@{
            RepoRoot = $repo
            AppRoot = $app
            LocalPropertiesGuard = $guards[0]
            RepoRootAclGuard = $rootAclGuard
            AppRootAclGuard = $appAclGuard
        }
    } catch {
        if ($null -ne $appAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $appAclGuard } catch { }
        }
        if ($null -ne $rootAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $rootAclGuard } catch { }
        }
        foreach ($guard in $guards) { $guard.Stream.Dispose() }
        foreach ($relative in @('local.properties')) {
            $candidate = Join-Path $app $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                [IO.File]::Delete($candidate)
            }
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentRepoInputGuardUnchanged {
    param([Parameter(Mandatory)]$RepoInputGuard)

    $app = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $RepoInputGuard.AppRoot 'app project root'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $app $RepoInputGuard.AppRoot)) {
        throw 'C1b app project root canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentEmptyFileGuardUnchanged `
        $RepoInputGuard.LocalPropertiesGuard 'app/local.properties sentinel'
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $RepoInputGuard.RepoRootAclGuard
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $RepoInputGuard.AppRootAclGuard
    foreach ($relative in @('buildSrc', 'build-logic')) {
        if (Test-Path -LiteralPath (Join-Path $app $relative) -PathType Container) {
            throw "C1b build-environment 运行期出现 app/$relative directory。"
        }
    }
}

function Close-TL1C1bBuildEnvironmentRepoInputGuard {
    param([AllowNull()]$RepoInputGuard)

    if ($null -eq $RepoInputGuard) { return }
    $bindings = @([pscustomobject]@{
        Relative = 'local.properties'; Guard = $RepoInputGuard.LocalPropertiesGuard
    })
    foreach ($binding in $bindings) {
        $expected = [IO.Path]::GetFullPath((Join-Path `
            $RepoInputGuard.AppRoot $binding.Relative))
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual $expected $binding.Guard.Path)) {
            throw "C1b app/$($binding.Relative) cleanup target 越界。"
        }
    }
    $validationFailure = $null
    try { Assert-TL1C1bBuildEnvironmentRepoInputGuardUnchanged $RepoInputGuard }
    catch { $validationFailure = $_ }
    $aclFailure = $null
    foreach ($aclGuard in @(
        $RepoInputGuard.AppRootAclGuard,
        $RepoInputGuard.RepoRootAclGuard
    )) {
        try { Restore-TL1C1bBuildEnvironmentDirectory $aclGuard }
        catch { if ($null -eq $aclFailure) { $aclFailure = $_ } }
    }
    foreach ($binding in $bindings) {
        if ($binding.Guard.Stream -is [IO.FileStream]) {
            $binding.Guard.Stream.Dispose()
        }
    }
    foreach ($binding in $bindings) {
        $expected = Join-Path $RepoInputGuard.AppRoot $binding.Relative
        if (Test-Path -LiteralPath $expected -PathType Leaf) {
            [IO.File]::Delete($expected)
        }
        if (Test-Path -LiteralPath $expected) {
            throw "C1b app/$($binding.Relative) sentinel 未删除。"
        }
    }
    if ($null -ne $validationFailure) { throw $validationFailure }
    if ($null -ne $aclFailure) { throw $aclFailure }
}

function New-TL1C1bBuildEnvironmentModuleBuildOutputGuard {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $repo = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $RepoRoot 'RepoRoot'
    $parent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        (Join-Path $repo 'app\tablet-c1b-probe') 'C1b module root'
    $directory = [IO.Path]::GetFullPath((Join-Path $parent 'build'))
    if (Test-Path -LiteralPath $directory) {
        throw 'C1b module build output 必须在 guard 前 absent；拒绝清理未知内容。'
    }
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    try {
        $aclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $directory `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        return [pscustomobject][ordered]@{
            Directory = $directory
            Parent = $parent
            Name = 'build'
            AclGuard = $aclGuard
            Closed = $false
        }
    } catch {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            [IO.Directory]::Delete($directory)
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentModuleBuildOutputGuardUnchanged {
    param([Parameter(Mandatory)]$Guard)

    if ([bool]$Guard.Closed) { throw 'C1b module build output guard 已关闭。' }
    $directory = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Guard.Directory 'fresh module build output'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $directory $Guard.Directory) -or
        [IO.Path]::GetFileName($directory) -cne 'build' -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetDirectoryName($directory)) $Guard.Parent)) {
        throw 'C1b fresh module build output path binding 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $Guard.AclGuard
}

function Restore-TL1C1bBuildEnvironmentModuleBuildOutputGuard {
    param([AllowNull()]$Guard)

    if ($null -eq $Guard -or [bool]$Guard.AclGuard.Restored) { return }
    Assert-TL1C1bBuildEnvironmentModuleBuildOutputGuardUnchanged $Guard
    Restore-TL1C1bBuildEnvironmentDirectory $Guard.AclGuard
}

function Remove-TL1C1bBuildEnvironmentModuleBuildOutputGuard {
    param([AllowNull()]$Guard)

    if ($null -eq $Guard -or [bool]$Guard.Closed) { return }
    if (-not [bool]$Guard.AclGuard.Restored) {
        throw 'C1b module build output cleanup 前 ACL guard 尚未恢复。'
    }
    $directory = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Guard.Directory 'module build output cleanup target'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $directory $Guard.Directory) -or
        [IO.Path]::GetFileName($directory) -cne 'build' -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetDirectoryName($directory)) $Guard.Parent)) {
        throw 'C1b module build output cleanup target 越界。'
    }
    $inventory = Get-TL1C1bBuildEnvironmentTreeInventory $Guard.Directory
    foreach ($relative in $inventory.Files) {
        $path = Join-Path $Guard.Directory `
            ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $stream = [IO.File]::Open(
            $path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite)
        try {
            if ([TL1C1bBuildEnvironmentFileIdentity]::Read(
                $stream.SafeFileHandle).LinkCount -ne 1) {
                throw 'C1b module build output cleanup 拒绝 hardlink。'
            }
        } finally { $stream.Dispose() }
    }
    Remove-Item -LiteralPath $Guard.Directory -Recurse -Force
    $Guard.Closed = $true
}

function New-TL1C1bBuildEnvironmentWorkspace {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $parentRoot = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Parent 'GRADLE_USER_HOME parent'
    $repo = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $RepoRoot 'RepoRoot'
    $relativeToRepo = [IO.Path]::GetRelativePath($repo, $parentRoot)
    if (-not [IO.Path]::IsPathFullyQualified($relativeToRepo) -and
        $relativeToRepo -cne '..' -and -not $relativeToRepo.StartsWith(
            '..' + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        throw 'C1b GRADLE_USER_HOME parent 不得位于 repository 内。'
    }
    $name = 'tl1-c1b-gradle-user-home-' + [guid]::NewGuid().ToString('N')
    $root = [IO.Path]::GetFullPath((Join-Path $parentRoot $name))
    if (Test-Path -LiteralPath $root) { throw 'C1b 新 GRADLE_USER_HOME 意外已存在。' }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $guards = [Collections.Generic.List[object]]::new()
    $projectCacheAclGuard = $null
    $kotlinRuntimeAclGuard = $null
    $processTempAclGuard = $null
    $rootAclGuard = $null
    try {
        foreach ($fileName in @('init.gradle', 'init.gradle.kts', 'init.d')) {
            $guards.Add((New-TL1C1bBuildEnvironmentEmptyFileGuard `
                (Join-Path $root $fileName)))
        }
        $projectCache = Join-Path $root 'project-cache'
        [IO.Directory]::CreateDirectory($projectCache) | Out-Null
        $projectCacheAclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $projectCache `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        $kotlinRuntime = Join-Path $root 'kotlin-runtime'
        [IO.Directory]::CreateDirectory($kotlinRuntime) | Out-Null
        $kotlinRuntimeAclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $kotlinRuntime `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        $processTemp = Join-Path $root 'process-temp'
        [IO.Directory]::CreateDirectory($processTemp) | Out-Null
        $processTempAclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $processTemp `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        $userHome = Join-Path $root 'user-home'
        [IO.Directory]::CreateDirectory((Join-Path $userHome '.android')) | Out-Null
        $rootAclGuard = Protect-TL1C1bBuildEnvironmentDirectory `
            -Directory $root `
            -Rights ([Security.AccessControl.FileSystemRights]::Delete)
        return [pscustomobject][ordered]@{
            Parent = $parentRoot
            Root = $root
            Name = $name
            InitGradleGuard = $guards[0]
            InitGradleKtsGuard = $guards[1]
            InitDDirectoryBlockerGuard = $guards[2]
            ProjectCacheDirectory = [IO.Path]::GetFullPath($projectCache)
            ProjectCacheAclGuard = $projectCacheAclGuard
            KotlinRuntimeDirectory = [IO.Path]::GetFullPath($kotlinRuntime)
            KotlinRuntimeAclGuard = $kotlinRuntimeAclGuard
            ProcessTempDirectory = [IO.Path]::GetFullPath($processTemp)
            ProcessTempAclGuard = $processTempAclGuard
            UserHomeDirectory = [IO.Path]::GetFullPath($userHome)
            RootAclGuard = $rootAclGuard
        }
    } catch {
        if ($null -ne $rootAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $rootAclGuard } catch { }
        }
        if ($null -ne $kotlinRuntimeAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $kotlinRuntimeAclGuard } catch { }
        }
        if ($null -ne $processTempAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $processTempAclGuard } catch { }
        }
        if ($null -ne $projectCacheAclGuard) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $projectCacheAclGuard } catch { }
        }
        foreach ($guard in $guards) { $guard.Stream.Dispose() }
        if (Test-Path -LiteralPath $root -PathType Container) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentWorkspaceUnchanged {
    param([Parameter(Mandatory)]$Workspace)

    $root = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Workspace.Root 'GRADLE_USER_HOME'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $root $Workspace.Root)) {
        throw 'C1b GRADLE_USER_HOME canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentEmptyFileGuardUnchanged `
        $Workspace.InitGradleGuard 'GRADLE_USER_HOME/init.gradle'
    Assert-TL1C1bBuildEnvironmentEmptyFileGuardUnchanged `
        $Workspace.InitGradleKtsGuard 'GRADLE_USER_HOME/init.gradle.kts'
    Assert-TL1C1bBuildEnvironmentEmptyFileGuardUnchanged `
        $Workspace.InitDDirectoryBlockerGuard 'GRADLE_USER_HOME/init.d blocker'
    if (Test-Path -LiteralPath (Join-Path $root 'init.d') -PathType Container) {
        throw 'C1b GRADLE_USER_HOME/init.d directory 不得创建。'
    }
    $projectCache = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Workspace.ProjectCacheDirectory 'fresh Gradle project cache'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        $projectCache $Workspace.ProjectCacheDirectory)) {
        throw 'C1b fresh Gradle project cache canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $Workspace.ProjectCacheAclGuard
    $kotlinRuntime = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Workspace.KotlinRuntimeDirectory 'fresh Kotlin runtime cache'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        $kotlinRuntime $Workspace.KotlinRuntimeDirectory)) {
        throw 'C1b fresh Kotlin runtime cache canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $Workspace.KotlinRuntimeAclGuard
    $processTemp = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Workspace.ProcessTempDirectory 'fresh process temp'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        $processTemp $Workspace.ProcessTempDirectory)) {
        throw 'C1b fresh process temp canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $Workspace.ProcessTempAclGuard
    $userHome = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Workspace.UserHomeDirectory 'fresh user.home'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        $userHome $Workspace.UserHomeDirectory)) {
        throw 'C1b fresh user.home canonical path 漂移。'
    }
    Assert-TL1C1bBuildEnvironmentDirectoryProtected $Workspace.RootAclGuard
}

function Assert-TL1C1bBuildEnvironmentRecoveryJournalPath {
    param([Parameter(Mandatory)][string]$JournalPath)

    if (-not [IO.Path]::IsPathFullyQualified($JournalPath)) {
        throw 'C1b ACL recovery journal 必须是绝对路径。'
    }
    $full = [IO.Path]::GetFullPath($JournalPath)
    if ([IO.Path]::GetFileName($full) -cnotmatch
        '^\.tl1-c1b-build-env-acl-[0-9a-f]{32}\.jsonl$') {
        throw 'C1b ACL recovery journal 名称不在专用 allowlist。'
    }
    $parent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($full)) 'ACL recovery journal parent'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        ([IO.Path]::GetDirectoryName($full)) $parent)) {
        throw 'C1b ACL recovery journal parent canonical path 漂移。'
    }
    return $full
}

function New-TL1C1bBuildEnvironmentRecoveryJournalSecurity {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $sid) { throw 'C1b 无法解析 recovery journal owner SID。' }
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$security.AddAccessRule($rule)
    $denyRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        ([Security.AccessControl.FileSystemRights]::WriteData -bor
            [Security.AccessControl.FileSystemRights]::AppendData -bor
            [Security.AccessControl.FileSystemRights]::Delete),
        [Security.AccessControl.AccessControlType]::Deny
    )
    [void]$security.AddAccessRule($denyRule)
    return $security
}

function Set-TL1C1bBuildEnvironmentRecoveryJournalAcl {
    param([Parameter(Mandatory)][string]$JournalPath)

    $security = New-TL1C1bBuildEnvironmentRecoveryJournalSecurity
    [IO.FileSystemAclExtensions]::SetAccessControl(
        [IO.FileInfo]::new($JournalPath), $security)
}

function Assert-TL1C1bBuildEnvironmentRecoveryJournalAcl {
    param([Parameter(Mandatory)][string]$JournalPath)

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $actual = [IO.FileSystemAclExtensions]::GetAccessControl(
        [IO.FileInfo]::new($JournalPath),
        [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner)
    $expected = New-TL1C1bBuildEnvironmentRecoveryJournalSecurity
    $actualAccess = $actual.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    $expectedAccess = $expected.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    $expectedAppliedAccess = $expectedAccess -replace '^D:P', 'D:PAI'
    if ($actual.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or
        ($actualAccess -cne $expectedAccess -and
            $actualAccess -cne $expectedAppliedAccess)) {
        throw 'C1b ACL recovery journal owner/access ACL 不是 exact protected form。'
    }
}

function Write-TL1C1bBuildEnvironmentRecoveryJournalRecord {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)]$Record
    )

    if ($Journal.Stream -isnot [IO.FileStream] -or
        $Journal.Stream.SafeFileHandle.IsClosed -or
        $Journal.Stream.SafeFileHandle.IsInvalid -or
        -not $Journal.Stream.CanRead -or -not $Journal.Stream.CanWrite) {
        throw 'C1b ACL recovery journal stream 已关闭。'
    }
    $json = $Record | ConvertTo-Json -Depth 4 -Compress
    if ($json.Contains("`r") -or $json.Contains("`n")) {
        throw 'C1b ACL recovery journal record 不得含换行。'
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $payload = $utf8.GetBytes($json)
    try {
        $line = [Convert]::ToBase64String($payload) + '|' +
            (Get-TL1C1bBuildEnvironmentSha256Bytes $payload) + "`n"
        $bytes = $utf8.GetBytes($line)
        try {
            $Journal.Stream.Position = $Journal.Stream.Length
            $Journal.Stream.Write($bytes, 0, $bytes.Length)
            $Journal.Stream.Flush($true)
        } finally {
            if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
    } finally {
        if ($payload.Length -ne 0) { [Array]::Clear($payload, 0, $payload.Length) }
    }
}

function New-TL1C1bBuildEnvironmentRecoveryJournal {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$AllowedRoots
    )

    $canonicalParent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Parent 'ACL recovery journal parent'
    $pending = @([IO.Directory]::EnumerateFiles(
        $canonicalParent, '.tl1-c1b-build-env-acl-*.jsonl',
        [IO.SearchOption]::TopDirectoryOnly))
    if ($pending.Count -ne 0) {
        throw ('C1b 检出未完成 ACL recovery journal；先调用 ' +
            'Repair-TL1C1bBuildEnvironmentRecoveryJournal：' +
            (($pending | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', '))
    }
    if ($null -ne $script:TL1C1bBuildEnvironmentActiveRecoveryJournal) {
        throw 'C1b 当前进程已有 active ACL recovery journal。'
    }
    $journalId = [guid]::NewGuid().ToString('N')
    $path = Assert-TL1C1bBuildEnvironmentRecoveryJournalPath (
        Join-Path $canonicalParent ('.tl1-c1b-build-env-acl-' + $journalId + '.jsonl'))
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $path, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read)
        Set-TL1C1bBuildEnvironmentRecoveryJournalAcl $path
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
        if ($identity.LinkCount -ne 1) {
            throw 'C1b ACL recovery journal hardlink count 必须 exact 1。'
        }
        $parentHandle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete(
            $canonicalParent)
        try {
            $parentIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($parentHandle)
        } finally { $parentHandle.Dispose() }
        $rootBindings = [Collections.Generic.List[object]]::new()
        $canonicalRoots = [string[]]@($AllowedRoots | ForEach-Object {
            Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $_ 'ACL recovery allowed root'
        })
        [Array]::Sort($canonicalRoots, [StringComparer]::OrdinalIgnoreCase)
        for ($index = 0; $index -lt $canonicalRoots.Count; $index++) {
            if ($index -gt 0 -and (Test-TL1C1bBuildEnvironmentPathEqual `
                $canonicalRoots[$index] $canonicalRoots[$index - 1])) {
                throw 'C1b ACL recovery allowed root 不得重复。'
            }
            $rootHandle =
                [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete(
                    $canonicalRoots[$index])
            try { $rootIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($rootHandle) }
            finally { $rootHandle.Dispose() }
            $rootBindings.Add([pscustomobject][ordered]@{
                path = $canonicalRoots[$index]
                stable_id = $rootIdentity.StableId
            })
        }
        $journal = [pscustomobject][ordered]@{
            Schema = $script:TL1C1bBuildEnvironmentRecoverySchema
            JournalId = $journalId
            Path = $path
            Parent = $canonicalParent
            ParentIdentity = $parentIdentity.StableId
            FileIdentity = $identity.StableId
            Stream = $stream
            Entries = [Collections.Generic.List[object]]::new()
            AllowedRoots = $rootBindings.ToArray()
            Removed = $false
        }
        Write-TL1C1bBuildEnvironmentRecoveryJournalRecord $journal `
            ([pscustomobject][ordered]@{
                kind = 'header'
                schema = $script:TL1C1bBuildEnvironmentRecoverySchema
                journal_id = $journalId
                parent_path = $canonicalParent
                parent_identity = $parentIdentity.StableId
                allowed_roots = $rootBindings.ToArray()
            })
        return $journal
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { [IO.File]::Delete($path) } catch { }
        }
        throw
    }
}

function Add-TL1C1bBuildEnvironmentRecoveryJournalEntry {
    param(
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$OriginalSddl,
        [Parameter(Mandatory)][string]$AppliedSddl
    )

    $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Directory 'ACL recovery directory'
    if ([string]::IsNullOrWhiteSpace($OriginalSddl) -or
        [string]::IsNullOrWhiteSpace($AppliedSddl)) {
        throw 'C1b ACL recovery SDDL 不得为空。'
    }
    if (@($Journal.AllowedRoots | Where-Object {
        Test-TL1C1bBuildEnvironmentPathWithinRoot $canonical ([string]$_.path)
    }).Count -eq 0) {
        throw 'C1b ACL recovery entry 越出 journal allowed roots。'
    }
    foreach ($existing in $Journal.Entries) {
        if (Test-TL1C1bBuildEnvironmentPathEqual $existing.Directory $canonical) {
            throw 'C1b ACL recovery journal 不接受重复 directory。'
        }
    }
    $handle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($canonical)
    try { $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($handle) }
    finally { $handle.Dispose() }
    $entry = [pscustomobject][ordered]@{
        Sequence = $Journal.Entries.Count + 1
        Directory = $canonical
        StableId = $identity.StableId
        OriginalSddl = $OriginalSddl
        AppliedSddl = $AppliedSddl
    }
    Write-TL1C1bBuildEnvironmentRecoveryJournalRecord $Journal `
        ([pscustomobject][ordered]@{
            kind = 'directory_acl'
            sequence = $entry.Sequence
            directory = $entry.Directory
            stable_id = $entry.StableId
            original_sddl = $entry.OriginalSddl
            applied_sddl = $entry.AppliedSddl
        })
    $Journal.Entries.Add($entry)
}

function Get-TL1C1bBuildEnvironmentRecoveryJournalBinding {
    param([Parameter(Mandatory)]$Journal)

    if ([bool]$Journal.Removed -or $Journal.Stream.SafeFileHandle.IsClosed) {
        throw 'C1b ACL recovery journal 已关闭。'
    }
    $Journal.Stream.Flush($true)
    Assert-TL1C1bBuildEnvironmentRecoveryJournalAcl $Journal.Path
    $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
        $Journal.Stream.SafeFileHandle)
    if ($identity.LinkCount -ne 1 -or
        [string]$identity.StableId -cne [string]$Journal.FileIdentity) {
        throw 'C1b ACL recovery journal identity/hardlink count 漂移。'
    }
    return [pscustomobject][ordered]@{
        schema = $script:TL1C1bBuildEnvironmentRecoverySchema
        directory_entry_count = $Journal.Entries.Count
        sha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $Journal.Stream
        file_deny_write_delete = $true
    }
}

function Read-TL1C1bBuildEnvironmentRecoveryJournalRecords {
    param([Parameter(Mandatory)][IO.FileStream]$Stream)

    if ($Stream.Length -lt 1 -or $Stream.Length -gt 67108864) {
        throw 'C1b ACL recovery journal 长度越界。'
    }
    $bytes = [byte[]]::new([int]$Stream.Length)
    try {
        $Stream.Position = 0
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $Stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) { throw 'C1b ACL recovery journal 意外截断。' }
            $offset += $read
        }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    } finally {
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal) -or
        $text.Contains("`r")) {
        throw 'C1b ACL recovery journal 必须为 complete LF records。'
    }
    $lines = [string[]]@($text.Substring(0, $text.Length - 1).Split("`n"))
    $records = [Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw 'C1b ACL recovery journal 含空 record。'
        }
        $separator = $line.LastIndexOf('|')
        if ($separator -lt 1) { throw 'C1b ACL recovery journal record 格式无效。' }
        $payload = $null
        try {
            $payload = [Convert]::FromBase64String($line.Substring(0, $separator))
            $expected = $line.Substring($separator + 1)
            if ($expected -cnotmatch '^sha256:[0-9a-f]{64}$' -or
                (Get-TL1C1bBuildEnvironmentSha256Bytes $payload) -cne $expected) {
                throw 'C1b ACL recovery journal record checksum 漂移。'
            }
            $json = [Text.UTF8Encoding]::new($false, $true).GetString($payload)
            $records.Add(($json | ConvertFrom-Json -Depth 4))
        } finally {
            if ($null -ne $payload -and $payload.Length -ne 0) {
                [Array]::Clear($payload, 0, $payload.Length)
            }
        }
    }
    return $records.ToArray()
}

function Assert-TL1C1bBuildEnvironmentRecoveryRecordKeys {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string[]]$ExpectedKeys
    )

    $actual = [string[]]@($Record.PSObject.Properties.Name)
    if (($actual -join "`n") -cne ($ExpectedKeys -join "`n")) {
        throw 'C1b ACL recovery journal record 字段集合漂移。'
    }
}

function Test-TL1C1bBuildEnvironmentPathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    return (Test-TL1C1bBuildEnvironmentPathEqual $fullPath $fullRoot) -or
        $fullPath.StartsWith(
            $fullRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)
}

function Repair-TL1C1bBuildEnvironmentRecoveryJournal {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedSha256,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$AllowedRoots
    )

    $path = Assert-TL1C1bBuildEnvironmentRecoveryJournalPath $JournalPath
    if ($null -ne $script:TL1C1bBuildEnvironmentActiveRecoveryJournal -and
        (Test-TL1C1bBuildEnvironmentPathEqual `
            $script:TL1C1bBuildEnvironmentActiveRecoveryJournal.Path $path)) {
        throw 'C1b 不得 repair 当前进程 active ACL recovery journal。'
    }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace((Get-TL1C1bBuildEnvironmentLinkType $item))) {
        throw 'C1b ACL recovery journal 必须是 ordinary file。'
    }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    Assert-TL1C1bBuildEnvironmentRecoveryJournalAcl $path
    $stream = [IO.File]::Open(
        $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $repaired = $false
    try {
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
        if ($identity.LinkCount -ne 1) {
            throw 'C1b ACL recovery journal hardlink count 必须 exact 1。'
        }
        $actualSha256 = Get-TL1C1bBuildEnvironmentStreamSha256 $stream
        if ($actualSha256 -cne $ExpectedSha256) {
            throw 'C1b ACL recovery journal SHA-256 与显式期望不一致。'
        }
        $records = @(Read-TL1C1bBuildEnvironmentRecoveryJournalRecords $stream)
        if ($records.Count -lt 1) { throw 'C1b ACL recovery journal 缺少 header。' }
        Assert-TL1C1bBuildEnvironmentRecoveryRecordKeys $records[0] @(
            'kind', 'schema', 'journal_id', 'parent_path', 'parent_identity',
            'allowed_roots')
        $header = $records[0]
        if ([string]$header.kind -cne 'header' -or
            [string]$header.schema -cne $script:TL1C1bBuildEnvironmentRecoverySchema -or
            [string]$header.journal_id -cnotmatch '^[0-9a-f]{32}$' -or
            [IO.Path]::GetFileName($path) -cne
                ('.tl1-c1b-build-env-acl-' + [string]$header.journal_id + '.jsonl')) {
            throw 'C1b ACL recovery journal header binding 漂移。'
        }
        $parent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            ([string]$header.parent_path) 'ACL recovery journal parent'
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
            $parent ([IO.Path]::GetDirectoryName($path)))) {
            throw 'C1b ACL recovery journal parent path binding 漂移。'
        }
        $parentHandle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($parent)
        try { $parentIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($parentHandle) }
        finally { $parentHandle.Dispose() }
        if ([string]$parentIdentity.StableId -cne [string]$header.parent_identity) {
            throw 'C1b ACL recovery journal parent identity 漂移。'
        }
        $trustedRoots = [string[]]@($AllowedRoots | ForEach-Object {
            Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
                $_ 'explicit ACL recovery allowed root'
        })
        [Array]::Sort($trustedRoots, [StringComparer]::OrdinalIgnoreCase)
        $headerRoots = @($header.allowed_roots)
        if ($headerRoots.Count -ne $trustedRoots.Count -or $trustedRoots.Count -lt 1) {
            throw 'C1b ACL recovery journal allowed roots count 漂移。'
        }
        for ($rootIndex = 0; $rootIndex -lt $trustedRoots.Count; $rootIndex++) {
            Assert-TL1C1bBuildEnvironmentRecoveryRecordKeys `
                $headerRoots[$rootIndex] @('path', 'stable_id')
            if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
                    ([string]$headerRoots[$rootIndex].path) $trustedRoots[$rootIndex])) {
                throw 'C1b ACL recovery journal allowed root path 漂移。'
            }
            $rootHandle =
                [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete(
                    $trustedRoots[$rootIndex])
            try { $rootIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($rootHandle) }
            finally { $rootHandle.Dispose() }
            if ([string]$rootIdentity.StableId -cne
                [string]$headerRoots[$rootIndex].stable_id) {
                throw 'C1b ACL recovery journal allowed root identity 漂移。'
            }
        }
        $entries = [Collections.Generic.List[object]]::new()
        $seen = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        for ($index = 1; $index -lt $records.Count; $index++) {
            $record = $records[$index]
            Assert-TL1C1bBuildEnvironmentRecoveryRecordKeys $record @(
                'kind', 'sequence', 'directory', 'stable_id',
                'original_sddl', 'applied_sddl')
            if ([string]$record.kind -cne 'directory_acl' -or
                [int]$record.sequence -ne $index -or
                [string]$record.stable_id -cnotmatch '^[0-9A-F]{8}:[0-9A-F]{16}$' -or
                [string]::IsNullOrWhiteSpace([string]$record.original_sddl) -or
                [string]::IsNullOrWhiteSpace([string]$record.applied_sddl)) {
                throw 'C1b ACL recovery journal directory record 无效。'
            }
            $directory = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
                ([string]$record.directory) 'ACL recovery directory'
            if (@($trustedRoots | Where-Object {
                Test-TL1C1bBuildEnvironmentPathWithinRoot $directory $_
            }).Count -eq 0) {
                throw 'C1b ACL recovery directory 越出 explicit allowed roots。'
            }
            if (-not $seen.Add($directory)) {
                throw 'C1b ACL recovery journal directory 不得重复。'
            }
            $handle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($directory)
            try { $directoryIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($handle) }
            finally { $handle.Dispose() }
            $security = [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($directory))
            $currentSddl = $security.GetSecurityDescriptorSddlForm(
                [Security.AccessControl.AccessControlSections]::Access)
            if ([string]$directoryIdentity.StableId -cne [string]$record.stable_id -or
                (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                        $currentSddl ([string]$record.original_sddl)) -and
                    -not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                        $currentSddl ([string]$record.applied_sddl)))) {
                throw 'C1b ACL recovery directory identity/SDDL 不在 journal 允许状态。'
            }
            $entries.Add([pscustomobject][ordered]@{
                Directory = $directory
                OriginalSddl = [string]$record.original_sddl
                AppliedSddl = [string]$record.applied_sddl
            })
        }
        if (-not $PSCmdlet.ShouldProcess($path, 'restore recorded directory ACLs')) {
            return [pscustomobject][ordered]@{
                journal_sha256 = $actualSha256
                directory_entry_count = $entries.Count
                repaired = $false
            }
        }
        for ($index = $entries.Count - 1; $index -ge 0; $index--) {
            $entry = $entries[$index]
            $directoryInfo = [IO.DirectoryInfo]::new($entry.Directory)
            $security = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
            $currentSddl = $security.GetSecurityDescriptorSddlForm(
                [Security.AccessControl.AccessControlSections]::Access)
            if (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                    $currentSddl $entry.AppliedSddl) {
                $security.SetSecurityDescriptorSddlForm(
                    $entry.OriginalSddl,
                    [Security.AccessControl.AccessControlSections]::Access)
                [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $security)
            }
            $verify = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo).
                GetSecurityDescriptorSddlForm(
                    [Security.AccessControl.AccessControlSections]::Access)
            if (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                    $verify $entry.OriginalSddl)) {
                throw 'C1b ACL recovery 未恢复 exact original SDDL。'
            }
        }
        $deleteSecurity = [Security.AccessControl.FileSecurity]::new()
        $deleteSecurity.SetOwner($currentSid)
        $deleteSecurity.SetAccessRuleProtection($true, $false)
        [void]$deleteSecurity.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $currentSid, [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl(
            [IO.FileInfo]::new($path), $deleteSecurity)
        $repaired = $true
    } finally {
        $stream.Dispose()
    }
    if ($repaired) { [IO.File]::Delete($path) }
    return [pscustomobject][ordered]@{
        journal_sha256 = $actualSha256
        directory_entry_count = $entries.Count
        repaired = $true
    }
}

function Remove-TL1C1bBuildEnvironmentRecoveryJournal {
    param([AllowNull()]$Journal)

    if ($null -eq $Journal -or [bool]$Journal.Removed) { return }
    $path = Assert-TL1C1bBuildEnvironmentRecoveryJournalPath $Journal.Path
    $failure = $null
    try {
        Assert-TL1C1bBuildEnvironmentRecoveryJournalAcl $path
        foreach ($entry in $Journal.Entries) {
            $directory = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
                $entry.Directory 'ACL recovery normal-close directory'
            $current = [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.DirectoryInfo]::new($directory)).GetSecurityDescriptorSddlForm(
                    [Security.AccessControl.AccessControlSections]::Access)
            if (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                    $current ([string]$entry.OriginalSddl))) {
                throw 'C1b ACL recovery journal 保留：directory 尚未恢复 original SDDL。'
            }
        }
        $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
            $Journal.Stream.SafeFileHandle)
        if ($identity.LinkCount -ne 1 -or
            [string]$identity.StableId -cne [string]$Journal.FileIdentity) {
            throw 'C1b ACL recovery journal cleanup identity 漂移。'
        }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $deleteSecurity = [Security.AccessControl.FileSecurity]::new()
        $deleteSecurity.SetOwner($sid)
        $deleteSecurity.SetAccessRuleProtection($true, $false)
        [void]$deleteSecurity.AddAccessRule(
            [Security.AccessControl.FileSystemAccessRule]::new(
                $sid, [Security.AccessControl.FileSystemRights]::FullControl,
                [Security.AccessControl.AccessControlType]::Allow))
        [IO.FileSystemAclExtensions]::SetAccessControl(
            [IO.FileInfo]::new($path), $deleteSecurity)
    } catch { $failure = $_ }
    if ($Journal.Stream -is [IO.FileStream]) { $Journal.Stream.Dispose() }
    if ($null -eq $failure) {
        [IO.File]::Delete($path)
        $Journal.Removed = $true
    } else { throw $failure }
}

function Test-TL1C1bBuildEnvironmentDirectoryCreateDenied {
    param([Parameter(Mandatory)][string]$Directory)

    $fileProbe = Join-Path $Directory ('.c1b-create-probe-' +
        [guid]::NewGuid().ToString('N') + '.tmp')
    $fileCreated = $false
    try {
        try {
            $stream = [IO.File]::Open(
                $fileProbe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            try { $stream.Flush($true) } finally { $stream.Dispose() }
            $fileCreated = $true
        } catch [UnauthorizedAccessException] { }
        if ($fileCreated) { return $false }
    } finally {
        if ($fileCreated -and (Test-Path -LiteralPath $fileProbe -PathType Leaf)) {
            [IO.File]::Delete($fileProbe)
        }
    }

    $directoryProbe = Join-Path $Directory ('.c1b-directory-probe-' +
        [guid]::NewGuid().ToString('N'))
    $directoryCreated = $false
    try {
        try {
            [IO.Directory]::CreateDirectory($directoryProbe) | Out-Null
            $directoryCreated = $true
        } catch [UnauthorizedAccessException] { }
        if ($directoryCreated) { return $false }
    } finally {
        if ($directoryCreated -and
            (Test-Path -LiteralPath $directoryProbe -PathType Container)) {
            [IO.Directory]::Delete($directoryProbe)
        }
    }
    return $true
}

function Protect-TL1C1bBuildEnvironmentDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Security.AccessControl.FileSystemRights]$Rights = (
            [Security.AccessControl.FileSystemRights]::CreateFiles -bor
            [Security.AccessControl.FileSystemRights]::CreateDirectories -bor
            [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor
            [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
            [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes
        )
    )

    $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $Directory 'tree ACL directory'
    $directoryInfo = [IO.DirectoryInfo]::new($canonical)
    $security = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
    $originalSddl = $security.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $sid) { throw 'C1b 无法解析当前 Windows SID。' }
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid,
        $Rights,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Deny
    )
    [void]$security.AddAccessRule($rule)
    $plannedSddl = $security.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    if ($null -ne $script:TL1C1bBuildEnvironmentActiveRecoveryJournal) {
        Add-TL1C1bBuildEnvironmentRecoveryJournalEntry `
            $script:TL1C1bBuildEnvironmentActiveRecoveryJournal `
            $canonical $originalSddl $plannedSddl
    }
    $modified = $false
    try {
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $security)
        $modified = $true
    } catch {
        $text = $_.Exception.ToString()
        if ($text -notmatch 'UnauthorizedAccess|Access.*denied|拒绝访问') { throw }
        $afterFailure = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
        $afterFailureSddl = $afterFailure.GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::Access)
        $requiresDenyCreate = (($Rights -band
            [Security.AccessControl.FileSystemRights]::CreateFiles) -ne 0) -or
            (($Rights -band
                [Security.AccessControl.FileSystemRights]::CreateDirectories) -ne 0)
        if (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                $afterFailureSddl $originalSddl) -or
            ($requiresDenyCreate -and
                -not (Test-TL1C1bBuildEnvironmentDirectoryCreateDenied $canonical))) {
            throw 'C1b tree directory 可新增 entry 且无法安装 deny-create ACL。'
        }
    }
    $applied = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
    $appliedSddl = $applied.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    $directoryHandle = $null
    try {
        if ($modified -and -not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                $appliedSddl $plannedSddl)) {
            throw "C1b applied directory ACL 未与 recovery journal planned SDDL exact 一致：$canonical；planned=$(Get-TL1C1bBuildEnvironmentSha256Text $plannedSddl)；applied=$(Get-TL1C1bBuildEnvironmentSha256Text $appliedSddl)。"
        }
        $directoryHandle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete(
            $canonical)
        $directoryIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($directoryHandle)
        return [pscustomobject][ordered]@{
            Directory = $canonical
            OriginalSddl = $originalSddl
            AppliedSddl = $appliedSddl
            Sid = $sid.Value
            Rights = [long]$Rights
            Modified = $modified
            DirectoryHandle = $directoryHandle
            DirectoryIdentity = $directoryIdentity.StableId
            Restored = $false
        }
    } catch {
        if ($null -ne $directoryHandle) { $directoryHandle.Dispose() }
        if ($modified) {
            try {
                $restore = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
                $restore.SetSecurityDescriptorSddlForm(
                    $originalSddl,
                    [Security.AccessControl.AccessControlSections]::Access)
                [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $restore)
            } catch { }
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentDirectoryProtected {
    param([Parameter(Mandatory)]$AclGuard)

    $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $AclGuard.Directory 'tree ACL directory'
    $current = [IO.FileSystemAclExtensions]::GetAccessControl(
        [IO.DirectoryInfo]::new($canonical))
    $sddl = $current.GetSecurityDescriptorSddlForm(
        [Security.AccessControl.AccessControlSections]::Access)
    if ($sddl -cne [string]$AclGuard.AppliedSddl) {
        throw 'C1b build-environment tree directory ACL 漂移。'
    }
    if ($AclGuard.DirectoryHandle.IsClosed -or $AclGuard.DirectoryHandle.IsInvalid) {
        throw 'C1b build-environment tree directory handle 已关闭。'
    }
    $heldIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read(
        $AclGuard.DirectoryHandle)
    $pathHandle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($canonical)
    try {
        $pathIdentity = [TL1C1bBuildEnvironmentFileIdentity]::Read($pathHandle)
        if ([string]$heldIdentity.StableId -cne [string]$AclGuard.DirectoryIdentity -or
            [string]$pathIdentity.StableId -cne [string]$AclGuard.DirectoryIdentity) {
            throw 'C1b build-environment current directory/held handle identity 漂移。'
        }
    } finally { $pathHandle.Dispose() }
    $requiresDenyCreate = (([long]$AclGuard.Rights -band
        [long][Security.AccessControl.FileSystemRights]::CreateFiles) -ne 0) -or
        (([long]$AclGuard.Rights -band
            [long][Security.AccessControl.FileSystemRights]::CreateDirectories) -ne 0)
    if (-not [bool]$AclGuard.Modified -and $requiresDenyCreate -and
        -not (Test-TL1C1bBuildEnvironmentDirectoryCreateDenied $canonical)) {
        throw 'C1b pre-existing tree directory ACL 不再 deny create。'
    }
}

function Restore-TL1C1bBuildEnvironmentDirectory {
    param([AllowNull()]$AclGuard)

    if ($null -eq $AclGuard -or [bool]$AclGuard.Restored) { return }
    $restoreCompleted = $false
    try {
        $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            $AclGuard.Directory 'tree ACL restore target'
        $directoryInfo = [IO.DirectoryInfo]::new($canonical)
        $current = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
        $currentSddl = $current.GetSecurityDescriptorSddlForm(
            [Security.AccessControl.AccessControlSections]::Access)
        $drifted = $currentSddl -cne [string]$AclGuard.AppliedSddl
        if ([bool]$AclGuard.Modified) {
            $current.SetSecurityDescriptorSddlForm(
                [string]$AclGuard.OriginalSddl,
                [Security.AccessControl.AccessControlSections]::Access)
            [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $current)
        }
        $restoredSddl = [IO.FileSystemAclExtensions]::GetAccessControl(
            $directoryInfo).GetSecurityDescriptorSddlForm(
                [Security.AccessControl.AccessControlSections]::Access)
        if (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
                $restoredSddl ([string]$AclGuard.OriginalSddl))) {
            throw 'C1b build-environment tree directory ACL 未恢复 original SDDL。'
        }
        $restoreCompleted = $true
        if ($drifted) {
            throw 'C1b build-environment tree directory ACL 在恢复前已漂移。'
        }
    } finally {
        try {
            if ($AclGuard.DirectoryHandle -is `
                    [Microsoft.Win32.SafeHandles.SafeFileHandle]) {
                $AclGuard.DirectoryHandle.Dispose()
            }
        } finally {
            $AclGuard.Restored = $restoreCompleted
        }
    }
}

function Protect-TL1C1bBuildEnvironmentTreeDirectories {
    param([Parameter(Mandatory)]$TreeGuard)

    $relativeDirectories = [string[]]@($TreeGuard.DirectoryRelativePaths)
    $paths = [Collections.Generic.List[string]]::new()
    $paths.Add([string]$TreeGuard.Root)
    foreach ($relative in $relativeDirectories) {
        $paths.Add([IO.Path]::GetFullPath((Join-Path $TreeGuard.Root `
            ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))))
    }
    $guards = [Collections.Generic.List[object]]::new()
    try {
        # Parent-first closes rename/create races at each boundary before descending. Every rule is
        # non-inherited so restoration can reproduce each directory's exact original SDDL.
        foreach ($path in $paths) {
            $guards.Add((Protect-TL1C1bBuildEnvironmentDirectory $path))
        }
        $result = [pscustomobject][ordered]@{
            Name = [string]$TreeGuard.Name
            Entries = $guards.ToArray()
            ProtectedDirectoryCount = $guards.Count
        }
        Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected $result
        [void](Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $TreeGuard)
        return $result
    } catch {
        for ($index = $guards.Count - 1; $index -ge 0; $index--) {
            try { Restore-TL1C1bBuildEnvironmentDirectory $guards[$index] } catch { }
        }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected {
    param([Parameter(Mandatory)]$AclGuards)

    if (@($AclGuards.Entries).Count -ne [int]$AclGuards.ProtectedDirectoryCount -or
        [int]$AclGuards.ProtectedDirectoryCount -lt 1) {
        throw 'C1b build-environment tree directory ACL guard 结构无效。'
    }
    foreach ($entry in @($AclGuards.Entries)) {
        Assert-TL1C1bBuildEnvironmentDirectoryProtected $entry
    }
}

function Restore-TL1C1bBuildEnvironmentTreeDirectories {
    param([AllowNull()]$AclGuards)

    if ($null -eq $AclGuards) { return }
    $failures = [Collections.Generic.List[string]]::new()
    $entries = @($AclGuards.Entries)
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        try { Restore-TL1C1bBuildEnvironmentDirectory $entries[$index] }
        catch { $failures.Add($_.Exception.Message) }
    }
    if ($failures.Count -ne 0) {
        throw ('C1b build-environment tree directory ACL 未完整恢复：' +
            ($failures -join ' | '))
    }
}

function Open-TL1C1bBuildEnvironmentPathChainGuard {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$DirectoryPaths
    )

    $pathMap = [Collections.Generic.Dictionary[string,string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($rawPath in $DirectoryPaths) {
        $cursor = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            $rawPath 'path-chain trust root'
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            $pathMap[$cursor] = $cursor
            $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar))
            if ([string]::IsNullOrWhiteSpace($parent) -or
                (Test-TL1C1bBuildEnvironmentPathEqual $parent $cursor)) { break }
            $cursor = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
                $parent 'path-chain ancestor'
        }
    }
    $paths = [string[]]@($pathMap.Values)
    [Array]::Sort($paths, [Comparison[string]]{
        param($left, $right)
        $depth = $left.Length.CompareTo($right.Length)
        if ($depth -ne 0) { return $depth }
        return [StringComparer]::OrdinalIgnoreCase.Compare($left, $right)
    })
    $entries = [Collections.Generic.List[object]]::new()
    try {
        foreach ($path in $paths) {
            $handle = [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($path)
            try {
                $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($handle)
                $entries.Add([pscustomobject][ordered]@{
                    Path = $path
                    StableId = $identity.StableId
                    Handle = $handle
                })
            } catch { $handle.Dispose(); throw }
        }
        return [pscustomobject][ordered]@{
            Entries = $entries.ToArray()
            DirectoryCount = $entries.Count
        }
    } catch {
        foreach ($entry in $entries) { $entry.Handle.Dispose() }
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentPathChainGuardUnchanged {
    param([Parameter(Mandatory)]$PathChainGuard)

    if (@($PathChainGuard.Entries).Count -ne [int]$PathChainGuard.DirectoryCount -or
        [int]$PathChainGuard.DirectoryCount -lt 1) {
        throw 'C1b path-chain guard 结构无效。'
    }
    foreach ($entry in $PathChainGuard.Entries) {
        if ($entry.Handle.IsClosed -or $entry.Handle.IsInvalid) {
            throw 'C1b path-chain directory handle 已关闭。'
        }
        $canonical = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            $entry.Path 'path-chain directory'
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual $canonical $entry.Path)) {
            throw 'C1b path-chain canonical path 漂移。'
        }
        $held = [TL1C1bBuildEnvironmentFileIdentity]::Read($entry.Handle)
        $currentHandle =
            [TL1C1bBuildEnvironmentFileIdentity]::OpenDirectoryDenyDelete($canonical)
        try {
            $current = [TL1C1bBuildEnvironmentFileIdentity]::Read($currentHandle)
            if ([string]$held.StableId -cne [string]$entry.StableId -or
                [string]$current.StableId -cne [string]$entry.StableId) {
                throw 'C1b path-chain held/current directory identity 漂移。'
            }
        } finally { $currentHandle.Dispose() }
    }
}

function Close-TL1C1bBuildEnvironmentPathChainGuard {
    param([AllowNull()]$PathChainGuard)

    if ($null -eq $PathChainGuard) { return }
    $entries = @($PathChainGuard.Entries)
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        if ($entries[$index].Handle -is [Microsoft.Win32.SafeHandles.SafeFileHandle]) {
            $entries[$index].Handle.Dispose()
        }
    }
}

function Open-TL1C1bBuildEnvironmentConcurrencyGuard {
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$TrustTuplePaths
    )

    $paths = [string[]]@($TrustTuplePaths | ForEach-Object {
        [IO.Path]::GetFullPath($_).ToUpperInvariant()
    })
    $tupleSha256 = Get-TL1C1bBuildEnvironmentSha256Text ($paths -join "`n")
    $name = 'Local\TL1C1bBuildEnvironment-v1'
    if ($script:TL1C1bBuildEnvironmentActiveMutexNames.Contains($name)) {
        throw 'C1b 相同 canonical trust tuple 已由当前进程持有。'
    }
    $mutex = [Threading.Mutex]::new($false, $name)
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            throw 'C1b 相同 canonical trust tuple 已由另一进程持有。'
        }
        [void]$script:TL1C1bBuildEnvironmentActiveMutexNames.Add($name)
        return [pscustomobject][ordered]@{
            Name = $name
            TrustTupleSha256 = $tupleSha256
            Mutex = $mutex
            Acquired = $true
            Disposed = $false
        }
    } catch {
        if ($acquired) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
        throw
    }
}

function Assert-TL1C1bBuildEnvironmentConcurrencyGuardHeld {
    param([Parameter(Mandatory)]$ConcurrencyGuard)

    if (-not [bool]$ConcurrencyGuard.Acquired -or
        [bool]$ConcurrencyGuard.Disposed -or
        $ConcurrencyGuard.Mutex.SafeWaitHandle.IsClosed -or
        -not $script:TL1C1bBuildEnvironmentActiveMutexNames.Contains(
            [string]$ConcurrencyGuard.Name)) {
        throw 'C1b canonical trust tuple mutex 未持有。'
    }
}

function Close-TL1C1bBuildEnvironmentConcurrencyGuard {
    param([AllowNull()]$ConcurrencyGuard)

    if ($null -eq $ConcurrencyGuard -or [bool]$ConcurrencyGuard.Disposed) { return }
    if ([bool]$ConcurrencyGuard.Acquired) {
        $ConcurrencyGuard.Mutex.ReleaseMutex()
        $ConcurrencyGuard.Acquired = $false
    }
    $ConcurrencyGuard.Mutex.Dispose()
    $ConcurrencyGuard.Disposed = $true
    [void]$script:TL1C1bBuildEnvironmentActiveMutexNames.Remove(
        [string]$ConcurrencyGuard.Name)
}

function New-TL1C1bBuildEnvironmentChildEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)

    $systemRoot = [string]$TrustGuard.HostPaths.SystemRoot
    $systemDirectory = [string]$TrustGuard.HostPaths.SystemDirectory
    $javaBin = Join-Path $TrustGuard.JavaHome 'bin'
    return @{
        JAVA_HOME = [string]$TrustGuard.JavaHome
        ANDROID_SDK_ROOT = [string]$TrustGuard.IsolatedAndroidSdk.Root
        ANDROID_HOME = [string]$TrustGuard.IsolatedAndroidSdk.Root
        ANDROID_USER_HOME = Join-Path $TrustGuard.Workspace.UserHomeDirectory '.android'
        GRADLE_USER_HOME = [string]$TrustGuard.Workspace.Root
        KOTLIN_DAEMON_RUN_FILES_PATH = [string]$TrustGuard.Workspace.KotlinRuntimeDirectory
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = 'NUL'
        GIT_OPTIONAL_LOCKS = '0'
        GIT_TERMINAL_PROMPT = '0'
        COMSPEC = [string]$TrustGuard.HostPaths.CmdPath
        PATH = $systemDirectory + [IO.Path]::PathSeparator + $javaBin
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        TEMP = [string]$TrustGuard.Workspace.ProcessTempDirectory
        TMP = [string]$TrustGuard.Workspace.ProcessTempDirectory
        TMPDIR = [string]$TrustGuard.Workspace.ProcessTempDirectory
        USERPROFILE = [string]$TrustGuard.Workspace.UserHomeDirectory
        HOME = [string]$TrustGuard.Workspace.UserHomeDirectory
        TL1_C1B_BUILD_OUTPUT_ROOT =
            [string]$TrustGuard.ModuleBuildOutputDirectory
        SystemRoot = $systemRoot
        windir = $systemRoot
    }
}

function New-TL1C1bBuildEnvironmentGitEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)

    $gitCmd = [IO.Path]::GetFullPath((Join-Path $TrustGuard.GitRoot 'cmd'))
    $gitMingwBin = [IO.Path]::GetFullPath((Join-Path $TrustGuard.GitRoot 'mingw64\bin'))
    return @{
        SYSTEMROOT = [string]$TrustGuard.HostPaths.SystemRoot
        WINDIR = [string]$TrustGuard.HostPaths.SystemRoot
        COMSPEC = [string]$TrustGuard.HostPaths.CmdPath
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        PATH = $gitCmd + [IO.Path]::PathSeparator + $gitMingwBin +
            [IO.Path]::PathSeparator + [string]$TrustGuard.HostPaths.SystemDirectory
        TEMP = [string]$TrustGuard.Workspace.ProcessTempDirectory
        TMP = [string]$TrustGuard.Workspace.ProcessTempDirectory
        USERPROFILE = [string]$TrustGuard.Workspace.UserHomeDirectory
        HOME = [string]$TrustGuard.Workspace.UserHomeDirectory
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = 'NUL'
        GIT_CONFIG_COUNT = '0'
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE = 'Never'
        GIT_OPTIONAL_LOCKS = '0'
    }
}

function Get-TL1C1bBuildEnvironmentHostPaths {
    $systemDirectory = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([Environment]::SystemDirectory) 'Windows SystemDirectory trust root'
    $systemRoot = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($systemDirectory)) 'Windows system root'
    $cmdPath = [IO.Path]::GetFullPath((Join-Path $systemDirectory 'cmd.exe'))
    $item = Get-Item -LiteralPath $cmdPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetFullPath($item.FullName)) $cmdPath)) {
        throw 'C1b Windows System32 cmd.exe 必须是 OS loader trust root 下 ordinary file。'
    }
    return [pscustomobject][ordered]@{
        SystemRoot = $systemRoot
        SystemDirectory = $systemDirectory
        CmdPath = $cmdPath
    }
}

function Assert-TL1C1bBuildEnvironmentHostPathsUnchanged {
    param([Parameter(Mandatory)]$Expected)

    $current = Get-TL1C1bBuildEnvironmentHostPaths
    foreach ($name in @('SystemRoot', 'SystemDirectory', 'CmdPath')) {
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([string]$Expected.$name) ([string]$current.$name))) {
            throw "C1b Windows host trust path/$name 漂移。"
        }
    }
    return $current
}

function Get-TL1C1bBuildEnvironmentWrapperInvocation {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    throw 'C1b 禁止执行 GradleWrapperMain；distribution 必须先冻结并直调 GradleMain。'
}

function Get-TL1C1bBuildEnvironmentGradleInvocation {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    $java = Get-TL1C1bBuildEnvironmentEntry $TrustGuard.JdkTreeGuard 'bin/java.exe'
    $cliMain = Get-TL1C1bBuildEnvironmentEntry `
        $TrustGuard.GradleTreeGuard 'lib/gradle-gradle-cli-main-8.9.jar'
    $agent = Get-TL1C1bBuildEnvironmentEntry `
        $TrustGuard.GradleTreeGuard `
        'lib/agents/gradle-instrumentation-agent-8.9.jar'
    return [pscustomobject][ordered]@{
        FilePath = [string]$java.Path
        Arguments = [string[]]@(
            '-Xmx64m'
            '-Xms64m'
            ('-javaagent:' + [string]$agent.Path)
            '-Dorg.gradle.appname=gradle'
            ('-Djava.io.tmpdir=' + [string]$TrustGuard.Workspace.ProcessTempDirectory)
            ('-Duser.home=' + [string]$TrustGuard.Workspace.UserHomeDirectory)
            '-classpath'
            [string]$cliMain.Path
            'org.gradle.launcher.GradleMain'
        )
    }
}

function Get-TL1C1bBuildEnvironmentApkSignerInvocation {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    $java = Get-TL1C1bBuildEnvironmentEntry $TrustGuard.JdkTreeGuard 'bin/java.exe'
    $apksigner = Get-TL1C1bBuildEnvironmentEntry `
        $TrustGuard.IsolatedAndroidSdk.TreeGuard `
        'build-tools/35.0.0/lib/apksigner.jar'
    return [pscustomobject][ordered]@{
        FilePath = [string]$java.Path
        Arguments = [string[]]@(
            '-Xmx64m'
            '-Xms64m'
            ('-Djava.io.tmpdir=' + [string]$TrustGuard.Workspace.ProcessTempDirectory)
            ('-Duser.home=' + [string]$TrustGuard.Workspace.UserHomeDirectory)
            '-jar'
            [string]$apksigner.Path
        )
    }
}

function Get-TL1C1bBuildEnvironmentGradleArguments {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged $TrustGuard)
    return [string[]]@(
        '--project-cache-dir'
        [string]$TrustGuard.Workspace.ProjectCacheDirectory
        '-PtabletC1bIsolatedBuild=true'
        '-Pkotlin.incremental=false'
        '-Pkotlin.compiler.execution.strategy=in-process'
    )
}

function Get-TL1C1bBuildEnvironmentGitBaseArguments {
    return [string[]]@(
        '-c'
        'core.fsmonitor=false'
        '-c'
        'core.untrackedCache=false'
        '-c'
        'core.hooksPath=NUL'
        '--no-optional-locks'
    )
}

function Compare-TL1C1bBuildEnvironmentJdkBinding {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($name in @(
        'vendor', 'version', 'archive_sha256', 'file_count', 'catalog_sha256',
        'java_sha256', 'jvm_sha256', 'release_sha256', 'modules_sha256',
        'signature_status', 'signature_subject', 'signature_certificate_sha256'
        'tree_files_deny_write_delete', 'tree_directories_acl_protected'
    )) {
        if ([string]$Expected.$name -cne [string]$Actual.$name) {
            throw "C1b JDK trust binding/$name 前后漂移。"
        }
    }
}

function Open-TL1C1bBuildEnvironmentTrustGuardCore {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$JavaHome,
        [Parameter(Mandatory)][string]$GradleHome,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$GitPath,
        [Parameter(Mandatory)][string]$GradleUserHomeParent,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string[]]$RepositoryInputPaths,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string[]]$RepositoryInputDirectories,
        [Parameter(Mandatory)][ValidateRange(1, 4096)][int]$ExpectedJdkFileCount,
        [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedJdkCatalogSha256,
        [Parameter(Mandatory)][Collections.IDictionary]$ExpectedJdkKeyFiles,
        [ValidateRange(1, 4096)][int]$ExpectedGradleFileCount =
            $script:TL1C1bBuildEnvironmentGradleFileCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedGradleCatalogSha256 =
            $script:TL1C1bBuildEnvironmentGradleCatalogSha256,
        [ValidateRange(1, 20000)][int]$ExpectedAndroidBuildToolsFileCount =
            $script:TL1C1bBuildEnvironmentAndroidBuildToolsFileCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedAndroidBuildToolsCatalogSha256 =
            $script:TL1C1bBuildEnvironmentAndroidBuildToolsCatalogSha256,
        [Collections.IDictionary]$ExpectedAndroidBuildToolsKeyFiles =
            $script:TL1C1bBuildEnvironmentAndroidBuildToolsKeyFiles,
        [ValidateRange(1, 20000)][int]$ExpectedAndroidPlatformFileCount =
            $script:TL1C1bBuildEnvironmentAndroidPlatformFileCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedAndroidPlatformCatalogSha256 =
            $script:TL1C1bBuildEnvironmentAndroidPlatformCatalogSha256,
        [Collections.IDictionary]$ExpectedAndroidPlatformKeyFiles =
            $script:TL1C1bBuildEnvironmentAndroidPlatformKeyFiles,
        [ValidateRange(1, 20000)][int]$ExpectedAndroidPlatformToolsFileCount =
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsFileCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedAndroidPlatformToolsCatalogSha256 =
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsCatalogSha256,
        [Collections.IDictionary]$ExpectedAndroidPlatformToolsKeyFiles =
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsKeyFiles,
        [ValidateRange(1, 20000)][int]$ExpectedIsolatedAndroidSdkFileCount =
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkFileCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedIsolatedAndroidSdkCatalogSha256 =
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkCatalogSha256,
        [ValidateRange(1, 20000)][int]$ExpectedGitFileCount =
            $script:TL1C1bBuildEnvironmentGitFileCount,
        [ValidateRange(1, 20000)][int]$ExpectedGitIdentityCount =
            $script:TL1C1bBuildEnvironmentGitIdentityCount,
        [ValidateRange(1, 20000)][int]$ExpectedGitInternalHardlinkGroupCount =
            $script:TL1C1bBuildEnvironmentGitInternalHardlinkGroupCount,
        [ValidatePattern('^sha256:[0-9a-f]{64}$')]
        [string]$ExpectedGitCatalogSha256 =
            $script:TL1C1bBuildEnvironmentGitCatalogSha256,
        [Collections.IDictionary]$ExpectedGitKeyFiles =
            $script:TL1C1bBuildEnvironmentGitKeyFiles,
        [scriptblock]$TestOnlySignatureReader,
        [scriptblock]$TestOnlyGitSignatureReader,
        [string]$TestOnlyExpectedGitRoot,
        [string]$TestOnlyDebugKeystorePath,
        [switch]$TestOnlySynthetic
    )

    if (-not $TestOnlySynthetic -and (
        $ExpectedJdkFileCount -ne $script:TL1C1bBuildEnvironmentJdkFileCount -or
        $ExpectedJdkCatalogSha256 -cne $script:TL1C1bBuildEnvironmentJdkCatalogSha256 -or
        $ExpectedGradleFileCount -ne $script:TL1C1bBuildEnvironmentGradleFileCount -or
        $ExpectedGradleCatalogSha256 -cne $script:TL1C1bBuildEnvironmentGradleCatalogSha256 -or
        $ExpectedAndroidBuildToolsFileCount -ne `
            $script:TL1C1bBuildEnvironmentAndroidBuildToolsFileCount -or
        $ExpectedAndroidBuildToolsCatalogSha256 -cne `
            $script:TL1C1bBuildEnvironmentAndroidBuildToolsCatalogSha256 -or
        $ExpectedAndroidPlatformFileCount -ne `
            $script:TL1C1bBuildEnvironmentAndroidPlatformFileCount -or
        $ExpectedAndroidPlatformCatalogSha256 -cne `
            $script:TL1C1bBuildEnvironmentAndroidPlatformCatalogSha256 -or
        $ExpectedAndroidPlatformToolsFileCount -ne `
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsFileCount -or
        $ExpectedAndroidPlatformToolsCatalogSha256 -cne `
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsCatalogSha256 -or
        $ExpectedIsolatedAndroidSdkFileCount -ne `
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkFileCount -or
        $ExpectedIsolatedAndroidSdkCatalogSha256 -cne `
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkCatalogSha256 -or
        $ExpectedGitFileCount -ne $script:TL1C1bBuildEnvironmentGitFileCount -or
        $ExpectedGitIdentityCount -ne $script:TL1C1bBuildEnvironmentGitIdentityCount -or
        $ExpectedGitInternalHardlinkGroupCount -ne `
            $script:TL1C1bBuildEnvironmentGitInternalHardlinkGroupCount -or
        $ExpectedGitCatalogSha256 -cne `
            $script:TL1C1bBuildEnvironmentGitCatalogSha256 -or
        $ExpectedGitKeyFiles -ne $script:TL1C1bBuildEnvironmentGitKeyFiles -or
        $null -ne $TestOnlySignatureReader -or $null -ne $TestOnlyGitSignatureReader -or
        -not [string]::IsNullOrWhiteSpace($TestOnlyExpectedGitRoot) -or
        -not [string]::IsNullOrWhiteSpace($TestOnlyDebugKeystorePath))) {
        throw 'C1b production build-environment core 不接受 synthetic trust expectations。'
    }
    Assert-TL1C1bBuildEnvironmentVariablesClean
    $hostPaths = Get-TL1C1bBuildEnvironmentHostPaths
    $repo = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $RepoRoot 'RepoRoot'
    $java = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory $JavaHome 'JAVA_HOME'
    $gradle = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $GradleHome 'trusted Gradle 8.9 home'
    $androidSdk = Assert-TL1C1bBuildEnvironmentAndroidRoots $AndroidSdkRoot
    $gradleParent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $GradleUserHomeParent 'GRADLE_USER_HOME parent'
    $gitRoot = Resolve-TL1C1bBuildEnvironmentGitRoot `
        -GitPath $GitPath `
        -TestOnlyExpectedGitRoot $TestOnlyExpectedGitRoot `
        -TestOnlySynthetic:$TestOnlySynthetic
    $debugKeystorePath = if ($TestOnlySynthetic -and
        -not [string]::IsNullOrWhiteSpace($TestOnlyDebugKeystorePath)) {
        [IO.Path]::GetFullPath($TestOnlyDebugKeystorePath)
    } else {
        [IO.Path]::GetFullPath((Join-Path `
            ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) `
            '.android\debug.keystore'))
    }
    $debugKeystoreParent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        ([IO.Path]::GetDirectoryName($debugKeystorePath)) `
        'canonical debug.keystore parent'
    $pathChainTargets = [Collections.Generic.List[string]]::new()
    foreach ($path in @(
        $repo, $java, $gradle, $androidSdk, $gitRoot, $gradleParent,
        $hostPaths.SystemRoot, $hostPaths.SystemDirectory, $debugKeystoreParent
    )) { $pathChainTargets.Add([string]$path) }
    foreach ($relative in $RepositoryInputPaths) {
        $inputPath = Resolve-TL1C1bBuildEnvironmentRepoRelativePath `
            $repo $relative 'repository path-chain input'
        $pathChainTargets.Add([IO.Path]::GetDirectoryName($inputPath))
    }
    foreach ($relative in $RepositoryInputDirectories) {
        $pathChainTargets.Add((Resolve-TL1C1bBuildEnvironmentRepoRelativePath `
            $repo $relative 'repository path-chain directory' -Directory))
    }
    $concurrencyGuard = Open-TL1C1bBuildEnvironmentConcurrencyGuard @(
        $repo, $java, $gradle, $androidSdk, $gitRoot,
        $gradleParent, $debugKeystorePath)
    $pathChainGuard = $null
    try {
        $pathChainGuard = Open-TL1C1bBuildEnvironmentPathChainGuard `
            $pathChainTargets.ToArray()
    } catch {
        Close-TL1C1bBuildEnvironmentConcurrencyGuard $concurrencyGuard
        throw
    }
    $recoveryJournal = $null
    $repoInputGuard = $null
    $moduleBuildOutputGuard = $null
    $repositoryFileSetGuard = $null
    $repositoryDirectoryAclGuards = $null
    $androidBuildToolsTree = $null
    $androidPlatformTree = $null
    $androidPlatformToolsTree = $null
    $isolatedAndroidSdk = $null
    $debugKeystoreGuard = $null
    $jdkTree = $null
    $jdkAclGuards = $null
    $gradleTree = $null
    $gradleAclGuards = $null
    $gitTree = $null
    $gitAclGuards = $null
    $workspace = $null
    try {
        $recoveryJournal = New-TL1C1bBuildEnvironmentRecoveryJournal `
            $gradleParent @($repo, $java, $gradle, $gitRoot, $gradleParent)
        $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $recoveryJournal
        $repoInputGuard = Open-TL1C1bBuildEnvironmentRepoInputGuard $repo
        $moduleBuildOutputGuard =
            New-TL1C1bBuildEnvironmentModuleBuildOutputGuard $repo
        $repositoryFileSetGuard = Open-TL1C1bBuildEnvironmentFileSetGuard `
            $repo $RepositoryInputPaths 'repository build inputs'
        $repositoryDirectoryAclGuards = Protect-TL1C1bBuildEnvironmentRepoDirectories `
            $repo $RepositoryInputDirectories 'repository source/resource roots'
        $gradleTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            $gradle $ExpectedGradleFileCount $ExpectedGradleCatalogSha256 `
            'Gradle 8.9 bin distribution'
        $gradleCliMain = Get-TL1C1bBuildEnvironmentEntry `
            $gradleTree 'lib/gradle-gradle-cli-main-8.9.jar'
        $gradleAgent = Get-TL1C1bBuildEnvironmentEntry `
            $gradleTree 'lib/agents/gradle-instrumentation-agent-8.9.jar'
        if (-not $TestOnlySynthetic -and (
            [string]$gradleCliMain.Sha256 -cne `
                $script:TL1C1bBuildEnvironmentGradleCliMainSha256 -or
            [string]$gradleAgent.Sha256 -cne `
                $script:TL1C1bBuildEnvironmentGradleInstrumentationAgentSha256)) {
            throw 'C1b GradleMain/instrumentation agent key hash 漂移。'
        }
        $gradleAclGuards = Protect-TL1C1bBuildEnvironmentTreeDirectories $gradleTree
        $gradleBinding = [pscustomobject][ordered]@{
            version = $script:TL1C1bBuildEnvironmentGradleVersion
            distribution = $script:TL1C1bBuildEnvironmentGradleDistribution
            file_count = $ExpectedGradleFileCount
            catalog_sha256 = $ExpectedGradleCatalogSha256
            wrapper_not_executed = $true
            entrypoint = 'org.gradle.launcher.GradleMain'
            cli_main_jar = 'lib/gradle-gradle-cli-main-8.9.jar'
            cli_main_jar_sha256 = [string]$gradleCliMain.Sha256
            instrumentation_agent_sha256 = [string]$gradleAgent.Sha256
            tree_files_deny_write_delete = $true
            tree_directories_acl_protected = $true
            init_d_acl_protected = $true
        }
        $androidBuildToolsTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            (Join-Path $androidSdk 'build-tools\35.0.0') `
            $ExpectedAndroidBuildToolsFileCount `
            $ExpectedAndroidBuildToolsCatalogSha256 `
            'Android build-tools 35.0.0'
        $androidPlatformTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            (Join-Path $androidSdk 'platforms\android-35') `
            $ExpectedAndroidPlatformFileCount `
            $ExpectedAndroidPlatformCatalogSha256 `
            'Android platform android-35'
        $androidPlatformToolsTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            (Join-Path $androidSdk 'platform-tools') `
            $ExpectedAndroidPlatformToolsFileCount `
            $ExpectedAndroidPlatformToolsCatalogSha256 `
            'Android platform-tools'
        $workspace = New-TL1C1bBuildEnvironmentWorkspace $gradleParent $repo
        $debugKeystoreGuard = New-TL1C1bBuildEnvironmentDebugKeystoreGuard `
            $debugKeystorePath $workspace
        $isolatedAndroidSdk = New-TL1C1bBuildEnvironmentIsolatedAndroidSdk `
            $workspace $androidBuildToolsTree $androidPlatformTree `
            $androidPlatformToolsTree $ExpectedIsolatedAndroidSdkFileCount `
            $ExpectedIsolatedAndroidSdkCatalogSha256
        $androidBinding = Get-TL1C1bBuildEnvironmentAndroidSdkBinding `
            $androidBuildToolsTree $androidPlatformTree $androidPlatformToolsTree `
            $isolatedAndroidSdk.TreeGuard $ExpectedAndroidBuildToolsKeyFiles `
            $ExpectedAndroidPlatformKeyFiles $ExpectedAndroidPlatformToolsKeyFiles
        $jdkTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            $java $ExpectedJdkFileCount $ExpectedJdkCatalogSha256 'Oracle JDK 21.0.5'
        $jdkAclGuards = Protect-TL1C1bBuildEnvironmentTreeDirectories $jdkTree
        $jdkBinding = Get-TL1C1bBuildEnvironmentJdkBinding `
            $jdkTree $ExpectedJdkKeyFiles $TestOnlySignatureReader
        $gitTree = Open-TL1C1bBuildEnvironmentTreeGuard `
            -Root $gitRoot `
            -ExpectedFileCount $ExpectedGitFileCount `
            -ExpectedCatalogSha256 $ExpectedGitCatalogSha256 `
            -Name 'Git for Windows 2.55.0.windows.3 installation' `
            -AllowInternalHardlinks `
            -ExpectedIdentityCount $ExpectedGitIdentityCount `
            -ExpectedInternalHardlinkGroupCount $ExpectedGitInternalHardlinkGroupCount
        $gitAclGuards = Protect-TL1C1bBuildEnvironmentTreeDirectories $gitTree
        $gitBinding = Get-TL1C1bBuildEnvironmentGitBinding `
            $gitTree $ExpectedGitKeyFiles $TestOnlyGitSignatureReader
        $trustGuard = [pscustomobject][ordered]@{
            Schema = $script:TL1C1bBuildEnvironmentTrustSchema
            ThreatBoundary = $script:TL1C1bBuildEnvironmentThreatBoundary
            HostPaths = $hostPaths
            ConcurrencyGuard = $concurrencyGuard
            PathChainGuard = $pathChainGuard
            RecoveryJournal = $recoveryJournal
            RepoRoot = $repo
            RepoInputGuard = $repoInputGuard
            ModuleBuildOutputGuard = $moduleBuildOutputGuard
            ModuleBuildOutputDirectory = $moduleBuildOutputGuard.Directory
            RepositoryFileSetGuard = $repositoryFileSetGuard
            RepositoryDirectoryAclGuards = $repositoryDirectoryAclGuards
            JavaHome = $java
            GradleRoot = $gradle
            AndroidSdkSourceRoot = $androidSdk
            AndroidSdkRoot = $isolatedAndroidSdk.Root
            AndroidBuildToolsTreeGuard = $androidBuildToolsTree
            AndroidPlatformTreeGuard = $androidPlatformTree
            AndroidPlatformToolsTreeGuard = $androidPlatformToolsTree
            IsolatedAndroidSdk = $isolatedAndroidSdk
            AndroidSdkBinding = $androidBinding
            ExpectedAndroidBuildToolsKeyFiles = $ExpectedAndroidBuildToolsKeyFiles
            ExpectedAndroidPlatformKeyFiles = $ExpectedAndroidPlatformKeyFiles
            ExpectedAndroidPlatformToolsKeyFiles = $ExpectedAndroidPlatformToolsKeyFiles
            JdkTreeGuard = $jdkTree
            JdkDirectoryAclGuards = $jdkAclGuards
            JdkBinding = $jdkBinding
            ExpectedJdkKeyFiles = $ExpectedJdkKeyFiles
            ExpectedGradleFileCount = $ExpectedGradleFileCount
            ExpectedGradleCatalogSha256 = $ExpectedGradleCatalogSha256
            TestOnlySignatureReader = $TestOnlySignatureReader
            GitRoot = $gitRoot
            GitPath = [IO.Path]::GetFullPath($GitPath)
            GitTreeGuard = $gitTree
            GitDirectoryAclGuards = $gitAclGuards
            GitBinding = $gitBinding
            ExpectedGitKeyFiles = $ExpectedGitKeyFiles
            TestOnlyGitSignatureReader = $TestOnlyGitSignatureReader
            TestOnlySynthetic = [bool]$TestOnlySynthetic
            Workspace = $workspace
            DebugKeystoreGuard = $debugKeystoreGuard
            DebugKeystoreGuardAnchor = $debugKeystoreGuard
            DebugKeystoreUserHomeDirectory =
                [IO.Path]::GetFullPath($workspace.UserHomeDirectory)
            GradleTreeGuard = $gradleTree
            GradleDirectoryAclGuards = $gradleAclGuards
            GradleBinding = $gradleBinding
            Disposed = $false
        }
        [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged $trustGuard)
        return $trustGuard
    } catch {
        if ($null -ne $gradleAclGuards) {
            try { Restore-TL1C1bBuildEnvironmentTreeDirectories $gradleAclGuards }
            catch { }
        }
        Close-TL1C1bBuildEnvironmentTreeGuard $gradleTree
        if ($null -ne $gitAclGuards) {
            try { Restore-TL1C1bBuildEnvironmentTreeDirectories $gitAclGuards }
            catch { }
        }
        Close-TL1C1bBuildEnvironmentTreeGuard $gitTree
        if ($null -ne $jdkAclGuards) {
            try { Restore-TL1C1bBuildEnvironmentTreeDirectories $jdkAclGuards }
            catch { }
        }
        Close-TL1C1bBuildEnvironmentTreeGuard $jdkTree
        if ($null -ne $isolatedAndroidSdk) {
            try {
                Restore-TL1C1bBuildEnvironmentTreeDirectories `
                    $isolatedAndroidSdk.DirectoryAclGuards
            } catch { }
            Close-TL1C1bBuildEnvironmentTreeGuard $isolatedAndroidSdk.TreeGuard
        }
        if ($null -ne $debugKeystoreGuard) {
            try { Close-TL1C1bBuildEnvironmentDebugKeystoreGuard $debugKeystoreGuard }
            catch { }
        }
        if ($null -ne $workspace) {
            foreach ($aclGuard in @(
                $workspace.RootAclGuard,
                $workspace.ProcessTempAclGuard,
                $workspace.KotlinRuntimeAclGuard,
                $workspace.ProjectCacheAclGuard
            )) {
                try { Restore-TL1C1bBuildEnvironmentDirectory $aclGuard } catch { }
            }
            foreach ($guard in @(
                $workspace.InitGradleGuard,
                $workspace.InitGradleKtsGuard,
                $workspace.InitDDirectoryBlockerGuard
            )) { $guard.Stream.Dispose() }
        }
        Close-TL1C1bBuildEnvironmentTreeGuard $androidPlatformTree
        Close-TL1C1bBuildEnvironmentTreeGuard $androidPlatformToolsTree
        Close-TL1C1bBuildEnvironmentTreeGuard $androidBuildToolsTree
        if ($null -ne $repositoryDirectoryAclGuards) {
            try {
                Restore-TL1C1bBuildEnvironmentTreeDirectories `
                    $repositoryDirectoryAclGuards
            } catch { }
        }
        Close-TL1C1bBuildEnvironmentFileSetGuard $repositoryFileSetGuard
        try {
            Restore-TL1C1bBuildEnvironmentModuleBuildOutputGuard `
                $moduleBuildOutputGuard
        } catch { }
        try { Close-TL1C1bBuildEnvironmentRepoInputGuard $repoInputGuard }
        catch { }
        try { Remove-TL1C1bBuildEnvironmentRecoveryJournal $recoveryJournal }
        catch { }
        if ($null -eq $recoveryJournal -or [bool]$recoveryJournal.Removed) {
            try {
                Remove-TL1C1bBuildEnvironmentModuleBuildOutputGuard `
                    $moduleBuildOutputGuard
            } catch { }
        }
        if ($script:TL1C1bBuildEnvironmentActiveRecoveryJournal -eq $recoveryJournal) {
            $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $null
        }
        if ($null -ne $workspace -and
            ($null -eq $recoveryJournal -or [bool]$recoveryJournal.Removed) -and
            (Test-Path -LiteralPath $workspace.Root -PathType Container)) {
            Remove-Item -LiteralPath $workspace.Root -Recurse -Force
        }
        Close-TL1C1bBuildEnvironmentPathChainGuard $pathChainGuard
        Close-TL1C1bBuildEnvironmentConcurrencyGuard $concurrencyGuard
        throw
    }
}

function Open-TL1C1bBuildEnvironmentTrustGuard {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$JavaHome,
        [Parameter(Mandatory)][string]$GradleHome,
        [Parameter(Mandatory)][string]$AndroidSdkRoot,
        [Parameter(Mandatory)][string]$GitPath,
        [Parameter(Mandatory)][string]$GradleUserHomeParent,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string[]]$RepositoryInputPaths,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string[]]$RepositoryInputDirectories
    )

    return Open-TL1C1bBuildEnvironmentTrustGuardCore `
        -RepoRoot $RepoRoot `
        -JavaHome $JavaHome `
        -GradleHome $GradleHome `
        -AndroidSdkRoot $AndroidSdkRoot `
        -GitPath $GitPath `
        -GradleUserHomeParent $GradleUserHomeParent `
        -RepositoryInputPaths $RepositoryInputPaths `
        -RepositoryInputDirectories $RepositoryInputDirectories `
        -ExpectedJdkFileCount $script:TL1C1bBuildEnvironmentJdkFileCount `
        -ExpectedJdkCatalogSha256 $script:TL1C1bBuildEnvironmentJdkCatalogSha256 `
        -ExpectedJdkKeyFiles $script:TL1C1bBuildEnvironmentJdkKeyFiles `
        -ExpectedGitFileCount $script:TL1C1bBuildEnvironmentGitFileCount `
        -ExpectedGitIdentityCount $script:TL1C1bBuildEnvironmentGitIdentityCount `
        -ExpectedGitInternalHardlinkGroupCount `
            $script:TL1C1bBuildEnvironmentGitInternalHardlinkGroupCount `
        -ExpectedGitCatalogSha256 $script:TL1C1bBuildEnvironmentGitCatalogSha256 `
        -ExpectedGitKeyFiles $script:TL1C1bBuildEnvironmentGitKeyFiles
}

function Get-TL1C1bBuildEnvironmentBootstrapEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged $TrustGuard)
    return New-TL1C1bBuildEnvironmentChildEnvironment $TrustGuard
}

function Find-TL1C1bBuildEnvironmentGradleRoot {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    return [string]$TrustGuard.GradleRoot
}

function Complete-TL1C1bBuildEnvironmentBootstrap {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [string]$GradleRoot
    )

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    $discovered = [string]$TrustGuard.GradleRoot
    if (-not [string]::IsNullOrWhiteSpace($GradleRoot)) {
        $explicit = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
            $GradleRoot 'explicit Gradle root'
        if (-not (Test-TL1C1bBuildEnvironmentPathEqual $discovered $explicit)) {
            throw 'C1b explicit/discovered Gradle root 不一致。'
        }
    }
    return Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle
}

function Get-TL1C1bBuildEnvironmentBuildEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    return New-TL1C1bBuildEnvironmentChildEnvironment $TrustGuard
}

function Get-TL1C1bBuildEnvironmentGitEnvironment {
    param([Parameter(Mandatory)]$TrustGuard)

    [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle)
    return New-TL1C1bBuildEnvironmentGitEnvironment $TrustGuard
}

function Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [switch]$RequireGradle
    )

    if ([bool]$TrustGuard.Disposed) {
        throw 'C1b build-environment trust guard 已关闭。'
    }
    Assert-TL1C1bBuildEnvironmentVariablesClean
    Assert-TL1C1bBuildEnvironmentConcurrencyGuardHeld $TrustGuard.ConcurrencyGuard
    [void](Assert-TL1C1bBuildEnvironmentHostPathsUnchanged $TrustGuard.HostPaths)
    Assert-TL1C1bBuildEnvironmentPathChainGuardUnchanged `
        $TrustGuard.PathChainGuard
    $recoveryJournal = Get-TL1C1bBuildEnvironmentRecoveryJournalBinding `
        $TrustGuard.RecoveryJournal
    Assert-TL1C1bBuildEnvironmentRepoInputGuardUnchanged `
        $TrustGuard.RepoInputGuard
    Assert-TL1C1bBuildEnvironmentModuleBuildOutputGuardUnchanged `
        $TrustGuard.ModuleBuildOutputGuard
    $repositoryInputs = Assert-TL1C1bBuildEnvironmentFileSetGuardUnchanged `
        $TrustGuard.RepositoryFileSetGuard
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $TrustGuard.RepositoryDirectoryAclGuards
    $java = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $TrustGuard.JavaHome 'JAVA_HOME'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $java $TrustGuard.JavaHome)) {
        throw 'C1b JAVA_HOME canonical path 漂移。'
    }
    $jdk = Get-TL1C1bBuildEnvironmentJdkBinding `
        $TrustGuard.JdkTreeGuard `
        $TrustGuard.ExpectedJdkKeyFiles `
        $TrustGuard.TestOnlySignatureReader
    Compare-TL1C1bBuildEnvironmentJdkBinding $TrustGuard.JdkBinding $jdk
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $TrustGuard.JdkDirectoryAclGuards
    $gitRoot = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $TrustGuard.GitRoot 'Git for Windows root'
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $gitRoot $TrustGuard.GitRoot) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            $TrustGuard.GitPath (Join-Path $gitRoot 'cmd\git.exe'))) {
        throw 'C1b Git for Windows canonical root/path 漂移。'
    }
    $git = Get-TL1C1bBuildEnvironmentGitBinding `
        $TrustGuard.GitTreeGuard `
        $TrustGuard.ExpectedGitKeyFiles `
        $TrustGuard.TestOnlyGitSignatureReader
    Compare-TL1C1bBuildEnvironmentGitBinding $TrustGuard.GitBinding $git
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $TrustGuard.GitDirectoryAclGuards
    $androidSdk = Assert-TL1C1bBuildEnvironmentAndroidRoots `
        $TrustGuard.AndroidSdkSourceRoot
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual `
        $androidSdk $TrustGuard.AndroidSdkSourceRoot)) {
        throw 'C1b source AndroidSdkRoot canonical path 漂移。'
    }
    $android = Get-TL1C1bBuildEnvironmentAndroidSdkBinding `
        $TrustGuard.AndroidBuildToolsTreeGuard $TrustGuard.AndroidPlatformTreeGuard `
        $TrustGuard.AndroidPlatformToolsTreeGuard `
        $TrustGuard.IsolatedAndroidSdk.TreeGuard `
        $TrustGuard.ExpectedAndroidBuildToolsKeyFiles `
        $TrustGuard.ExpectedAndroidPlatformKeyFiles `
        $TrustGuard.ExpectedAndroidPlatformToolsKeyFiles
    Compare-TL1C1bBuildEnvironmentAndroidSdkBinding `
        $TrustGuard.AndroidSdkBinding $android
    Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
        $TrustGuard.IsolatedAndroidSdk.DirectoryAclGuards
    Assert-TL1C1bBuildEnvironmentWorkspaceUnchanged $TrustGuard.Workspace
    $debugKeystoreGuard =
        Assert-TL1C1bBuildEnvironmentDebugKeystoreTrustBinding $TrustGuard
    $debugKeystore =
        Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged `
            $debugKeystoreGuard
    if ($RequireGradle -and $null -eq $TrustGuard.GradleTreeGuard) {
        throw 'C1b Gradle 8.9 distribution 尚未完成冻结。'
    }
    if ($null -ne $TrustGuard.GradleTreeGuard) {
        $gradle = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged `
            $TrustGuard.GradleTreeGuard
        if ([int]$gradle.file_count -ne [int]$TrustGuard.GradleBinding.file_count -or
            [string]$gradle.catalog_sha256 -cne `
                [string]$TrustGuard.GradleBinding.catalog_sha256) {
            throw 'C1b Gradle trust binding 前后漂移。'
        }
        Assert-TL1C1bBuildEnvironmentTreeDirectoriesProtected `
            $TrustGuard.GradleDirectoryAclGuards
    }
    return [pscustomobject][ordered]@{
        schema = $script:TL1C1bBuildEnvironmentTrustSchema
        platform = 'windows'
        threat_boundary = $script:TL1C1bBuildEnvironmentThreatBoundary
        java_home_explicit = $true
        gradle_home_explicit = $true
        gradle_user_home_fresh = $true
        project_cache_fresh = $true
        kotlin_runtime_fresh = $true
        module_build_output_fresh = $true
        inherited_injection_variables_absent = $true
        repo_local_properties_empty_guarded = $true
        repo_implicit_build_logic_absent = $true
        path_chain_directories_deny_rename = $true
        concurrency_guard = [pscustomobject][ordered]@{
            scope = 'windows-logon-session-all-c1b-builds'
            canonical_trust_tuple_sha256 =
                [string]$TrustGuard.ConcurrencyGuard.TrustTupleSha256
            named_mutex_held = $true
        }
        recovery_journal = $recoveryJournal
        debug_keystore = $debugKeystore
        host_process = [pscustomobject][ordered]@{
            windows_system_directory_api_trust_root = $true
            host_launcher_cmd_not_executed = $true
            runner_direct_launcher_is_java = $true
            comspec_is_os_trust_root = $true
            wrapper_not_executed = $true
            gradle_entrypoint = 'org.gradle.launcher.GradleMain'
            minimal_path = $true
            fresh_process_temp = $true
        }
        repository_inputs = [pscustomobject][ordered]@{
            file_count = $repositoryInputs.file_count
            catalog_sha256 = $repositoryInputs.catalog_sha256
            directory_root_count = $TrustGuard.RepositoryDirectoryAclGuards.RootCount
            protected_directory_count =
                $TrustGuard.RepositoryDirectoryAclGuards.ProtectedDirectoryCount
            files_deny_write_delete = $true
            directories_acl_protected = $true
        }
        jdk = $jdk
        git = $git
        android_sdk = $android
        gradle = $TrustGuard.GradleBinding
    }
}

function Assert-TL1C1bBuildEnvironmentPreBootstrap {
    param([Parameter(Mandatory)]$TrustGuard)
    return Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged $TrustGuard
}

function Assert-TL1C1bBuildEnvironmentPostBootstrap {
    param([Parameter(Mandatory)]$TrustGuard)
    return Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle
}

function Assert-TL1C1bBuildEnvironmentFrozen {
    param([Parameter(Mandatory)]$TrustGuard)
    return Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
        $TrustGuard -RequireGradle
}

function Assert-TL1C1bBuildEnvironmentCleanupTarget {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParent,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    $parent = Resolve-TL1C1bBuildEnvironmentOrdinaryDirectory `
        $ExpectedParent 'cleanup parent'
    if ($ExpectedName -cnotmatch '^tl1-c1b-gradle-user-home-[0-9a-f]{32}$') {
        throw 'C1b GRADLE_USER_HOME cleanup name 不在专用 allowlist。'
    }
    $expected = [IO.Path]::GetFullPath((Join-Path $parent $ExpectedName))
    $actual = [IO.Path]::GetFullPath($Path)
    if (-not (Test-TL1C1bBuildEnvironmentPathEqual $expected $actual) -or
        -not (Test-TL1C1bBuildEnvironmentPathEqual `
            ([IO.Path]::GetDirectoryName($actual)) $parent)) {
        throw 'C1b GRADLE_USER_HOME cleanup target 越界。'
    }
    if (-not (Test-Path -LiteralPath $actual)) { return $actual }
    $inventory = Get-TL1C1bBuildEnvironmentTreeInventory $actual
    foreach ($relative in $inventory.Files) {
        $file = Join-Path $actual ($relative.Replace('/', '\'))
        $stream = [IO.File]::Open(
            $file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $identity = [TL1C1bBuildEnvironmentFileIdentity]::Read($stream.SafeFileHandle)
            if ($identity.LinkCount -ne 1) {
                throw 'C1b cleanup target 含 hardlink，拒绝递归删除。'
            }
        } finally { $stream.Dispose() }
    }
    return $actual
}

function Close-TL1C1bBuildEnvironmentTrustGuard {
    param(
        [Parameter(Mandatory)]$TrustGuard,
        [switch]$KeepGradleUserHome
    )

    if ([bool]$TrustGuard.Disposed) { return }
    $failures = [Collections.Generic.List[string]]::new()
    try { [void](Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged $TrustGuard) }
    catch { $failures.Add("final frozen recheck: $($_.Exception.Message)") }
    if ($null -ne $TrustGuard.GradleDirectoryAclGuards) {
        try {
            Restore-TL1C1bBuildEnvironmentTreeDirectories `
                $TrustGuard.GradleDirectoryAclGuards
        } catch { $failures.Add("restore Gradle init.d ACL: $($_.Exception.Message)") }
    }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.GradleTreeGuard }
    catch { $failures.Add("close Gradle tree: $($_.Exception.Message)") }
    try {
        Restore-TL1C1bBuildEnvironmentTreeDirectories `
            $TrustGuard.IsolatedAndroidSdk.DirectoryAclGuards
    } catch { $failures.Add("restore isolated Android SDK ACL: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.IsolatedAndroidSdk.TreeGuard }
    catch { $failures.Add("close isolated Android SDK tree: $($_.Exception.Message)") }
    $debugKeystoreGuards = [Collections.Generic.List[object]]::new()
    foreach ($candidate in @(
        $TrustGuard.DebugKeystoreGuardAnchor,
        $TrustGuard.DebugKeystoreGuard
    )) {
        if ($null -eq $candidate) { continue }
        $duplicate = $false
        foreach ($existing in $debugKeystoreGuards) {
            if ([object]::ReferenceEquals($existing, $candidate)) {
                $duplicate = $true
                break
            }
        }
        if (-not $duplicate) { $debugKeystoreGuards.Add($candidate) }
    }
    foreach ($candidate in $debugKeystoreGuards) {
        try { Close-TL1C1bBuildEnvironmentDebugKeystoreGuard $candidate }
        catch {
            $failures.Add(
                "close isolated debug.keystore guard: $($_.Exception.Message)")
        }
    }
    foreach ($guard in @(
        $TrustGuard.Workspace.InitGradleGuard,
        $TrustGuard.Workspace.InitGradleKtsGuard,
        $TrustGuard.Workspace.InitDDirectoryBlockerGuard
    )) {
        try { if ($guard.Stream -is [IO.FileStream]) { $guard.Stream.Dispose() } }
        catch { $failures.Add("close GRADLE_USER_HOME sentinel: $($_.Exception.Message)") }
    }
    foreach ($aclGuard in @(
        $TrustGuard.Workspace.RootAclGuard,
        $TrustGuard.Workspace.ProcessTempAclGuard,
        $TrustGuard.Workspace.KotlinRuntimeAclGuard,
        $TrustGuard.Workspace.ProjectCacheAclGuard
    )) {
        try { Restore-TL1C1bBuildEnvironmentDirectory $aclGuard }
        catch { $failures.Add("restore fresh runtime/cache ACL: $($_.Exception.Message)") }
    }
    try {
        Restore-TL1C1bBuildEnvironmentTreeDirectories `
            $TrustGuard.GitDirectoryAclGuards
    } catch { $failures.Add("restore Git tree ACL: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.GitTreeGuard }
    catch { $failures.Add("close Git tree: $($_.Exception.Message)") }
    try {
        Restore-TL1C1bBuildEnvironmentTreeDirectories `
            $TrustGuard.JdkDirectoryAclGuards
    } catch { $failures.Add("restore JDK tree ACL: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.JdkTreeGuard }
    catch { $failures.Add("close JDK tree: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.AndroidPlatformTreeGuard }
    catch { $failures.Add("close Android platform tree: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.AndroidPlatformToolsTreeGuard }
    catch { $failures.Add("close Android platform-tools tree: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentTreeGuard $TrustGuard.AndroidBuildToolsTreeGuard }
    catch { $failures.Add("close Android build-tools tree: $($_.Exception.Message)") }
    try {
        Restore-TL1C1bBuildEnvironmentTreeDirectories `
            $TrustGuard.RepositoryDirectoryAclGuards
    } catch { $failures.Add("restore repository source ACL: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentFileSetGuard $TrustGuard.RepositoryFileSetGuard }
    catch { $failures.Add("close repository input guards: $($_.Exception.Message)") }
    try {
        Restore-TL1C1bBuildEnvironmentModuleBuildOutputGuard `
            $TrustGuard.ModuleBuildOutputGuard
    } catch { $failures.Add("remove fresh module build output: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentRepoInputGuard $TrustGuard.RepoInputGuard }
    catch { $failures.Add("remove app/local.properties sentinel: $($_.Exception.Message)") }
    try { Remove-TL1C1bBuildEnvironmentRecoveryJournal $TrustGuard.RecoveryJournal }
    catch { $failures.Add("remove ACL recovery journal: $($_.Exception.Message)") }
    if ([bool]$TrustGuard.RecoveryJournal.Removed) {
        try {
            Remove-TL1C1bBuildEnvironmentModuleBuildOutputGuard `
                $TrustGuard.ModuleBuildOutputGuard
        } catch { $failures.Add("remove fresh module build output: $($_.Exception.Message)") }
    }
    if ($script:TL1C1bBuildEnvironmentActiveRecoveryJournal -eq
        $TrustGuard.RecoveryJournal) {
        $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $null
    }
    $TrustGuard.Disposed = $true
    if (-not $KeepGradleUserHome -and [bool]$TrustGuard.RecoveryJournal.Removed) {
        try {
            $target = Assert-TL1C1bBuildEnvironmentCleanupTarget `
                $TrustGuard.Workspace.Root `
                $TrustGuard.Workspace.Parent `
                $TrustGuard.Workspace.Name
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        } catch { $failures.Add("remove GRADLE_USER_HOME: $($_.Exception.Message)") }
    }
    try { Close-TL1C1bBuildEnvironmentPathChainGuard $TrustGuard.PathChainGuard }
    catch { $failures.Add("close path-chain guard: $($_.Exception.Message)") }
    try { Close-TL1C1bBuildEnvironmentConcurrencyGuard $TrustGuard.ConcurrencyGuard }
    catch { $failures.Add("close canonical trust tuple mutex: $($_.Exception.Message)") }
    if ($failures.Count -ne 0) {
        throw ('C1b build-environment guard cleanup 未完整完成：' +
            ($failures -join ' | '))
    }
}
