#Requires -Version 7.5

if ($null -ne ('TL1C1bRealBuildSmokeFileIdentityV1' -as [type])) {
    throw 'TL1C1b real-build verifier native authority type is already loaded.'
}
$null = Microsoft.PowerShell.Utility\Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class TL1C1bRealBuildSmokeFileIdentityV1Result {
    public uint LinkCount { get; set; }
    public uint FileAttributes { get; set; }
    public ulong FileSize { get; set; }
    public long LastWriteTimeUtcFileTime { get; set; }
    public string StableId { get; set; }
}

public static class TL1C1bRealBuildSmokeFileIdentityV1 {
    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME { public uint Low; public uint High; }

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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle file, StringBuilder path, uint characterCount, uint flags);

    public static SafeFileHandle OpenDirectoryDenyDelete(string path) {
        const uint FILE_LIST_DIRECTORY = 0x00000001;
        const uint FILE_READ_ATTRIBUTES = 0x00000080;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint FILE_SHARE_WRITE = 0x00000002;
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        SafeFileHandle handle = CreateFileW(
            path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static SafeFileHandle OpenFileReadNoFollowDenyWriteDelete(
        string path) {
        const uint GENERIC_READ = 0x80000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint OPEN_EXISTING = 3;
        const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint FILE_FLAG_SEQUENTIAL_SCAN = 0x08000000;
        SafeFileHandle handle = CreateFileW(
            path, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT |
                FILE_FLAG_SEQUENTIAL_SCAN,
            IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
        return handle;
    }

    public static string GetFinalDosPath(SafeFileHandle file) {
        const int MAXIMUM_PATH_CHARACTERS = 32768;
        StringBuilder path = new StringBuilder(MAXIMUM_PATH_CHARACTERS);
        uint result = GetFinalPathNameByHandleW(
            file, path, (uint)path.Capacity, 0);
        if (result == 0) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        if (result >= path.Capacity) {
            throw new InvalidOperationException(
                "Final path exceeds the fixed Windows path bound.");
        }
        return path.ToString();
    }

    public static TL1C1bRealBuildSmokeFileIdentityV1Result Read(
        SafeFileHandle file) {
        BY_HANDLE_FILE_INFORMATION information;
        if (!GetFileInformationByHandle(file, out information)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ulong size = ((ulong)information.FileSizeHigh << 32) |
            information.FileSizeLow;
        ulong lastWrite = ((ulong)information.LastWriteTime.High << 32) |
            information.LastWriteTime.Low;
        return new TL1C1bRealBuildSmokeFileIdentityV1Result {
            LinkCount = information.NumberOfLinks,
            FileAttributes = information.FileAttributes,
            FileSize = size,
            LastWriteTimeUtcFileTime = unchecked((long)lastWrite),
            StableId = information.VolumeSerialNumber.ToString("X8") + ":" +
                information.FileIndexHigh.ToString("X8") +
                information.FileIndexLow.ToString("X8")
        };
    }
}
'@

function Find-TL1C1bRealBuildSmokeDuplicateJsonProperty {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Duplicates
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = "$Path/$($property.Name)"
            if (-not $names.Add($property.Name)) { $Duplicates.Add($childPath) }
            Find-TL1C1bRealBuildSmokeDuplicateJsonProperty `
                -Element $property.Value -Path $childPath -Duplicates $Duplicates
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1C1bRealBuildSmokeDuplicateJsonProperty `
                -Element $child -Path "$Path/$index" -Duplicates $Duplicates
            $index++
        }
    }
}

function Find-TL1C1bRealBuildSmokeInvalidJsonNumber {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [Collections.Generic.List[string]]$InvalidPaths
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Number) {
        $raw = $Element.GetRawText()
        $parsed = 0L
        if ($raw -cnotmatch '\A(?:0|-?[1-9][0-9]*)\z' -or
            -not [long]::TryParse(
                $raw, [Globalization.NumberStyles]::AllowLeadingSign,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            $InvalidPaths.Add($Path)
        }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            Find-TL1C1bRealBuildSmokeInvalidJsonNumber `
                -Element $property.Value -Path "$Path/$($property.Name)" `
                -InvalidPaths $InvalidPaths
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1C1bRealBuildSmokeInvalidJsonNumber `
                -Element $child -Path "$Path/$index" -InvalidPaths $InvalidPaths
            $index++
        }
    }
}

function Get-TL1C1bRealBuildSmokeSummaryRequiredProperties {
    return [string[]]@(
        'schema','started_at_utc','completed_at_utc','status','expected_commit_sha',
        'helper_sha256','bootstrap_git_execution_count',
        'bootstrap_git_provenance_verified','pre_git_provenance_verified',
        'post_git_provenance_verified','build_environment_schema',
        'repository_input_count','repository_input_catalog_sha256',
        'repository_input_directory_root_count','real_jdk_gradlemain_execution_count',
        'real_apksigner_execution_count','held_aapt2_verification_execution_count',
        'held_git_execution_count','unexpected_direct_process_count',
        'direct_adb_attempt_count','observed_adb_process_start_count',
        'real_adb_call_count','observed_direct_child_java_process_start_count',
        'observed_other_java_process_start_count','process_start_observer_scope',
        'process_start_observer_limitation','process_start_observation_ended_at_utc',
        'pre_adb_process_count','post_adb_process_count',
        'pre_default_adb_listener_count','post_default_adb_listener_count',
        'default_adb_listener_observation','device_enumeration_call_count',
        'install_attempt_count','t0_call_count','capture_call_count','jdk_version',
        'jdk_catalog_sha256','gradle_version','gradle_catalog_sha256',
        'gradle_entrypoint','wrapper_not_executed','apksigner_jar_sha256',
        'artifact_proof_sha256','debug_apk_sha256','release_apk_sha256',
        'signer_certificate_sha256','forbidden_match_count',
        'manifest_mutating_capability_count','manifest_extra_component_count',
        'dependency_allowlist_verified','packaged_axml_verified',
        'post_gradle_lock_sealed','artifact_guards_cleanup',
        'build_environment_cleanup','repository_library_guards_cleanup',
        'workspace_residual','recovery_journal_residual','module_build_residual',
        'module_gradle_residual','local_properties_residual','c1b_java_residual_count',
        'failure_count','failure_reasons'
    )
}

function Assert-TL1C1bRealBuildSmokeSummaryExactProperties {
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -isnot [pscustomobject]) { throw 'Helper summary root is not an object.' }
    $actual = [string[]]@($Value.PSObject.Properties.Name)
    $expected = Get-TL1C1bRealBuildSmokeSummaryRequiredProperties
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw 'Helper summary property set is not exact.'
    }
}

function ConvertFrom-TL1C1bRealBuildSmokeSummaryJson {
    param([Parameter(Mandatory)][string]$Raw)
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Raw)
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Helper summary root is not a JSON object.'
        }
        $duplicates = [Collections.Generic.List[string]]::new()
        Find-TL1C1bRealBuildSmokeDuplicateJsonProperty `
            -Element $document.RootElement -Path '' -Duplicates $duplicates
        if ($duplicates.Count -ne 0) {
            throw "Helper summary contains duplicate JSON properties: $($duplicates -join ', ')"
        }
        $invalidNumbers = [Collections.Generic.List[string]]::new()
        Find-TL1C1bRealBuildSmokeInvalidJsonNumber `
            -Element $document.RootElement -Path '' -InvalidPaths $invalidNumbers
        if ($invalidNumbers.Count -ne 0) {
            throw "Helper summary contains a non-Int64 JSON number: $($invalidNumbers -join ', ')"
        }
        return $Raw | Microsoft.PowerShell.Utility\ConvertFrom-Json `
            -Depth 100 -DateKind String -ErrorAction Stop
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain {
    param([Parameter(Mandatory)][string]$Path)
    $item = Microsoft.PowerShell.Management\Get-Item `
        -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw 'Helper summary expected parent is not a directory.' }
    $reversed = [Collections.Generic.List[string]]::new()
    $cursor = [IO.DirectoryInfo]$item
    while ($null -ne $cursor) {
        $current = Microsoft.PowerShell.Management\Get-Item `
            -LiteralPath $cursor.FullName -Force -ErrorAction Stop
        $linkProperty = $current.PSObject.Properties['LinkType']
        $linkType = if ($null -eq $linkProperty) { '' } else { [string]$linkProperty.Value }
        if (-not $current.PSIsContainer -or
            ($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace($linkType)) {
            throw 'Helper summary directory path chain is not ordinary and reparse-free.'
        }
        $reversed.Add([IO.Path]::GetFullPath($current.FullName))
        $cursor = $current.Parent
    }
    $result = [string[]]::new($reversed.Count)
    for ($index = 0; $index -lt $reversed.Count; $index++) {
        $result[$index] = $reversed[$reversed.Count - $index - 1]
    }
    return $result
}

function Assert-TL1C1bRealBuildSmokeOrdinaryLeaf {
    param([Parameter(Mandatory)][string]$Path)
    $item = Microsoft.PowerShell.Management\Get-Item `
        -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Helper summary is not an ordinary, reparse-free file.'
    }
}

function Get-TL1C1bRealBuildSmokeHeldFileIdentity {
    param([Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle)
    return [TL1C1bRealBuildSmokeFileIdentityV1]::Read($Handle)
}

function ConvertFrom-TL1C1bRealBuildSmokeFinalDosPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        return [IO.Path]::GetFullPath('\\' + $Path.Substring(8))
    }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) {
        return [IO.Path]::GetFullPath($Path.Substring(4))
    }
    return [IO.Path]::GetFullPath($Path)
}

function Assert-TL1C1bRealBuildSmokeHandleFinalPath {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][string]$ExpectedPath
    )
    $actual = ConvertFrom-TL1C1bRealBuildSmokeFinalDosPath `
        -Path ([TL1C1bRealBuildSmokeFileIdentityV1]::GetFinalDosPath($Handle))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $actual.TrimEnd([IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar),
            ([IO.Path]::GetFullPath($ExpectedPath)).TrimEnd(
                [IO.Path]::DirectorySeparatorChar,
                [IO.Path]::AltDirectorySeparatorChar))) {
        throw 'Held handle final path does not match its canonical expected path.'
    }
}

function Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity {
    param([Parameter(Mandatory)][object]$Identity)
    $directoryFlag = [uint32][IO.FileAttributes]::Directory
    $reparseFlag = [uint32][IO.FileAttributes]::ReparsePoint
    if (([uint32]$Identity.FileAttributes -band $directoryFlag) -eq 0 -or
        ([uint32]$Identity.FileAttributes -band $reparseFlag) -ne 0) {
        throw 'Helper summary held directory is not ordinary and reparse-free.'
    }
}

function Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld {
    param([Parameter(Mandatory)][object]$Binding)
    $currentHandle = $null
    try {
        $currentHandle = [TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete(
            [string]$Binding.Path)
        $currentIdentity = Get-TL1C1bRealBuildSmokeHeldFileIdentity `
            -Handle $currentHandle
        Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity -Identity $currentIdentity
        Assert-TL1C1bRealBuildSmokeHandleFinalPath `
            -Handle $currentHandle -ExpectedPath ([string]$Binding.Path)
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$currentIdentity.StableId,
                [string]$Binding.Identity.StableId)) {
            throw 'Helper summary directory path no longer resolves to its held directory.'
        }
    }
    finally { if ($null -ne $currentHandle) { $currentHandle.Dispose() } }
}

function Assert-TL1C1bRealBuildSmokeHeldFileIdentity {
    param(
        [Parameter(Mandatory)][object]$Identity,
        [Parameter(Mandatory)][long]$ExpectedLength
    )
    $directoryFlag = [uint32][IO.FileAttributes]::Directory
    $reparseFlag = [uint32][IO.FileAttributes]::ReparsePoint
    if ([uint32]$Identity.LinkCount -ne 1) {
        throw 'Helper summary held file has a hard-link count other than one.'
    }
    if (([uint32]$Identity.FileAttributes -band $directoryFlag) -ne 0 -or
        ([uint32]$Identity.FileAttributes -band $reparseFlag) -ne 0) {
        throw 'Helper summary held handle is not an ordinary, reparse-free file.'
    }
    if ([uint64]$Identity.FileSize -ne [uint64]$ExpectedLength) {
        throw 'Helper summary held file length changed.'
    }
}

function Assert-TL1C1bRealBuildSmokePathMatchesHeldFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$HeldIdentity,
        [Parameter(Mandatory)][long]$ExpectedLength
    )
    $pathHandle = $null
    try {
        $pathHandle = [TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete(
            $Path)
        $pathIdentity = Get-TL1C1bRealBuildSmokeHeldFileIdentity -Handle $pathHandle
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity `
            -Identity $pathIdentity -ExpectedLength $ExpectedLength
        Assert-TL1C1bRealBuildSmokeHandleFinalPath `
            -Handle $pathHandle -ExpectedPath $Path
        if (-not [StringComparer]::Ordinal.Equals(
                [string]$pathIdentity.StableId, [string]$HeldIdentity.StableId)) {
            throw 'Helper summary path no longer resolves to the held file.'
        }
    }
    finally { if ($null -ne $pathHandle) { $pathHandle.Dispose() } }
}

function Assert-TL1C1bRealBuildSmokeSummaryValue {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedHelperSha256,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessStartedNotBeforeUtc,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessExitedNotAfterUtc,
        [Parameter(Mandatory)][double]$MaximumObserverTailSeconds
    )
    if ([double]::IsNaN($MaximumObserverTailSeconds) -or
        [double]::IsInfinity($MaximumObserverTailSeconds) -or
        $MaximumObserverTailSeconds -lt 0.0 -or $MaximumObserverTailSeconds -gt 5.0) {
        throw 'Maximum observer tail must be finite and within 0..5 seconds.'
    }
    if ($HelperProcessExitedNotAfterUtc -lt $HelperProcessStartedNotBeforeUtc) {
        throw 'Helper process execution envelope is invalid.'
    }
    Assert-TL1C1bRealBuildSmokeSummaryExactProperties -Value $Value

    $integerProperties = [string[]]@(
        'bootstrap_git_execution_count','repository_input_count',
        'repository_input_directory_root_count','real_jdk_gradlemain_execution_count',
        'real_apksigner_execution_count','held_aapt2_verification_execution_count',
        'held_git_execution_count','unexpected_direct_process_count',
        'direct_adb_attempt_count','observed_adb_process_start_count',
        'real_adb_call_count','observed_direct_child_java_process_start_count',
        'observed_other_java_process_start_count','pre_adb_process_count',
        'post_adb_process_count','pre_default_adb_listener_count',
        'post_default_adb_listener_count','device_enumeration_call_count',
        'install_attempt_count','t0_call_count','capture_call_count',
        'forbidden_match_count','manifest_mutating_capability_count',
        'manifest_extra_component_count','c1b_java_residual_count','failure_count'
    )
    foreach ($name in $integerProperties) {
        if ($Value.PSObject.Properties[$name].Value -isnot [long]) {
            throw "Helper summary property is not an Int64: $name"
        }
    }
    $booleanProperties = [string[]]@(
        'bootstrap_git_provenance_verified','pre_git_provenance_verified',
        'post_git_provenance_verified','wrapper_not_executed',
        'dependency_allowlist_verified','packaged_axml_verified',
        'post_gradle_lock_sealed','workspace_residual','recovery_journal_residual',
        'module_build_residual','module_gradle_residual','local_properties_residual'
    )
    foreach ($name in $booleanProperties) {
        if ($Value.PSObject.Properties[$name].Value -isnot [bool]) {
            throw "Helper summary property is not boolean: $name"
        }
    }
    $stringProperties = [string[]]@(
        'schema','started_at_utc','completed_at_utc','status','expected_commit_sha',
        'helper_sha256','build_environment_schema','repository_input_catalog_sha256',
        'process_start_observer_scope','process_start_observer_limitation',
        'process_start_observation_ended_at_utc','default_adb_listener_observation',
        'jdk_version','jdk_catalog_sha256','gradle_version','gradle_catalog_sha256',
        'gradle_entrypoint','apksigner_jar_sha256','artifact_proof_sha256',
        'debug_apk_sha256','release_apk_sha256','signer_certificate_sha256',
        'artifact_guards_cleanup','build_environment_cleanup',
        'repository_library_guards_cleanup'
    )
    foreach ($name in $stringProperties) {
        $propertyValue = $Value.PSObject.Properties[$name].Value
        if ($propertyValue -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$propertyValue)) {
            throw "Helper summary property is not a nonempty string: $name"
        }
    }
    if ($Value.failure_reasons -isnot [Array]) {
        throw 'Helper summary failure_reasons is not an array.'
    }

    $timestampPattern = '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z\z'
    foreach ($name in @('started_at_utc','completed_at_utc','process_start_observation_ended_at_utc')) {
        if ([string]$Value.PSObject.Properties[$name].Value -cnotmatch $timestampPattern) {
            throw "Helper summary timestamp is not exact UTC: $name"
        }
    }
    $timestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
    $timestampStyles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    try {
        $startedAt = [DateTimeOffset]::ParseExact([string]$Value.started_at_utc,
            $timestampFormat, [Globalization.CultureInfo]::InvariantCulture, $timestampStyles)
        $completedAt = [DateTimeOffset]::ParseExact([string]$Value.completed_at_utc,
            $timestampFormat, [Globalization.CultureInfo]::InvariantCulture, $timestampStyles)
        $observationEndedAt = [DateTimeOffset]::ParseExact(
            [string]$Value.process_start_observation_ended_at_utc, $timestampFormat,
            [Globalization.CultureInfo]::InvariantCulture, $timestampStyles)
    }
    catch { throw 'Helper summary contains an invalid UTC timestamp.' }
    if ($completedAt -lt $startedAt -or $observationEndedAt -le $startedAt -or
        $observationEndedAt -gt $completedAt) {
        throw 'Helper summary timestamp ordering is invalid.'
    }
    if ($startedAt -lt $HelperProcessStartedNotBeforeUtc -or
        $completedAt -gt $HelperProcessExitedNotAfterUtc) {
        throw 'Helper summary timestamps are outside the launcher process envelope.'
    }
    if (($completedAt - $observationEndedAt).TotalSeconds -gt $MaximumObserverTailSeconds) {
        throw 'Helper summary process observer ended too early.'
    }

    $artifactHashValues = [string[]]@(
        $Value.jdk_catalog_sha256,$Value.gradle_catalog_sha256,
        $Value.apksigner_jar_sha256,$Value.artifact_proof_sha256,
        $Value.debug_apk_sha256,$Value.release_apk_sha256,
        $Value.signer_certificate_sha256)
    $invalidArtifactHashCount = 0
    foreach ($artifactHashValue in $artifactHashValues) {
        if ([string]$artifactHashValue -cnotmatch '\Asha256:[0-9a-f]{64}\z') {
            $invalidArtifactHashCount++
        }
    }
    $checks = [ordered]@{
        schema = ([string]$Value.schema -ceq 'tablet-layout-c1b-real-build-smoke-summary/v1')
        status = ([string]$Value.status -ceq 'passed')
        commit = ([string]$Value.expected_commit_sha -cmatch '\A[0-9a-f]{40}\z' -and
            [string]$Value.expected_commit_sha -ceq $ExpectedCommitSha)
        helper = ([string]$Value.helper_sha256 -cmatch '\Asha256:[0-9a-f]{64}\z' -and
            [string]$Value.helper_sha256 -ceq ('sha256:' + $ExpectedHelperSha256))
        bootstrap_git = ([long]$Value.bootstrap_git_execution_count -eq 2 -and [bool]$Value.bootstrap_git_provenance_verified)
        git_provenance = ([bool]$Value.pre_git_provenance_verified -and [bool]$Value.post_git_provenance_verified)
        build_schema = ([string]$Value.build_environment_schema -ceq 'tablet-layout-c1b-build-environment-trust/v1')
        inputs = ([long]$Value.repository_input_count -eq 42)
        roots = ([long]$Value.repository_input_directory_root_count -eq 3 -and [string]$Value.repository_input_catalog_sha256 -cmatch '\Asha256:[0-9a-f]{64}\z')
        gradle = ([long]$Value.real_jdk_gradlemain_execution_count -eq 1)
        signer = ([long]$Value.real_apksigner_execution_count -eq 1)
        aapt2 = ([long]$Value.held_aapt2_verification_execution_count -eq 4)
        git = ([long]$Value.held_git_execution_count -eq 32)
        unexpected_process = ([long]$Value.unexpected_direct_process_count -eq 0)
        adb = ([long]$Value.real_adb_call_count -eq 0 -and [long]$Value.direct_adb_attempt_count -eq 0 -and [long]$Value.observed_adb_process_start_count -eq 0)
        adb_snapshots = ([long]$Value.pre_adb_process_count -eq 0 -and [long]$Value.post_adb_process_count -eq 0 -and [long]$Value.pre_default_adb_listener_count -eq 0 -and [long]$Value.post_default_adb_listener_count -eq 0)
        java_canary = ([long]$Value.observed_direct_child_java_process_start_count -eq 2 -and [long]$Value.observed_other_java_process_start_count -ge 0)
        observer = ([string]$Value.process_start_observer_scope -ceq 'host_wide_best_effort_wmi' -and [string]$Value.process_start_observer_limitation -ceq 'Win32_ProcessStartTrace is operational observation, not a persistent kernel or syscall audit.' -and [string]$Value.default_adb_listener_observation -ceq 'boundary_snapshots_only')
        no_device = ([long]$Value.device_enumeration_call_count -eq 0 -and [long]$Value.install_attempt_count -eq 0 -and [long]$Value.t0_call_count -eq 0 -and [long]$Value.capture_call_count -eq 0)
        toolchain = ([string]$Value.jdk_version -ceq '21.0.5' -and [string]$Value.jdk_catalog_sha256 -ceq 'sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9' -and [string]$Value.gradle_version -ceq '8.9' -and [string]$Value.gradle_catalog_sha256 -ceq 'sha256:d0974b974d9471723cccf083f59e8772448b5bb6672f479bddd63897ba665189' -and [string]$Value.gradle_entrypoint -ceq 'org.gradle.launcher.GradleMain' -and [bool]$Value.wrapper_not_executed -and [string]$Value.apksigner_jar_sha256 -ceq 'sha256:00ef9948f843fe395d2440ae3ef41405b8040a6d5d46493bd1902ac0ee6deae7')
        artifacts = ([long]$Value.forbidden_match_count -eq 0 -and [long]$Value.manifest_mutating_capability_count -eq 0 -and [long]$Value.manifest_extra_component_count -eq 0 -and [bool]$Value.dependency_allowlist_verified -and [bool]$Value.packaged_axml_verified -and [bool]$Value.post_gradle_lock_sealed -and $invalidArtifactHashCount -eq 0)
        cleanup = ([string]$Value.artifact_guards_cleanup -ceq 'completed' -and [string]$Value.build_environment_cleanup -ceq 'completed' -and [string]$Value.repository_library_guards_cleanup -ceq 'completed')
        residue = (-not [bool]$Value.workspace_residual -and -not [bool]$Value.recovery_journal_residual -and -not [bool]$Value.module_build_residual -and -not [bool]$Value.module_gradle_residual -and -not [bool]$Value.local_properties_residual -and [long]$Value.c1b_java_residual_count -eq 0)
        failures = ([long]$Value.failure_count -eq 0 -and @($Value.failure_reasons).Count -eq 0)
    }
    $failed = [Collections.Generic.List[string]]::new()
    foreach ($check in $checks.GetEnumerator()) {
        if (-not [bool]$check.Value) { $failed.Add([string]$check.Key) }
    }
    if ($failed.Count -ne 0) {
        throw "Helper summary verification failed: $([string[]]$failed -join ', ')"
    }
}

function Assert-TL1C1bRealBuildSmokeSummaryFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParentDirectory,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{40}\z')][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedHelperSha256,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessStartedNotBeforeUtc,
        [Parameter(Mandatory)][DateTimeOffset]$HelperProcessExitedNotAfterUtc,
        [Parameter(Mandatory)][double]$MaximumObserverTailSeconds
    )
    if (-not [OperatingSystem]::IsWindows()) {
        throw 'Helper summary held-file verification only accepts Windows.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or
        -not [IO.Path]::IsPathFullyQualified($ExpectedParentDirectory)) {
        throw 'Helper summary path and expected parent must be absolute.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $expectedParent = [IO.Path]::GetFullPath($ExpectedParentDirectory)
    $actualParent = [IO.Path]::GetDirectoryName($fullPath)
    if (-not [StringComparer]::Ordinal.Equals(
            $actualParent.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar),
            $expectedParent.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar))) {
        throw 'Helper summary path is outside the exact expected parent directory.'
    }
    $relative = [IO.Path]::GetRelativePath($expectedParent, $fullPath)
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -ceq '.' -or
        $relative.Contains([IO.Path]::DirectorySeparatorChar) -or
        $relative.Contains([IO.Path]::AltDirectorySeparatorChar) -or
        $relative.Contains(':')) {
        throw 'Helper summary path is not one ordinary leaf under the expected parent.'
    }

    $directoryBindings = [Collections.Generic.List[object]]::new()
    $fileHandle = $null
    $stream = $null
    $bytes = $null
    $result = $null
    try {
        $directoryChain = @(Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain -Path $expectedParent)
        Assert-TL1C1bRealBuildSmokeOrdinaryLeaf -Path $fullPath
        foreach ($directory in $directoryChain) {
            $directoryHandle = $null
            try {
                $directoryHandle = [TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete(
                    $directory)
                $directoryIdentity = Get-TL1C1bRealBuildSmokeHeldFileIdentity `
                    -Handle $directoryHandle
                Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity `
                    -Identity $directoryIdentity
                Assert-TL1C1bRealBuildSmokeHandleFinalPath `
                    -Handle $directoryHandle -ExpectedPath $directory
                $directoryBindings.Add([pscustomobject]@{
                    Path = [string]$directory
                    Handle = $directoryHandle
                    Identity = $directoryIdentity
                })
                $directoryHandle = $null
            }
            finally {
                if ($null -ne $directoryHandle) { $directoryHandle.Dispose() }
            }
        }
        $secondDirectoryChain = @(Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain -Path $expectedParent)
        if (($directoryChain -join "`n") -cne ($secondDirectoryChain -join "`n")) {
            throw 'Helper summary directory path chain changed while being held.'
        }
        foreach ($binding in $directoryBindings) {
            Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld -Binding $binding
        }
        Assert-TL1C1bRealBuildSmokeOrdinaryLeaf -Path $fullPath

        $fileHandle = [TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete(
            $fullPath)
        Assert-TL1C1bRealBuildSmokeHandleFinalPath `
            -Handle $fileHandle -ExpectedPath $fullPath
        $stream = [IO.FileStream]::new(
            $fileHandle, [IO.FileAccess]::Read, 4096, $false)
        $fileHandle = $null
        $length = [long]$stream.Length
        if ($length -lt 1 -or $length -gt 65536) {
            throw 'Helper summary byte length is outside the closed bound.'
        }
        $initialIdentity = Get-TL1C1bRealBuildSmokeHeldFileIdentity `
            -Handle $stream.SafeFileHandle
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity -Identity $initialIdentity -ExpectedLength $length
        Assert-TL1C1bRealBuildSmokeOrdinaryLeaf -Path $fullPath
        Assert-TL1C1bRealBuildSmokePathMatchesHeldFile -Path $fullPath -HeldIdentity $initialIdentity -ExpectedLength $length

        $bytes = [byte[]]::new([int]$length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw 'Helper summary held-file read ended early.' }
            $offset += $read
        }
        if ($stream.ReadByte() -ne -1 -or $stream.Length -ne $length) {
            throw 'Helper summary held-file length changed during the read.'
        }
        $finalIdentity = Get-TL1C1bRealBuildSmokeHeldFileIdentity `
            -Handle $stream.SafeFileHandle
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity -Identity $finalIdentity -ExpectedLength $length
        if (-not [StringComparer]::Ordinal.Equals([string]$initialIdentity.StableId,
                [string]$finalIdentity.StableId) -or
            [long]$initialIdentity.LastWriteTimeUtcFileTime -ne [long]$finalIdentity.LastWriteTimeUtcFileTime) {
            throw 'Helper summary held-file identity changed during the read.'
        }
        $thirdDirectoryChain = @(Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain -Path $expectedParent)
        if (($directoryChain -join "`n") -cne ($thirdDirectoryChain -join "`n")) {
            throw 'Helper summary directory path chain changed after the read.'
        }
        foreach ($binding in $directoryBindings) {
            Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld -Binding $binding
        }
        Assert-TL1C1bRealBuildSmokeOrdinaryLeaf -Path $fullPath
        Assert-TL1C1bRealBuildSmokePathMatchesHeldFile -Path $fullPath -HeldIdentity $finalIdentity -ExpectedLength $length

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
            $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            throw 'Helper summary must not contain a UTF-8 BOM.'
        }
        $sha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $raw = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $value = ConvertFrom-TL1C1bRealBuildSmokeSummaryJson -Raw $raw
        Assert-TL1C1bRealBuildSmokeSummaryValue -Value $value `
            -ExpectedCommitSha $ExpectedCommitSha -ExpectedHelperSha256 $ExpectedHelperSha256 `
            -HelperProcessStartedNotBeforeUtc $HelperProcessStartedNotBeforeUtc `
            -HelperProcessExitedNotAfterUtc $HelperProcessExitedNotAfterUtc `
            -MaximumObserverTailSeconds $MaximumObserverTailSeconds
        $result = [pscustomobject][ordered]@{
            ByteLength = [long]$length
            Sha256 = [string]$sha256
        }
    }
    finally {
        $cleanupFailures = [Collections.Generic.List[string]]::new()
        if ($null -ne $bytes -and $bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
        if ($null -ne $stream) {
            try { $stream.Dispose() }
            catch { $cleanupFailures.Add("file stream: $($_.Exception.Message)") }
        }
        if ($null -ne $fileHandle) {
            try { $fileHandle.Dispose() }
            catch { $cleanupFailures.Add("file handle: $($_.Exception.Message)") }
        }
        for ($index = $directoryBindings.Count - 1; $index -ge 0; $index--) {
            try { $directoryBindings[$index].Handle.Dispose() }
            catch {
                $cleanupFailures.Add(
                    "directory handle $($directoryBindings[$index].Path): $($_.Exception.Message)")
            }
        }
        if ($cleanupFailures.Count -ne 0) {
            throw "Helper summary held-handle cleanup failed: $($cleanupFailures -join '; ')"
        }
    }
    return $result
}
