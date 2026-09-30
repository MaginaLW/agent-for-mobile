#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RepoRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommitSha,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$JavaHome,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GradleHome,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$AndroidSdkRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SummaryPath,
    [ValidateNotNullOrEmpty()][string]$GitPath = [IO.Path]::GetFullPath(
        (Join-Path ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::ProgramFiles)) 'Git\cmd\git.exe'))
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$expectedSha = '__FINAL_COMMIT_SHA__'
if ($ExpectedCommitSha -cne $expectedSha) {
    throw "This one-shot smoke helper is pinned to $expectedSha."
}
if (-not [OperatingSystem]::IsWindows()) { throw 'C1b real build smoke requires Windows.' }
$isAdministrator = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdministrator) {
    throw 'C1b real build smoke requires an elevated token for the build-environment ACL guard.'
}

$RepoRoot = [IO.Path]::GetFullPath($RepoRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)
$helperPath = [IO.Path]::GetFullPath($PSCommandPath)
$repoPrefix = $RepoRoot + [IO.Path]::DirectorySeparatorChar
if ($helperPath.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The one-shot smoke helper must run from outside the repository.'
}
$helperItem = Get-Item -LiteralPath $helperPath -Force
if (($helperItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
    $helperItem.PSIsContainer) {
    throw 'The one-shot smoke helper must be an ordinary file.'
}
$SummaryPath = [IO.Path]::GetFullPath($SummaryPath)
$expectedSummaryRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot '.checks'))
$summaryParent = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($SummaryPath))
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($summaryParent, $expectedSummaryRoot)) {
    throw 'SummaryPath must be a direct child of the repository .checks directory.'
}
if ([IO.Path]::GetFileName($SummaryPath) -cne
    'tablet-c1b-real-build-smoke-__FINAL_COMMIT_SHORT__.summary.json') {
    throw 'SummaryPath leaf is not the pinned smoke summary name.'
}
if (Test-Path -LiteralPath $SummaryPath) { throw 'SummaryPath already exists.' }
if (-not (Test-Path -LiteralPath $expectedSummaryRoot -PathType Container)) {
    throw 'The repository .checks directory is missing.'
}
$summaryRootItem = Get-Item -LiteralPath $expectedSummaryRoot -Force
if ($summaryRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'The repository .checks directory must not be a reparse point.'
}

function Get-SmokeFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Smoke bootstrap file is not ordinary: $full"
    }
    $stream = [IO.FileStream]::new(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        return 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
    }
    finally { $stream.Dispose() }
}

function Open-SmokeHeldFile {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Smoke held file is not ordinary: $full"
    }
    $stream = [IO.FileStream]::new(
        $full,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $sha256 = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($stream)
        ).ToLowerInvariant()
        $stream.Position = 0L
        return [pscustomobject][ordered]@{
            Path = $full
            Sha256 = $sha256
            Guard = $stream
        }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

$GitPath = [IO.Path]::GetFullPath($GitPath)
$expectedGitPath = [IO.Path]::GetFullPath((Join-Path (
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
) 'Git\cmd\git.exe'))
if ($GitPath -cne $expectedGitPath -or
    (Get-SmokeFileSha256 $GitPath) -cne
        'sha256:7b7971dd13f0c3a284e538601f2f9770b3a87dfaccb5fb52d68141c67ed22364') {
    throw 'Smoke bootstrap Git path/hash binding failed.'
}
$script:SmokeBootstrapGitCount = 0L
function Invoke-SmokeBootstrapGit {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $GitPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment.Clear()
    $systemDirectory = [Environment]::SystemDirectory
    $windowsRoot = [IO.Directory]::GetParent($systemDirectory).FullName
    $userProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
    $processTemp = [IO.Path]::GetTempPath().TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
    foreach ($entry in ([ordered]@{
        SYSTEMROOT = $windowsRoot
        WINDIR = $windowsRoot
        COMSPEC = Join-Path $systemDirectory 'cmd.exe'
        PATHEXT = '.COM;.EXE;.BAT;.CMD'
        PATH = $systemDirectory
        TEMP = $processTemp
        TMP = $processTemp
        USERPROFILE = $userProfile
        HOME = $userProfile
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = 'NUL'
        GIT_CONFIG_COUNT = '0'
        GIT_TERMINAL_PROMPT = '0'
        GCM_INTERACTIVE = 'Never'
        GIT_OPTIONAL_LOCKS = '0'
    }).GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($argument in @(
        '--no-optional-locks',
        '-c', 'core.autocrlf=true',
        '-c', 'core.fsmonitor=false',
        '-c', 'core.untrackedCache=false',
        '-c', 'core.hooksPath=NUL',
        '-C', $RepoRoot
    ) + $Arguments) {
        $start.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Smoke bootstrap Git could not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch { }
            throw 'Smoke bootstrap Git timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or
            -not [string]::IsNullOrWhiteSpace($stderr)) {
            throw "Smoke bootstrap Git failed (exit=$($process.ExitCode))."
        }
        $script:SmokeBootstrapGitCount++
        return $stdout
    }
    finally { $process.Dispose() }
}

$bootstrapHead = (Invoke-SmokeBootstrapGit `
    @('rev-parse', '--verify', 'HEAD^{commit}')).Trim()
if ($bootstrapHead -cne $ExpectedCommitSha) {
    throw "Smoke bootstrap HEAD drifted: $bootstrapHead"
}
$bootstrapStatus = Invoke-SmokeBootstrapGit `
    @('status', '--porcelain=v1', '--untracked-files=all')
if (-not [string]::IsNullOrWhiteSpace($bootstrapStatus)) {
    throw 'Smoke bootstrap requires an exact clean worktree.'
}

$libraries = [ordered]@{
    c1a = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1a.ps1'
    validator = Join-Path $RepoRoot 'scripts\lib\tablet-layout-observation-c1b-v1-validator.ps1'
    c1b = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b.ps1'
    artifact = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-artifact-proof.ps1'
    aapt2 = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-aapt2.ps1'
    build = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-build-env.ps1'
    runner = Join-Path $RepoRoot 'scripts\run-tablet-layout-c1b.ps1'
}
foreach ($path in $libraries.Values) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "C1b smoke library is missing or not an ordinary file: $path"
    }
}
$expectedLibraryHashes = [ordered]@{
    c1a = 'sha256:428cf770ea37a4572615d4e121accba275efca5a61bbbd0e17536ddff1b23dca'
    validator = 'sha256:967f93beb24f0ce8098600bb713860e4a7d1a50bffd638f706498cbf10396a3a'
    c1b = 'sha256:5a6303a25e921e23c40e4f77502cda8d8bb333cfb3c1fbe55a3c87e29ced32b5'
    artifact = 'sha256:247c6b0fdb3c3172ac3d74896b960885a1ba2ee515b9eb2cb26114dc13473631'
    aapt2 = 'sha256:d0616c8de0d4790c36fbbb277896b27901b20ce9a3113d68967f0c53263cb5c6'
    build = 'sha256:a4539baf020e38e76f86a14b1e2f36420cb080ab3980155afce9c5131210e639'
    runner = 'sha256:84e5259088449f54392d39e72c412724c1d19ddc6501a6e77b7c3de723712a9b'
}
$requiredLibraryKeys = [string[]]@(
    'c1a', 'validator', 'c1b', 'artifact', 'aapt2', 'build', 'runner'
)
$libraryKeys = [string[]]@($libraries.Keys)
$libraryHashKeys = [string[]]@($expectedLibraryHashes.Keys)
if (($libraryKeys -join "`n") -cne ($requiredLibraryKeys -join "`n") -or
    ($libraryHashKeys -join "`n") -cne ($requiredLibraryKeys -join "`n")) {
    throw 'C1b smoke held/pinned library closure drifted.'
}
$repositoryLibraryGuards = [Collections.Generic.List[object]]::new()
try {
    foreach ($entry in $expectedLibraryHashes.GetEnumerator()) {
        $libraryGuard = Open-SmokeHeldFile $libraries[$entry.Key]
        $repositoryLibraryGuards.Add($libraryGuard)
        if ([string]$libraryGuard.Sha256 -cne [string]$entry.Value) {
            throw "Smoke bootstrap repository hash drifted: $($entry.Key)"
        }
    }
    if ($repositoryLibraryGuards.Count -ne 7) {
        throw 'C1b smoke must hold exactly seven repository loader inputs.'
    }
. $libraries.c1a
. $libraries.validator
. $libraries.c1b
. $libraries.artifact
. $libraries.aapt2
. $libraries.build

$requiredClosedJsonWalkers = [string[]]@(
    'Find-TL1C1BV1DuplicateJsonProperty',
    'Find-TL1C1BV1InvalidNumber'
)
foreach ($walkerName in $requiredClosedJsonWalkers) {
    $walkerCommands = @(Get-Command -Name $walkerName -CommandType Function `
        -All -ErrorAction SilentlyContinue)
    $walkerFile = if ($walkerCommands.Count -eq 1) {
        [string]$walkerCommands[0].ScriptBlock.File
    }
    else { '' }
    if ($walkerCommands.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace($walkerFile) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath($walkerFile),
            [IO.Path]::GetFullPath([string]$libraries.validator))) {
        throw "C1b smoke closed-JSON walker load binding failed: $walkerName"
    }
}
$closedJsonParserCommands = @(Get-Command -Name ConvertFrom-TL1C1bClosedJson `
    -CommandType Function -All -ErrorAction SilentlyContinue)
$closedJsonParserFile = if ($closedJsonParserCommands.Count -eq 1) {
    [string]$closedJsonParserCommands[0].ScriptBlock.File
}
else { '' }
if ($closedJsonParserCommands.Count -ne 1 -or
    [string]::IsNullOrWhiteSpace($closedJsonParserFile) -or
    -not [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath($closedJsonParserFile),
        [IO.Path]::GetFullPath([string]$libraries.c1b))) {
    throw 'C1b smoke closed-JSON parser load binding failed.'
}
$closedJsonCanary = ConvertFrom-TL1C1bClosedJson '{"n":0}'
if ($closedJsonCanary -isnot [pscustomobject] -or
    @($closedJsonCanary.PSObject.Properties.Name).Count -ne 1 -or
    [string]$closedJsonCanary.PSObject.Properties.Name -cne 'n' -or
    $closedJsonCanary.n -isnot [long] -or [long]$closedJsonCanary.n -ne 0L) {
    throw 'C1b smoke closed-JSON parser canary failed.'
}

$helperSha256 = Get-SmokeFileSha256 $helperPath
$repositoryInputPaths = [string[]]@($script:TL1C1bImplementationPathMap.Values)
[Array]::Sort($repositoryInputPaths, [StringComparer]::Ordinal)
if ($script:TL1C1bImplementationPathMap.Count -ne 42 -or
    $repositoryInputPaths.Count -ne 42 -or
    @($repositoryInputPaths | Sort-Object -CaseSensitive -Unique).Count -ne 42) {
    throw 'C1b real build smoke input closure must contain exactly 42 unique files.'
}
foreach ($relativePath in $repositoryInputPaths) {
    if ([IO.Path]::IsPathFullyQualified($relativePath) -or
        $relativePath.StartsWith('../', [StringComparison]::Ordinal) -or
        $relativePath.StartsWith('..\', [StringComparison]::Ordinal)) {
        throw "C1b repository input escapes the repository: $relativePath"
    }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot ($relativePath -replace '/', '\')))
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or
        ((Get-Item -LiteralPath $fullPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "C1b repository input is missing or not ordinary: $relativePath"
    }
}
$repositoryInputDirectories = [string[]]@(
    'app/tablet-c1b-probe/src/main'
    'app/gateway/src/main/java/dev/magina/gateway/tablet'
    'app/gateway/src/debug/java/dev/magina/gateway/tablet/c1b'
)

# Wrap the only process primitive available to the loaded libraries. Any direct adb.exe
# attempt is denied before process creation. The remaining direct surface is exact Git,
# held Java for GradleMain/ApkSignerTool, and held aapt2 for packaged AXML verification.
Rename-Item -LiteralPath Function:\Invoke-TL1C1aProcess `
    -NewName Invoke-TL1C1aProcessSmokeUnderlying
$script:SmokeDirectAdbAttemptCount = 0L
$script:SmokeGradleMainCount = 0L
$script:SmokeApkSignerCount = 0L
$script:SmokeAapt2Count = 0L
$script:SmokeGitCount = 0L
$script:SmokeUnexpectedDirectProcessCount = 0L
$script:SmokeExpectedGitPath = $GitPath
$script:SmokeHeldJavaPath = $null
$script:SmokeHeldAapt2Path = $null
$script:SmokeExpectedGradleArguments = $null
$script:SmokeExpectedSignerArguments = $null
function Test-SmokeOrdinalArgumentSequence {
    param(
        [AllowNull()][string[]]$Actual,
        [AllowNull()][string[]]$Expected
    )
    if ($null -eq $Actual -or $null -eq $Expected -or
        $Actual.Count -ne $Expected.Count) {
        return $false
    }
    for ($index = 0; $index -lt $Actual.Count; $index++) {
        if ([string]$Actual[$index] -cne [string]$Expected[$index]) {
            return $false
        }
    }
    return $true
}
function Invoke-TL1C1aProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Operation,
        [byte[]]$InputBytes,
        [hashtable]$Environment,
        [switch]$ClearEnvironment,
        [ValidateRange(1, 300)][int]$TimeoutSec = 30,
        [switch]$AllowFailure
    )
    if ($null -eq $Environment -or -not $ClearEnvironment.IsPresent) {
        $script:SmokeUnexpectedDirectProcessCount++
        throw 'C1b build-only smoke requires an explicit cleared child environment.'
    }
    $fullProcessPath = [IO.Path]::GetFullPath($FilePath)
    $leaf = [IO.Path]::GetFileName($fullProcessPath)
    if ($leaf -ieq 'adb.exe') {
        $script:SmokeDirectAdbAttemptCount++
        throw 'C1b build-only smoke denied a direct adb.exe process attempt.'
    }
    if ($leaf -ieq 'git.exe') {
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
            $fullProcessPath,
            $script:SmokeExpectedGitPath)) {
            $script:SmokeUnexpectedDirectProcessCount++
            throw 'C1b build-only smoke denied a Git path outside the pinned held executable.'
        }
        $script:SmokeGitCount++
    }
    elseif ($leaf -ieq 'aapt2.exe') {
        if ([string]::IsNullOrWhiteSpace($script:SmokeHeldAapt2Path) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                $fullProcessPath,
                $script:SmokeHeldAapt2Path) -or
            $Arguments.Count -ne 5 -or
            $Arguments[0] -cne 'dump' -or
            $Arguments[1] -cne 'xmltree' -or
            $Arguments[3] -cne '--file') {
            $script:SmokeUnexpectedDirectProcessCount++
            throw 'C1b build-only smoke denied an unexpected aapt2 path or argv.'
        }
        $script:SmokeAapt2Count++
    }
    elseif ($leaf -ieq 'java.exe') {
        if ([string]::IsNullOrWhiteSpace($script:SmokeHeldJavaPath) -or
            -not [StringComparer]::OrdinalIgnoreCase.Equals(
                $fullProcessPath,
                $script:SmokeHeldJavaPath)) {
            $script:SmokeUnexpectedDirectProcessCount++
            throw 'C1b build-only smoke denied a Java path outside the pinned held executable.'
        }
        if ($Arguments -ccontains 'org.gradle.launcher.GradleMain') {
            if (-not (Test-SmokeOrdinalArgumentSequence `
                $Arguments $script:SmokeExpectedGradleArguments)) {
                $script:SmokeUnexpectedDirectProcessCount++
                throw 'C1b GradleMain argv drifted from the pinned sequence.'
            }
            $script:SmokeGradleMainCount++
        }
        elseif (@($Arguments | Where-Object {
            $_ -cmatch '(?:^|[\\/])apksigner\.jar$'
        }).Count -eq 1 -and
            $Arguments -ccontains 'verify' -and
            $Arguments -ccontains '--print-certs') {
            if (-not (Test-SmokeOrdinalArgumentSequence `
                $Arguments $script:SmokeExpectedSignerArguments)) {
                $script:SmokeUnexpectedDirectProcessCount++
                throw 'C1b ApkSignerTool argv drifted from the pinned sequence.'
            }
            $script:SmokeApkSignerCount++
        }
        else {
            $script:SmokeUnexpectedDirectProcessCount++
            throw 'C1b build-only smoke denied an unexpected direct Java invocation.'
        }
    }
    else {
        $script:SmokeUnexpectedDirectProcessCount++
        throw "C1b build-only smoke denied an unexpected direct process: $leaf"
    }
    return Invoke-TL1C1aProcessSmokeUnderlying @PSBoundParameters
}

function Get-SmokeAdbProcessSnapshot {
    try {
        return @(
            Get-CimInstance -Namespace root/cimv2 `
                -Query "SELECT ProcessId, ParentProcessId, CreationDate, ExecutablePath FROM Win32_Process WHERE Name='adb.exe'" `
                -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    pid = [uint32]$_.ProcessId
                    parent_pid = [uint32]$_.ParentProcessId
                    created = [string]$_.CreationDate
                    path = [string]$_.ExecutablePath
                }
            }
        )
    }
    catch { throw "ADB process snapshot unavailable: $($_.Exception.Message)" }
}
function Get-SmokeDefaultAdbListenerSnapshot {
    try {
        return @(
            Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { [int]$_.LocalPort -eq 5037 } |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    address = [string]$_.LocalAddress
                    port = [int]$_.LocalPort
                    pid = [uint32]$_.OwningProcess
                }
            }
        )
    }
    catch { throw "TCP/5037 listener snapshot unavailable: $($_.Exception.Message)" }
}

$preAdbProcesses = @()
$postAdbProcesses = @()
$preDefaultAdbListeners = @()
$postDefaultAdbListeners = @()
$eventSource = 'TL1C1bBuildSmokeProcessStart-' + [guid]::NewGuid().ToString('N')
$eventSubscription = $null
$eventSubscriptionId = $null
$eventObserverEstablished = $false
$eventUnregistered = $false
$eventObservationFailures = [Collections.Generic.List[string]]::new()
$adbStartEvents = @()
$directJavaStartEvents = @()
$otherJavaStartEvents = @()
$allObservedProcessStartEvents = @()
$guard = $null
$guardAnchor = $null
$aapt2TrustGuard = $null
$artifactProofGuard = $null
$debugApkGuard = $null
$releaseApkGuard = $null
$debugMergedManifestGuard = $null
$releaseMergedManifestGuard = $null
$coreResult = $null
$primaryFailure = $null
$cleanupFailures = [Collections.Generic.List[string]]::new()
$preGitProvenanceVerified = $false
$postGitProvenanceVerified = $false
$artifactGuardSeen = $false
$artifactGuardsCleanup = 'not_acquired'
$buildEnvironmentCleanup = 'not_acquired'
$repositoryLibraryGuardsCleanup = 'held'
$startedAt = [DateTime]::UtcNow
$buildRoot = Join-Path $RepoRoot 'app\tablet-c1b-probe\build'
$moduleGradleRoot = Join-Path $RepoRoot 'app\tablet-c1b-probe\.gradle'
$localPropertiesPath = Join-Path $RepoRoot 'app\local.properties'
$workspaceRoot = $null
$recoveryJournalPath = $null
}
catch {
    $setupFailure = $_.Exception
    $setupCleanupFailures = [Collections.Generic.List[Exception]]::new()
    for ($guardIndex = $repositoryLibraryGuards.Count - 1;
        $guardIndex -ge 0;
        $guardIndex--) {
        $setupGuard = $repositoryLibraryGuards[$guardIndex]
        try {
            $setupSafeHandle = $setupGuard.Guard.SafeFileHandle
            $setupGuard.Guard.Dispose()
            if (-not $setupSafeHandle.IsClosed) {
                throw "Repository library setup held file did not close: $($setupGuard.Path)"
            }
        }
        catch { $setupCleanupFailures.Add($_.Exception) }
    }
    if ($setupCleanupFailures.Count -eq 0) { throw $setupFailure }
    throw [AggregateException]::new(
        'C1b smoke setup and repository library cleanup both failed.',
        [Exception[]]@($setupFailure) + $setupCleanupFailures.ToArray())
}

try {
    $eventSubscription = Register-CimIndicationEvent -Namespace 'root/cimv2' `
        -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName='adb.exe' OR ProcessName='java.exe'" `
        -SourceIdentifier $eventSource -ErrorAction Stop
    $registeredSubscriber = Get-EventSubscriber -SourceIdentifier $eventSource `
        -ErrorAction Stop
    if (@($registeredSubscriber).Count -ne 1) {
        throw 'C1b process-start observer did not create exactly one subscriber.'
    }
    $eventSubscriptionId = [int]$registeredSubscriber.SubscriptionId
    $eventObserverEstablished = $true
    $preAdbProcesses = @(Get-SmokeAdbProcessSnapshot)
    $preDefaultAdbListeners = @(Get-SmokeDefaultAdbListenerSnapshot)
    if ($preAdbProcesses.Count -ne 0 -or $preDefaultAdbListeners.Count -ne 0) {
        throw 'C1b build-only smoke requires zero pre-existing adb processes and zero TCP/5037 listeners.'
    }

    $guard = Open-TL1C1bBuildEnvironmentTrustGuard `
        -RepoRoot $RepoRoot -JavaHome $JavaHome -GradleHome $GradleHome `
        -AndroidSdkRoot $AndroidSdkRoot -GitPath $GitPath `
        -GradleUserHomeParent ([IO.Path]::GetTempPath()) `
        -RepositoryInputPaths $repositoryInputPaths `
        -RepositoryInputDirectories $repositoryInputDirectories
    $guardAnchor = $guard
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
        [IO.Path]::GetFullPath([string]$guard.GitPath),
        $script:SmokeExpectedGitPath)) {
        throw 'C1b build-environment guard Git path drifted from the bootstrap binding.'
    }
    $workspaceRoot = [string]$guard.Workspace.Root
    $recoveryJournalPath = [string]$guard.RecoveryJournal.Path

    $binding = Assert-TL1C1bBuildEnvironmentFrozen $guard
    $preSealBindingRaw = $binding | ConvertTo-Json -Depth 20 -Compress
    if ([long]$binding.repository_inputs.file_count -ne 42 -or
        [long]$binding.repository_inputs.directory_root_count -ne 3 -or
        [string]$binding.repository_inputs.catalog_sha256 -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'C1b real build smoke repository-input binding drifted.'
    }
    $environment = Get-TL1C1bBuildEnvironmentBuildEnvironment $guard
    $gitEnvironment = Get-TL1C1bBuildEnvironmentGitEnvironment $guard
    [void](Assert-TL1C1aGitProvenance -RepoRoot $RepoRoot `
        -ExpectedCommitSha $ExpectedCommitSha -GitPath $guard.GitPath `
        -ProcessEnvironment $gitEnvironment -ClearEnvironment)
    $preGitProvenanceVerified = $true

    $isolatedSdkRoot = [IO.Path]::GetFullPath([string]$guard.AndroidSdkRoot)
    $aapt2TrustGuard = Open-TL1C1bAapt2TrustGuard -RepoRoot $RepoRoot `
        -AndroidSdkRoot $isolatedSdkRoot -AndroidHome $isolatedSdkRoot
    $aapt2TrustBinding = $aapt2TrustGuard.Binding
    $script:SmokeHeldAapt2Path = [IO.Path]::GetFullPath(
        [string]$aapt2TrustGuard.CanonicalPath)

    $buildChallenge = 'c1b-' + [Convert]::ToHexString(
        [Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
    ).ToLowerInvariant()
    $environment['TABLET_C1B_BUILD_CHALLENGE'] = $buildChallenge
    $environment['TL1_C1B_EXPECTED_COMMIT_SHA'] = $ExpectedCommitSha

    $gradleInvocation = Get-TL1C1bBuildEnvironmentGradleInvocation $guard
    $signerInvocation = Get-TL1C1bBuildEnvironmentApkSignerInvocation $guard
    if ([string]$gradleInvocation.FilePath -cne [string]$signerInvocation.FilePath) {
        throw 'C1b GradleMain and ApkSignerTool are not bound to the same held Java.'
    }
    $script:SmokeHeldJavaPath = [IO.Path]::GetFullPath(
        [string]$gradleInvocation.FilePath)
    $gradleArguments = [string[]]@(
        @($gradleInvocation.Arguments)
        @(Get-TL1C1bBuildEnvironmentGradleArguments $guard)
        @(
            '-p', (Join-Path $RepoRoot 'app'),
            ':tablet-c1b-probe:verifyTabletC1bReadOnlyArtifact',
            '--dependency-verification=strict',
            '--no-build-cache',
            '--no-configuration-cache',
            '--rerun-tasks',
            '--no-daemon',
            '--console=plain',
            '--quiet'
        )
    )
    $script:SmokeExpectedGradleArguments = [string[]]$gradleArguments.Clone()
    $buildStarted = [DateTime]::UtcNow
    [void](Invoke-TL1C1aProcess -FilePath ([string]$gradleInvocation.FilePath) `
        -Arguments $gradleArguments `
        -Operation 'C1b 42-input real isolated direct GradleMain smoke' `
        -Environment $environment -ClearEnvironment -TimeoutSec 300)

    $binding = Seal-TL1C1bBuildEnvironmentDebugKeystoreLock `
        -TrustGuard $guard -ExpectedTrustGuard $guardAnchor `
        -ExpectedPreSealBindingRaw $preSealBindingRaw
    if (-not [bool]$binding.debug_keystore.post_gradle_lock_sealed_achieved) {
        throw 'C1b post-Gradle debug.keystore.lock seal was not achieved.'
    }
    $postSealBindingRaw = $binding | ConvertTo-Json -Depth 20 -Compress

    $debugApk = Join-Path $buildRoot 'outputs\apk\debug\tablet-c1b-probe-debug.apk'
    $releaseApk = Join-Path $buildRoot 'outputs\apk\release\tablet-c1b-probe-release-unsigned.apk'
    $artifactProof = Join-Path $buildRoot 'reports\tablet-c1b-read-only-artifact-proof.json'
    $artifactProofSchema = Join-Path $RepoRoot `
        'docs\contracts\tablet-c1b-read-only-artifact-proof-v1.schema.json'
    foreach ($freshPath in @($debugApk, $releaseApk, $artifactProof)) {
        if (-not (Test-Path -LiteralPath $freshPath -PathType Leaf)) {
            throw "C1b real build smoke artifact is missing: $freshPath"
        }
        $freshItem = Get-Item -LiteralPath $freshPath -Force
        if (($freshItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $freshItem.LastWriteTimeUtc -lt $buildStarted.AddSeconds(-2)) {
            throw "C1b real build smoke artifact is not fresh and ordinary: $freshPath"
        }
    }

    $artifactProofGuard = Open-TL1C1bArtifactGuard $RepoRoot $artifactProof
    $debugApkGuard = Open-TL1C1bArtifactGuard $RepoRoot $debugApk
    $releaseApkGuard = Open-TL1C1bArtifactGuard $RepoRoot $releaseApk
    $artifactBinding = Assert-TL1C1bReadOnlyArtifactProof `
        -RepoRoot $RepoRoot -ProofPath $artifactProof `
        -ProofSchemaPath $artifactProofSchema -ExpectedCommitSha $ExpectedCommitSha `
        -BuildChallenge $buildChallenge -DebugApkPath $debugApk `
        -Aapt2TrustBinding $aapt2TrustBinding -ProofGuard $artifactProofGuard `
        -DebugApkGuard $debugApkGuard -ReleaseApkGuard $releaseApkGuard
    $artifactBindingRaw = $artifactBinding | ConvertTo-Json -Depth 20 -Compress

    $debugMergedManifestGuard = Open-TL1C1bArtifactGuard `
        $RepoRoot $artifactBinding.Debug.MergedManifestPath
    $releaseMergedManifestGuard = Open-TL1C1bArtifactGuard `
        $RepoRoot $artifactBinding.Release.MergedManifestPath
    if ([string]$debugMergedManifestGuard.Sha256 -cne
            [string]$artifactBinding.Debug.MergedManifestSha256 -or
        [string]$releaseMergedManifestGuard.Sha256 -cne
            [string]$artifactBinding.Release.MergedManifestSha256) {
        throw 'C1b merged-manifest held guards are not bound to the artifact proof.'
    }

    $debugAxml = Get-TL1C1bPackagedAxmlDumpBinding `
        -TrustGuard $aapt2TrustGuard -ArtifactGuard $debugApkGuard `
        -Variant debug -ProcessEnvironment $environment -ClearEnvironment
    $releaseAxml = Get-TL1C1bPackagedAxmlDumpBinding `
        -TrustGuard $aapt2TrustGuard -ArtifactGuard $releaseApkGuard `
        -Variant release -ProcessEnvironment $environment -ClearEnvironment
    foreach ($pair in @(
        [pscustomobject]@{ Actual = $debugAxml; Expected = $artifactBinding.Debug },
        [pscustomobject]@{ Actual = $releaseAxml; Expected = $artifactBinding.Release }
    )) {
        if ([string]$pair.Actual.ApkSha256 -cne [string]$pair.Expected.ApkSha256 -or
            [string]$pair.Actual.PackagedManifestAxmlDumpSha256 -cne
                [string]$pair.Expected.PackagedManifestAxmlDumpSha256 -or
            [string]$pair.Actual.PackagedA11yAxmlDumpSha256 -cne
                [string]$pair.Expected.PackagedA11yAxmlDumpSha256) {
            throw 'C1b packaged AXML held re-read does not match the artifact proof.'
        }
    }
    $packagedAxmlVerified = [bool]$artifactBinding.AxmlParserVerified -and
        [bool]$artifactBinding.Debug.PackagedManifestExactTreeVerified -and
        [bool]$artifactBinding.Debug.PackagedA11yExactTreeVerified -and
        [bool]$artifactBinding.Release.PackagedManifestExactTreeVerified -and
        [bool]$artifactBinding.Release.PackagedA11yExactTreeVerified
    if (-not $packagedAxmlVerified) {
        throw 'C1b packaged AXML exact-tree verification is incomplete.'
    }

    $signerArguments = [string[]]@(
        @($signerInvocation.Arguments) + @('verify', '--print-certs', $debugApk)
    )
    $script:SmokeExpectedSignerArguments = [string[]]$signerArguments.Clone()
    $signerResult = Invoke-TL1C1aProcess `
        -FilePath ([string]$signerInvocation.FilePath) `
        -Arguments $signerArguments `
        -Operation 'C1b 42-input real isolated direct ApkSignerTool smoke' `
        -Environment $environment -ClearEnvironment -TimeoutSec 60
    if (-not [string]::IsNullOrWhiteSpace([string]$signerResult.Stderr)) {
        throw 'C1b ApkSignerTool verification produced stderr.'
    }
    $signerMatches = @([regex]::Matches(
        [string]$signerResult.Text,
        '(?im)^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-f]{64})\s*$'
    ))
    if ($signerMatches.Count -ne 1) {
        throw 'C1b ApkSignerTool certificate digest is missing or ambiguous.'
    }
    $signerSha256 = 'sha256:' + $signerMatches[0].Groups[1].Value.ToLowerInvariant()

    $finalArtifactBinding = Assert-TL1C1bReadOnlyArtifactProof `
        -RepoRoot $RepoRoot -ProofPath $artifactProof `
        -ProofSchemaPath $artifactProofSchema -ExpectedCommitSha $ExpectedCommitSha `
        -BuildChallenge $buildChallenge -DebugApkPath $debugApk `
        -Aapt2TrustBinding $aapt2TrustBinding -ProofGuard $artifactProofGuard `
        -DebugApkGuard $debugApkGuard -ReleaseApkGuard $releaseApkGuard
    if (($finalArtifactBinding | ConvertTo-Json -Depth 20 -Compress) -cne
        $artifactBindingRaw) {
        throw 'C1b final artifact-proof binding drifted.'
    }
    $binding = Assert-TL1C1bBuildEnvironmentFrozen $guard
    if (-not [object]::ReferenceEquals($guard, $guardAnchor) -or
        ($binding | ConvertTo-Json -Depth 20 -Compress) -cne $postSealBindingRaw) {
        throw 'C1b final build-environment binding drifted after the post-Gradle seal.'
    }
    [void](Assert-TL1C1bAapt2TrustGuardUnchanged $aapt2TrustGuard)
    [void](Assert-TL1C1aGitProvenance -RepoRoot $RepoRoot `
        -ExpectedCommitSha $ExpectedCommitSha -GitPath $guard.GitPath `
        -ProcessEnvironment $gitEnvironment -ClearEnvironment)
    $postGitProvenanceVerified = $true
    if ((Get-TL1C1aFileSha256 $helperPath) -cne $helperSha256) {
        throw 'C1b one-shot smoke helper changed during execution.'
    }
    if ($script:SmokeGradleMainCount -ne 1 -or
        $script:SmokeApkSignerCount -ne 1 -or
        $script:SmokeAapt2Count -ne 4 -or
        $script:SmokeGitCount -ne 32 -or
        $script:SmokeDirectAdbAttemptCount -ne 0 -or
        $script:SmokeUnexpectedDirectProcessCount -ne 0) {
        throw 'C1b direct process call counts are outside the build-only contract.'
    }

    $coreResult = [ordered]@{
        status = 'passed'
        expected_commit_sha = $ExpectedCommitSha
        helper_sha256 = $helperSha256
        build_environment_schema = [string]$binding.schema
        repository_input_count = [long]$binding.repository_inputs.file_count
        repository_input_catalog_sha256 = [string]$binding.repository_inputs.catalog_sha256
        repository_input_directory_root_count = [long]$binding.repository_inputs.directory_root_count
        jdk_version = [string]$binding.jdk.version
        jdk_catalog_sha256 = [string]$binding.jdk.catalog_sha256
        gradle_version = [string]$binding.gradle.version
        gradle_catalog_sha256 = [string]$binding.gradle.catalog_sha256
        gradle_entrypoint = [string]$binding.gradle.entrypoint
        wrapper_not_executed = [bool]$binding.gradle.wrapper_not_executed
        apksigner_jar_sha256 = [string]$binding.android_sdk.build_tools.apksigner_jar_sha256
        artifact_proof_sha256 = [string]$artifactBinding.ProofSha256
        debug_apk_sha256 = [string]$artifactBinding.Debug.ApkSha256
        release_apk_sha256 = [string]$artifactBinding.Release.ApkSha256
        signer_certificate_sha256 = $signerSha256
        forbidden_match_count = [long]$artifactBinding.ForbiddenMatchCount
        manifest_mutating_capability_count = [long]$artifactBinding.ManifestMutatingCapabilityCount
        manifest_extra_component_count = [long]$artifactBinding.ManifestExtraComponentCount
        dependency_allowlist_verified = [bool]$artifactBinding.DependencyAllowlistVerified
        packaged_axml_verified = $packagedAxmlVerified
        post_gradle_lock_sealed = [bool]$binding.debug_keystore.post_gradle_lock_sealed_achieved
        pre_git_provenance_verified = [bool]$preGitProvenanceVerified
        post_git_provenance_verified = [bool]$postGitProvenanceVerified
    }
}
catch {
    $primaryFailure = $_.Exception
}
finally {
    foreach ($heldGuard in @(
        $releaseMergedManifestGuard,
        $debugMergedManifestGuard,
        $releaseApkGuard,
        $debugApkGuard,
        $artifactProofGuard,
        $aapt2TrustGuard
    )) {
        if ($null -eq $heldGuard) { continue }
        $artifactGuardSeen = $true
        try {
            $heldStream = $heldGuard.Guard
            $heldSafeHandle = $heldStream.SafeFileHandle
            $heldStream.Dispose()
            if (-not $heldSafeHandle.IsClosed) {
                throw 'Held artifact/aapt2 handle did not close.'
            }
        }
        catch {
            $artifactGuardsCleanup = 'failed'
            $cleanupFailures.Add($_.Exception.Message)
        }
    }
    if ($artifactGuardSeen -and $artifactGuardsCleanup -cne 'failed') {
        $artifactGuardsCleanup = 'completed'
    }
    if ($null -ne $guard) {
        $buildEnvironmentCleanup = 'completed'
        try {
            Close-TL1C1bBuildEnvironmentTrustGuard $guard
            if (-not [bool]$guard.Disposed) {
                throw 'Build-environment guard did not enter disposed state.'
            }
        }
        catch {
            $buildEnvironmentCleanup = 'failed'
            $cleanupFailures.Add($_.Exception.Message)
        }
    }
    $repositoryLibraryGuardsCleanup = 'completed'
    foreach ($libraryGuard in $repositoryLibraryGuards) {
        try {
            $librarySafeHandle = $libraryGuard.Guard.SafeFileHandle
            $libraryGuard.Guard.Dispose()
            if (-not $librarySafeHandle.IsClosed) {
                throw "Repository library held file did not close: $($libraryGuard.Path)"
            }
        }
        catch {
            $repositoryLibraryGuardsCleanup = 'failed'
            $cleanupFailures.Add($_.Exception.Message)
        }
    }
}

$workspaceResidual = $false
$journalResidual = $false
$moduleBuildResidual = $false
$moduleGradleResidual = $false
$localPropertiesResidual = $false
$c1bJavaResidualCount = 0L
$observationEndedAt = $null
$postBoundaryAndResidueObservationCompleted = $false
try {
    $postAdbProcesses = @(Get-SmokeAdbProcessSnapshot)
    $postDefaultAdbListeners = @(Get-SmokeDefaultAdbListenerSnapshot)
    if (-not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $workspaceResidual = Test-Path -LiteralPath $workspaceRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($recoveryJournalPath)) {
        $journalResidual = Test-Path -LiteralPath $recoveryJournalPath
    }
    $moduleBuildResidual = Test-Path -LiteralPath $buildRoot
    $moduleGradleResidual = Test-Path -LiteralPath $moduleGradleRoot
    $localPropertiesResidual = Test-Path -LiteralPath $localPropertiesPath
    if (-not [string]::IsNullOrWhiteSpace($workspaceRoot)) {
        $c1bJavaResidualCount = [long]@(
            Get-CimInstance -Namespace root/cimv2 `
                -Query "SELECT ProcessId, ParentProcessId, CommandLine FROM Win32_Process WHERE Name='java.exe'" `
                -ErrorAction Stop |
            Where-Object {
                ([string]$_.CommandLine).IndexOf(
                    $workspaceRoot,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0
            }
        ).Count
    }
    $postBoundaryAndResidueObservationCompleted = $true
}
catch { $eventObservationFailures.Add($_.Exception.Message) }

if ($null -ne $eventSubscriptionId) {
    try {
        Start-Sleep -Seconds 2
        $activeSubscriber = @(
            Get-EventSubscriber -ErrorAction Stop |
            Where-Object { [int]$_.SubscriptionId -eq $eventSubscriptionId }
        )
        if ($activeSubscriber.Count -ne 1 -or
            [string]$activeSubscriber[0].SourceIdentifier -cne $eventSource) {
            throw 'C1b process-start observer subscriber drifted before shutdown.'
        }
        Unregister-Event -SubscriptionId $eventSubscriptionId -ErrorAction Stop
        $eventUnregistered = $true
        $observationEndedAt = [DateTime]::UtcNow
    }
    catch { $eventObservationFailures.Add($_.Exception.Message) }
}

if (-not $eventUnregistered -and $null -ne $eventSubscriptionId) {
    try {
        Unregister-Event -SubscriptionId $eventSubscriptionId -ErrorAction Stop
        $eventUnregistered = $true
        $observationEndedAt = [DateTime]::UtcNow
    }
    catch { $eventObservationFailures.Add("observer unregister cleanup: $($_.Exception.Message)") }
}
if (-not $eventUnregistered) {
    try {
        $fallbackSubscribers = @(
            Get-EventSubscriber -ErrorAction Stop |
            Where-Object { [string]$_.SourceIdentifier -ceq $eventSource }
        )
        if ($fallbackSubscribers.Count -eq 0) {
            throw 'C1b process-start observer subscriber was already absent before fallback shutdown.'
        }
        foreach ($fallbackSubscriber in $fallbackSubscribers) {
            Unregister-Event -SubscriptionId ([int]$fallbackSubscriber.SubscriptionId) `
                -ErrorAction Stop
        }
        $eventUnregistered = $true
        $observationEndedAt = [DateTime]::UtcNow
    }
    catch { $eventObservationFailures.Add("observer source cleanup: $($_.Exception.Message)") }
}

try {
    $allObservedProcessStartEvents = @(
        Get-Event -ErrorAction Stop |
        Where-Object { [string]$_.SourceIdentifier -ceq $eventSource }
    )
    foreach ($processEvent in $allObservedProcessStartEvents) {
        $newEvent = $processEvent.SourceEventArgs.NewEvent
        $processName = [string]$newEvent.ProcessName
        if ($processName -ieq 'adb.exe') {
            $adbStartEvents += $processEvent
        }
        elseif ($processName -ieq 'java.exe') {
            if ([uint32]$newEvent.ParentProcessID -eq [uint32]$PID) {
                $directJavaStartEvents += $processEvent
            }
            else {
                $otherJavaStartEvents += $processEvent
            }
        }
        else {
            throw "C1b process-start observer delivered an unexpected event: $processName"
        }
    }
}
catch { $eventObservationFailures.Add($_.Exception.Message) }
finally {
    foreach ($processEvent in $allObservedProcessStartEvents) {
        try { Remove-Event -EventIdentifier $processEvent.EventIdentifier -ErrorAction Stop }
        catch { $eventObservationFailures.Add("observer event cleanup: $($_.Exception.Message)") }
    }
    try {
        $remainingSubscribers = @(
            Get-EventSubscriber -ErrorAction Stop |
            Where-Object { [string]$_.SourceIdentifier -ceq $eventSource }
        )
        $remainingEvents = @(
            Get-Event -ErrorAction Stop |
            Where-Object { [string]$_.SourceIdentifier -ceq $eventSource }
        )
        if ($remainingSubscribers.Count -ne 0 -or $remainingEvents.Count -ne 0) {
            throw 'C1b process-start observer cleanup left subscriber or event residue.'
        }
    }
    catch { $eventObservationFailures.Add($_.Exception.Message) }
}
if (-not $postBoundaryAndResidueObservationCompleted) {
    $eventObservationFailures.Add(
        'C1b post-boundary or residue observation did not complete.')
}
if (-not $eventObserverEstablished -or -not $eventUnregistered) {
    if ($eventObservationFailures.Count -eq 0) {
        $eventObservationFailures.Add(
            'C1b process-start observer did not reach an established and successfully unregistered state.')
    }
    $observationEndedAt = $null
}

$finalFailures = [Collections.Generic.List[string]]::new()
$maximumObserverFailureReasons = 16L
$observerFailureReasonCount = [Math]::Min(
    [long]$eventObservationFailures.Count,
    $maximumObserverFailureReasons)
for ($failureIndex = 0L;
    $failureIndex -lt $observerFailureReasonCount;
    $failureIndex++) {
    $finalFailures.Add(
        "observer: $($eventObservationFailures[[int]$failureIndex])")
}
if ([long]$eventObservationFailures.Count -gt
    $maximumObserverFailureReasons) {
    $omittedObserverFailureCount = [long]$eventObservationFailures.Count -
        $maximumObserverFailureReasons
    $finalFailures.Add(
        "observer: closed-bound omitted_count=$omittedObserverFailureCount.")
}
if ($script:SmokeDirectAdbAttemptCount -ne 0 -or $adbStartEvents.Count -ne 0 -or
    $preAdbProcesses.Count -ne 0 -or $postAdbProcesses.Count -ne 0 -or
    $preDefaultAdbListeners.Count -ne 0 -or $postDefaultAdbListeners.Count -ne 0) {
    $finalFailures.Add(
        'ADB-zero boundary failed: direct attempt, process-start event, process snapshot, or TCP/5037 listener was nonzero.')
}
if ($null -ne $primaryFailure) {
    $finalFailures.Add("primary: $($primaryFailure.Message)")
}
$maximumCleanupFailureReasons = 16L
$cleanupFailureReasonCount = [Math]::Min(
    [long]$cleanupFailures.Count,
    $maximumCleanupFailureReasons)
for ($failureIndex = 0L;
    $failureIndex -lt $cleanupFailureReasonCount;
    $failureIndex++) {
    $finalFailures.Add("cleanup: $($cleanupFailures[[int]$failureIndex])")
}
if ([long]$cleanupFailures.Count -gt $maximumCleanupFailureReasons) {
    $omittedCleanupFailureCount = [long]$cleanupFailures.Count -
        $maximumCleanupFailureReasons
    $finalFailures.Add(
        "cleanup: closed-bound omitted_count=$omittedCleanupFailureCount.")
}
if ($null -eq $coreResult) {
    $finalFailures.Add('core: real build smoke result is missing.')
}
if ($null -ne $coreResult -and $directJavaStartEvents.Count -ne 2) {
    $finalFailures.Add(
        "observer: direct-child Java event canary expected 2, observed $($directJavaStartEvents.Count).")
}
if ($workspaceResidual -or $journalResidual -or $moduleBuildResidual -or
    $moduleGradleResidual -or $localPropertiesResidual -or $c1bJavaResidualCount -ne 0) {
    $finalFailures.Add(
        'residue: workspace, journal, module output, local.properties, or C1b Java process remained.')
}

$completedAt = [DateTime]::UtcNow
$summaryValues = [ordered]@{
    schema = 'tablet-layout-c1b-real-build-smoke-summary/v1'
    started_at_utc = $startedAt.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'")
    completed_at_utc = $completedAt.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'")
    status = if ($finalFailures.Count -eq 0) { 'passed' } else { 'failed' }
    expected_commit_sha = $ExpectedCommitSha
    helper_sha256 = $helperSha256
    bootstrap_git_execution_count = [long]$script:SmokeBootstrapGitCount
    bootstrap_git_provenance_verified = [bool](
        $bootstrapHead -ceq $ExpectedCommitSha -and
        [string]::IsNullOrWhiteSpace($bootstrapStatus))
    pre_git_provenance_verified = [bool]$preGitProvenanceVerified
    post_git_provenance_verified = [bool]$postGitProvenanceVerified
    build_environment_schema = $null
    repository_input_count = $null
    repository_input_catalog_sha256 = $null
    repository_input_directory_root_count = $null
    real_jdk_gradlemain_execution_count = [long]$script:SmokeGradleMainCount
    real_apksigner_execution_count = [long]$script:SmokeApkSignerCount
    held_aapt2_verification_execution_count = [long]$script:SmokeAapt2Count
    held_git_execution_count = [long]$script:SmokeGitCount
    unexpected_direct_process_count = [long]$script:SmokeUnexpectedDirectProcessCount
    direct_adb_attempt_count = [long]$script:SmokeDirectAdbAttemptCount
    observed_adb_process_start_count = [long]$adbStartEvents.Count
    real_adb_call_count = [long](
        $script:SmokeDirectAdbAttemptCount + $adbStartEvents.Count)
    observed_direct_child_java_process_start_count = [long]$directJavaStartEvents.Count
    observed_other_java_process_start_count = [long]$otherJavaStartEvents.Count
    process_start_observer_scope = 'host_wide_best_effort_wmi'
    process_start_observer_limitation = 'Win32_ProcessStartTrace is operational observation, not a persistent kernel or syscall audit.'
    process_start_observation_ended_at_utc = if ($null -eq $observationEndedAt) {
        $null
    } else {
        $observationEndedAt.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'")
    }
    pre_adb_process_count = [long]$preAdbProcesses.Count
    post_adb_process_count = [long]$postAdbProcesses.Count
    pre_default_adb_listener_count = [long]$preDefaultAdbListeners.Count
    post_default_adb_listener_count = [long]$postDefaultAdbListeners.Count
    default_adb_listener_observation = 'boundary_snapshots_only'
    device_enumeration_call_count = 0L
    install_attempt_count = 0L
    t0_call_count = 0L
    capture_call_count = 0L
    jdk_version = $null
    jdk_catalog_sha256 = $null
    gradle_version = $null
    gradle_catalog_sha256 = $null
    gradle_entrypoint = $null
    wrapper_not_executed = $null
    apksigner_jar_sha256 = $null
    artifact_proof_sha256 = $null
    debug_apk_sha256 = $null
    release_apk_sha256 = $null
    signer_certificate_sha256 = $null
    forbidden_match_count = $null
    manifest_mutating_capability_count = $null
    manifest_extra_component_count = $null
    dependency_allowlist_verified = $null
    packaged_axml_verified = $null
    post_gradle_lock_sealed = $null
    artifact_guards_cleanup = $artifactGuardsCleanup
    build_environment_cleanup = $buildEnvironmentCleanup
    repository_library_guards_cleanup = $repositoryLibraryGuardsCleanup
    workspace_residual = $workspaceResidual
    recovery_journal_residual = $journalResidual
    module_build_residual = $moduleBuildResidual
    module_gradle_residual = $moduleGradleResidual
    local_properties_residual = $localPropertiesResidual
    c1b_java_residual_count = $c1bJavaResidualCount
    failure_count = [long]$finalFailures.Count
    failure_reasons = [string[]]@($finalFailures | ForEach-Object {
        $message = [regex]::Replace(
            [string]$_,
            '[\u0000-\u001f\\"]',
            ' ',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        if ($message.Length -gt 128) { $message.Substring(0, 128) } else { $message }
    })
}
$coreFields = [string[]]@(
    'build_environment_schema',
    'repository_input_count',
    'repository_input_catalog_sha256',
    'repository_input_directory_root_count',
    'jdk_version',
    'jdk_catalog_sha256',
    'gradle_version',
    'gradle_catalog_sha256',
    'gradle_entrypoint',
    'wrapper_not_executed',
    'apksigner_jar_sha256',
    'artifact_proof_sha256',
    'debug_apk_sha256',
    'release_apk_sha256',
    'signer_certificate_sha256',
    'forbidden_match_count',
    'manifest_mutating_capability_count',
    'manifest_extra_component_count',
    'dependency_allowlist_verified',
    'packaged_axml_verified',
    'post_gradle_lock_sealed'
)
if ($null -ne $coreResult) {
    foreach ($fieldName in $coreFields) {
        $summaryValues[$fieldName] = $coreResult[$fieldName]
    }
}
$summary = [pscustomobject]$summaryValues
$summaryRaw = $summary | ConvertTo-Json -Depth 12 -Compress
$summaryBytes = [Text.UTF8Encoding]::new($false).GetBytes($summaryRaw)
if ($summaryBytes.Length -lt 1 -or $summaryBytes.Length -gt 65536) {
    throw 'C1b real build smoke summary exceeded the closed 1..65536-byte contract.'
}
$summaryTempPath = Join-Path $summaryParent (
    '.' + [IO.Path]::GetFileName($SummaryPath) + '.' +
    [guid]::NewGuid().ToString('N') + '.tmp')
$summaryStream = $null
$summaryPublished = $false
$summaryPublicationFailures = [Collections.Generic.List[Exception]]::new()
try {
    $summaryStream = [IO.FileStream]::new(
        $summaryTempPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None)
    $summaryStream.Write($summaryBytes, 0, $summaryBytes.Length)
    $summaryStream.Flush($true)
    $summaryStream.Dispose()
    $summaryStream = $null

    $tempReadbackBytes = [IO.File]::ReadAllBytes($summaryTempPath)
    try {
        $tempReadbackRaw = [Text.UTF8Encoding]::new($false, $true).GetString(
            $tempReadbackBytes)
    }
    finally {
        if ($tempReadbackBytes.Length -ne 0) {
            [Array]::Clear($tempReadbackBytes, 0, $tempReadbackBytes.Length)
        }
    }
    if ($tempReadbackRaw -cne $summaryRaw) {
        throw 'C1b real build smoke temporary summary readback drifted.'
    }
    $null = $tempReadbackRaw | ConvertFrom-Json -ErrorAction Stop
    [IO.File]::Move($summaryTempPath, $SummaryPath, $false)
    $summaryPublished = $true
}
catch {
    $summaryPublicationFailures.Add($_.Exception)
}
finally {
    if ($null -ne $summaryStream) {
        try { $summaryStream.Dispose() }
        catch { $summaryPublicationFailures.Add($_.Exception) }
    }
    if ($summaryBytes.Length -ne 0) { [Array]::Clear($summaryBytes, 0, $summaryBytes.Length) }
    try {
        if (-not $summaryPublished -and (Test-Path -LiteralPath $summaryTempPath)) {
            Remove-Item -LiteralPath $summaryTempPath -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $summaryTempPath) {
                throw 'C1b real build smoke temporary summary remained after cleanup.'
            }
        }
    }
    catch { $summaryPublicationFailures.Add($_.Exception) }
}
if ($summaryPublicationFailures.Count -eq 1) {
    throw $summaryPublicationFailures[0]
}
if ($summaryPublicationFailures.Count -gt 1) {
    throw [AggregateException]::new(
        'C1b real build smoke summary publication or cleanup failed.',
        $summaryPublicationFailures.ToArray())
}
$readbackBytes = [IO.File]::ReadAllBytes($SummaryPath)
try {
    $readbackRaw = [Text.UTF8Encoding]::new($false, $true).GetString($readbackBytes)
}
finally {
    if ($readbackBytes.Length -ne 0) { [Array]::Clear($readbackBytes, 0, $readbackBytes.Length) }
}
if ($readbackRaw -cne $summaryRaw) {
    throw 'C1b real build smoke summary readback drifted.'
}
[Console]::WriteLine($summaryRaw)
if ($finalFailures.Count -ne 0) {
    throw "C1b real build smoke failed; see $SummaryPath"
}
