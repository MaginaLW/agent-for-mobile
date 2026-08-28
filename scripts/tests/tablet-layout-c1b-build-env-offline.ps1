#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-build-env.ps1')
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1')

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) `
    ('tablet-layout-c1b-build-env-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0
$script:Failed = 0

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

function Write-SyntheticFile(
    [string]$Root,
    [string]$RelativePath,
    [string]$Content
) {
    $path = Join-Path $Root ($RelativePath.Replace('/', '\'))
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
}

function New-SyntheticJdk([string]$Name) {
    $root = Join-Path $TestRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Write-SyntheticFile $root 'bin/java.exe' 'synthetic java executable bytes'
    Write-SyntheticFile $root 'bin/server/jvm.dll' 'synthetic JVM library bytes'
    Write-SyntheticFile $root 'release' 'JAVA_VERSION="21.0.5"'
    Write-SyntheticFile $root 'lib/modules' 'synthetic module image bytes'
    Write-SyntheticFile $root 'legal/readme.txt' 'synthetic legal text'
    return $root
}

function New-SyntheticGradle([string]$Name) {
    $root = Join-Path $TestRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Write-SyntheticFile $root 'bin/gradle.bat' '@echo synthetic Gradle must never execute'
    Write-SyntheticFile $root 'init.d/readme.txt' 'synthetic init directory readme'
    Write-SyntheticFile $root 'lib/gradle-gradle-cli-main-8.9.jar' 'synthetic CLI main bytes'
    Write-SyntheticFile $root 'lib/agents/gradle-instrumentation-agent-8.9.jar' `
        'synthetic instrumentation agent bytes'
    Write-SyntheticFile $root 'lib/plugins/plugin.jar' 'synthetic plugin bytes'
    return $root
}

function New-SyntheticRepo([string]$Name) {
    $root = Join-Path $TestRoot $Name
    [IO.Directory]::CreateDirectory((Join-Path $root 'app')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root 'app\tablet-c1b-probe')) |
        Out-Null
    Write-SyntheticFile $root 'app/settings.gradle.kts' 'rootProject.name = "synthetic"'
    Write-SyntheticFile $root 'app/build.gradle.kts' 'plugins {}'
    Write-SyntheticFile $root 'app/gradle/wrapper/gradle-wrapper.jar' 'synthetic wrapper jar'
    Write-SyntheticFile $root 'app/src/main/java/example/Probe.kt' 'class Probe'
    Write-SyntheticFile $root 'app/src/main/res/xml/probe.xml' '<probe />'
    Write-SyntheticFile $root 'docs/proof.schema.json' '{}'
    $gitRoot = Join-Path $root 'Git'
    Write-SyntheticFile $gitRoot 'cmd/git.exe' 'synthetic Git launcher bytes'
    Write-SyntheticFile $gitRoot 'mingw64/bin/git.exe' 'synthetic Git implementation bytes'
    $gitLibexec = Join-Path $gitRoot 'mingw64\libexec\git-core'
    [IO.Directory]::CreateDirectory($gitLibexec) | Out-Null
    try {
        New-Item -ItemType HardLink `
            -Path (Join-Path $gitLibexec 'git.exe') `
            -Target (Join-Path $gitRoot 'mingw64\bin\git.exe') `
            -ErrorAction Stop | Out-Null
    } catch {
        throw "synthetic Git hardlink test prerequisite 不可用：$($_.Exception.Message)"
    }
    Write-SyntheticFile $gitRoot 'mingw64/bin/libcurl-4.dll' 'synthetic libcurl bytes'
    Write-SyntheticFile $gitRoot 'mingw64/bin/libssl-3-x64.dll' 'synthetic libssl bytes'
    Write-SyntheticFile $gitRoot 'mingw64/bin/libcrypto-3-x64.dll' 'synthetic libcrypto bytes'
    Write-SyntheticFile $gitRoot 'etc/gitconfig' '[core]'
    Write-SyntheticFile $root 'tools/debug.keystore' 'synthetic debug keystore bytes'
    return [pscustomobject][ordered]@{
        Root = $root
        GitRoot = $gitRoot
        GitPath = Join-Path $gitRoot 'cmd\git.exe'
        DebugKeystorePath = Join-Path $root 'tools\debug.keystore'
        InputPaths = [string[]]@(
            'app/build.gradle.kts'
            'app/gradle/wrapper/gradle-wrapper.jar'
            'app/settings.gradle.kts'
            'app/src/main/java/example/Probe.kt'
            'app/src/main/res/xml/probe.xml'
            'docs/proof.schema.json'
        )
        InputDirectories = [string[]]@(
            'app/src/main/java'
            'app/src/main/res'
        )
    }
}

function New-SyntheticAndroidSdk([string]$Name) {
    $root = Join-Path $TestRoot $Name
    $buildTools = Join-Path $root 'build-tools\35.0.0'
    $platform = Join-Path $root 'platforms\android-35'
    $platformTools = Join-Path $root 'platform-tools'
    [IO.Directory]::CreateDirectory($buildTools) | Out-Null
    [IO.Directory]::CreateDirectory($platform) | Out-Null
    [IO.Directory]::CreateDirectory($platformTools) | Out-Null
    Write-SyntheticFile $buildTools 'source.properties' 'Pkg.Revision=35.0.0'
    Write-SyntheticFile $buildTools 'package.xml' '<build-tools />'
    Write-SyntheticFile $buildTools 'aapt2.exe' 'synthetic aapt2 bytes'
    Write-SyntheticFile $buildTools 'lib/apksigner.jar' 'synthetic apksigner bytes'
    Write-SyntheticFile $platform 'android.jar' 'synthetic android API bytes'
    Write-SyntheticFile $platform 'source.properties' 'AndroidVersion.ApiLevel=35'
    Write-SyntheticFile $platform 'package.xml' '<platform />'
    Write-SyntheticFile $platform 'framework.aidl' 'synthetic framework aidl'
    Write-SyntheticFile $platform 'core-for-system-modules.jar' 'synthetic core modules'
    Write-SyntheticFile $platform 'data/res/values.xml' '<resources />'
    Write-SyntheticFile $platformTools 'package.xml' '<platform-tools />'
    Write-SyntheticFile $platformTools 'source.properties' 'Pkg.Revision=37.0.1'
    Write-SyntheticFile $platformTools 'adb.exe' 'synthetic adb bytes'
    return [pscustomobject][ordered]@{
        Root = $root
        BuildToolsRoot = $buildTools
        PlatformRoot = $platform
        PlatformToolsRoot = $platformTools
    }
}

function Get-IndependentTreeProof([string]$Root) {
    $canonical = [IO.Path]::GetFullPath($Root)
    $relativePaths = [string[]]@(Get-ChildItem -LiteralPath $canonical -File -Recurse -Force |
        ForEach-Object {
            [IO.Path]::GetRelativePath($canonical, $_.FullName).Replace('\', '/')
        })
    [Array]::Sort($relativePaths, [StringComparer]::Ordinal)
    $entries = [Collections.Generic.List[object]]::new()
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($relative in $relativePaths) {
        $path = Join-Path $canonical ($relative.Replace('/', '\'))
        $sha256 = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).
            Hash.ToLowerInvariant()
        $entries.Add([pscustomobject][ordered]@{
            RelativePath = $relative
            Sha256 = $sha256
        })
        $lines.Add("$relative=$sha256")
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($lines -join "`n")
    try {
        $catalog = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)
        ).ToLowerInvariant()
    } finally {
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    return [pscustomobject][ordered]@{
        Entries = $entries.ToArray()
        FileCount = $entries.Count
        CatalogSha256 = $catalog
    }
}

function Get-IndependentCombinedTreeProof([object[]]$Trees) {
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($tree in $Trees) {
        $root = [IO.Path]::GetFullPath([string]$tree.Root)
        foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse -Force) {
            $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
            $entries.Add([pscustomobject][ordered]@{
                RelativePath = ([string]$tree.Prefix + '/' + $relative)
                Sha256 = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            })
        }
    }
    $array = $entries.ToArray()
    [Array]::Sort($array, [Comparison[object]]{
        param($left, $right)
        [StringComparer]::Ordinal.Compare(
            [string]$left.RelativePath, [string]$right.RelativePath)
    })
    $lines = @($array | ForEach-Object { "$($_.RelativePath)=$($_.Sha256)" })
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($lines -join "`n")
    try {
        return [pscustomobject][ordered]@{
            FileCount = $array.Count
            CatalogSha256 = 'sha256:' + [Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
    } finally {
        if ($bytes.Length -ne 0) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-SyntheticJdkKeyFiles([string]$Root) {
    $result = [ordered]@{}
    foreach ($relative in @('bin/java.exe', 'bin/server/jvm.dll', 'release', 'lib/modules')) {
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        $result[$relative] = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).
            Hash.ToLowerInvariant()
    }
    return $result
}

function Get-SyntheticGitKeyFiles([string]$Root) {
    $result = [ordered]@{}
    foreach ($relative in @(
        'cmd/git.exe', 'mingw64/bin/git.exe',
        'mingw64/libexec/git-core/git.exe', 'mingw64/bin/libcurl-4.dll',
        'mingw64/bin/libssl-3-x64.dll', 'mingw64/bin/libcrypto-3-x64.dll'
    )) {
        $path = Join-Path $Root ($relative.Replace('/', '\'))
        $result[$relative] = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).
            Hash.ToLowerInvariant()
    }
    return $result
}

$SyntheticSignatureReader = {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'synthetic signature path missing' }
    return [pscustomobject][ordered]@{
        status = 'Valid'
        subject = 'CN="Oracle America, Inc.", O="Oracle America, Inc.", L=Redwood City, S=California, C=US'
        certificate_sha256 = 'sha256:4b59d847d7187ed910590d52798fd7e6fcb13396092fdbc1fe43b2311aab6eeb'
    }
}


$SyntheticGitSignatureReader = {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'synthetic Git signature path missing' }
    return [pscustomobject][ordered]@{
        status = 'Valid'
        subject = 'CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE'
        certificate_sha256 = 'sha256:1668941fff36fec818a596ffde6589f34daa6c6434069e60f356b7755f084e63'
    }
}

function Open-SyntheticTrustGuard([string]$Name) {
    $repo = New-SyntheticRepo ($Name + '-repo')
    $jdk = New-SyntheticJdk ($Name + '-jdk')
    $androidSdk = New-SyntheticAndroidSdk ($Name + '-android-sdk')
    $gradleSource = New-SyntheticGradle ($Name + '-gradle-source')
    $jdkProof = Get-IndependentTreeProof $jdk
    $gradleProof = Get-IndependentTreeProof $gradleSource
    $gitProof = Get-IndependentTreeProof $repo.GitRoot
    $buildToolsProof = Get-IndependentTreeProof $androidSdk.BuildToolsRoot
    $platformProof = Get-IndependentTreeProof $androidSdk.PlatformRoot
    $platformToolsProof = Get-IndependentTreeProof $androidSdk.PlatformToolsRoot
    $isolatedProof = Get-IndependentCombinedTreeProof @(
        [pscustomobject]@{ Prefix = 'build-tools/35.0.0'; Root = $androidSdk.BuildToolsRoot }
        [pscustomobject]@{ Prefix = 'platform-tools'; Root = $androidSdk.PlatformToolsRoot }
        [pscustomobject]@{ Prefix = 'platforms/android-35'; Root = $androidSdk.PlatformRoot }
    )
    $buildToolsKeys = [ordered]@{}
    foreach ($relative in @('source.properties', 'package.xml', 'lib/apksigner.jar')) {
        $buildToolsKeys[$relative] = 'sha256:' + (Get-FileHash -LiteralPath `
            (Join-Path $androidSdk.BuildToolsRoot $relative) -Algorithm SHA256).
                Hash.ToLowerInvariant()
    }
    $platformToolsKeys = [ordered]@{}
    foreach ($relative in @('source.properties', 'package.xml')) {
        $platformToolsKeys[$relative] = 'sha256:' + (Get-FileHash -LiteralPath `
            (Join-Path $androidSdk.PlatformToolsRoot $relative) -Algorithm SHA256).
                Hash.ToLowerInvariant()
    }
    $platformKeys = [ordered]@{}
    foreach ($relative in @(
        'android.jar', 'source.properties', 'package.xml', 'framework.aidl',
        'core-for-system-modules.jar'
    )) {
        $platformKeys[$relative] = 'sha256:' + (Get-FileHash -LiteralPath `
            (Join-Path $androidSdk.PlatformRoot $relative) -Algorithm SHA256).
                Hash.ToLowerInvariant()
    }
    $guard = Open-TL1C1bBuildEnvironmentTrustGuardCore `
        -RepoRoot $repo.Root `
        -JavaHome $jdk `
        -GradleHome $gradleSource `
        -AndroidSdkRoot $androidSdk.Root `
        -GitPath $repo.GitPath `
        -GradleUserHomeParent $TestRoot `
        -RepositoryInputPaths $repo.InputPaths `
        -RepositoryInputDirectories $repo.InputDirectories `
        -ExpectedJdkFileCount $jdkProof.FileCount `
        -ExpectedJdkCatalogSha256 $jdkProof.CatalogSha256 `
        -ExpectedJdkKeyFiles (Get-SyntheticJdkKeyFiles $jdk) `
        -ExpectedGradleFileCount $gradleProof.FileCount `
        -ExpectedGradleCatalogSha256 $gradleProof.CatalogSha256 `
        -ExpectedAndroidBuildToolsFileCount $buildToolsProof.FileCount `
        -ExpectedAndroidBuildToolsCatalogSha256 $buildToolsProof.CatalogSha256 `
        -ExpectedAndroidBuildToolsKeyFiles $buildToolsKeys `
        -ExpectedAndroidPlatformFileCount $platformProof.FileCount `
        -ExpectedAndroidPlatformCatalogSha256 $platformProof.CatalogSha256 `
        -ExpectedAndroidPlatformKeyFiles $platformKeys `
        -ExpectedAndroidPlatformToolsFileCount $platformToolsProof.FileCount `
        -ExpectedAndroidPlatformToolsCatalogSha256 $platformToolsProof.CatalogSha256 `
        -ExpectedAndroidPlatformToolsKeyFiles $platformToolsKeys `
        -ExpectedIsolatedAndroidSdkFileCount $isolatedProof.FileCount `
        -ExpectedIsolatedAndroidSdkCatalogSha256 $isolatedProof.CatalogSha256 `
        -ExpectedGitFileCount $gitProof.FileCount `
        -ExpectedGitIdentityCount ($gitProof.FileCount - 1) `
        -ExpectedGitInternalHardlinkGroupCount 1 `
        -ExpectedGitCatalogSha256 $gitProof.CatalogSha256 `
        -ExpectedGitKeyFiles (Get-SyntheticGitKeyFiles $repo.GitRoot) `
        -TestOnlySignatureReader $SyntheticSignatureReader `
        -TestOnlyGitSignatureReader $SyntheticGitSignatureReader `
        -TestOnlyExpectedGitRoot $repo.GitRoot `
        -TestOnlyDebugKeystorePath $repo.DebugKeystorePath `
        -TestOnlySynthetic
    return [pscustomobject][ordered]@{
        Guard = $guard
        Repo = $repo
        Jdk = $jdk
        AndroidSdk = $androidSdk
        GradleSource = $gradleSource
        GradleProof = $gradleProof
    }
}

function Close-TestWorkspace($Workspace) {
    foreach ($aclGuard in @(
        $Workspace.RootAclGuard,
        $Workspace.ProcessTempAclGuard,
        $Workspace.KotlinRuntimeAclGuard,
        $Workspace.ProjectCacheAclGuard
    )) { Restore-TL1C1bBuildEnvironmentDirectory $aclGuard }
    foreach ($guard in @(
        $Workspace.InitGradleGuard,
        $Workspace.InitGradleKtsGuard,
        $Workspace.InitDDirectoryBlockerGuard
    )) { $guard.Stream.Dispose() }
    $safe = Assert-TL1C1bBuildEnvironmentCleanupTarget `
        $Workspace.Root $Workspace.Parent $Workspace.Name
    Remove-Item -LiteralPath $safe -Recurse -Force
}

function Install-SyntheticGradleDistribution($Fixture) {
    $root = Join-Path $Fixture.Guard.Workspace.Root `
        'wrapper\dists\gradle-8.9-bin\abcdefgh12345678\gradle-8.9'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Fixture.GradleSource -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $root -Recurse
    }
    return $root
}

function Close-SyntheticFixture($Fixture, [switch]$KeepGradleUserHome) {
    if ($null -eq $Fixture -or $null -eq $Fixture.Guard) { return }
    Close-TL1C1bBuildEnvironmentTrustGuard `
        $Fixture.Guard -KeepGradleUserHome:$KeepGradleUserHome
}

[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
$savedAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$savedAndroidHome = $env:ANDROID_HOME
$env:ANDROID_SDK_ROOT = $null
$env:ANDROID_HOME = $null
$savedDangerousEnvironment = @((Get-ChildItem Env:) | Where-Object {
    $upper = $_.Name.ToUpperInvariant()
    ($script:TL1C1bBuildEnvironmentDangerousExactNames -ccontains $upper) -or
    @($script:TL1C1bBuildEnvironmentDangerousPrefixes | Where-Object {
        $upper.StartsWith($_, [StringComparison]::Ordinal)
    }).Count -ne 0
} | ForEach-Object {
    [pscustomobject]@{ Name = [string]$_.Name; Value = [string]$_.Value }
})
foreach ($entry in $savedDangerousEnvironment) {
    Remove-Item -LiteralPath ("Env:" + $entry.Name)
}
try {
    Test-Case '冻结的 Oracle JDK/Gradle 常量与 threat boundary 必须 exact' {
        Assert-True ($script:TL1C1bBuildEnvironmentJdkVersion -ceq '21.0.5') `
            'JDK version 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentJdkArchiveSha256 -ceq `
            'sha256:6cce98ce38b86737c63912fd1df9ecfee1fe209ab08c0e1e16500f054e67de48') `
            'Oracle archive SHA-256 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentJdkFileCount -eq 418) `
            'Oracle tree file count 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentJdkCatalogSha256 -ceq `
            'sha256:6426cb4a162d91e6b9069014d9ab9e3e7ff79635fe85e66b03e8e1b1c3265ca9') `
            'Oracle tree catalog 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentGradleFileCount -eq 299) `
            'Gradle tree file count 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentGradleCatalogSha256 -ceq `
            'sha256:d0974b974d9471723cccf083f59e8772448b5bb6672f479bddd63897ba665189') `
            'Gradle tree catalog 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentThreatBoundary -match `
            'process-memory injection.*pre-existing writable handles/mappings.*ACL/ownership takeover') `
            'threat boundary 未明确排除同用户内存、pre-existing handles/mappings 与 ACL takeover。'
        Assert-True ($script:TL1C1bBuildEnvironmentThreatBoundary -match `
            'same-user concurrent mutation.*all intentionally writable fresh build working state.*process temp.*module outputs.*post-exit-to-final-guard') `
            'threat boundary 未精确标注 writable fresh caches 的并发变更。'
        Assert-True ($script:TL1C1bBuildEnvironmentGitFileCount -eq 9576 -and
            $script:TL1C1bBuildEnvironmentGitIdentityCount -eq 9489 -and
            $script:TL1C1bBuildEnvironmentGitInternalHardlinkGroupCount -eq 85 -and
            $script:TL1C1bBuildEnvironmentGitCatalogSha256 -ceq `
                'sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458' -and
            $script:TL1C1bBuildEnvironmentGitKeyFiles['cmd/git.exe'] -ceq `
                'sha256:7b7971dd13f0c3a284e538601f2f9770b3a87dfaccb5fb52d68141c67ed22364' -and
            $script:TL1C1bBuildEnvironmentGitKeyFiles['mingw64/bin/git.exe'] -ceq `
                'sha256:1a0043555d254618f2d56c936c3d9a1fbfb878bc878416a133c346bc7835eda9') `
            'Git full-tree frozen constants 漂移。'
        Assert-True ($script:TL1C1bBuildEnvironmentAndroidPlatformFileCount -eq 11163 -and
            $script:TL1C1bBuildEnvironmentAndroidPlatformToolsFileCount -eq 15 -and
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkFileCount -eq 11348 -and
            $script:TL1C1bBuildEnvironmentIsolatedAndroidSdkCatalogSha256 -ceq `
                'sha256:09a7cb46fef3c2b505330e4dfa09abbe4ba739412e8450e97b3458ddbaf473d8') `
            'Android SDK/isolated SDK frozen constants 漂移。'
    }

    Test-Case 'JUnit BOM Gradle module metadata 的 Maven Central SHA-256 必须 exact' {
        [xml]$metadata = Get-Content -LiteralPath `
            (Join-Path $RepoRoot 'app\gradle\verification-metadata.xml') `
            -Raw -Encoding UTF8
        $namespace = [System.Xml.XmlNamespaceManager]::new($metadata.NameTable)
        $namespace.AddNamespace(
            'dv', 'https://schema.gradle.org/dependency-verification')
        $expected = [ordered]@{
            '5.9.2' = 'ab137ba5a8e32c9b066bf9126a1c76dd5614b724ba5c0b02549772b5e9f4cf1f'
            '5.9.3' = 'b401fd25901e582a524aa5343c4b39e28bc56e24961c1069bf2b4bbfcee46b93'
        }
        foreach ($version in $expected.Keys) {
            $components = @($metadata.SelectNodes(
                "/dv:verification-metadata/dv:components/dv:component[@group='org.junit' and @name='junit-bom' and @version='$version']",
                $namespace))
            Assert-True ($components.Count -eq 1) `
                "junit-bom $version component 必须唯一。"
            $module = @($components[0].SelectNodes(
                "dv:artifact[@name='junit-bom-$version.module']", $namespace))
            $pom = @($components[0].SelectNodes(
                "dv:artifact[@name='junit-bom-$version.pom']", $namespace))
            Assert-True ($module.Count -eq 1 -and $pom.Count -eq 1) `
                "junit-bom $version module/pom artifact 必须各唯一。"
            $sha = @($module[0].SelectNodes('dv:sha256', $namespace))
            Assert-True ($sha.Count -eq 1 -and
                [string]$sha[0].value -ceq [string]$expected[$version] -and
                [string]$sha[0].origin -ceq 'Maven Central .sha256') `
                "junit-bom $version module SHA-256/origin 漂移。"
        }
    }

    Test-Case 'GRADLE/JVM/Kotlin/Maven/Ant 环境注入全集 fail closed' {
        foreach ($name in @(
            'GRADLE_OPTS', 'gradle_user_home', 'ORG_GRADLE_PROJECT_secret',
            'SYSTEM_PROP_http_proxy', 'JAVA_TOOL_OPTIONS', '_JAVA_OPTIONS',
            'JDK_JAVA_OPTIONS', 'JAVA_OPTS', 'CLASSPATH', 'KOTLIN_DAEMON_JVMARGS',
            'MAVEN_OPTS', 'ANT_OPTS', 'GIT_CONFIG_GLOBAL', 'git_dir',
            'ANDROID_SDK_HOME', 'ANDROID_USER_HOME', 'ANDROID_PREFS_ROOT',
            'ANDROID_AVD_HOME'
        )) {
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentVariablesClean ([ordered]@{$name = 'inject'})
            } '拒绝环境注入变量' "环境注入变量 $name 未 fail closed。"
        }
        Assert-TL1C1bBuildEnvironmentVariablesClean ([ordered]@{
            JAVA_HOME = 'explicit-only'; PATH = 'synthetic'
        })
    }

    Test-Case 'Oracle signer subject/certificate 仅接受 exact binding' {
        Assert-True (Test-TL1C1bBuildEnvironmentOracleSignerSubject `
            'CN="Oracle America, Inc.", O="Oracle America, Inc.", L=Redwood City, S=California, C=US') `
            '精确 Oracle subject 被拒绝。'
        foreach ($spoof in @(
            'Oracle America, Inc.',
            'CN="Oracle America, Inc. Evil", O="Oracle America, Inc.", L=Redwood City, S=California, C=US',
            'CN=Oracle America, Inc., O=Oracle America, Inc., L=Redwood City, S=California, C=US'
        )) {
            Assert-True (-not (Test-TL1C1bBuildEnvironmentOracleSignerSubject $spoof)) `
                "Oracle subject spoof 被接受：$spoof"
        }
        Assert-True (Test-TL1C1bBuildEnvironmentGitSignerSubject `
            'CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE') `
            '精确 Git signer subject 被拒绝。'
        Assert-True (-not (Test-TL1C1bBuildEnvironmentGitSignerSubject `
            'CN=Johannes Schindelin Evil, O=Johannes Schindelin, L=Bruehl, C=DE')) `
            'Git signer substring spoof 被接受。'
    }

    Test-Case 'C1a Git wrapper 将 controlled environment 与 ClearEnvironment 传到底层' {
        $script:GitProcessCapture = $null
        function Invoke-TL1C1aProcess {
            param(
                [string]$FilePath, [string[]]$Arguments, [string]$Operation,
                [byte[]]$InputBytes, [hashtable]$Environment,
                [switch]$ClearEnvironment, [int]$TimeoutSec, [switch]$AllowFailure
            )
            $script:GitProcessCapture = [pscustomobject][ordered]@{
                FilePath = $FilePath
                Arguments = $Arguments
                Environment = $Environment
                ClearEnvironment = [bool]$ClearEnvironment
                AllowFailure = [bool]$AllowFailure
            }
            return [pscustomobject]@{ ExitCode = 0; Bytes = [byte[]]@(); Text = ''; Stderr = '' }
        }
        [void](Invoke-TL1C1aGit `
            -RepoRoot $RepoRoot `
            -Arguments @('status','--porcelain=v1') `
            -GitPath 'X:\Git\cmd\git.exe' `
            -ProcessEnvironment @{PATH='controlled-git-path';SYSTEMROOT='controlled-root'} `
            -ClearEnvironment -AllowFailure)
        $capture = $script:GitProcessCapture
        Assert-True ($capture.FilePath -ceq 'X:\Git\cmd\git.exe' -and
            $capture.ClearEnvironment -and $capture.AllowFailure -and
            $capture.Environment.PATH -ceq 'controlled-git-path' -and
            $capture.Environment.SYSTEMROOT -ceq 'controlled-root' -and
            $capture.Environment.GIT_CONFIG_NOSYSTEM -ceq '1' -and
            $capture.Environment.GIT_CONFIG_GLOBAL -ceq 'NUL' -and
            $capture.Environment.GIT_CONFIG_COUNT -ceq '0' -and
            $capture.Environment.GIT_TERMINAL_PROMPT -ceq '0' -and
            $capture.Environment.GCM_INTERACTIVE -ceq 'Never' -and
            $capture.Environment.GIT_OPTIONAL_LOCKS -ceq '0') `
            'C1a Git wrapper 未完整下传 controlled/cleared environment。'
    }

    Test-Case 'synthetic ordinary tree catalog 可冻结且 held handles deny write/delete' {
        $tree = New-SyntheticJdk 'tree-lock'
        $proof = Get-IndependentTreeProof $tree
        $guard = Open-TL1C1bBuildEnvironmentTreeGuard `
            $tree $proof.FileCount $proof.CatalogSha256 'synthetic tree'
        try {
            $after = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard
            Assert-True ($after.catalog_sha256 -ceq $proof.CatalogSha256) `
                'synthetic tree catalog 复核漂移。'
            $java = Join-Path $tree 'bin\java.exe'
            Assert-Throws {
                $writer = [IO.File]::Open(
                    $java, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite)
                try { $writer | Out-Null } finally { $writer.Dispose() }
            } 'held tree file 未 deny write。' | Out-Null
            Assert-Throws { [IO.File]::Delete($java) } `
                'held tree file 未 deny delete。' | Out-Null
        } finally { Close-TL1C1bBuildEnvironmentTreeGuard $guard }
    }

    Test-Case 'tree catalog/path 内容漂移在打开 guard 前 fail closed' {
        $tree = New-SyntheticJdk 'catalog-drift'
        $proof = Get-IndependentTreeProof $tree
        [IO.File]::AppendAllText((Join-Path $tree 'release'), 'tamper')
        Assert-ThrowsLike {
            Open-TL1C1bBuildEnvironmentTreeGuard `
                $tree $proof.FileCount $proof.CatalogSha256 'tampered tree' | Out-Null
        } 'catalog SHA-256' 'tree 内容漂移未 fail closed。'

        $tree2 = New-SyntheticJdk 'path-drift'
        $proof2 = Get-IndependentTreeProof $tree2
        [IO.File]::Move((Join-Path $tree2 'legal\readme.txt'),
            (Join-Path $tree2 'legal\renamed.txt'))
        Assert-ThrowsLike {
            Open-TL1C1bBuildEnvironmentTreeGuard `
                $tree2 $proof2.FileCount $proof2.CatalogSha256 'renamed tree' | Out-Null
        } 'catalog SHA-256' 'tree path 漂移未 fail closed。'
    }

    Test-Case 'tree root/descendant junction 在文件冻结前 fail closed' {
        $target = New-SyntheticJdk 'junction-target'
        $rootJunction = Join-Path $TestRoot 'root-junction'
        New-Item -ItemType Junction -Path $rootJunction -Target $target | Out-Null
        try {
            Assert-ThrowsLike {
                Get-TL1C1bBuildEnvironmentTreeInventory $rootJunction | Out-Null
            } 'reparse/link directory' 'tree root junction 未 fail closed。'
        } finally { Remove-Item -LiteralPath $rootJunction -Force }

        $tree = New-SyntheticJdk 'nested-junction-tree'
        $outside = Join-Path $TestRoot 'nested-junction-outside'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $nested = Join-Path $tree 'evil-link'
        New-Item -ItemType Junction -Path $nested -Target $outside | Out-Null
        try {
            Assert-ThrowsLike {
                Get-TL1C1bBuildEnvironmentTreeInventory $tree | Out-Null
            } 'reparse/link entry' 'nested tree junction 未 fail closed。'
        } finally { Remove-Item -LiteralPath $nested -Force }
    }

    Test-Case 'tree file hardlink count 非 1 时 fail closed' {
        $tree = New-SyntheticJdk 'hardlink-tree'
        $proof = Get-IndependentTreeProof $tree
        $alias = Join-Path $TestRoot 'outside-hardlink-alias.bin'
        New-Item -ItemType HardLink -Path $alias -Target `
            (Join-Path $tree 'bin\java.exe') | Out-Null
        try {
            Assert-ThrowsLike {
                Open-TL1C1bBuildEnvironmentTreeGuard `
                    $tree $proof.FileCount $proof.CatalogSha256 'hardlink tree' | Out-Null
            } 'hardlink count.*1' 'tree hardlink 未 fail closed。'
        } finally { Remove-Item -LiteralPath $alias -Force }
    }

    Test-Case 'Git tree 仅接受 catalog 内闭合 hardlink topology' {
        $repo = New-SyntheticRepo 'git-hardlink-topology'
        $proof = Get-IndependentTreeProof $repo.GitRoot
        $guard = Open-TL1C1bBuildEnvironmentTreeGuard `
            -Root $repo.GitRoot `
            -ExpectedFileCount $proof.FileCount `
            -ExpectedCatalogSha256 $proof.CatalogSha256 `
            -Name 'synthetic Git internal hardlinks' `
            -AllowInternalHardlinks `
            -ExpectedIdentityCount ($proof.FileCount - 1) `
            -ExpectedInternalHardlinkGroupCount 1
        try {
            $binding = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard
            Assert-True ($binding.identity_count -eq ($proof.FileCount - 1) -and
                $binding.internal_hardlink_group_count -eq 1 -and
                $binding.hardlink_topology_internal) `
                'Git internal hardlink topology binding 漂移。'
        } finally { Close-TL1C1bBuildEnvironmentTreeGuard $guard }

        $outsideAlias = Join-Path $TestRoot 'git-outside-hardlink.exe'
        try {
            New-Item -ItemType HardLink -Path $outsideAlias `
                -Target (Join-Path $repo.GitRoot 'cmd\git.exe') -ErrorAction Stop |
                Out-Null
            Assert-ThrowsLike {
                Open-TL1C1bBuildEnvironmentTreeGuard `
                    -Root $repo.GitRoot `
                    -ExpectedFileCount $proof.FileCount `
                    -ExpectedCatalogSha256 $proof.CatalogSha256 `
                    -Name 'synthetic Git external hardlink' `
                    -AllowInternalHardlinks `
                    -ExpectedIdentityCount ($proof.FileCount - 1) `
                    -ExpectedInternalHardlinkGroupCount 1 | Out-Null
            } '闭合在冻结 root/catalog' 'Git root 外 hardlink 未 fail closed。'
        } finally {
            if (Test-Path -LiteralPath $outsideAlias -PathType Leaf) {
                Remove-Item -LiteralPath $outsideAlias -Force
            }
        }
    }

    Test-Case 'fresh GRADLE_USER_HOME 空 init 文件持锁且 init.d directory 被阻断' {
        $workspace = New-TL1C1bBuildEnvironmentWorkspace $TestRoot $RepoRoot
        try {
            Assert-TL1C1bBuildEnvironmentWorkspaceUnchanged $workspace
            foreach ($guard in @(
                $workspace.InitGradleGuard,
                $workspace.InitGradleKtsGuard,
                $workspace.InitDDirectoryBlockerGuard
            )) {
                Assert-True ($guard.Stream.Length -eq 0) 'Gradle init sentinel 非空。'
                Assert-Throws {
                    $writer = [IO.File]::Open(
                        $guard.Path, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                        [IO.FileShare]::ReadWrite)
                    try { $writer | Out-Null } finally { $writer.Dispose() }
                } 'Gradle init sentinel 未 deny write。' | Out-Null
                Assert-Throws { [IO.File]::Delete($guard.Path) } `
                    'Gradle init sentinel 未 deny delete。' | Out-Null
            }
            Assert-Throws {
                [IO.Directory]::CreateDirectory((Join-Path $workspace.Root 'init.d')) |
                    Out-Null
            } 'GRADLE_USER_HOME/init.d directory 可被创建。' | Out-Null
        } finally {
            Close-TestWorkspace $workspace
        }
    }

    Test-Case '既有 local.properties/buildSrc/build-logic 在任何 build guard 前拒绝' {
        foreach ($relative in @('local.properties', 'buildSrc', 'build-logic')) {
            $repo = New-SyntheticRepo ('implicit-input-' + $relative.Replace('.', '-'))
            $candidate = Join-Path $repo.Root ('app\' + $relative)
            if ($relative -ceq 'local.properties') {
                [IO.File]::WriteAllText($candidate, 'sdk.dir=untrusted')
            } else {
                [IO.Directory]::CreateDirectory($candidate) | Out-Null
            }
            Assert-ThrowsLike {
                Open-TL1C1bBuildEnvironmentRepoInputGuard $repo.Root | Out-Null
            } '拒绝 ignored/implicit' "既有 app/$relative 未 fail closed。"
        }
        $repo = New-SyntheticRepo 'preexisting-module-output'
        $build = Join-Path $repo.Root 'app\tablet-c1b-probe\build'
        [IO.Directory]::CreateDirectory($build) | Out-Null
        Assert-ThrowsLike {
            New-TL1C1bBuildEnvironmentModuleBuildOutputGuard $repo.Root | Out-Null
        } '必须在 guard 前 absent' '未知既有 module build output 未 fail closed。'
    }

    Test-Case 'synthetic lifecycle 提供 exact bootstrap/build env 与 path-free attestation' {
        $fixture = Open-SyntheticTrustGuard 'lifecycle'
        $workspacePath = $fixture.Guard.Workspace.Root
        $journalPath = $fixture.Guard.RecoveryJournal.Path
        try {
            $bootstrap = Get-TL1C1bBuildEnvironmentBootstrapEnvironment $fixture.Guard
            Assert-True ($bootstrap.Count -eq 21 -and
                $bootstrap.JAVA_HOME -ceq $fixture.Jdk -and
                $bootstrap.ANDROID_SDK_ROOT -ceq $fixture.Guard.AndroidSdkRoot -and
                $bootstrap.ANDROID_HOME -ceq $fixture.Guard.AndroidSdkRoot -and
                $bootstrap.GRADLE_USER_HOME -ceq $workspacePath -and
                $bootstrap.GIT_CONFIG_NOSYSTEM -ceq '1' -and
                $bootstrap.GIT_CONFIG_GLOBAL -ceq 'NUL' -and
                $bootstrap.GIT_OPTIONAL_LOCKS -ceq '0' -and
                $bootstrap.GIT_TERMINAL_PROMPT -ceq '0' -and
                $bootstrap.COMSPEC -ceq $fixture.Guard.HostPaths.CmdPath -and
                $bootstrap.PATHEXT -ceq '.COM;.EXE;.BAT;.CMD' -and
                $bootstrap.TEMP -ceq $fixture.Guard.Workspace.ProcessTempDirectory -and
                $bootstrap.TMP -ceq $fixture.Guard.Workspace.ProcessTempDirectory -and
                $bootstrap.TMPDIR -ceq $fixture.Guard.Workspace.ProcessTempDirectory -and
                $bootstrap.USERPROFILE -ceq $fixture.Guard.Workspace.UserHomeDirectory -and
                $bootstrap.HOME -ceq $fixture.Guard.Workspace.UserHomeDirectory -and
                $bootstrap.ANDROID_USER_HOME -ceq `
                    (Join-Path $fixture.Guard.Workspace.UserHomeDirectory '.android') -and
                -not $bootstrap.ContainsKey('ANDROID_PREFS_ROOT') -and
                $bootstrap.TL1_C1B_BUILD_OUTPUT_ROOT -ceq `
                    (Join-Path $fixture.Repo.Root 'app\tablet-c1b-probe\build') -and
                $bootstrap.KOTLIN_DAEMON_RUN_FILES_PATH -ceq `
                    $fixture.Guard.Workspace.KotlinRuntimeDirectory) `
                'bootstrap Environment hashtable 漂移。'
            Assert-ThrowsLike {
                Get-TL1C1bBuildEnvironmentWrapperInvocation $fixture.Guard | Out-Null
            } '禁止执行 GradleWrapperMain' 'WrapperMain execution API 未 fail closed。'
            $gradleInvocation = Get-TL1C1bBuildEnvironmentGradleInvocation $fixture.Guard
            Assert-True ($gradleInvocation.FilePath -ceq `
                (Join-Path $fixture.Jdk 'bin\java.exe')) `
                'GradleMain 未使用 held JAVA_HOME/bin/java.exe。'
            Assert-True (($gradleInvocation.Arguments -join "`n") -ceq (@(
                '-Xmx64m'
                '-Xms64m'
                ('-javaagent:' + (Join-Path $fixture.GradleSource `
                    'lib\agents\gradle-instrumentation-agent-8.9.jar'))
                '-Dorg.gradle.appname=gradle'
                ('-Djava.io.tmpdir=' + $fixture.Guard.Workspace.ProcessTempDirectory)
                ('-Duser.home=' + $fixture.Guard.Workspace.UserHomeDirectory)
                '-classpath'
                (Join-Path $fixture.GradleSource 'lib\gradle-gradle-cli-main-8.9.jar')
                'org.gradle.launcher.GradleMain'
            ) -join "`n")) 'direct Java GradleMain arguments 漂移。'
            $gradleArguments = Get-TL1C1bBuildEnvironmentGradleArguments $fixture.Guard
            Assert-True (($gradleArguments -join "`n") -ceq (@(
                '--project-cache-dir'
                $fixture.Guard.Workspace.ProjectCacheDirectory
                '-PtabletC1bIsolatedBuild=true'
                '-Pkotlin.incremental=false'
                '-Pkotlin.compiler.execution.strategy=in-process'
            ) -join "`n")) 'Gradle controlled arguments 漂移。'
            Assert-True ((Get-TL1C1bBuildEnvironmentGitBaseArguments) -join "`n" -ceq `
                (@('-c','core.fsmonitor=false','-c','core.untrackedCache=false','-c',
                    'core.hooksPath=NUL','--no-optional-locks') -join "`n")) `
                'Git controlled base arguments 漂移。'
            $post = Complete-TL1C1bBuildEnvironmentBootstrap `
                $fixture.Guard $fixture.GradleSource
            $build = Get-TL1C1bBuildEnvironmentBuildEnvironment $fixture.Guard
            $gitEnvironment = Get-TL1C1bBuildEnvironmentGitEnvironment $fixture.Guard
            $frozen = Assert-TL1C1bBuildEnvironmentFrozen $fixture.Guard
            Assert-True ($build.Count -eq 21 -and
                $build.JAVA_HOME -ceq $fixture.Jdk -and
                $build.GRADLE_USER_HOME -ceq $workspacePath -and
                -not $build.ContainsKey('ANDROID_PREFS_ROOT')) `
                'build Environment hashtable 漂移。'
            Assert-True ($post.schema -ceq 'tablet-layout-c1b-build-environment-trust/v1' -and
                $post.platform -ceq 'windows' -and $post.java_home_explicit -and
                $post.gradle_user_home_fresh -and
                $post.project_cache_fresh -and $post.kotlin_runtime_fresh -and
                $post.inherited_injection_variables_absent -and
                $post.repo_local_properties_empty_guarded -and
                $post.repo_implicit_build_logic_absent -and
                $post.module_build_output_fresh -and
                $post.repository_inputs.file_count -eq $fixture.Repo.InputPaths.Count -and
                $post.git.version -ceq '2.55.0.windows.3' -and
                $post.git.file_count -eq 7 -and $post.git.identity_count -eq 6 -and
                $post.git.internal_hardlink_group_count -eq 1 -and
                $post.git.hardlink_topology_internal -and
                $post.git.child_environment_cleared -and $post.git.minimal_path -and
                $post.git.system_and_global_config_disabled -and
                $post.git.tree_files_deny_write_delete -and
                $post.git.tree_directories_acl_protected -and
                $post.android_sdk.build_tools.version -ceq '35.0.0' -and
                $post.android_sdk.platform.version -ceq 'android-35' -and
                $post.android_sdk.platform_tools.version -ceq '37.0.1' -and
                $post.android_sdk.child_uses_only_isolated_sdk -and
                $post.android_sdk.isolated.dot_known_packages_absent -and
                $post.path_chain_directories_deny_rename -and
                $post.recovery_journal.directory_entry_count -gt 0 -and
                $post.host_process.host_launcher_cmd_not_executed -and
                $post.host_process.runner_direct_launcher_is_java -and
                $post.host_process.comspec_is_os_trust_root -and
                $post.host_process.wrapper_not_executed -and
                $post.gradle.version -ceq '8.9' -and
                $post.gradle.wrapper_not_executed -and
                $post.debug_keystore.isolated_copy_equal -and
                $post.debug_keystore.gradle_lock_precreated -and
                $post.debug_keystore.gradle_lock_identity_guarded -and
                $post.debug_keystore.gradle_lock_deny_delete -and
                $post.debug_keystore.gradle_lock_write_allowed_during_gradle -and
                $post.debug_keystore.post_gradle_lock_seal_required -and
                $post.debug_keystore.post_gradle_lock_zero_length -and
                -not $post.debug_keystore.post_gradle_lock_sealed_achieved -and
                $post.gradle.tree_directories_acl_protected -and
                $post.gradle.init_d_acl_protected) 'post-bootstrap attestation 漂移。'
            $expectedGitEnvironmentKeys = [string[]]@(
                'COMSPEC','GCM_INTERACTIVE','GIT_CONFIG_COUNT','GIT_CONFIG_GLOBAL',
                'GIT_CONFIG_NOSYSTEM','GIT_OPTIONAL_LOCKS','GIT_TERMINAL_PROMPT','HOME',
                'PATH','PATHEXT','SYSTEMROOT','TEMP','TMP','USERPROFILE','WINDIR'
            )
            $actualGitEnvironmentKeys = [string[]]@($gitEnvironment.Keys)
            [Array]::Sort($actualGitEnvironmentKeys, [StringComparer]::Ordinal)
            Assert-True (($actualGitEnvironmentKeys -join "`n") -ceq `
                ($expectedGitEnvironmentKeys -join "`n")) `
                'Git controlled child environment keys 不是 exact allowlist。'
            $expectedGitPath = (Join-Path $fixture.Repo.GitRoot 'cmd') +
                [IO.Path]::PathSeparator +
                (Join-Path $fixture.Repo.GitRoot 'mingw64\bin') +
                [IO.Path]::PathSeparator + $fixture.Guard.HostPaths.SystemDirectory
            Assert-True ($gitEnvironment.PATH -ceq $expectedGitPath -and
                $gitEnvironment.GIT_CONFIG_NOSYSTEM -ceq '1' -and
                $gitEnvironment.GIT_CONFIG_GLOBAL -ceq 'NUL' -and
                $gitEnvironment.GIT_CONFIG_COUNT -ceq '0' -and
                $gitEnvironment.GIT_OPTIONAL_LOCKS -ceq '0' -and
                $gitEnvironment.GIT_TERMINAL_PROMPT -ceq '0' -and
                $gitEnvironment.GCM_INTERACTIVE -ceq 'Never' -and
                $gitEnvironment.USERPROFILE -ceq $fixture.Guard.Workspace.UserHomeDirectory -and
                $gitEnvironment.HOME -ceq $fixture.Guard.Workspace.UserHomeDirectory) `
                'Git controlled child environment/path 漂移。'
            $apkSigner = Get-TL1C1bBuildEnvironmentApkSignerInvocation $fixture.Guard
            Assert-True ($apkSigner.FilePath -ceq (Join-Path $fixture.Jdk 'bin\java.exe') -and
                $apkSigner.Arguments[-2] -ceq '-jar' -and
                $apkSigner.Arguments[-1] -ceq (Join-Path $fixture.Guard.AndroidSdkRoot `
                    'build-tools\35.0.0\lib\apksigner.jar')) `
                'apksigner 未使用 held Java + isolated held JAR。'
            $json = $frozen | ConvertTo-Json -Depth 10 -Compress
            Assert-True (-not $json.Contains($fixture.Jdk) -and
                -not $json.Contains($workspacePath) -and
                -not $json.Contains($fixture.Repo.Root) -and
                -not $json.Contains($TestRoot)) `
                'attestation 泄露本机绝对路径。'
        } finally { Close-SyntheticFixture $fixture }
        Assert-True (-not (Test-Path -LiteralPath $workspacePath)) `
            'finally 未删除专用 GRADLE_USER_HOME。'
        Assert-True (-not (Test-Path -LiteralPath $journalPath)) `
            '正常 close 未删除 ACL recovery journal。'
        Assert-True (-not (Test-Path -LiteralPath `
            (Join-Path $fixture.Repo.Root 'app\tablet-c1b-probe\build'))) `
            'finally 未删除 fresh module build output。'
    }

    Test-Case '运行期新增危险环境变量触发 pre/frozen recheck fail closed' {
        $fixture = Open-SyntheticTrustGuard 'environment-drift'
        $saved = $env:JAVA_TOOL_OPTIONS
        try {
            $env:JAVA_TOOL_OPTIONS = '-javaagent:evil.jar'
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentPreBootstrap $fixture.Guard | Out-Null
            } '拒绝环境注入变量' '运行期 JAVA_TOOL_OPTIONS 漂移未 fail closed。'
        } finally {
            $env:JAVA_TOOL_OPTIONS = $saved
            Close-SyntheticFixture $fixture
        }
    }

    Test-Case 'held tree 新增 file/directory 会被 frozen recheck 检出' {
        $tree = New-SyntheticJdk 'held-drift'
        $proof = Get-IndependentTreeProof $tree
        $guard = Open-TL1C1bBuildEnvironmentTreeGuard `
            $tree $proof.FileCount $proof.CatalogSha256 'held drift tree'
        try {
            $extraFile = Join-Path $tree 'extra.bin'
            [IO.File]::WriteAllText($extraFile, 'extra')
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard | Out-Null
            } 'file count 漂移' '新增 tree file 未被复核检出。'
            [IO.File]::Delete($extraFile)
            $extraDirectory = Join-Path $tree 'empty-extra-directory'
            [IO.Directory]::CreateDirectory($extraDirectory) | Out-Null
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard | Out-Null
            } 'directory count 漂移' '新增 tree directory 未被复核检出。'
            [IO.Directory]::Delete($extraDirectory)
            [void](Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard)
        } finally { Close-TL1C1bBuildEnvironmentTreeGuard $guard }
    }

    Test-Case 'JDK/Gradle 全目录 ACL 阻止 transient add/delete 并在 finally 恢复' {
        $fixture = Open-SyntheticTrustGuard 'acl-restore'
        $workspacePath = $fixture.Guard.Workspace.Root
        $gradleRoot = $fixture.GradleSource
        $closed = $false
        try {
            [void](Complete-TL1C1bBuildEnvironmentBootstrap $fixture.Guard $gradleRoot)
            $attackPaths = @(
                (Join-Path $fixture.Jdk 'bin\evil.dll'),
                (Join-Path $fixture.Guard.AndroidSdkRoot `
                    'build-tools\35.0.0\evil.exe'),
                (Join-Path $fixture.Guard.AndroidSdkRoot `
                    'platforms\android-35\evil.jar'),
                (Join-Path $fixture.Guard.AndroidSdkRoot 'platform-tools\evil.exe'),
                (Join-Path $fixture.Repo.GitRoot 'mingw64\bin\evil.dll'),
                (Join-Path $fixture.Repo.GitRoot 'mingw64\libexec\git-core\evil.exe'),
                (Join-Path $gradleRoot 'lib\evil.jar'),
                (Join-Path $gradleRoot 'lib\plugins\evil.jar'),
                (Join-Path $gradleRoot 'init.d\evil.gradle'),
                (Join-Path $fixture.Repo.Root 'app\src\main\java\evil.kt'),
                (Join-Path $fixture.Guard.Workspace.UserHomeDirectory `
                    '.android\repositories.cfg')
            )
            foreach ($evil in $attackPaths) {
                Assert-Throws {
                    [IO.File]::WriteAllText($evil, 'transient malicious input')
                } 'JDK/Gradle/repository directory ACL 未 deny create。' | Out-Null
                Assert-True (-not (Test-Path -LiteralPath $evil)) `
                    'deny-create 测试遗留了 transient attack file。'
            }
            foreach ($blocker in @('buildSrc', 'build-logic')) {
                Assert-Throws {
                    [IO.Directory]::CreateDirectory(
                        (Join-Path $fixture.Repo.Root "app\$blocker")) | Out-Null
                } "app/$blocker blocker 未阻止目录创建。" | Out-Null
            }
            foreach ($guardedFile in @(
                (Join-Path $fixture.Repo.Root 'app\settings.gradle.kts'),
                $fixture.Repo.GitPath,
                (Join-Path $fixture.Repo.GitRoot 'mingw64\bin\git.exe'),
                (Join-Path $fixture.Repo.GitRoot 'mingw64\bin\libcurl-4.dll'),
                $fixture.Repo.DebugKeystorePath,
                (Join-Path $fixture.Guard.Workspace.UserHomeDirectory `
                    '.android\debug.keystore'),
                (Join-Path $fixture.Repo.Root 'app\local.properties')
            )) {
                Assert-Throws {
                    $writer = [IO.File]::Open(
                        $guardedFile, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                        [IO.FileShare]::ReadWrite)
                    try { $writer | Out-Null } finally { $writer.Dispose() }
                } 'repo/Git held file 未 deny write。' | Out-Null
                Assert-Throws { [IO.File]::Delete($guardedFile) } `
                    'repo/Git held file 未 deny delete。' | Out-Null
            }
            $realLockGuard = $fixture.Guard.DebugKeystoreGuard.LockGuard
            $decoyLockPath = Join-Path $TestRoot `
                ('debug-keystore-decoy-' + [guid]::NewGuid().ToString('N') + '.lock')
            $decoyLockGuard = Open-TL1C1bBuildEnvironmentMutableEmptyFileGuard `
                $decoyLockPath 'external decoy debug.keystore.lock'
            try {
                $fixture.Guard.DebugKeystoreGuard.LockGuard = $decoyLockGuard
                Assert-ThrowsLike {
                    Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged `
                        $fixture.Guard.DebugKeystoreGuard | Out-Null
                } 'canonical path binding 漂移' `
                    '外部 decoy lock guard 绕过了 isolated user.home path binding。'
            } finally {
                $fixture.Guard.DebugKeystoreGuard.LockGuard = $realLockGuard
                Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard $decoyLockGuard
                if (Test-Path -LiteralPath $decoyLockPath -PathType Leaf) {
                    [IO.File]::Delete($decoyLockPath)
                }
            }
            $gradleLock = Join-Path $fixture.Guard.Workspace.UserHomeDirectory `
                '.android\debug.keystore.lock'
            Assert-Throws { [IO.File]::Delete($gradleLock) } `
                'precreated debug.keystore.lock 未 deny delete。' | Out-Null
            $lockWriter = [IO.File]::Open(
                $gradleLock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                ([IO.FileShare]::Read -bor [IO.FileShare]::Write))
            try {
                $lockWriter.WriteByte(1)
                $lockWriter.Flush($true)
            } finally { $lockWriter.Dispose() }
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged `
                    $fixture.Guard.DebugKeystoreGuard | Out-Null
            } 'empty-file binding 漂移' `
                '非空 debug.keystore.lock 未被 frozen recheck 检出。'
            $lockWriter = [IO.File]::Open(
                $gradleLock, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                ([IO.FileShare]::Read -bor [IO.FileShare]::Write))
            try {
                $lockWriter.SetLength(0)
                $lockWriter.Flush($true)
            } finally { $lockWriter.Dispose() }
            [void](Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged `
                $fixture.Guard.DebugKeystoreGuard)
            $preSealBinding = Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
                $fixture.Guard -RequireGradle
            $preSealBindingRaw = $preSealBinding | ConvertTo-Json -Depth 20 -Compress
            $postSealBindingRaw = $preSealBindingRaw.Replace(
                '"post_gradle_lock_sealed_achieved":false',
                '"post_gradle_lock_sealed_achieved":true')
            Assert-TL1C1bBuildEnvironmentSealBindingTransition `
                $preSealBindingRaw $postSealBindingRaw
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentSealBindingTransition `
                    $preSealBindingRaw `
                    ($postSealBindingRaw.Replace('"minimal_path":true',
                        '"minimal_path":false'))
            } '除 achieved false→true 外发生漂移' `
                'pre/post full binding 接受了 seal 同时漂移其他字段。'
            Assert-ThrowsLike {
                Seal-TL1C1bBuildEnvironmentDebugKeystoreLock `
                    -TrustGuard $fixture.Guard `
                    -ExpectedTrustGuard ([pscustomobject]@{}) `
                    -ExpectedPreSealBindingRaw $preSealBindingRaw | Out-Null
            } 'trust guard identity 漂移' `
                'post-Gradle seal 接受了不同 trust guard identity。'
            Assert-ThrowsLike {
                Seal-TL1C1bBuildEnvironmentDebugKeystoreLock `
                    -TrustGuard $fixture.Guard `
                    -ExpectedTrustGuard $fixture.Guard `
                    -ExpectedPreSealBindingRaw ($preSealBindingRaw + ' ') | Out-Null
            } '初始 binding.*漂移' `
                'post-Gradle seal 接受了漂移的 pre-seal full binding。'
            $sealedBinding=Seal-TL1C1bBuildEnvironmentDebugKeystoreLock `
                -TrustGuard $fixture.Guard `
                -ExpectedTrustGuard $fixture.Guard `
                -ExpectedPreSealBindingRaw $preSealBindingRaw
            Assert-True ([bool]$fixture.Guard.DebugKeystoreGuard.LockGuard.Sealed) `
                'post-Gradle debug.keystore.lock 未进入 sealed state。'
            Assert-True ([bool]$sealedBinding.debug_keystore.post_gradle_lock_sealed_achieved) `
                'post-Gradle build-environment binding 未记录 seal achieved。'
            Assert-Throws {
                $writer = [IO.File]::Open(
                    $gradleLock, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                    [IO.FileShare]::ReadWrite)
                try { $writer | Out-Null } finally { $writer.Dispose() }
            } 'sealed debug.keystore.lock 未 deny residual writer。' | Out-Null
            [void](Assert-TL1C1bBuildEnvironmentDebugKeystoreGuardUnchanged `
                $fixture.Guard.DebugKeystoreGuard)
            foreach ($directoryBinding in @(
                [pscustomobject]@{
                    Path = Join-Path $fixture.Repo.Root 'app\gradle\wrapper'
                    Destination = Join-Path $fixture.Repo.Root 'app\gradle\wrapper-moved'
                },
                [pscustomobject]@{
                    Path = $fixture.Jdk; Destination = $fixture.Jdk + '-moved'
                },
                [pscustomobject]@{
                    Path = $fixture.Repo.GitRoot
                    Destination = $fixture.Repo.GitRoot + '-moved'
                },
                [pscustomobject]@{
                    Path = $gradleRoot; Destination = $gradleRoot + '-moved'
                },
                [pscustomobject]@{
                    Path = Join-Path $fixture.Guard.AndroidSdkRoot 'build-tools\35.0.0'
                    Destination = (Join-Path $fixture.Guard.AndroidSdkRoot `
                        'build-tools\35.0.0-moved')
                },
                [pscustomobject]@{
                    Path = $fixture.Guard.Workspace.ProjectCacheDirectory
                    Destination = $fixture.Guard.Workspace.ProjectCacheDirectory + '-moved'
                }
            )) {
                Assert-Throws {
                    [IO.Directory]::Move($directoryBinding.Path, $directoryBinding.Destination)
                } 'held directory handle 未 deny rename/root replacement。' | Out-Null
            }
            $projectCacheProbe = Join-Path `
                $fixture.Guard.Workspace.ProjectCacheDirectory 'mutable-cache.bin'
            [IO.File]::WriteAllText($projectCacheProbe, 'allowed Gradle cache output')
            Assert-True (Test-Path -LiteralPath $projectCacheProbe -PathType Leaf) `
                'fresh project cache 未保持可写。'
            [IO.File]::Delete($projectCacheProbe)
            $moduleOutputProbe = Join-Path `
                $fixture.Guard.ModuleBuildOutputDirectory 'classes.bin'
            [IO.File]::WriteAllText($moduleOutputProbe, 'allowed module output')
            Assert-True (Test-Path -LiteralPath $moduleOutputProbe -PathType Leaf) `
                'fresh module output 未保持可写。'
            Close-SyntheticFixture $fixture -KeepGradleUserHome
            $closed = $true
            $postRestoreJdk = Join-Path $fixture.Jdk 'bin\post-restore.dll'
            $postRestoreGit = Join-Path $fixture.Repo.GitRoot 'mingw64\bin\post-restore.dll'
            $postRestoreAndroid = Join-Path `
                $fixture.Guard.AndroidSdkRoot 'build-tools\35.0.0\post-restore.exe'
            $postRestoreGradle = Join-Path $gradleRoot 'lib\post-restore.jar'
            $postRestoreRepo = Join-Path $fixture.Repo.Root 'app\src\main\java\post-restore.kt'
            foreach ($probe in @(
                $postRestoreJdk, $postRestoreGit, $postRestoreAndroid,
                $postRestoreGradle, $postRestoreRepo
            )) {
                [IO.File]::WriteAllText($probe, 'post-restore probe')
                Assert-True (Test-Path -LiteralPath $probe -PathType Leaf) `
                    'finally 未恢复 tree directory 原 ACL。'
                [IO.File]::Delete($probe)
            }
            $safe = Assert-TL1C1bBuildEnvironmentCleanupTarget `
                $workspacePath $fixture.Guard.Workspace.Parent $fixture.Guard.Workspace.Name
            Remove-Item -LiteralPath $safe -Recurse -Force
        } finally {
            if (-not $closed) {
                Close-SyntheticFixture $fixture
            }
        }
    }

    Test-Case 'debug signing nested guard equal-swap fail closed 并清理两套 handles' {
        $fixture = Open-SyntheticTrustGuard 'debug-keystore-nested-swap'
        $closed = $false
        $realGuard = $fixture.Guard.DebugKeystoreGuard
        $decoyGuard = $null
        try {
            [void](Complete-TL1C1bBuildEnvironmentBootstrap `
                $fixture.Guard $fixture.GradleSource)
            $preSealBinding = Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
                $fixture.Guard -RequireGradle
            $preSealBindingRaw =
                $preSealBinding | ConvertTo-Json -Depth 20 -Compress
            $decoyUserHome = Join-Path `
                $fixture.Guard.Workspace.ProcessTempDirectory 'decoy-user-home'
            [IO.Directory]::CreateDirectory(
                (Join-Path $decoyUserHome '.android')) | Out-Null
            $decoyGuard = New-TL1C1bBuildEnvironmentDebugKeystoreGuard `
                -SourcePath $fixture.Repo.DebugKeystorePath `
                -Workspace ([pscustomobject]@{
                    UserHomeDirectory = $decoyUserHome
                })
            $fixture.Guard.DebugKeystoreGuard = $decoyGuard
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged `
                    $fixture.Guard -RequireGradle | Out-Null
            } 'creation-time guard identity 漂移' `
                'outer trust 接受了整套 nested debug signing guard equal-swap。'
            Assert-ThrowsLike {
                Seal-TL1C1bBuildEnvironmentDebugKeystoreLock `
                    -TrustGuard $fixture.Guard `
                    -ExpectedTrustGuard $fixture.Guard `
                    -ExpectedPreSealBindingRaw $preSealBindingRaw | Out-Null
            } 'creation-time guard identity 漂移' `
                'post-Gradle seal 接受了整套 nested debug signing guard equal-swap。'
            Assert-True (-not [bool]$realGuard.LockGuard.Sealed -and
                -not [bool]$decoyGuard.LockGuard.Sealed) `
                'nested equal-swap 拒绝后仍错误 seal 了 real/decoy lock。'
            Assert-ThrowsLike {
                Close-SyntheticFixture $fixture
            } 'final frozen recheck:.*creation-time guard identity 漂移' `
                'nested equal-swap cleanup 未保留原始 frozen recheck 异常。'
            $closed = $true
            Assert-True ([bool]$fixture.Guard.Disposed -and
                -not (Test-Path -LiteralPath $fixture.Guard.Workspace.Root)) `
                'nested equal-swap cleanup 未完成 trust guard dispose/workspace removal。'
            foreach ($candidate in @($realGuard, $decoyGuard)) {
                foreach ($stream in @(
                    $candidate.SourceGuard.Stream,
                    $candidate.CopyGuard.Stream,
                    $candidate.LockGuard.MutableStream,
                    $candidate.LockGuard.SealStream
                )) {
                    if ($stream -is [IO.FileStream]) {
                        Assert-True ([bool]$stream.SafeFileHandle.IsClosed) `
                            'nested equal-swap cleanup 泄漏了 debug signing file handle。'
                    }
                }
                foreach ($entry in @($candidate.DirectoryAclGuards.Entries)) {
                    Assert-True ([bool]$entry.DirectoryHandle.IsClosed) `
                        'nested equal-swap cleanup 泄漏了 debug signing directory handle。'
                }
            }
        } finally {
            if (-not $closed) {
                $fixture.Guard.DebugKeystoreGuard = $realGuard
                if ($null -ne $decoyGuard) {
                    Close-TL1C1bBuildEnvironmentDebugKeystoreGuard $decoyGuard
                }
                Close-SyntheticFixture $fixture
            }
        }
    }

    Test-Case 'debug.keystore.lock seal 拒绝 residual writer' {
        $root = Join-Path $TestRoot 'debug-keystore-lock-residual-writer'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $path = Join-Path $root 'debug.keystore.lock'
        $guard = $null
        $writer = $null
        try {
            $guard = Open-TL1C1bBuildEnvironmentMutableEmptyFileGuard `
                $path 'residual writer regression'
            $writer = [IO.File]::Open(
                $path, [IO.FileMode]::Open, [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite)
            Assert-Throws {
                Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard $guard
            } 'post-Gradle seal 接受了 residual writer。' | Out-Null
        } finally {
            if ($writer -is [IO.FileStream]) { $writer.Dispose() }
            Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard $guard
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [IO.File]::Delete($path)
            }
            if (Test-Path -LiteralPath $root -PathType Container) {
                [IO.Directory]::Delete($root)
            }
        }
    }

    Test-Case 'debug signing ACL restore 异常仍释放全部 file/directory handles' {
        $root = Join-Path $TestRoot 'debug-keystore-close-failure'
        $userHome = Join-Path $root 'user-home'
        $android = Join-Path $userHome '.android'
        $source = Join-Path $root 'source.keystore'
        [IO.Directory]::CreateDirectory($android) | Out-Null
        [IO.File]::WriteAllText($source, 'synthetic debug keystore')
        $guard = $null
        $originalAclBindings = @()
        try {
            $guard = New-TL1C1bBuildEnvironmentDebugKeystoreGuard `
                -SourcePath $source `
                -Workspace ([pscustomobject]@{ UserHomeDirectory = $userHome })
            $originalAclBindings = @($guard.DirectoryAclGuards.Entries | ForEach-Object {
                [pscustomobject]@{
                    Directory = [string]$_.Directory
                    OriginalSddl = [string]$_.OriginalSddl
                }
            })
            $guard.DirectoryAclGuards.Entries[0].OriginalSddl = 'not-an-sddl'
            Assert-ThrowsLike {
                Close-TL1C1bBuildEnvironmentDebugKeystoreGuard $guard
            } '未完整关闭' 'ACL restore 漂移未 fail closed。'
            foreach ($entry in @($guard.DirectoryAclGuards.Entries)) {
                Assert-True ([bool]$entry.DirectoryHandle.IsClosed) `
                    'ACL restore 异常后仍有 directory handle 未释放。'
            }
            for ($index = $originalAclBindings.Count - 1; $index -ge 0; $index--) {
                $binding = $originalAclBindings[$index]
                $directoryInfo = [IO.DirectoryInfo]::new($binding.Directory)
                $security = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
                $security.SetSecurityDescriptorSddlForm(
                    $binding.OriginalSddl,
                    [Security.AccessControl.AccessControlSections]::Access)
                [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $security)
                $guard.DirectoryAclGuards.Entries[$index].OriginalSddl = `
                    $binding.OriginalSddl
                $guard.DirectoryAclGuards.Entries[$index].Restored = $true
            }
            $originalAclBindings = @()
            foreach ($path in @(
                $guard.LockGuard.Path,
                $guard.CopyGuard.Path,
                $guard.SourceGuard.Path
            )) {
                [IO.File]::Delete([string]$path)
                Assert-True (-not (Test-Path -LiteralPath $path)) `
                    'ACL restore 失败后仍有 file handle 阻止删除。'
            }
        } finally {
            for ($index = $originalAclBindings.Count - 1; $index -ge 0; $index--) {
                $binding = $originalAclBindings[$index]
                $directoryInfo = [IO.DirectoryInfo]::new($binding.Directory)
                $security = [IO.FileSystemAclExtensions]::GetAccessControl($directoryInfo)
                $security.SetSecurityDescriptorSddlForm(
                    $binding.OriginalSddl,
                    [Security.AccessControl.AccessControlSections]::Access)
                [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $security)
            }
            if ($null -ne $guard) {
                Close-TL1C1bBuildEnvironmentMutableEmptyFileGuard `
                    $guard.LockGuard
                Close-TL1C1bBuildEnvironmentExternalFileGuard $guard.CopyGuard
                Close-TL1C1bBuildEnvironmentExternalFileGuard $guard.SourceGuard
            }
            if (Test-Path -LiteralPath $root -PathType Container) {
                [IO.Directory]::Delete($root, $true)
            }
        }
    }

    Test-Case 'ACL recovery journal 防写删、mandatory hash/root binding 且可 crash repair' {
        Assert-True (Test-TL1C1bBuildEnvironmentPathEqual `
            ($TestRoot + [IO.Path]::DirectorySeparatorChar) $TestRoot) `
            'path equality 未规范化 trailing separator。'
        Assert-True (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
            'D:(D;;SD;;;S-1-5-18)(A;;FA;;;S-1-5-18)' `
            'D:AI(D;;SD;;;S-1-5-18)(A;;FA;;;S-1-5-18)') `
            'Windows 自动追加 AI control flag 后等价 DACL 被拒绝。'
        Assert-True (-not (Test-TL1C1bBuildEnvironmentAccessSddlEquivalent `
            'D:(A;;FA;;;S-1-5-18)' 'D:P(A;;FA;;;S-1-5-18)')) `
            'SDDL equivalence 错误忽略了 protected DACL flag。'
        $scope = Join-Path $TestRoot 'recovery-scope'
        $outside = Join-Path $TestRoot 'recovery-wrong-scope'
        $protected = Join-Path $scope 'protected-directory'
        [IO.Directory]::CreateDirectory($protected) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $journal = New-TL1C1bBuildEnvironmentRecoveryJournal $TestRoot @($scope)
        $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $journal
        $aclGuard = $null
        try {
            Assert-ThrowsLike {
                Protect-TL1C1bBuildEnvironmentDirectory $outside | Out-Null
            } '越出 journal allowed roots' `
                'recovery journal 接受了 allowed roots 外的 ACL target。'
            $aclGuard = Protect-TL1C1bBuildEnvironmentDirectory $protected
            $binding = Get-TL1C1bBuildEnvironmentRecoveryJournalBinding $journal
            Assert-Throws {
                [IO.File]::WriteAllText($journal.Path, 'forged')
            } 'crash journal ACL 未 deny ordinary WriteData。' | Out-Null
            Assert-Throws { [IO.File]::Delete($journal.Path) } `
                'crash journal ACL 未 deny Delete。' | Out-Null
            Assert-Throws {
                [IO.File]::WriteAllText((Join-Path $protected 'evil.bin'), 'evil')
            } 'synthetic protected directory 未 deny create。' | Out-Null
            $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $null
            $aclGuard.DirectoryHandle.Dispose()
            $journal.Stream.Dispose()
            Assert-ThrowsLike {
                Repair-TL1C1bBuildEnvironmentRecoveryJournal `
                    -JournalPath $journal.Path `
                    -ExpectedSha256 ('sha256:' + ('0' * 64)) `
                    -AllowedRoots @($scope) -Confirm:$false | Out-Null
            } 'SHA-256.*不一致' '错误 recovery hash 未 fail closed。'
            Assert-ThrowsLike {
                Repair-TL1C1bBuildEnvironmentRecoveryJournal `
                    -JournalPath $journal.Path `
                    -ExpectedSha256 $binding.sha256 `
                    -AllowedRoots @($outside) -Confirm:$false | Out-Null
            } 'allowed root path 漂移' '越界 recovery allowed root 未 fail closed。'
            $result = Repair-TL1C1bBuildEnvironmentRecoveryJournal `
                -JournalPath $journal.Path `
                -ExpectedSha256 $binding.sha256 `
                -AllowedRoots @($scope) -Confirm:$false
            Assert-True ($result.repaired -and $result.directory_entry_count -eq 1 -and
                -not (Test-Path -LiteralPath $journal.Path)) `
                'crash recovery 未恢复/删除 exact journal。'
            $probe = Join-Path $protected 'post-repair.bin'
            [IO.File]::WriteAllText($probe, 'restored')
            Assert-True (Test-Path -LiteralPath $probe -PathType Leaf) `
                'crash recovery 未恢复 original directory ACL。'
            [IO.File]::Delete($probe)
        } finally {
            $script:TL1C1bBuildEnvironmentActiveRecoveryJournal = $null
            if ($null -ne $aclGuard -and -not $aclGuard.DirectoryHandle.IsClosed) {
                try { Restore-TL1C1bBuildEnvironmentDirectory $aclGuard } catch { }
            }
            if ($journal.Stream -is [IO.FileStream] -and
                -not $journal.Stream.SafeFileHandle.IsClosed) {
                $journal.Stream.Dispose()
            }
        }
    }

    Test-Case 'path-chain handles 阻止 ancestor transient rename/replacement' {
        $ancestor = Join-Path $TestRoot 'ancestor-chain'
        $target = Join-Path $ancestor 'level\target'
        $moved = Join-Path $TestRoot 'ancestor-chain-moved'
        [IO.Directory]::CreateDirectory($target) | Out-Null
        $guard = Open-TL1C1bBuildEnvironmentPathChainGuard @($target)
        try {
            Assert-TL1C1bBuildEnvironmentPathChainGuardUnchanged $guard
            Assert-Throws { [IO.Directory]::Move($ancestor, $moved) } `
                'path-chain ancestor 可被 transient rename。' | Out-Null
        } finally { Close-TL1C1bBuildEnvironmentPathChainGuard $guard }
        [IO.Directory]::Move($ancestor, $moved)
        Assert-True (Test-Path -LiteralPath (Join-Path $moved 'level\target') `
            -PathType Container) 'path-chain close 后仍阻止预期 rename。'
    }

    Test-Case 'Windows logon-session 全局 mutex 串行化全部 C1b build ACL' {
        $first = Open-TL1C1bBuildEnvironmentConcurrencyGuard @($TestRoot)
        try {
            Assert-ThrowsLike {
                Open-TL1C1bBuildEnvironmentConcurrencyGuard @(
                    (Join-Path $TestRoot 'different-trust-tuple')) | Out-Null
            } '当前进程持有' '不同 tuple 绕过了共享 JDK/SDK/Gradle DACL 全局互斥。'
        } finally { Close-TL1C1bBuildEnvironmentConcurrencyGuard $first }
        $afterRelease = Open-TL1C1bBuildEnvironmentConcurrencyGuard @(
            (Join-Path $TestRoot 'after-release'))
        Close-TL1C1bBuildEnvironmentConcurrencyGuard $afterRelease
    }

    Test-Case 'tree guard 接受并冻结超过旧 4096 上限的 synthetic tree' {
        $tree = Join-Path $TestRoot 'large-tree-4097'
        [IO.Directory]::CreateDirectory($tree) | Out-Null
        for ($index = 0; $index -lt 4097; $index++) {
            [IO.File]::WriteAllBytes(
                (Join-Path $tree (('{0:D4}.bin' -f $index))), [byte[]]@($index % 251))
        }
        $proof = Get-IndependentTreeProof $tree
        $guard = Open-TL1C1bBuildEnvironmentTreeGuard `
            $tree $proof.FileCount $proof.CatalogSha256 '4097-file tree'
        try {
            $current = Assert-TL1C1bBuildEnvironmentTreeGuardUnchanged $guard
            Assert-True ($current.file_count -eq 4097) `
                'tree guard 未接受 android-35 所需 >4096 file-count range。'
        } finally { Close-TL1C1bBuildEnvironmentTreeGuard $guard }
    }

    Test-Case 'cleanup target 必须是 expected parent 下的专用随机目录' {
        $workspace = New-TL1C1bBuildEnvironmentWorkspace $TestRoot $RepoRoot
        try {
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentCleanupTarget `
                    $TestRoot $TestRoot $workspace.Name | Out-Null
            } 'cleanup target 越界' 'cleanup 接受了 parent 本身。'
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentCleanupTarget `
                    $workspace.Root $TestRoot 'not-a-c1b-directory' | Out-Null
            } 'cleanup name.*allowlist' 'cleanup 接受了非专用目录名。'
        } finally {
            Close-TestWorkspace $workspace
        }
    }

    Test-Case 'cleanup 遇到 descendant reparse 时拒绝且不触及外部目标' {
        $workspace = New-TL1C1bBuildEnvironmentWorkspace $TestRoot $RepoRoot
        $outside = Join-Path $TestRoot 'cleanup-outside'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $sentinel = Join-Path $outside 'keep.txt'
        [IO.File]::WriteAllText($sentinel, 'keep')
        foreach ($guard in @(
            $workspace.InitGradleGuard,
            $workspace.InitGradleKtsGuard,
            $workspace.InitDDirectoryBlockerGuard
        )) { $guard.Stream.Dispose() }
        Restore-TL1C1bBuildEnvironmentDirectory $workspace.RootAclGuard
        Restore-TL1C1bBuildEnvironmentDirectory $workspace.ProcessTempAclGuard
        Restore-TL1C1bBuildEnvironmentDirectory $workspace.KotlinRuntimeAclGuard
        Restore-TL1C1bBuildEnvironmentDirectory $workspace.ProjectCacheAclGuard
        $junction = Join-Path $workspace.Root 'outside-link'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        try {
            Assert-ThrowsLike {
                Assert-TL1C1bBuildEnvironmentCleanupTarget `
                    $workspace.Root $workspace.Parent $workspace.Name | Out-Null
            } 'reparse/link entry' 'cleanup 接受了 descendant junction。'
            Assert-True ((Get-Content -Raw $sentinel) -ceq 'keep') `
                'cleanup 越界触及外部 sentinel。'
        } finally {
            Remove-Item -LiteralPath $junction -Force
            $safe = Assert-TL1C1bBuildEnvironmentCleanupTarget `
                $workspace.Root $workspace.Parent $workspace.Name
            Remove-Item -LiteralPath $safe -Recurse -Force
        }
    }

    Test-Case 'production core 拒绝 synthetic expectations/test signature reader' {
        $repo = New-SyntheticRepo 'production-core-repo'
        $jdk = New-SyntheticJdk 'production-core-reject'
        $proof = Get-IndependentTreeProof $jdk
        $gitProof = Get-IndependentTreeProof $repo.GitRoot
        Assert-ThrowsLike {
            Open-TL1C1bBuildEnvironmentTrustGuardCore `
                -RepoRoot $repo.Root `
                -JavaHome $jdk `
                -GradleHome (New-SyntheticGradle 'production-core-gradle') `
                -AndroidSdkRoot (New-SyntheticAndroidSdk `
                    'production-core-android-sdk').Root `
                -GitPath $repo.GitPath `
                -GradleUserHomeParent $TestRoot `
                -RepositoryInputPaths $repo.InputPaths `
                -RepositoryInputDirectories $repo.InputDirectories `
                -ExpectedJdkFileCount $proof.FileCount `
                -ExpectedJdkCatalogSha256 $proof.CatalogSha256 `
                -ExpectedJdkKeyFiles (Get-SyntheticJdkKeyFiles $jdk) `
                -ExpectedGitFileCount $gitProof.FileCount `
                -ExpectedGitIdentityCount ($gitProof.FileCount - 1) `
                -ExpectedGitInternalHardlinkGroupCount 1 `
                -ExpectedGitCatalogSha256 $gitProof.CatalogSha256 `
                -ExpectedGitKeyFiles (Get-SyntheticGitKeyFiles $repo.GitRoot) `
                -TestOnlyExpectedGitRoot $repo.GitRoot `
                -TestOnlySignatureReader $SyntheticSignatureReader | Out-Null
        } '不接受 synthetic trust expectations' `
            'production core 接受了 synthetic expectations。'
    }

    Test-Case 'disposed trust guard fail closed 且 close 幂等' {
        $fixture = Open-SyntheticTrustGuard 'disposed'
        Close-SyntheticFixture $fixture
        Close-SyntheticFixture $fixture
        Assert-ThrowsLike {
            Assert-TL1C1bBuildEnvironmentPreBootstrap $fixture.Guard | Out-Null
        } 'trust guard 已关闭' 'disposed trust guard 仍可复核。'
    }
} finally {
    $env:ANDROID_SDK_ROOT = $savedAndroidSdkRoot
    $env:ANDROID_HOME = $savedAndroidHome
    foreach ($entry in $savedDangerousEnvironment) {
        Set-Item -LiteralPath ("Env:" + $entry.Name) -Value $entry.Value
    }
    $safeRoot = [IO.Path]::GetFullPath($TestRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    if ([IO.Path]::GetDirectoryName($safeRoot) -cne $tempRoot -or
        [IO.Path]::GetFileName($safeRoot) -cnotmatch `
            '^tablet-layout-c1b-build-env-[0-9a-f]{32}$') {
        throw 'C1b build-environment 离线测试清理目标越界。'
    }
    if (Test-Path -LiteralPath $safeRoot -PathType Container) {
        Remove-Item -LiteralPath $safeRoot -Recurse -Force
    }
}

Write-Output "tablet-layout-c1b build environment offline: $script:Passed passed, $script:Failed failed, 0 JDK/Gradle executions"
if ($script:Failed -ne 0) { exit 1 }
