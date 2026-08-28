#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)

$RepoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1')
. (Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b.ps1')

$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('tablet-layout-c1b-adb-provenance-'+[guid]::NewGuid().ToString('N'))
$Sentinel=Join-Path $TestRoot 'fake-adb-executed.txt'
$script:Passed=0
$script:Failed=0

function Assert-True([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Assert-ThrowsLike([scriptblock]$Action,[string]$Pattern,[string]$Message){
    $failure=$null
    try{&$Action}catch{$failure=$_}
    if($null-eq$failure){throw $Message}
    if($failure.Exception.ToString()-notmatch$Pattern){
        throw "$Message`n实际异常：$($failure.Exception.ToString())"
    }
}
function Test-Case([string]$Name,[scriptblock]$Body){
    try{&$Body;$script:Passed++;Write-Output "PASS  $Name"}
    catch{$script:Failed++;Write-Output "FAIL  $Name :: $($_.Exception.Message)"}
}
function New-SdkRoot([string]$Name){
    $sdk=Join-Path $TestRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $sdk 'platform-tools') -Force|Out-Null
    return $sdk
}
function Assert-FakeNeverExecuted([string]$Context){
    Assert-True (-not(Test-Path -LiteralPath $Sentinel -PathType Leaf)) `
        "$Context 在 trust gate 完成前执行了 unsigned fake adb。"
}

New-Item -ItemType Directory -Path $TestRoot|Out-Null
$savedSdkRoot=$env:ANDROID_SDK_ROOT
$savedAndroidHome=$env:ANDROID_HOME
try{
    $sourceDirectory=Join-Path $TestRoot 'source'
    New-Item -ItemType Directory -Path $sourceDirectory|Out-Null
    $fakeSource=Join-Path $sourceDirectory 'fake-adb.cs'
    $fakeExecutable=Join-Path $sourceDirectory 'fake-adb.exe'
    $sentinelLiteral=$Sentinel.Replace('\','\\').Replace('"','\"')
    $source=@"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class Program {
    public static int Main(string[] args) {
        File.WriteAllText("$sentinelLiteral", "executed", new UTF8Encoding(false));
        string path = Process.GetCurrentProcess().MainModule.FileName;
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.Write("Android Debug Bridge version 1.0.41\r\n" +
            "Version 36.0.0-13206524\r\n" +
            "Installed as " + path + "\r\n");
        return 0;
    }
}
"@
    [IO.File]::WriteAllText($fakeSource,$source,[Text.UTF8Encoding]::new($false))
    $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $csc -PathType Leaf)){
        $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    Assert-True (Test-Path -LiteralPath $csc -PathType Leaf) '离线测试缺少 Windows csc.exe。'
    & $csc /nologo /target:exe "/out:$fakeExecutable" $fakeSource
    Assert-True ($LASTEXITCODE-eq0-and(Test-Path -LiteralPath $fakeExecutable -PathType Leaf)) `
        '无法编译 unsigned fake adb。'

    Test-Case 'Google LLC subject 必须精确匹配而非 substring' {
        Assert-True (Test-TL1C1bGoogleAdbSignerSubject $script:TL1C1bGoogleAdbSignerSubject) `
            '精确 Google LLC subject 被误拒绝。'
        foreach($spoof in @(
            'CN=Evil LLC, OU=Google LLC, O=Evil LLC, C=US',
            ('CN=Google LLC Evil, O=Google LLC, '+$script:TL1C1bGoogleAdbSignerSubject),
            'Google LLC'
        )){
            Assert-True (-not(Test-TL1C1bGoogleAdbSignerSubject $spoof)) `
                "subject substring 欺骗被接受：$spoof"
        }
    }

    Test-Case 'canonical SDK 中自报 Installed as 的 unsigned fake adb 在执行前 fail closed' {
        $sdk=New-SdkRoot 'unsigned-sdk'
        $adb=Join-Path $sdk 'platform-tools\adb.exe'
        Copy-Item -LiteralPath $fakeExecutable -Destination $adb
        $env:ANDROID_SDK_ROOT=$sdk
        $env:ANDROID_HOME=$sdk
        Assert-ThrowsLike {Get-TL1C1bAdbTrustBinding $adb $env:ANDROID_SDK_ROOT $env:ANDROID_HOME|Out-Null} `
            'Authenticode/OS trust.*Valid' 'unsigned canonical fake adb 未 fail closed。'
        Assert-FakeNeverExecuted 'unsigned canonical fake'
    }

    Test-Case 'SDK reparse trust root 在签名与执行前拒绝' {
        $realSdk=New-SdkRoot 'real-sdk'
        Copy-Item -LiteralPath $fakeExecutable -Destination (Join-Path $realSdk 'platform-tools\adb.exe')
        $junction=Join-Path $TestRoot 'sdk-junction'
        New-Item -ItemType Junction -Path $junction -Target $realSdk|Out-Null
        $adb=Join-Path $junction 'platform-tools\adb.exe'
        Assert-ThrowsLike {Get-TL1C1bAdbTrustBinding $adb $junction $junction|Out-Null} `
            'ordinary directory' 'SDK junction/reparse 未 fail closed。'
        Assert-FakeNeverExecuted 'SDK reparse'
    }

    Test-Case 'canonical adb hardlink count 非 1 在签名与执行前拒绝' {
        $sdk=New-SdkRoot 'hardlink-sdk'
        $adb=Join-Path $sdk 'platform-tools\adb.exe'
        New-Item -ItemType HardLink -Path $adb -Target $fakeExecutable|Out-Null
        Assert-ThrowsLike {Get-TL1C1bAdbTrustBinding $adb $sdk $sdk|Out-Null} `
            'hardlink count.*1' 'canonical adb hardlink 未 fail closed。'
        Assert-FakeNeverExecuted 'adb hardlink'
    }

    $officialCandidates=@(
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME,
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
    )|Where-Object{-not[string]::IsNullOrWhiteSpace([string]$_)}|Select-Object -Unique
    $official=$null
    foreach($candidate in $officialCandidates){
        $candidateFull=[IO.Path]::GetFullPath([string]$candidate)
        $candidateAdb=Join-Path $candidateFull 'platform-tools\adb.exe'
        if(Test-Path -LiteralPath $candidateAdb -PathType Leaf){
            $sig=Get-AuthenticodeSignature -LiteralPath $candidateAdb
            if([string]$sig.Status-ceq'Valid'-and$null-ne$sig.SignerCertificate-and
               (Test-TL1C1bGoogleAdbSignerSubject ([string]$sig.SignerCertificate.Subject))){
                $official=[pscustomobject]@{Root=$candidateFull;Adb=$candidateAdb}
                break
            }
        }
    }
    if($null-ne$official){
        Test-Case '本机官方 adb 只读 Authenticode/文件 trust 检查（不执行 adb）' {
            $trust=Open-TL1C1bAdbTrustGuard $official.Adb $official.Root $official.Root
            try{
                Assert-True ($trust.SignatureStatus-ceq'Valid') '官方 adb OS trust 非 Valid。'
                Assert-True ($trust.SignatureSubject-ceq$script:TL1C1bGoogleAdbSignerSubject) `
                    '官方 adb signer subject 不符。'
                Assert-True ($trust.SignatureCertificateSha256-cmatch'^sha256:[0-9a-f]{64}$') `
                    '官方 adb 签名证书 SHA-256 不稳定。'
                Assert-True ($trust.ExecutableSha256-cmatch'^sha256:[0-9a-f]{64}$') `
                    '官方 adb 文件 SHA-256 不稳定。'
            }finally{$trust.Guard.Dispose()}
            $trustAgain=Open-TL1C1bAdbTrustGuard $official.Adb $official.Root $official.Root
            try{
                Assert-True ($trustAgain.SignatureSubject-ceq$trust.SignatureSubject-and
                    $trustAgain.SignatureCertificateSha256-ceq$trust.SignatureCertificateSha256-and
                    $trustAgain.ExecutableSha256-ceq$trust.ExecutableSha256) `
                    '官方 adb 前后只读 trust binding 不稳定。'
            }finally{$trustAgain.Guard.Dispose()}
            Assert-FakeNeverExecuted '官方 adb read-only trust check'
        }

        Test-Case '已签名 adb 内容篡改后 OS trust 非 Valid 并 fail closed' {
            $sdk=New-SdkRoot 'tampered-signed-sdk'
            $adb=Join-Path $sdk 'platform-tools\adb.exe'
            Copy-Item -LiteralPath $official.Adb -Destination $adb
            $bytes=[IO.File]::ReadAllBytes($adb)
            try{
                $offset=[Math]::Min(4096,$bytes.Length-1)
                $bytes[$offset]=$bytes[$offset] -bxor 0x01
                [IO.File]::WriteAllBytes($adb,$bytes)
            }finally{if($bytes.Length-ne0){[Array]::Clear($bytes,0,$bytes.Length)}}
            Assert-ThrowsLike {
                $unexpected=Open-TL1C1bAdbTrustGuard $adb $sdk $sdk
                try{$unexpected|Out-Null}finally{$unexpected.Guard.Dispose()}
            } `
                'Authenticode/OS trust.*Valid' '篡改后的 signed adb 未 fail closed。'
            Assert-FakeNeverExecuted 'tampered signed adb'
        }
    }else{
        Write-Output 'SKIP  本机未找到精确 Google LLC/Valid 的官方 adb；未执行任何 adb。'
    }
}finally{
    $env:ANDROID_SDK_ROOT=$savedSdkRoot
    $env:ANDROID_HOME=$savedAndroidHome
    $safeRoot=[IO.Path]::GetFullPath($TestRoot)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    if([IO.Path]::GetDirectoryName($safeRoot)-cne$tempRoot){
        throw '离线测试清理目标越界。'
    }
    if(Test-Path -LiteralPath $safeRoot){Remove-Item -LiteralPath $safeRoot -Recurse -Force}
}

Write-Output "tablet-layout-c1b adb provenance offline: $script:Passed passed, $script:Failed failed"
if($script:Failed-ne0){exit 1}
