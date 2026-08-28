#Requires -Version 7.5
# C1b 专用只读 APK 的宿主侧独立证明校验。调用方须先加载 C1a/C1b 基础库。

Set-StrictMode -Version 3.0

$script:TL1C1bReadOnlyPolicy = 'tl1-c1b-read-only/v2'
$script:TL1C1bArtifactProofSchema = 'tablet-c1b-read-only-artifact-proof/v1'
$script:TL1C1bArtifactProofSchemaRelativePath = 'docs/contracts/tablet-c1b-read-only-artifact-proof-v1.schema.json'
$script:TL1C1bArtifactProofRelativePath = 'app/tablet-c1b-probe/build/reports/tablet-c1b-read-only-artifact-proof.json'
$script:TL1C1bDebugApkRelativePath = 'app/tablet-c1b-probe/build/outputs/apk/debug/tablet-c1b-probe-debug.apk'
$script:TL1C1bReleaseApkRelativePath = 'app/tablet-c1b-probe/build/outputs/apk/release/tablet-c1b-probe-release-unsigned.apk'
$script:TL1C1bArtifactSourcePaths = [string[]]@(
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/C1bPendingStartRegistry.kt'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bContentProvider.kt'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bProtocol.kt'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bReadCoordinator.kt'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TabletC1bRuntimeController.kt'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b/TrustedRuntimeContextFactory.kt'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbe.kt'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/TabletLayoutProbeModel.kt'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bModel.kt'
    'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/TabletC1bProbe.kt'
    'app/tablet-c1b-probe/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt'
)
$script:TL1C1bArtifactBuildInputPaths = [string[]]@(
    'app/build.gradle.kts'
    'app/gradle.properties'
    'app/gradle/verification-metadata.xml'
    'app/gradle/wrapper/gradle-wrapper.jar'
    'app/gradle/wrapper/gradle-wrapper.properties'
    'app/gradlew.bat'
    'app/settings.gradle.kts'
    'app/tablet-c1b-probe/build.gradle.kts'
    'app/tablet-c1b-probe/src/main/AndroidManifest.xml'
    'app/tablet-c1b-probe/src/main/res/values/strings.xml'
    'app/tablet-c1b-probe/src/main/res/xml/a11y_config.xml'
)
$script:TL1C1bArtifactAllowedArtifacts = @(
    [pscustomobject][ordered]@{
        Coordinate='org.jetbrains.kotlin:kotlin-stdlib:2.0.20'
        Sha256='sha256:fb169596659a518357c4b2c16f43dc75ab1c4980565ed4b4a317a050e5e39006'
    }
    [pscustomobject][ordered]@{
        Coordinate='org.jetbrains:annotations:13.0'
        Sha256='sha256:ace2a10dc8e2d5fd34925ecac03e4988b2c0f851650c94b8cef49ba1bd111478'
    }
)
$script:TL1C1bDexDependencyStringWaivers = [string[]]@(
    'FileOutputStream'
    'forName'
    'getMethod'
    'java/lang/Runtime'
    'java/lang/reflect'
    'java/nio/file/Files'
)

function Test-TL1C1bOrdinalSequence {
    param([AllowNull()][object[]]$Actual,[Parameter(Mandatory)][string[]]$Expected)
    $actualStrings=[string[]]@($Actual|ForEach-Object{[string]$_})
    if($actualStrings.Count-ne$Expected.Count){return $false}
    for($index=0;$index-lt$Expected.Count;$index++){
        if($actualStrings[$index]-cne$Expected[$index]){return $false}
    }
    return $true
}

function Open-TL1C1bArtifactGuard {
    param([Parameter(Mandatory)][string]$RepoRoot,[Parameter(Mandatory)][string]$Path)
    $ordinary=Assert-TL1C1aOrdinaryPath $RepoRoot $Path
    $guard=[IO.File]::Open($ordinary,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $identity=[TL1C1bFileIdentity]::Read($guard.SafeFileHandle)
        if($identity.LinkCount-ne1){throw 'C1b artifact hardlink count 必须 exact 1。'}
        $guard.Position=0
        $sha='sha256:'+[Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($guard)).ToLowerInvariant()
        $guard.Position=0
        return [pscustomobject][ordered]@{Guard=$guard;Path=$ordinary;Sha256=$sha;FileIdentity=$identity.StableId}
    }catch{$guard.Dispose();throw}
}

function Copy-TL1C1bGuardedArtifactAtomic {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$SourceGuard,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [long]$MaximumBytes=64MB
    )
    if($ExpectedSha256-cnotmatch'^sha256:[0-9a-f]{64}$'-or
       [string]$SourceGuard.Sha256-cne$ExpectedSha256-or$null-eq$SourceGuard.Guard){
        throw 'C1b artifact archive source guard 绑定失败。'
    }
    $sourceStream=$SourceGuard.Guard
    if($sourceStream.Length-lt1-or$sourceStream.Length-gt$MaximumBytes){throw 'C1b artifact archive byte count 越界。'}
    $destinationFull=Assert-TL1C1aOrdinaryPath $RepoRoot $Destination -AllowMissingLeaf
    if([IO.Path]::GetExtension($destinationFull)-cnotin @('.json','.apk','.xml')){
        throw 'C1b artifact archive 扩展名不在 allowlist。'
    }
    if(Test-Path -LiteralPath $destinationFull){throw 'C1b artifact archive 拒绝覆盖既有证据。'}
    $directory=[IO.Path]::GetDirectoryName($destinationFull)
    if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw 'C1b artifact archive 目标目录缺失。'}
    $temporary=Join-Path $directory ('.c1b-artifact-'+[guid]::NewGuid().ToString('N')+'.tmp')
    $published=$false;$archiveGuard=$null
    $buffer=[byte[]]::new(64KB)
    $hasher=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try{
        $sourceStream.Position=0
        $destinationStream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{
            while(($read=$sourceStream.Read($buffer,0,$buffer.Length))-gt0){
                $destinationStream.Write($buffer,0,$read)
                $hasher.AppendData($buffer,0,$read)
            }
            $destinationStream.Flush($true)
        }finally{$destinationStream.Dispose();$sourceStream.Position=0}
        $copiedSha='sha256:'+[Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
        if($copiedSha-cne$ExpectedSha256){throw 'C1b artifact archive copy hash 漂移。'}
        [IO.File]::Move($temporary,$destinationFull)
        $published=$true
        $archiveGuard=Open-TL1C1bArtifactGuard $RepoRoot $destinationFull
        if([string]$archiveGuard.Sha256-cne$ExpectedSha256){throw 'C1b artifact archive final hash 漂移。'}
        return $archiveGuard
    }catch{
        if($null-ne$archiveGuard){$archiveGuard.Guard.Dispose()}
        if($published-and(Test-Path -LiteralPath $destinationFull -PathType Leaf)){Remove-Item -LiteralPath $destinationFull -Force}
        throw
    }finally{
        $hasher.Dispose();[Array]::Clear($buffer,0,$buffer.Length)
        if(Test-Path -LiteralPath $temporary -PathType Leaf){Remove-Item -LiteralPath $temporary -Force}
    }
}

function Get-TL1C1bZipDexProof {
    param([Parameter(Mandatory)][string]$ApkPath)
    $archive=[IO.Compression.ZipFile]::OpenRead($ApkPath)
    try{
        $duplicateEntries=@($archive.Entries|Group-Object -Property FullName|Where-Object{$_.Count-ne1})
        if($duplicateEntries.Count-ne0){throw 'C1b 专用 APK 不允许重复 ZIP entry。'}
        $manifestEntries=@($archive.Entries|Where-Object{$_.FullName-ceq'AndroidManifest.xml'})
        if($manifestEntries.Count-ne1){throw 'C1b 专用 APK 必须恰好包含 AndroidManifest.xml。'}
        $manifestStream=$manifestEntries[0].Open()
        try{
            $manifestHash='sha256:'+[Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($manifestStream)).ToLowerInvariant()
        }finally{$manifestStream.Dispose()}
        $dexEntries=@($archive.Entries|Where-Object{$_.FullName-cmatch'^classes(?:[2-9]|[1-9][0-9]+)?\.dex$'}|Sort-Object @{
            Expression={if($_.FullName-ceq'classes.dex'){1}else{[int]([regex]::Match($_.FullName,'^classes([0-9]+)\.dex$').Groups[1].Value)}}
        })
        if($dexEntries.Count-notin 1..32){throw 'C1b 专用 APK DEX entry 数量越界。'}
        for($dexIndex=1;$dexIndex-le$dexEntries.Count;$dexIndex++){
            $expectedDexName=if($dexIndex-eq1){'classes.dex'}else{"classes$dexIndex.dex"}
            if($dexEntries[$dexIndex-1].FullName-cne$expectedDexName){
                throw 'C1b 专用 APK DEX entry 必须从 classes.dex 开始连续编号。'
            }
        }
        $dexProofs=[Collections.Generic.List[object]]::new()
        $dexCatalogLines=[Collections.Generic.List[string]]::new()
        foreach($dexEntry in $dexEntries){
            $stream=$dexEntry.Open()
            try{
                $hash='sha256:'+[Convert]::ToHexString(
                    [Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
            }finally{$stream.Dispose()}
            $dexProofs.Add([pscustomobject][ordered]@{RelativePath=$dexEntry.FullName;Sha256=$hash})
            $dexCatalogLines.Add("$($dexEntry.FullName)=$hash")
        }
        return [pscustomobject][ordered]@{
            Entries=$dexProofs.ToArray()
            EntryCount=$dexProofs.Count
            Sha256=$dexProofs[0].Sha256
            CatalogSha256=Get-TL1C1aSha256Text ($dexCatalogLines-join"`n")
            PackagedManifestSha256=$manifestHash
        }
    }finally{$archive.Dispose()}
}

function Get-TL1C1bMergedManifestPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('debug','release')][string]$Variant
    )
    $intermediates=Join-Path $RepoRoot 'app\tablet-c1b-probe\build\intermediates'
    if(-not(Test-Path -LiteralPath $intermediates -PathType Container)){throw 'C1b merged manifest 根目录缺失。'}
    $matches=@(Get-ChildItem -LiteralPath $intermediates -Filter AndroidManifest.xml -File -Recurse|Where-Object{
        $relative=[IO.Path]::GetRelativePath($intermediates,$_.FullName).Replace('\','/')
        ($relative-cmatch'(^|/)merged_manifests/')-and
        ($relative-cmatch("(^|/)"+[regex]::Escape($Variant)+"(/|$)"))
    })
    if($matches.Count-ne1){throw "C1b $Variant merged manifest 必须唯一。"}
    return Assert-TL1C1aOrdinaryPath $RepoRoot $matches[0].FullName
}

function Assert-TL1C1bReadOnlyArtifactProof {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ProofPath,
        [Parameter(Mandatory)][string]$ProofSchemaPath,
        [Parameter(Mandatory)][string]$ExpectedCommitSha,
        [Parameter(Mandatory)][string]$BuildChallenge,
        [Parameter(Mandatory)][string]$DebugApkPath,
        [Parameter(Mandatory)]$Aapt2TrustBinding,
        $ProofGuard,
        $DebugApkGuard,
        $ReleaseApkGuard
    )
    $root=[IO.Path]::GetFullPath($RepoRoot)
    if($ExpectedCommitSha-cnotmatch'^[0-9a-f]{40}$'){throw 'C1b artifact proof expected SHA 格式错误。'}
    $proofFile=Assert-TL1C1aOrdinaryPath $root $ProofPath
    $expectedSchemaPath=[IO.Path]::GetFullPath((Join-Path $root ($script:TL1C1bArtifactProofSchemaRelativePath-replace'/','\')))
    $schemaPath=Assert-TL1C1aOrdinaryPath $root $ProofSchemaPath
    if($schemaPath-cne$expectedSchemaPath){throw 'C1b artifact proof schema 路径不唯一。'}
    $expectedProofPath=[IO.Path]::GetFullPath((Join-Path $root ($script:TL1C1bArtifactProofRelativePath-replace'/','\')))
    if($proofFile-cne$expectedProofPath){throw 'C1b artifact proof 路径不唯一。'}
    if($null-ne$ProofGuard-and(
        [string]$ProofGuard.Path-cne$proofFile-or[string]$ProofGuard.Sha256-cne(Get-TL1C1aFileSha256 $proofFile))){
        throw 'C1b artifact proof guard 绑定失败。'
    }
    $proofBytes=[IO.File]::ReadAllBytes($proofFile)
    try{
        if($proofBytes.Length-notin 1..1048576){throw 'C1b artifact proof byte count 越界。'}
        $raw=ConvertFrom-TL1C1aStrictUtf8 $proofBytes 'C1b artifact proof'
        $proof=ConvertFrom-TL1C1bClosedJson $raw
        if(-not($raw|Test-Json -SchemaFile $ProofSchemaPath -ErrorAction SilentlyContinue)){
            throw 'C1b artifact proof closed schema 失败。'
        }
        if($proof.schema-cne$script:TL1C1bArtifactProofSchema-or$proof.policy-cne$script:TL1C1bReadOnlyPolicy-or
           $proof.application_id-cne'dev.magina.gateway'-or
           $proof.accessibility_service_component-cne'dev.magina.gateway.a11y.GatewayA11yService'-or
           $proof.provider_component-cne'dev.magina.gateway.tablet.c1b.TabletC1bContentProvider'-or
           $proof.provider_authority-cne'dev.magina.gateway.tablet.c1b'-or
           [long]$proof.forbidden_match_count-ne0-or[long]$proof.manifest_mutating_capability_count-ne0-or
           [long]$proof.manifest_extra_component_count-ne0-or-not[bool]$proof.dependency_allowlist.passed-or
           $proof.git_sha-cne$ExpectedCommitSha-or
           $proof.build_challenge_sha256-cne(Get-TL1C1aSha256Text $BuildChallenge)){
            throw 'C1b artifact proof 身份、零能力或 Git/build challenge 绑定失败。'
        }
        if($Aapt2TrustBinding.schema-cne'tablet-layout-c1b-aapt2-trust/v1'-or
           $Aapt2TrustBinding.trust_root-cne'android_sdk_build_tools'-or
           $Aapt2TrustBinding.build_tools_version-cne'35.0.0'-or
           $Aapt2TrustBinding.canonical_relative_path-cne'build-tools/35.0.0/aapt2.exe'-or
           -not[bool]$Aapt2TrustBinding.sdk_roots_equal-or
           $Aapt2TrustBinding.executable_sha256-cne'sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'-or
           $Aapt2TrustBinding.signature_status-cne'Valid'-or
           $Aapt2TrustBinding.signature_subject-cne'CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'-or
           $Aapt2TrustBinding.signature_certificate_sha256-cne'sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'-or
           $proof.axml_parser.tool-cne'aapt2'-or
           $proof.axml_parser.build_tools_version-cne$Aapt2TrustBinding.build_tools_version-or
           $proof.axml_parser.aapt2_relative_path-cne$Aapt2TrustBinding.canonical_relative_path-or
           $proof.axml_parser.aapt2_sha256-cne$Aapt2TrustBinding.executable_sha256){
            throw 'C1b artifact proof AXML parser/trusted aapt2 绑定失败。'
        }

        $expectedSources=[string[]]@($script:TL1C1bArtifactSourcePaths)
        [Array]::Sort($expectedSources,[StringComparer]::Ordinal)
        $proofSourcePaths=[string[]]@($proof.scanned_sources|ForEach-Object{[string]$_.relative_path})
        if(-not(Test-TL1C1bOrdinalSequence $proofSourcePaths $expectedSources)){
            throw 'C1b artifact proof source allowlist 漂移。'
        }
        foreach($source in $proof.scanned_sources){
            $sourcePath=Assert-TL1C1aOrdinaryPath $root (Join-Path $root ([string]$source.relative_path-replace'/','\'))
            if((Get-TL1C1aFileSha256 $sourcePath)-cne[string]$source.sha256){
                throw "C1b artifact proof source hash 漂移：$($source.relative_path)。"
            }
        }

        $expectedBuildInputs=[string[]]@($script:TL1C1bArtifactBuildInputPaths)
        [Array]::Sort($expectedBuildInputs,[StringComparer]::Ordinal)
        $proofBuildInputPaths=[string[]]@($proof.scanned_build_inputs|ForEach-Object{[string]$_.relative_path})
        if(-not(Test-TL1C1bOrdinalSequence $proofBuildInputPaths $expectedBuildInputs)){
            throw 'C1b artifact proof build-input allowlist 漂移。'
        }
        foreach($input in $proof.scanned_build_inputs){
            $inputPath=Assert-TL1C1aOrdinaryPath $root (Join-Path $root ([string]$input.relative_path-replace'/','\'))
            if((Get-TL1C1aFileSha256 $inputPath)-cne[string]$input.sha256){
                throw "C1b artifact proof build input hash 漂移：$($input.relative_path)。"
            }
        }

        $waivers=[string[]]@($proof.dex_dependency_string_waivers)
        if(-not(Test-TL1C1bOrdinalSequence $waivers $script:TL1C1bDexDependencyStringWaivers)){
            throw 'C1b artifact DEX dependency string waiver 漂移。'
        }
        $namedWaivers=@($proof.named_read_only_waivers)
        if($namedWaivers.Count-ne1-or
           [string]$namedWaivers[0].id-cne'accessibility-node-refresh-read-freshness'-or
           [string]$namedWaivers[0].relative_path-cne'app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt'-or
           [string]$namedWaivers[0].exact_invocation-cne'node.androidNode.refresh()'-or
           [long]$namedWaivers[0].count-ne1){
            throw 'C1b artifact named read-only waiver 漂移。'
        }
        $refreshSourcePath=Join-Path $root 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\AndroidTabletC1bSource.kt'
        $refreshSource=[IO.File]::ReadAllText((Assert-TL1C1aOrdinaryPath $root $refreshSourcePath),[Text.UTF8Encoding]::new($false,$true))
        if(([regex]::Matches($refreshSource,[regex]::Escape('node.androidNode.refresh()'))).Count-ne1-or
           @($script:TL1C1bArtifactSourcePaths|ForEach-Object{
               $candidate=[IO.File]::ReadAllText((Join-Path $root ($_-replace'/','\')),[Text.UTF8Encoding]::new($false,$true))
               [regex]::Matches($candidate,'\.refresh\s*\(').Count
           }|Measure-Object -Sum).Sum-ne1){
            throw 'C1b artifact named read-only waiver 调用面漂移。'
        }

        $resolved=@($proof.dependency_allowlist.resolved_artifacts)
        if($resolved.Count-ne$script:TL1C1bArtifactAllowedArtifacts.Count){
            throw 'C1b artifact resolved dependency 数量漂移。'
        }
        $dependencyCatalogLines=[Collections.Generic.List[string]]::new()
        for($dependencyIndex=0;$dependencyIndex-lt$script:TL1C1bArtifactAllowedArtifacts.Count;$dependencyIndex++){
            $expectedArtifact=$script:TL1C1bArtifactAllowedArtifacts[$dependencyIndex]
            $actualArtifact=$resolved[$dependencyIndex]
            if([string]$actualArtifact.coordinate-cne[string]$expectedArtifact.Coordinate-or
               [string]$actualArtifact.artifact_sha256-cne[string]$expectedArtifact.Sha256){
                throw 'C1b artifact resolved dependency coordinate/hash 越出 exact allowlist。'
            }
            $dependencyCatalogLines.Add("$($expectedArtifact.Coordinate)=$($expectedArtifact.Sha256)")
        }
        $dependencyCatalogSha256=Get-TL1C1aSha256Text ($dependencyCatalogLines-join"`n")

        $variantNames=[string[]]@($proof.variants|ForEach-Object{[string]$_.name})
        if(-not(Test-TL1C1bOrdinalSequence $variantNames ([string[]]@('debug','release')))){
            throw 'C1b artifact proof variant 集合漂移。'
        }
        $variantResults=[ordered]@{}
        foreach($variant in $proof.variants){
            $name=[string]$variant.name
            $expectedRelative=if($name-ceq'debug'){$script:TL1C1bDebugApkRelativePath}else{$script:TL1C1bReleaseApkRelativePath}
            if([string]$variant.apk_relative_path-cne$expectedRelative){
                throw "C1b $name APK proof 路径漂移。"
            }
            $apk=Assert-TL1C1aOrdinaryPath $root (Join-Path $root ($expectedRelative-replace'/','\'))
            if($name-ceq'debug'-and$apk-cne[IO.Path]::GetFullPath($DebugApkPath)){
                throw 'C1b runner 安装包不是 proof 中的专用 debug APK。'
            }
            $apkSha=Get-TL1C1aFileSha256 $apk
            if($apkSha-cne[string]$variant.apk_sha256){throw "C1b $name APK hash 漂移。"}
            $guard=if($name-ceq'debug'){$DebugApkGuard}else{$ReleaseApkGuard}
            if($null-ne$guard-and([string]$guard.Path-cne$apk-or[string]$guard.Sha256-cne$apkSha)){
                throw "C1b $name APK guard 绑定失败。"
            }
            $manifest=Get-TL1C1bMergedManifestPath $root $name
            $manifestSha=Get-TL1C1aFileSha256 $manifest
            if($manifestSha-cne[string]$variant.merged_manifest_sha256){
                throw "C1b $name merged manifest hash 漂移。"
            }
            $dex=Get-TL1C1bZipDexProof $apk
            $proofDexEntries=@($variant.dex_entries)
            if($proofDexEntries.Count-ne$dex.EntryCount){
                throw "C1b $name DEX proof 漂移。"
            }
            for($dexIndex=0;$dexIndex-lt$dex.EntryCount;$dexIndex++){
                if([string]$proofDexEntries[$dexIndex].relative_path-cne[string]$dex.Entries[$dexIndex].RelativePath-or
                   [string]$proofDexEntries[$dexIndex].sha256-cne[string]$dex.Entries[$dexIndex].Sha256){
                    throw "C1b $name DEX proof 漂移。"
                }
            }
            if([string]$variant.packaged_manifest_sha256-cne$dex.PackagedManifestSha256){
                throw "C1b $name packaged manifest proof 漂移。"
            }
            if(-not[bool]$variant.packaged_manifest_exact_tree_verified-or
               -not[bool]$variant.packaged_a11y_exact_tree_verified){
                throw "C1b $name packaged AXML exact-tree proof 缺失。"
            }
            if([string]$variant.packaged_manifest_axml_dump_sha256-cnotmatch'^sha256:[0-9a-f]{64}$'-or
               [string]$variant.packaged_a11y_axml_dump_sha256-cnotmatch'^sha256:[0-9a-f]{64}$'){
                throw "C1b $name packaged AXML dump hash proof 缺失。"
            }
            $variantResults[$name]=[pscustomobject][ordered]@{
                ApkPath=$apk;ApkSha256=$apkSha;MergedManifestPath=$manifest;MergedManifestSha256=$manifestSha
                PackagedManifestSha256=$dex.PackagedManifestSha256
                PackagedManifestAxmlDumpSha256=[string]$variant.packaged_manifest_axml_dump_sha256
                PackagedA11yAxmlDumpSha256=[string]$variant.packaged_a11y_axml_dump_sha256
                PackagedManifestExactTreeVerified=[bool]$variant.packaged_manifest_exact_tree_verified
                PackagedA11yExactTreeVerified=[bool]$variant.packaged_a11y_exact_tree_verified
                DexEntryCount=$dex.EntryCount;DexSha256=$dex.Sha256;DexCatalogSha256=$dex.CatalogSha256
            }
        }
        return [pscustomobject][ordered]@{
            Proof=$proof
            ProofSha256=Get-TL1C1aSha256Bytes $proofBytes
            Debug=$variantResults.debug
            Release=$variantResults.release
            ForbiddenMatchCount=[long]$proof.forbidden_match_count
            ManifestMutatingCapabilityCount=[long]$proof.manifest_mutating_capability_count
            ManifestExtraComponentCount=[long]$proof.manifest_extra_component_count
            DependencyAllowlistVerified=[bool]$proof.dependency_allowlist.passed
            DependencyArtifactCatalogSha256=$dependencyCatalogSha256
            AxmlParserVerified=$true
        }
    }finally{if($proofBytes.Length-ne0){[Array]::Clear($proofBytes,0,$proofBytes.Length)}}
}
