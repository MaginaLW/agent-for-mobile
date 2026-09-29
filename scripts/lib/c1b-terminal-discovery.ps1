#Requires -Version 7.6
# Completed-run evidence only. This module never launches a runner, ADB, or a provider.

function Assert-C1bTd([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "C1b terminal discovery: $Message" }
}

function Get-C1bTdHash([byte[]]$Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Assert-C1bTdExactKeys($Value,[string[]]$Keys,[string]$Name) {
    Assert-C1bTd ($Value -is [Collections.IDictionary] -and $Value.Count -eq $Keys.Count) "$Name closed object required."
    foreach ($key in $Keys) { Assert-C1bTd ($Value.Contains($key)) "$Name required property absent." }
}

function ConvertFrom-C1bTdJson([byte[]]$Bytes) {
    $raw=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    Assert-C1bTd (-not $raw.StartsWith([char]0xfeff) -and -not $raw.Contains([char]0)) 'JSON BOM/NUL rejected.'
    $document=[Text.Json.JsonDocument]::Parse($raw)
    try {
        function Check-C1bTdNames([Text.Json.JsonElement]$Node) {
            if ($Node.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $Node.EnumerateObject()) {
                    Assert-C1bTd ($names.Add($property.Name)) 'Duplicate JSON property.'
                    Check-C1bTdNames $property.Value
                }
            } elseif ($Node.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Node.EnumerateArray()) { Check-C1bTdNames $item }
            }
        }
        Check-C1bTdNames $document.RootElement
        Assert-C1bTd ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object) 'JSON object required.'
    } finally { $document.Dispose() }
    return ConvertFrom-Json -InputObject $raw -AsHashtable -Depth 100 -DateKind String
}

function Get-C1bTerminalDiscoverySourcePaths {
    return @(
        'scripts/read-tablet-layout-c1b-discovery-evidence.ps1',
        'scripts/lib/tablet-layout-c1b-discovery-consumer.ps1',
        'scripts/lib/tablet-layout-c1a.ps1',
        'scripts/lib/tablet-layout-observation-v2-validator.ps1',
        'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1',
        'scripts/lib/tablet-layout-c1b.ps1',
        'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1',
        'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json'
    )
}

function Assert-C1bTdOrdinaryPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    Assert-C1bTd ([StringComparer]::OrdinalIgnoreCase.Equals($Path,$full)) 'Canonical absolute path required.'
    $cursor=$full
    while (-not [string]::IsNullOrEmpty($cursor)) {
        Assert-C1bTd (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Reparse path rejected.'
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Resolve-C1bTdRelativePath([string]$Root,[string]$Relative,[string]$Prefix='') {
    Assert-C1bTd ($Relative -cmatch '^[a-zA-Z0-9._/-]+$' -and -not [IO.Path]::IsPathRooted($Relative) -and
        $Relative -notmatch '(^|/)\.\.?(/|$)' -and -not $Relative.Contains('//')) 'Unsafe repository relative path.'
    if ($Prefix) { Assert-C1bTd ($Relative.StartsWith($Prefix,[StringComparison]::Ordinal)) 'Evidence path outside allowed namespace.' }
    $full=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    Assert-C1bTd ($full.StartsWith($Root.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'Repository path escaped.'
    return $full
}

function New-C1bTerminalDiscoverySourcePins {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{40}$')][string]$ExpectedCommitSha)
    # Preparation computes actual raw bytes. The caller freezes this JSON and its hash
    # only after the candidate has been independently established; this is not a Git check.
    $root=[IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/')
    $sources=[ordered]@{}
    foreach ($relative in (Get-C1bTerminalDiscoverySourcePaths)) {
        $path=Resolve-C1bTdRelativePath $root $relative
        Assert-C1bTdOrdinaryPath $path
        $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            Assert-C1bTd ($stream.Length -in 1..4194304) 'Source length outside bounds.'
            $bytes=[byte[]]::new([int]$stream.Length);$stream.ReadExactly($bytes)
            $sources[$relative]=[ordered]@{byte_length=$bytes.Length;sha256=(Get-C1bTdHash $bytes)}
        } finally { $stream.Dispose() }
    }
    $schemaRelative='docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json'
    $schemaPath=Resolve-C1bTdRelativePath $root $schemaRelative
    Assert-C1bTdOrdinaryPath $schemaPath
    $schemaBytes=[IO.File]::ReadAllBytes($schemaPath)
    return [ordered]@{schema='c1b-terminal-discovery-source-pins/v1';expected_commit_sha=$ExpectedCommitSha;
        sources=$sources;identity_schema_pin=[ordered]@{path=$schemaRelative;byte_length=$schemaBytes.Length;sha256=(Get-C1bTdHash $schemaBytes)}}
}

function Add-C1bTdHeldDirectory($Context,[string]$Path) {
    Assert-C1bTdOrdinaryPath $Path
    foreach ($parent in (Get-TL1C1bRealBuildSmokeOrdinaryDirectoryChain $Path)) {
        if ($Context.Directories.ContainsKey($parent)) { continue }
        $handle=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenDirectoryDenyDelete($parent)
        $entry=[pscustomobject]@{Path=$parent;Handle=$handle;Identity=$null}
        $Context.Directories.Add($parent,$entry)
        $entry.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($handle)
        Assert-TL1C1bRealBuildSmokeHeldDirectoryIdentity $entry.Identity
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $handle $parent
    }
}

function Add-C1bTdHeldFile($Context,[string]$Path,[string]$Sha256,[long]$ByteLength=-1,[switch]$AllowEmpty) {
    Assert-C1bTd ($Sha256 -cmatch '^[0-9a-f]{64}$') 'Raw SHA256 required.'
    Assert-C1bTdOrdinaryPath $Path
    Add-C1bTdHeldDirectory $Context ([IO.Path]::GetDirectoryName($Path))
    $handle=[TL1C1bRealBuildSmokeFileIdentityV1]::OpenFileReadNoFollowDenyWriteDelete($Path)
    $entry=[pscustomobject]@{Path=$Path;Handle=$handle;Stream=$null;Identity=$null;Bytes=$null;Hash=$Sha256}
    $Context.Files.Add($entry)
    $entry.Stream=[IO.FileStream]::new($handle,[IO.FileAccess]::Read,4096,$false)
    $entry.Identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($handle)
    Assert-TL1C1bRealBuildSmokeHeldFileIdentity $entry.Identity $entry.Stream.Length
    Assert-TL1C1bRealBuildSmokeHandleFinalPath $handle $Path
    $minimum=if($AllowEmpty){0}else{1}
    Assert-C1bTd ($entry.Stream.Length -ge $minimum -and $entry.Stream.Length -le 4194304 -and
        ($ByteLength -lt 0 -or $entry.Stream.Length -eq $ByteLength)) 'Held input length differs.'
    $entry.Bytes=[byte[]]::new([int]$entry.Stream.Length);$entry.Stream.ReadExactly($entry.Bytes)
    Assert-C1bTd ((Get-C1bTdHash $entry.Bytes) -ceq $Sha256) 'Held input hash differs.'
    Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $Path $entry.Identity $entry.Bytes.Length
    return $entry
}

function Assert-C1bTdContextBound($Context) {
    foreach ($entry in $Context.Directories.Values) { Assert-TL1C1bRealBuildSmokeDirectoryPathMatchesHeld $entry }
    foreach ($entry in $Context.Files) {
        $identity=[TL1C1bRealBuildSmokeFileIdentityV1]::Read($entry.Handle)
        Assert-TL1C1bRealBuildSmokeHeldFileIdentity $identity $entry.Bytes.Length
        Assert-C1bTd ($identity.StableId -ceq $entry.Identity.StableId) 'Held input identity changed.'
        Assert-TL1C1bRealBuildSmokeHandleFinalPath $entry.Handle $entry.Path
        Assert-TL1C1bRealBuildSmokePathMatchesHeldFile $entry.Path $identity $entry.Bytes.Length
        $entry.Stream.Position=0
        Assert-C1bTd ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($entry.Stream)).ToLowerInvariant() -ceq $entry.Hash) 'Held input bytes changed.'
    }
}

function Close-C1bTerminalDiscoveryContext($Context) {
    $failures=[Collections.Generic.List[Exception]]::new()
    for ($index=$Context.Files.Count-1;$index -ge 0;$index--) {
        $entry=$Context.Files[$index]
        try { if ($null -ne $entry.Stream) { $entry.Stream.Dispose() } else { $entry.Handle.Dispose() } } catch { $failures.Add($_.Exception) }
        if ($null -ne $entry.Bytes) { [Array]::Clear($entry.Bytes,0,$entry.Bytes.Length) }
    }
    $directories=@($Context.Directories.Values)
    for ($index=$directories.Count-1;$index -ge 0;$index--) { try { $directories[$index].Handle.Dispose() } catch { $failures.Add($_.Exception) } }
    if ($failures.Count) { throw [AggregateException]::new('Held input cleanup failed.',$failures.ToArray()) }
}

function New-C1bTerminalDiscoveryContext {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{40}$')][string]$ExpectedCommitSha,
        [Parameter(Mandatory)]$SourcePins)
    $root=[IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/')
    Assert-C1bTdOrdinaryPath $root
    Assert-C1bTdExactKeys $SourcePins @('schema','expected_commit_sha','sources','identity_schema_pin') 'source pins'
    Assert-C1bTd ($SourcePins.schema -ceq 'c1b-terminal-discovery-source-pins/v1' -and $SourcePins.expected_commit_sha -ceq $ExpectedCommitSha) 'Source pin candidate differs.'
    $paths=Get-C1bTerminalDiscoverySourcePaths
    Assert-C1bTd ($SourcePins.sources.Count -eq $paths.Count) 'Exactly eight original source pins required.'
    foreach ($path in $paths) {
        Assert-C1bTd ($SourcePins.sources.Contains($path)) 'Required source pin absent.'
        $pin=$SourcePins.sources[$path]
        Assert-C1bTdExactKeys $pin @('byte_length','sha256') 'source pin'
        Assert-C1bTd ($pin.sha256 -is [string] -and $pin.sha256 -cmatch '^[0-9a-f]{64}$' -and
            ($pin.byte_length -is [int] -or $pin.byte_length -is [long]) -and $pin.byte_length -ge 1 -and $pin.byte_length -le 4194304) 'Invalid source pin.'
    }
    $strictPath=Resolve-C1bTdRelativePath $root 'scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1'
    $strictPin=$SourcePins.sources['scripts/lib/tablet-layout-c1b-real-build-smoke-verifier.ps1']
    Assert-C1bTdOrdinaryPath $strictPath
    $bootstrap=[IO.File]::Open($strictPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $context=[pscustomobject]@{Root=$root;Commit=$ExpectedCommitSha;Pins=$SourcePins;
        Files=[Collections.Generic.List[object]]::new();Directories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)}
    try {
        Assert-C1bTd ($bootstrap.Length -eq $strictPin.byte_length) 'Native bootstrap length differs.'
        $bytes=[byte[]]::new([int]$bootstrap.Length);$bootstrap.ReadExactly($bytes)
        Assert-C1bTd ((Get-C1bTdHash $bytes) -ceq $strictPin.sha256) 'Native bootstrap hash differs.'
        if ($null -eq ('TL1C1bRealBuildSmokeFileIdentityV1' -as [type])) {
            # Dot source in module script scope so contexts keep the same verified native helpers.
            $nativeText=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            . ([scriptblock]::Create($nativeText))
            $nativeTokens=$null;$nativeErrors=$null
            $nativeAst=[Management.Automation.Language.Parser]::ParseInput($nativeText,[ref]$nativeTokens,[ref]$nativeErrors)
            Assert-C1bTd ($nativeErrors.Count -eq 0) 'Native source Parser rejected.'
            foreach ($definition in $nativeAst.EndBlock.Statements) {
                if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
                    Set-Item -Path ('function:script:'+$definition.Name) -Value (Get-Item -LiteralPath ('function:'+$definition.Name)).ScriptBlock
                }
            }
            $script:C1bTdNativeHash=$strictPin.sha256
        } else {
            Assert-C1bTd ((Get-Variable C1bTdNativeHash -Scope Script -ErrorAction SilentlyContinue) -and $script:C1bTdNativeHash -ceq $strictPin.sha256) 'Native authority was loaded outside this source binding.'
        }
        foreach ($relative in $paths) {
            $pin=$SourcePins.sources[$relative]
            [void](Add-C1bTdHeldFile $context (Resolve-C1bTdRelativePath $root $relative) $pin.sha256 $pin.byte_length)
        }
        $schemaPin=$SourcePins.identity_schema_pin
        Assert-C1bTdExactKeys $schemaPin @('path','byte_length','sha256') 'identity schema pin'
        Assert-C1bTd ($schemaPin.path -ceq 'docs/contracts/tablet-layout-c1b-sidecar-v1.schema.json' -and
            $schemaPin.sha256 -is [string] -and $schemaPin.sha256 -cmatch '^[0-9a-f]{64}$' -and
            ($schemaPin.byte_length -is [int] -or $schemaPin.byte_length -is [long]) -and $schemaPin.byte_length -ge 1 -and $schemaPin.byte_length -le 4194304) 'Identity schema source differs.'
        [void](Add-C1bTdHeldFile $context (Resolve-C1bTdRelativePath $root $schemaPin.path) $schemaPin.sha256 $schemaPin.byte_length)
        Assert-C1bTdContextBound $context
        return $context
    } catch {
        $primary=$_.Exception
        try { Close-C1bTerminalDiscoveryContext $context } catch { throw [AggregateException]::new('Context setup and cleanup failed.',[Exception[]]@($primary,$_.Exception)) }
        throw $primary
    } finally { $bootstrap.Dispose() }
}

function Get-C1bTerminalDiscoveryIdentity {
    [CmdletBinding()]param([Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('success','failed','needs-user',IgnoreCase=$false)][string]$TerminalStatus,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EvidenceSources,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$RunnerStdoutBytes,
        [switch]$CheckpointPrePromotionVerified)
    $stdout=[Text.UTF8Encoding]::new($false,$true).GetString($RunnerStdoutBytes)
    foreach ($relative in @('scripts/lib/tablet-layout-c1a.ps1','scripts/lib/tablet-layout-observation-v2-validator.ps1',
        'scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1','scripts/lib/tablet-layout-c1b.ps1','scripts/lib/tablet-layout-c1b-discovery-consumer.ps1')) {
        $held=@($Context.Files | Where-Object { $_.Path -eq (Resolve-C1bTdRelativePath $Context.Root $relative) })[0]
        . ([scriptblock]::Create([Text.UTF8Encoding]::new($false,$true).GetString($held.Bytes)))
    }
    $failureReferences=[Collections.Generic.List[object]]::new()
    $checkpointReferences=[Collections.Generic.List[object]]::new()
    foreach ($line in @($stdout -split '\r?\n')) {
        if ($line.StartsWith('C1b discovery evidence: ',[StringComparison]::Ordinal)) {
            $match=[regex]::Match($line,'^C1b discovery evidence: checkpoint=(before_install|after_capture); path=(docs/runs/evidence/[a-zA-Z0-9._/-]+); sha256=(sha256:[0-9a-f]{64})$')
            Assert-C1bTd ($match.Success) 'Malformed current checkpoint publication pointer.'
            $checkpointReferences.Add([ordered]@{checkpoint=$match.Groups[1].Value;path=$match.Groups[2].Value;sha256=$match.Groups[3].Value})
        }
        if (-not $line.StartsWith('C1b failure evidence reference: ',[StringComparison]::Ordinal)) { continue }
        $reference=ConvertFrom-C1bTdJson ([Text.UTF8Encoding]::new($false,$true).GetBytes($line.Substring(32)))
        Assert-C1bTdExactKeys $reference @('schema','attempt_id','run_id','expected_commit_sha','kind','path','bytes','sha256') 'failure reference'
        Assert-C1bTd ($reference.schema -ceq 'tablet-layout-c1b-failure-reference/v1' -and
            $reference.expected_commit_sha -ceq $Context.Commit -and $reference.kind -cin @('run_failure','attempt_failure') -and
            $reference.sha256 -cmatch '^[0-9a-f]{64}$' -and ($reference.bytes -is [int] -or $reference.bytes -is [long]) -and
            $reference.bytes -in 1..65536 -and $reference.attempt_id -cmatch '^[a-z0-9][a-z0-9._-]{0,79}$') 'Failure reference closed bindings differ.'
        $failureReferences.Add($reference)
    }
    Assert-C1bTd ($failureReferences.Count -le 1) 'Multiple current failure publication references are ambiguous.'
    Assert-C1bTd ($checkpointReferences.Count -le 2 -and @($checkpointReferences | ForEach-Object { $_.path } | Select-Object -Unique).Count -eq $checkpointReferences.Count) 'Ambiguous current checkpoint publication references.'
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $attempt=$null;$run=$null;$runKnown=$false;$sources=[Collections.Generic.List[object]]::new()
    foreach ($source in $EvidenceSources) {
        Assert-C1bTdExactKeys $source @('kind','path','sha256','byte_length') 'identity source'
        Assert-C1bTd ($source.kind -is [string] -and $source.kind -cin @('sidecar','run_failure','attempt_failure','checkpoint') -and
            $source.path -is [string] -and $source.sha256 -is [string] -and $source.sha256 -cmatch '^(sha256:)?[0-9a-f]{64}$' -and
            ($source.byte_length -is [int] -or $source.byte_length -is [long]) -and $source.byte_length -ge 1 -and $source.byte_length -le 4194304) 'Unknown or untyped identity source.'
        Assert-C1bTd ($seen.Add($source.path)) 'Duplicate identity source.'
        $path=Resolve-C1bTdRelativePath $Context.Root $source.path 'docs/runs/evidence/'
        $pin=([string]$source.sha256) -replace '^sha256:',''
        $held=Add-C1bTdHeldFile $Context $path $pin ([long]$source.byte_length)
        $value=ConvertFrom-C1bTdJson $held.Bytes
        $raw=[Text.UTF8Encoding]::new($false,$true).GetString($held.Bytes)
        # Match the actual publication pointer. Neither timestamps nor names select an identity.
        if ($source.kind -ceq 'sidecar') {
            $published=@([regex]::Matches($stdout,'(?m)^T-L1 C1b 受控只读采集完成：([^\r\n]+)\r?$'))
            Assert-C1bTd ($TerminalStatus -ceq 'success' -and $published.Count -eq 1 -and
                [StringComparer]::OrdinalIgnoreCase.Equals($published[0].Groups[1].Value,$path)) 'Sidecar lacks current runner publication binding.'
            $schema=Resolve-C1bTdRelativePath $Context.Root $Context.Pins.identity_schema_pin.path
            Assert-C1bTd ($raw | Test-Json -SchemaFile $schema -ErrorAction Stop) 'Sidecar schema rejected.'
            Assert-TL1C1bSidecarCrossBindings (ConvertFrom-TL1C1bClosedJson $raw)
            Assert-C1bTd ($value.expected_commit_sha -ceq $Context.Commit) 'Sidecar candidate differs.'
            $id=$value.run_id;$candidateRun=$id;$known=$true
            $expectedPath="docs/runs/evidence/$id/tablet-layout-c1b/tablet-layout-c1b-sidecar-v1.json"
        } else {
            if ($source.kind -ceq 'checkpoint') {
                $line="C1b discovery evidence: checkpoint=$($value.checkpoint); path=$($source.path); sha256=sha256:$pin"
                Assert-C1bTd (@($stdout -split '\r?\n' | Where-Object { $_ -ceq $line }).Count -eq 1) 'Identity source lacks one current runner raw publication pointer.'
            } else {
                Assert-C1bTd ($failureReferences.Count -eq 1 -and $failureReferences[0].kind -ceq $source.kind -and
                    $failureReferences[0].path -ceq $source.path -and $failureReferences[0].sha256 -ceq $pin -and
                    $failureReferences[0].bytes -eq $held.Bytes.Length) 'Identity source lacks one current runner raw publication pointer.'
            }
            if ($source.kind -ceq 'run_failure') {
                Assert-C1bTd ($TerminalStatus -ceq 'failed') 'Run failure contradicts terminal status.'
                Assert-TL1C1bFailureEvidence (ConvertFrom-TL1C1bClosedJson $raw)
                $id=$value.run_id;$candidateRun=$id;$known=$true
                $expectedPath="docs/runs/evidence/$id/tablet-layout-c1b/tablet-layout-c1b-failure.json"
            } elseif ($source.kind -ceq 'attempt_failure') {
                Assert-C1bTd ($TerminalStatus -ceq 'failed' -and $value.expected_commit_sha -ceq $Context.Commit -and $null -eq $value.run_id) 'Attempt failure candidate/terminal/run differs.'
                $schema=Resolve-C1bTdRelativePath $Context.Root 'docs/contracts/tablet-layout-c1b-attempt-failure-v1.schema.json'
                Assert-C1bTd ($raw | Test-Json -SchemaFile $schema -ErrorAction Stop) 'Attempt failure schema rejected.'
                Assert-TL1C1bAttemptFailureCrossBindings (ConvertFrom-TL1C1bClosedJson $raw)
                $id=$value.attempt_id;$candidateRun=$null;$known=$true
                $expectedPath="docs/runs/evidence/tablet-layout-c1b-attempt-$id.json"
            } else {
                $id=$value.attempt_id
                Assert-C1bTd ($value.expected_commit_sha -ceq $Context.Commit -and $value.checkpoint -cin @('before_install','after_capture')) 'Checkpoint candidate/name differs.'
                Assert-C1bTdExactKeys $value @('schema','attempt_id','checkpoint','expected_commit_sha','recorded_at_utc',
                    'discovery','server','server_diagnostic_available','diagnostic_only','device_acceptance_verified','cleanup_verified_by_this_record') 'checkpoint'
                Assert-C1bTd ($value.schema -ceq 'tablet-layout-c1b-device-discovery-evidence/v1' -and
                    $value.server_diagnostic_available -is [bool] -and $value.server_diagnostic_available -eq ($null -ne $value.server) -and
                    $value.diagnostic_only -is [bool] -and $value.diagnostic_only -and $value.device_acceptance_verified -is [bool] -and
                    -not $value.device_acceptance_verified -and $value.cleanup_verified_by_this_record -is [bool] -and -not $value.cleanup_verified_by_this_record) 'Checkpoint closed diagnostic claims differ.'
                Assert-TL1C1bConsumerTime $value.recorded_at_utc 'checkpoint'
                $closed=ConvertFrom-TL1C1bClosedJson $raw
                Assert-TL1C1bConsumerDiscovery $closed.discovery
                Assert-TL1C1bConsumerServer $closed.server
                $candidateRun=$null;$known=($TerminalStatus -ceq 'needs-user' -and $CheckpointPrePromotionVerified)
                $expectedPath="docs/runs/evidence/tablet-layout-c1b-discovery-$id-$($value.checkpoint).json"
            }
        }
        Assert-C1bTd ($id -is [string] -and $id -cmatch '^[a-z0-9][a-z0-9._-]{0,79}$' -and $source.path -ceq $expectedPath) 'Record internal identity/path differs.'
        if ($source.kind -cin @('run_failure','attempt_failure')) {
            $reference=$failureReferences[0]
            Assert-C1bTd ($reference.attempt_id -ceq $id -and
                (($null -eq $candidateRun -and $null -eq $reference.run_id) -or ($null -ne $candidateRun -and $reference.run_id -ceq $candidateRun))) 'Failure publication internal attempt/run differs from raw record.'
        }
        if ($null -ne $attempt) { Assert-C1bTd ($attempt -ceq $id) 'Current publication sources disagree on internal attempt.' } else { $attempt=$id }
        if ($known) {
            if ($runKnown) { Assert-C1bTd (($null -eq $run -and $null -eq $candidateRun) -or ($null -ne $run -and $run -ceq $candidateRun)) 'Publication sources disagree on promoted run.' }
            $run=$candidateRun;$runKnown=$true
        }
        $sources.Add([ordered]@{kind=$source.kind;path=$source.path;sha256='sha256:'+$pin;byte_length=$held.Bytes.Length})
    }
    Assert-C1bTdContextBound $Context
    Assert-C1bTd ($failureReferences.Count -eq @($sources | Where-Object { $_.kind -cin @('run_failure','attempt_failure') }).Count) 'Current failure reference omitted from identity sources.'
    Assert-C1bTd ($checkpointReferences.Count -eq @($sources | Where-Object { $_.kind -ceq 'checkpoint' }).Count) 'Current checkpoint reference omitted from identity sources.'
    $verified=($null -ne $attempt -and $runKnown)
    return [ordered]@{schema='c1b-terminal-discovery-identity/v1';status=if($verified){'verified'}else{'unavailable'};
        expected_commit_sha=$Context.Commit;attempt_id=$attempt;run_id=$run;run_id_knowledge=if($runKnown){'known'}else{'unknown'};
        identity_verified_from_current_evidence=$verified;sources=$sources.ToArray();
        unavailable_reason=if($verified){$null}elseif($null -eq $attempt){'no_current_identity_record'}else{'run_promotion_unknown'}}
}

function Assert-C1bTdTerminalAuthority($Context,$Observation,$Terminal,$Binding,[string]$BindingSha256) {
    # Existing v1 envelopes retain reviewer metadata. Extra metadata is ignored;
    # every field used to authorize discovery is mandatory and strictly typed.
    # Closed maps: source pins, identity, references, records and process receipts.
    Assert-C1bTd ($Observation -is [Collections.IDictionary] -and $Terminal -is [Collections.IDictionary] -and $Binding -is [Collections.IDictionary]) 'Authority envelopes must be objects.'
    Assert-C1bTd ($Observation.errors -is [array]) 'Observer errors must be an actual array.'
    foreach ($name in @('wrapper_started')) { Assert-C1bTd ($Observation[$name] -is [bool]) 'Observer boolean type differs.' }
    foreach ($name in @('wrapper_launch_call_count','automatic_wrapper_retry_count')) {
        Assert-C1bTd ($Observation[$name] -is [int] -or $Observation[$name] -is [long]) 'Observer counter type differs.'
    }
    Assert-C1bTd ($Observation.schema -ceq 'c1b-device-external-process-observation/v1' -and $Observation.expected_commit_sha -ceq $Context.Commit) 'Current observer required.'
    Assert-C1bTd ($Observation.observation_status -ceq 'observed' -and $Observation.wrapper_started -eq $true -and
        $Observation.wrapper_launch_call_count -eq 1 -and $Observation.automatic_wrapper_retry_count -eq 0 -and $Observation.errors.Count -eq 0) 'Runner observation incomplete or retried.'
    Assert-C1bTd ($Observation.binding_sha256 -ceq $BindingSha256 -and $Observation.expected_binding_sha256 -ceq $BindingSha256 -and
        $Binding.schema -ceq 'c1b-device-root-preparation-binding/v1' -and $Binding.commit_sha -ceq $Context.Commit -and
        $Binding.runner_sha256 -is [string] -and $Binding.runner_sha256 -cmatch '^[0-9a-f]{64}$' -and
        [StringComparer]::OrdinalIgnoreCase.Equals($Binding.repo_root,$Context.Root)) 'Current binding raw pin/candidate/root differs.'
    foreach ($name in @('observed_runner_exit','observed_wrapper_exit','native_wrapper_exit','runner_pid','wrapper_pid')) {
        Assert-C1bTd ($Observation[$name] -is [int] -or $Observation[$name] -is [long]) 'Observed process tuple must contain actual integers.'
    }
    Assert-C1bTd ($Observation.runner_pid -gt 0 -and $Observation.wrapper_pid -gt 0 -and
        $Observation.native_wrapper_exit -eq $Observation.observed_wrapper_exit) 'Ended wrapper/runner tuple required.'
    Assert-C1bTd ($Terminal.schema -ceq 'c1b-device-terminal-readback/v1' -and $Terminal.verification_status -ceq 'verified' -and
        $Terminal.expected_commit_sha -ceq $Context.Commit -and $Terminal.cleanup_failure_count -eq 0 -and
        $Terminal.readback_external_process_invocation_count -eq 0 -and $Terminal.readback_device_invocation_count -eq 0) 'Verified read-only terminal required.'
    foreach ($name in @('cleanup_failure_count','readback_external_process_invocation_count','readback_device_invocation_count','observed_runner_exit',
        'runner_exit','observed_outer_exit','observed_runner_pid','runner_pid','stdout_byte_length','stderr_byte_length')) {
        Assert-C1bTd ($Terminal[$name] -is [int] -or $Terminal[$name] -is [long]) 'Terminal counter/process/raw length type differs.'
    }
    Assert-C1bTd ($Terminal.observed_runner_exit -eq $Observation.observed_runner_exit -and $Terminal.runner_exit -eq $Observation.observed_runner_exit -and
        $Terminal.observed_outer_exit -eq $Observation.observed_wrapper_exit -and $Terminal.observed_runner_pid -eq $Observation.runner_pid -and
        $Terminal.runner_pid -eq $Observation.runner_pid -and $Terminal.terminal_status -cin @('success','failed','needs-user')) 'Terminal/observer process tuple differs.'
    $expectedExit=switch ($Terminal.terminal_status) { success {0} failed {1} 'needs-user' {2} }
    Assert-C1bTd ($Observation.observed_runner_exit -eq $expectedExit) 'Terminal status/actual exit differs.'
}

function Read-C1bTerminalDiscoveryAuthority {
    [CmdletBinding()]param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$TerminalReadbackPath,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$TerminalReadbackSha256,
        [Parameter(Mandatory)][string]$ReceiptRoot,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ObservationSha256,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ExpectedBindingSha256)
    $receipt=[IO.Path]::GetFullPath($ReceiptRoot).TrimEnd('\','/')
    $receiptRelative=[IO.Path]::GetRelativePath($Context.Root,$receipt).Replace('\','/')
    Assert-C1bTd ($receiptRelative -cmatch ('^\.checks/c1b-device-once/'+$Context.Commit.Substring(0,7)+'/[a-z0-9][a-z0-9._-]{0,79}$')) 'Current candidate receipt namespace required.'
    Add-C1bTdHeldDirectory $Context $receipt
    $observation=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context (Join-Path $receipt 'external-process-observation.json') $ObservationSha256).Bytes
    $terminal=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context $TerminalReadbackPath $TerminalReadbackSha256).Bytes
    $binding=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context (Join-Path $receipt 'binding.json') $ExpectedBindingSha256).Bytes
    Assert-C1bTdTerminalAuthority $Context $observation $terminal $binding $ExpectedBindingSha256
    Assert-C1bTd ($binding.attempt -is [string] -and $binding.attempt -ceq [IO.Path]::GetFileName($receipt)) 'Receipt namespace differs from binding; it is never the runner internal AttemptId.'
    foreach ($name in @('reservation_sha256','exit_receipt_sha256','stdout_sha256','stderr_sha256')) {
        Assert-C1bTd ($terminal[$name] -is [string] -and $terminal[$name] -cmatch '^sha256:[0-9a-f]{64}$') 'Terminal raw receipt/stream pin missing.'
    }
    $once=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context (Join-Path $receipt 'reservation.json') $terminal.reservation_sha256.Substring(7)).Bytes
    $exitRecord=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context (Join-Path $receipt 'exit.json') $terminal.exit_receipt_sha256.Substring(7)).Bytes
    Assert-C1bTdExactKeys $once @('schema','commit_sha','runner_sha256','started_at_utc','automatic_retry_count') 'runner reservation'
    Assert-C1bTdExactKeys $exitRecord @('schema','commit_sha','runner_sha256','runner_started','runner_pid','runner_exit_code','wrapper_failure',
        'started_at_utc','completed_at_utc','automatic_retry_count','success_requires_runner_evidence_validation') 'runner exit receipt'
    Assert-C1bTd ($once.automatic_retry_count -is [int] -or $once.automatic_retry_count -is [long]) 'Runner reservation counter type differs.'
    foreach ($name in @('automatic_retry_count','runner_pid','runner_exit_code')) {
        Assert-C1bTd ($exitRecord[$name] -is [int] -or $exitRecord[$name] -is [long]) 'Runner exit receipt counter/process type differs.'
    }
    Assert-C1bTd ($once.schema -ceq 'c1b-device-cli-once/v1' -and $exitRecord.schema -ceq 'c1b-device-cli-exit/v1' -and
        $once.commit_sha -ceq $Context.Commit -and $exitRecord.commit_sha -ceq $Context.Commit -and
        $once.runner_sha256 -ceq $binding.runner_sha256 -and $exitRecord.runner_sha256 -ceq $binding.runner_sha256 -and
        $once.automatic_retry_count -eq 0 -and $exitRecord.automatic_retry_count -eq 0 -and
        $exitRecord.runner_started -is [bool] -and $exitRecord.runner_started -and $null -eq $exitRecord.wrapper_failure -and
        $exitRecord.success_requires_runner_evidence_validation -is [bool] -and $exitRecord.success_requires_runner_evidence_validation -and
        $exitRecord.runner_pid -eq $observation.runner_pid -and $exitRecord.runner_exit_code -eq $observation.observed_runner_exit -and
        $once.started_at_utc -ceq $exitRecord.started_at_utc -and
        [DateTimeOffset]$exitRecord.completed_at_utc -ge [DateTimeOffset]$once.started_at_utc) 'Current runner receipts contradict observed terminal tuple.'
    [void](Add-C1bTdHeldFile $Context (Join-Path $Context.Root 'scripts/run-tablet-layout-c1b.ps1') $binding.runner_sha256)
    $stdout=Add-C1bTdHeldFile $Context (Join-Path $receipt 'runner.stdout.bin') $terminal.stdout_sha256.Substring(7) $terminal.stdout_byte_length -AllowEmpty
    [void](Add-C1bTdHeldFile $Context (Join-Path $receipt 'runner.stderr.bin') $terminal.stderr_sha256.Substring(7) $terminal.stderr_byte_length -AllowEmpty)
    Assert-C1bTd ($terminal.Contains('discovery_identity')) 'Terminal producer has not supplied discovery identity.'
    Assert-C1bTdExactKeys $terminal.discovery_identity @('schema','status','expected_commit_sha','attempt_id','run_id','run_id_knowledge',
        'identity_verified_from_current_evidence','sources','unavailable_reason') 'terminal discovery identity'
    Assert-C1bTd ($terminal.discovery_identity.identity_verified_from_current_evidence -is [bool] -and $terminal.discovery_identity.sources -is [array]) 'Terminal discovery identity type differs.'
    $prePromotion=$false
    if ($terminal.terminal_status -ceq 'needs-user') {
        $payload=$terminal.details.payload
        Assert-C1bTdExactKeys $payload @('schema','status','reason_code','settings_changed','retry_allowed_after_user_action') 'needs-user payload'
        Assert-C1bTd ($payload.schema -ceq 'tablet-layout-c1b-needs-user/v1' -and $payload.status -ceq 'needs-user' -and
            $payload.reason_code -ceq 'a11y_service_not_enabled_or_bound' -and $payload.settings_changed -is [bool] -and -not $payload.settings_changed -and
            $payload.retry_allowed_after_user_action -is [bool] -and $payload.retry_allowed_after_user_action -and
            $terminal.details.t0_started -is [bool] -and -not $terminal.details.t0_started -and
            $terminal.details.device_install_already_attempted -is [bool] -and $terminal.details.device_install_already_attempted) 'Needs-user pre-promotion proof unavailable.'
        $raw=[Text.UTF8Encoding]::new($false,$true).GetString($stdout.Bytes)
        $lines=@($raw -split '\r?\n' | Where-Object { $_ -match '"schema"\s*:\s*"tablet-layout-c1b-needs-user/v1"' })
        Assert-C1bTd ($lines.Count -eq 1) 'Needs-user exact current stdout payload unavailable.'
        $actualPayload=ConvertFrom-C1bTdJson ([Text.UTF8Encoding]::new($false,$true).GetBytes($lines[0]))
        Assert-C1bTd (($actualPayload | ConvertTo-Json -Depth 5 -Compress) -ceq ($payload | ConvertTo-Json -Depth 5 -Compress)) 'Needs-user payload differs from actual stdout.'
        $prePromotion=$true
    }
    $identity=Get-C1bTerminalDiscoveryIdentity -Context $Context -TerminalStatus $terminal.terminal_status `
        -EvidenceSources @($terminal.discovery_identity.sources) -RunnerStdoutBytes $stdout.Bytes -CheckpointPrePromotionVerified:$prePromotion
    foreach ($name in @('schema','status','expected_commit_sha','attempt_id','run_id','run_id_knowledge','identity_verified_from_current_evidence','unavailable_reason')) {
        Assert-C1bTd ($identity[$name] -ceq $terminal.discovery_identity[$name]) 'Terminal identity differs from independently derived current raw evidence.'
    }
    Assert-C1bTdContextBound $Context
    return [ordered]@{identity=$identity;terminal_status=$terminal.terminal_status;receipt_root=$receipt}
}

function Invoke-C1bTdPinnedReader($Context,[string]$Mode,$Identity,[string]$TerminalStatus,[string]$DestinationDirectory='') {
    Assert-C1bTdContextBound $Context
    $arguments=@{Mode=$Mode;AttemptId=$Identity.attempt_id;ExpectedCommitSha=$Context.Commit;RunId=$Identity.run_id;TerminalStatus=$TerminalStatus;RepoRoot=$Context.Root}
    if ($Mode -ceq 'Freeze') { $arguments.DestinationDirectory=$DestinationDirectory }
    $values=@(& (Join-Path $Context.Root 'scripts/read-tablet-layout-c1b-discovery-evidence.ps1') @arguments)
    Assert-C1bTd ($values.Count -eq 1 -and $values[0] -is [string]) 'Versioned reader must emit exactly one JSON object.'
    Assert-C1bTdContextBound $Context
    return ConvertFrom-C1bTdJson ([Text.UTF8Encoding]::new($false,$true).GetBytes($values[0]))
}

function Assert-C1bTdConsumption($Context,$Value,$Identity,[string]$TerminalStatus) {
    Assert-C1bTd ($Value.schema -ceq 'tablet-layout-c1b-discovery-consumption/v1' -and $Value.attempt_id -ceq $Identity.attempt_id -and
        $Value.expected_commit_sha -ceq $Context.Commit -and $Value.observed_terminal_status -ceq $TerminalStatus -and
        $Value.acceptance_proven_by_this_bundle -is [bool] -and -not $Value.acceptance_proven_by_this_bundle) 'Discovery consumption tuple/claim differs.'
    Assert-C1bTd (($null -eq $Identity.run_id -and $null -eq $Value.run_id) -or ($null -ne $Identity.run_id -and $Value.run_id -ceq $Identity.run_id)) 'Discovery nullable run differs.'
}

function Invoke-C1bTerminalDiscoveryFreeze {
    [CmdletBinding()]param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$TerminalReadbackPath,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$TerminalReadbackSha256,
        [Parameter(Mandatory)][string]$ReceiptRoot,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ObservationSha256,
        [Parameter(Mandatory)][ValidatePattern('(?-i)^[0-9a-f]{64}$')][string]$ExpectedBindingSha256)
    # Public callers cannot substitute a claimed verified Identity for actual held authority.
    $authority=Read-C1bTerminalDiscoveryAuthority @PSBoundParameters
    $Identity=$authority.identity;$TerminalStatus=$authority.terminal_status
    $DestinationDirectory=Join-Path $authority.receipt_root 'discovery-freeze'
    $ReservationPath=Join-Path $authority.receipt_root 'discovery-freeze-once.json'
    Assert-C1bTd ($Identity.status -ceq 'verified' -and $Identity.identity_verified_from_current_evidence -eq $true -and
        $Identity.expected_commit_sha -ceq $Context.Commit -and $Identity.run_id_knowledge -ceq 'known') 'Actual terminal identity unavailable; Freeze refused.'
    $destination=[IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\','/')
    $reservation=[IO.Path]::GetFullPath($ReservationPath)
    Assert-C1bTd ($destination.StartsWith((Join-Path $Context.Root '.checks')+'\',[StringComparison]::OrdinalIgnoreCase) -and
        [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($reservation),[IO.Path]::GetDirectoryName($destination)) -and
        [IO.Path]::GetFileName($reservation) -ceq 'discovery-freeze-once.json') 'Freeze namespace/reservation differs.'
    Assert-C1bTd (-not [IO.File]::Exists($reservation) -and -not [IO.Directory]::Exists($reservation)) 'Freeze already reserved; no retry.'
    Assert-C1bTd ([IO.Directory]::Exists($destination) -and @(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) 'Freeze destination must already exist and be empty.'
    Add-C1bTdHeldDirectory $Context $destination
    $read=Invoke-C1bTdPinnedReader $Context Read $Identity $TerminalStatus
    Assert-C1bTdConsumption $Context $read $Identity $TerminalStatus
    # Hold every present source before reserving Freeze; preserve absent_unknown/not_reached.
    foreach ($name in @('before_install','after_capture','attempt_failure')) {
        $record=if($name -ceq 'attempt_failure'){$read.attempt_failure}else{$read.checkpoints[$name]}
        Assert-C1bTd ($record.status -cin @('present','absent_unknown','not_reached')) 'Unknown checkpoint status.'
        if ($record.status -ceq 'present') {
            [void](Add-C1bTdHeldFile $Context (Resolve-C1bTdRelativePath $Context.Root $record.path 'docs/runs/evidence/') $record.sha256.Substring(7) $record.byte_length)
        } else { Assert-C1bTd ($null -eq $record.path -and $null -eq $record.sha256 -and $null -eq $record.byte_length) 'Unknown/unreached record contains fabricated raw metadata.' }
    }
    Assert-C1bTdContextBound $Context
    $once=[ordered]@{schema='c1b-discovery-freeze-once/v1';candidate_sha=$Context.Commit;attempt_id=$Identity.attempt_id;run_id=$Identity.run_id;
        terminal_status=$TerminalStatus;reserved_at_utc=[DateTimeOffset]::UtcNow.ToString('o');automatic_retry_count=0;
        terminal_readback_sha256=$TerminalReadbackSha256;observation_sha256=$ObservationSha256;binding_sha256=$ExpectedBindingSha256;reservation_is_not_success=$true}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($once | ConvertTo-Json -Depth 8 -Compress))
    $stream=[IO.File]::Open($reservation,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($bytes);$stream.Flush($true);[IO.File]::SetAttributes($reservation,[IO.File]::GetAttributes($reservation) -bor [IO.FileAttributes]::ReadOnly) } finally { $stream.Dispose() }
    # Do not remove this marker even if Freeze or any later verification fails.
    [void](Add-C1bTdHeldFile $Context $reservation (Get-C1bTdHash $bytes) $bytes.Length)
    $freeze=Invoke-C1bTdPinnedReader $Context Freeze $Identity $TerminalStatus $destination
    Assert-C1bTdConsumption $Context $freeze.readback $Identity $TerminalStatus
    $manifestPath=Join-Path $destination 'freeze-manifest.json'
    Assert-C1bTd ([StringComparer]::OrdinalIgnoreCase.Equals($freeze.manifest_path,$manifestPath) -and $freeze.manifest_sha256 -cmatch '^sha256:[0-9a-f]{64}$') 'Freeze manifest escaped or lacks raw pin.'
    $manifest=ConvertFrom-C1bTdJson (Add-C1bTdHeldFile $Context $manifestPath $freeze.manifest_sha256.Substring(7)).Bytes
    Assert-C1bTd ($manifest.schema -ceq 'tablet-layout-c1b-discovery-freeze/v1' -and $manifest.attempt_id -ceq $Identity.attempt_id -and
        $manifest.expected_commit_sha -ceq $Context.Commit -and $manifest.observed_terminal_status -ceq $TerminalStatus -and
        $manifest.acceptance_proven_by_this_freeze -is [bool] -and -not $manifest.acceptance_proven_by_this_freeze) 'Frozen manifest tuple/claim differs.'
    Assert-C1bTd (($null -eq $Identity.run_id -and $null -eq $manifest.run_id) -or ($null -ne $Identity.run_id -and $manifest.run_id -ceq $Identity.run_id)) 'Frozen nullable run differs.'
    foreach ($name in @('before_install','after_capture','attempt_failure')) {
        $record=if($name -ceq 'attempt_failure'){$read.attempt_failure}else{$read.checkpoints[$name]};$member=$manifest.members[$name]
        Assert-C1bTd ($member.status -ceq $record.status -and $member.source_path -ceq $record.path -and
            $member.byte_length -eq $record.byte_length -and $member.sha256 -ceq $record.sha256) 'Frozen raw member/status differs from Read.'
        if ($record.status -ceq 'present') {
            Assert-C1bTd ($member.frozen_file -ceq [IO.Path]::GetFileName($record.path)) 'Frozen member leaf differs.'
            [void](Add-C1bTdHeldFile $Context (Join-Path $destination $member.frozen_file) $member.sha256.Substring(7) $member.byte_length)
        } else { Assert-C1bTd ($null -eq $member.frozen_file) 'Unknown/unreached record became a fabricated frozen file.' }
    }
    Assert-C1bTdContextBound $Context
    return [ordered]@{schema='c1b-terminal-discovery-bridge/v1';candidate_sha=$Context.Commit;discovery_identity=$Identity;read=$read;freeze=$freeze;
        freeze_once_reservation=$reservation;freeze_once_sha256=(Get-C1bTdHash $bytes);automatic_retry_count=0;device_acceptance_proven_by_this_bridge=$false;device_or_adb_invocations=0}
}
