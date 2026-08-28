#Requires -Version 7.5
[CmdletBinding()]param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)

$SourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $SourceRoot 'scripts\lib\tablet-layout-c1a.ps1')
. (Join-Path $SourceRoot 'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1')
. (Join-Path $SourceRoot 'scripts\lib\tablet-layout-c1b.ps1')
. (Join-Path $SourceRoot 'scripts\lib\tablet-layout-c1b-artifact-proof.ps1')
$SourceSchema=Join-Path $SourceRoot 'docs\contracts\tablet-c1b-read-only-artifact-proof-v1.schema.json'
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('tablet-c1b-artifact-proof-'+[guid]::NewGuid().ToString('N'))
$Commit='a'*40
$Challenge='c1b-'+'b'*32
$script:Passed=0
$script:Failed=0

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Assert-Throws([scriptblock]$Action,[string]$Message){$threw=$false;try{&$Action}catch{$threw=$true};if(-not$threw){throw $Message}}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{&$Body;$script:Passed++;Write-Output "PASS  $Name"}
    catch{$script:Failed++;Write-Output "FAIL  $Name :: $($_.Exception.Message)"}
}
function Write-Utf8([string]$Path,[string]$Text){
    $parent=Split-Path $Path -Parent;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force $parent|Out-Null}
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function New-TestApk([string]$Path,[byte]$Marker,[int]$DexCount=1){
    $parent=Split-Path $Path -Parent;if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Force $parent|Out-Null}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try{
            $entrySpecs=[Collections.Generic.List[object]]::new()
            foreach($entrySpec in @(
                [pscustomobject]@{Name='AndroidManifest.xml';Bytes=[byte[]](1,$Marker,2)},
                [pscustomobject]@{Name='res/xml/a11y_config.xml';Bytes=[byte[]](3,$Marker,4)}
            )){$entrySpecs.Add($entrySpec)}
            for($dexIndex=1;$dexIndex-le$DexCount;$dexIndex++){
                $dexName=if($dexIndex-eq1){'classes.dex'}else{"classes$dexIndex.dex"}
                $entrySpecs.Add([pscustomobject]@{Name=$dexName;Bytes=[byte[]](100,101,120,10,$Marker,[byte]$dexIndex)})
            }
            foreach($entrySpec in $entrySpecs){
                $entry=$zip.CreateEntry($entrySpec.Name,[IO.Compression.CompressionLevel]::NoCompression)
                $entryStream=$entry.Open();try{$entryStream.Write($entrySpec.Bytes)}finally{$entryStream.Dispose()}
            }
        }finally{$zip.Dispose()}
    }finally{$stream.Dispose()}
}
function Copy-Value($Value){return ($Value|ConvertTo-Json -Depth 20)|ConvertFrom-Json -Depth 20 -DateKind String}
function Write-Proof($Proof){Write-Utf8 $script:ProofPath (($Proof|ConvertTo-Json -Depth 20)+"`n")}
function Invoke-ProofCheck {
    Assert-TL1C1bReadOnlyArtifactProof -RepoRoot $TestRoot -ProofPath $script:ProofPath `
        -ProofSchemaPath $script:Schema -ExpectedCommitSha $Commit -BuildChallenge $Challenge `
        -DebugApkPath $script:DebugApk -Aapt2TrustBinding $script:Aapt2TrustBinding
}

New-Item -ItemType Directory -Path $TestRoot|Out-Null
try{
    $script:Schema=Join-Path $TestRoot ($script:TL1C1bArtifactProofSchemaRelativePath-replace'/','\')
    $schemaParent=Split-Path $script:Schema -Parent;New-Item -ItemType Directory -Force $schemaParent|Out-Null
    Copy-Item -LiteralPath $SourceSchema -Destination $script:Schema
    foreach($relative in $script:TL1C1bArtifactSourcePaths){
        Write-Utf8 (Join-Path $TestRoot ($relative-replace'/','\')) "source:$relative`n"
    }
    Write-Utf8 (Join-Path $TestRoot 'app\gateway\src\main\java\dev\magina\gateway\tablet\c1b\AndroidTabletC1bSource.kt') `
        "source:AndroidTabletC1bSource`nnode.androidNode.refresh()`n"
    foreach($relative in $script:TL1C1bArtifactBuildInputPaths){
        Write-Utf8 (Join-Path $TestRoot ($relative-replace'/','\')) "build-input:$relative`n"
    }
    $script:DebugApk=Join-Path $TestRoot ($script:TL1C1bDebugApkRelativePath-replace'/','\')
    $releaseApk=Join-Path $TestRoot ($script:TL1C1bReleaseApkRelativePath-replace'/','\')
    New-TestApk $script:DebugApk 7 3
    New-TestApk $releaseApk 9
    $debugManifest=Join-Path $TestRoot 'app\tablet-c1b-probe\build\intermediates\merged_manifests\debug\processDebugManifest\AndroidManifest.xml'
    $releaseManifest=Join-Path $TestRoot 'app\tablet-c1b-probe\build\intermediates\merged_manifests\release\processReleaseManifest\AndroidManifest.xml'
    Write-Utf8 $debugManifest '<manifest package="dev.magina.gateway" />'
    Write-Utf8 $releaseManifest '<manifest package="dev.magina.gateway" />'
    $script:ProofPath=Join-Path $TestRoot ($script:TL1C1bArtifactProofRelativePath-replace'/','\')
    $script:Aapt2TrustBinding=[pscustomobject][ordered]@{
        schema='tablet-layout-c1b-aapt2-trust/v1'
        trust_root='android_sdk_build_tools'
        build_tools_version='35.0.0'
        canonical_relative_path='build-tools/35.0.0/aapt2.exe'
        sdk_roots_equal=$true
        executable_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'
        signature_status='Valid'
        signature_subject='CN=Google LLC, O=Google LLC, L=Mountain View, S=California, C=US'
        signature_certificate_sha256='sha256:7d3d117664f121e592ef897973ef9c159150e3d736326e9cd2755f71e0febc0c'
    }

    $sources=@($script:TL1C1bArtifactSourcePaths|ForEach-Object{
        [ordered]@{relative_path=$_;sha256=Get-TL1C1aFileSha256 (Join-Path $TestRoot ($_-replace'/','\'))}
    })
    [Array]::Sort($sources,[Comparison[object]]{
        param($left,$right);[StringComparer]::Ordinal.Compare([string]$left.relative_path,[string]$right.relative_path)
    })
    $debugDex=Get-TL1C1bZipDexProof $script:DebugApk
    $releaseDex=Get-TL1C1bZipDexProof $releaseApk
    $buildInputs=@($script:TL1C1bArtifactBuildInputPaths|ForEach-Object{
        [ordered]@{relative_path=$_;sha256=Get-TL1C1aFileSha256 (Join-Path $TestRoot ($_-replace'/','\'))}
    })
    [Array]::Sort($buildInputs,[Comparison[object]]{
        param($left,$right);[StringComparer]::Ordinal.Compare([string]$left.relative_path,[string]$right.relative_path)
    })
    $script:BaseProof=[ordered]@{
        schema='tablet-c1b-read-only-artifact-proof/v1';policy='tl1-c1b-read-only/v2';git_sha=$Commit
        build_challenge_sha256=Get-TL1C1aSha256Text $Challenge;application_id='dev.magina.gateway'
        accessibility_service_component='dev.magina.gateway.a11y.GatewayA11yService'
        provider_component='dev.magina.gateway.tablet.c1b.TabletC1bContentProvider'
        provider_authority='dev.magina.gateway.tablet.c1b';forbidden_match_count=[long]0
        manifest_mutating_capability_count=[long]0;manifest_extra_component_count=[long]0
        axml_parser=[ordered]@{tool='aapt2';build_tools_version='35.0.0';aapt2_relative_path='build-tools/35.0.0/aapt2.exe';aapt2_sha256='sha256:cbfe5deda5f7074ce47b6f33818b456ee8046a076a11af13e29c837d3c80c564'}
        dependency_allowlist=[ordered]@{passed=$true;resolved_artifacts=@(
            [ordered]@{coordinate='org.jetbrains.kotlin:kotlin-stdlib:2.0.20';artifact_sha256='sha256:fb169596659a518357c4b2c16f43dc75ab1c4980565ed4b4a317a050e5e39006'}
            [ordered]@{coordinate='org.jetbrains:annotations:13.0';artifact_sha256='sha256:ace2a10dc8e2d5fd34925ecac03e4988b2c0f851650c94b8cef49ba1bd111478'}
        )}
        named_read_only_waivers=@([ordered]@{id='accessibility-node-refresh-read-freshness';relative_path='app/gateway/src/main/java/dev/magina/gateway/tablet/c1b/AndroidTabletC1bSource.kt';exact_invocation='node.androidNode.refresh()';count=1})
        dex_dependency_string_waivers=@('FileOutputStream','forName','getMethod','java/lang/Runtime','java/lang/reflect','java/nio/file/Files')
        scanned_sources=$sources
        scanned_build_inputs=$buildInputs
        variants=@(
            [ordered]@{name='debug';apk_relative_path=$script:TL1C1bDebugApkRelativePath;apk_sha256=Get-TL1C1aFileSha256 $script:DebugApk;merged_manifest_sha256=Get-TL1C1aFileSha256 $debugManifest;packaged_manifest_sha256=$debugDex.PackagedManifestSha256;packaged_manifest_axml_dump_sha256='sha256:'+'d'*64;packaged_a11y_axml_dump_sha256='sha256:'+'e'*64;packaged_manifest_exact_tree_verified=$true;packaged_a11y_exact_tree_verified=$true;dex_entries=@($debugDex.Entries|ForEach-Object{[ordered]@{relative_path=$_.RelativePath;sha256=$_.Sha256}})}
            [ordered]@{name='release';apk_relative_path=$script:TL1C1bReleaseApkRelativePath;apk_sha256=Get-TL1C1aFileSha256 $releaseApk;merged_manifest_sha256=Get-TL1C1aFileSha256 $releaseManifest;packaged_manifest_sha256=$releaseDex.PackagedManifestSha256;packaged_manifest_axml_dump_sha256='sha256:'+'f'*64;packaged_a11y_axml_dump_sha256='sha256:'+'a'*64;packaged_manifest_exact_tree_verified=$true;packaged_a11y_exact_tree_verified=$true;dex_entries=@($releaseDex.Entries|ForEach-Object{[ordered]@{relative_path=$_.RelativePath;sha256=$_.Sha256}})}
        )
    }

    Test-Case 'valid proof 独立复算 APK/manifest/DEX/source' {
        Write-Proof $script:BaseProof
        $result=Invoke-ProofCheck
        Assert-True ($result.Debug.ApkSha256-ceq$script:BaseProof.variants[0].apk_sha256) 'debug APK binding 缺失'
        Assert-True ($result.Debug.DexEntryCount-eq3) 'debug multidex 全量 binding 缺失'
        Assert-True ($result.Release.DexSha256-ceq$script:BaseProof.variants[1].dex_entries[0].sha256) 'release DEX binding 缺失'
        Assert-True ($result.Debug.PackagedA11yAxmlDumpSha256-ceq$script:BaseProof.variants[0].packaged_a11y_axml_dump_sha256) 'packaged AXML dump hash binding 缺失'
        Assert-True ($result.ForbiddenMatchCount-eq0-and$result.DependencyAllowlistVerified) 'zero/allowlist proof 缺失'
    }
    Test-Case 'proof/debug/release deny-write guard 绑定并持续持有' {
        Write-Proof $script:BaseProof
        $proofGuard=Open-TL1C1bArtifactGuard $TestRoot $script:ProofPath
        $debugGuard=Open-TL1C1bArtifactGuard $TestRoot $script:DebugApk
        $releaseGuard=Open-TL1C1bArtifactGuard $TestRoot $releaseApk
        try{
            $result=Assert-TL1C1bReadOnlyArtifactProof -RepoRoot $TestRoot -ProofPath $script:ProofPath `
                -ProofSchemaPath $script:Schema -ExpectedCommitSha $Commit -BuildChallenge $Challenge `
                -DebugApkPath $script:DebugApk -Aapt2TrustBinding $script:Aapt2TrustBinding `
                -ProofGuard $proofGuard -DebugApkGuard $debugGuard -ReleaseApkGuard $releaseGuard
            Assert-True ($result.ProofSha256-ceq$proofGuard.Sha256) 'proof guard hash 未绑定'
            Assert-Throws {
                $writer=[IO.File]::Open($script:DebugApk,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $writer.Dispose()
            } 'debug APK guard 未阻止写入'
        }finally{$releaseGuard.Guard.Dispose();$debugGuard.Guard.Dispose();$proofGuard.Guard.Dispose()}
    }
    Test-Case '大于 1 MiB artifact 以流式 CreateNew/flush/atomic move 归档并持锁' {
        $source=Join-Path $TestRoot 'app\tablet-c1b-probe\build\large-source.apk'
        $sourceParent=Split-Path $source -Parent;New-Item -ItemType Directory -Force $sourceParent|Out-Null
        $bytes=[byte[]]::new(1MB+17);for($index=0;$index-lt$bytes.Length;$index+=4096){$bytes[$index]=[byte]($index%251)}
        [IO.File]::WriteAllBytes($source,$bytes);[Array]::Clear($bytes,0,$bytes.Length)
        $sourceGuard=Open-TL1C1bArtifactGuard $TestRoot $source
        $destination=Join-Path $TestRoot 'app\tablet-c1b-probe\build\archive\large.apk'
        New-Item -ItemType Directory -Force (Split-Path $destination -Parent)|Out-Null
        $archiveGuard=$null
        try{
            $archiveGuard=Copy-TL1C1bGuardedArtifactAtomic $TestRoot $sourceGuard $destination $sourceGuard.Sha256
            Assert-True ((Get-Item -LiteralPath $destination).Length-eq(1MB+17)) '大 artifact byte count 漂移'
            Assert-True ($archiveGuard.Sha256-ceq$sourceGuard.Sha256) '大 artifact archive hash 漂移'
            Assert-Throws {Copy-TL1C1bGuardedArtifactAtomic $TestRoot $sourceGuard $destination $sourceGuard.Sha256|Out-Null} 'archive overwrite 未拒绝'
            Assert-Throws {$writer=[IO.File]::Open($destination,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);$writer.Dispose()} 'archive guard 未阻止写入'
        }finally{if($null-ne$archiveGuard){$archiveGuard.Guard.Dispose()};$sourceGuard.Guard.Dispose()}
    }
    Test-Case 'artifact hardlink 在证明前拒绝' {
        $link=Join-Path (Split-Path $script:DebugApk -Parent) 'debug-hardlink.apk'
        New-Item -ItemType HardLink -Path $link -Target $script:DebugApk|Out-Null
        try{Assert-Throws {Open-TL1C1bArtifactGuard $TestRoot $script:DebugApk|Out-Null} 'artifact hardlink 未拒绝'}
        finally{Remove-Item -LiteralPath $link -Force}
    }
    Test-Case 'schema 必须是仓内固定路径且不能替代机械常量' {
        Write-Proof $script:BaseProof
        Assert-Throws {
            Assert-TL1C1bReadOnlyArtifactProof -RepoRoot $TestRoot -ProofPath $script:ProofPath `
                -ProofSchemaPath $SourceSchema -ExpectedCommitSha $Commit -BuildChallenge $Challenge `
                -DebugApkPath $script:DebugApk -Aapt2TrustBinding $script:Aapt2TrustBinding|Out-Null
        } '外部 schema 未拒绝'
        $schemaBytes=[IO.File]::ReadAllBytes($script:Schema)
        try{
            Write-Utf8 $script:Schema '{"type":"object"}'
            $proof=Copy-Value $script:BaseProof;$proof.forbidden_match_count=1;Write-Proof $proof
            Assert-Throws {Invoke-ProofCheck|Out-Null} '替代 schema 放行非零能力'
        }finally{[IO.File]::WriteAllBytes($script:Schema,$schemaBytes);[Array]::Clear($schemaBytes,0,$schemaBytes.Length)}
    }
    foreach($mutation in @('extra','commit','challenge','source_path','source_hash','build_input_path','build_input_hash','forbidden','dependency','dependency_hash','named_waiver','dex_waiver','aapt2_path','aapt2_hash','variant_order','apk_path','apk_hash','manifest_hash','packaged_manifest_hash','packaged_manifest_dump_hash','packaged_a11y_dump_hash','packaged_manifest_exact','packaged_a11y_exact','dex_path','dex_hash','dex_second_hash')){
        Test-Case "mutation fail closed: $mutation" {
            $proof=Copy-Value $script:BaseProof
            switch($mutation){
                extra{$proof|Add-Member -NotePropertyName extra -NotePropertyValue $true}
                commit{$proof.git_sha='c'*40}
                challenge{$proof.build_challenge_sha256='sha256:'+'c'*64}
                source_path{$proof.scanned_sources[0].relative_path='app/gateway/src/main/java/extra.kt'}
                source_hash{$proof.scanned_sources[0].sha256='sha256:'+'c'*64}
                build_input_path{$proof.scanned_build_inputs[0].relative_path='app/extra.gradle.kts'}
                build_input_hash{$proof.scanned_build_inputs[0].sha256='sha256:'+'c'*64}
                forbidden{$proof.forbidden_match_count=1}
                dependency{$proof.dependency_allowlist.resolved_artifacts[0].coordinate='evil:runtime:1'}
                dependency_hash{$proof.dependency_allowlist.resolved_artifacts[0].artifact_sha256='sha256:'+'c'*64}
                named_waiver{$proof.named_read_only_waivers[0].count=2}
                dex_waiver{$proof.dex_dependency_string_waivers[0]='evil'}
                aapt2_path{$proof.axml_parser.aapt2_relative_path='build-tools/34.0.0/aapt2.exe'}
                aapt2_hash{$proof.axml_parser.aapt2_sha256='sha256:'+'c'*64}
                variant_order{$proof.variants=@($proof.variants[1],$proof.variants[0])}
                apk_path{$proof.variants[0].apk_relative_path=$script:TL1C1bReleaseApkRelativePath}
                apk_hash{$proof.variants[0].apk_sha256='sha256:'+'c'*64}
                manifest_hash{$proof.variants[0].merged_manifest_sha256='sha256:'+'c'*64}
                packaged_manifest_hash{$proof.variants[0].packaged_manifest_sha256='sha256:'+'c'*64}
                packaged_manifest_dump_hash{$proof.variants[0].packaged_manifest_axml_dump_sha256='invalid'}
                packaged_a11y_dump_hash{$proof.variants[0].packaged_a11y_axml_dump_sha256='invalid'}
                packaged_manifest_exact{$proof.variants[0].packaged_manifest_exact_tree_verified=$false}
                packaged_a11y_exact{$proof.variants[0].packaged_a11y_exact_tree_verified=$false}
                dex_path{$proof.variants[0].dex_entries[1].relative_path='classes9.dex'}
                dex_hash{$proof.variants[0].dex_entries[0].sha256='sha256:'+'c'*64}
                dex_second_hash{$proof.variants[0].dex_entries[1].sha256='sha256:'+'c'*64}
            }
            Write-Proof $proof
            Assert-Throws {Invoke-ProofCheck|Out-Null} "$mutation proof 欺骗未拒绝"
        }
    }
    Test-Case 'source 文件写后漂移 fail closed' {
        Write-Proof $script:BaseProof
        $relative=[string]$script:BaseProof.scanned_sources[0].relative_path
        $path=Join-Path $TestRoot ($relative-replace'/','\')
        $original=[IO.File]::ReadAllBytes($path)
        try{[IO.File]::WriteAllText($path,'tampered',[Text.UTF8Encoding]::new($false));Assert-Throws {Invoke-ProofCheck|Out-Null} 'source 文件漂移未拒绝'}
        finally{[IO.File]::WriteAllBytes($path,$original);[Array]::Clear($original,0,$original.Length)}
    }
}finally{
    $safe=[IO.Path]::GetFullPath($TestRoot);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($safe)-cne$temp){throw 'artifact proof test 清理目标越界。'}
    if($env:TL1_C1B_KEEP_ARTIFACT_TEMP-ceq'1'){
        [Console]::Error.WriteLine("C1b artifact proof temp kept: $safe")
    }elseif(Test-Path -LiteralPath $safe){Remove-Item -LiteralPath $safe -Recurse -Force}
}

Write-Output "tablet-layout-c1b artifact proof offline: $script:Passed passed, $script:Failed failed"
if($script:Failed-ne0){exit 1}
