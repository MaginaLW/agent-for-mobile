#Requires -Version 7.5
# T-L1 v2 diagnostic-only consumer。只消费显式 synthetic fixture；runtime producer/runner attest 尚未开放。

Set-StrictMode -Version 3.0

if ($null -eq ('TabletLayoutObservationV2.NativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace TabletLayoutObservationV2 {
    [StructLayout(LayoutKind.Sequential)]
    public struct ByHandleFileInformation {
        public uint FileAttributes; public FILETIME CreationTime; public FILETIME LastAccessTime;
        public FILETIME LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh;
        public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow;
    }
    public static class NativePath {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint length, uint flags);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation info);
    }
}
'@ -ErrorAction Stop
}

$script:TL1V2Schema = 'tablet-layout-observation/v2'
$script:TL1V2ValidationSchema = 'tablet-layout-observation-validation/v2'
$script:TL1V2TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'"
$script:TL1V2MinimumIntervalTicks = [TimeSpan]::FromMilliseconds(900).Ticks
$script:TL1V2MaximumSpanTicks = [TimeSpan]::FromSeconds(15).Ticks
$script:TL1V2MaximumAgeTicks = [TimeSpan]::FromMinutes(2).Ticks
$script:TL1V2MaximumT0AgeTicks = [TimeSpan]::FromMinutes(10).Ticks
$script:TL1V2TrustedT0ProducerSha = '4ca32b131007df58f7752c5ee9b2d049cb1cd54e'
$script:TL1V2FixedT0FixtureName = 'upstream-t0-v5.json'
$script:TL1V2SyntheticPrivacyCanary = 'tl1v2.synthetic-privacy-canary.fixture-only.20260825'
$script:TL1V2RequiredBlockers = [string[]]@(
    'tablet_layout_diagnostic_only', 'upstream_t0_readiness_blocked',
    'tablet_landscape_p0_unimplemented', 'tablet_tl2_unverified'
)
$script:TL1V2ConsumerValidationTimeReasons = [string[]]@('capture_in_future', 'capture_stale')

function Add-TL1V2Issue {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path
    )
    foreach ($issue in $Issues) {
        if ($issue.code -ceq $Code -and $issue.path -ceq $Path) { return }
    }
    $Issues.Add([pscustomobject]@{ code = $Code; path = $Path })
}

function Get-TL1V2ReasonCodes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues)
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $result = [Collections.Generic.List[string]]::new()
    foreach ($issue in $Issues) {
        if ($set.Add([string]$issue.code)) { $result.Add([string]$issue.code) }
    }
    return [string[]]$result.ToArray()
}

function Get-TL1V2Sha256Bytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return 'sha256:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Get-TL1V2Sha256Text {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    try { return Get-TL1V2Sha256Bytes $bytes }
    finally { if ($bytes.Length -gt 0) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

$script:TL1V2SyntheticPrivacyCanaryHash = Get-TL1V2Sha256Text $script:TL1V2SyntheticPrivacyCanary

function Get-TL1V2SyntheticPrivacyCanary {
    return $script:TL1V2SyntheticPrivacyCanary
}

function Get-TL1V2SyntheticPrivacyCanaryHash {
    return $script:TL1V2SyntheticPrivacyCanaryHash
}

function ConvertTo-TL1V2CanonicalJson {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int64] -or $Value -is [int32] -or $Value -is [int16] -or $Value -is [byte]) {
        return ([Convert]::ToInt64($Value)).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject ([string]$Value) -Compress }
    if ($Value -is [Array]) {
        return '[' + ((@($Value) | ForEach-Object { ConvertTo-TL1V2CanonicalJson $_ }) -join ',') + ']'
    }
    if ($null -ne $Value.PSObject) {
        $names = [string[]]@($Value.PSObject.Properties.Name)
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $members = foreach ($name in $names) {
            (ConvertTo-Json -InputObject $name -Compress) + ':' +
                (ConvertTo-TL1V2CanonicalJson $Value.PSObject.Properties[$name].Value)
        }
        return '{' + ($members -join ',') + '}'
    }
    throw "unsupported canonical value type: $($Value.GetType().FullName)"
}

function Get-TL1V2DeviceProfileHash {
    param([Parameter(Mandatory)]$Device)
    return Get-TL1V2Sha256Text ("tablet-t0-device-profile/v2`n" + (ConvertTo-TL1V2CanonicalJson $Device))
}

function ConvertFrom-TL1V2Timestamp {
    param($Value)
    if ($Value -isnot [string] -or $Value.Length -ne 28) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact(
            $Value, $script:TL1V2TimestampFormat, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$parsed
        ) -or $parsed.Offset -ne [TimeSpan]::Zero) { return $null }
    return $parsed
}

function Test-TL1V2RectValid {
    param($Rect)
    return $null -ne $Rect -and [long]$Rect.right -gt [long]$Rect.left -and
        [long]$Rect.bottom -gt [long]$Rect.top
}

function Test-TL1V2RectContained {
    param($Inner, $Outer)
    return (Test-TL1V2RectValid $Inner) -and (Test-TL1V2RectValid $Outer) -and
        [long]$Inner.left -ge [long]$Outer.left -and [long]$Inner.top -ge [long]$Outer.top -and
        [long]$Inner.right -le [long]$Outer.right -and [long]$Inner.bottom -le [long]$Outer.bottom
}

function Test-TL1V2RectEqual {
    param($Left, $Right)
    return $null -ne $Left -and $null -ne $Right -and
        [long]$Left.left -eq [long]$Right.left -and [long]$Left.top -eq [long]$Right.top -and
        [long]$Left.right -eq [long]$Right.right -and [long]$Left.bottom -eq [long]$Right.bottom
}

function Test-TL1V2RectsOverlap {
    param($Left, $Right)
    return (Test-TL1V2RectValid $Left) -and (Test-TL1V2RectValid $Right) -and
        [long]$Left.left -lt [long]$Right.right -and [long]$Left.right -gt [long]$Right.left -and
        [long]$Left.top -lt [long]$Right.bottom -and [long]$Left.bottom -gt [long]$Right.top
}

function Get-TL1V2RectSignature {
    param($Rect)
    if ($null -eq $Rect) { return '<null>' }
    return "$([long]$Rect.left),$([long]$Rect.top),$([long]$Rect.right),$([long]$Rect.bottom)"
}

function Find-TL1V2DuplicateJsonProperty {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Duplicates
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = "$Path/$($property.Name)"
            if (-not $names.Add($property.Name)) { $Duplicates.Add($childPath) }
            Find-TL1V2DuplicateJsonProperty $property.Value $childPath $Duplicates
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1V2DuplicateJsonProperty $child "$Path/$index" $Duplicates
            $index++
        }
    }
}

function Find-TL1V2InvalidNumber {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$InvalidPaths
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Number) {
        $rawNumber = $Element.GetRawText()
        $parsed = 0L
        if ($rawNumber -cnotmatch '\A-?(0|[1-9][0-9]*)\z' -or -not [long]::TryParse(
                $rawNumber, [Globalization.NumberStyles]::AllowLeadingSign,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed
            )) { $InvalidPaths.Add($Path) }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            Find-TL1V2InvalidNumber $property.Value "$Path/$($property.Name)" $InvalidPaths
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1V2InvalidNumber $child "$Path/$index" $InvalidPaths
            $index++
        }
    }
}

function Find-TL1V2ForbiddenPrivacyProperty {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Findings
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = "$Path/$($property.Name)"
            $lower = $property.Name.ToLowerInvariant()
            if ($lower -in @('window_id','raw_window_id','raw_window_identity','node_id','raw_node_id','raw_node_identity','view_id','view_id_resource_name')) {
                $Findings.Add([pscustomobject]@{ code='raw_identity_persisted'; path=$childPath })
            }
            elseif ($lower -in @('text','chat_text','chat_plaintext','content_description','message_text','raw_dump','screenshot_base64')) {
                $Findings.Add([pscustomobject]@{ code='chat_plaintext_persisted'; path=$childPath })
            }
            elseif ($lower -in @('content_hash','content_hashes','text_hash','description_hash','stable_content_sha256') -or
                $lower -match '(content|text|description).*(hash|digest|sha)') {
                $Findings.Add([pscustomobject]@{ code='chat_content_digest_persisted'; path=$childPath })
            }
            Find-TL1V2ForbiddenPrivacyProperty $property.Value $childPath $Findings
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1V2ForbiddenPrivacyProperty $child "$Path/$index" $Findings
            $index++
        }
    }
}

function Find-TL1V2SyntheticPrivacyCanaryValue {
    param(
        [Parameter(Mandatory)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Findings
    )
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        if ($null -ne $value -and $value.Contains(
                $script:TL1V2SyntheticPrivacyCanary, [StringComparison]::Ordinal
            )) {
            $Findings.Add([pscustomobject]@{ code='chat_plaintext_persisted'; path=$Path })
        }
        $canaryHash = Get-TL1V2SyntheticPrivacyCanaryHash
        if ($null -ne $value -and $value.Contains($canaryHash, [StringComparison]::Ordinal)) {
            $Findings.Add([pscustomobject]@{ code='chat_content_digest_persisted'; path=$Path })
        }
        return
    }
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        foreach ($property in $Element.EnumerateObject()) {
            Find-TL1V2SyntheticPrivacyCanaryValue $property.Value "$Path/$($property.Name)" $Findings
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Find-TL1V2SyntheticPrivacyCanaryValue $child "$Path/$index" $Findings
            $index++
        }
    }
}

function Test-TL1V2ReparseChain {
    param(
        [Parameter(Mandatory)][IO.FileSystemInfo]$Item,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [Parameter(Mandatory)][string]$IssuePath
    )
    $current = $Item
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Add-TL1V2Issue $Issues 'evidence_path_reparse_point' $IssuePath
            return $false
        }
        $current = if ($current -is [IO.DirectoryInfo]) { $current.Parent } else { $current.Directory }
    }
    return $true
}

function Resolve-TL1V2ControlledPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    try {
        if (-not [IO.Path]::IsPathFullyQualified($EvidenceRoot) -or
            $EvidenceRoot.StartsWith('\\', [StringComparison]::Ordinal) -or
            $Path.StartsWith('\\', [StringComparison]::Ordinal)) {
            Add-TL1V2Issue $Issues 'evidence_path_not_local' '/path'
            return $null
        }
        $root = [IO.Path]::GetFullPath($EvidenceRoot).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        $anchor = [IO.Path]::GetPathRoot($root).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
        )
        if ($root.Equals($anchor, [StringComparison]::OrdinalIgnoreCase)) {
            Add-TL1V2Issue $Issues 'evidence_root_too_broad' '/evidence_root'
            return $null
        }
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
        if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
            Add-TL1V2Issue $Issues 'evidence_root_not_fixed_local' '/evidence_root'
            return $null
        }
        $candidate = if ([IO.Path]::IsPathFullyQualified($Path)) {
            [IO.Path]::GetFullPath($Path)
        } else { [IO.Path]::GetFullPath((Join-Path $root $Path)) }
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        if (-not $candidate.StartsWith($prefix, [StringComparison]::Ordinal) -or
            [IO.Path]::GetExtension($candidate) -cne '.json' -or
            $candidate.Substring($root.Length).Contains(':', [StringComparison]::Ordinal)) {
            Add-TL1V2Issue $Issues 'evidence_path_outside_root' '/path'
            return $null
        }
        $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
        if (-not $rootItem.PSIsContainer -or -not (Test-TL1V2ReparseChain $rootItem $Issues '/evidence_root')) {
            return $null
        }
        $relative = [IO.Path]::GetRelativePath($root, $candidate)
        $current = $root
        foreach ($segment in @($relative.Split(
                    [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
                    [StringSplitOptions]::RemoveEmptyEntries
                ))) {
            $current = Join-Path $current $segment
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Add-TL1V2Issue $Issues 'evidence_path_reparse_point' '/path'
                return $null
            }
        }
        $file = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
        if ($file.PSIsContainer) { throw 'not a file' }
        return [string]$file.FullName
    }
    catch {
        Add-TL1V2Issue $Issues 'evidence_file_missing' '/path'
        return $null
    }
}

function Test-TL1V2OpenedFileIdentity {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$Handle,
        [Parameter(Mandatory)][string]$ExpectedFullPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $buffer = [Text.StringBuilder]::new(32768)
    $length = [TabletLayoutObservationV2.NativePath]::GetFinalPathNameByHandle(
        $Handle, $buffer, [uint32]$buffer.Capacity, 0
    )
    if ($length -eq 0 -or $length -ge $buffer.Capacity) {
        Add-TL1V2Issue $Issues 'evidence_final_path_unavailable' '/path'
        return $false
    }
    $final = $buffer.ToString()
    if ($final.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $final = '\\' + $final.Substring(8) }
    elseif ($final.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { $final = $final.Substring(4) }
    if (-not ([IO.Path]::GetFullPath($final)).Equals(
            [IO.Path]::GetFullPath($ExpectedFullPath), [StringComparison]::Ordinal
        )) {
        Add-TL1V2Issue $Issues 'evidence_path_changed_after_validation' '/path'
        return $false
    }
    $info = [TabletLayoutObservationV2.ByHandleFileInformation]::new()
    if (-not [TabletLayoutObservationV2.NativePath]::GetFileInformationByHandle($Handle, [ref]$info)) {
        Add-TL1V2Issue $Issues 'evidence_file_identity_unavailable' '/path'
        return $false
    }
    if ($info.NumberOfLinks -ne 1) {
        Add-TL1V2Issue $Issues 'evidence_file_hardlink_unsupported' '/path'
        return $false
    }
    return $true
}

function Read-TL1V2ControlledUtf8 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.FileStream]::new(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read,
            4096, [IO.FileOptions]::SequentialScan
        )
        if (-not (Test-TL1V2OpenedFileIdentity $stream.SafeFileHandle $Path $Issues)) { return $null }
        if ($stream.Length -le 0 -or $stream.Length -gt 1048576) {
            Add-TL1V2Issue $Issues 'evidence_document_size_invalid' '/'
            return $null
        }
        $reader = [IO.StreamReader]::new(
            $stream, [Text.UTF8Encoding]::new($false, $true), $false, 4096, $true
        )
        return $reader.ReadToEnd()
    }
    catch {
        Add-TL1V2Issue $Issues 'evidence_file_unavailable' '/'
        return $null
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertFrom-TL1V2StrictJson {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues,
        [switch]$CheckPrivacy,
        [switch]$CheckSyntheticPrivacyCanary
    )
    $document = $null
    try {
        $document = [Text.Json.JsonDocument]::Parse($Raw)
        $duplicates = [Collections.Generic.List[string]]::new()
        Find-TL1V2DuplicateJsonProperty $document.RootElement '' $duplicates
        foreach ($path in $duplicates) { Add-TL1V2Issue $Issues 'duplicate_json_property' $path }
        $invalidNumbers = [Collections.Generic.List[string]]::new()
        Find-TL1V2InvalidNumber $document.RootElement '' $invalidNumbers
        foreach ($path in $invalidNumbers) { Add-TL1V2Issue $Issues 'json_number_not_int64' $path }
        if ($CheckPrivacy) {
            $findings = [Collections.Generic.List[object]]::new()
            Find-TL1V2ForbiddenPrivacyProperty $document.RootElement '' $findings
            foreach ($finding in $findings) { Add-TL1V2Issue $Issues $finding.code $finding.path }
        }
        if ($CheckPrivacy -or $CheckSyntheticPrivacyCanary) {
            $canaryFindings = [Collections.Generic.List[object]]::new()
            Find-TL1V2SyntheticPrivacyCanaryValue $document.RootElement '' $canaryFindings
            foreach ($finding in $canaryFindings) { Add-TL1V2Issue $Issues $finding.code $finding.path }
        }
        if ($issues.Count -gt 0) { return $null }
        return $Raw | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
    }
    catch {
        Add-TL1V2Issue $Issues 'validation_exception' '/'
        return $null
    }
    finally { if ($null -ne $document) { $document.Dispose() } }
}

function New-TL1V2ValidationResult {
    param(
        [bool]$FixtureContractValid,
        [bool]$DiagnosticObserved,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    return [pscustomobject][ordered]@{
        schema = $script:TL1V2ValidationSchema
        contract_schema = $script:TL1V2Schema
        fixture_contract_valid = $FixtureContractValid
        diagnostic_observed = $DiagnosticObserved
        diagnostic_status = if ($DiagnosticObserved) { 'observed' } else { 'blocked' }
        reason_codes = @(Get-TL1V2ReasonCodes $Issues)
        issues = @($Issues.ToArray())
        runtime_evidence = $false
        layout_accepted = $false
        wechat_layout_verified = $false
        editor_action_ready = $false
        settings_mutation_allowed = $false
        device_action_allowed = $false
        p0_capability = 'unsupported'
        execution_grant = $false
    }
}

function Test-TL1V2UpstreamT0 {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$T0,
        [Parameter(Mandatory)][string]$T0Raw,
        [Parameter(Mandatory)][DateTimeOffset]$FirstFrameAt,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    try {
        $topNames = [string[]]@($T0.PSObject.Properties.Name)
        $requiredTopMissing = $false
        foreach ($required in @('schema_version','run_id','captured_at_utc','device','assessment')) {
            if ($topNames -cnotcontains $required) {
                Add-TL1V2Issue $Issues 'upstream_t0_invalid' "/upstream_t0/$required"
                $requiredTopMissing = $true
            }
        }
        # Prior observation/provenance issues do not waive the independent T0
        # hash, device, producer, and freshness checks. Only a locally missing
        # required T0 top-level field makes those checks unsafe to continue.
        if ($requiredTopMissing) { return }
        $assessment = $T0.assessment
        if ([long]$T0.schema_version -ne 5 -or $T0.run_id -cne $Evidence.upstream_t0.run_id -or
            $T0.captured_at_utc -cne $Evidence.upstream_t0.captured_at -or
            $assessment.intake_status -cne 'accepted' -or $assessment.readiness_status -cne 'blocked' -or
            $assessment.p0_capability -cne 'unsupported') {
            Add-TL1V2Issue $Issues 'upstream_t0_invalid' '/upstream_t0'
        }
        if ((@($assessment.readiness_block_reasons) -join "`n") -cne
            (@($Evidence.upstream_t0.readiness_reasons) -join "`n") -or
            (@($assessment.p0_unsupported_reasons) -join "`n") -cne
            (@($Evidence.upstream_t0.p0_unsupported_reasons) -join "`n")) {
            Add-TL1V2Issue $Issues 'upstream_t0_invalid' '/upstream_t0/reasons'
        }
        $rawBytes = [Text.Encoding]::UTF8.GetBytes($T0Raw)
        try { $artifactHash = Get-TL1V2Sha256Bytes $rawBytes }
        finally { if ($rawBytes.Length -gt 0) { [Array]::Clear($rawBytes, 0, $rawBytes.Length) } }
        if ($Evidence.upstream_t0.artifact_sha256 -cne $artifactHash) {
            Add-TL1V2Issue $Issues 'upstream_t0_hash_mismatch' '/upstream_t0/artifact_sha256'
        }
        if ($Evidence.upstream_t0.device_profile_hash -cne (Get-TL1V2DeviceProfileHash $T0.device)) {
            Add-TL1V2Issue $Issues 'upstream_t0_device_hash_mismatch' '/upstream_t0/device_profile_hash'
        }
        if ($Evidence.upstream_t0.producer_commit_sha -cne $script:TL1V2TrustedT0ProducerSha) {
            Add-TL1V2Issue $Issues 'upstream_t0_producer_mismatch' '/upstream_t0/producer_commit_sha'
        }
        $t0At = ConvertFrom-TL1V2Timestamp $T0.captured_at_utc
        if ($null -eq $t0At -or $t0At -gt $FirstFrameAt -or
            ($FirstFrameAt - $t0At).Ticks -gt $script:TL1V2MaximumT0AgeTicks) {
            Add-TL1V2Issue $Issues 'upstream_t0_stale' '/upstream_t0/captured_at'
        }
    }
    catch { Add-TL1V2Issue $Issues 'upstream_t0_invalid' '/upstream_t0' }
}

function Get-TL1V2WindowSignature {
    param([Parameter(Mandatory)]$Window)
    return @(
        $Window.window_label, $Window.identity_namespace, $Window.display_id, $Window.type,
        $Window.root_status, $Window.root_package, $Window.layer,
        (Get-TL1V2RectSignature $Window.bounds), (Get-TL1V2RectSignature $Window.touchable_bounds),
        $Window.active, $Window.focused
    ) -join '|'
}

function Get-TL1V2FrameSemanticSignature {
    param([Parameter(Mandatory)]$Frame)
    $windows = [string[]]@($Frame.a11y_windows | ForEach-Object { Get-TL1V2WindowSignature $_ })
    [Array]::Sort($windows, [StringComparer]::Ordinal)
    $panes = [string[]]@($Frame.panes | ForEach-Object {
        "$($_.pane_label)|$($_.window_label)|$($_.role)|$(Get-TL1V2RectSignature $_.bounds)|$($_.binding)"
    })
    [Array]::Sort($panes, [StringComparer]::Ordinal)
    $target = $Frame.target
    $titles = [string[]]@($target.title_candidates | ForEach-Object {
        "$($_.label_hash)|$($_.semantic_role)|$($_.source)|$(Get-TL1V2RectSignature $_.bounds)|$($_.window_label)|$($_.pane_label)"
    })
    [Array]::Sort($titles, [StringComparer]::Ordinal)
    $regions = [Collections.Generic.List[string]]::new()
    foreach ($name in @('toolbar_candidates','message_candidates','input_candidates')) {
        foreach ($item in @($target.$name)) {
            $inputSuffix = if ($name -ceq 'input_candidates') {
                "$($item.editable)|$($item.focused)|$($item.editor_fingerprint_hash)"
            } else { 'n/a|n/a|n/a' }
            $regions.Add("$name|$(Get-TL1V2RectSignature $item.bounds)|$($item.window_label)|$($item.pane_label)|$inputSuffix")
        }
    }
    $regionRows = [string[]]$regions.ToArray()
    [Array]::Sort($regionRows, [StringComparer]::Ordinal)
    $displayWidth = if ($null -eq $Frame.display.effective_size) { '<null>' } else { $Frame.display.effective_size.width }
    $displayHeight = if ($null -eq $Frame.display.effective_size) { '<null>' } else { $Frame.display.effective_size.height }
    return @(
        $Frame.display.display_id_status, $Frame.display.display_id,
        $displayWidth, $displayHeight, $Frame.display.orientation,
        $Frame.windows_truncated, ($windows -join ';'), $Frame.panes_truncated, ($panes -join ';'),
        $Frame.nodes_truncated, $target.conversation_window_label,
        $target.conversation_pane_label, ($titles -join ';'), ($regionRows -join ';'),
        $target.focus.status, $target.focus.window_label, $target.focus.input_candidate_label,
        $target.ime.visible, $target.ime.mode, (Get-TL1V2RectSignature $target.ime.bounds),
        $target.ime.editor_fingerprint_hash, $target.ime.binding, $target.ime.target_input_candidate_label
    ) -join '|'
}

function Test-TL1V2FrameSemantics {
    param(
        [Parameter(Mandatory)]$Frame,
        [Parameter(Mandatory)][int]$FrameIndex,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    $path = "/frames/$FrameIndex"
    $token = [string]$Frame.capture.token
    $expectedToken = "c$($FrameIndex + 1)"
    if ($token -cne $expectedToken) {
        Add-TL1V2Issue $Issues 'capture_order_invalid' "$path/capture/token"
    }
    if ([long]$Frame.capture.revision_before -ne [long]$Frame.capture.revision_after -or
        [long]$Frame.capture.revision_before -ne [long]$Frame.capture.layout_revision -or
        [long]$Frame.capture.revision_before -ne [long]$Frame.capture.ime_revision) {
        Add-TL1V2Issue $Issues 'atomic_capture_revision_invalid' "$path/capture"
    }
    $display = $Frame.display
    if ($display.display_id_status -cne 'known' -or $null -eq $display.display_id -or
        $null -eq $display.effective_size) {
        Add-TL1V2Issue $Issues 'display_unknown' "$path/display"
    }
    if ($display.orientation -cne 'landscape' -or $null -eq $display.effective_size -or
        ($null -ne $display.effective_size -and
            [long]$display.effective_size.width -le [long]$display.effective_size.height)) {
        Add-TL1V2Issue $Issues 'not_landscape' "$path/display"
    }

    $windows = @($Frame.a11y_windows)
    if ($Frame.windows_truncated) {
        Add-TL1V2Issue $Issues 'window_inventory_truncated' "$path/windows_truncated"
    }
    $windowMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($window in $windows) {
        $label = [string]$window.window_label
        if ($label -notmatch '\Aaw[1-9][0-9]{0,2}\z' -or $label -match '\Aw[0-9]') {
            Add-TL1V2Issue $Issues 'window_label_invalid' "$path/a11y_windows"
        }
        if ($windowMap.ContainsKey($label)) {
            Add-TL1V2Issue $Issues 'window_label_duplicate' "$path/a11y_windows"
        } else { $windowMap.Add($label, $window) }
        if (-not (Test-TL1V2RectValid $window.bounds) -or
            ($null -ne $window.touchable_bounds -and -not (Test-TL1V2RectValid $window.touchable_bounds))) {
            Add-TL1V2Issue $Issues 'window_geometry_invalid' "$path/a11y_windows/$label"
        }
        if ($display.display_id_status -ceq 'known' -and $window.display_id -ne $display.display_id) {
            Add-TL1V2Issue $Issues 'multi_display_blocked' "$path/a11y_windows/$label/display_id"
        }
    }
    $appWindows = @($windows | Where-Object { $_.type -ceq 'application' })
    if ($appWindows.Count -ne 2) { Add-TL1V2Issue $Issues 'window_count_not_two' "$path/a11y_windows" }
    foreach ($window in $appWindows) {
        if ($window.root_status -cne 'readable' -or $window.root_package -cne 'com.tencent.mm') {
            Add-TL1V2Issue $Issues 'window_root_owner_conflict' "$path/a11y_windows/$($window.window_label)"
        }
    }

    $panes = @($Frame.panes)
    if ($Frame.panes_truncated) {
        Add-TL1V2Issue $Issues 'pane_inventory_truncated' "$path/panes_truncated"
    }
    $paneMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $windowPaneCount = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($pane in $panes) {
        $label = [string]$pane.pane_label
        if ($paneMap.ContainsKey($label)) {
            Add-TL1V2Issue $Issues 'window_pane_bijection_invalid' "$path/panes"
        } else { $paneMap.Add($label, $pane) }
        $windowLabel = [string]$pane.window_label
        if (-not $windowMap.ContainsKey($windowLabel) -or
            $windowMap[$windowLabel].type -cne 'application') {
            Add-TL1V2Issue $Issues 'window_pane_bijection_invalid' "$path/panes/$label/window_label"
            continue
        }
        if (-not $windowPaneCount.ContainsKey($windowLabel)) { $windowPaneCount.Add($windowLabel, 0) }
        $windowPaneCount[$windowLabel]++
        if ($pane.binding -ceq 'unknown' -or -not (Test-TL1V2RectValid $pane.bounds) -or
            -not (Test-TL1V2RectEqual $pane.bounds $windowMap[$windowLabel].bounds)) {
            Add-TL1V2Issue $Issues 'pane_geometry_invalid' "$path/panes/$label"
        }
    }
    if ($panes.Count -ne 2 -or @($panes | Where-Object { $_.role -ceq 'navigation' }).Count -ne 1 -or
        @($panes | Where-Object { $_.role -ceq 'conversation' }).Count -ne 1) {
        Add-TL1V2Issue $Issues 'window_pane_bijection_invalid' "$path/panes"
    }
    foreach ($window in $appWindows) {
        if (-not $windowPaneCount.ContainsKey([string]$window.window_label) -or
            $windowPaneCount[[string]$window.window_label] -ne 1) {
            Add-TL1V2Issue $Issues 'window_pane_bijection_invalid' "$path/panes"
        }
    }

    $target = $Frame.target
    $targetWindow = if ($windowMap.ContainsKey([string]$target.conversation_window_label)) {
        $windowMap[[string]$target.conversation_window_label]
    } else { $null }
    $targetPane = if ($paneMap.ContainsKey([string]$target.conversation_pane_label)) {
        $paneMap[[string]$target.conversation_pane_label]
    } else { $null }
    if ($null -eq $targetWindow -or $null -eq $targetPane -or $targetWindow.type -cne 'application' -or
        $targetWindow.root_package -cne 'com.tencent.mm' -or $targetPane.role -cne 'conversation' -or
        $targetPane.window_label -cne $targetWindow.window_label) {
        Add-TL1V2Issue $Issues 'target_window_pane_missing' "$path/target"
    }

    $nodeMap = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($node in @($Frame.node_observations)) {
        if ($nodeMap.ContainsKey([string]$node.node_label)) {
            Add-TL1V2Issue $Issues 'node_binding_invalid' "$path/node_observations"
        } else { $nodeMap.Add([string]$node.node_label, $node) }
        if (-not $windowMap.ContainsKey([string]$node.window_label) -or
            ($null -ne $node.pane_label -and -not $paneMap.ContainsKey([string]$node.pane_label)) -or
            ($null -ne $node.pane_label -and $paneMap[[string]$node.pane_label].window_label -cne $node.window_label) -or
            -not (Test-TL1V2RectValid $node.bounds) -or
            -not (Test-TL1V2RectContained $node.bounds $windowMap[[string]$node.window_label].bounds)) {
            Add-TL1V2Issue $Issues 'node_binding_invalid' "$path/node_observations/$($node.node_label)"
        }
    }
    if ($Frame.nodes_truncated) { Add-TL1V2Issue $Issues 'node_inventory_truncated' "$path/nodes_truncated" }

    $titles = @($target.title_candidates)
    if ($titles.Count -ne 1 -or @($titles | Where-Object { $_.label_hash -cne $target.expected_title_hash }).Count -gt 0) {
        Add-TL1V2Issue $Issues 'target_title_not_unique' "$path/target/title_candidates"
    }
    foreach ($title in $titles) {
        $titleNode = if ($nodeMap.ContainsKey([string]$title.node_label)) {
            $nodeMap[[string]$title.node_label]
        } else { $null }
        if ($title.capture_token -cne $token -or $null -eq $titleNode -or
            ($null -ne $titleNode -and (
                $titleNode.window_label -cne $title.window_label -or
                $titleNode.pane_label -cne $title.pane_label -or
                -not (Test-TL1V2RectEqual $titleNode.bounds $title.bounds)
            ))) {
            Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/title_candidates"
        }
        if ($title.window_label -cne $target.conversation_window_label) {
            Add-TL1V2Issue $Issues 'title_wrong_window' "$path/target/title_candidates"
        }
        if ($title.pane_label -cne $target.conversation_pane_label) {
            Add-TL1V2Issue $Issues 'title_wrong_pane' "$path/target/title_candidates"
        }
        if ($title.semantic_role -cne 'pane_toolbar_title' -or $null -eq $titleNode -or
            ($null -ne $titleNode -and $titleNode.role -cne 'toolbar_title')) {
            Add-TL1V2Issue $Issues 'title_wrong_role' "$path/target/title_candidates"
        }
        if ($null -eq $targetPane -or -not (Test-TL1V2RectContained $title.bounds $targetPane.bounds)) {
            Add-TL1V2Issue $Issues 'title_geometry_invalid' "$path/target/title_candidates"
        }
    }

    $selected = @{}
    foreach ($entry in @(
            [pscustomobject]@{ Name='toolbar'; Values=@($target.toolbar_candidates) },
            [pscustomobject]@{ Name='message'; Values=@($target.message_candidates) },
            [pscustomobject]@{ Name='input'; Values=@($target.input_candidates) }
        )) {
        if ($entry.Values.Count -eq 0) {
            Add-TL1V2Issue $Issues 'region_candidate_missing' "$path/target/$($entry.Name)_candidates"
        }
        elseif ($entry.Values.Count -gt 1) {
            Add-TL1V2Issue $Issues 'region_candidate_ambiguous' "$path/target/$($entry.Name)_candidates"
        }
        if ($entry.Values.Count -eq 1) { $selected[$entry.Name] = $entry.Values[0] }
        foreach ($candidate in $entry.Values) {
            if ($candidate.capture_token -cne $token) {
                Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/$($entry.Name)_candidates"
            }
            if ($candidate.window_label -cne $target.conversation_window_label) {
                Add-TL1V2Issue $Issues 'cross_window_region' "$path/target/$($entry.Name)_candidates"
            }
            if ($candidate.pane_label -cne $target.conversation_pane_label -or $null -eq $targetPane -or
                -not (Test-TL1V2RectContained $candidate.bounds $targetPane.bounds)) {
                Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/$($entry.Name)_candidates"
            }
            $sourceLabels = if ($entry.Name -ceq 'input') { @($candidate.node_label) } else { @($candidate.source_node_labels) }
            foreach ($nodeLabel in $sourceLabels) {
                if (-not $nodeMap.ContainsKey([string]$nodeLabel) -or
                    $nodeMap[[string]$nodeLabel].window_label -cne $candidate.window_label -or
                    $nodeMap[[string]$nodeLabel].pane_label -cne $candidate.pane_label -or
                    -not (Test-TL1V2RectContained $nodeMap[[string]$nodeLabel].bounds $candidate.bounds)) {
                    Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/$($entry.Name)_candidates"
                }
            }
            if ($entry.Name -ceq 'toolbar') {
                $structuralToolbar = @($sourceLabels | Where-Object {
                        $nodeMap.ContainsKey([string]$_) -and
                        $nodeMap[[string]$_].role -ceq 'container' -and
                        (Test-TL1V2RectEqual $nodeMap[[string]$_].bounds $candidate.bounds)
                    })
                if ($structuralToolbar.Count -ne 1) {
                    Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/toolbar_candidates"
                }
            }
            elseif ($entry.Name -ceq 'message') {
                $messageNodes = @($sourceLabels | Where-Object {
                        $nodeMap.ContainsKey([string]$_) -and
                        $nodeMap[[string]$_].role -ceq 'message_viewport' -and
                        (Test-TL1V2RectEqual $nodeMap[[string]$_].bounds $candidate.bounds)
                    })
                if ($messageNodes.Count -ne 1) {
                    Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/message_candidates"
                }
            }
            else {
                $inputNode = if ($nodeMap.ContainsKey([string]$candidate.node_label)) {
                    $nodeMap[[string]$candidate.node_label]
                } else { $null }
                if ($null -eq $inputNode -or $inputNode.role -cne 'input_editor' -or
                    -not (Test-TL1V2RectEqual $inputNode.bounds $candidate.bounds) -or
                    [bool]$inputNode.editable -ne [bool]$candidate.editable -or
                    [bool]$inputNode.focused -ne [bool]$candidate.focused) {
                    Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/input_candidates"
                }
            }
        }
    }
    if ($selected.ContainsKey('input') -and (-not $selected.input.editable -or
            $null -eq $selected.input.editor_fingerprint_hash)) {
        Add-TL1V2Issue $Issues 'region_binding_invalid' "$path/target/input_candidates"
    }
    if ($selected.ContainsKey('toolbar') -and $titles.Count -eq 1 -and
        -not (Test-TL1V2RectContained $titles[0].bounds $selected.toolbar.bounds)) {
        Add-TL1V2Issue $Issues 'title_geometry_invalid' "$path/target/title_candidates"
    }
    if ($selected.ContainsKey('toolbar') -and $selected.ContainsKey('message') -and $selected.ContainsKey('input')) {
        $toolbar = $selected.toolbar.bounds
        $message = $selected.message.bounds
        $input = $selected.input.bounds
        if ($null -eq $targetPane -or
            [long]$toolbar.left -ne [long]$targetPane.bounds.left -or [long]$toolbar.right -ne [long]$targetPane.bounds.right -or
            [long]$message.left -ne [long]$targetPane.bounds.left -or [long]$message.right -ne [long]$targetPane.bounds.right -or
            [long]$input.left -ne [long]$targetPane.bounds.left -or [long]$input.right -ne [long]$targetPane.bounds.right -or
            [long]$toolbar.top -ne [long]$targetPane.bounds.top -or [long]$toolbar.bottom -ne [long]$message.top -or
            [long]$message.bottom -ne [long]$input.top -or [long]$input.bottom -ne [long]$targetPane.bounds.bottom -or
            -not (Test-TL1V2RectValid $toolbar) -or -not (Test-TL1V2RectValid $message) -or
            -not (Test-TL1V2RectValid $input)) {
            Add-TL1V2Issue $Issues 'region_geometry_invalid' "$path/target"
        }
    }

    $focusedApplicationWindows = @($windows | Where-Object { $_.type -ceq 'application' -and $_.focused })
    $focusedNonApplicationWindows = @($windows | Where-Object { $_.type -cne 'application' -and $_.focused })
    $focusedInputs = @($target.input_candidates | Where-Object { $_.focused })
    $focusInventoryConflict = $focusedNonApplicationWindows.Count -gt 0 -or
        $focusedApplicationWindows.Count -gt 1 -or $focusedInputs.Count -gt 1 -or
        (($focusedApplicationWindows.Count -eq 0) -ne ($focusedInputs.Count -eq 0))
    if ($focusedApplicationWindows.Count -eq 1 -and $focusedInputs.Count -eq 1 -and
        ($focusedApplicationWindows[0].window_label -cne $focusedInputs[0].window_label -or
            $focusedApplicationWindows[0].window_label -cne $target.conversation_window_label -or
            $focusedInputs[0].window_label -cne $target.conversation_window_label)) {
        $focusInventoryConflict = $true
    }
    $focus = $target.focus
    if ($focus.status -ceq 'absent') {
        if ($null -ne $focus.window_label -or $null -ne $focus.input_candidate_label -or
            $focusInventoryConflict -or $focusedApplicationWindows.Count -ne 0 -or
            $focusedNonApplicationWindows.Count -ne 0 -or $focusedInputs.Count -ne 0) {
            Add-TL1V2Issue $Issues 'focus_target_conflict' "$path/target/focus"
        }
    }
    elseif ($focus.status -ceq 'unknown') {
        Add-TL1V2Issue $Issues 'focus_fallback_insufficient' "$path/target/focus"
        if ($focusInventoryConflict) {
            Add-TL1V2Issue $Issues 'focus_target_conflict' "$path/target/focus"
        }
    }
    else {
        $inputMatches = @($target.input_candidates | Where-Object { $_.candidate_label -ceq $focus.input_candidate_label })
        if ($focusInventoryConflict -or $focus.window_label -cne $target.conversation_window_label -or
            $inputMatches.Count -ne 1 -or
            $inputMatches[0].window_label -cne $target.conversation_window_label -or
            -not $inputMatches[0].focused -or $focusedApplicationWindows.Count -ne 1 -or
            $focusedApplicationWindows[0].window_label -cne $target.conversation_window_label) {
            Add-TL1V2Issue $Issues 'focus_target_conflict' "$path/target/focus"
        }
    }

    $ime = $target.ime
    $imeWindows = @($windows | Where-Object { $_.type -ceq 'input_method' })
    foreach ($imeWindowCandidate in $imeWindows) {
        if ($null -ne $imeWindowCandidate.bounds -and
            -not (Test-TL1V2RectValid $imeWindowCandidate.bounds)) {
            Add-TL1V2Issue $Issues 'region_geometry_invalid' `
                "$path/a11y_windows/$($imeWindowCandidate.window_label)/bounds"
        }
    }
    if ($ime.capture_token -cne $token) {
        Add-TL1V2Issue $Issues 'atomic_capture_revision_invalid' "$path/target/ime/capture_token"
    }
    if (-not $ime.visible) {
        if ($Frame.windows_truncated -or $imeWindows.Count -ne 0 -or $ime.mode -cne 'none' -or
            $ime.binding -cne 'not_active' -or $null -ne $ime.bounds -or
            $null -ne $ime.editor_fingerprint_hash -or $null -ne $ime.target_input_candidate_label) {
            Add-TL1V2Issue $Issues 'ime_target_editor_unbound' "$path/target/ime"
        }
    }
    else {
        if ($ime.mode -ceq 'floating') { Add-TL1V2Issue $Issues 'floating_ime_unsupported' "$path/target/ime" }
        if ($null -ne $ime.bounds -and -not (Test-TL1V2RectValid $ime.bounds)) {
            Add-TL1V2Issue $Issues 'region_geometry_invalid' "$path/target/ime/bounds"
        }
        $imeWindow = if ($imeWindows.Count -eq 1) { $imeWindows[0] } else { $null }
        if ($Frame.windows_truncated -or $null -eq $imeWindow -or $null -eq $targetWindow -or
            $display.display_id_status -cne 'known' -or $null -eq $display.display_id -or
            $null -eq $targetWindow.display_id -or $null -eq $imeWindow.display_id -or
            $targetWindow.display_id -ne $display.display_id -or
            $imeWindow.display_id -ne $targetWindow.display_id -or
            -not (Test-TL1V2RectValid $imeWindow.bounds) -or
            -not (Test-TL1V2RectValid $ime.bounds) -or
            -not (Test-TL1V2RectEqual $imeWindow.bounds $ime.bounds)) {
            Add-TL1V2Issue $Issues 'ime_target_editor_unbound' "$path/target/ime"
        }
        $imeInputs = @($target.input_candidates | Where-Object { $_.candidate_label -ceq $ime.target_input_candidate_label })
        if ($ime.mode -cne 'docked' -or $ime.binding -cne 'target_editor' -or $imeInputs.Count -ne 1 -or
            $null -eq $ime.editor_fingerprint_hash -or -not (Test-TL1V2RectValid $ime.bounds) -or
            $ime.editor_fingerprint_hash -cne $imeInputs[0].editor_fingerprint_hash) {
            Add-TL1V2Issue $Issues 'ime_target_editor_unbound' "$path/target/ime"
        }
    }

    if ($null -ne $targetWindow) {
        $occlusionRects = [Collections.Generic.List[object]]::new()
        foreach ($collectionName in @('title_candidates','toolbar_candidates','message_candidates','input_candidates')) {
            foreach ($candidate in @($target.$collectionName | Where-Object {
                        $_.window_label -ceq $target.conversation_window_label -and
                        $_.pane_label -ceq $target.conversation_pane_label
                    })) {
                $occlusionRects.Add($candidate.bounds)
            }
        }
        foreach ($overlay in @($windows | Where-Object {
                    $_.type -in @('accessibility_overlay','system','unknown') -and
                    $null -ne $_.display_id -and $null -ne $targetWindow.display_id -and
                    [long]$_.display_id -eq [long]$targetWindow.display_id -and
                    [long]$_.layer -gt [long]$targetWindow.layer
                })) {
            foreach ($rect in $occlusionRects) {
                if (Test-TL1V2RectsOverlap $overlay.bounds $rect) {
                    Add-TL1V2Issue $Issues 'overlay_target_occlusion' "$path/a11y_windows/$($overlay.window_label)"
                    break
                }
            }
        }
    }
    return Get-TL1V2FrameSemanticSignature $Frame
}

function Test-TL1V2Semantics {
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)]$T0,
        [Parameter(Mandatory)][string]$T0Raw,
        [Parameter(Mandatory)][DateTimeOffset]$ValidationNowUtc,
        [Parameter(Mandatory)][ValidateSet('fixture','trusted_runtime')][string]$OriginMode,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Issues
    )
    if ($Evidence.schema -cne $script:TL1V2Schema -or $Evidence.mode -cne 'diagnostic_only') {
        Add-TL1V2Issue $Issues 'safety_constants_invalid' '/schema'
    }
    if ($OriginMode -ceq 'fixture') {
        if ($Evidence.provenance.kind -cne 'offline_fixture' -or
            $Evidence.upstream_t0.source_kind -cne 'offline_fixture') {
            Add-TL1V2Issue $Issues 'fixture_origin_required' '/provenance'
        }
    }
    elseif ($Evidence.provenance.kind -cne 'gateway_runtime_probe' -or
        $Evidence.upstream_t0.source_kind -cne 'trusted_runtime') {
        Add-TL1V2Issue $Issues 'fixture_origin_required' '/provenance'
    }
    if ($Evidence.provenance.runtime_attested -or $Evidence.route.kind -cne 'probe_only' -or
        $Evidence.route.settings_mutation_allowed -or $Evidence.route.device_action_allowed) {
        Add-TL1V2Issue $Issues 'route_contract_violation' '/route'
    }
    if ($Evidence.layout_accepted -or $Evidence.wechat_layout_verified -or $Evidence.editor_action_ready -or
        $Evidence.p0_capability -cne 'unsupported' -or $Evidence.execution_grant) {
        Add-TL1V2Issue $Issues 'safety_constants_invalid' '/'
    }
    $blockers = @($Evidence.p0_blockers)
    if ($blockers.Count -ne $script:TL1V2RequiredBlockers.Count -or
        @($blockers | Select-Object -Unique).Count -ne $blockers.Count) {
        Add-TL1V2Issue $Issues 'safety_constants_invalid' '/p0_blockers'
    }
    foreach ($blocker in $script:TL1V2RequiredBlockers) {
        if ($blockers -cnotcontains $blocker) { Add-TL1V2Issue $Issues 'safety_constants_invalid' '/p0_blockers' }
    }

    $frames = @($Evidence.frames)
    $firstAt = ConvertFrom-TL1V2Timestamp $frames[0].captured_at
    Test-TL1V2UpstreamT0 $Evidence $T0 $T0Raw $firstAt $Issues
    $previousAt = [DateTimeOffset]::MinValue
    $firstFrameAt = $firstAt
    $previousRevision = 0L
    $minimumIntervalTicks = [long]::MaxValue
    $firstSignature = $null
    $firstWindowLabels = $null
    $firstTargetWindow = $null
    $firstTargetPane = $null
    $captureTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $frames.Count; $index++) {
        $frame = $frames[$index]
        if (-not $captureTokens.Add([string]$frame.capture.token)) {
            Add-TL1V2Issue $Issues 'capture_order_invalid' "/frames/$index/capture/token"
        }
        $at = ConvertFrom-TL1V2Timestamp $frame.captured_at
        if ($null -eq $at) { Add-TL1V2Issue $Issues 'capture_order_invalid' "/frames/$index/captured_at"; continue }
        if ($at -gt $ValidationNowUtc) { Add-TL1V2Issue $Issues 'capture_in_future' "/frames/$index/captured_at" }
        if ($index -gt 0) {
            if ($at -le $previousAt -or [long]$frame.capture.revision_before -le $previousRevision) {
                Add-TL1V2Issue $Issues 'capture_order_invalid' "/frames/$index"
            }
            if ($at -gt $previousAt) {
                $ticks = ($at - $previousAt).Ticks
                if ($ticks -lt $minimumIntervalTicks) { $minimumIntervalTicks = $ticks }
            }
        }
        $signature = Test-TL1V2FrameSemantics $frame $index $Issues
        $labels = [string[]]@($frame.a11y_windows | ForEach-Object { $_.window_label })
        [Array]::Sort($labels, [StringComparer]::Ordinal)
        if ($index -eq 0) {
            $firstSignature = $signature
            $firstWindowLabels = $labels -join "`n"
            # Preserve JSON null as null. Casting here would collapse null to an
            # empty string and make a later null compare unequal to the first
            # frame even though both nullable labels are unchanged.
            $firstTargetWindow = $frame.target.conversation_window_label
            $firstTargetPane = $frame.target.conversation_pane_label
        }
        else {
            if (($labels -join "`n") -cne $firstWindowLabels) {
                Add-TL1V2Issue $Issues 'window_identity_replacement' "/frames/$index/a11y_windows"
            }
            if ($frame.target.conversation_window_label -cne $firstTargetWindow -or
                $frame.target.conversation_pane_label -cne $firstTargetPane) {
                Add-TL1V2Issue $Issues 'target_window_pane_drift' "/frames/$index/target"
            }
            if ($signature -cne $firstSignature) {
                Add-TL1V2Issue $Issues 'capture_semantics_drift' "/frames/$index"
            }
        }
        $previousAt = $at
        $previousRevision = [long]$frame.capture.revision_before
    }
    if ($minimumIntervalTicks -eq [long]::MaxValue -or $minimumIntervalTicks -lt $script:TL1V2MinimumIntervalTicks) {
        Add-TL1V2Issue $Issues 'capture_order_invalid' '/frames'
    }
    if ($previousAt -ne [DateTimeOffset]::MinValue -and
        ($ValidationNowUtc - $previousAt).Ticks -gt $script:TL1V2MaximumAgeTicks) {
        Add-TL1V2Issue $Issues 'capture_stale' '/captured_at'
    }
    if ($firstFrameAt -ne [DateTimeOffset]::MinValue -and
        ($previousAt - $firstFrameAt).Ticks -gt $script:TL1V2MaximumSpanTicks) {
        Add-TL1V2Issue $Issues 'capture_span_exceeded' '/frames'
    }
    if ((ConvertFrom-TL1V2Timestamp $Evidence.captured_at) -ne $previousAt) {
        Add-TL1V2Issue $Issues 'capture_order_invalid' '/captured_at'
    }
    $minimumMs = if ($minimumIntervalTicks -eq [long]::MaxValue) { -1L } else {
        [long][Math]::Floor($minimumIntervalTicks / [double][TimeSpan]::TicksPerMillisecond)
    }
    $allCodes = [string[]]@(Get-TL1V2ReasonCodes $Issues)
    # Producer 只能稳定重算 observation intrinsic reasons。相对实际 UtcNow 的 future/stale
    # 由 consumer 在最终 envelope 中追加，不能反向要求 evidence 预知 validation time。
    $intrinsicCodes = [string[]]@($allCodes | Where-Object {
            $script:TL1V2ConsumerValidationTimeReasons -cnotcontains $_
        } | Sort-Object -Unique)
    # consistency 只描述两帧是否属于同一原子、稳定的 capture 序列，不等同于整份诊断是否可 observed。
    # owner/title/focus/IME 与 validation-time freshness 等阻断可以在 consistency.stable=true 时存在。
    $consistencyCodes = [string[]]@($intrinsicCodes | Where-Object {
            $_ -cin @(
                'atomic_capture_revision_invalid','capture_order_invalid','capture_span_exceeded',
                'window_identity_replacement','target_window_pane_drift','capture_semantics_drift'
            )
        } | Sort-Object -Unique)
    $consistencyStable = $consistencyCodes.Count -eq 0
    if ([long]$Evidence.consistency.sample_count -ne $frames.Count -or
        [long]$Evidence.consistency.minimum_interval_ms -ne $minimumMs -or
        [bool]$Evidence.consistency.stable -ne $consistencyStable -or
        (([string[]]@($Evidence.consistency.reason_codes | Sort-Object -Unique)) -join "`n") -cne
            ($consistencyCodes -join "`n")) {
        Add-TL1V2Issue $Issues 'consistency_declared_mismatch' '/consistency'
    }
    $declaredReasons = [string[]]@($Evidence.reason_codes | Sort-Object -Unique)
    $expectedDeclaredStatus = if ($intrinsicCodes.Count -eq 0) { 'observed' } else { 'blocked' }
    if ($Evidence.diagnostic_status -cne $expectedDeclaredStatus) {
        Add-TL1V2Issue $Issues 'declared_status_mismatch' '/diagnostic_status'
    }
    if (@($intrinsicCodes | Where-Object { $declaredReasons -cnotcontains $_ }).Count -gt 0) {
        Add-TL1V2Issue $Issues 'declared_reasons_incomplete' '/reason_codes'
    }
    if (@($declaredReasons | Where-Object { $intrinsicCodes -cnotcontains $_ }).Count -gt 0) {
        # 包括 evidence 伪造 consumer-owned future/stale；extra reason 不是 producer intrinsic 声明。
        Add-TL1V2Issue $Issues 'declared_status_mismatch' '/reason_codes'
    }
}

function Test-TabletLayoutObservationV2File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [switch]$FixtureMode
    )
    $issues = [Collections.Generic.List[object]]::new()
    $script:TL1V2LastValidationException = $null
    if (-not $FixtureMode) {
        Add-TL1V2Issue $issues 'runtime_producer_unavailable' '/provenance'
        return New-TL1V2ValidationResult $false $false $issues
    }
    try {
        $controlledPath = Resolve-TL1V2ControlledPath $Path $EvidenceRoot $issues
        if ($null -eq $controlledPath) { return New-TL1V2ValidationResult $false $false $issues }
        $raw = Read-TL1V2ControlledUtf8 $controlledPath $issues
        if ($null -eq $raw) { return New-TL1V2ValidationResult $false $false $issues }
        $evidence = ConvertFrom-TL1V2StrictJson $raw $issues -CheckPrivacy
        if ($null -eq $evidence) { return New-TL1V2ValidationResult $false $false $issues }
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $schemaPath = Join-Path $repoRoot 'docs\contracts\tablet-layout-observation-v2.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or
            -not ($raw | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            Add-TL1V2Issue $issues 'json_schema_validation_failed' '/'
            return New-TL1V2ValidationResult $false $false $issues
        }
        # Schema 与语义只读同一 immutable snapshot。
        $snapshotRaw = $evidence | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
        $snapshot = $snapshotRaw | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
        $t0Candidate = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) $script:TL1V2FixedT0FixtureName
        $t0Path = Resolve-TL1V2ControlledPath $t0Candidate $EvidenceRoot $issues
        if ($null -eq $t0Path) { return New-TL1V2ValidationResult $false $false $issues }
        $t0Raw = Read-TL1V2ControlledUtf8 $t0Path $issues
        if ($null -eq $t0Raw) { return New-TL1V2ValidationResult $false $false $issues }
        $t0 = ConvertFrom-TL1V2StrictJson $t0Raw $issues -CheckSyntheticPrivacyCanary
        if ($null -eq $t0) { return New-TL1V2ValidationResult $false $false $issues }
        Test-TL1V2Semantics $snapshot $t0 $t0Raw ([DateTimeOffset]::UtcNow) fixture $issues
        $observed = $issues.Count -eq 0
        return New-TL1V2ValidationResult $true $observed $issues
    }
    catch {
        $script:TL1V2LastValidationException = $_.Exception.ToString()
        Add-TL1V2Issue $issues 'validation_exception' '/'
        return New-TL1V2ValidationResult $false $false $issues
    }
}

function Test-TabletLayoutObservationV2TrustedRuntimeFile {
    <#
    仅供经受控 C1a runner 完成设备/APK/入口绑定后调用。公共 CLI 不暴露此 switch；
    普通非 Fixture 入口仍在读取 caller 路径前返回 runtime_producer_unavailable。
    C1a 只证明 origin，validation envelope 的 runtime_evidence 仍固定 false，留给 A3/C1b 新合同。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedProducerCommitSha,
        [Parameter(Mandatory)][string]$ExpectedProducerArtifactSha256
    )
    $issues = [Collections.Generic.List[object]]::new()
    $script:TL1V2LastValidationException = $null
    if ($ExpectedRunId -cnotmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -or
        $ExpectedProducerCommitSha -cnotmatch '^[0-9a-f]{40}$' -or
        $ExpectedProducerArtifactSha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
        Add-TL1V2Issue $issues 'runtime_producer_unavailable' '/provenance'
        return New-TL1V2ValidationResult $false $false $issues
    }
    try {
        $originBindingValid = $true
        $controlledPath = Resolve-TL1V2ControlledPath $Path $EvidenceRoot $issues
        if ($null -eq $controlledPath) { return New-TL1V2ValidationResult $false $false $issues }
        $raw = Read-TL1V2ControlledUtf8 $controlledPath $issues
        if ($null -eq $raw) { return New-TL1V2ValidationResult $false $false $issues }
        $evidence = ConvertFrom-TL1V2StrictJson $raw $issues -CheckPrivacy
        if ($null -eq $evidence) { return New-TL1V2ValidationResult $false $false $issues }
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $schemaPath = Join-Path $repoRoot 'docs\contracts\tablet-layout-observation-v2.schema.json'
        if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or
            -not ($raw | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
            Add-TL1V2Issue $issues 'json_schema_validation_failed' '/'
            return New-TL1V2ValidationResult $false $false $issues
        }
        $snapshotRaw = $evidence | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
        $snapshot = $snapshotRaw | ConvertFrom-Json -Depth 100 -DateKind String -ErrorAction Stop
        if ($snapshot.run_id -cne $ExpectedRunId -or
            $snapshot.provenance.kind -cne 'gateway_runtime_probe' -or
            $snapshot.provenance.runtime_attested -ne $false -or
            $snapshot.provenance.producer_commit_sha -cne $ExpectedProducerCommitSha -or
            $snapshot.provenance.producer_artifact_sha256 -cne $ExpectedProducerArtifactSha256 -or
            $snapshot.upstream_t0.source_kind -cne 'trusted_runtime' -or
            $snapshot.upstream_t0.run_id -cne $ExpectedRunId) {
            Add-TL1V2Issue $issues 'runtime_producer_unavailable' '/provenance'
            $originBindingValid = $false
        }
        $t0Candidate = Join-Path ([IO.Path]::GetFullPath($EvidenceRoot)) $script:TL1V2FixedT0FixtureName
        $t0Path = Resolve-TL1V2ControlledPath $t0Candidate $EvidenceRoot $issues
        if ($null -eq $t0Path) { return New-TL1V2ValidationResult $false $false $issues }
        $t0Raw = Read-TL1V2ControlledUtf8 $t0Path $issues
        if ($null -eq $t0Raw) { return New-TL1V2ValidationResult $false $false $issues }
        $t0 = ConvertFrom-TL1V2StrictJson $t0Raw $issues -CheckSyntheticPrivacyCanary
        if ($null -eq $t0) { return New-TL1V2ValidationResult $false $false $issues }
        Test-TL1V2Semantics $snapshot $t0 $t0Raw ([DateTimeOffset]::UtcNow) trusted_runtime $issues
        $observed = $issues.Count -eq 0
        $originFailureCodes = @(
            'runtime_producer_unavailable','upstream_t0_invalid','upstream_t0_stale',
            'upstream_t0_hash_mismatch','upstream_t0_producer_mismatch','upstream_t0_device_hash_mismatch',
            'fixture_origin_required','route_contract_violation','safety_constants_invalid',
            'consistency_declared_mismatch','declared_status_mismatch','declared_reasons_incomplete',
            'privacy_contract_violation','raw_identity_persisted','chat_plaintext_persisted',
            'chat_content_digest_persisted','validation_exception'
        )
        if (@($issues | Where-Object { $originFailureCodes -ccontains [string]$_.code }).Count -gt 0) {
            $originBindingValid = $false
        }
        # C1a 不允许把 runtime origin proof 提升为 runtime acceptance。
        return New-TL1V2ValidationResult $originBindingValid $observed $issues
    }
    catch {
        $script:TL1V2LastValidationException = $_.Exception.ToString()
        Add-TL1V2Issue $issues 'validation_exception' '/'
        return New-TL1V2ValidationResult $false $false $issues
    }
}
