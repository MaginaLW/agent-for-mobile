#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference='Stop';Set-StrictMode -Version 3.0
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$helper=Join-Path $root 'scripts\lib\tablet-layout-c1b-readonly.ps1'
$runner=Join-Path $root 'scripts\run-tablet-layout-c1b.ps1'
$t0Runner=Join-Path $root 'scripts\run-tablet-intake.ps1'
$t0Library=Join-Path $root 'scripts\lib\tablet-intake.ps1'
. $helper
$passed=0;$failed=0;$temp=Join-Path ([IO.Path]::GetTempPath()) ('tl1-c1b-readonly-'+[guid]::NewGuid().ToString('N'))
$canonicalTokenTopologyReason='C1b runner canonical token topology SHA-256 漂移。'
$script:lastRunnerMutationPath=$null
[void](New-Item -ItemType Directory -Path $temp)
function Pass([string]$Name,[scriptblock]$Body){try{&$Body;$script:passed++;"PASS $Name"}catch{$script:failed++;"FAIL $Name :: $($_.Exception.Message)"}}
function ExactReason([string]$Message){return '\A'+[regex]::Escape($Message)+'\z'}
function Throws(
    [scriptblock]$Body,
    [string]$Message,
    [string]$SemanticReason,
    [switch]$HardTopologyOnly
){
    $hardFailure=$null
    try{&$Body}catch{$hardFailure=$_}
    if($null-eq$hardFailure){throw $Message}
    if(-not$HardTopologyOnly-and[string]::IsNullOrEmpty($SemanticReason)){
        return
    }
    if($hardFailure.Exception.Message-cne$canonicalTokenTopologyReason){
        throw "runner mutation hard gate 未命中 canonical token topology：$($hardFailure.Exception.Message)"
    }
    if($HardTopologyOnly){return}
    $candidatePath=[string]$script:lastRunnerMutationPath
    if([string]::IsNullOrWhiteSpace($candidatePath)-or
       -not(Test-Path -LiteralPath $candidatePath -PathType Leaf)){
        throw 'runner mutation semantic candidate 缺失。'
    }
    $parsed=Read-TL1C1bReadonlyAst $candidatePath 'runner mutation semantic candidate'
    $originalTokenSha=[string]$script:TL1C1bReadonlyRunnerTokenSha256
    if($parsed.TokenSha256-ceq$originalTokenSha){
        throw 'runner mutation 未改变 canonical token topology SHA-256。'
    }
    $semanticFailure=$null
    try{
        $script:TL1C1bReadonlyRunnerTokenSha256=[string]$parsed.TokenSha256
        try{&$Body}catch{$semanticFailure=$_}
    }finally{
        $script:TL1C1bReadonlyRunnerTokenSha256=$originalTokenSha
    }
    if($null-eq$semanticFailure){throw $Message}
    $semanticMessage=[string]$semanticFailure.Exception.Message
    if($semanticMessage-ceq$canonicalTokenTopologyReason){
        throw 'runner mutation semantic pass 仍停在 hard token topology。'
    }
    if($semanticMessage-cnotmatch$SemanticReason){
        throw "runner mutation semantic reason 不匹配 /$SemanticReason/：$semanticMessage"
    }
}
function Mutate([string]$Source,[string]$Old,[string]$New,[string]$Name){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8);if(-not$raw.Contains($Old)){throw "mutation anchor missing: $Old"}
    $path=Join-Path $temp $Name;[IO.File]::WriteAllText($path,$raw.Replace($Old,$New),[Text.UTF8Encoding]::new($false));$script:lastRunnerMutationPath=$path;return $path
}
function MutateOnce([string]$Source,[string]$Old,[string]$New,[string]$Name){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8)
    $index=$raw.IndexOf($Old,[StringComparison]::Ordinal);if($index-lt0){throw "mutation anchor missing: $Old"}
    $mutated=$raw.Substring(0,$index)+$New+$raw.Substring($index+$Old.Length)
    $path=Join-Path $temp $Name;[IO.File]::WriteAllText($path,$mutated,[Text.UTF8Encoding]::new($false));$script:lastRunnerMutationPath=$path;return $path
}
function MutateLast([string]$Source,[string]$Old,[string]$New,[string]$Name){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8)
    $index=$raw.LastIndexOf($Old,[StringComparison]::Ordinal);if($index-lt0){throw "mutation anchor missing: $Old"}
    $mutated=$raw.Substring(0,$index)+$New+$raw.Substring($index+$Old.Length)
    $path=Join-Path $temp $Name;[IO.File]::WriteAllText($path,$mutated,[Text.UTF8Encoding]::new($false));$script:lastRunnerMutationPath=$path;return $path
}
function WrapSegment(
    [string]$Source,
    [string]$Start,
    [string]$End,
    [string]$Prefix,
    [string]$Suffix,
    [string]$Name
){
    $raw=[IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8)
    $startIndex=$raw.IndexOf($Start,[StringComparison]::Ordinal)
    if($startIndex-lt0){throw "segment start anchor missing: $Start"}
    $endIndex=$raw.IndexOf($End,$startIndex,[StringComparison]::Ordinal)
    if($endIndex-lt0){throw "segment end anchor missing: $End"}
    $endIndex+=$End.Length
    $mutated=$raw.Substring(0,$startIndex)+$Prefix+
        $raw.Substring($startIndex,$endIndex-$startIndex)+$Suffix+
        $raw.Substring($endIndex)
    $path=Join-Path $temp $Name
    [IO.File]::WriteAllText($path,$mutated,[Text.UTF8Encoding]::new($false))
    $script:lastRunnerMutationPath=$path
    return $path
}
try{
    $proof=$null;$t0Proof=$null
    Pass ast_positive {
        $script:proof=Assert-TL1C1bRunnerReadOnlyAst $runner;if($proof.schema-cne'tablet-layout-c1b-runner-readonly-ast/v1'){throw 'schema'}
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `":tablet-c1b-probe:clean`"" 'double-clean.ps1')} 'double-quoted clean accepted' -SemanticReason (ExactReason 'C1b runner 禁止 Gradle clean/WrapperMain 执行面。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    'org.gradle.wrapper.' + 'GradleWrapperMain'" 'concat-wrapper.ps1')} 'concatenated WrapperMain accepted' -SemanticReason (ExactReason 'C1b runner 禁止 Gradle clean/WrapperMain 执行面。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment' 'adb-env-inherit.ps1')} 'ADB inherited environment accepted' -SemanticReason (ExactReason 'C1b runner Invoke-TL1C1aAdb 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment:$false' 'adb-env-false.ps1')} 'ADB ClearEnvironment false accepted' -SemanticReason (ExactReason 'C1b runner Invoke-TL1C1aAdb 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $adbTrustEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' 'adb-trust-env-rebind.ps1')} 'ADB trust command accepted device/server environment' -SemanticReason (ExactReason 'C1b runner adb trust version 必须保持非 private socket 普通 launcher 绑定。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $buildEnvironment' 'aapt2-env-inherit.ps1')} 'aapt2 inherited environment accepted' -SemanticReason (ExactReason 'C1b runner aapt2 dump 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $adbEnvironment -ClearEnvironment' 'aapt2-env-rebind.ps1')} 'aapt2 process environment rebinding accepted' -SemanticReason (ExactReason 'C1b runner aapt2 dump 必须绑定 exact `$buildEnvironment。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -ProcessEnvironment $buildEnvironment -ClearEnvironment' ' -ProcessEnvironment $buildEnvironment -ClearEnvironment:$false' 'aapt2-env-false.ps1')} 'aapt2 ClearEnvironment false accepted' -SemanticReason (ExactReason 'C1b runner aapt2 dump 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $adbEnvironment -ClearEnvironment -TimeoutSec 300' 'java-env-rebind.ps1')} 'Gradle process environment rebinding accepted' -SemanticReason (ExactReason 'C1b runner held launcher binding 漂移：fresh C1b dedicated read-only APK 构建与闭包证明。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $buildEnvironment -ClearEnvironment:$false -TimeoutSec 300' 'java-env-false.ps1')} 'Gradle ClearEnvironment false accepted' -SemanticReason (ExactReason 'C1b runner held launcher 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300' '-Environment $buildEnvironment -ClearEnvironment $false -TimeoutSec 300' 'java-env-separate-false.ps1')} 'Gradle ClearEnvironment separate false accepted' -SemanticReason (ExactReason 'C1b runner held launcher 必须使用 bare -ClearEnvironment；不得省略或显式绑定 false。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner '-ProcessEnvironment $t0Environment' '-ProcessEnvironment $buildEnvironment' 'pwsh-env-rebind.ps1')} 'T0 pwsh process environment rebinding accepted' -SemanticReason (ExactReason 'C1b runner private adb guarded T0 launcher binding 漂移。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '$Java=[string]$gradleInvocation.FilePath' '$Java=[string]$signerInvocation.FilePath' 'java-source-rebind.ps1')} 'held Java source rebinding accepted' -SemanticReason (ExactReason 'C1b runner held launcher assignment closure 漂移。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "@('verify','--print-certs',`$Apk)" "@('verify','--verbose',`$Apk)" 'signer-argv-rebind.ps1')} 'apksigner argv rebinding accepted' -SemanticReason (ExactReason 'C1b runner held launcher binding 漂移：C1b debug APK signer 证书复核。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact' ':tablet-c1b-probe:assembleDebug' 'gradle-task-rebind.ps1')} 'Gradle task rebinding accepted' -SemanticReason (ExactReason 'C1b runner held launcher assignment closure 漂移。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '                Assert-C1bImplementationSnapshot' "                Write-Output 'skip-post-write-implementation-snapshot'" 'implementation-postwrite-removed.ps1')} 'post-write implementation snapshot removal accepted' -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移。')
    }
    Pass t0_positive {$script:t0Proof=Assert-TL1C1bT0ReadOnlySurface $t0Runner $t0Library;if($t0Proof.query_invocation_counts.devices-ne1){throw 'devices'}}
    Pass parse_error {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' 'try { {' 'parse.ps1')} 'parse error accepted'}
    Pass ampersand_dynamic {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    & `$AdbPath version" 'amp.ps1')} 'dynamic invocation accepted' -SemanticReason (ExactReason 'C1b runner 禁止 ampersand dynamic invocation。')}
    Pass invoke_expression {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-Expression 'adb version'" 'iex.ps1')} 'Invoke-Expression accepted' -SemanticReason (ExactReason 'C1b runner 禁止 command Invoke-Expression。')}
    Pass start_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Start-Process adb.exe" 'start.ps1')} 'Start-Process accepted' -SemanticReason (ExactReason 'C1b runner 禁止 command Start-Process。')}
    Pass direct_adb_command {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    adb.exe version" 'adb.ps1')} 'direct adb accepted' -SemanticReason (ExactReason 'C1b runner 禁止直接 adb executable。')}
    Pass direct_adb_generic_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-TL1C1aProcess -FilePath `$AdbPath -Arguments @('version')" 'generic.ps1')} 'generic adb accepted' -SemanticReason (ExactReason 'C1b runner 禁止绕过封闭 wrapper 直接执行 adb。')}
    Pass unbound_generic_process {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Invoke-TL1C1aProcess -FilePath (Join-Path `$env:TEMP 'adb.exe') -Arguments @('version')" 'generic-computed.ps1')} 'computed generic process accepted' -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移：Invoke-TL1C1aProcess。')}
    Pass debug_keystore_lock_seal_lifecycle {
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner `
                'Seal-TL1C1bBuildEnvironmentDebugKeystoreLock' `
                'Write-Output' 'debug-keystore-lock-seal-removed.ps1')
        } 'debug.keystore.lock seal removal accepted' `
            -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移：Seal-TL1C1bBuildEnvironmentDebugKeystoreLock。')
        $withoutOriginalSeal=Mutate $runner `
            'Seal-TL1C1bBuildEnvironmentDebugKeystoreLock' `
            'Write-Output' 'debug-keystore-lock-seal-rebound.ps1'
        $movedSeal=Mutate $withoutOriginalSeal `
            '$buildStarted=[DateTime]::UtcNow' `
            "`$buildEnvironmentBinding=Seal-TL1C1bBuildEnvironmentDebugKeystoreLock -TrustGuard `$buildEnvironmentGuard -ExpectedTrustGuard `$buildEnvironmentGuardAnchor -ExpectedPreSealBindingRaw `$buildEnvironmentPreSealBindingRaw`n    `$buildStarted=[DateTime]::UtcNow" `
            'debug-keystore-lock-seal-before-gradle.ps1'
        Throws {Assert-TL1C1bRunnerReadOnlyAst $movedSeal} `
            'pre-Gradle debug.keystore.lock seal accepted' `
            -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移。')
        $buildAnchor='$buildStarted=[DateTime]::UtcNow'
        foreach($mutation in @(
            '$buildEnvironmentGuard=$otherGuard',
            '$buildEnvironmentGuard.DebugKeystoreGuard=$otherGuard.DebugKeystoreGuard',
            '$script:buildEnvironmentGuard.DebugKeystoreGuard.LockGuard=$otherLockGuard',
            '$buildEnvironmentGuardAnchor=$otherGuard',
            '$global:buildEnvironmentPreSealBindingRaw=''{}''',
            '$buildEnvironmentBindingRaw=''{}''',
            '$buildEnvironmentPreSealBindingRaw=''{}'''
        )){
            Throws {
                Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner $buildAnchor `
                    ($mutation+"`n    "+$buildAnchor) `
                    ('build-environment-state-rebind-'+[guid]::NewGuid().ToString('N')+'.ps1'))
            } "build-environment guard/binding rebind accepted: $mutation" `
                -SemanticReason (ExactReason 'C1b runner build-environment guard/binding assignment closure 漂移。')
        }
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner `
                '-ExpectedTrustGuard $buildEnvironmentGuardAnchor' `
                '-ExpectedTrustGuard $buildEnvironmentGuard' `
                'debug-keystore-lock-anchor-bypass.ps1')
        } 'seal accepted tautological guard identity binding' `
            -SemanticReason (ExactReason 'C1b runner build-environment guard/binding assignment closure 漂移。')
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner `
                '-ExpectedPreSealBindingRaw $buildEnvironmentPreSealBindingRaw' `
                '-ExpectedPreSealBindingRaw $buildEnvironmentBindingRaw' `
                'debug-keystore-lock-prebinding-bypass.ps1')
        } 'seal accepted mutable pre-binding baseline' `
            -SemanticReason (ExactReason 'C1b runner build-environment guard/binding assignment closure 漂移。')
    }
    Pass gradle_seal_frozen_topology {
        $gradleStart='[void](Invoke-TL1C1aProcess -FilePath $Java -Arguments $gradleArguments `'
        $gradleEnd='-Environment $buildEnvironment -ClearEnvironment -TimeoutSec 300)'
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (WrapSegment $runner `
                $gradleStart $gradleEnd '@(' '; Start-Sleep -Milliseconds 1)' `
                'gradle-array-wrapper.ps1')
        } 'Gradle array/subexpression wrapper accepted' `
            -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移：Start-Sleep。')
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (WrapSegment $runner `
                $gradleStart $gradleEnd 'if($false){' '}' `
                'gradle-dead-if.ps1')
        } 'dead if Gradle accepted' `
            -SemanticReason (ExactReason 'C1b runner Gradle/seal/frozen lifecycle ordering 漂移。')
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (WrapSegment $runner `
                $gradleStart 'Assert-C1bFrozenState' `
                'function Invoke-DeadBuild {' '}' `
                'gradle-seal-frozen-dead-function.ps1')
        } 'non-invoked function Gradle/seal/frozen tuple accepted' `
            -SemanticReason (ExactReason 'C1b runner function definition count 漂移。')
        Throws {
            Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner `
                $gradleEnd ($gradleEnd+' | Write-Output') `
                'gradle-extra-pipeline.ps1')
        } 'Gradle extra pipeline accepted' `
            -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移。')
        $equalSwap=MutateOnce $runner `
            'try{$guard.Guard.Dispose()}' 'try{$null=$guard.Guard}' `
            'equal-swap-remove-dispose.ps1'
        $lastFrozen='Assert-C1bFrozenState;Assert-C1bArtifactFrozenState;Assert-C1bHostReadOnlyFrozenState'
        $equalSwap=MutateLast $equalSwap $lastFrozen `
            ($lastFrozen+"`n    `$buildEnvironmentGuard.DebugKeystoreGuard.LockGuard.SealStream.Dispose()") `
            'equal-swap-move-dispose.ps1'
        $equalSwap=MutateOnce $equalSwap `
            '[Array]::Clear($validationBytes,0,$validationBytes.Length)' `
            '$null=$validationBytes.Length' 'equal-swap-remove-clear.ps1'
        $equalSwap=MutateOnce $equalSwap `
            'if($cleanupFailures.Count-ne0){' `
            "`$cleanupFailures.Clear()`n    if(`$cleanupFailures.Count-ne0){" `
            'equal-swap-move-clear.ps1'
        Throws {Assert-TL1C1bRunnerReadOnlyAst $equalSwap} `
            'equal-name/count Dispose/Clear callsite swap accepted' `
            -HardTopologyOnly
    }
    Pass debug_keystore_lock_seal_shadow {
        $anchor='$staticReadOnlyProof=Assert-TL1C1bRunnerReadOnlyAst $PSCommandPath'
        foreach($definition in @(
            'function Seal-TL1C1bBuildEnvironmentDebugKeystoreLock { param($Guard) }',
            'function seal-tl1c1bbuildenvironmentdebugkeystorelock { param($Guard) }',
            'function script:Seal-TL1C1bBuildEnvironmentDebugKeystoreLock { param($Guard) }',
            'function Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard { param($Guard) }',
            'function Assert-TL1C1bBuildEnvironmentTrustGuardUnchanged { param($Guard) $script:buildEnvironmentBinding }',
            'function global:assert-tl1c1bbuildenvironmenttrustguardunchanged { param($Guard) $script:buildEnvironmentBinding }'
        )){
            Throws {
                Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner $anchor `
                    ($definition+"`n    "+$anchor) `
                    ('debug-keystore-lock-seal-shadow-'+[guid]::NewGuid().ToString('N')+'.ps1'))
            } "debug.keystore.lock seal function shadow accepted: $definition" `
                -SemanticReason (ExactReason 'C1b runner function definition count 漂移。')
        }
        foreach($case in @(
            [pscustomobject]@{
                Mutation='Set-Item Function:\Seal-TL1C1bBuildEnvironmentDebugKeystoreLock -Value { param($Guard) }'
                Reason='C1b runner 禁止 command Set-Item。'
            },
            [pscustomobject]@{
                Mutation='Set-Content Function:\Seal-TL1C1bBuildEnvironmentDebugKeystoreLock -Value ''param($Guard)'''
                Reason='C1b runner 禁止 command Set-Content。'
            },
            [pscustomobject]@{
                Mutation='Set-Item Alias:\Seal-TL1C1bBuildEnvironmentDebugKeystoreLock -Value Write-Output'
                Reason='C1b runner 禁止 command Set-Item。'
            },
            [pscustomobject]@{
                Mutation='New-Item -Path Function:\Seal-TL1C1bBuildEnvironmentDebugKeystoreLock -Value { param($Guard) }'
                Reason='C1b runner command name/count closure 漂移：New-Item。'
            },
            [pscustomobject]@{
                Mutation='$buildEnvironmentGuard.DebugKeystoreGuard | Add-Member -Force -NotePropertyName LockGuard -NotePropertyValue $otherLockGuard'
                Reason='C1b runner 禁止 command Add-Member。'
            },
            [pscustomobject]@{
                Mutation='Import-Module .\untrusted-shadow.psm1'
                Reason='C1b runner 禁止 command Import-Module。'
            }
        )){
            $mutation=[string]$case.Mutation
            Throws {
                Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner $anchor `
                    ($mutation+"`n    "+$anchor) `
                    ('debug-keystore-lock-command-rebind-'+[guid]::NewGuid().ToString('N')+'.ps1'))
            } "command-resolution mutation accepted: $mutation" `
                -SemanticReason (ExactReason ([string]$case.Reason))
        }
    }
    Pass c1a_name_allowlist {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name install ' ' -Name a11y_enabled ' 'c1a-name.ps1')} 'C1a name accepted' -SemanticReason (ExactReason 'C1b runner C1a Name 非 allowlist：a11y_enabled。')}
    Pass c1a_dynamic_name {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name install ' ' -Name $dynamicName ' 'c1a-dynamic.ps1')} 'C1a dynamic name accepted' -SemanticReason (ExactReason 'Invoke-TL1C1aAdb -Name 必须是 static string literal。')}
    Pass c1b_name_allowlist {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner ' -Name content_result ' ' -Name content_unknown ' 'c1b-name.ps1')} 'C1b name accepted' -SemanticReason (ExactReason 'C1b runner C1b Name 非 allowlist：content_unknown。')}
    Pass read_control_dynamic_callsite {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Read-C1bControl content_c1 $uris.c1' 'Read-C1bControl $dynamicName $uris.c1' 'read-dynamic.ps1')} 'dynamic wrapper callsite accepted' -SemanticReason (ExactReason 'Read-C1bControl Name 必须是 static string literal。')}
    Pass read_control_reassignment {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'function Read-C1bControl([string]$Name,[string]$Uri) {' "function Read-C1bControl([string]`$Name,[string]`$Uri) {`n    `$Name='content_status'" 'read-assign.ps1')} 'Name reassignment accepted' -SemanticReason (ExactReason 'Read-C1bControl 禁止改写 $Name。')}
    Pass dot_source_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "Join-Path `$PSScriptRoot 'lib\tablet-layout-c1b.ps1'" "Join-Path `$PSScriptRoot 'lib\evil.ps1'" 'dot-rebind.ps1')} 'dot-source rebinding accepted' -SemanticReason (ExactReason 'C1b runner dot-source binding Library path 漂移。')}
    Pass private_adb_dot_source_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "Join-Path `$PSScriptRoot 'lib\tablet-layout-c1b-adb-server.ps1'" "Join-Path `$PSScriptRoot 'lib\evil-adb-server.ps1'" 'private-adb-dot-rebind.ps1')} 'private adb dot-source rebinding accepted' -SemanticReason (ExactReason 'C1b runner dot-source binding AdbServerLibrary path 漂移。')}
    Pass private_adb_open_environment_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-AdbPath $AdbPath -ProcessEnvironment $adbTrustEnvironment' '-AdbPath $AdbPath -ProcessEnvironment $adbEnvironment' 'private-adb-open-env.ps1')} 'private adb open environment rebinding accepted' -SemanticReason (ExactReason 'C1b runner private adb open binding 漂移。')}
    Pass private_adb_client_guard_rebinding {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Get-TL1C1bPrivateAdbClientEnvironment $adbServerGuard' 'Get-TL1C1bPrivateAdbClientEnvironment $otherGuard' 'private-adb-client-guard.ps1')} 'private adb client guard rebinding accepted' -SemanticReason (ExactReason 'C1b runner private adb guard argument 漂移：Get-TL1C1bPrivateAdbClientEnvironment。')}
    Pass private_adb_business_guard_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner ' -PrivateAdbServerGuard $adbServerGuard' '' 'private-adb-business-guard-removed.ps1')} 'single private business ADB wrapper Guard removal accepted' -SemanticReason (ExactReason 'Invoke-TL1C1bAdb 必须有且仅有一个 -PrivateAdbServerGuard。')}
    Pass private_adb_business_guard_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (MutateOnce $runner ' -PrivateAdbServerGuard $adbServerGuard' ' -PrivateAdbServerGuard $otherGuard' 'private-adb-business-guard-rebound.ps1')} 'single private business ADB wrapper Guard rebinding accepted' -SemanticReason (ExactReason 'C1b runner Invoke-TL1C1bAdb 必须绑定 exact -PrivateAdbServerGuard $adbServerGuard。')}
    Pass private_adb_t0_guarded_launcher_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Invoke-TL1C1bPrivateAdbGuardedProcess' 'Invoke-TL1C1aProcess' 'private-adb-t0-generic-launcher.ps1')} 'T0 generic launcher fallback accepted' -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移。')}
    Pass private_adb_t0_arguments_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner "@('-NoProfile','-File',`$T0Runner,'-AdbPath',`$T0AdbCmd,'-RunId',`$runId)" "@('-NoProfile','-File',`$T0Runner,'-RunId',`$runId,'-AdbPath',`$T0AdbCmd)" 'private-adb-t0-arguments.ps1')} 'T0 guarded launcher argument reordering accepted' -SemanticReason (ExactReason 'C1b runner private adb guarded T0 Arguments literal argument value/order 漂移。')}
    Pass private_adb_t0_client_kind_rebound {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-ClientKind T0Root' '-ClientKind AdbCli' 'private-adb-t0-kind.ps1')} 'T0 guarded launcher ClientKind rebinding accepted' -SemanticReason (ExactReason 'C1b runner private adb guarded T0 launcher binding 漂移。')}
    Pass private_adb_t0_extra_argument {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '-ClientKind T0Root' "-ClientKind T0Root 'extra'" 'private-adb-t0-extra-argument.ps1')} 'T0 guarded launcher extra positional argument accepted' -SemanticReason (ExactReason 'C1b runner private adb guarded T0 launcher argument count 漂移。')}
    Pass adb_trust_private_guard_injected {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -ProcessEnvironment' 'Get-TL1C1bAdbTrustBinding $AdbPath $AndroidSdkRoot $AndroidHome -PrivateAdbServerGuard $adbServerGuard -ProcessEnvironment' 'adb-trust-private-guard.ps1')} 'adb trust version private socket Guard accepted' -SemanticReason (ExactReason 'C1b runner adb trust version 必须保持非 private socket 普通 launcher 绑定。')}
    Pass private_adb_cleanup_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'Close-TL1C1bPrivateAdbServerGuard $adbServerGuard' "Write-Output 'skip-private-adb-close'" 'private-adb-close-removed.ps1')} 'private adb close removal accepted' -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移：Close-TL1C1bPrivateAdbServerGuard。')}
    Pass private_adb_frozen_recheck_removed {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '[void](Assert-C1bPrivateAdbServerFrozenState)' "[void](Write-Output 'skip-private-adb-recheck')" 'private-adb-recheck-removed.ps1')} 'private adb frozen recheck removal accepted' -SemanticReason (ExactReason 'C1b runner command name/count closure 漂移：Assert-C1bPrivateAdbServerFrozenState。')}
    Pass private_adb_cleanup_after_sidecar {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner '$sessionConsumed=$true' '$sessionConsumed=$true;$sidecar=[ordered]@{}' 'private-adb-cleanup-after-sidecar.ps1')} 'sidecar construction before private adb cleanup accepted' -SemanticReason (ExactReason 'C1b runner private adb open/use/cleanup/publish ordering 漂移。')}
    Pass process_start_bypass {Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    [Diagnostics.Process]::Start(`$AdbPath)" 'process-start.ps1')} 'Process.Start accepted' -SemanticReason (ExactReason 'C1b runner 禁止 ProcessStartInfo/.Start executable bypass。')}
    Pass scriptblock_dynamic_invoke {
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `$dynamic={ adb.exe version }; `$dynamic.Invoke()" 'scriptblock-invoke.ps1')} 'scriptblock Invoke accepted' -SemanticReason (ExactReason 'C1b runner 禁止直接 adb executable。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `$ExecutionContext.InvokeCommand.InvokeScript('function global:Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard { param(`$Guard) }')" 'invoke-command-invokescript.ps1')} 'InvokeCommand.InvokeScript accepted' -SemanticReason (ExactReason 'C1b runner 禁止 ExecutionContext/SessionState command-resolution surface。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `$ExecutionContext.SessionState.PSVariable.Set('buildEnvironmentGuard',`$otherGuard)" 'session-state-psvariable-set.ps1')} 'SessionState.PSVariable.Set accepted' -SemanticReason (ExactReason 'C1b runner 禁止 ExecutionContext/SessionState command-resolution surface。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    `$dynamic=[scriptblock]::Create('function global:Seal-TL1C1bBuildEnvironmentMutableEmptyFileGuard { param(`$Guard) }'); 1|ForEach-Object -Process `$dynamic" 'scriptblock-create-foreach.ps1')} 'ScriptBlock.Create plus ForEach-Object accepted' -SemanticReason (ExactReason 'C1b runner 禁止 command ForEach-Object。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    (New-Object -ComObject WScript.Shell).Run('cmd.exe /c exit')" 'com-process-run.ps1')} 'COM process Run accepted' -SemanticReason (ExactReason 'C1b runner 禁止 command New-Object。')
        Throws {Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' "try {`n    Add-Type -TypeDefinition 'public static class DynamicRunner { public static void Run() {} }'; [DynamicRunner]::Run()" 'add-type-run.ps1')} 'Add-Type dynamic process surface accepted' -SemanticReason (ExactReason 'C1b runner 禁止 command Add-Type。')
    }
    $categoryMutations=[ordered]@{
        display_screenshot=[pscustomobject]@{Command='Get-DisplayScreenshot';Reason='C1b runner prohibited category display_screenshot_call_count is nonzero。'}
        window_screenshot=[pscustomobject]@{Command='Get-WindowScreenshot';Reason='C1b runner prohibited category window_screenshot_call_count is nonzero。'}
        ocr=[pscustomobject]@{Command='Invoke-Host-Ocr';Reason='C1b runner prohibited category ocr_invocation_count is nonzero。'}
        action=[pscustomobject]@{Command='Invoke-MobileAction';Reason='C1b runner prohibited category action_call_count is nonzero。'}
        gesture=[pscustomobject]@{Command='Invoke-Gesture';Reason='C1b runner prohibited category gesture_call_count is nonzero。'}
        input=[pscustomobject]@{Command='Send-DeviceInput';Reason='C1b runner prohibited category input_call_count is nonzero。'}
        settings=[pscustomobject]@{Command='Set-AndroidSetting';Reason='C1b runner prohibited category settings_mutation_count is nonzero。'}
        target=[pscustomobject]@{Command='Start-TargetApp';Reason='C1b runner prohibited category target_app_start_count is nonzero。'}
        mcp=[pscustomobject]@{Command='mcp__mobile__read';Reason='C1b runner prohibited category mcp_call_count is nonzero。'}
        dispatch=[pscustomobject]@{Command='Invoke-TaskDispatch';Reason='C1b runner prohibited category dispatch_call_count is nonzero。'}
    }
    foreach($entry in $categoryMutations.GetEnumerator()){
        Pass ("category_"+$entry.Key) {
            Throws {
                Assert-TL1C1bRunnerReadOnlyAst (Mutate $runner 'try {' `
                    ("try {`n    "+$entry.Value.Command) `
                    ("category-"+$entry.Key+'.ps1'))
            } ("category accepted: "+$entry.Key) `
                -SemanticReason (ExactReason ([string]$entry.Value.Reason))
        }
    }
    Pass t0_validate_set {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'devices', 'prop_brand'" "'devices', 'evil', 'prop_brand'" 't0-set.ps1')} 'T0 ValidateSet mutation accepted'}
    Pass t0_mapping_command {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "@('shell', 'wm', 'size')" "@('shell', 'wm', 'reset')" 't0-map.ps1')} 'T0 mapping mutation accepted'}
    Pass t0_settings_put {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'settings', 'get', 'global'" "'settings', 'put', 'global'" 't0-settings.ps1')} 'settings put accepted'}
    Pass t0_am_start {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library "'am', 'get-config'" "'am', 'start'" 't0-am.ps1')} 'am start accepted'}
    Pass t0_runner_foreach {Throws {Assert-TL1C1bT0ReadOnlySurface (Mutate $t0Runner "'zen', 'default_ime'" "'zen', 'evil', 'default_ime'" 't0-runner-loop.ps1') $t0Library} 'T0 foreach mutation accepted'}
    Pass t0_runner_dynamic {Throws {Assert-TL1C1bT0ReadOnlySurface (Mutate $t0Runner '-Name activity -Serial $serial' '-Name $outsideName -Serial $serial' 't0-runner-dynamic.ps1') $t0Library} 'T0 outside dynamic name accepted'}
    Pass t0_library_direct_adb {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'Set-StrictMode -Version 3.0' "Set-StrictMode -Version 3.0`nadb.exe version" 't0-direct-adb.ps1')} 'T0 direct adb accepted'}
    Pass t0_library_second_process_start {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'Set-StrictMode -Version 3.0' "Set-StrictMode -Version 3.0`n[Diagnostics.Process]::Start('adb.exe')" 't0-process-start.ps1')} 'T0 second Process.Start accepted'}
    Pass t0_arguments_reassignment {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library '$start = [Diagnostics.ProcessStartInfo]::new()' "`$arguments=@('shell','settings','put','secure','x','1')`n    `$start = [Diagnostics.ProcessStartInfo]::new()" 't0-args-reassign.ps1')} 'T0 arguments reassignment accepted'}
    Pass t0_argument_list_injection {Throws {Assert-TL1C1bT0ReadOnlySurface $t0Runner (Mutate $t0Library 'foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }' "foreach (`$argument in `$arguments) { `$start.ArgumentList.Add(`$argument) }`n    `$start.ArgumentList.Add('shell')" 't0-args-add.ps1')} 'T0 ArgumentList injection accepted'}
    $capture=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;result_read_count=1L;recapture_count=0L}
    $control=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;committed_tokens=[string[]]@('c1','c2');recapture_count=0L}
    Pass counts_positive {$counts=ConvertTo-TL1C1bReadOnlyCounts $capture $control $proof;if($counts.a11y_frame_capture_count-ne2L-or$counts.recapture_count-ne0L){throw 'derived counts'}}
    Pass capture_extra_property {$x=$capture|Select-Object *;$x|Add-Member extra 0L;Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'capture extra accepted'}
    Pass capture_wrong_integer_type {$x=[pscustomobject][ordered]@{c1_requests_accepted=1;c2_requests_accepted=1L;result_read_count=1L;recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'Int32 accepted'}
    Pass control_tuple_mismatch {$x=[pscustomobject][ordered]@{c1_requests_accepted=0L;c2_requests_accepted=1L;committed_tokens=[string[]]@('c1','c2');recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $x $proof} 'control mismatch accepted'}
    Pass committed_tokens_scalar {$x=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;committed_tokens='c1';recapture_count=0L};Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $x $proof} 'token scalar accepted'}
    Pass proof_invocation_count_mutation {$x=$proof|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$x.c1a_invocation_counts.fingerprint=3L;Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $control $x} 'proof invocation count accepted'}
    Pass recapture_nonzero {$x=[pscustomobject][ordered]@{c1_requests_accepted=1L;c2_requests_accepted=1L;result_read_count=1L;recapture_count=1L};Throws {ConvertTo-TL1C1bReadOnlyCounts $x $control $proof} 'recapture accepted'}
    foreach($name in $script:TL1C1bReadonlyZeroNames){
        Pass ("nonzero_"+$name) {$x=$proof|ConvertTo-Json -Depth 10|ConvertFrom-Json -DateKind String;$x.static_zero_counts|Add-Member -Force -NotePropertyName $name -NotePropertyValue 1L;Throws {ConvertTo-TL1C1bReadOnlyCounts $capture $control $x} ("nonzero accepted: "+$name)}
    }
}finally{
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
"RESULT passed=$passed failed=$failed"
if($failed-ne0){exit 1}
