#Requires -Version 7.5
# 纯源代码转换；不读写文件、不运行候选、Git、构建或设备命令。
# 冻结工件只能作为输入。返回值是待审查源代码，发布仍须使用 held/no-follow renderer。

function Get-C1bCandidateSourceAst {
    param([Parameter(Mandatory)][string]$Source)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Source, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Candidate source has parser errors.' }
    return $ast
}

function Get-C1bCandidateSourceHash {
    param([Parameter(Mandatory)][string]$Source)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.UTF8Encoding]::new($false, $true).GetBytes($Source))).ToLowerInvariant()
}

function Get-C1bCandidateLiteralAssignment {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Name)
    $ast = Get-C1bCandidateSourceAst $Source
    $matches = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $_.Left.VariablePath.UserPath -ceq $Name
    })
    if ($matches.Count -ne 1) { throw "Expected one top-level assignment: $Name" }
    if ($matches[0].Right -isnot [Management.Automation.Language.CommandExpressionAst]) {
        throw "Assignment is not a direct literal expression: $Name"
    }
    return $matches[0].Right.Expression.SafeGetValue()
}

function Set-C1bCandidateLiteralAssignments {
    param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][Collections.IDictionary]$Values)
    $ast = Get-C1bCandidateSourceAst $Source
    $edits = [Collections.Generic.List[object]]::new()
    foreach ($name in $Values.Keys) {
        $matches = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -ceq $name
        })
        if ($matches.Count -ne 1) { throw "Expected one top-level assignment: $name" }
        $value = $Values[$name]
        $literal = if ($value -is [string]) {
            if ($value.Contains([char]0) -or $value.Contains("`r") -or $value.Contains("`n")) {
                throw "Assignment contains control characters: $name"
            }
            "'" + $value.Replace("'", "''") + "'"
        } elseif ($value -is [int] -or $value -is [long]) {
            $value.ToString([Globalization.CultureInfo]::InvariantCulture) + 'L'
        } else { throw "Unsupported constant type: $name" }
        $edits.Add([pscustomobject]@{ Extent=$matches[0].Right.Extent; Text=$literal })
    }
    foreach ($edit in @($edits | Sort-Object { $_.Extent.StartOffset } -Descending)) {
        $Source = $Source.Substring(0, $edit.Extent.StartOffset) + $edit.Text +
            $Source.Substring($edit.Extent.EndOffset)
    }
    [void](Get-C1bCandidateSourceAst $Source)
    return $Source
}

function Replace-C1bCandidateExactText {
    param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Old,
        [Parameter(Mandatory)][AllowEmptyString()][string]$New,
        [int]$ExpectedCount = 1)
    $count = 0
    $offset = 0
    while (($offset = $Source.IndexOf($Old, $offset, [StringComparison]::Ordinal)) -ge 0) {
        $count++
        $offset += $Old.Length
    }
    if ($count -ne $ExpectedCount) { throw "Exact source replacement cardinality: $count != $ExpectedCount" }
    return $Source.Replace($Old, $New, [StringComparison]::Ordinal)
}

function Get-C1bLauncherSourceTransformations {
    # 同一组可审查字节替换同时供内存 candidate 与 held renderer 使用。
    param([Parameter(Mandatory)][string]$Source)
    $newline = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $bootstrapOld = @'
    $childBootstrapSource = @'
#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
'@
    $bootstrapNew = $bootstrapOld.Replace('$ErrorActionPreference',
        '$ProgressPreference = ''SilentlyContinue''' + "`n" + '$ErrorActionPreference',
        [StringComparison]::Ordinal)
    $stderrOld = @'
                stderr = if ($null -eq $stderrResult) { $null } else {
                    [pscustomobject][ordered]@{
                        total_byte_length = [long]$stderrResult.TotalByteLength
                        captured_byte_length = [long]$stderrResult.CapturedBytes.Length
'@
    $stderrNew = $stderrOld + "`n" + @'
                        captured_prefix_base64 = [Convert]::ToBase64String($stderrResult.CapturedBytes)
                        captured_prefix_sha256 = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stderrResult.CapturedBytes)).ToLowerInvariant()
                        captured_prefix_byte_length = [long]$stderrResult.CapturedBytes.Length
                        capture_is_prefix = $true
                        uncaptured_byte_length = [long]$stderrResult.TotalByteLength - [long]$stderrResult.CapturedBytes.Length
'@
    foreach ($change in @(
        @{Old='7.6.4';New='7.6.5';Count=3},
        @{Old=$bootstrapOld;New=$bootstrapNew;Count=1},
        @{Old=$stderrOld;New=$stderrNew;Count=1},
        @{Old='else { $stdoutResult.CapturedBytes })';New='else { ,$stdoutResult.CapturedBytes })';Count=1},
        @{Old='else { $stderrResult.CapturedBytes })';New='else { ,$stderrResult.CapturedBytes })';Count=1}
    )) {
        [pscustomobject]@{
            Old=$change.Old.Replace("`r`n", "`n").Replace("`n", $newline)
            New=$change.New.Replace("`r`n", "`n").Replace("`n", $newline)
            Count=[int]$change.Count
        }
    }
}

function Update-C1bLauncherCandidateTemplate {
    param([Parameter(Mandatory)][string]$Source)
    foreach ($change in @(Get-C1bLauncherSourceTransformations $Source)) {
        $Source = Replace-C1bCandidateExactText $Source $change.Old $change.New $change.Count
    }
    [void](Get-C1bCandidateSourceAst $Source)
    return $Source
}

function New-C1bLauncherRendererTransformSource {
    param([Parameter(Mandatory)][string]$TemplateSource)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($change in @(Get-C1bLauncherSourceTransformations $TemplateSource)) {
        $old64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($change.Old))
        $new64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($change.New))
        $lines.Add('    $launcherTransformOld = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(''' + $old64 + '''))')
        $lines.Add('    $launcherTransformNew = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(''' + $new64 + '''))')
        $lines.Add('    Assert-Renderer (([regex]::Matches($launcherText, [regex]::Escape($launcherTransformOld))).Count -eq ' + $change.Count + ') ''Launcher source transform cardinality drifted.''')
        $lines.Add('    $launcherText = $launcherText.Replace($launcherTransformOld, $launcherTransformNew, [StringComparison]::Ordinal)')
    }
    return [string]::Join("`r`n", $lines)
}

function Get-C1bHelperLibraryPaths {
    return [ordered]@{
        c1a='scripts/lib/tablet-layout-c1a.ps1'
        validator='scripts/lib/tablet-layout-observation-c1b-v1-validator.ps1'
        c1b='scripts/lib/tablet-layout-c1b.ps1'
        artifact='scripts/lib/tablet-layout-c1b-artifact-proof.ps1'
        aapt2='scripts/lib/tablet-layout-c1b-aapt2.ps1'
        build='scripts/lib/tablet-layout-c1b-build-env.ps1'
        runner='scripts/run-tablet-layout-c1b.ps1'
    }
}

function Assert-C1bHelperLibraryHashes {
    param([Parameter(Mandatory)][Collections.IDictionary]$LibraryHashes)
    $requiredKeys=[string[]]@((Get-C1bHelperLibraryPaths).Keys)
    if($LibraryHashes.Count-ne7-or
        (([string[]]@($LibraryHashes.Keys))-join "`n")-cne($requiredKeys-join "`n")){
        throw 'Helper library hash keys/order must be exactly the seven loader inputs.'
    }
    foreach($key in $requiredKeys){
        if($LibraryHashes[$key]-isnot[string]-or
            [string]$LibraryHashes[$key]-cnotmatch'\Asha256:[0-9a-f]{64}\z'){
            throw "Helper library hash must be a lowercase SHA-256 literal: $key"
        }
    }
}

function Get-C1bHelperLibraryHashTransformation {
    param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][Collections.IDictionary]$LibraryHashes)
    Assert-C1bHelperLibraryHashes $LibraryHashes
    $ast=Get-C1bCandidateSourceAst $Source
    $assignments=@($ast.FindAll({param($node)
        $node-is[Management.Automation.Language.AssignmentStatementAst]-and
        $node.Left-is[Management.Automation.Language.VariableExpressionAst]-and
        $node.Left.VariablePath.UserPath-imatch'(^|:)expectedLibraryHashes$'
    },$true))
    if($assignments.Count-ne1-or$assignments[0].Parent-ne$ast.EndBlock-or
        $assignments[0].Left.VariablePath.UserPath-cne'expectedLibraryHashes'-or
        $assignments[0].Operator.ToString()-cne'Equals'){
        throw 'Helper requires one top-level expectedLibraryHashes literal assignment.'
    }
    $assignment=$assignments[0]
    $expression=if($assignment.Right-is[Management.Automation.Language.CommandExpressionAst]){
        $assignment.Right.Expression
    }else{$null}
    if($expression-isnot[Management.Automation.Language.ConvertExpressionAst]-or
        $expression.Type.TypeName.FullName-cne'ordered'-or
        $expression.Child-isnot[Management.Automation.Language.HashtableAst]){
        throw 'Helper expectedLibraryHashes must be an ordered literal map.'
    }
    $oldValues=[ordered]@{}
    foreach($pair in $expression.Child.KeyValuePairs){
        if($pair.Item1-isnot[Management.Automation.Language.StringConstantExpressionAst]){
            throw 'Helper library key must be a literal.'
        }
        $key=[string]$pair.Item1.Value
        if($oldValues.Contains($key)){throw 'Helper library map contains a duplicate key.'}
        $value=$pair.Item2
        if($value-isnot[Management.Automation.Language.PipelineAst]-or
            $value.PipelineElements.Count-ne1-or
            $value.PipelineElements[0]-isnot[Management.Automation.Language.CommandExpressionAst]-or
            $value.PipelineElements[0].Expression-isnot[Management.Automation.Language.StringConstantExpressionAst]){
            throw 'Helper library hash value must be a literal.'
        }
        $oldValues[$key]=$value.PipelineElements[0].Expression.Value
    }
    Assert-C1bHelperLibraryHashes $oldValues
    $newline=if($Source.Contains("`r`n")){"`r`n"}else{"`n"}
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('$expectedLibraryHashes = [ordered]@{')
    foreach($key in (Get-C1bHelperLibraryPaths).Keys){
        $lines.Add("    $key = '$($LibraryHashes[$key])'")
    }
    $lines.Add('}')
    return [pscustomobject]@{Old=$assignment.Extent.Text;New=([string]::Join($newline,$lines));Count=1}
}

function Get-C1bHelperSourceTransformations {
    param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][Collections.IDictionary]$LibraryHashes)
    $newline = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
    $wrapperOld = @'
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
'@
    $gradleOld = @'
    [void](Invoke-TL1C1aProcess -FilePath ([string]$gradleInvocation.FilePath) `
        -Arguments $gradleArguments `
        -Operation 'C1b 42-input real isolated direct GradleMain smoke' `
        -Environment $environment -ClearEnvironment -TimeoutSec 300)
'@
    foreach ($change in @(
        @{Old=$wrapperOld;New=$wrapperOld.Replace('[switch]$AllowFailure', '[switch]$AllowFailure,' + "`n" + '        [switch]$FailureDiagnostics')},
        @{Old=$gradleOld;New=$gradleOld.Replace('-TimeoutSec 300)', '-TimeoutSec 300 -FailureDiagnostics)')}
    )) {
        [pscustomobject]@{
            Old=$change.Old.Replace("`r`n","`n").Replace("`n",$newline)
            New=$change.New.Replace("`r`n","`n").Replace("`n",$newline)
            Count=1
        }
    }
    Get-C1bHelperLibraryHashTransformation $Source $LibraryHashes
}

function Update-C1bHelperCandidateTemplate {
    param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][Collections.IDictionary]$LibraryHashes)
    foreach ($change in @(Get-C1bHelperSourceTransformations $Source $LibraryHashes)) {
        $Source = Replace-C1bCandidateExactText $Source $change.Old $change.New $change.Count
    }
    [void](Get-C1bCandidateSourceAst $Source)
    return $Source
}

function New-C1bHelperRendererTransformSource {
    param([Parameter(Mandatory)][string]$TemplateSource,
        [Parameter(Mandatory)][Collections.IDictionary]$LibraryHashes)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($change in @(Get-C1bHelperSourceTransformations $TemplateSource $LibraryHashes)) {
        $old64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($change.Old))
        $new64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($change.New))
        $lines.Add('    $helperTransformOld = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(''' + $old64 + '''))')
        $lines.Add('    $helperTransformNew = [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(''' + $new64 + '''))')
        $lines.Add('    Assert-Renderer (([regex]::Matches($helperText, [regex]::Escape($helperTransformOld))).Count -eq ' + $change.Count + ') ''Helper source transform cardinality drifted.''')
        $lines.Add('    $helperText = $helperText.Replace($helperTransformOld, $helperTransformNew, [StringComparison]::Ordinal)')
    }
    return [string]::Join("`r`n", $lines)
}

function New-C1bExactPairCandidateSource {
    param(
        [Parameter(Mandatory)][string]$BaselineRendererSource,
        [Parameter(Mandatory)][string]$HelperTemplateSource,
        [Parameter(Mandatory)][string]$LauncherTemplateSource,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CommitSha,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][Collections.IDictionary]$RepositoryLibraryHashes,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$VerifierSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$UtilityAssemblySha256,
        [Parameter(Mandatory)][long]$UtilityAssemblyLength
    )
    if ($UtilityAssemblySha256 -cne '2f6201bb3caf4c08158be733e786dd85b11537694f7e6ab40356fc0727a3596f' -or
        $UtilityAssemblyLength -ne 1652504L) {
        throw 'Pinned PowerShell 7.6.5 Utility assembly binding drifted.'
    }
    if ((Get-C1bCandidateSourceHash $BaselineRendererSource) -cne
        '3086b43031b4e7fa6dc50c5227da44729d9675bf1757bf896fa25ece8203958a') {
        throw 'Frozen r12 renderer source drifted.'
    }
    foreach ($binding in @(
        @($HelperTemplateSource, 'expectedHelperTemplateSha256'),
        @($LauncherTemplateSource, 'expectedLauncherTemplateSha256'))) {
        if ((Get-C1bCandidateSourceHash $binding[0]) -cne
            (Get-C1bCandidateLiteralAssignment $BaselineRendererSource $binding[1])) {
            throw "Frozen template source drifted: $($binding[1])"
        }
    }
    # 先复算上一对冻结字节。旧 hash 只从其变量名读，避免与历史常量串值。
    $previousHelper = Replace-C1bCandidateExactText $HelperTemplateSource '__FINAL_COMMIT_SHA__' (
        Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'commitSha')
    $previousHelper = Replace-C1bCandidateExactText $previousHelper '__FINAL_COMMIT_SHORT__' (
        Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'commitShort')
    $previousLauncher = $LauncherTemplateSource
    foreach ($slot in ([ordered]@{
        '__FINAL_COMMIT_SHA__'='commitSha'; '__FINAL_COMMIT_SHORT__'='commitShort'
        '__REPO_ROOT__'='repoRoot'; '__FAILURE_SIDECAR_ABSOLUTE_PATH__'='failureSidecarPath'
        '__HELPER_ABSOLUTE_PATH__'='helperPath'; '__HELPER_SHA256__'='expectedHelperSha256'
        '__VERIFIER_SHA256__'='expectedVerifierSha256'; '__PWSH_ABSOLUTE_PATH__'='pwshPath'
        '__PWSH_SHA256__'='expectedPwshSha256'
    }).GetEnumerator()) {
        # path RHS 可为 Combine 表达式；旧 renderer 直接 path常量与组合需要安全求值，不能执行旧代码。
        $value = switch ($slot.Value) {
            'failureSidecarPath' { [IO.Path]::Combine(
                (Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'stagingRoot'),
                'launcher-015835c-r11.failure.json'); break }
            'helperPath' { [IO.Path]::Combine(
                (Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'stagingRoot'),
                'helper-015835c-r11.ps1'); break }
            default { Get-C1bCandidateLiteralAssignment $BaselineRendererSource $slot.Value }
        }
        $previousLauncher = Replace-C1bCandidateExactText $previousLauncher $slot.Key $value
    }
    if ((Get-C1bCandidateSourceHash $previousHelper) -cne
        (Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'expectedHelperSha256') -or
        (Get-C1bCandidateSourceHash $previousLauncher) -cne
        (Get-C1bCandidateLiteralAssignment $BaselineRendererSource 'expectedLauncherSha256')) {
        throw 'Previous frozen pair cannot be reproduced exactly.'
    }
    $short = $CommitSha.Substring(0, 7)
    $helperPath = [IO.Path]::Combine($StagingRoot, "helper-$short-r11.ps1")
    $launcherPath = [IO.Path]::Combine($StagingRoot, "launcher-$short-r11.ps1")
    $failurePath = [IO.Path]::Combine($StagingRoot, "launcher-$short-r11.failure.json")
    $pwshHash = '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139'
    # 旧 pair 已复现；仅新 helper 绑定当前仓库原始 hash，并启用有界脱敏构建诊断。
    $helper = Update-C1bHelperCandidateTemplate $HelperTemplateSource $RepositoryLibraryHashes
    $helper = Replace-C1bCandidateExactText $helper '__FINAL_COMMIT_SHA__' $CommitSha
    $helper = Replace-C1bCandidateExactText $helper '__FINAL_COMMIT_SHORT__' $short
    # 原冻结 template 保持原 hash；只转换新 candidate 的运行时/progress/诊断/缓冲引用。
    $template = Update-C1bLauncherCandidateTemplate $LauncherTemplateSource
    $slots = [ordered]@{
        '__FINAL_COMMIT_SHA__'=$CommitSha; '__FINAL_COMMIT_SHORT__'=$short
        '__REPO_ROOT__'=$RepoRoot; '__FAILURE_SIDECAR_ABSOLUTE_PATH__'=$failurePath
        '__HELPER_ABSOLUTE_PATH__'=$helperPath; '__HELPER_SHA256__'=(Get-C1bCandidateSourceHash $helper)
        '__VERIFIER_SHA256__'=$VerifierSha256
        '__PWSH_ABSOLUTE_PATH__'=$PwshPath; '__PWSH_SHA256__'=$pwshHash
    }
    $launcher = $template
    foreach ($slot in $slots.Keys) { $launcher = Replace-C1bCandidateExactText $launcher $slot $slots[$slot] }
    $outputRoot = [IO.Path]::Combine($RepoRoot, '.checks')
    $constants = [ordered]@{
        stagingRoot=$StagingRoot; repoRoot=$RepoRoot; commitSha=$CommitSha; commitShort=$short
        helperPath=$helperPath; launcherPath=$launcherPath
        helperTemporaryPath=[IO.Path]::Combine($StagingRoot, "helper-$short-r11.rendering.tmp")
        launcherTemporaryPath=[IO.Path]::Combine($StagingRoot, "launcher-$short-r11.rendering.tmp")
        failureSidecarPath=$failurePath
        summaryPath=[IO.Path]::Combine($outputRoot, "tablet-c1b-real-build-smoke-$short.summary.json")
        logPath=[IO.Path]::Combine($outputRoot, "tablet-c1b-real-build-smoke-$short.log")
        launcherResultPath=[IO.Path]::Combine($outputRoot, "tablet-c1b-real-build-smoke-$short.launcher.json")
        pwshPath=$PwshPath
        utilityAssemblyPath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($PwshPath), 'Microsoft.PowerShell.Commands.Utility.dll')
        expectedPwshSha256=$pwshHash; expectedPwshVersion='7.6.5'
        expectedVerifierSha256=$VerifierSha256
        expectedUtilityAssemblySha256=$UtilityAssemblySha256; expectedUtilityAssemblyLength=$UtilityAssemblyLength
        expectedHelperSha256=(Get-C1bCandidateSourceHash $helper)
        expectedLauncherSha256=(Get-C1bCandidateSourceHash $launcher)
        expectedHelperLength=[long][Text.UTF8Encoding]::new($false).GetByteCount($helper)
        expectedLauncherLength=[long][Text.UTF8Encoding]::new($false).GetByteCount($launcher)
    }
    $renderer = Set-C1bCandidateLiteralAssignments $BaselineRendererSource $constants
    $helperAnchor = '$helperText = [string]$inputByLabel[''helper_template''].Text'
    $renderer = Replace-C1bCandidateExactText $renderer $helperAnchor (
        $helperAnchor + "`r`n" + (New-C1bHelperRendererTransformSource $HelperTemplateSource $RepositoryLibraryHashes))
    $anchor = '$launcherText = [string]$inputByLabel[''launcher_template_r11''].Text'
    $renderer = Replace-C1bCandidateExactText $renderer $anchor (
        $anchor + "`r`n" + (New-C1bLauncherRendererTransformSource $LauncherTemplateSource))
    [void](Get-C1bCandidateSourceAst $renderer)
    [void](Get-C1bCandidateSourceAst $launcher)
    [void](Get-C1bCandidateSourceAst $helper)
    return [pscustomobject]@{
        RendererSource=$renderer; HelperSource=$helper; LauncherSource=$launcher
        LauncherTemplateSha256=(Get-C1bCandidateSourceHash $template)
        HelperSha256=$constants.expectedHelperSha256; LauncherSha256=$constants.expectedLauncherSha256
        HelperByteLength=$constants.expectedHelperLength; LauncherByteLength=$constants.expectedLauncherLength
    }
}

function New-C1bPreflightR14CandidateSource {
    param(
        [Parameter(Mandatory)][string]$BaselineLeafSource,
        [Parameter(Mandatory)][string]$ChecksSource,
        [Parameter(Mandatory)][Collections.IDictionary]$Constants
    )
    if ((Get-C1bCandidateSourceHash $BaselineLeafSource) -cne
        'bf15d0097fa02c9c99f69f8b08b5415390728bfb3d054b84bbd7895abafcd57c') {
        throw 'Frozen r13 preflight source drifted.'
    }
    $BaselineLeafSource = Update-C1bPreflightLauncherBootstrapAssertion $BaselineLeafSource
    return Add-C1bPreflightR14ChecksToSource -BaselineLeafSource $BaselineLeafSource `
        -ChecksSource $ChecksSource -Constants $Constants
}

function Update-C1bPreflightLauncherBootstrapAssertion {
    param([Parameter(Mandatory)][string]$Source)
    $old = @'
        $childEndStatements.Count -eq 5 -and
        (Get-CompactAstText $childEndStatements[0]) -ceq
            '$ErrorActionPreference=''Stop''' -and
        [object]::ReferenceEquals(
            $childEndStatements[1],
            $childStrictModeCommands[0].Parent) -and
        $childEndStatements[2] -is
            [Management.Automation.Language.AssignmentStatementAst] -and
        (Get-CompactAstText $childEndStatements[2]) -ceq
            '$gate=[Threading.EventWaitHandle]::OpenExisting($env:TL1C1B_LAUNCH_GATE)'
'@
    $new = @'
        $childEndStatements.Count -eq 6 -and
        (Get-CompactAstText $childEndStatements[0]) -ceq
            '$ProgressPreference=''SilentlyContinue''' -and
        (Get-CompactAstText $childEndStatements[1]) -ceq
            '$ErrorActionPreference=''Stop''' -and
        [object]::ReferenceEquals(
            $childEndStatements[2],
            $childStrictModeCommands[0].Parent) -and
        $childEndStatements[3] -is
            [Management.Automation.Language.AssignmentStatementAst] -and
        (Get-CompactAstText $childEndStatements[3]) -ceq
            '$gate=[Threading.EventWaitHandle]::OpenExisting($env:TL1C1B_LAUNCH_GATE)'
'@
    $newline = if ($Source.Contains("`r`n")) { "`r`n" } else { "`n" }
    return Replace-C1bCandidateExactText $Source `
        ($old.Replace("`r`n", "`n").Replace("`n", $newline)) `
        ($new.Replace("`r`n", "`n").Replace("`n", $newline))
}

function Add-C1bPreflightR14ChecksToSource {
    # 仅供转换器/离线 fixture；生产入口必须先验证冻结源 hash。
    param([Parameter(Mandatory)][string]$BaselineLeafSource,
        [Parameter(Mandatory)][string]$ChecksSource,
        [Parameter(Mandatory)][Collections.IDictionary]$Constants)
    $checksAst = Get-C1bCandidateSourceAst $ChecksSource
    if ($checksAst.ParamBlock -or $checksAst.BeginBlock -or $checksAst.ProcessBlock -or
        @($checksAst.EndBlock.Statements | Where-Object {
            $_ -isnot [Management.Automation.Language.FunctionDefinitionAst]
        }).Count -ne 0) { throw 'R14 checks must contain functions only.' }
    foreach ($name in @('repoRoot','stagingRoot','expectedCommitSha','expectedCommitShort',
        'helperPath','expectedHelperSha256','expectedHelperByteLength',
        'launcherPath','expectedLauncherSha256','expectedLauncherByteLength',
        'expectedLauncherTemplateSha256','failureSidecarPath','pwshPath','expectedPwshSha256',
        'expectedGitIndexSha256','expectedGitTrackedPathCount','expectedGitConfigSha256',
        'expectedGitAttributesSha256','expectedGitIgnoreSha256','expectedGitInfoExcludeSha256',
        'expectedVerifierSha256','summaryLeaf','logLeaf','launcherResultLeaf','receiptLeaf')) {
        if (-not $Constants.Contains($name)) { throw "Missing exact r14 constant: $name" }
    }
    if ($Constants.expectedCommitSha -cnotmatch '^[a-f0-9]{40}$' -or
        $Constants.expectedCommitShort -cne $Constants.expectedCommitSha.Substring(0,7) -or
        $Constants.expectedPwshSha256 -cne
        '362a356ce7f0940ec74f73a8fc2c990a2cc24a38a11c90bbd8eca947110ad139') {
        throw 'R14 commit/runtime binding is invalid.'
    }
    $source = Set-C1bCandidateLiteralAssignments $BaselineLeafSource $Constants
    foreach ($old in @("'-r10.ps1'", "'-r10.failure.json'")) {
        $count = if ($old -ceq "'-r10.ps1'") { 2 } else { 1 }
        $source = Replace-C1bCandidateExactText $source $old ($old.Replace('r10','r11')) $count
    }
    $newline = if ($BaselineLeafSource.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalizedChecks = $ChecksSource.Replace("`r`n", "`n").Replace("`n", $newline)
    $source = Replace-C1bCandidateExactText $source 'function Invoke-ReadOnlyGit {' (
        $normalizedChecks.TrimEnd() + $newline + $newline + 'function Invoke-ReadOnlyGit {')
    $initial = @'
$gitTrustTreeBefore = $null
$gitTrustTreeAfter = $null
$gitTrustTreePreCheckAttemptCount = 0L
$gitTrustTreePostCheckAttemptCount = 0L
$gitTrustTreePostCheckFailureCount = 0L
$gitTrustTreePostCheckFailureReasons = [Collections.Generic.List[string]]::new()
$gitTrustTreeContinuityVerified = $false
$launcherByteReturnCanary = $null
$launcherStreamContract = $null
'@
    $source = Replace-C1bCandidateExactText $source '$gitInvocationCount = 0L' (
        $initial.Replace("`r`n", "`n").Replace("`n", $newline) + $newline + '$gitInvocationCount = 0L')
    $pre = @'
    $gitTrustTreePreCheckAttemptCount++
    $gitTrustTreeBefore = Get-TL1C1bPreflightGitTreeSnapshot `
        -Root ([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($gitPath)))) `
        -ExpectedFileCount 9576L `
        -ExpectedCatalogSha256 'sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458' `
        -ExpectedIdentityCount 9489L -ExpectedInternalHardlinkGroupCount 85L -Stage 'before_git'
'@
    $source = Replace-C1bCandidateExactText $source '    $gitRepositoryIdentity = Invoke-ReadOnlyGit @(' (
        $pre.Replace("`r`n", "`n").Replace("`n", $newline) + $newline + '    $gitRepositoryIdentity = Invoke-ReadOnlyGit @(')
    # 主 finally 内只追加结果；后置异常不能替换已固定的 primary。
    $post = @'
    if ($null -ne $gitTrustTreeBefore) {
        $gitTrustTreePostCheckAttemptCount++
        try {
            $gitTrustTreeAfter = Get-TL1C1bPreflightGitTreeSnapshot `
                -Root $gitTrustTreeBefore.Root -ExpectedFileCount 9576L `
                -ExpectedCatalogSha256 'sha256:4c5e585b10f371f181b42b60948a883409c0efda910b869ff98c2e5604267458' `
                -ExpectedIdentityCount 9489L -ExpectedInternalHardlinkGroupCount 85L -Stage 'after_git'
            Assert-TL1C1bPreflightGitTreeContinuity -Before $gitTrustTreeBefore -After $gitTrustTreeAfter
            $gitTrustTreeContinuityVerified = $true
        }
        catch {
            $gitTrustTreePostCheckFailureCount++
            $gitTrustTreePostCheckFailureReasons.Add($_.Exception.ToString())
            $failures.Add('Git trust-root post-check: ' + $_.Exception.ToString())
        }
    }
'@
    $anchor = 'finally {' + $newline + '    $cleanupFailures = [Collections.Generic.List[string]]::new()'
    $source = Replace-C1bCandidateExactText $source $anchor (
        'finally {' + $newline + $post.Replace("`r`n", "`n").Replace("`n", $newline) +
        $newline + '    $cleanupFailures = [Collections.Generic.List[string]]::new()')
    $source = Replace-C1bCandidateExactText $source '    $launcherParsed = Parse-HeldPowerShell $launcherBinding' (
        '    $launcherParsed = Parse-HeldPowerShell $launcherBinding' + $newline +
        '    $launcherByteReturnCanary = Assert-TL1C1bPreflightLauncherByteReturn -LauncherAst $launcherParsed.Ast' + $newline +
        '    $launcherStreamContract = Assert-TL1C1bPreflightLauncherStreamContract -LauncherAst $launcherParsed.Ast')
    $gates = @'
    $gitTrustTreePreCheckAttemptCount -eq 1L -and
    $gitTrustTreePostCheckAttemptCount -eq 1L -and
    $gitTrustTreePostCheckFailureCount -eq 0L -and
    $gitTrustTreeContinuityVerified -and
    $null -ne $launcherByteReturnCanary -and
    $null -ne $launcherStreamContract -and
'@
    $source = Replace-C1bCandidateExactText $source '    $gitInvocationCount -eq 4L -and' (
        $gates.Replace("`r`n", "`n").Replace("`n", $newline) + $newline + '    $gitInvocationCount -eq 4L -and')
    $evidence = @'
    git_trust_root_before = $gitTrustTreeBefore
    git_trust_root_after = $gitTrustTreeAfter
    git_trust_root_pre_check_attempt_count = $gitTrustTreePreCheckAttemptCount
    git_trust_root_post_check_attempt_count = $gitTrustTreePostCheckAttemptCount
    git_trust_root_post_check_failure_count = $gitTrustTreePostCheckFailureCount
    git_trust_root_post_check_failure_reasons = [string[]]$gitTrustTreePostCheckFailureReasons.ToArray()
    git_trust_root_continuity_verified = $gitTrustTreeContinuityVerified
    git_trust_root_transient_change_excluded = $false
    launcher_byte_return_canary = $launcherByteReturnCanary
    launcher_stream_contract = $launcherStreamContract
'@
    $source = Replace-C1bCandidateExactText $source '    read_only_git_invocation_count = [long]$gitInvocationCount' (
        $evidence.Replace("`r`n", "`n").Replace("`n", $newline) + $newline +
        '    read_only_git_invocation_count = [long]$gitInvocationCount')
    [void](Get-C1bCandidateSourceAst $source)
    return $source
}

function New-C1bPreflightR14RendererSource {
    param([Parameter(Mandatory)][string]$PairRendererSource,
        [Parameter(Mandatory)][string]$PreflightSource,
        [Parameter(Mandatory)][string]$BaselineLeafPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$IndexSha256,
        [Parameter(Mandatory)][ValidateRange(12,4194304)][long]$IndexByteLength)
    # 复用上一 renderer 的 bootstrap、no-follow held inputs 与同句柄发布函数。
    # 候选字节嵌入 renderer 并另钉 hash/length；不动态读取可变转换库。
    $anchor = '$directoryChains = [Collections.Generic.List[object]]::new()'
    $offset = $PairRendererSource.IndexOf($anchor, [StringComparison]::Ordinal)
    if ($offset -lt 0 -or $PairRendererSource.LastIndexOf($anchor, [StringComparison]::Ordinal) -ne $offset) {
        throw 'Renderer publication boundary is not unique.'
    }
    $prefix = $PairRendererSource.Substring(0, $offset)
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($PreflightSource)
    $config = @'
$r14BaselineLeafPath = '__BASELINE_LEAF__'
$r14SourceBase64 = '__SOURCE_BASE64__'
$r14SourceSha256 = '__SOURCE_HASH__'
$r14SourceLength = __SOURCE_LENGTH__L
$r14IndexSha256 = '__INDEX_HASH__'
$r14IndexLength = __INDEX_LENGTH__L
$r14LeafPath = [IO.Path]::Combine($stagingRoot, "preflight-$commitShort-r14.ps1")
$r14TemporaryPath = [IO.Path]::Combine($stagingRoot, "preflight-$commitShort-r14.rendering.tmp")
$r14ReceiptPath = [IO.Path]::Combine($stagingRoot, "preflight-$commitShort-r14.prepared-not-authorized.receipt.json")
$r14IndexPath = [IO.Path]::Combine($repoRoot, '.git', 'index')
$directoryChains = [Collections.Generic.List[object]]::new()
$inputs = [Collections.Generic.List[object]]::new()
$candidates = [Collections.Generic.List[object]]::new()
$mainPrimary = $null
$mainCleanup = [Collections.Generic.List[System.Exception]]::new()
$successJson = $null
$decoded = $null
try {
    foreach ($path in @($stagingRoot,$repoRoot,$outputRoot,$r14BaselineLeafPath,$r14LeafPath,$r14TemporaryPath,
        $r14ReceiptPath,$r14IndexPath,$helperPath,$launcherPath,$pwshPath,$utilityAssemblyPath,$verifierPath)) {
        Assert-RendererCanonicalPath $path 'r14 authority path'
    }
    foreach ($path in @($stagingRoot,$repoRoot,$pwshPath)) {
        $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($path))
        Assert-Renderer ($drive.IsReady -and $drive.DriveFormat -ceq 'NTFS') 'R14 renderer requires ready NTFS.'
    }
    foreach ($path in @($r14BaselineLeafPath,$r14LeafPath,$r14TemporaryPath,$r14ReceiptPath,$helperPath,$launcherPath)) {
        Assert-Renderer ([StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetDirectoryName($path),$stagingRoot)) 'R14 staging child escaped parent.'
    }
    foreach ($path in @($stagingRoot,$outputRoot,[IO.Path]::GetDirectoryName($r14IndexPath),
        [IO.Path]::GetDirectoryName($pwshPath),[IO.Path]::GetDirectoryName($verifierPath))) {
        $directoryChains.Add((Open-RendererDirectoryChain -Path $path -Label 'r14 authority parent'))
    }
    $stagingDirectoryEntry = $directoryChains[0].Entries[$directoryChains[0].Entries.Count - 1]
    Assert-RendererEntriesAbsent ([string[]]@($r14LeafPath,$r14TemporaryPath,$r14ReceiptPath,
        $failureSidecarPath,$summaryPath,$logPath,$launcherResultPath)) 'r14 unused output'
    $specs = @(
        @{Path=$r14BaselineLeafPath;Hash='bf15d0097fa02c9c99f69f8b08b5415390728bfb3d054b84bbd7895abafcd57c';Length=300938L;Frozen=$true;Parse=$true},
        @{Path=$r14IndexPath;Hash=$r14IndexSha256;Length=$r14IndexLength;Frozen=$false;Parse=$false},
        @{Path=$helperPath;Hash=$expectedHelperSha256;Length=$expectedHelperLength;Frozen=$true;Parse=$true},
        @{Path=$launcherPath;Hash=$expectedLauncherSha256;Length=$expectedLauncherLength;Frozen=$true;Parse=$true},
        @{Path=$pwshPath;Hash=$expectedPwshSha256;Length=1048576L;Frozen=$false;Parse=$false},
        @{Path=$utilityAssemblyPath;Hash=$expectedUtilityAssemblySha256;Length=$expectedUtilityAssemblyLength;Frozen=$false;Parse=$false},
        @{Path=$verifierPath;Hash=$expectedVerifierSha256;Length=1048576L;Frozen=$false;Parse=$true}
    )
    foreach ($spec in $specs) {
        $inputs.Add((Open-RendererInput -Path $spec.Path -ExpectedSha256 $spec.Hash `
            -MaximumLength $spec.Length -RequireReadOnly $spec.Frozen -DecodeUtf8 $spec.Parse `
            -ParsePowerShell $spec.Parse -Label 'r14 exact source input'))
    }
    $decoded = [Convert]::FromBase64String($r14SourceBase64)
    Assert-Renderer ($decoded.Length -eq $r14SourceLength) 'R14 embedded source length drifted.'
    $rendered = [Text.UTF8Encoding]::new($false,$true).GetString($decoded)
    $candidate = New-RendererCandidate -TemporaryPath $r14TemporaryPath -FinalPath $r14LeafPath `
        -Text $rendered -ExpectedSha256 $r14SourceSha256 -ExpectedLength $r14SourceLength `
        -ParentDirectoryEntry $stagingDirectoryEntry -Label 'exact r14 preflight'
    $candidates.Add($candidate)
    foreach ($chain in $directoryChains) { Assert-RendererDirectoryChainStillBound $chain }
    foreach ($inputObject in $inputs) { Assert-RendererInputStillBound $inputObject }
    Publish-RendererCandidate $candidate
    foreach ($chain in $directoryChains) { Assert-RendererDirectoryChainStillBound $chain }
    foreach ($inputObject in $inputs) { Assert-RendererInputStillBound $inputObject }
    Assert-RendererCandidateStillBound $candidate $r14LeafPath $true
    Assert-RendererEntriesAbsent ([string[]]@($r14TemporaryPath,$r14ReceiptPath,$failureSidecarPath,
        $summaryPath,$logPath,$launcherResultPath)) 'r14 unauthorized output'
    $success = [pscustomobject][ordered]@{
        schema='tablet-layout-c1b-r14-render/v1'; commit_sha=$commitSha
        renderer_execution_scope='artifact_generation_only'
        preflight_path=$r14LeafPath; preflight_sha256=$candidate.Sha256
        preflight_byte_length=$candidate.ByteLength; preflight_read_only=$true
        inputs_held_deny_data_write_delete_sharing=$true; publication_same_handle_rename_no_replace=$true
        final_paths_verified_from_held_handles=$true; final_stable_ids_revalidated=$true
        final_bytes_revalidated_from_held_handles=$true; continuous_namespace_lease_claimed=$false
        launcher_executed=$false; helper_executed=$false; preflight_executed=$false
        git_executed=$false; build_executed=$false; adb_or_device_operation_executed=$false
    }
    $records = @(Invoke-RendererPinnedCmdlet -Name 'ConvertTo-Json' `
        -CmdletType $pinnedConvertToJsonCmdletType -Parameters @{InputObject=$success;Depth=5;Compress=$true})
    Assert-Renderer ($records.Count -eq 1) 'R14 renderer success record count drifted.'
    $successJson = [string]$records[0]
}
catch { $mainPrimary = $_ }
finally {
    if ($null -ne $decoded) {
        try { [Array]::Clear($decoded,0,$decoded.Length) } catch { $mainCleanup.Add($_.Exception) }
    }
    foreach ($candidate in $candidates) {
        try { $candidate.Stream.Dispose() } catch { $mainCleanup.Add($_.Exception) }
        try { [Array]::Clear($candidate.Bytes,0,$candidate.Bytes.Length) } catch { $mainCleanup.Add($_.Exception) }
    }
    for ($i=$inputs.Count-1; $i -ge 0; $i--) {
        try { $inputs[$i].Stream.Dispose() } catch { $mainCleanup.Add($_.Exception) }
        try { [Array]::Clear($inputs[$i].Bytes,0,$inputs[$i].Bytes.Length) } catch { $mainCleanup.Add($_.Exception) }
    }
    for ($i=$directoryChains.Count-1; $i -ge 0; $i--) {
        for ($j=$directoryChains[$i].Entries.Count-1; $j -ge 0; $j--) {
            try { $directoryChains[$i].Entries[$j].Handle.Dispose() } catch { $mainCleanup.Add($_.Exception) }
        }
    }
}
Complete-RendererLocalFailure -Label 'r14 renderer' -Primary $mainPrimary -Cleanup ([System.Exception[]]$mainCleanup.ToArray())
Assert-Renderer (-not [string]::IsNullOrWhiteSpace($successJson)) 'R14 renderer has no success record.'
[Console]::Out.WriteLine($successJson)
'@
    foreach ($slot in ([ordered]@{
        '__BASELINE_LEAF__'=$BaselineLeafPath.Replace("'", "''")
        '__SOURCE_BASE64__'=[Convert]::ToBase64String($bytes)
        '__SOURCE_HASH__'=(Get-C1bCandidateSourceHash $PreflightSource)
        '__SOURCE_LENGTH__'=$bytes.Length.ToString([Globalization.CultureInfo]::InvariantCulture)
        '__INDEX_HASH__'=$IndexSha256
        '__INDEX_LENGTH__'=$IndexByteLength.ToString([Globalization.CultureInfo]::InvariantCulture)
    }).GetEnumerator()) { $config = Replace-C1bCandidateExactText $config $slot.Key $slot.Value }
    $result = $prefix + $config
    [void](Get-C1bCandidateSourceAst $result)
    return $result
}
