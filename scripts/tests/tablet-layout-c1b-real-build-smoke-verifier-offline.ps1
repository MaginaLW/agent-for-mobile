#Requires -Version 7.5
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)

$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$LibraryPath = Join-Path $RepoRoot 'scripts\lib\tablet-layout-c1b-real-build-smoke-verifier.ps1'
$FixturePath = Join-Path $PSScriptRoot 'fixtures\tablet-layout-c1b-real-build-smoke-summary-v1.json'
$FixtureParent = [IO.Path]::GetDirectoryName($FixturePath)
$ExpectedCommitSha = '8882add6116ebd3cca547d865f9d142bbbcac1a4'
$ExpectedHelperSha256 = 'be4d2afa0e48aa1492eae870b5df6bfa9913a518a70770b0f46e64f4315014c9'
$FixtureExpectedByteLength = 2998L
$FixtureExpectedSha256 = 'sha256:ec4d8ed153e9ca95448084099122e3eba227dcf6e74d70a145e31d6d3f1b0715'
$HelperProcessStartedNotBeforeUtc = [DateTimeOffset]::Parse('2026-08-29T10:54:52.0000000Z')
$HelperProcessExitedNotAfterUtc = [DateTimeOffset]::Parse('2026-08-29T11:22:56.0000000Z')
$MaximumObserverTailSeconds = 5.0

$libraryItem = Microsoft.PowerShell.Management\Get-Item `
    -LiteralPath $LibraryPath -Force -ErrorAction Stop
$libraryLinkProperty = $libraryItem.PSObject.Properties['LinkType']
$libraryLinkType = if ($null -eq $libraryLinkProperty) {
    ''
} else {
    [string]$libraryLinkProperty.Value
}
if ($libraryItem.PSIsContainer -or
    ($libraryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    -not [string]::IsNullOrWhiteSpace($libraryLinkType)) {
    throw 'Verifier library authority path is not one ordinary unlinked file.'
}
$libraryAuthorityStream = [IO.File]::Open(
    $LibraryPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
    [IO.FileShare]::Read)
$libraryAuthorityLength = [long]$libraryAuthorityStream.Length
if ($libraryAuthorityLength -lt 1 -or $libraryAuthorityLength -gt 65536) {
    throw 'Verifier library authority length is outside 1..65536 bytes.'
}
$libraryAuthorityBytes = [byte[]]::new([int]$libraryAuthorityLength)
$libraryOffset = 0
while ($libraryOffset -lt $libraryAuthorityBytes.Length) {
    $libraryRead = $libraryAuthorityStream.Read(
        $libraryAuthorityBytes, $libraryOffset,
        $libraryAuthorityBytes.Length - $libraryOffset)
    if ($libraryRead -le 0) { throw 'Verifier library held read ended early.' }
    $libraryOffset += $libraryRead
}
if ($libraryAuthorityStream.ReadByte() -ne -1) {
    throw 'Verifier library held length changed during pre-load read.'
}
$libraryAuthoritySha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        $libraryAuthorityBytes)).ToLowerInvariant()
$libraryAuthorityLastWriteUtc = $libraryItem.LastWriteTimeUtc
$librarySource = [Text.UTF8Encoding]::new(
    $false, $true).GetString($libraryAuthorityBytes)
$libraryTokens = $null
$libraryErrors = $null
$libraryAst = [Management.Automation.Language.Parser]::ParseInput(
    $librarySource, $LibraryPath, [ref]$libraryTokens, [ref]$libraryErrors)
if ($libraryErrors.Count -ne 0) { throw 'Verifier library parser errors prevent the offline test.' }
$expectedFunctionNames = [string[]]@($libraryAst.FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true) | ForEach-Object { $_.Name } | Sort-Object -Unique)

# Fail fast before dot-sourcing: the tracked verifier is executable authority.
# Its PowerShell command graph and embedded native surface must remain closed.
$topLevelStatements = @($libraryAst.EndBlock.Statements)
$topLevelFunctions = @($topLevelStatements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst]
})
$topLevelIfStatements = @($topLevelStatements | Where-Object {
    $_ -is [Management.Automation.Language.IfStatementAst]
})
$topLevelAssignments = @($topLevelStatements | Where-Object {
    $_ -is [Management.Automation.Language.AssignmentStatementAst]
})
if ($expectedFunctionNames.Count -ne 16 -or
    $topLevelFunctions.Count -ne $expectedFunctionNames.Count -or
    $topLevelIfStatements.Count -ne 1 -or
    $topLevelAssignments.Count -ne 1 -or
    $topLevelStatements.Count -ne ($expectedFunctionNames.Count + 2)) {
    throw 'Verifier top-level AST is not exactly one contamination guard, one Add-Type, and 16 functions.'
}
$typeGuard = $topLevelIfStatements[0]
if ($typeGuard.Clauses.Count -ne 1 -or $null -ne $typeGuard.ElseClause -or
    $typeGuard.Clauses[0].Item1.Extent.Text -cne
        '$null -ne (''TL1C1bRealBuildSmokeFileIdentityV1'' -as [type])' -or
    $typeGuard.Clauses[0].Item2.Statements.Count -ne 1 -or
    $typeGuard.Clauses[0].Item2.Statements[0] -isnot
        [Management.Automation.Language.ThrowStatementAst] -or
    $typeGuard.Clauses[0].Item2.Statements[0].Extent.Text -cnotmatch
        'native authority type is already loaded') {
    throw 'Verifier preloaded-native-authority contamination guard AST drifted.'
}

$allowedCommands = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $expectedFunctionNames) { [void]$allowedCommands.Add($name) }
foreach ($name in @(
    'Microsoft.PowerShell.Utility\Add-Type',
    'Microsoft.PowerShell.Utility\ConvertFrom-Json',
    'Microsoft.PowerShell.Management\Get-Item')) {
    [void]$allowedCommands.Add($name)
}
$libraryCommandAsts = @($libraryAst.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true))
$addTypeCommands = @($libraryCommandAsts | Where-Object {
    $_.GetCommandName() -ceq 'Microsoft.PowerShell.Utility\Add-Type'
})
if ($addTypeCommands.Count -ne 1 -or
    $topLevelAssignments[0].Left.Extent.Text -cne '$null' -or
    -not $topLevelAssignments[0].Extent.Text.Contains(
        $addTypeCommands[0].Extent.Text, [StringComparison]::Ordinal)) {
    throw 'Verifier Add-Type command is not one unique unconditional top-level assignment.'
}
foreach ($commandAst in $libraryCommandAsts) {
    $commandName = $commandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace([string]$commandName) -or
        $commandAst.InvocationOperator -ne
            [Management.Automation.Language.TokenKind]::Unknown -or
        -not $allowedCommands.Contains([string]$commandName)) {
        throw "Verifier command AST is not allowlisted: $($commandAst.Extent.Text)"
    }
}
if (@($libraryAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.RedirectionAst] -or
        $node -is [Management.Automation.Language.TrapStatementAst] -or
        $node -is [Management.Automation.Language.UsingStatementAst]
    }, $true)).Count -ne 0) {
    throw 'Verifier contains redirection, trap, or using AST capability.'
}
$forbiddenTypePattern = '(?i)(Diagnostics\.Process|ProcessStartInfo|Runspace|Automation\.PowerShell|ScriptBlock|ThreadJob|PSSession|Remoting|WSMan|CimSession|ManagementObject|Threading|Reflection|Runtime\.Loader|Net\.|Activator|AppDomain|Assembly|Delegate|Registry)'
foreach ($typeAst in $libraryAst.FindAll({
    param($node) $node -is [Management.Automation.Language.TypeExpressionAst]
}, $true)) {
    if ([string]$typeAst.TypeName.FullName -match $forbiddenTypePattern) {
        throw "Verifier contains forbidden capability type: $($typeAst.Extent.Text)"
    }
}
foreach ($memberAst in $libraryAst.FindAll({
    param($node) $node -is [Management.Automation.Language.MemberExpressionAst]
}, $true)) {
    if ([string]$memberAst.Member.Value -in @(
        'Invoke','BeginInvoke','EndInvoke','CreateDelegate','Load','LoadFrom',
        'Start','StartNew','GetType')) {
        throw "Verifier contains forbidden dynamic member: $($memberAst.Extent.Text)"
    }
}

$csharpLiterals = @($libraryAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $node.StringConstantType -eq
        [Management.Automation.Language.StringConstantType]::SingleQuotedHereString
}, $true))
if ($csharpLiterals.Count -ne 1) { throw 'Verifier must contain exactly one C# here-string.' }
$csharpSource = [string]$csharpLiterals[0].Value
if ($csharpSource -match '(?i)(CreateProcess[A-Za-z0-9_]*|ShellExecute[A-Za-z0-9_]*|WinExec|ProcessStartInfo|System\.Diagnostics\.Process|System\.Management\.Automation|System\.Reflection|System\.Runtime\.Loader|System\.Threading|System\.Net|System\.IO\.Pipes|\bActivator\b|\bAppDomain\b|\bAssembly\b|\bDelegate\b|\bDynamicMethod\b|\bMethodInfo\b|Type\.GetType|Environment\.(Exit|FailFast)|NativeLibrary|LibraryImport|GetDelegateForFunctionPointer|\bunsafe\b)') {
    throw 'Verifier embedded C# contains process or dynamic-loading capability.'
}
$usingNamespaces = [string[]]@([regex]::Matches(
    $csharpSource, '(?m)^using (?<namespace>[A-Za-z0-9_.]+);$') |
    ForEach-Object { $_.Groups['namespace'].Value })
[Array]::Sort($usingNamespaces, [StringComparer]::Ordinal)
$expectedNamespaces = [string[]]@(
    'Microsoft.Win32.SafeHandles','System','System.ComponentModel',
    'System.Runtime.InteropServices','System.Text')
[Array]::Sort($expectedNamespaces, [StringComparer]::Ordinal)
if (($usingNamespaces -join "`n") -cne ($expectedNamespaces -join "`n")) {
    throw 'Verifier embedded C# using namespace set is not exact.'
}
$dllImports = @([regex]::Matches($csharpSource,
    '(?s)\[DllImport\("(?<library>[^"]+)".*?\)\]\s*private static extern\s+[A-Za-z0-9_\.<>]+\s+(?<name>[A-Za-z0-9_]+)\s*\('))
$actualDllImports = [string[]]@($dllImports | ForEach-Object {
    $_.Groups['library'].Value + ':' + $_.Groups['name'].Value
})
[Array]::Sort($actualDllImports, [StringComparer]::Ordinal)
$expectedDllImports = [string[]]@(
    'kernel32.dll:CreateFileW','kernel32.dll:GetFileInformationByHandle',
    'kernel32.dll:GetFinalPathNameByHandleW')
[Array]::Sort($expectedDllImports, [StringComparer]::Ordinal)
if (($actualDllImports -join "`n") -cne ($expectedDllImports -join "`n") -or
    ([regex]::Matches($csharpSource, '\bDllImport\s*\(')).Count -ne 3) {
    throw 'Verifier embedded C# DllImport surface is not exact.'
}

$publicFileFunctions = @($topLevelFunctions | Where-Object {
    $_.Name -ceq 'Assert-TL1C1bRealBuildSmokeSummaryFile'
})
if ($publicFileFunctions.Count -ne 1) { throw 'Public file verifier AST is not unique.' }
$publicFileBody = $publicFileFunctions[0].Body
$publicFileStatements = @($publicFileBody.EndBlock.Statements)
$publicFileReturns = @($publicFileBody.FindAll({
    param($node) $node -is [Management.Automation.Language.ReturnStatementAst]
}, $true))
if ($publicFileReturns.Count -ne 1 -or
    $publicFileStatements[-1] -isnot
        [Management.Automation.Language.ReturnStatementAst] -or
    $publicFileStatements[-1].Extent.Text -cne 'return $result') {
    throw 'Public file verifier success binding is not emitted once after cleanup.'
}
$publicFileCommands = @($publicFileBody.FindAll({
    param($node) $node -is [Management.Automation.Language.CommandAst]
}, $true))
foreach ($expectedCall in @(
    @{Name='Get-TL1C1bRealBuildSmokeHeldFileIdentity';Count=3},
    @{Name='Assert-TL1C1bRealBuildSmokePathMatchesHeldFile';Count=2},
    @{Name='ConvertFrom-TL1C1bRealBuildSmokeSummaryJson';Count=1},
    @{Name='Assert-TL1C1bRealBuildSmokeSummaryValue';Count=1}
)) {
    if (@($publicFileCommands | Where-Object {
            $_.GetCommandName() -ceq $expectedCall.Name
        }).Count -ne $expectedCall.Count) {
        throw "Public file verifier call topology drifted: $($expectedCall.Name)"
    }
}
$noFollowLeafCalls = @($publicFileBody.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    [string]$node.Member.Value -ceq 'OpenFileReadNoFollowDenyWriteDelete'
}, $true))
if ($noFollowLeafCalls.Count -ne 1 -or
    $noFollowLeafCalls[0].Parent.Parent -isnot
        [Management.Automation.Language.AssignmentStatementAst] -or
    $noFollowLeafCalls[0].Parent.Parent.Left.Extent.Text -cne '$fileHandle') {
    throw 'Public file verifier no-follow leaf open is not one live fileHandle assignment.'
}
$fileStreamConstructors = @($publicFileBody.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '[IO.FileStream]' -and
    [string]$node.Member.Value -ceq 'new'
}, $true))
if ($fileStreamConstructors.Count -ne 1 -or
    $fileStreamConstructors[0].Parent.Parent -isnot
        [Management.Automation.Language.AssignmentStatementAst] -or
    $fileStreamConstructors[0].Parent.Parent.Left.Extent.Text -cne '$stream' -or
    $fileStreamConstructors[0].Extent.Text -cnotmatch '\$fileHandle') {
    throw 'Public file verifier stream is not one live FileStream(fileHandle) assignment.'
}
if (@($publicFileBody.FindAll({
        param($node)
        $node -is [Management.Automation.Language.TypeExpressionAst] -and
        [string]$node.TypeName.FullName -cmatch 'StreamReader'
    }, $true)).Count -ne 0) {
    throw 'Public file verifier contains a path-capable StreamReader.'
}
$pathRereads = @($publicFileBody.FindAll({
    param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Get-Content','Import-Clixml')) -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        [string]$node.Member.Value -in @('ReadAllBytes','ReadAllText','Open') -and
        $node.Expression.Extent.Text -cmatch '^\[IO\.File\]$')
}, $true))
if ($pathRereads.Count -ne 0) { throw 'Public file verifier contains a path content re-read API.' }
$streamReads = @($publicFileBody.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Expression.Extent.Text -ceq '$stream' -and
    [string]$node.Member.Value -ceq 'Read'
}, $true))
$byteConsumers = @($publicFileBody.FindAll({
    param($node)
    $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
    [string]$node.Member.Value -in @('HashData','GetString') -and
    $node.Extent.Text -cmatch '\$bytes'
}, $true))
if ($streamReads.Count -ne 1 -or $byteConsumers.Count -ne 2) {
    throw 'Public file verifier held-stream byte flow topology drifted.'
}
$staticProcessApiReferenceCount = 0L

$preexistingInternalCommands = [Collections.Generic.List[string]]::new()
foreach ($name in $expectedFunctionNames) {
    foreach ($command in @(Get-Command -Name $name -All -ErrorAction SilentlyContinue)) {
        $preexistingInternalCommands.Add(
            "${name}:$($command.CommandType):$($command.Source)")
    }
}
if ($preexistingInternalCommands.Count -ne 0) {
    throw "Verifier internal command names are already occupied: $($preexistingInternalCommands -join ', ')"
}

$loadOutput = @(. $LibraryPath)
$libraryAuthorityStream.Position = 0
$libraryAfterLoadBytes = [byte[]]::new([int]$libraryAuthorityLength)
$libraryOffset = 0
while ($libraryOffset -lt $libraryAfterLoadBytes.Length) {
    $libraryRead = $libraryAuthorityStream.Read(
        $libraryAfterLoadBytes, $libraryOffset,
        $libraryAfterLoadBytes.Length - $libraryOffset)
    if ($libraryRead -le 0) { throw 'Verifier library held re-read ended early.' }
    $libraryOffset += $libraryRead
}
$libraryAfterLoadItem = Microsoft.PowerShell.Management\Get-Item `
    -LiteralPath $LibraryPath -Force -ErrorAction Stop
$libraryAfterLoadSha256 = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        $libraryAfterLoadBytes)).ToLowerInvariant()
try {
    if ($libraryAuthorityStream.ReadByte() -ne -1 -or
        $libraryAuthorityStream.Length -ne $libraryAuthorityLength -or
        $libraryAfterLoadSha256 -cne $libraryAuthoritySha256 -or
        $libraryAfterLoadItem.LastWriteTimeUtc -ne $libraryAuthorityLastWriteUtc -or
        [IO.Path]::GetFullPath($libraryAfterLoadItem.FullName) -cne
            [IO.Path]::GetFullPath($libraryItem.FullName)) {
        throw 'Verifier library authority changed between scan and load.'
    }
}
finally {
    $libraryAuthorityStream.Dispose()
    [Array]::Clear($libraryAuthorityBytes, 0, $libraryAuthorityBytes.Length)
    [Array]::Clear($libraryAfterLoadBytes, 0, $libraryAfterLoadBytes.Length)
}
$injectedFunctions = @{}
foreach ($name in $expectedFunctionNames) {
    $commands = @(Get-Command -Name $name -All -ErrorAction SilentlyContinue)
    if ($commands.Count -eq 1 -and
        $commands[0] -is [Management.Automation.FunctionInfo]) {
        $injectedFunctions[$name] = $commands[0]
    }
}
$script:CapturedConvert = $injectedFunctions['ConvertFrom-TL1C1bRealBuildSmokeSummaryJson']
$script:CapturedValueVerifier = $injectedFunctions['Assert-TL1C1bRealBuildSmokeSummaryValue']
$script:CapturedFileVerifier = $injectedFunctions['Assert-TL1C1bRealBuildSmokeSummaryFile']

$Raw = [IO.File]::ReadAllText($FixturePath, [Text.UTF8Encoding]::new($false, $true))
$TempRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) (
    'tl1-c1b-real-build-verifier-' + [guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($TempRoot)

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:MutationAssertionCount = 0
$script:ProcessApiReferenceCount = 0
$script:PathCapabilitySkipCount = 0
$script:CapturedPublicFileInvocationCount = 0
$script:CapturedPublicFileRejectionCount = 0
$script:DirectValueRejectionCount = 0
$script:FailureMessages = [Collections.Generic.List[string]]::new()
$script:SkipMessages = [Collections.Generic.List[string]]::new()
$script:CurrentCaseSkipped = $false

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-ThrowsLike {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    if ($null -eq $failure) { throw $Message }
    if ($failure.Exception.ToString() -cnotmatch $Pattern) {
        throw "$Message; actual=$($failure.Exception.Message)"
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentCaseSkipped = $false
    try {
        & $Body
        if ($script:CurrentCaseSkipped) { $script:Skipped++ }
        else { $script:Passed++ }
    }
    catch {
        $script:Failed++
        $script:FailureMessages.Add("$Name :: $($_.Exception.Message)")
    }
}

function Skip-CurrentCase {
    param([string]$Reason)
    $script:CurrentCaseSkipped = $true
    $script:SkipMessages.Add($Reason)
}

function Test-IsOptionalLinkCapabilityUnavailable {
    param([Exception]$Exception)
    $cursor = $Exception
    while ($null -ne $cursor) {
        if ($cursor -is [UnauthorizedAccessException] -or
            $cursor -is [PlatformNotSupportedException] -or
            $cursor -is [NotSupportedException] -or
            $cursor.Message -match 'privilege|not supported|所需的特权|不支持') {
            return $true
        }
        $cursor = $cursor.InnerException
    }
    return $false
}

function Get-FileVerifierParameters {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedParentDirectory
    )
    return @{
        Path = $Path
        ExpectedParentDirectory = $ExpectedParentDirectory
        ExpectedCommitSha = $ExpectedCommitSha
        ExpectedHelperSha256 = $ExpectedHelperSha256
        HelperProcessStartedNotBeforeUtc = $HelperProcessStartedNotBeforeUtc
        HelperProcessExitedNotAfterUtc = $HelperProcessExitedNotAfterUtc
        MaximumObserverTailSeconds = $MaximumObserverTailSeconds
    }
}

function Get-ValueVerifierParameters {
    return @{
        ExpectedCommitSha = $ExpectedCommitSha
        ExpectedHelperSha256 = $ExpectedHelperSha256
        HelperProcessStartedNotBeforeUtc = $HelperProcessStartedNotBeforeUtc
        HelperProcessExitedNotAfterUtc = $HelperProcessExitedNotAfterUtc
        MaximumObserverTailSeconds = $MaximumObserverTailSeconds
    }
}

function Copy-ValidSummary {
    return & $script:CapturedConvert -Raw $Raw
}

function Invoke-FileVerifier {
    param(
        [string]$Path,
        [string]$ExpectedParentDirectory,
        [hashtable]$Overrides
    )
    $parameters = Get-FileVerifierParameters -Path $Path `
        -ExpectedParentDirectory $ExpectedParentDirectory
    if ($null -ne $Overrides) {
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
    }
    $script:CapturedPublicFileInvocationCount++
    return & $script:CapturedFileVerifier @parameters
}

function Invoke-ValueVerifier {
    param([object]$Value, [hashtable]$Overrides)
    $parameters = Get-ValueVerifierParameters
    if ($null -ne $Overrides) {
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
    }
    return & $script:CapturedValueVerifier -Value $Value @parameters
}

function Assert-FileRejected {
    param(
        [string]$Path,
        [string]$ExpectedParentDirectory,
        [string]$Pattern,
        [string]$Message,
        [hashtable]$Overrides
    )
    $script:MutationAssertionCount++
    $script:CapturedPublicFileRejectionCount++
    Assert-ThrowsLike {
        [void](Invoke-FileVerifier -Path $Path `
            -ExpectedParentDirectory $ExpectedParentDirectory `
            -Overrides $Overrides)
    } $Pattern $Message
}

function Assert-FixtureFileBindingRejected {
    param([hashtable]$Overrides, [string]$Pattern, [string]$Message)
    $casePath = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::Copy($FixturePath, $casePath)
        Assert-FileRejected -Path $casePath -ExpectedParentDirectory $TempRoot `
            -Pattern $Pattern -Message $Message -Overrides $Overrides
    }
    finally { if ([IO.File]::Exists($casePath)) { [IO.File]::Delete($casePath) } }
}

function Assert-RawRejected {
    param([string]$CaseRaw, [string]$Pattern, [string]$Message)
    $casePath = Join-Path $TempRoot ([guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($casePath, $CaseRaw, [Text.UTF8Encoding]::new($false))
        Assert-FileRejected -Path $casePath -ExpectedParentDirectory $TempRoot `
            -Pattern $Pattern -Message $Message
    }
    finally { if ([IO.File]::Exists($casePath)) { [IO.File]::Delete($casePath) } }
}

function Assert-ValueRejected {
    param([object]$Value, [string]$Pattern, [string]$Message)
    $caseRaw = $Value | ConvertTo-Json -Depth 100 -Compress
    Assert-RawRejected -CaseRaw $caseRaw -Pattern $Pattern -Message $Message
}

function Assert-ParsedValueRejected {
    param(
        [object]$Value,
        [string]$Pattern,
        [string]$Message,
        [hashtable]$Overrides
    )
    $script:MutationAssertionCount++
    $script:DirectValueRejectionCount++
    Assert-ThrowsLike {
        [void](Invoke-ValueVerifier -Value $Value -Overrides $Overrides)
    } $Pattern $Message
}

function Set-SinglePropertyMutation {
    param([object]$Value, [string]$Name, [object]$NewValue)
    $Value.PSObject.Properties[$Name].Value = $NewValue
    return $Value
}

Test-Case 'tracked library dot-source is silent and all functions have one authority' {
    Assert-True ($loadOutput.Count -eq 0) 'dot-source emitted success-stream output'
    Assert-True ($expectedFunctionNames.Count -eq 16) 'tracked function count drifted'
    Assert-True ($injectedFunctions.Count -eq $expectedFunctionNames.Count) `
        'not every tracked verifier function was injected exactly once'
    foreach ($name in $expectedFunctionNames) {
        $command = $injectedFunctions[$name]
        Assert-True ($null -ne $command) "missing captured function: $name"
        $actualFile = [IO.Path]::GetFullPath([string]$command.ScriptBlock.File)
        Assert-True ([StringComparer]::OrdinalIgnoreCase.Equals($actualFile, $LibraryPath)) `
            "function source drifted: $name"
    }
    foreach ($captured in @($script:CapturedConvert,$script:CapturedValueVerifier,$script:CapturedFileVerifier)) {
        Assert-True ($captured -is [Management.Automation.FunctionInfo]) `
            'public verifier binding is not a captured FunctionInfo'
    }

    $childPath = Join-Path $TempRoot ('preloaded-native-' +
        [guid]::NewGuid().ToString('N') + '.ps1')
    $escapedLibraryPath = $LibraryPath.Replace("'", "''")
    $childSource = @'
$ErrorActionPreference = 'Stop'
$null = Add-Type -TypeDefinition 'public static class TL1C1bRealBuildSmokeFileIdentityV1 {}'
try {
    . '__LIBRARY_PATH__'
    exit 91
}
catch {
    if ($_.Exception.Message -cnotmatch 'native authority type is already loaded') {
        exit 92
    }
    exit 0
}
'@.Replace('__LIBRARY_PATH__', $escapedLibraryPath)
    $process = $null
    try {
        [IO.File]::WriteAllText(
            $childPath, $childSource, [Text.UTF8Encoding]::new($false))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [Environment]::ProcessPath
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-File')
        $start.ArgumentList.Add($childPath)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        Assert-True ($process.Start()) 'preloaded-native child pwsh did not start'
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch { }
            throw 'preloaded-native child pwsh timed out'
        }
        $childStdout = $process.StandardOutput.ReadToEnd()
        $childStderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.ExitCode -eq 0) `
            "preloaded native authority was not rejected (exit=$($process.ExitCode))"
        Assert-True ($childStdout -ceq '' -and $childStderr -ceq '') `
            'preloaded-native child pwsh emitted output'
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        if ([IO.File]::Exists($childPath)) { [IO.File]::Delete($childPath) }
    }

    $childPath = Join-Path $TempRoot ('shadowed-where-' +
        [guid]::NewGuid().ToString('N') + '.ps1')
    $escapedFixturePath = $FixturePath.Replace("'", "''")
    $escapedFixtureParent = $FixtureParent.Replace("'", "''")
    $childSource = @'
$ErrorActionPreference = 'Stop'
function global:Add-Type { throw 'ambient Add-Type shadow was invoked' }
function global:ConvertFrom-Json { throw 'ambient ConvertFrom-Json shadow was invoked' }
function global:Get-Item { throw 'ambient Get-Item shadow was invoked' }
function global:Where-Object { throw 'ambient Where-Object shadow was invoked' }
$loadOutput = @(. '__LIBRARY_PATH__')
if ($loadOutput.Count -ne 0) { exit 101 }
$verifier = Get-Command -Name 'Assert-TL1C1bRealBuildSmokeSummaryFile' -CommandType Function
$parameters = @{
    Path = '__FIXTURE_PATH__'
    ExpectedParentDirectory = '__FIXTURE_PARENT__'
    ExpectedCommitSha = '__COMMIT_SHA__'
    ExpectedHelperSha256 = '__HELPER_SHA__'
    HelperProcessStartedNotBeforeUtc = [DateTimeOffset]::Parse('2026-08-29T10:54:52.0000000Z')
    HelperProcessExitedNotAfterUtc = [DateTimeOffset]::Parse('2026-08-29T11:22:56.0000000Z')
    MaximumObserverTailSeconds = 5.0
}
$output = @(& $verifier @parameters)
if ($output.Count -ne 1 -or $output[0].ByteLength -ne 2998 -or
    $output[0].Sha256 -cne 'sha256:ec4d8ed153e9ca95448084099122e3eba227dcf6e74d70a145e31d6d3f1b0715') {
    exit 102
}
exit 0
'@.Replace('__LIBRARY_PATH__', $escapedLibraryPath).
    Replace('__FIXTURE_PATH__', $escapedFixturePath).
    Replace('__FIXTURE_PARENT__', $escapedFixtureParent).
    Replace('__COMMIT_SHA__', $ExpectedCommitSha).
    Replace('__HELPER_SHA__', $ExpectedHelperSha256)
    $process = $null
    try {
        [IO.File]::WriteAllText(
            $childPath, $childSource, [Text.UTF8Encoding]::new($false))
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = [Environment]::ProcessPath
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.ArgumentList.Add('-NoProfile')
        $start.ArgumentList.Add('-File')
        $start.ArgumentList.Add($childPath)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        Assert-True ($process.Start()) 'shadowed-builtin child pwsh did not start'
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill($true) } catch { }
            throw 'shadowed-builtin child pwsh timed out'
        }
        $childStdout = $process.StandardOutput.ReadToEnd()
        $childStderr = $process.StandardError.ReadToEnd()
        Assert-True ($process.ExitCode -eq 0) `
            "ambient builtin affected verifier (exit=$($process.ExitCode))"
        Assert-True ($childStdout -ceq '' -and $childStderr -ceq '') `
            'shadowed-builtin child pwsh emitted output'
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        if ([IO.File]::Exists($childPath)) { [IO.File]::Delete($childPath) }
    }
}

Test-Case 'pre-load AST CSharp and public file topology gates were exact' {
    $script:ProcessApiReferenceCount = $staticProcessApiReferenceCount
    Assert-True ($script:ProcessApiReferenceCount -eq 0) `
        'pre-load verifier capability review was not clean'
    Assert-True ($librarySource -cmatch 'const uint FILE_SHARE_READ = 0x00000001;' -and
        $librarySource -cmatch 'FILE_FLAG_OPEN_REPARSE_POINT') `
        'pre-load native sharing or no-follow proof drifted'
    Assert-True (@($libraryCommandAsts | Where-Object {
        $_.GetCommandName() -ceq 'Where-Object'
    }).Count -eq 0) 'tracked verifier still depends on shadowable Where-Object'
}

Test-Case 'fixture is exact no-BOM no-newline historical evidence' {
    $bytes = [IO.File]::ReadAllBytes($FixturePath)
    try {
        $sha = 'sha256:' + [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Assert-True ([long]$bytes.Length -eq $FixtureExpectedByteLength) `
            'fixture byte length drifted'
        Assert-True ($sha -ceq $FixtureExpectedSha256) 'fixture SHA-256 drifted'
        Assert-True ($bytes[-1] -ne 0x0A -and $bytes[-1] -ne 0x0D) `
            'fixture has a trailing newline'
        Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
            $bytes[2] -eq 0xBF)) 'fixture has a UTF-8 BOM'
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

Test-Case 'default parser promotion is reproduced while production preserves strings' {
    $defaultValue = $Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    $preservedValue = & $script:CapturedConvert -Raw $Raw
    foreach ($name in @('started_at_utc','completed_at_utc','process_start_observation_ended_at_utc')) {
        Assert-True ($defaultValue.PSObject.Properties[$name].Value -is [DateTime]) `
            "default parser did not promote: $name"
        Assert-True ($preservedValue.PSObject.Properties[$name].Value -is [string]) `
            "production parser did not preserve: $name"
    }
}

Test-Case 'captured file verifier returns one exact strongly typed binding object' {
    $output = @(Invoke-FileVerifier -Path $FixturePath `
        -ExpectedParentDirectory $FixtureParent -Overrides @{})
    Assert-True ($output.Count -eq 1) 'file verifier emitted other pipeline objects'
    $binding = $output[0]
    Assert-True ($binding -is [pscustomobject]) 'binding is not a PSCustomObject'
    $actualKeys = [string[]]@($binding.PSObject.Properties.Name)
    Assert-True (($actualKeys -join ',') -ceq 'ByteLength,Sha256') `
        'binding keys or order drifted'
    Assert-True ($binding.ByteLength -is [long]) 'ByteLength is not Int64'
    Assert-True ($binding.Sha256 -is [string]) 'Sha256 is not string'
    Assert-True ($binding.ByteLength -eq $FixtureExpectedByteLength) `
        'binding byte length drifted'
    Assert-True ($binding.Sha256 -ceq $FixtureExpectedSha256) `
        'binding hash drifted'
}

Test-Case 'each timestamp rejects DateTime and DateTimeOffset object promotion' {
    foreach ($name in @('started_at_utc','completed_at_utc','process_start_observation_ended_at_utc')) {
        foreach ($typed in @(
            [DateTime]::Parse('2026-08-29T10:54:52Z').ToUniversalTime(),
            [DateTimeOffset]::Parse('2026-08-29T10:54:52Z'))) {
            $value = Copy-ValidSummary
            $value.PSObject.Properties[$name].Value = $typed
            Assert-ParsedValueRejected -Value $value `
                -Pattern "not a nonempty string: $name" `
                -Message "accepted typed timestamp: $name / $($typed.GetType().Name)" `
                -Overrides @{}
        }
    }
    foreach ($name in @('started_at_utc','completed_at_utc','process_start_observation_ended_at_utc')) {
        foreach ($entry in @(
            @{Label='number';Value=1L},@{Label='boolean';Value=$true},
            @{Label='null';Value=$null},
            @{Label='object';Value=[pscustomobject]@{value='2026-08-29T10:54:52.6366290Z'}},
            @{Label='array';Value=[object[]]@('2026-08-29T10:54:52.6366290Z')},
            @{Label='whitespace';Value='   '}
        )) {
            $value = Copy-ValidSummary
            $value.PSObject.Properties[$name].Value = $entry.Value
            Assert-ValueRejected -Value $value -Pattern "not a nonempty string: $name" `
                -Message "accepted $($entry.Label) timestamp: $name"
        }
    }
}

Test-Case 'timestamp lexical form ordering envelope and observer tail fail closed' {
    foreach ($entry in @(
        @{ Name='started_at_utc'; Value='2026-08-29T10:54:52.636629Z'; Pattern='timestamp is not exact UTC' },
        @{ Name='completed_at_utc'; Value='2026-08-29T11:22:55.1546671'; Pattern='timestamp is not exact UTC' },
        @{ Name='process_start_observation_ended_at_utc'; Value='2026-08-29T11:22:55.1541442+00:00'; Pattern='timestamp is not exact UTC' },
        @{ Name='started_at_utc'; Value='２０２６-08-29T10:54:52.6366290Z'; Pattern='timestamp is not exact UTC' },
        @{ Name='started_at_utc'; Value='2026-02-30T10:54:52.6366290Z'; Pattern='invalid UTC timestamp' },
        @{ Name='completed_at_utc'; Value='2026-08-29T10:54:51.0000000Z'; Pattern='timestamp ordering is invalid' },
        @{ Name='process_start_observation_ended_at_utc'; Value='2026-08-29T10:54:51.0000000Z'; Pattern='timestamp ordering is invalid' },
        @{ Name='process_start_observation_ended_at_utc'; Value='2026-08-29T10:54:52.6366290Z'; Pattern='timestamp ordering is invalid' },
        @{ Name='process_start_observation_ended_at_utc'; Value='2026-08-29T11:22:55.2000000Z'; Pattern='timestamp ordering is invalid' },
        @{ Name='process_start_observation_ended_at_utc'; Value='2026-08-29T10:54:53.6366290Z'; Pattern='observer ended too early' }
    )) {
        $value = Copy-ValidSummary
        $value.PSObject.Properties[$entry.Name].Value = $entry.Value
        Assert-ValueRejected -Value $value -Pattern $entry.Pattern `
            -Message "accepted timestamp mutation: $($entry.Name)=$($entry.Value)"
    }
    Assert-FixtureFileBindingRejected -Pattern 'outside the launcher process envelope' `
        -Message 'file wrapper accepted stale helper summary' -Overrides @{
            HelperProcessStartedNotBeforeUtc = [DateTimeOffset]::Parse('2026-08-29T10:54:53Z')
        }
    Assert-FixtureFileBindingRejected -Pattern 'outside the launcher process envelope' `
        -Message 'file wrapper accepted future helper summary' -Overrides @{
            HelperProcessExitedNotAfterUtc = [DateTimeOffset]::Parse('2026-08-29T11:22:54Z')
        }
    Assert-FixtureFileBindingRejected -Pattern 'execution envelope is invalid' `
        -Message 'file wrapper accepted reversed launcher envelope' -Overrides @{
            HelperProcessStartedNotBeforeUtc = [DateTimeOffset]::Parse('2026-08-29T12:00:00Z')
        }
    Assert-FixtureFileBindingRejected -Pattern 'Maximum observer tail' `
        -Message 'file wrapper accepted an observer tail above the closed maximum' `
        -Overrides @{ MaximumObserverTailSeconds = 5.1 }
    foreach ($invalidMaximum in @(-0.1,[double]::NaN,[double]::PositiveInfinity)) {
        Assert-FixtureFileBindingRejected -Pattern 'Maximum observer tail' `
            -Message "file wrapper accepted invalid observer tail maximum: $invalidMaximum" `
            -Overrides @{ MaximumObserverTailSeconds = $invalidMaximum }
    }
    Assert-FixtureFileBindingRejected -Pattern 'observer ended too early' `
        -Message 'file wrapper accepted a nonzero tail under a zero-second maximum' `
        -Overrides @{ MaximumObserverTailSeconds = 0.0 }
}

Test-Case 'closed JSON rejects collisions duplicates and every noncanonical number form' {
    $missing = Copy-ValidSummary
    [void]$missing.PSObject.Properties.Remove('status')
    Assert-ValueRejected $missing 'property set is not exact' 'accepted missing property'
    $extra = Copy-ValidSummary
    $extra | Add-Member -NotePropertyName extra -NotePropertyValue 0L
    Assert-ValueRejected $extra 'property set is not exact' 'accepted extra property'
    foreach ($entry in @(
        @{ Raw=$Raw.Replace('"status":"passed"','"status":"passed","status":"passed"'); Pattern='duplicate JSON properties'; Label='same duplicate' },
        @{ Raw=$Raw.Replace('"status":"passed"','"status":"passed","status":"failed"'); Pattern='duplicate JSON properties'; Label='different-value duplicate' },
        @{ Raw=$Raw.Replace('"status":"passed"','"status":"passed","Status":"passed"'); Pattern='different casing|property set is not exact'; Label='case collision' },
        @{ Raw=$Raw.Replace('"status":"passed"','"Status":"passed"'); Pattern='property set is not exact'; Label='case-only property replacement' },
        @{ Raw=$Raw.Replace('"status":"passed"','"status":"passed","sta\u0074us":"passed"'); Pattern='duplicate JSON properties'; Label='escaped duplicate' },
        @{ Raw=$Raw.Replace('"failure_reasons":[]','"failure_reasons":[{"nested":0,"nested":1}]'); Pattern='duplicate JSON properties'; Label='nested duplicate' },
        @{ Raw=$Raw.Replace('"bootstrap_git_execution_count":2','"bootstrap_git_execution_count":-0'); Pattern='non-Int64 JSON number'; Label='negative zero' },
        @{ Raw=$Raw.Replace('"bootstrap_git_execution_count":2','"bootstrap_git_execution_count":2.0'); Pattern='non-Int64 JSON number'; Label='decimal' },
        @{ Raw=$Raw.Replace('"bootstrap_git_execution_count":2','"bootstrap_git_execution_count":2e0'); Pattern='non-Int64 JSON number'; Label='exponent' },
        @{ Raw=$Raw.Replace('"bootstrap_git_execution_count":2','"bootstrap_git_execution_count":9223372036854775808'); Pattern='non-Int64 JSON number'; Label='Int64 overflow' },
        @{ Raw=$Raw.Replace('"bootstrap_git_execution_count":2','"bootstrap_git_execution_count":-9223372036854775809'); Pattern='non-Int64 JSON number'; Label='Int64 underflow' }
    )) {
        Assert-RawRejected $entry.Raw $entry.Pattern "accepted $($entry.Label)"
    }
}

Test-Case 'every declared lexical property type is strict' {
    $integerProperties = @(
        'bootstrap_git_execution_count','repository_input_count','repository_input_directory_root_count',
        'real_jdk_gradlemain_execution_count','real_apksigner_execution_count',
        'held_aapt2_verification_execution_count','held_git_execution_count','unexpected_direct_process_count',
        'direct_adb_attempt_count','observed_adb_process_start_count','real_adb_call_count',
        'observed_direct_child_java_process_start_count','observed_other_java_process_start_count',
        'pre_adb_process_count','post_adb_process_count','pre_default_adb_listener_count',
        'post_default_adb_listener_count','device_enumeration_call_count','install_attempt_count',
        't0_call_count','capture_call_count','forbidden_match_count','manifest_mutating_capability_count',
        'manifest_extra_component_count','c1b_java_residual_count','failure_count')
    foreach ($name in $integerProperties) {
        $value = Set-SinglePropertyMutation (Copy-ValidSummary) $name '0'
        Assert-ValueRejected $value "not an Int64: $name" "accepted string integer: $name"
    }
    $booleanProperties = @(
        'bootstrap_git_provenance_verified','pre_git_provenance_verified','post_git_provenance_verified',
        'wrapper_not_executed','dependency_allowlist_verified','packaged_axml_verified',
        'post_gradle_lock_sealed','workspace_residual','recovery_journal_residual',
        'module_build_residual','module_gradle_residual','local_properties_residual')
    foreach ($name in $booleanProperties) {
        $value = Set-SinglePropertyMutation (Copy-ValidSummary) $name 'true'
        Assert-ValueRejected $value "not boolean: $name" "accepted string boolean: $name"
    }
    $stringProperties = @(
        'schema','started_at_utc','completed_at_utc','status','expected_commit_sha','helper_sha256',
        'build_environment_schema','repository_input_catalog_sha256','process_start_observer_scope',
        'process_start_observer_limitation','process_start_observation_ended_at_utc',
        'default_adb_listener_observation','jdk_version','jdk_catalog_sha256','gradle_version',
        'gradle_catalog_sha256','gradle_entrypoint','apksigner_jar_sha256','artifact_proof_sha256',
        'debug_apk_sha256','release_apk_sha256','signer_certificate_sha256','artifact_guards_cleanup',
        'build_environment_cleanup','repository_library_guards_cleanup')
    foreach ($name in $stringProperties) {
        $value = Set-SinglePropertyMutation (Copy-ValidSummary) $name 1L
        Assert-ValueRejected $value "not a nonempty string: $name" "accepted integer string property: $name"
    }
    $failureType = Set-SinglePropertyMutation (Copy-ValidSummary) 'failure_reasons' 'reason'
    Assert-ValueRejected $failureType 'failure_reasons is not an array' `
        'accepted scalar failure_reasons'
}

Test-Case 'every production semantic check conjunct rejects one-field drift' {
    $validWrongHash = 'sha256:' + ('a' * 64)
    $mutations = @(
        @{Name='schema';Value='wrong';Pattern='schema'},@{Name='status';Value='failed';Pattern='status'},
        @{Name='expected_commit_sha';Value=('a'*40);Pattern='commit'},@{Name='helper_sha256';Value=$validWrongHash;Pattern='helper'},
        @{Name='bootstrap_git_execution_count';Value=1L;Pattern='bootstrap_git'},@{Name='bootstrap_git_provenance_verified';Value=$false;Pattern='bootstrap_git'},
        @{Name='pre_git_provenance_verified';Value=$false;Pattern='git_provenance'},@{Name='post_git_provenance_verified';Value=$false;Pattern='git_provenance'},
        @{Name='build_environment_schema';Value='wrong';Pattern='build_schema'},@{Name='repository_input_count';Value=41L;Pattern='inputs'},
        @{Name='repository_input_directory_root_count';Value=2L;Pattern='roots'},@{Name='repository_input_catalog_sha256';Value='sha256:bad';Pattern='roots'},
        @{Name='real_jdk_gradlemain_execution_count';Value=0L;Pattern='gradle'},@{Name='real_apksigner_execution_count';Value=0L;Pattern='signer'},
        @{Name='held_aapt2_verification_execution_count';Value=3L;Pattern='aapt2'},@{Name='held_git_execution_count';Value=31L;Pattern='git'},
        @{Name='unexpected_direct_process_count';Value=1L;Pattern='unexpected_process'},@{Name='real_adb_call_count';Value=1L;Pattern='adb'},
        @{Name='direct_adb_attempt_count';Value=1L;Pattern='adb'},@{Name='observed_adb_process_start_count';Value=1L;Pattern='adb'},
        @{Name='pre_adb_process_count';Value=1L;Pattern='adb_snapshots'},@{Name='post_adb_process_count';Value=1L;Pattern='adb_snapshots'},
        @{Name='pre_default_adb_listener_count';Value=1L;Pattern='adb_snapshots'},@{Name='post_default_adb_listener_count';Value=1L;Pattern='adb_snapshots'},
        @{Name='observed_direct_child_java_process_start_count';Value=1L;Pattern='java_canary'},@{Name='observed_other_java_process_start_count';Value=-1L;Pattern='java_canary'},
        @{Name='process_start_observer_scope';Value='wrong';Pattern='observer'},@{Name='process_start_observer_limitation';Value='wrong';Pattern='observer'},
        @{Name='default_adb_listener_observation';Value='wrong';Pattern='observer'},@{Name='device_enumeration_call_count';Value=1L;Pattern='no_device'},
        @{Name='install_attempt_count';Value=1L;Pattern='no_device'},@{Name='t0_call_count';Value=1L;Pattern='no_device'},
        @{Name='capture_call_count';Value=1L;Pattern='no_device'},@{Name='jdk_version';Value='21.0.4';Pattern='toolchain'},
        @{Name='jdk_catalog_sha256';Value=$validWrongHash;Pattern='toolchain'},@{Name='gradle_version';Value='8.8';Pattern='toolchain'},
        @{Name='gradle_catalog_sha256';Value=$validWrongHash;Pattern='toolchain'},@{Name='gradle_entrypoint';Value='wrong';Pattern='toolchain'},
        @{Name='wrapper_not_executed';Value=$false;Pattern='toolchain'},@{Name='apksigner_jar_sha256';Value=$validWrongHash;Pattern='toolchain'},
        @{Name='forbidden_match_count';Value=1L;Pattern='artifacts'},@{Name='manifest_mutating_capability_count';Value=1L;Pattern='artifacts'},
        @{Name='manifest_extra_component_count';Value=1L;Pattern='artifacts'},@{Name='dependency_allowlist_verified';Value=$false;Pattern='artifacts'},
        @{Name='packaged_axml_verified';Value=$false;Pattern='artifacts'},@{Name='post_gradle_lock_sealed';Value=$false;Pattern='artifacts'},
        @{Name='jdk_catalog_sha256';Value='sha256:bad';Pattern='artifacts'},@{Name='gradle_catalog_sha256';Value='sha256:bad';Pattern='artifacts'},
        @{Name='apksigner_jar_sha256';Value='sha256:bad';Pattern='artifacts'},@{Name='artifact_proof_sha256';Value='sha256:bad';Pattern='artifacts'},
        @{Name='debug_apk_sha256';Value='sha256:bad';Pattern='artifacts'},@{Name='release_apk_sha256';Value='sha256:bad';Pattern='artifacts'},
        @{Name='signer_certificate_sha256';Value='sha256:bad';Pattern='artifacts'},@{Name='artifact_guards_cleanup';Value='failed';Pattern='cleanup'},
        @{Name='build_environment_cleanup';Value='failed';Pattern='cleanup'},@{Name='repository_library_guards_cleanup';Value='failed';Pattern='cleanup'},
        @{Name='workspace_residual';Value=$true;Pattern='residue'},@{Name='recovery_journal_residual';Value=$true;Pattern='residue'},
        @{Name='module_build_residual';Value=$true;Pattern='residue'},@{Name='module_gradle_residual';Value=$true;Pattern='residue'},
        @{Name='local_properties_residual';Value=$true;Pattern='residue'},@{Name='c1b_java_residual_count';Value=1L;Pattern='residue'},
        @{Name='failure_count';Value=1L;Pattern='failures'},@{Name='failure_reasons';Value=[object[]]@('reason');Pattern='failures'}
    )
    foreach ($mutation in $mutations) {
        $value = Set-SinglePropertyMutation (Copy-ValidSummary) $mutation.Name $mutation.Value
        Assert-ValueRejected $value ("verification failed: .*" + $mutation.Pattern) `
            "accepted semantic drift: $($mutation.Name)"
    }
    foreach ($mutation in @(
        @{Name='expected_commit_sha';Pattern='verification failed: .*commit'},
        @{Name='helper_sha256';Pattern='verification failed: .*helper'},
        @{Name='repository_input_catalog_sha256';Pattern='verification failed: .*roots'},
        @{Name='jdk_catalog_sha256';Pattern='verification failed: .*toolchain, artifacts'},
        @{Name='gradle_catalog_sha256';Pattern='verification failed: .*toolchain, artifacts'},
        @{Name='apksigner_jar_sha256';Pattern='verification failed: .*toolchain, artifacts'},
        @{Name='artifact_proof_sha256';Pattern='verification failed: .*artifacts'},
        @{Name='debug_apk_sha256';Pattern='verification failed: .*artifacts'},
        @{Name='release_apk_sha256';Pattern='verification failed: .*artifacts'},
        @{Name='signer_certificate_sha256';Pattern='verification failed: .*artifacts'}
    )) {
        $value = Copy-ValidSummary
        $original = [string]$value.PSObject.Properties[$mutation.Name].Value
        $value.PSObject.Properties[$mutation.Name].Value = $original + "`n"
        Assert-ValueRejected $value $mutation.Pattern `
            "accepted valid-length hash or commit with trailing LF: $($mutation.Name)"
    }
    Assert-FixtureFileBindingRejected @{ ExpectedCommitSha = 'a' * 40 } `
        'verification failed: commit' 'file wrapper accepted wrong expected commit binding'
    Assert-FixtureFileBindingRejected @{ ExpectedHelperSha256 = 'b' * 64 } `
        'verification failed: helper' 'file wrapper accepted wrong expected helper binding'
    Assert-FixtureFileBindingRejected @{ ExpectedCommitSha = $ExpectedCommitSha + "`n" } `
        "Cannot validate argument on parameter 'ExpectedCommitSha'" `
        'public file API accepted ExpectedCommitSha with trailing LF'
    Assert-FixtureFileBindingRejected @{ ExpectedHelperSha256 = $ExpectedHelperSha256 + "`n" } `
        "Cannot validate argument on parameter 'ExpectedHelperSha256'" `
        'public file API accepted ExpectedHelperSha256 with trailing LF'
    Assert-ParsedValueRejected (Copy-ValidSummary) `
        "Cannot validate argument on parameter 'ExpectedCommitSha'" `
        'value API accepted ExpectedCommitSha with trailing LF' `
        @{ ExpectedCommitSha = $ExpectedCommitSha + "`n" }
    Assert-ParsedValueRejected (Copy-ValidSummary) `
        "Cannot validate argument on parameter 'ExpectedHelperSha256'" `
        'value API accepted ExpectedHelperSha256 with trailing LF' `
        @{ ExpectedHelperSha256 = $ExpectedHelperSha256 + "`n" }
}

Test-Case 'file path containment type size encoding and BOM boundaries fail closed' {
    $missing = Join-Path $TempRoot 'missing.json'
    Assert-FileRejected $missing $TempRoot 'Cannot find path|Could not find file' 'accepted missing file'
    Assert-FileRejected $TempRoot ([IO.Path]::GetDirectoryName($TempRoot)) `
        'not an ordinary|expected parent' 'accepted directory as file'
    Assert-FileRejected $FixturePath $TempRoot 'outside the exact expected parent' `
        'accepted wrong expected parent'
    Assert-FileRejected '.\relative.json' $TempRoot 'must be absolute' 'accepted relative path'
    Assert-FileRejected ($FixturePath + ':evidence') $FixtureParent `
        'not one ordinary leaf' 'accepted alternate data stream path'

    $casePath = Join-Path $TempRoot 'case-parent.json'
    [IO.File]::WriteAllText($casePath, $Raw, [Text.UTF8Encoding]::new($false))
    Assert-FileRejected $casePath $TempRoot.ToUpperInvariant() `
        'outside the exact expected parent' 'accepted case-variant expected parent'

    $child = Join-Path $TempRoot 'child'
    [void][IO.Directory]::CreateDirectory($child)
    $nested = Join-Path $child 'nested.json'
    [IO.File]::WriteAllText($nested, $Raw, [Text.UTF8Encoding]::new($false))
    Assert-FileRejected $nested $TempRoot 'outside the exact expected parent' `
        'accepted nested path under non-exact parent'

    foreach ($entry in @(
        @{Name='empty.json';Bytes=[byte[]]@();Pattern='byte length is outside'},
        @{Name='one-byte.json';Bytes=[byte[]]@(0x7B);Pattern='JSON|end of data'},
        @{Name='maximum.json';Bytes=[byte[]]::new(65536);Pattern='JSON|invalid start'},
        @{Name='oversize.json';Bytes=[byte[]]::new(65537);Pattern='byte length is outside'},
        @{Name='bom.json';Bytes=[byte[]](0xEF,0xBB,0xBF,0x7B,0x7D);Pattern='must not contain a UTF-8 BOM'},
        @{Name='invalid-utf8.json';Bytes=[byte[]](0xC3,0x28);Pattern='Unable to translate bytes|invalid'}
    )) {
        $path = Join-Path $TempRoot $entry.Name
        [IO.File]::WriteAllBytes($path, $entry.Bytes)
        Assert-FileRejected $path $TempRoot $entry.Pattern "accepted file boundary: $($entry.Name)"
    }
}

Test-Case 'hard-link leaf is rejected by held handle link count' {
    $target = Join-Path $TempRoot 'hardlink-target.json'
    $link = Join-Path $TempRoot 'hardlink.json'
    [IO.File]::Copy($FixturePath, $target)
    $null = New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop
    Assert-FileRejected $link $TempRoot 'hard-link count other than one' `
        'accepted hard-linked evidence file'
}

Test-Case 'junction ancestor is rejected without symlink privilege' {
    $realDirectory = Join-Path $TempRoot 'junction-real-parent'
    $junctionDirectory = Join-Path $TempRoot 'junction-linked-parent'
    [void][IO.Directory]::CreateDirectory($realDirectory)
    [IO.File]::WriteAllText((Join-Path $realDirectory 'summary.json'), $Raw,
        [Text.UTF8Encoding]::new($false))
    try {
        $null = New-Item -ItemType Junction -Path $junctionDirectory `
            -Target $realDirectory -ErrorAction Stop
        Assert-FileRejected (Join-Path $junctionDirectory 'summary.json') `
            $junctionDirectory 'directory path chain is not ordinary' `
            'accepted junction ancestor'
    }
    finally {
        if ([IO.Directory]::Exists($junctionDirectory)) {
            [IO.Directory]::Delete($junctionDirectory)
        }
    }
}

Test-Case 'symbolic-link leaf is rejected when supported' {
    $link = Join-Path $TempRoot 'symbolic-file.json'
    try { [void][IO.File]::CreateSymbolicLink($link, $FixturePath) }
    catch {
        if (-not (Test-IsOptionalLinkCapabilityUnavailable $_.Exception)) { throw }
        $script:PathCapabilitySkipCount++
        Skip-CurrentCase "symbolic-link leaf capability unavailable: $($_.Exception.Message)"
        return
    }
    Assert-FileRejected $link $TempRoot 'not an ordinary, reparse-free file' `
        'accepted symbolic-link evidence file'
}

Test-Case 'symbolic-link ancestor is rejected when supported' {
    $realDirectory = Join-Path $TempRoot 'real-parent'
    $linkedDirectory = Join-Path $TempRoot 'linked-parent'
    [void][IO.Directory]::CreateDirectory($realDirectory)
    [IO.File]::WriteAllText((Join-Path $realDirectory 'summary.json'), $Raw,
        [Text.UTF8Encoding]::new($false))
    try { [void][IO.Directory]::CreateSymbolicLink($linkedDirectory, $realDirectory) }
    catch {
        if (-not (Test-IsOptionalLinkCapabilityUnavailable $_.Exception)) { throw }
        $script:PathCapabilitySkipCount++
        Skip-CurrentCase "symbolic-link ancestor capability unavailable: $($_.Exception.Message)"
        return
    }
    Assert-FileRejected (Join-Path $linkedDirectory 'summary.json') $linkedDirectory `
        'directory path chain is not ordinary' 'accepted symbolic-link ancestor'
}

try {
    $expectedTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $TempRoot.StartsWith($expectedTempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFileName($TempRoot).StartsWith(
            'tl1-c1b-real-build-verifier-', [StringComparison]::Ordinal)) {
        throw 'Refusing to clean an unexpected verifier test directory.'
    }
}
catch {
    $script:Failed++
    $script:FailureMessages.Add("temp cleanup guard :: $($_.Exception.Message)")
}
finally {
    if ([IO.Directory]::Exists($TempRoot)) {
        try { [IO.Directory]::Delete($TempRoot, $true) }
        catch {
            $script:Failed++
            $script:FailureMessages.Add("temp cleanup :: $($_.Exception.Message)")
        }
    }
}

$summary = [ordered]@{
    schema = 'tablet-layout-c1b-real-build-smoke-verifier-offline/v2'
    passed = [long]$script:Passed
    failed = [long]$script:Failed
    skipped = [long]$script:Skipped
    mutation_assertion_count = [long]$script:MutationAssertionCount
    process_api_reference_count = [long]$script:ProcessApiReferenceCount
    path_capability_skip_count = [long]$script:PathCapabilitySkipCount
    captured_public_file_invocation_count =
        [long]$script:CapturedPublicFileInvocationCount
    captured_public_file_rejection_count =
        [long]$script:CapturedPublicFileRejectionCount
    direct_value_rejection_count = [long]$script:DirectValueRejectionCount
    pwsh_version = [string]$PSVersionTable.PSVersion.ToString()
    failure_messages = [string[]]$script:FailureMessages.ToArray()
    skip_messages = [string[]]$script:SkipMessages.ToArray()
}
[Console]::Out.WriteLine(($summary | ConvertTo-Json -Depth 5 -Compress))
if ($script:Failed -ne 0) { exit 1 }
